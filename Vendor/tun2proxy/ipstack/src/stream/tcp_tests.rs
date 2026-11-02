// Elarni: the TCP behaviour a TUN client needs from this stack, driven with raw packets.
use crate::{
    IpStack, IpStackConfig, IpStackStream, IpStackTcpStream,
    packet::{NetworkPacket, TransportHeader},
};
use etherparse::{PacketBuilder, SlicedPacket, TcpOptionElement, TransportSlice};
use std::pin::Pin;
use std::task::{Context, Poll};
use std::time::{Duration, Instant};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, ReadBuf};
use tokio::sync::mpsc::{UnboundedReceiver, UnboundedSender, unbounded_channel};

struct Device {
    input: UnboundedReceiver<Vec<u8>>,
    output: UnboundedSender<Vec<u8>>,
}

impl AsyncRead for Device {
    fn poll_read(mut self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &mut ReadBuf<'_>) -> Poll<std::io::Result<()>> {
        match self.input.poll_recv(cx) {
            Poll::Ready(Some(packet)) => {
                buf.put_slice(&packet);
                Poll::Ready(Ok(()))
            }
            Poll::Ready(None) => Poll::Ready(Ok(())),
            Poll::Pending => Poll::Pending,
        }
    }
}

impl AsyncWrite for Device {
    fn poll_write(self: Pin<&mut Self>, _: &mut Context<'_>, buf: &[u8]) -> Poll<std::io::Result<usize>> {
        let _ = self.output.send(buf.to_vec());
        Poll::Ready(Ok(buf.len()))
    }
    fn poll_flush(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Poll::Ready(Ok(()))
    }
    fn poll_shutdown(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Poll::Ready(Ok(()))
    }
}

const CLIENT: [u8; 4] = [10, 7, 0, 2];
const SERVER: [u8; 4] = [93, 184, 216, 34];
const ISN: u32 = 5000;
const MSS: usize = 1460;

#[derive(Clone, Copy, Default)]
struct Flags {
    syn: bool,
    fin: bool,
    rst: bool,
    psh: bool,
}

#[derive(Clone)]
struct Segment {
    seq: u32,
    ack: u32,
    window: u16,
    syn: bool,
    fin: bool,
    len: usize,
    mss: Option<u16>,
    payload: Vec<u8>,
}

impl std::fmt::Debug for Segment {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let (seq, ack, window, len) = (self.seq, self.ack, self.window, self.len);
        write!(
            f,
            "seq {seq} ack {ack} win {window} len {len}{}{}",
            if self.syn { " SYN" } else { "" },
            if self.fin { " FIN" } else { "" }
        )
    }
}

fn client_packet(seq: u32, ack: Option<u32>, flags: Flags, window: u16, options: &[TcpOptionElement], data: &[u8]) -> Vec<u8> {
    let mut builder = PacketBuilder::ipv4(CLIENT, SERVER, 64).tcp(41000, 443, seq, window);
    if !options.is_empty() {
        builder = builder.options(options).unwrap();
    }
    if flags.syn {
        builder = builder.syn();
    }
    if let Some(ack) = ack {
        builder = builder.ack(ack);
    }
    if flags.fin {
        builder = builder.fin();
    }
    if flags.rst {
        builder = builder.rst();
    }
    if flags.psh {
        builder = builder.psh();
    }
    let mut packet = Vec::new();
    builder.write(&mut packet, data).unwrap();
    packet
}

fn parse(packet: &[u8]) -> Option<Segment> {
    let sliced = SlicedPacket::from_ip(packet).ok()?;
    let Some(TransportSlice::Tcp(tcp)) = sliced.transport else {
        return None;
    };
    let mss = tcp.options_iterator().find_map(|option| match option {
        Ok(TcpOptionElement::MaximumSegmentSize(value)) => Some(value),
        _ => None,
    });
    Some(Segment {
        seq: tcp.sequence_number(),
        ack: tcp.acknowledgment_number(),
        window: tcp.window_size(),
        syn: tcp.syn(),
        fin: tcp.fin(),
        len: tcp.payload().len(),
        mss,
        payload: tcp.payload().to_vec(),
    })
}

struct Peer {
    input: UnboundedSender<Vec<u8>>,
    output: UnboundedReceiver<Vec<u8>>,
    _stack: IpStack,
    /// The stack's first data sequence number.
    server_seq: u32,
    syn_ack: Segment,
}

impl Peer {
    fn send(&self, seq_offset: u32, ack: u32, flags: Flags, window: u16, data: &[u8]) {
        let packet = client_packet(ISN + 1 + seq_offset, Some(ack), flags, window, &[], data);
        self.input.send(packet).unwrap();
    }

    /// Every segment the stack sends within `wait`.
    async fn collect(&mut self, wait: Duration) -> Vec<(Duration, Segment)> {
        self.collect_until(wait, |_| false).await
    }

    /// The segments the stack sends until one satisfies `done`, for at most `wait`.
    async fn collect_until(&mut self, wait: Duration, done: impl Fn(&Segment) -> bool) -> Vec<(Duration, Segment)> {
        let start = Instant::now();
        let mut segments = Vec::new();
        while let Some(left) = wait.checked_sub(start.elapsed()) {
            match tokio::time::timeout(left, self.output.recv()).await {
                Ok(Some(packet)) => {
                    if let Some(segment) = parse(&packet) {
                        let finished = done(&segment);
                        segments.push((start.elapsed(), segment));
                        if finished {
                            break;
                        }
                    }
                }
                _ => break,
            }
        }
        segments
    }

    /// Waits for the stack's FIN and returns its sequence number.
    async fn fin(&mut self) -> u32 {
        let segments = self.collect_until(Duration::from_secs(2), |s| s.fin).await;
        segments
            .iter()
            .find(|(_, s)| s.fin)
            .unwrap_or_else(|| panic!("no FIN: {segments:?}"))
            .1
            .seq
    }
}

async fn connect(window: u16, options: &[TcpOptionElement]) -> (Peer, IpStackTcpStream) {
    let (input, device_input) = unbounded_channel();
    let (device_output, mut output) = unbounded_channel();
    let mut config = IpStackConfig::default();
    config.mtu(1500).unwrap();
    let mut stack = IpStack::new(
        config,
        Device {
            input: device_input,
            output: device_output,
        },
    );
    input
        .send(client_packet(
            ISN,
            None,
            Flags {
                syn: true,
                ..Flags::default()
            },
            window,
            options,
            &[],
        ))
        .unwrap();
    let IpStackStream::Tcp(stream) = stack.accept().await.unwrap() else {
        panic!("not TCP")
    };
    let syn_ack = parse(&output.recv().await.unwrap()).unwrap();
    assert!(syn_ack.syn);
    let server_seq = syn_ack.seq.wrapping_add(1);
    input
        .send(client_packet(ISN + 1, Some(server_seq), Flags::default(), window, &[], &[]))
        .unwrap();
    (
        Peer {
            input,
            output,
            _stack: stack,
            server_seq,
            syn_ack,
        },
        stream,
    )
}

// A 16 KiB send limit capped one download at 16 KiB per TUN round trip.
#[tokio::test(flavor = "multi_thread")]
async fn a_full_client_window_is_filled_past_sixteen_kib() {
    let (mut peer, mut stream) = connect(65535, &[]).await;
    assert_eq!(peer.syn_ack.mss, Some(MSS as u16), "SYN-ACK must carry the MSS");
    tokio::spawn(async move {
        let chunk = vec![1u8; 8192];
        while stream.write_all(&chunk).await.is_ok() {}
    });
    let sent: usize = peer.collect(Duration::from_millis(150)).await.iter().map(|(_, s)| s.len).sum();
    assert!(sent >= 60 * 1024, "only {sent} bytes in flight against a 64 KiB window");
    assert!(sent <= 65535, "{sent} bytes overran a 64 KiB window");
}

#[tokio::test(flavor = "multi_thread")]
async fn segments_respect_the_client_mss() {
    let (mut peer, mut stream) = connect(65535, &[TcpOptionElement::MaximumSegmentSize(536)]).await;
    stream.write_all(&[2u8; 4000]).await.unwrap();
    let segments = peer.collect(Duration::from_millis(200)).await;
    assert!(!segments.is_empty() && segments.iter().all(|(_, s)| s.len <= 536), "{segments:?}");
}

// Retransmission only ran when a packet arrived, so a lost last segment hung the transfer.
#[tokio::test(flavor = "multi_thread")]
async fn a_lost_last_segment_is_retransmitted_without_client_traffic() {
    let (mut peer, mut stream) = connect(65535, &[]).await;
    stream.write_all(&[2u8; 4000]).await.unwrap();
    let sent = peer.collect(Duration::from_millis(100)).await;
    let last = sent.iter().filter(|(_, s)| s.len > 0).map(|(_, s)| s.seq).max().unwrap();
    peer.send(0, last, Flags::default(), 65535, &[]); // all but the last segment arrived
    let resent = peer
        .collect_until(Duration::from_millis(2500), |s| s.seq == last && s.len > 0)
        .await;
    assert!(
        resent.iter().any(|(_, s)| s.seq == last && s.len > 0),
        "no retransmission of {last}: {resent:?}"
    );
}

// The stack ACKed every upload byte into an unbounded queue while the app did not read.
#[tokio::test(flavor = "multi_thread")]
async fn an_unread_upload_closes_the_window_and_reopens_it_on_read() {
    let (mut peer, mut stream) = connect(65535, &[]).await;
    let (mut next, mut acked, mut window) = (0usize, 0usize, peer.syn_ack.window as usize);
    let start = Instant::now();
    while start.elapsed() < Duration::from_millis(800) {
        while next < acked + window {
            let len = MSS.min(acked + window - next);
            peer.send(
                next as u32,
                peer.server_seq,
                Flags {
                    psh: true,
                    ..Flags::default()
                },
                65535,
                &[7u8; MSS][..len],
            );
            next += len;
        }
        for (_, segment) in peer.collect(Duration::from_millis(20)).await {
            acked = acked.max(segment.ack.wrapping_sub(ISN + 1) as usize);
            window = segment.window as usize;
        }
    }
    assert!(acked <= 256 * 1024, "ACKed {acked} unread bytes");
    assert_eq!(window, 0, "the window must close while nothing is read");
    let mut buffer = vec![0u8; acked];
    stream.read_exact(&mut buffer).await.unwrap();
    let update = peer.collect(Duration::from_millis(300)).await;
    assert!(
        update.iter().any(|(_, s)| s.window > 0),
        "no window update after the read: {update:?}"
    );
}

// A client FIN never reached the app, so the proxy side never saw the request end.
#[tokio::test(flavor = "multi_thread")]
async fn a_client_fin_ends_the_read_and_the_reply_still_flows() {
    let (mut peer, mut stream) = connect(65535, &[]).await;
    peer.send(
        0,
        peer.server_seq,
        Flags {
            psh: true,
            fin: true,
            ..Flags::default()
        },
        65535,
        b"request",
    );
    let mut request = Vec::new();
    tokio::time::timeout(Duration::from_secs(2), stream.read_to_end(&mut request))
        .await
        .expect("read hung after FIN")
        .unwrap();
    assert_eq!(request, b"request");
    let early = peer.collect(Duration::from_millis(100)).await;
    assert!(
        early.iter().all(|(_, s)| !s.fin),
        "the stack closed before the app finished: {early:?}"
    );
    stream.write_all(b"reply").await.unwrap();
    let shutdown = tokio::spawn(async move {
        stream.shutdown().await.unwrap();
        stream
    });
    let ack = ISN + 1 + 7 + 1;
    let reply = peer.collect(Duration::from_millis(100)).await;
    assert!(
        reply.iter().all(|(_, s)| s.ack == ack && !s.fin),
        "FIN before the reply was acknowledged: {reply:?}"
    );
    let data: Vec<u8> = reply.iter().flat_map(|(_, s)| s.payload.clone()).collect();
    assert_eq!(data, b"reply");
    peer.send(8, peer.server_seq + 5, Flags::default(), 65535, &[]);
    let fin = peer.collect(Duration::from_millis(100)).await;
    let fin = fin
        .iter()
        .find(|(_, s)| s.fin)
        .unwrap_or_else(|| panic!("no FIN after the app shut down: {fin:?}"))
        .1
        .seq;
    assert_eq!(fin, peer.server_seq + 5);
    peer.send(8, fin.wrapping_add(1), Flags::default(), 65535, &[]);
    tokio::time::timeout(Duration::from_secs(2), shutdown)
        .await
        .expect("shutdown hung")
        .unwrap();
}

#[tokio::test(flavor = "multi_thread")]
async fn a_client_reset_ends_a_pending_read() {
    let (peer, mut stream) = connect(65535, &[]).await;
    let reader = tokio::spawn(async move {
        let mut buffer = [0u8; 16];
        stream.read(&mut buffer).await
    });
    tokio::time::sleep(Duration::from_millis(50)).await;
    peer.send(
        0,
        peer.server_seq,
        Flags {
            rst: true,
            ..Flags::default()
        },
        0,
        &[],
    );
    let result = tokio::time::timeout(Duration::from_secs(1), reader)
        .await
        .expect("read hung after RST")
        .unwrap();
    assert!(matches!(result, Ok(0) | Err(_)), "{result:?}");
}

// Out-of-order data got no duplicate ACKs (no fast retransmit) and PSH segments were discarded.
#[tokio::test(flavor = "multi_thread")]
async fn out_of_order_segments_get_duplicate_acks_and_are_kept() {
    let (mut peer, mut stream) = connect(65535, &[]).await;
    let flags = Flags {
        psh: true,
        ..Flags::default()
    };
    for index in [0u32, 2, 3, 4, 5] {
        peer.send(index * 1000, peer.server_seq, flags, 65535, &[index as u8; 1000]);
    }
    let gap = ISN + 1 + 1000;
    let duplicates = peer
        .collect(Duration::from_millis(200))
        .await
        .iter()
        .filter(|(_, s)| s.ack == gap)
        .count();
    assert!(duplicates >= 4, "{duplicates} ACKs at the gap, want one per segment");
    peer.send(1000, peer.server_seq, flags, 65535, &[1u8; 1000]);
    let acks = peer.collect(Duration::from_millis(200)).await;
    assert!(
        acks.iter().any(|(_, s)| s.ack == ISN + 1 + 6000),
        "the filled gap must ACK all data: {acks:?}"
    );
    let mut data = vec![0u8; 6000];
    stream.read_exact(&mut data).await.unwrap();
    for index in 0..6 {
        assert!(
            data[index * 1000..(index + 1) * 1000].iter().all(|&b| b == index as u8),
            "segment {index} corrupted"
        );
    }
}

// A write right after accept went out before the SYN-ACK, which then carried a sequence number past the data.
// One thread, and the write is polled before the stream's task first runs and sends the SYN-ACK.
#[tokio::test(flavor = "current_thread")]
async fn data_written_before_the_handshake_waits_for_it() {
    let (up, mut output) = unbounded_channel::<NetworkPacket>();
    let syn = NetworkPacket::parse(&client_packet(
        ISN,
        None,
        Flags {
            syn: true,
            ..Flags::default()
        },
        65535,
        &[],
        &[],
    ))
    .unwrap();
    let TransportHeader::Tcp(header) = syn.transport_header().clone() else {
        panic!("not TCP")
    };
    let (client, server) = ((CLIENT, 41000).into(), (SERVER, 443).into());
    // Dropping a live stream blocks in place, which a current-thread runtime does not allow.
    let mut stream =
        std::mem::ManuallyDrop::new(IpStackTcpStream::new(client, server, header, up, 1500, None, Default::default()).unwrap());
    let early = tokio::time::timeout(Duration::ZERO, stream.write(b"banner")).await;
    let mut next = async || parse(&output.recv().await.unwrap().to_bytes().unwrap()).unwrap();
    let syn_ack = next().await;
    assert!(syn_ack.syn && syn_ack.len == 0, "first segment is not the SYN-ACK: {syn_ack:?}");
    let first = syn_ack.seq.wrapping_add(1);
    let ack = client_packet(ISN + 1, Some(first), Flags::default(), 65535, &[], &[]);
    stream.stream_sender().send(NetworkPacket::parse(&ack).unwrap()).unwrap();
    if early.is_err() {
        stream.write_all(b"banner").await.unwrap();
    }
    let data = tokio::time::timeout(Duration::from_secs(1), next()).await.expect("no data");
    assert_eq!((data.seq, data.payload.as_slice()), (first, &b"banner"[..]));
}

// Without SACK, macOS (like BSD) counts an ACK as a duplicate only when its window is unchanged, so a
// window that grew while the application read during a gap kept the client from fast retransmitting.
#[tokio::test(flavor = "multi_thread")]
async fn duplicate_acks_keep_their_window_while_the_application_reads() {
    let (mut peer, mut stream) = connect(65535, &[]).await;
    let flags = Flags {
        psh: true,
        ..Flags::default()
    };
    for index in 0..20u32 {
        peer.send(index * 1000, peer.server_seq, flags, 65535, &[1u8; 1000]);
    }
    let gap = ISN + 1 + 20_000;
    for index in [21u32, 22] {
        peer.send(index * 1000, peer.server_seq, flags, 65535, &[2u8; 1000]);
    }
    let mut acks = peer.collect(Duration::from_millis(100)).await;
    let mut read = vec![0u8; 10_000];
    stream.read_exact(&mut read).await.unwrap();
    for index in [23u32, 24, 25] {
        peer.send(index * 1000, peer.server_seq, flags, 65535, &[2u8; 1000]);
    }
    acks.extend(peer.collect(Duration::from_millis(100)).await);
    let windows: Vec<u16> = acks.iter().filter(|(_, s)| s.ack == gap).map(|(_, s)| s.window).collect();
    assert!(windows.len() >= 5, "{windows:?}");
    assert!(
        windows.iter().all(|&w| w == windows[0]),
        "duplicate ACK windows changed: {windows:?}"
    );
}

const FIN: Flags = Flags {
    fin: true,
    syn: false,
    rst: false,
    psh: false,
};

/// The app shuts down first; the client acknowledges our FIN, then sends `last` with its own FIN.
/// Returns the client's next sequence offset and the app's read and shutdown.
async fn close_from_the_app_first(
    last: &[u8],
) -> (
    Peer,
    tokio::task::JoinHandle<std::io::Result<Vec<u8>>>,
    tokio::task::JoinHandle<std::io::Result<()>>,
) {
    let (mut peer, stream) = connect(65535, &[]).await;
    let (mut reader, mut writer) = tokio::io::split(stream);
    let read = tokio::spawn(async move {
        let mut rest = Vec::new();
        reader.read_to_end(&mut rest).await.map(|_| rest)
    });
    let shutdown = tokio::spawn(async move { writer.shutdown().await });
    let fin = peer.fin().await;
    peer.send(0, fin.wrapping_add(1), Flags::default(), 65535, &[]);
    peer.send(0, fin.wrapping_add(1), FIN, 65535, last);
    (peer, read, shutdown)
}

// TIME_WAIT left the app's pending read asleep until the 600 s idle timeout.
#[tokio::test(flavor = "multi_thread")]
async fn a_client_fin_after_ours_ends_the_pending_read() {
    let (_peer, read, shutdown) = close_from_the_app_first(b"").await;
    let rest = tokio::time::timeout(Duration::from_secs(1), read)
        .await
        .expect("read hung after the client's FIN")
        .unwrap()
        .unwrap();
    assert!(rest.is_empty());
    tokio::time::timeout(Duration::from_secs(4), shutdown)
        .await
        .expect("shutdown hung")
        .unwrap()
        .unwrap();
}

// A FIN that came with the client's last bytes was never acknowledged.
#[tokio::test(flavor = "multi_thread")]
async fn a_client_fin_with_data_after_ours_is_acknowledged() {
    let (mut peer, read, shutdown) = close_from_the_app_first(b"bye").await;
    let fin_ack = ISN + 1 + 3 + 1;
    let acks = peer.collect_until(Duration::from_secs(1), |s| s.ack == fin_ack).await;
    assert!(
        acks.iter().any(|(_, s)| s.ack == fin_ack),
        "the client's FIN was not acknowledged: {acks:?}"
    );
    let rest = tokio::time::timeout(Duration::from_secs(1), read)
        .await
        .expect("read hung")
        .unwrap()
        .unwrap();
    assert_eq!(rest, b"bye");
    tokio::time::timeout(Duration::from_secs(4), shutdown)
        .await
        .expect("shutdown hung")
        .unwrap()
        .unwrap();
}

// FIN_WAIT_1 never resent a lost FIN and left on any ACK, so the client never saw the end.
#[tokio::test(flavor = "multi_thread")]
async fn a_lost_fin_is_resent_until_acknowledged() {
    let (mut peer, mut stream) = connect(65535, &[]).await;
    let shutdown = tokio::spawn(async move {
        stream.shutdown().await.unwrap();
        stream
    });
    let fin = peer.fin().await;
    peer.send(0, fin, Flags::default(), 65535, &[]); // a window update, not an ACK of the FIN
    let resent = peer.collect_until(Duration::from_secs(2), |s| s.fin).await;
    assert!(resent.iter().any(|(_, s)| s.fin && s.seq == fin), "FIN not resent: {resent:?}");
    peer.send(0, fin.wrapping_add(1), Flags::default(), 65535, &[]);
    peer.send(0, fin.wrapping_add(1), FIN, 65535, &[]);
    tokio::time::timeout(Duration::from_secs(4), shutdown)
        .await
        .expect("shutdown hung")
        .unwrap();
}

// LAST_ACK closed on any ACK, so a duplicate one ended the FIN retransmissions.
#[tokio::test(flavor = "multi_thread")]
async fn last_ack_waits_for_the_ack_of_our_fin() {
    let (mut peer, mut stream) = connect(65535, &[]).await;
    peer.send(0, peer.server_seq, FIN, 65535, &[]);
    let mut rest = Vec::new();
    tokio::time::timeout(Duration::from_secs(1), stream.read_to_end(&mut rest))
        .await
        .expect("read hung after FIN")
        .unwrap();
    let shutdown = tokio::spawn(async move {
        stream.shutdown().await.unwrap();
        stream
    });
    let fin = peer.fin().await;
    peer.send(1, fin, Flags::default(), 65535, &[]); // a duplicate ACK, not an ACK of the FIN
    let resent = peer.collect_until(Duration::from_secs(2), |s| s.fin).await;
    assert!(resent.iter().any(|(_, s)| s.fin && s.seq == fin), "FIN not resent: {resent:?}");
    peer.send(1, fin.wrapping_add(1), Flags::default(), 65535, &[]);
    tokio::time::timeout(Duration::from_secs(2), shutdown)
        .await
        .expect("shutdown hung")
        .unwrap();
}

// CLOSE_WAIT ignored a resent FIN, so a lost ACK left the client retransmitting it.
#[tokio::test(flavor = "multi_thread")]
async fn a_resent_client_fin_is_acknowledged_again() {
    let (mut peer, mut stream) = connect(65535, &[]).await;
    peer.send(0, peer.server_seq, FIN, 65535, &[]);
    let fin_ack = ISN + 1 + 1;
    let first = peer.collect_until(Duration::from_secs(1), |s| s.ack == fin_ack).await;
    assert!(first.iter().any(|(_, s)| s.ack == fin_ack), "FIN not acknowledged: {first:?}");
    peer.send(0, peer.server_seq, FIN, 65535, &[]);
    let again = peer.collect_until(Duration::from_millis(500), |s| s.ack == fin_ack).await;
    assert!(
        again.iter().any(|(_, s)| s.ack == fin_ack),
        "resent FIN not acknowledged: {again:?}"
    );
    let mut rest = Vec::new();
    stream.read_to_end(&mut rest).await.unwrap();
    let shutdown = tokio::spawn(async move {
        stream.shutdown().await.unwrap();
        stream
    });
    let fin = peer.fin().await;
    peer.send(1, fin.wrapping_add(1), Flags::default(), 65535, &[]);
    tokio::time::timeout(Duration::from_secs(2), shutdown)
        .await
        .expect("shutdown hung")
        .unwrap();
}

// A read returned one segment, so the proxy wrote each 1460-byte upload segment with its own system call.
#[tokio::test(flavor = "multi_thread")]
async fn one_read_takes_every_queued_segment_that_fits() {
    let (mut peer, mut stream) = connect(65535, &[]).await;
    for i in 0..5u32 {
        peer.send(i * 1000, peer.server_seq, Flags::default(), 65535, &[i as u8; 1000]);
    }
    peer.collect_until(Duration::from_secs(2), |s| s.ack == ISN + 1 + 5000).await;
    let mut buffer = vec![0u8; 8192];
    let n = stream.read(&mut buffer).await.unwrap();
    assert_eq!(n, 5000, "one read returned {n} of 5000 queued bytes");
    assert!((0..5).all(|i| buffer[i * 1000..(i + 1) * 1000].iter().all(|&b| b == i as u8)));
}

struct WaitingDevice {
    input: UnboundedReceiver<Vec<u8>>,
}

impl AsyncRead for WaitingDevice {
    fn poll_read(mut self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &mut ReadBuf<'_>) -> Poll<std::io::Result<()>> {
        match self.input.poll_recv(cx) {
            Poll::Ready(Some(packet)) => {
                buf.put_slice(&packet);
                Poll::Ready(Ok(()))
            }
            Poll::Ready(None) => Poll::Ready(Ok(())),
            Poll::Pending => Poll::Pending,
        }
    }
}

impl AsyncWrite for WaitingDevice {
    fn poll_write(self: Pin<&mut Self>, _: &mut Context<'_>, _: &[u8]) -> Poll<std::io::Result<usize>> {
        Poll::Pending
    }
    fn poll_flush(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Poll::Ready(Ok(()))
    }
    fn poll_shutdown(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Poll::Ready(Ok(()))
    }
}

// The stack wrote to the device inside its read loop, so a device waiting for room (the packet
// bridge's full output queue) also stopped it reading, and the bridge dropped incoming packets.
#[tokio::test(flavor = "multi_thread")]
async fn a_waiting_device_write_does_not_stop_reads() {
    let (input, device_input) = unbounded_channel();
    let mut config = IpStackConfig::default();
    config.mtu(1500).unwrap();
    let mut stack = IpStack::new(config, WaitingDevice { input: device_input });
    let mut streams = Vec::new();
    for port in [41000, 41001] {
        let mut syn = Vec::new();
        PacketBuilder::ipv4(CLIENT, SERVER, 64)
            .tcp(port, 443, ISN, 65535)
            .syn()
            .write(&mut syn, &[])
            .unwrap();
        input.send(syn).unwrap();
        match tokio::time::timeout(Duration::from_secs(2), stack.accept()).await {
            Ok(Ok(IpStackStream::Tcp(stream))) => streams.push(stream),
            _ => panic!("the SYN from port {port} was not read"),
        }
        tokio::time::sleep(Duration::from_millis(100)).await; // the SYN-ACK write is now waiting
    }
}
