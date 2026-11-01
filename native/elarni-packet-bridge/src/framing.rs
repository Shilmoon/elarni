use std::collections::VecDeque;
use std::io;

#[derive(Debug)]
pub struct FrameAssembler {
    pending: Vec<u8>,
    output: VecDeque<Vec<u8>>,
    max_packet_bytes: usize,
    max_queued_packets: usize,
    dropped: u64,
}

impl FrameAssembler {
    pub fn new(max_packet_bytes: usize, max_queued_packets: usize) -> Self {
        Self {
            pending: Vec::with_capacity(max_packet_bytes),
            output: VecDeque::with_capacity(max_queued_packets),
            max_packet_bytes,
            max_queued_packets,
            dropped: 0,
        }
    }

    /// Packets dropped because the output queue was full.
    pub fn dropped(&self) -> u64 {
        self.dropped
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
            // A full queue is congestion: drop the packet as a link would; an
            // error here would end the whole packet stack.
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
        self.output.pop_front()
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
