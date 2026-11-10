import CryptoKit
import Foundation
import Network
import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
  private let secretStore: KeychainSecretStore = SystemKeychainSecretStore()
  private let xray: XrayCore = NativeXrayCore()
  private let bridge: PacketBridge = NativePacketBridge()
  private let lifecycle = ProviderLifecycleCoordinator()
  private let runtime = ProviderLifecycleRuntime()
  private let switchCancellation = ProviderSwitchCancellation()
  private let backendLock = NSLock()
  private var activeBackend: TunnelBackend?
  private var utunDiagnostic: (state: ProviderLifecycleState, count: Int)?
  private var activeConfiguration: (TunnelPlan, PreparedXray)?
  // Random login used when the user leaves inbound login off, so other local apps cannot ride the VPN's listener.
  private var sessionCredentials: InboundCredentials?
  private var activePlanDigest: Data?
  private let instanceID = UUID().uuidString
  private var sleeping = false
  private var bridgeFailure: ProviderLifecycleGeneration?
  // The monitor's latest verdict, for the generation it watched.
  private var liveness: (generation: UInt64, state: String?)?
#if os(iOS)
  private var alertArmedAt = -Double.infinity
#endif
  // Pooled outbound connections stay on a path that is gone after a handoff, and the app
  // may not be running to notice; the extension tells the core or restarts it itself.
  private let pathMonitor = NWPathMonitor()
  private var pathMonitorStarted = false
  private var latestPath: (signature: String, satisfied: Bool)?
  // The path the core last opened its connections on, and whether the primary path left it since.
  private var corePath: String?
  private var pathMoved = false
  // The core failed its liveness checks; the next path check restarts it on the same path.
  private var coreStalled = false
  // Stall restarts since a check last passed; each one doubles the failed checks the next needs.
  private var stallRestarts = 0
  private var pathSettle: Task<Void, Never>?
  // A handoff often flaps for a few seconds; restart once it has held.
  private static let pathSettleTime = Duration.seconds(6)
  // Checks after a restart that could not run or failed before the core stopped; reset when the core moves.
  private var pathRetries = 0
  // The path restart in flight, and the one a user switch made give way.
  private var pathRestart: ProviderLifecycleGeneration?
  private var pathRestartYielded: ProviderLifecycleGeneration?
  // The switch past its point of no return: the old core's monitor is paused and the core stops next.
  private var switchCommitted: ProviderLifecycleGeneration?
#if DEBUG
  private let debugFaults = ProviderDebugFaults(save: ProviderDebugFaults.save)
  private var debugSaveStop: (ProviderDebugFaults.StopReceipt) throws -> Void = ProviderDebugFaults.saveStop
#endif
  // In the host's version+build form: the Mac app warns when the system runs another copy's extension.
  private static let version: String = {
    let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    return build.isEmpty ? short : "\(short)+\(build)"
  }()

  override func startTunnel(
    options: [String: NSObject]?,
    completionHandler: @escaping (Error?) -> Void
  ) {
    // Peek at the switch before any boundary marker, so a failed start is recorded whole.
    if DiagnosticLog.always || (try? savedPlan())?.plan.runtimeSettings.recordDiagnostics == true {
      DiagnosticLog.start(role: "provider")
    }
    DiagnosticLog.record("provider_start")
    CoreLog.applyLevel()
    guard let generation = lifecycle.beginStart(reserving: { runtime.reserve($0) }) else {
      completionHandler(ProviderError.invalidState)
      return
    }
    startPathMonitor()
    let attempt = ProviderBoundaryEvidence.reset()
    guard runtime.setAttempt(attempt, generation: generation) else {
      ProviderBoundaryEvidence.finish(attempt)
      completionHandler(ProviderError.startCancelled)
      return
    }
    ProviderBoundaryEvidence.begin(.providerLifecycle, attempt: attempt)

    let launched = runtime.launchStartup(generation: generation) { [weak self] in
      guard let self else {
        completionHandler(ProviderError.startCancelled)
        return
      }
      await self.runStartup(
        generation: generation,
        attempt: attempt,
        options: options,
        completionHandler: completionHandler
      )
    }
    if !launched { completionHandler(ProviderError.startCancelled) }
  }

  override func stopTunnel(
    with reason: NEProviderStopReason,
    completionHandler: @escaping () -> Void
  ) {
    DiagnosticLog.record("provider_stop", ["reason": Int64(reason.rawValue)])
    CoreLog.persist()
#if os(iOS)
    // Alert after cleanup has joined the monitor, so a late refresh cannot re-arm it.
    let cause = Self.unexpectedStopCause(reason)
    let completion = {
      if let cause { IOSConnectionAlerts.stopped(cause) } else { IOSConnectionAlerts.disarm() }
      DiagnosticLog.stop()
      completionHandler()
    }
#else
    let completion = {
      DiagnosticLog.stop()
      completionHandler()
    }
#endif
    let action = lifecycle.beginStop(completion: completion)
    guard case let .cleanup(generation) = action else { return }
#if DEBUG
    debugFaults.finish("cancelled", generation: generation.rawValue)
#endif
    let detached = runtime.detach(generation)
    if let attempt = detached.attempt {
      ProviderBoundaryEvidence.begin(.providerLifecycle, attempt: attempt)
    }
    beginCleanup(generation: generation, detached: detached, startupError: nil)
  }

  override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
    if messageData == Data("diagnostics_mark".utf8) || messageData == Data("diagnostics_flush".utf8) {
      Task {
        let recorded = (try? await DiagnosticLog.perform(messageData == Data("diagnostics_mark".utf8) ? "mark" : "flush")) != nil
        completionHandler?(try? JSONSerialization.data(withJSONObject: ["recorded": recorded]))
      }
      return
    }
#if DEBUG
    if messageData.count <= 4096,
       let object = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any],
       object["operation"] as? String == "debugCoreExit" {
      var armedFault: (UUID, UInt64)?
      do {
        guard object["schemaVersion"] as? Int == 1,
              let payload = object["fault"],
              case let .running(generation) = lifecycle.state,
              let core = xray as? NativeXrayCore else { throw ProviderDebugFaults.Failure.rejected }
        let request = try JSONDecoder().decode(ProviderDebugFaults.Request.self,
          from: JSONSerialization.data(withJSONObject: payload))
        guard request.action == .coreExit else { throw ProviderDebugFaults.Failure.rejected }
        try debugFaults.arm(request, instanceID: instanceID, generation: generation.rawValue,
                            now: ProcessInfo.processInfo.systemUptime)
        armedFault = (request.id, generation.rawValue)
        guard try debugFaults.consume(.coreExit, generation: generation.rawValue,
                                      now: ProcessInfo.processInfo.systemUptime) else {
          throw ProviderDebugFaults.Failure.rejected
        }
        core.injectExit()
        completionHandler?(Self.switchResponse("injected"))
      } catch {
        if let (id, generation) = armedFault { debugFaults.finish("cancelled", generation: generation, requestID: id) }
        completionHandler?(Self.switchResponse("rejected"))
      }
      return
    }
#endif
    if messageData != Data("state".utf8) {
      if messageData.count <= 256,
         let request = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any],
         request["operation"] as? String == "logs" {
        // The app may have chosen another level since this tunnel started.
        CoreLog.applyLevel()
        let lines = try? CoreLog.read(after: (request["after"] as? NSNumber)?.int64Value ?? 0)
        completionHandler?(try? JSONSerialization.data(withJSONObject: lines ?? [:]))
        return
      }
      if messageData.count <= 256,
         let request = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any],
         request["operation"] as? String == "connections" {
        // The connections view: recent routing decisions with the app per-app routing found.
        let list = try? NativeXrayCore.invokeObject(method: "readConnections", payload: [
          "epoch": (request["epoch"] as? NSNumber)?.int64Value ?? 0,
          "after": (request["after"] as? NSNumber)?.uint64Value ?? 0,
        ])
        completionHandler?(try? JSONSerialization.data(withJSONObject: list ?? [:]))
        return
      }
      if messageData.count <= 1024,
         let request = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any],
         request["operation"] as? String == "prepareStop" {
        prepareStop(messageData, completionHandler: completionHandler)
        return
      }
      if messageData.count <= 1024,
         let request = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any],
         request["schemaVersion"] as? Int == 1, request["operation"] as? String == "cancelSwitch",
         let text = request["operationID"] as? String, let id = UUID(uuidString: text) {
        if switchCancellation.cancel(id), case .switching(let generation) = lifecycle.state {
#if DEBUG
          debugFaults.finish("cancelled", generation: generation.rawValue, requestID: id)
#endif
          runtime.cancelStartup(generation)
        }
        completionHandler?(Self.switchResponse("cancelled"))
        return
      }
      guard messageData.count <= 96 * 1024,
            let request = try? JSONDecoder().decode(ProviderSwitchRequest.self, from: messageData),
            request.schemaVersion == 1, ["switch", "refreshPath"].contains(request.operation),
            let plan = try? request.envelope.validatedPlan() else {
        completionHandler?(Self.switchResponse("rejected"))
        return
      }
      let id = request.operationID ?? UUID()
      let failedGeneration = backendLock.withLock { bridgeFailure }
      guard failedGeneration == nil || failedGeneration?.rawValue != lifecycle.state.generation else {
        completionHandler?(Self.switchResponse("quarantined"))
        return
      }
      guard switchCancellation.admit(id) else {
        completionHandler?(Self.switchResponse(switchCancellation.saturated ? "quarantined" : "rejected"))
        return
      }
      var debugGeneration: UInt64?
#if DEBUG
      if let fault = request.debugFault {
        do {
          guard [.candidateFailure, .restoreFailure].contains(fault.action), fault.id == id, request.operation == "switch",
                case let .running(generation) = lifecycle.state else { throw ProviderDebugFaults.Failure.rejected }
          try debugFaults.arm(fault, instanceID: instanceID, generation: generation.rawValue,
                              now: ProcessInfo.processInfo.systemUptime)
          debugGeneration = generation.rawValue
        } catch {
          switchCancellation.finish(id)
          completionHandler?(Self.switchResponse("rejected"))
          return
        }
      }
#endif
      guard let generation = lifecycle.beginSwitch(requiringRunning: debugGeneration != nil) else {
#if DEBUG
        if let debugGeneration { debugFaults.finish("cancelled", generation: debugGeneration, requestID: id) }
#endif
        switchCancellation.finish(id)
        // A path restart in flight gives way, or, past its commit, finishes first: this switch
        // restarts the core on the new path too.
        if debugGeneration == nil, let pending = backendLock.withLock({ () -> (restart: ProviderLifecycleGeneration, committed: Bool)? in
          guard let restart = pathRestart, restart != pathRestartYielded else { return nil }
          pathRestartYielded = restart
          return (restart, switchCommitted == restart)
        }) {
          if !pending.committed { runtime.cancelStartup(pending.restart) }
          Task { [weak self] in
            // A committed restart only has the new core to start; 5 s covers that, the 15 s bound does not.
            for _ in 0..<50 where self?.lifecycle.state == .switching(pending.restart) { try? await Task.sleep(for: .milliseconds(100)) }
            self?.handleAppMessage(messageData, completionHandler: completionHandler)
          }
          return
        }
        completionHandler?(Self.switchResponse(lifecycle.state.label == "quarantinedFailClosed" ? "quarantined" : "rejected"))
        return
      }
      let launched = runtime.launchStartup(generation: generation) { [weak self] in
        guard let self else {
          completionHandler?(Self.switchResponse("rejected"))
          return
        }
        let refreshOnly = request.operation == "refreshPath" &&
          self.backendLock.withLock { self.activePlanDigest == request.envelope.digest }
        let code = await self.boundedSwitch(plan: plan, generation: generation, refreshOnly: refreshOnly, operationID: id,
          onDeadline: { self.switchCancellation.cancel(id) }, cancelled: { self.switchCancellation.isCancelled(id) })
        if code == "switched" { self.backendLock.withLock { self.activePlanDigest = request.envelope.digest } }
#if os(iOS)
        if ["protectedFailure", "quarantinedFailClosed"].contains(self.lifecycle.state.label) { IOSConnectionAlerts.failed() }
        else if code == "switched" { IOSConnectionAlerts.connected() }
#endif
#if DEBUG
        if request.debugFault != nil { self.debugFaults.finish(code, generation: generation.rawValue, requestID: id) }
#endif
        self.runtime.startupFinished(generation)
        self.switchCancellation.finish(id)
        completionHandler?(Self.switchResponse(code, digest: request.envelope.digest))
      }
      if !launched {
#if DEBUG
        if request.debugFault != nil { debugFaults.finish("cancelled", generation: generation.rawValue, requestID: id) }
#endif
        lifecycle.finishSwitch(generation, restored: true)
        switchCancellation.finish(id)
        completionHandler?(Self.switchResponse("rejected"))
      }
      return
    }
    Task {
      let lifecycleState = lifecycle.state
      let utunCount = backendLock.withLock {
        if let cached = utunDiagnostic, cached.state == lifecycleState { return cached.count }
        let count = UtunDescriptorResolver.candidates().count
        utunDiagnostic = (lifecycleState, count)
        return count
      }
      let backend = currentBackend
      let counters = backend == .xrayTun ? await xray.metrics() : bridge.counters
      let liveness = backendLock.withLock {
        self.liveness.flatMap { $0.generation == lifecycleState.generation ? $0.state : nil }
      }
      let response: [String: Any] = [
        "schemaVersion": 1,
        "state": lifecycleState.label,
        "instanceID": instanceID,
        "sleeping": backendLock.withLock { sleeping },
        "resourceRecoveryRequired": backendLock.withLock {
          bridgeFailure.map { $0.rawValue == lifecycleState.generation } ?? false
        },
        "configurationDigest": backendLock.withLock { activePlanDigest?.base64EncodedString() ?? "" },
        "generation": lifecycleState.generation ?? 0,
        "counters": counters,
        "liveness": liveness.map { $0 as Any } ?? NSNull(),
        "endpoint": "[REDACTED]",
        "sharedKeychainResolved": runtime.sharedKeychainResolved,
        "backend": backend?.rawValue ?? "none",
        "utunCandidateCount": utunCount,
        "utunDescriptorReady": utunCount == 1,
        "extensionMemoryBytes": Self.memoryFootprint(),
        "extensionVersion": Self.version,
      ]
      completionHandler?(try? JSONSerialization.data(withJSONObject: response))
    }
  }

  override func sleep(completionHandler: @escaping () -> Void) {
    DiagnosticLog.record("sleep")
    backendLock.withLock {
      sleeping = true
#if os(iOS)
      // A sleeping extension cannot push the pending alert back; the monitor re-arms after wake.
      IOSConnectionAlerts.disarm()
      alertArmedAt = -.infinity
#endif
    }
    completionHandler()
  }
  override func wake() {
    backendLock.withLock { sleeping = false }
    DiagnosticLog.record("wake")
    backendLock.withLock {
#if os(macOS)
      // A Mac's network sleeps with it: its pooled connections may be gone on the same path.
      pathMoved = true
#endif
      // A handoff during sleep is acted on now.
      schedulePathCheck()
    }
  }

  private func startPathMonitor() {
    let start = backendLock.withLock {
      defer { pathMonitorStarted = true }
      return !pathMonitorStarted
    }
    guard start else { return }
    pathMonitor.pathUpdateHandler = { [weak self] path in self?.pathChanged(path) }
    pathMonitor.start(queue: DispatchQueue(label: "elarni.provider.path"))
  }

  private func pathChanged(_ path: Network.NWPath) {
    // New connections take the preferred physical interface (the tunnel's utun is
    // `.other`). Cellular coming and going behind Wi-Fi leaves the core's connections
    // alone; any departure of the primary path, even one that returns, may not.
    let interfaces = path.availableInterfaces.filter { $0.type != .other && $0.type != .loopback }
    let satisfied = path.status == .satisfied
    // IPv4 gateways and the interface's IPv4 address tell apart two Wi-Fi networks on one
    // interface; IPv6 router advertisements and the list order change without a handoff.
    let gateways = path.gateways.compactMap { endpoint -> String? in
      if case .hostPort(.ipv4(let address), _) = endpoint { return "\(address)" }
      return nil
    }.sorted()
    let primary = interfaces.first.map { ["\($0.type):\($0.index)"] + Self.ipv4Addresses(of: $0.name) } ?? []
    let signature = satisfied ? (primary + gateways).joined(separator: ",") : ""
    DiagnosticLog.record("network_path", ["available": satisfied ? 1 : 0, "interfaces": Int64(interfaces.count),
      "ipv4": path.supportsIPv4 ? 1 : 0, "ipv6": path.supportsIPv6 ? 1 : 0, "expensive": path.isExpensive ? 1 : 0])
    backendLock.withLock {
      latestPath = (signature, satisfied)
      if corePath == nil, activeConfiguration != nil { corePath = signature }
      if let corePath, signature != corePath { pathMoved = true }
      schedulePathCheck()
    }
  }

  private static func ipv4Addresses(of name: String) -> [String] {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let first = list else { return [] }
    defer { freeifaddrs(list) }
    var addresses: [String] = []
    for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
      guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
            String(cString: entry.pointee.ifa_name) == name else { continue }
      var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
        addresses.append(String(cString: host))
      }
    }
    return addresses.sorted()
  }

  /// Call with backendLock held.
  private func schedulePathCheck(after delay: Duration = pathSettleTime) {
    pathSettle?.cancel()
    pathSettle = Task { [weak self] in
      do { try await Task.sleep(for: delay) } catch { return }
      self?.restartIfPathMoved()
    }
  }

  /// Call with backendLock held. Waits 12, 24, 48, then 60 s.
  private func retryPathCheck() {
    pathRetries = min(pathRetries + 1, 4)
    schedulePathCheck(after: .seconds(min(6 << pathRetries, 60)))
  }

  private func restartIfPathMoved() {
    let work: (plan: TunnelPlan, refreshOnly: Bool)? = backendLock.withLock {
      guard !sleeping, pathMoved || coreStalled, latestPath?.satisfied == true,
            let plan = activeConfiguration?.0 else { return nil }
#if os(iOS)
      // Connections on a primary path that is gone die with it, and a restart closes them at once.
      // Back on the core's own path, telling the core keeps the ones that still work.
      let restart = coreStalled || latestPath?.signature != corePath
#else
      // A Mac keeps the connections on its other interfaces: tell the core, unless its server
      // addresses or DNS moved, which the refresh restarts it for.
      let restart = coreStalled
#endif
      return (plan, !restart)
    }
    guard let work else { return }
    // runSwitch restarts only the native tun2proxy backend in place; Xray's own TUN can only be told.
    guard work.plan.effectiveBackend == .nativeTun2Proxy else {
      Task { [weak self] in
        if await self?.xray.socketPathChanged() == true { self?.noteCorePath() }
      }
      return
    }
    let plan = work.plan
    guard let generation = lifecycle.beginSwitch() else {
      // A switch or refresh is running; its core may have started on the old path.
      backendLock.withLock { retryPathCheck() }
      return
    }
    backendLock.withLock { pathRestart = generation }
    DiagnosticLog.record("path_restart", ["generation": Int64(generation.rawValue), "refresh": work.refreshOnly ? 1 : 0])
    let launched = runtime.launchStartup(generation: generation) { [weak self] in
      guard let self else { return }
      self.finishPathRestart(generation, code: await self.boundedSwitch(plan: plan, generation: generation,
                                                                       refreshOnly: work.refreshOnly))
    }
    if !launched {
      lifecycle.finishSwitch(generation, restored: true)
      backendLock.withLock {
        pathRestart = nil
        retryPathCheck()
      }
    }
  }

  private func finishPathRestart(_ generation: ProviderLifecycleGeneration, code: String) {
#if os(iOS)
    if ["protectedFailure", "quarantinedFailClosed"].contains(lifecycle.state.label) { IOSConnectionAlerts.failed() }
    else if code == "switched" { IOSConnectionAlerts.connected() }
#endif
    DiagnosticLog.record("path_restart_done", ["switched": code == "switched" ? 1 : 0])
    runtime.startupFinished(generation)
    backendLock.withLock {
      pathRestart = nil
      // Failed before the core stopped (DNS or the Keychain not ready on the new path), or gave way.
      if pathMoved || coreStalled, code != "cancelled" || pathRestartYielded != generation { retryPathCheck() }
    }
  }

#if os(iOS)
  /// Stops the user did not ask for. Settings, another VPN, sleep and removal stay quiet.
  private static func unexpectedStopCause(_ reason: NEProviderStopReason) -> String? {
    switch reason {
    case .noNetworkAvailable: String(localized: "no network was available")
    case .unrecoverableNetworkChange: String(localized: "the network changed")
    case .providerFailed, .connectionFailed, .configurationFailed, .internalError: String(localized: "the connection failed")
    case .idleTimeout: String(localized: "the connection was idle")
    case .appUpdate: String(localized: "Elarni was updated")
    default: nil
    }
  }
#endif

  /// Bytes the malloc zones hold for Rust, Swift and the system frameworks; Go maps its own memory.
  private static func mallocInUse() -> Int {
    var stats = malloc_statistics_t()
    malloc_zone_statistics(nil, &stats)
    return stats.size_in_use
  }

  /// The footprint iOS holds against the extension's 50 MB limit; resident size counts shared pages too.
  private static func memoryFootprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<natural_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return status == KERN_SUCCESS ? info.phys_footprint : 0
  }

  private func runStartup(
    generation: ProviderLifecycleGeneration,
    attempt: ProviderBoundaryAttempt,
    options: [String: NSObject]? = nil,
    completionHandler: @escaping (Error?) -> Void
  ) async {
    var debugRequestID: UUID?
    do {
      try requireActive(generation)
#if DEBUG
      if let data = options?["elarniDebugFault"] as? Data {
        guard data.count <= 4096 else { throw ProviderDebugFaults.Failure.rejected }
        let request = try JSONDecoder().decode(ProviderDebugFaults.Request.self, from: data)
        guard request.action == .startupFailure else { throw ProviderDebugFaults.Failure.rejected }
        try debugFaults.arm(request, instanceID: instanceID, generation: generation.rawValue,
                            now: ProcessInfo.processInfo.systemUptime)
        debugRequestID = request.id
      }
#endif
      let plan = try loadPlan()
      let backend = plan.effectiveBackend
      var endpoint = try await ProviderLifecycleRuntime.runBlocking {
        try self.secretStore.resolve(secretRef: plan.secretRef, attempt: attempt)
      }
      runtime.markKeychainResolved(generation)
      defer { endpoint.clear() }
      var servers = try await resolvePerAppServers(plan, attempt: attempt)
      defer { for ref in Array(servers.keys) { servers[ref]?.clear() } }
      var inboundCredentials: InboundCredentials?
      if plan.runtimeSettings.inboundAuthEnabled == true {
        guard let reference = plan.runtimeSettings.inboundCredentialRef else {
          throw TunnelPlanError.invalidBounds
        }
        var secret = try await ProviderLifecycleRuntime.runBlocking {
          try self.secretStore.resolve(secretRef: reference, attempt: attempt)
        }
        defer { secret.clear() }
        inboundCredentials = try InboundCredentials(data: secret.bytes)
      } else {
        func token() -> String { (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined() }
        let session = try InboundCredentials(data: JSONSerialization.data(
          withJSONObject: ["username": token(), "password": token()]))
        backendLock.withLock { sessionCredentials = session }
        inboundCredentials = session
      }
      defer { inboundCredentials?.clear() }
      try requireActive(generation)

      let prepared = try await xray.prepare(
        plan: plan,
        endpoint: &endpoint,
        servers: servers,
        inboundCredentials: inboundCredentials,
        attempt: attempt
      )
      try requireActive(generation)
      ProviderBoundaryEvidence.begin(.tunnelSettings, attempt: attempt)
      do {
        let settings = try TunnelSettingsFactory.make(
          plan: plan,
          excludedEndpointAddresses: prepared.addresses,
          keepDiscovery: protocolConfiguration.includeAllNetworks
        )
        try await apply(settings)
        ProviderBoundaryEvidence.success(.tunnelSettings, attempt: attempt)
      } catch {
        ProviderBoundaryEvidence.failure(
          .tunnelSettings,
          code: .tunnelSettingsApplyFailed,
          attempt: attempt
        )
        throw error
      }
      guard lifecycle.isActive(generation), !Task.isCancelled else {
        _ = await clearSettings()
        try? await bridge.stop(deadline: .seconds(2))
        try? await xray.stop()
        throw ProviderError.startCancelled
      }

#if DEBUG
      if try debugFaults.consume(.startup, generation: generation.rawValue, now: ProcessInfo.processInfo.systemUptime) {
        throw ProviderDebugFaults.Failure.injected
      }
#endif
      try await xray.start(prepared, attempt: attempt)
      noteCorePath()
      guard lifecycle.isActive(generation), !Task.isCancelled else {
        try? await xray.stop()
        throw ProviderError.startCancelled
      }

      if backend == .nativeTun2Proxy {
        try await bridge.start(
          socksPort: plan.socksPort,
          mtu: plan.mtu,
          tcpMaxConnections: plan.runtimeSettings.tcpMaxConnections,
          udpMaxConnections: plan.runtimeSettings.udpMaxConnections,
          inboundCredentials: inboundCredentials,
          attempt: attempt
        )
        guard lifecycle.isActive(generation), !Task.isCancelled else {
          try? await bridge.stop(deadline: .seconds(2))
          try? await xray.stop()
          throw ProviderError.startCancelled
        }
      }

      if backend == .nativeTun2Proxy {
        ProviderBoundaryEvidence.begin(.packetPump, attempt: attempt)
        let packetPump = PacketFlowPump(flow: packetFlow, bridge: bridge) { [weak self] error in
          guard let self, self.lifecycle.isActive(generation) else { return }
          ProviderBoundaryEvidence.failure(
            .packetPump,
            code: .packetPumpRuntimeFailed,
            attempt: attempt
          )
          ProviderBoundaryEvidence.finalFailure(attempt: attempt)
          self.handlePacketBridgeFailure(generation)
        }
        guard runtime.installAndStartPump(packetPump, generation: generation) else {
          packetPump.stop()
          throw ProviderError.startCancelled
        }
        ProviderBoundaryEvidence.success(.packetPump, attempt: attempt)
      }

      setActiveBackend(backend)
      backendLock.withLock { activeConfiguration = (plan, prepared) }
      guard lifecycle.markRunning(generation) else { throw ProviderError.startCancelled }
      if !runtime.launchMonitor(generation: generation, operation: {
        [weak self] in
        await self?.runMonitor(generation: generation, attempt: attempt)
      }) {
        throw ProviderError.startCancelled
      }

      ProviderBoundaryEvidence.success(.providerLifecycle, attempt: attempt)
      runtime.startupFinished(generation)
#if os(iOS)
      IOSConnectionAlerts.connected()
#endif
      completionHandler(nil)
#if os(macOS)
      // Listed apps that were running keep their open connections outside the tunnel.
      Task { [xray] in await xray.moveOpenedConnections() }
#endif
    } catch {
      runtime.startupFinished(generation)
      ProviderBoundaryEvidence.finalFailure(attempt: attempt)
      if lifecycle.beginFailureCleanup(generation) {
        let detached = runtime.detach(generation)
        beginCleanup(
          generation: generation,
          detached: detached,
          startupError: error,
          startupCompletion: completionHandler,
          debugRequestID: debugRequestID
        )
      } else {
        // Stop owns cleanup now. Reporting startup failure before it drains can
        // let macOS terminate the provider before prepareStop receives its reply.
        let action = lifecycle.beginStop(expectedGeneration: generation.rawValue) {
          completionHandler(error)
        }
        if action == .rejected { completionHandler(error) }
      }
    }
  }

  private static func switchResponse(_ code: String, digest: Data? = nil) -> Data? {
    var response = ["code": code]
    if let digest { response["digest"] = digest.base64EncodedString() }
    return try? JSONSerialization.data(withJSONObject: response)
  }

  /// runSwitch within 15 s. Cancelled (by the bound or `cancelled`) before it committed, the old
  /// core keeps running; after, the switch ends in a protected failure.
  private func boundedSwitch(plan: TunnelPlan, generation: ProviderLifecycleGeneration, refreshOnly: Bool = false,
                             operationID: UUID? = nil, onDeadline: @escaping () -> Bool = { true },
                             cancelled: () -> Bool = { false }) async -> String {
    let deadline = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(15)) } catch { return }
      guard let self, onDeadline() else { return }
      self.runtime.cancelStartup(generation)
    }
    defer { deadline.cancel() }
    var code = cancelled() ? "cancelled" :
      await runSwitch(plan: plan, generation: generation, refreshOnly: refreshOnly, operationID: operationID)
    let committed = backendLock.withLock {
      defer { if switchCommitted == generation { switchCommitted = nil } }
      return switchCommitted == generation
    }
    if cancelled() || Task.isCancelled {
      lifecycle.finishSwitch(generation, restored: !committed)
      if committed { lifecycle.protectFailure(generation) }
      code = "cancelled"
    }
    return code
  }

  private func runSwitch(plan: TunnelPlan, generation: ProviderLifecycleGeneration, refreshOnly: Bool = false, operationID: UUID? = nil) async -> String {
    guard backendLock.withLock({ bridgeFailure != generation }) else {
      lifecycle.finishSwitch(generation, restored: false)
      return "quarantined"
    }
    let previous = backendLock.withLock { activeConfiguration }
    guard let (oldPlan, oldCore) = previous,
          plan.effectiveBackend == .nativeTun2Proxy,
          oldPlan.effectiveBackend == plan.effectiveBackend,
          oldPlan.runtimeSettings == plan.runtimeSettings,
          oldPlan.socksPort == plan.socksPort, oldPlan.mtu == plan.mtu else {
      lifecycle.finishSwitch(generation, restored: true)
      return "rejected"
    }
    guard let attempt = runtime.currentAttempt else {
      lifecycle.finishSwitch(generation, restored: true)
      return "rejected"
    }
    var coreStopped = false
    var settingsAttempted = false
    do {
      // Resolve/compile while the old path can still carry DNS. Rollback uses
      // the retained configuration and never depends on new DNS or Keychain work.
      var endpoint = try await ProviderLifecycleRuntime.runBlocking {
        try self.secretStore.resolve(secretRef: plan.secretRef, attempt: attempt)
      }
      defer { endpoint.clear() }
      var servers = try await resolvePerAppServers(plan, attempt: attempt)
      defer { for ref in Array(servers.keys) { servers[ref]?.clear() } }
      var credentials: InboundCredentials?
      if plan.runtimeSettings.inboundAuthEnabled == true {
        guard let reference = plan.runtimeSettings.inboundCredentialRef else {
          throw TunnelPlanError.invalidBounds
        }
        var secret = try await ProviderLifecycleRuntime.runBlocking {
          try self.secretStore.resolve(secretRef: reference, attempt: attempt)
        }
        defer { secret.clear() }
        credentials = try InboundCredentials(data: secret.bytes)
      } else {
        // The bridge keeps the login it started with.
        credentials = backendLock.withLock { sessionCredentials }
        guard credentials != nil else { throw TunnelPlanError.invalidBounds }
      }
      defer { credentials?.clear() }
      let candidate = try await xray.prepare(
        plan: plan, endpoint: &endpoint, servers: servers, inboundCredentials: credentials, attempt: attempt
      )
      try requireActive(generation)
      let settingsChanged = plan.dnsServers != oldPlan.dnsServers ||
        candidate.addresses.sorted() != oldCore.addresses.sorted()
      // The core keeps its connections and checks its pooled ones; one that cannot be told restarts.
      if refreshOnly, plan.secretRef == oldPlan.secretRef, !settingsChanged, await xray.socketPathChanged() {
        guard lifecycle.finishSwitch(generation, restored: true) else { return "cancelled" }
        noteCorePath()
        return "unchanged"
      }
      backendLock.withLock { switchCommitted = generation }
      await runtime.pauseMonitor(generation)
      try requireActive(generation)
      reasserting = true
      coreStopped = true
      try await xray.stop()
      try requireActive(generation)
      // Keep installed routes when only the core changes. If settings differ,
      // replace them completely and restore even after a partially failed apply.
      if settingsChanged {
        let settings = try TunnelSettingsFactory.make(plan: plan, excludedEndpointAddresses: candidate.addresses, keepDiscovery: protocolConfiguration.includeAllNetworks)
        settingsAttempted = true
        try await apply(settings)
      }
      try requireActive(generation)
#if DEBUG
      if try debugFaults.consume(.candidate, generation: generation.rawValue, operationID: operationID,
                                now: ProcessInfo.processInfo.systemUptime) {
        throw ProviderDebugFaults.Failure.injected
      }
#endif
      try await xray.start(candidate, attempt: attempt)
      noteCorePath()
      try requireActive(generation)
      backendLock.withLock { activeConfiguration = (plan, candidate) }
      guard lifecycle.finishSwitch(generation, restored: true, started: true) else { return "cancelled" }
      reasserting = false
      _ = runtime.launchMonitor(generation: generation) { [weak self] in
        await self?.runMonitor(generation: generation, attempt: attempt)
      }
#if os(macOS)
      // A new core starts a new connections list.
      Task { [xray] in await xray.moveOpenedConnections() }
#endif
      return "switched"
    } catch {
      guard lifecycle.isActive(generation), !Task.isCancelled else { return "cancelled" }
      if coreStopped {
        var stopConfirmed = false
        do {
          try await xray.stop()
          stopConfirmed = true
          try requireActive(generation)
          if settingsAttempted {
            try await apply(TunnelSettingsFactory.make(plan: oldPlan, excludedEndpointAddresses: oldCore.addresses, keepDiscovery: protocolConfiguration.includeAllNetworks))
          }
          try requireActive(generation)
#if DEBUG
          if try debugFaults.consume(.restoration, generation: generation.rawValue, operationID: operationID,
                                    now: ProcessInfo.processInfo.systemUptime) {
            throw ProviderDebugFaults.Failure.injected
          }
#endif
          try await xray.start(oldCore, attempt: attempt)
          noteCorePath()
          try requireActive(generation)
        } catch {
          guard lifecycle.isActive(generation), !Task.isCancelled else { return "cancelled" }
          // Keep the provider and routes installed until an explicit stop.
          lifecycle.finishSwitch(generation, restored: false, quarantined: !stopConfirmed)
          return stopConfirmed ? "restore_failed" : "quarantined"
        }
      }
      guard lifecycle.finishSwitch(generation, restored: true, started: coreStopped) else { return "cancelled" }
      // A switch from a protected failure that failed before stopping the core leaves that failure.
      reasserting = lifecycle.state != .running(generation)
      if coreStopped {
        _ = runtime.launchMonitor(generation: generation) { [weak self] in
          await self?.runMonitor(generation: generation, attempt: attempt)
        }
      }
      if !coreStopped {
        if error is KeychainError { return "missing_credentials" }
        if case NativeAdapterError.resolutionFailed = error { return "resolution_failed" }
        return "invalid_configuration"
      }
      return "restored"
    }
  }

  private func runMonitor(
    generation: ProviderLifecycleGeneration,
    attempt: ProviderBoundaryAttempt,
    // Each wake costs battery while the tunnel idles; a core exit still shows within 2 s.
    wait: @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(2)) }
  ) async {
    var tracker = ProviderLiveness()
    while !Task.isCancelled {
      try? await wait()
      guard !Task.isCancelled, lifecycle.isActive(generation) else { return }
      let now = ProcessInfo.processInfo.systemUptime
      if tracker.due(at: now), !backendLock.withLock({ sleeping }),
         tracker.needsProbe(uplink: await xray.metrics()["uplinkBytes"] ?? 0, at: now) {
        var passed = false
        for target in ProviderLiveness.targets where !passed {
          passed = await xray.passesTraffic(url: target, timeout: 5)
        }
        guard !Task.isCancelled, lifecycle.isActive(generation) else { return }
        tracker.record(passed: passed, uplink: await xray.metrics()["uplinkBytes"] ?? 0,
                       at: ProcessInfo.processInfo.systemUptime)
        let state = tracker.state, failures = tracker.failures
        let stalled = backendLock.withLock { () -> Bool in
          liveness = (generation.rawValue, state)
          if passed {
            coreStalled = false
            stallRestarts = 0
            return false
          }
          // Two failed checks in a row restart the core as a path change does; after each restart
          // that did not help, twice as many, up to 16 (checks run a minute apart, while traffic leaves).
          guard !coreStalled, failures >= 2 << min(stallRestarts, 3) else { return false }
          coreStalled = true
          stallRestarts += 1
          schedulePathCheck(after: .zero)
          return true
        }
        if stalled { DiagnosticLog.record("core_stalled", ["failures": Int64(failures)]) }
      }
      if DiagnosticLog.isCollecting {
        let counters = currentBackend == .xrayTun ? await xray.metrics() : bridge.counters
        var diagnostic: [String: Int64] = ["generation": Int64(generation.rawValue), "memory_bytes": Int64(Self.memoryFootprint()), "malloc_bytes": Int64(Self.mallocInUse()), "sleeping": backendLock.withLock { sleeping ? 1 : 0 }]
        let allowed = ["packetsIn": "packets_in", "packetsOut": "packets_out", "bytesIn": "bytes_in", "bytesOut": "bytes_out", "malformed": "malformed", "overflows": "overflows", "uplinkBytes": "uplink_bytes", "downlinkBytes": "downlink_bytes", "activeTcpSessions": "tcp_sessions", "activeUdpSessions": "udp_sessions", "droppedTcpSessions": "dropped_tcp_sessions", "droppedUdpSessions": "dropped_udp_sessions"]
        for (key, value) in counters {
          if let name = allowed[key] { diagnostic[name] = Int64(clamping: value) }
        }
        DiagnosticLog.record("runtime_metrics", diagnostic)
      }
#if os(iOS)
      backendLock.withLock {
        let now = ProcessInfo.processInfo.systemUptime
        guard !sleeping, now - alertArmedAt >= IOSConnectionAlerts.refreshSeconds,
              lifecycle.state == .running(generation) else { return }
        IOSConnectionAlerts.arm()
        alertArmedAt = now
      }
#endif
      // A sleeping tunnel is not asked; an exit while asleep shows at the first check after wake.
      if !backendLock.withLock({ sleeping }), !(await xray.isRunning()) {
        guard !Task.isCancelled, lifecycle.isActive(generation) else { return }
        ProviderBoundaryEvidence.failure(
          .libXrayState,
          code: .libXrayNotRunning,
          attempt: attempt
        )
        ProviderBoundaryEvidence.finalFailure(attempt: attempt)
        // Retain routes and packet ownership until recovery or explicit stop.
        if lifecycle.protectFailure(generation) {
          reasserting = true
#if os(iOS)
          IOSConnectionAlerts.failed()
#endif
#if DEBUG
          debugFaults.finish("coreExited", generation: generation.rawValue)
#endif
        }
        return
      }
    }
  }

  private func handlePacketBridgeFailure(_ generation: ProviderLifecycleGeneration) {
    guard lifecycle.isActive(generation) else { return }
    backendLock.withLock {
      if (bridgeFailure?.rawValue ?? 0) <= generation.rawValue { bridgeFailure = generation }
    }
    runtime.cancelStartup(generation)
    if lifecycle.protectFailure(generation) {
      reasserting = true
#if os(iOS)
      IOSConnectionAlerts.failed()
#endif
    }
  }

  private func prepareStop(_ message: Data, completionHandler: ((Data?) -> Void)?) {
    struct Request: Decodable {
      let schemaVersion: Int
      let operation: String
      let instanceID: String
      let generation: UInt64
    }
    guard message.count <= 1024,
          let request = try? JSONDecoder().decode(Request.self, from: message),
          request.schemaVersion == 1, request.operation == "prepareStop",
          request.instanceID == instanceID else {
      completionHandler?(Self.switchResponse("rejected"))
      return
    }
    let action = lifecycle.beginStop(expectedGeneration: request.generation) {
      completionHandler?(try? JSONSerialization.data(withJSONObject: [
        "code": self.lifecycle.state == .idle ? "stopped" : "quarantined",
        "instanceID": self.instanceID, "generation": request.generation,
      ]))
    }
    switch action {
    case .cleanup(let generation):
      // Drain owners while the OS still retains the tunnel's network settings.
      beginCleanup(generation: generation, detached: runtime.detach(generation), startupError: nil)
    case .rejected:
      completionHandler?(Self.switchResponse("rejected"))
    case .joined, .completed:
      break
    }
  }

  private func beginCleanup(
    generation: ProviderLifecycleGeneration,
    detached: ProviderDetachedResources,
    startupError: Error?,
    startupCompletion: ((Error?) -> Void)? = nil,
    debugRequestID: UUID? = nil
  ) {
    let requiresSettingsRollback = startupError != nil
    ProviderLifecycleRuntime.cleanup(
      detached: detached,
      clearSettings: {
        guard requiresSettingsRollback else { return true }
        return await self.clearSettings(attempt: detached.attempt)
      },
      stopBridge: {
        do {
          try await self.bridge.stop(deadline: .seconds(2))
          return true
        } catch {
          if let attempt = detached.attempt {
            ProviderBoundaryEvidence.failure(
              .providerLifecycle,
              code: .providerBridgeStopFailed,
              attempt: attempt
            )
          }
          return false
        }
      },
      stopXray: {
        do {
          try await self.xray.stop()
          return true
        } catch {
          if let attempt = detached.attempt {
            ProviderBoundaryEvidence.failure(
              .providerLifecycle,
              code: .providerXrayStopFailed,
              attempt: attempt
            )
          }
          return false
        }
      },
      completion: { ownersRemain in
        if let attempt = detached.attempt {
          if ownersRemain {
            ProviderBoundaryEvidence.failure(
              .providerLifecycle,
              code: .providerStopDeadlineExceeded,
              attempt: attempt
            )
            ProviderBoundaryEvidence.finalFailure(attempt: attempt)
          } else if startupError == nil {
            ProviderBoundaryEvidence.success(.providerLifecycle, attempt: attempt)
          }
          ProviderBoundaryEvidence.finish(attempt)
        }
#if DEBUG
        if !ownersRemain, startupError == nil, self.lifecycle.state == .stopping(generation),
           let instance = UUID(uuidString: self.instanceID) {
          // All tunnel owners are confirmed stopped. Persist before notifying the
          // OS; further provider execution after that callback is not guaranteed.
          try? self.debugSaveStop(.init(instanceID: instance, generation: generation.rawValue,
            completedAtMs: Int64((Date().timeIntervalSince1970 * 1000).rounded(.up))))
        }
#endif
        self.setActiveBackend(nil)
        self.backendLock.withLock {
          self.activeConfiguration = nil
          self.corePath = nil
          self.pathMoved = false
          self.coreStalled = false
          self.stallRestarts = 0
          self.sessionCredentials?.clear()
          self.sessionCredentials = nil
        }
#if DEBUG
        self.debugFaults.finish(ownersRemain ? "cleanupFailed" : (startupError == nil ? "stopped" : "startupFailed"),
                               generation: generation.rawValue, requestID: debugRequestID)
#endif
        self.lifecycle.finishStop(generation, ownersRemain: ownersRemain)
        startupCompletion?(startupError)
      }
    )
  }

  /// The core just opened its connections on the latest path, or was told about it.
  private func noteCorePath() {
    backendLock.withLock {
      corePath = latestPath?.signature
      pathMoved = false
      coreStalled = false
      pathRetries = 0
    }
  }

  private func requireActive(_ generation: ProviderLifecycleGeneration) throws {
    guard lifecycle.isActive(generation), !Task.isCancelled else {
      throw ProviderError.startCancelled
    }
  }

  /// The configurations of the plan's per-app server targets, from the keychain.
  private func resolvePerAppServers(_ plan: TunnelPlan, attempt: ProviderBoundaryAttempt) async throws -> [String: SecretValue] {
    var servers: [String: SecretValue] = [:]
    do {
      for ref in plan.runtimeSettings.perAppServerRefs {
        servers[ref] = try await ProviderLifecycleRuntime.runBlocking {
          try self.secretStore.resolve(secretRef: ref, attempt: attempt)
        }
      }
    } catch {
      for ref in Array(servers.keys) { servers[ref]?.clear() }
      throw error
    }
    return servers
  }

  private func loadPlan() throws -> TunnelPlan {
    let (plan, digest) = try savedPlan()
    backendLock.withLock { activePlanDigest = digest }
    return plan
  }

  private func savedPlan() throws -> (plan: TunnelPlan, digest: Data) {
    guard
      let protocolConfiguration = protocolConfiguration as? NETunnelProviderProtocol,
      let configuration = protocolConfiguration.providerConfiguration,
      let payload = configuration["planPayload"] as? Data,
      let digest = configuration["planDigest"] as? Data
    else { throw ProviderError.missingPlan }
    return (try TunnelPlanEnvelope(payload: payload, digest: digest).validatedPlan(), digest)
  }

  private func apply(_ settings: NEPacketTunnelNetworkSettings?) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      setTunnelNetworkSettings(settings) { error in
        self.backendLock.withLock { self.utunDiagnostic = nil }
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(returning: ())
        }
      }
    }
  }

  private func clearSettings(attempt: ProviderBoundaryAttempt? = nil) async -> Bool {
    do {
      try await apply(nil)
      return true
    } catch {
      if let attempt {
        let value = error as NSError
        let code: ProviderBoundaryCode
        if value.domain != NETunnelProviderErrorDomain {
          code = .providerClearSettingsOther
        } else {
          switch value.code {
          case NETunnelProviderError.networkSettingsInvalid.rawValue:
            code = .providerClearSettingsInvalid
          case NETunnelProviderError.networkSettingsCanceled.rawValue:
            code = .providerClearSettingsCanceled
          case NETunnelProviderError.networkSettingsFailed.rawValue:
            code = .providerClearSettingsRequestFailed
          default:
            code = .providerClearSettingsOther
          }
        }
        ProviderBoundaryEvidence.failure(
          .providerLifecycle,
          code: code,
          attempt: attempt
        )
      }
      return false
    }
  }

  private var currentBackend: TunnelBackend? {
    backendLock.lock()
    defer { backendLock.unlock() }
    return activeBackend
  }

  private func setActiveBackend(_ backend: TunnelBackend?) {
    backendLock.lock()
    utunDiagnostic = nil
    activeBackend = backend
    backendLock.unlock()
  }
}

private struct ProviderSwitchRequest: Decodable {
  let operationID: UUID?
  let schemaVersion: Int
  let operation: String
  let envelope: TunnelPlanEnvelope
#if DEBUG
  let debugFault: ProviderDebugFaults.Request?
#endif
}

enum ProviderError: Error {
  case invalidState
  case missingPlan
  case startCancelled
}
