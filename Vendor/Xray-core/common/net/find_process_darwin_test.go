//go:build darwin && !ios

package net

import (
	"encoding/binary"
	"net/netip"
	"testing"

	"golang.org/x/sys/unix"
)

func TestDarwinSocketTableBoundsAndOwnership(t *testing.T) {
	// Synthetic XNU xinpgen, xinpcb_n, padded xsocket_n, xinpgen.
	fixture := make([]byte, 24+104+80+24)
	put32 := binary.NativeEndian.PutUint32
	put64 := binary.NativeEndian.PutUint64
	put32(fixture, 24)
	put64(fixture[8:], 10)
	pcb, socket := fixture[24:128], fixture[128:208]
	put32(pcb, 104)
	put32(pcb[4:], 0x10)
	put64(pcb[8:], 7)
	binary.BigEndian.PutUint16(pcb[16:], 443)
	binary.BigEndian.PutUint16(pcb[18:], 0x1234)
	put64(pcb[28:], 10)
	pcb[44] = 1
	copy(pcb[60:64], []byte{198, 51, 100, 9})
	copy(pcb[76:80], []byte{192, 0, 2, 2})
	put32(socket, 76)
	put32(socket[4:], 1)
	put64(socket[28:], 7)
	put32(socket[36:], unix.IPPROTO_TCP)
	put32(socket[40:], unix.AF_INET)
	put32(socket[68:], 123)
	put32(fixture[208:], 24)
	src, dst := netip.MustParseAddr("192.0.2.2"), netip.MustParseAddr("198.51.100.9")
	for _, tc := range []struct {
		name    string
		edit    func([]byte)
		pid     int32
		invalid bool
	}{
		{"ordinary owner", func([]byte) {}, 123, false},
		{"delegated owner", func(b []byte) { put32(b[128+72:], 456) }, 456, false},
		{"byte-swapped port", func(b []byte) { binary.LittleEndian.PutUint16(b[24+18:], 0x1234) }, 0, false},
		{"other peer", func(b []byte) { b[24+63]++ }, 0, false},
		{"new generation", func(b []byte) { put64(b[24+28:], 11) }, 0, false},
		{"unrelated PCB", func(b []byte) { put64(b[128+28:], 8) }, 0, false},
		{"short header", func(b []byte) { put32(b, 8) }, 0, true},
		{"zero record", func(b []byte) { put32(b[24:], 0) }, 0, true},
		{"short socket", func(b []byte) { put32(b[128:], 64) }, 0, true},
		{"oversized record", func(b []byte) { put32(b[24:], 0xffffffff) }, 0, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			data := append([]byte(nil), fixture...)
			tc.edit(data)
			pid, err := darwinSocketPID(data, "tcp", src, 0x1234, dst, 443)
			if pid != tc.pid || (err != nil) != tc.invalid {
				t.Fatalf("pid=%d err=%v", pid, err)
			}
		})
	}
	for _, end := range []int{len(fixture) - 1, 208} {
		if _, err := darwinSocketPID(fixture[:end], "tcp", src, 0x1234, dst, 443); err == nil {
			t.Fatal("truncated footer accepted")
		}
	}
}
