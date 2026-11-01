//go:build windows || linux

package main

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// A portable bundle stays writable by its user, so a same-user program could
// swap the binary just before a consent prompt elevates it. Each build is
// therefore copied once, behind that prompt, into an admin-only directory named
// by its digest; every later prompt starts only that copy.

type helperFile struct{ name, source, digest string }

func fileDigest(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()
	digest := sha256.New()
	if _, err := io.Copy(digest, file); err != nil {
		return "", err
	}
	return hex.EncodeToString(digest.Sum(nil)), nil
}

// helperDirectory is where the build with this digest is installed.
func helperDirectory(root, digest string) string { return filepath.Join(root, digest[:16]) }

func helperInstalled(directory string, names ...string) bool {
	for _, name := range names {
		if info, err := os.Stat(filepath.Join(directory, name)); err != nil || !info.Mode().IsRegular() {
			return false
		}
	}
	return true
}

// installHelper publishes the files for build digest under root only once every
// copy matches its expected digest, then removes other builds' directories.
// Other dot-prefixed entries (markers) are never pruned.
func installHelper(root, digest string, files []helperFile) error {
	target := helperDirectory(root, digest)
	names := make([]string, len(files))
	for index, file := range files {
		names[index] = file.name
	}
	if !helperInstalled(target, names...) {
		staging, err := os.MkdirTemp(root, ".partial-")
		if err != nil {
			return err
		}
		defer os.RemoveAll(staging)
		for _, file := range files {
			copied, err := copyHelperFile(file.source, filepath.Join(staging, file.name))
			if err != nil {
				return err
			}
			if copied != file.digest {
				return errors.New("helper_copy_mismatch")
			}
		}
		if err := os.Chmod(staging, 0o755); err != nil {
			return err
		}
		_ = os.RemoveAll(target) // An incomplete earlier copy; complete copies returned above.
		if err := os.Rename(staging, target); err != nil && !helperInstalled(target, names...) {
			return err
		}
	}
	entries, err := os.ReadDir(root)
	if err != nil {
		return nil
	}
	for _, entry := range entries {
		path, name := filepath.Join(root, entry.Name()), entry.Name()
		// A killed install leaves its staging copy; a recent one may still be writing.
		if strings.HasPrefix(name, ".partial-") {
			if info, err := entry.Info(); err == nil && time.Since(info.ModTime()) > time.Hour {
				_ = os.RemoveAll(path)
			}
			continue
		}
		// In-use Windows builds stay locked; a running Linux build keeps its open image.
		if path != target && !strings.HasPrefix(name, ".") {
			_ = os.RemoveAll(path)
		}
	}
	return nil
}

// copyHelperFile returns the digest of the bytes it wrote. Only administrators
// can change the staged copy, so hashing it while writing is as strong as reading
// it back, and a reopen made Windows Defender scan the 52 MB core a second time.
func copyHelperFile(source, destination string) (string, error) {
	input, err := os.Open(source)
	if err != nil {
		return "", err
	}
	defer input.Close()
	output, err := os.OpenFile(destination, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o755)
	if err != nil {
		return "", err
	}
	digest := sha256.New()
	if _, err := io.Copy(io.MultiWriter(output, digest), input); err != nil {
		output.Close()
		return "", err
	}
	if err := output.Sync(); err != nil {
		output.Close()
		return "", err
	}
	if err := output.Close(); err != nil {
		return "", err
	}
	return hex.EncodeToString(digest.Sum(nil)), nil
}
