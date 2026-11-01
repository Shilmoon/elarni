package filesystem

import (
	"bytes"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"

	"github.com/xtls/xray-core/common/buf"
	"github.com/xtls/xray-core/common/platform"
)

type FileReaderFunc func(path string) (io.ReadCloser, error)

// NewAssetReader optionally supplies logical, memory-backed assets to embedded
// runtimes. Set before starting the core; filesystem behavior is the default.
// Its readers report their size, as MemoryAsset does: the geodata loader bounds entries by it.
var NewAssetReader FileReaderFunc

// AssetGeneration identifies the content NewAssetReader serves. Whoever swaps
// that content under the same names advances it.
var AssetGeneration atomic.Uint64

// MemoryAsset serves an in-memory asset through NewAssetReader without copying it.
type MemoryAsset struct{ *bytes.Reader }

func (MemoryAsset) Close() error { return nil }

var NewFileReader FileReaderFunc = func(path string) (io.ReadCloser, error) {
	return os.Open(path)
}

func ReadFile(path string) ([]byte, error) {
	reader, err := NewFileReader(path)
	if err != nil {
		return nil, err
	}
	defer reader.Close()

	return buf.ReadAllToBytes(reader)
}

func ReadAsset(file string) ([]byte, error) {
	reader, _, err := OpenAsset(file)
	if err != nil {
		return nil, err
	}
	defer reader.Close()
	return buf.ReadAllToBytes(reader)
}

func OpenAsset(file string) (io.ReadCloser, int64, error) {
	if NewAssetReader != nil {
		reader, err := NewAssetReader(file)
		if err != nil {
			return nil, 0, err
		}
		sized, ok := reader.(interface{ Size() int64 })
		if !ok {
			reader.Close()
			return nil, 0, errors.New("asset reader does not report its size")
		}
		return reader, sized.Size(), nil
	}
	path, info, err := getAssetFileLocation(file)
	if err != nil {
		return nil, 0, err
	}
	r, err := NewFileReader(path)
	return r, info.Size(), err
}

// AssetVersion identifies the content an asset name serves now, for caches of
// parsed assets: apps replace reduced geofiles under the same names per route.
func AssetVersion(file string) string {
	if NewAssetReader != nil {
		return strconv.FormatUint(AssetGeneration.Load(), 10)
	}
	if _, info, err := getAssetFileLocation(file); err == nil {
		return strconv.FormatInt(info.ModTime().UnixNano(), 10) + "/" + strconv.FormatInt(info.Size(), 10)
	}
	return ""
}

func StatAsset(file string) (os.FileInfo, error) {
	_, info, err := getAssetFileLocation(file)
	return info, err
}

func ResolveAsset(file string) (string, error) {
	path, _, err := getAssetFileLocation(file)
	return path, err
}

func getAssetFileLocation(file string) (string, os.FileInfo, error) {
	if !filepath.IsLocal(file) || file == "." {
		return "", nil, errors.New("asset path must stay in asset directory")
	}
	local, err := filepath.Localize(file)
	if err != nil {
		return "", nil, err
	}
	path := platform.GetAssetLocation(local)
	info, err := os.Stat(path)
	if err != nil {
		return "", nil, err
	}
	if !info.Mode().IsRegular() {
		return "", nil, errors.New("asset is not a regular file")
	}
	return path, info, nil
}

func ReadCert(file string) ([]byte, error) {
	if filepath.IsAbs(file) {
		return ReadFile(file)
	}
	return ReadFile(platform.GetCertLocation(file))
}

// ResolveLuaFile finds a local .lua script and returns its absolute path.
// Relative paths: XRAY_LOCATION_CONFDIR > XRAY_LOCATION_CONFIG > working dir > executable dir.
func ResolveLuaFile(path string) (string, error) {
	if !strings.EqualFold(filepath.Ext(path), ".lua") {
		return "", errors.New("Lua file extension must be .lua")
	}
	if filepath.IsAbs(path) {
		return path, nil
	}
	for _, dir := range []string{
		platform.GetConfDirPath(),
		platform.NewEnvFlag(platform.ConfigLocation).GetValue(func() string { return "" }),
		".",
		platform.GetExecutableDir(),
	} {
		if dir != "" {
			resolved := filepath.Join(dir, path)
			if _, err := os.Stat(resolved); err == nil {
				return filepath.Abs(resolved)
			} else if !os.IsNotExist(err) {
				return "", err
			}
		}
	}
	return "", os.ErrNotExist
}
