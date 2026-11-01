// Package net is a drop-in replacement to Golang's net package, with some more functionalities.
package net // import "github.com/xtls/xray-core/common/net"

import (
	"net"
	"slices"
	"sync/atomic"
	"time"

	"github.com/xtls/xray-core/common/errors"
)

// defines the maximum time an idle TCP session can survive in the tunnel, so
// it should be consistent across HTTP versions and with other transports.
const ConnIdleTimeout = 300 * time.Second

// consistent with quic-go
const QuicgoH3KeepAlivePeriod = 10 * time.Second

// consistent with chrome
const ChromeH2KeepAlivePeriod = 45 * time.Second

var ErrNotLocal = errors.New("the source address is not from local machine.")

type localIPCacheEntry struct {
	addrs      []net.Addr
	lastUpdate time.Time
}

var localIPCache = atomic.Pointer[localIPCacheEntry]{}

func IsLocal(ip net.IP) (bool, error) {
	matches := func(addr net.Addr) bool {
		ipnet, ok := addr.(*net.IPNet)
		return ok && ipnet.IP.Equal(ip)
	}
	if entry := localIPCache.Load(); entry != nil && time.Since(entry.lastUpdate) <= time.Minute && slices.ContainsFunc(entry.addrs, matches) {
		return true, nil
	}
	// A TUN adapter or IPv6 address may have appeared since the snapshot.
	// Refresh a miss before rejecting the source and skipping per-app routing.
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		return false, err
	}
	localIPCache.Store(&localIPCacheEntry{addrs: addrs, lastUpdate: time.Now()})
	return slices.ContainsFunc(addrs, matches), nil
}
