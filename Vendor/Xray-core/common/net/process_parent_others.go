//go:build !(linux && !android) && !windows && !(darwin && !ios)

package net

// ParentProcess names a program's parent on Linux, Windows and macOS. Android routes by app
// user ID, which an app's processes share.
func ParentProcess(int) (Process, bool) { return Process{}, false }
