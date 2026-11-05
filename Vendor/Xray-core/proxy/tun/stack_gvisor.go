package tun

import (
	"context"
	"sync"
	"time"

	"github.com/xtls/xray-core/common/buf"
	"github.com/xtls/xray-core/common/errors"
	"github.com/xtls/xray-core/common/net"
	"gvisor.dev/gvisor/pkg/buffer"
	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
	"gvisor.dev/gvisor/pkg/tcpip/checksum"
	"gvisor.dev/gvisor/pkg/tcpip/header"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv4"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv6"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
	"gvisor.dev/gvisor/pkg/tcpip/transport/icmp"
	"gvisor.dev/gvisor/pkg/tcpip/transport/tcp"
	"gvisor.dev/gvisor/pkg/tcpip/transport/udp"
	"gvisor.dev/gvisor/pkg/waiter"
)

const (
	defaultNIC tcpip.NICID = 1

	// Elarni: a stalled app or upload keeps its buffer full, and gVisor grew them to 8 and 6 MiB.
	// On a phone, 1 MiB kept upload speed and a 2 MiB send buffer kept download speed (1 MiB cost 9%).
	tcpRXBufMinSize = tcp.MinBufferSize
	tcpRXBufDefSize = tcp.DefaultSendBufferSize
	tcpRXBufMaxSize = 1 << 20

	tcpTXBufMinSize = tcp.MinBufferSize
	tcpTXBufDefSize = tcp.DefaultReceiveBufferSize
	tcpTXBufMaxSize = 2 << 20
)

// stackGVisor is ip stack implemented by gVisor package
type stackGVisor struct {
	ctx         context.Context
	tun         Tun
	idleTimeout time.Duration
	handler     *Handler
	stack       *stack.Stack
	endpoint    stack.LinkEndpoint
	udpHandler  *udpConnectionHandler
}

// closableEndpoint refuses writes once the stack closes. fdbased does not own the
// TUN descriptor, and late UDP replies and TCP retransmits outlive Close: once the
// device closes the descriptor, its number can belong to another file.
type closableEndpoint struct {
	stack.LinkEndpoint
	mu     sync.RWMutex
	closed bool
}

func (e *closableEndpoint) WritePackets(packets stack.PacketBufferList) (int, tcpip.Error) {
	e.mu.RLock()
	defer e.mu.RUnlock()
	if e.closed {
		return 0, &tcpip.ErrClosedForSend{}
	}
	return e.LinkEndpoint.WritePackets(packets)
}

// GSOMaxSize and SupportedGSO pass the device's segmentation offload through,
// which the embedded interface hides from gVisor.
func (e *closableEndpoint) GSOMaxSize() uint32 {
	if device, ok := e.LinkEndpoint.(stack.GSOEndpoint); ok {
		return device.GSOMaxSize()
	}
	return 0
}

func (e *closableEndpoint) SupportedGSO() stack.SupportedGSO {
	if device, ok := e.LinkEndpoint.(stack.GSOEndpoint); ok {
		return device.SupportedGSO()
	}
	return stack.GSONotSupported
}

// closeWrites returns once no write is in progress or can start.
func (e *closableEndpoint) closeWrites() {
	e.mu.Lock()
	e.closed = true
	e.mu.Unlock()
}

// NewStack builds new ip stack (using gVisor)
func NewStack(ctx context.Context, options StackOptions, handler *Handler) (Stack, error) {
	gStack := &stackGVisor{
		ctx:         ctx,
		tun:         options.Tun,
		idleTimeout: options.IdleTimeout,
		handler:     handler,
	}

	return gStack, nil
}

// Start is called by Handler to bring stack to life
func (t *stackGVisor) Start() error {
	device, err := t.tun.newEndpoint()
	if err != nil {
		return err
	}
	linkEndpoint := &closableEndpoint{LinkEndpoint: device}

	ipStack, err := newStack()
	if err != nil {
		return err
	}

	// The forwarder already runs each request in its own goroutine.
	tcpForwarder := tcp.NewForwarder(ipStack, 0, 65535, func(r *tcp.ForwarderRequest) {
		id := r.ID()
		// Admission comes before the handshake (Elarni): a refused SYN gets a RST instead of a connection
		// that takes the app's request and then resets.
		tracked := newActiveConn(nil)
		tracked.touch()
		admitted := t.handler.tcpAdmission.acquire(&tracked.activity, nil)
		if admitted == nil {
			r.Complete(true)
			return
		}

		// Perform a TCP three-way handshake.
		var wq waiter.Queue
		ep, err := r.CreateEndpoint(&wq)
		// The endpoint now owns the connection: free the SYN and the forwarder's in-flight entry (Elarni).
		r.Complete(err != nil)
		if err != nil {
			admitted.release()
			errors.LogError(t.ctx, err.String())
			return
		}

		options := ep.SocketOptions()
		options.SetKeepAlive(false)
		options.SetReuseAddress(true)
		options.SetReusePort(true)

		tracked.Conn = &tcpConn{TCPConn: gonet.NewTCPConn(&wq, ep), ep: ep, wq: &wq}
		t.handler.serve(tracked,
			// local address on the gVisor side is connection destination
			net.TCPDestination(net.IPAddress(id.LocalAddress.AsSlice()), net.Port(id.LocalPort)),
			admitted)

		// close the socket
		ep.Close()
	})
	ipStack.SetTransportProtocolHandler(tcp.ProtocolNumber, tcpForwarder.HandlePacket)

	// Use custom UDP packet handler, instead of strict gVisor forwarder, for FullCone NAT support
	t.udpHandler = newUdpConnectionHandler(t.handler.HandleConnection, t.writeRawUDPPacket)
	ipStack.SetTransportProtocolHandler(udp.ProtocolNumber, t.handleUDPPacket)
	ipStack.SetTransportProtocolHandler(icmp.ProtocolNumber4, t.handleICMPv4Packet)
	ipStack.SetTransportProtocolHandler(icmp.ProtocolNumber6, t.handleICMPv6Packet)

	if err := attachNIC(ipStack, linkEndpoint); err != nil {
		return err
	}

	t.stack = ipStack
	t.endpoint = linkEndpoint

	return nil
}

// handleUDPPacket passes a datagram from tun to its flow, copied once into a pooled buffer (Elarni).
func (t *stackGVisor) handleUDPPacket(id stack.TransportEndpointID, pkt *stack.PacketBuffer) bool {
	data := pkt.Data()
	b := buf.NewWithSize(int32(data.Size()))
	data.ReadTo(b, true)
	// source/destination of the packet we process as incoming, on gVisor side are Remote/Local
	// in other terms, src is the side behind tun, dst is the side behind gVisor
	// this function handle packets passing from the tun to the gVisor, therefore the src/dst assignement
	srcIP := net.IPAddress(id.RemoteAddress.AsSlice())
	dstIP := net.IPAddress(id.LocalAddress.AsSlice())
	if srcIP == nil || dstIP == nil {
		panic(id)
	}
	src := net.UDPDestination(srcIP, net.Port(id.RemotePort))
	dst := net.UDPDestination(dstIP, net.Port(id.LocalPort))
	t.udpHandler.HandlePacket(src, dst, b)
	return true
}

// writeRawUDPPacket builds the reply in one view of its final size, so the payload is copied once (Elarni).
func (t *stackGVisor) writeRawUDPPacket(payload []byte, src net.Destination, dst net.Destination) error {
	udpLen := header.UDPMinimumSize + len(payload)
	srcIP := tcpip.AddrFromSlice(src.Address.IP())
	dstIP := tcpip.AddrFromSlice(dst.Address.IP())

	// build packet with appropriate IP header size
	isIPv4 := dst.Address.Family().IsIPv4()
	ipHdrSize := header.IPv6MinimumSize
	ipProtocol := header.IPv6ProtocolNumber
	if isIPv4 {
		ipHdrSize = header.IPv4MinimumSize
		ipProtocol = header.IPv4ProtocolNumber
	}

	view := buffer.NewViewSize(ipHdrSize + udpLen)
	packet := view.AsSlice()
	copy(packet[ipHdrSize+header.UDPMinimumSize:], payload)

	// Build UDP header
	udpHdr := header.UDP(packet[ipHdrSize:])
	udpHdr.Encode(&header.UDPFields{
		SrcPort: uint16(src.Port),
		DstPort: uint16(dst.Port),
		Length:  uint16(udpLen),
	})

	// Calculate and set UDP checksum; a computed zero goes out as all ones, since zero means none (RFC 768)
	xsum := header.PseudoHeaderChecksum(header.UDPProtocolNumber, srcIP, dstIP, uint16(udpLen))
	if xsum = ^udpHdr.CalculateChecksum(checksum.Checksum(payload, xsum)); xsum == 0 {
		xsum = 0xffff
	}
	udpHdr.SetChecksum(xsum)

	// Build IP header
	if isIPv4 {
		ipHdr := header.IPv4(packet)
		ipHdr.Encode(&header.IPv4Fields{
			TotalLength: uint16(header.IPv4MinimumSize + udpLen),
			TTL:         64,
			Protocol:    uint8(header.UDPProtocolNumber),
			SrcAddr:     srcIP,
			DstAddr:     dstIP,
		})
		ipHdr.SetChecksum(^ipHdr.CalculateChecksum())
	} else {
		ipHdr := header.IPv6(packet)
		ipHdr.Encode(&header.IPv6Fields{
			PayloadLength:     uint16(udpLen),
			TransportProtocol: header.UDPProtocolNumber,
			HopLimit:          64,
			SrcAddr:           srcIP,
			DstAddr:           dstIP,
		})
	}

	// dispatch the packet
	err := t.stack.WriteRawPacket(defaultNIC, ipProtocol, buffer.MakeWithView(view))
	if err != nil {
		return errors.New("failed to write raw udp packet back to stack", err)
	}

	return nil
}

// Close is called by Handler to shut down the stack
func (t *stackGVisor) Close() error {
	if t.stack == nil {
		return nil
	}
	t.endpoint.Attach(nil)
	t.udpHandler.Close()
	t.stack.Close()
	for _, endpoint := range t.stack.CleanupEndpoints() {
		endpoint.Abort()
	}
	// Handler closes the device next.
	if endpoint, ok := t.endpoint.(*closableEndpoint); ok {
		endpoint.closeWrites()
	}

	return nil
}

// The device must be closed first so a blocked packet reader can exit. Only the
// reader is joined: a TCP handshake that registered after Close resends for
// about two minutes, and stack.Wait would wait for it.
func (t *stackGVisor) Wait() {
	if t.endpoint != nil {
		t.endpoint.Wait()
	}
}

// createStack configure gVisor ip stack
func createStack(ep stack.LinkEndpoint) (*stack.Stack, error) {
	gStack, err := newStack()
	if err != nil {
		return nil, err
	}
	if err := attachNIC(gStack, ep); err != nil {
		return nil, err
	}
	return gStack, nil
}

// attachNIC starts the device's packet reader, so the stack must be complete,
// handlers included: a reader started earlier delivers to a half-built stack.
func attachNIC(gStack *stack.Stack, ep stack.LinkEndpoint) error {
	if err := gStack.CreateNIC(defaultNIC, ep); err != nil {
		return errors.New(err.String())
	}

	gStack.SetRouteTable([]tcpip.Route{
		{Destination: header.IPv4EmptySubnet, NIC: defaultNIC},
		{Destination: header.IPv6EmptySubnet, NIC: defaultNIC},
	})

	if err := gStack.SetSpoofing(defaultNIC, true); err != nil {
		return errors.New(err.String())
	}
	if err := gStack.SetPromiscuousMode(defaultNIC, true); err != nil {
		return errors.New(err.String())
	}
	return nil
}

func newStack() (*stack.Stack, error) {
	opts := stack.Options{
		NetworkProtocols:   []stack.NetworkProtocolFactory{ipv4.NewProtocol, ipv6.NewProtocol},
		TransportProtocols: []stack.TransportProtocolFactory{tcp.NewProtocol, udp.NewProtocol, icmp.NewProtocol4, icmp.NewProtocol6},
		HandleLocal:        false,
	}
	gStack := stack.New(opts)

	cOpt := tcpip.CongestionControlOption("cubic")
	gStack.SetTransportProtocolOption(tcp.ProtocolNumber, &cOpt)
	sOpt := tcpip.TCPSACKEnabled(true)
	gStack.SetTransportProtocolOption(tcp.ProtocolNumber, &sOpt)
	mOpt := tcpip.TCPModerateReceiveBufferOption(true)
	gStack.SetTransportProtocolOption(tcp.ProtocolNumber, &mOpt)

	// Disable RACK/TLP loss recovery to fix connection stalls under high load
	rOpt := tcpip.TCPRecovery(0)
	gStack.SetTransportProtocolOption(tcp.ProtocolNumber, &rOpt)

	// The stack closes first for blocked sites and servers that close; the app's kernel then frees the port at once
	// and may reuse it. A SYN meeting a TIME_WAIT endpoint is handed only to a listener, never to the forwarder, so
	// that connect would hang for the whole TIME_WAIT (60 s). The TUN link has no stale duplicates for it to absorb.
	twOpt := tcpip.TCPTimeWaitTimeoutOption(0)
	if err := gStack.SetTransportProtocolOption(tcp.ProtocolNumber, &twOpt); err != nil {
		return nil, errors.New(err.String())
	}

	tcpRXBufOpt := tcpip.TCPReceiveBufferSizeRangeOption{
		Min:     tcpRXBufMinSize,
		Default: tcpRXBufDefSize,
		Max:     tcpRXBufMaxSize,
	}
	err := gStack.SetTransportProtocolOption(tcp.ProtocolNumber, &tcpRXBufOpt)
	if err != nil {
		return nil, errors.New(err.String())
	}

	tcpTXBufOpt := tcpip.TCPSendBufferSizeRangeOption{
		Min:     tcpTXBufMinSize,
		Default: tcpTXBufDefSize,
		Max:     tcpTXBufMaxSize,
	}
	err = gStack.SetTransportProtocolOption(tcp.ProtocolNumber, &tcpTXBufOpt)
	if err != nil {
		return nil, errors.New(err.String())
	}

	return gStack, nil
}
