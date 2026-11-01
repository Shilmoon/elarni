//go:build windows

package main

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"strconv"
	"time"
	"unsafe"

	"github.com/xtls/xray-core/transport/internet"
	"golang.org/x/sys/windows"
)

type catalogEnvelope struct {
	Version  int             `json:"version"`
	Revision string          `json:"revision"`
	Catalog  json.RawMessage `json:"catalog"`
}

var catalogLease *os.File

func deviceVersion() string {
	version := windows.RtlGetVersion()
	return fmt.Sprintf("%d.%d.%d", version.MajorVersion, version.MinorVersion, version.BuildNumber)
}

// The elevated VPN child shares this profile's cache, so one directory holds both.
func recordingDirectories() []string { return []string{userRecordingDirectory()} }

func platformRequest(method string, payload json.RawMessage) (any, error, bool) {
	switch method {
	case "retireRoutingAssets":
		var request struct {
			Keep []string `json:"keep"`
		}
		if json.Unmarshal(payload, &request) != nil {
			return nil, errors.New("invalid_assets"), true
		}
		root, err := os.UserCacheDir()
		if err != nil {
			return nil, errors.New("assets_unavailable"), true
		}
		return map[string]any{}, retireAssets(filepath.Join(root, "Elarni", "assets"), request.Keep), true
	case "runVPN":
		data, err := runVPN(payload)
		return data, err, true
	case "stopVPN":
		data, err := stopVPN()
		return data, err, true
	case "clearVPNGuard":
		data, err := clearVPNGuard()
		return data, err, true
	case "staleVPNGuard":
		return map[string]any{"stale": staleGuard()}, nil, true
	case "vpnServiceStatus":
		return vpnServiceStatus(), nil, true
	case "setVPNService":
		data, err := setVPNService(payload)
		return data, err, true
	case "pingEndpoint":
		var request struct {
			Address string `json:"address"`
			Port    int    `json:"port"`
			Timeout int    `json:"timeout"`
		}
		decoder := json.NewDecoder(bytes.NewReader(payload))
		decoder.DisallowUnknownFields()
		if decoder.Decode(&request) != nil || request.Port < 1 || request.Port > 65535 || request.Timeout < 1 || request.Timeout > 15 {
			return nil, errors.New("invalid_request"), true
		}
		address, err := netip.ParseAddr(request.Address)
		if err != nil || address.IsUnspecified() || address.IsMulticast() {
			return nil, errors.New("invalid_request"), true
		}
		if bindPhysicalRoutes() != nil {
			return nil, errors.New("ping_failed"), true
		}
		dialer := net.Dialer{Timeout: time.Duration(request.Timeout) * time.Second, Control: internet.RequiredSocketController}
		started := time.Now()
		conn, err := dialer.Dial("tcp", net.JoinHostPort(address.String(), strconv.Itoa(request.Port)))
		if err != nil {
			return nil, errors.New("ping_failed"), true
		}
		delay := time.Since(started).Milliseconds()
		conn.Close()
		return map[string]any{"delay": delay}, nil, true
	case "runXrayFromJson", "ping", "validateConfig":
		var request struct {
			AssetRevision string `json:"assetRevision"`
			PacketPath    bool   `json:"packetPath"`
		}
		if json.Unmarshal(payload, &request) != nil {
			return nil, errors.New("invalid_assets"), true
		}
		root, err := os.UserCacheDir()
		if err != nil {
			return nil, errors.New("assets_unavailable"), true
		}
		assets, err := readAssets(filepath.Join(root, "Elarni", "assets"), request.AssetRevision)
		if err != nil {
			return nil, err, true
		}
		if err = installAssets(assets); err != nil {
			return nil, err, true
		}
		if method == "ping" && !request.PacketPath {
			if bindPhysicalRoutes() != nil {
				return nil, errors.New("ping_failed"), true
			}
		}
		return nil, nil, false
	case "prepareRoutingAssets":
		var request assetRequest
		if json.Unmarshal(payload, &request) != nil {
			return nil, errors.New("invalid_assets"), true
		}
		root, err := os.UserCacheDir()
		if err != nil {
			return nil, errors.New("assets_unavailable"), true
		}
		data, err := prepareAssets(filepath.Join(root, "Elarni", "assets"), request, downloadAsset)
		return data, err, true
	case "acquireCatalog", "loadCatalog", "saveCatalog":
		root, err := os.UserCacheDir()
		if err != nil {
			return nil, errors.New("storage_unavailable"), true
		}
		root = filepath.Join(root, "Elarni")
		if method == "acquireCatalog" {
			catalogLease, err = acquireCatalog(root)
			return map[string]any{}, err, true
		}
		data, err := catalogOperation(root, method, payload)
		return data, err, true
	}
	return nil, nil, false
}

func acquireCatalog(root string) (*os.File, error) {
	if os.MkdirAll(root, 0700) != nil {
		return nil, errors.New("storage_unavailable")
	}
	file, err := os.OpenFile(filepath.Join(root, "session.lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, errors.New("storage_unavailable")
	}
	var overlap windows.Overlapped
	if windows.LockFileEx(windows.Handle(file.Fd()), windows.LOCKFILE_EXCLUSIVE_LOCK|windows.LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, &overlap) != nil {
		file.Close()
		return nil, errors.New("storage_busy")
	}
	// The OS releases this lock after parent EOF or any helper termination.
	return file, nil
}

func protectCatalog(data []byte, decrypt bool) ([]byte, error) {
	if len(data) == 0 || len(data) > maxMessage+4096 {
		return nil, errors.New("storage_corrupt")
	}
	in := windows.DataBlob{Size: uint32(len(data)), Data: &data[0]}
	var out windows.DataBlob
	var err error
	if decrypt {
		err = windows.CryptUnprotectData(&in, nil, nil, 0, nil, windows.CRYPTPROTECT_UI_FORBIDDEN, &out)
	} else {
		err = windows.CryptProtectData(&in, nil, nil, 0, nil, windows.CRYPTPROTECT_UI_FORBIDDEN, &out)
	}
	if err != nil {
		return nil, errors.New("storage_corrupt")
	}
	buffer := unsafe.Slice(out.Data, int(out.Size))
	result := bytes.Clone(buffer)
	clear(buffer)
	_, _ = windows.LocalFree(windows.Handle(unsafe.Pointer(out.Data)))
	return result, nil
}

func readCatalog(path string) (catalogEnvelope, error) {
	var envelope catalogEnvelope
	file, err := os.Open(path)
	if errors.Is(err, os.ErrNotExist) {
		return catalogEnvelope{Version: 1}, nil
	}
	if err != nil {
		return envelope, errors.New("storage_unavailable")
	}
	defer file.Close()
	encrypted, err := io.ReadAll(io.LimitReader(file, maxMessage+4097))
	if err != nil {
		return envelope, errors.New("storage_unavailable")
	}
	plain, err := protectCatalog(encrypted, true)
	if err != nil {
		return envelope, err
	}
	defer clear(plain)
	if json.Unmarshal(plain, &envelope) != nil || envelope.Version != 1 || len(envelope.Revision) != 64 ||
		!json.Valid(envelope.Catalog) || len(envelope.Catalog) == 0 || envelope.Catalog[0] != '{' {
		return catalogEnvelope{}, errors.New("storage_corrupt")
	}
	return envelope, nil
}

// The lock and revision comparison cover other app instances and sessions.
// Only ciphertext reaches the temporary file and atomic replacement.
func catalogOperation(root, method string, payload json.RawMessage) (any, error) {
	if err := os.MkdirAll(root, 0700); err != nil {
		return nil, errors.New("storage_unavailable")
	}
	lock, err := os.OpenFile(filepath.Join(root, "catalog.lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, errors.New("storage_unavailable")
	}
	defer lock.Close()
	var overlap windows.Overlapped
	if windows.LockFileEx(windows.Handle(lock.Fd()), windows.LOCKFILE_EXCLUSIVE_LOCK|windows.LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, &overlap) != nil {
		return nil, errors.New("storage_busy")
	}
	defer windows.UnlockFileEx(windows.Handle(lock.Fd()), 0, 1, 0, &overlap)
	path := filepath.Join(root, "catalog.dpapi")
	current, err := readCatalog(path)
	if err != nil {
		return nil, err // Never replace an unreadable catalog.
	}
	if method == "loadCatalog" {
		return current, nil
	}
	var incoming struct {
		Revision string          `json:"revision"`
		Catalog  json.RawMessage `json:"catalog"`
	}
	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&incoming) != nil || len(incoming.Catalog) > 12*1024*1024 ||
		len(incoming.Catalog) == 0 || incoming.Catalog[0] != '{' || !json.Valid(incoming.Catalog) {
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
	encrypted, err := protectCatalog(plain, false)
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
	if writeErr != nil || syncErr != nil || closeErr != nil {
		return nil, errors.New("storage_unavailable")
	}
	from, e1 := windows.UTF16PtrFromString(file.Name())
	to, e2 := windows.UTF16PtrFromString(path)
	if e1 != nil || e2 != nil || windows.MoveFileEx(from, to, windows.MOVEFILE_REPLACE_EXISTING|windows.MOVEFILE_WRITE_THROUGH) != nil {
		return nil, errors.New("storage_unavailable")
	}
	return map[string]any{"revision": current.Revision}, nil
}
