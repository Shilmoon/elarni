package tun

import (
	"encoding/binary"
	"math/bits"
)

// clampGuestMSS caps the MSS of a TCP SYN that the Windows stack did not send at what
// a 1500-byte frame carries (Elarni). WSL's mirrored networking gives its guest the TUN's
// MTU, but drops larger replies to it without ICMP (microsoft/WSL#41419). Windows sends
// with TTL 128 and keeps jumbo segments; other senders sit behind a 1500-byte link.
// The guest's own jumbo frames do reach the TUN, so the stack's SYN-ACK keeps its MSS.
func clampGuestMSS(packet []byte) {
	var segment []byte
	limit := uint16(1500 - ipv4HeaderSize - tcpHeaderSize)
	switch {
	case len(packet) >= ipv4HeaderSize && packet[0]>>4 == 4:
		length, total := int(packet[0]&0xf)*4, int(binary.BigEndian.Uint16(packet[2:]))
		if packet[8] >= 128 || packet[9] != protoTCP || binary.BigEndian.Uint16(packet[6:])&0x1fff != 0 ||
			length < ipv4HeaderSize || total < length || total > len(packet) {
			return
		}
		segment = packet[length:total]
	case len(packet) >= ipv6HeaderSize && packet[0]>>4 == 6:
		total := ipv6HeaderSize + int(binary.BigEndian.Uint16(packet[4:]))
		if packet[7] >= 128 || packet[6] != protoTCP || total > len(packet) {
			return
		}
		segment = packet[ipv6HeaderSize:total]
		limit = 1500 - ipv6HeaderSize - tcpHeaderSize
	default:
		return
	}
	if len(segment) < tcpHeaderSize {
		return
	}
	const syn, ack = 0x02, 0x10
	offset := int(segment[12]>>4) * 4
	if segment[13]&(syn|ack) != syn || offset < tcpHeaderSize || offset > len(segment) {
		return
	}
	for at := tcpHeaderSize; at < offset; {
		switch segment[at] {
		case 0: // end of options
			return
		case 1: // no-operation
			at++
			continue
		}
		if at+1 >= offset || segment[at+1] < 2 || at+int(segment[at+1]) > offset {
			return
		}
		if segment[at] == 2 && segment[at+1] == 4 { // MSS
			old := binary.BigEndian.Uint16(segment[at+2:])
			if old <= limit {
				return
			}
			binary.BigEndian.PutUint16(segment[at+2:], limit)
			// Incremental update (RFC 1624); a field at an odd offset sums byte-swapped.
			before, after := old, limit
			if at%2 == 1 {
				before, after = bits.ReverseBytes16(before), bits.ReverseBytes16(after)
			}
			sum := ^binary.BigEndian.Uint16(segment[16:])
			binary.BigEndian.PutUint16(segment[16:], checksum(uint64(sum)+uint64(^before)+uint64(after)))
			return
		}
		at += int(segment[at+1])
	}
}
