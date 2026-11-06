//go:build android

package tun

import (
	"context"
	"net"
	"strconv"
	"sync"

	"github.com/xtls/xray-core/common/errors"
	"github.com/xtls/xray-core/common/platform"
	"golang.org/x/sys/unix"
)

type AndroidTun struct {
	*fdTun
	options   *Config
	closeOnce sync.Once
	closeErr  error
}

// DefaultTun implements Tun
var _ Tun = (*AndroidTun)(nil)

var androidTunInput = struct {
	sync.Mutex
	fd int
}{fd: -1}

// SetAndroidTunFD borrows a VpnService descriptor and duplicates it immediately (Elarni), so the service may close
// its own copy at any time. NewTun consumes the duplicate once. -1 discards an unconsumed duplicate.
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

// NewTun builds new tun interface handler
func NewTun(options *Config) (Tun, error) {
	androidTunInput.Lock()
	owned := androidTunInput.fd
	androidTunInput.fd = -1
	androidTunInput.Unlock()
	if owned >= 0 {
		if err := unix.SetNonblock(owned, true); err != nil {
			_ = unix.Close(owned)
			return nil, err
		}
		return &AndroidTun{fdTun: newFdTun(owned, 0), options: options}, nil
	}

	// Without a descriptor set or named, fd 0 would be taken for the TUN (Elarni).
	value := platform.NewEnvFlag(platform.TunFdKey).GetValue(func() string { return "" })
	if value == "" {
		return nil, errors.New("Android TUN descriptor is missing")
	}
	fd, err := strconv.Atoi(value)
	errors.LogInfo(context.Background(), "read Android Tun Fd ", fd, err)

	err = unix.SetNonblock(fd, true)
	if err != nil {
		_ = unix.Close(fd)
		return nil, err
	}

	// the descriptor stays with the application, Close ends the reading of a duplicate
	fd, err = unix.FcntlInt(uintptr(fd), unix.F_DUPFD_CLOEXEC, 0)
	if err != nil {
		return nil, err
	}

	return &AndroidTun{
		fdTun:   newFdTun(fd, 0),
		options: options,
	}, nil
}

func (t *AndroidTun) Start() error {
	return nil
}

// Close closes the descriptor once: a second Close must not touch a number the system has handed out again.
func (t *AndroidTun) Close() error {
	t.closeOnce.Do(func() { t.closeErr = t.closeFile() })
	return t.closeErr
}

func (t *AndroidTun) Name() (string, error) {
	ifr, err := unix.NewIfreq("")
	if err != nil {
		return "", err
	}
	if err = unix.IoctlIfreq(t.fd, unix.TUNGETIFF, ifr); err != nil {
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
