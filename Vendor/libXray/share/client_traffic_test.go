package share

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	mathrand "math/rand/v2"
	"net"
	"net/http"
	"net/http/httptest"
	"reflect"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
	"weak"

	"github.com/cloudflare/circl/sign/mldsa/mldsa65"
	realityserver "github.com/xtls/reality"
	"github.com/xtls/xray-core/common/buf"
	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/protocol"
	"github.com/xtls/xray-core/common/session"
	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/infra/conf"
	_ "github.com/xtls/xray-core/main/distro/all"
	"github.com/xtls/xray-core/proxy/socks"
)

// Keep actual accepted SOCKS sockets alive through shutdown. The ordinary
// protocol matrix closes its client connections before stopping the core.
func TestCoreStopClosesAcceptedSocksConnections(t *testing.T) {
	for _, mode := range []string{"pending-handshake", "tcp", "udp"} {
		t.Run(mode, func(t *testing.T) {
			type object = map[string]any
			port := trafficPort(t)
			_, stop := startTrafficCore(t, object{"log": object{"loglevel": "none"},
				"inbounds":  []any{object{"listen": "127.0.0.1", "port": port, "protocol": "socks", "settings": object{"auth": "noauth", "udp": true}}},
				"outbounds": []any{object{"protocol": "freedom"}}})
			control, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)), time.Second)
			if err != nil {
				t.Fatal(err)
			}
			defer control.Close()
			control.SetDeadline(time.Now().Add(3 * time.Second))
			var exchange func() bool
			if mode == "pending-handshake" {
				if _, err := control.Write([]byte{5, 1, 0}); err != nil {
					t.Fatal(err)
				}
				reply := make([]byte, 2)
				if _, err := io.ReadFull(control, reply); err != nil || !bytes.Equal(reply, []byte{5, 0}) {
					t.Fatalf("SOCKS greeting: %v, %v", reply, err)
				}
			} else if mode == "tcp" {
				echo, err := net.Listen("tcp", "127.0.0.1:0")
				if err != nil {
					t.Fatal(err)
				}
				defer echo.Close()
				go func() {
					peer, err := echo.Accept()
					if err == nil {
						defer peer.Close()
						peer.SetDeadline(time.Now().Add(3 * time.Second))
						io.Copy(peer, peer)
					}
				}()
				dest := xnet.DestinationFromAddr(echo.Addr())
				if _, err := socks.ClientHandshake(&protocol.RequestHeader{Command: protocol.RequestCommandTCP, Address: dest.Address, Port: dest.Port}, control, control); err != nil {
					t.Fatal(err)
				}
				exchange = func() bool {
					payload := []byte("owned TCP session")
					if _, err := control.Write(payload); err != nil {
						return false
					}
					reply := make([]byte, len(payload))
					_, err := io.ReadFull(control, reply)
					return err == nil && bytes.Equal(reply, payload)
				}
			} else {
				echo, err := net.ListenPacket("udp4", "127.0.0.1:0")
				if err != nil {
					t.Fatal(err)
				}
				defer echo.Close()
				go func() {
					p := make([]byte, 2048)
					for {
						n, peer, err := echo.ReadFrom(p)
						if err != nil {
							return
						}
						echo.WriteTo(p[:n], peer)
					}
				}()
				relay, err := socks.ClientHandshake(&protocol.RequestHeader{Command: protocol.RequestCommandUDP}, control, control)
				if err != nil {
					t.Fatal(err)
				}
				udp, err := net.DialUDP("udp4", nil, &net.UDPAddr{IP: relay.Address.IP(), Port: int(relay.Port)})
				if err != nil {
					t.Fatal(err)
				}
				defer udp.Close()
				dest := xnet.DestinationFromAddr(echo.LocalAddr())
				exchange = func() bool {
					payload := []byte("owned UDP session")
					packet, err := socks.EncodeUDPPacket(&protocol.RequestHeader{Address: dest.Address, Port: dest.Port}, payload)
					if err != nil {
						t.Fatal(err)
					}
					defer packet.Release()
					udp.SetDeadline(time.Now().Add(time.Second))
					if _, err := udp.Write(packet.Bytes()); err != nil {
						return false
					}
					p := make([]byte, 2048)
					n, err := udp.Read(p)
					if err != nil {
						return false
					}
					response := buf.FromBytes(p[:n])
					defer response.Release()
					_, err = socks.DecodeUDPPacket(response)
					return err == nil && bytes.Equal(response.Bytes(), payload)
				}
			}
			if exchange != nil && !exchange() {
				t.Fatal("baseline echo failed")
			}
			stop()
			control.SetReadDeadline(time.Now().Add(time.Second))
			if _, err := control.Read(make([]byte, 1)); err == nil {
				t.Error("control socket still readable after Stop")
			} else if timeout, ok := err.(net.Error); ok && timeout.Timeout() {
				t.Error("accepted control socket remained open after Stop")
			}
			if exchange != nil && exchange() {
				t.Error("accepted session still forwards after Stop")
			}
		})
	}
}

// Proxy mode hands direct traffic to a freedom outbound with AsIs, which dials
// names through the system resolver. A routing profile's DnsHosts pin must
// still win there, as in TUN mode, where apps resolve through the core's DNS.
func TestAsIsFreedomDialsStaticHostsPins(t *testing.T) {
	type object = map[string]any
	const pinned = "pinned.elarni.test"
	// The core's only name server never answers: an unpinned name sent there would stall past every deadline here.
	silent, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer silent.Close()
	port := trafficPort(t)
	instance, _ := startTrafficCore(t, object{"log": object{"loglevel": "none"},
		"dns":       object{"servers": []any{object{"address": "127.0.0.1", "port": silent.LocalAddr().(*net.UDPAddr).Port, "timeoutMs": 30000}}, "hosts": object{pinned: []string{"127.0.0.1"}, "second." + pinned: []string{"127.0.0.1"}}, "queryStrategy": "UseIP", "useSystemHosts": false},
		"inbounds":  []any{object{"listen": "127.0.0.1", "port": port, "protocol": "socks", "settings": object{"auth": "noauth", "udp": true}}},
		"outbounds": []any{object{"protocol": "freedom", "settings": object{"domainStrategy": "AsIs"}, "targetStrategy": "AsIs"}}})
	trafficRoundTrip(t, instance, "tcp", "127.0.0.1", pinned)
	trafficRoundTrip(t, instance, "udp", "127.0.0.1", pinned)
	trafficRoundTrip(t, instance, "tcp", "127.0.0.1", "localhost")

	// A SOCKS UDP client names the destination of each datagram.
	echo, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer echo.Close()
	go func() {
		p := make([]byte, 2048)
		for {
			n, peer, err := echo.ReadFrom(p)
			if err != nil {
				return
			}
			echo.WriteTo(p[:n], peer)
		}
	}()
	control, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)), time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer control.Close()
	control.SetDeadline(time.Now().Add(5 * time.Second))
	relay, err := socks.ClientHandshake(&protocol.RequestHeader{Command: protocol.RequestCommandUDP}, control, control)
	if err != nil {
		t.Fatal(err)
	}
	udp, err := net.DialUDP("udp4", nil, &net.UDPAddr{IP: relay.Address.IP(), Port: int(relay.Port)})
	if err != nil {
		t.Fatal(err)
	}
	defer udp.Close()
	// The first name is the one freedom dials; later names resolve per datagram.
	for _, name := range []string{pinned, "second." + pinned} {
		payload := []byte("SOCKS datagram to " + name)
		packet, err := socks.EncodeUDPPacket(&protocol.RequestHeader{Address: xnet.DomainAddress(name), Port: xnet.Port(echo.LocalAddr().(*net.UDPAddr).Port)}, payload)
		if err != nil {
			t.Fatal(err)
		}
		udp.SetDeadline(time.Now().Add(5 * time.Second))
		_, err = udp.Write(packet.Bytes())
		packet.Release()
		if err != nil {
			t.Fatal(err)
		}
		p := make([]byte, 2048)
		n, err := udp.Read(p)
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		response := buf.FromBytes(p[:n])
		if _, err := socks.DecodeUDPPacket(response); err != nil || !bytes.Equal(response.Bytes(), payload) {
			t.Fatalf("%s: SOCKS UDP reply %q, %v", name, response.Bytes(), err)
		}
		response.Release()
	}
}

// Android runs the core in-process and the elevated Windows VPN child serves
// many sessions, so every reconnect stops one core and starts another in the
// same process. Transports that pool connections per stream config kept a
// stopped core's sockets and goroutines until an idle timeout (300 s for
// XHTTP, 30 min for gRPC) or for good (Hysteria with keepalives). The pool
// entries themselves are checked in the gRPC and Hysteria packages.
func TestCoreRestartsLeaveNoTransportState(t *testing.T) {
	type object = map[string]any
	const id = "00000000-0000-4000-8000-000000000001"
	const password = "fixture-password"
	for _, transport := range []string{"grpc", "hysteria", "xhttp packet-up", "xhttp stream-one"} {
		t.Run(transport, func(t *testing.T) {
			network, mode, _ := strings.Cut(transport, " ")
			protocol, serverSettings, clientSettings := "vless", object{"clients": []any{object{"id": id}}, "decryption": "none"}, object{"id": id, "encryption": "none"}
			serverStream, clientStream := trafficTLS(t)
			serverStream["network"], clientStream["network"] = network, network
			switch network {
			case "hysteria":
				protocol, serverSettings, clientSettings = "hysteria", object{"version": 2, "clients": []any{object{"auth": password}}}, object{"version": 2}
				serverStream["hysteriaSettings"] = object{"version": 2}
				clientStream["hysteriaSettings"] = object{"version": 2, "auth": password}
			case "xhttp":
				for _, stream := range []object{serverStream, clientStream} {
					stream["xhttpSettings"] = object{"path": "/fixture", "mode": mode, "xmux": object{"maxConnections": 3}}
				}
			}
			port := trafficPort(t)
			startTrafficCore(t, object{"log": object{"loglevel": "none"},
				"inbounds":  []any{object{"listen": "127.0.0.1", "port": port, "protocol": protocol, "settings": serverSettings, "streamSettings": serverStream}},
				"outbounds": []any{object{"protocol": "freedom", "settings": object{"finalRules": []any{object{"action": "allow", "ip": []string{"127.0.0.1/32"}}}}}}})
			relayPort, liveSockets := startCountingRelay(t, network == "hysteria", port)
			echo, err := net.Listen("tcp", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			defer echo.Close()
			go func() {
				for {
					peer, err := echo.Accept()
					if err != nil {
						return
					}
					go func() { defer peer.Close(); io.Copy(peer, peer) }()
				}
			}()

			clientSettings["address"], clientSettings["port"] = "127.0.0.1", relayPort
			client := object{"log": object{"loglevel": "none"}, "outbounds": []any{object{"protocol": protocol, "settings": clientSettings, "streamSettings": clientStream}}}
			baseline := 0
			var cores []weak.Pointer[core.Instance]
			for cycle := range 4 {
				instance, stop := startTrafficCore(t, client)
				cores = append(cores, weak.Make(instance))
				var flows []net.Conn
				for range 4 {
					conn, err := core.Dial(t.Context(), instance, xnet.DestinationFromAddr(echo.Addr()))
					if err != nil {
						t.Fatal(err)
					}
					flows = append(flows, conn)
					conn.SetDeadline(time.Now().Add(5 * time.Second))
					reply := make([]byte, 4)
					if _, err := conn.Write([]byte("ping")); err != nil {
						t.Fatal(err)
					}
					if _, err := io.ReadFull(conn, reply); err != nil || string(reply) != "ping" {
						t.Fatalf("cycle %d echo: %q, %v", cycle, reply, err)
					}
				}
				// The last flow stays open, so Stop must also cut streams in use.
				for _, conn := range flows[:len(flows)-1] {
					conn.Close()
				}
				if liveSockets() == 0 {
					t.Fatal("client sockets bypassed the relay")
				}
				stop()
				if n := settle(liveSockets, 0, 5*time.Second); n > 0 {
					t.Errorf("cycle %d: %d %s sockets outlived the stopped core", cycle, n, network)
				}
				flows[len(flows)-1].Close()
				if cycle == 0 {
					// The first core also starts package-level workers, such as Hysteria's cleaner.
					baseline = settle(runtime.NumGoroutine, -1, 5*time.Second)
				}
			}
			// The XHTTP server in this process keeps a reaper goroutine for 30 s
			// after each packet-up session starts.
			if n := settle(runtime.NumGoroutine, baseline, 35*time.Second); n > baseline {
				t.Errorf("%d goroutines outlived the next 3 stopped cores (%d after the first)", n-baseline, baseline)
			}
			reachable := func() (n int) {
				runtime.GC()
				for _, c := range cores {
					if c.Value() != nil {
						n++
					}
				}
				return n
			}
			// Stopped runtime timers keep their closures until their old deadline.
			// XHTTP's 16 s request setup timers may hold a request context, and so
			// its core, that long; nothing may hold a stopped core longer.
			if n := settle(reachable, 0, 20*time.Second); n > 0 {
				t.Errorf("%d of %d stopped cores are still reachable", n, len(cores))
			}
		})
	}
}

// startCountingRelay forwards to the server port and counts the client core's
// sockets that are still open. A UDP socket counts while its port cannot be
// bound again: QUIC sends no close that a relay could rely on.
func startCountingRelay(t *testing.T, udp bool, port int) (int, func() int) {
	t.Helper()
	server := net.JoinHostPort("127.0.0.1", strconv.Itoa(port))
	if !udp {
		relay, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { relay.Close() })
		var live atomic.Int32
		go func() {
			for {
				client, err := relay.Accept()
				if err != nil {
					return
				}
				live.Add(1)
				go func() {
					defer live.Add(-1)
					defer client.Close()
					upstream, err := net.Dial("tcp", server)
					if err != nil {
						return
					}
					defer upstream.Close()
					go func() { io.Copy(upstream, client); upstream.Close() }()
					io.Copy(client, upstream)
				}()
			}
		}()
		return relay.Addr().(*net.TCPAddr).Port, func() int { return int(live.Load()) }
	}
	relay, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	var access sync.Mutex
	upstreams := map[string]net.Conn{}
	t.Cleanup(func() {
		relay.Close()
		access.Lock()
		defer access.Unlock()
		for _, upstream := range upstreams {
			upstream.Close()
		}
	})
	go func() {
		packet := make([]byte, 65536)
		for {
			n, client, err := relay.ReadFrom(packet)
			if err != nil {
				return
			}
			access.Lock()
			upstream := upstreams[client.String()]
			if upstream == nil {
				if upstream, err = net.Dial("udp", server); err != nil {
					access.Unlock()
					continue
				}
				upstreams[client.String()] = upstream
				go func() {
					reply := make([]byte, 65536)
					for {
						n, err := upstream.Read(reply)
						if err != nil {
							return
						}
						relay.WriteTo(reply[:n], client)
					}
				}()
			}
			access.Unlock()
			upstream.Write(packet[:n])
		}
	}()
	return relay.LocalAddr().(*net.UDPAddr).Port, func() int {
		access.Lock()
		defer access.Unlock()
		for client, upstream := range upstreams {
			_, port, _ := net.SplitHostPort(client)
			if probe, err := net.ListenPacket("udp", ":"+port); err == nil {
				probe.Close()
				upstream.Close()
				delete(upstreams, client)
			}
		}
		return len(upstreams)
	}
}

// settle polls count for up to wait until it is at most limit (or, for a
// negative limit, until it stops changing) and returns the last count.
func settle(count func() int, limit int, wait time.Duration) int {
	n := count()
	for deadline := time.Now().Add(wait); time.Now().Before(deadline) && (limit < 0 || n > limit); {
		time.Sleep(200 * time.Millisecond)
		previous := n
		if n = count(); limit < 0 && n == previous {
			break
		}
	}
	return n
}

// Real datagram boundaries are essential here: stream ReadFull can hide a
// large UDP message split into several smaller messages. Construct SOCKS bytes
// independently so the encoder under test cannot silently shrink the oracle.
// Standard VLESS and Shadowsocks peers cannot carry datagrams over 8 KiB, so
// the client must drop them without corruption, a split or a crashed core.
// Replies from these fork-based servers may still arrive, but only intact.
func TestSocksLargeDatagramsCarryExactMessages(t *testing.T) {
	type object = map[string]any
	const id = "00000000-0000-4000-8000-000000000001"
	for _, mode := range []string{"freedom", "vless-xudp", "vless-packet", "socks", "shadowsocks"} {
		t.Run(mode, func(t *testing.T) {
			carries := mode == "freedom" || mode == "socks"
			upstream := mode
			if strings.HasPrefix(mode, "vless-") {
				upstream = "vless"
				t.Setenv("xray.cone.disabled", strconv.FormatBool(mode == "vless-packet"))
			}
			outbound := object{"protocol": "freedom"}
			if upstream != "freedom" {
				port := trafficPort(t)
				settings := object{"auth": "noauth", "udp": true}
				client := object{"address": "127.0.0.1", "port": port}
				switch upstream {
				case "vless":
					settings = object{"clients": []any{object{"id": id}}, "decryption": "none"}
					client["id"], client["encryption"] = id, "none"
				case "shadowsocks":
					settings = object{"method": "aes-128-gcm", "password": "fixture-password", "network": "tcp,udp"}
					client["method"], client["password"] = "aes-128-gcm", "fixture-password"
				}
				_, stop := startTrafficCore(t, object{"log": object{"loglevel": "none"},
					"inbounds": []any{object{"listen": "127.0.0.1", "port": port, "protocol": upstream, "settings": settings}},
					"outbounds": []any{object{"protocol": "freedom", "settings": object{"finalRules": []any{
						object{"action": "allow", "ip": []string{"127.0.0.1/32", "::1/128"}}}}}}})
				defer stop()
				outbound = object{"protocol": upstream, "settings": client}
			}
			port := trafficPort(t)
			_, stop := startTrafficCore(t, object{"log": object{"loglevel": "none"},
				"inbounds":  []any{object{"listen": "127.0.0.1", "port": port, "protocol": "socks", "settings": object{"auth": "noauth", "udp": true}}},
				"outbounds": []any{outbound}})
			defer stop()
			for _, host := range []string{"127.0.0.1", "::1"} {
				for _, size := range []int{8192, 32768} {
					for _, direction := range []string{"uplink", "downlink"} {
						t.Run(fmt.Sprintf("%s/%d/%s", host, size, direction), func(t *testing.T) {
							echo, err := net.ListenPacket("udp", net.JoinHostPort(host, "0"))
							if err != nil {
								t.Fatal(err)
							}
							defer echo.Close()
							if err := echo.(*net.UDPConn).SetWriteBuffer(65535); err != nil {
								t.Fatal(err)
							}
							request, reply := []byte{0x31}, []byte{0x72}
							large := make([]byte, size)
							for i := range large {
								large[i] = byte(i % 251)
							}
							if direction == "uplink" {
								request = large
							} else {
								reply = large
							}
							// A later one-byte 0x32 probe shows that a dropped datagram left the session working.
							received := make(chan []byte, 4)
							echo.SetDeadline(time.Now().Add(5 * time.Second))
							go func() {
								p := make([]byte, 65535)
								for {
									n, peer, err := echo.ReadFrom(p)
									if err != nil {
										return
									}
									received <- append([]byte(nil), p[:n]...)
									answer := reply
									if n == 1 && p[0] == 0x32 {
										answer = []byte{0x73}
									}
									echo.WriteTo(answer, peer)
								}
							}()
							control, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)), time.Second)
							if err != nil {
								t.Fatal(err)
							}
							defer control.Close()
							control.SetDeadline(time.Now().Add(5 * time.Second))
							relay, err := socks.ClientHandshake(&protocol.RequestHeader{Command: protocol.RequestCommandUDP}, control, control)
							if err != nil {
								t.Fatal(err)
							}
							udp, err := net.DialUDP("udp4", nil, &net.UDPAddr{IP: relay.Address.IP(), Port: int(relay.Port)})
							if err != nil {
								t.Fatal(err)
							}
							defer udp.Close()
							if err := udp.SetWriteBuffer(65535); err != nil {
								t.Fatal(err)
							}
							dest := echo.LocalAddr().(*net.UDPAddr)
							header := []byte{0, 0, 0, 1}
							ip := dest.IP.To4()
							if ip == nil {
								header[3] = 4
								ip = dest.IP.To16()
							}
							header = append(header, ip...)
							header = binary.BigEndian.AppendUint16(header, uint16(dest.Port))
							send := func(payload []byte) {
								if _, err := udp.Write(append(append([]byte(nil), header...), payload...)); err != nil {
									t.Fatal(err)
								}
							}
							p := make([]byte, 65535)
							expectReply := func(payload []byte) {
								udp.SetReadDeadline(time.Now().Add(2 * time.Second))
								n, err := udp.Read(p)
								expected := append(append([]byte(nil), header...), payload...)
								if err != nil || !bytes.Equal(p[:n], expected) {
									t.Fatalf("downlink datagram: got %d bytes, want %d, error %v", n, len(expected), err)
								}
							}
							expectReceived := func(payload []byte) {
								select {
								case got := <-received:
									if !bytes.Equal(got, payload) {
										t.Fatalf("uplink datagram length/content: got %d, want %d", len(got), len(payload))
									}
								case <-time.After(2 * time.Second):
									t.Fatalf("uplink datagram of %d bytes was not delivered", len(payload))
								}
							}
							send(request)
							if carries {
								expectReceived(request)
								expectReply(reply)
								udp.SetReadDeadline(time.Now().Add(30 * time.Millisecond))
								if n, err := udp.Read(p); err == nil {
									t.Fatalf("extra datagram: %d bytes", n)
								}
								return
							}
							if direction == "uplink" {
								select {
								case got := <-received:
									t.Fatalf("oversized uplink datagram reached the server as %d bytes", len(got))
								case <-time.After(200 * time.Millisecond):
								}
							} else {
								expectReceived(request)
								udp.SetReadDeadline(time.Now().Add(200 * time.Millisecond))
								expected := append(append([]byte(nil), header...), reply...)
								if n, err := udp.Read(p); err == nil && !bytes.Equal(p[:n], expected) {
									t.Fatalf("oversized downlink datagram arrived altered as %d bytes", n)
								}
							}
							send([]byte{0x32})
							expectReceived([]byte{0x32})
							expectReply([]byte{0x73})
						})
					}
				}
			}
		})
	}
}

// These fixtures are synthetic local servers. They exercise imported client
// configurations, authentication, both address families, and core restart.
func TestImportedClientsCarryLoopbackTraffic(t *testing.T) {
	type object = map[string]any
	const id = "00000000-0000-4000-8000-000000000001"
	const password = "fixture-password"
	serverTLS, clientTLS := trafficTLS(t)
	fixtures := []struct {
		name, protocol string
		server, client object
		network        string
		tls, udp       bool
	}{
		{"VLESS", "vless", object{"clients": []any{object{"id": id}}, "decryption": "none"}, object{"id": id, "encryption": "none"}, "raw", false, true},
		{"VMess", "vmess", object{"clients": []any{object{"id": id}}}, object{"id": id, "security": "auto"}, "raw", false, true},
		{"Trojan TLS", "trojan", object{"clients": []any{object{"password": password}}}, object{"password": password}, "raw", true, true},
		{"Shadowsocks", "shadowsocks", object{"method": "chacha20-ietf-poly1305", "password": password, "network": "tcp,udp"}, object{"method": "chacha20-ietf-poly1305", "password": password}, "raw", false, true},
		{"Shadowsocks 2022", "shadowsocks", object{"method": "2022-blake3-aes-128-gcm", "password": base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{1}, 16)), "network": "tcp,udp"}, object{"method": "2022-blake3-aes-128-gcm", "password": base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{1}, 16))}, "raw", false, true},
		{"SOCKS", "socks", object{"auth": "password", "accounts": []any{object{"user": "fixture", "pass": password}}, "udp": true, "ip": "127.0.0.1"}, object{"user": "fixture", "pass": password}, "raw", false, true},
		{"HTTP", "http", object{"accounts": []any{object{"user": "fixture", "pass": password}}}, object{"user": "fixture", "pass": password}, "raw", false, false},
		{"HTTPS", "http", object{"accounts": []any{object{"user": "fixture", "pass": password}}}, object{"user": "fixture", "pass": password}, "raw", true, false},
		{"Hysteria2", "hysteria", object{"version": 2, "clients": []any{object{"auth": password}}}, object{"version": 2}, "hysteria", true, true},
	}
	for _, network := range []string{"ws", "grpc", "httpupgrade", "xhttp", "kcp"} {
		fixture := fixtures[0]
		fixture.name, fixture.network, fixture.tls = "VLESS "+network, network, network != "kcp"
		fixtures = append(fixtures, fixture)
	}
	for _, index := range []int{3, 4, 5} {
		fixture := fixtures[index]
		fixture.name += " KCP"
		fixture.network = "kcp"
		// SS UDP packets require their own datagram listener, which cannot
		// share the KCP listener's UDP port. SOCKS negotiates a separate relay.
		fixture.udp = fixture.protocol == "socks"
		fixtures = append(fixtures, fixture)
	}
	for _, fixture := range fixtures {
		t.Run(fixture.name, func(t *testing.T) {
			for cycle := 0; cycle < 2; cycle++ {
				serverAddress := "127.0.0.1"
				if cycle == 1 {
					serverAddress = "::1"
				}
				port := trafficPort(t, serverAddress)
				serverSettings := object{}
				for key, value := range fixture.server {
					serverSettings[key] = value
				}
				if fixture.protocol == "socks" {
					serverSettings["ip"] = serverAddress
				}
				if fixture.protocol == "shadowsocks" && fixture.network == "kcp" {
					serverSettings["network"] = "tcp"
				}
				serverStream, clientStream := object{"network": fixture.network}, object{"network": fixture.network}
				if fixture.tls {
					for k, v := range serverTLS {
						serverStream[k] = v
					}
					for k, v := range clientTLS {
						clientStream[k] = v
					}
				}
				if fixture.network == "hysteria" {
					serverStream["hysteriaSettings"] = object{"version": 2}
					clientStream["hysteriaSettings"] = object{"version": 2, "auth": password}
				}
				if fixture.network == "xhttp" {
					serverStream["xhttpSettings"] = object{"path": "/fixture"}
					clientStream["xhttpSettings"] = object{"path": "/fixture", "mode": "stream-up"}
				}
				server, stopServer := startTrafficCore(t, object{"log": object{"loglevel": "none"},
					"inbounds":  []any{object{"listen": serverAddress, "port": port, "protocol": fixture.protocol, "settings": serverSettings, "streamSettings": serverStream}},
					"outbounds": []any{object{"protocol": "freedom", "settings": object{"finalRules": []any{object{"action": "allow", "ip": []string{"127.0.0.1/32", "::1/128"}}}}}}})
				_ = server
				settings := object{"address": serverAddress, "port": port}
				for k, v := range fixture.client {
					settings[k] = v
				}
				input, err := json.Marshal(object{"outbounds": []any{object{"tag": "proxy", "protocol": fixture.protocol, "settings": settings, "streamSettings": clientStream}}})
				if err != nil {
					t.Fatal(err)
				}
				imported, err := ImportClientProfiles(string(input))
				if err != nil {
					t.Fatal(err)
				}
				var profile object
				if err := json.Unmarshal(imported.Profiles[0].Config, &profile); err != nil {
					t.Fatal(err)
				}
				profile["log"] = object{"loglevel": "none"}
				client, stopClient := startTrafficCore(t, profile)
				for _, address := range []string{"127.0.0.1", "::1"} {
					trafficRoundTrip(t, client, "tcp", address)
					if fixture.udp {
						trafficRoundTrip(t, client, "udp", address)
					}
				}
				stopClient()
				stopServer()
			}
		})
	}
}

func trafficTLS(t *testing.T) (map[string]any, map[string]any) {
	t.Helper()
	type object = map[string]any
	certificateServer := httptest.NewTLSServer(http.NotFoundHandler())
	certificate := certificateServer.TLS.Certificates[0]
	certificateServer.Close()
	key, err := x509.MarshalPKCS8PrivateKey(certificate.PrivateKey)
	if err != nil {
		t.Fatal(err)
	}
	pin := sha256.Sum256(certificate.Certificate[0])
	serverTLS := object{"security": "tls", "tlsSettings": object{"certificates": []any{object{
		"certificate": strings.Split(string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: certificate.Certificate[0]})), "\n"),
		"key":         strings.Split(string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: key})), "\n"),
	}}}}
	clientTLS := object{"security": "tls", "tlsSettings": object{"pinnedPeerCertSha256": hex.EncodeToString(pin[:])}}
	return serverTLS, clientTLS
}

func TestImportedAdvancedSecurityCarriesTraffic(t *testing.T) {
	type object = map[string]any
	const id = "00000000-0000-4000-8000-000000000001"
	for _, security := range []string{"TLS ECH", "REALITY Vision", "VLESS encryption"} {
		t.Run(security, func(t *testing.T) {
			private, err := ecdh.X25519().GenerateKey(rand.Reader)
			if err != nil {
				t.Fatal(err)
			}
			serverStream, clientStream := trafficTLS(t)
			serverUser, clientSettings := object{"id": id}, object{"id": id, "encryption": "none"}
			decryption := "none"
			if security == "TLS ECH" {
				// ECHConfig wire layout: X25519/HKDF-SHA256/AES-128-GCM, no extensions.
				body := []byte{0, 0, 0x20, 0, 32}
				body = append(body, private.PublicKey().Bytes()...)
				body = append(body, 0, 4, 0, 1, 0, 1, 0, 11)
				body = append(body, []byte("example.com")...)
				body = append(body, 0, 0)
				config := binary.BigEndian.AppendUint16([]byte{0xfe, 0x0d}, uint16(len(body)))
				config = append(config, body...)
				publicList := binary.BigEndian.AppendUint16(nil, uint16(len(config)))
				publicList = append(publicList, config...)
				keys := binary.BigEndian.AppendUint16(nil, 32)
				keys = append(keys, private.Bytes()...)
				keys = binary.BigEndian.AppendUint16(keys, uint16(len(config)))
				keys = append(keys, config...)
				serverStream["tlsSettings"].(object)["echServerKeys"] = base64.StdEncoding.EncodeToString(keys)
				clientStream["tlsSettings"].(object)["echConfigList"] = base64.StdEncoding.EncodeToString(publicList)
				clientStream["tlsSettings"].(object)["serverName"] = "example.com"
			} else if security == "VLESS encryption" {
				decryption = "mlkem768x25519plus.native.600s." + base64.RawURLEncoding.EncodeToString(private.Bytes())
				clientSettings["encryption"] = "mlkem768x25519plus.native.1rtt." + base64.RawURLEncoding.EncodeToString(private.PublicKey().Bytes())
			} else {
				serverStream, clientStream = realityTrafficStreams(t, private)
				serverUser["flow"], clientSettings["flow"] = "xtls-rprx-vision", "xtls-rprx-vision"
			}
			for cycle := 0; cycle < 2; cycle++ {
				port := trafficPort(t)
				_, stopServer := startTrafficCore(t, object{"log": object{"loglevel": "none"},
					"inbounds":  []any{object{"listen": "127.0.0.1", "port": port, "protocol": "vless", "settings": object{"clients": []any{serverUser}, "decryption": decryption}, "streamSettings": serverStream}},
					"outbounds": []any{object{"protocol": "freedom", "settings": object{"finalRules": []any{object{"action": "allow", "ip": []string{"127.0.0.1/32", "::1/128"}}}}}}})
				if security == "TLS ECH" && cycle == 1 {
					clientStream["tlsSettings"].(object)["fingerprint"] = "chrome"
				}
				clientSettings["address"], clientSettings["port"] = "127.0.0.1", port
				raw, _ := json.Marshal(object{"outbounds": []any{object{"protocol": "vless", "settings": clientSettings, "streamSettings": clientStream}}})
				imported, err := ImportClientProfiles(string(raw))
				if err != nil {
					t.Fatal(err)
				}
				var profile object
				if err := json.Unmarshal(imported.Profiles[0].Config, &profile); err != nil {
					t.Fatal(err)
				}
				profile["log"] = object{"loglevel": "none"}
				client, stopClient := startTrafficCore(t, profile)
				for _, address := range []string{"127.0.0.1", "::1"} {
					trafficRoundTrip(t, client, "tcp", address)
					trafficRoundTrip(t, client, "udp", address)
				}
				stopClient()
				stopServer()
			}
		})
	}
}

// Xray applies UDP masks last to first and only the first applied may dial, so
// a hop mask in front of salamander failed every connection.
func TestHysteria2ObfuscatedHoppingLinkCarriesTraffic(t *testing.T) {
	type object = map[string]any
	const password = "fixture-password"
	serverTLS, clientTLS := trafficTLS(t)
	pin := clientTLS["tlsSettings"].(object)["pinnedPeerCertSha256"].(string)
	port := trafficPort(t)
	stream := object{"network": "hysteria", "hysteriaSettings": object{"version": 2},
		"finalmask": object{"udp": []any{object{"type": "salamander", "settings": object{"password": "fixture-obfs"}}}}}
	for k, v := range serverTLS {
		stream[k] = v
	}
	startTrafficCore(t, object{"log": object{"loglevel": "none"},
		"inbounds":  []any{object{"listen": "127.0.0.1", "port": port, "protocol": "hysteria", "settings": object{"version": 2, "clients": []any{object{"auth": password}}}, "streamSettings": stream}},
		"outbounds": []any{object{"protocol": "freedom", "settings": object{"finalRules": []any{object{"action": "allow", "ip": []string{"127.0.0.1/32"}}}}}}})
	imported, err := ImportClientProfiles(fmt.Sprintf("hysteria2://%s@127.0.0.1:%d?sni=example.com&pinSHA256=%s&obfs=salamander&obfs-password=fixture-obfs&ports=%d#hop", password, port, pin, port))
	if err != nil {
		t.Fatal(err)
	}
	var profile object
	if err := json.Unmarshal(imported.Profiles[0].Config, &profile); err != nil {
		t.Fatal(err)
	}
	profile["log"] = object{"loglevel": "none"}
	client, _ := startTrafficCore(t, profile)
	trafficRoundTrip(t, client, "tcp", "127.0.0.1")
	trafficRoundTrip(t, client, "udp", "127.0.0.1")
}

// realityTrafficStreams starts a TLS 1.3 cover target and returns REALITY
// server and client stream settings for it.
func realityTrafficStreams(t *testing.T, private *ecdh.PrivateKey) (server, client map[string]any) {
	t.Helper()
	type object = map[string]any
	target := realityCoverTarget(t)
	target.StartTLS()
	t.Cleanup(target.Close)
	// The server's public-certificate probe cannot trust httptest's certificate.
	// Supply the target's fixture padding policy; REALITY authentication stays real.
	for _, alpn := range []string{"0", "1", "2"} {
		key := target.Listener.Addr().String() + " example.com " + alpn
		realityserver.GlobalPostHandshakeRecordsLens.Store(key, []int{})
		t.Cleanup(func() { realityserver.GlobalPostHandshakeRecordsLens.Delete(key) })
	}
	seed := [32]byte{1}
	verification, _ := mldsa65.NewKeyFromSeed(&seed)
	server = object{"security": "reality", "realitySettings": object{
		"target": target.Listener.Addr().String(), "serverNames": []string{"example.com"},
		"mldsa65Seed": base64.RawURLEncoding.EncodeToString(seed[:]), "privateKey": base64.RawURLEncoding.EncodeToString(private.Bytes()), "shortIds": []string{"0123456789abcdef"},
	}}
	client = object{"security": "reality", "realitySettings": object{
		"mldsa65Verify": base64.RawURLEncoding.EncodeToString(verification.Bytes()), "serverName": "example.com", "fingerprint": "chrome", "publicKey": base64.RawURLEncoding.EncodeToString(private.PublicKey().Bytes()), "shortId": "0123456789abcdef",
	}}
	return server, client
}

// realityCoverTarget returns an unstarted TLS 1.3 server for REALITY to borrow.
func realityCoverTarget(t *testing.T) *httptest.Server {
	t.Helper()
	target := httptest.NewUnstartedServer(http.NotFoundHandler())
	target.EnableHTTP2 = true
	issuer := httptest.NewTLSServer(http.NotFoundHandler())
	certificate := issuer.TLS.Certificates[0]
	issuer.Close()
	template, err := x509.ParseCertificate(certificate.Certificate[0])
	if err != nil {
		t.Fatal(err)
	}
	// REALITY needs enough target certificate space for ML-DSA-65.
	template.ExtraExtensions = []pkix.Extension{{Id: []int{1, 2, 3, 4}, Value: make([]byte, 4096)}}
	encoded, err := x509.CreateCertificate(rand.Reader, template, template, template.PublicKey, certificate.PrivateKey)
	if err != nil {
		t.Fatal(err)
	}
	certificate.Certificate = [][]byte{encoded}
	target.TLS = &tls.Config{Certificates: []tls.Certificate{certificate}, CurvePreferences: []tls.CurveID{tls.X25519}, MinVersion: tls.VersionTLS13}
	return target
}

func startTrafficCore(t *testing.T, profile map[string]any) (*core.Instance, func()) {
	t.Helper()
	raw, err := json.Marshal(profile)
	if err != nil {
		t.Fatal(err)
	}
	var config conf.Config
	if err := json.Unmarshal(raw, &config); err != nil {
		t.Fatal(err)
	}
	restoreNilRawMessages(reflect.ValueOf(&config))
	built, err := config.Build()
	if err != nil {
		t.Fatal(err)
	}
	instance, err := core.New(built)
	if err != nil {
		t.Fatal(err)
	}
	stop := func() {
		if instance != nil {
			if err := instance.Close(); err != nil {
				t.Error(err)
			}
			instance = nil // t.Cleanup keeps this func, which must not keep the core
		}
	}
	t.Cleanup(stop)
	if err := instance.Start(); err != nil {
		t.Fatal(err)
	}
	return instance, stop
}

// trafficPort returns a port free for both TCP and UDP: SOCKS, Shadowsocks and
// QUIC fixtures bind both, and a one-protocol check can land on a busy port
// (Windows mDNS holds UDP 5353). It stays below the ephemeral ranges (Linux 32768
// and up, Windows and macOS 49152 and up), so another test's outgoing connection
// cannot take the port before the fixture binds it.
func trafficPort(t *testing.T, hosts ...string) int {
	t.Helper()
	host := "127.0.0.1"
	if len(hosts) > 0 {
		host = hosts[0]
	}
	for range 64 {
		port := 20000 + mathrand.IntN(12000)
		tcp, err := net.Listen("tcp", net.JoinHostPort(host, strconv.Itoa(port)))
		if err != nil {
			continue
		}
		udp, err := net.ListenPacket("udp", net.JoinHostPort(host, strconv.Itoa(port)))
		tcp.Close()
		if err == nil {
			udp.Close()
			return port
		}
	}
	t.Fatal("no port is free for both TCP and UDP")
	return 0
}

func trafficRoundTrip(t *testing.T, instance *core.Instance, network, address string, destinationHost ...string) {
	t.Helper()
	trafficRoundTripFromInbound(t, instance, network, address, "", destinationHost...)
}

func trafficRoundTripFromInbound(t *testing.T, instance *core.Instance, network, address, inbound string, destinationHost ...string) {
	t.Helper()
	payload := []byte(fmt.Sprintf("elarni %s %s fixture", network, address))
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if inbound != "" {
		ctx = session.ContextWithInbound(ctx, &session.Inbound{Tag: inbound})
	}
	var target net.Addr
	done := make(chan struct{})
	if network == "tcp" {
		listener, err := net.Listen("tcp", net.JoinHostPort(address, "0"))
		if err != nil {
			t.Fatal(err)
		}
		defer listener.Close()
		target = listener.Addr()
		go func() {
			defer close(done)
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			defer conn.Close()
			conn.SetDeadline(time.Now().Add(5 * time.Second))
			received := make([]byte, len(payload))
			if _, err := io.ReadFull(conn, received); err == nil {
				conn.Write(received)
			}
		}()
	} else {
		socket, err := net.ListenPacket("udp", net.JoinHostPort(address, "0"))
		if err != nil {
			t.Fatal(err)
		}
		defer socket.Close()
		target = socket.LocalAddr()
		go func() {
			defer close(done)
			socket.SetDeadline(time.Now().Add(5 * time.Second))
			buffer := make([]byte, 2048)
			n, peer, err := socket.ReadFrom(buffer)
			if err == nil {
				socket.WriteTo(buffer[:n], peer)
			}
		}()
	}
	destination := xnet.DestinationFromAddr(target)
	if len(destinationHost) > 0 {
		destination.Address = xnet.DomainAddress(destinationHost[0])
	}
	conn, err := core.Dial(ctx, instance, destination)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	stopCancellation := context.AfterFunc(ctx, func() { conn.Close() })
	defer stopCancellation()
	conn.SetDeadline(time.Now().Add(5 * time.Second))
	if _, err := conn.Write(payload); err != nil {
		t.Fatal(err)
	}
	response := make([]byte, len(payload))
	if _, err := io.ReadFull(conn, response); err != nil {
		t.Fatalf("%s %s: %v", network, address, err)
	}
	if !bytes.Equal(payload, response) {
		t.Fatal("traffic payload changed")
	}
	conn.Close()
	cancel()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("echo did not shut down")
	}
}
