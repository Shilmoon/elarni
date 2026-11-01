import Darwin
import Foundation
import CFNetwork

enum NativeAdapterError: Error {
  case abiMismatch
  case invalidResponse
  case operationFailed
  case xrayFailure(ProviderBoundaryReason, ProviderBoundaryPath)
  case resolutionFailed
  case notRunning
  case stopTimeout
}

private struct CompiledEndpoint: Sendable {
  let config: String
  let endpoints: [NativeProfileEndpoint]

  func prepared(resolved: [String: String], unavailable: [String], pin: Bool, pinHosts: [String]) throws -> Self {
    guard let data = config.data(using: .utf8),
          let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw NativeAdapterError.invalidResponse }
    let result = try ElarniDomainCompiler.request("prepareConfig", payload: ["config": object,
      "resolved": resolved, "unavailable": unavailable, "pin": pin, "pinHosts": pinHosts])
    guard let config = result["config"] as? [String: Any] else { throw NativeAdapterError.invalidResponse }
    let rewritten = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
    return Self(config: String(decoding: rewritten, as: UTF8.self), endpoints: endpoints)
  }
}

private struct NativeProfileEndpoint: Decodable, Sendable {
  let host: String
  let port: UInt16
  let physical: Bool
  let addresses: [String]
  let addressPath: String
  let domainStrategy: String
}

private enum ElarniDomainCompiler {
  static func compile(
    plan: TunnelPlan,
    endpoint: inout SecretValue,
    servers: [String: SecretValue],
    inboundCredentials: InboundCredentials?,
    attempt: ProviderBoundaryAttempt
  ) throws -> CompiledEndpoint {
    ProviderBoundaryEvidence.begin(.domainCompile, attempt: attempt)
    do {
      let result = try compileUnchecked(plan: plan, endpoint: &endpoint, servers: servers,
        inboundCredentials: inboundCredentials)
      ProviderBoundaryEvidence.success(.domainCompile, attempt: attempt)
      return result
    } catch NativeAdapterError.abiMismatch {
      ProviderBoundaryEvidence.failure(
        .domainCompile,
        code: .domainAbiMismatch,
        attempt: attempt
      )
      throw NativeAdapterError.abiMismatch
    } catch NativeAdapterError.invalidResponse {
      ProviderBoundaryEvidence.failure(
        .domainCompile,
        code: .domainResponseInvalid,
        attempt: attempt
      )
      throw NativeAdapterError.invalidResponse
    } catch {
      ProviderBoundaryEvidence.failure(
        .domainCompile,
        code: .domainCompileFailed,
        attempt: attempt
      )
      throw error
    }
  }

  private static func compileUnchecked(
    plan: TunnelPlan,
    endpoint: inout SecretValue,
    servers: [String: SecretValue],
    inboundCredentials: InboundCredentials?
  ) throws -> CompiledEndpoint {
    guard elarni_abi_version() == ELARNI_ABI_VERSION else {
      throw NativeAdapterError.abiMismatch
    }
    let operation: String
    var runtime = compilerRuntime(plan.runtimeSettings)
    if let inboundCredentials { runtime["inboundAuth"] = inboundCredentials.compilerMap }
    let perAppTargets = try plan.runtimeSettings.compilerPerAppTargets(servers: servers)
    if !perAppTargets.isEmpty { runtime["perAppTargets"] = perAppTargets }
    guard plan.runtimeSettings.inboundAuthEnabled != true || inboundCredentials != nil else {
      throw NativeAdapterError.invalidResponse
    }
    var operationPayload: [String: Any]
    var routes: [String: Any]
    if let runtimeRoutes = try plan.runtimeRouteModel() {
      routes = runtimeRoutes
    } else {
      routes = [
        "rules": plan.controlledRoutes.map {
          ["action": $0.action.rawValue, "domains": $0.domains, "ips": $0.ipRanges]
        },
        "dnsServers": ["1.1.1.1"],
        "staticHosts": plan.staticHosts,
      ]
      if let fallbackAction = plan.fallbackAction {
        routes["fallbackAction"] = fallbackAction.rawValue
      }
    }
    if plan.outboundFormat == .xrayProfile {
      guard let profile = try JSONSerialization.jsonObject(with: endpoint.bytes) as? [String: Any]
      else { throw NativeAdapterError.invalidResponse }
      operation = "compileProfile"
      operationPayload = ["profile": profile, "socksPort": plan.socksPort,
        "packetBackend": plan.effectiveBackend.rawValue, "tunMtu": plan.mtu, "runtime": runtime]
      if plan.routingRevision != nil || !plan.controlledRoutes.isEmpty || plan.fallbackAction != nil {
        operationPayload["routes"] = routes
      }
      if let preference = plan.runtimeSettings.profilePreferredIP { operationPayload["preferredIp"] = preference }
    } else if plan.outboundFormat == .xrayOutbound {
      guard let outbound = try JSONSerialization.jsonObject(with: endpoint.bytes) as? [String: Any]
      else { throw NativeAdapterError.invalidResponse }
      operation = "compileOutbound"
      operationPayload = [
        "outbound": outbound,
        "routes": routes,
        "socksPort": plan.socksPort,
        "packetBackend": plan.effectiveBackend.rawValue,
        "tunMtu": plan.mtu,
        "runtime": runtime,
      ]
    } else {
      operation = "compileHy2Uri"
      operationPayload = [
        "uri": String(decoding: endpoint.bytes, as: UTF8.self),
        "authenticationRef": ["id": plan.secretRef],
        "obfuscationRef": ["id": "\(plan.secretRef).obfuscation"],
        "routes": routes,
        "socksPort": plan.socksPort,
        "packetBackend": plan.effectiveBackend.rawValue,
        "tunMtu": plan.mtu,
        "runtime": runtime,
      ]
    }
    let response = try request(operation, payload: operationPayload)
    guard
      let compiledConfig = response["configUtf8"] as? String,
      !compiledConfig.isEmpty,
      let configObject = try JSONSerialization.jsonObject(with: Data(compiledConfig.utf8)) as? [String: Any]
    else { throw NativeAdapterError.invalidResponse }
    let manifest = try request("profileEndpoints", payload: ["config": configObject])
    let endpoints = try JSONDecoder().decode([NativeProfileEndpoint].self,
      from: JSONSerialization.data(withJSONObject: manifest["endpoints"] ?? []))
    var config = compiledConfig
    let assetDirectory = try plan.assetDirectory()
    if assetDirectory != nil || plan.effectiveBackend == .xrayTun {
      guard let configData = config.data(using: .utf8),
            var configObject = try JSONSerialization.jsonObject(with: configData) as? [String: Any]
      else { throw NativeAdapterError.invalidResponse }
      var environment = configObject["env"] as? [String: Any] ?? [:]
      if let assetDirectory {
        environment["xray.location.asset"] = assetDirectory
      }
      if plan.effectiveBackend == .xrayTun {
        environment["xray.tun.fd"] = String(try UtunDescriptorResolver.resolve().descriptor)
      }
      configObject["env"] = environment
      let data = try JSONSerialization.data(withJSONObject: configObject, options: [.sortedKeys])
      guard let rewritten = String(data: data, encoding: .utf8) else {
        throw NativeAdapterError.invalidResponse
      }
      config = rewritten
    }
    return CompiledEndpoint(config: config, endpoints: endpoints)
  }

  static func request(_ operation: String, payload: [String: Any]) throws -> [String: Any] {
    let request = try JSONSerialization.data(withJSONObject: ["schemaVersion": TunnelPlan.schemaVersion,
      "operation": operation, "payload": payload])
    guard let handle = elarni_handle_new() else { throw NativeAdapterError.operationFailed }
    defer { elarni_handle_free(handle) }
    var output = ElarniBuffer(data: nil, len: 0, capacity: 0)
    let status = request.withUnsafeBytes { bytes in
      elarni_request(handle, bytes.bindMemory(to: UInt8.self).baseAddress, request.count, &output)
    }
    defer { elarni_buffer_free(output) }
    guard status == ELARNI_STATUS_OK, let bytes = output.data,
          let result = try JSONSerialization.jsonObject(with: Data(bytes: bytes, count: output.len)) as? [String: Any]
    else { throw NativeAdapterError.operationFailed }
    return result
  }

  private static func compilerRuntime(_ settings: TunnelRuntimeSettings) -> [String: Any] {
    var result: [String: Any] = [
      "fragmentationEnabled": settings.fragmentationEnabled,
      "fragmentPackets": settings.fragmentPackets ?? "tlshello",
      "fragmentLength": settings.fragmentLength ?? "100-200",
      "fragmentInterval": settings.fragmentInterval ?? "0-1",
      "muxEnabled": settings.muxEnabled,
      "preferredIp": settings.preferredIP,
      "connectionIdleSeconds": settings.idleTimeoutSeconds,
      "sniffingEnabled": settings.sniffingEnabled,
      "httpInboundEnabled": settings.httpInboundEnabled,
      "allowLan": settings.allowLAN == true,
      "useDnsFromJson": settings.useDNSFromJSON != false,
      "profileDnsMode": settings.profileDNSMode ?? "inherit",
      "perAppMode": settings.perAppMode ?? "off",
      "perAppProcesses": settings.perAppProcesses ?? [],
    ]
    if let port = settings.httpPort { result["httpPort"] = port }
    return result
  }
}

enum SystemEndpointResolver {
  static func resolve(
    _ host: String,
    preferredIP: String,
    attempt: ProviderBoundaryAttempt
  ) async throws -> [String] {
    ProviderBoundaryEvidence.begin(.endpointResolver, attempt: attempt)
    do {
      let lookup = Lookup(host: host, preferredIP: preferredIP)
      let result = try await withTaskCancellationHandler {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
          DispatchQueue.main.async { lookup.start(continuation) }
        }
      } onCancel: {
        DispatchQueue.main.async { lookup.finish(.failure(CancellationError())) }
      }
      try Task.checkCancellation()
      ProviderBoundaryEvidence.success(.endpointResolver, attempt: attempt)
      return result
    } catch {
      ProviderBoundaryEvidence.failure(
        .endpointResolver,
        code: .endpointResolutionFailed,
        attempt: attempt
      )
      throw error
    }
  }

  // Endpoint route exclusions require addresses before the core can connect.
  // CFHost provides cancellable system resolution, including scoped/local DNS;
  // a timed-out getaddrinfo worker would still outlive provider cleanup.
  private final class Lookup: @unchecked Sendable {
    private let host: CFHost
    private let preferredIP: String
    // All mutable state and CFHost callbacks run on the main run loop.
    private var continuation: CheckedContinuation<[String], Error>?
    private var result: Result<[String], Error>?
    private var scheduled = false

    init(host: String, preferredIP: String) {
      self.host = CFHostCreateWithName(nil, host as CFString).takeRetainedValue()
      self.preferredIP = preferredIP
    }

    func start(_ continuation: CheckedContinuation<[String], Error>) {
      if let result { continuation.resume(with: result); return }
      self.continuation = continuation
      var context = CFHostClientContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
        retain: { info in
          guard let info else { return nil }
          _ = Unmanaged<Lookup>.fromOpaque(info).retain()
          return info
        }, release: { info in
          if let info { Unmanaged<Lookup>.fromOpaque(info).release() }
        }, copyDescription: nil)
      guard CFHostSetClient(host, { _, _, error, info in
        guard let info else { return }
        let lookup = Unmanaged<Lookup>.fromOpaque(info).takeUnretainedValue()
        if let error, error.pointee.error != 0 {
          lookup.finish(.failure(NativeAdapterError.resolutionFailed))
        } else {
          lookup.completed()
        }
      }, &context) else {
        finish(.failure(NativeAdapterError.resolutionFailed)); return
      }
      CFHostScheduleWithRunLoop(host, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
      scheduled = true
      var error = CFStreamError()
      guard CFHostStartInfoResolution(host, .addresses, &error) else {
        finish(.failure(NativeAdapterError.resolutionFailed)); return
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
        self?.finish(.failure(NativeAdapterError.resolutionFailed))
      }
    }

    private func completed() {
      var resolved = DarwinBoolean(false)
      guard let values = CFHostGetAddressing(host, &resolved)?.takeUnretainedValue() as? [Data],
            resolved.boolValue else { finish(.failure(NativeAdapterError.resolutionFailed)); return }
      var addresses = Set<String>()
      for value in values {
        value.withUnsafeBytes { bytes in
          guard let address = bytes.baseAddress?.assumingMemoryBound(to: sockaddr.self),
                bytes.count >= MemoryLayout<sockaddr>.size else { return }
          let family = Int32(address.pointee.sa_family)
          guard (family == AF_INET || family == AF_INET6),
                preferredIP != "ipv4" || family == AF_INET,
                preferredIP != "ipv6" || family == AF_INET6 else { return }
          var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
          if getnameinfo(address, socklen_t(bytes.count), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
            addresses.insert(String(cString: buffer))
          }
        }
      }
      finish(addresses.isEmpty ? .failure(NativeAdapterError.resolutionFailed) : .success(addresses.sorted()))
    }

    func finish(_ result: Result<[String], Error>) {
      guard self.result == nil else { return }
      self.result = result
      if scheduled {
        CFHostCancelInfoResolution(host, .addresses)
        CFHostUnscheduleFromRunLoop(host, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        scheduled = false
      }
      CFHostSetClient(host, nil, nil)
      continuation?.resume(with: result)
      continuation = nil
    }
  }
}

final class NativeXrayCore: XrayCore, @unchecked Sendable {
  private let lock = NSLock()
  private var running = false

  func prepare(
    plan: TunnelPlan,
    endpoint: inout SecretValue,
    servers: [String: SecretValue],
    inboundCredentials: InboundCredentials?,
    attempt: ProviderBoundaryAttempt
  ) async throws -> PreparedXray {
    let endpointValue = endpoint
    let compiled = try await ProviderLifecycleRuntime.runBlocking {
      var endpointCopy = endpointValue
      return try ElarniDomainCompiler.compile(
        plan: plan,
        endpoint: &endpointCopy,
        servers: servers,
        inboundCredentials: inboundCredentials,
        attempt: attempt
      )
    }
    try Task.checkCancellation()
    var addresses = Set<String>()
    var resolved: [String: String] = [:]
    var unavailable: [String] = []
    let endpoints = compiled.endpoints.filter(\.physical)
    let hosts = Set(endpoints.map(\.host)).sorted()
    let mappings = try Self.invokeObject(method: "profileHostMappings", payload: ["configJSON": compiled.config, "hosts": hosts])
    var pinHosts: [String] = []
    var candidatesByHost: [String: [String]] = [:]
    for host in hosts {
      try Task.checkCancellation()
      let mapping = mappings[host] as? [String: Any]
      do {
        if mapping?["blocked"] as? Bool == true { throw NativeAdapterError.resolutionFailed }
        let candidates: [String]
        if let mapped = mapping?["addresses"] as? [String] { candidates = mapped }
        else { candidates = try await SystemEndpointResolver.resolve(mapping?["alias"] as? String ?? host, preferredIP: plan.effectivePreferredIP, attempt: attempt) }
        candidatesByHost[host] = candidates
        if mapping != nil { pinHosts.append(host) }
      } catch NativeAdapterError.resolutionFailed { candidatesByHost[host] = [] }
    }
    for endpoint in endpoints {
      let candidates = TunnelSettingsFactory.endpointAddresses(candidatesByHost[endpoint.host] ?? [], strategy: endpoint.domainStrategy, preferredIP: plan.effectivePreferredIP)
      guard let first = candidates.first else { unavailable.append(endpoint.addressPath); continue }
      resolved[endpoint.addressPath] = first
      addresses.formUnion(candidates)
    }
    try Task.checkCancellation()
    let prepared = try compiled.prepared(resolved: resolved, unavailable: unavailable, pin: plan.runtimeSettings.resolveServer == true, pinHosts: pinHosts)
    return PreparedXray(
      config: prepared.config, addresses: addresses.sorted(),
      memoryLimitBytes: plan.runtimeSettings.memoryLimitBytes
    )
  }

  func start(_ prepared: PreparedXray, attempt: ProviderBoundaryAttempt) async throws {
    ProviderBoundaryEvidence.begin(.libXrayRun, attempt: attempt)
    let response: Bool
    do {
      response = try await ProviderLifecycleRuntime.runBlocking {
        _ = try self.invoke(
          method: "setMemoryLimit",
          payload: ["bytes": prepared.memoryLimitBytes]
        )
        return try self.invoke(method: "runXrayFromJson", payload: ["configJSON": prepared.config])
      }
    } catch NativeAdapterError.xrayFailure(let reason, let path) {
      ProviderBoundaryEvidence.failure(
        .libXrayRun,
        code: .libXrayRunFailed,
        reason: reason,
        path: path,
        attempt: attempt
      )
      throw NativeAdapterError.xrayFailure(reason, path)
    } catch {
      ProviderBoundaryEvidence.failure(
        .libXrayRun,
        code: .libXrayRunFailed,
        attempt: attempt
      )
      throw error
    }
    guard response else {
      ProviderBoundaryEvidence.failure(
        .libXrayRun,
        code: .libXrayRunRejected,
        attempt: attempt
      )
      throw NativeAdapterError.operationFailed
    }
    ProviderBoundaryEvidence.success(.libXrayRun, attempt: attempt)
    lock.withLock { running = true }

    ProviderBoundaryEvidence.begin(.libXrayState, attempt: attempt)
    let stateConfirmed: Bool
    do {
      stateConfirmed = try await ProviderLifecycleRuntime.runBlocking {
        try self.invoke(method: "getXrayState", payload: [:])
      }
    } catch {
      ProviderBoundaryEvidence.failure(
        .libXrayState,
        code: .libXrayStateFailed,
        attempt: attempt
      )
      try? await stop()
      throw error
    }
    guard stateConfirmed else {
      ProviderBoundaryEvidence.failure(
        .libXrayState,
        code: .libXrayNotRunning,
        attempt: attempt
      )
      try? await stop()
      throw NativeAdapterError.notRunning
    }
    ProviderBoundaryEvidence.success(.libXrayState, attempt: attempt)
  }

  func stop() async throws {
    _ = try await ProviderLifecycleRuntime.runBlocking {
      try self.invoke(method: "stopXray", payload: [:])
    }
    lock.withLock { running = false }
  }

  func isRunning() async -> Bool {
    guard lock.withLock({ running }) else { return false }
    return (try? await ProviderLifecycleRuntime.runBlocking {
      try self.invoke(method: "getXrayState", payload: [:])
    }) == true
  }

  func metrics() async -> [String: UInt64] {
    (try? await ProviderLifecycleRuntime.runBlocking {
      let values = try Self.invokeObject(method: "getRuntimeMetrics", payload: [:])
      return values.reduce(into: [String: UInt64]()) { result, item in
        if let value = item.value as? NSNumber, value.int64Value >= 0 {
          result[item.key] = value.uint64Value
        }
      }
    }) ?? [:]
  }

  func passesTraffic(url: String, timeout: Int) async -> Bool {
    (try? await ProviderLifecycleRuntime.runBlocking {
      try Self.invokeObject(method: "ping", payload: ["runningCore": true, "url": url, "method": "GET",
        "timeout": timeout, "expectedStatus": 204, "expectedBody": ""])
    }) != nil
  }

  #if DEBUG
  func injectExit() { _ = try? invoke(method: "stopXray", payload: [:]) }
  #endif

  private func invoke(method: String, payload: [String: Any]) throws -> Bool {
    let data = try Self.invokeObject(method: method, payload: payload)
    if method == "getXrayState" {
      return data["running"] as? Bool == true
    }
    return true
  }

  static func invokeObject(method: String, payload: [String: Any]) throws -> [String: Any] {
    let request = try JSONSerialization.data(withJSONObject: [
      "apiVersion": 1,
      "method": method,
      "payload": payload,
    ])
    guard let requestText = String(data: request, encoding: .utf8),
          let requestPointer = strdup(requestText) else {
      throw NativeAdapterError.xrayFailure(.xrayBridgeFailed, .root)
    }
    defer { free(requestPointer) }
    guard let responsePointer = CGoInvoke(requestPointer) else {
      throw NativeAdapterError.xrayFailure(.xrayBridgeFailed, .root)
    }
    defer { CGoFree(responsePointer) }
    let responseData = Data(bytes: responsePointer, count: strlen(responsePointer))
    guard let response = try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
    else { throw NativeAdapterError.xrayFailure(.xrayBridgeFailed, .root) }
    guard response["success"] as? Bool == true else {
      let nativeError = (response["error"] as? String)?.lowercased() ?? ""
      let diagnostic = ProviderBoundaryReason.xrayDiagnostic(nativeError)
      throw NativeAdapterError.xrayFailure(diagnostic.0, diagnostic.1)
    }
    return response["data"] as? [String: Any] ?? [:]
  }

}

/// The core log, redacted where libXray records it. The app writes the level to the shared
/// container; the lines the extension kept when it last stopped stay readable there.
enum CoreLog {
  static var directory: URL? {
#if os(iOS)
    IOSPlatform.containerURL?.appendingPathComponent("Logs", isDirectory: true)
#else
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.elarni.mac")?
      .appendingPathComponent("Logs", isDirectory: true)
#endif
  }

  static func applyLevel(from directory: URL? = CoreLog.directory) {
    guard let url = directory?.appendingPathComponent("level"),
          let level = try? String(contentsOf: url, encoding: .utf8) else { return }
    _ = try? NativeXrayCore.invokeObject(method: "setLogLevel",
                                         payload: ["level": level.trimmingCharacters(in: .whitespacesAndNewlines)])
  }

  static func read(after: Int64) throws -> [String: Any] {
    try NativeXrayCore.invokeObject(method: "readLogs", payload: ["after": after])
  }

  static func persist(to directory: URL? = CoreLog.directory) {
    guard let directory, let lines = try? read(after: 0),
          let data = try? JSONSerialization.data(withJSONObject: lines) else { return }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? data.write(to: directory.appendingPathComponent("last.json"), options: .atomic)
  }
}

final class NativePacketBridge: PacketBridge, @unchecked Sendable {
  private let lock = NSLock()
  // Held while a thread waits in the bridge, so stop frees it only after that thread returns.
  private let waitLock = NSLock()
  private var bridge: OpaquePointer?
  private var receiveBuffer = [UInt8](repeating: 0, count: 65_535)

  func start(
    socksPort: UInt16,
    mtu: UInt16,
    tcpMaxConnections: Int,
    udpMaxConnections: Int,
    inboundCredentials: InboundCredentials?,
    attempt: ProviderBoundaryAttempt
  ) async throws {
    try await ProviderLifecycleRuntime.runBlocking {
      try self.startBlocking(
        socksPort: socksPort,
        mtu: mtu,
        tcpMaxConnections: tcpMaxConnections,
        udpMaxConnections: udpMaxConnections,
        inboundCredentials: inboundCredentials,
        attempt: attempt
      )
    }
  }

  private func startBlocking(
    socksPort: UInt16,
    mtu: UInt16,
    tcpMaxConnections: Int,
    udpMaxConnections: Int,
    inboundCredentials: InboundCredentials?,
    attempt: ProviderBoundaryAttempt
  ) throws {
    ProviderBoundaryEvidence.begin(.packetBridge, attempt: attempt)
    guard elarni_packet_abi_version() == ELARNI_PACKET_ABI_VERSION else {
      ProviderBoundaryEvidence.failure(
        .packetBridge,
        code: .packetBridgeAbiMismatch,
        attempt: attempt
      )
      throw NativeAdapterError.abiMismatch
    }
    let created: OpaquePointer?
    if let credentials = inboundCredentials {
      created = credentials.username.withUnsafeBytes { username in
        credentials.password.withUnsafeBytes { password in
          elarni_packet_bridge_new_authenticated(
            socksPort, mtu, tcpMaxConnections, udpMaxConnections, 256, 65_535,
            username.bindMemory(to: UInt8.self).baseAddress, username.count,
            password.bindMemory(to: UInt8.self).baseAddress, password.count
          )
        }
      }
    } else {
      created = elarni_packet_bridge_new(
        socksPort, mtu, tcpMaxConnections, udpMaxConnections, 256, 65_535
      )
    }
    guard let created else {
      ProviderBoundaryEvidence.failure(
        .packetBridge,
        code: .packetBridgeCreateFailed,
        attempt: attempt
      )
      throw NativeAdapterError.operationFailed
    }
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    var state = elarni_packet_bridge_state(created)
    while state.rawValue == 0, ProcessInfo.processInfo.systemUptime < deadline {
      Thread.sleep(forTimeInterval: 0.005)
      state = elarni_packet_bridge_state(created)
    }
    guard state.rawValue == 1 else {
      elarni_packet_bridge_free(created)
      ProviderBoundaryEvidence.failure(
        .packetBridge,
        code: .packetBridgeCreateFailed,
        attempt: attempt
      )
      throw NativeAdapterError.operationFailed
    }
    let accepted = lock.withLock { () -> Bool in
      guard bridge == nil else { return false }
      bridge = created
      return true
    }
    if !accepted {
      elarni_packet_bridge_free(created)
      ProviderBoundaryEvidence.failure(
        .packetBridge,
        code: .packetBridgeAlreadyRunning,
        attempt: attempt
      )
      throw NativeAdapterError.operationFailed
    }
    ProviderBoundaryEvidence.success(.packetBridge, attempt: attempt)
  }

  func submit(_ packet: Data) throws {
    try lock.withLock {
      guard let active = bridge else { throw NativeAdapterError.notRunning }
      guard !packet.isEmpty else { return }
      let status = packet.withUnsafeBytes { bytes in
        elarni_packet_bridge_submit(
          active,
          bytes.bindMemory(to: UInt8.self).baseAddress,
          packet.count
        )
      }
      // A full queue or a malformed packet (counted by the bridge) drops this
      // packet like a congested or noisy link; the tunnel stays up.
      guard status == ELARNI_PACKET_STATUS_OK || status == ELARNI_PACKET_STATUS_QUEUE_OVERFLOW ||
              status == ELARNI_PACKET_STATUS_MALFORMED_PACKET else {
        throw NativeAdapterError.operationFailed
      }
    }
  }

  func receive() -> Data? {
    lock.withLock {
      guard let active = bridge else { return nil }
      let capacity = receiveBuffer.count
      var written = 0
      return receiveBuffer.withUnsafeMutableBytes { bytes in
        let status = elarni_packet_bridge_receive(
          active,
          bytes.bindMemory(to: UInt8.self).baseAddress,
          capacity,
          &written
        )
        guard status.rawValue == 0 else { return nil }
        return Data(bytes: bytes.baseAddress!, count: written)
      }
    }
  }

  func awaitOutput(timeout: Duration) -> Bool? {
    waitLock.withLock {
      guard let active = lock.withLock({ bridge }) else { return nil }
      let (seconds, attoseconds) = timeout.components
      let status = elarni_packet_bridge_wait(active, UInt32(clamping: seconds * 1000 + attoseconds / 1_000_000_000_000_000))
      return status == ELARNI_PACKET_STATUS_OK ? true : status == ELARNI_PACKET_STATUS_EMPTY ? false : nil
    }
  }

  func stop(deadline _: Duration) async throws {
    try await ProviderLifecycleRuntime.runBlocking {
      try self.stopBlocking()
    }
  }

  private func stopBlocking() throws {
    let stopped = try lock.withLock { () -> OpaquePointer? in
      guard let active = bridge else { return nil }
      // Native stop owns the deadline and reports StopTimeout itself. It also wakes a waiting pump.
      let status = elarni_packet_bridge_stop(active)
      guard status.rawValue == 0 else { throw NativeAdapterError.stopTimeout }
      bridge = nil
      return active
    }
    if let stopped { waitLock.withLock { elarni_packet_bridge_free(stopped) } }
  }

  var counters: [String: UInt64] {
    lock.withLock {
      guard let active = bridge else { return [:] }
      var value = ElarniPacketCounters()
      guard elarni_packet_bridge_counters(active, &value).rawValue == 0 else { return [:] }
      return [
      "packetsIn": value.packets_in,
      "bytesIn": value.bytes_in,
      "packetsOut": value.packets_out,
      "bytesOut": value.bytes_out,
      "malformed": value.malformed,
      "overflows": value.overflows,
      "syntheticDnsAnswers": value.synthetic_dns_answers,
      "mappingHits": value.synthetic_mapping_hits,
      "restoredDomainSessions": value.restored_domain_sessions,
      "restoredProxySessions": value.restored_proxy_sessions,
      "restoredDirectSessions": value.restored_direct_sessions,
      "restoredBlockSessions": value.restored_block_sessions,
      "restoredDnsSessions": value.restored_dns_sessions,
      "activeTcpSessions": value.active_tcp_sessions,
      "activeUdpSessions": value.active_udp_sessions,
      "droppedTcpSessions": value.dropped_tcp_sessions,
      "droppedUdpSessions": value.dropped_udp_sessions,
      "mappingEvictions": value.synthetic_mapping_evictions,
      "mappingExpirations": value.synthetic_mapping_expirations,
      "allocationCollisions": value.synthetic_allocation_collisions,
      ]
    }
  }

  deinit {
    lock.withLock {
      if let active = bridge {
        _ = elarni_packet_bridge_stop(active)
        elarni_packet_bridge_free(active)
        bridge = nil
      }
    }
  }
}

private extension NSLock {
  func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
