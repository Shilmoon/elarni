//go:build windows

package main

import (
	"os"
	"path/filepath"
	"testing"
)

// The elevated helper must refuse a DLL planted beside a portable install.
func TestWintunLoadRequiresThePinnedBuild(t *testing.T) {
	planted := filepath.Join(t.TempDir(), "wintun.dll")
	if err := os.WriteFile(planted, []byte("MZ planted"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := loadPinnedWintun(planted); err == nil {
		t.Fatal("an unpinned wintun.dll was loaded")
	}
	// CI names the DLL its Windows build extracted, so this case cannot skip there.
	official := os.Getenv("ELARNI_TEST_WINTUN")
	if official == "" {
		official = filepath.Join("..", "..", "..", "..", "build", "windows", "x64", "native", "wintun", "bin", "amd64", "wintun.dll")
		if _, err := os.Stat(official); err != nil {
			t.Skip("the pinned Wintun archive has not been extracted by a Windows build; set ELARNI_TEST_WINTUN to its wintun.dll")
		}
	}
	if err := loadPinnedWintun(official); err != nil {
		t.Fatalf("the pinned wintun.dll was refused: %v", err)
	}
}
