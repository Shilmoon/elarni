//go:build linux && !android

package tun

import (
	"encoding/binary"
	"sync"

	"golang.org/x/sys/unix"
	"gvisor.dev/gvisor/pkg/buffer"
	"gvisor.dev/gvisor/pkg/rawfile"
	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/header"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
)

const (
	vnetHdrSize = 10 // struct virtio_net_hdr
	// The largest IP packet, and so the largest TCP segment either side hands over.
	vnetGSOMaxSize = 65535
)

// vnetEndpoint is the gVisor link endpoint of a TUN opened with IFF_VNET_HDR and
// TCP segmentation offload. The kernel hands over the TCP segments its apps send
// at up to 64 KiB, unsplit and with partial checksums, and splits and checksums the
// segments gVisor writes, so a bulk transfer takes one read or write per 64 KiB
// instead of one per MTU-sized packet. fdbased offers host GSO only on sockets
// with an Ethernet header.
type vnetEndpoint struct {
	fd  int
	efd int // wakes the reader to stop
	mtu uint32

	mu      sync.Mutex
	reading bool
	readers sync.WaitGroup
	closed  sync.Once
}

var _ stack.GSOEndpoint = (*vnetEndpoint)(nil)

func newVnetEndpoint(fd int, mtu uint32) (*vnetEndpoint, error) {
	// The reader's readv is a raw syscall: blocking in it would stall the Go runtime.
	if err := unix.SetNonblock(fd, true); err != nil {
		return nil, err
	}
	efd, err := unix.Eventfd(0, unix.EFD_NONBLOCK|unix.EFD_CLOEXEC)
	if err != nil {
		return nil, err
	}
	return &vnetEndpoint{fd: fd, efd: efd, mtu: mtu}, nil
}

func (e *vnetEndpoint) MTU() uint32                             { return e.mtu }
func (e *vnetEndpoint) SetMTU(uint32)                           {}
func (e *vnetEndpoint) MaxHeaderLength() uint16                 { return 0 }
func (e *vnetEndpoint) LinkAddress() tcpip.LinkAddress          { return "" }
func (e *vnetEndpoint) SetLinkAddress(tcpip.LinkAddress)        {}
func (e *vnetEndpoint) ARPHardwareType() header.ARPHardwareType { return header.ARPHardwareNone }
func (e *vnetEndpoint) AddHeader(*stack.PacketBuffer)           {}
func (e *vnetEndpoint) ParseHeader(*stack.PacketBuffer) bool    { return true }
func (e *vnetEndpoint) SetOnCloseAction(func())                 {}
func (e *vnetEndpoint) GSOMaxSize() uint32                      { return vnetGSOMaxSize }
func (e *vnetEndpoint) SupportedGSO() stack.SupportedGSO        { return stack.HostGSOSupported }

// Capabilities: segments from the kernel may carry partial checksums.
func (e *vnetEndpoint) Capabilities() stack.LinkEndpointCapabilities {
	return stack.CapabilityRXChecksumOffload
}

func (e *vnetEndpoint) Attach(dispatcher stack.NetworkDispatcher) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if dispatcher == nil {
		e.stop()
		return
	}
	if e.reading {
		return
	}
	e.reading = true
	e.readers.Add(1)
	go func() {
		defer e.readers.Done()
		e.dispatchLoop(dispatcher)
	}()
}

func (e *vnetEndpoint) IsAttached() bool {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.reading
}

func (e *vnetEndpoint) stop() {
	if e.reading {
		e.reading = false
		var one [8]byte
		binary.NativeEndian.PutUint64(one[:], 1)
		_, _ = unix.Write(e.efd, one[:])
	}
}

func (e *vnetEndpoint) Close() {
	e.Attach(nil)
}

// Wait returns once the reader stopped; nothing uses the eventfd after that.
func (e *vnetEndpoint) Wait() {
	e.readers.Wait()
	e.closed.Do(func() { _ = unix.Close(e.efd) })
}

func (e *vnetEndpoint) dispatchLoop(dispatcher stack.NetworkDispatcher) {
	var vnet [vnetHdrSize]byte
	// One reused buffer: packets are copied out at their own size, so a queued
	// ACK never pins 64 KiB. An IPv6 segment carries up to 64 KiB after its header.
	data := make([]byte, header.IPv6MinimumSize+vnetGSOMaxSize)
	iovecs := []unix.Iovec{{Base: &vnet[0]}, {Base: &data[0]}}
	iovecs[0].SetLen(len(vnet))
	iovecs[1].SetLen(len(data))
	for {
		n, errno := rawfile.BlockingReadvUntilStopped(e.efd, e.fd, iovecs)
		if n < 0 || (errno != 0 && errno != unix.EINTR) {
			return // stopped, or the TUN is gone
		}
		// The header only describes the offloads, and gVisor neither splits
		// segments nor looks at their checksums.
		n -= vnetHdrSize
		if n <= 0 {
			continue
		}
		var protocol tcpip.NetworkProtocolNumber
		switch data[0] >> 4 {
		case 4:
			protocol = header.IPv4ProtocolNumber
		case 6:
			protocol = header.IPv6ProtocolNumber
		default:
			continue
		}
		packet := stack.NewPacketBuffer(stack.PacketBufferOptions{Payload: buffer.MakeWithData(data[:n])})
		dispatcher.DeliverNetworkPacket(protocol, packet)
		packet.DecRef()
	}
}

func (e *vnetEndpoint) WritePackets(packets stack.PacketBufferList) (int, tcpip.Error) {
	for n, packet := range packets.AsSlice() {
		if err := e.writePacket(packet); err != nil {
			return n, err
		}
	}
	return packets.Len(), nil
}

func (e *vnetEndpoint) writePacket(packet *stack.PacketBuffer) tcpip.Error {
	var vnet [vnetHdrSize]byte
	if gso := packet.GSOOptions; gso.Type == stack.GSOTCPv4 || gso.Type == stack.GSOTCPv6 {
		if gso.NeedsCsum {
			// gVisor left the pseudo-header sum; the kernel completes it from csum_start.
			vnet[0] = unix.VIRTIO_NET_HDR_F_NEEDS_CSUM
			binary.NativeEndian.PutUint16(vnet[6:], gso.L3HdrLen)
			binary.NativeEndian.PutUint16(vnet[8:], gso.CsumOffset)
		}
		binary.NativeEndian.PutUint16(vnet[2:], uint16(packet.HeaderSize()))
		if packet.Data().Size() > int(gso.MSS) {
			vnet[1] = unix.VIRTIO_NET_HDR_GSO_TCPV4
			if gso.Type == stack.GSOTCPv6 {
				vnet[1] = unix.VIRTIO_NET_HDR_GSO_TCPV6
			}
			binary.NativeEndian.PutUint16(vnet[4:], gso.MSS)
		}
	}
	slices := packet.AsSlices()
	iovecs := make([]unix.Iovec, 0, len(slices)+1)
	iovecs = append(iovecs, unix.Iovec{Base: &vnet[0]})
	iovecs[0].SetLen(len(vnet))
	for _, s := range slices {
		if len(s) == 0 {
			continue
		}
		iovec := unix.Iovec{Base: &s[0]}
		iovec.SetLen(len(s))
		iovecs = append(iovecs, iovec)
	}
	if errno := rawfile.NonBlockingWriteIovec(e.fd, iovecs); errno != 0 {
		return tcpip.TranslateErrno(errno)
	}
	return nil
}
