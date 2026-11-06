//go:build android

package libXray

import (
	"bytes"
	"maps"

	"github.com/xtls/xray-core/common/platform/filesystem"
)

// Called under the probe startup lock. Core construction retains immutable
// geodata, so restore the active runtime's readers before requests run in parallel.
func prepareProbeAssets(directory *string) (func(), error) {
	if directory == nil {
		return nil, nil
	}
	androidAssets.RLock()
	previous, previousDirectory := androidAssets.files, androidAssets.directory
	androidAssets.RUnlock()
	if err := UseAndroidAssets(*directory); err != nil {
		return nil, err
	}
	return func() {
		androidAssets.Lock()
		changed := androidAssets.directory != previousDirectory && !maps.EqualFunc(androidAssets.files, previous, bytes.Equal)
		androidAssets.files, androidAssets.directory = previous, previousDirectory
		androidAssets.Unlock()
		if changed {
			// Matchers the probe built from its files must not serve the active route.
			filesystem.AssetGeneration.Add(1)
		}
	}, nil
}
