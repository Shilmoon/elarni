//go:build darwin

package tun

import (
	"bytes"
	"encoding/binary"
	"errors"
	"os"
	"strconv"
	"testing"
	"time"

	"github.com/xtls/xray-core/common/platform"
	"golang.org/x/sys/unix"
	"gvisor.dev/gvisor/pkg/buffer"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
)

// Model NetworkExtension's borrowed datagram descriptor without changing routes.
func TestDarwinTunBorrowedDescriptorRestart(t *testing.T) {
	fds, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_DGRAM, 0)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { unix.Close(fds[0]); unix.Close(fds[1]) })
	t.Setenv(platform.TunFdKey, strconv.Itoa(fds[0]))
	for round := range 2 {
		device, err := NewTun(&Config{MTU: 1500})
		if err != nil {
			t.Fatal(err)
		}
		tun := device.(*DarwinTun)
		t.Cleanup(func() { tun.tunFile.Close() })
		packet := []byte{0, 0, 0, unix.AF_INET, 0x45, byte(round)}
		if _, err := unix.Write(fds[1], packet); err != nil {
			t.Fatal(err)
		}
		version, received, err := tun.ReadPacket()
		if err != nil {
			t.Fatal(err)
		}
		if version != 4 || received.Data().AsRange().ToSlice()[1] != byte(round) {
			t.Error("restarted reader did not receive its packet")
		}
		received.DecRef()
		readDone := make(chan error, 1)
		go func() {
			_, packet, err := tun.ReadPacket()
			if packet != nil {
				packet.DecRef()
			}
			readDone <- err
		}()
		select {
		case err := <-readDone:
			t.Fatalf("idle read returned instead of waiting: %v", err)
		case <-time.After(20 * time.Millisecond):
		}
		if err := tun.Close(); err != nil {
			t.Fatal(err)
		}
		select {
		case err := <-readDone:
			if !errors.Is(err, os.ErrClosed) {
				t.Fatalf("closed reader: %v", err)
			}
		case <-time.After(time.Second):
			t.Fatal("stopped tunnel reader still owns the provider's packet stream")
		}
		if _, err := unix.FcntlInt(uintptr(fds[0]), unix.F_GETFD, 0); err != nil {
			t.Fatalf("provider descriptor was closed: %v", err)
		}
	}
}

func TestDarwinTunWritesCompleteLargeDatagram(t *testing.T) {
	fds, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_DGRAM, 0)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { unix.Close(fds[0]); unix.Close(fds[1]) })
	if err := unix.SetsockoptInt(fds[0], unix.SOL_SOCKET, unix.SO_SNDBUF, 8192); err != nil {
		t.Fatal(err)
	}
	t.Setenv(platform.TunFdKey, strconv.Itoa(fds[0]))
	device, err := NewTun(&Config{MTU: 1500})
	if err != nil {
		t.Fatal(err)
	}
	defer device.Close()
	payload := bytes.Repeat([]byte{0xAB}, 3000)
	payload[0] = 0x45
	binary.BigEndian.PutUint16(payload[2:4], uint16(len(payload)))
	packet := stack.NewPacketBuffer(stack.PacketBufferOptions{Payload: buffer.MakeWithData(payload)})
	defer packet.DecRef()
	if err := device.(*DarwinTun).WritePacket(packet); err != nil {
		t.Fatal(err.String())
	}
	got := make([]byte, len(payload)+utunHeaderSize+1)
	n, err := unix.Read(fds[1], got)
	if err != nil {
		t.Fatal(err)
	}
	want := append([]byte{0, 0, 0, unix.AF_INET}, payload...)
	if !bytes.Equal(got[:n], want) {
		t.Fatalf("datagram truncated or changed: received %d bytes, want %d", n, len(want))
	}
}

func TestDarwinTunEmptyQueueWaitDoesNotSpin(t *testing.T) {
	var before, after unix.Rusage
	if err := unix.Getrusage(unix.RUSAGE_SELF, &before); err != nil {
		t.Fatal(err)
	}
	started := time.Now()
	device := &DarwinTun{}
	for time.Since(started) < 100*time.Millisecond {
		device.Wait()
	}
	if err := unix.Getrusage(unix.RUSAGE_SELF, &after); err != nil {
		t.Fatal(err)
	}
	cpu := time.Duration(after.Utime.Nano() + after.Stime.Nano() - before.Utime.Nano() - before.Stime.Nano())
	if cpu > time.Since(started)/2 {
		t.Fatalf("empty queue busy-spins: %s CPU in %s", cpu, time.Since(started))
	}
}
