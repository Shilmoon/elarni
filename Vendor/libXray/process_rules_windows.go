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

// serviceInstalled reports a service by its name, or one this check may not look up.
func serviceInstalled(name string) bool {
	manager, err := windows.OpenSCManager(nil, nil, windows.SC_MANAGER_CONNECT)
	if err != nil {
		return true
	}
	defer windows.CloseServiceHandle(manager)
	wide, err := windows.UTF16PtrFromString(name)
	if err != nil {
		return false
	}
	service, err := windows.OpenService(manager, wide, windows.SERVICE_QUERY_STATUS)
	if err != nil {
		return err != windows.ERROR_SERVICE_DOES_NOT_EXIST && err != windows.ERROR_INVALID_NAME
	}
	windows.CloseServiceHandle(service)
	return true
}
