package main

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"testing"

	"github.com/xtls/libxray/xray"
	"github.com/xtls/xray-core/common/geodata"
	"github.com/xtls/xray-core/common/platform/filesystem"
	"google.golang.org/protobuf/proto"
)

func TestAssetPublicationKeepsLastGoodRevision(t *testing.T) {
	root := t.TempDir()
	original, _ := proto.Marshal(&geodata.GeoSiteList{Entry: []*geodata.GeoSite{{Code: "TEST", Domain: []*geodata.Domain{{Value: "example.com", Type: geodata.Domain_Full}}}}})
	request := assetRequest{Files: map[string]string{"geosite": "https://example.invalid/geosite.dat"}, Selectors: []string{"geosite:test"}, Reduce: true}
	value, err := prepareAssets(root, request, bodies(func(string) ([]byte, error) { return original, nil }))
	if err != nil {
		t.Fatal(err)
	}
	revision := value.(map[string]any)["assetRevision"].(string)
	path := filepath.Join(root, revision, "geosite.dat")
	good, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	request.Previous = revision
	request.Refresh = true
	if _, err := prepareAssets(root, request, bodies(func(string) ([]byte, error) { return nil, errors.New("fetch_failed") })); err == nil {
		t.Fatal("failed download published")
	}
	if _, err := prepareAssets(root, request, bodies(func(string) ([]byte, error) { return []byte("invalid"), nil })); err == nil {
		t.Fatal("invalid data published")
	}
	after, err := os.ReadFile(path)
	if err != nil || !bytes.Equal(after, good) {
		t.Fatal("previous revision changed")
	}
	entries, _ := os.ReadDir(root)
	if len(entries) != 1 {
		t.Fatal("failed staging was not removed")
	}
	assets, err := readAssets(root, revision)
	if err != nil {
		t.Fatal(err)
	}
	previous := filesystem.NewAssetReader
	defer func() { filesystem.NewAssetReader = previous }()
	if installAssets(assets) != nil {
		t.Fatal("logical assets rejected")
	}
	loaded, err := filesystem.ReadAsset("geosite.dat")
	if err != nil || !bytes.Equal(loaded, good) {
		t.Fatal("memory asset did not load")
	}
	if _, _, err := filesystem.OpenAsset("../private.dat"); err == nil {
		t.Fatal("arbitrary asset read allowed")
	}
	changed, _ := proto.Marshal(&geodata.GeoSiteList{Entry: []*geodata.GeoSite{{Code: "TEST", Domain: []*geodata.Domain{{Value: "changed.example", Type: geodata.Domain_Full}}}}})
	newValue, err := prepareAssets(root, request, bodies(func(string) ([]byte, error) { return changed, nil }))
	if err != nil {
		t.Fatal(err)
	}
	newRevision := newValue.(map[string]any)["assetRevision"].(string)
	unrelated := filepath.Join(root, "unrelated")
	if err := os.Mkdir(unrelated, 0700); err != nil {
		t.Fatal(err)
	}
	if retireAssets(root, []string{revision, newRevision}) != nil {
		t.Fatal("pending and committed revisions must both survive")
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatal("rollback revision retired before commit")
	}
	if retireAssets(root, []string{newRevision}) != nil {
		t.Fatal("retirement failed")
	}
	if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("unreferenced revision retained")
	}
	// A cleared cache must not start the route without its geofiles.
	if _, err := readAssets(root, revision); err == nil || err.Error() != "assets_missing" {
		t.Fatalf("lost revision read with %v, want assets_missing", err)
	}
	// The app then prepares the route again from its links.
	request.Refresh = false
	again, err := prepareAssets(root, request, bodies(func(string) ([]byte, error) { return changed, nil }))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := readAssets(root, again.(map[string]any)["assetRevision"].(string)); err != nil {
		t.Fatal("re-prepared revision unreadable", err)
	}
	for _, retained := range []string{unrelated, filepath.Join(root, newRevision, "geosite.dat")} {
		if _, err := os.Stat(retained); err != nil {
			t.Fatal("retirement removed retained data")
		}
	}
}

// A reused helper installs each tunnel's route files under the same names.
func TestReinstalledAssetsReplaceTheCachedGeodata(t *testing.T) {
	previous := filesystem.NewAssetReader
	defer func() { filesystem.NewAssetReader = previous }()
	for _, ip := range [][]byte{{192, 0, 2, 0}, {198, 51, 100, 0}} {
		data, _ := proto.Marshal(&geodata.GeoIPList{Entry: []*geodata.GeoIP{{Code: "TEST", Cidr: []*geodata.CIDR{{Ip: ip, Prefix: 24}}}}})
		if err := installAssets(map[string][]byte{"geoip.dat": data}); err != nil {
			t.Fatal(err)
		}
		rules, _ := geodata.ParseIPRules([]string{"geoip:test"})
		matcher, err := geodata.IPReg.BuildIPMatcher(rules)
		if err != nil {
			t.Fatal(err)
		}
		if !matcher.Match(append(slices.Clone(ip[:3]), 1)) {
			t.Fatalf("route files for %v matched the previous route's geoip", ip)
		}
	}
}

func TestPreparedAssetsSkipCodesOnlyDirectBlockAndDomesticDNSUse(t *testing.T) {
	root := t.TempDir()
	geoip, _ := proto.Marshal(&geodata.GeoIPList{Entry: []*geodata.GeoIP{{Code: "PRIVATE", Cidr: []*geodata.CIDR{{Ip: []byte{10, 0, 0, 0}, Prefix: 8}}}}})
	geosite, _ := proto.Marshal(&geodata.GeoSiteList{Entry: []*geodata.GeoSite{{Code: "TEST", Domain: []*geodata.Domain{{Value: "example.com", Type: geodata.Domain_Full}}}}})
	downloads := map[string][]byte{"https://example.invalid/geoip.dat": geoip, "https://example.invalid/geosite.dat": geosite}
	fetch := func(url string) ([]byte, error) { return downloads[url], nil }
	// As in a provider profile whose Direct rule names geoip:ru although its geoip.dat lacks RU.
	request := assetRequest{Files: map[string]string{"geoip": "https://example.invalid/geoip.dat", "geosite": "https://example.invalid/geosite.dat"},
		Selectors: []string{"geosite:test"}, Optional: []string{"geoip:ru", "geoip:private", "geosite:missing"}}
	config := `{"log":{"loglevel":"none"},
		"dns":{"servers":[{"address":"192.0.2.53","domains":["geosite:missing"],"skipFallback":true},"192.0.2.54"]},
		"outbounds":[{"tag":"proxy","protocol":"freedom"},{"tag":"direct","protocol":"freedom"},{"tag":"block","protocol":"blackhole"}],
		"routing":{"rules":[{"ip":["geoip:ru","geoip:private"],"outboundTag":"direct"},
			{"domain":["geosite:missing"],"outboundTag":"block"},{"domain":["geosite:test"],"outboundTag":"proxy"}]}}`
	previous := filesystem.NewAssetReader
	defer func() { filesystem.NewAssetReader = previous }()
	for _, reduce := range []bool{true, false} {
		request.Reduce = reduce
		value, err := prepareAssets(root, request, bodies(fetch))
		if err != nil {
			t.Fatalf("reduce=%v: %v", reduce, err)
		}
		result := value.(map[string]any)
		if skipped, _ := result["skippedGeodata"].([]string); !slices.Equal(skipped, []string{"geoip:ru", "geosite:missing"}) {
			t.Fatalf("reduce=%v: skipped %v", reduce, result["skippedGeodata"])
		}
		assets, err := readAssets(root, result["assetRevision"].(string))
		if err != nil || installAssets(assets) != nil {
			t.Fatalf("reduce=%v: prepared assets rejected: %v", reduce, err)
		}
		instance, err := xray.StartXrayFromJSON(config)
		if err != nil {
			t.Fatalf("reduce=%v: core rejected skipped codes: %v", reduce, err)
		}
		if err := instance.Close(); err != nil {
			t.Fatal(err)
		}
	}
	// A Proxy rule still needs its code, and the reply names every missing one.
	request.Selectors = []string{"geosite:test", "geosite:proxied", "geoip:ru"}
	value, err := prepareAssets(root, request, bodies(fetch))
	if reply := nativeResponse(value, err); reply != `{"data":{"missing":["geoip:ru","geosite:proxied"]},"error":"missing_geodata","success":false}` {
		t.Fatalf("missing Proxy code reply: %s", reply)
	}
}

func TestIdenticalAssetRefreshRetainsRevision(t *testing.T) {
	root := t.TempDir()
	original, _ := proto.Marshal(&geodata.GeoSiteList{Entry: []*geodata.GeoSite{
		{Code: "TEST", Domain: []*geodata.Domain{{Value: "example.com", Type: geodata.Domain_Full}}},
		{Code: "OTHER", Domain: []*geodata.Domain{{Value: "other.example", Type: geodata.Domain_Full}}},
	}})
	request := assetRequest{Files: map[string]string{"geosite": "https://example.invalid/geosite.dat"}, Selectors: []string{"geosite:test"}, Reduce: true}
	fetches := 0
	fetch := func(string) ([]byte, error) { fetches++; return original, nil }
	first, err := prepareAssets(root, request, bodies(fetch))
	if err != nil {
		t.Fatal(err)
	}
	revision := first.(map[string]any)["assetRevision"].(string)
	request.Previous = revision
	for _, refresh := range []bool{false, true} {
		request.Refresh = refresh
		value, err := prepareAssets(root, request, bodies(fetch))
		if err != nil {
			t.Fatal(err)
		}
		if value.(map[string]any)["assetRevision"] != revision {
			t.Fatal("identical assets acquired a different runtime revision")
		}
	}
	if fetches != 2 {
		t.Fatalf("got %d downloads, want initial and forced refresh only", fetches)
	}
	entries, err := os.ReadDir(root)
	if err != nil || len(entries) != 1 {
		t.Fatal("redundant staging revision retained", err)
	}
	request.Refresh = false
	request.Selectors = []string{"geosite:other"}
	changed, err := prepareAssets(root, request, bodies(fetch))
	if err != nil {
		t.Fatal(err)
	}
	if changed.(map[string]any)["assetRevision"] == revision || fetches != 2 {
		t.Fatal("changed selectors must prepare a new revision using the retained original")
	}
}

// A refresh sends the stored original's validators and keeps that original when the server reports it unchanged.
func TestAssetRefreshDownloadsOnlyChangedGeofiles(t *testing.T) {
	root := t.TempDir()
	site := func(domain string) []byte {
		data, _ := proto.Marshal(&geodata.GeoSiteList{Entry: []*geodata.GeoSite{{Code: "TEST", Domain: []*geodata.Domain{{Value: domain, Type: geodata.Domain_Full}}}}})
		return data
	}
	var sent []assetValidators
	reply := func(body []byte, validators assetValidators) assetFetch {
		return func(_ string, stored assetValidators) ([]byte, assetValidators, error) {
			sent = append(sent, stored)
			return body, validators, nil
		}
	}
	request := assetRequest{Files: map[string]string{"geosite": "https://example.invalid/geosite.dat"}, Selectors: []string{"geosite:test"}, Reduce: true}
	prepare := func(fetch assetFetch) string {
		t.Helper()
		value, err := prepareAssets(root, request, fetch)
		if err != nil {
			t.Fatal(err)
		}
		request.Previous, request.Refresh = value.(map[string]any)["assetRevision"].(string), true
		return request.Previous
	}
	tagged := assetValidators{ETag: `"v1"`, LastModified: "Wed, 28 Oct 2026 10:00:00 GMT"}
	first := prepare(reply(site("example.com"), tagged))
	if prepare(reply(nil, assetValidators{})) != first {
		t.Fatal("an unchanged geofile prepared a new revision")
	}
	// The same bytes under a new tag keep the revision and send the new tag next time.
	if prepare(reply(site("example.com"), assetValidators{ETag: `"v2"`})) != first {
		t.Fatal("identical bytes prepared a new revision")
	}
	changed := prepare(reply(site("changed.example"), assetValidators{ETag: `"v3"`}))
	if changed == first {
		t.Fatal("a changed geofile kept the old revision")
	}
	if prepare(reply(nil, assetValidators{})) != changed {
		t.Fatal("an unchanged geofile prepared a new revision")
	}
	// Another link's server must not judge this copy.
	request.Files["geosite"] = "https://other.invalid/geosite.dat"
	prepare(reply(site("other.example"), assetValidators{}))
	want := []assetValidators{{}, tagged, tagged, {ETag: `"v2"`}, {ETag: `"v3"`}, {}}
	if !slices.Equal(sent, want) {
		t.Fatalf("sent validators %v, want %v", sent, want)
	}
	if entries, _ := os.ReadDir(root); len(entries) != 3 {
		t.Fatalf("got %d revisions, want the first, the changed and the other link's", len(entries))
	}
}

// bodies adapts a fetch that ignores validators, as a server without them would.
func bodies(fetch func(string) ([]byte, error)) assetFetch {
	return func(url string, _ assetValidators) ([]byte, assetValidators, error) {
		body, err := fetch(url)
		return body, assetValidators{}, err
	}
}
