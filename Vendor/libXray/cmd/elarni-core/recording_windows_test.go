//go:build windows

package main

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"golang.org/x/sys/windows"
)

func TestServiceRecordingFolderIsTheAccountsAlone(t *testing.T) {
	sid, err := currentAccount()
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	directory, err := prepareWindowsRecording(root, sid)
	// This account owns the test folders, so it may give itself access back to remove them.
	t.Cleanup(func() {
		for _, path := range []string{filepath.Join(root, ".diagnostics"), directory} {
			if descriptor, err := windows.SecurityDescriptorFromString("D:(A;OICI;FA;;;" + sid + ")"); err == nil {
				if dacl, _, err := descriptor.DACL(); err == nil {
					_ = windows.SetNamedSecurityInfo(path, windows.SE_FILE_OBJECT, windows.DACL_SECURITY_INFORMATION, nil, nil, dacl, nil)
				}
			}
		}
	})
	if err != nil {
		t.Fatal(err)
	}
	if directory != filepath.Join(root, ".diagnostics", sid) {
		t.Fatalf("directory = %s", directory)
	}
	for path, want := range map[string][]string{
		filepath.Join(root, ".diagnostics"): {"(A;OICI;FA;;;SY)", "(A;OICI;FA;;;BA)", "(A;;0x100020;;;BU)"},
		directory:                           {"(A;OICI;FA;;;SY)", "(A;OICI;FA;;;BA)", "(A;OICI;0x1200a9;;;" + sid + ")"},
	} {
		descriptor, err := windows.GetNamedSecurityInfo(path, windows.SE_FILE_OBJECT, windows.DACL_SECURITY_INFORMATION)
		if err != nil {
			t.Fatal(err)
		}
		sddl := descriptor.String()
		dacl := sddl[strings.Index(sddl, "D:"):]
		if !strings.HasPrefix(dacl, "D:P") {
			t.Fatalf("%s inherits its DACL: %s", path, sddl)
		}
		// Exactly these entries: no Users or Everyone entry lets another account read the recording.
		if got := strings.Count(dacl, "("); got != len(want) {
			t.Fatalf("%s DACL %s, want only %v", path, dacl, want)
		}
		for _, entry := range want {
			if !strings.Contains(dacl, entry) {
				t.Fatalf("%s DACL %s lacks %s", path, dacl, entry)
			}
		}
	}
	// The account reads its recording but cannot plant files or links in it for SYSTEM to write through.
	// An elevated process (the CI runner) writes through the Administrators entry by design; the exact
	// DACL above already shows the account's own entry is read-only, and the app runs unelevated.
	if !windows.GetCurrentProcessToken().IsElevated() {
		if err := os.WriteFile(filepath.Join(directory, "rvdiag-helper-1-1-000001.jsonl"), []byte("{}\n"), 0o600); err == nil {
			t.Fatal("the account could write into its service recording folder")
		}
	}
	if _, err := os.ReadDir(directory); err != nil {
		t.Fatalf("the account cannot list its recording: %v", err)
	}
	if again, err := prepareWindowsRecording(root, sid); err != nil || again != directory {
		t.Fatalf("second prepare = %s, %v", again, err)
	}
}

func TestServiceRecordingFolderRefusesGroupsAndPaths(t *testing.T) {
	root := t.TempDir()
	for _, sid := range []string{"S-1-1-0", "S-1-5-18", "S-1-5-32-545", `..\..\Windows`, ""} {
		if _, err := prepareWindowsRecording(root, sid); err == nil {
			t.Fatalf("prepared a folder for %q", sid)
		}
	}
	if entries, _ := os.ReadDir(root); len(entries) != 0 {
		t.Fatalf("left %v", entries)
	}
}

func TestExportReadsTheServiceRecordingFolder(t *testing.T) {
	sid, err := currentAccount()
	if err != nil {
		t.Fatal(err)
	}
	root := isolateMachineRecordings(t)
	directories := recordingDirectories()
	if !slices.Contains(directories, userRecordingDirectory()) || !slices.Contains(directories, filepath.Join(root, ".diagnostics", sid)) {
		t.Fatalf("directories = %v", directories)
	}
}
