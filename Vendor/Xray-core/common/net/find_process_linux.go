//go:build linux && !android

package net

import (
	"bufio"
	"encoding/binary"
	"encoding/hex"
	"fmt"
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
	inode, err := findInodeInFile(procFile, targetHexAddr, remote, network == "udp")
	if err != nil {
		return 0, "", "", errors.New("could not search in ", procFile).Base(err)
	}
	if inode == "" {
		return 0, "", "", errors.New("connection for ", srcIP, ":", srcPort, " not found in ", procFile)
	}

	pidStr, err := findPidByInode(inode)
	if err != nil {
		return 0, "", "", errors.New("could not find PID for inode ", inode, ": ", err)
	}
	if pidStr == "" {
		return 0, "", "", errors.New("no process found for inode ", inode)
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

func findInodeInFile(filePath, targetHexAddr, remote string, udp bool) (string, error) {
	file, err := os.Open(filePath)
	if err != nil {
		return "", err
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)

	wildcard := strings.Repeat("0", strings.IndexByte(targetHexAddr, ':'))
	wildLocal := wildcard + targetHexAddr[len(wildcard):]
	wildRemote := wildcard + ":0000"
	best, inode, ambiguous := -1, "", false
	for scanner.Scan() {
		line := scanner.Text()
		fields := strings.Fields(line)

		if len(fields) < 10 {
			continue
		}

		localAddress, remoteAddress := fields[1], fields[2]
		score := 0
		if localAddress == targetHexAddr {
			score += 2
		} else if !udp || localAddress != wildLocal {
			continue
		}
		if remote != "" {
			if remoteAddress == remote {
				score++
			} else if !udp || remoteAddress != wildRemote {
				continue
			}
		}
		if fields[9] == "0" {
			continue
		}
		if score > best {
			best, inode, ambiguous = score, fields[9], false
		} else if score == best && inode != fields[9] {
			ambiguous = true
		}
	}
	if scanner.Err() != nil {
		return "", scanner.Err()
	}
	if ambiguous {
		return "", errors.New("ambiguous socket ownership")
	}
	return inode, nil
}

// readLink is swapped by tests to count reads.
var readLink = os.Readlink

// recentOwners lists the processes that owned the last looked-up sockets, newest
// first. A full scan readlinks every open file on the host (14 ms at 10k fds),
// while apps open their connections in bursts.
var recentOwners struct {
	sync.Mutex
	pids []string
}

func findPidByInode(inode string) (string, error) {
	targetLink := "socket:[" + inode + "]"
	recentOwners.Lock()
	recent := slices.Clone(recentOwners.pids)
	recentOwners.Unlock()
	for _, pid := range recent {
		if ownsSocket(pid, targetLink) {
			rememberOwner(pid)
			return pid, nil
		}
	}

	procDir, err := os.ReadDir("/proc")
	if err != nil {
		return "", err
	}
	for _, entry := range procDir {
		pid := entry.Name()
		if !entry.IsDir() || slices.Contains(recent, pid) {
			continue
		}
		if _, err := strconv.Atoi(pid); err != nil {
			continue
		}
		if ownsSocket(pid, targetLink) {
			rememberOwner(pid)
			return pid, nil
		}
	}
	return "", nil
}

func rememberOwner(pid string) {
	recentOwners.Lock()
	defer recentOwners.Unlock()
	others := slices.DeleteFunc(recentOwners.pids, func(p string) bool { return p == pid })
	recentOwners.pids = append([]string{pid}, others[:min(len(others), 7)]...)
}

func ownsSocket(pid, targetLink string) bool {
	fdPath := "/proc/" + pid + "/fd"
	fdDir, err := os.ReadDir(fdPath)
	if err != nil {
		return false
	}
	for _, fdEntry := range fdDir {
		if linkTarget, err := readLink(fdPath + "/" + fdEntry.Name()); err == nil && linkTarget == targetLink {
			return true
		}
	}
	return false
}

func getAbsPath(pid string) (string, error) {
	path := fmt.Sprintf("/proc/%s/exe", pid)
	return readLink(path)
}
