import CryptoKit
import AppKit
import Darwin
import FlutterMacOS
import Foundation
import Network
import NetworkExtension
import ServiceManagement

// Automatic recovery, health checks and server selection.
extension TunnelMethodChannel {
  static let automationKey = "ElarniAutomationV1"
  private static let episodeKey = "ElarniRecoveryEpisodeV1"
  static let automationMutationMethods: Set<String> = [
    "selectNode", "refreshSubscription", "deleteSubscription", "deleteNode", "importClientProfiles", "selectProfileGroup", "setNodeIPPreference",
    "updateTunnelSettings", "updateInboundCredentials", "updateRoutingProfile",
    "assignRoutingProfile", "setRoutingProfileEnabled", "resetRoutingProfile", "deleteRoutingProfile",
    "refreshRoutingGeofiles", "importRouting", "configureAutomation",
  ]

  @MainActor
  func automationSnapshot() -> [String: Any] {
    var policySupported = true
    if let id = try? subscriptionStore().selectedNodeID(),
       let subscriptionID = try? subscriptionStore().subscriptionID(nodeID: id) {
      policySupported = (try? requireProbePolicy(subscriptionID: subscriptionID)) != nil
    }
    return ["schemaVersion": 1, "enabled": automationConfiguration.enabled,
     "policy": automationConfiguration.policy.rawValue, "status": automationStatus,
     "policySupported": policySupported,
     "healthNodeID": verifiedHealth?.epoch == automation.epoch ? verifiedHealth!.node as Any : NSNull(),
     "healthAgeSeconds": verifiedHealth?.epoch == automation.epoch ? max(0, automationNow() - verifiedHealth!.at) as Any : NSNull(),
     "configuration": ["schemaVersion": 1, "enabled": automationConfiguration.enabled,
       "policy": automationConfiguration.policy.rawValue,
       "subscriptionID": automationConfiguration.subscriptionID, "nodeIDs": automationConfiguration.nodeIDs,
       "russianEntryNodeIDs": automationConfiguration.russianEntryNodeIDs ?? [],
       "targets": automationConfiguration.targets.map {
         ["id": $0.id, "url": $0.url, "expectedStatus": $0.expectedStatus, "expectedBody": $0.expectedBody] as [String: Any]
       }],
     "attempts": automation.episode.attempts, "exhausted": automation.episode.exhausted,
     "pendingRetry": automation.retryAt != nil, "pathAvailable": automation.online,
     "sleeping": automation.sleeping, "targetIDs": automationConfiguration.targets.map(\.id),
     "physicalPaths": physicalPaths.sorted { $0.key < $1.key }.map {
       ["monitor": $0.key, "available": $0.value.available, "status": $0.value.status,
        "unsatisfiedReason": $0.value.unsatisfiedReason] as [String: Any]
     },
     "candidateFailures": automationCandidateFailures, "whitelistMode": automation.whitelist,
     "diagnostics": healthDiagnostics.suffix(2).map(\.channelMap)]
  }

  @MainActor
  func saveEpisode() {
    if !automationUnreadable, let data = try? JSONEncoder().encode(automation.episode) {
      automationDefaults.set(data, forKey: Self.episodeKey)
    }
  }

  @MainActor
  func configureAutomation(_ arguments: [String: Any]) async throws -> [String: Any] {
    try Task.checkCancellation()
    guard !automationUnreadable else { throw AutomationFailure.invalidConfiguration }
    let data = try JSONSerialization.data(withJSONObject: arguments)
    let configuration = try JSONDecoder().decode(AutomationConfiguration.self, from: data)
    try configuration.validate()
    if configuration.enabled {
      let store = try subscriptionStore()
      // Allowed servers may come from any subscription; each one's routing must permit checks.
      // shortcut: an automatic switch does not prepare a backup's routing geofiles; the probe
      // policy admits no routing rules, which are what need them.
      let subscriptions = Set(try configuration.nodeIDs.map(store.subscriptionID(nodeID:)))
      guard let current = store.selectedNodeID(), configuration.nodeIDs.contains(current) else {
        throw AutomationFailure.invalidConfiguration
      }
      if configuration.policy != .fixed {
        for subscription in subscriptions { try requireProbePolicy(subscriptionID: subscription) }
      }
    }
    if configuration != automationConfiguration {
      invalidateAutomation(configuration: true)
      automationConfiguration = configuration
      automationPaused = false
      automationDefaults.set(try JSONEncoder().encode(configuration), forKey: Self.automationKey)
      automation.rearm(now: self.automationNow())
      saveEpisode()
    }
    automationStatus = configuration.enabled ? "waitingForPath" : "disabled"
    do {
      let selected = try await loadManager()
      try await setOnDemand(selected,
        enabled: commands.intent == .connected && settingsStore.current.onDemandEnabled && !configuration.enabled,
        retainingProtection: commands.intent == .connected && settingsStore.current.includeAllNetworks,
        untrustedWiFi: untrustedWiFiArmed)
      automationPaused = false
    } catch RunnerTunnelError.notPrepared {
      // Recovery may be configured before the first connection. With no saved
      // VPN profile there is no OS On Demand rule to suspend.
      automationPaused = false
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      automationPaused = true
      automationStatus = "onDemandSuspensionFailed"
      throw RunnerTunnelError.onDemandSuspensionFailed
    }
    return automationSnapshot()
  }

  @MainActor
  func invalidateAutomation(configuration: Bool = false) {
    automationTimer?.cancel()
    automationTimer = nil
    automationWork?.cancel()
    commands.invalidateAutomatic()
    automation.invalidate(configuration: configuration)
    healthDiagnostics = []
    automationFailover = false
    if configuration { automationCandidateFailures.removeAll() }
  }

  @MainActor
  func automationCommandReceived(_ method: String) {
    if ["disconnect", "restoreCatalogBackup", "repairTunnel"].contains(method) {
      invalidateAutomation()
      automation.stop()
      automationStatus = "stopped"
      saveEpisode()
    } else if method == "connect" {
      invalidateAutomation()
      automation.rearm(now: self.automationNow())
      automationPaused = false
      saveEpisode()
    } else if Self.automationMutationMethods.contains(method) {
      invalidateAutomation()
    }
  }

  @MainActor
  func automationRevision() -> Data? {
    guard automationConfiguration.enabled, let store = try? subscriptionStore() else { return nil }
    var references: [String: String] = [:]
    for id in automationConfiguration.nodeIDs { references[id] = (try? store.outboundRef(nodeID: id)) ?? "" }
    let plan = store.selectedNodeID().flatMap { try? automationContext(nodeID: $0).plan }
    return try? JSONSerialization.data(withJSONObject: [
      "references": references, "selected": store.selectedNodeID() ?? "", "plan": plan?.base64EncodedString() ?? "",
    ], options: [.sortedKeys])
  }

  @MainActor
  func startAutomationObservation() {
    if let object = automationDefaults.object(forKey: Self.automationKey) {
      if let data = object as? Data,
         let saved = try? JSONDecoder().decode(AutomationConfiguration.self, from: data),
         (try? saved.validate()) != nil {
        automationConfiguration = saved
      } else { automationUnreadable = true }
    }
    if let object = automationDefaults.object(forKey: Self.episodeKey) {
      if let data = object as? Data,
         let saved = try? JSONDecoder().decode(AutomationPolicy.Episode.self, from: data),
         saved.schemaVersion == 1, (0...6).contains(saved.attempts) {
        automation = AutomationPolicy(savedEpisode: saved)
      } else { automationUnreadable = true }
    }
    automationStatus = automationUnreadable ? "unreadableConfiguration" :
      (automationConfiguration.enabled ? "waitingForPath" : "disabled")
    for (index, monitor) in pathMonitors.enumerated() {
      monitor.pathUpdateHandler = { [weak self] path in
      // Interface identity, capability and gateways distinguish meaningful handoffs.
      let signature = "\(path.status):\(path.supportsIPv4):\(path.supportsIPv6):" +
        path.availableInterfaces.map { "\($0.index):\($0.type)" }.sorted().joined(separator: ",") +
        path.gateways.map { String(describing: $0) }.sorted().joined(separator: ",")
      let available: Bool
      if path.status == .satisfied {
        available = true
      } else if #available(macOS 14.0, *), path.unsatisfiedReason == .vpnInactive {
        available = true
      } else {
        available = false
      }
      DiagnosticLog.record("network_path", ["monitor": Int64(index), "available": available ? 1 : 0, "ipv4": path.supportsIPv4 ? 1 : 0, "ipv6": path.supportsIPv6 ? 1 : 0, "expensive": path.isExpensive ? 1 : 0, "constrained": path.isConstrained ? 1 : 0])
      Task { @MainActor in
        guard let self else { return }
        self.physicalPaths[index] = (signature, available,
          String(describing: path.status),
          path.status == .unsatisfied ? String(describing: path.unsatisfiedReason) : "")
        guard self.physicalPaths.count == self.pathMonitors.count else { return }
        let paths = self.physicalPaths.sorted { $0.key < $1.key }
        let available = paths.filter { $0.value.available }
        let combined = available.map { "\($0.key):\($0.value.signature)" }.joined(separator: "|")
        guard self.automation.pathChanged(combined, available: !available.isEmpty,
                                          now: self.automationNow()) else { return }
        self.suspendMaintenance()
        self.scheduleMaintenance()
        self.automationTimer?.cancel()
        self.automationWork?.cancel()
        self.commands.invalidateAutomatic()
        self.automationRefreshPath = true
        self.automationFailover = false
        self.saveEpisode()
        self.scheduleAutomation()
      }
      }
      monitor.start(queue: DispatchQueue(label: "com.elarni.automation.path.\(index)"))
    }
    for (name, sleeping) in [(NSWorkspace.willSleepNotification, true), (NSWorkspace.didWakeNotification, false)] {
      automationObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
        forName: name, object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor in
          guard let self, self.automation.sleepChanged(sleeping, now: self.automationNow()) else { return }
          self.suspendMaintenance()
          self.scheduleMaintenance()
          self.automationTimer?.cancel()
          self.automationWork?.cancel()
          self.commands.invalidateAutomatic()
          if !sleeping { self.automationRefreshPath = true }
          self.automationFailover = false
          self.saveEpisode()
          self.scheduleAutomation()
        }
      })
    }
    automationObservers.append(NotificationCenter.default.addObserver(
      forName: .NEVPNStatusDidChange, object: nil, queue: .main
    ) { [weak self] notification in
      Task { @MainActor in
        guard let self, let connection = notification.object as? NEVPNConnection,
              connection === self.manager?.connection else { return }
        guard self.observedProviderStatus != connection.status else { return }
        self.observedProviderStatus = connection.status
        if [.disconnected, .invalid].contains(connection.status) {
          self.invalidateAutomation()
        }
        if self.automationWork == nil { self.scheduleAutomation(immediate: true) }
      }
    })
    scheduleAutomation()
  }

  @MainActor
  private func canRestartProviderWithoutPath() -> Bool {
    // A protected app path can remain unavailable until its provider restarts.
    commands.intent == .connected && settingsStore.current.includeAllNetworks &&
      manager?.connection.status == .disconnected
  }

  /// Whether a check may be scheduled; when not, the status says why.
  @MainActor
  private func automationMayRun() -> Bool {
    guard let store = try? subscriptionStore(), !store.runtimeReconciliationRequired else { return false }
    if automationUnreadable { automationStatus = "unreadableConfiguration"; return false }
    if !automationConfiguration.enabled { automationStatus = "disabled"; return false }
    guard commands.intent == .connected else {
      automationStatus = commands.intent == .disconnected ? "stopped" : "intentRequired"
      return false
    }
    if automation.sleeping { automationStatus = "sleeping"; return false }
    if !automation.online && !canRestartProviderWithoutPath() { automationStatus = "offline"; return false }
    if automation.episode.exhausted { automationStatus = "exhausted"; return false }
    return !automationPaused && automationWork == nil
  }

  @MainActor
  func scheduleAutomation(immediate: Bool = false) {
    guard observesSystem else { return }
    guard automationMayRun() else {
      automationTimer?.cancel()
      automationTimer = nil
      return
    }
    let now = self.automationNow()
    let due = automation.retryAt ?? (immediate ? now : automation.healthAt ?? now)
    let epoch = automation.epoch
    if let timer = automationTimer, !timer.isCancelled, let pending = automationTimerDue,
       pending.at == due, pending.epoch == epoch { return }
    automationTimer?.cancel()
    automationTimerDue = (due, epoch)
    automationTimer = Task { @MainActor [weak self] in
      do { try await self?.automationSleep(max(0, due - (self?.automationNow() ?? due))) }
      catch { return }
      guard let self, self.automation.epoch == epoch else { return }
      self.automationTimer = nil
      self.automationWork = Task { @MainActor [weak self] in
        guard let self else { return }
        defer {
          self.automationWork = nil
          self.saveEpisode()
          self.scheduleAutomation()
        }
        do {
          try await self.commands.perform(automatic: true) {
            guard self.automation.epoch == epoch, self.commands.intent == .connected,
                  self.automation.online || self.canRestartProviderWithoutPath(),
                  !self.automation.sleeping else { throw CancellationError() }
            try await self.runAutomationCycle()
          }
        } catch is CancellationError {
          // Stop/path changes own the next schedule; cancelled work cannot re-arm it.
        } catch {
          self.automationStatus = (error as? AutomationFailure)?.rawValue ?? "correctionRequired"
          if let failure = error as? AutomationFailure,
             [.endpointFailure, .providerFailure, .exhaustedCandidates, .restorationFailed,
              .replacementRestored, .deadline, .unavailableProbePath].contains(failure) {
            _ = self.automation.scheduleRetry(now: self.automationNow(), jitter: self.automationJitter(),
              allowOffline: self.canRestartProviderWithoutPath())
          } else {
            if let failure = error as? AutomationFailure {
              if [.invalidConfiguration, .missingCredentials, .unsupportedPolicy, .quarantine].contains(failure) {
                self.automationPaused = true
              }
            } else { self.automationPaused = true }
            self.automation.scheduleHealth(now: self.automationNow(), jitter: self.automationJitter())
          }
        }
      }
    }
  }

  @MainActor
  func automationContext(nodeID: String) throws -> AutomationContext {
    let store = try subscriptionStore()
    guard automationConfiguration.nodeIDs.contains(nodeID) else {
      throw AutomationFailure.invalidConfiguration
    }
    let reference = try store.outboundRef(nodeID: nodeID)
    let revision = try store.routing.runtimeRevision(subscriptionID: store.subscriptionID(nodeID: nodeID))
    return AutomationContext(epoch: automation.epoch, intentRevision: commands.revision,
      nodeID: nodeID, reference: reference,
      plan: try makePlan(secretRef: reference, routingRevision: revision))
  }

  @MainActor
  private func requireAutomationContext(_ context: AutomationContext, allowOffline: Bool = false) throws {
    try Task.checkCancellation()
    guard commands.intent == .connected,
          automation.online || (allowOffline && settingsStore.current.includeAllNetworks), !automation.sleeping,
          try automationContext(nodeID: context.nodeID) == context else {
      throw AutomationFailure.staleContext
    }
    if let deadline = automation.remainingEpisodeTime, self.automationNow() >= deadline {
      throw AutomationFailure.deadline
    }
  }

  @MainActor
  func requireProbePolicy(subscriptionID: String) throws {
    // D06: nested probes use covered app traffic. No endpoint exclusions or
    // route overrides are added to make a candidate reachable.
    let settings = settingsStore.current
    guard settings.includeAllNetworks, !settings.xrayTunEnabled,
          settings.excludedRoutes.isEmpty,
          Set(settings.includedRoutes) == Set(["0.0.0.0/0", "::/0"]) else {
      throw AutomationFailure.unsupportedPolicy
    }
    guard try subscriptionStore().routing.runtimeProbeProxiesAll(subscriptionID: subscriptionID) != false else {
      throw AutomationFailure.unsupportedPolicy
    }
  }

  nonisolated private static func automaticNativeProbe(_ payload: [String: Any]) async throws -> (delay: Double, diagnostics: [String: Any]) {
    let id = UUID().uuidString.lowercased()
    _ = try invokeLibXray(method: "prepareProbe", payload: ["operationId": id, "timeout": 5])
    defer { _ = try? invokeLibXray(method: "releaseProbe", payload: ["operationId": id]) }
    var request = payload
    request["operationId"] = id
    request["timeout"] = 5
    let arguments = request
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      let response: [String: Any]
      do {
        response = try await Task.detached { try invokeLibXray(method: "ping", payload: arguments) }.value
      } catch let failure as RunnerProbeFailure {
        if ["pending", "failed"].contains(failure.details["cleanupState"] as? String ?? "") {
          throw AutomationFailure.quarantine
        }
        throw failure
      }
      try Task.checkCancellation()
      guard let delay = response["delay"] as? NSNumber, delay.doubleValue >= 0,
            delay.doubleValue < 5000 else { throw AutomationFailure.endpointFailure }
      return (delay.doubleValue, sanitizedProbeDiagnostics(response["diagnostics"]) ?? [:])
    } onCancel: {
      _ = try? invokeLibXray(method: "cancelProbe", payload: ["operationId": id])
    }
  }

  @MainActor
  func activeHealth(_ context: AutomationContext) async throws -> Double {
    healthDiagnostics = []
    let entered = automationNow()
    var readiness = ProbeDiagnostic(targetOrdinal: 1, revision: context.intentRevision,
      deadline: min(entered + 5, automation.remainingEpisodeTime ?? (entered + 5)), started: entered)
    readiness.outcomes[.localPath] = physicalPaths.isEmpty ? .unknown :
      (physicalPaths.values.contains(where: { $0.available }) ? .passed : .unreachable)
    defer {
      if healthDiagnostics.isEmpty {
        readiness.duration = max(0, automationNow() - entered)
        if Task.isCancelled { readiness.outcomes[.providerBridge] = .cancelled }
        healthDiagnostics = [readiness]
      }
    }
    try requireProbePolicy(subscriptionID: subscriptionStore().subscriptionID(nodeID: context.nodeID))
    try requireAutomationContext(context)
    readiness.outcomes[.providerBridge] = .unknown
    let before = try await runtimeMetrics()
    try requireAutomationContext(context)
    try requireProbePolicy(subscriptionID: subscriptionStore().subscriptionID(nodeID: context.nodeID))
    readiness.generation = before["generation"] as? UInt64
    readiness.outcomes[.providerBridge] = .failed
    guard before["state"] as? String != "quarantinedFailClosed",
          before["resourceRecoveryRequired"] as? Bool != true else { throw AutomationFailure.quarantine }
    guard before["state"] as? String == "connected",
          before["configurationDigest"] as? String == Data(SHA256.hash(data: context.plan)).base64EncodedString(),
          let generation = before["generation"] as? UInt64,
          let instance = before["instanceID"] as? String, !instance.isEmpty else { throw AutomationFailure.providerFailure }
    var qualifyingFailures = 0
    var invalidTarget = false
    for (ordinal, target) in automationConfiguration.targets.prefix(2).enumerated() {
      let started = automationNow()
      var diagnostic = ProbeDiagnostic(targetOrdinal: ordinal + 1, revision: context.intentRevision,
        deadline: min(started + 5, automation.remainingEpisodeTime ?? (started + 5)), started: started,
        generation: generation)
      diagnostic.outcomes[.localPath] = physicalPaths.isEmpty ? .unknown :
        (physicalPaths.values.contains(where: { $0.available }) ? .passed : .unreachable)
      diagnostic.outcomes[.providerBridge] = .passed
      defer {
        diagnostic.duration = max(0, automationNow() - started)
        healthDiagnostics.append(diagnostic)
      }
      do {
        try requireAutomationContext(context)
        try requireProbePolicy(subscriptionID: subscriptionStore().subscriptionID(nodeID: context.nodeID))
        let response: Result<(delay: Double, diagnostics: [String: Any]), Error>
        do {
          response = .success(try await Self.automaticNativeProbe([
            "packetPath": true, "url": target.url, "method": "GET", "mode": "default",
            "expectedStatus": target.expectedStatus, "expectedBody": target.expectedBody,
          ]))
        } catch { response = .failure(error) }
        try requireAutomationContext(context)
        diagnostic.outcomes[.providerBridge] = .unknown
        let after = try await runtimeMetrics()
        try requireAutomationContext(context)
        try requireProbePolicy(subscriptionID: subscriptionStore().subscriptionID(nodeID: context.nodeID))
        guard after["instanceID"] as? String == instance,
              after["generation"] as? UInt64 == generation,
              after["state"] as? String == "connected",
              after["resourceRecoveryRequired"] as? Bool != true,
              after["configurationDigest"] as? String == before["configurationDigest"] as? String else {
          throw AutomationFailure.staleContext
        }
        diagnostic.outcomes[.providerBridge] = .passed
        let result = try response.get()
        diagnostic.recordNative(result.diagnostics, outcome: .passed)
        verifiedHealth = (context.nodeID, automationNow(), automation.epoch)
        automation.observe(node: context.nodeID, passed: true, russianEntry: russianEntry(context.nodeID))
        return result.delay
      } catch is CancellationError {
        diagnostic.recordNative([:], outcome: .cancelled)
        throw CancellationError()
      }
      catch let failure as AutomationFailure where [.staleContext, .deadline, .quarantine, .unsupportedPolicy].contains(failure) { throw failure }
      catch let failure as RunnerProbeFailure {
        diagnostic.recordNative(failure.details, outcome: ProbeDiagnostic.outcome(code: failure.details["code"] as? String))
        if ["pending", "failed"].contains(failure.details["cleanupState"] as? String ?? "") {
          throw AutomationFailure.quarantine
        }
        if ["target_dns_failed"].contains(failure.details["code"] as? String ?? "") ||
            (failure.details["httpStatus"] as? Int ?? 0) != 0 {
          invalidTarget = true
        }
        // EOF/generic handshake errors may be authentication failures. Only
        // classified timeouts at every target (both, when there are two) qualify for cycling.
        if failure.details["code"] as? String == "timeout" { qualifyingFailures += 1 }
      } catch { /* Unclassified failures remain indeterminate. */ }
    }
    if invalidTarget { throw AutomationFailure.invalidTarget }
    guard qualifyingFailures >= automationConfiguration.endpointFailureTimeouts else { throw AutomationFailure.indeterminate }
    automation.observe(node: context.nodeID, passed: false, russianEntry: russianEntry(context.nodeID))
    throw AutomationFailure.endpointFailure
  }

  @MainActor
  private func russianEntry(_ nodeID: String) -> Bool {
    automationConfiguration.russianEntryNodeIDs?.contains(nodeID) == true
  }

  @MainActor
  private func recoveryOrder(current: String) throws -> [String] {
    let store = try subscriptionStore()
    let order = automationConfiguration.nodeIDs
    return automation.recoveryOrder(order, current: current,
      tcp443: Set(order.filter { (try? store.outbound(nodeID: $0)).map(AutomationPolicy.tcp443) == true }),
      russianEntry: Set(automationConfiguration.russianEntryNodeIDs ?? []))
  }

  @MainActor
  private func runAutomationCycle() async throws {
    let store = try subscriptionStore()
    guard let current = store.selectedNodeID() else { throw AutomationFailure.exhaustedCandidates }
    let probeSupported = (try? requireProbePolicy(subscriptionID: store.subscriptionID(nodeID: current))) != nil
    if !probeSupported && automationConfiguration.policy != .fixed { throw AutomationFailure.unsupportedPolicy }
    let context = try automationContext(nodeID: current)
    let selected = try await loadManager()
    let restartingOffline = !automation.online && canRestartProviderWithoutPath()
    let retry = automation.beginRetry(now: self.automationNow(), allowOffline: restartingOffline)
    if retry { saveEpisode() }
    let epoch = automation.epoch
    let deadlineTask = automation.remainingEpisodeTime.map { deadline in
      Task { @MainActor [weak self] in
        guard let self else { return }
        do { try await self.automationSleep(max(0, deadline - self.automationNow())) }
        catch { return }
        guard self.automation.epoch == epoch else { return }
        self.automation.expireEpisode()
        self.automationStatus = "exhausted"
        self.commands.invalidateAutomatic()
      }
    }
    defer { deadlineTask?.cancel() }
    try await setOnDemand(selected, enabled: false,
      retainingProtection: commands.intent == .connected && settingsStore.current.includeAllNetworks)
    guard ![.connecting, .disconnecting].contains(selected.connection.status) else {
      automation.scheduleHealth(now: self.automationNow(), jitter: 0)
      return
    }
    if selected.connection.status == .disconnected {
      guard retry else { throw AutomationFailure.providerFailure }
      try requireAutomationContext(context, allowOffline: restartingOffline)
      do {
        try await prepareSelectedConnection()
        try requireAutomationContext(context, allowOffline: restartingOffline)
        try await connect()
        try await waitForConnected()
        try requireAutomationContext(context, allowOffline: restartingOffline)
      } catch RunnerTunnelError.invalidState {
        guard automation.online, probeSupported, automationConfiguration.policy != .fixed else {
          throw AutomationFailure.providerFailure
        }
        try await selectAutomatically(current: context, healthy: false)
        return
      }
    }
    if !automation.online {
      // Connection status is not verified health and cannot replenish the budget.
      automationStatus = "waitingForPath"
      return
    }
    if !probeSupported {
      // Custom routing can still reconnect the same disconnected provider.
      // Liveness must never be presented as verified internet access.
      let metrics = try await runtimeMetrics()
      try requireAutomationContext(context)
      guard metrics["state"] as? String == "connected",
            metrics["resourceRecoveryRequired"] as? Bool != true else {
        automationPaused = true
        throw AutomationFailure.unsupportedPolicy
      }
      automation.healthy(now: automationNow(), jitter: automationJitter())
      automationStatus = "connectedUnchecked"
      return
    }
    var healthy = false
    do {
      _ = try await activeHealth(context)
      if automationRefreshPath {
        try await switchProvider(plan: context.plan, selected: selected, refreshOnly: true)
        _ = try await activeHealth(context)
        try requireAutomationContext(context)
        automationRefreshPath = false
      }
      healthy = true
      automation.healthy(now: self.automationNow(), jitter: self.automationJitter())
      automationFailover = false
      automationStatus = "healthy"
    } catch let failure as AutomationFailure {
      if failure == .indeterminate || failure == .invalidTarget || failure == .quarantine ||
          failure == .unsupportedPolicy || failure == .staleContext {
        _ = automation.failedHealth(failure)
        throw failure
      }
      let failover = automation.failedHealth(failure)
      if failover { automationFailover = true }
      if retry {
        if automationFailover && automationConfiguration.policy != .fixed {
          do {
            try await selectAutomatically(current: context, healthy: false)
            automationFailover = false
            return
          } catch let unavailable as AutomationFailure where
              unavailable == .unavailableProbePath || unavailable == .exhaustedCandidates {
            // Retry the current node when no allowed alternate is available.
          }
        }
        try await replaceAutomatically(context, previousHealthy: false)
        automation.healthy(now: self.automationNow(), jitter: self.automationJitter())
        automationFailover = false
        automationStatus = "recovered"
        return
      }
      if failure == .providerFailure { throw failure }
      if !failover {
        automationStatus = "healthFailure"
        automation.scheduleHealth(now: self.automationNow(), jitter: self.automationJitter())
        return
      }
    }
    if automationConfiguration.policy == .fixed {
      if !healthy { throw AutomationFailure.endpointFailure }
      return
    }
    if healthy && !automation.beginOptimization(now: self.automationNow()) { return }
    if !healthy { automation.reject(node: current, transient: true, now: self.automationNow()) }
    try await selectAutomatically(current: context, healthy: healthy)
  }

  @MainActor
  private func selectAutomatically(current: AutomationContext, healthy: Bool) async throws {
    if !healthy {
      // Try the explicitly permitted candidate through the managed provider.
      // No physical-path probe or route exclusion is introduced during outage.
      let candidates = automation.recoveryCandidates(policy: automationConfiguration.policy,
        order: try recoveryOrder(current: current.nodeID), current: current.nodeID, now: automationNow())
      let deadline = min(automationNow() + 60, automation.remainingEpisodeTime ?? .infinity)
      let epoch = automation.epoch
      let expiry = Task { @MainActor [weak self] in
        guard let self else { return }
        do { try await automationSleep(max(0, deadline - automationNow())) }
        catch { return }
        guard automation.epoch == epoch else { return }
        automationStatus = "selectionDeadline"
        _ = automation.scheduleRetry(now: automationNow(), jitter: automationJitter())
        saveEpisode()
        commands.invalidateAutomatic()
      }
      defer { expiry.cancel() }
      for node in candidates {
        try requireAutomationContext(current)
        guard automationNow() + 10 <= deadline else { throw AutomationFailure.deadline }
        do {
          try await replaceAutomatically(automationContext(nodeID: node), previousHealthy: false)
          automation.switched(now: automationNow())
          verifiedHealth = (node, automationNow(), automation.epoch)
          automation.healthy(now: automationNow(), jitter: automationJitter())
          automationStatus = "selected"
          channel.invokeMethod("subscriptionsChanged", arguments: nil)
          return
        } catch AutomationFailure.replacementRestored {
          automationCandidateFailures[node] = "checkFailed"
          // Restoration of the old plan was confirmed; another allowed backup
          // may now be tried within the same bounded recovery round.
        } catch let failure as AutomationFailure where failure == .missingCredentials || failure == .invalidConfiguration {
          automation.reject(node: node, transient: false, now: automationNow())
          automationCandidateFailures[node] = failure.rawValue
        }
      }
      throw AutomationFailure.exhaustedCandidates
    }
    let store = try subscriptionStore()
    let nodes = automation.round(nodes: automationConfiguration.nodeIDs, current: current.nodeID, now: self.automationNow())
    guard !nodes.isEmpty else { throw AutomationFailure.exhaustedCandidates }
    let deadline = self.automationNow() + 60
    let roundEpoch = automation.epoch
    let roundDeadline = Task { @MainActor [weak self] in
      guard let self else { return }
      do { try await self.automationSleep(max(0, deadline - self.automationNow())) }
      catch { return }
      guard self.automation.epoch == roundEpoch else { return }
      self.automationStatus = "selectionDeadline"
      _ = self.automation.scheduleRetry(now: self.automationNow(), jitter: self.automationJitter())
      self.saveEpisode()
      self.commands.invalidateAutomatic()
    }
    defer { roundDeadline.cancel() }
    var scores: [String: Double] = [:]
    for node in nodes {
      try requireAutomationContext(current)
      guard self.automationNow() + 5 <= deadline else { break }
      let candidate: AutomationContext
      do { candidate = try automationContext(nodeID: node) }
      catch { automation.reject(node: node, transient: false, now: self.automationNow()); continue }
      if let score = automation.score(node: node, reference: candidate.reference, now: self.automationNow()) {
        scores[node] = score
        continue
      }
      // This branch optimizes a verified healthy path. Outage recovery above
      // verifies permitted candidates through managed provider replacement.
      let config: String
      do {
        let snapshot = try store.routing.runtimeProbeConfiguration(subscriptionID: store.subscriptionID(nodeID: node))
        let outbound = try store.outbound(nodeID: node)
        let settings = settingsStore.current.applyingIPPreference(try store.ipPreference(nodeID: node))
        var runtime = settings.compilerRuntime
        runtime["httpInboundEnabled"] = false
        runtime["allowLan"] = false
        config = try Self.compilePingConfig(outbound: outbound, socksPort: Self.freePort(),
          routes: snapshot.routes, runtime: runtime, assetDirectory: snapshot.assetDirectory,
          profilePreferredIP: settings.profilePreferredIP)
      } catch {
        automation.reject(node: node, transient: false, now: self.automationNow())
        if case SubscriptionError.keychainFailure = error {
          automationCandidateFailures[node] = AutomationFailure.missingCredentials.rawValue
        } else { automationCandidateFailures[node] = AutomationFailure.invalidConfiguration.rawValue }
        continue
      }
      guard let object = try JSONSerialization.jsonObject(with: Data(config.utf8)) as? [String: Any],
            let inbounds = object["inbounds"] as? [[String: Any]], inbounds.count == 1,
            inbounds[0]["listen"] as? String == "127.0.0.1",
            let port = inbounds[0]["port"] as? Int else { throw AutomationFailure.unsupportedPolicy }
      var samples: [Double] = []
      do {
        var sampleFailed = false
        for _ in 0..<3 {
          try requireAutomationContext(candidate)
          guard self.automationNow() + 5 <= deadline else { throw AutomationFailure.deadline }
          let target = automationConfiguration.targets[0]
          do {
            samples.append(try await Self.automaticNativeProbe([
              "configJSON": config, "proxy": "socks5://127.0.0.1:\(port)",
              "url": target.url, "method": "GET", "mode": "default",
              "expectedStatus": target.expectedStatus, "expectedBody": target.expectedBody,
            ]).delay)
          } catch is CancellationError { throw CancellationError() }
          catch AutomationFailure.quarantine { throw AutomationFailure.quarantine }
          catch { sampleFailed = true }
        }
        try requireAutomationContext(candidate)
        automation.observe(node: node, passed: !sampleFailed, russianEntry: russianEntry(node))
        if sampleFailed { throw AutomationFailure.endpointFailure }
        automation.record(node: node, reference: candidate.reference, samples: samples, now: self.automationNow())
        scores[node] = automation.score(node: node, reference: candidate.reference, now: self.automationNow())
      } catch is CancellationError { throw CancellationError() }
      catch AutomationFailure.quarantine { throw AutomationFailure.quarantine }
      catch {
        automation.reject(node: node, transient: true, now: self.automationNow())
        automationCandidateFailures[node] = (error as? AutomationFailure)?.rawValue ?? "probeFailed"
      }
    }
    try requireAutomationContext(current)
    guard self.automationNow() < deadline else { throw AutomationFailure.deadline }
    guard let chosen = automation.choose(policy: automationConfiguration.policy,
      order: automationConfiguration.nodeIDs, current: current.nodeID, scores: scores,
      healthy: healthy, now: self.automationNow()) else {
      if !nodes.isEmpty && nodes.allSatisfy({ automationCandidateFailures[$0] == AutomationFailure.missingCredentials.rawValue }) {
        throw AutomationFailure.missingCredentials
      }
      throw healthy ? AutomationFailure.exhaustedCandidates : AutomationFailure.unavailableProbePath
    }
    if chosen != current.nodeID || !healthy {
      try await replaceAutomatically(automationContext(nodeID: chosen))
      automation.switched(now: self.automationNow())
      verifiedHealth = (chosen, automationNow(), automation.epoch)
      automation.healthy(now: self.automationNow(), jitter: self.automationJitter())
      automationStatus = "selected"
      channel.invokeMethod("subscriptionsChanged", arguments: nil)
    }
  }

  @MainActor
  func replaceAutomatically(_ candidate: AutomationContext, previousHealthy: Bool = true) async throws {
    try requireProbePolicy(subscriptionID: subscriptionStore().subscriptionID(nodeID: candidate.nodeID))
    let store = try subscriptionStore()
    guard let oldID = store.selectedNodeID() else { throw AutomationFailure.exhaustedCandidates }
    let previous = try automationContext(nodeID: oldID)
    let selected = try await loadManager()
    let startingDisconnected = selected.connection.status == .disconnected
    try requireAutomationContext(candidate)
    automationStatus = "replacing"
    try store.beginSelectionPublication()
    var activated = false
    do {
      if startingDisconnected {
        // The old provider is already stopped. Install/start the permitted plan
        // with the same protection settings; never relax routes to pre-probe it.
        try await persistPlan(candidate.plan)
        try requireAutomationContext(candidate)
        try await connect()
        try await waitForConnected()
      } else {
        try await switchProvider(plan: candidate.plan, selected: selected)
      }
      activated = true
      _ = try await activeHealth(candidate)
      try requireAutomationContext(candidate)
      try await persistPlan(candidate.plan)
      try requireAutomationContext(candidate)
      try store.finishSelectionPublication(nodeID: candidate.nodeID)
    } catch {
      try store.rollbackPublication(recoveringAfterInterruption: true)
      try Task.checkCancellation()
      try requireAutomationContext(previous)
      if candidate.nodeID != previous.nodeID {
        let permanent = (error as? AutomationFailure).map {
          [AutomationFailure.invalidConfiguration, .missingCredentials, .unsupportedPolicy].contains($0)
        } ?? false
        automation.reject(node: candidate.nodeID, transient: !permanent, now: automationNow())
      }
      // A provider-level failed switch may already have restored its retained core.
      if !startingDisconnected, !activated, !(error is RunnerTunnelError) {
        // The previous plan is still running and saved, so nothing is left to reconcile.
        if Self.keptPreviousPlan(error) { try store.finishRuntimeReconciliation() }
        throw error
      }
      do {
        if (try await loadManager()).connection.status == .disconnected {
          try await persistPlan(previous.plan)
        } else {
          try await switchProvider(plan: previous.plan, selected: try await loadManager())
        }
        // An outage already established that the previous path is unhealthy.
        // Restore its protected configuration without requiring working traffic.
        if previousHealthy { _ = try await activeHealth(previous) }
        try requireAutomationContext(previous)
        try await persistPlan(previous.plan)
        try store.finishRuntimeReconciliation()
      } catch {
        try Task.checkCancellation()
        throw AutomationFailure.restorationFailed
      }
      throw AutomationFailure.replacementRestored
    }
  }
}
