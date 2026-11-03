package wireguard

import (
	"bytes"
	"net"
	"net/netip"
	"runtime"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"golang.zx2c4.com/wireguard/conn"
)

type testCounter struct{ atomic.Int64 }

func (c *testCounter) Value() int64      { return c.Load() }
func (c *testCounter) Set(v int64) int64 { return c.Swap(v) }
func (c *testCounter) Add(v int64) int64 { return c.Int64.Add(v) - v }

// Linux reads and writes the queued datagrams of a batch in one system call; the
// counters, reserved bytes and endpoints stay as they were per datagram. The socket is
// dual-stack and the peer IPv4, as DialSystem makes them.
func TestBindMovesDatagramBatchesWithReservedBytesAndCounters(t *testing.T) {
	socket, err := net.ListenPacket("udp", "0.0.0.0:0")
	if err != nil {
		t.Fatal(err)
	}
	peer, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer peer.Close()
	read, written := &testCounter{}, &testCounter{}
	b := &bind{reserved: []byte{7, 8, 9}, listenFunc: func() (net.PacketConn, error) {
		return &PacketCounterConnection{PacketConn: socket, ReadCounter: read, WriteCounter: written}, nil
	}}
	fns, _, err := b.Open(0)
	if err != nil {
		t.Fatal(err)
	}
	defer b.Close()
	wantBatch := 1
	if runtime.GOOS == "linux" {
		wantBatch = conn.IdealBatchSize
	}
	if b.BatchSize() != wantBatch {
		t.Fatalf("batch size %d, want %d", b.BatchSize(), wantBatch)
	}

	target := &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: socket.LocalAddr().(*net.UDPAddr).Port}
	for i := range 5 {
		if _, err := peer.WriteTo([]byte{4, 1, 1, 1, byte(i)}, target); err != nil {
			t.Fatal(err)
		}
	}
	bufs, sizes, eps := make([][]byte, 8), make([]int, 8), make([]conn.Endpoint, 8)
	for i := range bufs {
		bufs[i] = make([]byte, 2048)
	}
	var got [][]byte
	for len(got) < 5 {
		n, err := fns[0](bufs, sizes, eps)
		if err != nil {
			t.Fatal(err)
		}
		if runtime.GOOS == "linux" && n != 5 {
			t.Fatalf("one receive returned %d of 5 queued datagrams", n)
		}
		for i := range n {
			if from := eps[i].(*conn.StdNetEndpoint).AddrPort; netip.AddrPortFrom(from.Addr().Unmap(), from.Port()).String() != peer.LocalAddr().String() {
				t.Fatalf("endpoint %s, want %s", from, peer.LocalAddr())
			}
			got = append(got, bytes.Clone(bufs[i][:sizes[i]]))
		}
	}
	for i, datagram := range got {
		if !bytes.Equal(datagram, []byte{4, 0, 0, 0, byte(i)}) {
			t.Fatalf("datagram %d is %v; reserved bytes must be cleared", i, datagram)
		}
	}
	if read.Value() != 25 {
		t.Fatalf("read counter %d, want 25", read.Value())
	}

	ep, err := b.ParseEndpoint(peer.LocalAddr().String())
	if err != nil {
		t.Fatal(err)
	}
	out := make([][]byte, 5)
	for i := range out {
		out[i] = []byte{4, 0, 0, 0, byte(i), 0}
	}
	if err := b.Send(out, ep); err != nil {
		t.Fatal(err)
	}
	peer.SetReadDeadline(time.Now().Add(5 * time.Second))
	buf := make([]byte, 64)
	for i := range 5 {
		n, _, err := peer.ReadFrom(buf)
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(buf[:n], []byte{4, 7, 8, 9, byte(i), 0}) {
			t.Fatalf("sent datagram %d arrived as %v", i, buf[:n])
		}
	}
	if written.Value() != 30 {
		t.Fatalf("write counter %d, want 30", written.Value())
	}
}

// AmneziaWG keeps 64 KiB message buffers, so batches would hold megabytes per device.
func TestAmneziaEngineKeepsSingleDatagramBatches(t *testing.T) {
	if got := (&amneziaBind{&bind{}}).BatchSize(); got != 1 {
		t.Fatalf("AmneziaWG bind batch size %d", got)
	}
	if got := (&amneziaTUN{}).BatchSize(); got != 1 {
		t.Fatalf("AmneziaWG TUN batch size %d", got)
	}
}

// The default UDP buffers overflowed when several streams arrived at once.
func TestBindEnlargesTheSocketBuffers(t *testing.T) {
	fresh, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defaultSize := receiveBuffer(t, fresh)
	fresh.Close()
	socket, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	b := &bind{listenFunc: func() (net.PacketConn, error) { return &PacketCounterConnection{PacketConn: socket}, nil }}
	if _, _, err := b.Open(0); err != nil {
		t.Fatal(err)
	}
	defer b.Close()
	if size := receiveBuffer(t, socket); size <= defaultSize {
		t.Fatalf("receive buffer %d, default %d", size, defaultSize)
	}
}

func receiveBuffer(t *testing.T, conn syscall.Conn) int {
	t.Helper()
	raw, err := conn.SyscallConn()
	if err != nil {
		t.Fatal(err)
	}
	size := 0
	raw.Control(func(fd uintptr) { size, err = getReceiveBuffer(fd) })
	if err != nil {
		t.Fatal(err)
	}
	return size
}
