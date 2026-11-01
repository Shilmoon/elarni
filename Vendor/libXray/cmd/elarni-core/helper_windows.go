//go:build windows

package main

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
)

// Users may read and run the helper; only administrators and SYSTEM may change it.
const windowsHelperACL = "D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;BU)"

func windowsHelperRoot() (string, error) {
	programs, err := windows.KnownFolderPath(windows.FOLDERID_ProgramFiles, 0)
	if err != nil {
		return "", err
	}
	return filepath.Join(programs, "Elarni VPN Helper"), nil
}

// windowsHelper returns this build's protected copy, installing it first behind
// its own consent prompt when the build is new to this machine.
func windowsHelper() (string, error) {
	executable, err := os.Executable()
	if err != nil {
		return "", errors.New("native_unavailable")
	}
	root, err := windowsHelperRoot()
	if err != nil {
		return "", errors.New("native_unavailable")
	}
	digest, err := fileDigest(executable)
	if err != nil {
		return "", errors.New("native_unavailable")
	}
	directory := helperDirectory(root, digest)
	if !helperInstalled(directory, "elarni-core.exe", "wintun.dll") {
		if err := runElevated(executable, "--install-helper"); err != nil {
			return "", err
		}
		if !helperInstalled(directory, "elarni-core.exe", "wintun.dll") {
			return "", errors.New("elevation_failed")
		}
	}
	return filepath.Join(directory, "elarni-core.exe"), nil
}

// installWindowsHelper runs elevated from the bundle being installed.
func installWindowsHelper() error {
	executable, err := os.Executable()
	if err != nil {
		return err
	}
	root, err := windowsHelperRoot()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(root, 0o755); err != nil {
		return err
	}
	// An explicit protected DACL keeps the folder admin-only whatever it inherited.
	descriptor, err := windows.SecurityDescriptorFromString(windowsHelperACL)
	if err != nil {
		return err
	}
	dacl, _, err := descriptor.DACL()
	if err != nil {
		return err
	}
	if err := windows.SetNamedSecurityInfo(root, windows.SE_FILE_OBJECT,
		windows.DACL_SECURITY_INFORMATION|windows.PROTECTED_DACL_SECURITY_INFORMATION, nil, nil, dacl, nil); err != nil {
		return err
	}
	digest, err := fileDigest(executable)
	if err != nil {
		return err
	}
	// The VPN service runs from the copy it was pointed at, which locks that
	// directory; it is stopped first and then pointed at this build's copy.
	manager, service, line, release, err := installedVPNService()
	if err == nil {
		defer release()
		if service != nil {
			stopVPNService(service)
		}
	}
	if err := installHelper(root, digest, []helperFile{
		{"elarni-core.exe", executable, digest},
		{"wintun.dll", filepath.Join(filepath.Dir(executable), "wintun.dll"), wintunSHA256[runtime.GOARCH]},
	}); err != nil {
		return err
	}
	helper := filepath.Join(helperDirectory(root, digest), "elarni-core.exe")
	warmHelper(helper)
	if service != nil {
		return pointVPNService(manager, service, helper, serviceCommandUsers(line))
	}
	return nil
}

// uninstallWindowsHelper runs elevated from the MSI uninstall, or by hand for a
// portable bundle, and removes what the helper left on this machine.
func uninstallWindowsHelper() error {
	root, err := windowsHelperRoot()
	if err != nil {
		return err
	}
	// The service runs from root; deleted first, it no longer holds the folder.
	return errors.Join(removeVPNService(), uninstallHelper(root, func() error { return clearStaleGuard(releaseGuard) }))
}

// uninstallHelper first ends the copies still running from root, which own the
// DNS guard and lock their files, then clears the guard and deletes root.
func uninstallHelper(root string, clearGuard func() error) error {
	stopHelpers(root)
	return errors.Join(clearGuard(), os.RemoveAll(root))
}

// stopHelpers ends every process started from a file under root. A killed
// helper leaves its DNS guard behind, as a crashed one does.
func stopHelpers(root string) {
	snapshot, err := windows.CreateToolhelp32Snapshot(windows.TH32CS_SNAPPROCESS, 0)
	if err != nil {
		return
	}
	defer windows.CloseHandle(snapshot)
	entry := windows.ProcessEntry32{Size: uint32(unsafe.Sizeof(windows.ProcessEntry32{}))}
	image := make([]uint16, 32768)
	for found := windows.Process32First(snapshot, &entry); found == nil; found = windows.Process32Next(snapshot, &entry) {
		if entry.ProcessID == windows.GetCurrentProcessId() {
			continue
		}
		process, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION|windows.PROCESS_TERMINATE|windows.SYNCHRONIZE, false, entry.ProcessID)
		if err != nil {
			continue
		}
		length := uint32(len(image))
		if windows.QueryFullProcessImageName(process, 0, &image[0], &length) == nil {
			if relative, err := filepath.Rel(root, windows.UTF16ToString(image[:length])); err == nil && filepath.IsLocal(relative) {
				windows.TerminateProcess(process, 1)
				windows.WaitForSingleObject(process, 5000)
			}
		}
		windows.CloseHandle(process)
	}
}

// warmHelper creates the installed copy suspended and ends it, so no code runs.
// Windows Defender scans a new executable on its first launch, ~4 s for the core;
// this takes that scan here, which for the MSI is at setup instead of the first connect.
func warmHelper(path string) {
	command := exec.Command(path)
	command.SysProcAttr = &syscall.SysProcAttr{CreationFlags: windows.CREATE_SUSPENDED | windows.CREATE_NO_WINDOW}
	if command.Start() == nil {
		_ = command.Process.Kill()
		_ = command.Wait()
	}
}

// runElevated starts file with consent and waits for it to exit successfully.
func runElevated(file, arguments string) error {
	process, err := shellRunAs(file, arguments)
	if err != nil {
		return err
	}
	defer windows.CloseHandle(process)
	var code uint32
	if state, err := windows.WaitForSingleObject(process, 60000); err != nil || state != windows.WAIT_OBJECT_0 {
		windows.TerminateProcess(process, 1)
		return errors.New("elevation_failed")
	}
	if windows.GetExitCodeProcess(process, &code) != nil || code != 0 {
		return errors.New("elevation_failed")
	}
	return nil
}

func shellRunAs(file, arguments string) (windows.Handle, error) {
	verb, _ := windows.UTF16PtrFromString("runas")
	name, _ := windows.UTF16PtrFromString(file)
	args, _ := windows.UTF16PtrFromString(arguments)
	directory, _ := windows.UTF16PtrFromString(filepath.Dir(file))
	info := shellExecuteInfo{Mask: 0x40 | 0x100 | 0x400 | 0x8000, Verb: verb, File: name, Parameters: args, Directory: directory}
	info.Size = uint32(unsafe.Sizeof(info))
	proc := windows.NewLazySystemDLL("shell32.dll").NewProc("ShellExecuteExW")
	ok, _, callErr := proc.Call(uintptr(unsafe.Pointer(&info)))
	if ok == 0 {
		if errors.Is(callErr, windows.ERROR_CANCELLED) {
			return 0, errors.New("elevation_denied")
		}
		return 0, errors.New("elevation_failed")
	}
	if info.Process == 0 {
		return 0, errors.New("elevation_failed")
	}
	return info.Process, nil
}
