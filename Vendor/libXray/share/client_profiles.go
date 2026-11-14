package share

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	dnsapp "github.com/xtls/xray-core/app/dns"
	dnsfeature "github.com/xtls/xray-core/features/dns"
	"net"
	"net/url"
	"reflect"
	"regexp"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/xtls/xray-core/infra/conf"
)

type ClientProfile struct {
	Format string          `json:"format"`
	Name   string          `json:"name"`
	Config json.RawMessage `json:"config,omitempty"`
	URL    string          `json:"url,omitempty"`
}

type ClientImport struct {
	Profiles     []ClientProfile   `json:"profiles"`
	Directives   []string          `json:"directives,omitempty"`
	HideURL      bool              `json:"hideURL,omitempty"`
	Migration    map[string]string `json:"-"`
	NewSourceURL string            `json:"newSourceURL,omitempty"`
	FallbackURL  string            `json:"fallbackURL,omitempty"`
	// SystemResolverDNS: a profile's DNS would ask the system resolver, outside the tunnel.
	SystemResolverDNS bool `json:"systemResolverDNS,omitempty"`
	// Skipped lists the first maxSkippedListed members that could not be imported; SkippedCount counts them all.
	Skipped      []SkippedProfile `json:"skipped,omitempty"`
	SkippedCount int              `json:"skippedCount,omitempty"`
}

// SkippedProfile names a feed member that was not imported: its display name when it has a safe one,
// and its kind (a link scheme, "xray", or a Clash proxy type).
type SkippedProfile struct {
	Name string `json:"name,omitempty"`
	Kind string `json:"kind"`
}

// maxSkippedListed bounds the report a provider's feed can make the app show.
const maxSkippedListed = 32

var skippedKindPattern = regexp.MustCompile(`^[a-z][a-z0-9+.-]{0,15}$`)

// skippedMembers collects the members an import passes over, and the first one's error: with
// nothing left to import, that error is the import's, as it was for a single bad member.
type skippedMembers struct {
	list  []SkippedProfile
	count int
	first error
}

func (s *skippedMembers) add(name, kind, fallback string, err error) {
	if s.first == nil {
		s.first = err
	}
	s.count++
	if len(s.list) >= maxSkippedListed {
		return
	}
	// Provider text: shown only when it is short, valid text without control characters.
	if !utf8.ValidString(name) || utf8.RuneCountInString(name) > 128 || strings.IndexFunc(name, unicode.IsControl) >= 0 {
		name = ""
	}
	if !skippedKindPattern.MatchString(kind) {
		kind = fallback
	}
	s.list = append(s.list, SkippedProfile{Name: name, Kind: kind})
}

// addLink names a skipped link by its fragment and scheme, which it may not parse far enough to have.
func (s *skippedMembers) addLink(line string, err error) {
	// Only "scheme://" names a kind: a feed's text line ("status: ...") is no kind of server.
	scheme, _, found := strings.Cut(line, "://")
	if !found {
		scheme = ""
	}
	_, fragment, _ := strings.Cut(line, "#")
	name, unescapeErr := url.PathUnescape(fragment)
	if unescapeErr != nil {
		name = ""
	}
	s.add(name, strings.ToLower(scheme), "link", err)
}

func (s *skippedMembers) report(result *ClientImport) {
	result.Skipped, result.SkippedCount = s.list, s.count
}

// systemResolverDNS reports a DNS block Xray answers from the system resolver over a
// socket outside the tunnel: a "localhost" server, or no server at all.
func systemResolverDNS(config json.RawMessage) bool {
	var profile struct {
		DNS *struct {
			Servers []json.RawMessage `json:"servers"`
		} `json:"dns"`
	}
	if json.Unmarshal(config, &profile) != nil || profile.DNS == nil {
		return false
	}
	if len(profile.DNS.Servers) == 0 {
		return true
	}
	for _, server := range profile.DNS.Servers {
		var address string
		if json.Unmarshal(server, &address) != nil {
			var object struct {
				Address string `json:"address"`
			}
			_ = json.Unmarshal(server, &object)
			address = object.Address
		}
		if strings.EqualFold(address, "localhost") {
			return true
		}
	}
	return false
}

// ImportClientProfiles imports every member of a feed it can and reports the rest in Skipped:
// one unsupported line used to cost the user every server of the subscription. A feed with
// nothing left to import fails with its first member's error; one Xray object, one WireGuard
// configuration and a Clash file's structure still stand or fall as a whole.
func ImportClientProfiles(text string) (*ClientImport, error) {
	input, err := NormalizeClientInput(text)
	if err != nil {
		return nil, err
	}
	text = input.Text
	result, err := importClientProfiles(text)
	if err == nil {
		for _, profile := range result.Profiles {
			result.SystemResolverDNS = result.SystemResolverDNS || systemResolverDNS(profile.Config)
		}
		result.Migration = make(map[string]string)
		for _, line := range strings.Split(text, "\n") {
			for _, name := range []string{"new-url", "new-domain", "fallback-url"} {
				// Happ writes "#name: value", Incy "#name value".
				rest, found := strings.CutPrefix(strings.TrimSpace(line), "#"+name)
				if found && (strings.HasPrefix(rest, ":") || strings.HasPrefix(rest, " ")) {
					result.Migration[name] = strings.TrimSpace(strings.TrimPrefix(rest, ":"))
				}
			}
			key, value, ok := strings.Cut(strings.TrimSpace(line), ":")
			if ok && strings.EqualFold(key, "#hide-url") {
				switch strings.ToLower(strings.TrimSpace(value)) {
				case "1", "true", "yes":
					result.HideURL = true
				}
			}
		}
	}
	return result, err
}

func importClientProfiles(text string) (*ClientImport, error) {
	if len(text) > 4*1024*1024 {
		return nil, fmt.Errorf("profile input exceeds 4 MiB")
	}
	result := &ClientImport{Profiles: []ClientProfile{}}
	firstContent := text
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") || strings.HasPrefix(line, ";") {
			continue
		}
		firstContent = line
		break
	}
	if strings.EqualFold(firstContent, "[interface]") {
		profile, err := importWireGuard(text, false, "")
		if err != nil {
			return nil, err
		}
		return &ClientImport{Profiles: []ClientProfile{profile}}, nil
	}
	var skipped skippedMembers
	if strings.HasPrefix(text, "[") || strings.HasPrefix(text, "{") {
		var profiles []json.RawMessage
		array := strings.HasPrefix(text, "[")
		if array {
			if err := json.Unmarshal([]byte(text), &profiles); err != nil {
				return nil, fmt.Errorf("invalid Xray profile array")
			}
		} else {
			profiles = []json.RawMessage{json.RawMessage(text)}
		}
		for index, raw := range profiles {
			var root map[string]json.RawMessage
			if err := json.Unmarshal(raw, &root); err != nil || root == nil {
				err := fmt.Errorf("profile %d is not an object", index+1)
				if !array {
					return nil, err
				}
				skipped.add("", "xray", "xray", err)
				continue
			}
			var name string
			_ = json.Unmarshal(root["remarks"], &name)
			if name == "" {
				_ = json.Unmarshal(root["name"], &name)
			}
			if _, ok := root["protocol"]; ok {
				raw, _ = json.Marshal(map[string]any{"outbounds": []json.RawMessage{raw}})
			}
			if err := validateClientProfile(raw); err != nil {
				err := fmt.Errorf("profile %d has invalid or unsupported outbound settings", index+1)
				if !array {
					return nil, err
				}
				skipped.add(name, "xray", "xray", err)
				continue
			}
			if name == "" {
				name = fmt.Sprintf("Profile %d", index+1)
			}
			result.Profiles = append(result.Profiles, ClientProfile{Format: "xrayProfile", Name: name, Config: raw})
		}
	} else if hasTopLevelClashProxiesKey(text) {
		return importClashProfiles(text)
	} else {
		for index, line := range strings.Split(text, "\n") {
			line = strings.TrimSpace(line)
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			if strings.HasPrefix(line, "happ://routing/") || strings.HasPrefix(line, "incy://") || strings.HasPrefix(line, "elarni://routing/") {
				result.Directives = append(result.Directives, line)
				continue
			}
			if telegramURL, ok := TelegramProxyURL(line); ok {
				result.Profiles = append(result.Profiles, ClientProfile{Format: "telegram", Name: "Telegram proxy", URL: telegramURL})
				continue
			}
			if strings.HasPrefix(line, "vpn://") || strings.HasPrefix(line, "wireguard://") {
				profile, err := importWireGuardLink(line)
				if err != nil {
					skipped.addLink(line, fmt.Errorf("invalid WireGuard or AmneziaWG link on line %d: %w", index+1, err))
					continue
				}
				result.Profiles = append(result.Profiles, profile)
				continue
			}
			u, err := parseClientLink(line)
			if err != nil {
				skipped.addLink(line, fmt.Errorf("invalid client link on line %d", index+1))
				continue
			}
			outbound, err := (xrayShareLink{link: u, rawText: line}).outbound()
			if err != nil {
				skipped.addLink(line, fmt.Errorf("invalid or unsupported client link on line %d", index+1))
				continue
			}
			name := getOutboundName(*outbound)
			outbound.SendThrough = nil // URI remarks are metadata, never a bind address.
			outbound.Tag = "proxy"
			raw, err := json.Marshal(map[string]any{"outbounds": []conf.OutboundDetourConfig{*outbound}})
			if err != nil || validateClientProfile(raw) != nil {
				skipped.addLink(line, fmt.Errorf("unsupported client settings on line %d", index+1))
				continue
			}
			result.Profiles = append(result.Profiles, ClientProfile{Format: "xrayProfile", Name: name, Config: raw})
		}
	}
	if len(result.Profiles) == 0 && skipped.first != nil {
		return nil, skipped.first
	}
	if len(result.Profiles) == 0 || len(result.Profiles) > 1024 {
		return nil, fmt.Errorf("expected 1 to 1024 client profiles")
	}
	skipped.report(result)
	return result, nil
}

func validateClientProfile(raw json.RawMessage) error {
	if err := ValidateClientFileAccess(raw); err != nil {
		return err
	}
	var config conf.Config
	if err := json.Unmarshal(raw, &config); err != nil {
		return err
	}
	if len(config.OutboundConfigs) == 0 || len(config.OutboundConfigs) > 1024 {
		return fmt.Errorf("invalid outbound count")
	}
	restoreNilRawMessages(reflect.ValueOf(&config))
	if err := config.ValidateTUICChains(); err != nil {
		return err
	}
	for index := range config.OutboundConfigs {
		if err := buildOutbound(&config.OutboundConfigs[index]); err != nil {
			return err
		}
	}
	return nil
}

// ValidateClientFileAccess also guards runtime startup of profiles saved by older
// versions, before Xray configuration building can open local certificate files.
func ValidateClientFileAccess(raw []byte) error {
	var value any
	if err := json.Unmarshal(raw, &value); err != nil {
		return err
	}
	return validateProfileFiles(value, "")
}

// envFields are the JSON fields (lowercase) whose Xray types (Address, PortList, PortRange) read
// a value written as env:NAME from the core's environment; DNS "servers" strings and "hosts"
// values are addresses too.
var envFields = map[string]bool{"address": true, "port": true, "listen": true, "rewriteaddress": true,
	"clientip": true, "ip": true, "sourceport": true, "localport": true, "vlessroute": true,
	"remoteports": true, "qtype": true, "servers": true, "hosts": true}

// envField returns the envFields name key decodes into, or "". Xray's JSON decoder
// matches names by Unicode case folding, so "addreſs" fills Address too.
func envField(key string) string {
	for name := range envFields {
		if strings.EqualFold(key, name) {
			return name
		}
	}
	return ""
}

// field is the JSON field value sits under; array elements and "hosts" entries keep their parent's.
func validateProfileFiles(value any, field string) error {
	switch value := value.(type) {
	case map[string]any:
		for key, child := range value {
			if key == "remarks" { // display text, never an address
				continue
			}
			childField := envField(key)
			if field == "hosts" {
				childField = field
			}
			// Xray decodes JSON field names case-insensitively, including nested
			// transports. Both TLS and REALITY support session-key log files.
			if text, _ := child.(string); text != "" {
				if strings.EqualFold(key, "masterKeyLog") {
					return fmt.Errorf("client profiles cannot enable TLS key logging")
				}
				if strings.EqualFold(key, "certificateFile") || strings.EqualFold(key, "keyFile") {
					return fmt.Errorf("client certificates must be embedded in the profile")
				}
			}
			if err := validateProfileFiles(child, childField); err != nil {
				return err
			}
		}
	case []any:
		for _, child := range value {
			if err := validateProfileFiles(child, field); err != nil {
				return err
			}
		}
	case string:
		// Xray reads an address or port written as env:NAME (or a port list entry)
		// from the core's environment, so a provider could pull local values into
		// server hosts and DNS lookups.
		if !envFields[field] {
			return nil
		}
		for _, part := range strings.Split(value, ",") {
			if strings.HasPrefix(strings.TrimSpace(part), "env:") {
				return fmt.Errorf("client profiles cannot read environment variables")
			}
		}
	}
	return nil
}

// Telegram links are data until the user explicitly activates the handoff.
func TelegramProxyURL(text string) (string, bool) {
	u, err := url.Parse(text)
	if err != nil || u.User != nil {
		return "", false
	}
	if !((u.Scheme == "tg" && u.Host == "proxy" && u.Path == "") ||
		(u.Scheme == "https" && (u.Host == "t.me" || u.Host == "telegram.me") && u.Path == "/proxy")) {
		return "", false
	}
	query, err := url.ParseQuery(u.RawQuery)
	if err != nil || len(query) != 3 {
		return "", false
	}
	for _, key := range []string{"server", "port", "secret"} {
		if len(query[key]) != 1 {
			return "", false
		}
	}
	server := query.Get("server")
	if server == "" || len(server) > 253 || strings.ContainsAny(server, " /?#@\r\n\t") {
		return "", false
	}
	port, err := strconv.ParseUint(query.Get("port"), 10, 16)
	if err != nil || port == 0 {
		return "", false
	}
	secret, err := hex.DecodeString(query.Get("secret"))
	if err != nil || !(len(secret) == 16 || (len(secret) == 17 && secret[0] == 0xdd) || (len(secret) > 17 && secret[0] == 0xee)) {
		return "", false
	}
	return (&url.URL{Scheme: "tg", Host: "proxy", RawQuery: query.Encode()}).String(), true
}

// ProfileHostMappings uses the same matching, blocking and alias semantics as
// the running core. It performs no network queries.
func ProfileHostMappings(configJSON string, hosts []string) (map[string]any, error) {
	var profile struct {
		DNS struct {
			Hosts *conf.HostsWrapper `json:"hosts"`
		} `json:"dns"`
	}
	if err := json.Unmarshal([]byte(configJSON), &profile); err != nil {
		return nil, fmt.Errorf("invalid profile DNS")
	}
	result := map[string]any{}
	if profile.DNS.Hosts == nil {
		return result, nil
	}
	mappings, err := profile.DNS.Hosts.Build()
	if err != nil {
		return nil, fmt.Errorf("invalid profile hosts")
	}
	matcher, err := dnsapp.NewStaticHosts(mappings)
	if err != nil {
		return nil, fmt.Errorf("invalid profile hosts matcher")
	}
	for _, host := range hosts {
		if net.ParseIP(host) != nil {
			continue
		}
		values, err := matcher.Lookup(strings.TrimSuffix(host, "."), dnsfeature.IPOption{IPv4Enable: true, IPv6Enable: true})
		if err != nil || (values != nil && len(values) == 0) {
			result[host] = map[string]any{"blocked": true}
			continue
		}
		if values == nil {
			continue
		}
		if len(values) == 1 && values[0].Family().IsDomain() {
			result[host] = map[string]any{"alias": values[0].Domain()}
			continue
		}
		addresses := []string{}
		for _, value := range values {
			if value.Family().IsIP() {
				addresses = append(addresses, value.IP().String())
			}
		}
		result[host] = map[string]any{"addresses": addresses}
	}
	return result, nil
}
