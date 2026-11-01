//go:build windows

package tun

import (
	"bytes"
	"encoding/binary"
	"errors"
	"os"
	"testing"

	"golang.zx2c4.com/wintun"
	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/checksum"
	"gvisor.dev/gvisor/pkg/tcpip/header"
)

// synPacket builds a TCP packet from 100.127.255.2 (or fd76:6f75:7465::2) with a valid checksum.
func synPacket(ipv6 bool, ttl uint8, flags header.TCPFlags, options []byte) []byte {
	segment := make([]byte, header.TCPMinimumSize+len(options))
	header.TCP(segment).Encode(&header.TCPFields{SrcPort: 40000, DstPort: 443, SeqNum: 1, Flags: flags,
		DataOffset: uint8(len(segment)), WindowSize: 64240})
	copy(segment[header.TCPMinimumSize:], options)
	var packet []byte
	var src, dst tcpip.Address
	if ipv6 {
		src, dst = tcpip.AddrFrom16([16]byte{0xfd, 0x76, 0x6f, 0x75, 0x74, 0x65, 15: 2}), tcpip.AddrFrom16([16]byte{0x26, 0x06, 4, 0x70, 15: 1})
		packet = make([]byte, header.IPv6MinimumSize, header.IPv6MinimumSize+len(segment))
		header.IPv6(packet).Encode(&header.IPv6Fields{PayloadLength: uint16(len(segment)), TransportProtocol: header.TCPProtocolNumber,
			HopLimit: ttl, SrcAddr: src, DstAddr: dst})
	} else {
		src, dst = tcpip.AddrFrom4([4]byte{100, 127, 255, 2}), tcpip.AddrFrom4([4]byte{1, 1, 1, 1})
		packet = make([]byte, header.IPv4MinimumSize, header.IPv4MinimumSize+len(segment))
		ip := header.IPv4(packet)
		ip.Encode(&header.IPv4Fields{TotalLength: uint16(header.IPv4MinimumSize + len(segment)), TTL: ttl,
			Protocol: uint8(header.TCPProtocolNumber), SrcAddr: src, DstAddr: dst})
		ip.SetChecksum(^ip.CalculateChecksum())
	}
	xsum := header.PseudoHeaderChecksum(header.TCPProtocolNumber, src, dst, uint16(len(segment)))
	header.TCP(segment).SetChecksum(^checksum.Checksum(segment, xsum))
	return append(packet, segment...)
}

func tcpChecksumValid(t *testing.T, packet []byte) bool {
	t.Helper()
	var segment []byte
	var src, dst tcpip.Address
	if packet[0]>>4 == 6 {
		ip := header.IPv6(packet)
		segment, src, dst = packet[header.IPv6MinimumSize:], ip.SourceAddress(), ip.DestinationAddress()
	} else {
		ip := header.IPv4(packet)
		segment, src, dst = packet[ip.HeaderLength():], ip.SourceAddress(), ip.DestinationAddress()
	}
	xsum := header.PseudoHeaderChecksum(header.TCPProtocolNumber, src, dst, uint16(len(segment)))
	return checksum.Checksum(segment, xsum) == 0xffff
}

func mssOption(mss uint16) []byte {
	return binary.BigEndian.AppendUint16([]byte{header.TCPOptionMSS, header.TCPOptionMSSLength}, mss)
}

// A WSL guest in mirrored mode inherits MTU 9000 but receives only 1500-byte frames.
func TestClampGuestMSS(t *testing.T) {
	linux := append(append(mssOption(8960), 4, 2, 8, 10), make([]byte, 8)...)
	linux = append(linux, 1, 3, 3, 7)
	for _, test := range []struct {
		name   string
		packet []byte
		mss    uint16
	}{
		{"IPv4 guest SYN", synPacket(false, 64, header.TCPFlagSyn, linux), 1460},
		{"IPv4 guest SYN after a forwarding hop", synPacket(false, 63, header.TCPFlagSyn, linux), 1460},
		{"IPv6 guest SYN", synPacket(true, 64, header.TCPFlagSyn, append(mssOption(8940), 1, 1, 4, 2)), 1440},
		{"MSS at an odd offset", synPacket(false, 64, header.TCPFlagSyn, append([]byte{1}, append(mssOption(8960), 1, 1, 1)...)), 1460},
		{"Windows SYN keeps jumbo segments", synPacket(false, 128, header.TCPFlagSyn, append(mssOption(8960), 1, 3, 3, 8)), 8960},
		{"Windows IPv6 SYN keeps jumbo segments", synPacket(true, 128, header.TCPFlagSyn, append(mssOption(8940), 1, 1, 4, 2)), 8940},
		{"guest MSS already fits", synPacket(false, 64, header.TCPFlagSyn, append(mssOption(1400), 1, 1, 4, 2)), 1400},
		{"SYN-ACK", synPacket(false, 64, header.TCPFlagSyn|header.TCPFlagAck, append(mssOption(8960), 1, 1, 4, 2)), 8960},
		{"not a SYN", synPacket(false, 64, header.TCPFlagAck, append(mssOption(8960), 1, 1, 4, 2)), 8960},
	} {
		t.Run(test.name, func(t *testing.T) {
			clampGuestMSS(test.packet)
			segment := test.packet[header.IPv4MinimumSize:]
			if test.packet[0]>>4 == 6 {
				segment = test.packet[header.IPv6MinimumSize:]
			}
			offset := bytes.Index(segment[header.TCPMinimumSize:], []byte{header.TCPOptionMSS, header.TCPOptionMSSLength})
			if got := binary.BigEndian.Uint16(segment[header.TCPMinimumSize+offset+2:]); got != test.mss {
				t.Fatalf("MSS %d, want %d", got, test.mss)
			}
			if !tcpChecksumValid(t, test.packet) {
				t.Fatal("TCP checksum invalid after the clamp")
			}
		})
	}
}

// Option walking must stop at the header end on malformed or truncated packets.
func TestClampGuestMSSIgnoresMalformedPackets(t *testing.T) {
	for name, packet := range map[string][]byte{
		"zero option length":     synPacket(false, 64, header.TCPFlagSyn, []byte{8, 0, 0, 0}),
		"option past the header": synPacket(false, 64, header.TCPFlagSyn, []byte{1, 1, 8, 10}),
		"short MSS option":       synPacket(false, 64, header.TCPFlagSyn, []byte{2, 3, 0x23, 0}),
		"options after EOL":      synPacket(false, 64, header.TCPFlagSyn, append([]byte{0, 0, 0, 0}, mssOption(8960)...)),
		"truncated IPv4":         synPacket(false, 64, header.TCPFlagSyn, mssOption(8960))[:30],
		"truncated IPv6":         synPacket(true, 64, header.TCPFlagSyn, mssOption(8960))[:50],
		"empty":                  {},
	} {
		t.Run(name, func(t *testing.T) {
			before := bytes.Clone(packet)
			clampGuestMSS(packet)
			if !bytes.Equal(packet, before) {
				t.Fatalf("malformed packet changed:\n%x\n%x", before, packet)
			}
		})
	}
	// A data offset larger than the segment must not be read past.
	packet := synPacket(false, 64, header.TCPFlagSyn, mssOption(8960))
	packet[header.IPv4MinimumSize+12] = 15 << 4
	before := bytes.Clone(packet)
	clampGuestMSS(packet)
	if !bytes.Equal(packet, before) {
		t.Fatal("packet with an oversized data offset changed")
	}
}

// A reconnect in the same helper must take the parked adapter, not create one.
func TestWindowsTunUnparkReusesTheParkedAdapter(t *testing.T) {
	kept := &wintun.Adapter{}
	parked.name, parked.adapter = "elarni-test", kept
	t.Cleanup(func() { parked.name, parked.adapter = "", nil })
	adapter, err := unpark("elarni-test", "Elarni")
	if err != nil || adapter != kept {
		t.Fatalf("unpark = %p, %v; want the parked adapter %p", adapter, err, kept)
	}
	if parked.adapter != nil {
		t.Fatal("the adapter stayed parked while in use")
	}
}

func TestWindowsTunClosedOperationsDoNotUseNativeSession(t *testing.T) {
	device := &WindowsTun{}
	device.closed.Store(true)
	if _, _, err := device.ReadPacket(); !errors.Is(err, os.ErrClosed) {
		t.Fatalf("closed read: %v", err)
	}
	device.Wait()
	if err := device.WritePacket(nil); err == nil {
		t.Fatal("closed write accepted")
	}
}
