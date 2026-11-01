package geo

import (
	"errors"
	"maps"
	"slices"
	"strings"

	"github.com/xtls/xray-core/common/geodata"
	"google.golang.org/protobuf/encoding/protowire"
	"google.golang.org/protobuf/proto"
)

// MissingError lists the selectors whose codes a file lacks although a rule needs them.
type MissingError []string

func (MissingError) Error() string { return "missing_geodata" }

// Reduce keeps complete referenced records, including attributes and unknown
// protobuf fields. External selectors require the original full logical file.
// Optional selectors come from Direct and Block rules and domestic DNS domains: a
// code only they name may be missing, and then gets an empty record, which Xray
// loads as matching nothing. Reduce returns those skipped selectors.
func Reduce(name string, data []byte, selectors, optional []string, reduce bool) ([]byte, string, []string, error) {
	invalid := errors.New("invalid_geodata")
	if len(data) == 0 || len(data) > 64*1024*1024 {
		return nil, "", nil, invalid
	}
	wanted := map[string]bool{} // code -> whether a missing record is an error
	status := "disabled"
	if reduce {
		status = "ready"
	}
	for i, selector := range append(slices.Clip(selectors), optional...) {
		// Xray reads a leading ! on an IP rule like one before the code.
		bare := strings.TrimLeft(selector, "!")
		// Xray reads ext-site: and ext-domain: from the named file as it does ext:.
		if prefix, _, _ := strings.Cut(bare, ":"); slices.Contains([]string{"ext", "ext-ip", "ext-site", "ext-domain"}, prefix) {
			reduce = false
			status = "fullFileFallback"
		}
		if suffix, ok := strings.CutPrefix(strings.ToLower(bare), name+":"); ok {
			code, _, _ := strings.Cut(strings.TrimLeft(suffix, "!"), "@")
			if code != "" {
				// An empty record would make a negated selector match everything.
				wanted[code] = wanted[code] || i < len(selectors) || bare != selector || strings.HasPrefix(suffix, "!")
			}
		}
	}
	seen := map[string]bool{}
	reducing := reduce && len(wanted) > 0
	var result []byte
	switch name {
	case "geoip":
		var list geodata.GeoIPList
		if proto.Unmarshal(data, &list) != nil || len(list.Entry) == 0 {
			return nil, "", nil, invalid
		}
		kept := make([]*geodata.GeoIP, 0)
		for _, entry := range list.Entry {
			code := strings.ToLower(entry.Code)
			if code == "" || seen[code] {
				return nil, "", nil, invalid
			}
			seen[code] = true
			for _, cidr := range entry.Cidr {
				if (len(cidr.Ip) != 4 && len(cidr.Ip) != 16) || cidr.Prefix > uint32(len(cidr.Ip)*8) {
					return nil, "", nil, invalid
				}
			}
			if _, ok := wanted[code]; ok {
				kept = append(kept, entry)
			}
		}
		if reducing {
			list.Entry = kept
			var err error
			if result, err = proto.Marshal(&list); err != nil {
				return nil, "", nil, err
			}
		}
	case "geosite":
		var list geodata.GeoSiteList
		if proto.Unmarshal(data, &list) != nil || len(list.Entry) == 0 {
			return nil, "", nil, invalid
		}
		kept := make([]*geodata.GeoSite, 0)
		for _, entry := range list.Entry {
			code := strings.ToLower(entry.Code)
			if code == "" || seen[code] {
				return nil, "", nil, invalid
			}
			seen[code] = true
			for _, domain := range entry.Domain {
				if domain.Value == "" || domain.Type < 0 || domain.Type > 3 {
					return nil, "", nil, invalid
				}
			}
			if _, ok := wanted[code]; ok {
				kept = append(kept, entry)
			}
		}
		if reducing {
			list.Entry = kept
			var err error
			if result, err = proto.Marshal(&list); err != nil {
				return nil, "", nil, err
			}
		}
	default:
		return nil, "", nil, invalid
	}
	if !reducing {
		result = data
	}
	var missing MissingError
	skipped := []string{}
	var empty []byte
	for _, code := range slices.Sorted(maps.Keys(wanted)) {
		switch {
		case seen[code]:
		case wanted[code]:
			missing = append(missing, name+":"+code)
		default:
			skipped = append(skipped, name+":"+code)
			// GeoIP and GeoSite both keep the code in field 1; Xray matches it upper-cased.
			record := protowire.AppendString(protowire.AppendTag(nil, 1, protowire.BytesType), strings.ToUpper(code))
			empty = protowire.AppendBytes(protowire.AppendTag(empty, 1, protowire.BytesType), record)
		}
	}
	if len(missing) > 0 {
		return nil, "", nil, missing
	}
	return append(slices.Clip(result), empty...), status, skipped, nil
}
