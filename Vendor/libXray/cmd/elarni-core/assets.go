package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"github.com/xtls/libxray/share"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"time"

	"github.com/xtls/libxray/geo"
	"github.com/xtls/xray-core/common/platform/filesystem"
)

var assetRevision = regexp.MustCompile(`^[a-f0-9]{64}$`)

type assetRequest struct {
	Previous  string            `json:"previous"`
	Files     map[string]string `json:"files"`
	Selectors []string          `json:"selectors"`
	// From Direct and Block rules and domestic DNS domains; see geo.Reduce.
	Optional []string `json:"optional"`
	Reduce   bool     `json:"reduce"`
	Refresh  bool     `json:"refresh"`
	File     string   `json:"file"`
}

// assetValidators are the ETag and Last-Modified a server sent with a stored original.
type assetValidators struct {
	ETag         string `json:"etag,omitempty"`
	LastModified string `json:"lastModified,omitempty"`
}

// assetFetch downloads url into the new file destination and reports whether it did: given the stored
// original's validators, false means that original is current.
type assetFetch func(url string, stored assetValidators, destination string) (bool, assetValidators, error)

func prepareAssets(root string, request assetRequest, fetch assetFetch) (any, error) {
	if len(request.Files) > 2 || len(request.Selectors)+len(request.Optional) > 65536 ||
		request.Previous != "" && !assetRevision.MatchString(request.Previous) ||
		request.File != "" && request.File != "geoip" && request.File != "geosite" {
		return nil, errors.New("invalid_assets")
	}
	for name, url := range request.Files {
		if name != "geoip" && name != "geosite" || len(url) > 8192 {
			return nil, errors.New("invalid_assets")
		}
	}
	if os.MkdirAll(root, 0700) != nil {
		return nil, errors.New("assets_unavailable")
	}
	var random [32]byte
	if _, err := rand.Read(random[:]); err != nil {
		return nil, errors.New("assets_unavailable")
	}
	revision := hex.EncodeToString(random[:])
	stage := filepath.Join(root, revision)
	if os.Mkdir(stage, 0700) != nil {
		return nil, errors.New("assets_unavailable")
	}
	complete := false
	defer func() {
		if !complete {
			os.RemoveAll(stage)
		}
	}()
	files := []map[string]any{}
	skipped := []string{}
	var missing geo.MissingError
	status := "disabled"
	if request.Reduce {
		status = "ready"
	}
	for _, name := range []string{"geoip", "geosite"} {
		url := request.Files[name]
		if url == "" {
			continue
		}
		// Originals stay on disk (Elarni): one may be far larger than the core's limit.
		original := filepath.Join(stage, name+".original.dat")
		var stored string
		var validators assetValidators
		if request.Previous != "" {
			stored = filepath.Join(root, request.Previous, name+".original.dat")
			validators = readAssetSource(filepath.Join(root, request.Previous, name+".source.json"), url)
			if info, err := os.Stat(stored); err != nil || !info.Mode().IsRegular() {
				stored = ""
			}
		}
		downloaded := false
		var err error
		if stored == "" {
			downloaded, validators, err = fetch(url, assetValidators{}, original)
		} else if request.Refresh && (request.File == "" || request.File == name) {
			var fresh assetValidators
			if downloaded, fresh, err = fetch(url, validators, original); downloaded {
				validators = fresh
			}
		}
		if err != nil {
			return nil, err
		}
		if !downloaded && copyAssetFile(stored, original) != nil {
			return nil, errors.New("assets_unavailable")
		}
		target := filepath.Join(stage, name+".dat")
		reduction, skips, err := geo.ReduceFile(name, original, target, request.Selectors, request.Optional, request.Reduce)
		var lacks geo.MissingError
		if errors.As(err, &lacks) {
			// Name the codes from both files at once.
			missing = append(missing, lacks...)
			continue
		}
		if err != nil && (err.Error() == "input_too_large" || err.Error() == "assets_unavailable") {
			return nil, err
		}
		if err != nil {
			return nil, errors.New("invalid_geodata")
		}
		skipped = append(skipped, skips...)
		if reduction == "fullFileFallback" {
			status = reduction
		}
		originalInfo, errOriginal := os.Stat(original)
		targetInfo, errTarget := os.Stat(target)
		if errOriginal != nil || errTarget != nil {
			return nil, errors.New("assets_unavailable")
		}
		if validators != (assetValidators{}) {
			source, _ := json.Marshal(assetSource{URL: url, assetValidators: validators})
			if writeAssetFile(filepath.Join(stage, name+".source.json"), source) != nil {
				return nil, errors.New("assets_unavailable")
			}
		}
		kind := "domain"
		if name == "geoip" {
			kind = "ip"
		}
		if geo.CountGeoData(stage, name, kind) != nil {
			return nil, errors.New("invalid_geodata")
		}
		// CountGeoData's result is the file, not the function's return value.
		counts, err := os.ReadFile(filepath.Join(stage, name+".json"))
		if err != nil || !json.Valid(counts) {
			return nil, errors.New("invalid_geodata")
		}
		files = append(files, map[string]any{"name": name, "source": url, "bytes": targetInfo.Size(),
			"originalBytes": originalInfo.Size(), "updatedAt": float64(time.Now().UnixMilli()) / 1000})
	}
	if len(missing) > 0 {
		return map[string]any{"missing": missing}, missing
	}
	if previous := filepath.Join(root, request.Previous); request.Previous != "" && sameAssetFiles(stage, previous) {
		// Retain the immutable revision when downloading/reducing produced identical data.
		revision = request.Previous
		// Only the validators may have changed; the core never reads them.
		for _, name := range []string{"geoip.source.json", "geosite.source.json"} {
			if os.Rename(filepath.Join(stage, name), filepath.Join(previous, name)) != nil {
				os.Remove(filepath.Join(previous, name))
			}
		}
	} else {
		complete = true
	}
	return map[string]any{"assetRevision": revision, "geofiles": files,
		"geofileStatus": "ready", "reductionStatus": status, "skippedGeodata": skipped}, nil
}

// assetSource is stored beside an original; its validators hold only for the link it came from.
type assetSource struct {
	URL string `json:"url"`
	assetValidators
}

func readAssetSource(path, url string) assetValidators {
	var source assetSource
	data, err := os.ReadFile(path)
	if err != nil || len(data) > 16*1024 || json.Unmarshal(data, &source) != nil || source.URL != url {
		return assetValidators{}
	}
	return source.assetValidators
}

func sameAssetFiles(first, second string) bool {
	for _, name := range []string{"geoip.dat", "geosite.dat", "geoip.original.dat", "geosite.original.dat"} {
		_, errA := os.Stat(filepath.Join(first, name))
		_, errB := os.Stat(filepath.Join(second, name))
		if errors.Is(errA, os.ErrNotExist) && errors.Is(errB, os.ErrNotExist) {
			continue
		}
		if !sameFile(filepath.Join(first, name), filepath.Join(second, name)) {
			return false
		}
	}
	return true
}

// sameFile compares two files a chunk at a time; an original may be far larger than the core's limit.
func sameFile(first, second string) bool {
	a, errA := os.Open(first)
	b, errB := os.Open(second)
	if errA == nil {
		defer a.Close()
	}
	if errB == nil {
		defer b.Close()
	}
	if errA != nil || errB != nil {
		return false
	}
	infoA, errA := a.Stat()
	infoB, errB := b.Stat()
	if errA != nil || errB != nil || infoA.Size() != infoB.Size() {
		return false
	}
	bufA, bufB := make([]byte, 64<<10), make([]byte, 64<<10)
	for {
		n, errA := io.ReadFull(a, bufA)
		m, errB := io.ReadFull(b, bufB)
		if n != m || !bytes.Equal(bufA[:n], bufB[:m]) {
			return false
		}
		if errA != nil || errB != nil {
			// ReadFull reports a short last chunk as ErrUnexpectedEOF and none as EOF.
			return errA == errB && (errA == io.EOF || errA == io.ErrUnexpectedEOF)
		}
	}
}

// copyAssetFile copies a stored original into a staged revision.
func copyAssetFile(source, target string) error {
	in, err := os.Open(source)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(target, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	_, copyErr := io.Copy(out, in)
	syncErr := out.Sync()
	return errors.Join(copyErr, syncErr, out.Close())
}

func writeAssetFile(path string, data []byte) error {
	file, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	_, writeErr := file.Write(data)
	syncErr := file.Sync()
	closeErr := file.Close()
	return errors.Join(writeErr, syncErr, closeErr)
}

func retireAssets(root string, keep []string) error {
	if len(keep) > 256 {
		return errors.New("invalid_assets")
	}
	retained := map[string]bool{}
	for _, revision := range keep {
		if !assetRevision.MatchString(revision) {
			return errors.New("invalid_assets")
		}
		retained[revision] = true
	}
	entries, err := os.ReadDir(root)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return errors.New("assets_unavailable")
	}
	for _, entry := range entries {
		if !entry.IsDir() || entry.Type()&os.ModeSymlink != 0 || !assetRevision.MatchString(entry.Name()) || retained[entry.Name()] {
			continue
		}
		if os.RemoveAll(filepath.Join(root, entry.Name())) != nil {
			return errors.New("assets_unavailable")
		}
	}
	return nil
}

func readAssetFile(path string) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, errors.New("assets_unavailable")
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, 64*1024*1024+1))
	if err != nil || len(data) > 64*1024*1024 {
		return nil, errors.New("invalid_geodata")
	}
	return data, nil
}

func readAssets(root, revision string) (map[string][]byte, error) {
	result := map[string][]byte{}
	if revision == "" {
		return result, nil
	}
	if !assetRevision.MatchString(revision) {
		return nil, errors.New("invalid_assets")
	}
	// A route names a revision only after its files were prepared; without it the
	// core would start and then fail on the first geodata rule.
	if _, err := os.Stat(filepath.Join(root, revision)); errors.Is(err, os.ErrNotExist) {
		return nil, errors.New("assets_missing")
	}
	for _, name := range []string{"geoip", "geosite"} {
		path := filepath.Join(root, revision, name+".dat")
		if _, err := os.Stat(path); errors.Is(err, os.ErrNotExist) {
			continue
		}
		data, err := readAssetFile(path)
		if err != nil {
			return nil, err
		}
		if _, _, _, err = geo.Reduce(name, data, nil, nil, false); err != nil {
			return nil, errors.New("invalid_geodata")
		}
		result[name+".dat"] = data
	}
	return result, nil
}

func installAssets(assets map[string][]byte) error {
	if len(assets) > 2 {
		return errors.New("invalid_assets")
	}
	for name, data := range assets {
		kind := ""
		if name == "geoip.dat" {
			kind = "geoip"
		}
		if name == "geosite.dat" {
			kind = "geosite"
		}
		if _, _, _, err := geo.Reduce(kind, data, nil, nil, false); err != nil {
			return errors.New("invalid_geodata")
		}
	}
	filesystem.NewAssetReader = func(name string) (io.ReadCloser, error) {
		data, found := assets[name]
		if !found {
			return nil, errors.New("asset_unavailable")
		}
		return filesystem.MemoryAsset{Reader: bytes.NewReader(data)}, nil
	}
	// Parsed-geodata caches key on this; a reused helper serves each route's own files.
	filesystem.AssetGeneration.Add(1)
	return nil
}

func downloadAsset(url string, stored assetValidators, destination string) (bool, assetValidators, error) {
	result, err := share.FetchResourceToFile(context.Background(), share.SubscriptionFetchRequest{URL: url, ETag: stored.ETag, LastModified: stored.LastModified}, geo.MaxSourceBytes, 180*time.Second, destination)
	if err != nil {
		return false, assetValidators{}, err
	}
	value := result.(map[string]any)
	if value["warning"] != nil {
		return false, assetValidators{}, errors.New("approval_required")
	}
	if value["notModified"] == true {
		return false, stored, nil
	}
	etag, _ := value["etag"].(string)
	modified, _ := value["lastModified"].(string)
	return true, assetValidators{ETag: etag, LastModified: modified}, nil
}
