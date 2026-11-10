package libXray

import (
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"unicode"

	"github.com/xtls/xray-core/app/router"
	xnet "github.com/xtls/xray-core/common/net"
)

// Elarni: the per-app editor asks which rules match running programs and why a rule may match
// nothing. Counts use the core's own matcher; file checks report only what they could read.

type ProcessRuleCheckRequest struct {
	Rules []string `json:"rules"`
}

type ProcessRuleWarning struct {
	// missing, folder, notFolder, script, symlink, case, launcher or bundleName. Flatpak, AppImage
	// and service rules can be missing; an AppImage rule's path can also need a fix.
	Code       string `json:"code"`
	Suggestion string `json:"suggestion,omitempty"`
}

type ProcessRuleCheck struct {
	Rule     string               `json:"rule"`
	Running  int                  `json:"running"`
	Warnings []ProcessRuleWarning `json:"warnings"`
}

type ProcessRuleCheckResponse struct {
	Rules []ProcessRuleCheck `json:"rules"`
	// False when the running programs could not be listed; the counts are then 0.
	Listed bool `json:"listed"`
}

func invokeCheckProcessRules(payload json.RawMessage) string {
	request, err := decodePayload[ProcessRuleCheckRequest](payload)
	if err != nil || !validProcessRules(request.Rules) {
		return encodeInvokeResponse(nil, errors.New("invalid_rules"))
	}
	return encodeInvokeResponse(checkProcessRules(request.Rules), nil)
}

// The same bounds as per-app settings: 256 rules of 1024 bytes without control characters.
func validProcessRules(rules []string) bool {
	if len(rules) > 256 {
		return false
	}
	for _, rule := range rules {
		if rule == "" || len(rule) > 1024 || strings.TrimSpace(rule) != rule ||
			strings.IndexFunc(rule, unicode.IsControl) >= 0 {
			return false
		}
	}
	return true
}

func checkProcessRules(rules []string) ProcessRuleCheckResponse {
	processes, err := xnet.ListProcesses()
	response := ProcessRuleCheckResponse{Rules: make([]ProcessRuleCheck, 0, len(rules)), Listed: err == nil}
	for _, rule := range rules {
		check := ProcessRuleCheck{Rule: rule, Warnings: processRuleWarnings(rule)}
		if rule != "-1" {
			matcher := router.NewProcessNameMatcher([]string{rule})
			for _, process := range processes {
				if matcher.MatchesProcess(process.PID, process.Name, process.Path) {
					check.Running++
				}
			}
		}
		response.Rules = append(response.Rules, check)
	}
	return response
}

func processRuleWarnings(rule string) []ProcessRuleWarning {
	warn := func(code, suggestion string) []ProcessRuleWarning {
		return []ProcessRuleWarning{{Code: code, Suggestion: suggestion}}
	}
	// Rules of another system's kind match nothing here; the editor refuses them.
	if id, ok := strings.CutPrefix(rule, "flatpak:"); ok {
		if runtime.GOOS != "linux" || flatpakInstalled(id) {
			return nil
		}
		return warn("missing", "")
	}
	if image, ok := strings.CutPrefix(rule, "appimage:"); ok {
		if runtime.GOOS != "linux" || !strings.HasPrefix(image, "/") {
			return nil
		}
		// The image is a file the app runs from; its suggestions stay AppImage rules.
		warnings := processRuleWarnings(image)
		for i := range warnings {
			if warnings[i].Code == "script" {
				return nil
			}
			if warnings[i].Suggestion != "" {
				warnings[i].Suggestion = "appimage:" + warnings[i].Suggestion
			}
		}
		return warnings
	}
	if service, ok := strings.CutPrefix(rule, "service:"); ok {
		if runtime.GOOS != "windows" || serviceInstalled(service) {
			return nil
		}
		return warn("missing", "")
	}
	windows := runtime.GOOS == "windows"
	slashed := rule
	if windows {
		slashed = strings.ReplaceAll(rule, `\`, "/")
	}
	if rule == "-1" || !strings.Contains(slashed, "/") {
		lower := strings.ToLower(rule)
		switch {
		case runtime.GOOS == "darwin" && strings.HasSuffix(lower, ".app"):
			return warn("bundleName", existingDir(filepath.Join("/Applications", rule), "/"))
		case windows && windowsLauncher(lower):
			return warn("launcher", "")
		}
		return nil
	}
	if !localRulePath(rule) {
		return nil
	}
	sep := string(filepath.Separator)
	folder := strings.HasSuffix(slashed, "/")
	suffix := "" // a suggestion for a folder rule stays a folder rule
	if folder {
		suffix = sep
	}
	path := filepath.FromSlash(strings.TrimSuffix(slashed, "/"))
	info, err := ruleLstat(path)
	if err != nil {
		if !errors.Is(err, fs.ErrNotExist) {
			return nil // unreadable here, as from the App Sandbox
		}
		if real := realCase(path); real != "" && !windows {
			return warn("case", real+suffix)
		}
		return warn("missing", "")
	}
	if !windows {
		// macOS disks ignore case, but rules compare it.
		if real := realCase(path); real != "" && real != path {
			return warn("case", real+suffix)
		}
		if info.Mode()&fs.ModeSymlink != 0 {
			// The process is the link's target; macOS and Linux report that path.
			if target, err := filepath.EvalSymlinks(path); err == nil {
				return warn("symlink", target+suffix)
			}
			return nil
		}
	}
	switch {
	case folder && !info.IsDir():
		return warn("notFolder", path)
	case folder:
		return nil
	case info.IsDir():
		// Without the separator the rule is an exact path, which no process has.
		return warn("folder", path+sep)
	case windows && windowsLauncher(strings.ToLower(path)):
		return warn("launcher", "")
	case windows:
		if root := squirrelRoot(path); root != "" {
			return warn("launcher", root+sep)
		}
	case script(path):
		return warn("script", "")
	}
	return nil
}

// ruleLstat is swapped by tests to see which paths a check opens.
var ruleLstat = os.Lstat

// flatpakInstallations lists the Flatpak installations: the user's and the system's.
var flatpakInstallations = func() []string {
	var dirs []string
	if dir := os.Getenv("FLATPAK_USER_DIR"); dir != "" {
		dirs = append(dirs, dir)
	} else if home, err := os.UserHomeDir(); err == nil {
		dirs = append(dirs, filepath.Join(home, ".local", "share", "flatpak"))
	}
	if dir := os.Getenv("FLATPAK_SYSTEM_DIR"); dir != "" {
		return append(dirs, dir)
	}
	return append(dirs, "/var/lib/flatpak")
}

// flatpakInstalled reports an app installed in a Flatpak installation, or one this check cannot
// see.
func flatpakInstalled(id string) bool {
	if !xnet.ValidFlatpakApp(id) {
		return false
	}
	for _, dir := range flatpakInstallations() {
		if _, err := os.Stat(filepath.Join(dir, "app", id)); !errors.Is(err, fs.ErrNotExist) {
			return true
		}
	}
	return false
}

func windowsLauncher(name string) bool {
	for _, extension := range []string{".lnk", ".url", ".bat", ".cmd", ".ps1", ".vbs"} {
		if strings.HasSuffix(name, extension) {
			return true
		}
	}
	return false
}

// squirrelRoot returns the install folder when path is a Squirrel app's root stub (Discord,
// Slack): <root>\Update.exe and <root>\app-<version>\ beside <root>\<name>.exe.
func squirrelRoot(path string) string {
	root := filepath.Dir(path)
	if !strings.HasSuffix(strings.ToLower(path), ".exe") || strings.EqualFold(filepath.Base(path), "Update.exe") {
		return ""
	}
	if info, err := os.Stat(filepath.Join(root, "Update.exe")); err != nil || info.IsDir() {
		return ""
	}
	entries, err := os.ReadDir(root)
	if err != nil {
		return ""
	}
	for _, entry := range entries {
		if entry.IsDir() && strings.HasPrefix(strings.ToLower(entry.Name()), "app-") {
			return root
		}
	}
	return ""
}

// script reports a file that starts with "#!": the running process is its interpreter.
func script(path string) bool {
	file, err := os.Open(path)
	if err != nil {
		return false
	}
	defer file.Close()
	head := make([]byte, 2)
	_, err = io.ReadFull(file, head)
	return err == nil && string(head) == "#!"
}

func existingDir(path, suffix string) string {
	if info, err := os.Stat(path); err == nil && info.IsDir() {
		return path + suffix
	}
	return ""
}

// realCase spells an absolute path as the disk does, or returns "" when no entry matches in
// any letter case or a folder cannot be read.
func realCase(path string) string {
	if !filepath.IsAbs(path) {
		return ""
	}
	volume := filepath.VolumeName(path)
	real := volume + string(filepath.Separator)
	for _, part := range strings.Split(strings.Trim(path[len(volume):], string(filepath.Separator)), string(filepath.Separator)) {
		if part == "" {
			continue
		}
		entries, err := os.ReadDir(real)
		if err != nil {
			return ""
		}
		found := ""
		for _, entry := range entries {
			if entry.Name() == part {
				found = part
				break
			}
			if found == "" && strings.EqualFold(entry.Name(), part) {
				found = entry.Name()
			}
		}
		if found == "" {
			return ""
		}
		real = filepath.Join(real, found)
	}
	return real
}
