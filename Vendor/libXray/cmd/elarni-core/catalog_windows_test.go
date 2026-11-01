//go:build windows

package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// Proves the Windows trust boundary: encrypted disk data, atomic publication,
// stale-writer rejection and preservation of unreadable user data.
func TestCatalogEncryptedPublication(t *testing.T) {
	root := filepath.Join(t.TempDir(), "data with spaces")
	load := func() catalogEnvelope {
		t.Helper()
		value, err := catalogOperation(root, "loadCatalog", nil)
		if err != nil {
			t.Fatal(err)
		}
		return value.(catalogEnvelope)
	}
	if load().Revision != "" {
		t.Fatal("new store was not empty")
	}
	payload := []byte(`{"revision":"","catalog":{"secret":"synthetic-private-profile"}}`)
	result, err := catalogOperation(root, "saveCatalog", payload)
	if err != nil {
		t.Fatal(err)
	}
	loaded := load()
	if loaded.Revision != result.(map[string]any)["revision"] || !bytes.Contains(loaded.Catalog, []byte("synthetic-private-profile")) {
		t.Fatal("published data did not round trip")
	}
	path := filepath.Join(root, "catalog.dpapi")
	ciphertext, err := os.ReadFile(path)
	if err != nil || bytes.Contains(ciphertext, []byte("synthetic-private-profile")) || json.Valid(ciphertext) {
		t.Fatal("plaintext reached the catalog file")
	}
	if _, err := catalogOperation(root, "saveCatalog", payload); err == nil || err.Error() != "storage_conflict" {
		t.Fatal("stale instance overwrote the catalog")
	}
	if after, err := os.ReadFile(path); err != nil || !bytes.Equal(after, ciphertext) {
		t.Fatal("failed publication changed the catalog")
	}
	ciphertext[len(ciphertext)/2] ^= 0x80
	if err := os.WriteFile(path, ciphertext, 0600); err != nil {
		t.Fatal(err)
	}
	for _, method := range []string{"loadCatalog", "saveCatalog"} {
		if _, err := catalogOperation(root, method, payload); err == nil || err.Error() != "storage_corrupt" {
			t.Fatal("corrupt data was accepted or replaced")
		}
	}
	if after, err := os.ReadFile(path); err != nil || !bytes.Equal(after, ciphertext) {
		t.Fatal("unreadable user data was overwritten")
	}
}
