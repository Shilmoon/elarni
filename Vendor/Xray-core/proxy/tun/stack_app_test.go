package tun

import (
	"context"
	stdErrors "errors"
	"io"
	"strings"
	"testing"
	"time"

	"github.com/xtls/xray-core/common"
	"github.com/xtls/xray-core/common/buf"
	"github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/features/routing"
	"github.com/xtls/xray-core/transport"
	"gvisor.dev/gvisor/pkg/buffer"
	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
	"gvisor.dev/gvisor/pkg/tcpip/header"
	"gvisor.dev/gvisor/pkg/tcpip/link/channel"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv4"
	gstack "gvisor.dev/gvisor/pkg/tcpip/stack"
	"gvisor.dev/gvisor/pkg/tcpip/transport/tcp"
	"gvisor.dev/gvisor/pkg/waiter"
)

// dialThroughTun starts handler's real stack behind a TUN link and returns how an app connects
// through it from a local port.
func dialThroughTun(t testing.TB, handler *Handler) func(port uint16) (*gonet.TCPConn, error) {
	dial := connectThroughTun(t, handler)
	return func(port uint16) (*gonet.TCPConn, error) {
		conn, _, err := dial(port)
		return conn, err
	}
}

// connectThroughTun is dialThroughTun that also returns the app's endpoint, to reset the connection.
// The app is a gVisor stack on the other side of the link.
func connectThroughTun(t testing.TB, handler *Handler) func(port uint16) (*gonet.TCPConn, tcpip.Endpoint, error) {
	device, appSide := newLink(), channel.New(256, 1500, "")
	device.out = func(packet []byte) {
		pkt := gstack.NewPacketBuffer(gstack.PacketBufferOptions{Payload: buffer.MakeWithData(packet)})
		appSide.InjectInbound(ipv4.ProtocolNumber, pkt)
		pkt.DecRef()
	}
	handler.ctx, handler.config, handler.tun = context.Background(), &Config{}, device
	network, err := NewStack(handler.ctx, StackOptions{Tun: device, MTU: 1500}, handler)
	if err != nil {
		t.Fatal(err)
	}
	if err := network.Start(); err != nil {
		t.Fatal(err)
	}
	handler.stack = network
	app := gstack.New(gstack.Options{NetworkProtocols: []gstack.NetworkProtocolFactory{ipv4.NewProtocol}, TransportProtocols: []gstack.TransportProtocolFactory{tcp.NewProtocol}})
	if err := app.CreateNIC(1, appSide); err != nil {
		t.Fatal(err)
	}
	local := tcpip.AddrFrom4([4]byte{10, 0, 0, 1})
	if err := app.AddProtocolAddress(1, tcpip.ProtocolAddress{Protocol: ipv4.ProtocolNumber, AddressWithPrefix: local.WithPrefix()}, gstack.AddressProperties{}); err != nil {
		t.Fatal(err)
	}
	app.SetRouteTable([]tcpip.Route{{Destination: header.IPv4EmptySubnet, NIC: 1}})
	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		for {
			pkt := appSide.ReadContext(ctx)
			if pkt == nil {
				return
			}
			packet := pkt.ToView().AsSlice()
			pkt.DecRef()
			select {
			case device.in <- packet:
			case <-ctx.Done():
				return
			}
		}
	}()
	t.Cleanup(func() { cancel(); handler.Close(); app.Close() })
	return func(port uint16) (*gonet.TCPConn, tcpip.Endpoint, error) {
		var wq waiter.Queue
		ep, err := app.NewEndpoint(tcp.ProtocolNumber, ipv4.ProtocolNumber, &wq)
		if err != nil {
			t.Fatal(err)
		}
		if err := ep.Bind(tcpip.FullAddress{NIC: 1, Addr: local, Port: port}); err != nil {
			t.Fatal(err)
		}
		connected, notify := waiter.NewChannelEntry(waiter.WritableEvents | waiter.EventHUp)
		wq.EventRegister(&connected)
		defer wq.EventUnregister(&connected)
		connectErr := ep.Connect(tcpip.FullAddress{NIC: 1, Addr: tcpip.AddrFrom4([4]byte{203, 0, 113, 10}), Port: 443})
		if _, started := connectErr.(*tcpip.ErrConnectStarted); started {
			select {
			case <-notify:
			case <-time.After(time.Second):
			}
			connectErr = ep.LastError()
		}
		if connectErr != nil {
			ep.Close()
			return nil, nil, stdErrors.New(connectErr.String())
		}
		return gonet.NewTCPConn(&wq, ep), ep, nil
	}
}

// heldDispatcher reports each connection and holds it until the app closes it.
type heldDispatcher struct {
	routing.Dispatcher
	links chan *transport.Link
}

func (d *heldDispatcher) DispatchLink(_ context.Context, _ net.Destination, link *transport.Link) error {
	d.links <- link
	for {
		mb, err := link.Reader.ReadMultiBuffer()
		buf.ReleaseMulti(mb)
		if err != nil {
			return nil
		}
	}
}

// A full table used to complete the handshake and reset the connection after the app sent its request.
// The SYN must be refused instead, before the app has anything to retry.
func TestFullTCPTableRefusesConnectionBeforeHandshake(t *testing.T) {
	dispatcher := &heldDispatcher{links: make(chan *transport.Link, 2)}
	handler := &Handler{dispatcher: dispatcher, tcpAdmission: sessionAdmission{limit: 1, minIdle: time.Minute}}
	dial := dialThroughTun(t, handler)
	first, err := dial(40000)
	if err != nil {
		t.Fatal(err)
	}
	defer first.Close()
	select {
	case <-dispatcher.links:
	case <-time.After(time.Second):
		t.Fatal("first connection not dispatched")
	}
	second, err := dial(40001)
	if err == nil {
		second.Close()
		t.Fatal("full table completed the handshake of a connection it cannot admit")
	}
	if !strings.Contains(err.Error(), "refused") {
		t.Fatalf("connect failed with %v, want a refusal", err)
	}
	if len(dispatcher.links) != 0 {
		t.Fatal("refused connection reached the dispatcher")
	}
}

// stalledDial reports each session's context, then waits on it like an outbound that is still dialing.
type stalledDial struct {
	routing.Dispatcher
	sessions chan context.Context
}

func (d *stalledDial) DispatchLink(ctx context.Context, _ net.Destination, _ *transport.Link) error {
	d.sessions <- ctx
	<-ctx.Done()
	return ctx.Err()
}

// An app that gives up on a connection resets it while the outbound may still be dialing for seconds;
// the dial must stop then. A FIN alone must not stop it: the app may still await the reply.
func TestAppResetCancelsTheDialButHalfCloseDoesNot(t *testing.T) {
	dispatcher := &stalledDial{sessions: make(chan context.Context, 2)}
	dial := connectThroughTun(t, &Handler{dispatcher: dispatcher})
	session := func(port uint16) (*gonet.TCPConn, tcpip.Endpoint, context.Context) {
		conn, ep, err := dial(port)
		if err != nil {
			t.Fatal(err)
		}
		select {
		case ctx := <-dispatcher.sessions:
			return conn, ep, ctx
		case <-time.After(time.Second):
			t.Fatal("connection not dispatched")
			return nil, nil, nil
		}
	}
	halfClosed, halfEP, halfCtx := session(40000)
	defer halfEP.Abort()
	halfClosed.CloseWrite()
	_, resetEP, resetCtx := session(40001)
	resetEP.Abort()
	select {
	case <-resetCtx.Done():
	case <-time.After(time.Second):
		t.Fatal("the dial went on after the app reset its connection")
	}
	// The tun side ACKs the FIN on its own goroutine.
	for deadline := time.Now().Add(time.Second); halfEP.State() != uint32(tcp.StateFinWait2); time.Sleep(time.Millisecond) {
		if time.Now().After(deadline) {
			t.Fatalf("app endpoint in state %d, want FIN_WAIT_2: the FIN never reached the tun side", halfEP.State())
		}
	}
	if halfCtx.Err() != nil {
		t.Fatal("a half-close stopped the dial")
	}
}

// After the response ended, the app's close puts the tun side in TIME_WAIT, which raises the events
// of a reset; the outbound may still be sending the app's last bytes, so its session must go on.
func TestAppCloseAfterTheResponseKeepsTheSession(t *testing.T) {
	dispatcher := lingeringResponse{sessions: make(chan context.Context, 1)}
	conn, ep, err := connectThroughTun(t, &Handler{dispatcher: dispatcher})(40000)
	if err != nil {
		t.Fatal(err)
	}
	conn.SetReadDeadline(time.Now().Add(time.Second))
	if got, err := io.ReadAll(conn); err != nil || string(got) != "reply" {
		t.Fatalf("read %q, %v; want the response and its end", got, err)
	}
	ctx := <-dispatcher.sessions
	conn.Close()
	select {
	case <-ctx.Done():
		t.Fatal("the app's orderly close cancelled the session")
	case <-time.After(200 * time.Millisecond):
	}
	if state := ep.State(); state != uint32(tcp.StateClose) {
		t.Fatalf("app endpoint in state %d, want CLOSED: the close never reached the tun side", state)
	}
}

// lingeringResponse sends a response and ends it, then holds the session open like an outbound
// waiting out policy uplinkOnly.
type lingeringResponse struct {
	routing.Dispatcher
	sessions chan context.Context // reports each session's context, when set
}

func (d lingeringResponse) DispatchLink(ctx context.Context, _ net.Destination, link *transport.Link) error {
	if err := link.Writer.WriteMultiBuffer(buf.MultiBuffer{buf.FromBytes([]byte("reply"))}); err != nil {
		return err
	}
	common.Close(link.Writer)
	if d.sessions != nil {
		d.sessions <- ctx
	}
	select {
	case <-ctx.Done():
	case <-time.After(2 * time.Second):
	}
	return nil
}

// An app that reads a response until EOF must get the FIN when the response ends, not when the
// whole session closes.
func TestTunTCPPassesTheEndOfAResponseToTheApp(t *testing.T) {
	conn, err := dialThroughTun(t, &Handler{dispatcher: lingeringResponse{}})(40000)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.SetReadDeadline(time.Now().Add(time.Second))
	got, err := io.ReadAll(conn)
	if err != nil || string(got) != "reply" {
		t.Fatalf("read %q, %v; want the response and its end", got, err)
	}
}

// uploadSink reads each session to its end and reports how many bytes it read.
type uploadSink struct {
	routing.Dispatcher
	total chan int64
}

func (d *uploadSink) DispatchLink(_ context.Context, _ net.Destination, link *transport.Link) error {
	var n int64
	for {
		mb, err := link.Reader.ReadMultiBuffer()
		n += int64(mb.Len())
		buf.ReleaseMulti(mb)
		if err != nil {
			d.total <- n
			return nil
		}
	}
}

// An app uploading through the stack; each segment wakes the tun side's waiters.
func BenchmarkTCPUplink(b *testing.B) {
	sink := &uploadSink{total: make(chan int64, 1)}
	conn, _, err := connectThroughTun(b, &Handler{dispatcher: sink})(40000)
	if err != nil {
		b.Fatal(err)
	}
	defer conn.Close()
	chunk := make([]byte, 64<<10)
	b.SetBytes(int64(len(chunk)))
	b.ReportAllocs()
	b.ResetTimer()
	for range b.N {
		if _, err := conn.Write(chunk); err != nil {
			b.Fatal(err)
		}
	}
	conn.CloseWrite()
	if got := <-sink.total; got != int64(b.N*len(chunk)) {
		b.Fatalf("outbound read %d bytes, want %d", got, b.N*len(chunk))
	}
}
