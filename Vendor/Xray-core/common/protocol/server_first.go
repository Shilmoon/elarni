package protocol

import "github.com/xtls/xray-core/common/net"

// Elarni: clients of these protocols send nothing until the server greets them (FTP, SMTP, POP3,
// IMAP, submission, MySQL, VNC), so waiting for their first bytes only delays the greeting.
var serverFirstPorts = map[net.Port]bool{21: true, 25: true, 110: true, 143: true, 587: true, 3306: true, 5900: true}

// ServerFirst reports whether dest is a TCP port where the server speaks first.
func ServerFirst(dest net.Destination) bool {
	return dest.Network == net.Network_TCP && serverFirstPorts[dest.Port]
}
