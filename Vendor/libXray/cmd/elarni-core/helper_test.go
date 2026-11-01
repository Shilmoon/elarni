//go:build windows || linux

package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// The protected copy is the only binary elevation starts, so a partial or
// tampered copy must never be published, and old builds must not pile up.
func TestHelperInstallPublishesOnlyVerifiedCopiesAndPrunesOldBuilds(t *testing.T) {
	source, root := t.TempDir(), t.TempDir()
	core := filepath.Join(source, "core")
	if err := os.WriteFile(core, []byte("build two"), 0o755); err != nil {
		t.Fatal(err)
	}
	digest, err := fileDigest(core)
	if err != nil {
		t.Fatal(err)
	}
	if err := installHelper(root, digest, []helperFile{{"core", core, "0000"}}); err == nil {
		t.Fatal("a copy that does not match its digest was published")
	}
	if entries, _ := os.ReadDir(root); len(entries) != 0 {
		t.Fatalf("a failed install left %d entries", len(entries))
	}
	old := filepath.Join(root, "0123456789abcdef")
	marker := filepath.Join(root, ".dns-guard")
	// A killed install leaves its staging copy; a concurrent one is still writing.
	abandoned, staging := filepath.Join(root, ".partial-1"), filepath.Join(root, ".partial-2")
	for _, path := range []string{old, marker, abandoned, staging} {
		if err := os.MkdirAll(path, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Chtimes(abandoned, time.Now().Add(-2*time.Hour), time.Now().Add(-2*time.Hour)); err != nil {
		t.Fatal(err)
	}
	for range 2 { // A repeat install keeps the published copy.
		if err := installHelper(root, digest, []helperFile{{"core", core, digest}}); err != nil {
			t.Fatal(err)
		}
	}
	copied, err := fileDigest(filepath.Join(helperDirectory(root, digest), "core"))
	if err != nil || copied != digest {
		t.Fatalf("installed copy differs: %v", err)
	}
	if _, err := os.Stat(old); !os.IsNotExist(err) {
		t.Fatal("an unused older build was kept")
	}
	if _, err := os.Stat(marker); err != nil {
		t.Fatal("a dot-prefixed marker was pruned")
	}
	if _, err := os.Stat(abandoned); !os.IsNotExist(err) {
		t.Fatal("an abandoned staging copy was kept")
	}
	if _, err := os.Stat(staging); err != nil {
		t.Fatal("a recent staging copy was pruned")
	}
}
