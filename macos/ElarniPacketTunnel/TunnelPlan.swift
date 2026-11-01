import CryptoKit
import Foundation

struct TunnelPlan: Codable, Sendable {
  static let schemaVersion = 1

  let schemaVersion: Int
  let secretRef: String
  let socksPort: UInt16
  let mtu: UInt16
  let dnsServers: [String]
  let controlledRoutes: [ControlledRoute]
  let staticHosts: [String: [String]]
  let outboundFormat: OutboundFormat?
  let fallbackAction: ControlledRoute.Action?
  let routingRevision: String?
  let routingDigest: String?
  let assetRevision: String?
  let backend: TunnelBackend?
  let settings: TunnelRuntimeSettings?

  var effectiveBackend: TunnelBackend { backend ?? .nativeTun2Proxy }
  var runtimeSettings: TunnelRuntimeSettings { settings ?? .defaults }
  var effectivePreferredIP: String {
    outboundFormat == .xrayProfile ? runtimeSettings.profilePreferredIP ?? "automatic" : runtimeSettings.preferredIP
  }

  func validate() throws {
#if os(iOS)
    guard effectiveBackend == .nativeTun2Proxy else { throw TunnelPlanError.invalidBounds }
#endif
    guard schemaVersion == Self.schemaVersion else { throw TunnelPlanError.unsupportedSchema }
    guard (1...128).contains(secretRef.count), secretRef.allSatisfy({
      $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0))
    }) else { throw TunnelPlanError.invalidSecretRef }
    guard socksPort != 0, (1280...9000).contains(mtu) else { throw TunnelPlanError.invalidBounds }
    guard (1...4).contains(dnsServers.count), controlledRoutes.count <= 128,
          staticHosts.count <= 32 else {
      throw TunnelPlanError.invalidBounds
    }
    guard staticHosts.allSatisfy({ key, addresses in
      !key.isEmpty && key.count <= 253 && key.allSatisfy(\.isASCII) &&
        (1...4).contains(addresses.count) && addresses.allSatisfy { !$0.isEmpty && $0.count <= 64 }
    }) else { throw TunnelPlanError.invalidBounds }
    guard (routingRevision == nil) == (routingDigest == nil) else {
      throw TunnelPlanError.invalidRoutingRevision
    }
    if let routingRevision, let routingDigest {
      guard routingRevision.count <= 96,
            routingRevision.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0)) }),
            routingDigest.count == 64,
            routingDigest.allSatisfy({ $0.isHexDigit }) else {
        throw TunnelPlanError.invalidRoutingRevision
      }
    }
    if let assetRevision {
      guard assetRevision.count <= 64,
            assetRevision.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0)) }) else {
        throw TunnelPlanError.invalidRoutingRevision
      }
    }
    try runtimeSettings.validate()
  }

  func runtimeRouteModel(containerURL: () -> URL? = {
#if os(iOS)
    IOSPlatform.containerURL
#else
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.elarni.mac")
#endif
  }) throws -> [String: Any]? {
    guard let routingRevision, let routingDigest else { return nil }
    guard let container = containerURL() else { throw TunnelPlanError.invalidRoutingRevision }
    let url = container
      .appendingPathComponent("Routing", isDirectory: true)
      .appendingPathComponent("Revisions", isDirectory: true)
      .appendingPathComponent(routingRevision, isDirectory: false)
    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
    guard data.count <= 8 * 1024 * 1024,
          SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == routingDigest,
          let model = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw TunnelPlanError.invalidRoutingRevision
    }
    return model
  }

  func assetDirectory(containerURL: () -> URL? = {
#if os(iOS)
    IOSPlatform.containerURL
#else
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.elarni.mac")
#endif
  }) throws -> String? {
    guard let assetRevision else { return nil }
    guard let container = containerURL() else { throw TunnelPlanError.invalidRoutingRevision }
    let url = container
      .appendingPathComponent("Routing", isDirectory: true)
      .appendingPathComponent("Assets", isDirectory: true)
      .appendingPathComponent(assetRevision, isDirectory: true)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
          isDirectory.boolValue else { throw TunnelPlanError.invalidRoutingRevision }
    return url.path
  }
}

struct TunnelRuntimeSettings: Codable, Sendable, Equatable {
  var perAppMode: String? = nil
  var perAppProcesses: [String]? = nil
  /// A listed app's own target: direct, routing, block, proxy:<URL> or server:<keychain entry>.
  var perAppTargets: [String: String]? = nil
  var fragmentPackets: String? = nil
  var fragmentLength: String? = nil
  var fragmentInterval: String? = nil
  var profilePreferredIP: String? = nil
  var profileDNSMode: String? = nil
  var httpPort: Int?
  var allowLAN: Bool?
  var inboundAuthEnabled: Bool?
  var inboundCredentialRef: String?
  var useDNSFromJSON: Bool?
  var resolveServer: Bool?
  var recordDiagnostics: Bool?
  static let defaults = TunnelRuntimeSettings(
    schemaVersion: 1,
    fragmentationEnabled: false,
    muxEnabled: false,
    preferredIP: "ipv4",
    httpInboundEnabled: false,
    xrayTunEnabled: false,
    memoryLimitMB: 0,
    idleTimeoutSeconds: 300,
    tcpMaxConnections: 256,
    udpMaxConnections: 128,
    sniffingEnabled: true,
    monitoringEnabled: false,
    hideVPNIcon: false,
    includedRoutes: ["0.0.0.0/0", "::/0"],
    excludedRoutes: []
  )

  let schemaVersion: Int
  let fragmentationEnabled: Bool
  let muxEnabled: Bool
  let preferredIP: String
  let httpInboundEnabled: Bool
  let xrayTunEnabled: Bool
  let memoryLimitMB: Int
  let idleTimeoutSeconds: Int
  let tcpMaxConnections: Int
  let udpMaxConnections: Int
  let sniffingEnabled: Bool
  let monitoringEnabled: Bool
  let hideVPNIcon: Bool
  let includedRoutes: [String]
  let excludedRoutes: [String]

  var memoryLimitBytes: Int {
#if os(iOS)
    // Match libXray's iOS initialization on every start. This is a Go heap
    // target, not a promise about the complete extension's resident memory.
    30 * 1_024 * 1_024
#else
    // Old saved provider plans can start before the host migrates their settings.
    // Automatic uses Go's normal GC pacing, as on Windows; zero bytes would force GC.
    memoryLimitMB == 0 || (40...50).contains(memoryLimitMB)
      ? Int.max : memoryLimitMB * 1_024 * 1_024
#endif
  }

  func validate() throws {
#if os(iOS)
    guard (perAppMode ?? "off") == "off", (perAppProcesses ?? []).isEmpty, (perAppTargets ?? [:]).isEmpty,
          !xrayTunEnabled, !hideVPNIcon, memoryLimitMB == 0 else {
      throw TunnelPlanError.invalidBounds
    }
#endif
    guard schemaVersion == 1,
          ["off", "bypass", "proxyOnly"].contains(perAppMode ?? "off"),
          (perAppMode ?? "off") == "off" || (xrayTunEnabled && !(perAppProcesses ?? []).isEmpty),
          (perAppProcesses ?? []).count <= 256,
          (perAppProcesses ?? []).allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 &&
            $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines) &&
            $0.rangeOfCharacter(from: .controlCharacters) == nil }),
          (perAppTargets ?? [:]).allSatisfy({ process, target in
            (perAppProcesses ?? []).contains(process) && Self.validTarget(target) }),
          httpPort == nil || (1...65_535).contains(httpPort!),
          inboundAuthEnabled != true || inboundCredentialRef != nil,
          allowLAN != true || inboundAuthEnabled == true,
          ["ipv4", "ipv6", "automatic"].contains(preferredIP),
          profilePreferredIP == nil || ["ipv4", "ipv6", "automatic"].contains(profilePreferredIP!),
          profileDNSMode == nil || ["inherit", "routing", "default"].contains(profileDNSMode!),
          (memoryLimitMB == 0 || (40...4096).contains(memoryLimitMB)),
          (30...3_600).contains(idleTimeoutSeconds),
          (1...4_096).contains(tcpMaxConnections),
          (1...4_096).contains(udpMaxConnections),
          (1...64).contains(includedRoutes.count),
          excludedRoutes.count <= 64,
          Set(includedRoutes).count == includedRoutes.count,
          Set(excludedRoutes).count == excludedRoutes.count else {
      throw TunnelPlanError.invalidBounds
    }
    if let ref = inboundCredentialRef {
      guard ref.hasPrefix("inbound."), ref.count <= 64,
            ref.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0)) })
      else { throw TunnelPlanError.invalidBounds }
    }
  }

  /// The core checks a proxy URL itself; a server target names only a subscription's keychain entry.
  private static func validTarget(_ target: String) -> Bool {
    if ["direct", "routing", "block"].contains(target) { return true }
    if target.hasPrefix("proxy:") { return target.count <= 256 }
    guard target.hasPrefix("server:") else { return false }
    let ref = target.dropFirst(7)
    return ref.hasPrefix("subscription.") && ref.count <= 128 &&
      ref.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0)) })
  }

  /// The keychain entries of the per-app server targets, which the provider resolves before compiling.
  var perAppServerRefs: [String] {
    guard (perAppMode ?? "off") != "off" else { return [] }
    return Set((perAppTargets ?? [:]).values.filter { $0.hasPrefix("server:") }.map { String($0.dropFirst(7)) }).sorted()
  }

  /// The compiler's per-app targets, each server target with its configuration.
  func compilerPerAppTargets(servers: [String: SecretValue]) throws -> [[String: Any]] {
    guard (perAppMode ?? "off") != "off" else { return [] }
    return try (perAppTargets ?? [:]).sorted { $0.key < $1.key }.map { process, target -> [String: Any] in
      if target.hasPrefix("server:") {
        guard let secret = servers[String(target.dropFirst(7))],
              let server = try JSONSerialization.jsonObject(with: secret.bytes) as? [String: Any]
        else { throw TunnelPlanError.invalidBounds }
        return ["process": process, "target": "server", "server": server]
      }
      if target.hasPrefix("proxy:") { return ["process": process, "target": "proxy", "proxy": String(target.dropFirst(6))] }
      return ["process": process, "target": target]
    }
  }
}

struct InboundCredentials: Sendable {
  var username: Data
  var password: Data

  init(data: Data) throws {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: String],
          let username = object["username"], let password = object["password"],
          (1...255).contains(username.utf8.count), (1...255).contains(password.utf8.count)
    else { throw TunnelPlanError.invalidBounds }
    self.username = Data(username.utf8)
    self.password = Data(password.utf8)
  }

  var compilerMap: [String: Any] {
    ["username": String(decoding: username, as: UTF8.self),
     "password": String(decoding: password, as: UTF8.self)]
  }

  mutating func clear() {
    username.resetBytes(in: 0..<username.count)
    password.resetBytes(in: 0..<password.count)
    username.removeAll(keepingCapacity: false)
    password.removeAll(keepingCapacity: false)
  }
}

enum OutboundFormat: String, Codable, Sendable {
  case xrayOutbound
  case xrayProfile
}

enum TunnelBackend: String, Codable, Sendable {
  case nativeTun2Proxy
  case xrayTun
}

struct ControlledRoute: Codable, Sendable {
  enum Action: String, Codable, Sendable { case proxy, direct, block }

  let action: Action
  let domains: [String]
  let ipRanges: [String]
}

struct TunnelPlanEnvelope: Codable, Sendable {
  let payload: Data
  let digest: Data

  func validatedPlan() throws -> TunnelPlan {
    guard payload.count <= 64 * 1024, digest.count == SHA256.byteCount else {
      throw TunnelPlanError.invalidBounds
    }
    guard Data(SHA256.hash(data: payload)) == digest else { throw TunnelPlanError.digestMismatch }
    let plan = try JSONDecoder().decode(TunnelPlan.self, from: payload)
    try plan.validate()
    return plan
  }
}

enum TunnelPlanError: Error {
  case unsupportedSchema
  case invalidSecretRef
  case invalidBounds
  case digestMismatch
  case invalidRoutingRevision
}
