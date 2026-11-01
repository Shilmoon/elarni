//go:build linux && !android

package tun

import (
	"context"
	"os"
	"testing"

	"golang.org/x/sys/unix"
)

// fdbased stops each packet reader through an eventfd it never closes, so every
// connect cycle left one descriptor open.
func TestHandlerCloseReleasesTheReaderStopEventfd(t *testing.T) {
	before := eventfds(t)
	for range 20 {
		pair, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_SEQPACKET|unix.SOCK_CLOEXEC, 0)
		if err != nil {
			t.Fatal(err)
		}
		device := &LinuxTun{tunFd: pair[0], options: &Config{MTU: 1500}}
		handler := &Handler{ctx: context.Background(), config: &Config{}}
		network, err := NewStack(handler.ctx, StackOptions{Tun: device}, handler)
		if err != nil {
			t.Fatal(err)
		}
		if err := network.Start(); err != nil {
			t.Fatal(err)
		}
		handler.stack, handler.tun = network, device
		if err := handler.Close(); err != nil {
			t.Fatal(err)
		}
		unix.Close(pair[1])
	}
	if after := eventfds(t); after > before {
		t.Fatalf("%d eventfds stayed open after 20 TUN start and close cycles", after-before)
	}
}

func eventfds(t *testing.T) int {
	entries, err := os.ReadDir("/proc/self/fd")
	if err != nil {
		t.Fatal(err)
	}
	count := 0
	for _, entry := range entries {
		if target, _ := os.Readlink("/proc/self/fd/" + entry.Name()); target == "anon_inode:[eventfd]" {
			count++
		}
	}
	return count
}
