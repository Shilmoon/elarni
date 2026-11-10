//go:build windows

package libXray

import "golang.org/x/sys/windows"

// localRulePath reports a path on a fixed drive. Others are not opened: a UNC path in an
// imported profile would make Windows sign in to that server.
func localRulePath(path string) bool {
	if len(path) < 3 || path[1] != ':' || path[2] != '\\' && path[2] != '/' {
		return false
	}
	letter := path[0] | 0x20
	if letter < 'a' || letter > 'z' {
		return false
	}
	root, err := windows.UTF16PtrFromString(path[:2] + `\`)
	return err == nil && windows.GetDriveType(root) == windows.DRIVE_FIXED
}
