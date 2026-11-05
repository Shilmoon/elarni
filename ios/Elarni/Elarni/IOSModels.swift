import Foundation
import Darwin

struct ServerNode: Identifiable {
  let raw: [String: Any]
  let subscriptionID: String
  var id: String { raw["id"] as? String ?? "" }
  var name: String { raw["name"] as? String ?? String(localized: "Server") }
  var protocolName: String { raw["protocol"] as? String ?? "" }
  var transport: String { raw["transport"] as? String ?? "" }
  var security: String { raw["security"] as? String ?? "" }
  var format: String { raw["format"] as? String ?? "xrayProfile" }
  var favorite: Bool { raw["favorite"] as? Bool == true }
  var revision: String { raw["configurationRevision"] as? String ?? "" }
  var ipPreference: String { raw["ipPreference"] as? String ?? "inherit" }
  var lastSuccess: Date? { (raw["lastSuccessAt"] as? Double).map(Date.init(timeIntervalSince1970:)) }
  var successCurrent: Bool { raw["lastSuccessCurrent"] as? Bool == true }
  var groups: [[String: Any]] { raw["groups"] as? [[String: Any]] ?? [] }
  /// As on desktop and Android: name, country, protocol, transport, security or provider.
  func matches(_ search: String, provider: String) -> Bool {
    search.isEmpty || [name, ServerLocation.fromName(name)?.name ?? "", protocolName, transport, security, provider]
      .contains { $0.localizedCaseInsensitiveContains(search) }
  }
}

struct HiddenServer: Identifiable {
  let id: String
  let name: String
}

struct ServerSubscription: Identifiable {
  let raw: [String: Any]
  var id: String { raw["id"] as? String ?? "" }
  var name: String { raw["name"] as? String ?? String(localized: "Subscription") }
  var status: String { raw["status"] as? String ?? "unknown" }
  var local: Bool { raw["isLocal"] as? Bool == true }
  var nodes: [ServerNode] { (raw["nodes"] as? [[String: Any]] ?? []).map { ServerNode(raw: $0, subscriptionID: id) } }
  /// Provider servers the user hid; a refresh keeps them out.
  var hiddenNodes: [HiddenServer] { (raw["hiddenNodes"] as? [[String: Any]] ?? []).map { HiddenServer(id: $0["id"] as? String ?? "", name: $0["name"] as? String ?? String(localized: "Server")) } }
  var metadata: [String: Any] { raw["metadata"] as? [String: Any] ?? [:] }
  var actions: [String] { raw["actions"] as? [String] ?? [] }
  var lastRefresh: Date? { (raw["lastSuccessfulFetch"] as? Double).map(Date.init(timeIntervalSince1970:)) }
  var format: String { raw["format"] as? String ?? "original" }
  var statusText: String {
    if local { return String(localized: "Local group") }
    switch status {
    case "ready": return String(localized: "Ready")
    case "refreshing": return String(localized: "Refreshing")
    case "approval_required": return String(localized: "Needs your approval")
    case "refresh_failed": return String(localized: "Last update failed")
    case "device_required": return String(localized: "Provider requires device registration")
    case "device_limit": return String(localized: "Provider device limit reached")
    default: return String(localized: "Unavailable")
    }
  }
  /// Whether a provider needs the user; a working one shows no status in lists. Failures are severe.
  var attention: (needed: Bool, severe: Bool) {
    if local { return (false, false) }
    switch status {
    case "approval_required", "device_required": return (true, false)
    case "refresh_failed", "device_limit": return (true, true)
    default: return (false, false)
    }
  }
  var refreshErrorText: String? {
    switch raw["refreshError"] as? String {
    case nil: return nil
    // Approval and device registration pause automatic refresh.
    case "authorization": return String(localized: "Automatic refresh is paused until this is resolved.")
    case "routing": return String(localized: "The provider’s routing profile could not be applied.")
    case "secret": return String(localized: "Secure storage is unavailable.")
    default: return String(localized: "The last download failed. Servers from the previous download are kept.")
    }
  }
}

struct RecentIssue: Identifiable {
  let id = UUID()
  let code: String
  let message: String
  let date: Date
}

struct RoutingProfile: Identifiable {
  let raw: [String: Any]
  var id: String { raw["id"] as? String ?? "" }
  var name: String { raw["name"] as? String ?? String(localized: "Routing") }
  var enabled: Bool { raw["enabled"] as? Bool == true }
  var edited: Bool { raw["edited"] as? Bool == true }
  var source: String { raw["source"] as? String ?? "local" }
  var owner: String? { raw["providerSubscriptionId"] as? String }
  var json: String { raw["json"] as? String ?? "{}" }
  var geofiles: [[String: Any]] { raw["geofiles"] as? [[String: Any]] ?? [] }
  /// RoutingStore publishes sizes as Int, which `as? Int64` never matches.
  static func bytes(_ file: [String: Any]) -> Int64? { (file["bytes"] as? NSNumber)?.int64Value }
  var managedSources: [[String: Any]] { ((try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any])?["ManagedSources"] as? [[String: Any]] ?? [] }
  func managedStatus(_ id: String?) -> [String: Any] { (raw["managedStatus"] as? [[String: Any]] ?? []).first { $0["id"] as? String == id } ?? [:] }
  var reductionText: String {
    switch raw["reductionStatus"] as? String {
    case nil, "disabled": String(localized: "Off")
    case "reduced": String(localized: "Reduced to the codes in use")
    case let message?: message
    }
  }
}

struct ProbeResult {
  let milliseconds: Int?
  let status: String
  let revision: String
  let date: Date
  var mode = "proxy"
  var failure: String?
  /// The status is state ("Passed", "Failed"); this is its text.
  var statusLabel: String { String(localized: String.LocalizationValue(status)) }
  var scope: String {
    switch mode {
    case "tcp": String(localized: "TCP endpoint")
    case "icmp": String(localized: "ICMP endpoint")
    case "activeProxy": String(localized: "Active connection HTTP")
    default: String(localized: "Proxy HTTP")
    }
  }
  func current(for node: ServerNode) -> Bool { revision == node.revision && Date().timeIntervalSince(date) < 300 }
  func currentMilliseconds(for node: ServerNode) -> Int? {
    guard current(for: node), status == "Passed", let milliseconds, milliseconds >= 0 else { return nil }
    return milliseconds
  }
}

/// Where a server reached the internet, from Cloudflare's trace through it.
struct ExitResult {
  let ip: String
  let country: String
  let revision: String
  var countryName: String { country == "XX" ? String(localized: "unknown country") : country == "T1" ? "Tor" : ServerLocation.fromCode(country)?.name ?? country }
  /// The name's country and the exit's, when they disagree. A provider's label is not evidence; the trace is.
  func mismatch(name: String) -> (named: ServerLocation, exit: ServerLocation)? {
    guard let named = ServerLocation.fromName(name), named.code != "EU", let exit = ServerLocation.fromCode(country), exit.code != named.code else { return nil }
    return (named, exit)
  }
}

/// Home's filtered and grouped servers, rebuilt only when what they show changes.
@MainActor final class ServerListCache {
  struct Key: Equatable {
    var catalog: Int, search: String, country: String, filter: String, order: String, favoritesFirst: Bool, pinned: [String]
    // Latency order follows results; the other orders ignore them.
    var latencies: [String: Int]
  }
  typealias Group = (code: String, location: ServerLocation?, nodes: [ServerNode])
  private var key: Key?
  private(set) var builds = 0
  private(set) var visible: [ServerNode] = []
  private(set) var groups: [Group] = []
  private(set) var locations: [ServerLocation] = []
  private(set) var hasOther = false

  // shortcut: a latency order keeps results that age past five minutes until anything else changes.
  func update(_ key: Key, subscriptions: [ServerSubscription], probes: [String: ProbeResult]) {
    guard key != self.key else { return }
    self.key = key
    builds += 1
    func score(_ node: ServerNode) -> Int { guard let p = probes[node.id], p.current(for: node), let ms = p.milliseconds else { return .max }; return ms }
    let favoritesFirst = key.favoritesFirst && key.filter != "recent"
    var all: [ServerNode] = [], visible: [ServerNode] = []
    for source in subscriptions {
      let nodes = source.nodes
      all += nodes
      let values = nodes.filter { node in
        node.matches(key.search, provider: source.name) &&
        (key.country.isEmpty || (ServerLocation.fromName(node.name)?.code ?? "other") == key.country) &&
        (key.filter == "all" || key.filter == "favorites" && node.favorite || key.filter == "recent" && node.lastSuccess != nil)
      }
      var sorted: [ServerNode]
      switch key.order {
      case "name": sorted = values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
      case "latency": sorted = values.sorted { score($0) < score($1) }
      default: sorted = key.filter == "recent" ? values.sorted { ($0.lastSuccess ?? .distantPast) > ($1.lastSuccess ?? .distantPast) } : values
      }
      visible += favoritesFirst ? sorted.filter(\.favorite) + sorted.filter { !$0.favorite } : sorted
    }
    self.visible = visible
    groups = Dictionary(grouping: visible, by: { ServerLocation.fromName($0.name)?.code ?? "other" }).map { code, nodes in
      let positions = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($0.element.id, $0.offset) })
      let sorted = nodes.sorted { a, b in
        let aPinned = key.pinned.contains(a.subscriptionID), bPinned = key.pinned.contains(b.subscriptionID)
        if aPinned != bPinned { return aPinned }
        if favoritesFirst && a.favorite != b.favorite { return a.favorite }
        if key.filter == "recent", a.lastSuccess != b.lastSuccess { return (a.lastSuccess ?? .distantPast) > (b.lastSuccess ?? .distantPast) }
        if key.filter != "recent" && key.order == "name" {
          let compared = a.name.localizedStandardCompare(b.name)
          if compared != .orderedSame { return compared == .orderedAscending }
        }
        if key.filter != "recent" && key.order == "latency" && score(a) != score(b) { return score(a) < score(b) }
        return positions[a.id]! < positions[b.id]!
      }
      return (code, nodes.first.flatMap { ServerLocation.fromName($0.name) }, sorted)
    }.sorted { a, b in
      if a.code == "other" { return false }; if b.code == "other" { return true }
      return (a.location?.name ?? "").localizedStandardCompare(b.location?.name ?? "") == .orderedAscending
    }
    locations = Array(Set(all.compactMap { ServerLocation.fromName($0.name) })).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    hasOther = all.contains { ServerLocation.fromName($0.name) == nil }
  }
}

struct IOSPreferences: Codable {
  var version = 1
  var theme = "system"
  var accent = "evergreen"
  var serverOrder = "provider"
  // Optional, so that preferences saved before it still decode; nil is on.
  var favoritesFirst: Bool?
  var pinned: [String] = []
  var expiryReminders = false
  var autoUpdateHours = 4
  var probeMode = "proxy"
  var probeURL = "https://www.gstatic.com/generate_204"
  var probeMethod = "GET"
  var probeVariant = "default"
  var probeTimeout = 5
  var probeExpectedStatus = 204
  var probeExpectedBody = ""
  var automation = AutomationConfiguration()
}

struct IOSTunnelSettings: Codable, Equatable {
  var version = 1
  var socksPort = 10890
  var httpPort = 10891
  var httpInboundEnabled = false
  var allowLAN = false
  var inboundAuthEnabled = false
  var inboundCredentialRef: String?
  /// On for a new install: iOS starts no killed extension again without it. Saved settings keep their choice.
  var onDemandEnabled = true
  /// Joining a Wi-Fi network outside trustedWiFiNetworks connects, through On Demand. Optional: older saved settings lack them.
  var connectOnUntrustedWiFi: Bool?
  var trustedWiFiNetworks: [String]?
  var includeAllNetworks = false
  var enforceRoutes = false
  var disconnectOnSleep = false
  var preferredIP = "ipv4"
  var profilePreferredIP = "inherit"
  var profileDNSMode = "inherit"
  var resolveServer = false
  var fragmentationEnabled = false
  var fragmentPackets = "tlshello"
  var fragmentLength = "100-200"
  var fragmentInterval = "0-1"
  var muxEnabled = false
  var sniffingEnabled = true
  var monitoringEnabled = false
  var recordDiagnostics: Bool? // optional, so settings saved by older builds still decode
  var idleTimeoutSeconds = 300
  var tcpMaxConnections = 2_048
  var udpMaxConnections = 1_024
  var includedRoutes = ["0.0.0.0/0", "::/0"]
  var excludedRoutes: [String] = []

  func validate() throws {
    func range(_ text: String, low: Int, high: Int) -> Bool {
      let parts = text.split(separator: "-", omittingEmptySubsequences: false)
      guard (1...2).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
            let a = Int(parts[0]), let b = Int(parts[parts.count - 1]) else { return false }
      return a >= low && a <= b && b <= high
    }
    guard version == 1, (1...65535).contains(socksPort), (1...65535).contains(httpPort),
          !httpInboundEnabled || socksPort != httpPort, !allowLAN || inboundAuthEnabled,
          !inboundAuthEnabled || inboundCredentialRef != nil,
          ["inherit", "automatic", "ipv4", "ipv6"].contains(profilePreferredIP),
          ["inherit", "routing", "default"].contains(profileDNSMode),
          fragmentPackets == "tlshello" || range(fragmentPackets, low: 1, high: 65535),
          range(fragmentLength, low: 1, high: 65535), range(fragmentInterval, low: 0, high: 1000),
          includedRoutes.allSatisfy(Self.validCIDR), excludedRoutes.allSatisfy(Self.validCIDR),
          (trustedWiFiNetworks ?? []).count <= 64,
          (trustedWiFiNetworks ?? []).allSatisfy({ (1...32).contains($0.utf8.count) &&
            $0.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) }),
          !enforceRoutes || (!includeAllNetworks && !includedRoutes.contains(where: { $0.hasSuffix("/0") }))
    else { throw IOSAppError.invalidSettings }
    try runtime().validate()
  }

  func runtime(nodePreference: String? = nil) throws -> TunnelRuntimeSettings {
    var map = try JSONSerialization.jsonObject(with: JSONEncoder().encode(TunnelRuntimeSettings.defaults)) as! [String: Any]
    let own = try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as! [String: Any]
    for (key, value) in own where map[key] != nil || ["fragmentPackets", "fragmentLength", "fragmentInterval", "httpPort", "allowLAN", "inboundAuthEnabled", "inboundCredentialRef", "resolveServer", "profileDNSMode", "recordDiagnostics"].contains(key) {
      map[key] = value
    }
    if profilePreferredIP != "inherit" { map["profilePreferredIP"] = profilePreferredIP }
    if let nodePreference { map["profilePreferredIP"] = nodePreference; map["preferredIP"] = nodePreference }
    map["useDNSFromJSON"] = profileDNSMode != "default"
    return try JSONDecoder().decode(TunnelRuntimeSettings.self, from: JSONSerialization.data(withJSONObject: map))
  }

  var compilerRuntime: [String: Any] {
    ["fragmentationEnabled": fragmentationEnabled, "fragmentPackets": fragmentPackets,
     "fragmentLength": fragmentLength, "fragmentInterval": fragmentInterval, "muxEnabled": muxEnabled,
     "preferredIp": preferredIP, "connectionIdleSeconds": idleTimeoutSeconds, "sniffingEnabled": sniffingEnabled,
     "httpInboundEnabled": httpInboundEnabled, "httpPort": httpPort, "allowLan": allowLAN,
     "useDnsFromJson": profileDNSMode != "default", "profileDnsMode": profileDNSMode,
     "perAppMode": "off", "perAppProcesses": []]
  }

  static func validCIDR(_ value: String) -> Bool {
    let parts = value.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2, let prefix = Int(parts[1]) else { return false }
    var v4 = in_addr(); var v6 = in6_addr()
    return ((0...32).contains(prefix) && inet_pton(AF_INET, String(parts[0]), &v4) == 1) ||
      ((0...128).contains(prefix) && inet_pton(AF_INET6, String(parts[0]), &v6) == 1)
  }
}
