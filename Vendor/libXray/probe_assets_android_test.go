//go:build android

package libXray

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/xtls/xray-core/common/geodata"
	"github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/platform/filesystem"
	"google.golang.org/protobuf/proto"
)

// A probe of a server on another route serves that route's files, then restores the
// active ones; matchers built after the restore must not reuse the probe's geodata. The
// loaded revision directory is served as is, without reading and checking it again.
func TestAndroidProbeRestoreRefreshesGeodata(t *testing.T) {
	route := func(prefix byte) string {
		directory := t.TempDir()
		data, err := proto.Marshal(&geodata.GeoIPList{Entry: []*geodata.GeoIP{{Code: "TEST", Cidr: []*geodata.CIDR{{Ip: []byte{prefix, 0, 2, 0}, Prefix: 24}}}}})
		if err == nil {
			err = os.WriteFile(filepath.Join(directory, "geoip.dat"), data, 0o644)
		}
		if err != nil {
			t.Fatal(err)
		}
		return directory
	}
	probe := func(directory string) geodata.IPMatcher {
		restore, err := prepareProbeAssets(&directory)
		if err != nil {
			t.Fatal(err)
		}
		defer restore()
		rules, err := geodata.ParseIPRules([]string{"geoip:test"})
		if err != nil {
			t.Fatal(err)
		}
		matcher, err := geodata.IPReg.BuildIPMatcher(rules)
		if err != nil {
			t.Fatal(err)
		}
		return matcher
	}
	active, other := route(192), route(198)
	if err := UseAndroidAssets(active); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = UseAndroidAssets("") })
	for range 2 {
		if !probe(other).Match(net.ParseAddress("198.0.2.1").IP()) {
			t.Fatal("the other route's probe did not use its geodata")
		}
	}
	matcher := probe(active)
	if !matcher.Match(net.ParseAddress("192.0.2.1").IP()) || matcher.Match(net.ParseAddress("198.0.2.1").IP()) {
		t.Fatal("the active route's probe reused the other route's geodata")
	}
	generation := filesystem.AssetGeneration.Load()
	if err := os.WriteFile(filepath.Join(active, "geoip.dat"), []byte("not geodata"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := UseAndroidAssets(active); err != nil || filesystem.AssetGeneration.Load() != generation {
		t.Fatalf("the loaded directory was read again: %v", err)
	}
}
