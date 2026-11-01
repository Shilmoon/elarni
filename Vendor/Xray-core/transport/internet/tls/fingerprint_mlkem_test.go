package tls

import (
	"net"
	"testing"

	utls "github.com/refraction-networking/utls"
)

// sendsMLKEMKeyShare builds the first ClientHello of id and reports whether it
// carries an X25519MLKEM768 key share, which REALITY servers since Xray 26.9.8 require.
func sendsMLKEMKeyShare(t *testing.T, id *utls.ClientHelloID) bool {
	t.Helper()
	c, peer := net.Pipe()
	defer c.Close()
	defer peer.Close()
	u := utls.UClient(c, &utls.Config{ServerName: "example.com"}, *id)
	if err := u.BuildHandshakeState(); err != nil {
		t.Fatalf("%s: %v", id.Str(), err)
	}
	for _, share := range u.HandshakeState.Hello.KeyShares {
		if share.Group == utls.X25519MLKEM768 {
			return true
		}
	}
	return false
}

func TestRandomFingerprintAlwaysSendsMLKEMKeyShare(t *testing.T) {
	for i := 0; i < 200; i++ {
		if id := randomFingerprint(); id == nil || !sendsMLKEMKeyShare(t, id) {
			t.Fatalf("random picked %v, which sends no X25519MLKEM768 key share", id)
		}
	}
}

func TestHasMLKEMKeyShareMatchesTheBuiltHello(t *testing.T) {
	for name, id := range ModernFingerprints {
		if got, want := HasMLKEMKeyShare(id), sendsMLKEMKeyShare(t, id); got != want {
			t.Errorf("%s: HasMLKEMKeyShare = %v, built hello = %v", name, got, want)
		}
	}
}
