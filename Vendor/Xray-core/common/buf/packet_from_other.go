//go:build !unix

package buf

import (
	"errors"
	"net"
)

const pooledUDPReads = false

func readUDPFrom(*net.UDPConn) (*Buffer, net.Addr, error) {
	return nil, nil, errors.ErrUnsupported
}
