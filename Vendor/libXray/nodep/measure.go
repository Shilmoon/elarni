package nodep

import (
	"context"
	"fmt"
	"io"
	"math"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/xtls/xray-core/common/probe"
)

type ExpectedResponse struct {
	Status int
	Body   string
	// Trace, when set, takes Cloudflare's /cdn-cgi/trace body instead of comparing it.
	Trace *Exit
}

// Exit is where a request through a server reached the internet: Cloudflare's ip= and loc=.
type Exit struct {
	IP      string `json:"ip"`
	Country string `json:"country"`
}

func (exit *Exit) read(body string) bool {
	for line := range strings.SplitSeq(body, "\n") {
		key, value, _ := strings.Cut(strings.TrimSpace(line), "=")
		switch key {
		case "ip":
			if net.ParseIP(value) == nil {
				return false
			}
			exit.IP = value
		case "loc":
			// ISO 3166 codes, and Cloudflare's XX (unknown) and T1 (Tor).
			if len(value) != 2 || strings.Trim(value, "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789") != "" {
				return false
			}
			exit.Country = value
		}
	}
	return exit.IP != "" && exit.Country != ""
}

const (
	PingDelayTimeout int64 = 11000
	PingDelayError   int64 = 10000
)

// MeasureDelayContext gets the delay of a request to url.
// timeout means how long the http request will be cancelled if no response, in units of seconds.
// proxy means the local http/socks5 proxy, like "socks5://[::1]:1080". If proxy is empty, it means no proxy.
func MeasureDelayContext(ctx context.Context, timeout int, url string, proxy string, method string, mode string, expected ...*ExpectedResponse) (int64, error) {
	if method == "" {
		method = "HEAD"
	}
	if mode == "" {
		mode = "default"
	}
	if mode != "default" && mode != "double" && mode != "keepalive" {
		return PingDelayError, fmt.Errorf("unsupported ping mode")
	}
	httpTimeout := time.Second * time.Duration(timeout)
	keepAlive := mode == "keepalive"
	c, err := coreHTTPClient(httpTimeout, proxy, keepAlive)
	if err != nil {
		return PingDelayError, err
	}
	defer c.CloseIdleConnections()
	request := func() (int64, error) { return pingHTTPRequestContext(ctx, c, url, timeout, method, expected...) }
	if mode == "keepalive" {
		if _, err := request(); err != nil {
			return PingDelayError, err
		}
		return request()
	}
	first, err := request()
	if mode != "double" || err != nil {
		return first, err
	}
	second, secondErr := MeasureDelayContext(ctx, timeout, url, proxy, method, "default", expected...)
	if secondErr != nil {
		return second, secondErr
	}
	if secondErr == nil && second < first {
		return second, nil
	}
	return first, nil
}

func coreHTTPClient(timeout time.Duration, proxy string, keepAlive bool) (*http.Client, error) {
	tr := &http.Transport{
		DisableKeepAlives: !keepAlive,
	}

	if len(proxy) > 0 {
		tr.Proxy = func(r *http.Request) (*url.URL, error) {
			return url.Parse(proxy)
		}
	}

	c := &http.Client{
		Transport:     tr,
		Timeout:       timeout,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}

	return c, nil
}

// PingHTTPRequestContext checks one request with the caller's client, such as one that dials through a running core.
func PingHTTPRequestContext(ctx context.Context, c *http.Client, url string, timeout int, method string, expected ...*ExpectedResponse) (int64, error) {
	return pingHTTPRequestContext(ctx, c, url, timeout, method, expected...)
}

func pingHTTPRequestContext(ctx context.Context, c *http.Client, url string, timeout int, method string, expected ...*ExpectedResponse) (int64, error) {
	if method != "GET" && method != "HEAD" {
		return PingDelayError, fmt.Errorf("unsupported HTTP method")
	}
	start := time.Now()
	req, err := http.NewRequestWithContext(ctx, method, url, nil)
	if err != nil {
		return PingDelayError, err
	}
	response, err := c.Do(req)
	status := 0
	if response != nil {
		status = response.StatusCode
	}
	probe.Emit(ctx, "target_response", err, status)
	delay := time.Since(start).Milliseconds()
	if err != nil {
		precision := delay - int64(timeout)*1000
		if math.Abs(float64(precision)) < 50 {
			return PingDelayTimeout, err
		}
		return PingDelayError, err
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return PingDelayError, fmt.Errorf("unexpected_response_status")
	}
	if len(expected) > 0 && expected[0] != nil {
		contract := expected[0]
		if response.StatusCode != contract.Status {
			return PingDelayError, fmt.Errorf("unexpected_response_status")
		}
		body, err := io.ReadAll(io.LimitReader(response.Body, 4097))
		if err != nil {
			return PingDelayError, err
		}
		if contract.Trace != nil {
			if len(body) > 4096 || !contract.Trace.read(string(body)) {
				return PingDelayError, fmt.Errorf("unexpected_response_body")
			}
		} else if len(body) > 4096 || string(body) != contract.Body {
			return PingDelayError, fmt.Errorf("unexpected_response_body")
		}
	}
	return time.Since(start).Milliseconds(), nil
}
