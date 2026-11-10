//go:build !(linux && !android) && !windows

package net

// Flatpak, AppImage and service identities exist on Linux and Windows.
func FlatpakApp(int) string { return "" }

func AppImage(int, string) string { return "" }

func ProcessServices(int, string) []string { return nil }

func AppRule(int, string, string) string { return "" }
