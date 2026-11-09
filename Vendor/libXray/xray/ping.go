package xray

import (
	"context"
	"errors"
	"net"
	"net/http"
	"time"

	"github.com/xtls/libxray/nodep"
	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/core"
)

// PingRunningCore checks a target through the running core's routing, the way app
// traffic goes, without a listener login or a second core.
func PingRunningCore(ctx context.Context, timeout int, url, method string, expected *nodep.ExpectedResponse) (int64, error) {
	coreServerMu.Lock()
	server := coreServer
	coreServerMu.Unlock()
	if server == nil {
		return nodep.PingDelayError, errors.New("not_connected")
	}
	client := &http.Client{
		Timeout: time.Duration(timeout) * time.Second,
		Transport: &http.Transport{DisableKeepAlives: true, DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
			destination, err := xnet.ParseDestination(network + ":" + address)
			if err != nil {
				return nil, err
			}
			return core.Dial(ctx, server, destination)
		}},
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	return nodep.PingHTTPRequestContext(ctx, client, url, timeout, method, expected)
}
