//go:build !android

package libXray

import "errors"

func prepareProbeAssets(directory *string) (func(), error) {
	if directory != nil {
		return nil, errors.New("invalid_probe_assets")
	}
	return nil, nil
}
