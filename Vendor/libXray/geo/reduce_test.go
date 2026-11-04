package geo

import (
	"bytes"
	"errors"
	"io"
	"math"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
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

// field appends one length-delimited field.
func field(b []byte, number protowire.Number, value []byte) []byte {
	return protowire.AppendBytes(protowire.AppendTag(b, number, protowire.BytesType), value)
}

func varintField(b []byte, number protowire.Number, value uint64) []byte {
	return protowire.AppendVarint(protowire.AppendTag(b, number, protowire.VarintType), value)
}

// acceptedBefore is the validation Reduce did by decoding with proto.Unmarshal: the streaming
// validator must accept and reject the same files.
func acceptedBefore(name string, data []byte) bool {
	seen := map[string]bool{}
	unique := func(code string) bool {
		code = strings.ToLower(code)
		ok := code != "" && !seen[code]
		seen[code] = true
		return ok
	}
	if name == "geoip" {
		var list geodata.GeoIPList
		if proto.Unmarshal(data, &list) != nil || len(list.Entry) == 0 {
			return false
		}
		for _, entry := range list.Entry {
			if !unique(entry.Code) {
				return false
			}
			for _, cidr := range entry.Cidr {
				if (len(cidr.Ip) != 4 && len(cidr.Ip) != 16) || cidr.Prefix > uint32(len(cidr.Ip)*8) {
					return false
				}
			}
		}
		return true
	}
	var list geodata.GeoSiteList
	if proto.Unmarshal(data, &list) != nil || len(list.Entry) == 0 {
		return false
	}
	for _, entry := range list.Entry {
		if !unique(entry.Code) {
			return false
		}
		for _, domain := range entry.Domain {
			if domain.Value == "" || domain.Type < 0 || domain.Type > 3 {
				return false
			}
		}
	}
	return true
}

func TestStreamingValidationMatchesWholeDecoding(t *testing.T) {
	code := func(c string) []byte { return field(nil, 1, []byte(c)) }
	domain := func(fields ...[]byte) []byte { return field(nil, 2, slices.Concat(fields...)) }
	value := func(v string) []byte { return field(nil, 2, []byte(v)) }
	kind := func(v uint64) []byte { return varintField(nil, 1, v) }
	cidr := func(fields ...[]byte) []byte { return field(nil, 2, slices.Concat(fields...)) }
	ip := func(b ...byte) []byte { return field(nil, 1, b) }
	prefix := func(v uint64) []byte { return varintField(nil, 2, v) }
	list := func(records ...[]byte) []byte {
		var b []byte
		for _, record := range records {
			b = field(b, 1, record)
		}
		return b
	}
	group := protowire.AppendTag(varintField(protowire.AppendTag(nil, 9, protowire.StartGroupType), 1, 5), 9, protowire.EndGroupType)
	sites := map[string][]byte{
		"plain":                      list(slices.Concat(code("TEST"), domain(kind(3), value("example.com")))),
		"no domains":                 list(code("TEST")),
		"empty value":                list(slices.Concat(code("TEST"), domain(kind(3)))),
		"type out of range":          list(slices.Concat(code("TEST"), domain(kind(4), value("example.com")))),
		"negative type":              list(slices.Concat(code("TEST"), domain(kind(math.MaxUint64), value("example.com")))),
		"type truncated to int32":    list(slices.Concat(code("TEST"), domain(kind(1<<32+2), value("example.com")))),
		"value not UTF-8":            list(slices.Concat(code("TEST"), domain(value("\xff")))),
		"code not UTF-8":             list(code("\xff")),
		"empty code":                 list(slices.Concat(code(""), domain(value("example.com")))),
		"no code":                    list(domain(value("example.com"))),
		"duplicate code":             list(code("TEST"), code("test")),
		"last code wins":             list(slices.Concat(code("A"), code("B")), code("A")),
		"last value wins":            list(slices.Concat(code("TEST"), domain(value("example.com"), field(nil, 2, nil)))),
		"attribute":                  list(slices.Concat(code("TEST"), domain(value("example.com"), field(nil, 3, slices.Concat(field(nil, 1, []byte("ads")), varintField(nil, 2, 1)))))),
		"attribute key not UTF-8":    list(slices.Concat(code("TEST"), domain(value("example.com"), field(nil, 3, field(nil, 1, []byte("\xff")))))),
		"attribute truncated":        list(slices.Concat(code("TEST"), domain(value("example.com"), field(nil, 3, []byte{0x0a, 0x05})))),
		"domain as varint":           list(slices.Concat(code("TEST"), varintField(nil, 2, 7))),
		"code as varint":             list(slices.Concat(varintField(nil, 1, 7), domain(value("example.com")))),
		"value as varint":            list(slices.Concat(code("TEST"), domain(varintField(nil, 2, 7)))),
		"unknown fields and a group": list(slices.Concat(code("TEST"), group, protowire.AppendFixed32(protowire.AppendTag(nil, 8, protowire.Fixed32Type), 1), domain(value("example.com"), group))),
		"unterminated group":         list(slices.Concat(code("TEST"), protowire.AppendTag(nil, 9, protowire.StartGroupType))),
		"truncated domain":           list(slices.Concat(code("TEST"), []byte{0x12, 0x05, 0x12})),
		"field number zero":          list(slices.Concat(code("TEST"), []byte{0x02, 0x00})),
		"empty list":                 nil,
	}
	ips := map[string][]byte{
		"plain":                    list(slices.Concat(code("RU"), cidr(ip(192, 0, 2, 0), prefix(24)), cidr(ip(make([]byte, 16)...), prefix(128)))),
		"no networks":              list(code("RU")),
		"address length 5":         list(slices.Concat(code("RU"), cidr(ip(1, 2, 3, 4, 5), prefix(8)))),
		"no address":               list(slices.Concat(code("RU"), cidr(prefix(8)))),
		"prefix too long":          list(slices.Concat(code("RU"), cidr(ip(192, 0, 2, 0), prefix(33)))),
		"prefix truncated":         list(slices.Concat(code("RU"), cidr(ip(192, 0, 2, 0), prefix(1<<32+24)))),
		"last address wins":        list(slices.Concat(code("RU"), cidr(ip(1, 2, 3, 4, 5), ip(192, 0, 2, 0), prefix(24)))),
		"network as varint":        list(slices.Concat(code("RU"), varintField(nil, 2, 1))),
		"reverse match":            list(slices.Concat(code("RU"), cidr(ip(192, 0, 2, 0)), varintField(nil, 3, 1))),
		"duplicate code":           list(code("RU"), code("ru")),
		"empty code":               list(cidr(ip(192, 0, 2, 0))),
		"code not UTF-8":           list(code("\xfe")),
		"truncated network":        list(slices.Concat(code("RU"), []byte{0x12, 0x04, 0x0a, 0x04})),
		"unknown list field":       varintField(list(code("RU")), 7, 1),
		"list record as varint":    varintField(list(code("RU")), 1, 1),
		"truncated list framing":   append(list(code("RU")), 0x0a),
		"invalid list wire type":   append(list(code("RU")), 0x0f),
		"group at list level":      slices.Concat(list(code("RU")), group),
		"end group without start":  protowire.AppendTag(list(code("RU")), 3, protowire.EndGroupType),
		"record length past input": append(list(code("RU")), 0x0a, 0xff, 0xff, 0xff, 0x7f),
	}
	for name, cases := range map[string]map[string][]byte{"geosite": sites, "geoip": ips} {
		for why, data := range cases {
			want := acceptedBefore(name, data)
			_, _, _, err := Reduce(name, data, nil, nil, false)
			if got := err == nil; got != want {
				t.Errorf("%s %s: accepted %v, whole decoding accepted %v (%v)", name, why, got, want, err)
			}
		}
	}
	// The code a record keeps is the last one, as proto.Unmarshal reads it.
	reduced, _, _, err := Reduce("geosite", sites["last code wins"], []string{"geosite:b"}, nil, true)
	var kept geodata.GeoSiteList
	if err != nil || proto.Unmarshal(reduced, &kept) != nil || len(kept.Entry) != 1 || kept.Entry[0].Code != "B" {
		t.Fatalf("last code: %v %v", kept.Entry, err)
	}
}

// Records no selector names are never decoded: a reduced file can only contain what was validated.
func TestReductionSkipsUnusedRecordsUnread(t *testing.T) {
	good, _ := proto.Marshal(&geodata.GeoSite{Code: "TEST", Domain: []*geodata.Domain{{Value: "example.com", Type: geodata.Domain_Full}}})
	// A valid leading code, then a domain Reduce would reject.
	unused := slices.Concat(field(nil, 1, []byte("UNUSED")), field(nil, 2, nil))
	data := field(field(nil, 1, good), 1, unused)
	reduced, status, _, err := Reduce("geosite", data, []string{"geosite:test"}, nil, true)
	if err != nil || status != "ready" || !bytes.Equal(reduced, field(nil, 1, good)) {
		t.Fatalf("reduced: %s %v", status, err)
	}
	if _, _, _, err := Reduce("geosite", data, []string{"geosite:unused"}, nil, true); err == nil {
		t.Fatal("an invalid record a rule needs was kept")
	}
	if _, _, _, err := Reduce("geosite", data, nil, nil, false); err == nil {
		t.Fatal("a complete file kept an invalid record")
	}
}

// writeLargeGeosite writes TEST, then an unused record of about size bytes, then AFTER.
func writeLargeGeosite(t *testing.T, path string, size int) {
	t.Helper()
	file, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	record := func(code, value string) []byte {
		data, _ := proto.Marshal(&geodata.GeoSite{Code: code, Domain: []*geodata.Domain{{Value: value, Type: geodata.Domain_Full}}})
		return field(nil, 1, data)
	}
	head := field(nil, 1, []byte("BIG"))
	head = protowire.AppendVarint(protowire.AppendTag(head, 15, protowire.BytesType), uint64(size))
	framing := protowire.AppendVarint(protowire.AppendTag(nil, 1, protowire.BytesType), uint64(len(head)+size))
	zeros := make([]byte, 1<<20)
	if _, err := file.Write(slices.Concat(record("TEST", "example.com"), framing, head)); err != nil {
		t.Fatal(err)
	}
	for left := size; left > 0; left -= len(zeros) {
		if _, err := file.Write(zeros[:min(left, len(zeros))]); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := file.Write(record("AFTER", "after.example")); err != nil {
		t.Fatal(err)
	}
}

// A runetfreedom geosite.dat is 85 MB, 75 MB of it two categories few profiles use (Elarni).
func TestReduceFileTrimsAFileOverTheCoreLimitWithoutHoldingIt(t *testing.T) {
	dir := t.TempDir()
	source := filepath.Join(dir, "geosite.original.dat")
	writeLargeGeosite(t, source, 66<<20)
	var before, after runtime.MemStats
	runtime.ReadMemStats(&before)
	status, skipped, err := ReduceFile("geosite", source, filepath.Join(dir, "geosite.dat"), []string{"geosite:test"}, []string{"geosite:after", "geosite:missing"}, true)
	runtime.ReadMemStats(&after)
	if err != nil || status != "ready" || !slices.Equal(skipped, []string{"geosite:missing"}) {
		t.Fatalf("reduce: %s %v %v", status, skipped, err)
	}
	if allocated := after.TotalAlloc - before.TotalAlloc; allocated > 8<<20 {
		t.Fatalf("trimming allocated %d MB for a 66 MB unused record", allocated>>20)
	}
	data, _ := os.ReadFile(filepath.Join(dir, "geosite.dat"))
	var list geodata.GeoSiteList
	if proto.Unmarshal(data, &list) != nil || len(list.Entry) != 3 || list.Entry[0].Code != "TEST" || list.Entry[1].Code != "AFTER" ||
		list.Entry[2].Code != "MISSING" || len(list.Entry[2].Domain) != 0 {
		t.Fatalf("kept %v", list.Entry)
	}
	// The core would load a complete file whole.
	for _, fixture := range []struct {
		selectors []string
		reduce    bool
	}{{[]string{"geosite:test"}, false}, {nil, true}, {[]string{"ext:geosite.dat:test"}, true}} {
		target := filepath.Join(dir, "complete.dat")
		if _, _, err := ReduceFile("geosite", source, target, fixture.selectors, nil, fixture.reduce); err == nil || err.Error() != "input_too_large" {
			t.Fatalf("%v reduce=%v: %v, want input_too_large", fixture.selectors, fixture.reduce, err)
		}
		if _, err := os.Stat(target); !errors.Is(err, os.ErrNotExist) {
			t.Fatal("a refused file was left behind")
		}
	}
	missing := filepath.Join(dir, "missing.dat")
	if _, _, err := ReduceFile("geosite", source, missing, []string{"geosite:test", "geosite:none"}, nil, true); !errors.As(err, new(MissingError)) {
		t.Fatalf("missing code: %v", err)
	}
	if _, err := os.Stat(missing); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("a refused file was left behind")
	}
}

func TestReduceFileRefusesASourceOverItsLimitUnread(t *testing.T) {
	dir := t.TempDir()
	source := filepath.Join(dir, "geosite.original.dat")
	file, err := os.Create(source)
	if err != nil {
		t.Fatal(err)
	}
	// Sparse: nothing is written, and nothing may be read.
	if err := errors.Join(file.Truncate(MaxSourceBytes+1), file.Close()); err != nil {
		t.Fatal(err)
	}
	if _, _, err := ReduceFile("geosite", source, filepath.Join(dir, "geosite.dat"), []string{"geosite:test"}, nil, true); err == nil || err.Error() != "input_too_large" {
		t.Fatalf("%v, want input_too_large", err)
	}
}

func TestCountGeoDataCountsRulesAndAttributes(t *testing.T) {
	dir := t.TempDir()
	attribute := func(key string) []*geodata.Domain_Attribute {
		return []*geodata.Domain_Attribute{{Key: key, TypedValue: &geodata.Domain_Attribute_BoolValue{BoolValue: true}}}
	}
	site, _ := proto.Marshal(&geodata.GeoSiteList{Entry: []*geodata.GeoSite{
		{Code: "B", Domain: []*geodata.Domain{{Value: "b.example", Type: geodata.Domain_Full}}},
		{Code: "A", Domain: []*geodata.Domain{{Value: "a.example", Attribute: attribute("ads")},
			{Value: "c.example", Attribute: append(attribute("ads"), attribute("cn")...)}}}}})
	ip, _ := proto.Marshal(&geodata.GeoIPList{Entry: []*geodata.GeoIP{
		{Code: "Y", Cidr: []*geodata.CIDR{{Ip: []byte{192, 0, 2, 0}, Prefix: 24}}},
		{Code: "X", Cidr: []*geodata.CIDR{{Ip: []byte{198, 51, 100, 0}, Prefix: 24}, {Ip: []byte{203, 0, 113, 0}, Prefix: 24}}}}})
	for name, data := range map[string][]byte{"geosite.dat": site, "geoip.dat": ip} {
		if err := os.WriteFile(filepath.Join(dir, name), data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	for name, want := range map[string]string{
		"geosite": `{"codes":[{"code":"A","ruleCount":2},{"code":"A@ads","ruleCount":2},{"code":"A@cn","ruleCount":1},{"code":"B","ruleCount":1}],"categoryCount":2,"ruleCount":3}`,
		"geoip":   `{"codes":[{"code":"X","ruleCount":2},{"code":"Y","ruleCount":1}],"categoryCount":2,"ruleCount":3}`,
	} {
		kind := map[string]string{"geosite": "domain", "geoip": "ip"}[name]
		if err := CountGeoData(dir, name, kind); err != nil {
			t.Fatal(err)
		}
		if got, _ := os.ReadFile(filepath.Join(dir, name+".json")); string(got) != want {
			t.Fatalf("%s counts\n got %s\nwant %s", name, got, want)
		}
	}
	if err := os.WriteFile(filepath.Join(dir, "geosite.dat"), []byte("invalid"), 0600); err != nil {
		t.Fatal(err)
	}
	if CountGeoData(dir, "geosite", "domain") == nil {
		t.Fatal("invalid geodata counted")
	}
}
