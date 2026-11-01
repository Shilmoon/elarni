use crate::error::IpStackError;
use etherparse::{
    IpFragOffset, IpNumber, Ipv4Header, Ipv6ExtensionSlice, Ipv6Header, NetSlice, SlicedPacket, TcpHeader, UdpHeader, defrag::IpDefragBuf,
};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::time::{Duration, Instant};

type FragmentKey = (IpAddr, IpAddr, u32, IpNumber);

pub(crate) struct FragmentReassembler {
    active: ahash::AHashMap<FragmentKey, (Option<IpDefragBuf>, Instant)>,
}

impl FragmentReassembler {
    pub(crate) fn new() -> Self {
        Self {
            active: ahash::AHashMap::new(),
        }
    }

    pub(crate) fn expire(&mut self) {
        self.active.retain(|_, (_, started)| started.elapsed() < Duration::from_secs(60));
    }

    pub(crate) fn is_empty(&self) -> bool {
        self.active.is_empty()
    }

    pub(crate) fn parse(&mut self, bytes: &[u8]) -> Result<Option<NetworkPacket>, IpStackError> {
        let sliced = SlicedPacket::from_ip(bytes).map_err(|_| IpStackError::InvalidPacket)?;
        let (mut ip, key, offset, more, payload) = match sliced.net.as_ref() {
            Some(NetSlice::Ipv4(ip)) if ip.header().is_fragmenting_payload() => {
                let h = ip.header();
                (
                    IpHeader::Ipv4(h.to_header()),
                    (
                        IpAddr::V4(h.source().into()),
                        IpAddr::V4(h.destination().into()),
                        u32::from(h.identification()),
                        ip.payload().ip_number,
                    ),
                    h.fragments_offset(),
                    h.more_fragments(),
                    ip.payload().payload,
                )
            }
            Some(NetSlice::Ipv6(ip)) => {
                let fragment = ip.extensions().clone().into_iter().find_map(|ext| match ext {
                    Ipv6ExtensionSlice::Fragment(header) if header.is_fragmenting_payload() => Some(header.to_header()),
                    _ => None,
                });
                let Some(f) = fragment else {
                    return NetworkPacket::from_sliced(sliced).map(Some);
                };
                let h = ip.header();
                (
                    IpHeader::Ipv6(h.to_header()),
                    (
                        IpAddr::V6(h.source().into()),
                        IpAddr::V6(h.destination().into()),
                        f.identification,
                        ip.payload().ip_number,
                    ),
                    f.fragment_offset,
                    f.more_fragments,
                    ip.payload().payload,
                )
            }
            _ => return NetworkPacket::from_sliced(sliced).map(Some),
        };
        self.expire();
        // Bound incomplete packets as well as their lifetime. IpDefragBuf bounds
        // each datagram to 65535 bytes; a flood must not grow the map indefinitely.
        if self.active.len() >= 64 && !self.active.contains_key(&key) {
            return Ok(None);
        }
        let (entry, _) = self
            .active
            .entry(key)
            .or_insert_with(|| (Some(IpDefragBuf::new(key.3, Vec::new(), Vec::new())), Instant::now()));
        let Some(buffer) = entry else {
            return Ok(None);
        };
        let start = usize::from(offset.value()) * 8;
        let end = start + payload.len();
        if buffer
            .sections()
            .iter()
            .any(|range| start < usize::from(range.end) && end > usize::from(range.start))
            || buffer.add(offset, more, payload).is_err()
        {
            // Keep a bounded rejection marker until expiry so later fragments
            // cannot revive an invalid/overlapping datagram (RFC 5722).
            *entry = None;
            return Ok(None);
        }
        if !buffer.is_complete() {
            return Ok(None);
        }
        let (payload, _) = self
            .active
            .remove(&key)
            .expect("completed fragment entry")
            .0
            .expect("valid fragment buffer")
            .take_bufs();
        match &mut ip {
            IpHeader::Ipv4(ip) => {
                ip.more_fragments = false;
                ip.fragment_offset = IpFragOffset::try_new(0).expect("zero fragment offset");
                ip.set_payload_len(payload.len())?;
            }
            IpHeader::Ipv6(ip) => {
                ip.next_header = key.3;
                ip.payload_length = payload.len() as u16;
            }
        }
        let packet = NetworkPacket {
            ip,
            transport: TransportHeader::Unknown,
            payload: Some(payload),
        };
        NetworkPacket::parse(&packet.to_bytes()?).map(Some)
    }
}

#[derive(Eq, Hash, PartialEq, Debug, Clone, Copy)]
pub struct NetworkTuple {
    pub src: SocketAddr,
    pub dst: SocketAddr,
    pub tcp: bool,
}

impl NetworkTuple {
    pub fn new(src: SocketAddr, dst: SocketAddr, tcp: bool) -> Self {
        NetworkTuple { src, dst, tcp }
    }
}

impl std::fmt::Display for NetworkTuple {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let tcp = if self.tcp { "TCP" } else { "UDP" };
        write!(f, "{} {} -> {}", tcp, self.src, self.dst)
    }
}

pub mod tcp_flags {
    pub const CWR: u8 = 0b10000000;
    pub const ECE: u8 = 0b01000000;
    pub const URG: u8 = 0b00100000;
    pub const ACK: u8 = 0b00010000;
    pub const PSH: u8 = 0b00001000;
    pub const RST: u8 = 0b00000100;
    pub const SYN: u8 = 0b00000010;
    pub const FIN: u8 = 0b00000001;
}

#[derive(Debug, Clone)]
pub(crate) enum IpHeader {
    Ipv4(Ipv4Header),
    Ipv6(Ipv6Header),
}

#[derive(Debug, Clone)]
pub(crate) enum TransportHeader {
    Tcp(TcpHeader),
    Udp(UdpHeader),
    Unknown,
}

#[derive(Debug, Clone)]
pub struct NetworkPacket {
    pub(crate) ip: IpHeader,
    pub(crate) transport: TransportHeader,
    pub(crate) payload: Option<Vec<u8>>,
}

impl NetworkPacket {
    pub fn parse(buf: &[u8]) -> Result<Self, IpStackError> {
        let p = SlicedPacket::from_ip(buf).map_err(|_| IpStackError::InvalidPacket)?;
        Self::from_sliced(p)
    }

    fn from_sliced(p: SlicedPacket<'_>) -> Result<Self, IpStackError> {
        let ip = p.net.ok_or(IpStackError::InvalidPacket)?;

        let (ip, ip_payload) = match ip {
            NetSlice::Ipv4(ip) => (IpHeader::Ipv4(ip.header().to_header()), ip.payload().payload),
            NetSlice::Ipv6(ip) => (IpHeader::Ipv6(ip.header().to_header()), ip.payload().payload),
            NetSlice::Arp(_) => return Err(IpStackError::UnsupportedTransportProtocol),
        };
        let (transport, payload) = match p.transport {
            Some(etherparse::TransportSlice::Tcp(h)) => (TransportHeader::Tcp(h.to_header()), h.payload()),
            Some(etherparse::TransportSlice::Udp(u)) => (TransportHeader::Udp(u.to_header()), u.payload()),
            _ => (TransportHeader::Unknown, ip_payload),
        };
        let payload = if payload.is_empty() { None } else { Some(payload.to_vec()) };

        Ok(NetworkPacket { ip, transport, payload })
    }
    pub(crate) fn transport_header(&self) -> &TransportHeader {
        &self.transport
    }
    pub fn src_addr(&self) -> SocketAddr {
        let port = match &self.transport {
            TransportHeader::Udp(udp) => udp.source_port,
            TransportHeader::Tcp(tcp) => tcp.source_port,
            _ => 0,
        };
        match &self.ip {
            IpHeader::Ipv4(ip) => SocketAddr::new(IpAddr::V4(Ipv4Addr::from(ip.source)), port),
            IpHeader::Ipv6(ip) => SocketAddr::new(IpAddr::V6(Ipv6Addr::from(ip.source)), port),
        }
    }
    pub fn dst_addr(&self) -> SocketAddr {
        let port = match &self.transport {
            TransportHeader::Udp(udp) => udp.destination_port,
            TransportHeader::Tcp(tcp) => tcp.destination_port,
            _ => 0,
        };
        match &self.ip {
            IpHeader::Ipv4(ip) => SocketAddr::new(IpAddr::V4(Ipv4Addr::from(ip.destination)), port),
            IpHeader::Ipv6(ip) => SocketAddr::new(IpAddr::V6(Ipv6Addr::from(ip.destination)), port),
        }
    }
    pub fn network_tuple(&self) -> NetworkTuple {
        NetworkTuple {
            src: self.src_addr(),
            dst: self.dst_addr(),
            tcp: matches!(self.transport, TransportHeader::Tcp(_)),
        }
    }
    pub fn reverse_network_tuple(&self) -> NetworkTuple {
        NetworkTuple {
            src: self.dst_addr(),
            dst: self.src_addr(),
            tcp: matches!(self.transport, TransportHeader::Tcp(_)),
        }
    }
    pub fn to_bytes(&self) -> Result<Vec<u8>, IpStackError> {
        let mut buf = Vec::new();
        match self.ip {
            IpHeader::Ipv4(ref ip) => ip.write(&mut buf)?,
            IpHeader::Ipv6(ref ip) => ip.write(&mut buf)?,
        }
        match self.transport {
            TransportHeader::Tcp(ref h) => h.write(&mut buf)?,
            TransportHeader::Udp(ref h) => h.write(&mut buf)?,
            _ => {}
        };

        if let Some(payload) = &self.payload {
            buf.extend_from_slice(payload);
        }
        Ok(buf)
    }
    pub fn ttl(&self) -> u8 {
        match &self.ip {
            IpHeader::Ipv4(ip) => ip.time_to_live,
            IpHeader::Ipv6(ip) => ip.hop_limit,
        }
    }
}

pub fn tcp_header_fmt(header: &TcpHeader) -> String {
    let mut flags = String::new();
    if header.cwr {
        flags.push_str("CWR ");
    }
    if header.ece {
        flags.push_str("ECE ");
    }
    if header.urg {
        flags.push_str("URG ");
    }
    if header.ack {
        flags.push_str("ACK ");
    }
    if header.psh {
        flags.push_str("PSH ");
    }
    if header.rst {
        flags.push_str("RST ");
    }
    if header.syn {
        flags.push_str("SYN ");
    }
    if header.fin {
        flags.push_str("FIN ");
    }
    format!(
        "TcpHeader {{ seq: {}, ack: {}, flags: {} }}",
        header.sequence_number,
        header.acknowledgment_number,
        flags.trim()
    )
}

pub fn tcp_header_flags(inner: &TcpHeader) -> u8 {
    let mut flags = 0;
    if inner.cwr {
        flags |= tcp_flags::CWR;
    }
    if inner.ece {
        flags |= tcp_flags::ECE;
    }
    if inner.urg {
        flags |= tcp_flags::URG;
    }
    if inner.ack {
        flags |= tcp_flags::ACK;
    }
    if inner.psh {
        flags |= tcp_flags::PSH;
    }
    if inner.rst {
        flags |= tcp_flags::RST;
    }
    if inner.syn {
        flags |= tcp_flags::SYN;
    }
    if inner.fin {
        flags |= tcp_flags::FIN;
    }

    flags
}

// pub struct UdpPacket {
//     header: UdpHeader,
// }

// impl UdpPacket {
//     pub fn inner(&self) -> &UdpHeader {
//         &self.header
//     }
// }

// impl From<&UdpHeader> for UdpPacket {
//     fn from(header: &UdpHeader) -> Self {
//         UdpPacket {
//             header: header.clone(),
//         }
//     }
// }
