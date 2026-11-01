package wireguard

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"io"
	"net"
	"net/netip"
	"slices"
	"strings"
	"testing"
	"time"

	awg "github.com/amnezia-vpn/amneziawg-go/v3/device"
	"github.com/miekg/dns"
	"github.com/xtls/xray-core/transport/internet"
	"golang.zx2c4.com/wireguard/device"
	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
)

// Uses fresh keys, loopback wire sockets and isolated gVisor stacks. No OS VPN,
// production peer, persistent identity or root privileges are involved.
func TestWireGuardEnginesCarryTCPAndUDP(t *testing.T) {
	for _, amnezia := range []bool{false, true} {
		t.Run(fmt.Sprintf("amnezia=%t", amnezia), func(t *testing.T) {
			clientKey, err := ecdh.X25519().GenerateKey(rand.Reader)
			if err != nil {
				t.Fatal(err)
			}
			serverKey, err := ecdh.X25519().GenerateKey(rand.Reader)
			if err != nil {
				t.Fatal(err)
			}
			clientTun, clientNet, _, err := CreateNetTUN([]netip.Addr{netip.MustParseAddr("10.29.0.2"), netip.MustParseAddr("fd29::2")}, []netip.Addr{netip.MustParseAddr("10.29.0.1")}, 1280, true)
			if err != nil {
				t.Fatal(err)
			}
			serverTun, _, serverStack, err := CreateNetTUN([]netip.Addr{netip.MustParseAddr("10.29.0.1"), netip.MustParseAddr("fd29::1")}, nil, 1280, true)
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
			var client, server tunnelDevice
			obf := ""
			if amnezia {
				logger := &awg.Logger{Verbosef: func(string, ...any) {}, Errorf: t.Logf}
				server = awg.NewDevice(adaptAmneziaTUN(serverTun), &amneziaBind{serverBind}, logger)
				// Full-width headers catch the reserved-byte corruption regression.
				obf = "jc=4\njmin=40\njmax=80\ns1=16\ns2=17\ns3=18\ns4=19\nh1=100000-100100\nh2=200000-200100\nh3=300000-300100\nh4=400000-400100\nheader_protection_key=" + hex.EncodeToString(bytes.Repeat([]byte{0x5a}, 32)) + "\ncontent_padding_addition=4-8\nrandom_trailers=true\ndisable_cookies=true\n"
			} else {
				logger := &device.Logger{Verbosef: func(string, ...any) {}, Errorf: t.Logf}
				server = device.NewDevice(serverTun, serverBind, logger)
			}
			defer serverSocket.Close()
			defer server.Close()
			if err := server.IpcSet("private_key=" + hex.EncodeToString(serverKey.Bytes()) + "\n" + obf + "public_key=" + hex.EncodeToString(clientKey.PublicKey().Bytes()) + "\nallowed_ip=10.29.0.2/32\nallowed_ip=fd29::2/128\n"); err != nil {
				t.Fatal(err)
			}
			settings := map[string]string{}
			for _, line := range strings.Split(obf, "\n") {
				if key, value, ok := strings.Cut(line, "="); ok {
					settings[key] = value
				}
			}
			handler := &Handler{conf: &DeviceConfig{SecretKey: hex.EncodeToString(clientKey.Bytes()), Amnezia: amnezia, AmneziaSettings: settings,
				Peers: []*PeerConfig{{PublicKey: hex.EncodeToString(serverKey.PublicKey().Bytes()), Endpoint: serverSocket.LocalAddr().String(), AllowedIps: []string{"0.0.0.0/0", "::/0"}}}},
				tun: clientTun, tnet: clientNet, streamSettings: &internet.MemoryStreamConfig{}}
			defer handler.Close()
			if err := handler.init(context.Background()); err != nil {
				t.Fatal(err)
			}
			client = handler.dev
			if err := server.Up(); err != nil {
				t.Fatal(err)
			}
			if err := client.Up(); err != nil {
				t.Fatal(err)
			}
			dnsAddress, dnsFamily := convertToFullAddr(netip.MustParseAddrPort("10.29.0.1:53"))
			dnsSocket, err := gonet.DialUDP(serverStack, &dnsAddress, nil, dnsFamily)
			if err != nil {
				t.Fatal(err)
			}
			defer dnsSocket.Close()
			dnsDone := make(chan struct{})
			go func() {
				defer close(dnsDone)
				buffer := make([]byte, 2048)
				for {
					n, from, err := dnsSocket.ReadFrom(buffer)
					if err != nil {
						return
					}
					var request dns.Msg
					if request.Unpack(buffer[:n]) != nil {
						continue
					}
					response := new(dns.Msg)
					response.SetReply(&request)
					for _, q := range request.Question {
						if q.Qtype == dns.TypeA {
							response.Answer = append(response.Answer, &dns.A{Hdr: dns.RR_Header{Name: q.Name, Rrtype: dns.TypeA, Class: dns.ClassINET, Ttl: 60}, A: net.ParseIP("192.0.2.29")})
						}
						if q.Qtype == dns.TypeAAAA {
							response.Answer = append(response.Answer, &dns.AAAA{Hdr: dns.RR_Header{Name: q.Name, Rrtype: dns.TypeAAAA, Class: dns.ClassINET, Ttl: 60}, AAAA: net.ParseIP("2001:db8::29")})
						}
					}
					packet, err := response.Pack()
					if err == nil {
						dnsSocket.WriteTo(packet, from)
					}
				}
			}()
			defer func() { dnsSocket.Close(); <-dnsDone }()
			for cycle := 0; cycle < 2; cycle++ {
				if cycle > 0 {
					if err := client.Down(); err != nil {
						t.Fatal(err)
					}
					if err := handler.init(context.Background()); err != nil {
						t.Fatal(err)
					}
				}
				ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
				addresses, err := clientNet.LookupContextHost(ctx, fmt.Sprintf("fixture-%d.test", cycle))
				cancel()
				if err != nil || !slices.Contains(addresses, "192.0.2.29") || !slices.Contains(addresses, "2001:db8::29") {
					t.Fatalf("configured tunnel DNS failed: %v %v", addresses, err)
				}
				for _, address := range []string{fmt.Sprintf("10.29.0.1:%d", 18181+cycle), fmt.Sprintf("[fd29::1]:%d", 18181+cycle)} {
					remote := netip.MustParseAddrPort(address)
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
					udpServer, err := gonet.DialUDP(serverStack, &full, nil, family)
					if err != nil {
						t.Fatal(err)
					}
					defer udpServer.Close()
					go func() {
						udpServer.SetDeadline(time.Now().Add(10 * time.Second))
						bytes := make([]byte, 2048)
						n, from, err := udpServer.ReadFrom(bytes)
						if err == nil {
							udpServer.WriteTo(bytes[:n], from)
						}
					}()
					udpClient, err := clientNet.DialUDPAddrPort(netip.AddrPort{}, remote)
					if err != nil {
						t.Fatal(err)
					}
					checkEcho(t, udpClient)
				}
			}
			if err := handler.Close(); err != nil {
				t.Fatal(err)
			}
			if err := handler.init(context.Background()); err == nil {
				t.Fatal("closed WireGuard handler restarted")
			}
		})
	}
}

func checkEcho(t *testing.T, connection net.Conn) {
	t.Helper()
	defer connection.Close()
	connection.SetDeadline(time.Now().Add(10 * time.Second))
	payload := []byte("elarni encrypted peer fixture")
	if _, err := connection.Write(payload); err != nil {
		t.Fatal(err)
	}
	reply := make([]byte, len(payload))
	if _, err := io.ReadFull(connection, reply); err != nil {
		t.Fatal(err)
	}
	if string(reply) != string(payload) {
		t.Fatal("tunneled payload changed")
	}
}
