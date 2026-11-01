package wireguard

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	awg "github.com/amnezia-vpn/amneziawg-go/v3/device"
	"github.com/xtls/xray-core/common/buf"
	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/features/dns"
	"github.com/xtls/xray-core/transport/internet"
	"golang.zx2c4.com/wireguard/device"
	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
)

// offlineDNS resolves every name to loopback unless offline is set.
type offlineDNS struct{ offline *atomic.Bool }

func (offlineDNS) Type() any    { return dns.ClientType() }
func (offlineDNS) Start() error { return nil }
func (offlineDNS) Close() error { return nil }
func (d offlineDNS) LookupIP(string, dns.IPOption) ([]net.IP, uint32, error) {
	if d.offline.Load() {
		return nil, 0, errors.New("offline")
	}
	return []net.IP{net.IPv4(127, 0, 0, 1)}, 0, nil
}

// Regression: a start that failed while offline closed the device and its TUN,
// so every later dial failed with "closed" until the core restarted.
func TestWireGuardRetriesFailedStart(t *testing.T) {
	var dnsOffline, socketOffline atomic.Bool
	previous := internet.RequiredSocketController
	internet.RequiredSocketController = func(string, string, syscall.RawConn) error {
		if socketOffline.Load() {
			return errors.New("offline")
		}
		return nil
	}
	t.Cleanup(func() { internet.RequiredSocketController = previous })
	for _, amnezia := range []bool{false, true} {
		// IpcSet fails resolving the peer endpoint; dev.Up fails opening the bind's socket.
		for _, failing := range []string{"endpoint_dns", "bind_socket"} {
			t.Run(fmt.Sprintf("amnezia=%t/%s", amnezia, failing), func(t *testing.T) {
				offline := &dnsOffline
				if failing == "bind_socket" {
					offline = &socketOffline
				}
				clientKey, err := ecdh.X25519().GenerateKey(rand.Reader)
				if err != nil {
					t.Fatal(err)
				}
				serverKey, err := ecdh.X25519().GenerateKey(rand.Reader)
				if err != nil {
					t.Fatal(err)
				}
				clientTun, clientNet, _, err := CreateNetTUN([]netip.Addr{netip.MustParseAddr("10.29.0.2")}, nil, 1280, true)
				if err != nil {
					t.Fatal(err)
				}
				serverTun, _, serverStack, err := CreateNetTUN([]netip.Addr{netip.MustParseAddr("10.29.0.1")}, nil, 1280, true)
				if err != nil {
					clientTun.Close()
					t.Fatal(err)
				}
				serverSocket, err := net.ListenPacket("udp4", "127.0.0.1:0")
				if err != nil {
					clientTun.Close()
					serverTun.Close()
					t.Fatal(err)
				}
				serverBind := &bind{preserveHeader: amnezia, listenFunc: func() (net.PacketConn, error) { return serverSocket, nil }}
				var server tunnelDevice
				settings := map[string]string{}
				if amnezia {
					server = awg.NewDevice(adaptAmneziaTUN(serverTun), &amneziaBind{serverBind}, &awg.Logger{Verbosef: func(string, ...any) {}, Errorf: t.Logf})
					// Headers must match the server's, so a retry that skipped the config could not handshake.
					settings = map[string]string{"jc": "2", "jmin": "10", "jmax": "20", "h1": "100000-100100", "h2": "200000-200100", "h3": "300000-300100", "h4": "400000-400100"}
				} else {
					server = device.NewDevice(serverTun, serverBind, &device.Logger{Verbosef: func(string, ...any) {}, Errorf: t.Logf})
				}
				defer serverSocket.Close()
				defer server.Close()
				serverConfig := "private_key=" + hex.EncodeToString(serverKey.Bytes()) + "\n"
				for key, value := range settings {
					serverConfig += key + "=" + value + "\n"
				}
				if err := server.IpcSet(serverConfig + "public_key=" + hex.EncodeToString(clientKey.PublicKey().Bytes()) + "\nallowed_ip=10.29.0.2/32\n"); err != nil {
					t.Fatal(err)
				}
				if err := server.Up(); err != nil {
					t.Fatal(err)
				}
				endpoint := fmt.Sprintf("localhost:%d", serverSocket.LocalAddr().(*net.UDPAddr).Port)
				handler := &Handler{conf: &DeviceConfig{SecretKey: hex.EncodeToString(clientKey.Bytes()), Amnezia: amnezia, AmneziaSettings: settings,
					Peers: []*PeerConfig{{PublicKey: hex.EncodeToString(serverKey.PublicKey().Bytes()), Endpoint: endpoint, AllowedIps: []string{"0.0.0.0/0"}}}},
					dns: offlineDNS{&dnsOffline}, tun: clientTun, tnet: clientNet, streamSettings: &internet.MemoryStreamConfig{}}
				defer handler.Close()

				offline.Store(true)
				if err := handler.init(context.Background()); err == nil {
					t.Fatal("WireGuard started while offline")
				}
				offline.Store(false)
				if err := handler.init(context.Background()); err != nil {
					t.Fatalf("WireGuard did not start once back online: %v", err)
				}
				remote := netip.MustParseAddrPort("10.29.0.1:18183")
				full, family := convertToFullAddr(remote)
				listener, err := gonet.ListenTCP(serverStack, full, family)
				if err != nil {
					t.Fatal(err)
				}
				defer listener.Close()
				go func() {
					conn, err := listener.Accept()
					if err != nil {
						return
					}
					defer conn.Close()
					conn.SetDeadline(time.Now().Add(10 * time.Second))
					io.Copy(conn, conn)
				}()
				ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
				connection, err := clientNet.DialContextTCPAddrPort(ctx, remote)
				cancel()
				if err != nil {
					t.Fatal(err)
				}
				checkEcho(t, connection)
				if err := handler.Close(); err != nil {
					t.Fatal(err)
				}
				if err := handler.init(context.Background()); err == nil {
					t.Fatal("closed WireGuard handler restarted")
				}
			})
		}
	}
}

// Regression: replies were read into one buf.Size buffer, so a datagram over
// 8 KiB reached the client truncated although the handler carries large packets.
func TestWireGuardDeliversLargeUDPReplies(t *testing.T) {
	clientKey, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	serverKey, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	clientTun, clientNet, _, err := CreateNetTUN([]netip.Addr{netip.MustParseAddr("10.29.0.2")}, nil, 1280, true)
	if err != nil {
		t.Fatal(err)
	}
	serverTun, _, serverStack, err := CreateNetTUN([]netip.Addr{netip.MustParseAddr("10.29.0.1")}, nil, 1280, true)
	if err != nil {
		clientTun.Close()
		t.Fatal(err)
	}
	serverSocket, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		clientTun.Close()
		serverTun.Close()
		t.Fatal(err)
	}
	server := device.NewDevice(serverTun, &bind{listenFunc: func() (net.PacketConn, error) { return serverSocket, nil }}, &device.Logger{Verbosef: func(string, ...any) {}, Errorf: t.Logf})
	defer serverSocket.Close()
	defer server.Close()
	if err := server.IpcSet("private_key=" + hex.EncodeToString(serverKey.Bytes()) + "\npublic_key=" + hex.EncodeToString(clientKey.PublicKey().Bytes()) + "\nallowed_ip=10.29.0.2/32\n"); err != nil {
		t.Fatal(err)
	}
	if err := server.Up(); err != nil {
		t.Fatal(err)
	}
	handler := &Handler{conf: &DeviceConfig{SecretKey: hex.EncodeToString(clientKey.Bytes()),
		Peers: []*PeerConfig{{PublicKey: hex.EncodeToString(serverKey.PublicKey().Bytes()), Endpoint: serverSocket.LocalAddr().String(), AllowedIps: []string{"0.0.0.0/0"}}}},
		dns: offlineDNS{&atomic.Bool{}}, tun: clientTun, tnet: clientNet, streamSettings: &internet.MemoryStreamConfig{}}
	defer handler.Close()
	if err := handler.init(context.Background()); err != nil {
		t.Fatal(err)
	}
	remote := netip.MustParseAddrPort("10.29.0.1:5300")
	full, family := convertToFullAddr(remote)
	listener, err := gonet.DialUDP(serverStack, &full, nil, family)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	reply := make([]byte, 9000)
	for i := range reply {
		reply[i] = byte(i % 251)
	}
	go func() {
		request := make([]byte, 16)
		_, peer, err := listener.ReadFrom(request)
		if err == nil {
			listener.WriteTo(reply, peer)
		}
	}()
	conn, err := clientNet.DialUDPAddrPort(netip.AddrPort{}, remote)
	if err != nil {
		t.Fatal(err)
	}
	packets := conn.(*xnet.PacketConnWrapper).PacketConn
	defer packets.Close()
	client := &udpConnClient{PacketConn: packets, dest: net.UDPAddrFromAddrPort(remote)}
	request := buf.New()
	request.WriteString("ping")
	if err := client.WriteMultiBuffer(buf.MultiBuffer{request}); err != nil {
		t.Fatal(err)
	}
	packets.SetReadDeadline(time.Now().Add(10 * time.Second))
	received, err := client.ReadMultiBuffer()
	if err != nil {
		t.Fatal(err)
	}
	defer buf.ReleaseMulti(received)
	if len(received) != 1 || !bytes.Equal(received[0].Bytes(), reply) {
		t.Fatalf("received %d bytes in %d buffers, want the %d-byte reply in one", received.Len(), len(received), len(reply))
	}
}

// Regression: the bind kept its first socket for the device's life. On Windows
// that socket stays on the adapter it was bound to, so after the default route
// moved to another adapter the tunnel was dead until the core restarted.
func TestWireGuardRebindsWhenTheSocketPathChanges(t *testing.T) {
	clientKey, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	serverKey, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	clientTun, clientNet, _, err := CreateNetTUN([]netip.Addr{netip.MustParseAddr("10.29.0.2")}, nil, 1280, true)
	if err != nil {
		t.Fatal(err)
	}
	serverTun, _, serverStack, err := CreateNetTUN([]netip.Addr{netip.MustParseAddr("10.29.0.1")}, nil, 1280, true)
	if err != nil {
		clientTun.Close()
		t.Fatal(err)
	}
	serverSocket, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		clientTun.Close()
		serverTun.Close()
		t.Fatal(err)
	}
	server := device.NewDevice(serverTun, &bind{listenFunc: func() (net.PacketConn, error) { return serverSocket, nil }}, &device.Logger{Verbosef: func(string, ...any) {}, Errorf: t.Logf})
	defer serverSocket.Close()
	defer server.Close()
	if err := server.IpcSet("private_key=" + hex.EncodeToString(serverKey.Bytes()) + "\npublic_key=" + hex.EncodeToString(clientKey.PublicKey().Bytes()) + "\nallowed_ip=10.29.0.2/32\n"); err != nil {
		t.Fatal(err)
	}
	if err := server.Up(); err != nil {
		t.Fatal(err)
	}
	// The relay stands in for the network: packets from a dead client socket reach nothing.
	relay, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer relay.Close()
	var mu sync.Mutex
	var client, dead string
	go func() {
		packet := make([]byte, 65535)
		for {
			n, from, err := relay.ReadFrom(packet)
			if err != nil {
				return
			}
			mu.Lock()
			to := serverSocket.LocalAddr().String()
			if from.String() == to {
				to = client
			} else if from.String() != dead {
				client = from.String()
			} else {
				to = ""
			}
			mu.Unlock()
			if address, err := net.ResolveUDPAddr("udp4", to); to != "" && err == nil {
				relay.WriteTo(packet[:n], address)
			}
		}
	}()
	handler := &Handler{conf: &DeviceConfig{SecretKey: hex.EncodeToString(clientKey.Bytes()),
		Peers: []*PeerConfig{{PublicKey: hex.EncodeToString(serverKey.PublicKey().Bytes()), Endpoint: relay.LocalAddr().String(), AllowedIps: []string{"0.0.0.0/0"}}}},
		dns: offlineDNS{&atomic.Bool{}}, tun: clientTun, tnet: clientNet, streamSettings: &internet.MemoryStreamConfig{}}
	defer handler.Close()
	if err := handler.init(context.Background()); err != nil {
		t.Fatal(err)
	}
	remote := netip.MustParseAddrPort("10.29.0.1:5301")
	full, family := convertToFullAddr(remote)
	listener, err := gonet.DialUDP(serverStack, &full, nil, family)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	go func() {
		packet := make([]byte, 64)
		for {
			n, peer, err := listener.ReadFrom(packet)
			if err != nil {
				return
			}
			listener.WriteTo(packet[:n], peer)
		}
	}()
	echo := func() bool {
		conn, err := clientNet.DialUDPAddrPort(netip.AddrPort{}, remote)
		if err != nil {
			return false
		}
		defer conn.Close()
		conn.SetDeadline(time.Now().Add(time.Second))
		if _, err := conn.Write([]byte("ping")); err != nil {
			return false
		}
		reply := make([]byte, 16)
		n, err := conn.Read(reply)
		return err == nil && string(reply[:n]) == "ping"
	}
	if !echo() {
		t.Fatal("tunnel did not start")
	}
	mu.Lock()
	dead = client
	mu.Unlock()
	if echo() {
		t.Fatal("the old path still carried traffic")
	}
	internet.SocketPathChanged()
	for deadline := time.Now().Add(10 * time.Second); !echo(); {
		if time.Now().After(deadline) {
			t.Fatal("WireGuard stayed on the old path after it changed")
		}
	}
}
