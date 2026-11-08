#[cfg(target_os = "linux")]
extern crate bincode_next as bincode;

#[cfg(feature = "udpgw")]
use crate::udpgw::UdpGwClient;
use crate::{
    directions::{IncomingDataEvent, IncomingDirection, OutgoingDirection},
    http::HttpManager,
    no_proxy::NoProxyManager,
    session_info::{IpProtocol, SessionInfo},
};
pub use clap::ValueEnum;
use ipstack::{IpStackStream, IpStackTcpStream, IpStackUdpStream};
use proxy_handler::{ProxyHandler, ProxyHandlerManager};
use socks::SocksProxyManager;
pub use socks5_impl::protocol::UserKey;
#[cfg(feature = "udpgw")]
use std::net::{Ipv4Addr, Ipv6Addr, SocketAddrV4, SocketAddrV6};
use std::{
    collections::VecDeque,
    io::ErrorKind,
    net::{IpAddr, SocketAddr},
    sync::Arc,
};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt},
    net::{TcpSocket, TcpStream, UdpSocket},
    sync::{Mutex, mpsc::Receiver},
    task::JoinSet,
};
pub use tokio_util::sync::CancellationToken;
pub use tun::DEFAULT_MTU;
#[cfg(feature = "udpgw")]
use udpgw::{UDPGW_KEEPALIVE_TIME, UDPGW_MAX_CONNECTIONS, UdpGwClientStream, UdpGwResponse};

pub use {
    args::{ArgDns, ArgProxy, ArgVerbosity, Args, ProxyType},
    error::{BoxError, Error, Result},
    traffic_status::{TrafficStatus, tun2proxy_set_traffic_status_callback},
    virtual_dns::{VirtualDns, VirtualDnsMetrics, VirtualDnsMetricsSnapshot},
};

pub use general_api::general_run_async;

pub const FORCE_EXIT_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(2);

mod android;
mod args;
mod directions;
mod dns;
mod dump_logger;
mod error;
mod general_api;
mod http;
mod no_proxy;
mod proxy_handler;
mod session_info;
pub mod socket_transfer;
mod socks;
mod traffic_status;
#[cfg(feature = "udpgw")]
pub mod udpgw;
mod virtual_dns;
#[doc(hidden)]
pub mod win_svc;

const DNS_PORT: u16 = 53;
/// Elarni: a DNS session still waiting for an answer ends after this long without traffic, as before the UDP timeout rose.
const DNS_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);
/// Elarni: UDP sessions past `udp_max_sessions` that only DNS may take. A burst of fresh UDP flows filled
/// the cap and refused every lookup with it; DNS sessions end with their answer, so this bounds lookups in flight.
const DNS_RESERVED_SESSIONS: usize = 128;

/// Elarni: `tproxy_config::is_private_ip` with std checks instead of nine regexes compiled per call,
/// which every IPv6 or public IPv4 DNS session paid.
fn is_private_ip(ip: IpAddr) -> bool {
    let private = |v4: std::net::Ipv4Addr| v4.is_private() || v4.is_loopback() || v4.is_link_local();
    match ip {
        IpAddr::V4(v4) => private(v4) || (v4.octets()[0] == 198 && v4.octets()[1] & 0xfe == 18),
        IpAddr::V6(v6) => {
            let first = v6.segments()[0];
            v6.to_ipv4_mapped().is_some_and(private)
                || first & 0xfe00 == 0xfc00
                || first == 0xfe80
                || v6.is_loopback()
                || v6.is_unspecified()
        }
    }
}

#[allow(unused)]
#[derive(Hash, Copy, Clone, Eq, PartialEq, Debug)]
#[cfg_attr(
    target_os = "linux",
    derive(bincode::Encode, bincode::Decode, serde::Serialize, serde::Deserialize)
)]
pub enum SocketProtocol {
    Tcp,
    Udp,
}

#[allow(unused)]
#[derive(Hash, Copy, Clone, Eq, PartialEq, Debug)]
#[cfg_attr(
    target_os = "linux",
    derive(bincode::Encode, bincode::Decode, serde::Serialize, serde::Deserialize)
)]
pub enum SocketDomain {
    IpV4,
    IpV6,
}

impl From<IpAddr> for SocketDomain {
    fn from(value: IpAddr) -> Self {
        match value {
            IpAddr::V4(_) => Self::IpV4,
            IpAddr::V6(_) => Self::IpV6,
        }
    }
}

struct SocketQueue {
    tcp_v4: Mutex<Receiver<TcpSocket>>,
    tcp_v6: Mutex<Receiver<TcpSocket>>,
    udp_v4: Mutex<Receiver<UdpSocket>>,
    udp_v6: Mutex<Receiver<UdpSocket>>,
}

impl SocketQueue {
    async fn recv_tcp(&self, domain: SocketDomain) -> Result<TcpSocket, std::io::Error> {
        match domain {
            SocketDomain::IpV4 => &self.tcp_v4,
            SocketDomain::IpV6 => &self.tcp_v6,
        }
        .lock()
        .await
        .recv()
        .await
        .ok_or(ErrorKind::Other.into())
    }
    async fn recv_udp(&self, domain: SocketDomain) -> Result<UdpSocket, std::io::Error> {
        match domain {
            SocketDomain::IpV4 => &self.udp_v4,
            SocketDomain::IpV6 => &self.udp_v6,
        }
        .lock()
        .await
        .recv()
        .await
        .ok_or(ErrorKind::Other.into())
    }
}

async fn create_tcp_stream(socket_queue: &Option<Arc<SocketQueue>>, peer: SocketAddr) -> std::io::Result<TcpStream> {
    let stream = match &socket_queue {
        None => TcpStream::connect(peer).await,
        Some(queue) => queue.recv_tcp(peer.ip().into()).await?.connect(peer).await,
    }?;
    // Elarni: Nagle held a small write behind an unacknowledged one on the proxy leg.
    let _ = stream.set_nodelay(true);
    Ok(stream)
}

async fn create_udp_stream(socket_queue: &Option<Arc<SocketQueue>>, peer: SocketAddr) -> std::io::Result<UdpSocket> {
    let socket = match &socket_queue {
        None => {
            let bind_addr = match peer {
                SocketAddr::V4(_) => SocketAddr::from((std::net::Ipv4Addr::UNSPECIFIED, 0)),
                SocketAddr::V6(_) => SocketAddr::from((std::net::Ipv6Addr::UNSPECIFIED, 0)),
            };
            UdpSocket::bind(bind_addr).await?
        }
        Some(queue) => queue.recv_udp(peer.ip().into()).await?,
    };
    // Darwin's default send capacity rejects large UDP messages with EMSGSIZE.
    #[cfg(target_vendor = "apple")]
    nix::sys::socket::setsockopt(&socket, nix::sys::socket::sockopt::SndBuf, &(u16::MAX as usize))?;
    // udp-stream read replies into a 17 KiB buffer, losing (Windows) or truncating (Unix)
    // larger datagrams. A connected socket filters by peer and reads each one whole.
    socket.connect(peer).await?;
    Ok(socket)
}

#[derive(Debug, Default)]
pub struct SessionMetrics {
    pub active_tcp: std::sync::atomic::AtomicUsize,
    pub active_udp: std::sync::atomic::AtomicUsize,
    // New sessions refused at the limit; a log line alone hid stalled DNS.
    pub dropped_tcp: std::sync::atomic::AtomicUsize,
    pub dropped_udp: std::sync::atomic::AtomicUsize,
}

struct SessionGuard(Arc<SessionMetrics>, IpProtocol);

impl Drop for SessionGuard {
    fn drop(&mut self) {
        let count = match self.1 {
            IpProtocol::Tcp => &self.0.active_tcp,
            IpProtocol::Udp => &self.0.active_udp,
            _ => return,
        };
        let active = count.fetch_sub(1, std::sync::atomic::Ordering::Relaxed).saturating_sub(1);
        log::trace!("{:?} session count {active}", self.1);
    }
}

/// Run the proxy server
/// # Arguments
/// * `device` - The network device to use
/// * `mtu` - The MTU of the network device
/// * `args` - The arguments to use
/// * `shutdown_token` - The token to exit the server
/// # Returns
/// * The number of sessions while exiting
pub async fn run<D>(device: D, mtu: u16, args: Args, shutdown_token: CancellationToken) -> crate::Result<usize>
where
    D: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    log::info!("{} {} starting...", env!("CARGO_PKG_NAME"), version_info!());
    log::info!("Proxy {} server: {}", args.proxy.proxy_type, args.proxy.addr);

    let server_addr = args.proxy.addr;
    let key = args.proxy.credentials.clone();
    let dns_addr = args.dns_addr;
    let ipv6_enabled = args.ipv6_enabled;
    let virtual_dns = if args.dns == ArgDns::Virtual {
        let metrics = args.virtual_dns_metrics.clone().unwrap_or_default();
        Some(Arc::new(Mutex::new(VirtualDns::new(
            args.virtual_dns_pool,
            args.virtual_dns_ipv6_pool,
            args.virtual_dns_capacity,
            std::time::Duration::from_secs(args.virtual_dns_mapping_ttl),
            args.virtual_dns_answer_ttl,
            metrics,
        )?)))
    } else {
        None
    };

    #[cfg(target_os = "linux")]
    let socket_queue = match args.socket_transfer_fd {
        None => None,
        Some(fd) => {
            use crate::socket_transfer::{reconstruct_socket, reconstruct_transfer_socket, request_sockets};
            use tokio::sync::mpsc::channel;

            let fd = reconstruct_socket(fd)?;
            let socket = reconstruct_transfer_socket(fd)?;
            let socket = Arc::new(Mutex::new(socket));

            macro_rules! create_socket_queue {
                ($domain:ident) => {{
                    const SOCKETS_PER_REQUEST: usize = 64;

                    let socket = socket.clone();
                    let (tx, rx) = channel(SOCKETS_PER_REQUEST);
                    tokio::spawn(async move {
                        loop {
                            let sockets =
                                match request_sockets(socket.lock().await, SocketDomain::$domain, SOCKETS_PER_REQUEST as u32).await {
                                    Ok(sockets) => sockets,
                                    Err(err) => {
                                        log::warn!("Socket allocation request failed: {err}");
                                        continue;
                                    }
                                };
                            for s in sockets {
                                if let Err(_) = tx.send(s).await {
                                    return;
                                }
                            }
                        }
                    });
                    Mutex::new(rx)
                }};
            }

            Some(Arc::new(SocketQueue {
                tcp_v4: create_socket_queue!(IpV4),
                tcp_v6: create_socket_queue!(IpV6),
                udp_v4: create_socket_queue!(IpV4),
                udp_v6: create_socket_queue!(IpV6),
            }))
        }
    };

    #[cfg(not(target_os = "linux"))]
    let socket_queue = None;

    use socks5_impl::protocol::Version::{V4, V5};
    let mgr: Arc<dyn ProxyHandlerManager> = match args.proxy.proxy_type {
        ProxyType::Socks5 => Arc::new(SocksProxyManager::new(server_addr, V5, key)),
        ProxyType::Socks4 => Arc::new(SocksProxyManager::new(server_addr, V4, key)),
        ProxyType::Http => Arc::new(HttpManager::new(server_addr, key)),
        ProxyType::None => Arc::new(NoProxyManager::new()),
    };

    let mut ipstack_config = ipstack::IpStackConfig::default();
    ipstack_config.mtu(mtu)?;
    let mut tcp_cfg = ipstack::TcpConfig::default();
    tcp_cfg.timeout = std::time::Duration::from_secs(args.tcp_timeout);
    if let Some(mss) = args.tcp_mss {
        tcp_cfg.options = Some(vec![ipstack::TcpOptions::MaximumSegmentSize(mss)]);
    }
    ipstack_config.with_tcp_config(tcp_cfg);
    ipstack_config.udp_timeout(std::time::Duration::from_secs(args.udp_timeout));

    let mut ip_stack = ipstack::IpStack::new(ipstack_config, device);

    #[cfg(feature = "udpgw")]
    let udpgw_client = args.udpgw_server.map(|addr| {
        log::info!("UDP Gateway enabled, server: {addr}");
        use std::time::Duration;
        let client = Arc::new(UdpGwClient::new(
            mtu,
            args.udpgw_connections.unwrap_or(UDPGW_MAX_CONNECTIONS),
            args.udpgw_keepalive.map(Duration::from_secs).unwrap_or(UDPGW_KEEPALIVE_TIME),
            args.udp_timeout,
            addr,
        ));
        let client_keepalive = client.clone();
        let shutdown_clone = shutdown_token.clone();
        tokio::spawn(async move {
            if let Err(err) = client_keepalive.heartbeat_task(shutdown_clone).await {
                log::error!("UDP Gateway heartbeat task error: {err}");
            }
        });
        client
    });

    let session_metrics = args.session_metrics.clone().unwrap_or_default();
    let mut session_tasks = JoinSet::new();
    use std::sync::atomic::Ordering::Relaxed;

    loop {
        let tcp_metrics = session_metrics.clone();
        let udp_metrics = session_metrics.clone();
        let virtual_dns = virtual_dns.clone();
        let ip_stack_stream = tokio::select! {
            _ = shutdown_token.cancelled() => {
                log::info!("Shutdown received");
                break;
            }
            completed = session_tasks.join_next(), if !session_tasks.is_empty() => {
                if let Some(Err(error)) = completed {
                    log::error!("Session task failed: {error}");
                }
                continue;
            }
            ip_stack_stream = ip_stack.accept() => {
                ip_stack_stream?
            }
        };
        match ip_stack_stream {
            IpStackStream::Tcp(tcp) => {
                let max_sessions = args.tcp_max_sessions;
                if tcp_metrics.active_tcp.load(Relaxed) >= max_sessions {
                    if args.exit_on_fatal_error {
                        log::info!("Too many sessions that over {max_sessions}, exiting...");
                        break;
                    }
                    log::warn!("Too many sessions that over {max_sessions}, dropping new session");
                    tcp_metrics.dropped_tcp.fetch_add(1, Relaxed);
                    continue;
                }
                let active = tcp_metrics.active_tcp.fetch_add(1, Relaxed).saturating_add(1);
                log::trace!("TCP session count {active}");
                let guard = SessionGuard(tcp_metrics, IpProtocol::Tcp);
                let info = SessionInfo::new(tcp.local_addr(), tcp.peer_addr(), IpProtocol::Tcp);
                let domain_name = if let Some(virtual_dns) = &virtual_dns {
                    let mut virtual_dns = virtual_dns.lock().await;
                    virtual_dns.touch_ip(&tcp.peer_addr().ip());
                    virtual_dns.resolve_ip(&tcp.peer_addr().ip())
                } else {
                    None
                };
                let proxy_handler = mgr.new_proxy_handler(info, domain_name, false).await?;
                let socket_queue = socket_queue.clone();
                session_tasks.spawn(async move {
                    let _session = guard;
                    if let Err(err) = handle_tcp_session(tcp, proxy_handler, socket_queue).await {
                        log::error!("{info} error \"{err}\"");
                    }
                });
            }
            IpStackStream::Udp(udp) => {
                let mut max_sessions = args.udp_max_sessions;
                if udp.peer_addr().port() == DNS_PORT {
                    max_sessions = max_sessions.saturating_add(DNS_RESERVED_SESSIONS);
                }
                if udp_metrics.active_udp.load(Relaxed) >= max_sessions {
                    if args.exit_on_fatal_error {
                        log::info!("Too many sessions that over {max_sessions}, exiting...");
                        break;
                    }
                    log::warn!("Too many sessions that over {max_sessions}, dropping new session");
                    udp_metrics.dropped_udp.fetch_add(1, Relaxed);
                    continue;
                }
                let active = udp_metrics.active_udp.fetch_add(1, Relaxed).saturating_add(1);
                log::trace!("UDP session count {active}");
                let guard = SessionGuard(udp_metrics, IpProtocol::Udp);
                let mut info = SessionInfo::new(udp.local_addr(), udp.peer_addr(), IpProtocol::Udp);
                if info.dst.port() == DNS_PORT {
                    if is_private_ip(info.dst.ip()) {
                        info.dst.set_ip(dns_addr); // !!! Here we change the destination address to remote DNS server!!!
                    }
                    if args.dns == ArgDns::OverTcp {
                        info.protocol = IpProtocol::Tcp;
                        let proxy_handler = mgr.new_proxy_handler(info, None, false).await?;
                        let socket_queue = socket_queue.clone();
                        session_tasks.spawn(async move {
                            let _session = guard;
                            if let Err(err) = handle_dns_over_tcp_session(udp, proxy_handler, socket_queue, ipv6_enabled).await {
                                log::error!("{info} error \"{err}\"");
                            }
                        });
                        continue;
                    }
                    if args.dns == ArgDns::Virtual {
                        session_tasks.spawn(async move {
                            let _session = guard;
                            if let Some(virtual_dns) = virtual_dns {
                                if let Err(err) = handle_virtual_dns_session(udp, virtual_dns).await {
                                    log::error!("{info} error \"{err}\"");
                                }
                            }
                        });
                        continue;
                    }
                    assert_eq!(args.dns, ArgDns::Direct);
                }
                let domain_name = if let Some(virtual_dns) = &virtual_dns {
                    let mut virtual_dns = virtual_dns.lock().await;
                    virtual_dns.touch_ip(&udp.peer_addr().ip());
                    virtual_dns.resolve_ip(&udp.peer_addr().ip())
                } else {
                    None
                };
                #[cfg(feature = "udpgw")]
                if let Some(udpgw) = udpgw_client.clone() {
                    let tcp_src = match udp.peer_addr() {
                        SocketAddr::V4(_) => SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, 0)),
                        SocketAddr::V6(_) => SocketAddr::V6(SocketAddrV6::new(Ipv6Addr::UNSPECIFIED, 0, 0, 0)),
                    };
                    let tcpinfo = SessionInfo::new(tcp_src, udpgw.get_udpgw_server_addr(), IpProtocol::Tcp);
                    let proxy_handler = mgr.new_proxy_handler(tcpinfo, None, false).await?;
                    let queue = socket_queue.clone();
                    session_tasks.spawn(async move {
                        let _session = guard;
                        let dst = info.dst; // real UDP destination address
                        let dst_addr = match domain_name {
                            Some(ref d) => socks5_impl::protocol::Address::from((d.clone(), dst.port())),
                            None => dst.into(),
                        };
                        if let Err(e) = handle_udp_gateway_session(udp, udpgw, &dst_addr, proxy_handler, queue, ipv6_enabled).await {
                            log::info!("Ending {info} with \"{e}\"");
                        }
                    });
                    continue;
                }
                match mgr.new_proxy_handler(info, domain_name, true).await {
                    Ok(proxy_handler) => {
                        let socket_queue = socket_queue.clone();
                        session_tasks.spawn(async move {
                            let _session = guard;
                            let ty = args.proxy.proxy_type;
                            if let Err(err) = handle_udp_associate_session(udp, ty, proxy_handler, socket_queue, ipv6_enabled).await {
                                log::info!("Ending {info} with \"{err}\"");
                            }
                        });
                    }
                    Err(e) => {
                        log::error!("Failed to create UDP connection: {e}");
                    }
                }
            }
            IpStackStream::UnknownTransport(u) => {
                let len = u.payload().len();
                log::info!("#0 unhandled transport - Ip Protocol {:?}, length {}", u.ip_protocol(), len);
                continue;
            }
            IpStackStream::UnknownNetwork(pkt) => {
                log::info!("#0 unknown transport - {} bytes", pkt.len());
                continue;
            }
        }
    }
    let remaining = session_metrics.active_tcp.load(Relaxed) + session_metrics.active_udp.load(Relaxed);
    shutdown_sessions(&mut session_tasks).await;
    Ok(remaining)
}

async fn shutdown_sessions(session_tasks: &mut JoinSet<()>) {
    session_tasks.abort_all();
    while session_tasks.join_next().await.is_some() {}
}

// A UDP read needs room for a whole datagram: ipstack and the relay socket
// truncate a larger one. Reading into spare capacity commits memory only for the
// bytes received, so an idle session does not hold zero-filled 64 KiB buffers.
fn datagram_buffer() -> Vec<u8> {
    Vec::with_capacity(u16::MAX as usize)
}

async fn handle_virtual_dns_session(mut udp: IpStackUdpStream, dns: Arc<Mutex<VirtualDns>>) -> crate::Result<()> {
    let mut buf = datagram_buffer();
    loop {
        buf.clear();
        let len = match udp.read_buf(&mut buf).await {
            Err(e) => {
                // indicate UDP read fails not an error.
                log::debug!("Virtual DNS session error: {e}");
                break;
            }
            Ok(len) => len,
        };
        if len == 0 {
            break;
        }
        let (msg, qname, ip) = dns.lock().await.generate_query(&buf[..len])?;
        udp.write_all(&msg).await?;
        log::debug!("Virtual DNS query: {qname} -> {ip}");
    }
    Ok(())
}

async fn copy_and_record_traffic<R, W>(reader: &mut R, writer: &mut W, is_tx: bool) -> tokio::io::Result<u64>
where
    R: tokio::io::AsyncRead + Unpin + ?Sized,
    W: tokio::io::AsyncWrite + Unpin + ?Sized,
{
    let mut buf = vec![0; 8192];
    let mut total = 0;
    loop {
        match reader.read(&mut buf).await? {
            0 => break, // EOF
            n => {
                total += n as u64;
                let (tx, rx) = if is_tx { (n, 0) } else { (0, n) };
                if let Err(e) = crate::traffic_status::traffic_status_update(tx, rx) {
                    log::debug!("Record traffic status error: {e}");
                }
                writer.write_all(&buf[..n]).await?;
            }
        }
    }
    Ok(total)
}

async fn handle_tcp_session(
    mut tcp_stack: IpStackTcpStream,
    proxy_handler: Arc<Mutex<dyn ProxyHandler>>,
    socket_queue: Option<Arc<SocketQueue>>,
) -> crate::Result<()> {
    let (session_info, server_addr) = {
        let handler = proxy_handler.lock().await;

        (handler.get_session_info(), handler.get_server_addr())
    };

    let mut server = create_tcp_stream(&socket_queue, server_addr).await?;

    log::info!("Beginning {session_info}");

    if let Err(e) = handle_proxy_session(&mut server, proxy_handler).await {
        tcp_stack.shutdown().await?;
        return Err(e);
    }

    let (mut t_rx, mut t_tx) = tokio::io::split(tcp_stack);
    let (mut s_rx, mut s_tx) = tokio::io::split(server);

    let res = tokio::join!(
        async move {
            let r = copy_and_record_traffic(&mut t_rx, &mut s_tx, true).await;
            if let Err(err) = s_tx.shutdown().await {
                log::trace!("{session_info} s_tx shutdown error {err}");
            }
            r
        },
        async move {
            let r = copy_and_record_traffic(&mut s_rx, &mut t_tx, false).await;
            if let Err(err) = t_tx.shutdown().await {
                log::trace!("{session_info} t_tx shutdown error {err}");
            }
            r
        },
    );
    log::info!("Ending {session_info} with {res:?}");

    Ok(())
}

#[cfg(feature = "udpgw")]
async fn handle_udp_gateway_session(
    mut udp_stack: IpStackUdpStream,
    udpgw_client: Arc<UdpGwClient>,
    udp_dst: &socks5_impl::protocol::Address,
    proxy_handler: Arc<Mutex<dyn ProxyHandler>>,
    socket_queue: Option<Arc<SocketQueue>>,
    ipv6_enabled: bool,
) -> crate::Result<()> {
    let proxy_server_addr = { proxy_handler.lock().await.get_server_addr() };
    let udp_mtu = udpgw_client.get_udp_mtu();
    let udp_timeout = udpgw_client.get_udp_timeout();

    let mut stream = loop {
        match udpgw_client.pop_server_connection_from_queue().await {
            Some(stream) => {
                if stream.is_closed() {
                    continue;
                } else {
                    break stream;
                }
            }
            None => {
                let mut tcp_server_stream = create_tcp_stream(&socket_queue, proxy_server_addr).await?;
                if let Err(e) = handle_proxy_session(&mut tcp_server_stream, proxy_handler).await {
                    return Err(format!("udpgw connection error: {e}").into());
                }
                break UdpGwClientStream::new(tcp_server_stream);
            }
        }
    };

    let tcp_local_addr = stream.local_addr();
    let sn = stream.serial_number();

    log::info!("[UdpGw] Beginning stream {} {} -> {}", sn, tcp_local_addr, udp_dst);

    let Some(mut reader) = stream.get_reader() else {
        return Err("get reader failed".into());
    };

    let Some(mut writer) = stream.get_writer() else {
        return Err("get writer failed".into());
    };

    let mut tmp_buf = vec![0; udp_mtu.into()];

    loop {
        tokio::select! {
            len = udp_stack.read(&mut tmp_buf) => {
                let read_len = match len {
                    Ok(0) => {
                        log::info!("[UdpGw] Ending stream {} {} <> {}", sn, tcp_local_addr, udp_dst);
                        break;
                    }
                    Ok(n) => n,
                    Err(e) => {
                        log::info!("[UdpGw] Ending stream {} {} <> {} with udp stack \"{}\"", sn, tcp_local_addr, udp_dst, e);
                        break;
                    }
                };
                crate::traffic_status::traffic_status_update(read_len, 0)?;
                let sn = stream.serial_number();
                if let Err(e) = UdpGwClient::send_udpgw_packet(ipv6_enabled, &tmp_buf[0..read_len], udp_dst, sn, &mut writer).await {
                    log::info!("[UdpGw] Ending stream {} {} <> {} with send_udpgw_packet {}", sn, tcp_local_addr, udp_dst, e);
                    break;
                }
                log::debug!("[UdpGw] stream {} {} -> {} send len {}", sn, tcp_local_addr, udp_dst, read_len);
                stream.update_activity();
            }
            ret = UdpGwClient::recv_udpgw_packet(udp_mtu, udp_timeout, &mut reader) => {
                if let Ok((len, _)) = ret {
                    crate::traffic_status::traffic_status_update(0, len)?;
                }
                match ret {
                    Err(e) => {
                        log::warn!("[UdpGw] Ending stream {} {} <> {} with recv_udpgw_packet {}", sn, tcp_local_addr, udp_dst, e);
                        stream.close();
                        break;
                    }
                    Ok((_, packet)) => match packet {
                        //should not received keepalive
                        UdpGwResponse::KeepAlive => {
                            log::error!("[UdpGw] Ending stream {} {} <> {} with recv keepalive", sn, tcp_local_addr, udp_dst);
                            stream.close();
                            break;
                        }
                        //server udp may be timeout,can continue to receive udp data?
                        UdpGwResponse::Error => {
                            log::info!("[UdpGw] Ending stream {} {} <> {} with recv udp error", sn, tcp_local_addr, udp_dst);
                            stream.update_activity();
                            continue;
                        }
                        UdpGwResponse::TcpClose => {
                            log::error!("[UdpGw] Ending stream {} {} <> {} with tcp closed", sn, tcp_local_addr, udp_dst);
                            stream.close();
                            break;
                        }
                        UdpGwResponse::Data(data) => {
                            use socks5_impl::protocol::StreamOperation;
                            let len = data.len();
                            let f = data.header.flags;
                            log::debug!("[UdpGw] stream {sn} {} <- {} receive {f} len {len}", tcp_local_addr, udp_dst);
                            if let Err(e) = udp_stack.write_all(&data.data).await {
                                log::error!("[UdpGw] Ending stream {} {} <> {} with send_udp_packet {}", sn, tcp_local_addr, udp_dst, e);
                                break;
                            }
                        }
                    }
                }
                stream.update_activity();
            }
        }
    }

    if !stream.is_closed() {
        udpgw_client.store_server_connection_full(stream, reader, writer).await;
    }

    Ok(())
}

async fn handle_udp_associate_session(
    mut udp_stack: IpStackUdpStream,
    proxy_type: ProxyType,
    proxy_handler: Arc<Mutex<dyn ProxyHandler>>,
    socket_queue: Option<Arc<SocketQueue>>,
    ipv6_enabled: bool,
) -> crate::Result<()> {
    use socks5_impl::protocol::{Address, StreamOperation, UdpHeader};

    let (session_info, server_addr, domain_name, udp_addr) = {
        let handler = proxy_handler.lock().await;
        (
            handler.get_session_info(),
            handler.get_server_addr(),
            handler.get_domain_name(),
            handler.get_udp_associate(),
        )
    };

    log::info!("Beginning {session_info}");

    // The association ends when its control connection closes. Keeping only
    // the socket alive would leave UDP sending to an obsolete relay after a
    // proxy restart, even when the SOCKS listener reuses the same TCP port.
    let (mut server, udp_addr) = match udp_addr {
        Some(udp_addr) => (None, udp_addr),
        None => {
            let mut server = create_tcp_stream(&socket_queue, server_addr).await?;
            let udp_addr = handle_proxy_session(&mut server, proxy_handler).await?;
            (Some(server), udp_addr.ok_or("udp associate failed")?)
        }
    };

    let udp_server = create_udp_stream(&socket_queue, udp_addr).await?;

    let mut buf1 = datagram_buffer();
    let mut buf2 = datagram_buffer();
    let mut control_buffer = [0_u8; 1];
    loop {
        buf1.clear();
        buf2.clear();
        tokio::select! {
            len = async {
                match server.as_mut() {
                    Some(server) => server.read(&mut control_buffer).await,
                    None => std::future::pending().await,
                }
            } => {
                if len? == 0 { break; }
            }
            len = udp_stack.read_buf(&mut buf1) => {
                let len = len?;
                if len == 0 {
                    break;
                }
                let buf1 = &buf1[..len];

                crate::traffic_status::traffic_status_update(len, 0)?;

                if let ProxyType::Socks4 | ProxyType::Socks5 = proxy_type {
                    let s5addr = if let Some(domain_name) = &domain_name {
                        Address::DomainAddress(domain_name.clone().into(), session_info.dst.port())
                    } else {
                        session_info.dst.into()
                    };

                    // Add SOCKS5 UDP header to the incoming data
                    let mut s5_udp_data = Vec::<u8>::new();
                    UdpHeader::new(0, s5addr).write_to_stream(&mut s5_udp_data)?;
                    s5_udp_data.extend_from_slice(buf1);

                    udp_server.send(&s5_udp_data).await?;
                } else {
                    udp_server.send(buf1).await?;
                }
            }
            len = udp_server.recv_buf(&mut buf2) => {
                let len = len?;
                if len == 0 {
                    break;
                }
                let buf2 = &buf2[..len];

                crate::traffic_status::traffic_status_update(0, len)?;

                if let ProxyType::Socks4 | ProxyType::Socks5 = proxy_type {
                    // Remove SOCKS5 UDP header from the server data
                    let header = UdpHeader::retrieve_from_stream(&mut &buf2[..])?;
                    let data = &buf2[header.len()..];

                    let buf = if session_info.dst.port() == DNS_PORT {
                        let mut message = dns::parse_data_to_dns_message(data, false)?;
                        if !ipv6_enabled {
                            dns::remove_ipv6_entries(&mut message);
                        }
                        message.to_vec()?
                    } else {
                        data.to_vec()
                    };

                    udp_stack.write_all(&buf).await?;
                } else {
                    udp_stack.write_all(buf2).await?;
                }
            }
        }
    }

    log::info!("Ending {session_info}");

    Ok(())
}

async fn handle_dns_over_tcp_session(
    mut udp_stack: IpStackUdpStream,
    proxy_handler: Arc<Mutex<dyn ProxyHandler>>,
    socket_queue: Option<Arc<SocketQueue>>,
    ipv6_enabled: bool,
) -> crate::Result<()> {
    let (session_info, server_addr) = {
        let handler = proxy_handler.lock().await;

        (handler.get_session_info(), handler.get_server_addr())
    };

    let mut server = create_tcp_stream(&socket_queue, server_addr).await?;

    log::info!("Beginning {session_info}");

    let _ = handle_proxy_session(&mut server, proxy_handler).await?;

    let mut buf1 = datagram_buffer();
    let mut buf2 = [0_u8; 4096];
    let mut pending = Vec::new();
    // Elarni: the session ends with the answer to its last query; it held a proxy connection for the whole UDP timeout.
    let mut unanswered = 0_usize;
    let idle = tokio::time::sleep(DNS_TIMEOUT);
    tokio::pin!(idle);
    loop {
        buf1.clear();
        tokio::select! {
            _ = &mut idle => break,
            len = udp_stack.read_buf(&mut buf1) => {
                let len = len?;
                if len == 0 {
                    break;
                }
                let buf1 = &buf1[..len];

                _ = dns::parse_data_to_dns_message(buf1, false)?;

                // Insert the DNS message length in front of the payload
                let len = u16::try_from(buf1.len())?;
                let mut buf = Vec::with_capacity(std::mem::size_of::<u16>() + usize::from(len));
                buf.extend_from_slice(&len.to_be_bytes());
                buf.extend_from_slice(buf1);

                server.write_all(&buf).await?;
                unanswered += 1;
                idle.as_mut().reset(tokio::time::Instant::now() + DNS_TIMEOUT);

                crate::traffic_status::traffic_status_update(buf.len(), 0)?;
            }
            len = server.read(&mut buf2) => {
                let len = len?;
                if len == 0 {
                    break;
                }
                pending.extend_from_slice(&buf2[..len]);

                crate::traffic_status::traffic_status_update(0, len)?;

                let mut to_send: VecDeque<Vec<u8>> = VecDeque::new();
                loop {
                    if pending.len() < 2 {
                        break;
                    }
                    let len = u16::from_be_bytes([pending[0], pending[1]]) as usize;
                    if pending.len() < len + 2 {
                        break;
                    }

                    // remove the length field
                    let data = pending[2..len + 2].to_vec();
                    pending.drain(..len + 2);

                    let mut message = dns::parse_data_to_dns_message(&data, false)?;

                    let name = dns::extract_domain_from_dns_message(&message)?;
                    let ip = dns::extract_ipaddr_from_dns_message(&message);
                    log::trace!("DNS over TCP query result: {name} -> {ip:?}");

                    if !ipv6_enabled {
                        dns::remove_ipv6_entries(&mut message);
                    }

                    to_send.push_back(message.to_vec()?);
                }

                while let Some(packet) = to_send.pop_front() {
                    udp_stack.write_all(&packet).await?;
                    unanswered = unanswered.saturating_sub(1);
                }
                if unanswered == 0 {
                    break;
                }
                idle.as_mut().reset(tokio::time::Instant::now() + DNS_TIMEOUT);
            }
        }
    }

    log::info!("Ending {session_info}");

    Ok(())
}

/// This function is used to handle the business logic of tun2proxy and SOCKS5 server.
/// When handling UDP proxy, the return value UDP associate IP address is the result of this business logic.
/// However, when handling TCP business logic, the return value Ok(None) is meaningless, just indicating that the operation was successful.
async fn handle_proxy_session(server: &mut TcpStream, proxy_handler: Arc<Mutex<dyn ProxyHandler>>) -> crate::Result<Option<SocketAddr>> {
    let mut launched = false;
    let mut proxy_handler = proxy_handler.lock().await;
    let dir = OutgoingDirection::ToServer;
    let (mut tx, mut rx) = (0, 0);

    loop {
        if proxy_handler.connection_established() {
            break;
        }

        if !launched {
            let data = proxy_handler.peek_data(dir).buffer;
            let len = data.len();
            if len == 0 {
                return Err("proxy_handler launched went wrong".into());
            }
            server.write_all(data).await?;
            proxy_handler.consume_data(dir, len);
            tx += len;

            launched = true;
        }

        let mut buf = [0_u8; 4096];
        let len = server.read(&mut buf).await?;
        if len == 0 {
            return Err("server closed accidentially".into());
        }
        rx += len;
        let event = IncomingDataEvent {
            direction: IncomingDirection::FromServer,
            buffer: &buf[..len],
        };
        proxy_handler.push_data(event).await?;

        let data = proxy_handler.peek_data(dir).buffer;
        let len = data.len();
        if len > 0 {
            server.write_all(data).await?;
            proxy_handler.consume_data(dir, len);
            tx += len;
        }
    }
    crate::traffic_status::traffic_status_update(tx, rx)?;
    Ok(proxy_handler.get_udp_associate())
}

#[cfg(test)]
mod tests {
    // The std checks answer like tproxy-config's regexes for every kind of address a DNS query can target.
    #[test]
    fn private_ip_matches_tproxy_config() {
        for ip in [
            "10.1.2.3",
            "172.16.0.1",
            "172.31.255.255",
            "172.32.0.1",
            "192.168.1.1",
            "127.0.0.1",
            "169.254.1.1",
            "198.18.0.1",
            "198.19.255.255",
            "198.20.0.1",
            "8.8.8.8",
            "1.1.1.1",
            "100.64.0.1",
            "0.0.0.0",
            "::",
            "::1",
            "fc00::1",
            "fd12:3456::1",
            "fe80::1",
            "fe80:1::1",
            "fec0::1",
            "fbff::1",
            "2001:2::1",
            "2001:db8::1",
            "2606:4700::1111",
            "::ffff:10.0.0.1",
            "::ffff:192.168.0.1",
            "::ffff:172.20.0.1",
            "::ffff:127.0.0.1",
            "::ffff:169.254.0.1",
            "::ffff:198.18.0.1",
            "::ffff:8.8.8.8",
            "::10.0.0.1",
            "64:ff9b::a00:1",
        ] {
            let ip: std::net::IpAddr = ip.parse().unwrap();
            assert_eq!(super::is_private_ip(ip), tproxy_config::is_private_ip(ip), "{ip}");
        }
    }
}
