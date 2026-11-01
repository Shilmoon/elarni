import CryptoKit
import AppKit
import Darwin
import FlutterMacOS
import Foundation
import Network
import NetworkExtension
import ServiceManagement

// Server latency probes: TCP, ICMP and the libXray HTTP probe.
extension TunnelMethodChannel {
  @MainActor
  func pingNode(arguments: [String: Any]) async throws -> [String: Any] {
    guard let nodeID = arguments["nodeId"] as? String,
          let pingProtocol = arguments["protocol"] as? String,
          ["proxy", "activeProxy", "tcp", "icmp"].contains(pingProtocol),
          let method = arguments["method"] as? String,
          ["GET", "HEAD"].contains(method),
          let mode = arguments["mode"] as? String,
          ["default", "double", "keepalive"].contains(mode),
          let timeout = arguments["timeout"] as? Int, (5...15).contains(timeout),
          let urlText = arguments["url"] as? String else {
      throw RunnerTunnelError.pingFailure
    }
    let store = try subscriptionStore()
    let outbound = try store.outbound(nodeID: nodeID)
    let configurationRevision = try store.configurationRevision(nodeID: nodeID)
    let nodePreference = try store.ipPreference(nodeID: nodeID)
    let nodeSettings = settingsStore.current.applyingIPPreference(nodePreference)
    let endpointPreference = outbound["outbounds"] == nil ? nodeSettings.preferredIP
      : nodeSettings.profilePreferredIP ?? "automatic"
    let delay: Int
    var probeDiagnostics: [String: Any]?
    var probePath: String?
    // Check exit reads Cloudflare's trace at the URL; the core names the exit.
    let trace = arguments["trace"] as? Bool == true
    var exit: Any?
    #if DEBUG
    let diagnosticVariant = arguments["diagnosticVariant"] as? String ?? ""
    #else
    let diagnosticVariant = ""
    #endif
    switch pingProtocol {
    case "proxy", "activeProxy":
      let expectedStatus = arguments["expectedStatus"] as? Int ?? 204
      let expectedBody = arguments["expectedBody"] as? String ?? ""
      // Only proxy probes fetch the URL; settings hide it for TCP and ICMP.
      guard (200...299).contains(expectedStatus), expectedBody.utf8.count <= 4096,
            method != "HEAD" || expectedBody.isEmpty, !trace || method == "GET",
            let url = URL(string: urlText), ["http", "https"].contains(url.scheme),
            url.user == nil, url.password == nil, url.fragment == nil else { throw RunnerTunnelError.pingFailure }
      let intentRevision = commands.revision
      let current = try? await loadManager()
      try Task.checkCancellation()
      if current?.connection.status == .connected &&
          (pingProtocol == "activeProxy" || settingsStore.current.includeAllNetworks) {
        guard store.selectedNodeID() == nodeID, commands.intent == .connected else {
          throw RunnerTunnelError.pingFailure
        }
        let subscriptionID = try store.subscriptionID(nodeID: nodeID)
        let started = automationNow()
        var diagnostic = ProbeDiagnostic(targetOrdinal: 1, revision: intentRevision,
          deadline: started + Double(timeout), started: started)
        diagnostic.outcomes[.localPath] = physicalPaths.isEmpty ? .unknown :
          (physicalPaths.values.contains(where: { $0.available }) ? .passed : .unreachable)
        defer {
          diagnostic.duration = max(0, automationNow() - started)
          if Task.isCancelled {
            diagnostic.outcomes[diagnostic.outcomes[.activeTraffic] == nil ? .providerBridge : .activeTraffic] = .cancelled
          }
          healthDiagnostics = [diagnostic]
        }
        try requireProbePolicy(subscriptionID: subscriptionID)
        let reference = try store.outboundRef(nodeID: nodeID)
        let settings = settingsStore.current
        let plan = try makePlan(secretRef: reference,
          routingRevision: store.routing.runtimeRevision(subscriptionID: subscriptionID))
        func requireContext() throws {
          try Task.checkCancellation()
          guard commands.intent == .connected, commands.revision == intentRevision,
                store.selectedNodeID() == nodeID, settingsStore.current == settings,
                try store.subscriptionID(nodeID: nodeID) == subscriptionID,
                try store.outboundRef(nodeID: nodeID) == reference,
                try makePlan(secretRef: reference,
                  routingRevision: store.routing.runtimeRevision(subscriptionID: subscriptionID)) == plan else {
            throw AutomationFailure.staleContext
          }
          try requireProbePolicy(subscriptionID: subscriptionID)
        }
        try requireContext()
        let before = try await runtimeMetrics()
        try requireContext()
        diagnostic.generation = before["generation"] as? UInt64
        diagnostic.outcomes[.providerBridge] = .failed
        guard before["state"] as? String != "quarantinedFailClosed",
              before["resourceRecoveryRequired"] as? Bool != true else { throw AutomationFailure.quarantine }
        guard before["state"] as? String == "connected",
              before["configurationDigest"] as? String == Data(SHA256.hash(data: plan)).base64EncodedString(),
              let generation = before["generation"] as? UInt64,
              let instance = before["instanceID"] as? String, !instance.isEmpty else {
          throw AutomationFailure.providerFailure
        }
        diagnostic.outcomes[.providerBridge] = .passed
        // A Runner-owned SOCKS probe is itself captured by full-tunnel policy.
        // Use ordinary application packets to verify the selected active path.
        let response: [String: Any]
        do {
          let native: Result<[String: Any], Error>
          do {
            var payload: [String: Any] = [
              "packetPath": true, "timeout": timeout, "url": urlText,
              "method": method, "mode": mode,
              "expectedStatus": expectedStatus, "expectedBody": expectedBody,
            ]
            if trace { payload["trace"] = true }
            native = .success(try await Self.invokeManualProbe(payload: payload))
          } catch { native = .failure(error) }
          try requireContext()
          diagnostic.outcomes[.providerBridge] = .unknown
          let after = try await runtimeMetrics()
          try requireContext()
          guard after["instanceID"] as? String == instance,
                after["generation"] as? UInt64 == generation,
                after["state"] as? String == "connected",
                after["resourceRecoveryRequired"] as? Bool != true,
                after["configurationDigest"] as? String == before["configurationDigest"] as? String else {
            throw AutomationFailure.staleContext
          }
          diagnostic.outcomes[.providerBridge] = .passed
          response = try native.get()
        } catch is CancellationError {
          diagnostic.recordNative([:], outcome: .cancelled)
          throw CancellationError()
        } catch let failure as RunnerProbeFailure {
          diagnostic.recordNative(failure.details, outcome: ProbeDiagnostic.outcome(code: failure.details["code"] as? String))
          throw failure
        } catch {
          diagnostic.recordNative([:], outcome: .unknown)
          throw error
        }
        diagnostic.recordNative(response["diagnostics"] as? [String: Any] ?? [:], outcome: .unknown)
        guard let value = response["delay"] as? NSNumber, value.doubleValue >= 0 else {
          throw RunnerTunnelError.pingFailure
        }
        diagnostic.outcomes[.providerBridge] = .passed
        diagnostic.outcomes[.activeTraffic] = .passed
        delay = value.intValue
        probeDiagnostics = Self.sanitizedProbeDiagnostics(response["diagnostics"])
        probePath = "packetTunnel"
        exit = response["exit"]
        break
      }
      var routes: [String: Any]?
      var runtime: [String: Any] = [:]
      var assetDirectory: String?
      if pingProtocol == "activeProxy" {
        let snapshot = try store.routing.runtimeProbeConfiguration(
          subscriptionID: store.subscriptionID(nodeID: nodeID)
        )
        routes = snapshot.routes ?? (outbound["outbounds"] == nil ? [
          "rules": [], "dnsServers": ["1.1.1.1"], "staticHosts": [:], "fallbackAction": "proxy",
        ] : nil)
        runtime = nodeSettings.compilerRuntime
        // A probe owns only its temporary SOCKS listener.
        runtime["httpInboundEnabled"] = false
        runtime["allowLan"] = false
        assetDirectory = snapshot.assetDirectory
      }
      if let nodePreference { runtime["preferredIp"] = nodePreference }
      let probeRoutes = routes
      let probeRuntime = runtime
      let probeAssets = assetDirectory
      let profilePreference = pingProtocol == "activeProxy" ? nodeSettings.profilePreferredIP : nodePreference
      let (config, port) = try await Task.detached {
        let port = try Self.freePort()
        let config = try Self.compilePingConfig(
          outbound: outbound, socksPort: port, routes: probeRoutes,
          runtime: probeRuntime, assetDirectory: probeAssets, profilePreferredIP: profilePreference
        )
        return (config, port)
      }.value
      try Task.checkCancellation()
      var payload: [String: Any] = [
        "configJSON": config,
        "timeout": timeout,
        "url": urlText,
        "proxy": "socks5://127.0.0.1:\(port)",
        "method": method,
        "mode": mode,
        "diagnosticVariant": diagnosticVariant,
        "expectedStatus": expectedStatus,
        "expectedBody": expectedBody,
      ]
      if trace { payload["trace"] = true }
      let nativeResult = try await Self.invokeManualProbe(payload: payload,
        probeConfiguration: Self.probeConfigurationSummary(outbound: outbound, config: config))
      guard let value = nativeResult["delay"] as? NSNumber else {
        throw RunnerTunnelError.pingFailure
      }
      delay = value.intValue
      probeDiagnostics = Self.sanitizedProbeDiagnostics(nativeResult["diagnostics"])
      probePath = "isolatedProxy"
      exit = nativeResult["exit"]
    case "tcp":
      guard !trace else { throw RunnerTunnelError.pingFailure }
      let endpoint = try Self.outboundEndpoint(outbound, requireTCP: true)
      delay = try await Self.measureTCP(
        host: endpoint.host,
        port: endpoint.port,
        timeout: timeout,
        preferredIP: endpointPreference
      )
    default:
      guard !trace else { throw RunnerTunnelError.pingFailure }
      let endpoint = try Self.outboundEndpoint(outbound)
      delay = try await measureICMP(
        host: endpoint.host,
        timeout: timeout,
        preferredIP: endpointPreference
      )
    }
    try Task.checkCancellation()
    var result: [String: Any] = [
      "nodeId": nodeID,
      "configurationRevision": configurationRevision,
      "protocol": pingProtocol,
      "status": "success",
      "latencyMs": delay,
      "timestamp": Date().timeIntervalSince1970,
    ]
    if let probeDiagnostics { result["diagnostics"] = probeDiagnostics }
    if let probePath { result["path"] = probePath }
    if let exit { result["exit"] = exit }
    return result
  }
  nonisolated private static func outboundEndpoint(_ outbound: [String: Any], requireTCP: Bool = false) throws -> (host: String, port: UInt16) {
    let config = outbound["outbounds"] == nil ? ["outbounds": [outbound]] : outbound
    let manifest = try RoutingDomainDecoder.request("profileEndpoints", payload: ["config": config])
    guard let endpoints = manifest["endpoints"] as? [[String: Any]],
          let endpoint = endpoints.first(where: { $0["physical"] as? Bool == true }),
          let host = endpoint["host"] as? String,
          let port = (endpoint["port"] as? NSNumber)?.intValue,
          !host.isEmpty, (1...65_535).contains(port) else {
      throw RunnerTunnelError.pingFailure
    }
    if requireTCP && endpoint["supportsTcpProbe"] as? Bool != true {
      throw RunnerTunnelError.unsupportedPingMethod
    }
    return (host, UInt16(port))
  }
  nonisolated private static func measureTCP(
    host: String,
    port: UInt16,
    timeout: Int,
    preferredIP: String
  ) async throws -> Int {
    guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
      throw RunnerTunnelError.pingFailure
    }
    let queue = DispatchQueue(label: "com.elarni.tcp-ping")
    let parameters = NWParameters.tcp
    if preferredIP == "ipv4" {
      (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
    }
    if preferredIP == "ipv6" {
      (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v6
    }
    let started = DispatchTime.now().uptimeNanoseconds
    let connection = NWConnection(
      host: NWEndpoint.Host(host),
      port: endpointPort,
      using: parameters
    )
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        var finished = false
        let finish: (Result<Int, Error>) -> Void = { result in
          guard !finished else { return }
          finished = true
          connection.cancel()
          continuation.resume(with: result)
        }
        queue.asyncAfter(deadline: .now() + .seconds(timeout)) {
          finish(.failure(RunnerTunnelError.pingFailure))
        }
        connection.stateUpdateHandler = { state in
          switch state {
          case .ready:
            let elapsed = (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            finish(.success(Int(elapsed)))
          case .failed, .cancelled:
            finish(.failure(RunnerTunnelError.pingFailure))
          default:
            break
          }
        }
        connection.start(queue: queue)
      }
    } onCancel: { connection.cancel() }
  }
  @MainActor
  private func measureICMP(host: String, timeout: Int, preferredIP: String) async throws -> Int {
    let selected = try await loadManager()
    let reconnect = selected.connection.status == .connected
    guard reconnect || selected.connection.status == .disconnected else {
      throw RunnerTunnelError.invalidState
    }
    if reconnect && commands.intent != .connected { throw RunnerTunnelError.connectionIntentRequired }
    if reconnect { try await stopForRestart(selected) }
    do {
      let delay = try await Task.detached {
        try Self.runICMPProbe(host: host, timeout: timeout, preferredIP: preferredIP)
      }.value
      try Task.checkCancellation()
      if reconnect {
        try await connect()
        try await waitForConnected()
      }
      return delay
    } catch {
      try Task.checkCancellation()
      guard reconnect else { throw RunnerTunnelError.pingFailure }
      do {
        try await connect()
        try await waitForConnected()
      } catch {
        try Task.checkCancellation()
        throw RunnerTunnelError.icmpRestoreFailed
      }
      throw RunnerTunnelError.icmpFailedRestored
    }
  }
#if ELARNI_CONTROL_CHECKS
  nonisolated static func checkICMPProbe(host: String, timeout: Int, preferredIP: String) throws -> Int {
    try runICMPProbe(host: host, timeout: timeout, preferredIP: preferredIP)
  }
  nonisolated static func checkICMPFallback() throws -> Int {
    var hints = addrinfo()
    hints.ai_family = AF_INET6
    hints.ai_socktype = SOCK_DGRAM
    var resolved: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo("::1", nil, &hints, &resolved) == 0, let resolved else {
      throw RunnerTunnelError.pingFailure
    }
    defer { freeaddrinfo(resolved) }
    var invalid = resolved.pointee
    invalid.ai_addrlen = 0 // Deterministic socket failure; no external endpoint.
    return try runICMPProbe(addresses: [invalid, resolved.pointee], timeout: 1)
  }
#endif
  nonisolated private static func runICMPProbe(host: String, timeout: Int, preferredIP: String) throws -> Int {
    var hints = addrinfo()
    hints.ai_family = preferredIP == "ipv6" ? AF_INET6 : preferredIP == "ipv4" ? AF_INET : AF_UNSPEC
    hints.ai_socktype = SOCK_DGRAM
    hints.ai_protocol = 0
    var resolved: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, nil, &hints, &resolved) == 0, let resolved else {
      throw RunnerTunnelError.pingFailure
    }
    defer { freeaddrinfo(resolved) }
    var addresses: [addrinfo] = []
    var cursor: UnsafeMutablePointer<addrinfo>? = resolved
    while let address = cursor {
      if address.pointee.ai_family == AF_INET || address.pointee.ai_family == AF_INET6 {
        addresses.append(address.pointee)
      }
      cursor = address.pointee.ai_next
    }
    return try runICMPProbe(addresses: addresses, timeout: timeout)
  }
  nonisolated private static func runICMPProbe(addresses: [addrinfo], timeout: Int) throws -> Int {
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(1, timeout)) * 1_000_000_000
    for (index, address) in addresses.enumerated() {
      let now = DispatchTime.now().uptimeNanoseconds
      guard now < deadline else { break }
      // Reserve time for other resolved addresses instead of allowing an
      // unreachable first family to consume the entire probe budget.
      let budget = max(1, Int((deadline - now) / 1_000_000) / (addresses.count - index))
      if let delay = try? runICMPProbe(address: address, timeoutMilliseconds: budget) { return delay }
    }
    throw RunnerTunnelError.pingFailure
  }
  nonisolated private static func runICMPProbe(address: addrinfo, timeoutMilliseconds: Int) throws -> Int {
    let family = address.ai_family
    let icmpProtocol = family == AF_INET6 ? IPPROTO_ICMPV6 : IPPROTO_ICMP
    let descriptor = socket(family, SOCK_DGRAM, icmpProtocol)
    guard descriptor >= 0 else { throw RunnerTunnelError.pingFailure }
    defer { Darwin.close(descriptor) }
    guard Darwin.connect(
      descriptor,
      address.ai_addr,
      address.ai_addrlen
    ) == 0 else { throw RunnerTunnelError.pingFailure }
    var receiveTimeout = timeval(tv_sec: timeoutMilliseconds / 1000,
      tv_usec: Int32((timeoutMilliseconds % 1000) * 1000))
    guard setsockopt(
      descriptor,
      SOL_SOCKET,
      SO_RCVTIMEO,
      &receiveTimeout,
      socklen_t(MemoryLayout<timeval>.size)
    ) == 0 else { throw RunnerTunnelError.pingFailure }

    var packet = [UInt8](repeating: 0, count: 16)
    packet[0] = family == AF_INET6 ? 128 : 8
    let identifier = UInt16(truncatingIfNeeded: getpid()).bigEndian
    withUnsafeBytes(of: identifier) { packet.replaceSubrange(4..<6, with: $0) }
    packet[7] = 1
    if family == AF_INET {
      let checksum = icmpChecksum(packet).bigEndian
      withUnsafeBytes(of: checksum) { packet.replaceSubrange(2..<4, with: $0) }
    }
    let started = DispatchTime.now().uptimeNanoseconds
    let sent = packet.withUnsafeBytes {
      Darwin.send(descriptor, $0.baseAddress, $0.count, 0)
    }
    guard sent == packet.count else { throw RunnerTunnelError.pingFailure }
    var response = [UInt8](repeating: 0, count: 256)
    let received = response.withUnsafeMutableBytes {
      Darwin.recv(descriptor, $0.baseAddress, $0.count, 0)
    }
    guard received > 0 else { throw RunnerTunnelError.pingFailure }
    let elapsed = (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
    return max(1, Int(elapsed))
  }
  nonisolated private static func icmpChecksum(_ bytes: [UInt8]) -> UInt16 {
    var sum: UInt32 = 0
    for index in stride(from: 0, to: bytes.count, by: 2) {
      sum += UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1])
    }
    while sum > 0xffff { sum = (sum & 0xffff) + (sum >> 16) }
    return ~UInt16(sum)
  }
  nonisolated static func freePort() throws -> Int {
    let response = try invokeLibXray(method: "getFreePorts", payload: ["count": 1])
    guard let port = (response["ports"] as? [NSNumber])?.first?.intValue else {
      throw RunnerTunnelError.pingFailure
    }
    return port
  }
  nonisolated static func compilePingConfig(
    outbound: [String: Any], socksPort: Int, routes: [String: Any]? = nil,
    runtime: [String: Any] = [:], assetDirectory: String? = nil, profilePreferredIP: String? = nil,
    packetBackend: String? = nil
  ) throws -> String {
    let profile = outbound["outbounds"] != nil
    var runtime = runtime
    if packetBackend == nil { runtime["perAppMode"] = "off" } // HTTP probes own only a SOCKS listener.
    var payload: [String: Any] = [profile ? "profile" : "outbound": outbound,
      "socksPort": socksPort, "runtime": runtime]
    if let packetBackend { payload["packetBackend"] = packetBackend; payload["tunMtu"] = 1500 }
    if let routes { payload["routes"] = routes }
    else if !profile {
      payload["routes"] = ["rules": [], "dnsServers": ["1.1.1.1"], "staticHosts": [:], "fallbackAction": "proxy"]
    }
    if profile, let profilePreferredIP { payload["preferredIp"] = profilePreferredIP }
    let request = try JSONSerialization.data(withJSONObject: [
      "schemaVersion": 1,
      "operation": profile ? "compileProfile" : "compileOutbound",
      "payload": payload,
    ])
    guard let handle = elarni_handle_new() else { throw RunnerTunnelError.pingFailure }
    defer { elarni_handle_free(handle) }
    var output = ElarniBuffer(data: nil, len: 0, capacity: 0)
    let status = request.withUnsafeBytes {
      elarni_request(handle, $0.bindMemory(to: UInt8.self).baseAddress, request.count, &output)
    }
    defer { elarni_buffer_free(output) }
    guard status == ELARNI_STATUS_OK, let bytes = output.data,
          let object = try JSONSerialization.jsonObject(
            with: Data(bytes: bytes, count: output.len)
          ) as? [String: Any],
          let config = object["configUtf8"] as? String else { throw RunnerTunnelError.pingFailure }
    guard let assetDirectory else { return config }
    guard let data = config.data(using: .utf8),
          var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw RunnerTunnelError.pingFailure
    }
    object["env"] = ["xray.location.asset": assetDirectory]
    return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
  }
  nonisolated static func invokeLibXray(method: String, payload: [String: Any], probeConfiguration: [String: Any]? = nil) throws -> [String: Any] {
    let data = try JSONSerialization.data(withJSONObject: [
      "apiVersion": 1, "method": method, "payload": payload,
    ])
    guard let text = String(data: data, encoding: .utf8), let request = strdup(text) else {
      throw RunnerTunnelError.pingFailure
    }
    defer { free(request) }
    guard let pointer = CGoInvoke(request) else { throw RunnerTunnelError.pingFailure }
    defer { CGoFree(pointer) }
    return try decodeLibXrayResponse(Data(bytes: pointer, count: strlen(pointer)),
      method: method, probeConfiguration: probeConfiguration)
  }
  nonisolated private static func invokeManualProbe(payload: [String: Any], probeConfiguration: [String: Any]? = nil) async throws -> [String: Any] {
    guard let executable = Bundle.main.url(forAuxiliaryExecutable: "elarni-core") else {
      throw RunnerTunnelError.pingFailure
    }
    let response = try await ProbeProcess.run(payload, executable: executable)
    return try decodeLibXrayResponse(response, method: "ping", probeConfiguration: probeConfiguration)
  }
  nonisolated private static func decodeLibXrayResponse(_ data: Data, method: String, probeConfiguration: [String: Any]?) throws -> [String: Any] {
    guard let response = try JSONSerialization.jsonObject(
      with: data
    ) as? [String: Any],
          var result = response["data"] as? [String: Any] else {
      throw RunnerTunnelError.pingFailure
    }
    if method == "ping", let probeConfiguration,
       var diagnostic = result["diagnostics"] as? [String: Any] {
      diagnostic["configuration"] = probeConfiguration
      result["diagnostics"] = diagnostic
    }
    guard response["success"] as? Bool == true else {
      if method == "ping", let details = sanitizedProbeDiagnostics(result["diagnostics"]) {
        throw RunnerProbeFailure(details: details)
      }
      throw RunnerTunnelError.pingFailure
    }
    return result
  }
  nonisolated private static func probeConfigurationSummary(outbound: [String: Any], config: String) -> [String: Any] {
    let source = (outbound["outbounds"] as? [[String: Any]])?.first ?? outbound
    guard let root = try? JSONSerialization.jsonObject(with: Data(config.utf8)) as? [String: Any],
          let outputs = root["outbounds"] as? [[String: Any]],
          let compiled = outbound["outbounds"] == nil ? outputs.first(where: { $0["tag"] as? String == "elarni-proxy" }) : outputs.first else { return [:] }
    let before = source["streamSettings"] as? [String: Any] ?? [:]
    let after = compiled["streamSettings"] as? [String: Any] ?? [:]
    let xhttp = after["xhttpSettings"] as? [String: Any] ?? [:]
    let effectiveXHTTP = xhttp.keys.contains("extra") ? (xhttp["extra"] as? [String: Any] ?? [:]) : xhttp
    let originalReality = before["realitySettings"] as? [String: Any] ?? [:]
    let compiledReality = after["realitySettings"] as? [String: Any] ?? [:]
    let originalName = (originalReality["serverName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
      ?? (originalReality["serverNames"] as? [String])?.first
    let equal: (Any?, Any?) -> Bool = { lhs, rhs in
      NSDictionary(dictionary: ["value": lhs ?? NSNull()]).isEqual(to: ["value": rhs ?? NSNull()])
    }
    var summary: [String: Any] = [
      "streamSettingsPreserved": equal(before, after),
      "realitySettingsPreserved": equal(before["realitySettings"], after["realitySettings"]),
      "accountSettingsPreserved": equal(source["settings"], compiled["settings"]),
      "muxPreserved": equal(source["mux"], compiled["mux"]),
      "downloadSettingsPresent": effectiveXHTTP["downloadSettings"] is [String: Any],
      "xhttpSettingsPreserved": equal(before["xhttpSettings"], after["xhttpSettings"]),
      "realityKeyPreserved": equal(originalReality["publicKey"], compiledReality["publicKey"]) && equal(originalReality["password"], compiledReality["password"]),
      "realityShortIdPreserved": equal(originalReality["shortId"], compiledReality["shortId"]),
      "realityFingerprintPreserved": equal(originalReality["fingerprint"], compiledReality["fingerprint"]),
      "realityServerNamePreserved": equal(originalName, compiledReality["serverName"]),
      "modePresent": xhttp["mode"] != nil,
    ]
    if let mode = xhttp["mode"] as? String, ["auto", "packet-up", "stream-one", "stream-up"].contains(mode) { summary["mode"] = mode }
    return summary
  }
  nonisolated static func sanitizedProbeDiagnostics(_ value: Any?) -> [String: Any]? {
    guard let value = value as? [String: Any] else { return nil }
    let codes: Set<String> = ["ok", "failed", "timeout", "canceled", "eof", "unexpected_eof", "closed_pipe", "target_dns_failed"]
    let stages: Set<String> = [
      "admission", "instance_start", "target_request", "target_dns", "native_enter", "native_return",
      "instance_admitted", "instance_start_begin", "instance_start_end", "instance_close_begin", "instance_close_end",
      "request_begin", "request_end", "target_response", "target_dns_start", "target_dns_done", "target_dns_hosts",
      "target_dns_resolver", "control_system_resolution", "proxy_socket_start", "proxy_socket_done",
      "reality_start", "reality_done", "reality_handshake_done", "xhttp_connection_obtained", "xhttp_download_response", "xhttp_upload_response",
    ]
    var result: [String: Any] = [:]
    for key in ["code", "transportCode", "cleanupCode"] {
      if let text = value[key] as? String, codes.contains(text) { result[key] = text }
    }
    if let stage = value["stage"] as? String, stages.contains(stage) { result["stage"] = stage }
    if let state = value["cleanupState"] as? String, ["not_started", "instance_closed", "failed", "pending"].contains(state) {
      result["cleanupState"] = state
    }
    for key in ["probeId", "httpStatus", "trackedWorkComplete"] {
      if let number = value[key] as? NSNumber { result[key] = number }
    }
    result["events"] = (value["events"] as? [[String: Any]] ?? []).prefix(256).compactMap { event -> [String: Any]? in
      guard let stage = event["stage"] as? String, stages.contains(stage) else { return nil }
      var safe: [String: Any] = ["stage": stage]
      if let role = event["role"] as? String, ["target", "dns"].contains(role) { safe["role"] = role }
      if let code = event["code"] as? String, codes.contains(code) { safe["code"] = code }
      for key in ["session", "elapsedMs", "status", "reused", "verified"] {
        if let number = event[key] as? NSNumber { safe[key] = number }
      }
      return safe
    }
    if let configuration = value["configuration"] as? [String: Any] {
      var safe: [String: Any] = [:]
      for key in ["streamSettingsPreserved", "realitySettingsPreserved", "accountSettingsPreserved", "muxPreserved", "downloadSettingsPresent", "modePresent", "xhttpSettingsPreserved", "realityKeyPreserved", "realityShortIdPreserved", "realityFingerprintPreserved", "realityServerNamePreserved"] {
        if let flag = configuration[key] as? Bool { safe[key] = flag }
      }
      if let mode = configuration["mode"] as? String, ["auto", "packet-up", "stream-one", "stream-up"].contains(mode) { safe["mode"] = mode }
      result["configuration"] = safe
    }
    return result
  }
}

struct RunnerProbeFailure: Error {
  let details: [String: Any]
}
