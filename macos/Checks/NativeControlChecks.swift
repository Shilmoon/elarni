import FlutterMacOS
import Foundation
import NetworkExtension
import Security

// Exercises the registered production handler, with no OS VPN preferences,
// subscriptions, network observers or automation timers available to the fixture.
@main
@MainActor
struct NativeControlChecks {
  struct Failure: Error { let message: String }

  // Selection checks record their failure; run() fails once at the end so each one reports.
  static var selectionFailures: [String] = []
  static func record(_ body: () async throws -> Void) async {
    do { try await body() }
    catch let failure as Failure { selectionFailures.append(failure.message) }
    catch { selectionFailures.append("\(error)") }
  }

  static func main() async {
    DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
      fputs("FAIL native control checks timed out\n", stderr)
      exit(1)
    }
    do { try await run() }
    catch let failure as Failure { fputs("FAIL \(failure.message)\n", stderr); exit(1) }
    catch { fputs("FAIL native control checks\n", stderr); exit(1) }
  }

  static func run() async throws {
    let suite = "com.elarni.control-checks.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    // An existing install; a fresh one stores a generated listener login (freshInstallLoginChecks).
    defaults.set(try JSONEncoder().encode(AppTunnelSettings.defaults), forKey: "ElarniTunnelSettingsV1")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("elarni-native-control-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    var keychainCalls = 0
    func openStore() throws -> SubscriptionStore {
      let secrets = SubscriptionSecretAccess(
        add: { _, _ in keychainCalls += 1; return errSecInteractionNotAllowed },
        copy: { _, _ in keychainCalls += 1; return errSecInteractionNotAllowed },
        update: { _, _ in keychainCalls += 1; return errSecInteractionNotAllowed },
        delete: { _ in keychainCalls += 1; return errSecInteractionNotAllowed },
        accessGroup: { "TEST.com.elarni.control-checks" })
      return try SubscriptionStore(directory: directory,
        routing: RoutingStore(directory: directory.appendingPathComponent("routing")), secretAccess: secrets)
    }
    let messenger = ControlMessenger()
    let controller = TunnelMethodChannel(messenger: messenger, defaults: defaults,
      observesSystem: false, makeSubscriptions: openStore, loadPreferences: { [] })
    defer { withExtendedLifetime(controller) {} }
    guard try await messenger.call("state")["state"] as? String == "disconnected" else {
      throw Failure(message: "fresh controller state")
    }
    for _ in 0..<2 {
      guard try await messenger.call("disconnect")["state"] as? String == "disconnected" else {
        throw Failure(message: "Stop without a profile")
      }
    }
    guard TunnelCommandCoordinator(defaults: defaults).intent == .disconnected else {
      throw Failure(message: "Stop intent did not survive recreation")
    }
    print("PASS native Stop is idempotent without a saved VPN profile and persists intent")
    // scripts/check-macos-control embeds NativeControlInfo.plist in this binary.
    guard try await messenger.call("systemInfo")["appVersion"] as? String == "1.2.3+45" else {
      throw Failure(message: "systemInfo has no app version for Settings")
    }
    print("PASS systemInfo reports the bundle's version and build")
    do {
      _ = try await messenger.call("importClientProfiles", arguments: ["content": "happ://routing/off"])
      throw Failure(message: "a routing link without a selected server was accepted")
    } catch let failure as Failure where failure.message == "importClientProfiles: no_selected_subscription" {}
    print("PASS a routing link without a selected server asks for one")

    let startingMessenger = ControlMessenger()
    var pendingLoad: CheckedContinuation<[NETunnelProviderManager], Error>?
    var pauseFirstLoad = true
    let startingController = TunnelMethodChannel(messenger: startingMessenger, defaults: defaults,
      observesSystem: false, makeSubscriptions: openStore, loadPreferences: {
        guard pauseFirstLoad else { return [] }
        pauseFirstLoad = false
        return try await withCheckedThrowingContinuation { pendingLoad = $0 }
      })
    defer { withExtendedLifetime(startingController) {} }
    let start = Task { try await startingMessenger.call("connect") }
    while pendingLoad == nil { await Task.yield() }
    let stop = Task { try await startingMessenger.call("disconnect") }
    while TunnelCommandCoordinator(defaults: defaults).intent != .disconnected { await Task.yield() }
    let first = pendingLoad!
    pendingLoad = nil
    first.resume(returning: [])
    do { _ = try await start.value; throw Failure(message: "late Start survived Stop") }
    catch let failure as Failure where failure.message == "connect: operation_cancelled" {}
    _ = try await stop.value
    print("PASS native Stop cancels Start waiting for OS preferences; late completion cannot reconnect")

    // This is the durable post-journal state after an interrupted publication.
    let catalog = directory.appendingPathComponent("subscriptions-v1.json")
    try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "subscriptions": [],
      "runtimeReconciliationRequired": true]).write(to: catalog, options: .atomic)
    let recovered = try openStore()
    try TunnelCommandCoordinator(defaults: defaults).persist(.connected)
    var denyPreferences = true
    let recoveryMessenger = ControlMessenger()
    let recoveryController = TunnelMethodChannel(messenger: recoveryMessenger, defaults: defaults,
      observesSystem: false, makeSubscriptions: { recovered }, loadPreferences: {
        if denyPreferences { throw NSError(domain: NEVPNErrorDomain, code: 5) }
        return []
      })
    defer { withExtendedLifetime(recoveryController) {} }
    do { _ = try await recoveryMessenger.call("state"); throw Failure(message: "failed recovery accepted") }
    catch let failure as Failure where failure.message == "state: vpn_configuration_failed" {}
    guard recovered.runtimeReconciliationRequired, try openStore().runtimeReconciliationRequired,
          TunnelCommandCoordinator(defaults: defaults).intent == .disconnected else {
      throw Failure(message: "failed OS reconciliation lost durable recovery/Stop state")
    }
    denyPreferences = false
    _ = try await recoveryMessenger.call("state")
    guard !recovered.runtimeReconciliationRequired, try !openStore().runtimeReconciliationRequired else {
      throw Failure(message: "successful reconciliation was not acknowledged")
    }
    print("PASS failed OS reconciliation retains recovery marker and Stop; retry clears it only after confirmation")

    for status in [NEVPNStatus.disconnected, .invalid] {
      try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "subscriptions": [],
        "runtimeReconciliationRequired": true]).write(to: catalog, options: .atomic)
      let pendingRemoval = try openStore()
      let manager = ControlManager()
      manager.fixtureConnection.fixtureStatus = status
      let configuration = NETunnelProviderProtocol()
      configuration.providerBundleIdentifier = "com.elarni.mac.packet-tunnel"
      manager.protocolConfiguration = configuration
      manager.isOnDemandEnabled = status != .invalid
      manager.onDemandRules = status != .invalid ? [NEOnDemandRuleConnect()] : nil
      let removalMessenger = ControlMessenger()
      let removalController = TunnelMethodChannel(messenger: removalMessenger, defaults: defaults,
        observesSystem: false, makeSubscriptions: { pendingRemoval }, loadPreferences: {
          manager.removed ? [] : [manager]
        })
      defer { withExtendedLifetime(removalController) {} }
      do { _ = try await removalMessenger.call("state"); throw Failure(message: "failed removal accepted") }
      catch let failure as Failure where failure.message == "state: vpn_configuration_failed" {}
      guard (manager.saved || status == .invalid), !manager.isOnDemandEnabled, pendingRemoval.runtimeReconciliationRequired else {
        throw Failure(message: "recovery did not disarm before removal, or acknowledged failed cleanup")
      }
      manager.failRemoval = false
      _ = try await removalMessenger.call("state")
      guard manager.removed, !pendingRemoval.runtimeReconciliationRequired else {
        throw Failure(message: "saved plan removal did not complete recovery")
      }
      print("PASS recovery reconciles \(status == .invalid ? "invalid" : "disconnected") profile and retains marker until removal succeeds")
    }

    let damagedMessenger = ControlMessenger()
    let damagedController = TunnelMethodChannel(messenger: damagedMessenger, defaults: defaults,
      observesSystem: false, makeSubscriptions: { throw SubscriptionError.invalidCatalog }, loadPreferences: { [] })
    defer { withExtendedLifetime(damagedController) {} }
    for method in ["disconnect", "repairTunnel"] {
      guard try await damagedMessenger.call(method)["state"] as? String == "disconnected" else {
        throw Failure(message: "damaged catalog prevented \(method)")
      }
    }
    print("PASS unreadable catalog does not prevent Stop or profile repair")

    try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "subscriptions": [],
      "runtimeReconciliationRequired": true]).write(to: catalog, options: .atomic)
    let unreadableStore = try openStore()
    let unknownIntent = Data("unknown intent schema".utf8)
    defaults.set(unknownIntent, forKey: "ElarniConnectionIntentV1")
    var attemptedCleanup = false
    let unreadableMessenger = ControlMessenger()
    let unreadableController = TunnelMethodChannel(messenger: unreadableMessenger, defaults: defaults,
      observesSystem: false, makeSubscriptions: { unreadableStore }, loadPreferences: {
        attemptedCleanup = true
        return []
      })
    defer { withExtendedLifetime(unreadableController) {} }
    do { _ = try await unreadableMessenger.call("disconnect"); throw Failure(message: "unreadable intent silently replaced") }
    catch let failure as Failure where failure.message == "disconnect: connection_intent_unreadable" {}
    guard attemptedCleanup, unreadableStore.runtimeReconciliationRequired,
          defaults.data(forKey: "ElarniConnectionIntentV1") == unknownIntent else {
      throw Failure(message: "unreadable intent prevented cleanup or lost durable recovery state")
    }
    print("PASS unreadable intent allows Stop cleanup and preserves unknown durable state")
    try await selectionChecks(defaults: defaults)
    try await freshInstallLoginChecks()
    await record { try await otherSubscriptionAssetsCheck(defaults: defaults) }
    await record { try await crossSubscriptionRecoveryCheck(defaults: defaults) }
    await record { try await perAppTargetCheck(defaults: defaults) }
    await record { try await coreLogCheck(defaults: defaults) }

    // Call the actual socket probe without measureICMP, which requires an OS
    // VPN manager. Loopback exposes address-family selection without a tunnel.
    for (host, preference) in [("::1", "automatic"), ("::1", "ipv6"),
                               ("127.0.0.1", "automatic"), ("127.0.0.1", "ipv4")] {
      let delay = try TunnelMethodChannel.checkICMPProbe(host: host, timeout: 1, preferredIP: preference)
      guard delay >= 1 && delay < 2000 else { throw Failure(message: "loopback ICMP timing") }
    }
    do {
      _ = try TunnelMethodChannel.checkICMPProbe(host: "::1", timeout: 1, preferredIP: "ipv4")
      throw Failure(message: "IPv4 preference accepted IPv6")
    } catch RunnerTunnelError.pingFailure {}
    guard try TunnelMethodChannel.checkICMPFallback() >= 1 else {
      throw Failure(message: "ICMP did not try the next address after socket failure")
    }
    print("PASS production ICMP probe supports Automatic IPv4/IPv6, address fallback and explicit family")
    guard keychainCalls == 0 else { throw Failure(message: "fixture unexpectedly needed credentials") }
    guard selectionFailures.isEmpty else { throw Failure(message: selectionFailures.joined(separator: "; ")) }
    print("21 native control checks passed; no VPN preferences or credentials used; ICMP uses loopback only")
  }

  // Other local apps must not reach a fresh install's listeners without a login (v2rayNG #5457).
  static func freshInstallLoginChecks() async throws {
    var values: [String: Data] = [:]
    func key(_ query: CFDictionary) -> String { (query as NSDictionary)[kSecAttrAccount] as! String }
    let secrets = SubscriptionSecretAccess(add: { query, _ in
      values[key(query)] = (query as NSDictionary)[kSecValueData] as? Data; return errSecSuccess
    }, copy: { query, output in
      guard let data = values[key(query)] else { return errSecItemNotFound }
      output?.pointee = data as CFData; return errSecSuccess
    }, update: { query, attributes in
      values[key(query)] = (attributes as NSDictionary)[kSecValueData] as? Data; return errSecSuccess
    }, delete: { query in values.removeValue(forKey: key(query)); return errSecSuccess },
      accessGroup: { "TEST.com.elarni.login-checks" })
    for upgraded in [false, true] {
      let suite = "com.elarni.login-checks.\(UUID())"
      let defaults = UserDefaults(suiteName: suite)!
      defer { defaults.removePersistentDomain(forName: suite) }
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent("elarni-login-control-\(UUID())")
      defer { try? FileManager.default.removeItem(at: directory) }
      if upgraded {
        defaults.set(try JSONSerialization.data(withJSONObject: ["xrayTunEnabled": false]), forKey: "ElarniTunnelSettingsV1")
      }
      let store = try SubscriptionStore(directory: directory,
        routing: RoutingStore(directory: directory.appendingPathComponent("routing")), secretAccess: secrets)
      let messenger = ControlMessenger()
      let controller = TunnelMethodChannel(messenger: messenger, defaults: defaults, observesSystem: false,
        makeSubscriptions: { store }, loadPreferences: { [] })
      defer { withExtendedLifetime(controller) {} }
      let settings = try await messenger.call("tunnelSettings")
      let required = settings["inboundAuthEnabled"] as? Bool == true && settings["inboundCredentialsConfigured"] as? Bool == true
      guard required != upgraded else {
        throw Failure(message: upgraded ? "an upgraded install's listeners changed" : "a fresh install's listeners take no login")
      }
      if !upgraded {
        let login = try store.inboundCredentials(ref: try requiredRef(controller.settingsStore.current.inboundCredentialRef))
        guard [login["username"], login["password"]].allSatisfy({ $0?.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil }) else {
          throw Failure(message: "a fresh install's generated login")
        }
      }
      // Settings shows the saved login so apps can be set up with it.
      let shown = try await messenger.call("inboundCredentials")
      let saved = try controller.settingsStore.current.inboundCredentialRef.map { try store.inboundCredentials(ref: $0) } ?? [:]
      guard shown as NSDictionary == saved as NSDictionary else {
        throw Failure(message: "the app shows a login other than the saved one")
      }
    }
    print("PASS a fresh install's listeners require a generated login; an upgraded install's stay as they were")
  }

  private static func requiredRef(_ value: String?) throws -> String {
    guard let value else { throw Failure(message: "no inbound credential reference") }
    return value
  }

  static func selectionChecks(defaults: UserDefaults) async throws {
    defaults.removeObject(forKey: "ElarniConnectionIntentV1")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("elarni-switch-control-\(UUID())")
    let directory = root.appendingPathComponent("source"), interrupted = root.appendingPathComponent("interrupted")
    defer { try? FileManager.default.removeItem(at: root) }
    var values: [String: Data] = [:]
    func key(_ query: CFDictionary) -> String { (query as NSDictionary)[kSecAttrAccount] as! String }
    let secrets = SubscriptionSecretAccess(add: { query, _ in
      let account = key(query)
      guard values[account] == nil else { return errSecDuplicateItem }
      values[account] = (query as NSDictionary)[kSecValueData] as? Data
      return errSecSuccess
    }, copy: { query, output in
      guard let data = values[key(query)] else { return errSecItemNotFound }
      output?.pointee = data as CFData; return errSecSuccess
    }, update: { query, attributes in
      values[key(query)] = (attributes as NSDictionary)[kSecValueData] as? Data; return errSecSuccess
    }, delete: { query in values.removeValue(forKey: key(query)); return errSecSuccess },
      accessGroup: { "TEST.com.elarni.switch-checks" })
    func open(_ directory: URL) throws -> SubscriptionStore {
      try SubscriptionStore(directory: directory,
        routing: RoutingStore(directory: directory.appendingPathComponent("routing")), secretAccess: secrets)
    }
    let store = try open(directory)
    store.publishRefresh = { candidate in
      _ = try store.beginPublication(candidate); try store.finishPublication(candidate)
    }
    let id = try store.registerProfiles("socks://127.0.0.1:1080#First\nsocks://127.0.0.1:1081#Second")
    _ = try await store.refresh(id: id)
    let groups = store.snapshot()["subscriptions"] as! [[String: Any]]
    let nodes = groups[0]["nodes"] as! [[String: Any]]
    guard nodes.count == 2 else { throw Failure(message: "selection fixture import") }
    let first = nodes[0]["id"] as! String, second = nodes[1]["id"] as! String
    try store.commitSelection(nodeID: first)
    let firstRef = try store.outboundRef(nodeID: first)
    let oldPlan = try JSONSerialization.data(withJSONObject: ["secretRef": firstRef])
    defaults.set(try JSONSerialization.data(withJSONObject: ["xrayTunEnabled": false]), forKey: "ElarniTunnelSettingsV1")
    try TunnelCommandCoordinator(defaults: defaults).persist(.connected)
    let manager = SwitchManager(plan: oldPlan)
    let messenger = ControlMessenger()
    let controller = TunnelMethodChannel(messenger: messenger, defaults: defaults, observesSystem: false,
      makeSubscriptions: { store }, loadPreferences: { [manager] })
    defer { withExtendedLifetime(controller) {} }
    manager.pauseSave = true
    let switching = Task { try await messenger.call("selectNode", arguments: ["id": second]) }
    while manager.pendingSave == nil { await Task.yield() }
    guard store.publicationInProgress, manager.fixtureSession.switches == 1 else {
      throw Failure(message: "selection was not journaled before provider/save publication")
    }
    // Copy only this synthetic fixture while the real handler is suspended at
    // OS persistence. Reopening it models host death without killing any app.
    try FileManager.default.copyItem(at: directory, to: interrupted)
    let recovered = try open(interrupted)
    guard recovered.selectedNodeID() == first, recovered.runtimeReconciliationRequired else {
      throw Failure(message: "relaunch lost the previous selection")
    }
    let candidate = (manager.protocolConfiguration as! NETunnelProviderProtocol).providerConfiguration!["planPayload"] as! Data
    let recoveredManager = SwitchManager(plan: candidate)
    let recoveredMessenger = ControlMessenger()
    let recoveredController = TunnelMethodChannel(messenger: recoveredMessenger, defaults: defaults, observesSystem: false,
      makeSubscriptions: { recovered }, loadPreferences: { [recoveredManager] })
    defer { withExtendedLifetime(recoveredController) {} }
    _ = try await recoveredMessenger.call("state")
    let restored = try JSONSerialization.jsonObject(with:
      (recoveredManager.protocolConfiguration as! NETunnelProviderProtocol).providerConfiguration!["planPayload"] as! Data) as! [String: Any]
    guard !recovered.runtimeReconciliationRequired, recoveredManager.fixtureSession.status == .disconnected,
          restored["secretRef"] as? String == firstRef else {
      throw Failure(message: "real handler did not reconcile interrupted selection")
    }
    // The original owner is an independent simulated process; restore its
    // fixture intent after the simulated relaunch's orderly Stop.
    try TunnelCommandCoordinator(defaults: defaults).persist(.connected)
    manager.resumeSave()
    _ = try await switching.value
    guard store.selectedNodeID() == second, !store.publicationInProgress else {
      throw Failure(message: "completed handler selection was not committed")
    }
    print("PASS real selection handler journals provider/save gap and relaunch restores catalog/plan agreement")

    manager.pauseSave = true
    let cancelled = Task { try await messenger.call("selectNode", arguments: ["id": first]) }
    while manager.pendingSave == nil { await Task.yield() }
    let stopping = Task { try await messenger.call("disconnect") }
    while TunnelCommandCoordinator(defaults: defaults).intent != .disconnected { await Task.yield() }
    manager.resumeSave()
    do { _ = try await cancelled.value; throw Failure(message: "cancelled selection completed") }
    catch let failure as Failure where failure.message == "selectNode: operation_cancelled" {}
    _ = try await stopping.value
    _ = try await messenger.call("state")
    guard store.selectedNodeID() == second, !store.publicationInProgress, !store.runtimeReconciliationRequired,
          manager.fixtureSession.status == .disconnected,
          TunnelCommandCoordinator(defaults: defaults).intent == .disconnected else {
      throw Failure(message: "Stop lost selection recovery or restarted provider")
    }
    print("PASS Stop crossing saved-plan publication preserves committed selection and reconciles without reconnecting")

    // A fail-closed provider answers prepareStop with "quarantined"; Stop is the way out.
    try TunnelCommandCoordinator(defaults: defaults).persist(.connected)
    let quarantined = SwitchManager(plan: candidate)
    quarantined.fixtureSession.stopCode = "quarantined"
    quarantined.onDemandRules = [NEOnDemandRuleConnect()]
    quarantined.isOnDemandEnabled = true
    let quarantinedMessenger = ControlMessenger()
    let quarantinedController = TunnelMethodChannel(messenger: quarantinedMessenger, defaults: defaults,
      observesSystem: false, makeSubscriptions: { store }, loadPreferences: { [quarantined] })
    defer { withExtendedLifetime(quarantinedController) {} }
    _ = try await quarantinedMessenger.call("disconnect")
    guard quarantined.fixtureSession.status == .disconnected, !quarantined.isOnDemandEnabled else {
      throw Failure(message: "Stop failed while the provider was quarantined")
    }
    print("PASS Stop disables On Demand and stops a quarantined provider")

    // These replies mean the provider kept the previous plan running.
    try TunnelCommandCoordinator(defaults: defaults).persist(.connected)
    let refused = SwitchManager(plan: candidate)
    let refusedMessenger = ControlMessenger()
    let refusedController = TunnelMethodChannel(messenger: refusedMessenger, defaults: defaults,
      observesSystem: false, makeSubscriptions: { store }, loadPreferences: { [refused] })
    defer { withExtendedLifetime(refusedController) {} }
    for (code, expected) in [("restored", "node_switch_failed_restored"), ("rejected", "node_switch_failed_restored"),
                             ("missing_credentials", "automation_missingCredentials"),
                             ("invalid_configuration", "automation_invalidConfiguration"),
                             ("resolution_failed", "automation_indeterminate")] {
      refused.fixtureSession.switchCode = code
      let switches = refused.fixtureSession.switches
      do {
        _ = try await refusedMessenger.call("selectNode", arguments: ["id": first])
        throw Failure(message: "refused \(code) switch was accepted")
      } catch let failure as Failure where failure.message == "selectNode: \(expected)" {}
      let pending = store.runtimeReconciliationRequired
      let state = try await refusedMessenger.call("state")
      let saved = (refused.protocolConfiguration as! NETunnelProviderProtocol).providerConfiguration!["planPayload"] as? Data
      guard !pending, state["state"] as? String == "connected", state["connectionIntent"] as? String == "connected",
            store.selectedNodeID() == second, refused.fixtureSession.switches == switches + 1, saved == candidate else {
        throw Failure(message: "refused \(code) switch left reconciliation that stops the working previous plan")
      }
    }
    print("PASS refused node switch keeps the previous plan connected with nothing left to reconcile")

    // The provider rejects a live switch to other runtime settings, so a server with its
    // own IP preference needs a restart, as on iOS.
    _ = try await store.setNodeIPPreference(nodeID: first, preference: "ipv6")
    let restarting = SwitchManager(plan: candidate)
    restarting.fixtureSession.switchCode = "rejected"
    restarting.fixtureSession.startable = true
    let restartingMessenger = ControlMessenger()
    let restartingController = TunnelMethodChannel(messenger: restartingMessenger, defaults: defaults,
      observesSystem: false, makeSubscriptions: { store }, loadPreferences: { [restarting] })
    defer { withExtendedLifetime(restartingController) {} }
    do { _ = try await restartingMessenger.call("selectNode", arguments: ["id": first]) }
    catch let failure as Failure { throw Failure(message: "switch to another IP preference: \(failure.message)") }
    let restarted = try JSONSerialization.jsonObject(with:
      (restarting.protocolConfiguration as! NETunnelProviderProtocol).providerConfiguration!["planPayload"] as! Data) as! [String: Any]
    guard store.selectedNodeID() == first, restarting.fixtureSession.switches == 0, restarting.fixtureSession.starts == 1,
          (restarted["settings"] as? [String: Any])?["preferredIP"] as? String == "ipv6" else {
      throw Failure(message: "a switch to another IP preference did not restart the provider with the new plan")
    }
    print("PASS a switch to a server with another IP preference restarts the provider")
    // A settings change rebuilds the selected server's plan; global settings must not replace it.
    let savedSettings = defaults.data(forKey: "ElarniTunnelSettingsV1")
    _ = try await restartingMessenger.call("updateTunnelSettings", arguments: ["muxEnabled": true])
    let reapplied = try JSONSerialization.jsonObject(with:
      (restarting.protocolConfiguration as! NETunnelProviderProtocol).providerConfiguration!["planPayload"] as! Data) as! [String: Any]
    let reappliedSettings = reapplied["settings"] as? [String: Any]
    guard reapplied["backend"] == nil, reappliedSettings?["preferredIP"] as? String == "ipv6",
          reappliedSettings?["muxEnabled"] as? Bool == true, restarting.fixtureSession.status == .connected else {
      throw Failure(message: "a settings change replaced the selected server's plan with global settings")
    }
    defaults.set(savedSettings, forKey: "ElarniTunnelSettingsV1")
    print("PASS a settings change keeps the selected server's IP preference and native plan")
    // With a Connect rule installed the system restarts a stopped tunnel by itself on the plan it
    // already has, so a settings change or an ICMP ping must lift the rule while it restarts the provider.
    let demanding = SwitchManager(plan: candidate)
    demanding.fixtureSession.startable = true
    let demandingMessenger = ControlMessenger()
    let demandingController = TunnelMethodChannel(messenger: demandingMessenger, defaults: defaults,
      observesSystem: false, makeSubscriptions: { store }, loadPreferences: { [demanding] })
    defer { withExtendedLifetime(demandingController) {} }
    _ = try await demandingMessenger.call("updateTunnelSettings", arguments: ["onDemandEnabled": true])
    guard demanding.isOnDemandEnabled, demanding.fixtureSession.starts == 0 else {
      throw Failure(message: "On Demand did not install on the connected tunnel")
    }
    _ = try await demandingMessenger.call("updateTunnelSettings", arguments: ["muxEnabled": true])
    _ = try await demandingMessenger.call("pingNode", arguments: ["nodeId": second, "protocol": "icmp",
      "method": "GET", "mode": "default", "timeout": 5, "url": ""])
    guard demanding.fixtureSession.onDemandRestarts == 0, demanding.fixtureSession.starts == 2,
          demanding.isOnDemandEnabled, demanding.fixtureSession.status == .connected else {
      throw Failure(message: "a restart left On Demand to bring back the old plan: " +
        "\(demanding.fixtureSession.onDemandRestarts) system restarts, \(demanding.fixtureSession.starts) starts")
    }
    defaults.set(savedSettings, forKey: "ElarniTunnelSettingsV1")
    print("PASS a settings change and an ICMP ping restart the provider themselves and keep On Demand")
    await record { try await untrustedWiFiCheck(store: store, defaults: defaults, plan: candidate) }
    // Back on the second server's plan, clearing the first server's preference changes no running plan,
    // which this fixture could not validate without the core helper.
    try store.commitSelection(nodeID: second)
    let resetting = SwitchManager(plan: candidate)
    let resettingMessenger = ControlMessenger()
    let resettingController = TunnelMethodChannel(messenger: resettingMessenger, defaults: defaults,
      observesSystem: false, makeSubscriptions: { store }, loadPreferences: { [resetting] })
    defer { withExtendedLifetime(resettingController) {} }
    _ = try await resettingMessenger.call("state")
    _ = try await store.setNodeIPPreference(nodeID: first, preference: nil)
    try await pingChecks(store: store, defaults: defaults)
    await record { try await fixedAutomationSelectionCheck(store: store, defaults: defaults, plan: candidate, pinned: second, other: first) }
  }

  // Settings hide the test URL for TCP and ICMP, so the app sends it empty.
  static func pingChecks(store: SubscriptionStore, defaults: UserDefaults) async throws {
    // A listening socket completes the TCP handshake without accept().
    let listener = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(listener) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    var length = socklen_t(address.sin_len)
    let listening = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(listener, $0, length) == 0 && listen(listener, 4) == 0 && getsockname(listener, $0, &length) == 0
      }
    }
    guard listener >= 0, listening else { throw Failure(message: "ping fixture listener") }
    let id = try store.registerProfiles("socks://127.0.0.1:\(UInt16(bigEndian: address.sin_port))#Ping")
    _ = try await store.refresh(id: id)
    let subscriptions = store.snapshot()["subscriptions"] as! [[String: Any]]
    guard let nodes = subscriptions.first(where: { $0["id"] as? String == id })?["nodes"] as? [[String: Any]],
          let node = nodes.first(where: { $0["name"] as? String == "Ping" })?["id"] as? String else { throw Failure(message: "ping fixture import") }
    try TunnelCommandCoordinator(defaults: defaults).persist(.disconnected)
    let messenger = ControlMessenger()
    let controller = TunnelMethodChannel(messenger: messenger, defaults: defaults, observesSystem: false,
      makeSubscriptions: { store }, loadPreferences: { [] })
    defer { withExtendedLifetime(controller) {} }
    func ping(_ pingProtocol: String) async throws -> [String: Any] {
      try await messenger.call("pingNode", arguments: ["nodeId": node, "protocol": pingProtocol,
        "method": "GET", "mode": "default", "timeout": 5, "url": ""])
    }
    let reply = try await ping("tcp")
    guard reply["status"] as? String == "success", reply["latencyMs"] is Int else {
      throw Failure(message: "TCP ping without a test URL")
    }
    do { _ = try await ping("proxy"); throw Failure(message: "proxy ping accepted an empty test URL") }
    catch let failure as Failure where failure.message == "pingNode: operation_failed" {}
    print("PASS TCP ping needs no test URL; proxy ping still requires one")
  }

  // Two servers in separate subscriptions, kept in an in-memory keychain; the first is selected.
  static func twoSubscriptions(_ directory: URL) async throws
    -> (store: SubscriptionStore, selected: (subscription: String, node: String), other: (subscription: String, node: String)) {
    var values: [String: Data] = [:]
    func key(_ query: CFDictionary) -> String { (query as NSDictionary)[kSecAttrAccount] as! String }
    let secrets = SubscriptionSecretAccess(add: { query, _ in
      let account = key(query)
      guard values[account] == nil else { return errSecDuplicateItem }
      values[account] = (query as NSDictionary)[kSecValueData] as? Data
      return errSecSuccess
    }, copy: { query, output in
      guard let data = values[key(query)] else { return errSecItemNotFound }
      output?.pointee = data as CFData; return errSecSuccess
    }, update: { query, attributes in
      values[key(query)] = (attributes as NSDictionary)[kSecValueData] as? Data; return errSecSuccess
    }, delete: { query in values.removeValue(forKey: key(query)); return errSecSuccess },
      accessGroup: { "TEST.com.elarni.other-assets-checks" })
    let store = try SubscriptionStore(directory: directory,
      routing: RoutingStore(directory: directory.appendingPathComponent("routing")), secretAccess: secrets)
    store.publishRefresh = { candidate in
      _ = try store.beginPublication(candidate); try store.finishPublication(candidate)
    }
    func importNode(_ link: String) async throws -> (subscription: String, node: String) {
      let id = try store.registerProfiles(link)
      _ = try await store.refresh(id: id)
      let groups = store.snapshot()["subscriptions"] as! [[String: Any]]
      let nodes = groups.first(where: { $0["id"] as? String == id })!["nodes"] as! [[String: Any]]
      return (id, nodes[0]["id"] as! String)
    }
    let selected = try await importNode("socks://127.0.0.1:1080#Selected")
    // A hidden import keeps its own group, so this server is in another subscription.
    let other = try await importNode("#hide-url: yes\nsocks://127.0.0.1:1081#Other")
    try store.commitSelection(nodeID: selected.node)
    return (store, selected, other)
  }

  // Recovery may list servers of any subscription, and a manual choice keeps them as backups.
  static func crossSubscriptionRecoveryCheck(defaults: UserDefaults) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("elarni-cross-recovery-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let (store, selected, other) = try await twoSubscriptions(directory)
    try TunnelCommandCoordinator(defaults: defaults).persist(.disconnected)
    let manager = SwitchManager(plan: Data("{}".utf8))
    manager.fixtureSession.fixtureStatus = .disconnected
    let messenger = ControlMessenger()
    let controller = TunnelMethodChannel(messenger: messenger, defaults: defaults, observesSystem: false,
      makeSubscriptions: { store }, loadPreferences: { [manager] })
    defer { withExtendedLifetime(controller) {} }
    let savedSettings = defaults.data(forKey: "ElarniTunnelSettingsV1")
    defer {
      defaults.set(savedSettings, forKey: "ElarniTunnelSettingsV1")
      defaults.removeObject(forKey: TunnelMethodChannel.automationKey)
    }
    // Backups are checked only through a tunnel that carries all traffic.
    _ = try await messenger.call("updateTunnelSettings", arguments: ["includeAllNetworks": true])
    func target(_ id: String) -> [String: Any] {
      ["id": id, "url": "https://\(id).invalid/", "expectedStatus": 204, "expectedBody": ""]
    }
    let configured = try await messenger.call("configureAutomation", arguments: ["schemaVersion": 1, "enabled": true,
      "policy": "orderedFallback", "subscriptionID": selected.subscription, "nodeIDs": [selected.node, other.node],
      "russianEntryNodeIDs": [other.node], "targets": [target("one"), target("two")]])
    guard configured["whitelistMode"] as? Bool == false else {
      throw Failure(message: "the recovery status does not report whitelist mode")
    }
    _ = try await messenger.call("selectNode", arguments: ["id": other.node])
    let configuration = try await messenger.call("automationStatus")["configuration"] as? [String: Any]
    guard configuration?["policy"] as? String == "orderedFallback",
          configuration?["nodeIDs"] as? [String] == [other.node, selected.node],
          configuration?["russianEntryNodeIDs"] as? [String] == [other.node] else {
      throw Failure(message: "a manual choice did not keep the backups of another subscription: \(String(describing: configuration))")
    }
    print("PASS recovery lists servers of any subscription, and a manual choice keeps them as backups")
  }

  // A per-app server target names its server's keychain entry in the saved plan. A deleted one fails
  // the next Connect, not catalog changes while nothing runs, and a restore keeps the target.
  static func perAppTargetCheck(defaults: UserDefaults) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("elarni-per-app-targets-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let (store, selected, other) = try await twoSubscriptions(directory)
    try TunnelCommandCoordinator(defaults: defaults).persist(.disconnected)
    let manager = SwitchManager(plan: Data("{}".utf8))
    manager.fixtureSession.fixtureStatus = .disconnected
    manager.fixtureSession.startable = true
    let messenger = ControlMessenger()
    let controller = TunnelMethodChannel(messenger: messenger, defaults: defaults, observesSystem: false,
      makeSubscriptions: { store }, loadPreferences: { [manager] })
    defer { withExtendedLifetime(controller) {} }
    let savedSettings = defaults.data(forKey: "ElarniTunnelSettingsV1")
    defer {
      defaults.set(savedSettings, forKey: "ElarniTunnelSettingsV1")
      defaults.removeObject(forKey: TunnelMethodChannel.automationKey)
    }
    let apps = ["/Applications/A.app/", "/Applications/B.app/"]
    func update(_ targets: [String: String], mode: String = "bypass") async throws -> [String: Any] {
      try await messenger.call("updateTunnelSettings", arguments: ["xrayTunEnabled": true, "includeAllNetworks": false,
        "perAppMode": mode, "perAppProcesses": apps, "perAppTargets": targets])
    }
    func savedTargets() throws -> [String: String]? {
      let payload = (manager.protocolConfiguration as! NETunnelProviderProtocol).providerConfiguration!["planPayload"] as! Data
      let plan = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
      return (plan["settings"] as? [String: Any])?["perAppTargets"] as? [String: String]
    }
    let socksPort = try await messenger.call("tunnelSettings")["socksPort"] as! Int
    let otherRef = try store.outboundRef(nodeID: other.node)
    let invalid: [[String: String]] = [["/Applications/C.app/": "direct"], [apps[0]: "server:\(otherRef)"], [apps[0]: "node:"],
      [apps[0]: "proxy:socks5://192.0.2.1:1080"], [apps[0]: "proxy:socks5://user:secret@127.0.0.1:1080"],
      [apps[0]: "proxy:socks5://127.0.0.1"], [apps[0]: "proxy:socks5://127.0.0.1:\(socksPort)"]]
    for targets in invalid {
      do { _ = try await update(targets); throw Failure(message: "settings accepted the per-app target \(targets)") }
      catch let failure as Failure where failure.message == "updateTunnelSettings: invalid_settings" {}
    }
    let targets = [apps[0]: "node:\(other.node)", apps[1]: "proxy:socks5://127.0.0.1:1080"]
    let reply = try await update(targets)
    guard reply["perAppTargets"] as? [String: String] == targets,
          try savedTargets() == [apps[0]: "server:\(otherRef)", apps[1]: targets[apps[1]]!] else {
      throw Failure(message: "a per-app server target did not reach the saved plan as its keychain entry: \(String(describing: try savedTargets()))")
    }
    _ = try await update(targets, mode: "off")
    guard try savedTargets() == nil,
          try await messenger.call("tunnelSettings")["perAppTargets"] as? [String: String] == targets else {
      throw Failure(message: "per-app routing off sent its targets to the provider or lost them")
    }
    _ = try await update(targets)
    _ = try await messenger.call("deleteSubscription", arguments: ["id": other.subscription])
    _ = try await messenger.call("assignRoutingProfile", arguments: ["subscriptionId": selected.subscription])
    do { _ = try await messenger.call("connect"); throw Failure(message: "Connect accepted a deleted per-app target server") }
    catch let failure as Failure where failure.message == "connect: per_app_target_missing" {}
    guard manager.fixtureSession.starts == 0 else { throw Failure(message: "a deleted per-app target server started the tunnel") }
    print("PASS per-app server targets reach the plan by keychain entry; a deleted one fails Connect, not catalog changes")

    _ = try await messenger.call("disconnect")
    _ = try await update([apps[0]: "node:\(selected.node)"])
    let password = "per-app-target-check"
    let backup = try await messenger.call("exportCatalogBackup", arguments: ["password": password, "headless": true])["text"] as! String
    _ = try await messenger.call("restoreCatalogBackup", arguments: ["password": password, "headless": true, "content": backup])
    guard let restored = store.selectedNodeID(), restored != selected.node,
          try await messenger.call("tunnelSettings")["perAppTargets"] as? [String: String] == [apps[0]: "node:\(restored)"] else {
      throw Failure(message: "a restore did not follow the per-app target to its renumbered server")
    }
    print("PASS a catalog restore keeps per-app server targets on their renumbered servers")
  }

  // The log level reaches the extension through the shared container without a reconnect. A running
  // extension serves its lines; while it does not run, the app reads the lines it kept when it stopped.
  static func coreLogCheck(defaults: UserDefaults) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("elarni-core-log-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let (store, _, _) = try await twoSubscriptions(directory)
    try TunnelCommandCoordinator(defaults: defaults).persist(.connected)
    let manager = SwitchManager(plan: Data("{}".utf8))
    manager.fixtureSession.fixtureStatus = .connected
    let messenger = ControlMessenger()
    let controller = TunnelMethodChannel(messenger: messenger, defaults: defaults, observesSystem: false,
      makeSubscriptions: { store }, loadPreferences: { [manager] })
    let logs = directory.appendingPathComponent("Logs", isDirectory: true)
    controller.logsDirectory = { logs }
    defer { withExtendedLifetime(controller) {} }
    let savedSettings = defaults.data(forKey: "ElarniTunnelSettingsV1")
    defer {
      defaults.set(savedSettings, forKey: "ElarniTunnelSettingsV1")
      defaults.removeObject(forKey: TunnelMethodChannel.automationKey)
      try? TunnelCommandCoordinator(defaults: defaults).persist(.disconnected)
    }
    guard try await messenger.call("tunnelSettings")["logLevel"] as? String == "warning" else {
      throw Failure(message: "the log level does not default to warning")
    }
    do { _ = try await messenger.call("updateTunnelSettings", arguments: ["logLevel": "loud"]); throw Failure(message: "settings accepted an unknown log level") }
    catch let failure as Failure where failure.message == "updateTunnelSettings: invalid_settings" {}
    _ = try await messenger.call("updateTunnelSettings", arguments: ["logLevel": "debug"])
    guard manager.fixtureSession.fixtureStatus == .connected, manager.fixtureSession.starts == 0,
          (try? String(contentsOf: logs.appendingPathComponent("level"), encoding: .utf8)) == "debug" else {
      throw Failure(message: "a log level change reconnected or did not reach the shared container")
    }
    let running = try await messenger.call("readLogs", arguments: ["after": 4])
    guard manager.fixtureSession.logReads == [4], running["level"] as? String == "debug",
          (running["entries"] as? [[String: Any]])?.map({ $0["seq"] as? Int }) == [5] else {
      throw Failure(message: "a running extension did not serve its log: \(running)")
    }
    manager.fixtureSession.fixtureStatus = .disconnected
    let kept: [String: Any] = ["level": "warning", "last": 3, "entries": [1, 2, 3].map {
      ["seq": $0, "time": 1_700_000_000_000, "level": "warning", "text": "line \($0)"] as [String: Any] }]
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: kept).write(to: logs.appendingPathComponent("last.json"))
    let stopped = try await messenger.call("readLogs", arguments: ["after": 1])
    guard manager.fixtureSession.logReads == [4], stopped["level"] as? String == "debug", stopped["last"] as? Int == 3,
          (stopped["entries"] as? [[String: Any]])?.map({ $0["seq"] as? Int }) == [2, 3] else {
      throw Failure(message: "a stopped extension's kept log was not served: \(stopped)")
    }
    try FileManager.default.removeItem(at: logs.appendingPathComponent("last.json"))
    guard (try await messenger.call("readLogs"))["entries"] as? [Any] != nil else {
      throw Failure(message: "a missing kept log was not an empty one")
    }
    print("PASS the log level reaches the extension without a reconnect; a stopped extension's lines stay readable")
  }

  // A server of a subscription that is not selected gets its routing geofiles before its plan is saved.
  static func otherSubscriptionAssetsCheck(defaults: UserDefaults) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("elarni-other-assets-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let (store, _, other) = try await twoSubscriptions(directory)
    // The synthetic geosite of SubscriptionChecks; nothing is downloaded.
    func field(_ number: UInt8, _ bytes: Data) -> Data { Data([number << 3 | 2, UInt8(bytes.count)]) + bytes }
    func site(_ code: String, _ domain: String) -> Data {
      field(1, field(1, Data(code.utf8)) + field(2, Data([8, 3]) + field(2, Data(domain.utf8))))
    }
    store.routing.fetchGeofile = { _, _, file in
      try (site("TEST", "example.com") + site("UNUSED", "unused.example")).write(to: file)
      return (true, nil)
    }
    try store.routing.importProvider(#"{"Name":"Asset fixture","RemoteDNSType":"DoU","RemoteDNSIP":"1.1.1.1","DomesticDNSType":"DoU","DomesticDNSIP":"8.8.8.8","DirectSites":["geosite:TEST"],"Geositeurl":"https://fixture.invalid/geosite.dat","UseChunkFiles":"true"}"#,
      subscriptionID: other.subscription)
    try TunnelCommandCoordinator(defaults: defaults).persist(.disconnected)
    let manager = SwitchManager(plan: Data("{}".utf8))
    manager.fixtureSession.fixtureStatus = .disconnected
    let messenger = ControlMessenger()
    let controller = TunnelMethodChannel(messenger: messenger, defaults: defaults, observesSystem: false,
      makeSubscriptions: { store }, loadPreferences: { [manager] })
    defer { withExtendedLifetime(controller) {} }
    _ = try await messenger.call("selectNode", arguments: ["id": other.node])
    let saved = (manager.protocolConfiguration as! NETunnelProviderProtocol).providerConfiguration!["planPayload"] as! Data
    let plan = try JSONSerialization.jsonObject(with: saved) as! [String: Any]
    guard store.selectedNodeID() == other.node, plan["routingRevision"] is String else {
      throw Failure(message: "other subscription fixture: its routing is not in the saved plan")
    }
    guard plan["assetRevision"] is String else {
      throw Failure(message: "a server of another subscription was saved without its routing geofiles")
    }
    print("PASS selecting a server of another subscription prepares its routing geofiles")
  }

  // Connect on untrusted Wi-Fi arms On Demand before any Connect; a connection it starts becomes the
  // app's, and a Stop pauses the rule until the next Connect.
  static func untrustedWiFiCheck(store: SubscriptionStore, defaults: UserDefaults, plan: Data) async throws {
    let kept = ["ElarniTunnelSettingsV1", "ElarniConnectionIntentV1", TunnelMethodChannel.automationKey,
                "ElarniUntrustedWiFiArmedV1"].map { ($0, defaults.object(forKey: $0)) }
    defer { for (key, value) in kept { defaults.set(value, forKey: key) } }
    defaults.removeObject(forKey: TunnelMethodChannel.automationKey)
    try TunnelCommandCoordinator(defaults: defaults).persist(.disconnected)
    let manager = SwitchManager(plan: plan)
    manager.fixtureSession.fixtureStatus = .disconnected
    manager.fixtureSession.startable = true
    let messenger = ControlMessenger()
    let controller = TunnelMethodChannel(messenger: messenger, defaults: defaults, observesSystem: false,
      makeSubscriptions: { store }, loadPreferences: { [manager] })
    defer { withExtendedLifetime(controller) {} }
    func armed() -> Bool {
      guard manager.isOnDemandEnabled, let rules = manager.onDemandRules, rules.count == 3 else { return false }
      return rules[0].action == .ignore && rules[0].interfaceTypeMatch == .wiFi && rules[0].ssidMatch == ["Home"] &&
        rules[1].action == .connect && rules[1].interfaceTypeMatch == .wiFi && rules[1].ssidMatch == nil &&
        rules[2].action == .ignore && rules[2].interfaceTypeMatch == .any
    }
    let tooLong = try? await messenger.call("updateTunnelSettings",
      arguments: ["connectOnUntrustedWiFi": true, "trustedWiFiNetworks": [String(repeating: "x", count: 33)]])
    guard tooLong == nil, !manager.isOnDemandEnabled else {
      throw Failure(message: "a 33-byte trusted Wi-Fi name was accepted")
    }
    let saved = try await messenger.call("updateTunnelSettings",
      arguments: ["connectOnUntrustedWiFi": true, "trustedWiFiNetworks": ["Home"]])
    guard saved["connectOnUntrustedWiFi"] as? Bool == true, saved["trustedWiFiNetworks"] as? [String] == ["Home"],
          armed(), manager.fixtureSession.starts == 0, manager.fixtureSession.fixtureStatus == .disconnected else {
      throw Failure(message: "turning Connect on untrusted Wi-Fi on did not arm its On Demand rules while stopped")
    }
    let payload = (manager.protocolConfiguration as! NETunnelProviderProtocol).providerConfiguration!["planPayload"] as! Data
    let planSettings = (try JSONSerialization.jsonObject(with: payload) as! [String: Any])["settings"] as? [String: Any]
    guard planSettings?["connectOnUntrustedWiFi"] == nil, planSettings?["trustedWiFiNetworks"] == nil else {
      throw Failure(message: "the provider plan carries the Wi-Fi rule")
    }
    // The system starts the tunnel on an untrusted network; the app takes it over and keeps the rule.
    manager.fixtureSession.fixtureStatus = .connected
    let adopted = try await messenger.call("state")
    guard adopted["connectionIntent"] as? String == "connected", armed() else {
      throw Failure(message: "a connection On Demand started was not taken over: \(adopted["connectionIntent"] ?? "none")")
    }
    _ = try await messenger.call("disconnect")
    _ = try await messenger.call("state")
    guard !manager.isOnDemandEnabled, manager.fixtureSession.fixtureStatus == .disconnected else {
      throw Failure(message: "a Stop left the untrusted Wi-Fi rule armed")
    }
    _ = try await messenger.call("connect")
    guard armed(), manager.fixtureSession.starts == 1 else {
      throw Failure(message: "a Connect did not re-arm the untrusted Wi-Fi rule")
    }
    _ = try await messenger.call("disconnect")
    _ = try await messenger.call("updateTunnelSettings", arguments: ["connectOnUntrustedWiFi": false])
    _ = try await messenger.call("updateTunnelSettings", arguments: ["connectOnUntrustedWiFi": true])
    guard armed(), manager.fixtureSession.fixtureStatus == .disconnected else {
      throw Failure(message: "turning the rule off and on after a Stop did not arm it again")
    }
    _ = try await messenger.call("updateTunnelSettings", arguments: ["connectOnUntrustedWiFi": false])
    guard !manager.isOnDemandEnabled else { throw Failure(message: "turning the rule off left On Demand on") }
    print("PASS Connect on untrusted Wi-Fi arms On Demand while stopped, takes over its connection and pauses after a Stop")
  }

  // A manual server choice while connected under a pinned automation server switches to it.
  static func fixedAutomationSelectionCheck(store: SubscriptionStore, defaults: UserDefaults, plan: Data,
                                            pinned: String, other: String) async throws {
    try TunnelCommandCoordinator(defaults: defaults).persist(.connected)
    let subscription = try store.subscriptionID(nodeID: pinned)
    let manager = SwitchManager(plan: plan)
    let messenger = ControlMessenger()
    let controller = TunnelMethodChannel(messenger: messenger, defaults: defaults, observesSystem: false,
      makeSubscriptions: { store }, loadPreferences: { [manager] })
    defer { withExtendedLifetime(controller) {} }
    _ = try await messenger.call("configureAutomation", arguments: ["schemaVersion": 1, "enabled": true,
      "policy": "fixed", "subscriptionID": subscription, "nodeIDs": [pinned],
      "targets": [["id": "fixture", "url": "https://fixture.invalid/", "expectedStatus": 204, "expectedBody": ""]]])
    do { _ = try await messenger.call("selectNode", arguments: ["id": other]) }
    catch let failure as Failure { throw Failure(message: "manual choice under a pinned server: \(failure.message)") }
    guard store.selectedNodeID() == other, manager.fixtureSession.switches == 1 else {
      throw Failure(message: "a manual choice under a pinned server did not switch the connected provider")
    }
    print("PASS a manual server choice under a pinned automation server switches the connected tunnel")
  }
}

final class SwitchManager: NETunnelProviderManager {
  let fixtureSession = SwitchSession()
  var pauseSave = false
  var pendingSave: ((Error?) -> Void)?
  init(plan: Data) {
    super.init()
    let configuration = NETunnelProviderProtocol()
    configuration.providerBundleIdentifier = "com.elarni.mac.packet-tunnel"
    configuration.providerConfiguration = ["planPayload": plan]
    protocolConfiguration = configuration
    fixtureSession.owner = self
  }
  required init?(coder: NSCoder) { fatalError("unused fixture initializer") }
  override var connection: NEVPNConnection { fixtureSession }
  override func saveToPreferences(completionHandler: ((Error?) -> Void)? = nil) {
    if pauseSave { pendingSave = completionHandler; pauseSave = false }
    else { completionHandler?(nil) }
  }
  func resumeSave() { let callback = pendingSave; pendingSave = nil; callback?(nil) }
  override func loadFromPreferences(completionHandler: @escaping (Error?) -> Void) { completionHandler(nil) }
  override func removeFromPreferences(completionHandler: ((Error?) -> Void)? = nil) { completionHandler?(nil) }
}

final class SwitchSession: NETunnelProviderSession {
  var fixtureStatus: NEVPNStatus = .connected
  var switches = 0
  var switchCode = "switched"
  var stopCode = "stopped"
  var startable = false
  var starts = 0
  var logReads: [Int] = []
  weak var owner: NEVPNManager?
  // As the system does, a stop under a Connect rule shows disconnected once, then the tunnel is back.
  var onDemandRestarts = 0
  private var demandPending = false
  override var status: NEVPNStatus {
    defer {
      if demandPending { demandPending = false; onDemandRestarts += 1; fixtureStatus = .connected }
    }
    return fixtureStatus
  }
  override func stopVPNTunnel() {
    fixtureStatus = .disconnected
    demandPending = owner?.isOnDemandEnabled == true && owner?.onDemandRules?.contains { $0.action == .connect } == true
  }
  override func startVPNTunnel() throws {
    guard startable else { fatalError("selection recovery must not start a VPN") }
    starts += 1
    fixtureStatus = .connected
  }
  override func sendProviderMessage(_ messageData: Data, responseHandler: ((Data?) -> Void)? = nil) throws {
    let identity: [String: Any] = ["instanceID": "fixture", "generation": 1]
    if messageData == Data("state".utf8) {
      responseHandler?(try JSONSerialization.data(withJSONObject: identity)); return
    }
    let request = try JSONSerialization.jsonObject(with: messageData) as! [String: Any]
    var response = identity
    switch request["operation"] as? String {
    case "switch":
      switches += 1
      response = ["code": switchCode, "digest": (request["envelope"] as! [String: Any])["digest"]!]
    case "prepareStop": response["code"] = stopCode
    case "cancelSwitch": response = [:]
    case "logs":
      let after = request["after"] as! Int
      logReads.append(after)
      response = ["level": "warning", "last": after + 1,
                  "entries": [["seq": after + 1, "time": 1_700_000_000_000, "level": "info", "text": "fixture"]]]
    default: throw NativeControlChecks.Failure(message: "unexpected fixture provider operation")
    }
    responseHandler?(try JSONSerialization.data(withJSONObject: response))
  }
}

// Every OS preference operation is overridden; this manager has no real profile.
final class ControlManager: NETunnelProviderManager {
  let fixtureConnection = ControlConnection()
  var saved = false
  var removed = false
  var failRemoval = true
  override var connection: NEVPNConnection { fixtureConnection }
  override func saveToPreferences(completionHandler: ((Error?) -> Void)? = nil) {
    saved = true
    completionHandler?(nil)
  }
  override func loadFromPreferences(completionHandler: @escaping (Error?) -> Void) { completionHandler(nil) }
  override func removeFromPreferences(completionHandler: ((Error?) -> Void)? = nil) {
    if failRemoval { completionHandler?(NSError(domain: NEVPNErrorDomain, code: 5)) }
    else { removed = true; completionHandler?(nil) }
  }
}

final class ControlConnection: NEVPNConnection {
  var fixtureStatus: NEVPNStatus = .disconnected
  override var status: NEVPNStatus { fixtureStatus }
  override func stopVPNTunnel() { fatalError("fixture connection is already stopped") }
}

final class ControlMessenger: NSObject, FlutterBinaryMessenger {
  var handler: FlutterBinaryMessageHandler?
  func send(onChannel channel: String, message: Data?) {}
  func send(onChannel channel: String, message: Data?, binaryReply callback: FlutterBinaryReply?) { callback?(nil) }
  func setMessageHandlerOnChannel(_ channel: String, binaryMessageHandler handler: FlutterBinaryMessageHandler?) -> FlutterBinaryMessengerConnection {
    self.handler = handler
    return 1
  }
  func cleanUpConnection(_ connection: FlutterBinaryMessengerConnection) { handler = nil }

  @MainActor
  func call(_ method: String, arguments: [String: Any] = [:]) async throws -> [String: Any] {
    let codec = FlutterStandardMethodCodec.sharedInstance()
    let response: Data? = await withCheckedContinuation { continuation in
      handler?(codec.encode(FlutterMethodCall(methodName: method, arguments: arguments))) {
        continuation.resume(returning: $0)
      }
    }
    guard let response else { throw NativeControlChecks.Failure(message: "missing \(method) reply") }
    let value = codec.decodeEnvelope(response)
    if let error = value as? FlutterError { throw NativeControlChecks.Failure(message: "\(method): \(error.code)") }
    guard let result = value as? [String: Any] else { throw NativeControlChecks.Failure(message: "invalid \(method) reply") }
    return result
  }
}
