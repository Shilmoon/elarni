# Elarni ipstack patch

Library source from narrowlink/ipstack tag `v.1.0.1`, commit
`a343ea8c696e761acce8dbcd6687c862ecd8aacd` (Apache-2.0; see LICENSE).
The upstream example-only Windows DLL installer and example programs are not
part of this library copy, nor are their dev-dependencies and the criterion
benchmark harness, so the remaining upstream and local unit tests run from the
Elarni workspace (`scripts/check-tests rust`).

Local repair: preserve a UDP write as one datagram and fragment its IP packet
at the configured MTU instead of returning a short write that splits the
application message. Input accepts complete offloaded IP packets and reassembles
fragments using the existing etherparse dependency. Incomplete datagrams are
limited to 64 entries and 60 seconds; overlaps are rejected and Stop drops state.
The existing LiveTunnelChecks fixture checks exact IPv4/IPv6 SOCKS/VLESS traffic
through the C and Swift packet bridge, including out-of-order input fragments,
admission, expiry and restart cleanup.

Local TCP repairs (`src/stream/tcp.rs`, `src/stream/tcb.rs`, tests in
`src/stream/tcp_tests.rs`):
- The SYN-ACK announces the MSS the MTU allows, segments respect the client's
  MSS, and the send and receive limits are 64 KiB (16 KiB capped one stream at
  16 KiB per TUN round trip).
- Bytes queued for the application but not yet read close the receive window,
  and a read that reopens half of it sends a window update. Before, every upload
  byte was ACKed into an unbounded queue while the proxy side did not read.
- Every data segment is ACKed, so a gap produces duplicate ACKs; out-of-order and
  partly overlapping segments are kept or trimmed instead of dropped.
  While a gap holds the ACK still, those ACKs repeat the last window: without SACK,
  macOS counts an ACK as a duplicate only if its window is unchanged.
- A timer retransmits the oldest unacknowledged segment (RTO 200 ms, doubling,
  5 retries, then RST). Retransmission used to run only when the client sent
  another packet, so a lost last segment hung the transfer.
- A client FIN, with or without data, ends the application's read and leaves its
  write open; our FIN follows the application's shutdown once its data is
  acknowledged. A FIN with data used to be ignored, and the session closed
  without waiting for the application's reply.
- Writes wait for the end of the handshake; one right after accept used to go
  out ahead of the SYN-ACK, which then carried a sequence number past the data.
- A client RST wakes pending reads and writes and ends the session. A resent
  FIN in LAST_ACK carries the FIN's own sequence number.
- When the application closes first, the client's FIN (also one carrying data)
  is acknowledged and ends the pending read; before, TIME_WAIT left that read
  asleep until the idle timeout (600 s in tun2proxy). Our FIN is resent in
  FIN_WAIT_1 as in LAST_ACK, and both states leave only on the ACK of that FIN.
  CLOSE_WAIT acknowledges a resent client FIN.
- A read takes every queued segment that fits, not one, so the proxy writes an
  upload in up to 8 KiB instead of one system call per segment. Per-packet log
  lines format their sequence numbers only when the line is logged.

Local device repair (`src/lib.rs`, test in `src/stream/tcp_tests.rs`): packets go
to the device from their own task over `tokio::io::split`, so a device write
waiting for room (the packet bridge's full output queue) no longer stops the
stack reading its input, which the bridge then dropped. While that write waits, UDP and
ICMP packets beyond 1024 queued are dropped like a full TUN queue drops them,
since their senders never wait and a tunnel that stopped reading grew the queue
without bound; TCP packets stay queued, bounded by each connection's window.
