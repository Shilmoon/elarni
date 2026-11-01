use std::io;
use std::pin::Pin;
use std::sync::{Arc, Condvar, Mutex};
use std::task::{Context, Poll};

use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::sync::mpsc;

use crate::framing::FrameAssembler;

pub struct PacketDevice {
    input: mpsc::Receiver<Vec<u8>>,
    current: Option<(Vec<u8>, usize)>,
    output: Arc<Mutex<FrameAssembler>>,
    output_ready: Arc<Condvar>,
}

impl PacketDevice {
    pub fn new(
        input: mpsc::Receiver<Vec<u8>>,
        output: Arc<Mutex<FrameAssembler>>,
        output_ready: Arc<Condvar>,
    ) -> Self {
        Self {
            input,
            current: None,
            output,
            output_ready,
        }
    }
}

impl AsyncRead for PacketDevice {
    fn poll_read(
        mut self: Pin<&mut Self>,
        context: &mut Context<'_>,
        buffer: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        if self.current.is_none() {
            match self.input.poll_recv(context) {
                Poll::Ready(Some(packet)) => self.current = Some((packet, 0)),
                Poll::Ready(None) => return Poll::Ready(Ok(())),
                Poll::Pending => return Poll::Pending,
            }
        }
        let capacity = buffer.remaining();
        let Some((packet, offset)) = self.current.as_mut() else {
            return Poll::Ready(Ok(()));
        };
        let count = capacity.min(packet.len() - *offset);
        buffer.put_slice(&packet[*offset..*offset + count]);
        *offset += count;
        if *offset == packet.len() {
            self.current = None;
        }
        Poll::Ready(Ok(()))
    }
}

impl AsyncWrite for PacketDevice {
    fn poll_write(
        self: Pin<&mut Self>,
        _context: &mut Context<'_>,
        bytes: &[u8],
    ) -> Poll<io::Result<usize>> {
        let mut output = self
            .output
            .lock()
            .map_err(|_| io::Error::other("packet output lock poisoned"))?;
        let was_empty = output.front().is_none();
        let result = output.ingest(bytes);
        // A waiter sleeps only on an empty queue, so only its first packet needs a wake.
        if was_empty && output.front().is_some() {
            self.output_ready.notify_all();
        }
        Poll::Ready(result)
    }

    fn poll_flush(self: Pin<&mut Self>, _context: &mut Context<'_>) -> Poll<io::Result<()>> {
        Poll::Ready(Ok(()))
    }

    fn poll_shutdown(self: Pin<&mut Self>, _context: &mut Context<'_>) -> Poll<io::Result<()>> {
        Poll::Ready(Ok(()))
    }
}
