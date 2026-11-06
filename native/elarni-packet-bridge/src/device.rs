use std::io;
use std::pin::Pin;
use std::sync::atomic::{AtomicUsize, Ordering, fence};
use std::sync::{Arc, Condvar, Mutex};
use std::task::{Context, Poll};

use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::sync::mpsc;

use crate::framing::FrameAssembler;

/// Wakes a submit that waits for room in the full input queue.
#[derive(Default)]
pub struct InputRoom {
    pub lock: Mutex<()>,
    pub freed: Condvar,
    /// Submits waiting on `freed`; the reader takes the lock only when one waits.
    pub waiting: AtomicUsize,
}

impl InputRoom {
    /// Called after the reader took a packet, which freed a slot.
    pub fn notify(&self) {
        // Pairs with the fence before a waiting submit's retry.
        fence(Ordering::SeqCst);
        if self.waiting.load(Ordering::Relaxed) > 0 {
            self.wake();
        }
    }

    pub fn wake(&self) {
        // Taking the lock orders this wake after a waiter's last retry.
        drop(self.lock.lock());
        self.freed.notify_all();
    }
}

pub struct PacketDevice {
    input: mpsc::Receiver<Vec<u8>>,
    input_room: Arc<InputRoom>,
    current: Option<(Vec<u8>, usize)>,
    output: Arc<Mutex<FrameAssembler>>,
    output_ready: Arc<Condvar>,
}

impl PacketDevice {
    pub fn new(
        input: mpsc::Receiver<Vec<u8>>,
        input_room: Arc<InputRoom>,
        output: Arc<Mutex<FrameAssembler>>,
        output_ready: Arc<Condvar>,
    ) -> Self {
        Self {
            input,
            input_room,
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
                Poll::Ready(Some(packet)) => {
                    self.current = Some((packet, 0));
                    self.input_room.notify();
                }
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
        context: &mut Context<'_>,
        bytes: &[u8],
    ) -> Poll<io::Result<usize>> {
        let mut output = self
            .output
            .lock()
            .map_err(|_| io::Error::other("packet output lock poisoned"))?;
        // Wait for the reader like a full TUN queue: dropped packets cost the stack a retransmission timeout.
        if output.full_or_park(context.waker()) {
            return Poll::Pending;
        }
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
