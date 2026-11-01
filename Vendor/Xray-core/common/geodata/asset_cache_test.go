package geodata

import (
	"bytes"
	"io"
	"testing"

	"github.com/xtls/xray-core/common/platform/filesystem"
	"google.golang.org/protobuf/proto"
)

// Android serves each route's reduced geoip.dat under the same name, so a core
// for another route must not reuse matchers parsed from the previous content.
func TestGeoIPCacheFollowsSwappedAssetContent(t *testing.T) {
	file := func(ip []byte) []byte {
		data, err := proto.Marshal(&GeoIPList{Entry: []*GeoIP{{Code: "TEST", Cidr: []*CIDR{{Ip: ip, Prefix: 24}}}}})
		if err != nil {
			t.Fatal(err)
		}
		return data
	}
	served := file([]byte{192, 0, 2, 0})
	previous := filesystem.NewAssetReader
	filesystem.NewAssetReader = func(string) (io.ReadCloser, error) {
		return filesystem.MemoryAsset{Reader: bytes.NewReader(served)}, nil
	}
	t.Cleanup(func() { filesystem.NewAssetReader = previous })
	factory := newIPSetFactory()
	rules := []*GeoIPRule{{File: "geoip.dat", Code: "TEST"}}
	first, err := factory.GetOrCreateFromGeoIPRules(rules)
	if err != nil {
		t.Fatal(err)
	}
	if again, _ := factory.GetOrCreateFromGeoIPRules(rules); again != first {
		t.Fatal("unchanged content was parsed again")
	}
	served = file([]byte{198, 51, 100, 0})
	filesystem.AssetGeneration.Add(1)
	if swapped, err := factory.GetOrCreateFromGeoIPRules(rules); err != nil || swapped == first {
		t.Fatal("matchers parsed from the previous route's file were reused", err)
	}
}
