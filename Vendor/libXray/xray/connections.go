package xray

import (
	"errors"

	"github.com/xtls/xray-core/app/dispatcher"
	"github.com/xtls/xray-core/features/routing"
)

// ConnectionsResult is the running core's recent connections that changed after a seq (Elarni:
// the connections view). Epoch names the core's list; a reader with another epoch gets them all.
type ConnectionsResult struct {
	Epoch       int64                         `json:"epoch"`
	Seq         uint64                        `json:"seq"`
	Connections []dispatcher.RecentConnection `json:"connections"`
}

func ReadConnections(epoch int64, after uint64) (ConnectionsResult, error) {
	coreServerMu.Lock()
	defer coreServerMu.Unlock()
	if coreServer == nil {
		return ConnectionsResult{}, errors.New("xray is not running")
	}
	recent, ok := coreServer.GetFeature(routing.DispatcherType()).(*dispatcher.DefaultDispatcher)
	if !ok {
		return ConnectionsResult{}, errors.New("connections_unavailable")
	}
	current, seq, entries := recent.RecentConnections(after)
	if current != epoch {
		current, seq, entries = recent.RecentConnections(0)
	}
	if entries == nil {
		entries = []dispatcher.RecentConnection{}
	}
	return ConnectionsResult{Epoch: current, Seq: seq, Connections: entries}, nil
}
