//go:build linux

package main

import (
	"bytes"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
)

// Providers see the distribution release, not just "linux".
func TestLinuxDeviceVersionReadsTheDistributionRelease(t *testing.T) {
	path := filepath.Join(t.TempDir(), "os-release")
	if err := os.WriteFile(path, []byte("NAME=\"Ubuntu\"\nVERSION_ID=\"22.04\"\nID=ubuntu\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if version := osReleaseVersion(path); version != "22.04" {
		t.Fatalf("version = %q", version)
	}
	if version := osReleaseVersion(filepath.Join(t.TempDir(), "missing")); version != "" {
		t.Fatalf("missing file version = %q", version)
	}
	if version := deviceVersion(); version == "" || version == "linux" {
		t.Fatalf("device version = %q", version)
	}
}

// A transient keyring failure while saving must never replace the key that
// encrypts the existing catalog: a failed rename would then lose the catalog.
func TestLinuxCatalogSaveNeverRegeneratesTheKeyOfAnExistingCatalog(t *testing.T) {
	directory := t.TempDir()
	key := filepath.Join(directory, "key")
	tool := filepath.Join(directory, "secret-tool")
	// When armed, the first lookup succeeds and every later one fails like a
	// keyring that locked or lost its D-Bus connection mid-operation.
	script := `#!/bin/sh
case "$1" in
lookup)
  if [ -f "$ELARNI_TEST_FAIL" ]; then
    [ -f "$ELARNI_TEST_FAIL.used" ] && exit 1
    : > "$ELARNI_TEST_FAIL.used"
  fi
  [ -f "$ELARNI_TEST_KEY" ] || exit 1
  cat "$ELARNI_TEST_KEY" ;;
store) cat > "$ELARNI_TEST_KEY" ;;
*) exit 2 ;;
esac
`
	if err := os.WriteFile(tool, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	failure := filepath.Join(directory, "fail")
	t.Setenv("ELARNI_TEST_KEY", key)
	t.Setenv("ELARNI_TEST_FAIL", failure)
	previous := linuxSecretTool
	linuxSecretTool = func() string { return tool }
	defer func() { linuxSecretTool = previous }()

	root := filepath.Join(directory, "Elarni")
	save := func(revision, catalog string) (any, error) {
		payload, _ := json.Marshal(map[string]any{"revision": revision, "catalog": json.RawMessage(catalog)})
		return catalogOperation(root, "saveCatalog", payload)
	}
	first, err := save("", `{"generation":1}`)
	if err != nil {
		t.Fatal("first save", err)
	}
	revision := first.(map[string]any)["revision"].(string)
	original, err := os.ReadFile(key)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(failure, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := save(revision, `{"generation":2}`); err != nil {
		t.Fatal("save could not reuse the key that decrypted the catalog", err)
	}
	if current, _ := os.ReadFile(key); !bytes.Equal(current, original) {
		t.Fatal("the existing catalog key was replaced")
	}
	for _, path := range []string{failure, failure + ".used"} {
		if err := os.Remove(path); err != nil {
			t.Fatal(err)
		}
	}
	loaded, err := catalogOperation(root, "loadCatalog", nil)
	if err != nil || string(loaded.(catalogEnvelope).Catalog) != `{"generation":2}` {
		t.Fatal("catalog unreadable after a keyring failure", loaded, err)
	}
	if info, err := os.Stat(root); err != nil || info.Mode().Perm() != 0o700 {
		t.Fatal("catalog directory is not private", info, err)
	}
}

// An existing, too-open data directory is made private before use.
func TestLinuxCatalogLockTightensExistingDirectory(t *testing.T) {
	root := filepath.Join(t.TempDir(), "Elarni")
	if err := os.Mkdir(root, 0o755); err != nil {
		t.Fatal(err)
	}
	lock, err := linuxCatalogLock(root, "catalog.lock")
	if err != nil {
		t.Fatal(err)
	}
	lock.Close()
	if info, err := os.Stat(root); err != nil || info.Mode().Perm() != 0o700 {
		t.Fatal("existing catalog directory kept group/other access", info, err)
	}
}

// A probe through the running local listener stays in this process: the root
// probe child bypasses the VPN and accepts only configurations with inbounds.
func TestLinuxProxyProbeSkipsTheRootProbe(t *testing.T) {
	previous := linuxProbeRoot
	linuxProbeRoot = t.TempDir()
	defer func() { linuxProbeRoot = previous }()
	t.Setenv("XDG_CACHE_HOME", t.TempDir())
	path := linuxProbePath(os.Getuid())
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	var calls atomic.Int32
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			calls.Add(1)
			conn.Close()
		}
	}()
	ping := func(payload map[string]any) bool {
		encoded, _ := json.Marshal(payload)
		_, _, handled := platformRequest("ping", encoded)
		return handled
	}
	// The same request without a proxy is a physical probe, which the root child serves.
	if !ping(map[string]any{"configJSON": `{"inbounds":[],"outbounds":[{"protocol":"freedom"}]}`}) || calls.Load() != 1 {
		t.Fatal("a physical probe did not reach the root probe", calls.Load())
	}
	if ping(map[string]any{"proxy": "socks5://127.0.0.1:1080", "configJSON": `{"inbounds":[],"outbounds":[{"protocol":"freedom"}]}`}) || calls.Load() != 1 {
		t.Fatal("a probe through the local listener went to the root probe", calls.Load())
	}
	// An isolated probe of another server brings its own listener; it must still bypass the VPN.
	if !ping(map[string]any{"proxy": "socks5://u:p@127.0.0.1:1081", "configJSON": `{"inbounds":[{"protocol":"socks","listen":"127.0.0.1","port":1081}],"outbounds":[{"protocol":"freedom"}]}`}) || calls.Load() != 2 {
		t.Fatal("an isolated probe did not reach the root probe", calls.Load())
	}
}
