//go:build android

package libXray

import (
	xinternet "github.com/xtls/xray-core/transport/internet"
	"net"
	"syscall"
	"testing"
)

type androidTestController bool

func (c androidTestController) ProtectFd(int) bool { return bool(c) }

// Successful traffic cannot prove that a denied protection callback propagates.
func TestAndroidRequiredSocketProtection(t *testing.T) {
	socket, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer socket.Close()
	raw, err := socket.(syscall.Conn).SyscallConn()
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 3; i++ {
		SetAndroidSocketController(androidTestController(false))
		if err := xinternet.RequiredSocketController("udp", "127.0.0.1:53", raw); err == nil {
			t.Fatal("protection denial was ignored")
		}
		SetAndroidSocketController(androidTestController(true))
		if err := xinternet.RequiredSocketController("udp", "127.0.0.1:53", raw); err != nil {
			t.Fatal(err)
		}
	}
}
