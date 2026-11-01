package reality

import (
	"net"
	"testing"

	utls "github.com/refraction-networking/utls"
)

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

// REALITY servers since Xray 26.9.8 hand any hello without an X25519MLKEM768
// key share to the cover target (XTLS/Xray-core#7259).
func TestRealityFingerprintsSendMLKEMKeyShare(t *testing.T) {
	families := map[string]string{
		"": "Chrome", "chrome": "Chrome", "firefox": "Firefox", "safari": "Safari",
		"ios": "Safari", "android": "Chrome", "edge": "Chrome", "360": "Chrome", "qq": "Chrome",
		"helloedge_106": "Chrome", "helloios_14": "Safari", "hellochrome_83": "Chrome",
		"hellofirefox_99": "Firefox", "hellosafari_16_0": "Safari",
	}
	for name, family := range families {
		id := realityFingerprint(name)
		if id == nil {
			t.Errorf("%q: no fingerprint", name)
			continue
		}
		if !sendsMLKEMKeyShare(t, id) {
			t.Errorf("%q -> %s sends no X25519MLKEM768 key share", name, id.Str())
		}
		if id.Client != family {
			t.Errorf("%q -> %s, want the %s family", name, id.Str(), family)
		}
	}
	if id := realityFingerprint("random"); id == nil || !sendsMLKEMKeyShare(t, id) {
		t.Errorf("random -> %v sends no X25519MLKEM768 key share", id)
	}
	if realityFingerprint("no-such-fingerprint") != nil {
		t.Error("an unknown fingerprint name must stay unknown")
	}
}
