# Elarni patches

Upstream: github.com/sagernet/quic-go v0.61.0-sing-box-mod.6 (revision
f7b7e9c4c6f6ec45e4ab2b4788eca63192975d80, the version sing-quic's TUIC client
requires), joined to the build by `go.work`. Only the non-test sources are
copied, as in `Vendor/quic-go`.

- `flow_controller_connection.go`: the `Vendor/quic-go` change (received stream
  bytes count as read for the connection window, up to twice its maximum size),
  so downloads the application stopped reading no longer freeze every other
  stream of a TUIC connection: 8 stalled streams at quic-go's first 2 MiB stream
  window filled the client's 16 MiB connection window. Past twice the window of
  unread bytes new streams still wait, which bounds memory.
  Test: `flow_controller_stalled_test.go`; end to end in Xray-core's
  `proxy/tuic/stalled_streams_test.go`.
  On iOS the allowance is half the maximum window instead of twice it (`unreadAllowance`), so
  one TUIC connection holds at most 24 MiB unread instead of 48 MiB: iOS kills the packet
  tunnel above about 50 MB. Test: `TestUnreadAllowanceIsSmallerOnIOS`.
- `client.go` (`setupTransportConn`, `DialConn`, `DialEarlyConn`): a conn with a
  `PacketConn() net.PacketConn` method that returns non-nil gets quic-go's unconnected-socket
  path on that socket (batched receive, GSO, ECN, DF). Xray's UDP dialer returns an unconnected
  socket in a wrapper, which hid it from quic-go; the connected path a syscall.Conn gets sends
  without an address, which that socket rejects. A conn with a `SetQUICConn(*Conn)` method
  learns the connection dialed over it, which sing-quic's TUIC client keeps private; Xray-core
  checks it after a network change. Tests: `client_unconnected_test.go`; end to end in
  Xray-core's `proxy/tuic/path_test.go`.
- `go.mod`, `go.sum`: tidied for the copied sources, without the `tool` block.
