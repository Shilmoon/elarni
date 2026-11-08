//go:build windows

package main

import (
	"errors"
	"os"
	"path/filepath"

	"golang.org/x/sys/windows"
)

// The VPN child may run as SYSTEM (the ElarniVPN service) or as another administrator who
// approved the prompt, whose caches the app's export cannot read. It records for the broker's
// account in the helper's admin-only folder instead: under a dot name, which helper updates keep,
// and removed with the helper. Each account's folder is readable by that account only.
const windowsRecordingFolder = ".diagnostics"

// recordingRoot is the helper root; tests point it elsewhere.
var recordingRoot = windowsHelperRoot

func windowsRecordingDirectory(root, sid string) string {
	return filepath.Join(root, windowsRecordingFolder, sid)
}

// windowsRecordingDirectories are where this account's recordings may be: its own cache, where
// the local proxy core and marks record, and its folder for the VPN child.
func windowsRecordingDirectories() []string {
	directories := []string{userRecordingDirectory()}
	root, rootErr := recordingRoot()
	sid, sidErr := currentAccount()
	if rootErr == nil && sidErr == nil {
		directories = append(directories, windowsRecordingDirectory(root, sid))
	}
	return directories
}

// vpnRecordingDirectory is where a VPN child records for the broker's account.
func vpnRecordingDirectory(broker windows.Handle) string {
	var token windows.Token
	if windows.OpenProcessToken(broker, windows.TOKEN_QUERY, &token) != nil {
		return ""
	}
	defer token.Close()
	owner, err := token.GetTokenUser()
	if err != nil {
		return ""
	}
	root, err := recordingRoot()
	if err != nil {
		return ""
	}
	directory, err := prepareWindowsRecording(root, owner.User.Sid.String())
	if err != nil {
		return ""
	}
	return directory
}

// prepareWindowsRecording makes the account's folder under root, which only administrators
// can change, so the account can read its recording but cannot swap the folder for a link.
func prepareWindowsRecording(root, sid string) (string, error) {
	sid, err := canonicalUserSID(sid)
	if err != nil {
		return "", err
	}
	const admins = "D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)"
	parent, directory := filepath.Join(root, windowsRecordingFolder), windowsRecordingDirectory(root, sid)
	for _, path := range []string{parent, directory} {
		if err := os.Mkdir(path, 0o700); err != nil && !errors.Is(err, os.ErrExist) {
			return "", err
		}
	}
	// 0x1200a9: read, list and traverse. The parent is secured last, so its creator can still make the folder.
	if err := secureRecordingFolder(directory, admins+"(A;OICI;0x1200a9;;;"+sid+")"); err != nil {
		return "", err
	}
	if err := secureRecordingFolder(parent, admins+"(A;;0x100020;;;BU)"); err != nil { // users may only pass through
		return "", err
	}
	return directory, nil
}

func secureRecordingFolder(path, acl string) error {
	if info, err := os.Lstat(path); err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 || info.Mode()&os.ModeIrregular != 0 {
		return errors.New("recording_folder_invalid")
	}
	descriptor, err := windows.SecurityDescriptorFromString(acl)
	if err != nil {
		return err
	}
	dacl, _, err := descriptor.DACL()
	if err != nil {
		return err
	}
	return windows.SetNamedSecurityInfo(path, windows.SE_FILE_OBJECT,
		windows.DACL_SECURITY_INFORMATION|windows.PROTECTED_DACL_SECURITY_INFORMATION, nil, nil, dacl, nil)
}
