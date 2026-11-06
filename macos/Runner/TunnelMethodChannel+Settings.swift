import CryptoKit
import AppKit
import Darwin
import FlutterMacOS
import Foundation
import Network
import NetworkExtension
import ServiceManagement

// Tunnel settings, their persistence and on-demand rules.
extension TunnelMethodChannel {
  @MainActor
  func apply(settings: AppTunnelSettings) async throws -> [String: Any] {
    try Task.checkCancellation()
    try settings.validateRoutePolicy()
    let previous = settingsStore.current
    // Neither the refresh interval nor the log level is part of the tunnel plan.
    var previousWithNewPreferences = previous
    previousWithNewPreferences.subscriptionAutoUpdateHours = settings.subscriptionAutoUpdateHours
    previousWithNewPreferences.logLevel = settings.logLevel
    if settings != previous, settings == previousWithNewPreferences {
      try settingsStore.save(settings)
      writeLogLevel(settings.logLevel)
      return settings.channelMap
    }
    let selected = try? await loadManager()
    try Task.checkCancellation()
    let active = selected?.connection.status == .connected || selected?.connection.status == .reasserting
    var connectionSettings = settings
    connectionSettings.onDemandEnabled = previous.onDemandEnabled
    connectionSettings.connectOnUntrustedWiFi = previous.connectOnUntrustedWiFi
    connectionSettings.trustedWiFiNetworks = previous.trustedWiFiNetworks
    connectionSettings.subscriptionAutoUpdateHours = previous.subscriptionAutoUpdateHours
    connectionSettings.logLevel = previous.logLevel
    let policyOnly = active && connectionSettings == previous
    let reconnect = selected?.connection.status == .connected && !policyOnly
    if active && commands.intent != .connected { throw RunnerTunnelError.connectionIntentRequired }
    if reconnect, let selected { try await stopForRestart(selected) }
    if settings.connectOnUntrustedWiFi && !previous.connectOnUntrustedWiFi { commands.armUntrustedWiFi() }
    do {
      if !policyOnly { try settings.checkListenerPorts() }
      try settingsStore.save(settings)
      writeLogLevel(settings.logLevel)
      // The selected server's plan carries its own IP preference and backend; rewriting it with global settings breaks both.
      var synchronized = false
      if !policyOnly, let store = try? subscriptionStore(), store.selectedNodeID() != nil {
        try await synchronizeSelectedPlan(store)
        synchronized = true
      }
      try await applyOnDemand(settings.onDemandEnabled, updatePlan: !policyOnly && !synchronized)
      if reconnect {
        try await connect()
        try await waitForConnected()
      }
      return settings.channelMap
    } catch {
      try Task.checkCancellation()
      try? settingsStore.save(previous)
      writeLogLevel(previous.logLevel)
      var restored = false
      if !policyOnly, let store = try? subscriptionStore(), store.selectedNodeID() != nil {
        restored = (try? await synchronizeSelectedPlan(store)) != nil
      }
      try? await applyOnDemand(previous.onDemandEnabled, updatePlan: !policyOnly && !restored)
      if reconnect {
        try? await connect()
        try? await waitForConnected()
      }
      throw error
    }
  }

  /// The provider's settings: a per-app server target names its server's keychain entry.
  func connectionPlanSettings(_ settings: AppTunnelSettings,
                              store: @autoclosure () -> SubscriptionStore?) throws -> [String: Any] {
    var map = settings.connectionPlanMap
    guard (settings.perAppMode ?? "off") != "off", !settings.perAppTargets.isEmpty else { return map }
    map["perAppTargets"] = try settings.perAppTargets.mapValues { (target: String) throws -> String in
      guard target.hasPrefix("node:") else { return target }
      guard let ref = try? store()?.outboundRef(nodeID: String(target.dropFirst(5))) else {
        throw RunnerTunnelError.perAppTargetMissing
      }
      return "server:" + ref
    }
    return map
  }
  @MainActor
  private func applyOnDemand(_ enabled: Bool, updatePlan: Bool = true) async throws {
    try Task.checkCancellation()
    let manager = try await loadManager()
    try Task.checkCancellation()
    var configurationChanged = false
    if let tunnelProtocol = manager.protocolConfiguration {
      if updatePlan, let provider = tunnelProtocol as? NETunnelProviderProtocol,
         let payload = provider.providerConfiguration?["planPayload"] as? Data,
         var plan = try JSONSerialization.jsonObject(with: payload) as? [String: Any] {
        plan["settings"] = try connectionPlanSettings(settingsStore.current, store: try? subscriptionStore())
        plan["socksPort"] = settingsStore.current.socksPort
        plan["backend"] = settingsStore.current.xrayTunEnabled ? "xrayTun" : "nativeTun2Proxy"
        let updated = try JSONSerialization.data(withJSONObject: plan, options: [.sortedKeys])
        var configuration = provider.providerConfiguration ?? [:]
        configuration["planPayload"] = updated
        configuration["planDigest"] = Data(SHA256.hash(data: updated))
        configurationChanged = (provider.providerConfiguration as NSDictionary?)?
          .isEqual(to: configuration) != true
        provider.providerConfiguration = configuration
      }
      configurationChanged = configurationChanged ||
        tunnelProtocol.enforceRoutes != settingsStore.current.enforceRoutes ||
        tunnelProtocol.includeAllNetworks != settingsStore.current.includeAllNetworks ||
        tunnelProtocol.disconnectOnSleep != settingsStore.current.disconnectOnSleep
      settingsStore.current.apply(to: tunnelProtocol)
    }
    try await setOnDemand(manager,
      enabled: enabled && commands.intent == .connected && !automationConfiguration.enabled,
      retainingProtection: commands.intent == .connected && settingsStore.current.includeAllNetworks,
      configurationChanged: configurationChanged, untrustedWiFi: untrustedWiFiArmed)
  }
}

struct AppTunnelSettings: Codable, Equatable {
  static let defaults = AppTunnelSettings()

  var schemaVersion = 1
  var fragmentationEnabled = false
  var fragmentPackets: String?
  var fragmentLength: String?
  var fragmentInterval: String?
  var muxEnabled = false
  var preferredIP = "ipv4"
  var profilePreferredIP: String?
  var profileDNSMode: String?
  var httpInboundEnabled = false
  var socksPort = 10_890
  var httpPort = 10_891
  var allowLAN = false
  var inboundAuthEnabled = false
  var inboundCredentialRef: String?
  var onDemandEnabled = false
  /// Joining a Wi-Fi network whose name is not in trustedWiFiNetworks connects, through On Demand.
  var connectOnUntrustedWiFi = false
  var trustedWiFiNetworks: [String] = []
  var subscriptionAutoUpdateHours = 4
  var enforceRoutes = false
  var includeAllNetworks = false
  var disconnectOnSleep = false
  var useDNSFromJSON = true
  var resolveServer = false
  var xrayTunEnabled = false
  var perAppMode: String?
  var perAppProcesses: [String]?
  /// A listed app's own target: direct, routing, block, node:<server ID> or proxy:<URL>. Apps without one take the mode's.
  var perAppTargets: [String: String] = [:]
  var memoryLimitMB = 0
  var idleTimeoutSeconds = 300
  var tcpMaxConnections = 2_048
  var udpMaxConnections = 1_024
  var sniffingEnabled = true
  var monitoringEnabled = false
  /// The extension reads it from the shared container, so it is not part of the plan.
  var logLevel = "warning"
  var recordDiagnostics = false
  var hideVPNIcon = false
  var includedRoutes = ["0.0.0.0/0", "::/0"]
  var excludedRoutes: [String] = []

  init() {}

  init(arguments: [String: Any], base: Self? = nil) throws {
    self.init()
    var arguments = arguments
    if base != nil { arguments.removeValue(forKey: "inboundCredentialRef") }
    let merged = (base ?? Self.defaults).planMap.merging(arguments) { _, supplied in supplied }
    guard let data = try? JSONSerialization.data(withJSONObject: merged),
          let value = try? JSONDecoder().decode(Self.self, from: data) else {
      throw RunnerTunnelError.invalidSettings
    }
    guard let included = Self.canonicalRoutes(value.includedRoutes),
          let excluded = Self.canonicalRoutes(value.excludedRoutes) else {
      throw RunnerTunnelError.invalidSettings
    }
    self = value
    // Migrate the former 40–50 MiB-only setting: it forces continuous GC on desktop workloads, and
    // the extension runs plans saved with it unlimited. A new choice in that range is refused below.
    if base == nil, (40...50).contains(memoryLimitMB) { memoryLimitMB = 0 }
    includedRoutes = included
    excludedRoutes = excluded
    try validate()
  }

  func validateRoutePolicy() throws {
    guard !enforceRoutes || (!includeAllNetworks && !includedRoutes.contains(where: { $0.hasSuffix("/0") })) else {
      throw RunnerTunnelError.invalidRouteEnforcement
    }
  }

  func applyingIPPreference(_ preference: String?) -> AppTunnelSettings {
    guard let preference else { return self }
    var result = self
    result.preferredIP = preference
    result.profilePreferredIP = preference
    return result
  }

  func validate() throws {
    func range(_ value: String, _ min: Int, _ max: Int) -> Bool {
      let parts = value.split(separator: "-", omittingEmptySubsequences: false)
      guard value.utf8.count <= 11, (1...2).contains(parts.count),
            parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
            let low = Int(parts[0]), let high = Int(parts[parts.count - 1]) else { return false }
      return low >= min && low <= high && high <= max
    }
    guard schemaVersion == 1,
          (1...168).contains(subscriptionAutoUpdateHours),
          ["off", "bypass", "proxyOnly"].contains(perAppMode ?? "off"),
          (perAppMode ?? "off") == "off" || (xrayTunEnabled && !(perAppProcesses ?? []).isEmpty),
          (perAppProcesses ?? []).count <= 256,
          (perAppProcesses ?? []).allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 &&
            $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines) &&
            $0.rangeOfCharacter(from: .controlCharacters) == nil }),
          fragmentPackets == nil || fragmentPackets == "tlshello" || range(fragmentPackets!, 1, 65535),
          range(fragmentLength ?? "100-200", 1, 65535), range(fragmentInterval ?? "0-1", 0, 1000),
          (1...65_535).contains(socksPort), (1...65_535).contains(httpPort),
          ["none", "error", "warning", "info", "debug"].contains(logLevel),
          !httpInboundEnabled || socksPort != httpPort,
          !inboundAuthEnabled || inboundCredentialRef != nil,
          !allowLAN || inboundAuthEnabled,
          ["ipv4", "ipv6", "automatic"].contains(preferredIP),
          profilePreferredIP == nil || ["ipv4", "ipv6", "automatic"].contains(profilePreferredIP!),
          profileDNSMode == nil || ["inherit", "routing", "default"].contains(profileDNSMode!),
          (memoryLimitMB == 0 || (51...4096).contains(memoryLimitMB)),
          (30...3_600).contains(idleTimeoutSeconds),
          (1...4_096).contains(tcpMaxConnections),
          (1...4_096).contains(udpMaxConnections),
          (1...64).contains(includedRoutes.count),
          excludedRoutes.count <= 64,
          trustedWiFiNetworks.count <= 64,
          trustedWiFiNetworks.allSatisfy({ (1...32).contains($0.utf8.count) &&
            $0.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) }),
          Set(includedRoutes).count == includedRoutes.count,
          Set(excludedRoutes).count == excludedRoutes.count,
          includedRoutes.allSatisfy(Self.validCIDR),
          excludedRoutes.allSatisfy(Self.validCIDR),
          perAppTargets.allSatisfy({ process, target in
            (perAppProcesses ?? []).contains(process) && (["direct", "routing", "block"].contains(target) ||
              target.hasPrefix("node:") && (6...133).contains(target.count) ||
              target.hasPrefix("proxy:") && validProxy(String(target.dropFirst(6))))
          }) else {
      throw RunnerTunnelError.invalidSettings
    }
    if let ref = inboundCredentialRef {
      guard ref.hasPrefix("inbound."), ref.count <= 64,
            ref.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0)) })
      else { throw RunnerTunnelError.invalidSettings }
    }
  }

  /// A per-app proxy: SOCKS5 or HTTP on this Mac without a login, and none of Elarni's own listeners.
  private func validProxy(_ text: String) -> Bool {
    guard let url = URLComponents(string: text), let scheme = url.scheme?.lowercased(),
          ["socks", "socks5", "http"].contains(scheme),
          let host = url.host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")),
          host.lowercased() == "localhost" || IPv4Address(host)?.isLoopback == true || IPv6Address(host)?.isLoopback == true,
          // HTTP defaults to port 80; SOCKS has no default.
          let port = url.port ?? (scheme == "http" ? 80 : nil), (1...65_535).contains(port),
          url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, ["", "/"].contains(url.path),
          port != socksPort, !httpInboundEnabled || port != httpPort else { return false }
    return true
  }

  /// These settings after a restore renumbered servers; a target the backup lacks stays missing.
  func remappingPerAppServers(_ nodeIDs: [String: String]) -> AppTunnelSettings {
    var result = self
    result.perAppTargets = perAppTargets.mapValues { target in
      guard target.hasPrefix("node:"), let id = nodeIDs[String(target.dropFirst(5))] else { return target }
      return "node:" + id
    }
    return result
  }

  func checkListenerPorts() throws {
    let primaryAddress = allowLAN ? INADDR_ANY : inet_addr("127.0.0.1")
    var addresses: Set<in_addr_t> = [primaryAddress, INADDR_ANY]
    if allowLAN {
      var interfaces: UnsafeMutablePointer<ifaddrs>?
      guard getifaddrs(&interfaces) == 0 else {
        throw RunnerTunnelError.listenerUnavailable(socksPort)
      }
      defer { if let interfaces { freeifaddrs(interfaces) } }
      var cursor = interfaces
      while let interface = cursor {
        if let address = interface.pointee.ifa_addr,
           address.pointee.sa_family == sa_family_t(AF_INET) {
          addresses.insert(UnsafeRawPointer(address)
            .assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr)
        }
        cursor = interface.pointee.ifa_next
      }
    }
    var descriptors: [Int32] = []
    defer { for descriptor in descriptors { close(descriptor) } }
    let listeners: [(Int, Int32)] = [(socksPort, SOCK_STREAM), (socksPort, SOCK_DGRAM)]
      + (httpInboundEnabled ? [(httpPort, SOCK_STREAM)] : [])
    // Darwin permits wildcard/specific TCP sharing with SO_REUSEADDR. Probe
    // concrete addresses too, retaining reuse for connections in TIME_WAIT.
    let probes = listeners.flatMap { port, kind in
      (kind == SOCK_STREAM ? Array(addresses) : [primaryAddress]).map { (port, kind, $0) }
    }
    for (port, kind, bindAddress) in probes {
      let descriptor = socket(AF_INET, kind, 0)
      guard descriptor >= 0 else { throw RunnerTunnelError.listenerUnavailable(port) }
      descriptors.append(descriptor)
      if kind == SOCK_STREAM {
        var enabled: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &enabled, socklen_t(MemoryLayout<Int32>.size))
      }
      var address = sockaddr_in()
      address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
      address.sin_family = sa_family_t(AF_INET)
      address.sin_port = UInt16(port).bigEndian
      address.sin_addr.s_addr = bindAddress
      let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
      }
      guard bound == 0, kind != SOCK_STREAM || listen(descriptor, 1) == 0 else {
        throw RunnerTunnelError.listenerUnavailable(port)
      }
    }
  }

  var planMap: [String: Any] {
    let data = try! JSONEncoder().encode(self)
    return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
  }

  var channelMap: [String: Any] {
    var map = planMap
    map.removeValue(forKey: "inboundCredentialRef")
    map["inboundCredentialsConfigured"] = inboundCredentialRef != nil
    return map
  }

  var connectionPlanMap: [String: Any] {
    var map = planMap
    map.removeValue(forKey: "subscriptionAutoUpdateHours")
    map.removeValue(forKey: "logLevel")
    // On Demand rules, not the provider, carry the Wi-Fi rule.
    map.removeValue(forKey: "connectOnUntrustedWiFi")
    map.removeValue(forKey: "trustedWiFiNetworks")
    // The channel adds them with each server's keychain entry.
    map.removeValue(forKey: "perAppTargets")
    return map
  }

  func apply(to tunnelProtocol: NEVPNProtocol) {
    tunnelProtocol.enforceRoutes = enforceRoutes
    tunnelProtocol.includeAllNetworks = includeAllNetworks
    tunnelProtocol.disconnectOnSleep = disconnectOnSleep
  }

  var compilerRuntime: [String: Any] {
    [
      "fragmentationEnabled": fragmentationEnabled,
      "fragmentPackets": fragmentPackets ?? "tlshello",
      "fragmentLength": fragmentLength ?? "100-200",
      "fragmentInterval": fragmentInterval ?? "0-1",
      "muxEnabled": muxEnabled,
      "preferredIp": preferredIP,
      "connectionIdleSeconds": idleTimeoutSeconds,
      "sniffingEnabled": sniffingEnabled,
      "httpInboundEnabled": httpInboundEnabled,
      "httpPort": httpPort,
      "allowLan": allowLAN,
      "useDnsFromJson": useDNSFromJSON,
      "profileDnsMode": profileDNSMode ?? "inherit",
      "perAppMode": perAppMode ?? "off",
      "perAppProcesses": perAppProcesses ?? [],
    ]
  }

  private static func validCIDR(_ value: String) -> Bool { canonicalCIDR(value) != nil }

  private static func canonicalRoutes(_ values: [String]) -> [String]? {
    let normalized = values.compactMap(canonicalCIDR)
    guard normalized.count == values.count else { return nil }
    var seen = Set<String>()
    return normalized.filter { seen.insert($0).inserted }
  }

  private static func canonicalCIDR(_ value: String) -> String? {
    let parts = value.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2, let prefix = Int(parts[1]) else { return nil }
    if parts[0].contains(":"), (0...128).contains(prefix),
       let address = IPv6Address(String(parts[0])),
       let data = masked(address.rawValue, prefix: prefix),
       let network = IPv6Address(data) {
      return "\(network)/\(prefix)"
    }
    guard (0...32).contains(prefix), let address = IPv4Address(String(parts[0])),
          let data = masked(address.rawValue, prefix: prefix),
          let network = IPv4Address(data) else { return nil }
    return "\(network)/\(prefix)"
  }

  private static func masked(_ data: Data, prefix: Int) -> Data? {
    guard prefix <= data.count * 8 else { return nil }
    var bytes = [UInt8](data)
    for index in bytes.indices {
      let remaining = prefix - index * 8
      if remaining <= 0 { bytes[index] = 0 }
      else if remaining < 8 { bytes[index] &= UInt8(0xff << (8 - remaining)) }
    }
    return Data(bytes)
  }
}
final class TunnelSettingsStore {
  private static let key = "ElarniTunnelSettingsV1"
  private static let sessionLimitsKey = "ElarniSessionLimitsMigrated"
  private let defaults: UserDefaults
  private(set) var current: AppTunnelSettings
  /// No settings were ever saved: a fresh install.
  let isFresh: Bool

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    isFresh = defaults.data(forKey: Self.key) == nil
    if let data = defaults.data(forKey: Self.key),
       let arguments = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let saved = try? AppTunnelSettings(arguments: arguments) {
      current = saved
    } else {
      current = .defaults
    }
    // The old 256 TCP / 128 UDP defaults refuse new flows under daily load.
    // Raise them once; a value the user picks afterwards is kept.
    if !defaults.bool(forKey: Self.sessionLimitsKey) {
      var raised = current
      if raised.tcpMaxConnections == 256 { raised.tcpMaxConnections = 2_048 }
      if raised.udpMaxConnections == 128 { raised.udpMaxConnections = 1_024 }
      if raised == current || (try? save(raised)) != nil {
        defaults.set(true, forKey: Self.sessionLimitsKey)
      }
    }
  }

  func save(_ value: AppTunnelSettings) throws {
    try value.validate()
    defaults.set(try JSONEncoder().encode(value), forKey: Self.key)
    current = value
  }
}
