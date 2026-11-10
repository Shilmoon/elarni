//go:build !windows

package libXray

func localRulePath(string) bool { return true }

// Service rules name Windows services.
func serviceInstalled(string) bool { return true }
