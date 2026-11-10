//go:build !android

package net

// PrefetchSocketOwner is Android's: desktop lookups scan the system's socket
// tables (every TCP row on Windows), too costly to run for every new flow.
func PrefetchSocketOwner(network, srcIP string, srcPort uint16, destIP string, destPort uint16) {}
