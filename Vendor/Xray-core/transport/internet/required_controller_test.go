package internet

import (
	"context"
	"errors"
	"syscall"
	"testing"

	"github.com/xtls/xray-core/common/net"
)

func TestRequiredControllerPreventsUnboundTraffic(t *testing.T) {
	previous := RequiredSocketController
	defer func() { RequiredSocketController = previous }()
	denied := errors.New("required-interface-unavailable")
	for _, destination := range []net.Destination{
		net.TCPDestination(net.ParseAddress("127.0.0.1"), 443),
		net.UDPDestination(net.ParseAddress("127.0.0.1"), 53),
		net.UDPDestination(net.ParseAddress("::1"), 53),
	} {
		called := false
		RequiredSocketController = func(network, address string, conn syscall.RawConn) error {
			called = true
			if address != destination.NetAddr() {
				t.Errorf("controller received %s, expected peer %s", address, destination.NetAddr())
			}
			return denied
		}
		connection, err := (&DefaultSystemDialer{}).Dial(context.Background(), nil, destination, nil)
		if connection != nil {
			connection.Close()
			t.Fatal("traffic escaped required binding")
		}
		if !called || !errors.Is(err, denied) {
			t.Fatalf("required binding was ignored: %v", err)
		}
	}
}
