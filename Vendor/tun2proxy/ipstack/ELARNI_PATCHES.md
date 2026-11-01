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
