use crate::{
    directions::{IncomingDataEvent, IncomingDirection, OutgoingDataEvent, OutgoingDirection},
    error::{Error, Result},
    proxy_handler::{ProxyHandler, ProxyHandlerManager},
    session_info::SessionInfo,
};
use socks5_impl::protocol::{self, Address, AuthMethod, StreamOperation, UserKey, handshake, password_method};
use std::{collections::VecDeque, net::SocketAddr, sync::Arc};
use tokio::sync::Mutex;

#[derive(Eq, PartialEq, Debug)]
enum SocksState {
    ClientHello,
    ServerHello,
    SendAuthData,
    ReceiveAuthResponse,
    SendRequest,
    ReceiveResponse,
    Established,
}

struct SocksProxyImpl {
    server_addr: SocketAddr,
    info: SessionInfo,
    state: SocksState,
    client_inbuf: VecDeque<u8>,
    server_inbuf: VecDeque<u8>,
    client_outbuf: VecDeque<u8>,
    server_outbuf: VecDeque<u8>,
    credentials: Option<UserKey>,
    command: protocol::Command,
    udp_associate: Option<SocketAddr>,
}

fn udp_relay_addr(server_addr: SocketAddr, relay_addr: SocketAddr) -> SocketAddr {
    if relay_addr.ip().is_unspecified() {
        SocketAddr::new(server_addr.ip(), relay_addr.port())
    } else {
        relay_addr
    }
}

impl SocksProxyImpl {
    fn new(server_addr: SocketAddr, info: SessionInfo, credentials: Option<UserKey>, command: protocol::Command) -> Result<Self> {
        let mut result = Self {
            server_addr,
            info,
            state: SocksState::ClientHello,
            client_inbuf: VecDeque::default(),
            server_inbuf: VecDeque::default(),
            client_outbuf: VecDeque::default(),
            server_outbuf: VecDeque::default(),
            credentials,
            command,
            udp_associate: None,
        };
        result.send_client_hello()?;
        Ok(result)
    }

    fn send_client_hello_socks5(&mut self) -> Result<(), Error> {
        let credentials = &self.credentials;
        let mut methods = vec![AuthMethod::NoAuth, AuthMethod::from(4_u8), AuthMethod::from(100_u8)];
        if credentials.is_some() {
            methods.push(AuthMethod::UserPass);
        }
        handshake::Request::new(methods).write_to_stream(&mut self.server_outbuf)?;
        Ok(())
    }

    fn send_client_hello(&mut self) -> Result<(), Error> {
        self.send_client_hello_socks5()?;
        self.state = SocksState::ServerHello;
        Ok(())
    }

    fn receive_server_hello_socks5(&mut self) -> std::io::Result<()> {
        let response = handshake::Response::retrieve_from_stream(&mut self.server_inbuf.clone());
        if let Err(e) = response {
            if e.kind() == std::io::ErrorKind::UnexpectedEof {
                log::trace!("receive_server_hello_socks5 needs more data \"{e}\"...");
                return Ok(());
            } else {
                return Err(e);
            }
        }
        let respones = response?;
        self.server_inbuf.drain(0..respones.len());
        let auth_method = respones.method;

        if auth_method != AuthMethod::NoAuth && self.credentials.is_none()
            || (auth_method != AuthMethod::NoAuth && auth_method != AuthMethod::UserPass) && self.credentials.is_some()
        {
            return Err(crate::Error::from("SOCKS5 server requires an unsupported authentication method.").into());
        }

        self.state = if auth_method == AuthMethod::UserPass {
            SocksState::SendAuthData
        } else {
            SocksState::SendRequest
        };
        self.state_change()
    }

    fn send_auth_data(&mut self) -> std::io::Result<()> {
        let tmp = UserKey::default();
        let credentials = self.credentials.as_ref().unwrap_or(&tmp);

        const SESSION_INFO_MARKER: &str = "+info";
        let username = if credentials.username.ends_with(SESSION_INFO_MARKER) {
            let base_username = &credentials.username[..credentials.username.len() - SESSION_INFO_MARKER.len()];
            let proto = match self.command {
                protocol::Command::Connect => "tcp",
                protocol::Command::UdpAssociate => "udp",
                _ => "unknown",
            };
            format!("{}|{}|{}|{}", base_username, proto, self.info.src.ip(), self.info.src.port())
        } else {
            credentials.username.clone()
        };

        let request = password_method::Request::new(&username, &credentials.password);
        request.write_to_stream(&mut self.server_outbuf)?;
        self.state = SocksState::ReceiveAuthResponse;
        Ok(())
    }

    fn receive_auth_data(&mut self) -> std::io::Result<()> {
        use password_method::Response;
        let response = Response::retrieve_from_stream(&mut self.server_inbuf.clone());
        if let Err(e) = response {
            if e.kind() == std::io::ErrorKind::UnexpectedEof {
                log::trace!("receive_auth_data needs more data \"{e}\"...");
                return Ok(());
            } else {
                return Err(e);
            }
        }
        let response = response?;
        self.server_inbuf.drain(0..response.len());
        if response.status != password_method::Status::Succeeded {
            return Err(crate::Error::from(format!("SOCKS authentication failed: {:?}", response.status)).into());
        }
        self.state = SocksState::SendRequest;
        self.state_change()
    }

    fn send_request_socks5(&mut self) -> std::io::Result<()> {
        let addr = if self.command == protocol::Command::UdpAssociate {
            Address::unspecified()
        } else {
            self.info.dst.into()
        };
        protocol::Request::new(self.command, addr).write_to_stream(&mut self.server_outbuf)?;
        self.state = SocksState::ReceiveResponse;
        Ok(())
    }

    fn receive_connection_status(&mut self) -> std::io::Result<()> {
        let response = protocol::Response::retrieve_from_stream(&mut self.server_inbuf.clone());
        if let Err(e) = response {
            if e.kind() == std::io::ErrorKind::UnexpectedEof {
                log::trace!("receive_connection_status needs more data \"{e}\"...");
                return Ok(());
            } else {
                return Err(e);
            }
        }
        let response = response?;
        self.server_inbuf.drain(0..response.len());
        if response.reply != protocol::Reply::Succeeded {
            return Err(crate::Error::from(format!("SOCKS connection failed: {}", response.reply)).into());
        }
        if self.command == protocol::Command::UdpAssociate {
            self.udp_associate = Some(udp_relay_addr(self.server_addr, SocketAddr::try_from(&response.address)?));
            // log::trace!("UDP associate recieved address {}", response.address);
        }

        self.state = SocksState::Established;
        Ok(())
    }

    fn relay_traffic(&mut self) -> Result<(), Error> {
        self.client_outbuf.extend(self.server_inbuf.iter());
        self.server_outbuf.extend(self.client_inbuf.iter());
        self.server_inbuf.clear();
        self.client_inbuf.clear();
        Ok(())
    }

    fn state_change(&mut self) -> std::io::Result<()> {
        match self.state {
            SocksState::ServerHello => self.receive_server_hello_socks5()?,

            SocksState::SendAuthData => self.send_auth_data()?,

            SocksState::ReceiveAuthResponse => self.receive_auth_data()?,

            SocksState::SendRequest => self.send_request_socks5()?,

            SocksState::ReceiveResponse => self.receive_connection_status()?,

            SocksState::Established => self.relay_traffic()?,

            _ => {}
        }
        Ok(())
    }
}

#[async_trait::async_trait]
impl ProxyHandler for SocksProxyImpl {
    fn get_server_addr(&self) -> SocketAddr {
        self.server_addr
    }

    fn get_session_info(&self) -> SessionInfo {
        self.info
    }

    async fn push_data(&mut self, event: IncomingDataEvent<'_>) -> std::io::Result<()> {
        let IncomingDataEvent { direction, buffer } = event;
        match direction {
            IncomingDirection::FromServer => {
                self.server_inbuf.extend(buffer.iter());
            }
            IncomingDirection::FromClient => {
                self.client_inbuf.extend(buffer.iter());
            }
        }

        self.state_change()
    }

    fn consume_data(&mut self, dir: OutgoingDirection, size: usize) {
        let buffer = match dir {
            OutgoingDirection::ToServer => &mut self.server_outbuf,
            OutgoingDirection::ToClient => &mut self.client_outbuf,
        };
        buffer.drain(0..size);
    }

    fn peek_data(&mut self, dir: OutgoingDirection) -> OutgoingDataEvent<'_> {
        let buffer = match dir {
            OutgoingDirection::ToServer => &mut self.server_outbuf,
            OutgoingDirection::ToClient => &mut self.client_outbuf,
        };
        OutgoingDataEvent {
            direction: dir,
            buffer: buffer.make_contiguous(),
        }
    }

    fn connection_established(&self) -> bool {
        self.state == SocksState::Established
    }

    fn data_len(&self, dir: OutgoingDirection) -> usize {
        match dir {
            OutgoingDirection::ToServer => self.server_outbuf.len(),
            OutgoingDirection::ToClient => self.client_outbuf.len(),
        }
    }

    fn reset_connection(&self) -> bool {
        false
    }

    fn get_udp_associate(&self) -> Option<SocketAddr> {
        self.udp_associate
    }
}

pub(crate) struct SocksProxyManager {
    server: SocketAddr,
    credentials: Option<UserKey>,
}

#[async_trait::async_trait]
impl ProxyHandlerManager for SocksProxyManager {
    async fn new_proxy_handler(&self, info: SessionInfo, udp_associate: bool) -> std::io::Result<Arc<Mutex<dyn ProxyHandler>>> {
        use socks5_impl::protocol::Command::{Connect, UdpAssociate};
        let command = if udp_associate { UdpAssociate } else { Connect };
        let credentials = self.credentials.clone();
        Ok(Arc::new(Mutex::new(SocksProxyImpl::new(self.server, info, credentials, command)?)))
    }
}

impl SocksProxyManager {
    pub(crate) fn new(server: SocketAddr, credentials: Option<UserKey>) -> Self {
        Self { server, credentials }
    }
}
