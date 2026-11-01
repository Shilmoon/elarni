package splithttp

import (
	"context"
	"errors"
	"io"
	gonet "net"
	"net/http"
	"strings"
	"testing"
	"time"
)

type failingClose struct{ io.Reader }

func (failingClose) Close() error { return errors.New("reader close failed") }

func TestSplitConnCloseReportsTheReaderError(t *testing.T) {
	_, writer := io.Pipe()
	conn := &splitConn{writer: writer, reader: failingClose{strings.NewReader("")}}
	if err := conn.Close(); err == nil || err.Error() != "reader close failed" {
		t.Fatalf("Close() = %v, want the reader's close error", err)
	}
}

// Stopping the core closes a client while its posts are still writing. An upload
// connection such a post returned afterwards stayed open with its reader.
func TestCloseShutsUploadConnectionsInUse(t *testing.T) {
	ours, theirs := gonet.Pipe()
	defer theirs.Close()
	client := &DefaultDialerClient{client: &http.Client{}, dialUploadConn: func(context.Context) (gonet.Conn, error) { return ours, nil }}
	conn, err := client.uploadConn(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	client.Close()
	client.putUploadConn(conn)
	theirs.SetReadDeadline(time.Now().Add(time.Second))
	if _, err := theirs.Read(make([]byte, 1)); err != io.EOF {
		t.Fatalf("the upload connection stayed open after Close: %v", err)
	}
	if _, err := client.uploadConn(context.Background()); err == nil {
		t.Fatal("a closed client dialed a new upload connection")
	}
}
