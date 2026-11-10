package net

import (
	"sync"
	"sync/atomic"
	"time"
)

// Elarni: Android names only the owner of a socket that still exists, and routing
// asks after sniffing, up to 200 ms after the flow's first packet. By then a QUIC
// socket whose flows a Vision server refuses at once has often closed, and so has
// a TCP connection the app gave up on; their flows had no app and missed per-app
// rules. socketOwners remembers what each socket was found to be.
type socketOwners struct {
	mu      sync.Mutex
	entries map[socketKey]socketOwner
	now     func() time.Time
}

type socketKey struct {
	network, ip string
	port        uint16
}

type socketOwner struct {
	pid  int
	name string
	at   time.Time
}

const (
	// An owner found this recently, by the TUN's prefetch, is used without asking again.
	socketOwnerFresh = 2 * time.Second
	// A socket that is gone keeps the owner it last had this long; a live answer wins.
	socketOwnerKept  = 30 * time.Second
	socketOwnerLimit = 4096
)

type socketFinder func(network, srcIP string, srcPort uint16, destIP string, destPort uint16) (int, string, string, error)

func (s *socketOwners) find(network, srcIP string, srcPort uint16, destIP string, destPort uint16, live socketFinder) (int, string, string, error) {
	key := socketKey{network, srcIP, srcPort}
	s.mu.Lock()
	known, ok := s.entries[key]
	s.mu.Unlock()
	if ok && s.now().Sub(known.at) < socketOwnerFresh {
		return known.pid, known.name, "", nil
	}
	pid, name, path, err := live(network, srcIP, srcPort, destIP, destPort)
	if err == nil && pid >= 0 {
		s.remember(key, socketOwner{pid, name, s.now()})
		return pid, name, path, nil
	}
	if ok && s.now().Sub(known.at) < socketOwnerKept {
		return known.pid, known.name, "", nil
	}
	return pid, name, path, err
}

func (s *socketOwners) remember(key socketKey, owner socketOwner) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.entries) >= socketOwnerLimit {
		for k, e := range s.entries {
			if owner.at.Sub(e.at) >= socketOwnerKept {
				delete(s.entries, k)
			}
		}
		if len(s.entries) >= socketOwnerLimit {
			clear(s.entries) // a burst beyond the limit costs only the closed-socket fallback
		}
	}
	s.entries[key] = owner
}

var socketOwnerPrefetchers atomic.Int32

// HoldSocketOwnerPrefetch counts routers with process rules; while one has them,
// the TUN looks up each new flow's owner as it arrives (PrefetchSocketOwner).
func HoldSocketOwnerPrefetch(delta int32) { socketOwnerPrefetchers.Add(delta) }

func SocketOwnerPrefetchWanted() bool { return socketOwnerPrefetchers.Load() > 0 }
