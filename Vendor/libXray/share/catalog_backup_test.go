package share

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
)

func TestCatalogBackupRoundTripAndAuthentication(t *testing.T) {
	const password = "synthetic backup password"
	const catalog = `{"version":1,"subscriptions":[{"id":"source","name":"Fixture","url":"https://provider.invalid/secret-token","nodes":[]}]}`
	first, err := SealCatalogBackup(json.RawMessage(catalog), password)
	if err != nil || strings.Contains(first, "secret-token") {
		t.Fatal("backup leaked plaintext", err)
	}
	second, err := SealCatalogBackup(json.RawMessage(catalog), password)
	if err != nil || first == second {
		t.Fatal("backup reused encryption randomness", err)
	}
	plain, err := OpenCatalogBackup(first, password)
	if err != nil || string(plain) != catalog {
		t.Fatal("backup round trip failed", err)
	}
	if _, err = OpenCatalogBackup(first, "incorrect password"); err == nil {
		t.Fatal("wrong password accepted")
	}
	var envelope backupEnvelope
	if err = json.Unmarshal([]byte(first), &envelope); err != nil {
		t.Fatal(err)
	}
	envelope.Data[0] ^= 1
	tampered, _ := json.Marshal(envelope)
	if _, err = OpenCatalogBackup(string(tampered), password); err == nil {
		t.Fatal("modified backup accepted")
	}
	if _, err = SealCatalogBackup(json.RawMessage(catalog), "short"); err == nil {
		t.Fatal("short password accepted")
	}
	if _, err = SealCatalogBackup(json.RawMessage(catalog), "пароль"); err == nil {
		t.Fatal("short multibyte password accepted")
	}
}

func TestCatalogBackupValidatesPortableReferencesAndProfiles(t *testing.T) {
	fixture := func() CatalogBackup {
		return CatalogBackup{Version: 1, Subscriptions: []BackupSubscription{{
			ID: "source", Name: "Fixture", URL: "https://provider.invalid/feed",
			Nodes: []BackupNode{{ID: "node", Name: "Direct", Format: "xrayProfile",
				Config: map[string]any{"outbounds": []any{map[string]any{"protocol": "freedom", "tag": "proxy"}}}}},
		}}, SelectedNodeID: "node"}
	}
	valid := fixture()
	valid.Subscriptions[0].Nodes[0].IPPreference = "ipv6"
	data, _ := json.Marshal(valid)
	result, err := ValidateCatalogBackup(data)
	if err != nil || result.SelectedNodeID != "node" || result.Routes == nil || result.Assignments == nil || result.Subscriptions[0].Nodes[0].IPPreference != "ipv6" {
		t.Fatal("valid portable catalog rejected or empty collections not normalized", err)
	}
	for name, mutate := range map[string]func(*CatalogBackup){
		"invalid IP preference": func(b *CatalogBackup) { b.Subscriptions[0].Nodes[0].IPPreference = "prefer6" },
		"duplicate sources":     func(b *CatalogBackup) { b.Subscriptions = append(b.Subscriptions, b.Subscriptions[0]) },
		"duplicate nodes": func(b *CatalogBackup) {
			b.Subscriptions[0].Nodes = append(b.Subscriptions[0].Nodes, b.Subscriptions[0].Nodes[0])
		},
		"broken profile": func(b *CatalogBackup) {
			b.Subscriptions[0].Nodes[0].Config = map[string]any{"outbounds": []any{map[string]any{"protocol": "unsupported"}}}
		},
		"unknown selection": func(b *CatalogBackup) { b.SelectedNodeID = "missing" },
		"missing route":     func(b *CatalogBackup) { b.Assignments = map[string]string{"source": "missing"} },
		"provider original missing": func(b *CatalogBackup) {
			b.Routes = []BackupRoute{{ID: "route", Profile: map[string]any{}, ProviderSubscriptionID: "source"}}
		},
		"mismatched share link": func(b *CatalogBackup) { b.Subscriptions[0].ShareLink = "https://other.invalid/feed" },
		"invalid fetch host":    func(b *CatalogBackup) { b.Subscriptions[0].FetchOptions = map[string]string{"httpHost": "bad/host"} },
		"telegram selection": func(b *CatalogBackup) {
			b.Subscriptions[0].Nodes[0] = BackupNode{ID: "node", Name: "Telegram", Format: "telegram", Config: map[string]any{"url": "tg://proxy?server=proxy.example&port=443&secret=000102030405060708090a0b0c0d0e0f"}}
		},
	} {
		t.Run(name, func(t *testing.T) {
			bad := fixture()
			mutate(&bad)
			data, _ := json.Marshal(bad)
			if _, err := ValidateCatalogBackup(data); err == nil {
				t.Fatal("invalid catalog accepted")
			}
		})
	}
}

// Export must refuse what restore would reject, or the user learns too late.
func TestCatalogBackupSealRejectsWhatRestoreRejects(t *testing.T) {
	const password = "synthetic backup password"
	node := func(id, name string) BackupNode {
		return BackupNode{ID: id, Name: name, Format: "xrayProfile",
			Config: map[string]any{"outbounds": []any{map[string]any{"protocol": "freedom", "tag": "proxy"}}}}
	}
	seal := func(nodes ...BackupNode) error {
		data, _ := json.Marshal(CatalogBackup{Version: 1, Subscriptions: []BackupSubscription{{ID: "source", Name: "Fixture", Nodes: nodes}}})
		_, err := SealCatalogBackup(data, password)
		return err
	}
	if err := seal(node("node", "Direct")); err != nil {
		t.Fatal("valid catalog was not sealed", err)
	}
	if err := seal(node("node", strings.Repeat("n", 1025))); err == nil {
		t.Fatal("sealed a server name that restore rejects")
	}
	many := make([]BackupNode, 4097)
	for i := range many {
		many[i] = node(fmt.Sprintf("node-%d", i), "Direct")
	}
	if err := seal(many...); err == nil {
		t.Fatal("sealed more servers than restore accepts")
	}
}

// A user's refresh interval overrides the provider's, in whole hours up to a week.
func TestCatalogBackupKeepsTheRefreshOverride(t *testing.T) {
	const catalog = `{"version":1,"subscriptions":[{"id":"source","name":"Fixture","url":"https://provider.invalid/feed","fetchOptions":{"refreshHours":"HOURS"},"nodes":[]}]}`
	for _, hours := range []string{"1", "12", "168"} {
		if _, err := ValidateCatalogBackup([]byte(strings.Replace(catalog, "HOURS", hours, 1))); err != nil {
			t.Fatalf("%s hours rejected: %v", hours, err)
		}
	}
	for _, hours := range []string{"", "0", "169", "1.5", "-1", " 2", "012"} {
		if _, err := ValidateCatalogBackup([]byte(strings.Replace(catalog, "HOURS", hours, 1))); err == nil {
			t.Fatalf("%q hours accepted", hours)
		}
	}
}

// Android offers a per-subscription user agent, which fetches accept.
func TestCatalogBackupKeepsTheSubscriptionUserAgent(t *testing.T) {
	const catalog = `{"version":1,"subscriptions":[{"id":"source","name":"Fixture","url":"https://provider.invalid/feed","fetchOptions":{"userAgent":"Fixture/1.0"},"nodes":[]}]}`
	if _, err := ValidateCatalogBackup([]byte(catalog)); err != nil {
		t.Fatal(err)
	}
	sealed, err := SealCatalogBackup(json.RawMessage(catalog), "synthetic backup password")
	if err != nil {
		t.Fatal(err)
	}
	if plain, err := OpenCatalogBackup(sealed, "synthetic backup password"); err != nil || !strings.Contains(string(plain), "Fixture/1.0") {
		t.Fatal("user agent lost", err)
	}
	invalid := strings.Replace(catalog, "Fixture/1.0", `Fixture\r\nX-Injected: 1`, 1)
	if _, err := ValidateCatalogBackup([]byte(invalid)); err == nil {
		t.Fatal("header injection accepted")
	}
}

// A restore must not undo the user's choices: a renamed server keeps the provider's
// name beside the user's, favorites stay, and hidden servers stay hidden.
func TestCatalogBackupKeepsRenamesFavoritesAndHiddenServers(t *testing.T) {
	const node = `{"id":"ID","name":"NAME","format":"xrayProfile","config":{"outbounds":[{"protocol":"freedom","tag":"proxy"}]}EXTRA}`
	server := func(id, name, extra string) string {
		return strings.NewReplacer("ID", id, "NAME", name, "EXTRA", extra).Replace(node)
	}
	catalog := func(selected, visible, hidden string) []byte {
		return []byte(`{"version":1,"selectedNodeId":"` + selected + `","subscriptions":[{"id":"source","name":"Fixture","url":"https://provider.invalid/feed","nodes":[` +
			visible + `],"hiddenNodes":[` + hidden + `]}]}`)
	}
	valid := catalog("mine", server("mine", "Mine", `,"providerName":"NL-1","favorite":true`), server("gone", "NL-2", ""))
	result, err := ValidateCatalogBackup(valid)
	if err != nil {
		t.Fatal(err)
	}
	source := result.Subscriptions[0]
	if len(source.Nodes) != 1 || source.Nodes[0].ProviderName != "NL-1" || !source.Nodes[0].Favorite ||
		len(source.HiddenNodes) != 1 || source.HiddenNodes[0].ID != "gone" {
		t.Fatalf("user choices lost: %+v", source)
	}
	for name, invalid := range map[string][]byte{
		"hidden selection":      catalog("gone", server("mine", "Mine", ""), server("gone", "NL-2", "")),
		"hidden duplicate":      catalog("mine", server("mine", "Mine", ""), server("mine", "NL-2", "")),
		"long provider name":    catalog("mine", server("mine", "Mine", `,"providerName":"`+strings.Repeat("n", 1025)+`"`), ""),
		"broken hidden profile": catalog("mine", server("mine", "Mine", ""), `{"id":"gone","name":"NL-2","format":"xrayProfile","config":{"outbounds":[{"protocol":"unsupported"}]}}`),
	} {
		if _, err := ValidateCatalogBackup(invalid); err == nil {
			t.Errorf("%s accepted", name)
		}
	}
}
