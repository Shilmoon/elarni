import CryptoKit
import Foundation
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
#if DEBUG
  private let debugFaults = ProviderDebugFaults(save: ProviderDebugFaults.save)
  private var debugSaveStop: (ProviderDebugFaults.StopReceipt) throws -> Void = ProviderDebugFaults.saveStop
#endif

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
        completionHandler?(Self.switchResponse(lifecycle.state.label == "quarantinedFailClosed" ? "quarantined" : "rejected"))
        return
      }
      let launched = runtime.launchStartup(generation: generation) { [weak self] in
        guard let self else {
          completionHandler?(Self.switchResponse("rejected"))
          return
        }
        let deadline = Task { [weak self] in
          do { try await Task.sleep(for: .seconds(15)) }
          catch { return }
          guard let self, self.switchCancellation.cancel(id) else { return }
          self.runtime.cancelStartup(generation)
        }
        defer { deadline.cancel() }
        let refreshOnly = request.operation == "refreshPath" &&
          self.backendLock.withLock { self.activePlanDigest == request.envelope.digest }
        var code = self.switchCancellation.isCancelled(id) ? "cancelled" :
          await self.runSwitch(plan: plan, generation: generation, refreshOnly: refreshOnly, operationID: id)
        if self.switchCancellation.isCancelled(id) || Task.isCancelled {
          self.lifecycle.finishSwitch(generation, restored: false)
          self.lifecycle.protectFailure(generation)
          code = "cancelled"
        }
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

  private static func memoryFootprint() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<natural_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
      }
    }
    return status == KERN_SUCCESS ? UInt64(info.resident_size) : 0
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
          excludedEndpointAddresses: prepared.addresses
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
      if refreshOnly, plan.secretRef == oldPlan.secretRef, !settingsChanged {
        guard lifecycle.finishSwitch(generation, restored: true) else { return "cancelled" }
        return "unchanged"
      }
      await runtime.pauseMonitor(generation)
      try requireActive(generation)
      reasserting = true
      coreStopped = true
      try await xray.stop()
      try requireActive(generation)
      // Keep installed routes when only the core changes. If settings differ,
      // replace them completely and restore even after a partially failed apply.
      if settingsChanged {
        let settings = try TunnelSettingsFactory.make(plan: plan, excludedEndpointAddresses: candidate.addresses)
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
      try requireActive(generation)
      backendLock.withLock { activeConfiguration = (plan, candidate) }
      guard lifecycle.finishSwitch(generation, restored: true, started: true) else { return "cancelled" }
      reasserting = false
      _ = runtime.launchMonitor(generation: generation) { [weak self] in
        await self?.runMonitor(generation: generation, attempt: attempt)
      }
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
            try await apply(TunnelSettingsFactory.make(plan: oldPlan, excludedEndpointAddresses: oldCore.addresses))
          }
          try requireActive(generation)
#if DEBUG
          if try debugFaults.consume(.restoration, generation: generation.rawValue, operationID: operationID,
                                    now: ProcessInfo.processInfo.systemUptime) {
            throw ProviderDebugFaults.Failure.injected
          }
#endif
          try await xray.start(oldCore, attempt: attempt)
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
        let state = tracker.state
        backendLock.withLock { liveness = (generation.rawValue, state) }
      }
      if DiagnosticLog.isCollecting {
        let counters = currentBackend == .xrayTun ? await xray.metrics() : bridge.counters
        var diagnostic: [String: Int64] = ["generation": Int64(generation.rawValue), "memory_bytes": Int64(Self.memoryFootprint()), "sleeping": backendLock.withLock { sleeping ? 1 : 0 }]
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
      if !(await xray.isRunning()) {
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
