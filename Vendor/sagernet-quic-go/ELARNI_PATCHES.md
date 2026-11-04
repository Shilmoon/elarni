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
- `go.mod`, `go.sum`: tidied for the copied sources, without the `tool` block.
