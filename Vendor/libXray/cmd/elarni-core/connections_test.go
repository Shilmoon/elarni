package main

import (
	"bufio"
	"encoding/json"
	"io"
	"testing"
	"time"

	"github.com/xtls/libxray/xray"
	"github.com/xtls/xray-core/app/dispatcher"
)

// A tunnel's elevated owner sends its core's connections in frames; the app gets them as an
// event of the tunnel session, and another core's list replaces the older one.
func TestRelayedConnectionsRideTheTunnelSession(t *testing.T) {
	relayedConnections = connectionsRelay{}
	t.Cleanup(func() { relayedConnections = connectionsRelay{} })
	relayedConnections.add(&xray.ConnectionsResult{Epoch: 1, Seq: 3, Connections: []dispatcher.RecentConnection{{Key: 1, Seq: 3}}})
	many := make([]dispatcher.RecentConnection, connectionsPerEvent+5)
	for i := range many {
		many[i] = dispatcher.RecentConnection{Key: uint64(i + 1), Seq: uint64(i + 1)}
	}
	relayedConnections.add(&xray.ConnectionsResult{Epoch: 2, Seq: uint64(len(many)), Connections: many})

	output, child := io.Pipe()
	defer output.Close()
	requests := make(chan string)
	closed := make(chan struct{})
	done := make(chan int, 1)
	go func() {
		done <- serveVPNSession(requests, closed, child, func(string) response { return response{} },
			func() bool { return true }, func() bool { return true }, true, true, xray.LastLogSeq())
	}()
	events := make(chan map[string]json.RawMessage, 4)
	go func() {
		scanner := bufio.NewScanner(output)
		scanner.Buffer(make([]byte, 1<<20), 1<<24)
		for scanner.Scan() {
			var event map[string]json.RawMessage
			if json.Unmarshal(scanner.Bytes(), &event) == nil {
				events <- event
			}
		}
	}()
	deadline := time.After(5 * time.Second)
	for {
		select {
		case event := <-events:
			if string(event["event"]) != `"connections"` {
				continue
			}
			var data xray.ConnectionsResult
			if err := json.Unmarshal(event["data"], &data); err != nil {
				t.Fatal(err)
			}
			if data.Epoch != 2 || len(data.Connections) != connectionsPerEvent || data.Connections[0].Key != 6 ||
				data.Seq != uint64(len(many)) {
				t.Fatalf("epoch %d seq %d, %d connections from %d", data.Epoch, data.Seq, len(data.Connections), data.Connections[0].Key)
			}
			if relayedConnections.take() != nil {
				t.Fatal("the event left entries behind")
			}
			close(closed)
			<-done
			return
		case <-deadline:
			t.Fatal("no connections event")
		}
	}
}
