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
	previous := androidAssets.files
	androidAssets.RUnlock()
	if err := UseAndroidAssets(*directory); err != nil {
		return nil, err
	}
	return func() {
		androidAssets.Lock()
		changed := !maps.EqualFunc(androidAssets.files, previous, bytes.Equal)
		androidAssets.files = previous
		androidAssets.Unlock()
		if changed {
			// Matchers the probe built from its files must not serve the active route.
			filesystem.AssetGeneration.Add(1)
		}
	}, nil
}
