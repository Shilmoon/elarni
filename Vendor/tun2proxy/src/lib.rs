//! Elarni: only what the Apple packet bridge runs is kept: SOCKS5 sessions and DNS over TCP. The
//! command-line programs, the HTTP and SOCKS4 proxies, virtual DNS, the UDP gateway, socket
//! transfer between namespaces and the Android and Windows service entry points are removed.

use crate::{
    directions::{IncomingDataEvent, IncomingDirection, OutgoingDirection},
    session_info::{IpProtocol, SessionInfo},
};
use ipstack::{IpStackStream, IpStackTcpStream, IpStackUdpStream};
use proxy_handler::{ProxyHandler, ProxyHandlerManager};
use socks::SocksProxyManager;
pub use socks5_impl::protocol::UserKey;
use std::{
    collections::VecDeque,
    net::{IpAddr, SocketAddr},
    sync::Arc,
};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt},
    net::{TcpStream, UdpSocket},
    sync::Mutex,
    task::JoinSet,
};
pub use tokio_util::sync::CancellationToken;

pub use {
    args::{ArgDns, ArgProxy, Args},
    error::{BoxError, Error, Result},
    traffic_status::{TrafficStatus, tun2proxy_set_traffic_status_callback},
};

mod args;
mod directions;
mod dns;
mod error;
mod proxy_handler;
mod session_info;
mod socks;
mod traffic_status;

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

async fn create_tcp_stream(peer: SocketAddr) -> std::io::Result<TcpStream> {
    let stream = TcpStream::connect(peer).await?;
    // Elarni: Nagle held a small write behind an unacknowledged one on the proxy leg.
    let _ = stream.set_nodelay(true);
    Ok(stream)
}

async fn create_udp_stream(peer: SocketAddr) -> std::io::Result<UdpSocket> {
    let bind_addr = match peer {
        SocketAddr::V4(_) => SocketAddr::from((std::net::Ipv4Addr::UNSPECIFIED, 0)),
        SocketAddr::V6(_) => SocketAddr::from((std::net::Ipv6Addr::UNSPECIFIED, 0)),
    };
    let socket = UdpSocket::bind(bind_addr).await?;
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
    log::info!("{} {} starting...", env!("CARGO_PKG_NAME"), env!("CARGO_PKG_VERSION"));
    log::info!("Proxy socks5 server: {}", args.proxy.addr);

    let server_addr = args.proxy.addr;
    let key = args.proxy.credentials.clone();
    let dns_addr = args.dns_addr;
    let ipv6_enabled = args.ipv6_enabled;

    let mgr: Arc<dyn ProxyHandlerManager> = Arc::new(SocksProxyManager::new(server_addr, key));

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

    let session_metrics = args.session_metrics.clone().unwrap_or_default();
    let mut session_tasks = JoinSet::new();
    use std::sync::atomic::Ordering::Relaxed;

    loop {
        let tcp_metrics = session_metrics.clone();
        let udp_metrics = session_metrics.clone();
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
                let proxy_handler = mgr.new_proxy_handler(info, false).await?;
                session_tasks.spawn(async move {
                    let _session = guard;
                    if let Err(err) = handle_tcp_session(tcp, proxy_handler).await {
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
                        let proxy_handler = mgr.new_proxy_handler(info, false).await?;
                        session_tasks.spawn(async move {
                            let _session = guard;
                            if let Err(err) = handle_dns_over_tcp_session(udp, proxy_handler, ipv6_enabled).await {
                                log::error!("{info} error \"{err}\"");
                            }
                        });
                        continue;
                    }
                    assert_eq!(args.dns, ArgDns::Direct);
                }
                match mgr.new_proxy_handler(info, true).await {
                    Ok(proxy_handler) => {
                        session_tasks.spawn(async move {
                            let _session = guard;
                            if let Err(err) = handle_udp_associate_session(udp, proxy_handler, ipv6_enabled).await {
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

async fn handle_tcp_session(mut tcp_stack: IpStackTcpStream, proxy_handler: Arc<Mutex<dyn ProxyHandler>>) -> crate::Result<()> {
    let (session_info, server_addr) = {
        let handler = proxy_handler.lock().await;

        (handler.get_session_info(), handler.get_server_addr())
    };

    let mut server = create_tcp_stream(server_addr).await?;

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

async fn handle_udp_associate_session(
    mut udp_stack: IpStackUdpStream,
    proxy_handler: Arc<Mutex<dyn ProxyHandler>>,
    ipv6_enabled: bool,
) -> crate::Result<()> {
    use socks5_impl::protocol::{StreamOperation, UdpHeader};

    let (session_info, server_addr, udp_addr) = {
        let handler = proxy_handler.lock().await;
        (handler.get_session_info(), handler.get_server_addr(), handler.get_udp_associate())
    };

    log::info!("Beginning {session_info}");

    // The association ends when its control connection closes. Keeping only
    // the socket alive would leave UDP sending to an obsolete relay after a
    // proxy restart, even when the SOCKS listener reuses the same TCP port.
    let (mut server, udp_addr) = match udp_addr {
        Some(udp_addr) => (None, udp_addr),
        None => {
            let mut server = create_tcp_stream(server_addr).await?;
            let udp_addr = handle_proxy_session(&mut server, proxy_handler).await?;
            (Some(server), udp_addr.ok_or("udp associate failed")?)
        }
    };

    let udp_server = create_udp_stream(udp_addr).await?;

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

                // Add SOCKS5 UDP header to the incoming data
                let mut s5_udp_data = Vec::<u8>::new();
                UdpHeader::new(0, session_info.dst.into()).write_to_stream(&mut s5_udp_data)?;
                s5_udp_data.extend_from_slice(buf1);

                udp_server.send(&s5_udp_data).await?;
            }
            len = udp_server.recv_buf(&mut buf2) => {
                let len = len?;
                if len == 0 {
                    break;
                }
                let buf2 = &buf2[..len];

                crate::traffic_status::traffic_status_update(0, len)?;

                // Remove SOCKS5 UDP header from the server data
                let header = UdpHeader::retrieve_from_stream(&mut &buf2[..])?;
                let data = &buf2[header.len()..];

                // Elarni: only an answer that loses its IPv6 records is parsed and rebuilt; the rest
                // goes on as received, without a copy.
                if session_info.dst.port() == DNS_PORT && !ipv6_enabled {
                    let mut message = dns::parse_data_to_dns_message(data, false)?;
                    dns::remove_ipv6_entries(&mut message);
                    udp_stack.write_all(&message.to_vec()?).await?;
                } else {
                    udp_stack.write_all(data).await?;
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
    ipv6_enabled: bool,
) -> crate::Result<()> {
    let (session_info, server_addr) = {
        let handler = proxy_handler.lock().await;

        (handler.get_session_info(), handler.get_server_addr())
    };

    let mut server = create_tcp_stream(server_addr).await?;

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

                    // Elarni: an answer is parsed only to drop its IPv6 records or for the trace line, not
                    // to be rebuilt unchanged, which also ended the session on an answer the parser rejects.
                    if ipv6_enabled && !log::log_enabled!(log::Level::Trace) {
                        to_send.push_back(data);
                        continue;
                    }
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
