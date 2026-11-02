package geo

import (
	"bytes"
	"errors"
	"io"
	"slices"
	"testing"

	"github.com/xtls/xray-core/common/geodata"
	"github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/platform/filesystem"
	"google.golang.org/protobuf/encoding/protowire"
	"google.golang.org/protobuf/proto"
)

func TestEveryExternalSelectorKeepsTheFullFile(t *testing.T) {
	original, err := proto.Marshal(&geodata.GeoSiteList{Entry: []*geodata.GeoSite{
		{Code: "CN", Domain: []*geodata.Domain{{Value: "cn.example", Type: geodata.Domain_Full}}},
		{Code: "GOOGLE", Domain: []*geodata.Domain{{Value: "google.example", Type: geodata.Domain_Full}}}}})
	if err != nil {
		t.Fatal(err)
	}
	// Xray reads ext-site: and ext-domain: like ext:, from the named file.
	for _, external := range []string{"ext:geosite.dat:cn", "ext-site:geosite.dat:cn", "ext-domain:geosite.dat:cn"} {
		full, status, _, err := Reduce("geosite", original, []string{external, "geosite:google"}, nil, true)
		if err != nil || status != "fullFileFallback" || !bytes.Equal(full, original) {
			t.Fatalf("%s: %s %v", external, status, err)
		}
	}
}

// Xray reads a leading ! on an IP rule like one before the code; provider JSON keeps it there.
func TestLeadingNegationKeepsItsCode(t *testing.T) {
	original, err := proto.Marshal(&geodata.GeoIPList{Entry: []*geodata.GeoIP{
		{Code: "RU", Cidr: []*geodata.CIDR{{Ip: []byte{192, 0, 2, 0}, Prefix: 24}}},
		{Code: "US", Cidr: []*geodata.CIDR{{Ip: []byte{198, 51, 100, 0}, Prefix: 24}}},
		{Code: "OTHER", Cidr: []*geodata.CIDR{{Ip: []byte{203, 0, 113, 0}, Prefix: 24}}}}})
	if err != nil {
		t.Fatal(err)
	}
	reduced, status, _, err := Reduce("geoip", original, []string{"!geoip:ru", "geoip:us"}, nil, true)
	var list geodata.GeoIPList
	if err != nil || status != "ready" || proto.Unmarshal(reduced, &list) != nil {
		t.Fatalf("%s %v", status, err)
	}
	if codes := []string{list.Entry[0].Code, list.Entry[len(list.Entry)-1].Code}; len(list.Entry) != 2 || codes[0] != "RU" || codes[1] != "US" {
		t.Fatalf("kept %d records, want RU and US", len(list.Entry))
	}
	full, status, _, err := Reduce("geoip", original, []string{"!ext:geoip.dat:ru", "geoip:us"}, nil, true)
	if err != nil || status != "fullFileFallback" || !bytes.Equal(full, original) {
		t.Fatalf("!ext: %s %v", status, err)
	}
}

func TestReductionPreservesCompleteRecords(t *testing.T) {
	kept := &geodata.GeoSite{Code: "TEST", Domain: []*geodata.Domain{{Value: "example.com", Type: geodata.Domain_Full,
		Attribute: []*geodata.Domain_Attribute{{Key: "ads", TypedValue: &geodata.Domain_Attribute_BoolValue{BoolValue: true}}}}}}
	original, err := proto.Marshal(&geodata.GeoSiteList{Entry: []*geodata.GeoSite{kept, {Code: "OTHER", Domain: []*geodata.Domain{{Value: "other.example", Type: geodata.Domain_Full}}}}})
	if err != nil {
		t.Fatal(err)
	}
	reduced, status, _, err := Reduce("geosite", original, []string{"geosite:test@ads"}, nil, true)
	if err != nil || status != "ready" {
		t.Fatalf("reduce: %s %v", status, err)
	}
	var list geodata.GeoSiteList
	if proto.Unmarshal(reduced, &list) != nil || len(list.Entry) != 1 || !proto.Equal(list.Entry[0], kept) {
		t.Fatal("record or attributes changed")
	}
	full, status, _, err := Reduce("geosite", original, []string{"ext:geosite.dat:test"}, nil, true)
	if err != nil || status != "fullFileFallback" || !bytes.Equal(full, original) {
		t.Fatal("external selector did not retain original")
	}
	if _, _, _, err := Reduce("geosite", original, []string{"geosite:missing"}, nil, true); err == nil {
		t.Fatal("missing referenced record accepted")
	}
	if _, _, _, err := Reduce("geosite", []byte("invalid"), nil, nil, false); err == nil {
		t.Fatal("invalid protobuf accepted")
	}
	ip, _ := proto.Marshal(&geodata.GeoIPList{Entry: []*geodata.GeoIP{{Code: "BAD", Cidr: []*geodata.CIDR{{Ip: []byte{127, 0, 0, 1}, Prefix: 33}}}}})
	if _, _, _, err := Reduce("geoip", ip, nil, nil, false); err == nil {
		t.Fatal("invalid network accepted")
	}
}

func TestOnlyOptionalSelectorsMaySkipMissingCodes(t *testing.T) {
	geoip, _ := proto.Marshal(&geodata.GeoIPList{Entry: []*geodata.GeoIP{{Code: "PRIVATE", Cidr: []*geodata.CIDR{{Ip: []byte{10, 0, 0, 0}, Prefix: 8}}}}})
	geosite, _ := proto.Marshal(&geodata.GeoSiteList{Entry: []*geodata.GeoSite{{Code: "TEST", Domain: []*geodata.Domain{{Value: "example.com", Type: geodata.Domain_Full}}}}})
	previous := filesystem.NewAssetReader
	defer func() { filesystem.NewAssetReader = previous }()
	for _, reduce := range []bool{true, false} {
		ip, _, skipped, err := Reduce("geoip", geoip, []string{"geoip:private"}, []string{"geoip:RU", "geoip:ru", "geoip:private"}, reduce)
		if err != nil || !slices.Equal(skipped, []string{"geoip:ru"}) {
			t.Fatalf("reduce=%v geoip: skipped %v, %v", reduce, skipped, err)
		}
		site, _, skipped, err := Reduce("geosite", geosite, nil, []string{"geosite:missing@cn", "geosite:test"}, reduce)
		if err != nil || !slices.Equal(skipped, []string{"geosite:missing"}) {
			t.Fatalf("reduce=%v geosite: skipped %v, %v", reduce, skipped, err)
		}
		// Xray loads a skipped code as an empty record, which matches nothing.
		files := map[string][]byte{"geoip.dat": ip, "geosite.dat": site}
		filesystem.NewAssetReader = func(name string) (io.ReadCloser, error) {
			return filesystem.MemoryAsset{Reader: bytes.NewReader(files[name])}, nil
		}
		for selector, matches := range map[string]bool{"geoip:ru": false, "geoip:private": true} {
			rules, err := geodata.ParseIPRules([]string{selector})
			if err != nil {
				t.Fatalf("reduce=%v %s: %v", reduce, selector, err)
			}
			matcher, err := geodata.IPReg.BuildIPMatcher(rules)
			if err != nil || matcher.Match(net.ParseAddress("10.0.0.1").IP()) != matches || matcher.Match(net.ParseAddress("8.8.8.8").IP()) {
				t.Fatalf("reduce=%v %s: wrong matches, %v", reduce, selector, err)
			}
		}
		for selector, matches := range map[string]bool{"geosite:missing@cn": false, "geosite:test": true} {
			rules, err := geodata.ParseDomainRules([]string{selector}, geodata.Domain_Substr)
			if err != nil {
				t.Fatalf("reduce=%v %s: %v", reduce, selector, err)
			}
			matcher, err := geodata.DomainReg.BuildDomainMatcher(rules)
			if err != nil || matcher.MatchAny("example.com") != matches || matcher.MatchAny("missing.example") {
				t.Fatalf("reduce=%v %s: wrong matches, %v", reduce, selector, err)
			}
		}
	}
	for _, fixture := range []struct {
		why                 string
		selectors, optional []string
	}{
		{"a Proxy rule needs its code", []string{"geoip:ru"}, nil},
		{"a Proxy rule's need outranks a Direct rule's", []string{"geoip:ru"}, []string{"geoip:ru"}},
		{"an empty record would make a negation match everything", nil, []string{"geoip:!ru"}},
	} {
		for _, reduce := range []bool{true, false} {
			var missing MissingError
			if _, _, _, err := Reduce("geoip", geoip, fixture.selectors, fixture.optional, reduce); !errors.As(err, &missing) ||
				!slices.Equal(missing, MissingError{"geoip:ru"}) || err.Error() != "missing_geodata" {
				t.Fatalf("%s (reduce=%v): %v", fixture.why, reduce, err)
			}
		}
	}
}

// Records are decoded one at a time; the list framing must accept and reject what proto.Unmarshal of the whole list did.
func TestRecordFramingMatchesWholeListDecoding(t *testing.T) {
	record, _ := proto.Marshal(&geodata.GeoSite{Code: "TEST", Domain: []*geodata.Domain{{Value: "example.com", Type: geodata.Domain_Full}}})
	list := protowire.AppendBytes(protowire.AppendTag(nil, 1, protowire.BytesType), record)
	cases := map[string][]byte{
		"plain":                 list,
		"unknown field":         protowire.AppendVarint(protowire.AppendTag(slices.Clone(list), 7, protowire.VarintType), 1),
		"record field as int":   protowire.AppendVarint(protowire.AppendTag(slices.Clone(list), 1, protowire.VarintType), 1),
		"truncated record":      list[:len(list)-1],
		"truncated tag":         append(slices.Clone(list), 0x80),
		"invalid wire type":     append(slices.Clone(list), 0x0f),
		"invalid record":        protowire.AppendBytes(protowire.AppendTag(slices.Clone(list), 1, protowire.BytesType), []byte{0x0a, 0x05}),
		"group end without one": protowire.AppendTag(slices.Clone(list), 3, protowire.EndGroupType),
	}
	for name, data := range cases {
		var whole geodata.GeoSiteList
		want := proto.Unmarshal(data, &whole) == nil
		_, _, _, err := Reduce("geosite", data, nil, nil, false)
		if got := err == nil; got != want {
			t.Errorf("%s: accepted %v, whole-list decoding accepted %v", name, got, want)
		}
	}
}
