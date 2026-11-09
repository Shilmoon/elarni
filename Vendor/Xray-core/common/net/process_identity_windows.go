//go:build windows

package net

import (
	"sync"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

// FlatpakApp and AppImage name Linux apps.
func FlatpakApp(int) string { return "" }

func AppImage(int, string) string { return "" }

// The service snapshot is reused for this long; a svchost process it does not know refreshes it
// sooner, as a service that just started does.
const (
	servicesFresh = 2 * time.Second
	servicesRetry = 250 * time.Millisecond
)

var serviceHosts struct {
	sync.Mutex
	taken time.Time
	byPID map[uint32][]string
}

// ProcessServices returns the names of the services a process runs. svchost runs most of them,
// one per process on most PCs, several per process on some.
func ProcessServices(pid int, name string) []string {
	if pid <= 0 {
		return nil
	}
	hosts := &serviceHosts
	hosts.Lock()
	defer hosts.Unlock()
	age := time.Since(hosts.taken)
	_, known := hosts.byPID[uint32(pid)]
	if hosts.taken.IsZero() || age > servicesFresh || !known && svchostName(name) && age > servicesRetry {
		if byPID, err := listServices(); err == nil {
			hosts.byPID = byPID
		}
		hosts.taken = time.Now()
	}
	return append([]string(nil), hosts.byPID[uint32(pid)]...)
}

// listServices maps the processes of running services to their names. Listing needs no
// administrator.
func listServices() (map[uint32][]string, error) {
	manager, err := windows.OpenSCManager(nil, nil, windows.SC_MANAGER_ENUMERATE_SERVICE)
	if err != nil {
		return nil, err
	}
	defer windows.CloseServiceHandle(manager)
	var buffer []byte
	for {
		var first *byte
		if len(buffer) > 0 {
			first = &buffer[0]
		}
		var needed, returned uint32
		err := windows.EnumServicesStatusEx(manager, windows.SC_ENUM_PROCESS_INFO, windows.SERVICE_WIN32,
			windows.SERVICE_ACTIVE, first, uint32(len(buffer)), &needed, &returned, nil, nil)
		if err == nil {
			byPID := map[uint32][]string{}
			if returned > 0 {
				for _, service := range unsafe.Slice((*windows.ENUM_SERVICE_STATUS_PROCESS)(unsafe.Pointer(&buffer[0])), int(returned)) {
					if pid := service.ServiceStatusProcess.ProcessId; pid != 0 {
						byPID[pid] = append(byPID[pid], windows.UTF16PtrToString(service.ServiceName))
					}
				}
			}
			return byPID, nil
		}
		if err != windows.ERROR_MORE_DATA || needed <= uint32(len(buffer)) {
			return nil, err
		}
		buffer = make([]byte, needed)
	}
}

// AppRule returns the rule for the app a process belongs to when its path does not name it: the
// service a svchost process runs, when it runs one. A rule for one of several would take the
// others' connections too.
func AppRule(pid int, name, _ string) string {
	if !svchostName(name) {
		return ""
	}
	if services := ProcessServices(pid, name); len(services) == 1 {
		return "service:" + services[0]
	}
	return ""
}
