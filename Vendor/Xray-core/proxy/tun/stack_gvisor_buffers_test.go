package tun

import (
	"testing"

	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/transport/tcp"
)

// An app that stops reading keeps its connection's send buffer full, and a stalled upload its
// receive buffer. Grown to 6 and 8 MiB, 80 such connections held 163 MB of live heap on a phone
// and kept the GC running against Android's 192 MB limit. The TUN leg's round trip is local.
func TestTunTCPBuffersStayBounded(t *testing.T) {
	endpoint := &LinkEndpoint{deviceMTU: 1500, device: idleDevice{}}
	network, err := createStack(endpoint)
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		endpoint.Close()
		endpoint.Wait()
		network.Close()
		network.Wait()
	}()
	var receive tcpip.TCPReceiveBufferSizeRangeOption
	if err := network.TransportProtocolOption(tcp.ProtocolNumber, &receive); err != nil {
		t.Fatal(err)
	}
	var send tcpip.TCPSendBufferSizeRangeOption
	if err := network.TransportProtocolOption(tcp.ProtocolNumber, &send); err != nil {
		t.Fatal(err)
	}
	if receive.Max > 1<<20 || receive.Default > receive.Max {
		t.Errorf("receive buffer range %+v, want at most 1 MiB", receive)
	}
	if send.Max > 2<<20 || send.Default > send.Max {
		t.Errorf("send buffer range %+v, want at most 2 MiB", send)
	}
}
