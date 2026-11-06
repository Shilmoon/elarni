//go:build linux && !android

package net

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"io"
	"net"
	"os"
	"slices"
	"strconv"
	"strings"
	"sync"

	"github.com/xtls/xray-core/common/errors"
)

func FindProcess(network, srcIP string, srcPort uint16, destIP string, destPort uint16) (PID int, Name string, AbsolutePath string, err error) {
	isLocal, err := IsLocal(net.ParseIP(srcIP))
	if err != nil {
		return 0, "", "", errors.New("failed to determine if address is local: ", err)
	}
	if !isLocal {
		return 0, "", "", ErrNotLocal
	}
	if network != "tcp" && network != "udp" {
		return 0, "", "", errors.New("unsupported network for process lookup")
	}

	var procFile string

	switch network {
	case "tcp":
		if net.ParseIP(srcIP).To4() != nil {
			procFile = "/proc/net/tcp"
		} else {
			procFile = "/proc/net/tcp6"
		}
	case "udp":
		if net.ParseIP(srcIP).To4() != nil {
			procFile = "/proc/net/udp"
		} else {
			procFile = "/proc/net/udp6"
		}
	default:
		panic("Unsupported network type for process lookup.")
	}

	targetHexAddr, err := formatLittleEndianString(net.ParseIP(srcIP), Port(srcPort))
	if err != nil {
		return 0, "", "", errors.New("failed to format address: ", err)
	}

	remote := ""
	if destIP != "" && destPort != 0 {
		remote, err = formatLittleEndianString(net.ParseIP(destIP), Port(destPort))
		if err != nil {
			return 0, "", "", err
		}
	}
	q := newSocketQuery(procFile, targetHexAddr, remote, network == "udp")
	lookupSocket(q)
	if q.err != nil {
		return 0, "", "", q.err
	}
	if q.inode == "" {
		return 0, "", "", errors.New("connection for ", srcIP, ":", srcPort, " not found in ", procFile)
	}
	pidStr := q.pid
	if pidStr == "" {
		return 0, "", "", errors.New("no process found for inode ", q.inode)
	}

	absPath, err := getAbsPath(pidStr)
	if err != nil {
		return 0, "", "", errors.New("could not get process name for PID ", pidStr, ":", err)
	}

	nameSplit := strings.Split(absPath, "/")
	procName := nameSplit[len(nameSplit)-1]

	pid, err := strconv.Atoi(pidStr)
	if err != nil {
		return 0, "", "", errors.New("failed to parse PID: ", err)
	}

	return pid, procName, absPath, nil
}

func formatLittleEndianString(addr net.IP, port Port) (string, error) {
	ip := addr
	var ipBytes []byte
	if ip.To4() != nil {
		ipBytes = ip.To4()
	} else {
		ipBytes = ip.To16()
	}
	if ipBytes == nil {
		return "", errors.New("invalid IP format for ", addr, ": ", ip)
	}

	// procfs prints each native-endian uint32 separately, including IPv6.
	// Copy first: net.IP.To4/To16 may alias the caller's address.
	ipBytes = append([]byte(nil), ipBytes...)
	for i := 0; i < len(ipBytes); i += 4 {
		binary.NativeEndian.PutUint32(ipBytes[i:i+4], binary.BigEndian.Uint32(ipBytes[i:i+4]))
	}
	portHex := fmt.Sprintf("%04X", uint16(port))
	ipHex := strings.ToUpper(hex.EncodeToString(ipBytes))
	return fmt.Sprintf("%s:%s", ipHex, portHex), nil
}

// socketQuery is one lookup's socket. Its batch fills in inode and pid, then closes done.
type socketQuery struct {
	file, local, remote   string
	wildLocal, wildRemote string
	port                  []byte // ":PORT " of the local address, to skip other rows cheaply
	udp                   bool
	done                  chan struct{}

	best      int
	ambiguous bool
	inode     string
	pid       string
	err       error
}

func newSocketQuery(file, local, remote string, udp bool) *socketQuery {
	colon := strings.IndexByte(local, ':')
	wildcard := strings.Repeat("0", colon)
	return &socketQuery{
		file: file, local: local, remote: remote, udp: udp,
		wildLocal: wildcard + local[colon:], wildRemote: wildcard + ":0000",
		port: []byte(local[colon:] + " "), best: -1, done: make(chan struct{}),
	}
}

// match scores one /proc/net row: the exact local address beats a wildcard UDP bind, and the exact
// peer beats an unconnected UDP socket. Two sockets with the best score make the owner ambiguous.
func (q *socketQuery) match(fields []string) {
	if len(fields) < 10 {
		return
	}
	localAddress, remoteAddress := fields[1], fields[2]
	score := 0
	if localAddress == q.local {
		score += 2
	} else if !q.udp || localAddress != q.wildLocal {
		return
	}
	if q.remote != "" {
		if remoteAddress == q.remote {
			score++
		} else if !q.udp || remoteAddress != q.wildRemote {
			return
		}
	}
	if fields[9] == "0" {
		return
	}
	if score > q.best {
		q.best, q.inode, q.ambiguous = score, fields[9], false
	} else if score == q.best && q.inode != fields[9] {
		q.ambiguous = true
	}
}

// openTable and readLink are swapped by tests to count and pause reads.
var (
	openTable = func(name string) (io.ReadCloser, error) { return os.Open(name) }
	readLink  = os.Readlink
)

// scanTable offers each row of one /proc/net table to every query for that table.
func scanTable(file string, queries []*socketQuery) error {
	table, err := openTable(file)
	if err != nil {
		return err
	}
	defer table.Close()
	scanner := bufio.NewScanner(table)
	for scanner.Scan() {
		line := scanner.Bytes()
		var fields []string
		for _, q := range queries {
			if bytes.Contains(line, q.port) {
				if fields == nil {
					fields = strings.Fields(string(line))
				}
				q.match(fields)
			}
		}
	}
	return scanner.Err()
}

// lookups batches concurrent lookups (Elarni): every new connection of a burst read the whole socket
// table and walked the same descriptors. A lookup only joins a batch that starts after it asked, so
// the batch's table and descriptor reads include its socket.
var lookups struct {
	sync.Mutex
	next    []*socketQuery
	reading bool // a batch is reading the tables; lookups that arrive meanwhile wait for the next one
}

func lookupSocket(q *socketQuery) {
	lookups.Lock()
	lead := !lookups.reading
	if lead {
		lookups.reading = true
	} else {
		lookups.next = append(lookups.next, q)
	}
	lookups.Unlock()
	if lead {
		runLookups([]*socketQuery{q})
	}
	<-q.done
}

// runLookups reads each table once for the batch, starts the next batch, and then walks the
// descriptors once for this batch's sockets, so a slow walk does not hold back later lookups.
func runLookups(batch []*socketQuery) {
	tables := map[string][]*socketQuery{}
	for _, q := range batch {
		tables[q.file] = append(tables[q.file], q)
	}
	wanted := map[string][]*socketQuery{}
	for file, queries := range tables {
		err := scanTable(file, queries)
		for _, q := range queries {
			switch {
			case err != nil:
				q.err = errors.New("could not search in ", file).Base(err)
			case q.ambiguous:
				q.err = errors.New("could not search in ", file).Base(errors.New("ambiguous socket ownership"))
			case q.inode != "":
				link := "socket:[" + q.inode + "]"
				wanted[link] = append(wanted[link], q)
				continue
			}
			close(q.done)
		}
	}

	lookups.Lock()
	next := lookups.next
	lookups.next = nil
	lookups.reading = next != nil
	lookups.Unlock()
	if next != nil {
		go runLookups(next)
	}
	findOwners(wanted)
}

// recentOwners lists the processes that owned the last looked-up sockets, newest
// first. A full scan readlinks every open file on the host (14 ms at 10k fds),
// while apps open their connections in bursts.
var recentOwners struct {
	sync.Mutex
	pids []string
}

// findOwners walks the recent owners' descriptors, then every process's, until each wanted socket
// link has an owner. Each lookup returns as soon as its own socket is found.
func findOwners(wanted map[string][]*socketQuery) {
	if len(wanted) == 0 {
		return
	}
	recentOwners.Lock()
	recent := slices.Clone(recentOwners.pids)
	recentOwners.Unlock()
	for _, pid := range recent {
		if claimSockets(pid, wanted) {
			return
		}
	}

	procDir, err := os.ReadDir("/proc")
	if err == nil {
		for _, entry := range procDir {
			pid := entry.Name()
			if !entry.IsDir() || slices.Contains(recent, pid) {
				continue
			}
			if _, err := strconv.Atoi(pid); err != nil {
				continue
			}
			if claimSockets(pid, wanted) {
				return
			}
		}
	}
	for _, queries := range wanted {
		for _, q := range queries {
			if err != nil {
				q.err = errors.New("could not find PID for inode ", q.inode, ": ", err)
			}
			close(q.done)
		}
	}
}

func rememberOwner(pid string) {
	recentOwners.Lock()
	defer recentOwners.Unlock()
	others := slices.DeleteFunc(recentOwners.pids, func(p string) bool { return p == pid })
	recentOwners.pids = append([]string{pid}, others[:min(len(others), 7)]...)
}

// claimSockets hands pid the wanted sockets among its descriptors; true once none is left.
func claimSockets(pid string, wanted map[string][]*socketQuery) bool {
	fdPath := "/proc/" + pid + "/fd"
	fdDir, err := os.ReadDir(fdPath)
	if err != nil {
		return false
	}
	remembered := false
	for _, fdEntry := range fdDir {
		link, err := readLink(fdPath + "/" + fdEntry.Name())
		queries, ok := wanted[link]
		if err != nil || !ok {
			continue
		}
		if !remembered {
			rememberOwner(pid)
			remembered = true
		}
		delete(wanted, link)
		for _, q := range queries {
			q.pid = pid
			close(q.done)
		}
		if len(wanted) == 0 {
			return true
		}
	}
	return false
}

func getAbsPath(pid string) (string, error) {
	path := fmt.Sprintf("/proc/%s/exe", pid)
	return readLink(path)
}
