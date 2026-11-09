package libXray

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"testing"
)

func warningCodes(check ProcessRuleCheck) []string {
	var codes []string
	for _, warning := range check.Warnings {
		codes = append(codes, warning.Code+"="+warning.Suggestion)
	}
	return codes
}

// A rule that names no program the core will see matches nothing, silently. The editor
// shows why: the path is gone, names a folder without the trailing separator, a script
// (the interpreter runs), a symlink (the target runs) or the wrong letter case.
func TestProcessRuleChecksExplainRulesThatMatchNothing(t *testing.T) {
	root := t.TempDir()
	if resolved, err := filepath.EvalSymlinks(root); err == nil {
		root = resolved // macOS: /var is a link to /private/var
	}
	program := filepath.Join(root, "Tools", "app")
	if runtime.GOOS == "windows" {
		program += ".exe"
	}
	if err := os.MkdirAll(filepath.Dir(program), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(program, []byte("\x7fELF"), 0o755); err != nil {
		t.Fatal(err)
	}
	script := filepath.Join(root, "Tools", "run.sh")
	if err := os.WriteFile(script, []byte("#!/bin/sh\nexec app\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	folder := filepath.Join(root, "Tools")
	sep := string(filepath.Separator)
	want := map[string][]string{
		program:                            nil,
		folder + sep:                       nil,
		folder:                             {"folder=" + folder + sep},
		filepath.Join(root, "Gone", "app"): {"missing="},
		filepath.Join(root, "Gone") + sep:  {"missing="},
		program + sep:                      {"notFolder=" + program},
		"curl":                             nil,
		"-1":                               nil,
	}
	if runtime.GOOS != "windows" {
		want[script] = []string{"script="}
		link := filepath.Join(root, "app-link")
		if err := os.Symlink(program, link); err != nil {
			t.Fatal(err)
		}
		want[link] = []string{"symlink=" + program}
		// Rules compare case-sensitively here, also on macOS's case-insensitive disks.
		want[filepath.Join(root, "tools", "app")] = []string{"case=" + program}
	}
	if runtime.GOOS == "windows" {
		// Windows rules ignore case; launchers start another program.
		want[strings.ToUpper(program)] = nil
		for _, name := range []string{"start.bat", "start.cmd", "App.lnk"} {
			path := filepath.Join(root, "Tools", name)
			if err := os.WriteFile(path, []byte("x"), 0o644); err != nil {
				t.Fatal(err)
			}
			want[path] = []string{"launcher="}
		}
		// A Squirrel app's root .exe only starts app-<version>\<name>.exe.
		squirrel := filepath.Join(root, "Discord")
		for _, dir := range []string{squirrel, filepath.Join(squirrel, "app-1.0.9")} {
			if err := os.MkdirAll(dir, 0o755); err != nil {
				t.Fatal(err)
			}
		}
		for _, name := range []string{"Update.exe", "Discord.exe"} {
			if err := os.WriteFile(filepath.Join(squirrel, name), []byte("MZ"), 0o755); err != nil {
				t.Fatal(err)
			}
		}
		want[filepath.Join(squirrel, "Discord.exe")] = []string{"launcher=" + squirrel + sep}
		// A rule on another computer is not opened, which would sign in to that server.
		want[`\\192.0.2.1\share\app.exe`] = nil
	}
	if runtime.GOOS == "darwin" {
		// A bare name is compared with the executable's name, never "Example.app".
		want["Example.app"] = []string{"bundleName="}
	}
	var opened []string
	previous := ruleLstat
	ruleLstat = func(path string) (os.FileInfo, error) {
		opened = append(opened, path)
		return previous(path)
	}
	t.Cleanup(func() { ruleLstat = previous })
	var rules []string
	for rule := range want {
		rules = append(rules, rule)
	}
	slices.Sort(rules)
	result := checkProcessRules(rules)
	if len(result.Rules) != len(rules) {
		t.Fatalf("%d results for %d rules", len(result.Rules), len(rules))
	}
	for i, check := range result.Rules {
		if check.Rule != rules[i] {
			t.Fatalf("result %d is for %q, want %q", i, check.Rule, rules[i])
		}
		if got := warningCodes(check); !slices.Equal(got, want[check.Rule]) {
			t.Errorf("%q: warnings %v, want %v", check.Rule, got, want[check.Rule])
		}
	}
	for _, path := range opened {
		if strings.HasPrefix(path, `\\`) {
			t.Errorf("opened %q, on another computer", path)
		}
	}
}

// Flatpak and AppImage rules are checked on Linux, service rules on Windows: an app that is
// not installed, an image that is gone or a folder without its separator. Suggestions keep the
// rule's kind.
func TestProcessRuleChecksOfTypedRules(t *testing.T) {
	root := t.TempDir()
	if resolved, err := filepath.EvalSymlinks(root); err == nil {
		root = resolved
	}
	want := map[string][]string{}
	switch runtime.GOOS {
	case "linux":
		images := filepath.Join(root, "Applications")
		image := filepath.Join(images, "Cursor.AppImage")
		if err := os.MkdirAll(images, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(image, []byte("\x7fELF"), 0o755); err != nil {
			t.Fatal(err)
		}
		link := filepath.Join(root, "cursor")
		if err := os.Symlink(image, link); err != nil {
			t.Fatal(err)
		}
		installed := filepath.Join(root, "flatpak", "app", "org.example.Installed")
		if err := os.MkdirAll(installed, 0o755); err != nil {
			t.Fatal(err)
		}
		previous := flatpakInstallations
		flatpakInstallations = func() []string { return []string{filepath.Join(root, "missing"), filepath.Join(root, "flatpak")} }
		t.Cleanup(func() { flatpakInstallations = previous })
		want["appimage:"+image] = nil
		want["appimage:"+images+"/"] = nil
		want["appimage:"+images] = []string{"folder=appimage:" + images + "/"}
		want["appimage:"+filepath.Join(images, "Gone.AppImage")] = []string{"missing="}
		want["appimage:"+link] = []string{"symlink=appimage:" + image}
		want["appimage:"+filepath.Join(root, "applications", "Cursor.AppImage")] = []string{"case=appimage:" + image}
		want["flatpak:org.example.Installed"] = nil
		want["flatpak:org.example.Gone"] = []string{"missing="}
		want["flatpak:not an id"] = []string{"missing="}
		want["service:wuauserv"] = nil
	case "windows":
		// The RPC service runs on every Windows.
		want["service:RpcSs"] = nil
		want["service:rpcss"] = nil
		want["service:ElarniNoSuchService"] = []string{"missing="}
		want["flatpak:org.example.Gone"] = nil
		want[`appimage:C:\Gone.AppImage`] = nil
	default:
		want["flatpak:org.example.Gone"] = nil
		want["service:wuauserv"] = nil
	}
	var rules []string
	for rule := range want {
		rules = append(rules, rule)
	}
	slices.Sort(rules)
	for i, check := range checkProcessRules(rules).Rules {
		if check.Rule != rules[i] {
			t.Fatalf("result %d is for %q, want %q", i, check.Rule, rules[i])
		}
		if got := warningCodes(check); !slices.Equal(got, want[check.Rule]) {
			t.Errorf("%q: warnings %v, want %v", check.Rule, got, want[check.Rule])
		}
		if runtime.GOOS == "windows" && strings.EqualFold(check.Rule, "service:RpcSs") && check.Running != 1 {
			t.Errorf("%q: %d running", check.Rule, check.Running)
		}
	}
}

// The count uses the core's own matcher, so it agrees with what routing will do.
func TestProcessRuleChecksCountRunningPrograms(t *testing.T) {
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	if resolved, err := filepath.EvalSymlinks(executable); err == nil {
		executable = resolved
	}
	name := filepath.Base(executable)
	rules := []string{executable, filepath.Dir(executable) + string(filepath.Separator), name,
		filepath.Join(t.TempDir(), "never-running")}
	raw := Invoke(`{"apiVersion":1,"method":"checkProcessRules","payload":` + mustJSON(t, map[string]any{"rules": rules}) + `}`)
	var reply struct {
		Success bool                     `json:"success"`
		Data    ProcessRuleCheckResponse `json:"data"`
		Error   string                   `json:"error"`
	}
	if err := json.Unmarshal([]byte(raw), &reply); err != nil || !reply.Success {
		t.Fatalf("checkProcessRules: %s", raw)
	}
	if !reply.Data.Listed {
		t.Fatal("running programs were not listed")
	}
	for i, check := range reply.Data.Rules {
		running := i < 3
		if (check.Running > 0) != running {
			t.Errorf("%q: %d running, want running=%v", check.Rule, check.Running, running)
		}
	}
}

func TestProcessRuleChecksRejectInvalidRequests(t *testing.T) {
	long := strings.Repeat("a", 1025)
	tooMany := make([]string, 257)
	for i := range tooMany {
		tooMany[i] = "curl"
	}
	for _, rules := range [][]string{{long}, tooMany, {""}, {"a\nb"}} {
		raw := Invoke(`{"apiVersion":1,"method":"checkProcessRules","payload":` + mustJSON(t, map[string]any{"rules": rules}) + `}`)
		if !strings.Contains(raw, `"success":false`) {
			t.Errorf("%d rules accepted: %s", len(rules), raw[:min(len(raw), 120)])
		}
	}
}

func mustJSON(t *testing.T, value any) string {
	t.Helper()
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}
