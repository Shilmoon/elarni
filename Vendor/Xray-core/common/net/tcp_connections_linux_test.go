//go:build linux && !android

package net

import (
	"net/netip"
	"testing"
)

func TestProcNetTCPReadsEstablishedEntries(t *testing.T) {
	table := []byte(`  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 1111 1 0000000000000000 100 0 0 10 0
   1: 0100007F:C350 0100007F:1F90 01 00000000:00000000 00:00000000 00000000  1000        0 2222 1 0000000000000000 20 4 30 10 -1
   2: 0100007F:C351 0100007F:1F90 06 00000000:00000000 03:00000000 00000000     0        0 0 3 0000000000000000
`)
	entries := procNetTCP(table)
	if len(entries) != 1 || entries[0].inode != "2222" ||
		entries[0].Local != netip.MustParseAddrPort("127.0.0.1:50000") || entries[0].Remote != netip.MustParseAddrPort("127.0.0.1:8080") {
		t.Fatalf("entries %+v", entries)
	}
	ipv6 := []byte(`  sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 00000000000000000000000001000000:C350 0000000000000000FFFF00000100007F:01BB 01 00000000:00000000 00:00000000 00000000  1000        0 3333 1 0000000000000000 20 4 30 10 -1
`)
	entries = procNetTCP(ipv6)
	if len(entries) != 1 || entries[0].Local != netip.MustParseAddrPort("[::1]:50000") ||
		entries[0].Remote != netip.MustParseAddrPort("[::ffff:127.0.0.1]:443") {
		t.Fatalf("entries %+v", entries)
	}
}
