//go:build linux && !android

package net

import (
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
)

// findInodeInFile matches one socket against a table file as a lookup batch does.
func findInodeInFile(path, local, remote string, udp bool) (string, error) {
	q := newSocketQuery(path, local, remote, udp)
	if err := scanTable(path, []*socketQuery{q}); err != nil {
		return "", err
	}
	if q.ambiguous {
		return "", errors.New("ambiguous socket ownership")
	}
	return q.inode, nil
}

func TestLinuxProcessLookupPeerAndAmbiguity(t *testing.T) {
	path := filepath.Join(t.TempDir(), "tcp")
	firstRow := "0: 0100007F:C000 010200C0:01BB 01 0:0 0:0 0 0 0 101\n"
	rows := firstRow +
		"1: 0100007F:C000 020200C0:01BB 01 0:0 0:0 0 0 0 102\n"
	if err := os.WriteFile(path, []byte(rows), 0600); err != nil {
		t.Fatal(err)
	}
	for remote, expected := range map[string]string{"010200C0:01BB": "101", "020200C0:01BB": "102", "030200C0:01BB": ""} {
		inode, err := findInodeInFile(path, "0100007F:C000", remote, false)
		if err != nil || inode != expected {
			t.Fatalf("%s: inode=%s err=%v", remote, inode, err)
		}
	}
	if _, err := findInodeInFile(path, "0100007F:C000", "", false); err == nil {
		t.Fatal("missing destination chose between ambiguous TCP sockets")
	}
	// A batch matches every lookup for a table in one pass; each keeps its own answer.
	shared := []*socketQuery{newSocketQuery(path, "0100007F:C000", "020200C0:01BB", false), newSocketQuery(path, "0100007F:C000", "010200C0:01BB", false), newSocketQuery(path, "0100007F:C001", "", false)}
	if err := scanTable(path, shared); err != nil || shared[0].inode != "102" || shared[1].inode != "101" || shared[2].inode != "" {
		t.Fatalf("one pass for three lookups: %q %q %q err=%v", shared[0].inode, shared[1].inode, shared[2].inode, err)
	}
	if err := os.WriteFile(path, []byte(firstRow), 0600); err != nil {
		t.Fatal(err)
	}
	if inode, err := findInodeInFile(path, "0100007F:C000", "", false); err != nil || inode != "101" {
		t.Fatalf("unique TCP socket without destination: inode=%s err=%v", inode, err)
	}
	rows = "0: 00000000:C000 00000000:0000 07 0:0 0:0 0 0 0 101\n" +
		"1: 00000000:C000 00000000:0000 07 0:0 0:0 0 0 0 102\n"
	if err := os.WriteFile(path, []byte(rows), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := findInodeInFile(path, "0100007F:C000", "010200C0:01BB", true); err == nil {
		t.Fatal("ambiguous wildcard sockets chose an arbitrary process")
	}
}

// Apps open many connections in a row. Once a process owned a socket, finding
// its next one must not readlink every open file on the host (14 ms at 10k fds).
func TestLinuxRecentOwnerSkipsTheFullScan(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	lookup := func() {
		t.Helper()
		client, err := net.Dial("tcp", listener.Addr().String())
		if err != nil {
			t.Fatal(err)
		}
		defer client.Close()
		local, remote := client.LocalAddr().(*net.TCPAddr), listener.Addr().(*net.TCPAddr)
		pid, _, _, err := FindProcess("tcp", "127.0.0.1", uint16(local.Port), "127.0.0.1", uint16(remote.Port))
		if err != nil || pid != os.Getpid() {
			t.Fatalf("pid=%d err=%v", pid, err)
		}
	}
	lookup()
	own, err := os.ReadDir("/proc/self/fd")
	if err != nil {
		t.Fatal(err)
	}
	reads := 0
	readLink = func(path string) (string, error) { reads++; return os.Readlink(path) }
	defer func() { readLink = os.Readlink }()
	lookup()
	// Our own descriptors, the new client socket, and the exe link.
	if reads > len(own)+2 {
		t.Fatalf("lookup read %d links; this process has %d descriptors", reads, len(own))
	}
}

// An unconnected application's UDP socket stays wildcard-bound in /proc even
// though its outgoing packet has the selected interface address.
func TestLinuxWildcardUDPProcess(t *testing.T) {
	for _, network := range []string{"udp4", "udp6"} {
		t.Run(network, func(t *testing.T) {
			ip := "127.0.0.1"
			if network == "udp6" {
				ip = "::1"
			}
			peer, err := net.ListenUDP(network, &net.UDPAddr{IP: net.ParseIP(ip)})
			if err != nil {
				t.Fatal(err)
			}
			defer peer.Close()
			client, err := net.ListenUDP(network, &net.UDPAddr{})
			if err != nil {
				t.Fatal(err)
			}
			defer client.Close()
			if _, err := client.WriteToUDP([]byte("fixture"), peer.LocalAddr().(*net.UDPAddr)); err != nil {
				t.Fatal(err)
			}
			pid, _, _, err := FindProcess("udp", ip, uint16(client.LocalAddr().(*net.UDPAddr).Port), ip, uint16(peer.LocalAddr().(*net.UDPAddr).Port))
			if err != nil || pid != os.Getpid() {
				t.Fatalf("pid=%d err=%v", pid, err)
			}
			pid, _, _, err = FindProcess("udp", ip, uint16(client.LocalAddr().(*net.UDPAddr).Port), "", 0)
			if err != nil || pid != os.Getpid() {
				t.Fatalf("UDP without destination: pid=%d err=%v", pid, err)
			}
		})
	}
}

// Java, .NET and Go open IPv6 sockets that also carry IPv4. Such a socket is listed only in the
// IPv6 table, bound to [::] or to the IPv4-mapped address, while its flow has IPv4 addresses.
func TestLinuxDualStackSocketProcess(t *testing.T) {
	t.Run("udp", func(t *testing.T) {
		peer, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
		if err != nil {
			t.Fatal(err)
		}
		defer peer.Close()
		client, err := net.ListenUDP("udp", &net.UDPAddr{})
		if err != nil {
			t.Fatal(err)
		}
		defer client.Close()
		if _, err := client.WriteToUDP([]byte("fixture"), peer.LocalAddr().(*net.UDPAddr)); err != nil {
			t.Skip("no dual-stack sockets here: ", err)
		}
		port := uint16(client.LocalAddr().(*net.UDPAddr).Port)
		pid, _, _, err := FindProcess("udp", "127.0.0.1", port, "127.0.0.1", uint16(peer.LocalAddr().(*net.UDPAddr).Port))
		if err != nil || pid != os.Getpid() {
			t.Fatalf("pid=%d err=%v", pid, err)
		}
	})
	t.Run("tcp", func(t *testing.T) {
		listener, err := net.Listen("tcp4", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		defer listener.Close()
		peerPort := listener.Addr().(*net.TCPAddr).Port
		fd, err := syscall.Socket(syscall.AF_INET6, syscall.SOCK_STREAM, 0)
		if err != nil {
			t.Skip("no IPv6 sockets here: ", err)
		}
		defer syscall.Close(fd)
		mapped := syscall.SockaddrInet6{Port: peerPort}
		copy(mapped.Addr[:], net.IPv4(127, 0, 0, 1).To16())
		if err := syscall.Connect(fd, &mapped); err != nil {
			t.Skip("no dual-stack sockets here: ", err)
		}
		local, err := syscall.Getsockname(fd)
		if err != nil {
			t.Fatal(err)
		}
		pid, _, _, err := FindProcess("tcp", "127.0.0.1", uint16(local.(*syscall.SockaddrInet6).Port), "127.0.0.1", uint16(peerPort))
		if err != nil || pid != os.Getpid() {
			t.Fatalf("pid=%d err=%v", pid, err)
		}
	})
}

type lookupResult struct {
	pid int
	err error
}

// findAsync looks up a local IPv4 socket on its own goroutine, as concurrent connections do.
func findAsync(network string, port, peerPort int) <-chan lookupResult {
	result := make(chan lookupResult, 1)
	go func() {
		pid, _, _, err := FindProcess(network, "127.0.0.1", uint16(port), "127.0.0.1", uint16(peerPort))
		result <- lookupResult{pid, err}
	}()
	return result
}

func awaitLookup(t *testing.T, result <-chan lookupResult, wantPID int) {
	t.Helper()
	select {
	case r := <-result:
		if r.err != nil || r.pid != wantPID {
			t.Fatalf("pid=%d err=%v, want pid %d", r.pid, r.err, wantPID)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("lookup did not return")
	}
}

type pausedTable struct {
	io.ReadCloser
	paused  chan<- struct{}
	release <-chan struct{}
}

func (p pausedTable) Close() error {
	close(p.paused)
	<-p.release
	return p.ReadCloser.Close()
}

// pauseTables counts table reads and holds the first one, after all its rows were read, until
// release is called: that batch's snapshot is taken while it still reads.
func pauseTables(t *testing.T) (opens *atomic.Int32, paused <-chan struct{}, release func()) {
	opens = new(atomic.Int32)
	pausedSignal, released := make(chan struct{}), make(chan struct{})
	original := openTable
	openTable = func(name string) (io.ReadCloser, error) {
		table, err := original(name)
		if err != nil || opens.Add(1) > 1 {
			return table, err
		}
		return pausedTable{table, pausedSignal, released}, nil
	}
	release = sync.OnceFunc(func() { close(released) })
	// TCP lookups find their socket without the table where the kernel answers by address.
	keyed := findTCPSocketInode
	findTCPSocketInode = func(netip.AddrPort, netip.AddrPort) (uint32, error) { return 0, nil }
	t.Cleanup(func() { openTable, findTCPSocketInode = original, keyed })
	t.Cleanup(release)
	return opens, pausedSignal, release
}

func awaitSignal(t *testing.T, signal <-chan struct{}, what string) {
	t.Helper()
	select {
	case <-signal:
	case <-time.After(10 * time.Second):
		t.Fatal(what, " did not happen")
	}
}

func awaitQueued(t *testing.T, n int) {
	t.Helper()
	for deadline := time.Now().Add(10 * time.Second); ; runtime.Gosched() {
		lookups.Lock()
		queued := len(lookups.next)
		lookups.Unlock()
		if queued == n {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("%d lookups queued, want %d", queued, n)
		}
	}
}

func setRecentOwners(t *testing.T, pids ...string) {
	recentOwners.Lock()
	saved := recentOwners.pids
	recentOwners.pids = pids
	recentOwners.Unlock()
	t.Cleanup(func() {
		recentOwners.Lock()
		recentOwners.pids = saved
		recentOwners.Unlock()
	})
}

func port(addr net.Addr) int {
	_, p, _ := net.SplitHostPort(addr.String())
	n, _ := strconv.Atoi(p)
	return n
}

// socketChild runs TestFindProcessChild, which holds a TCP and a UDP socket to address.
func socketChild(t *testing.T, address string) (pid, tcpPort, udpPort int) {
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(executable, "-test.run=^TestFindProcessChild$")
	cmd.Env = append(os.Environ(), "ELARNI_PROCESS_FIXTURE="+address)
	cmd.Stderr = os.Stderr
	out, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	in, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { in.Close(); cmd.Process.Kill(); cmd.Wait() })
	var sources []string
	if err := json.NewDecoder(out).Decode(&sources); err != nil || len(sources) != 2 {
		t.Fatalf("child sockets %v: %v", sources, err)
	}
	tcp, _ := net.ResolveTCPAddr("tcp", sources[0])
	udp, _ := net.ResolveUDPAddr("udp", sources[1])
	return cmd.Process.Pid, tcp.Port, udp.Port
}

// Elarni: each new connection of a burst read the whole socket table and walked the same descriptors.
// Lookups that queue behind a running batch share one read per table and one descriptor walk, each
// socket still gets its own process, and a socket of a recent owner does not wait while the batch
// walks every process for another app's socket.
// newestDescriptor returns this process's highest descriptor, other than the one listing them.
func newestDescriptor(t *testing.T) int {
	t.Helper()
	entries, err := os.ReadDir("/proc/self/fd")
	if err != nil {
		t.Fatal(err)
	}
	newest := -1
	for _, entry := range entries {
		fd, err := strconv.Atoi(entry.Name())
		if link, _ := os.Readlink("/proc/self/fd/" + entry.Name()); err == nil && fd > newest && !strings.HasSuffix(link, "/fd") {
			newest = fd
		}
	}
	return newest
}

func TestLinuxBurstSharesOneScanPerBatch(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	udpServer, err := net.ListenPacket("udp", listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer udpServer.Close()
	childPID, childTCP, childUDP := socketChild(t, listener.Addr().String())
	own := loopbackConns(t, 16)
	ownUDP, err := net.Dial("udp", udpServer.LocalAddr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer ownUDP.Close()

	self, child := strconv.Itoa(os.Getpid()), strconv.Itoa(childPID)
	setRecentOwners(t, self)
	opens, paused, release := pauseTables(t)
	var ownWalks atomic.Int32
	childReached, childWalk := make(chan struct{}), make(chan struct{})
	reachChild, unblockChild := sync.OnceFunc(func() { close(childReached) }), sync.OnceFunc(func() { close(childWalk) })
	newest := "/proc/" + self + "/fd/" + strconv.Itoa(newestDescriptor(t))
	readLink = func(path string) (string, error) {
		if path == newest {
			ownWalks.Add(1) // walks read the newest descriptors first
		}
		if strings.HasPrefix(path, "/proc/"+child+"/fd/") {
			reachChild()
			<-childWalk
		}
		return os.Readlink(path)
	}
	t.Cleanup(func() { readLink = os.Readlink })
	t.Cleanup(unblockChild)

	first := findAsync("tcp", port(own[0].LocalAddr()), port(own[0].RemoteAddr()))
	awaitSignal(t, paused, "the first table read")
	var ownResults []<-chan lookupResult
	for _, c := range own[1:] {
		ownResults = append(ownResults, findAsync("tcp", port(c.LocalAddr()), port(c.RemoteAddr())))
	}
	ownResults = append(ownResults, findAsync("udp", port(ownUDP.LocalAddr()), port(ownUDP.RemoteAddr())))
	childResults := []<-chan lookupResult{
		findAsync("tcp", childTCP, port(listener.Addr())),
		findAsync("udp", childUDP, port(listener.Addr())),
	}
	awaitQueued(t, len(ownResults)+len(childResults))
	release()

	awaitLookup(t, first, os.Getpid())
	for _, result := range ownResults {
		awaitLookup(t, result, os.Getpid()) // while the walk still waits at the child's descriptors
	}
	awaitSignal(t, childReached, "the walk through the child")
	unblockChild()
	for _, result := range childResults {
		awaitLookup(t, result, childPID)
	}
	if n := opens.Load(); n != 3 {
		t.Fatalf("%d table reads for 1 + %d lookups, want 3 (tcp, then tcp and udp once for the burst)", n, len(ownResults)+len(childResults))
	}
	if n := ownWalks.Load(); n != 2 {
		t.Fatalf("walked this process's descriptors %d times, want 2 (once per batch)", n)
	}
}

// A lookup that arrives while a batch still reads must not take that batch's answer: the table may
// have been read before its socket existed, and "not found" would skip the app's routing rule.
func TestLinuxLookupAfterASnapshotSeesItsSocket(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	early, err := net.Dial("tcp", listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer early.Close()
	_, paused, release := pauseTables(t)
	first := findAsync("tcp", port(early.LocalAddr()), port(listener.Addr()))
	awaitSignal(t, paused, "the first table read") // the batch has read every row and is still reading

	late, err := net.Dial("tcp", listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer late.Close()
	second := findAsync("tcp", port(late.LocalAddr()), port(listener.Addr()))
	awaitQueued(t, 1)
	release()
	awaitLookup(t, first, os.Getpid())
	awaitLookup(t, second, os.Getpid())
}

// The misses forget the owners of recent connections, so each lookup walks the descriptors.
func BenchmarkLinuxFindProcess(b *testing.B) {
	loopbackConns(b, 500)
	targets := loopbackConns(b, 64)
	forgetOwners := func() {
		recentOwners.Lock()
		recentOwners.pids = nil
		recentOwners.Unlock()
	}
	b.Run("single-miss", func(b *testing.B) {
		for b.Loop() {
			forgetOwners()
			lookupOwnConn(b, targets[0])
		}
	})
	b.Run("burst64-miss", func(b *testing.B) {
		for b.Loop() {
			forgetOwners()
			lookupBurst(b, targets)
		}
	})
}

// A package upgrade replaces the files of running programs; until such a program restarts,
// /proc/<pid>/exe reads "<path> (deleted)". Rules name the path, so the lookup drops the suffix.
func TestLinuxProcessOfAReplacedExecutable(t *testing.T) {
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	program, err := os.ReadFile(executable)
	if err != nil {
		t.Fatal(err)
	}
	app := filepath.Join(t.TempDir(), "upgraded-app")
	if err := os.WriteFile(app, program, 0o755); err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	cmd := exec.Command(app, "-test.run=^TestFindProcessChild$")
	cmd.Env = append(os.Environ(), "ELARNI_PROCESS_FIXTURE="+listener.Addr().String())
	cmd.Stderr = os.Stderr
	out, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	in, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { in.Close(); cmd.Process.Kill(); cmd.Wait() })
	var sources []string
	if err := json.NewDecoder(out).Decode(&sources); err != nil || len(sources) != 2 {
		t.Fatalf("child sockets %v: %v", sources, err)
	}
	// Upgrade it as dpkg does: the new file takes the old one's name.
	upgraded := app + ".dpkg-new"
	if err := os.WriteFile(upgraded, program, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(upgraded, app); err != nil {
		t.Fatal(err)
	}
	if link, _ := os.Readlink("/proc/" + strconv.Itoa(cmd.Process.Pid) + "/exe"); link != app+" (deleted)" {
		t.Fatalf("exe link %q, want the replaced form", link)
	}
	source, _ := net.ResolveTCPAddr("tcp", sources[0])
	pid, name, path, err := FindProcess("tcp", "127.0.0.1", uint16(source.Port), "127.0.0.1", uint16(port(listener.Addr())))
	if err != nil || pid != cmd.Process.Pid || name != "upgraded-app" || path != app {
		t.Fatalf("lookup pid=%d name=%q path=%q err=%v; want pid=%d %q", pid, name, path, err, cmd.Process.Pid, app)
	}
}

// A new connection's socket has the highest descriptor number, so its lookup reads only the
// newest descriptors, not every one the owner holds.
func TestLinuxLookupReadsTheNewestDescriptorsFirst(t *testing.T) {
	loopbackConns(t, 64)
	newest := loopbackConns(t, 1)[0] // the client; its accepted end is newer still
	setRecentOwners(t, strconv.Itoa(os.Getpid()))
	var reads atomic.Int32
	readLink = func(path string) (string, error) { reads.Add(1); return os.Readlink(path) }
	t.Cleanup(func() { readLink = os.Readlink })
	lookupOwnConn(t, newest)
	if n := reads.Load(); n > 4 { // the accepted end, the client, and the exe link
		t.Fatalf("the newest connection's lookup read %d links", n)
	}
}
