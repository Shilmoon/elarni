package tun

import (
	"sync"
	"testing"
	"time"

	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv4"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
	"gvisor.dev/gvisor/pkg/tcpip/transport/tcp"
	"gvisor.dev/gvisor/pkg/waiter"
)

type waitingDevice struct {
	blocked, wake chan struct{}
	once          sync.Once
}

func (*waitingDevice) WritePacket(*stack.PacketBuffer) tcpip.Error    { return nil }
func (*waitingDevice) ReadPacket() (byte, *stack.PacketBuffer, error) { return 0, nil, ErrQueueEmpty }
func (d *waitingDevice) Wait()                                        { d.once.Do(func() { close(d.blocked) }); <-d.wake }

func TestLinkEndpointShutdownJoinsBlockedReader(t *testing.T) {
	device := &waitingDevice{blocked: make(chan struct{}), wake: make(chan struct{})}
	endpoint := &LinkEndpoint{deviceMTU: 1500, device: device}
	network, err := createStack(endpoint)
	if err != nil {
		t.Fatal(err)
	}
	defer network.Close()
	var wake sync.Once
	defer wake.Do(func() { close(device.wake) })
	select {
	case <-device.blocked:
	case <-time.After(time.Second):
		t.Fatal("reader did not start")
	}
	endpoint.Close()
	done := make(chan struct{})
	go func() { endpoint.Wait(); close(done) }()
	select {
	case <-done:
		t.Fatal("shutdown returned while its device reader was still blocked")
	case <-time.After(20 * time.Millisecond):
	}
	wake.Do(func() { close(device.wake) })
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("shutdown did not join the released reader")
	}
	if endpoint.IsAttached() {
		t.Fatal("closed endpoint remained attached")
	}
	network.Close()
	network.Wait()
}

type idleDevice struct{}

func (idleDevice) WritePacket(*stack.PacketBuffer) tcpip.Error    { return nil }
func (idleDevice) ReadPacket() (byte, *stack.PacketBuffer, error) { return 0, nil, ErrQueueEmpty }
func (idleDevice) Wait()                                          { time.Sleep(time.Millisecond) }

// A handshake that registers just after Close keeps resending for about two
// minutes; stopping the VPN must wait only for the device reader.
func TestStackWaitSkipsHandshakesRegisteredAfterClose(t *testing.T) {
	endpoint := &LinkEndpoint{deviceMTU: 1500, device: idleDevice{}}
	network, err := createStack(endpoint)
	if err != nil {
		t.Fatal(err)
	}
	if err := network.AddProtocolAddress(defaultNIC, tcpip.ProtocolAddress{Protocol: ipv4.ProtocolNumber, AddressWithPrefix: tcpip.AddrFrom4([4]byte{10, 0, 0, 2}).WithPrefix()}, stack.AddressProperties{}); err != nil {
		t.Fatal(err)
	}
	endpoint.Attach(nil)
	network.Close()
	var wq waiter.Queue
	late, tcpErr := network.NewEndpoint(tcp.ProtocolNumber, ipv4.ProtocolNumber, &wq)
	if tcpErr != nil {
		t.Fatal(tcpErr)
	}
	defer late.Abort()
	late.Connect(tcpip.FullAddress{NIC: defaultNIC, Addr: tcpip.AddrFrom4([4]byte{192, 0, 2, 1}), Port: 80})
	done := make(chan struct{})
	go func() { (&stackGVisor{stack: network, endpoint: endpoint}).Wait(); close(done) }()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("Wait blocked on a TCP handshake that Close did not abort")
	}
}
