use super::seqnum::SeqNum;
use crate::{
    PacketReceiver, PacketSender, TTL,
    error::IpStackError,
    packet::{
        IpHeader, NetworkPacket, NetworkTuple, TransportHeader,
        tcp_flags::{ACK, FIN, PSH, RST, SYN},
        tcp_header_flags, tcp_header_fmt,
    },
    stream::tcb::{MAX_COUNT_FOR_DUP_ACK, MAX_RETRANSMIT_COUNT, MAX_UNACK, PacketType, READ_BUFFER_SIZE, RTO, Tcb, TcpState},
};
use etherparse::{IpNumber, Ipv4Header, Ipv6FlowLabel, TcpHeader, TcpOptionElement};
use std::{
    future::Future,
    io::ErrorKind::{BrokenPipe, ConnectionRefused, InvalidInput, UnexpectedEof},
    net::SocketAddr,
    pin::Pin,
    sync::Arc,
    task::{Context, Poll, Waker},
    time::Duration,
};
use tokio::io::{AsyncRead, AsyncWrite};

/// 2 * MSL (Maximum Segment Lifetime) is the maximum time a TCP connection can be in the TIME_WAIT state.
const TWO_MSL: Duration = Duration::from_secs(2);

const CLOSE_WAIT_TIMEOUT: Duration = Duration::from_secs(5);
const LAST_ACK_MAX_RETRIES: usize = 3;
const LAST_ACK_TIMEOUT: Duration = Duration::from_millis(500);
const TIMEOUT: Duration = Duration::from_secs(60);

#[non_exhaustive]
#[derive(Debug, Clone)]
/// TCP configuration
pub struct TcpConfig {
    /// Maximum number of retries for sending the last ACK in the LAST_ACK state. Default is 3.
    pub last_ack_max_retries: usize,
    /// Timeout for the last ACK in the LAST_ACK state. Default is 500ms.
    pub last_ack_timeout: Duration,
    /// Timeout for the CLOSE_WAIT state. Default is 5 seconds.
    pub close_wait_timeout: Duration,
    /// Timeout for TCP connections. Default is 60 seconds.
    pub timeout: Duration,
    /// Timeout for the TIME_WAIT state. Default is 2 seconds.
    pub two_msl: Duration,
    /// Maximum number of unacknowledged bytes allowed in the send buffer.
    pub max_unacked_bytes: u32,
    /// Size of the read buffer for incoming data.
    pub read_buffer_size: usize,
    /// Maximum number of duplicate ACKs before triggering fast retransmission.
    pub max_count_for_dup_ack: usize,
    /// Retransmission timeout duration.
    pub rto: std::time::Duration,
    /// Maximum number of retransmissions before giving up.
    pub max_retransmit_count: usize,
    /// TCP options
    pub options: Option<Vec<TcpOptions>>,
}

#[non_exhaustive]
#[derive(Debug, Clone)]
pub enum TcpOptions {
    /// Maximum segment size (MSS) for TCP connections.
    MaximumSegmentSize(u16),
}

impl Default for TcpConfig {
    fn default() -> Self {
        TcpConfig {
            last_ack_max_retries: LAST_ACK_MAX_RETRIES,
            last_ack_timeout: LAST_ACK_TIMEOUT,
            close_wait_timeout: CLOSE_WAIT_TIMEOUT,
            timeout: TIMEOUT,
            two_msl: TWO_MSL,
            max_unacked_bytes: MAX_UNACK,
            read_buffer_size: READ_BUFFER_SIZE,
            max_count_for_dup_ack: MAX_COUNT_FOR_DUP_ACK,
            rto: RTO,
            max_retransmit_count: MAX_RETRANSMIT_COUNT,
            options: Default::default(),
        }
    }
}

#[derive(Debug)]
enum Shutdown {
    None,
    Pending(Waker),
    Ready,
}

impl Shutdown {
    fn pending(&mut self, w: Waker) {
        *self = Shutdown::Pending(w);
    }
    fn ready(&mut self) {
        if let Shutdown::Pending(w) = self {
            w.wake_by_ref();
        }
        *self = Shutdown::Ready;
    }
}

impl std::fmt::Display for Shutdown {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Shutdown::None => write!(f, "None"),
            Shutdown::Pending(_) => write!(f, "Pending"),
            Shutdown::Ready => write!(f, "Ready"),
        }
    }
}

static SESSION_COUNTER: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

type TcbPtr = std::sync::Arc<std::sync::Mutex<Tcb>>;

/// A TCP stream in the IP stack.
///
/// This type represents a TCP connection and implements `AsyncRead` and `AsyncWrite`
/// for bidirectional data transfer. It handles TCP state management, flow control,
/// and retransmission automatically.
///
/// # Examples
///
/// ```no_run
/// use ipstack::{IpStack, IpStackConfig, IpStackStream};
/// use tokio::io::{AsyncReadExt, AsyncWriteExt};
///
/// # async fn example(mut ip_stack: IpStack) -> Result<(), Box<dyn std::error::Error>> {
/// if let IpStackStream::Tcp(mut tcp_stream) = ip_stack.accept().await? {
///     println!("New TCP connection from {}", tcp_stream.peer_addr());
///     
///     // Read data
///     let mut buffer = [0u8; 1024];
///     let n = tcp_stream.read(&mut buffer).await?;
///     
///     // Write data
///     tcp_stream.write_all(b"HTTP/1.1 200 OK\r\n\r\n").await?;
///     
///     // Shutdown the stream
///     tcp_stream.shutdown().await?;
/// }
/// # Ok(())
/// # }
/// ```
#[derive(Debug)]
pub struct IpStackTcpStream {
    src_addr: SocketAddr,
    dst_addr: SocketAddr,
    stream_sender: PacketSender,
    stream_receiver: Option<PacketReceiver>,
    up_packet_sender: PacketSender,
    tcb: TcbPtr,
    shutdown: std::sync::Arc<std::sync::Mutex<Shutdown>>,
    write_notify: std::sync::Arc<std::sync::Mutex<Option<Waker>>>,
    destroy_messenger: Option<::tokio::sync::oneshot::Sender<()>>,
    timeout: Pin<Box<tokio::time::Sleep>>,
    data_tx: tokio::sync::mpsc::UnboundedSender<Vec<u8>>,
    data_rx: tokio::sync::mpsc::UnboundedReceiver<Vec<u8>>,
    read_notify: std::sync::Arc<std::sync::Mutex<Option<Waker>>>,
    task_handle: Option<tokio::task::JoinHandle<std::io::Result<()>>>,
    exit_notifier: Option<tokio::sync::mpsc::Sender<()>>,
    temp_read_buffer: Vec<u8>,
    config: Arc<TcpConfig>,
}

impl IpStackTcpStream {
    pub(crate) fn new(
        src_addr: SocketAddr,
        dst_addr: SocketAddr,
        tcp: TcpHeader,
        up_packet_sender: PacketSender,
        mtu: u16,
        destroy_messenger: Option<::tokio::sync::oneshot::Sender<()>>,
        config: Arc<TcpConfig>,
    ) -> Result<IpStackTcpStream, IpStackError> {
        let mut tcb = Tcb::new(
            SeqNum(tcp.sequence_number),
            mtu,
            config.max_unacked_bytes,
            config.read_buffer_size,
            config.max_count_for_dup_ack,
            config.rto,
            config.max_retransmit_count,
        );
        for option in tcp.options_iterator() {
            if let Ok(TcpOptionElement::MaximumSegmentSize(mss)) = option {
                tcb.set_peer_mss(mss);
            }
        }
        let tuple = NetworkTuple::new(src_addr, dst_addr, true);
        if !tcp.syn {
            if !tcp.rst
                && let Err(err) = write_packet_to_device(&up_packet_sender, tuple, &tcb, None, ACK | RST, None, None)
            {
                log::warn!("Error sending RST/ACK packet: {err}");
            }
            let info = format!("Invalid TCP packet: {tuple} {}", tcp_header_fmt(&tcp));
            return Err(IpStackError::IoError(std::io::Error::new(ConnectionRefused, info)));
        }

        let (stream_sender, stream_receiver) = tokio::sync::mpsc::unbounded_channel::<NetworkPacket>();
        let (data_tx, data_rx) = tokio::sync::mpsc::unbounded_channel::<Vec<u8>>();
        let deadline = tokio::time::Instant::now() + config.timeout;

        let mut stream = IpStackTcpStream {
            src_addr,
            dst_addr,
            stream_sender,
            stream_receiver: Some(stream_receiver),
            up_packet_sender,
            tcb: std::sync::Arc::new(std::sync::Mutex::new(tcb.clone())),
            shutdown: std::sync::Arc::new(std::sync::Mutex::new(Shutdown::None)),
            write_notify: std::sync::Arc::new(std::sync::Mutex::new(None)),
            destroy_messenger,
            timeout: Box::pin(tokio::time::sleep_until(deadline)),
            data_tx,
            data_rx,
            read_notify: std::sync::Arc::new(std::sync::Mutex::new(None)),
            task_handle: None,
            exit_notifier: None,
            temp_read_buffer: Vec::new(),
            config,
        };

        let sessions = SESSION_COUNTER.fetch_add(1, std::sync::atomic::Ordering::SeqCst).saturating_add(1);
        let (seq, ack, state) = { (tcb.get_seq().0, tcb.get_ack().0, tcb.get_state()) };
        let l_info = format!("local {{ seq: {seq}, ack: {ack} }}");
        log::debug!("{tuple} {state:?}: {l_info} session begins, total TCP sessions: {sessions}");

        stream.spawn_tasks()?;
        Ok(stream)
    }

    fn reset_timeout(&mut self) {
        let deadline = tokio::time::Instant::now() + self.config.timeout;
        self.timeout.as_mut().reset(deadline);
    }

    pub(crate) fn network_tuple(&self) -> NetworkTuple {
        NetworkTuple::new(self.src_addr, self.dst_addr, true)
    }

    /// Returns the local socket address of the TCP connection.
    ///
    /// # Examples
    ///
    /// ```no_run
    /// # use ipstack::IpStackTcpStream;
    /// # fn example(tcp_stream: &IpStackTcpStream) {
    /// let local_addr = tcp_stream.local_addr();
    /// println!("Local address: {}", local_addr);
    /// # }
    /// ```
    pub fn local_addr(&self) -> SocketAddr {
        self.src_addr
    }

    /// Returns the remote socket address of the TCP connection.
    ///
    /// # Examples
    ///
    /// ```no_run
    /// # use ipstack::IpStackTcpStream;
    /// # fn example(tcp_stream: &IpStackTcpStream) {
    /// let peer_addr = tcp_stream.peer_addr();
    /// println!("Peer address: {}", peer_addr);
    /// # }
    /// ```
    pub fn peer_addr(&self) -> SocketAddr {
        self.dst_addr
    }

    pub fn stream_sender(&self) -> PacketSender {
        self.stream_sender.clone()
    }
}

impl AsyncRead for IpStackTcpStream {
    fn poll_read(mut self: std::pin::Pin<&mut Self>, cx: &mut Context<'_>, buf: &mut tokio::io::ReadBuf<'_>) -> Poll<std::io::Result<()>> {
        let network_tuple = self.network_tuple();

        if self.temp_read_buffer.is_empty() {
            // Register before reading the state, which the task changes before it wakes the reader.
            self.read_notify.lock().unwrap().replace(cx.waker().clone());
            // The task queues every byte before it records the FIN, so a FIN state seen here means the queue is complete.
            let state = self.tcb.lock().unwrap().get_state();
            if state == TcpState::Closed {
                self.shutdown.lock().unwrap().ready();
                self.write_notify.lock().unwrap().take().map(|w| w.wake_by_ref()).unwrap_or(());
                match self.data_rx.try_recv() {
                    Ok(data) => self.temp_read_buffer = data,
                    Err(_) => return Poll::Ready(Ok(())),
                }
            } else {
                // handle timeout
                if matches!(Pin::new(&mut self.timeout).poll(cx), Poll::Ready(_)) {
                    {
                        let mut tcb = self.tcb.lock().unwrap();
                        let (seq, ack) = (tcb.get_seq().0, tcb.get_ack().0);
                        let l_info = format!("local {{ seq: {seq}, ack: {ack} }}");
                        log::warn!("{network_tuple} {state:?}: [poll_read] {l_info}, session timeout reached, closing forcefully...");
                        let sender = &self.up_packet_sender;
                        write_packet_to_device(sender, network_tuple, &tcb, None, ACK | RST, None, None)?;
                        tcb.change_state(TcpState::Closed);
                        let state = tcb.get_state();
                        log::warn!("{network_tuple} {state:?}: [poll_read] {l_info}, session notified to close");
                    }
                    self.shutdown.lock().unwrap().ready();

                    return Poll::Ready(Err(std::io::Error::from(std::io::ErrorKind::TimedOut)));
                }
                self.reset_timeout();

                // read data from channel
                match self.data_rx.poll_recv(cx) {
                    Poll::Ready(Some(data)) => self.temp_read_buffer = data,
                    Poll::Ready(None) => return Poll::Ready(Ok(())),
                    // The peer sent FIN and everything before it was read.
                    Poll::Pending if matches!(state, TcpState::CloseWait | TcpState::LastAck | TcpState::TimeWait) => {
                        return Poll::Ready(Ok(()));
                    }
                    Poll::Pending => return Poll::Pending,
                }
            }
        }

        let mut len = std::cmp::min(buf.remaining(), self.temp_read_buffer.len());
        buf.put_slice(&self.temp_read_buffer[..len]);
        self.temp_read_buffer.drain(..len);
        // Elarni: take the other queued segments that fit, so the proxy writes them at once.
        while self.temp_read_buffer.is_empty() && buf.remaining() > 0 {
            let Ok(data) = self.data_rx.try_recv() else { break };
            let n = std::cmp::min(buf.remaining(), data.len());
            buf.put_slice(&data[..n]);
            self.temp_read_buffer = data;
            self.temp_read_buffer.drain(..n);
            len += n;
        }
        let mut tcb = self.tcb.lock().unwrap();
        if tcb.take_unread(len) && tcb.get_state() != TcpState::Closed {
            // Announce the reopened window; the read already succeeded, so a send error is left to the task.
            _ = write_packet_to_device(&self.up_packet_sender, network_tuple, &tcb, None, ACK, None, None);
        }
        Poll::Ready(Ok(()))
    }
}

impl AsyncWrite for IpStackTcpStream {
    fn poll_write(mut self: std::pin::Pin<&mut Self>, cx: &mut Context<'_>, buf: &[u8]) -> Poll<std::io::Result<usize>> {
        let nt = self.network_tuple();
        self.reset_timeout();

        let mut tcb = self.tcb.lock().unwrap();
        let state = tcb.get_state();
        let send_window = tcb.get_send_window();
        let room = tcb.send_room();
        let is_full = room == 0;

        if state == TcpState::Closed {
            self.shutdown.lock().unwrap().ready();
            self.read_notify.lock().unwrap().take().map(|w| w.wake_by_ref()).unwrap_or(());
            return Poll::Ready(Err(std::io::Error::new(BrokenPipe, "TCP connection closed")));
        }

        // Elarni: before the handshake ends, data would go out ahead of the SYN-ACK.
        if is_full || matches!(state, TcpState::Listen | TcpState::SynReceived) {
            self.write_notify.lock().unwrap().replace(cx.waker().clone());
            log::trace!(
                "{nt} {state:?}: [poll_write] current send window: {send_window}, send buffer full: {is_full}, waiting for the other side to send ACK..."
            );
            return Poll::Pending;
        }

        let sender = &self.up_packet_sender;
        let payload = buf[..buf.len().min(room)].to_vec();
        let payload_len = write_packet_to_device(sender, nt, &tcb, None, ACK | PSH, None, Some(payload))?;
        tcb.add_inflight_packet(buf[..payload_len].to_vec())?;

        let (state, seq, ack) = (tcb.get_state(), tcb.get_seq(), tcb.get_ack());
        let l_info = Local(seq, ack);
        log::trace!("{nt} {state:?}: [poll_write] {l_info} upstream data written to device, len = {payload_len}");

        Poll::Ready(Ok(payload_len))
    }

    fn poll_flush(self: std::pin::Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Poll::Ready(Ok(()))
    }

    fn poll_shutdown(self: std::pin::Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        let nt = self.network_tuple();
        {
            let mut tcb = self.tcb.lock().unwrap();
            let (state, seq) = (tcb.get_state(), tcb.get_seq());
            log::trace!("{nt} {state:?}: [poll_shutdown] seq = {seq}");
            if state == TcpState::Closed {
                return Poll::Ready(Ok(()));
            }
            tcb.request_fin();
            if let Some(exit_notifier) = &self.exit_notifier {
                send_fin_if_due(
                    "[poll_shutdown]",
                    nt,
                    &self.up_packet_sender,
                    &mut tcb,
                    &self.tcb,
                    exit_notifier,
                    &self.config,
                )?;
            }
        }
        let mut shutdown = self.shutdown.lock().unwrap();
        if let Shutdown::Ready = *shutdown {
            return Poll::Ready(Ok(()));
        }
        shutdown.pending(cx.waker().clone());
        Poll::Pending
    }
}

/// Sends our FIN once the application has shut down and the peer has acknowledged everything it wrote.
fn send_fin_if_due(
    hint: &str,
    nt: NetworkTuple,
    sender: &PacketSender,
    tcb: &mut Tcb,
    tcb_ptr: &TcbPtr,
    exit_notifier: &tokio::sync::mpsc::Sender<()>,
    config: &TcpConfig,
) -> std::io::Result<()> {
    let state = tcb.get_state();
    let next = match state {
        TcpState::Established => TcpState::FinWait1,
        TcpState::CloseWait => TcpState::LastAck,
        _ => return Ok(()),
    };
    if !tcb.is_fin_due() {
        return Ok(());
    }

    log::debug!("{nt} {state:?}: {hint} actively send a farewell packet to the other side...");
    write_packet_to_device(sender, nt, tcb, None, ACK | FIN, None, None)?;
    tcb.increase_seq();
    tcb.change_state(next);
    log::debug!("{nt} {state:?}: {hint} now in {next:?} state");
    // Elarni: resend the FIN until the other side acknowledges it; a lost one left the client waiting for the end.
    let (last_ack_timeout, retries) = (config.last_ack_timeout, config.last_ack_max_retries);
    tokio::spawn(task_resend_fin(
        tcb_ptr.clone(),
        exit_notifier.clone(),
        nt,
        sender.clone(),
        next,
        last_ack_timeout,
        retries,
    ));
    Ok(())
}

/// Resends our FIN while the session stays in `waiting` (FIN_WAIT_1 or LAST_ACK), then gives up and closes it.
async fn task_resend_fin(
    tcb: TcbPtr,
    exit_notifier: tokio::sync::mpsc::Sender<()>,
    nt: NetworkTuple,
    pkt_sdr: PacketSender,
    waiting: TcpState,
    last_ack_timeout: Duration,
    last_ack_max_retries: usize,
) {
    let hint = "[task_resend_fin]";
    for idx in 1..=last_ack_max_retries {
        tokio::time::sleep(last_ack_timeout).await;

        {
            let tcb = tcb.lock().unwrap();
            let state = tcb.get_state();
            if state != waiting {
                log::debug!("{nt} {state:?}: {hint} FIN acknowledged, exiting...");
                return;
            }
            log::debug!("{nt} {state:?}: {hint} timer expired, resending ACK|FIN (retry {idx}/{last_ack_max_retries})");
            let fin_seq = Some(tcb.get_seq() - 1);
            _ = write_packet_to_device(&pkt_sdr, nt, &tcb, None, ACK | FIN, fin_seq, None);
        }
    }
    {
        let mut tcb = tcb.lock().unwrap();
        tcb.change_state(TcpState::Closed);
        let state = tcb.get_state();
        log::warn!("{nt} {state:?}: {hint} max retries reached, forcibly closing session");
    }
    exit_notifier.send(()).await.unwrap_or(());
}

fn wake(notify: &std::sync::Mutex<Option<Waker>>) {
    if let Some(waker) = notify.lock().unwrap().take() {
        waker.wake();
    }
}

/// Resends the segments whose timer expired. Returns false after one ran out of retries and the connection was reset.
fn retransmit_timed_out(sender: &PacketSender, nt: NetworkTuple, tcb: &mut Tcb) -> std::io::Result<bool> {
    for packet in tcb.collect_timed_out_inflight_packets() {
        let (seq, count) = (packet.seq, packet.retransmit_count);
        log::debug!("{nt} inflight packet retransmission timeout: {seq:?}, retransmit_count: {count}");
        write_packet_to_device(sender, nt, tcb, None, ACK | PSH, Some(seq), Some(packet.payload))?;
    }
    if !tcb.is_retransmit_exhausted() {
        return Ok(true);
    }
    log::warn!("{nt} {:?}: retransmissions exhausted, resetting the connection", tcb.get_state());
    write_packet_to_device(sender, nt, tcb, None, ACK | RST, None, None)?;
    tcb.change_state(TcpState::Closed);
    Ok(false)
}

impl Drop for IpStackTcpStream {
    fn drop(&mut self) {
        let (nt, state) = (self.network_tuple(), self.tcb.lock().unwrap().get_state());
        log::trace!("{nt} {state:?}: [drop] session dropping, ========================= ");
        if let Some(task_handle) = self.task_handle.take() {
            if !task_handle.is_finished() {
                if let Some(notifier) = self.exit_notifier.take() {
                    _ = tokio::task::block_in_place(|| tokio::runtime::Handle::current().block_on(notifier.send(())));
                }
                // synchronously wait for the task to finish
                _ = tokio::task::block_in_place(|| tokio::runtime::Handle::current().block_on(task_handle));
            } else {
                log::trace!("{nt} {state:?}: [drop] task already finished, no need to wait exiting");
            }
        }
        let sessions = SESSION_COUNTER.fetch_sub(1, std::sync::atomic::Ordering::SeqCst).saturating_sub(1);
        log::debug!("{nt} {state:?}: [drop] session dropped, total TCP sessions: {sessions}");
    }
}

impl IpStackTcpStream {
    fn spawn_tasks(&mut self) -> std::io::Result<()> {
        let network_tuple = self.network_tuple();

        // task: data receiving and processing
        let tcb = self.tcb.clone();
        let stream_receiver = self.stream_receiver.take().unwrap();
        let up_packet_sender = self.up_packet_sender.clone();
        let shutdown = self.shutdown.clone();
        let write_notify = self.write_notify.clone();
        let read_notify = self.read_notify.clone();
        let (task_read_notify, task_write_notify) = (read_notify.clone(), write_notify.clone());
        let data_tx = self.data_tx.clone();
        let destroy_messenger = self.destroy_messenger.take();

        let (exit_task_notifier, exit_monitor) = tokio::sync::mpsc::channel::<()>(10);
        let exit_notifier = exit_task_notifier.clone();
        let config = self.config.clone();
        self.exit_notifier = Some(exit_task_notifier);

        let task_handle = tokio::spawn(async move {
            let v = tcp_main_logic_loop(
                tcb,
                config,
                stream_receiver,
                up_packet_sender,
                exit_notifier,
                network_tuple,
                write_notify,
                read_notify,
                data_tx,
                exit_monitor,
            )
            .await;
            if let Err(e) = &v {
                log::warn!("{network_tuple} task error: {e}");
            }
            _ = destroy_messenger.map(|m| m.send(())).unwrap_or(Ok(()));
            log::trace!("{network_tuple} task completed, destroy messenger sent successfully");
            shutdown.lock().unwrap().ready();
            // Elarni: a read or write still pending sees the closed session instead of waiting for the idle timeout.
            wake(&task_read_notify);
            wake(&task_write_notify);
            log::trace!("{network_tuple} shutdown.lock().unwrap().ready() ==========");
            v
        });
        self.task_handle = Some(task_handle);
        Ok(())
    }
}

#[allow(clippy::too_many_arguments)]
async fn tcp_main_logic_loop(
    tcb: TcbPtr,
    config: Arc<TcpConfig>,
    mut stream_receiver: PacketReceiver,
    up_packet_sender: PacketSender,
    exit_notifier: tokio::sync::mpsc::Sender<()>,
    network_tuple: NetworkTuple,
    write_notify: std::sync::Arc<std::sync::Mutex<Option<Waker>>>,
    read_notify: std::sync::Arc<std::sync::Mutex<Option<Waker>>>,
    data_tx: tokio::sync::mpsc::UnboundedSender<Vec<u8>>,
    mut exit_monitor: tokio::sync::mpsc::Receiver<()>,
) -> std::io::Result<()> {
    {
        let mut tcb = tcb.lock().unwrap();

        let state = tcb.get_state();
        if state != TcpState::Listen {
            log::warn!("{network_tuple} {state:?}: Invalid TCP state, not in Listen state");
            return Ok::<(), std::io::Error>(());
        }

        tcb.increase_ack();
        let (seq, ack) = (tcb.get_seq().0, tcb.get_ack().0);
        let l_info = format!("local {{ seq: {seq}, ack: {ack} }}");
        log::trace!("{network_tuple} {state:?}: {l_info} session begins");
        // Elarni: announce the MSS the MTU allows, so the client does not fall back to 536 bytes.
        let ip_and_tcp_headers = if network_tuple.src.is_ipv4() { 40 } else { 60 };
        let default_options = vec![TcpOptions::MaximumSegmentSize(tcb.get_mtu().saturating_sub(ip_and_tcp_headers))];
        let options = Some(config.options.as_ref().unwrap_or(&default_options));
        write_packet_to_device(&up_packet_sender, network_tuple, &tcb, options, ACK | SYN, None, None)?;
        tcb.increase_seq();
        tcb.change_state(TcpState::SynReceived);
        let state = tcb.get_state();
        log::trace!("{network_tuple} {state:?}: session now in {state:?} state");
    }

    let tcb_clone = tcb.clone();

    async fn task_wait_to_close(tcb: TcbPtr, exit_notifier: tokio::sync::mpsc::Sender<()>, nt: NetworkTuple, two_msl: Duration) {
        tokio::time::sleep(two_msl).await;
        {
            let mut tcb = tcb.lock().unwrap();
            tcb.change_state(TcpState::Closed);
            let state = tcb.get_state();
            log::debug!("{nt} {state:?}: [task_wait_to_close] session closed after {two_msl:?}");
        }
        exit_notifier.send(()).await.unwrap_or(());
    }

    loop {
        let exit_notifier = exit_notifier.clone();

        // Elarni: retransmit on a timer; it only ran when the client sent another packet, so a lost tail hung.
        let deadline = tcb.lock().unwrap().next_retransmit_deadline();
        let retransmit_timer = async move {
            match deadline {
                Some(deadline) => tokio::time::sleep_until(tokio::time::Instant::from_std(deadline)).await,
                None => std::future::pending().await,
            }
        };

        let network_packet = tokio::select! {
            _ = exit_monitor.recv() => {
                log::debug!("{network_tuple} task exited due to exit signal");
                break;
            }
            _ = retransmit_timer => {
                let mut tcb = tcb.lock().unwrap();
                if tcb.get_state() == TcpState::Closed {
                    break;
                }
                if retransmit_timed_out(&up_packet_sender, network_tuple, &mut tcb)? {
                    continue;
                }
                wake(&write_notify);
                wake(&read_notify);
                break;
            }
            network_packet = stream_receiver.recv() => network_packet,
        };

        let Some(mut network_packet) = network_packet else {
            let state = { tcb.lock().unwrap().get_state() };
            log::debug!("{network_tuple} {state:?}: session closed unexpectedly by pipe broken, exiting task");
            tcb.lock().unwrap().change_state(TcpState::Closed);
            write_notify.lock().unwrap().take().map(|w| w.wake_by_ref()).unwrap_or(());
            read_notify.lock().unwrap().take().map(|w| w.wake_by_ref()).unwrap_or(());
            break;
        };

        let payload = network_packet.payload.take().unwrap_or_default();
        let TransportHeader::Tcp(tcp_header) = network_packet.transport_header() else {
            log::warn!("{network_tuple} Invalid TCP packet");
            continue;
        };
        let flags = tcp_header_flags(tcp_header);
        let incoming_ack: SeqNum = tcp_header.acknowledgment_number.into();
        let incoming_seq: SeqNum = tcp_header.sequence_number.into();
        let incoming_win = tcp_header.window_size;

        let mut tcb = tcb.lock().unwrap();

        let state = tcb.get_state();
        if state == TcpState::Closed {
            log::debug!("{network_tuple} {state:?}: session finished, exiting task...");
            break;
        }

        if flags & RST == RST {
            // Elarni: wake the application, whose pending read or write would otherwise wait for the idle timeout.
            tcb.change_state(TcpState::Closed);
            wake(&write_notify);
            wake(&read_notify);
            break;
        }

        tcb.update_duplicate_ack_count(incoming_ack);

        tcb.update_inflight_packet_queue(incoming_ack);

        if !retransmit_timed_out(&up_packet_sender, network_tuple, &mut tcb)? {
            wake(&write_notify);
            wake(&read_notify);
            break;
        }

        let pkt_type = tcb.check_pkt_type(tcp_header, &payload);

        let (state, seq, ack) = { (tcb.get_state(), tcb.get_seq(), tcb.get_ack()) };
        let (l_info, len) = (Local(seq, ack), payload.len());
        log::trace!(
            "{network_tuple} {state:?}: {l_info} {}, {pkt_type:?}, len = {len}",
            tcp_header_fmt(tcp_header)
        );
        if pkt_type == PacketType::Invalid {
            continue;
        }

        match state {
            TcpState::SynReceived if flags & ACK == ACK => {
                if len > 0 {
                    tcb.add_unordered_packet(incoming_seq, payload);
                    extract_data_n_write_upstream(&up_packet_sender, &mut tcb, network_tuple, &data_tx, &read_notify)?;
                }
                tcb.change_state(TcpState::Established);
                wake(&write_notify);
            }
            TcpState::Established => {
                if pkt_type == PacketType::KeepAlive {
                    write_packet_to_device(&up_packet_sender, network_tuple, &tcb, None, ACK, None, None)?;
                } else if len > 0 {
                    // Elarni: keep out-of-order data and ACK every segment, so the client sees duplicate ACKs.
                    tcb.add_unordered_packet(incoming_seq, payload);
                    extract_data_n_write_upstream(&up_packet_sender, &mut tcb, network_tuple, &data_tx, &read_notify)?;
                    wake(&write_notify);
                } else {
                    match pkt_type {
                        PacketType::RetransmissionRequest => {
                            if let Some(packet) = tcb.find_inflight_packet(incoming_ack) {
                                let (s, p) = (packet.seq, packet.payload.clone());
                                log::debug!(
                                    "{network_tuple} {state:?}: {l_info}, {pkt_type:?}, retransmission request, seq = {s}, len = {}",
                                    p.len()
                                );
                                write_packet_to_device(&up_packet_sender, network_tuple, &tcb, None, ACK | PSH, Some(s), Some(p))?;
                            }
                        }
                        _ => wake(&write_notify),
                    }
                }
                // Elarni: a FIN ends the application's read and leaves its write open (half-close); our FIN follows its shutdown.
                if flags & FIN == FIN && tcb.get_ack() == incoming_seq + len as u32 {
                    tcb.increase_ack();
                    write_packet_to_device(&up_packet_sender, network_tuple, &tcb, None, ACK, None, None)?;
                    tcb.change_state(TcpState::CloseWait);
                    wake(&read_notify);
                    log::trace!("{network_tuple} {state:?}: {l_info}, closed by the other side");
                }
            }
            TcpState::CloseWait => {
                if flags & FIN == FIN {
                    // Elarni: the client resends its FIN when our ACK was lost.
                    write_packet_to_device(&up_packet_sender, network_tuple, &tcb, None, ACK, None, None)?;
                }
                wake(&write_notify);
            }
            TcpState::LastAck if flags & ACK == ACK && incoming_ack == tcb.get_seq() => {
                tcb.change_state(TcpState::Closed);
                let exit_notifier = exit_notifier.clone();
                tokio::spawn(async move {
                    if let Err(e) = exit_notifier.send(()).await {
                        log::debug!("exit_notifier send failed: {e}");
                    }
                });
                let new_state = tcb.get_state();
                log::trace!("{network_tuple} {state:?}: Received final ACK, transitioned to {new_state:?}");
            }
            TcpState::FinWait1 => {
                if flags & (ACK | FIN) == (ACK | FIN) && len == 0 {
                    // If the received packet is an ACK with FIN, we need to send an ACK and change state to TimeWait directly, not to FinWait2
                    tcb.increase_ack();
                    write_packet_to_device(&up_packet_sender, network_tuple, &tcb, None, ACK, None, None)?;
                    tcb.change_state(TcpState::TimeWait);

                    tokio::spawn(task_wait_to_close(
                        tcb_clone.clone(),
                        exit_notifier.clone(),
                        network_tuple,
                        config.two_msl,
                    ));
                    wake(&read_notify);
                    let new_state = tcb.get_state();
                    log::trace!("{network_tuple} {state:?}: Final ACK|FIN received too early, transitioned to {new_state:?} directly");
                } else if flags & ACK == ACK {
                    // Elarni: only the ACK of our FIN ends FIN_WAIT_1; task_resend_fin resends it until then.
                    if incoming_ack == tcb.get_seq() {
                        tcb.change_state(TcpState::FinWait2);
                    }
                    if len > 0 {
                        // if the other side is still sending data, we need to deal with it like PacketStatus::NewPacket
                        tcb.add_unordered_packet(incoming_seq, payload);
                        extract_data_n_write_upstream(&up_packet_sender, &mut tcb, network_tuple, &data_tx, &read_notify)?;
                        write_notify.lock().unwrap().take().map(|w| w.wake_by_ref()).unwrap_or(());
                    }
                    let new_state = tcb.get_state();
                    log::trace!("{network_tuple} {state:?}: Received ACK, transitioned to {new_state:?}");
                } else {
                    // unnormal case, we do nothing here
                    log::trace!("{network_tuple} {state:?}: Some unnormal case, we do nothing here");
                }
            }
            TcpState::FinWait2 => {
                if pkt_type == PacketType::KeepAlive {
                    write_packet_to_device(&up_packet_sender, network_tuple, &tcb, None, ACK, None, None)?;
                } else if len > 0 {
                    // if the other side is still sending data, we need to deal with it like PacketStatus::NewPacket
                    tcb.add_unordered_packet(incoming_seq, payload);
                    extract_data_n_write_upstream(&up_packet_sender, &mut tcb, network_tuple, &data_tx, &read_notify)?;
                    write_notify.lock().unwrap().take().map(|w| w.wake_by_ref()).unwrap_or(());
                }
                // Elarni: acknowledge an in-order FIN, also one carrying data, and end the application's read.
                if flags & FIN == FIN && tcb.get_ack() == incoming_seq + len as u32 {
                    tcb.increase_ack();
                    write_packet_to_device(&up_packet_sender, network_tuple, &tcb, None, ACK, None, None)?;
                    tcb.change_state(TcpState::TimeWait);
                    tokio::spawn(task_wait_to_close(
                        tcb_clone.clone(),
                        exit_notifier.clone(),
                        network_tuple,
                        config.two_msl,
                    ));
                    wake(&read_notify);
                    let new_state = tcb.get_state();
                    log::trace!("{network_tuple} {state:?}: Received final ACK|FIN, transitioned to {new_state:?}");
                }
            }
            TcpState::TimeWait if flags & (ACK | FIN) == (ACK | FIN) => {
                write_packet_to_device(&up_packet_sender, network_tuple, &tcb, None, ACK, None, None)?;
                // wait to timeout, can't call `tcb.change_state(TcpState::Closed);` to change state here
                // now we need to wait for the timeout to reach...
            }
            _ => {}
        } // end of match state
        send_fin_if_due(
            "[ack]",
            network_tuple,
            &up_packet_sender,
            &mut tcb,
            &tcb_clone,
            &exit_notifier,
            &config,
        )?;

        tcb.update_last_received_ack(incoming_ack);
        tcb.update_send_window(incoming_win);
    } // end of loop
    Ok::<(), std::io::Error>(())
}

fn extract_data_n_write_upstream(
    up_packet_sender: &PacketSender,
    tcb: &mut Tcb,
    network_tuple: NetworkTuple,
    data_tx: &tokio::sync::mpsc::UnboundedSender<Vec<u8>>,
    read_notify: &std::sync::Arc<std::sync::Mutex<Option<Waker>>>,
) -> std::io::Result<()> {
    let (state, seq, ack) = (tcb.get_state(), tcb.get_seq(), tcb.get_ack());
    let l_info = Local(seq, ack);
    if state == TcpState::Closed {
        log::debug!("{network_tuple} {state:?}: {l_info} session closed, exiting \"data extraction task\"...");
        return Ok(());
    }

    if let Some(data) = tcb.consume_unordered_packets(usize::MAX) {
        let hint = if state == TcpState::Established { "normally" } else { "still" };
        log::trace!("{network_tuple} {state:?}: {l_info} {hint} receiving data, len = {}", data.len());
        // Elarni: unread bytes close the receive window, which bounds this queue.
        tcb.add_unread(data.len());
        data_tx.send(data).map_err(|e| std::io::Error::new(BrokenPipe, e))?;
        read_notify.lock().unwrap().take().map(|w| w.wake_by_ref()).unwrap_or(());
    }
    // Also for a gap or a full window: the duplicate ACK tells the client what is missing.
    write_packet_to_device(up_packet_sender, network_tuple, tcb, None, ACK, None, None)?;
    Ok(())
}

/// Send a TCP packet to the downstream device, with the specified flags, sequence number, and payload.
/// The returned value is the length of the `payload` sent, it may be shorter than the length of the incoming parameter `payload`.
pub(crate) fn write_packet_to_device(
    up_packet_sender: &PacketSender,
    tuple: NetworkTuple,
    tcb: &Tcb,
    options: Option<&Vec<TcpOptions>>,
    flags: u8,
    seq: Option<SeqNum>,
    payload: Option<Vec<u8>>,
) -> std::io::Result<usize> {
    use std::io::Error;
    let seq = seq.unwrap_or(tcb.get_seq()).0;
    let (ack, window_size) = (tcb.get_ack().0, tcb.get_recv_window());
    let (src, dst) = (tuple.dst, tuple.src); // Note: The address is reversed here
    let calc = |ip_header_len: usize, tcp_header_len: usize| tcb.calculate_payload_max_len(ip_header_len, tcp_header_len);
    let packet = create_raw_packet(
        src,
        dst,
        calc,
        flags,
        TTL,
        seq,
        ack,
        window_size,
        payload.unwrap_or_default(),
        options,
    )?;
    let len = packet.payload.as_ref().map(|p| p.len()).unwrap_or(0);
    up_packet_sender.send(packet).map_err(|e| Error::new(UnexpectedEof, e))?;
    Ok(len)
}

#[allow(clippy::too_many_arguments)]
pub(crate) fn create_raw_packet(
    src_addr: SocketAddr,
    dst_addr: SocketAddr,
    calculate_payload_max_len: impl Fn(usize, usize) -> usize,
    flags: u8,
    ttl: u8,
    seq: u32,
    ack: u32,
    win: u16,
    mut payload: Vec<u8>,
    options: Option<&Vec<TcpOptions>>,
) -> std::io::Result<NetworkPacket> {
    let mut tcp_header = etherparse::TcpHeader::new(src_addr.port(), dst_addr.port(), seq, win);
    tcp_header.acknowledgment_number = ack;
    tcp_header.syn = flags & SYN != 0;
    tcp_header.ack = flags & ACK != 0;
    tcp_header.rst = flags & RST != 0;
    tcp_header.fin = flags & FIN != 0;
    tcp_header.psh = flags & PSH != 0;

    if let Some(opts) = options {
        let mut tcp_options = Vec::new();
        for opt in opts {
            match opt {
                TcpOptions::MaximumSegmentSize(mss) => tcp_options.push(TcpOptionElement::MaximumSegmentSize(*mss)),
            }
        }
        tcp_header
            .set_options(&tcp_options)
            .map_err(|e| std::io::Error::new(InvalidInput, e))?;
    }
    let ip_header = match (src_addr.ip(), dst_addr.ip()) {
        (std::net::IpAddr::V4(src), std::net::IpAddr::V4(dst)) => {
            let mut ip_h =
                Ipv4Header::new(0, ttl, IpNumber::TCP, src.octets(), dst.octets()).map_err(|e| std::io::Error::new(InvalidInput, e))?;
            let payload_len = calculate_payload_max_len(ip_h.header_len(), tcp_header.header_len());
            payload.truncate(payload_len);
            ip_h.set_payload_len(payload.len() + tcp_header.header_len())
                .map_err(|e| std::io::Error::new(InvalidInput, e))?;
            ip_h.dont_fragment = true;
            IpHeader::Ipv4(ip_h)
        }
        (std::net::IpAddr::V6(src), std::net::IpAddr::V6(dst)) => {
            let mut ip_h = etherparse::Ipv6Header {
                traffic_class: 0,
                flow_label: Ipv6FlowLabel::ZERO,
                payload_length: 0,
                next_header: IpNumber::TCP,
                hop_limit: ttl,
                source: src.octets(),
                destination: dst.octets(),
            };
            let payload_len = calculate_payload_max_len(ip_h.header_len(), tcp_header.header_len());
            payload.truncate(payload_len);
            let len = payload.len() + tcp_header.header_len();
            ip_h.set_payload_length(len).map_err(|e| std::io::Error::new(InvalidInput, e))?;

            IpHeader::Ipv6(ip_h)
        }
        _ => return Err(std::io::Error::new(std::io::ErrorKind::InvalidInput, "IP version mismatch")),
    };

    match ip_header {
        IpHeader::Ipv4(ref ip_header) => {
            tcp_header.checksum = tcp_header
                .calc_checksum_ipv4(ip_header, &payload)
                .map_err(|e| std::io::Error::new(InvalidInput, e))?;
        }
        IpHeader::Ipv6(ref ip_header) => {
            tcp_header.checksum = tcp_header
                .calc_checksum_ipv6(ip_header, &payload)
                .map_err(|e| std::io::Error::new(InvalidInput, e))?;
        }
    }
    Ok(NetworkPacket {
        ip: ip_header,
        transport: TransportHeader::Tcp(tcp_header),
        payload: Some(payload),
    })
}

/// Elarni: the sequence numbers for a log line, formatted only when the line is logged.
struct Local<T>(T, T);

impl<T: std::fmt::Display> std::fmt::Display for Local<T> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "local {{ seq: {}, ack: {} }}", self.0, self.1)
    }
}
