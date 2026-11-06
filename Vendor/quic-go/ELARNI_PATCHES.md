# Elarni patches

Upstream: github.com/apernet/quic-go v0.61.1-0.20260806010916-184d081eef3e (the
version Vendor/Xray-core requires), joined to the build by `go.work`. Only the
non-test sources are copied; the example, interop, integration-test, test-utility
and mock directories are left out.

- `flow_controller_connection.go`: bytes that arrived on a stream count as read for
  the connection window, up to twice its maximum size. Before, bytes held unread by
  streams the application stopped reading counted against the connection until it
  was consumed, so three stalled downloads froze every other stream of a Hysteria2
  or XHTTP/3 connection, with or without the Chrome parrot (each stream may hold
  6-8 MiB of a 15-20 MiB connection window). Each stream's own window still bounds
  what it holds, and the window update rides on the ACKs the stalled data elicits.
  Test: `flow_controller_stalled_test.go`; end to end in Xray-core's
  `transport/internet/hysteria/stalled_streams_test.go` and
  `transport/internet/splithttp/h3_stall_test.go`.
  On iOS the allowance is half the maximum window instead of twice it (`unreadAllowance`), so
  one XHTTP/3 connection holds at most 22.5 MiB unread instead of 45 MiB: iOS kills the packet
  tunnel above about 50 MB. Test: `TestUnreadAllowanceIsSmallerOnIOS`.
- `http3/transport.go` (`getClient`): the dial that every request for a host waits on no longer
  ends when the request that started it is canceled; `Transport.Close` still ends it. One closed
  app aborted a cold XHTTP/3 handshake for every flow waiting on it. Test: Xray-core's
  `TestXHTTP3CanceledFirstFlowKeepsTheSharedDial`.
- `connection.go`: `Conn.Ping` queues a PING, which the peer acknowledges at once; XHTTP/3
  checks its connections this way after a network change (`TestPathChangeKeepsAnsweringConnections`).
- `go.mod`, `go.sum`: tidied for the copied sources, without the `tool` block, so
  the workspace does not pull upstream's test and generator dependencies.
- `http3/{client,headers,request_writer,response_writer,server_conn}.go`: imports
  sorted by gofmt (upstream's module rename left them out of order).
