package conf

import (
	"fmt"
	"slices"
	"strconv"
	"strings"

	awg "github.com/amnezia-vpn/amneziawg-go/v3/device"
)

// Values use the engine's UAPI spelling. Never accept arbitrary UAPI commands.
func validateAmneziaSettings(settings map[string]string) error {
	for key, value := range settings {
		if strings.ContainsAny(value, "\r\n\x00") || len(value) > 65535 {
			return fmt.Errorf("invalid AmneziaWG %s", key)
		}
		var err error
		switch key {
		case "jc", "jmin", "jmax":
			// The AmneziaWG kernel module's limits: at most 128 junk packets of 1280 bytes.
			limit := uint64(1280)
			if key == "jc" {
				limit = 128
			}
			var n uint64
			if n, err = strconv.ParseUint(value, 10, 32); err == nil && n > limit {
				err = fmt.Errorf("out of range")
			}
		case "s1", "s2", "s3":
			_, err = strconv.ParseUint(value, 10, 16)
		case "s4":
			// The engine reads each packet at offset 16+S4 into a MaxSegmentSize buffer.
			var n uint64
			if n, err = strconv.ParseUint(value, 10, 16); err == nil && n > awg.MaxSegmentSize-awg.MessageTransportSize {
				err = fmt.Errorf("out of range")
			}
		case "h1", "h2", "h3", "h4", "content_padding_addition", "rekey_after_time", "rekey_timeout", "reject_after_time", "keepalive_timeout", "max_handshake_attempts":
			var r awg.UintRange
			err = r.FromString(value)
		case "header_protection_key":
			var k awg.HeaderCipherKey
			err = k.FromHex(value)
		case "random_trailers", "disable_cookies":
			_, err = strconv.ParseBool(value)
		case "i1", "i2", "i3", "i4", "i5":
			// The engine validates the obfuscation grammar when applying IpcSet.
			err = validateAmneziaPacketLength(value)
		default:
			return fmt.Errorf("unsupported AmneziaWG setting %s", key)
		}
		if err != nil {
			return fmt.Errorf("invalid AmneziaWG %s", key)
		}
	}
	min, _ := strconv.ParseUint(settings["jmin"], 10, 32)
	max, _ := strconv.ParseUint(settings["jmax"], 10, 32)
	count, _ := strconv.ParseUint(settings["jc"], 10, 32)
	// The engine sizes junk as Jmin plus a random share of Jmax-Jmin, a missing Jmax as 0.
	if _, present := settings["jmax"]; (present || count > 0) && min > max {
		return fmt.Errorf("AmneziaWG Jmin exceeds Jmax")
	}
	// The engine sorts each packet by the header range its type falls in and refuses
	// overlapping ranges at connect; an unset header keeps WireGuard's type 1-4.
	var headers [4]awg.UintRange
	for i, key := range []string{"h1", "h2", "h3", "h4"} {
		if value, present := settings[key]; present {
			headers[i].FromString(value)
		} else {
			headers[i].FromUint32(uint32(i+1), uint32(i+1))
		}
	}
	for i := range headers {
		for j := i + 1; j < len(headers); j++ {
			if headers[i].Overlap(headers[j]) {
				return fmt.Errorf("AmneziaWG headers H%d and H%d overlap", i+1, j+1)
			}
		}
	}
	return nil
}

// The engine allocates the length tags of an I-packet on every handshake and
// takes negative lengths; bound them by the largest UDP datagram.
func validateAmneziaPacketLength(spec string) error {
	total := 0
	for rest := spec; ; {
		start := strings.IndexByte(rest, '<')
		if start == -1 {
			return nil
		}
		end := strings.IndexByte(rest[start:], '>')
		if end == -1 {
			return nil // the engine rejects the unclosed tag
		}
		fields := strings.Fields(rest[start+1 : start+end])
		rest = rest[start+end+1:]
		if len(fields) < 2 || !slices.Contains([]string{"r", "rc", "rd", "dz"}, fields[0]) {
			continue
		}
		length, err := strconv.Atoi(fields[1])
		if err != nil || length < 0 || length > 65535-total {
			return fmt.Errorf("invalid packet length")
		}
		total += length
	}
}
