package wireguard

import (
	"sync"

	awgconn "github.com/amnezia-vpn/amneziawg-go/v3/conn"
	awgtun "github.com/amnezia-vpn/amneziawg-go/v3/tun"
	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/tun"
)

// Both engines use Xray's netstack and protected socket path. Only the named
// interface types differ; the standard WireGuard engine remains unchanged.
type tunnelDevice interface {
	Up() error
	Down() error
	BindUpdate() error
	IpcSet(string) error
	Close()
}

type amneziaTUN struct {
	tun.Device
	events chan awgtun.Event
	done   chan struct{}
	once   sync.Once
	err    error
}

func adaptAmneziaTUN(device tun.Device) *amneziaTUN {
	t := &amneziaTUN{Device: device, events: make(chan awgtun.Event), done: make(chan struct{})}
	go func() {
		defer close(t.events)
		for {
			select {
			case <-t.done:
				return
			case event, ok := <-device.Events():
				if !ok {
					return
				}
				select {
				case t.events <- awgtun.Event(event):
				case <-t.done:
					return
				}
			}
		}
	}()
	return t
}

func (t *amneziaTUN) Events() <-chan awgtun.Event { return t.events }
func (t *amneziaTUN) Close() error {
	t.once.Do(func() { close(t.done); t.err = t.Device.Close() })
	return t.err
}

type amneziaBind struct{ *bind }

func (b *amneziaBind) Open(port uint16) ([]awgconn.ReceiveFunc, uint16, error) {
	functions, actual, err := b.bind.Open(port)
	if err != nil {
		return nil, actual, err
	}
	converted := make([]awgconn.ReceiveFunc, len(functions))
	for i, receive := range functions {
		converted[i] = func(packets [][]byte, sizes []int, endpoints []awgconn.Endpoint) (int, error) {
			original := make([]conn.Endpoint, len(endpoints))
			n, err := receive(packets, sizes, original)
			for j := 0; j < n; j++ {
				endpoints[j] = original[j]
			}
			return n, err
		}
	}
	return converted, actual, nil
}

func (b *amneziaBind) Send(packets [][]byte, endpoint awgconn.Endpoint) error {
	return b.bind.Send(packets, endpoint)
}
func (b *amneziaBind) ParseEndpoint(value string) (awgconn.Endpoint, error) {
	return b.bind.ParseEndpoint(value)
}
