import CryptoKit
import AppKit
import Darwin
import FlutterMacOS
import Foundation
import Network
import NetworkExtension
import ServiceManagement

// NetworkExtension manager: connection lifecycle, saved plans and provider messages.
extension TunnelMethodChannel {
  @MainActor
  func prepareSelectedConnection() async throws {
    let selected: NETunnelProviderManager
    do { selected = try await loadManager() }
    catch RunnerTunnelError.notPrepared {
      let store = try subscriptionStore()
      guard store.selectedNodeID() != nil else { throw RunnerTunnelError.notPrepared }
      try await synchronizeSelectedPlan(store)
      return
    }
    guard selected.connection.status == .disconnected,
          let provider = selected.protocolConfiguration as? NETunnelProviderProtocol,
          let payload = provider.providerConfiguration?["planPayload"] as? Data,
          let plan = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
          ["xrayOutbound", "xrayProfile"].contains(plan["outboundFormat"] as? String ?? "") else { return }
    let store = try subscriptionStore()
    guard store.selectedNodeID() != nil else { throw RunnerTunnelError.notPrepared }
    // A cancelled switch may have saved its candidate without committing selection.
    try await synchronizeSelectedPlan(store)
  }
  @MainActor
  func connect(options: [String: NSObject]? = nil) async throws {
    try Task.checkCancellation()
    guard commands.intent == .connected else { throw RunnerTunnelError.connectionIntentRequired }
    try settingsStore.current.validateRoutePolicy()
    let selected = try await loadManager()
#if DEBUG
    if options != nil, selected.connection.status != .disconnected { throw RunnerTunnelError.invalidState }
#endif
    if [.connected, .connecting, .reasserting].contains(selected.connection.status) {
      try await setOnDemand(selected,
        enabled: settingsStore.current.onDemandEnabled && !automationConfiguration.enabled,
        retainingProtection: settingsStore.current.includeAllNetworks, untrustedWiFi: untrustedWiFiArmed)
      return
    }
    guard selected.connection.status == .disconnected else {
      throw RunnerTunnelError.invalidState
    }
    try settingsStore.current.checkListenerPorts()
    var deferOnDemand = false
#if DEBUG
    deferOnDemand = options != nil
#endif
    do {
      // Fault options must reach explicit start before On Demand can start without them.
      try await setOnDemand(selected,
        enabled: !deferOnDemand && settingsStore.current.onDemandEnabled && !automationConfiguration.enabled,
        retainingProtection: !deferOnDemand && settingsStore.current.includeAllNetworks,
        untrustedWiFi: !deferOnDemand && untrustedWiFiArmed)
      try Task.checkCancellation()
      try await reload(selected)
      try Task.checkCancellation()
      guard !settingsStore.current.includeAllNetworks ||
            (selected.protocolConfiguration as? NETunnelProviderProtocol)?.includeAllNetworks == true else {
        manager = nil
        throw RunnerTunnelError.invalidState
      }
#if DEBUG
      if let options {
        try selected.connection.startVPNTunnel(options: options)
        try await setOnDemand(selected,
          enabled: settingsStore.current.onDemandEnabled && !automationConfiguration.enabled,
          retainingProtection: settingsStore.current.includeAllNetworks, untrustedWiFi: untrustedWiFiArmed)
      } else { try selected.connection.startVPNTunnel() }
#else
      try selected.connection.startVPNTunnel()
#endif
    } catch {
#if DEBUG
      if deferOnDemand && !Task.isCancelled && commands.intent == .connected {
        // Restore only a still-confirmed full-tunnel plan. Explicit Stop owns cancellation.
        guard !settingsStore.current.includeAllNetworks ||
              (selected.protocolConfiguration as? NETunnelProviderProtocol)?.includeAllNetworks == true else { throw error }
        try await setOnDemand(selected,
          enabled: settingsStore.current.onDemandEnabled && !automationConfiguration.enabled,
          retainingProtection: settingsStore.current.includeAllNetworks, untrustedWiFi: untrustedWiFiArmed)
      }
#endif
      throw error
    }
    manager = selected
    // startVPNTunnel returns before the system enters its protected connecting state.
    for _ in 0..<100 {
      try Task.checkCancellation()
      switch selected.connection.status {
      case .connecting, .connected, .reasserting: return
      case .disconnected: try await automationSleep(0.05)
      default: throw RunnerTunnelError.invalidState
      }
    }
    throw RunnerTunnelError.invalidState
  }
  @MainActor
  func disconnect() async throws {
    let stopRequestedAt = Date()
#if DEBUG
    debugStopCompletedAtMs = nil
    debugOSDisconnectedAtMs = nil
    debugStopIdentity = nil
    defer { debugStopIdentity = nil }
    if let metrics = try? await runtimeMetrics(),
       let text = metrics["instanceID"] as? String, let instance = UUID(uuidString: text),
       let generation = metrics["generation"] as? UInt64, generation > 0 {
      debugStopIdentity = (instance, generation)
    }
#endif
    let selected: NETunnelProviderManager
    do { selected = try await loadManager() }
    catch RunnerTunnelError.notPrepared {
      // A fresh catalog or completed repair has nothing left to stop.
      // Keep explicit Stop durable so relaunch cannot re-arm recovery.
#if DEBUG
      let completedAt = Int64((Date().timeIntervalSince1970 * 1000).rounded(.up))
      debugStopCompletedAtMs = completedAt
      debugOSDisconnectedAtMs = completedAt
#endif
      try commands.requireReadableIntent()
      return
    }
    try await prepareProviderStop(selected)
    var suspensionFailed = false
    do { try await setOnDemand(selected, enabled: false) }
    catch is CancellationError { throw CancellationError() }
    catch { suspensionFailed = true }
    try await disconnectAndWait(since: stopRequestedAt)
    if suspensionFailed { throw RunnerTunnelError.onDemandSuspensionFailed }
    try commands.requireReadableIntent()
    try? subscriptions?.reclaimRetiredSecrets()
    await reclaimRoutingFiles()
  }
  @MainActor
  func stopForCatalogChange() async throws {
    let selected: NETunnelProviderManager
    do { selected = try await loadManager() }
    catch RunnerTunnelError.notPrepared { return }
    if selected.connection.status != .invalid { try await disconnect() }
  }
  @MainActor
  func removeSavedPlan() async throws {
    guard commands.intent == .disconnected else { throw RunnerTunnelError.invalidState }
    let selected: NETunnelProviderManager
    do { selected = try await loadManager() }
    catch RunnerTunnelError.notPrepared { return }
    guard selected.connection.status == .invalid ||
      (selected.connection.status == .disconnected && !selected.isOnDemandEnabled) else {
      throw RunnerTunnelError.invalidState
    }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      selected.removeFromPreferences { error in
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume(returning: ()) }
      }
    }
    manager = nil
  }
  @MainActor
  private func prepareProviderStop(_ selected: NETunnelProviderManager) async throws {
    guard [.connected, .connecting, .reasserting].contains(selected.connection.status) else { return }
    struct Reply: Decodable {
      let instanceID: String
      let generation: UInt64
      let code: String?
    }
    guard let session = selected.connection as? NETunnelProviderSession,
          let state = try await sendProviderMessage(Data("state".utf8), session: session),
          let identity = try? JSONDecoder().decode(Reply.self, from: state),
          !identity.instanceID.isEmpty, identity.instanceID.count <= 64 else {
      throw RunnerTunnelError.invalidState
    }
    let request = try JSONSerialization.data(withJSONObject: [
      "schemaVersion": 1, "operation": "prepareStop",
      "instanceID": identity.instanceID, "generation": identity.generation,
    ])
    // A fail-closed (quarantined) provider has no runtime left to drain, and
    // stopping it is the user's way out of its blocked network.
    guard let data = try await sendProviderMessage(request, session: session),
          let reply = try? JSONDecoder().decode(Reply.self, from: data),
          reply.code == "stopped" || reply.code == "quarantined",
          reply.instanceID == identity.instanceID,
          reply.generation == identity.generation else { throw RunnerTunnelError.invalidState }
    try Task.checkCancellation()
  }
  @MainActor
  func reconcileDisconnectedIntent() async throws {
    let armed = commands.intent != .connected && untrustedWiFiArmed
    guard commands.intent == .disconnected || armed else { return }
    let selected: NETunnelProviderManager
    do { selected = try await loadManager() }
    catch RunnerTunnelError.notPrepared { return }
    if armed {
      // On Demand connected an untrusted Wi-Fi network; that connection is the app's from now on.
      if [.connected, .connecting, .reasserting].contains(selected.connection.status) {
        try commands.persist(.connected)
        try await setOnDemand(selected,
          enabled: settingsStore.current.onDemandEnabled && !automationConfiguration.enabled,
          retainingProtection: settingsStore.current.includeAllNetworks, untrustedWiFi: untrustedWiFiArmed)
      } else {
        try await setOnDemand(selected, enabled: false, untrustedWiFi: true)
      }
      return
    }
    if selected.isOnDemandEnabled || !(selected.onDemandRules ?? []).isEmpty ||
        selected.connection.status != .disconnected {
      try await disconnect()
    }
  }
  /// Recovery restarts the tunnel itself while connected, so the Wi-Fi rule then waits as On Demand does.
  var untrustedWiFiArmed: Bool {
    settingsStore.current.connectOnUntrustedWiFi && commands.untrustedWiFiArmed &&
      (commands.intent != .connected || !automationConfiguration.enabled)
  }
  @MainActor
  func setOnDemand(_ selected: NETunnelProviderManager, enabled: Bool,
                           retainingProtection: Bool = false,
                           configurationChanged: Bool = false,
                           untrustedWiFi: Bool = false) async throws {
    // Retained protection must let the OS replace a dead provider before app retries run.
    let rules: [NEOnDemandRule] = (enabled || retainingProtection) ? [NEOnDemandRuleConnect()]
      : untrustedWiFi ? TunnelCommandCoordinator.untrustedWiFiRules(trusted: settingsStore.current.trustedWiFiNetworks) : []
    func policyMatches() -> Bool {
      selected.isOnDemandEnabled == !rules.isEmpty &&
        TunnelCommandCoordinator.sameRules(selected.onDemandRules ?? [], rules)
    }
    do {
      try Task.checkCancellation()
      if !configurationChanged && policyMatches() { return }
      selected.onDemandRules = rules.isEmpty ? nil : rules
      selected.isOnDemandEnabled = !rules.isEmpty
      try await save(selected)
      try await reload(selected)
      try Task.checkCancellation()
      guard policyMatches() else {
        throw RunnerTunnelError.onDemandSuspensionFailed
      }
    } catch {
      // A failed write/reload leaves the mutated cached object unconfirmed.
      manager = nil
      throw error
    }
  }
  @MainActor
  func selectNode(id: String) async throws -> [String: Any] {
    let store = try subscriptionStore()
    let requestedRef = try store.outboundRef(nodeID: id)
    let requestedSubscriptionID = try store.subscriptionID(nodeID: id)
    let status: NEVPNStatus
    do { status = try await loadManager().connection.status }
    catch RunnerTunnelError.notPrepared { status = .disconnected }
    switch status {
    case .disconnected:
      try await store.routing.prepareAssets(subscriptionID: requestedSubscriptionID)
      try store.beginSelectionPublication()
      do {
        try await installPlan(
          secretRef: requestedRef,
          routingSubscriptionID: requestedSubscriptionID
        )
        try Task.checkCancellation()
        try store.finishSelectionPublication(nodeID: id)
      } catch {
        try store.rollbackPublication(recoveringAfterInterruption: true)
        throw error
      }
      return ["state": "prepared", "subscriptions": store.snapshot()]
    case .connected, .reasserting:
      guard commands.intent == .connected else { throw RunnerTunnelError.connectionIntentRequired }
      // Any other manual choice switches directly; the caller then makes it the primary.
      if automationConfiguration.enabled, automationConfiguration.policy != .fixed,
         automationConfiguration.nodeIDs.contains(id) {
        try await replaceAutomatically(automationContext(nodeID: id))
        automation.switched(now: automationNow())
        automation.healthy(now: automationNow(), jitter: automationJitter())
        return ["state": "connected", "subscriptions": store.snapshot()]
      }
      let selected = try await loadManager()
      guard let configuration = selected.protocolConfiguration as? NETunnelProviderProtocol,
            let previousPlan = configuration.providerConfiguration?["planPayload"] as? Data else {
        throw RunnerTunnelError.invalidState
      }
      try await store.routing.prepareAssets(subscriptionID: requestedSubscriptionID)
      let revision = try store.routing.runtimeRevision(subscriptionID: requestedSubscriptionID)
      let candidate = try makePlan(secretRef: requestedRef, routingRevision: revision)
      try store.beginSelectionPublication()
      var activated = false
      do {
        try await switchProvider(plan: candidate, selected: selected)
        activated = true
        try Task.checkCancellation()
        try await persistPlan(candidate)
        try Task.checkCancellation()
        try store.finishSelectionPublication(nodeID: id)
        return ["state": "connected", "subscriptions": store.snapshot()]
      } catch {
        // Even cancellation must retain a durable obligation to reconcile the
        // provider/OS plan. Stop owns the next transition after cancellation.
        try store.rollbackPublication(recoveringAfterInterruption: true)
        try Task.checkCancellation()
        guard activated else {
          // The previous plan is still running and saved, so nothing is left to reconcile.
          if Self.keptPreviousPlan(error) { try store.finishRuntimeReconciliation() }
          throw error
        }
        do {
          try await switchProvider(plan: previousPlan, selected: selected)
          try Task.checkCancellation()
          try await persistPlan(previousPlan)
          try store.finishRuntimeReconciliation()
        } catch {
          try Task.checkCancellation()
          throw RunnerTunnelError.nodeSwitchRestoreFailed
        }
        throw RunnerTunnelError.nodeSwitchFailedRestored
      }
    default:
      throw RunnerTunnelError.invalidState
    }
  }
  @MainActor
  func synchronizeSelectedPlan(_ store: SubscriptionStore) async throws {
    try Task.checkCancellation()
    guard let nodeID = store.selectedNodeID() else { return }
    try await installPlan(
      secretRef: store.outboundRef(nodeID: nodeID),
      routingSubscriptionID: try store.subscriptionID(nodeID: nodeID)
    )
  }
  @MainActor
  private func installPlan(
    secretRef: String,
    routingSubscriptionID: String? = nil
  ) async throws {
    try Task.checkCancellation()
    let revision = try subscriptionStore().routing.runtimeRevision(subscriptionID: routingSubscriptionID)
    let plan = try makePlan(secretRef: secretRef, routingRevision: revision)
    try await persistPlan(plan)
  }
  @MainActor
  func switchProvider(plan: Data, selected: NETunnelProviderManager, refreshOnly: Bool = false, debugFault: Data? = nil) async throws {
    try Task.checkCancellation()
    let candidate = try JSONSerialization.jsonObject(with: plan) as? [String: Any]
    let saved = (selected.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?["planPayload"] as? Data
    if candidate?["backend"] as? String == "xrayTun" ||
       (!refreshOnly && debugFault == nil && !Self.canSwitchLive(from: saved, to: candidate)) {
      guard debugFault == nil, !refreshOnly, let previous = saved else {
        throw RunnerTunnelError.invalidState
      }
      // Xray owns the TUN device; the provider's live switch supports native tun2proxy only.
      do {
        try await TunnelCommandCoordinator.reconnect(from: previous, to: plan, stop: {
          try await self.disconnect()
        }, start: {
          try await self.persistPlan(plan)
          try await self.connect()
          try await self.waitForConnected()
        }, restore: {
          try await self.persistPlan(previous)
          try await self.connect()
          try await self.waitForConnected()
        })
      } catch TunnelCommandCoordinator.ReconnectFailure.restored {
        throw RunnerTunnelError.nodeSwitchFailedRestored
      } catch TunnelCommandCoordinator.ReconnectFailure.restoreFailed {
        throw RunnerTunnelError.nodeSwitchRestoreFailed
      }
      return
    }
    guard let session = selected.connection as? NETunnelProviderSession else {
      throw RunnerTunnelError.invalidState
    }
    let digest = Data(SHA256.hash(data: plan)).base64EncodedString()
    var operationID = UUID().uuidString
#if DEBUG
    if let debugFault {
      operationID = try JSONDecoder().decode(ProviderDebugFaults.Request.self, from: debugFault).id.uuidString
    }
#endif
    var object: [String: Any] = [
      "schemaVersion": 1, "operation": refreshOnly ? "refreshPath" : "switch",
      "operationID": operationID,
      "envelope": ["payload": plan.base64EncodedString(), "digest": digest],
    ]
#if DEBUG
    if let debugFault { object["debugFault"] = try JSONSerialization.jsonObject(with: debugFault) }
#endif
    let request = try JSONSerialization.data(withJSONObject: object)
    let cancellation = try JSONSerialization.data(withJSONObject: [
      "schemaVersion": 1, "operation": "cancelSwitch", "operationID": operationID,
    ])
    let responseData: Data?
    do {
      responseData = try await withTaskCancellationHandler {
        try await sendProviderMessage(request, session: session)
      } onCancel: {
        Task { @MainActor in try? session.sendProviderMessage(cancellation) { _ in } }
      }
    } catch {
      try? session.sendProviderMessage(cancellation) { _ in }
      throw error
    }
    guard let data = responseData,
          let response = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
      throw RunnerTunnelError.nodeSwitchRestoreFailed
    }
    try Task.checkCancellation()
    switch response["code"] {
    case "switched" where response["digest"] == digest: return
    case "unchanged" where refreshOnly && response["digest"] == digest: return
    case "quarantined": throw AutomationFailure.quarantine
    case "missing_credentials": throw AutomationFailure.missingCredentials
    case "invalid_configuration": throw AutomationFailure.invalidConfiguration
    case "resolution_failed": throw AutomationFailure.indeterminate
    case "restored", "rejected": throw RunnerTunnelError.nodeSwitchFailedRestored
    default: throw RunnerTunnelError.nodeSwitchRestoreFailed
    }
  }
  /// As on iOS, the provider switches live only between plans with the same backend and runtime;
  /// a key the saved plan lacks is left to the provider to judge.
  static func canSwitchLive(from saved: Data?, to candidate: [String: Any]?) -> Bool {
    guard let saved, let previous = try? JSONSerialization.jsonObject(with: saved) as? [String: Any],
          let candidate else { return true }
    return ["backend", "settings", "socksPort", "mtu"].allSatisfy { key in
      previous[key].map { ($0 as AnyObject).isEqual(candidate[key]) } ?? true
    }
  }
  /// The provider refused the candidate in these switch failures and still runs the previous plan.
  private static func keptPreviousPlan(_ error: Error) -> Bool {
    if case RunnerTunnelError.nodeSwitchFailedRestored = error { return true }
    guard let failure = error as? AutomationFailure else { return false }
    return [.missingCredentials, .invalidConfiguration, .indeterminate].contains(failure)
  }
#if DEBUG
  func debugFault(_ arguments: [String: Any]) async throws -> [String: Any] {
    guard !automationConfiguration.enabled, commands.intent == .connected,
          let text = arguments["id"] as? String, let id = UUID(uuidString: text),
          (try? ProviderDebugFaults.read(id: id)) == nil,
          let actionText = arguments["action"] as? String,
          let action = ProviderDebugFaults.Action(rawValue: actionText), action != .startupFailure,
          let instance = arguments["instanceID"] as? String, UUID(uuidString: instance) != nil,
          let generation = arguments["generation"] as? UInt64, generation > 0 else {
      throw RunnerTunnelError.invalidSettings
    }
    let selected = try await loadManager()
    guard selected.connection.status == .connected,
          let session = selected.connection as? NETunnelProviderSession else {
      throw RunnerTunnelError.invalidState
    }
    let fault = ProviderDebugFaults.Request(id: id, action: action,
      expiresAt: ProcessInfo.processInfo.systemUptime + 30, instanceID: instance, generation: generation)
    let data = try JSONEncoder().encode(fault)
    if action == .candidateFailure || action == .restoreFailure {
      guard let nodeID = arguments["nodeId"] as? String else { throw RunnerTunnelError.invalidSettings }
      let store = try subscriptionStore()
      let revision = try store.routing.runtimeRevision(subscriptionID: store.subscriptionID(nodeID: nodeID))
      let plan = try makePlan(secretRef: store.outboundRef(nodeID: nodeID), routingRevision: revision)
      try await switchProvider(plan: plan, selected: selected, debugFault: data)
      throw RunnerTunnelError.invalidState // A successful switch did not exercise the requested failure.
    }
    let message = try JSONSerialization.data(withJSONObject: [
      "schemaVersion": 1, "operation": "debugCoreExit",
      "fault": try JSONSerialization.jsonObject(with: data),
    ])
    guard let response = try await sendProviderMessage(message, session: session),
          let value = try JSONSerialization.jsonObject(with: response) as? [String: String],
          value["code"] == "injected" else { throw RunnerTunnelError.invalidState }
    return ["code": "injected", "id": id.uuidString]
  }
#endif
  @MainActor
  func persistPlan(_ plan: Data) async throws {
    try Task.checkCancellation()
    let planDigest = Data(SHA256.hash(data: plan))
    let selected: NETunnelProviderManager
    do { selected = try await loadManager() }
    catch RunnerTunnelError.notPrepared { selected = NETunnelProviderManager() }
    try Task.checkCancellation()
    let tunnelProtocol = NETunnelProviderProtocol()
    settingsStore.current.apply(to: tunnelProtocol)
    tunnelProtocol.providerBundleIdentifier = "com.elarni.mac.packet-tunnel"
    tunnelProtocol.serverAddress = "Elarni"
    tunnelProtocol.providerConfiguration = [
      "planPayload": plan,
      "planDigest": planDigest,
    ]
    var configurationChanged = true
    if let installed = selected.protocolConfiguration as? NETunnelProviderProtocol,
       installed.providerBundleIdentifier == tunnelProtocol.providerBundleIdentifier,
       installed.serverAddress == tunnelProtocol.serverAddress,
       (installed.providerConfiguration as NSDictionary?)?.isEqual(to: tunnelProtocol.providerConfiguration ?? [:]) == true,
       installed.includeAllNetworks == tunnelProtocol.includeAllNetworks,
       installed.excludeLocalNetworks == tunnelProtocol.excludeLocalNetworks,
       installed.enforceRoutes == tunnelProtocol.enforceRoutes,
       installed.disconnectOnSleep == tunnelProtocol.disconnectOnSleep,
       selected.isEnabled && selected.localizedDescription == "Elarni" {
      configurationChanged = false
    }
    if configurationChanged {
      selected.protocolConfiguration = tunnelProtocol
      selected.localizedDescription = "Elarni"
      selected.isEnabled = true
    }
    try await setOnDemand(selected,
      enabled: commands.intent == .connected && settingsStore.current.onDemandEnabled && !automationConfiguration.enabled,
      retainingProtection: commands.intent == .connected && settingsStore.current.includeAllNetworks,
      configurationChanged: configurationChanged, untrustedWiFi: untrustedWiFiArmed)
    manager = selected
  }
  @MainActor
  func disconnectAndWait(since stopRequestedAt: Date = Date()) async throws {
    let selected = try await loadManager()
#if DEBUG
    // Disabling On Demand can itself initiate the orderly provider stop.
    let stopStartedAt = Int64(stopRequestedAt.timeIntervalSince1970 * 1000)
#endif
    if selected.connection.status != .disconnected {
      selected.connection.stopVPNTunnel()
    }
    for _ in 0..<100 {
      try Task.checkCancellation()
      if selected.connection.status == .disconnected {
#if DEBUG
        let osDisconnectedAt = Int64((Date().timeIntervalSince1970 * 1000).rounded(.up))
        debugOSDisconnectedAtMs = osDisconnectedAt
        debugStopCompletedAtMs = osDisconnectedAt
        // OS status delivery can lag route release. Only a fresh, confirmed
        // provider cleanup may establish an earlier orderly-stop boundary.
        if let identity = debugStopIdentity, let receipt = debugReadStop(),
           let completedAt = receipt.confirmedTime(instance: identity.0, generation: identity.1,
             after: stopStartedAt, osDisconnected: osDisconnectedAt) {
          debugStopCompletedAtMs = completedAt
        }
#endif
        return
      }
      try await automationSleep(0.05)
    }
    throw RunnerTunnelError.disconnectTimedOut
  }
  /// Stops the provider for the caller to start again. The system restarts a tunnel stopped under a
  /// Connect rule at once, on the plan it has, so the rule goes first; connect() installs it again.
  @MainActor
  func stopForRestart(_ selected: NETunnelProviderManager) async throws {
    try await setOnDemand(selected, enabled: false)
    try await disconnectAndWait()
  }
  @MainActor
  func waitForConnected() async throws {
    let selected = try await loadManager()
    for attempt in 0..<300 {
      try Task.checkCancellation()
      if selected.connection.status == .connected { return }
      if attempt > 10 && [.disconnected, .invalid].contains(selected.connection.status) {
        throw RunnerTunnelError.invalidState
      }
      try await automationSleep(0.05)
    }
    throw RunnerTunnelError.invalidState
  }
  @MainActor
  func loadManager() async throws -> NETunnelProviderManager {
    try Task.checkCancellation()
    if let manager { return manager }
    let managers = try await loadPreferences()
    try Task.checkCancellation()
    let matching = managers.filter {
      ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier ==
        "com.elarni.mac.packet-tunnel"
    }
    guard matching.count <= 1 else { throw RunnerTunnelError.invalidState }
    guard let selected = matching.first else { throw RunnerTunnelError.notPrepared }
    manager = selected
    return selected
  }
  private func save(_ manager: NETunnelProviderManager) async throws {
    try Task.checkCancellation()
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      manager.saveToPreferences { error in
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume(returning: ()) }
      }
    }
  }
  private func reload(_ manager: NETunnelProviderManager) async throws {
    try Task.checkCancellation()
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      manager.loadFromPreferences { error in
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume(returning: ()) }
      }
    }
  }
  func sendProviderMessage(
    _ message: Data,
    session: NETunnelProviderSession
  ) async throws -> Data? {
    let reply = ProviderMessageReply()
    let deadline = Task {
      do { try await automationSleep(15) }
      catch { return }
      reply.finish(.failure(AutomationFailure.deadline))
    }
    defer { deadline.cancel() }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        reply.install(continuation)
        do {
          try Task.checkCancellation()
          try session.sendProviderMessage(message) { response in
            reply.finish(.success(response))
          }
        } catch {
          reply.finish(.failure(error))
        }
      }
    } onCancel: {
      reply.finish(.failure(CancellationError()))
    }
  }
  /// The plan, or nil when nothing runs and only a per-app target's server is gone: Connect
  /// reports that, and the saved plan keeps what it had until then.
  func planUnlessTargetMissing(secretRef: String, routingRevision: RuntimeRoutingRevision?, active: Bool) throws -> Data? {
    do { return try makePlan(secretRef: secretRef, routingRevision: routingRevision) }
    catch RunnerTunnelError.perAppTargetMissing where !active { return nil }
  }
  func makePlan(
    secretRef: String,
    routingRevision: RuntimeRoutingRevision? = nil
  ) throws -> Data {
    let store = try subscriptionStore()
    let settings = settingsStore.current.applyingIPPreference(try store.ipPreference(nodeID: store.nodeID(secretRef: secretRef)))
    var plan: [String: Any] = [
      "schemaVersion": 1,
      "secretRef": secretRef,
      "socksPort": settingsStore.current.socksPort,
      "mtu": 1_500,
      "dnsServers": ["198.18.0.1", "2001:2::1"],
      "controlledRoutes": [],
      "staticHosts": [:],
      "settings": try connectionPlanSettings(settings, store: store),
    ]
    let format = try store.outboundFormat(secretRef: secretRef)
    plan["outboundFormat"] = format
    if format == "xrayOutbound" { plan["fallbackAction"] = "proxy" }
    if let routingRevision {
      plan["routingRevision"] = routingRevision.name
      plan["routingDigest"] = routingRevision.digest
      if let assetRevision = routingRevision.assetRevision {
        plan["assetRevision"] = assetRevision
      }
    }
    if settingsStore.current.xrayTunEnabled {
      plan["backend"] = "xrayTun"
    }
    return try JSONSerialization.data(withJSONObject: plan, options: [.sortedKeys])
  }
}

// App command ownership is separate from the provider's resource generation.
private final class ProviderMessageReply: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Data?, Error>?
  private var result: Result<Data?, Error>?

  func install(_ continuation: CheckedContinuation<Data?, Error>) {
    lock.lock()
    let result = self.result
    if result == nil { self.continuation = continuation }
    lock.unlock()
    if let result { continuation.resume(with: result) }
  }

  func finish(_ result: Result<Data?, Error>) {
    lock.lock()
    guard self.result == nil else { lock.unlock(); return }
    self.result = result
    let continuation = self.continuation
    self.continuation = nil
    lock.unlock()
    continuation?.resume(with: result)
  }
}
