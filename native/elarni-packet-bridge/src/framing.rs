use std::collections::VecDeque;
use std::io;
use std::task::Waker;

#[derive(Debug)]
pub struct FrameAssembler {
    pending: Vec<u8>,
    output: VecDeque<Vec<u8>>,
    max_packet_bytes: usize,
    max_queued_packets: usize,
    dropped: u64,
    // A writer waiting for room, woken by `pop`.
    writer: Option<Waker>,
}

impl FrameAssembler {
    pub fn new(max_packet_bytes: usize, max_queued_packets: usize) -> Self {
        Self {
            pending: Vec::with_capacity(max_packet_bytes),
            output: VecDeque::with_capacity(max_queued_packets),
            max_packet_bytes,
            max_queued_packets,
            dropped: 0,
            writer: None,
        }
    }

    /// Packets dropped because the output queue was full.
    pub fn dropped(&self) -> u64 {
        self.dropped
    }

    /// Whether the queue is full; if so, `waker` runs once `pop` makes room.
    pub fn full_or_park(&mut self, waker: &Waker) -> bool {
        let full = self.output.len() >= self.max_queued_packets;
        if full {
            self.writer = Some(waker.clone());
        }
        full
    }

    pub fn ingest(&mut self, bytes: &[u8]) -> io::Result<usize> {
        if self.pending.len().saturating_add(bytes.len()) > self.max_packet_bytes * 2 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "packet framing buffer exceeded bound",
            ));
        }
        self.pending.extend_from_slice(bytes);
        while let Some(length) = packet_length(&self.pending)? {
            if length > self.max_packet_bytes {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "packet exceeds configured bound",
                ));
            }
            if self.pending.len() < length {
                break;
            }
            let remainder = self.pending.split_off(length);
            let packet = std::mem::replace(&mut self.pending, remainder);
            // Writers wait for room (`full_or_park`), so only a write carrying several
            // packets can overfill the queue: drop the excess, as an error would end the stack.
            if self.output.len() >= self.max_queued_packets {
                self.dropped += 1;
                continue;
            }
            self.output.push_back(packet);
        }
        Ok(bytes.len())
    }

    pub fn front(&self) -> Option<&[u8]> {
        self.output.front().map(Vec::as_slice)
    }

    pub fn pop(&mut self) -> Option<Vec<u8>> {
        let packet = self.output.pop_front();
        if packet.is_some()
            && let Some(writer) = self.writer.take()
        {
            writer.wake();
        }
        packet
    }
}

pub fn validate_packet(packet: &[u8], max_packet_bytes: usize) -> io::Result<()> {
    if packet.is_empty() || packet.len() > max_packet_bytes {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "packet size outside configured bounds",
        ));
    }
    let expected = packet_length(packet)?.ok_or_else(|| {
        io::Error::new(io::ErrorKind::UnexpectedEof, "incomplete IP packet header")
    })?;
    if expected != packet.len() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "IP packet length does not match frame boundary",
        ));
    }
    Ok(())
}

/// Whether a validated packet is addressed to many hosts at once: IPv4 multicast (224.0.0.0/4),
/// the limited broadcast 255.255.255.255, or IPv6 multicast (ff00::/8). No proxy carries such a
/// packet, and the system already sends its LAN discovery (mDNS, SSDP, LLMNR) on the LAN itself;
/// relayed, each one opened a UDP session, and a burst filled the table so that DNS was refused.
pub fn to_many_at_once(packet: &[u8]) -> bool {
    match packet.first().map(|first| first >> 4) {
        Some(4) if packet.len() >= 20 => {
            packet[16] & 0xf0 == 0xe0 || packet[16..20] == [255, 255, 255, 255]
        }
        Some(6) if packet.len() >= 40 => packet[24] == 0xff,
        _ => false,
    }
}

fn packet_length(packet: &[u8]) -> io::Result<Option<usize>> {
    let Some(first) = packet.first() else {
        return Ok(None);
    };
    match first >> 4 {
        4 => {
            if packet.len() < 4 {
                return Ok(None);
            }
            let header_len = usize::from(first & 0x0f) * 4;
            let total_len = usize::from(u16::from_be_bytes([packet[2], packet[3]]));
            if header_len < 20 || total_len < header_len {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "invalid IPv4 header length",
                ));
            }
            Ok(Some(total_len))
        }
        6 => {
            if packet.len() < 6 {
                return Ok(None);
            }
            let payload_len = usize::from(u16::from_be_bytes([packet[4], packet[5]]));
            Ok(Some(40 + payload_len))
        }
        _ => Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "unsupported IP version",
        )),
    }
}
