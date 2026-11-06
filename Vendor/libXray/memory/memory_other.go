//go:build !ios

package memory

import "sync"

var initForceFreeOnce sync.Once

// InitForceFree returns pooled buffers to the system when the core goes idle (Elarni).
func InitForceFree() {
	initForceFreeOnce.Do(func() { go releaseWhenIdle() })
}
