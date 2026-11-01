//go:build windows

package main

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"path/filepath"
	"runtime"

	"golang.org/x/sys/windows"
)

// The official Wintun 0.14.1 DLLs from the archive pinned in windows/CMakeLists.txt.
var wintunSHA256 = map[string]string{
	"amd64": "e5da8447dc2c320edc0fc52fa01885c103de8c118481f683643cacc3220dafce",
	"arm64": "f7ba89005544be9d85231a9e0d5f23b2d15b3311667e2dad0debd344918a3f80",
}

// bundledWintun is the DLL the elevated helper would otherwise load by name
// from a portable, user-writable install.
func bundledWintun() (string, error) {
	executable, err := os.Executable()
	if err != nil {
		return "", err
	}
	return filepath.Join(filepath.Dir(executable), "wintun.dll"), nil
}

// loadPinnedWintun maps path only if it is the pinned build. Windows resolves
// the TUN's later load by name to this already-loaded module.
func loadPinnedWintun(path string) error {
	// LoadLibraryEx search flags require an absolute path.
	path, err := filepath.Abs(path)
	if err != nil {
		return err
	}
	name, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return err
	}
	// Deny writers and deleters until the checked image is mapped.
	handle, err := windows.CreateFile(name, windows.GENERIC_READ, windows.FILE_SHARE_READ, nil,
		windows.OPEN_EXISTING, windows.FILE_ATTRIBUTE_NORMAL, 0)
	if err != nil {
		return err
	}
	file := os.NewFile(uintptr(handle), path)
	defer file.Close()
	digest := sha256.New()
	if _, err := io.Copy(digest, file); err != nil {
		return err
	}
	if hex.EncodeToString(digest.Sum(nil)) != wintunSHA256[runtime.GOARCH] {
		return errors.New("wintun.dll is not the bundled build")
	}
	_, err = windows.LoadLibraryEx(path, 0, windows.LOAD_LIBRARY_SEARCH_SYSTEM32)
	return err
}
