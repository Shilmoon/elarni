//go:build android

package net

import (
	"time"

	"github.com/xtls/xray-core/common/errors"
)

var androidProcessFinder func(network, srcIP string, srcPort uint16, destIP string, destPort uint16) (int, string, string, error)

var androidSocketOwners = &socketOwners{entries: map[socketKey]socketOwner{}, now: time.Now}

func RegisterAndroidProcessFinder(f func(network, srcIP string, srcPort uint16, destIP string, destPort uint16) (int, string, string, error)) {
	androidProcessFinder = f
}

func FindProcess(network, srcIP string, srcPort uint16, destIP string, destPort uint16) (int, string, string, error) {
	if androidProcessFinder != nil {
		return androidSocketOwners.find(network, srcIP, srcPort, destIP, destPort, androidProcessFinder)
	}
	return 0, "", "", errors.New("android process lookup must be registered before use")
}

// PrefetchSocketOwner looks up a new flow's owner while its socket still exists,
// when a router has process rules.
func PrefetchSocketOwner(network, srcIP string, srcPort uint16, destIP string, destPort uint16) {
	if androidProcessFinder != nil && SocketOwnerPrefetchWanted() {
		go FindProcess(network, srcIP, srcPort, destIP, destPort)
	}
}
