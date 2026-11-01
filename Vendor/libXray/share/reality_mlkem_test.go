package share

import (
	"crypto/ecdh"
	"crypto/rand"
	"encoding/binary"
	"encoding/json"
	"io"
	"maps"
	"net"
	"strconv"
	"testing"

	"golang.org/x/crypto/cryptobyte"
)

// helloHasMLKEMKeyShare reports whether a ClientHello handshake message
// carries an X25519MLKEM768 (0x11ec) key share.
func helloHasMLKEMKeyShare(message []byte) bool {
	s := cryptobyte.String(message)
	var kind uint8
	var body, skipped, extensions cryptobyte.String
	if !s.ReadUint8(&kind) || kind != 1 || !s.ReadUint24LengthPrefixed(&body) || !body.Skip(34) ||
		!body.ReadUint8LengthPrefixed(&skipped) || !body.ReadUint16LengthPrefixed(&skipped) ||
		!body.ReadUint8LengthPrefixed(&skipped) || !body.ReadUint16LengthPrefixed(&extensions) {
		return false
	}
	for !extensions.Empty() {
		var extension uint16
		var data, shares cryptobyte.String
		if !extensions.ReadUint16(&extension) || !extensions.ReadUint16LengthPrefixed(&data) {
			return false
		}
		if extension != 51 || !data.ReadUint16LengthPrefixed(&shares) {
			continue
		}
		for !shares.Empty() {
			var group uint16
			var key cryptobyte.String
			if !shares.ReadUint16(&group) || !shares.ReadUint16LengthPrefixed(&key) {
				return false
			}
			if group == 0x11ec {
				return true
			}
		}
	}
	return false
}

// mlkemOnlyGate forwards a connection to upstream only when its first TLS
// record is a ClientHello with an X25519MLKEM768 key share, the rule REALITY
// servers apply since Xray 26.9.8 (XTLS/Xray-core#7259). It closes the rest.
func mlkemOnlyGate(t *testing.T, upstream string) int {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				header := make([]byte, 5)
				if _, err := io.ReadFull(conn, header); err != nil || header[0] != 22 {
					return
				}
				record := make([]byte, binary.BigEndian.Uint16(header[3:]))
				if _, err := io.ReadFull(conn, record); err != nil || !helloHasMLKEMKeyShare(record) {
					return
				}
				server, err := net.Dial("tcp", upstream)
				if err != nil {
					return
				}
				defer server.Close()
				if _, err := server.Write(append(header, record...)); err != nil {
					return
				}
				go io.Copy(server, conn)
				io.Copy(conn, server)
			}()
		}
	}()
	return listener.Addr().(*net.TCPAddr).Port
}

func TestRealityPresetsReachAnMLKEMOnlyServer(t *testing.T) {
	type object = map[string]any
	const id = "00000000-0000-4000-8000-000000000001"
	private, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	serverStream, clientStream := realityTrafficStreams(t, private)
	port := trafficPort(t)
	startTrafficCore(t, object{"log": object{"loglevel": "none"},
		"inbounds":  []any{object{"listen": "127.0.0.1", "port": port, "protocol": "vless", "settings": object{"clients": []any{object{"id": id, "flow": "xtls-rprx-vision"}}, "decryption": "none"}, "streamSettings": serverStream}},
		"outbounds": []any{object{"protocol": "freedom", "settings": object{"finalRules": []any{object{"action": "allow", "ip": []string{"127.0.0.1/32"}}}}}}})
	gate := mlkemOnlyGate(t, net.JoinHostPort("127.0.0.1", strconv.Itoa(port)))
	for _, fingerprint := range []string{"chrome", "firefox", "safari", "ios", "android", "edge", "360", "qq", "random"} {
		t.Run(fingerprint, func(t *testing.T) {
			reality := maps.Clone(clientStream["realitySettings"].(object))
			reality["fingerprint"] = fingerprint
			raw, _ := json.Marshal(object{"outbounds": []any{object{"protocol": "vless",
				"settings":       object{"id": id, "encryption": "none", "flow": "xtls-rprx-vision", "address": "127.0.0.1", "port": gate},
				"streamSettings": object{"security": "reality", "realitySettings": reality}}}})
			imported, err := ImportClientProfiles(string(raw))
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
		})
	}
}
