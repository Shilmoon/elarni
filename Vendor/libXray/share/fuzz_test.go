package share

import (
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"flag"
	"go/ast"
	"go/parser"
	"go/token"
	"net/url"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
	"unicode"

	"github.com/xtls/xray-core/infra/conf"
)

// Provider-controlled text reaches these parsers. `go test` replays the seeds and
// testdata/fuzz; `go test -run=^$ -fuzz=FuzzImportClientProfiles ./share/` mutates them.

// fixtureStrings collects the string literals in this package's tests that keep accepts,
// so every corpus starts from the fixtures the unit tests use.
func fixtureStrings(f *testing.F, keep func(string) bool) []string {
	files, err := filepath.Glob("*_test.go")
	if err != nil {
		f.Fatal(err)
	}
	seen := map[string]bool{}
	var seeds []string
	for _, name := range files {
		file, err := parser.ParseFile(token.NewFileSet(), name, nil, 0)
		if err != nil {
			f.Fatal(err)
		}
		ast.Inspect(file, func(node ast.Node) bool {
			if literal, ok := node.(*ast.BasicLit); ok && literal.Kind == token.STRING {
				if text, err := strconv.Unquote(literal.Value); err == nil && !seen[text] && keep(text) {
					seen[text] = true
					seeds = append(seeds, text)
				}
			}
			return true
		})
	}
	if len(seeds) == 0 {
		f.Fatal("no fixture seeds")
	}
	return seeds
}

func importerInput(text string) bool {
	trimmed := strings.TrimSpace(text)
	return strings.Contains(text, "://") || strings.Contains(text, "proxies:") ||
		strings.Contains(strings.ToLower(text), "[interface]") || strings.HasPrefix(trimmed, "{") || strings.HasPrefix(trimmed, "[")
}

// checkFast fails an input that is slow while fuzzing; replaying seeds on a loaded CI
// host never fails on time. Linear work is allowed 2 µs a byte above the second.
func checkFast(t *testing.T, start time.Time, input string) {
	if fuzz := flag.Lookup("test.fuzz"); fuzz == nil || fuzz.Value.String() == "" {
		return
	}
	if elapsed := time.Since(start); elapsed > time.Second+time.Duration(len(input))*2*time.Microsecond {
		t.Fatalf("%d-byte input took %v", len(input), elapsed)
	}
}

func FuzzImportClientProfiles(f *testing.F) {
	seeds := fixtureStrings(f, importerInput)
	var links []string
	for _, seed := range seeds {
		f.Add(seed)
		if strings.Contains(seed, "://") && !strings.Contains(seed, "\n") {
			links = append(links, seed)
		}
	}
	f.Add(base64.StdEncoding.EncodeToString([]byte(strings.Join(links, "\n")))) // a base64 subscription body
	f.Fuzz(func(t *testing.T, text string) {
		start := time.Now()
		imported, err := ImportClientProfiles(text)
		if (imported == nil) == (err == nil) {
			t.Fatalf("import returned %v and error %v", imported, err)
		}
		if err == nil {
			checkImport(t, imported)
		}
		// The legacy libXray converter is still exported through Invoke.
		config, err := ConvertShareLinksToXrayJson(text)
		if (config == nil) == (err == nil) {
			t.Fatalf("conversion returned %v and error %v", config, err)
		}
		if err == nil {
			if _, err := json.Marshal(config); err != nil {
				t.Fatalf("converted config does not serialize: %v", err)
			}
		}
		checkFast(t, start, text)
	})
}

// checkImport asserts what callers rely on: Invoke serializes the result, the catalog
// backup re-imports every node from its stored config, and sharing exports links.
func checkImport(t *testing.T, imported *ClientImport) {
	t.Helper()
	if len(imported.Profiles) == 0 || len(imported.Profiles) > 1024 {
		t.Fatalf("%d profiles", len(imported.Profiles))
	}
	if _, err := json.Marshal(imported); err != nil {
		t.Fatalf("import result does not serialize: %v", err)
	}
	checkMigration(t, "https://feed.example/sub?token=fixture", imported.Migration)
	for _, profile := range imported.Profiles {
		var content string
		switch profile.Format {
		case "xrayProfile":
			// As validBackupNode stores it: decoded into a map and encoded again.
			var config map[string]any
			if err := json.Unmarshal(profile.Config, &config); err != nil || config == nil {
				t.Fatalf("profile config is not a JSON object: %v\n%s", err, profile.Config)
			}
			encoded, err := json.Marshal(config)
			if err != nil {
				t.Fatal(err)
			}
			content = string(encoded)
			_, _ = ProfileHostMappings(content, []string{"feed.example", "localhost"})
			if links, err := ConvertXrayJsonToShareLinks(profile.Config); err == nil && !strings.HasPrefix(links, "{") {
				if _, err := ImportClientProfiles(links); err != nil {
					t.Fatalf("exported links do not import: %v\n%s\nfrom %s", err, links, profile.Config)
				}
			}
		case "telegram":
			if !strings.HasPrefix(profile.URL, "tg://proxy?") {
				t.Fatalf("telegram profile URL %q", profile.URL)
			}
			content = profile.URL
		default:
			t.Fatalf("unknown profile format %q", profile.Format)
		}
		again, err := ImportClientProfiles(content)
		if err != nil || len(again.Profiles) != 1 || again.Profiles[0].Format != profile.Format {
			t.Fatalf("stored profile does not re-import alone: %v\n%s", err, content)
		}
	}
}

// checkMigration resolves body hints as Invoke does and checks a non-empty move.
func checkMigration(t *testing.T, source string, body map[string]string) {
	t.Helper()
	target, err := SubscriptionMigrationURL(source, body, nil)
	if err != nil && target != "" {
		t.Fatalf("migration returned %q with error %v", target, err)
	}
	checkMovedURL(t, source, target)
	checkMovedURL(t, source, SubscriptionFallbackURL(source, body, nil))
}

// checkMovedURL holds a URL the app stores in place of the subscription's own.
func checkMovedURL(t *testing.T, source, target string) {
	t.Helper()
	if target == "" {
		return
	}
	u, err := url.Parse(target)
	base, baseErr := url.Parse(source)
	if err != nil || baseErr != nil || target == source || len(target) > 16*1024 || u.User != nil || u.Fragment != "" ||
		u.Hostname() == "" || (u.Scheme != "https" && u.Scheme != "http") || base.Scheme == "https" && u.Scheme != "https" ||
		strings.IndexFunc(target, unicode.IsControl) >= 0 || strings.ContainsRune(target, ' ') {
		t.Fatalf("unsafe move from %q to %q (%v)", source, target, err)
	}
	// Stored and checked again on the next fetch, it must stay the same URL.
	if again, err := SubscriptionMigrationURL(target, nil, map[string]string{"new-url": target}); err != nil || again != "" {
		t.Fatalf("stored move %q does not validate as itself: %q %v", target, again, err)
	}
}

func FuzzClientLink(f *testing.F) {
	for _, seed := range fixtureStrings(f, func(text string) bool { return strings.Contains(text, "://") }) {
		f.Add(seed)
		// The VMess QR JSON sits under base64, where mutations rarely keep it valid.
		if payload, ok := strings.CutPrefix(seed, "vmess://"); ok {
			if decoded, err := decodeBase64Text(payload); err == nil {
				f.Add(decoded)
			}
		}
	}
	f.Fuzz(func(t *testing.T, line string) {
		start := time.Now()
		link, err := parseClientLink(line)
		if (link == nil) == (err == nil) {
			t.Fatalf("link parse returned %v and error %v", link, err)
		}
		if err == nil {
			outbound, err := (xrayShareLink{link: link, rawText: line}).outbound()
			if (outbound == nil) == (err == nil) {
				t.Fatalf("outbound %v and error %v", outbound, err)
			}
			if err == nil {
				raw, err := json.Marshal(map[string]any{"outbounds": []conf.OutboundDetourConfig{*outbound}})
				if err != nil {
					t.Fatalf("outbound does not serialize: %v", err)
				}
				_, _ = ConvertXrayJsonToShareLinks(raw) // unvalidated settings must not panic the exporter
			}
		}
		if outbound, err := parseVMessQrCode(line); (outbound == nil) == (err == nil) {
			t.Fatalf("VMess QR returned %v and error %v", outbound, err)
		}
		if profile, err := importWireGuardLink(line); (err == nil) != (profile.Format == "xrayProfile") || err == nil && !json.Valid(profile.Config) {
			t.Fatalf("WireGuard link returned %+v and error %v", profile, err)
		}
		if target, ok := TelegramProxyURL(line); ok {
			if again, ok := TelegramProxyURL(target); !ok || again != target {
				t.Fatalf("telegram URL %q normalizes to %q", target, again)
			}
		}
		if input, err := NormalizeClientInput(line); err != nil && input != (ClientInput{}) {
			t.Fatalf("normalized %+v with error %v", input, err)
		}
		checkFast(t, start, line)
	})
}

func FuzzSubscriptionMigration(f *testing.F) {
	for _, source := range []string{"https://old.example:8443/path/encoded%2Ftoken?key=a%2Bb", "https://old.example/feed?token=a", "http://192.0.2.1:8080/sub"} {
		f.Add(source, "https://new.example/sub?token=a b", "", "", false)
		f.Add(source, "", "new.example", "https://backup.example/feed?token=b", true)
		f.Add(source, "http://new.example/feed", "new.example:8443", "not a url", false)
		f.Add(source, "https://user:secret@new.example/feed", "[2001:db8::1]", "https://new.example/é", true)
	}
	f.Fuzz(func(t *testing.T, source, newURL, newDomain, fallback string, inHeaders bool) {
		start := time.Now()
		hints := map[string]string{}
		for key, value := range map[string]string{"new-url": newURL, "new-domain": newDomain, "fallback-url": fallback} {
			if value != "" {
				hints[key] = value
			}
		}
		body, headers := hints, map[string]string(nil)
		if inHeaders {
			body, headers = nil, hints
		}
		target, err := SubscriptionMigrationURL(source, body, headers)
		if err != nil && target != "" {
			t.Fatalf("migration returned %q with error %v", target, err)
		}
		checkMovedURL(t, source, target)
		checkMovedURL(t, source, SubscriptionFallbackURL(source, body, headers))
		checkFast(t, start, source+newURL+newDomain+fallback)
	})
}

// The stored ETag and Last-Modified and the fallback hosts come from providers.
func FuzzSubscriptionFetchOptions(f *testing.F) {
	f.Add("https://sub.example/feed?token=a", `W/"etag"`, "Mon, 02 Nov 2026 00:00:00 GMT", "mirror.example", "100-200", "10-20")
	f.Add("http://192.0.2.1/sub", "", "", "[2001:db8::1]", "1", "0")
	f.Add("https://sub.example:8443/x", "a\x01b", "", "a:b", "65535-1", "")
	f.Fuzz(func(t *testing.T, target, validator, modified, host, length, interval string) {
		start := time.Now()
		request := SubscriptionFetchRequest{URL: target, InstallationID: "fixture", ETag: validator, LastModified: modified,
			FallbackHosts: []string{host}, HTTPHost: host, FragmentLength: length, FragmentInterval: interval}
		if request.ValidateOptions() == nil && length != "" {
			// fragmentHelloConn draws rand.IntN(high-low+1) from both ranges.
			for _, check := range []struct {
				value     string
				low, high int
			}{{length, 1, 65535}, {interval, 0, 1000}} {
				bounds, err := fetchRange(check.value, check.low, check.high)
				if err != nil || bounds[0] < check.low || bounds[0] > bounds[1] || bounds[1] > check.high {
					t.Fatalf("accepted range %q as %v, %v", check.value, bounds, err)
				}
			}
		}
		if id, err := SubscriptionDeviceID(request); err == nil {
			if decoded, err := hex.DecodeString(id); err != nil || len(decoded) != 32 {
				t.Fatalf("device ID %q", id)
			}
		} else if id != "" {
			t.Fatalf("device ID %q with error %v", id, err)
		}
		checkFast(t, start, target+validator+modified+host+length+interval)
	})
}
