//go:build windows

package net

import (
	"os"
	"strings"
	"testing"
)

// svchost runs most Windows services; a service rule names the process that runs it, and a
// connection from a host of one service is named after that service.
func TestServicesOfARunningProcess(t *testing.T) {
	byPID, err := listServices()
	if err != nil {
		t.Fatal(err)
	}
	processes, err := ListProcesses()
	if err != nil {
		t.Fatal(err)
	}
	hosts := map[int]bool{}
	for _, process := range processes {
		if svchostName(process.Name) { // the list names programs without ".exe"
			hosts[process.PID] = true
		}
	}
	single, shared := 0, 0
	for pid, names := range byPID {
		if !hosts[int(pid)] {
			continue
		}
		got := ProcessServices(int(pid), "svchost.exe")
		for _, name := range names {
			found := false
			for _, service := range got {
				found = found || strings.EqualFold(service, name)
			}
			if !found {
				t.Fatalf("pid %d runs %s, lookup %v", pid, name, got)
			}
		}
		rule := AppRule(int(pid), "svchost.exe", `C:\Windows\System32\svchost.exe`)
		if len(names) == 1 {
			single++
			if !strings.EqualFold(rule, "service:"+names[0]) {
				t.Fatalf("pid %d runs %s, rule %q", pid, names[0], rule)
			}
		} else {
			shared++
			// A rule for one of several services would take the others' connections too.
			if rule != "" {
				t.Fatalf("pid %d runs %v, rule %q", pid, names, rule)
			}
		}
	}
	if single == 0 {
		t.Fatalf("no svchost runs one service: %v", byPID)
	}
	t.Logf("%d svchost processes run one service, %d run several", single, shared)
	if got := ProcessServices(os.Getpid(), "test.exe"); len(got) != 0 {
		t.Fatalf("this test runs %v", got)
	}
	if got := AppRule(os.Getpid(), "test.exe", `C:\test.exe`); got != "" {
		t.Fatalf("this test: %q", got)
	}
}
