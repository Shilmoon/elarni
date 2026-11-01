package socks_test

import (
	"errors"
	"net"
	"testing"
	"time"

	"github.com/xtls/xray-core/proxy/socks"
)

func TestTempUDPConnClosesBeforeAndAfterTimeoutSetup(t *testing.T) {
	for _, timeout := range []time.Duration{-1, 0, time.Minute} {
		t.Run(timeout.String(), func(t *testing.T) {
			udp, err := net.ListenPacket("udp4", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			defer udp.Close()
			left, right := net.Pipe()
			defer left.Close()
			defer right.Close()
			conn := socks.NewTempUDPConn(udp, left, &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
			defer func() {
				if value := recover(); value != nil {
					t.Fatalf("closing UDP association panicked: %v", value)
				}
			}()
			if timeout >= 0 {
				conn.SetTimeout(timeout)
			}
			conn.Close()
			if _, _, err := udp.ReadFrom(make([]byte, 1)); !errors.Is(err, net.ErrClosed) {
				t.Fatalf("UDP socket not closed: %v", err)
			}
			if _, err := right.Read(make([]byte, 1)); err == nil {
				t.Fatal("associated TCP stream not closed")
			}
		})
	}
}
