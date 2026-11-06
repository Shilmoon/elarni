//go:build linux

package main

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

// The root VPN worker records under /var/log; the local proxy core and marks stay in the user's cache.
func recordingDirectories() []string {
	return []string{userRecordingDirectory(), linuxRecordingDirectory(os.Getuid())}
}

// deviceVersion is the distribution release, as Windows and Android send theirs,
// or else the kernel release.
func deviceVersion() string {
	for _, path := range []string{"/etc/os-release", "/usr/lib/os-release"} {
		if version := osReleaseVersion(path); version != "" {
			return version
		}
	}
	var name unix.Utsname
	if unix.Uname(&name) == nil {
		if release := unix.ByteSliceToString(name.Release[:]); release != "" {
			return release
		}
	}
	return runtime.GOOS
}

func osReleaseVersion(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	for line := range strings.SplitSeq(string(data), "\n") {
		if value, found := strings.CutPrefix(line, "VERSION_ID="); found {
			value = strings.Trim(strings.TrimSpace(value), `"'`)
			if len(value) <= 64 && !strings.ContainsAny(value, "\r\x00") {
				return value
			}
		}
	}
	return ""
}

var catalogLease *os.File

type catalogEnvelope struct {
	Version  int             `json:"version"`
	Revision string          `json:"revision"`
	Catalog  json.RawMessage `json:"catalog"`
}

func linuxCatalogRoot() (string, error) {
	root := os.Getenv("XDG_DATA_HOME")
	if !filepath.IsAbs(root) {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", errors.New("storage_unavailable")
		}
		root = filepath.Join(home, ".local", "share")
	}
	return filepath.Join(root, "Elarni"), nil
}

func linuxAssetRoot() (string, error) {
	root, err := os.UserCacheDir()
	if err != nil {
		return "", errors.New("assets_unavailable")
	}
	return filepath.Join(root, "Elarni", "assets"), nil
}

func platformRequest(method string, payload json.RawMessage) (any, error, bool) {
	switch method {
	case "runVPN":
		data, err := runVPN(payload)
		return data, err, true
	case "stopVPN":
		data, err := stopVPN()
		return data, err, true
	case "staleVPNGuard":
		return map[string]any{"stale": linuxGuardLeft()}, nil, true
	case "clearVPNGuard":
		data, err := clearVPNGuard()
		return data, err, true
	case "pingICMP":
		data, err := linuxICMP(payload)
		return data, err, true
	case "pingEndpoint":
		data, err := linuxPingEndpoint(payload)
		return data, err, true
	case "retireRoutingAssets", "prepareRoutingAssets":
		root, err := linuxAssetRoot()
		if err != nil {
			return nil, err, true
		}
		if method == "prepareRoutingAssets" {
			var request assetRequest
			if json.Unmarshal(payload, &request) != nil {
				return nil, errors.New("invalid_assets"), true
			}
			data, err := prepareAssets(root, request, downloadAsset(request.Proxy))
			return data, err, true
		}
		var request struct {
			Keep []string `json:"keep"`
		}
		if json.Unmarshal(payload, &request) != nil {
			return nil, errors.New("invalid_assets"), true
		}
		return map[string]any{}, retireAssets(root, request.Keep), true
	case "runXrayFromJson", "ping", "validateConfig":
		var request struct {
			AssetRevision string `json:"assetRevision"`
			PacketPath    bool   `json:"packetPath"`
			Proxy         string `json:"proxy"`
			ConfigJSON    string `json:"configJSON"`
		}
		if json.Unmarshal(payload, &request) != nil {
			return nil, errors.New("invalid_assets"), true
		}
		root, err := linuxAssetRoot()
		if err != nil {
			return nil, err, true
		}
		assets, err := readAssets(root, request.AssetRevision)
		if err != nil {
			return nil, err, true
		}
		if err = installAssets(assets); err != nil {
			return nil, err, true
		}
		// A probe through the running local listener needs no bypass of the VPN. An
		// isolated probe of another server brings its own listener and does.
		var config struct {
			Inbounds []json.RawMessage `json:"inbounds"`
		}
		_ = json.Unmarshal([]byte(request.ConfigJSON), &config)
		if method == "ping" && !request.PacketPath && (request.Proxy == "" || len(config.Inbounds) > 0) {
			if data, err, handled := linuxPhysicalProbe(payload, assets); handled {
				return data, err, true
			}
		}
		return nil, nil, false
	case "acquireCatalog", "loadCatalog", "saveCatalog":
		root, err := linuxCatalogRoot()
		if err != nil {
			return nil, err, true
		}
		if method == "acquireCatalog" {
			catalogLease, err = acquireCatalog(root)
			return map[string]any{}, err, true
		}
		data, err := catalogOperation(root, method, payload)
		return data, err, true
	}
	return nil, nil, false
}

// linuxTool finds a distribution tool in fixed root-owned locations, never via
// PATH: root helpers must not run a binary the invoking user can replace.
// NixOS keeps tools under /run/current-system and setuid wrappers in /run/wrappers.
func linuxTool(name string, directories ...string) string {
	if len(directories) == 0 {
		directories = []string{"/usr/sbin", "/usr/bin", "/sbin", "/bin", "/run/current-system/sw/bin"}
	}
	for _, directory := range directories {
		path := filepath.Join(directory, name)
		info, err := os.Stat(path)
		if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0o111 == 0 || info.Mode().Perm()&0o022 != 0 {
			continue
		}
		if stat, ok := info.Sys().(*syscall.Stat_t); ok && stat.Uid == 0 {
			return path
		}
	}
	return "" // Fails to start like a missing tool; an untrusted file is never run.
}

var linuxSecretTool = func() string { return linuxTool("secret-tool", "/usr/bin", "/run/current-system/sw/bin") }

func linuxCatalogLock(root, name string) (*os.File, error) {
	if os.MkdirAll(root, 0700) != nil {
		return nil, errors.New("storage_unavailable")
	}
	// MkdirAll keeps the mode of a directory that already exists.
	if info, err := os.Lstat(root); err != nil || !info.IsDir() ||
		info.Mode().Perm()&0o077 != 0 && os.Chmod(root, 0o700) != nil {
		return nil, errors.New("storage_unavailable")
	}
	fd, err := unix.Open(filepath.Join(root, name), unix.O_CREAT|unix.O_RDWR|unix.O_CLOEXEC|unix.O_NOFOLLOW, 0600)
	if err != nil {
		return nil, errors.New("storage_unavailable")
	}
	file := os.NewFile(uintptr(fd), name)
	if unix.Flock(fd, unix.LOCK_EX|unix.LOCK_NB) != nil {
		file.Close()
		return nil, errors.New("storage_busy")
	}
	return file, nil
}

func acquireCatalog(root string) (*os.File, error) { return linuxCatalogLock(root, "session.lock") }

// Secret Service owns the encryption key. Never fall back to a key beside the
// ciphertext, environment variables, or plaintext when the keyring is locked.
func linuxCatalogKey(root string, create bool) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	args := []string{"lookup", "application", "com.elarni.Elarni", "catalog", root}
	command := exec.CommandContext(ctx, linuxSecretTool(), args...)
	var output bytes.Buffer
	command.Stdout = &output
	err := command.Run()
	if err == nil {
		defer clear(output.Bytes())
		key, err := hex.DecodeString(strings.TrimSpace(output.String()))
		if err != nil || len(key) != 32 {
			clear(key)
			return nil, errors.New("storage_corrupt")
		}
		return key, nil
	}
	if !create || ctx.Err() != nil {
		return nil, errors.New("storage_unavailable")
	}
	var exit *exec.ExitError
	if !errors.As(err, &exit) || exit.ExitCode() != 1 {
		return nil, errors.New("storage_unavailable")
	}
	key := make([]byte, 32)
	if _, err := rand.Read(key); err != nil {
		return nil, errors.New("storage_unavailable")
	}
	encoded := []byte(hex.EncodeToString(key) + "\n")
	defer clear(encoded)
	command = exec.CommandContext(ctx, linuxSecretTool(), "store", "--label=Elarni catalog key", "application", "com.elarni.Elarni", "catalog", root)
	command.Stdin = bytes.NewReader(encoded)
	if command.Run() != nil {
		clear(key)
		return nil, errors.New("storage_unavailable")
	}
	return key, nil
}

func protectLinuxCatalog(key, data []byte, decrypt bool) ([]byte, error) {
	if len(data) == 0 || len(data) > maxMessage+4096 {
		return nil, errors.New("storage_corrupt")
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, errors.New("storage_corrupt")
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, errors.New("storage_corrupt")
	}
	const header = "RVL1"
	if decrypt {
		if len(data) < len(header)+aead.NonceSize()+aead.Overhead() || string(data[:len(header)]) != header {
			return nil, errors.New("storage_corrupt")
		}
		plain, err := aead.Open(nil, data[len(header):len(header)+aead.NonceSize()], data[len(header)+aead.NonceSize():], []byte(header))
		if err != nil {
			return nil, errors.New("storage_corrupt")
		}
		return plain, nil
	}
	nonce := make([]byte, aead.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return nil, errors.New("storage_unavailable")
	}
	return aead.Seal(append([]byte(header), nonce...), nonce, data, []byte(header)), nil
}

// readCatalog also returns the key that decrypted it (nil when no catalog
// exists), so a save never looks the key up again and cannot replace it.
func readCatalog(path string) (catalogEnvelope, []byte, error) {
	var envelope catalogEnvelope
	fd, err := unix.Open(path, unix.O_RDONLY|unix.O_CLOEXEC|unix.O_NOFOLLOW, 0)
	if errors.Is(err, os.ErrNotExist) {
		return catalogEnvelope{Version: 1}, nil, nil
	}
	if err != nil {
		return envelope, nil, errors.New("storage_unavailable")
	}
	file := os.NewFile(uintptr(fd), path)
	defer file.Close()
	encrypted, err := io.ReadAll(io.LimitReader(file, maxMessage+4097))
	if err != nil {
		return envelope, nil, errors.New("storage_unavailable")
	}
	key, err := linuxCatalogKey(filepath.Dir(path), false)
	if err != nil {
		return envelope, nil, err
	}
	plain, err := protectLinuxCatalog(key, encrypted, true)
	if err != nil {
		clear(key)
		return envelope, nil, err
	}
	defer clear(plain)
	if json.Unmarshal(plain, &envelope) != nil || envelope.Version != 1 || len(envelope.Revision) != 64 || len(envelope.Catalog) == 0 || envelope.Catalog[0] != '{' || !json.Valid(envelope.Catalog) {
		clear(key)
		return catalogEnvelope{}, nil, errors.New("storage_corrupt")
	}
	return envelope, key, nil
}

func catalogOperation(root, method string, payload json.RawMessage) (any, error) {
	lock, err := linuxCatalogLock(root, "catalog.lock")
	if err != nil {
		return nil, err
	}
	defer lock.Close()
	path := filepath.Join(root, "catalog.enc")
	current, key, err := readCatalog(path)
	if err != nil {
		return nil, err
	}
	defer func() { clear(key) }() // key may be created below
	if method == "loadCatalog" {
		return current, nil
	}
	var incoming struct {
		Revision string          `json:"revision"`
		Catalog  json.RawMessage `json:"catalog"`
	}
	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&incoming) != nil || len(incoming.Catalog) == 0 || len(incoming.Catalog) > 12*1024*1024 || incoming.Catalog[0] != '{' || !json.Valid(incoming.Catalog) {
		return nil, errors.New("invalid_catalog")
	}
	if incoming.Revision != current.Revision {
		return nil, errors.New("storage_conflict")
	}
	var revision [32]byte
	if _, err := rand.Read(revision[:]); err != nil {
		return nil, errors.New("storage_unavailable")
	}
	current = catalogEnvelope{Version: 1, Revision: hex.EncodeToString(revision[:]), Catalog: incoming.Catalog}
	plain, err := json.Marshal(current)
	if err != nil {
		return nil, errors.New("invalid_catalog")
	}
	defer clear(plain)
	if key == nil {
		// Only a first save, with no ciphertext to strand, may create a key.
		if key, err = linuxCatalogKey(root, true); err != nil {
			return nil, err
		}
	}
	encrypted, err := protectLinuxCatalog(key, plain, false)
	if err != nil {
		return nil, err
	}
	file, err := os.CreateTemp(root, ".catalog-")
	if err != nil {
		return nil, errors.New("storage_unavailable")
	}
	defer os.Remove(file.Name())
	_, writeErr := file.Write(encrypted)
	syncErr := file.Sync()
	closeErr := file.Close()
	if writeErr != nil || syncErr != nil || closeErr != nil || os.Rename(file.Name(), path) != nil {
		return nil, errors.New("storage_unavailable")
	}
	directory, err := os.Open(root)
	if err != nil {
		return nil, errors.New("storage_unavailable")
	}
	err = directory.Sync()
	directory.Close()
	if err != nil {
		return nil, errors.New("storage_unavailable")
	}
	return map[string]any{"revision": current.Revision}, nil
}
