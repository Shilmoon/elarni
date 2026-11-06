//go:build android

package dns

import (
	"net"
	"sync"

	xnet "github.com/xtls/xray-core/common/net"
)

var (
	resolverMu       sync.Mutex
	previousResolver *net.Resolver
	previousXray     *net.Resolver
)

// SetDNS replaces Go's process-wide default resolver with an Android VPN-aware
// resolver. The caller must serialize this with the Xray lifecycle.
func SetDNS(server string, protect protectSocket) error {
	resolver, err := newResolver(server, protect)
	if err != nil {
		return err
	}

	resolverMu.Lock()
	defer resolverMu.Unlock()
	if previousResolver == nil {
		previousResolver, previousXray = net.DefaultResolver, xnet.DefaultResolver
	}
	// Xray keeps its own copy, taken at init, for freedom's and the dialer's lookups.
	net.DefaultResolver, xnet.DefaultResolver = resolver, resolver
	return nil
}

// ResetDNS restores the resolver that was active before SetDNS.
func ResetDNS() {
	resolverMu.Lock()
	defer resolverMu.Unlock()
	if previousResolver == nil {
		return
	}
	net.DefaultResolver, xnet.DefaultResolver = previousResolver, previousXray
	previousResolver, previousXray = nil, nil
}
