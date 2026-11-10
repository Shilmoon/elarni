use crate::{Error, Result};
use socks5_impl::protocol::UserKey;

use std::net::{IpAddr, SocketAddr, ToSocketAddrs};

/// What [`crate::run`] is started with.
/// Elarni: the options of the command-line program, of virtual DNS, of the UDP gateway and of the
/// route setup went with those parts; the packet bridge is the only caller.
#[derive(Debug, Clone)]
pub struct Args {
    /// The SOCKS5 server every session goes to.
    pub proxy: ArgProxy,

    /// IPv6 enabled
    pub ipv6_enabled: bool,

    /// DNS handling strategy
    pub dns: ArgDns,

    /// DNS resolver address
    pub dns_addr: IpAddr,

    /// TCP timeout in seconds
    pub tcp_timeout: u64,

    /// MSS advertised in the SYN-ACK to the kernel side. By default the userspace
    /// stack sends no MSS option, so the peer OS falls back to its own default
    /// (e.g. 512 on macOS), fragmenting large first segments such as a TLS
    /// ClientHello. Set this to the tunnel's (MTU - 40) to let the peer send big
    /// segments. `None` keeps the previous behaviour (no option advertised).
    pub tcp_mss: Option<u16>,

    /// UDP timeout in seconds
    pub udp_timeout: u64,

    /// Exit immediately when fatal error occurs, useful for running as a service
    pub exit_on_fatal_error: bool,

    /// Maximum concurrent TCP sessions.
    pub tcp_max_sessions: usize,

    /// Maximum concurrent UDP sessions.
    pub udp_max_sessions: usize,

    pub session_metrics: Option<std::sync::Arc<crate::SessionMetrics>>,
}

impl Default for Args {
    fn default() -> Self {
        Args {
            proxy: ArgProxy::default(),
            ipv6_enabled: false,
            dns: ArgDns::default(),
            dns_addr: "8.8.8.8".parse().unwrap(),
            tcp_timeout: 600,
            tcp_mss: None,
            udp_timeout: 10,
            exit_on_fatal_error: false,
            tcp_max_sessions: 200,
            udp_max_sessions: 200,
            session_metrics: None,
        }
    }
}

/// DNS query handling strategy
/// - OverTcp: Use TCP to send DNS queries to the DNS server
/// - Direct: Do not handle DNS by relying on DNS server bypassing
#[derive(Default, Debug, Copy, Clone, PartialEq, Eq)]
pub enum ArgDns {
    OverTcp,
    #[default]
    Direct,
}

/// A SOCKS5 server and what it asks of a client.
#[derive(Clone, Debug)]
pub struct ArgProxy {
    pub addr: SocketAddr,
    pub credentials: Option<UserKey>,
}

impl Default for ArgProxy {
    fn default() -> Self {
        ArgProxy {
            addr: "127.0.0.1:1080".parse().unwrap(),
            credentials: None,
        }
    }
}

/// A URL in the form socks5://[username[:password]@]host:port, with the username and the password
/// in percent encoding, for example socks5://myname:pass%40word@127.0.0.1:1080
impl TryFrom<&str> for ArgProxy {
    type Error = Error;
    fn try_from(s: &str) -> Result<Self> {
        let e = format!("`{s}` is not a valid proxy URL");
        let url = url::Url::parse(s).map_err(|_| Error::from(&e))?;
        let e = format!("`{s}` does not contain a host");
        let host = url.host_str().ok_or(Error::from(e))?;

        let e = format!("`{s}` does not contain a port");
        let port = url.port_or_known_default().ok_or(Error::from(&e))?;

        let e2 = format!("`{host}` does not resolve to a usable IP address");
        let addr = (host, port).to_socket_addrs()?.next().ok_or(Error::from(&e2))?;

        let credentials = if url.username() == "" && url.password().is_none() {
            None
        } else {
            use percent_encoding::percent_decode;
            let username = percent_decode(url.username().as_bytes()).decode_utf8()?;
            let password = percent_decode(url.password().unwrap_or("").as_bytes()).decode_utf8()?;
            Some(UserKey::new(username, password))
        };

        if url.scheme() != "socks5" {
            return Err(Error::from(&format!("`{}` is an invalid proxy type", url.scheme())));
        }

        Ok(ArgProxy { addr, credentials })
    }
}
