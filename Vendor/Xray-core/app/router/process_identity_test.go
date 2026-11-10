package router

import "testing"

// Flatpak, AppImage and service rules name an app by what the system knows of the process beyond
// its path, which a sandbox, a mount or a shared host hides. They never match as names or paths.
func TestTypedRulesMatchTheProcessIdentity(t *testing.T) {
	previousFlatpak, previousImage, previousServices := processFlatpakApp, processAppImage, processServices
	t.Cleanup(func() {
		processFlatpakApp, processAppImage, processServices = previousFlatpak, previousImage, previousServices
	})
	processFlatpakApp = func(pid int) string {
		if pid == 10 {
			return "org.mozilla.firefox"
		}
		return ""
	}
	processAppImage = func(pid int, path string) string {
		if pid == 20 && path == "/tmp/.mount_CursorAb12/usr/share/cursor/cursor" {
			return "/home/user/Applications/Cursor.AppImage"
		}
		return ""
	}
	processServices = func(pid int, name string) []string {
		if pid == 30 {
			return []string{"DoSvc", "BITS"}
		}
		return nil
	}
	for _, c := range []struct {
		name  string
		rules []string
		pid   int
		exe   string
		path  string
		want  bool
	}{
		{"flatpak app", []string{"flatpak:org.mozilla.firefox"}, 10, "firefox", "/app/lib/firefox/firefox", true},
		{"another flatpak app", []string{"flatpak:org.telegram.desktop"}, 10, "firefox", "/app/lib/firefox/firefox", false},
		{"flatpak ids keep their case", []string{"flatpak:org.Mozilla.firefox"}, 10, "firefox", "/app/lib/firefox/firefox", false},
		{"not in a sandbox", []string{"flatpak:org.mozilla.firefox"}, 11, "firefox", "/usr/lib/firefox/firefox", false},
		{"a rule is not a name", []string{"flatpak:org.mozilla.firefox"}, 11, "flatpak:org.mozilla.firefox", "/usr/bin/x", false},
		{"appimage file", []string{"appimage:/home/user/Applications/Cursor.AppImage"}, 20, "cursor",
			"/tmp/.mount_CursorAb12/usr/share/cursor/cursor", true},
		{"appimage folder", []string{"appimage:/home/user/Applications/"}, 20, "cursor",
			"/tmp/.mount_CursorAb12/usr/share/cursor/cursor", true},
		{"another appimage", []string{"appimage:/home/user/Applications/Other.AppImage"}, 20, "cursor",
			"/tmp/.mount_CursorAb12/usr/share/cursor/cursor", false},
		{"appimage rule is not a path", []string{"appimage:/tmp/.mount_CursorAb12/usr/share/cursor/cursor"}, 21, "cursor",
			"/tmp/.mount_CursorAb12/usr/share/cursor/cursor", false},
		{"service", []string{"service:BITS"}, 30, "svchost.exe", `C:\Windows\System32\svchost.exe`, true},
		{"service names ignore case", []string{"service:dosvc"}, 30, "svchost.exe", `C:\Windows\System32\svchost.exe`, true},
		{"another service", []string{"service:wuauserv"}, 30, "svchost.exe", `C:\Windows\System32\svchost.exe`, false},
		{"no process", []string{"flatpak:org.mozilla.firefox", "service:BITS"}, 0, "", "", false},
		{"listed with other rules", []string{"telegram", "flatpak:org.mozilla.firefox"}, 10, "firefox", "/app/lib/firefox/firefox", true},
	} {
		if got := NewProcessNameMatcher(c.rules).MatchesProcess(c.pid, c.exe, c.path); got != c.want {
			t.Errorf("%s: matched %v, want %v", c.name, got, c.want)
		}
	}
}

// Without a typed rule the matcher asks nothing more of the system.
func TestPlainRulesSkipIdentityLookups(t *testing.T) {
	previousFlatpak, previousImage, previousServices := processFlatpakApp, processAppImage, processServices
	t.Cleanup(func() {
		processFlatpakApp, processAppImage, processServices = previousFlatpak, previousImage, previousServices
	})
	asked := 0
	processFlatpakApp = func(int) string { asked++; return "" }
	processAppImage = func(int, string) string { asked++; return "" }
	processServices = func(int, string) []string { asked++; return nil }
	if NewProcessNameMatcher([]string{"telegram", "/usr/bin/curl", "/opt/apps/"}).MatchesProcess(7, "firefox", "/usr/bin/firefox") {
		t.Fatal("matched")
	}
	if asked != 0 {
		t.Fatalf("%d identity lookups", asked)
	}
}
