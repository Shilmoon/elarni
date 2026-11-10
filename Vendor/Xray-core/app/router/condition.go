package router

import (
	"context"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"slices"
	"strings"
	"time"

	"github.com/xtls/xray-core/common/errors"
	"github.com/xtls/xray-core/common/flightrecorder"
	"github.com/xtls/xray-core/common/geodata"
	"github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/features/routing"
	"github.com/xtls/xray-core/features/routing/dns"
	routingsession "github.com/xtls/xray-core/features/routing/session"
)

type Condition interface {
	Apply(ctx routing.Context) bool
}

type ConditionChan []Condition

func NewConditionChan() *ConditionChan {
	var condChan ConditionChan = make([]Condition, 0, 8)
	return &condChan
}

func (v *ConditionChan) Add(cond Condition) *ConditionChan {
	*v = append(*v, cond)
	return v
}

// Apply applies all conditions registered in this chan.
func (v *ConditionChan) Apply(ctx routing.Context) bool {
	for _, cond := range *v {
		if !cond.Apply(ctx) {
			return false
		}
	}
	return true
}

func (v *ConditionChan) Len() int {
	return len(*v)
}

type DomainMatcher struct{ geodata.DomainMatcher }

func NewDomainMatcher(rules []*geodata.DomainRule) (*DomainMatcher, error) {
	m, err := geodata.DomainReg.BuildDomainMatcher(rules)
	if err != nil {
		return nil, err
	}
	return &DomainMatcher{DomainMatcher: m}, nil
}

func (m *DomainMatcher) ApplyDomain(domain string) bool {
	return m.DomainMatcher.MatchAny(strings.ToLower(domain))
}

// Apply implements Condition.
func (m *DomainMatcher) Apply(ctx routing.Context) bool {
	domain := ctx.GetTargetDomain()
	if len(domain) == 0 {
		return false
	}
	return m.DomainMatcher.MatchAny(strings.ToLower(domain))
}

type MatcherAsType byte

const (
	MatcherAsType_Local MatcherAsType = iota
	MatcherAsType_Source
	MatcherAsType_Target
	MatcherAsType_VlessRoute // for port
)

type IPMatcher struct {
	matcher geodata.IPMatcher
	asType  MatcherAsType
}

func NewIPMatcher(rules []*geodata.IPRule, asType MatcherAsType) (*IPMatcher, error) {
	m, err := geodata.IPReg.BuildIPMatcher(rules)
	if err != nil {
		return nil, err
	}
	return &IPMatcher{matcher: m, asType: asType}, nil
}

// Apply implements Condition.
func (m *IPMatcher) Apply(ctx routing.Context) bool {
	var ips []net.IP

	switch m.asType {
	case MatcherAsType_Local:
		ips = ctx.GetLocalIPs()
	case MatcherAsType_Source:
		ips = ctx.GetSourceIPs()
	case MatcherAsType_Target:
		ips = ctx.GetTargetIPs()
	default:
		panic("unk asType")
	}

	return m.matcher.AnyMatch(ips)
}

type PortMatcher struct {
	port   net.MemoryPortList
	asType MatcherAsType
}

// NewPortMatcher create a new port matcher that can match source or local or destination port
func NewPortMatcher(list *net.PortList, asType MatcherAsType) *PortMatcher {
	return &PortMatcher{
		port:   net.PortListFromProto(list),
		asType: asType,
	}
}

// Apply implements Condition.
func (v *PortMatcher) Apply(ctx routing.Context) bool {
	switch v.asType {
	case MatcherAsType_Local:
		return v.port.Contains(ctx.GetLocalPort())
	case MatcherAsType_Source:
		return v.port.Contains(ctx.GetSourcePort())
	case MatcherAsType_Target:
		return v.port.Contains(ctx.GetTargetPort())
	case MatcherAsType_VlessRoute:
		return v.port.Contains(ctx.GetVlessRoute())
	default:
		panic("unk asType")
	}
}

type NetworkMatcher struct {
	list [8]bool
}

func NewNetworkMatcher(network []net.Network) NetworkMatcher {
	var matcher NetworkMatcher
	for _, n := range network {
		matcher.list[int(n)] = true
	}
	return matcher
}

// Apply implements Condition.
func (v NetworkMatcher) Apply(ctx routing.Context) bool {
	return v.list[int(ctx.GetNetwork())]
}

type UserMatcher struct {
	user    []string
	pattern []*regexp.Regexp
}

func NewUserMatcher(users []string) *UserMatcher {
	usersCopy := make([]string, 0, len(users))
	patternsCopy := make([]*regexp.Regexp, 0, len(users))
	for _, user := range users {
		if len(user) > 0 {
			if len(user) > 7 && strings.HasPrefix(user, "regexp:") {
				if re, err := regexp.Compile(user[7:]); err == nil {
					patternsCopy = append(patternsCopy, re)
				}
				// Items of users slice with an invalid regexp syntax are ignored.
				continue
			}
			usersCopy = append(usersCopy, user)
		}
	}
	return &UserMatcher{
		user:    usersCopy,
		pattern: patternsCopy,
	}
}

// Apply implements Condition.
func (v *UserMatcher) Apply(ctx routing.Context) bool {
	user := ctx.GetUser()
	if len(user) == 0 {
		return false
	}
	for _, u := range v.user {
		if u == user {
			return true
		}
	}
	for _, re := range v.pattern {
		if re.MatchString(user) {
			return true
		}
	}
	return false
}

type InboundTagMatcher struct {
	tags []string
}

func NewInboundTagMatcher(tags []string) *InboundTagMatcher {
	tagsCopy := make([]string, 0, len(tags))
	for _, tag := range tags {
		if len(tag) > 0 {
			tagsCopy = append(tagsCopy, tag)
		}
	}
	return &InboundTagMatcher{
		tags: tagsCopy,
	}
}

// Apply implements Condition.
func (v *InboundTagMatcher) Apply(ctx routing.Context) bool {
	tag := ctx.GetInboundTag()
	if len(tag) == 0 {
		return false
	}
	for _, t := range v.tags {
		if t == tag {
			return true
		}
	}
	return false
}

type ProtocolMatcher struct {
	protocols []string
}

func NewProtocolMatcher(protocols []string) *ProtocolMatcher {
	pCopy := make([]string, 0, len(protocols))

	for _, p := range protocols {
		if len(p) > 0 {
			pCopy = append(pCopy, p)
		}
	}

	return &ProtocolMatcher{
		protocols: pCopy,
	}
}

// Apply implements Condition.
func (m *ProtocolMatcher) Apply(ctx routing.Context) bool {
	protocol := ctx.GetProtocol()
	if len(protocol) == 0 {
		return false
	}
	for _, p := range m.protocols {
		if strings.HasPrefix(protocol, p) {
			return true
		}
	}
	return false
}

type AttributeMatcher struct {
	configuredKeys map[string]*regexp.Regexp
}

// Match implements attributes matching.
func (m *AttributeMatcher) Match(attrs map[string]string) bool {
	// header keys are case insensitive most likely. So we do a convert
	httpHeaders := make(map[string]string)
	for key, value := range attrs {
		httpHeaders[strings.ToLower(key)] = value
	}
	for key, regex := range m.configuredKeys {
		if a, ok := httpHeaders[key]; !ok || !regex.MatchString(a) {
			return false
		}
	}
	return true
}

// Apply implements Condition.
func (m *AttributeMatcher) Apply(ctx routing.Context) bool {
	attributes := ctx.GetAttributes()
	if attributes == nil {
		return false
	}
	return m.Match(attributes)
}

type ProcessNameMatcher struct {
	ProcessNames  []string
	AbsPaths      []string
	Folders       []string
	MatchXraySelf bool
	// Elarni: "-1" also names the owner of a local flow that the lookup could not find
	// (Android's finder already returns that name). Such a flow may belong to a listed
	// app, so "Only listed" keeps it in the tunnel.
	MatchUnknown bool
	// Elarni: apps that a path does not name. "flatpak:<app id>" is a Flatpak sandbox,
	// "appimage:<file>" an AppImage, or every AppImage in "appimage:<folder>/" (Linux), and
	// "service:<name>" a Windows service by its name, the process that runs it.
	FlatpakApps []string
	AppImages   []string
	Services    []string
}

// Elarni: what the system knows of a process beyond its path; tests replace these.
var (
	processFlatpakApp = net.FlatpakApp
	processAppImage   = net.AppImage
	processServices   = net.ProcessServices
)

func NewProcessNameMatcher(names []string) *ProcessNameMatcher {
	processNames := []string{}
	folders := []string{}
	absPaths := []string{}
	var flatpakApps, appImages, services []string
	matchXraySelf := false
	for _, name := range names {
		if name == "self/" {
			matchXraySelf = true
			continue
		}
		if id, ok := strings.CutPrefix(name, "flatpak:"); ok {
			flatpakApps = append(flatpakApps, id)
			continue
		}
		if image, ok := strings.CutPrefix(name, "appimage:"); ok {
			appImages = append(appImages, image)
			continue
		}
		if service, ok := strings.CutPrefix(name, "service:"); ok {
			services = append(services, strings.ToLower(service))
			continue
		}
		// replace xray/ with self executable path
		if name == "xray/" {
			xrayPath, err := os.Executable()
			if err != nil {
				errors.LogError(context.Background(), "Failed to get xray executable path: ", err)
				continue
			}
			name = xrayPath
		}
		name := filepath.ToSlash(name)
		if runtime.GOOS == "windows" {
			name = windowsPackageFamilyPath(strings.ToLower(name))
		}
		// /usr/bin/
		if strings.HasSuffix(name, "/") {
			folders = append(folders, name)
			continue
		}
		// /usr/bin/curl
		if strings.Contains(name, "/") {
			absPaths = append(absPaths, name)
			continue
		}
		// curl.exe or curl
		processNames = append(processNames, strings.TrimSuffix(name, ".exe"))
	}
	return &ProcessNameMatcher{
		ProcessNames:  processNames,
		AbsPaths:      absPaths,
		Folders:       folders,
		MatchXraySelf: matchXraySelf,
		MatchUnknown:  slices.Contains(processNames, "-1"),
		FlatpakApps:   flatpakApps,
		AppImages:     appImages,
		Services:      services,
	}
}

// Elarni: Microsoft Store (MSIX) apps run from <volume>\WindowsApps\<name>_<version>_<arch>_<resource>_<publisher>\,
// a new folder with every update. Rules and process paths compare that folder as <name>_<publisher>, its
// package family, so a rule saved for one version matches the next. Only Windows can install there: the
// folder is writable by the system alone. Takes a lowercased path with forward slashes.
func windowsPackageFamilyPath(path string) string {
	const parent = "/windowsapps/"
	start := strings.Index(path, parent)
	if start < 0 {
		return path
	}
	start += len(parent)
	end := strings.IndexByte(path[start:], '/')
	if end < 0 {
		end = len(path)
	} else {
		end += start
	}
	parts := strings.Split(path[start:end], "_")
	if len(parts) != 5 || !packageName(parts[0]) || !packageVersion(parts[1]) ||
		!slices.Contains([]string{"x86", "x64", "arm", "arm64", "neutral", "x86a64"}, parts[2]) ||
		len(parts[4]) != 13 || strings.Trim(parts[4], "abcdefghijklmnopqrstuvwxyz0123456789") != "" {
		return path
	}
	return path[:start] + parts[0] + "_" + parts[4] + path[end:]
}

func packageName(name string) bool {
	return name != "" && strings.Trim(name, "abcdefghijklmnopqrstuvwxyz0123456789.-") == ""
}

func packageVersion(version string) bool {
	fields := strings.Split(version, ".")
	for _, field := range fields {
		if field == "" || strings.Trim(field, "0123456789") != "" {
			return false
		}
	}
	return len(fields) == 4
}

// lookupProcess finds the owner of a local socket; tests replace it.
var lookupProcess = net.FindProcess

func (m *ProcessNameMatcher) Apply(ctx routing.Context) (matched bool) {
	code := "no_source"
	if flightrecorder.Enabled() {
		started := time.Now()
		defer func() {
			if matched && code == "not_matched" {
				code = "matched"
			}
			flightrecorder.Record(flightrecorder.Event{Name: "process_match", Code: code, Values: map[string]int64{"network": int64(ctx.GetNetwork()), "elapsed_us": time.Since(started).Microseconds()}})
		}()
	}
	if len(ctx.GetSourceIPs()) == 0 {
		return false
	}

	srcPort := uint16(ctx.GetSourcePort())
	srcIP := ctx.GetSourceIPs()[0].String()

	var network string
	switch ctx.GetNetwork() {
	case net.Network_TCP:
		network = "tcp"
	case net.Network_UDP:
		network = "udp"
	default:
		code = "unsupported_network"
		return false
	}

	var dstIP string
	var dstPort uint16 = 0

	// Process lookup needs the OS socket tuple, before sniffing/FakeDNS or DNS
	// resolution changed the routing target.
	lookupContext := ctx
	if resolvable, ok := ctx.(*dns.ResolvableContext); ok {
		lookupContext = resolvable.Context
	}
	if original, ok := lookupContext.(*routingsession.Context); ok && original.Outbound != nil && original.Outbound.OriginalTarget.IsValid() && original.Outbound.OriginalTarget.Address.Family().IsIP() {
		dstIP = original.Outbound.OriginalTarget.Address.IP().String()
		dstPort = uint16(original.Outbound.OriginalTarget.Port)
	} else if ips := lookupContext.GetTargetIPs(); len(ips) > 0 {
		dstIP = ips[0].String()
		dstPort = uint16(lookupContext.GetTargetPort())
	}

	find := func() (int, string, string, error) {
		pid, name, path, err := lookupProcess(network, srcIP, srcPort, dstIP, dstPort)
		if err != nil && err != net.ErrNotLocal {
			// Elarni: once per connection rather than per process rule, and at info: the connection is still routed by the other rules.
			errors.LogInfo(context.Background(), "Unable to find the process of ", network, " ", srcIP, ":", srcPort, ": ", err)
		}
		return pid, name, path, err
	}
	var pid int
	var name, absPath string
	var err error
	if original, ok := lookupContext.(*routingsession.Context); ok {
		pid, name, absPath, err = original.LookupProcess(find)
	} else {
		pid, name, absPath, err = find()
	}
	if err != nil {
		if err == net.ErrNotLocal {
			code = "not_local"
			return false
		}
		code = "lookup_failed"
		if m.MatchUnknown {
			code = "unknown_owner"
		}
		return m.MatchUnknown
	}
	code = "not_matched"
	return m.MatchesProcess(pid, name, absPath)
}

// MatchesProcess reports whether the rule names a process, as FindProcess describes it.
// Elarni: the per-app editor counts running programs with it, as routing would match them.
func (m *ProcessNameMatcher) MatchesProcess(pid int, name, absPath string) bool {
	if m.MatchXraySelf && pid == os.Getpid() {
		return true
	}
	// Identity lookups take the process as the lookup reported it.
	reportedName, reportedPath := name, absPath
	if runtime.GOOS == "windows" {
		name = strings.TrimSuffix(strings.ToLower(name), ".exe")
		absPath = windowsPackageFamilyPath(strings.ToLower(absPath))
	}
	if slices.Contains(m.ProcessNames, name) {
		return true
	}
	if slices.Contains(m.AbsPaths, absPath) {
		return true
	}
	for _, f := range m.Folders {
		if strings.HasPrefix(absPath, f) {
			return true
		}
	}
	if pid <= 0 {
		return false
	}
	if len(m.FlatpakApps) > 0 {
		if id := processFlatpakApp(pid); id != "" && slices.Contains(m.FlatpakApps, id) {
			return true
		}
	}
	if len(m.AppImages) > 0 {
		if image := processAppImage(pid, reportedPath); image != "" {
			for _, rule := range m.AppImages {
				if image == rule || strings.HasSuffix(rule, "/") && strings.HasPrefix(image, rule) {
					return true
				}
			}
		}
	}
	if len(m.Services) > 0 {
		for _, service := range processServices(pid, reportedName) {
			if slices.Contains(m.Services, strings.ToLower(service)) {
				return true
			}
		}
	}
	return false
}

// LocalOSMatcher matches the operating system Xray itself is running on. That never
// changes while Xray is running, so the result is resolved when the rule is built.
type LocalOSMatcher struct {
	matched bool
}

func NewLocalOSMatcher(names []string) *LocalOSMatcher {
	return &LocalOSMatcher{
		matched: slices.ContainsFunc(names, func(name string) bool {
			return strings.EqualFold(name, runtime.GOOS)
		}),
	}
}

// Apply implements Condition.
func (m *LocalOSMatcher) Apply(_ routing.Context) bool {
	return m.matched
}
