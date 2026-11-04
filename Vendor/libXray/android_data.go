//go:build android

package libXray

import (
	"bytes"
	"encoding/json"
	"errors"
	"image"
	_ "image/gif"
	_ "image/jpeg"
	_ "image/png"
	"io"
	"maps"
	"os"
	"path/filepath"
	"sync"

	"github.com/makiuchi-d/gozxing"
	"github.com/makiuchi-d/gozxing/qrcode"
	"github.com/xtls/libxray/geo"
	"github.com/xtls/xray-core/common/platform/filesystem"
)

// DecodeAndroidQRImage uses the same decoder and bounds as the desktop helper.
func DecodeAndroidQRImage(data []byte) (string, error) {
	if len(data) > 8*1024*1024 {
		return "", errors.New("invalid_qr_image")
	}
	config, _, err := image.DecodeConfig(bytes.NewReader(data))
	if err != nil || config.Width <= 0 || config.Height <= 0 || config.Width > 8192 || config.Height > 8192 || int64(config.Width)*int64(config.Height) > 16*1024*1024 {
		return "", errors.New("invalid_qr_image")
	}
	decoded, _, err := image.Decode(bytes.NewReader(data))
	if err != nil {
		return "", errors.New("invalid_qr_image")
	}
	bitmap, err := gozxing.NewBinaryBitmapFromImage(decoded)
	if err != nil {
		return "", errors.New("invalid_qr_image")
	}
	result, err := qrcode.NewQRCodeReader().Decode(bitmap, map[gozxing.DecodeHintType]interface{}{gozxing.DecodeHintType_TRY_HARDER: true})
	if err != nil {
		result, err = qrcode.NewQRCodeReader().Decode(bitmap, map[gozxing.DecodeHintType]interface{}{gozxing.DecodeHintType_PURE_BARCODE: true})
	}
	if err != nil || len(result.GetText()) == 0 || len(result.GetText()) > 4*1024*1024 {
		return "", errors.New("invalid_qr_image")
	}
	return result.GetText(), nil
}

// ReduceAndroidGeoFile writes the reduced copy of the downloaded geofile at source to the new
// file target, one record at a time (see geo.ReduceFile). The result names missing required
// codes instead of failing, so the caller can show them; other failures are their error codes.
func ReduceAndroidGeoFile(name, source, target, selectorsJSON, optionalJSON string, reduce bool) (string, error) {
	var selectors, optional []string
	if len(selectorsJSON)+len(optionalJSON) > 4*1024*1024 || json.Unmarshal([]byte(selectorsJSON), &selectors) != nil ||
		json.Unmarshal([]byte(optionalJSON), &optional) != nil || len(selectors)+len(optional) > 65536 {
		return "", errors.New("invalid_assets")
	}
	status, skipped, err := geo.ReduceFile(name, source, target, selectors, optional, reduce)
	var missing geo.MissingError
	if errors.As(err, &missing) {
		encoded, err := json.Marshal(map[string]any{"missing": missing})
		return string(encoded), err
	}
	if err != nil {
		return "", err
	}
	encoded, err := json.Marshal(map[string]any{"status": status, "skipped": skipped})
	return string(encoded), err
}

var androidAssets struct {
	sync.RWMutex
	once  sync.Once
	files map[string][]byte
}

// Called by the serialized Android native owner before config compilation or
// startup. Readers retain immutable bytes; no config can name arbitrary files.
func UseAndroidAssets(directory string) error {
	files := map[string][]byte{}
	if directory != "" {
		for _, name := range []string{"geoip", "geosite"} {
			file, err := os.Open(filepath.Join(directory, name+".dat"))
			if os.IsNotExist(err) {
				continue
			}
			if err != nil {
				return errors.New("assets_unavailable")
			}
			data, readErr := io.ReadAll(io.LimitReader(file, 64*1024*1024+1))
			_ = file.Close()
			if readErr != nil {
				return errors.New("assets_unavailable")
			}
			if _, _, _, err := geo.Reduce(name, data, nil, nil, false); err != nil {
				return errors.New("invalid_geodata")
			}
			files[name+".dat"] = data
		}
	}
	androidAssets.Lock()
	changed := !maps.EqualFunc(androidAssets.files, files, bytes.Equal)
	androidAssets.files = files
	androidAssets.Unlock()
	if changed {
		// Parsed-geodata caches key on this; each route serves its own files.
		filesystem.AssetGeneration.Add(1)
	}
	androidAssets.once.Do(func() {
		filesystem.NewAssetReader = func(name string) (io.ReadCloser, error) {
			androidAssets.RLock()
			data, found := androidAssets.files[name]
			androidAssets.RUnlock()
			if !found {
				return nil, errors.New("asset_unavailable")
			}
			return filesystem.MemoryAsset{Reader: bytes.NewReader(data)}, nil
		}
	})
	return nil
}
