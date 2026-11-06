package buf_test

import (
	"bytes"
	"errors"
	"fmt"
	"net"
	"os"
	"runtime"
	"sync"
	"testing"
	"time"

	"github.com/xtls/xray-core/common/buf"
)

// scratchOnly hides *net.UDPConn, so ReadPacketFrom reads into the reader's own scratch buffer.
type scratchOnly struct{ net.PacketConn }

var packetReads = []struct {
	name string
	wrap func(*net.UDPConn) net.PacketConn
}{
	{"pooled", func(c *net.UDPConn) net.PacketConn { return c }},
	{"scratch", func(c *net.UDPConn) net.PacketConn { return scratchOnly{c} }},
}

func udpPair(tb testing.TB, network string) (reader, sender *net.UDPConn) {
	tb.Helper()
	ip := net.IPv4(127, 0, 0, 1)
	if network == "udp6" {
		ip = net.IPv6loopback
	}
	reader, err := net.ListenUDP(network, &net.UDPAddr{IP: ip})
	if err != nil {
		tb.Skip(err)
	}
	tb.Cleanup(func() { reader.Close() })
	sender, err = net.DialUDP(network, nil, reader.LocalAddr().(*net.UDPAddr))
	if err != nil {
		tb.Fatal(err)
	}
	tb.Cleanup(func() { sender.Close() })
	sender.SetWriteBuffer(1 << 20) // Darwin rejects large datagrams by default
	return reader, sender
}

type packetRead struct {
	b    *buf.Buffer
	from net.Addr
	err  error
}

func readPacketAsync(conn net.PacketConn, scratch *[]byte) chan packetRead {
	result := make(chan packetRead, 1)
	go func() {
		b, from, err := buf.ReadPacketFrom(conn, scratch)
		result <- packetRead{b, from, err}
	}()
	return result
}

func await(t *testing.T, result chan packetRead) packetRead {
	t.Helper()
	select {
	case r := <-result:
		return r
	case <-time.After(5 * time.Second):
		t.Fatal("read did not return")
		return packetRead{}
	}
}

// A datagram arrives whole with its sender's address, whether the reader was waiting or it was
// queued, and an empty one reads as empty instead of spinning or blocking the reader.
func TestReadPacketFromKeepsDatagramsWhole(t *testing.T) {
	for _, network := range []string{"udp4", "udp6"} {
		for _, read := range packetReads {
			t.Run(network+"/"+read.name, func(t *testing.T) {
				reader, sender := udpPair(t, network)
				conn, scratch := read.wrap(reader), new([]byte)
				expect := func(r packetRead, payload []byte) {
					t.Helper()
					if r.err != nil {
						t.Fatal(r.err)
					}
					from, ok := r.from.(*net.UDPAddr)
					want := sender.LocalAddr().(*net.UDPAddr)
					if !ok || !from.IP.Equal(want.IP) || from.Port != want.Port {
						t.Fatalf("from %v, want %v", r.from, want)
					}
					if !bytes.Equal(r.b.Bytes(), payload) {
						t.Fatalf("read %d bytes, want %d", r.b.Len(), len(payload))
					}
					r.b.Release()
				}
				send := func(payloads ...[]byte) {
					t.Helper()
					for _, payload := range payloads {
						if _, err := sender.Write(payload); err != nil {
							t.Fatal(err)
						}
					}
				}
				large := bytes.Repeat([]byte{7}, 30000)

				waiting := readPacketAsync(conn, scratch)
				time.Sleep(50 * time.Millisecond) // let the reader wait
				send([]byte{})
				expect(await(t, waiting), []byte{})

				waiting = readPacketAsync(conn, scratch)
				time.Sleep(50 * time.Millisecond)
				send(large, []byte("small"), []byte("second"))
				expect(await(t, waiting), large)
				expect(await(t, readPacketAsync(conn, scratch)), []byte("small"))
				expect(await(t, readPacketAsync(conn, scratch)), []byte("second"))

				send([]byte{}, []byte("after empty"))
				time.Sleep(50 * time.Millisecond) // let both queue before the read
				expect(await(t, readPacketAsync(conn, scratch)), []byte{})
				expect(await(t, readPacketAsync(conn, scratch)), []byte("after empty"))
			})
		}
	}
}

// A waiting read ends on its deadline and on Close, and Close does not wait for a datagram.
func TestWaitingReadPacketFromEndsOnDeadlineAndClose(t *testing.T) {
	for _, read := range packetReads {
		t.Run(read.name, func(t *testing.T) {
			reader, _ := udpPair(t, "udp4")
			conn, scratch := read.wrap(reader), new([]byte)
			reader.SetReadDeadline(time.Now().Add(50 * time.Millisecond))
			if r := await(t, readPacketAsync(conn, scratch)); !errors.Is(r.err, os.ErrDeadlineExceeded) {
				t.Fatalf("read after the deadline: %v", r.err)
			}
			reader.SetReadDeadline(time.Time{})
			waiting := readPacketAsync(conn, scratch)
			time.Sleep(50 * time.Millisecond) // let the reader wait
			closed := make(chan error, 1)
			go func() { closed <- reader.Close() }()
			if r := await(t, waiting); !errors.Is(r.err, net.ErrClosed) {
				t.Fatalf("read after Close: %v", r.err)
			}
			select {
			case <-closed:
			case <-time.After(5 * time.Second):
				t.Fatal("Close waited for a datagram")
			}
		})
	}
}

func heapInUse() uint64 {
	runtime.GC()
	var stats runtime.MemStats
	runtime.ReadMemStats(&stats)
	return stats.HeapInuse
}

// startWaitingReaders starts one read per new socket, after it has read a burst of datagrams
// (every other one ending with an empty datagram), and returns once all of them wait.
func startWaitingReaders(tb testing.TB, count, burst int, wrap func(*net.UDPConn) net.PacketConn) (sockets []*net.UDPConn, results []chan packetRead) {
	tb.Helper()
	sender, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		tb.Fatal(err)
	}
	defer sender.Close()
	for k := range count {
		socket, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
		if err != nil {
			tb.Fatal(err)
		}
		tb.Cleanup(func() { socket.Close() })
		sockets = append(sockets, socket)
		for i := range burst {
			if _, err := sender.WriteTo(make([]byte, (burst-1-i+k%2)*100), socket.LocalAddr()); err != nil {
				tb.Fatal(err)
			}
		}
	}
	time.Sleep(50 * time.Millisecond) // let the bursts queue
	for _, socket := range sockets {
		conn, scratch := wrap(socket), new([]byte)
		for range burst {
			p, _, err := buf.ReadPacketFrom(conn, scratch)
			if err != nil {
				tb.Fatal(err)
			}
			p.Release()
		}
		results = append(results, readPacketAsync(conn, scratch))
	}
	time.Sleep(200 * time.Millisecond) // let every reader wait
	return sockets, results
}

// A UDP flow waiting for a reply held a 64 KiB read buffer for its whole life, also after it
// had read a burst of queued datagrams.
func TestWaitingUDPReadsHoldNoBuffer(t *testing.T) {
	const flows = 200
	before := heapInUse()
	sockets, results := startWaitingReaders(t, flows, 3, packetReads[0].wrap)
	if grown := int64(heapInUse()) - int64(before); grown > flows*16<<10 {
		t.Fatalf("%d waiting reads grew the heap by %d KiB", flows, grown>>10)
	}
	sender, err := net.DialUDP("udp4", nil, sockets[0].LocalAddr().(*net.UDPAddr))
	if err != nil {
		t.Fatal(err)
	}
	defer sender.Close()
	if _, err := sender.Write([]byte("reply")); err != nil {
		t.Fatal(err)
	}
	if r := await(t, results[0]); r.err != nil || string(r.b.Bytes()) != "reply" {
		t.Fatalf("read %v", r.err)
	}
}

// One sender saturates one reader: ns/op and cpu-ns/op are per received datagram.
func BenchmarkReadPacketFromSaturated(b *testing.B) {
	for _, size := range []int{1200, 65507} {
		for _, read := range packetReads {
			b.Run(fmt.Sprintf("%s/%d", read.name, size), func(b *testing.B) {
				reader, sender := udpPair(b, "udp4")
				reader.SetReadBuffer(4 << 20)
				payload := make([]byte, size)
				stop, stopped := make(chan struct{}), make(chan struct{})
				go func() {
					defer close(stopped)
					for {
						select {
						case <-stop:
							return
						default:
							sender.Write(payload)
						}
					}
				}()
				defer func() { close(stop); <-stopped }()
				conn, scratch := read.wrap(reader), new([]byte)
				b.SetBytes(int64(size))
				b.ReportAllocs()
				cpu := processCPU()
				b.ResetTimer()
				for range b.N {
					p, _, err := buf.ReadPacketFrom(conn, scratch)
					if err != nil {
						b.Fatal(err)
					}
					p.Release()
				}
				b.StopTimer()
				b.ReportMetric(float64(processCPU()-cpu)/float64(b.N), "cpu-ns/op")
			})
		}
	}
}

// Bursts already queued on the socket (a busy download) with nothing else running: ns/op is
// the reader's own cost per datagram.
func BenchmarkReadPacketFromQueued(b *testing.B) {
	for _, size := range []int{1200, 65507} {
		for _, read := range packetReads {
			b.Run(fmt.Sprintf("%s/%d", read.name, size), func(b *testing.B) {
				reader, sender := udpPair(b, "udp4")
				reader.SetReadBuffer(8 << 20)
				payload := make([]byte, size)
				burst := 1<<20/size + 1
				conn, scratch := read.wrap(reader), new([]byte)
				b.SetBytes(int64(size))
				b.ReportAllocs()
				b.ResetTimer()
				for done := 0; done < b.N; done += burst {
					b.StopTimer()
					burst = min(burst, b.N-done)
					for range burst {
						if _, err := sender.Write(payload); err != nil {
							b.Fatal(err)
						}
					}
					reader.SetReadDeadline(time.Now().Add(5 * time.Second)) // a dropped datagram fails, not hangs
					b.StartTimer()
					for range burst {
						p, _, err := buf.ReadPacketFrom(conn, scratch)
						if err != nil {
							b.Fatal(err)
						}
						p.Release()
					}
				}
			})
		}
	}
}

// Each reply reaches a reader that waits for it (a game or call flow): ns/op is one round trip.
func BenchmarkReadPacketFromEcho(b *testing.B) {
	for _, read := range packetReads {
		b.Run(read.name, func(b *testing.B) {
			reader, echo := udpPair(b, "udp4")
			go func() {
				p := make([]byte, 2048)
				for {
					n, err := echo.Read(p)
					if err != nil {
						return
					}
					echo.Write(p[:n])
				}
			}()
			to := echo.LocalAddr().(*net.UDPAddr).AddrPort()
			payload := make([]byte, 1200)
			conn, scratch := read.wrap(reader), new([]byte)
			b.ReportAllocs()
			cpu := processCPU()
			b.ResetTimer()
			for range b.N {
				if _, err := reader.WriteToUDPAddrPort(payload, to); err != nil {
					b.Fatal(err)
				}
				p, _, err := buf.ReadPacketFrom(conn, scratch)
				if err != nil {
					b.Fatal(err)
				}
				p.Release()
			}
			b.StopTimer()
			b.ReportMetric(float64(processCPU()-cpu)/float64(b.N), "cpu-ns/op")
		})
	}
}

// Run with -benchtime=1000x: each op is one more UDP read waiting for a datagram.
func BenchmarkWaitingUDPReaders(b *testing.B) {
	for _, read := range packetReads {
		b.Run(read.name, func(b *testing.B) {
			if b.N > 2000 {
				b.Skip("run with -benchtime=1000x")
			}
			var wg sync.WaitGroup
			defer wg.Wait()
			b.ReportAllocs()
			before := heapInUse()
			b.ResetTimer()
			sockets, results := startWaitingReaders(b, b.N, 0, read.wrap)
			b.StopTimer()
			b.ReportMetric(float64(int64(heapInUse())-int64(before))/float64(b.N), "heldB/reader")
			for i, socket := range sockets {
				socket.Close()
				wg.Go(func() { <-results[i] })
			}
		})
	}
}
