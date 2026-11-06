package quic

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"math/big"
	"net"
	"runtime"
	"testing"
	"time"
)

// unconnected is Xray's UDP dial result: an unconnected socket behind a net.Conn that writes to one peer.
type unconnected struct {
	net.Conn
	socket *net.UDPConn
	remote net.Addr
	conn   *Conn
}

func (c *unconnected) Write(p []byte) (int, error) { return c.socket.WriteTo(p, c.remote) }
func (c *unconnected) RemoteAddr() net.Addr        { return c.remote }
func (c *unconnected) PacketConn() net.PacketConn  { return c.socket }
func (c *unconnected) SetQUICConn(conn *Conn)      { c.conn = conn }

func selfSigned(t *testing.T) tls.Certificate {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.CreateCertificate(rand.Reader, &x509.Certificate{SerialNumber: big.NewInt(1), NotAfter: time.Now().Add(time.Hour)}, &x509.Certificate{}, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}
}

// Elarni: the TUIC client hid the socket in a wrapper, so quic-go read and sent one datagram per
// system call without GSO or ECN; the connected path that a syscall.Conn gets sends without an
// address, which the unconnected socket rejects.
func TestDialConnUsesTheSocketBehindAWrapper(t *testing.T) {
	ln, err := ListenAddr("127.0.0.1:0", &tls.Config{Certificates: []tls.Certificate{selfSigned(t)}, NextProtos: []string{"t"}}, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go ln.Accept(context.Background())
	socket, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4zero})
	if err != nil {
		t.Fatal(err)
	}
	defer socket.Close()
	c := &unconnected{Conn: socket, socket: socket, remote: ln.Addr()}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, err := DialConn(ctx, c, &tls.Config{InsecureSkipVerify: true, NextProtos: []string{"t"}}, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.CloseWithError(0, "")
	if c.conn != conn {
		t.Error("the conn's owner never learned its QUIC connection")
	}
	if capabilities := conn.conn.capabilities(); runtime.GOOS == "linux" && !(capabilities.GSO && capabilities.ECN) {
		t.Errorf("quic-go reached the socket without its offloads: %+v", capabilities)
	}
}
