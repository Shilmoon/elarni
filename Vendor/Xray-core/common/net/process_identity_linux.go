//go:build linux && !android

package net

import (
	"bytes"
	"io"
	"os"
	"strconv"
	"strings"
	"syscall"
)

// procRoot is /proc; tests use a fake tree.
var procRoot = "/proc"

// readProcFile reads a small regular file without following a final link or waiting on a pipe:
// a process controls what its root holds.
func readProcFile(path string, limit int64) []byte {
	fd, err := syscall.Open(path, syscall.O_RDONLY|syscall.O_NONBLOCK|syscall.O_NOCTTY|syscall.O_CLOEXEC|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return nil
	}
	file := os.NewFile(uintptr(fd), path)
	defer file.Close()
	if info, err := file.Stat(); err != nil || !info.Mode().IsRegular() {
		return nil
	}
	data, err := io.ReadAll(io.LimitReader(file, limit))
	if err != nil {
		return nil
	}
	return data
}

// FlatpakApp returns the app ID of a process in a Flatpak sandbox, as xdg-desktop-portal finds
// it: the [Application] name in the sandbox's /.flatpak-info. Its children share the sandbox.
func FlatpakApp(pid int) string {
	if pid <= 0 {
		return ""
	}
	group := ""
	for _, line := range strings.Split(string(readProcFile(procRoot+"/"+strconv.Itoa(pid)+"/root/.flatpak-info", 64<<10)), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			group = line[1 : len(line)-1]
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if group == "Application" && ok && strings.TrimSpace(key) == "name" {
			if id := strings.TrimSpace(value); ValidFlatpakApp(id) {
				return id
			}
			return ""
		}
	}
	return ""
}

// AppImage returns the image file of a process that runs from a mounted AppImage. Its runtime
// sets APPIMAGE to the file and APPDIR to the mount, which must hold the program: a browser the
// app opened keeps the variables but is not the app.
func AppImage(pid int, path string) string {
	if pid <= 0 || path == "" {
		return ""
	}
	var image, mount string
	for _, entry := range bytes.Split(readProcFile(procRoot+"/"+strconv.Itoa(pid)+"/environ", 1<<20), []byte{0}) {
		if value, ok := bytes.CutPrefix(entry, []byte("APPIMAGE=")); ok {
			image = string(value)
		} else if value, ok := bytes.CutPrefix(entry, []byte("APPDIR=")); ok {
			mount = strings.TrimRight(string(value), "/")
		}
	}
	if !strings.HasPrefix(image, "/") || !strings.HasPrefix(mount, "/") || !strings.HasPrefix(path, mount+"/") {
		return ""
	}
	return image
}

// ProcessServices names Windows services; Linux has none.
func ProcessServices(int, string) []string { return nil }

// AppRule returns the rule for the app a process belongs to when its path does not name it:
// its Flatpak app or its AppImage.
func AppRule(pid int, _, path string) string {
	if id := FlatpakApp(pid); id != "" {
		return "flatpak:" + id
	}
	if image := AppImage(pid, path); image != "" {
		return "appimage:" + image
	}
	return ""
}
