package dispatcher

import (
	"sort"
	"sync"
	"time"

	"github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/features/outbound"
	routing_session "github.com/xtls/xray-core/features/routing/session"
)

// Elarni: the connections view lists recent routing decisions with the app that routing found.
// Entries stay in this core's memory; the app is the lookup a process rule already made, so the
// list adds no lookup.

// RecentConnection is one routed connection. A connection re-entered through a loopback outbound
// (per-app rules that follow normal routing) is one entry, updated by its later decision.
type RecentConnection struct {
	// Key names the entry; Seq grows each time it changes.
	Key     uint64 `json:"key"`
	Seq     uint64 `json:"seq"`
	Time    int64  `json:"time"` // first decision, Unix milliseconds
	Network string `json:"network"`
	Host    string `json:"host"` // the routed domain, else the IP
	Port    uint16 `json:"port"`
	Inbound string `json:"inbound"`
	// The last decision's outbound and its kind: direct, block, proxy, dns or routing (re-entered).
	Outbound string `json:"outbound"`
	Kind     string `json:"kind"`
	// Tags of the rules that took it, in decision order; untagged rules are left out.
	Rules []string `json:"rules,omitempty"`
	// found, or unknown when the lookup failed (the "-1" rule's traffic); empty when no process
	// rule asked or the source is another host.
	Owner string `json:"owner,omitempty"`
	PID   int    `json:"pid,omitempty"`
	Name  string `json:"name,omitempty"`
	Path  string `json:"path,omitempty"`
	// The rule for the app when its path does not name it (a Flatpak, an AppImage, a service);
	// the reader sets it.
	App string `json:"app,omitempty"`
}

const recentCapacity = 500

type recentConnections struct {
	sync.Mutex
	epoch   int64
	seq     uint64
	key     uint64
	entries []RecentConnection // a ring; next is the oldest once full
	next    int
	// Re-entered connections waiting for their next decision, by session ID.
	reentered map[uint32]uint64
	kinds     map[string]string
}

func (r *recentConnections) reset() {
	r.Lock()
	defer r.Unlock()
	r.epoch = time.Now().UnixNano()
	r.seq, r.key, r.next = 0, 0, 0
	r.entries = nil
	r.reentered = map[uint32]uint64{}
	r.kinds = map[string]string{}
}

func (r *recentConnections) close() {
	r.Lock()
	defer r.Unlock()
	r.entries, r.reentered, r.kinds = nil, nil, nil
}

func (r *recentConnections) kind(handler outbound.Handler) string {
	tag := handler.Tag()
	if kind, ok := r.kinds[tag]; ok {
		return kind
	}
	kind := "proxy"
	if settings := handler.ProxySettings(); settings != nil {
		switch settings.Type {
		case "xray.proxy.freedom.Config":
			kind = "direct"
		case "xray.proxy.blackhole.Config":
			kind = "block"
		case "xray.proxy.loopback.Config":
			kind = "routing"
		case "xray.proxy.dns.Config":
			kind = "dns"
		}
	}
	r.kinds[tag] = kind
	return kind
}

// record notes one routing decision for a connection from an app (a valid source); traffic the
// core makes itself, such as DNS queries to servers, has none.
func (r *recentConnections) record(id uint32, link *routing_session.Context, destination net.Destination, handler outbound.Handler, rule string) {
	if link.Inbound == nil || !link.Inbound.Source.IsValid() {
		return
	}
	r.Lock()
	defer r.Unlock()
	if r.kinds == nil {
		return // before Start
	}
	r.seq++
	kind := r.kind(handler)
	if key, ok := r.reentered[id]; ok && id != 0 {
		delete(r.reentered, id)
		if entry := r.find(key); entry != nil {
			entry.Seq, entry.Outbound, entry.Kind = r.seq, handler.Tag(), kind
			if rule != "" {
				entry.Rules = append(entry.Rules, rule)
			}
			if domain := link.GetTargetDomain(); domain != "" {
				entry.Host = domain
			}
			if entry.Owner == "" {
				owner(entry, link)
			}
			if kind == "routing" {
				r.reentered[id] = key
			}
			return
		}
	}
	r.key++
	entry := RecentConnection{Key: r.key, Seq: r.seq, Time: time.Now().UnixMilli(), Network: destination.Network.SystemString(),
		Host: link.GetTargetDomain(), Port: uint16(destination.Port), Inbound: link.GetInboundTag(), Outbound: handler.Tag(), Kind: kind}
	if entry.Host == "" && destination.Address != nil {
		entry.Host = destination.Address.String()
	}
	if rule != "" {
		entry.Rules = []string{rule}
	}
	owner(&entry, link)
	if len(r.entries) < recentCapacity {
		r.entries = append(r.entries, entry)
	} else {
		if old := r.entries[r.next]; old.Kind == "routing" {
			for id, key := range r.reentered {
				if key == old.Key {
					delete(r.reentered, id)
				}
			}
		}
		r.entries[r.next] = entry
		r.next = (r.next + 1) % recentCapacity
	}
	if kind == "routing" && id != 0 {
		r.reentered[id] = entry.Key
	}
}

func (r *recentConnections) find(key uint64) *RecentConnection {
	// Keys grow in ring order, so the entry is at a known distance from the newest.
	if len(r.entries) == 0 || key > r.key || r.key-key >= uint64(len(r.entries)) {
		return nil
	}
	newest := len(r.entries) - 1
	if len(r.entries) == recentCapacity {
		newest = (r.next + recentCapacity - 1) % recentCapacity
	}
	index := (newest - int(r.key-key) + len(r.entries)) % len(r.entries)
	if r.entries[index].Key != key {
		return nil
	}
	return &r.entries[index]
}

func owner(entry *RecentConnection, link *routing_session.Context) {
	pid, name, path, err, ok := link.LookedUpProcess()
	switch {
	case !ok || err == net.ErrNotLocal:
	case err != nil || name == "-1": // Android names an owner it could not find "-1"
		entry.Owner = "unknown"
	default:
		entry.Owner, entry.PID, entry.Name, entry.Path = "found", pid, name, path
	}
}

// RecentConnections returns the entries changed after seq, oldest change first, with the epoch
// that names this core's list and the newest seq. A new core starts a new epoch.
func (d *DefaultDispatcher) RecentConnections(after uint64) (epoch int64, seq uint64, entries []RecentConnection) {
	r := &d.recent
	r.Lock()
	defer r.Unlock()
	for _, entry := range r.entries {
		if entry.Seq > after {
			entry.Rules = append([]string(nil), entry.Rules...)
			entries = append(entries, entry)
		}
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].Seq < entries[j].Seq })
	return r.epoch, r.seq, entries
}
