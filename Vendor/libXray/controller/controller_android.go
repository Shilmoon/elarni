//go:build android

package controller

import (
	"fmt"

	corenet "github.com/xtls/xray-core/common/net"
)

// RegisterProcessFinder -> registers process finder for per-app routing.
// Pass nil to unregister. The SDK version is unused: minSdk is 30, where
// getConnectionOwnerUid() exists and apps cannot read /proc/net.
func RegisterProcessFinder(finder func(network, srcIP string, srcPort int, destIP string, destPort int) int, _ int) {
	if finder == nil {
		corenet.RegisterAndroidProcessFinder(nil)
		return
	}

	corenet.RegisterAndroidProcessFinder(func(network, srcIP string, srcPort uint16, destIP string, destPort uint16) (int, string, string, error) {
		if destPort == 0 || destIP == "" {
			return 0, "", "", fmt.Errorf("process finder: no destination for %s %s:%d", network, srcIP, srcPort)
		}

		uid := finder(network, srcIP, int(srcPort), destIP, int(destPort))
		return uid, fmt.Sprintf("%d", uid), "", nil
	})
}
