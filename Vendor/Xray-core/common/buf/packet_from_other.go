//go:build !unix && !windows

package buf

import (
	"errors"
	"net"
)

const pooledUDPReads = false

func readUDPFrom(*net.UDPConn, *[]byte) (*Buffer, net.Addr, error) {
	return nil, nil, errors.ErrUnsupported
}
