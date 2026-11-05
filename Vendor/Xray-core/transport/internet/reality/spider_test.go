package reality

import (
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"testing"
	"time"

	"golang.org/x/net/http2"
)

type coverConn struct {
	server   net.Conn
	requests chan string
	done     chan struct{}
}

// coverSite returns the client end of a connection whose server end speaks HTTP/2 like the
// cover site behind a MITM: every page links to more paths than the crawler keeps.
func coverSite(t *testing.T) (net.Conn, *coverConn) {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	client, err := net.Dial("tcp", listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	server, err := listener.Accept()
	if err != nil {
		t.Fatal(err)
	}
	var page strings.Builder
	for i := 0; i < 2*maxSpiderPaths; i++ {
		fmt.Fprintf(&page, `<a href="/p%d">`, i)
	}
	cover := &coverConn{server: server, requests: make(chan string, 8), done: make(chan struct{})}
	go func() {
		defer close(cover.done)
		(&http2.Server{}).ServeConn(server, &http2.ServeConnOpts{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			cover.requests <- r.URL.Path
			_, _ = io.WriteString(w, page.String())
		})})
	}()
	t.Cleanup(func() { server.Close(); client.Close() })
	return client, cover
}

func crawling(name string) bool {
	maps.Lock()
	defer maps.Unlock()
	return maps.crawling[name]
}

// A MITM that fails every REALITY handshake used to get one crawler and one open
// connection per attempt, and a path set that grew for the life of the process.
func TestSpiderKeepsOneConnectionPerServerName(t *testing.T) {
	const name = "spider.fixture.invalid"
	config := &Config{SpiderX: "/", SpiderY: make([]int64, 10)}

	first, firstCover := coverSite(t)
	spider(first, name, config, "")
	select {
	case <-firstCover.requests:
	case <-time.After(2 * time.Second):
		t.Fatal("the crawler did not browse the cover site")
	}
	select {
	case <-firstCover.done:
		t.Fatal("the crawler closed its connection; upstream keeps it open like a browser")
	case <-time.After(200 * time.Millisecond):
	}

	second, secondCover := coverSite(t)
	spider(second, name, config, "")
	select {
	case <-secondCover.done:
	case <-time.After(2 * time.Second):
		t.Fatal("a second connection stayed open while the first crawl held the ServerName")
	}
	if len(secondCover.requests) != 0 {
		t.Fatal("a second crawler browsed while the first held the ServerName")
	}
	maps.Lock()
	learned := len(maps.maps[name])
	maps.Unlock()
	if learned <= 1 || learned > maxSpiderPaths {
		t.Fatalf("kept %d paths, want some and at most %d", learned, maxSpiderPaths)
	}

	firstCover.server.Close() // the cover site drops the idle connection
	for deadline := time.Now().Add(2 * time.Second); crawling(name); time.Sleep(10 * time.Millisecond) {
		if time.Now().After(deadline) {
			t.Fatal("the closed crawl connection still holds the ServerName")
		}
	}
	third, thirdCover := coverSite(t)
	spider(third, name, config, "")
	select {
	case <-thirdCover.requests:
	case <-time.After(2 * time.Second):
		t.Fatal("no crawl after the previous connection closed")
	}
}
