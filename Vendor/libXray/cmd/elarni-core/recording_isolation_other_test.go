//go:build !windows

package main

import "testing"

// isolateMachineRecordings: only the Windows VPN child records outside the user's cache.
func isolateMachineRecordings(t *testing.T) string { return "" }
