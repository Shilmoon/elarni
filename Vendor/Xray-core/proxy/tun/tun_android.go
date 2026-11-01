//go:build android

package tun

import (
	"net"
	"sync"

	"github.com/xtls/xray-core/common/errors"
	"golang.org/x/sys/unix"
	"gvisor.dev/gvisor/pkg/tcpip/link/fdbased"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
)

type AndroidTun struct {
	tunFd     int
	options   *Config
	closeOnce sync.Once
	closeErr  error
}

var androidTunInput = struct {
	sync.Mutex
	fd int
}{fd: -1}

// SetAndroidTunFD borrows a VpnService descriptor and duplicates it immediately.
// NewTun consumes the duplicate once. -1 discards an unconsumed duplicate.
func SetAndroidTunFD(fd int) error {
	androidTunInput.Lock()
	defer androidTunInput.Unlock()
	if fd == -1 {
		if androidTunInput.fd >= 0 {
			_ = unix.Close(androidTunInput.fd)
			androidTunInput.fd = -1
		}
		return nil
	}
	if fd <= 2 || androidTunInput.fd >= 0 {
		return errors.New("invalid or pending Android TUN descriptor")
	}
	owned, err := unix.FcntlInt(uintptr(fd), unix.F_DUPFD_CLOEXEC, 3)
	if err != nil {
		return err
	}
	androidTunInput.fd = owned
	return nil
}

// DefaultTun implements Tun
var _ Tun = (*AndroidTun)(nil)

// NewTun builds new tun interface handler
func NewTun(options *Config) (Tun, error) {
	androidTunInput.Lock()
	fd := androidTunInput.fd
	androidTunInput.fd = -1
	androidTunInput.Unlock()
	if fd < 0 {
		return nil, errors.New("Android TUN descriptor is missing")
	}
	err := unix.SetNonblock(fd, true)
	if err != nil {
		_ = unix.Close(fd)
		return nil, err
	}

	return &AndroidTun{
		tunFd:   fd,
		options: options,
	}, nil
}

func (t *AndroidTun) Start() error {
	return nil
}

func (t *AndroidTun) Close() error {
	t.closeOnce.Do(func() { t.closeErr = unix.Close(t.tunFd) })
	return t.closeErr
}

func (t *AndroidTun) Name() (string, error) {
	ifr, err := unix.NewIfreq("")
	if err != nil {
		return "", err
	}
	if err = unix.IoctlIfreq(t.tunFd, unix.TUNGETIFF, ifr); err != nil {
		return "", err
	}
	return ifr.Name(), nil
}

func (t *AndroidTun) Index() (int, error) {
	name, err := t.Name()
	if err != nil {
		return 0, err
	}
	iface, err := net.InterfaceByName(name)
	if err != nil {
		return 0, err
	}
	return iface.Index, nil
}

func (t *AndroidTun) newEndpoint() (stack.LinkEndpoint, error) {
	endpoint, err := fdbased.New(&fdbased.Options{
		FDs:               []int{t.tunFd},
		MTU:               t.options.MTU,
		RXChecksumOffload: true,
	})
	if err != nil {
		return nil, err
	}
	return &stopEventfdEndpoint{LinkEndpoint: endpoint}, nil
}

func setinterface(network, address string, fd uintptr, iface *net.Interface) error {
	return unix.BindToDevice(int(fd), iface.Name)
}

func findOutboundInterface(tunIndex int, fixedName string) (*net.Interface, error) {
	if fixedName == "" {
		return nil, errors.New("automatic outbound interface selection is not supported on this platform")
	}
	iface, err := net.InterfaceByName(fixedName)
	if err != nil {
		return nil, err
	}
	if iface.Index == tunIndex {
		return nil, errors.New("outbound interface cannot be the TUN interface")
	}
	return iface, nil
}
