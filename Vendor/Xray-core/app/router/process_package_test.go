package router

import "testing"

// Elarni: Microsoft Store apps such as Claude run from
// <volume>\WindowsApps\<name>_<version>_<arch>_<resource>_<publisher>\, a new folder with every
// update, so a rule saved from the running app stopped matching after the next update.
func TestWindowsPackageFolderComparesAsItsFamily(t *testing.T) {
	const family = "c:/program files/windowsapps/claude_pzs8sxrjxfjjc"
	for _, tc := range []struct{ path, want string }{
		{"c:/program files/windowsapps/claude_4.23118.0.0_x64__pzs8sxrjxfjjc/app/claude.exe", family + "/app/claude.exe"},
		{"c:/program files/windowsapps/claude_4.24001.0.0_x64__pzs8sxrjxfjjc/app/claude.exe", family + "/app/claude.exe"},
		{"c:/program files/windowsapps/claude_4.23118.0.0_x64__pzs8sxrjxfjjc/", family + "/"},
		{"c:/program files/windowsapps/claude_4.23118.0.0_arm64__pzs8sxrjxfjjc/app/claude.exe", family + "/app/claude.exe"},
		// The family form itself, as the app picker saves it.
		{family + "/", family + "/"},
		// Bundles carry a resource id; other volumes have their own WindowsApps folder.
		{"d:/windowsapps/5319275a.whatsappdesktop_2.2450.6.0_neutral_~_cv1g1gvanyjgm/whatsapp.exe",
			"d:/windowsapps/5319275a.whatsappdesktop_cv1g1gvanyjgm/whatsapp.exe"},
		// Only a folder directly in WindowsApps is a package; anywhere else the name is just a name.
		{"c:/apps/claude_4.23118.0.0_x64__pzs8sxrjxfjjc/app/claude.exe", "c:/apps/claude_4.23118.0.0_x64__pzs8sxrjxfjjc/app/claude.exe"},
		{"c:/program files/windowsapps/vendor/claude_4.23118.0.0_x64__pzs8sxrjxfjjc/claude.exe",
			"c:/program files/windowsapps/vendor/claude_4.23118.0.0_x64__pzs8sxrjxfjjc/claude.exe"},
		// Names that are not package full names stay as they are.
		{"c:/program files/windowsapps/claude_4.23118_x64__pzs8sxrjxfjjc/claude.exe", "c:/program files/windowsapps/claude_4.23118_x64__pzs8sxrjxfjjc/claude.exe"},
		{"c:/program files/windowsapps/claude_4.23118.0.0_x65__pzs8sxrjxfjjc/claude.exe", "c:/program files/windowsapps/claude_4.23118.0.0_x65__pzs8sxrjxfjjc/claude.exe"},
		{"c:/program files/windowsapps/claude_4.23118.0.0_x64__pzs8sxrjxfjj/claude.exe", "c:/program files/windowsapps/claude_4.23118.0.0_x64__pzs8sxrjxfjj/claude.exe"},
		{"c:/program files/windowsapps/_4.23118.0.0_x64__pzs8sxrjxfjjc/claude.exe", "c:/program files/windowsapps/_4.23118.0.0_x64__pzs8sxrjxfjjc/claude.exe"},
		{"c:/users/me/appdata/local/microsoft/windowsapps/winget.exe", "c:/users/me/appdata/local/microsoft/windowsapps/winget.exe"},
		{"claude", "claude"},
	} {
		if got := windowsPackageFamilyPath(tc.path); got != tc.want {
			t.Errorf("windowsPackageFamilyPath(%q) = %q, want %q", tc.path, got, tc.want)
		}
	}
}
