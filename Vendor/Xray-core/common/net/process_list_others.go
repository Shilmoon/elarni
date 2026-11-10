//go:build !(linux && !android) && !windows && !(darwin && !ios)

package net

import "github.com/xtls/xray-core/common/errors"

func ListProcesses() ([]Process, error) {
	return nil, errors.New("process listing is not supported on this platform")
}
