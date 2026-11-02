use super::*;
use std::io::ErrorKind;
use std::pin::Pin;
use std::sync::atomic::AtomicUsize;
use std::task::{Context, Poll, Wake, Waker};
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};

fn packet(version: u8, payload: usize) -> Vec<u8> {
    let header = if version == 4 { 20 } else { 40 };
    let mut bytes = vec![0; header + payload];
    bytes[0] = if version == 4 { 0x45 } else { 0x60 };
    if version == 4 {
        bytes[2..4].copy_from_slice(&((header + payload) as u16).to_be_bytes());
    } else {
        bytes[4..6].copy_from_slice(&(payload as u16).to_be_bytes());
    }
    bytes[header..].fill(0xAB);
    bytes
}

#[test]
fn framing_waits_for_split_ipv4_and_ipv6_headers_and_payloads() {
    for version in [4, 6] {
        let bytes = packet(version, 13);
        for split in 0..bytes.len() {
            let mut frames = FrameAssembler::new(1280, 4);
            assert_eq!(frames.ingest(&bytes[..split]).unwrap(), split);
            assert!(frames.front().is_none(), "version {version}, split {split}");
            frames.ingest(&bytes[split..]).unwrap();
            assert_eq!(frames.pop(), Some(bytes.clone()));
            assert!(frames.pop().is_none());
        }
    }
}

#[test]
fn framing_preserves_coalesced_packets_and_an_incomplete_tail() {
    let first = packet(4, 3);
    let second = packet(6, 7);
    let third = packet(4, 1);
    let mut frames = FrameAssembler::new(1280, 3);
    frames
        .ingest(&[first.as_slice(), &second, &third[..3]].concat())
        .unwrap();
    assert_eq!(frames.pop(), Some(first));
    assert_eq!(frames.pop(), Some(second));
    assert!(frames.front().is_none());
    frames.ingest(&third[3..]).unwrap();
    assert_eq!(frames.pop(), Some(third));
}

#[test]
fn invalid_versions_lengths_and_truncated_frames_are_rejected() {
    let mut bad_header = packet(4, 0);
    bad_header[0] = 0x44;
    let mut short_length = packet(4, 0);
    short_length[3] = 19;
    let mut truncated_v6 = packet(6, 0);
    truncated_v6[5] = 1;
    for bytes in [
        vec![],
        vec![0x70],
        vec![0x45, 0, 0],
        bad_header,
        short_length,
        truncated_v6,
    ] {
        assert!(
            validate_packet(&bytes, 1280).is_err(),
            "invalid frame: {bytes:?}"
        );
    }
    for version in [4, 6] {
        let mut bytes = packet(version, 0);
        assert!(validate_packet(&bytes, 1280).is_ok());
        bytes.push(0);
        assert_eq!(
            validate_packet(&bytes, 1280).unwrap_err().kind(),
            ErrorKind::InvalidData
        );
    }
}

#[test]
fn packet_pending_buffer_limits_fail_and_a_full_queue_drops_without_losing_queued_packets() {
    let at_limit = packet(4, 12);
    let oversized = packet(4, 13);
    assert!(validate_packet(&at_limit, 32).is_ok());
    assert!(validate_packet(&oversized, 32).is_err());
    assert!(FrameAssembler::new(32, 1).ingest(&oversized).is_err());
    assert!(FrameAssembler::new(32, 1).ingest(&[0; 65]).is_err());

    // A burst beyond the queue is congestion: drop that packet, keep the tunnel.
    let mut frames = FrameAssembler::new(32, 1);
    frames.ingest(&at_limit).unwrap();
    assert_eq!(frames.ingest(&at_limit).unwrap(), at_limit.len());
    assert_eq!(frames.dropped(), 1);
    assert_eq!(frames.pop(), Some(at_limit.clone()));
    assert_eq!(frames.pop(), None);
    frames.ingest(&at_limit).unwrap();
    assert_eq!(frames.pop(), Some(at_limit));
}

#[derive(Default)]
struct WakeCounter(AtomicUsize);
impl Wake for WakeCounter {
    fn wake(self: Arc<Self>) {
        self.0.fetch_add(1, Ordering::SeqCst);
    }
}

#[test]
fn device_wakes_on_input_preserves_partial_reads_and_reports_eof() {
    let (sender, receiver) = mpsc::channel(1);
    let output = Arc::new(Mutex::new(FrameAssembler::new(1280, 2)));
    let mut device = PacketDevice::new(receiver, output, Arc::default());
    let counter = Arc::new(WakeCounter::default());
    let waker = Waker::from(counter.clone());
    let mut context = Context::from_waker(&waker);
    let mut storage = [0; 3];
    let mut buffer = ReadBuf::new(&mut storage);
    assert!(
        Pin::new(&mut device)
            .poll_read(&mut context, &mut buffer)
            .is_pending()
    );
    sender.try_send(vec![1, 2, 3, 4, 5]).unwrap();
    assert!(counter.0.load(Ordering::SeqCst) > 0);
    assert!(matches!(
        Pin::new(&mut device).poll_read(&mut context, &mut buffer),
        Poll::Ready(Ok(()))
    ));
    assert_eq!(buffer.filled(), [1, 2, 3]);
    buffer.clear();
    assert!(matches!(
        Pin::new(&mut device).poll_read(&mut context, &mut buffer),
        Poll::Ready(Ok(()))
    ));
    assert_eq!(buffer.filled(), [4, 5]);
    drop(sender);
    buffer.clear();
    assert!(matches!(
        Pin::new(&mut device).poll_read(&mut context, &mut buffer),
        Poll::Ready(Ok(()))
    ));
    assert!(buffer.filled().is_empty());
}

struct CountingWaker(AtomicUsize);

impl Wake for CountingWaker {
    fn wake(self: Arc<Self>) {
        self.0.fetch_add(1, Ordering::SeqCst);
    }
}

// A full output queue dropped the stack's packets; 64 parallel downloads lost thousands and
// their synchronized retransmissions overflowed it again until the connections reset.
#[test]
fn device_waits_for_room_instead_of_dropping_and_propagates_framing_errors() {
    let (_sender, receiver) = mpsc::channel(1);
    let output = Arc::new(Mutex::new(FrameAssembler::new(1280, 1)));
    let mut device = PacketDevice::new(receiver, output.clone(), Arc::default());
    let wakes = Arc::new(CountingWaker(AtomicUsize::new(0)));
    let waker = Waker::from(wakes.clone());
    let mut context = Context::from_waker(&waker);
    let first = packet(6, 2);
    let second = packet(4, 3);
    assert!(
        matches!(Pin::new(&mut device).poll_write(&mut context, &first), Poll::Ready(Ok(n)) if n == first.len())
    );
    assert!(
        Pin::new(&mut device)
            .poll_write(&mut context, &second)
            .is_pending()
    );
    assert_eq!(wakes.0.load(Ordering::SeqCst), 0);
    assert_eq!(output.lock().unwrap().pop(), Some(first));
    assert_eq!(
        wakes.0.load(Ordering::SeqCst),
        1,
        "receiving made room but left the writer asleep"
    );
    assert!(
        matches!(Pin::new(&mut device).poll_write(&mut context, &second), Poll::Ready(Ok(n)) if n == second.len())
    );
    assert_eq!(output.lock().unwrap().pop(), Some(second));
    assert_eq!(output.lock().unwrap().dropped(), 0);

    let (_sender, receiver) = mpsc::channel(1);
    let mut device = PacketDevice::new(
        receiver,
        Arc::new(Mutex::new(FrameAssembler::new(1280, 1))),
        Arc::default(),
    );
    assert!(
        matches!(Pin::new(&mut device).poll_write(&mut context, &[0x70]), Poll::Ready(Err(e)) if e.kind() == ErrorKind::InvalidData)
    );
}

#[test]
fn ingress_overflow_drops_the_packet_and_keeps_the_bridge_running() {
    // Hold the receiver instead of starting a native worker: capacity is deterministic.
    let (input, mut receiver) = mpsc::channel(1);
    let mut bridge = ElarniPacketBridge {
        input,
        output: Arc::new(Mutex::new(FrameAssembler::new(1280, 1))),
        output_ready: Arc::default(),
        cancellation: CancellationToken::new(),
        state: Arc::new(AtomicU8::new(ElarniPacketState::Running as u8)),
        counters: Arc::new(Counters::default()),
        thread: Mutex::new(None),
        max_packet_bytes: 1280,
        virtual_dns_metrics: Arc::new(VirtualDnsMetrics::default()),
        session_metrics: Arc::new(tun2proxy::SessionMetrics::default()),
    };
    let bytes = packet(6, 8);
    // Live stack-owned bridge and packet remain valid for each exported call.
    unsafe {
        assert_eq!(
            elarni_packet_bridge_submit(&mut bridge, bytes.as_ptr(), bytes.len()),
            ElarniPacketStatus::Ok
        );
        assert_eq!(
            elarni_packet_bridge_submit(&mut bridge, bytes.as_ptr(), bytes.len()),
            ElarniPacketStatus::QueueOverflow
        );
        assert_eq!(
            elarni_packet_bridge_state(&bridge),
            ElarniPacketState::Running
        );
        assert!(!bridge.cancellation.is_cancelled());
        assert_eq!(receiver.try_recv().unwrap(), bytes);
        assert!(receiver.try_recv().is_err());
        assert_eq!(
            elarni_packet_bridge_submit(&mut bridge, bytes.as_ptr(), bytes.len()),
            ElarniPacketStatus::Ok
        );
        assert_eq!(receiver.try_recv().unwrap(), bytes);
        bridge.output.lock().unwrap().ingest(&bytes).unwrap();
        bridge.output.lock().unwrap().ingest(&bytes).unwrap();
        let mut counters = ElarniPacketCounters::default();
        assert_eq!(
            elarni_packet_bridge_counters(&bridge, &mut counters),
            ElarniPacketStatus::Ok
        );
        // One ingress and one egress drop.
        assert_eq!((counters.packets_in, counters.overflows), (2, 2));
    }
}

#[test]
fn stop_joins_worker_even_after_it_publishes_stopped() {
    let (input, _receiver) = mpsc::channel(1);
    let (release, wait) = std::sync::mpsc::channel();
    let worker = thread::spawn(move || wait.recv().unwrap());
    let mut bridge = ElarniPacketBridge {
        input,
        output: Arc::new(Mutex::new(FrameAssembler::new(1280, 1))),
        output_ready: Arc::default(),
        cancellation: CancellationToken::new(),
        state: Arc::new(AtomicU8::new(ElarniPacketState::Stopped as u8)),
        counters: Arc::new(Counters::default()),
        thread: Mutex::new(Some(worker)),
        max_packet_bytes: 1280,
        virtual_dns_metrics: Arc::new(VirtualDnsMetrics::default()),
        session_metrics: Arc::new(tun2proxy::SessionMetrics::default()),
    };
    let finish = thread::spawn(move || {
        thread::sleep(Duration::from_millis(20));
        release.send(()).unwrap();
    });
    let status = unsafe { elarni_packet_bridge_stop(&mut bridge) };
    finish.join().unwrap();
    assert_eq!(status, ElarniPacketStatus::Ok);
    assert!(
        bridge.thread.lock().unwrap().is_none(),
        "stop left its worker unjoined"
    );
}

#[test]
fn worker_shutdown_preserves_latched_failure() {
    let bridge = elarni_packet_bridge_new(10809, 1500, 1, 1, 1, 1500);
    assert!(!bridge.is_null());
    unsafe {
        let deadline = Instant::now() + Duration::from_secs(2);
        while elarni_packet_bridge_state(bridge) == ElarniPacketState::Starting
            && Instant::now() < deadline
        {
            thread::sleep(Duration::from_millis(1));
        }
        assert_eq!(
            elarni_packet_bridge_state(bridge),
            ElarniPacketState::Running
        );
        // Model the failure latched by submit before cancelling a live worker.
        (*bridge)
            .state
            .store(ElarniPacketState::Failed as u8, Ordering::Release);
        (*bridge).cancellation.cancel();
        let status = elarni_packet_bridge_stop(bridge);
        let state = elarni_packet_bridge_state(bridge);
        elarni_packet_bridge_free(bridge);
        assert_eq!(status, ElarniPacketStatus::Ok);
        assert_eq!(state, ElarniPacketState::Failed);
    }
}

fn started_bridge(port: u16) -> *mut ElarniPacketBridge {
    let bridge = elarni_packet_bridge_new(port, 1500, 4, 4, 8, 1500);
    assert!(!bridge.is_null());
    let deadline = Instant::now() + Duration::from_secs(5);
    while unsafe { elarni_packet_bridge_state(bridge) } == ElarniPacketState::Starting
        && Instant::now() < deadline
    {
        thread::sleep(Duration::from_millis(1));
    }
    bridge
}

fn wait_in_thread(bridge: *mut ElarniPacketBridge) -> JoinHandle<(ElarniPacketStatus, Duration)> {
    // Raw pointers are not Send; the bridge outlives the thread that waits on it.
    let address = bridge as usize;
    thread::spawn(move || {
        let started = Instant::now();
        let status =
            unsafe { elarni_packet_bridge_wait(address as *const ElarniPacketBridge, 10_000) };
        (status, started.elapsed())
    })
}

// A caller waiting for output sleeps until the stack has a packet for it, instead of polling
// receive, and a stop wakes it.
#[test]
fn wait_sleeps_until_output_arrives_or_the_bridge_stops() {
    // The kernel completes the SOCKS connection from the backlog; the stack answers the SYN itself.
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let bridge = started_bridge(listener.local_addr().unwrap().port());
    unsafe {
        let started = Instant::now();
        assert_eq!(
            elarni_packet_bridge_wait(bridge, 50),
            ElarniPacketStatus::Empty
        );
        assert!(started.elapsed() >= Duration::from_millis(50));
        let waiting = wait_in_thread(bridge);
        thread::sleep(Duration::from_millis(20));
        let syn = tcp_syn([10, 0, 0, 2], [192, 0, 2, 10], 40_000, 80);
        assert_eq!(
            elarni_packet_bridge_submit(bridge, syn.as_ptr(), syn.len()),
            ElarniPacketStatus::Ok
        );
        let (status, waited) = waiting.join().unwrap();
        assert_eq!(status, ElarniPacketStatus::Ok);
        assert!(
            waited < Duration::from_secs(5),
            "the waiter slept through the reply"
        );
        // A queued packet answers at once and stays queued for receive.
        assert_eq!(
            elarni_packet_bridge_wait(bridge, 10_000),
            ElarniPacketStatus::Ok
        );
        let mut written = 0;
        assert_eq!(
            elarni_packet_bridge_receive(bridge, ptr::null_mut(), 0, &mut written),
            ElarniPacketStatus::BufferTooSmall
        );
        elarni_packet_bridge_free(bridge);
    }

    let bridge = started_bridge(listener.local_addr().unwrap().port());
    let waiting = wait_in_thread(bridge);
    thread::sleep(Duration::from_millis(20));
    unsafe {
        assert_eq!(elarni_packet_bridge_stop(bridge), ElarniPacketStatus::Ok);
        let (status, waited) = waiting.join().unwrap();
        assert_eq!(status, ElarniPacketStatus::Stopped);
        assert!(
            waited < Duration::from_secs(5),
            "stop did not wake the waiter"
        );
        assert_eq!(
            elarni_packet_bridge_wait(bridge, 10_000),
            ElarniPacketStatus::Stopped
        );
        elarni_packet_bridge_free(bridge);
    }
}

fn checksum(parts: &[&[u8]]) -> [u8; 2] {
    let mut sum = 0u32;
    for pair in parts.concat().chunks(2) {
        sum += u32::from(u16::from_be_bytes([pair[0], *pair.get(1).unwrap_or(&0)]));
    }
    while sum > 0xFFFF {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }
    (!(sum as u16)).to_be_bytes()
}

fn tcp_syn(source: [u8; 4], destination: [u8; 4], source_port: u16, port: u16) -> Vec<u8> {
    let mut tcp = vec![0; 20];
    tcp[0..2].copy_from_slice(&source_port.to_be_bytes());
    tcp[2..4].copy_from_slice(&port.to_be_bytes());
    tcp[4..8].copy_from_slice(&1u32.to_be_bytes());
    tcp[12] = 5 << 4;
    tcp[13] = 0x02;
    tcp[14..16].copy_from_slice(&65_535u16.to_be_bytes());
    let pseudo = [&source[..], &destination[..], &[0, 6, 0, 20]].concat();
    let sum = checksum(&[&pseudo, &tcp]);
    tcp[16..18].copy_from_slice(&sum);
    let mut ip = vec![0x45, 0, 0, 40, 0, 1, 0x40, 0, 64, 6, 0, 0];
    ip.extend_from_slice(&source);
    ip.extend_from_slice(&destination);
    let sum = checksum(&[&ip]);
    ip[10..12].copy_from_slice(&sum);
    [ip, tcp].concat()
}

#[test]
fn authenticated_bridge_rejects_unusable_credentials() {
    let long = [b'a'; 256];
    for (user, pass) in [
        (&b""[..], &b"pass"[..]),
        (&b"user"[..], &b""[..]),
        (&long[..], &b"pass"[..]),
        (&b"user"[..], &[0xFF, 0xFE][..]),
    ] {
        let bridge = unsafe {
            elarni_packet_bridge_new_authenticated(
                10809,
                1500,
                1,
                1,
                1,
                1500,
                user.as_ptr(),
                user.len(),
                pass.as_ptr(),
                pass.len(),
            )
        };
        assert!(bridge.is_null(), "accepted {user:?}/{pass:?}");
    }
    let bridge = unsafe {
        elarni_packet_bridge_new_authenticated(
            10809,
            1500,
            1,
            1,
            1,
            1500,
            ptr::null(),
            4,
            b"pass".as_ptr(),
            4,
        )
    };
    assert!(bridge.is_null(), "accepted a null username");
}

// The login reaches the SOCKS server byte for byte, including URL-reserved characters,
// and the stack's reply leaves through receive.
#[test]
fn authenticated_bridge_logs_in_and_returns_the_reply() {
    use std::io::{Read, Write};
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        let mut header = [0; 2];
        stream.read_exact(&mut header).unwrap();
        let mut methods = vec![0; usize::from(header[1])];
        stream.read_exact(&mut methods).unwrap();
        assert_eq!(header[0], 5);
        assert!(methods.contains(&2), "client did not offer a login");
        stream.write_all(&[5, 2]).unwrap();
        let field = |stream: &mut std::net::TcpStream| {
            let mut length = [0; 1];
            stream.read_exact(&mut length).unwrap();
            let mut value = vec![0; usize::from(length[0])];
            stream.read_exact(&mut value).unwrap();
            value
        };
        let mut version = [0; 1];
        stream.read_exact(&mut version).unwrap();
        (field(&mut stream), field(&mut stream))
    });
    let (user, pass) = ("us:er@%/".as_bytes(), "p@ss:w%rd \u{fc}".as_bytes());
    let bridge = unsafe {
        elarni_packet_bridge_new_authenticated(
            port,
            1500,
            4,
            4,
            8,
            1500,
            user.as_ptr(),
            user.len(),
            pass.as_ptr(),
            pass.len(),
        )
    };
    assert!(!bridge.is_null());
    unsafe {
        let deadline = Instant::now() + Duration::from_secs(5);
        while elarni_packet_bridge_state(bridge) == ElarniPacketState::Starting
            && Instant::now() < deadline
        {
            thread::sleep(Duration::from_millis(1));
        }
        let syn = tcp_syn([10, 0, 0, 2], [192, 0, 2, 10], 40_000, 80);
        assert_eq!(
            elarni_packet_bridge_submit(bridge, syn.as_ptr(), syn.len()),
            ElarniPacketStatus::Ok
        );
        let mut written = 0;
        let mut status = ElarniPacketStatus::Empty;
        while status == ElarniPacketStatus::Empty && Instant::now() < deadline {
            status = elarni_packet_bridge_receive(bridge, ptr::null_mut(), 0, &mut written);
            thread::sleep(Duration::from_millis(1));
        }
        assert_eq!(status, ElarniPacketStatus::BufferTooSmall);
        let mut reply = vec![0; written];
        let status =
            elarni_packet_bridge_receive(bridge, reply.as_mut_ptr(), reply.len(), &mut written);
        let mut counters = ElarniPacketCounters::default();
        elarni_packet_bridge_counters(bridge, &mut counters);
        let login = server.join().unwrap();
        elarni_packet_bridge_stop(bridge);
        elarni_packet_bridge_free(bridge);
        assert_eq!(status, ElarniPacketStatus::Ok);
        assert_eq!((written, counters.packets_out), (reply.len(), 1));
        assert_eq!(&reply[16..20], &[10, 0, 0, 2]);
        assert_eq!(&reply[22..24], &40_000u16.to_be_bytes());
        assert_eq!(reply[33] & 0x12, 0x12, "reply is not a SYN-ACK");
        assert_eq!(login, (user.to_vec(), pass.to_vec()));
    }
}

fn udp_datagram(source: [u8; 4], destination: [u8; 4], source_port: u16, port: u16) -> Vec<u8> {
    let payload = b"elarni";
    let length = (8 + payload.len()) as u16;
    let mut udp = [
        &source_port.to_be_bytes()[..],
        &port.to_be_bytes(),
        &length.to_be_bytes(),
        &[0, 0],
        payload,
    ]
    .concat();
    let pseudo = [
        &source[..],
        &destination[..],
        &[0, 17],
        &length.to_be_bytes(),
    ]
    .concat();
    let sum = checksum(&[&pseudo, &udp]);
    udp[6..8].copy_from_slice(&sum);
    let mut ip = vec![0x45, 0, 0, 0, 0, 1, 0x40, 0, 64, 17, 0, 0];
    ip[2..4].copy_from_slice(&(20 + length).to_be_bytes());
    ip.extend_from_slice(&source);
    ip.extend_from_slice(&destination);
    let sum = checksum(&[&ip]);
    ip[10..12].copy_from_slice(&sum);
    [ip, udp].concat()
}

// A session over the limit is dropped; the counters say so instead of only a log line.
#[test]
fn sessions_refused_at_the_limit_are_counted() {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let (release, wait) = std::sync::mpsc::channel::<()>();
    // Hold the first session's SOCKS connection without answering, so it stays active.
    let server = thread::spawn(move || {
        let held = listener.accept();
        let _ = wait.recv_timeout(Duration::from_secs(10));
        drop(held);
    });
    let bridge = elarni_packet_bridge_new(port, 1500, 1, 1, 8, 1500);
    assert!(!bridge.is_null());
    let mut counters = ElarniPacketCounters::default();
    unsafe {
        let deadline = Instant::now() + Duration::from_secs(5);
        while elarni_packet_bridge_state(bridge) == ElarniPacketState::Starting
            && Instant::now() < deadline
        {
            thread::sleep(Duration::from_millis(1));
        }
        for source_port in [40_000, 40_001] {
            let datagram = udp_datagram([10, 0, 0, 2], [192, 0, 2, 10], source_port, 443);
            assert_eq!(
                elarni_packet_bridge_submit(bridge, datagram.as_ptr(), datagram.len()),
                ElarniPacketStatus::Ok
            );
        }
        while counters.dropped_udp_sessions == 0 && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(5));
            elarni_packet_bridge_counters(bridge, &mut counters);
        }
        elarni_packet_bridge_free(bridge);
    }
    release.send(()).unwrap();
    server.join().unwrap();
    assert_eq!(
        (
            counters.active_udp_sessions,
            counters.dropped_udp_sessions,
            counters.dropped_tcp_sessions
        ),
        (1, 1, 0)
    );
}

// Collects the stack's IPv4 output until one UDP datagram is complete and returns its payload.
fn receive_udp_payload(bridge: *mut ElarniPacketBridge, timeout: Duration) -> Option<Vec<u8>> {
    let deadline = Instant::now() + timeout;
    let (mut packet, mut datagram) = (vec![0; 65_535], vec![0; 65_535]);
    let (mut received, mut total) = (0, None);
    while Instant::now() < deadline {
        let mut written = 0;
        let status = unsafe {
            elarni_packet_bridge_receive(bridge, packet.as_mut_ptr(), packet.len(), &mut written)
        };
        if status != ElarniPacketStatus::Ok || packet[9] != 17 {
            thread::sleep(Duration::from_millis(1));
            continue;
        }
        let header = usize::from(packet[0] & 15) * 4;
        let flags = u16::from_be_bytes([packet[6], packet[7]]);
        let offset = usize::from(flags & 0x1fff) * 8;
        let fragment = &packet[header..written];
        datagram[offset..offset + fragment.len()].copy_from_slice(fragment);
        received += fragment.len();
        if flags & 0x2000 == 0 {
            total = Some(offset + fragment.len());
        }
        if total == Some(received) {
            return Some(datagram[8..received].to_vec());
        }
    }
    None
}

// A relay reply is one datagram of up to 64 KiB. It must come back whole, neither lost
// (Windows) nor truncated (Unix), and the session must survive it.
#[test]
fn large_udp_relay_replies_arrive_whole() {
    use std::io::{Read, Write};
    const SIZES: [usize; 3] = [30_000, 30_000, 65_000];
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let answered = Arc::new(AtomicUsize::new(0));
    thread::spawn(move || {
        for control in listener.incoming() {
            let (mut control, answered) = (control.unwrap(), answered.clone());
            thread::spawn(move || -> std::io::Result<()> {
                let mut header = [0; 2];
                control.read_exact(&mut header)?;
                control.read_exact(&mut vec![0; usize::from(header[1])])?;
                control.write_all(&[5, 0])?;
                let mut request = [0; 4];
                control.read_exact(&mut request)?;
                let address = if request[3] == 4 { 16 } else { 4 };
                control.read_exact(&mut vec![0; address + 2])?;
                let relay = std::net::UdpSocket::bind("127.0.0.1:0")?;
                // macOS refuses a datagram larger than the send buffer (9216 bytes by default).
                socket2::SockRef::from(&relay).set_send_buffer_size(1 << 20)?;
                relay.set_read_timeout(Some(Duration::from_secs(30)))?;
                let relay_port = relay.local_addr()?.port().to_be_bytes();
                control.write_all(&[5, 0, 0, 1, 127, 0, 0, 1, relay_port[0], relay_port[1]])?;
                thread::spawn(move || {
                    let mut buffer = vec![0; 65_535];
                    while let Ok((_, client)) = relay.recv_from(&mut buffer) {
                        // The request's IPv4 SOCKS header is 10 bytes; the reply repeats it.
                        let size =
                            SIZES[answered.fetch_add(1, Ordering::SeqCst).min(SIZES.len() - 1)];
                        let reply: Vec<u8> = buffer[..10]
                            .iter()
                            .copied()
                            .chain((0..size).map(|index| (index % 251) as u8))
                            .collect();
                        relay.send_to(&reply, client).unwrap();
                    }
                });
                // The association lasts until the bridge closes its control connection.
                std::io::copy(&mut control, &mut std::io::sink())?;
                Ok(())
            });
        }
    });
    let bridge = elarni_packet_bridge_new(port, 1500, 4, 4, 256, 65_535);
    assert!(!bridge.is_null());
    let mut replies = Vec::new();
    unsafe {
        let deadline = Instant::now() + Duration::from_secs(5);
        while elarni_packet_bridge_state(bridge) == ElarniPacketState::Starting
            && Instant::now() < deadline
        {
            thread::sleep(Duration::from_millis(1));
        }
        let datagram = udp_datagram([10, 0, 0, 2], [192, 0, 2, 10], 40_000, 443);
        for _ in SIZES {
            assert_eq!(
                elarni_packet_bridge_submit(bridge, datagram.as_ptr(), datagram.len()),
                ElarniPacketStatus::Ok
            );
            replies.push(receive_udp_payload(bridge, Duration::from_secs(5)).unwrap_or_default());
        }
        elarni_packet_bridge_free(bridge);
    }
    for (reply, size) in replies.iter().zip(SIZES) {
        assert!(
            reply.len() == size
                && reply
                    .iter()
                    .enumerate()
                    .all(|(index, byte)| *byte == (index % 251) as u8),
            "a {size}-byte reply arrived as {} bytes",
            reply.len()
        );
    }
}
