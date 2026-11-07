//go:build windows

package main

import "testing"

// isolateMachineRecordings points the VPN child's recording root at a test folder, so a real
// recording on this machine cannot show up in a test's export.
func isolateMachineRecordings(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	previous := recordingRoot
	recordingRoot = func() (string, error) { return root, nil }
	t.Cleanup(func() { recordingRoot = previous })
	return root
}
