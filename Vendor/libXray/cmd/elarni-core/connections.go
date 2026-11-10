package main

import (
	"sync"

	"github.com/xtls/libxray/xray"
	"github.com/xtls/xray-core/app/dispatcher"
)

// Elarni: the connections view's entries ride the event stream with metrics and logs. A tunnel's
// elevated owner sends its core's entries in its frames; the relay keeps them for the next event.

// connectionsPerEvent bounds an event; the core keeps no more than this either.
const connectionsPerEvent = 500

// connectionsCursor follows one core's list.
type connectionsCursor struct {
	epoch int64
	seq   uint64
}

// read returns the entries that changed since the last read, or nil.
func (c *connectionsCursor) read() *xray.ConnectionsResult {
	result, err := xray.ReadConnections(c.epoch, c.seq)
	if err != nil {
		return nil
	}
	c.epoch, c.seq = result.Epoch, result.Seq
	if len(result.Connections) == 0 {
		return nil
	}
	return &result
}

type connectionsRelay struct {
	sync.Mutex
	epoch   int64
	entries []dispatcher.RecentConnection
}

var relayedConnections connectionsRelay

// add keeps a tunnel owner's entries; another core's entries replace the older core's.
func (r *connectionsRelay) add(result *xray.ConnectionsResult) {
	if result == nil {
		return
	}
	r.Lock()
	defer r.Unlock()
	if result.Epoch != r.epoch {
		r.epoch, r.entries = result.Epoch, nil
	}
	r.entries = append(r.entries, result.Connections...)
	if extra := len(r.entries) - connectionsPerEvent; extra > 0 {
		r.entries = append([]dispatcher.RecentConnection(nil), r.entries[extra:]...)
	}
}

func (r *connectionsRelay) take() *xray.ConnectionsResult {
	r.Lock()
	defer r.Unlock()
	if len(r.entries) == 0 {
		return nil
	}
	result := &xray.ConnectionsResult{Epoch: r.epoch, Seq: r.entries[len(r.entries)-1].Seq, Connections: r.entries}
	r.entries = nil
	return result
}

// connectionsEvent carries a tunnel owner's relayed entries, else those of the core running here.
func connectionsEvent(cursor *connectionsCursor) any {
	result := relayedConnections.take()
	if result == nil {
		result = cursor.read()
	}
	if result == nil {
		return nil
	}
	return map[string]any{"event": "connections", "data": result}
}
