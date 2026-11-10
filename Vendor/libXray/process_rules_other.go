//go:build !windows

package libXray

func localRulePath(string) bool { return true }
