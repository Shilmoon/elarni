//go:build linux

package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// A portable bundle under the user's home must never be started through pkexec.
func TestLinuxTrustedRejectsUserWritablePaths(t *testing.T) {
	path := filepath.Join(t.TempDir(), "elarni-core")
	if err := os.WriteFile(path, []byte("core"), 0o755); err != nil {
		t.Fatal(err)
	}
	if os.Geteuid() != 0 && linuxTrusted(path) {
		t.Fatal("a file the user owns was trusted")
	}
	if !linuxTrusted("/") {
		t.Fatal("the root directory was not trusted")
	}
	// Root helpers run whatever linuxTool returns, so a failed check must not fall back to it.
	if tool := linuxTool("elarni-core", filepath.Dir(path)); os.Geteuid() != 0 && tool != "" {
		t.Fatalf("an untrusted tool was returned: %s", tool)
	}
}

// pkexec runs the staged installer, so it must hold exactly the bytes whose digest names the helper.
func TestStagedLinuxInstallerHoldsTheDigestedBytes(t *testing.T) {
	cache := t.TempDir()
	t.Setenv("XDG_CACHE_HOME", cache)
	source := filepath.Join(t.TempDir(), "elarni-core")
	if err := os.WriteFile(source, []byte("core"), 0o755); err != nil {
		t.Fatal(err)
	}
	digest, err := fileDigest(source)
	if err != nil {
		t.Fatal(err)
	}
	staged, err := stageLinuxInstaller(source, digest)
	if err != nil {
		t.Fatal(err)
	}
	if copied, err := fileDigest(staged); err != nil || copied != digest || filepath.Dir(filepath.Dir(staged)) != cache {
		t.Fatalf("staged %s (digest %s, %v)", staged, copied, err)
	}
	if linuxFUSE(staged) {
		t.Fatal("a temporary directory was reported as FUSE")
	}
	if _, err := stageLinuxInstaller(source, strings.Repeat("0", len(digest))); err == nil {
		t.Fatal("a copy that differs from the digest was staged")
	}
	if entries, _ := os.ReadDir(cache); len(entries) != 1 {
		t.Fatalf("a failed stage left %d entries in the cache", len(entries))
	}
}
