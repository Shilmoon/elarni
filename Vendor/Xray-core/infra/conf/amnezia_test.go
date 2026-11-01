package conf

import (
	"strconv"
	"strings"
	"testing"

	awg "github.com/amnezia-vpn/amneziawg-go/v3/device"
)

// The engine allocates junk and I-packets on every handshake and reads transport
// packets at offset 16+S4 into a MaxSegmentSize buffer, trusting these values.
func TestAmneziaSettingsTheEngineCannotRunAreRejected(t *testing.T) {
	s4 := awg.MaxSegmentSize - awg.MessageTransportSize
	for _, settings := range []map[string]string{
		{"jc": "2", "jmin": "40"},
		{"jc": "1", "jmax": "4294967295"},
		{"jc": "4294967295"},
		{"jc": "4", "jmin": "1281", "jmax": "1300"},
		{"i1": "<r -1>"},
		{"i2": "<rc 70000>"},
		{"i3": strings.Repeat("<rd 65535>", 2)},
		{"s4": strconv.Itoa(s4 + 1)},
	} {
		if validateAmneziaSettings(settings) == nil {
			t.Errorf("%v accepted", settings)
		}
	}
	for _, settings := range []map[string]string{
		{"jc": "128", "jmin": "1280", "jmax": "1280", "s4": strconv.Itoa(s4), "i1": "<r 65535>"},
		{"jmin": "40"},
	} {
		if err := validateAmneziaSettings(settings); err != nil {
			t.Errorf("%v rejected: %v", settings, err)
		}
	}
}

// AWG 2.0 headers are ranges, and the engine sorts each packet by the range its
// type falls in; an unset header keeps WireGuard's type 1-4. Overlapping ranges
// used to import and then fail only at connect.
func TestOverlappingAmneziaHeaderRangesAreRejected(t *testing.T) {
	for _, settings := range []map[string]string{
		{"h1": "100-200", "h2": "150-300", "h3": "400", "h4": "500"},
		{"h1": "1-5"},
		{"h4": "3"},
	} {
		if validateAmneziaSettings(settings) == nil {
			t.Errorf("%v accepted", settings)
		}
	}
	for _, settings := range []map[string]string{
		{"h1": "100000-100100", "h2": "200000-200100", "h3": "300000-300100", "h4": "400000-400100"},
		{"h1": "5-10"},
		{"h1": "1234567", "h2": "7654321", "h3": "3", "h4": "4"},
	} {
		if err := validateAmneziaSettings(settings); err != nil {
			t.Errorf("%v rejected: %v", settings, err)
		}
	}
}
