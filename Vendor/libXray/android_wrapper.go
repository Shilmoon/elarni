//go:build android

package libXray

import (
	"errors"
	"sync"
	"syscall"

	c "github.com/xtls/libxray/controller"
	"github.com/xtls/libxray/dns"
	"github.com/xtls/xray-core/proxy/tun"
	xinternet "github.com/xtls/xray-core/transport/internet"
)

type DialerController interface {
	ProtectFd(int) bool
}

// SetTunFD duplicates the descriptor owned by VpnService. Pass -1 after startup
// or cancellation to release any duplicate that the core did not consume.
func SetTunFD(fd int) error { return tun.SetAndroidTunFD(fd) }

func SetAndroidSessionLimits(tcp, udp int) error {
	if tcp < 1 || tcp > 4096 || udp < 1 || udp > 4096 {
		return errors.New("invalid session limits")
	}
	tun.SetSessionLimits(tcp, udp)
	return nil
}

var requiredAndroidController struct {
	sync.RWMutex
	once  sync.Once
	value DialerController
}

// SetAndroidSocketController installs one required hook. Unlike the legacy
// advisory controllers, protection denial aborts TCP and UDP dialing. Updating
// the delegate does not append callbacks or retain obsolete service instances.
func SetAndroidSocketController(controller DialerController) {
	requiredAndroidController.Lock()
	requiredAndroidController.value = controller
	requiredAndroidController.Unlock()
	requiredAndroidController.once.Do(func() {
		xinternet.RequiredSocketController = func(network, address string, socket syscall.RawConn) error {
			requiredAndroidController.RLock()
			delegate := requiredAndroidController.value
			requiredAndroidController.RUnlock()
			if delegate == nil {
				return errors.New("Android socket protector unavailable")
			}
			protected := false
			if err := socket.Control(func(fd uintptr) { protected = delegate.ProtectFd(int(fd)) }); err != nil {
				return err
			}
			if !protected {
				return errors.New("Android socket protection denied")
			}
			return nil
		}
	})
}

// SetDNS installs an Android VPN-aware process resolver. server must be an IP
// endpoint such as 8.8.8.8:53 or [2001:4860:4860::8888]:53.
func SetDNS(controller DialerController, server string) error {
	if controller == nil {
		return errors.New("dns dialer controller is nil")
	}
	return dns.SetDNS(server, func(fd uintptr) bool {
		return controller.ProtectFd(int(fd))
	})
}

// ResetDNS restores the resolver that was active before SetDNS.
func ResetDNS() {
	dns.ResetDNS()
}

// ProcessFinder -> implemented by apps to resolve UID from connection details.
// See RegisterProcessFinder.
type ProcessFinder interface {
	// FindProcessByConnection -> returns UID owning the connection, or -1.
	FindProcessByConnection(network, srcIP string, srcPort int, destIP string, destPort int) int
}

// SocketPathChanged reports that the default network moved: new sockets now
// leave through another network, so the core moves its long-lived ones there.
func SocketPathChanged() { xinternet.SocketPathChanged() }

// RegisterProcessFinder -> registers process finder for per-app routing.
// Pass nil to unregister.
// sdkVersion = Build.VERSION.SDK_INT (unused: minSdk 30 always asks the callback).
func RegisterProcessFinder(finder ProcessFinder, sdkVersion int) {
	if finder == nil {
		c.RegisterProcessFinder(nil, 0)
		return
	}

	c.RegisterProcessFinder(func(network, srcIP string, srcPort int, destIP string, destPort int) int {
		return finder.FindProcessByConnection(network, srcIP, srcPort, destIP, destPort)
	}, sdkVersion)
}
