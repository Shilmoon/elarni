package tun

import (
	"bytes"
	"encoding/binary"
	"testing"
)

// onesSum is a plain RFC 1071 sum, independent of the stack's checksum code.
func onesSum(chunks ...[]byte) uint16 {
	var s uint32
	for _, b := range chunks {
		for i := 0; i+1 < len(b); i += 2 {
			s += uint32(b[i])<<8 | uint32(b[i+1])
		}
		if len(b)%2 == 1 {
			s += uint32(b[len(b)-1]) << 8
		}
	}
	for s > 0xffff {
		s = s&0xffff + s>>16
	}
	return uint16(s)
}

func pseudoHeader(packet []byte, size int) []byte {
	addresses := packet[12:20]
	if packet[0]>>4 == 6 {
		addresses = packet[8:40]
	}
	return append(bytes.Clone(addresses), 0, protoTCP, byte(size>>8), byte(size))
}

// synPacket builds a TCP packet from 100.127.255.2 (or fd76:6f75:7465::2) with a valid checksum.
func synPacket(ipv6 bool, ttl uint8, flags byte, options []byte) []byte {
	segment := make([]byte, tcpHeaderSize+len(options))
	binary.BigEndian.PutUint16(segment[0:], 40000)
	binary.BigEndian.PutUint16(segment[2:], 443)
	binary.BigEndian.PutUint32(segment[4:], 1)
	segment[12], segment[13] = byte(len(segment)/4)<<4, flags
	binary.BigEndian.PutUint16(segment[14:], 64240)
	copy(segment[tcpHeaderSize:], options)
	var packet []byte
	if ipv6 {
		packet = make([]byte, ipv6HeaderSize)
		packet[0] = 6 << 4
		binary.BigEndian.PutUint16(packet[4:], uint16(len(segment)))
		packet[6], packet[7] = protoTCP, ttl
		copy(packet[8:], []byte{0xfd, 0x76, 0x6f, 0x75, 0x74, 0x65, 15: 2})
		copy(packet[24:], []byte{0x26, 0x06, 4, 0x70, 15: 1})
	} else {
		packet = make([]byte, ipv4HeaderSize)
		packet[0] = 4<<4 | 5
		binary.BigEndian.PutUint16(packet[2:], uint16(ipv4HeaderSize+len(segment)))
		packet[8], packet[9] = ttl, protoTCP
		copy(packet[12:], []byte{100, 127, 255, 2, 1, 1, 1, 1})
		binary.BigEndian.PutUint16(packet[10:], ^onesSum(packet))
	}
	binary.BigEndian.PutUint16(segment[16:], ^onesSum(pseudoHeader(packet, len(segment)), segment))
	return append(packet, segment...)
}

func synSegment(packet []byte) []byte {
	if packet[0]>>4 == 6 {
		return packet[ipv6HeaderSize:]
	}
	return packet[ipv4HeaderSize:]
}

func mssOption(mss uint16) []byte { return binary.BigEndian.AppendUint16([]byte{2, 4}, mss) }

// A WSL guest in mirrored mode inherits MTU 9000 but receives only 1500-byte frames.
func TestClampGuestMSS(t *testing.T) {
	const syn, ack = 0x02, 0x10
	linux := append(append(mssOption(8960), 4, 2, 8, 10), make([]byte, 8)...)
	linux = append(linux, 1, 3, 3, 7)
	for _, test := range []struct {
		name   string
		packet []byte
		mss    uint16
	}{
		{"IPv4 guest SYN", synPacket(false, 64, syn, linux), 1460},
		{"IPv4 guest SYN after a forwarding hop", synPacket(false, 63, syn, linux), 1460},
		{"IPv6 guest SYN", synPacket(true, 64, syn, append(mssOption(8940), 1, 1, 4, 2)), 1440},
		{"MSS at an odd offset", synPacket(false, 64, syn, append([]byte{1}, append(mssOption(8960), 1, 1, 1)...)), 1460},
		{"Windows SYN keeps jumbo segments", synPacket(false, 128, syn, append(mssOption(8960), 1, 3, 3, 8)), 8960},
		{"Windows IPv6 SYN keeps jumbo segments", synPacket(true, 128, syn, append(mssOption(8940), 1, 1, 4, 2)), 8940},
		{"guest MSS already fits", synPacket(false, 64, syn, append(mssOption(1400), 1, 1, 4, 2)), 1400},
		{"SYN-ACK", synPacket(false, 64, syn|ack, append(mssOption(8960), 1, 1, 4, 2)), 8960},
		{"not a SYN", synPacket(false, 64, ack, append(mssOption(8960), 1, 1, 4, 2)), 8960},
	} {
		t.Run(test.name, func(t *testing.T) {
			clampGuestMSS(test.packet)
			segment := synSegment(test.packet)
			offset := bytes.Index(segment[tcpHeaderSize:], []byte{2, 4})
			if got := binary.BigEndian.Uint16(segment[tcpHeaderSize+offset+2:]); got != test.mss {
				t.Fatalf("MSS %d, want %d", got, test.mss)
			}
			if onesSum(pseudoHeader(test.packet, len(segment)), segment) != 0xffff {
				t.Fatal("TCP checksum invalid after the clamp")
			}
		})
	}
}

// Option walking must stop at the header end on malformed or truncated packets.
func TestClampGuestMSSIgnoresMalformedPackets(t *testing.T) {
	const syn = 0x02
	for name, packet := range map[string][]byte{
		"zero option length":     synPacket(false, 64, syn, []byte{8, 0, 0, 0}),
		"option past the header": synPacket(false, 64, syn, []byte{1, 1, 8, 10}),
		"short MSS option":       synPacket(false, 64, syn, []byte{2, 3, 0x23, 0}),
		"options after EOL":      synPacket(false, 64, syn, append([]byte{0, 0, 0, 0}, mssOption(8960)...)),
		"truncated IPv4":         synPacket(false, 64, syn, mssOption(8960))[:30],
		"truncated IPv6":         synPacket(true, 64, syn, mssOption(8960))[:50],
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
	packet := synPacket(false, 64, syn, mssOption(8960))
	packet[ipv4HeaderSize+12] = 15 << 4
	before := bytes.Clone(packet)
	clampGuestMSS(packet)
	if !bytes.Equal(packet, before) {
		t.Fatal("packet with an oversized data offset changed")
	}
}
