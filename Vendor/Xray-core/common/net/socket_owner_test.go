package net

import (
	"strconv"
	"testing"
	"time"
)

// androidLike answers as Elarni's Android finder: the UID while the socket exists,
// -1 with no error once it is gone.
type androidLike struct {
	owners map[uint16]int
	calls  int
}

func (a *androidLike) find(_, _ string, srcPort uint16, _ string, _ uint16) (int, string, string, error) {
	a.calls++
	uid, ok := a.owners[srcPort]
	if !ok {
		uid = -1
	}
	return uid, strconv.Itoa(uid), "", nil
}

func newOwners(now *time.Time) *socketOwners {
	return &socketOwners{entries: map[socketKey]socketOwner{}, now: func() time.Time { return *now }}
}

func TestSocketOwnerOfAClosedSocketIsTheOneLastFound(t *testing.T) {
	// A QUIC socket's first flow was routed while it existed; Vision refused it, and the
	// next datagrams' flow was routed after the app had closed the socket.
	now := time.Unix(1000, 0)
	owners, app := newOwners(&now), &androidLike{owners: map[uint16]int{40000: 10123}}
	if uid, _, _, _ := owners.find("udp", "198.51.100.253", 40000, "142.250.1.1", 443, app.find); uid != 10123 {
		t.Fatalf("live lookup gave %d", uid)
	}
	delete(app.owners, 40000)
	now = now.Add(5 * time.Second)
	uid, name, _, err := owners.find("udp", "198.51.100.253", 40000, "142.250.1.1", 443, app.find)
	if err != nil || uid != 10123 || name != "10123" {
		t.Fatalf("closed socket gave %d %q %v", uid, name, err)
	}
}

func TestSocketOwnerIsAskedAgainWhileTheSocketMayHaveChanged(t *testing.T) {
	now := time.Unix(1000, 0)
	owners, app := newOwners(&now), &androidLike{owners: map[uint16]int{40000: 10123}}
	owners.find("tcp", "198.51.100.253", 40000, "1.1.1.1", 443, app.find)
	// Another app took the port: a live answer wins over what was found before.
	app.owners[40000] = 10200
	now = now.Add(socketOwnerFresh)
	if uid, _, _, _ := owners.find("tcp", "198.51.100.253", 40000, "1.1.1.1", 443, app.find); uid != 10200 {
		t.Fatalf("reused port named %d", uid)
	}
	// Past the time a closed socket's owner is kept, nothing is named.
	delete(app.owners, 40000)
	now = now.Add(socketOwnerKept)
	if uid, _, _, _ := owners.find("tcp", "198.51.100.253", 40000, "1.1.1.1", 443, app.find); uid != -1 {
		t.Fatalf("expired owner named %d", uid)
	}
}

func TestSocketOwnerPrefetchedJustNowIsNotAskedTwice(t *testing.T) {
	now := time.Unix(1000, 0)
	owners, app := newOwners(&now), &androidLike{owners: map[uint16]int{40000: 10123}}
	owners.find("tcp", "198.51.100.253", 40000, "1.1.1.1", 443, app.find) // the TUN's prefetch
	now = now.Add(200 * time.Millisecond)                                 // routing after sniffing
	if uid, _, _, _ := owners.find("tcp", "198.51.100.253", 40000, "1.1.1.1", 443, app.find); uid != 10123 || app.calls != 1 {
		t.Fatalf("uid %d after %d lookups", uid, app.calls)
	}
}

func TestSocketOwnersKeepsSocketsApartAndStaysBounded(t *testing.T) {
	now := time.Unix(1000, 0)
	owners, app := newOwners(&now), &androidLike{owners: map[uint16]int{}}
	for port := range uint16(socketOwnerLimit + 100) {
		app.owners[port+1] = int(port) + 10000
		owners.find("udp", "198.51.100.253", port+1, "1.1.1.1", 443, app.find)
	}
	if n := len(owners.entries); n > socketOwnerLimit {
		t.Fatalf("%d entries", n)
	}
	// Same port over the other protocol is another socket.
	app.owners = map[uint16]int{}
	if uid, _, _, _ := owners.find("tcp", "198.51.100.253", socketOwnerLimit+100, "1.1.1.1", 443, app.find); uid != -1 {
		t.Fatalf("tcp socket named by a udp one: %d", uid)
	}
}

func TestSocketOwnerPrefetchWaitsForProcessRules(t *testing.T) {
	if SocketOwnerPrefetchWanted() {
		t.Fatal("prefetch on without process rules")
	}
	HoldSocketOwnerPrefetch(1)
	HoldSocketOwnerPrefetch(1)
	HoldSocketOwnerPrefetch(-1)
	if !SocketOwnerPrefetchWanted() {
		t.Fatal("prefetch off while a router has process rules")
	}
	HoldSocketOwnerPrefetch(-1)
	if SocketOwnerPrefetchWanted() {
		t.Fatal("prefetch on after the last router let go")
	}
}
