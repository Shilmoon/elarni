//go:build linux

package main

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
)

const linuxHelperRoot = "/opt/elarni-vpn-helper"

// linuxTrusted reports whether only root can replace path: it and every
// ancestor directory are root-owned real files that group and others cannot write.
func linuxTrusted(path string) bool {
	for {
		info, err := os.Lstat(path)
		if err != nil || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm()&0o022 != 0 {
			return false
		}
		if stat, ok := info.Sys().(*syscall.Stat_t); !ok || stat.Uid != 0 {
			return false
		}
		parent := filepath.Dir(path)
		if parent == path {
			return true
		}
		path = parent
	}
}

// linuxHelper returns the binary pkexec may start: a root-owned install (the
// .deb) as is, otherwise this build's protected copy, installed first behind
// its own authentication when the build is new to this machine.
func linuxHelper(executable string) (string, error) {
	if linuxTrusted(executable) {
		return executable, nil
	}
	digest, err := fileDigest(executable)
	if err != nil {
		return "", errors.New("native_unavailable")
	}
	helper := filepath.Join(helperDirectory(linuxHelperRoot, digest), "elarni-core")
	if !linuxTrusted(helper) {
		installer := executable
		if linuxFUSE(executable) {
			// A running AppImage is a FUSE mount that root cannot open, so pkexec
			// gets a copy of the same bytes from the user's cache instead.
			staged, err := stageLinuxInstaller(executable, digest)
			if err != nil {
				return "", errors.New("native_unavailable")
			}
			defer os.RemoveAll(filepath.Dir(staged))
			installer = staged
		}
		err := exec.Command(linuxTool("pkexec", "/usr/bin", "/run/wrappers/bin"), installer, "--install-helper").Run()
		var exit *exec.ExitError
		if errors.As(err, &exit) && (exit.ExitCode() == 126 || exit.ExitCode() == 127) {
			return "", errors.New("elevation_denied")
		}
		if err != nil || !linuxTrusted(helper) {
			return "", errors.New("elevation_failed")
		}
	}
	return helper, nil
}

// linuxFUSE reports whether path is on a FUSE file system (FUSE_SUPER_MAGIC).
func linuxFUSE(path string) bool {
	var fs syscall.Statfs_t
	return syscall.Statfs(path, &fs) == nil && fs.Type == 0x65735546
}

// stageLinuxInstaller copies executable into a new directory under the user's
// cache, where root can run it, and returns the copy's path.
func stageLinuxInstaller(executable, digest string) (string, error) {
	cache, err := os.UserCacheDir()
	if err != nil {
		return "", err
	}
	if err := os.MkdirAll(cache, 0o700); err != nil {
		return "", err
	}
	directory, err := os.MkdirTemp(cache, "elarni-installer-")
	if err != nil {
		return "", err
	}
	staged := filepath.Join(directory, "elarni-core")
	if copied, err := copyHelperFile(executable, staged); err != nil || copied != digest {
		_ = os.RemoveAll(directory)
		return "", errors.New("helper_copy_mismatch")
	}
	return staged, nil
}

// installLinuxHelper runs as root and copies the image pkexec approved, not
// whatever its user-writable path holds now.
func installLinuxHelper() error {
	syscall.Umask(0o022)
	digest, err := fileDigest("/proc/self/exe")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(linuxHelperRoot, 0o755); err != nil {
		return err
	}
	if !linuxTrusted(linuxHelperRoot) {
		return errors.New("helper_root_untrusted")
	}
	return installHelper(linuxHelperRoot, digest, []helperFile{{"elarni-core", "/proc/self/exe", digest}})
}
