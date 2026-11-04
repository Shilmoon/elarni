package freedom

import (
	"bytes"
	gonet "net"
	"runtime"
	"testing"
	"time"

	"github.com/xtls/xray-core/common/buf"
	"github.com/xtls/xray-core/common/net"
)

func heapInUse() uint64 {
	runtime.GC()
	var stats runtime.MemStats
	runtime.ReadMemStats(&stats)
	return stats.HeapInuse
}

// Each direct UDP flow held a 64 KiB read buffer while it waited for a reply; a
// datagram must still arrive whole, and one queued behind another must not wait.
func TestWaitingUDPFlowsHoldNoReadBuffer(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Windows reads into a buffer per flow")
	}
	const flows = 200
	before := heapInUse()
	sockets := make([]*gonet.UDPConn, flows)
	results := make([]chan buf.MultiBuffer, flows)
	readers := make([]*PacketReader, flows)
	for i := range flows {
		socket, err := gonet.ListenUDP("udp4", &gonet.UDPAddr{IP: gonet.IPv4(127, 0, 0, 1)})
		if err != nil {
			t.Fatal(err)
		}
		defer socket.Close()
		sockets[i], results[i] = socket, make(chan buf.MultiBuffer, 1)
		readers[i] = &PacketReader{PacketConnWrapper: &net.PacketConnWrapper{PacketConn: socket, Dest: socket.LocalAddr()}, Handler: &Handler{}, IsOverridden: true}
		go func(r *PacketReader, result chan buf.MultiBuffer) {
			mb, _ := r.ReadMultiBuffer()
			result <- mb
		}(readers[i], results[i])
	}
	time.Sleep(200 * time.Millisecond) // let every reader block
	if grown := int64(heapInUse()) - int64(before); grown > flows*16<<10 {
		t.Fatalf("%d waiting flows grew the heap by %d KiB", flows, grown>>10)
	}

	sender, err := gonet.ListenUDP("udp4", &gonet.UDPAddr{IP: gonet.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer sender.Close()
	sender.SetWriteBuffer(65535) // Darwin rejects larger datagrams by default
	large := bytes.Repeat([]byte{7}, 30000)
	for _, payload := range [][]byte{large, []byte("small"), []byte("second")} {
		if _, err := sender.WriteTo(payload, sockets[0].LocalAddr()); err != nil {
			t.Fatal(err)
		}
	}
	got := [][]byte{}
	select {
	case mb := <-results[0]:
		got = append(got, mb[0].Bytes())
	case <-time.After(5 * time.Second):
		t.Fatal("no datagram")
	}
	for range 2 {
		sockets[0].SetReadDeadline(time.Now().Add(5 * time.Second))
		mb, err := readers[0].ReadMultiBuffer()
		if err != nil {
			t.Fatal(err)
		}
		got = append(got, mb[0].Bytes())
	}
	if !bytes.Equal(got[0], large) || string(got[1]) != "small" || string(got[2]) != "second" {
		t.Fatalf("read %d, %q, %q", len(got[0]), got[1], got[2])
	}
}
