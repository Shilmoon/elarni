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

// Ping Xray config and find the delay and country code of its outbound.
// configPath means the config.json file path.
// timeout means how long the http request will be cancelled if no response, in units of seconds.
// url means the website we use to test speed. "https://www.google.com" is a good choice for most cases.
// proxy means the local http/socks5 proxy, like "socks5://[::1]:1080".
func Ping(configPath string, timeout int, url string, proxy string) (int64, error) {
	return PingWithOptions(configPath, timeout, url, proxy, "HEAD", "default", nil)
}

func PingWithOptions(configPath string, timeout int, url, proxy, method, mode string, expected *nodep.ExpectedResponse) (int64, error) {
	server, err := StartXray(configPath)
	if err != nil {
		return nodep.PingDelayError, err
	}

	if err := server.Start(); err != nil {
		_ = server.Close()
		return nodep.PingDelayError, err
	}
	defer server.Close()

	delay, err := nodep.MeasureDelayContext(context.Background(), timeout, url, proxy, method, mode, expected)
	if err != nil {
		return delay, err
	}

	return delay, nil
}

func PingJSON(configJSON string, timeout int, url string, proxy string, method string, mode string) (int64, error) {
	delay, _, err := PingJSONWithDiagnostics(configJSON, timeout, url, proxy, method, mode, "")
	return delay, err
}
