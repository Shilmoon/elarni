package net

import "strings"

// Elarni: per-app rules can name an app by what the system knows of its processes beyond their
// path: a Flatpak sandbox's app ID and an AppImage's file on Linux, the services a Windows
// process runs. AppRule gives the connections view that rule for a program.

// ValidFlatpakApp reports a plausible Flatpak app ID: reverse-DNS names of letters, digits, "_"
// and "-".
func ValidFlatpakApp(id string) bool {
	if len(id) == 0 || len(id) > 255 || strings.Trim(id, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-") != "" {
		return false
	}
	parts := strings.Split(id, ".")
	for _, part := range parts {
		if part == "" {
			return false
		}
	}
	return len(parts) > 1
}

// svchostName reports Windows's shared service host, by file name with or without ".exe".
func svchostName(name string) bool {
	return strings.EqualFold(strings.TrimSuffix(strings.ToLower(name), ".exe"), "svchost")
}
