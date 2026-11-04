import CryptoKit
import Foundation
import Network
import Observation
import Security
import UIKit
import UserNotifications

@MainActor @Observable
final class IOSAppModel {
  /// The app's model; Shortcuts and Control Center reach it too. Unit tests swap in their own.
  static var shared = IOSAppModel()
  let vpn = IOSVPNController()
  private(set) var subscriptions: [ServerSubscription] = []
  private(set) var routingProfiles: [RoutingProfile] = []
  private(set) var assignments: [String: String] = [:]
  private(set) var selectedID: String?
  private(set) var preferences = IOSPreferences()
  private(set) var settings = IOSTunnelSettings()
  private(set) var probes: [String: ProbeResult] = [:]
  private(set) var exits: [String: ExitResult] = [:]
  private(set) var exitFailures = Set<String>()
  /// Changes with every catalog reload, so that views can keep what they derive from it.
  private(set) var catalogRevision = 0
  @ObservationIgnored private var nodesCache: (revision: Int, nodes: [ServerNode]) = (-1, [])
  private(set) var busyCount = 0
  private(set) var loaded = false
  private(set) var lastCheck: Date?
  private(set) var recoveryStatus = String(localized: "Off")
  private(set) var whitelistMode = false
  private(set) var testingIDs = Set<String>()
  private(set) var probeQuarantined = false
  private(set) var networkInfo: [String: String] = [:]
  var errorMessage: String?
  private(set) var recentIssues: [RecentIssue] = []
  var errorPresenters: [UUID] = []
  var notice: String?
  var approval: SubscriptionSafetyWarning?
  @ObservationIgnored private var approvalFormats: [String: String] = [:]
  var incomingText: String?
  var linkStopRequested = false
  var selectedTab = 0
  @ObservationIgnored private var store: SubscriptionStore?
  @ObservationIgnored private var startup: Task<Void, Never>?
  @ObservationIgnored private var directory: URL?
  @ObservationIgnored private var commands: TunnelCommandCoordinator
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private var maintenance: Task<Void, Never>?
  @ObservationIgnored private var probeTask: Task<Void, Never>?
  @ObservationIgnored private var foreground = false
  @ObservationIgnored private var recovery = AutomationPolicy()
  @ObservationIgnored private let pathMonitor = NWPathMonitor()
  @ObservationIgnored private var reminderSnapshot: String?
  @ObservationIgnored private var isolation: String?
  @ObservationIgnored private var tunnelChanges: [UUID: Task<Void, Error>] = [:]
  @ObservationIgnored private var backgroundTime = UIBackgroundTaskIdentifier.invalid
  @ObservationIgnored private var sawConnected = false

  var busy: Bool { busyCount > 0 }
  var nodes: [ServerNode] {
    if nodesCache.revision != catalogRevision { nodesCache = (catalogRevision, subscriptions.flatMap(\.nodes)) }
    return nodesCache.nodes
  }
  var selected: ServerNode? { nodes.first { $0.id == selectedID } }
  var selectedSubscription: ServerSubscription? { subscriptions.first { $0.id == selected?.subscriptionID } }

  init() {
#if DEBUG
    let args = ProcessInfo.processInfo.arguments
    if let index = args.firstIndex(of: "--ui-testing"), args.indices.contains(index + 1), UUID(uuidString: args[index + 1]) != nil {
      isolation = args[index + 1]
    }
#endif
    let defaults = isolation.flatMap { UserDefaults(suiteName: "elarni.ios.tests.\($0)") } ?? .standard
    self.defaults = defaults
    commands = TunnelCommandCoordinator(defaults: defaults)
    vpn.untrustedWiFiArmed = { [weak self] in self?.untrustedWiFiArmed ?? false }
  }

  func start() async {
    guard !loaded else { return }
    if let startup { await startup.value; return }
    let task = Task { @MainActor in await self.initialize() }
    startup = task
    await task.value
    startup = nil
  }

  private func initialize() async {
    do {
      let root: URL
#if targetEnvironment(simulator)
      root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        .appendingPathComponent(isolation.map { "UITests-\($0)" } ?? "Elarni", isDirectory: true)
#else
      guard let shared = IOSPlatform.containerURL else { throw IOSPlatformError.signingRequired }
      root = shared
#endif
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      directory = root
      preferences = try read(IOSPreferences.self, name: "ios-preferences.json") ?? IOSPreferences()
      recovery = AutomationPolicy(savedEpisode: try read(AutomationPolicy.Episode.self, name: "ios-recovery.json"))
      settings = try read(IOSTunnelSettings.self, name: "ios-settings.json") ?? IOSTunnelSettings()
      try settings.validate()
      // The old 256 TCP / 128 UDP defaults refuse new flows, DNS queries first, under daily load.
      // Raise them once; a value the user picks afterwards is kept.
      if !defaults.bool(forKey: "ElarniSessionLimitsMigrated") {
        var raised = settings
        if raised.tcpMaxConnections == 256 { raised.tcpMaxConnections = 2_048 }
        if raised.udpMaxConnections == 128 { raised.udpMaxConnections = 1_024 }
        if raised != settings { try write(raised, name: "ios-settings.json"); settings = raised }
        defaults.set(true, forKey: "ElarniSessionLimitsMigrated")
      }
      let routing = try RoutingStore(directory: root.appendingPathComponent("Routing", isDirectory: true))
      var access = SubscriptionSecretAccess()
#if targetEnvironment(simulator)
      // Simulator has no provisioned shared Keychain. Use its app-only Keychain;
      // device and extension builds always require the actual signed access group.
      func localQuery(_ value: CFDictionary) -> CFDictionary {
        let result = (value as NSDictionary).mutableCopy() as! NSMutableDictionary
        result.removeObject(forKey: kSecAttrAccessGroup)
        return result as CFDictionary
      }
      access.accessGroup = { "simulator.com.elarni.ios.shared" }
      access.add = { SecItemAdd(localQuery($0), $1) }
      access.copy = { SecItemCopyMatching(localQuery($0), $1) }
      access.update = { SecItemUpdate(localQuery($0), $1) }
      access.delete = { SecItemDelete(localQuery($0)) }
#endif
      let catalog = try SubscriptionStore(directory: root, routing: routing, secretAccess: access)
      store = catalog
      catalog.autoUpdateInterval = { [weak self] in Double(self?.preferences.autoUpdateHours ?? 4) * 3600 }
      catalog.previewContext = { [weak self] in
        guard let self else { return "" }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self.settings).base64EncodedString()) ?? "unavailable"
      }
      catalog.compilePreview = { [weak self] config, routes, preference in
        guard let self else { throw IOSAppError.busy }
        return try self.compile(config, routes: routes, preference: preference, port: self.settings.socksPort)
      }
      catalog.publishRefresh = { [weak self] candidate in
        guard let self else { throw IOSAppError.busy }
        try await self.publish(candidate)
      }
      routing.publishManaged = { [weak self] candidate in
        guard let self else { throw IOSAppError.busy }
        try await self.commitRouting { routing in try routing.publish(candidate) }
      }
      try await vpn.load()
      if catalog.runtimeReconciliationRequired {
        if vpn.active { notice = String(localized: "A previous update was interrupted. Disconnect to finish catalog recovery.") }
        else { try await vpn.clearSavedPlan(); try catalog.finishRuntimeReconciliation() }
      }
      reload()
      reconcileRecovery()
      loaded = true
      pathMonitor.pathUpdateHandler = { [weak self] path in
        let signature = path.availableInterfaces.map { "\($0.type):\($0.index)" }.sorted().joined(separator: ",")
        Task { @MainActor in
          guard let self else { return }
          self.networkInfo = ["Status": path.status == .satisfied ? String(localized: "Available") : String(localized: "Unavailable"),
            "Interfaces": path.availableInterfaces.map { "\($0.type) (\($0.name))" }.joined(separator: ", "),
            "Gateways": path.gateways.map { "\($0)" }.joined(separator: ", "),
            "IPv4": path.supportsIPv4 ? String(localized: "Supported") : String(localized: "Unavailable"), "IPv6": path.supportsIPv6 ? String(localized: "Supported") : String(localized: "Unavailable"),
            "Constrained": path.isConstrained ? String(localized: "Yes") : String(localized: "No"), "Expensive": path.isExpensive ? String(localized: "Yes") : String(localized: "No")]
          if self.recovery.pathChanged(signature, available: path.status == .satisfied, now: ProcessInfo.processInfo.systemUptime) {
            self.commands.invalidateAutomatic()
          }
        }
      }
      pathMonitor.start(queue: DispatchQueue(label: "elarni.ios.path"))
    } catch { show(error) }
  }

  func setForeground(_ active: Bool) {
    foreground = active
    maintenance?.cancel(); maintenance = nil
    guard active else {
      store?.cancelRefreshes(); store?.routing.cancelManagedRefreshes(); probeTask?.cancel()
      commands.invalidateAutomatic()
      if !tunnelChanges.isEmpty { holdBackgroundTime() }
      return
    }
    maintenance = Task { [weak self] in
      guard let self else { return }
      await self.start()
      while !Task.isCancelled {
        await self.tick()
        do { try await Task.sleep(for: .seconds(2)) } catch { break }
      }
    }
  }

  private func tick() async {
    guard loaded else { return }
    try? await vpn.refreshProvider()
    adoptUntrustedWiFiConnection()
    noteUnexpectedDisconnect()
    guard !busy, let store else { return }
    for id in store.dueSubscriptions() {
      guard foreground, !Task.isCancelled else { return }
      _ = await perform(automatic: true, reportError: false) {
        _ = try await store.refresh(id: id, interactive: false)
      }
    }
    for item in store.routing.dueManagedSources() {
      guard foreground, !Task.isCancelled else { return }
      _ = await perform(automatic: true, reportError: false) { try await store.routing.refreshManaged(id: item.profileID, sourceID: item.sourceID) }
    }
    for id in store.routing.dueGeofiles() {
      guard foreground, !Task.isCancelled else { return }
      _ = await perform(automatic: true, reportError: false) { _ = try await store.routing.refreshGeofiles(id: id) }
    }
    await refreshReminders()
    await recoverIfNeeded()
  }

  @discardableResult
  func perform(intent: TunnelCommandCoordinator.Intent? = nil, automatic: Bool = false,
               reportError: Bool = true, _ action: @escaping @MainActor () async throws -> Void) async -> Bool {
    busyCount += 1
    defer { busyCount -= 1; reload(); reconcileRecovery() }
    do {
      try await commands.perform(intent: intent, automatic: automatic) {
        try await action()
        self.reclaimRoutingFiles()
      }
      return true
    } catch is CancellationError { return false }
    catch { if reportError { show(error) }; return false }
  }

  /// Deletes route models and asset revisions that neither the catalog nor the saved plan names.
  /// A running provider may read any of them, so this waits until it has stopped.
  private func reclaimRoutingFiles() {
    guard loaded, let store, !vpn.active, !store.publicationInProgress,
          !store.publicationRecoveryRequired, !store.runtimeReconciliationRequired else { return }
    var routes = Set<String>(), assets = Set<String>()
    if let saved = vpn.savedPlan {
      // Retain every file when the saved plan cannot say which ones it needs.
      guard let plan = try? JSONDecoder().decode(TunnelPlan.self, from: saved) else { return }
      if let name = plan.routingRevision { routes.insert(name) }
      if let revision = plan.assetRevision { assets.insert(revision) }
    }
    // A failed reclaim keeps the remaining files; the next command retries.
    try? store.routing.reclaimUnusedFiles(routeNames: routes, assetRevisions: assets)
  }

  func launch(_ action: @escaping @MainActor () async throws -> Void) {
    Task { await perform(action) }
  }

  /// Runs a tunnel change to its end or rollback even when backgrounding, a network change,
  /// a refresh cancel or the recovery deadline cancels the caller: stopping between
  /// disconnect and reconnect would leave the VPN off. Only an explicit Stop cancels it.
  private func changingTunnel(_ change: @escaping @MainActor () async throws -> Void) async throws {
    try Task.checkCancellation()
    let id = UUID()
    let task = Task { @MainActor in try await change() }
    tunnelChanges[id] = task
    if !foreground { holdBackgroundTime() }
    defer {
      tunnelChanges.removeValue(forKey: id)
      if tunnelChanges.isEmpty { releaseBackgroundTime() }
    }
    try await task.value
  }

  // iOS suspends the app soon after it leaves the screen; finish the change first.
  private func holdBackgroundTime() {
    guard backgroundTime == .invalid else { return }
    // The expiration handler runs on the main thread and must end the task before returning.
    backgroundTime = UIApplication.shared.beginBackgroundTask(withName: "Elarni connection change") { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.releaseBackgroundTime()
      }
    }
  }

  private func releaseBackgroundTime() {
    guard backgroundTime != .invalid else { return }
    UIApplication.shared.endBackgroundTask(backgroundTime)
    backgroundTime = .invalid
  }

  /// Reports a VPN that went down without the user's Stop, while the app was open or suspended.
  /// On Demand connected an untrusted Wi-Fi network; that connection is the app's from now on.
  func adoptUntrustedWiFiConnection() {
    if vpn.connected, commands.intent != .connected, untrustedWiFiArmed, !busy { try? commands.persist(.connected) }
  }

  private func noteUnexpectedDisconnect() {
    if vpn.connected { sawConnected = true; return }
    guard sawConnected, !vpn.active, !busy else { return }
    sawConnected = false
    guard commands.intent == .connected else { return }
    notice = String(localized: "Elarni disconnected without a Stop from you. Tap Connect to reconnect.") +
      (settings.onDemandEnabled || settings.includeAllNetworks ? "" : String(localized: " Turn on On Demand in Settings › General so iOS reconnects it automatically."))
  }

  /// Disconnect alerts come from the VPN extension under the app's notification permission.
  private func requestAlertPermission() async {
    let center = UNUserNotificationCenter.current()
    guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
    _ = try? await center.requestAuthorization(options: [.alert, .sound])
  }

  private func catalog() throws -> SubscriptionStore {
    guard let store else { throw IOSPlatformError.signingRequired }
    return store
  }

  func reload() {
    guard let store else { return }
    let snapshot = store.snapshot()
    subscriptions = (snapshot["subscriptions"] as? [[String: Any]] ?? []).map(ServerSubscription.init(raw:))
    catalogRevision &+= 1
    selectedID = snapshot["selectedNodeId"] as? String
    let routes = store.routing.snapshot()
    routingProfiles = (routes["profiles"] as? [[String: Any]] ?? []).map(RoutingProfile.init(raw:))
    assignments = routes["assignments"] as? [String: String] ?? [:]
  }

  // Allowed servers may come from any subscription.
  private func recoverySelectionExists(_ config: AutomationConfiguration) -> Bool {
    guard let selected, config.nodeIDs.contains(selected.id) else { return false }
    return config.nodeIDs.allSatisfy { id in nodes.contains { $0.id == id && $0.format != "telegram" } }
  }

  private func reconcileRecovery() {
    guard preferences.automation.enabled, !recoverySelectionExists(preferences.automation) else { return }
    preferences.automation.enabled = false
    recovery.stop()
    commands.invalidateAutomatic()
    recoveryStatus = String(localized: "Off — allowed servers changed")
    notice = String(localized: "Automatic recovery was turned off because an allowed server was removed. Review the servers in Settings.")
    do { try write(preferences, name: "ios-preferences.json"); try saveEpisode() }
    catch { show(error) }
  }

  func importInput(_ content: String) async throws {
    let store = try catalog()
    guard content.utf8.count <= 4 * 1024 * 1024 else { throw IOSAppError.invalidFile }
    if RoutingDomainDecoder.isRoutingInput(content) {
      try await editRouting { _ = try $0.importContent(content, selectedSubscriptionID: store.selectedSubscriptionID()) }
      selectedTab = 3
    } else {
      let id = try store.registerProfiles(content)
      try await refresh(id)
      if store.selectedNodeID() == nil,
         let source = (store.snapshot()["subscriptions"] as? [[String: Any]])?.first(where: { $0["id"] as? String == id }),
         let first = (source["nodes"] as? [[String: Any]])?.first(where: { $0["format"] as? String != "telegram" }),
         let node = first["id"] as? String { try store.commitSelection(nodeID: node) }
      selectedTab = 0
    }
    reload()
  }

  func refresh(_ id: String, challenge: String? = nil, format: String? = nil) async throws {
    let store = try catalog()
    // The approval prompt answers with the challenge alone; keep the format that asked for it.
    let format = format ?? (challenge == nil ? nil : approvalFormats[id])
    let result: SubscriptionOperationResult
    do { result = try await store.refresh(id: id, challenge: challenge, format: format) }
    catch let error as SubscriptionError {
      // A failed download names its provider, so the provider's outages are not reported as app bugs.
      guard case .fetchClass(let code) = error, let name = subscriptions.first(where: { $0.id == id })?.name else { throw error }
      let text = switch code {
      case "provider_unreachable": String(localized: "\(name)’s server did not answer. Your network may block it, or it is down. Retry later or ask the provider for a mirror.")
      case "provider_error": String(localized: "\(name)’s server reported an error. Nothing is wrong with Elarni or this device; retry later.")
      case "rate_limited": String(localized: "\(name) is limiting requests. Elarni retries later; wait before refreshing again.")
      case "subscription_denied": String(localized: "\(name) refused the request. The subscription may have expired, run out of traffic or reached its device limit. Contact the provider.")
      case "subscription_unavailable": String(localized: "\(name) removed or changed this link. Ask the provider for a new one.")
      default: describe(error)
      }
      throw IOSAppError.refreshFailed(text + String(localized: " The last working servers were kept."))
    }
    approvalFormats[id] = result.warning == nil ? nil : format
    // Another subscription's success must not hide a pending prompt.
    if result.warning != nil || approval?.subscriptionID == id { approval = result.warning }
  }

  /// Pull to refresh stops at a subscription that needs approval, as on Android.
  func refreshAll() async {
    for source in subscriptions where !source.local {
      _ = await perform { try await self.refresh(source.id) }
      if approval != nil { return }
    }
  }

  func rename(_ group: ServerSubscription, name: String) throws { _ = try catalog().rename(id: group.id, name: name) }
  func delete(_ group: ServerSubscription) async throws {
    let store = try catalog()
    if store.removesSelection(subscriptionID: group.id) {
      try await vpn.disconnect(); try await vpn.clearSavedPlan()
      try commands.persist(.disconnected); recovery.stop(); try saveEpisode()
    }
    // A provider's routing profile goes with it, also where the selected server's
    // subscription uses it; the tunnel must not keep those rules (as on macOS).
    let revision = try store.routing.runtimeRevision(subscriptionID: store.selectedSubscriptionID())
    try await changingTunnel { [self] in
      let previous = vpn.savedPlan
      let wasConnected = vpn.connected
      let waiting = onDemandWaiting
      var synchronized = false
      do {
        _ = try await store.delete(id: group.id) {
          guard store.selectedNodeID() != nil,
                try store.routing.runtimeRevision(subscriptionID: store.selectedSubscriptionID()) != revision else { return }
          synchronized = true
          try await self.synchronize()
        }
      } catch {
        try Task.checkCancellation()
        // The deletion rolled back its routing; the tunnel goes back with it, as after a refused publish.
        if synchronized, wasConnected, let previous {
          if !IOSVPNController.keptPreviousPlan(error) {
            try await vpn.replacePlan(previous, settings: settings)
            try await vpn.persist(previous, settings: settings, allowOnDemand: commands.intent == .connected)
          }
        } else if synchronized, waiting, let previous { try await vpn.persist(previous, settings: settings, allowOnDemand: commands.intent == .connected) }
        throw error
      }
    }
  }
  func setFavorite(_ node: ServerNode) throws { _ = try catalog().setFavorite(nodeID: node.id, favorite: !node.favorite) }
  func renameNode(_ node: ServerNode, name: String) throws { _ = try catalog().renameNode(id: node.id, name: name) }
  func showNode(id: String) throws { _ = try catalog().showNode(id: id) }
  func deviceID(subscriptionID: String) throws -> String { try catalog().deviceID(subscriptionID: subscriptionID) }
  func resetDeviceID(subscriptionID: String) throws { _ = try catalog().resetDeviceID(subscriptionID: subscriptionID) }
  func deleteNode(_ node: ServerNode) throws { try deleteNodes([node]) }
  /// Hides provider servers and deletes local ones, all or none.
  func deleteNodes(_ values: [ServerNode]) throws {
    let ids = values.map(\.id)
    _ = try catalog().deleteNodes(ids: ids)
    // Recovery requires every listed server, so it keeps the rest; one left is fixed recovery.
    guard preferences.automation.nodeIDs.contains(where: ids.contains) else { return }
    var next = preferences
    next.automation.nodeIDs.removeAll { ids.contains($0) }
    if next.automation.nodeIDs.count < 2 { next.automation.policy = .fixed }
    reload()
    try savePreferences(next)
  }
  func setIP(_ node: ServerNode, value: String) async throws {
    _ = try await catalog().setNodeIPPreference(nodeID: node.id, preference: value == "inherit" ? nil : value)
  }
  func selectGroup(_ node: ServerNode, group: String, value: String) async throws {
    _ = try await catalog().selectProfileGroup(nodeID: node.id, group: group, choice: value)
  }
  func updateFetch(_ id: String, options: [String: Any]) throws { _ = try catalog().updateFetchOptions(id: id, options: options) }
  func share(id: String, subscription: Bool) throws -> String { try catalog().sharingText(id: id, subscription: subscription) }
  func shareLinks(_ group: ServerSubscription, nodeIDs: [String]) throws -> String { try catalog().shareLinks(subscriptionID: group.id, nodeIDs: nodeIDs) }
  func linkableNodeIDs(_ group: ServerSubscription) -> Set<String> { (try? catalog().linkableNodeIDs(subscriptionID: group.id)) ?? [] }
  func providerURL(_ group: ServerSubscription, action: String) throws -> URL { try catalog().providerURL(subscriptionID: group.id, action: action) }
  func telegramURL(_ node: ServerNode) throws -> URL { try catalog().telegramURL(nodeID: node.id) }

  func select(_ node: ServerNode, manual: Bool = true) async throws {
    let store = try catalog()
    guard node.format != "telegram" else { throw IOSAppError.invalidSettings }
    // On Demand starts the saved plan while it waits, so the new choice must be saved too.
    let waiting = onDemandWaiting
    if vpn.connected || waiting {
      try await changingTunnel { [self] in
        let plan = try await makePlan(nodeID: node.id)
        let previous = vpn.savedPlan
        try store.beginSelectionPublication()
        do {
          if !waiting { try await vpn.replacePlan(plan, settings: settings) }
          try await vpn.persist(plan, settings: settings, allowOnDemand: commands.intent == .connected)
          try store.finishSelectionPublication(nodeID: node.id)
        } catch {
          try store.rollbackPublication(recoveringAfterInterruption: true)
          try Task.checkCancellation()
          // A refused switch left the previous plan running and saved; switching back would restart it.
          if IOSVPNController.keptPreviousPlan(error) { try store.finishRuntimeReconciliation() }
          else if let previous {
            do {
              if !waiting { try await vpn.replacePlan(previous, settings: settings) }
              try await vpn.persist(previous, settings: settings, allowOnDemand: commands.intent == .connected)
              try store.finishRuntimeReconciliation()
            } catch { throw IOSAppError.switchRestoreFailed }
          }
          throw error
        }
      }
    } else {
      guard !vpn.active else { throw IOSAppError.busy }
      try store.commitSelection(nodeID: node.id)
    }
    reload()
    if manual {
      recovery.invalidate(configuration: true)
      // The picked server becomes the primary; the allowed backups stay.
      if preferences.automation.enabled {
        var next = preferences
        let backups = next.automation.policy == .fixed ? [] : next.automation.nodeIDs.filter { $0 != node.id }.prefix(999)
        next.automation.subscriptionID = node.subscriptionID; next.automation.nodeIDs = [node.id] + backups
        next.automation.russianEntryNodeIDs = next.automation.russianEntryNodeIDs?.filter(next.automation.nodeIDs.contains)
        try savePreferences(next)
      }
    }
    reload()
  }

  func connect() async {
    probeTask?.cancel()
    let connected = await perform(intent: .connected) {
      guard !self.vpn.active else { throw IOSAppError.busy }
      IOSConnectionAlerts.clear()
      try await self.changingTunnel { [self] in
        let store = try catalog()
        guard var id = store.selectedNodeID() else { throw IOSAppError.noSelection }
        let original = id
        recovery.rearm(now: ProcessInfo.processInfo.systemUptime)
        try saveEpisode()
        if preferences.automation.enabled, preferences.automation.policy == .lowestLatency, !vpn.active {
          id = try await chooseBeforeConnecting(current: id)
          try Task.checkCancellation()
        }
        let plan = try await makePlan(nodeID: id)
        if id != original { try store.beginSelectionPublication() }
        do {
          try await vpn.connect(plan, settings: settings)
          try Task.checkCancellation()
          if id != original { try store.finishSelectionPublication(nodeID: id) }
        } catch {
          if id != original {
            try store.rollbackPublication(recoveringAfterInterruption: true)
            // Cancellation leaves the durable journal for Stop/startup to reconcile.
            try Task.checkCancellation()
            try await vpn.disconnect()
            try await vpn.clearSavedPlan()
            try store.finishRuntimeReconciliation()
          }
          throw error
        }
        reload()
        recoveryStatus = String(localized: "Connected, awaiting check")
      }
    }
    if connected { await requestAlertPermission() }
  }

  func disconnect() async {
    probeTask?.cancel(); store?.cancelRefreshes(); store?.routing.cancelManagedRefreshes()
    for change in tunnelChanges.values { change.cancel() }
    await perform(intent: .disconnected) {
      self.recovery.stop(); self.recoveryStatus = String(localized: "Stopped")
      try self.saveEpisode()
      try await self.vpn.disconnect()
      // A switch this Stop interrupted may have posted a "connection lost" alert.
      IOSConnectionAlerts.clear()
      if let store = self.store, store.runtimeReconciliationRequired {
        try await self.vpn.clearSavedPlan(); try store.finishRuntimeReconciliation()
      }
    }
  }

  private func publish(_ candidate: RefreshCandidate) async throws {
    try await changingTunnel { [self] in
      let store = try catalog()
      let previous = vpn.savedPlan
      let wasConnected = vpn.connected
      let waiting = onDemandWaiting
      let selected = store.selectedNodeID().flatMap { id in nodes.first { $0.id == id } }
      let removed = try store.beginPublication(candidate)
      do {
        // A server the provider dropped hands over to the next one instead of disconnecting.
        let next = removed ? fallback(after: selected, in: store) : nil
        if let next { try store.commitSelection(nodeID: next.id) }
        try await synchronize()
        try store.finishPublication(candidate)
        if let selected, let next, wasConnected {
          notice = String(localized: "\(selected.name) is gone from \(subscriptions.first { $0.id == selected.subscriptionID }?.name ?? String(localized: "its subscription")). Connected to \(next.name).")
        }
        if !vpn.active { try store.reclaimRetiredSecrets() }
      } catch {
        try store.rollbackPublication(recoveringAfterInterruption: true)
        try Task.checkCancellation()
        if wasConnected, let previous {
          if !IOSVPNController.keptPreviousPlan(error) {
            try await vpn.replacePlan(previous, settings: settings)
            try await vpn.persist(previous, settings: settings, allowOnDemand: commands.intent == .connected)
          }
        } else if waiting, let previous { try await vpn.persist(previous, settings: settings, allowOnDemand: commands.intent == .connected) }
        else if !vpn.active { try await vpn.clearSavedPlan() }
        try store.finishRuntimeReconciliation()
        throw error
      }
    }
  }

  // Recovery's allowed servers come first, then the subscription's own servers in the provider's order.
  private func fallback(after removed: ServerNode?, in store: SubscriptionStore) -> ServerNode? {
    guard let removed else { return nil }
    let fresh = (store.snapshot()["subscriptions"] as? [[String: Any]] ?? []).map(ServerSubscription.init(raw:))
    let usable = fresh.flatMap(\.nodes).filter { $0.format != "telegram" }
    let allowed = preferences.automation.enabled ? preferences.automation.nodeIDs.compactMap { id in usable.first { $0.id == id } } : []
    return allowed.first ?? usable.first { $0.subscriptionID == removed.subscriptionID }
  }

  /// On Demand reads as disconnected while it waits to reconnect, yet it still owns the saved plan.
  /// An armed Wi-Fi rule owns it too: iOS may start it on the next untrusted network.
  private var onDemandWaiting: Bool {
    !vpn.active && (commands.intent == .connected && vpn.manager?.isOnDemandEnabled == true || untrustedWiFiArmed)
  }
  /// Recovery restarts the tunnel itself while connected, so the Wi-Fi rule then waits as On Demand does.
  private var untrustedWiFiArmed: Bool {
    settings.connectOnUntrustedWiFi == true && commands.untrustedWiFiArmed &&
      (commands.intent != .connected || !preferences.automation.enabled)
  }

  private func synchronize() async throws {
    let store = try catalog()
    if vpn.connected, let node = store.selectedNodeID() {
      let plan = try await makePlan(nodeID: node)
      if plan != vpn.savedPlan {
        try await vpn.replacePlan(plan, settings: settings)
        try await vpn.persist(plan, settings: settings, allowOnDemand: commands.intent == .connected)
      }
    } else if vpn.connected, store.selectedNodeID() == nil {
      try await vpn.disconnect(); try await vpn.clearSavedPlan(); try commands.persist(.disconnected); recovery.stop(); try saveEpisode()
    } else if vpn.active {
      throw IOSAppError.busy
    } else if onDemandWaiting, let node = store.selectedNodeID() {
      try await vpn.persist(try await makePlan(nodeID: node), settings: settings, allowOnDemand: commands.intent == .connected)
    } else { try await vpn.clearSavedPlan() }
  }

  func editRouting(_ mutation: (RoutingStore) throws -> Void) async throws {
    let store = try catalog()
    let previous = try store.routing.beginStaging()
    let checkpoint: Data
    // Compiling every server validates the edit before it reaches the tunnel.
    do { try mutation(store.routing); try store.validateNodes(); checkpoint = try store.routing.checkpoint(); try store.routing.endStaging(previous) }
    catch { try store.routing.endStaging(previous); throw error }
    try await commitRouting { try $0.restore(checkpoint) }
  }

  private func commitRouting(_ mutation: @escaping (RoutingStore) throws -> Void) async throws {
    try await changingTunnel { [self] in
      let store = try catalog()
      let checkpoint = try store.routing.checkpoint()
      let previousPlan = vpn.savedPlan
      let wasConnected = vpn.connected
      let waiting = onDemandWaiting
      let node = store.selectedNodeID()
      if node != nil { try store.beginSelectionPublication() }
      do {
        try mutation(store.routing)
        try await synchronize()
        if let node { try store.finishSelectionPublication(nodeID: node) }
      } catch {
        // A selection's rollback restores no routing, so the checkpoint is restored either way.
        if node != nil { try store.rollbackPublication(recoveringAfterInterruption: true) }
        try store.routing.restore(checkpoint)
        try Task.checkCancellation()
        if wasConnected, let previousPlan {
          if !IOSVPNController.keptPreviousPlan(error) {
            try await vpn.replacePlan(previousPlan, settings: settings)
            try await vpn.persist(previousPlan, settings: settings, allowOnDemand: commands.intent == .connected)
          }
        } else if waiting, let previousPlan { try await vpn.persist(previousPlan, settings: settings, allowOnDemand: commands.intent == .connected) }
        else if !vpn.active { try await vpn.clearSavedPlan() }
        if node != nil { try store.finishRuntimeReconciliation() }
        throw error
      }
    }
  }

  func refreshAssets(_ profile: RoutingProfile, file: String? = nil) async throws {
    _ = try await catalog().routing.refreshGeofiles(id: profile.id, force: true, file: file)
    try await changingTunnel { [self] in try await synchronize() }
  }

  func refreshManaged(profileID: String, sourceID: String) async throws {
    try await catalog().routing.refreshManaged(id: profileID, sourceID: sourceID)
  }

  func makePlan(nodeID: String) async throws -> Data {
    let store = try catalog()
    try settings.validate()
    let source = try store.subscriptionID(nodeID: nodeID)
    try await store.routing.prepareAssets(subscriptionID: source)
    let routes = try store.routing.runtimeRevision(subscriptionID: source)
    let preference = try store.ipPreference(nodeID: nodeID)
    let ref = try store.outboundRef(nodeID: nodeID)
    // Compile before asking iOS to start the provider, including unsupported-rule checks.
    _ = try compile(try store.outbound(nodeID: nodeID), routes: try store.routing.previewRoutes(subscriptionID: source), preference: preference, port: settings.socksPort)
    let plan = TunnelPlan(schemaVersion: 1, secretRef: ref, socksPort: UInt16(settings.socksPort), mtu: 1500,
      dnsServers: ["198.18.0.1", "2001:2::1"], controlledRoutes: [], staticHosts: [:],
      outboundFormat: OutboundFormat(rawValue: try store.outboundFormat(secretRef: ref)), fallbackAction: .proxy,
      routingRevision: routes?.name, routingDigest: routes?.digest, assetRevision: routes?.assetRevision,
      backend: .nativeTun2Proxy, settings: try settings.runtime(nodePreference: preference))
    try plan.validate()
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(plan)
  }

  func compile(_ config: [String: Any], routes: [String: Any]?, preference: String?, port: Int,
                       probe: Bool = false) throws -> [String: Any] {
    let profile = config["outbounds"] != nil
    var runtime = settings.compilerRuntime
    let effective = preference ?? (!profile || settings.profilePreferredIP == "inherit" ? nil : settings.profilePreferredIP)
    if let effective { runtime["preferredIp"] = effective }
    if let ref = settings.inboundCredentialRef, settings.inboundAuthEnabled { runtime["inboundAuth"] = try catalog().inboundCredentials(ref: ref) }
    if probe { runtime["httpInboundEnabled"] = false; runtime["allowLan"] = false; runtime.removeValue(forKey: "inboundAuth") }
    var payload: [String: Any] = [profile ? "profile" : "outbound": config, "socksPort": port, "runtime": runtime, "packetBackend": "nativeTun2Proxy"]
    if let routes { payload["routes"] = routes }
    else if !profile { payload["routes"] = ["rules": [], "dnsServers": ["1.1.1.1"], "staticHosts": [:], "fallbackAction": "proxy"] }
    if profile, let effective { payload["preferredIp"] = effective }
    let result = try RoutingDomainDecoder.request(profile ? "compileProfile" : "compileOutbound", payload: payload)
    guard let json = result["configUtf8"] as? String,
          let compiled = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { throw IOSAppError.nativeFailure }
    let rules = (compiled["routing"] as? [String: Any])?["rules"] as? [[String: Any]] ?? []
    guard !rules.contains(where: { ($0["process"] as? [String])?.isEmpty == false }) else { throw IOSAppError.unsupportedProcessRouting }
    return compiled
  }

  func saveSettings(_ next: IOSTunnelSettings) async throws {
    try next.validate()
    guard next != settings else { return }
    if next.connectOnUntrustedWiFi == true && settings.connectOnUntrustedWiFi != true { commands.armUntrustedWiFi() }
    try await changingTunnel { [self] in
      guard vpn.connected || !vpn.active else { throw IOSAppError.busy }
      let previous = settings
      let wasConnected = vpn.connected
      let waiting = onDemandWaiting
      let previousPlan = vpn.savedPlan
      if vpn.active { try await vpn.disconnect() }
      do {
        settings = next
        if wasConnected, let id = selectedID { try await vpn.connect(try await makePlan(nodeID: id), settings: next) }
        else if onDemandWaiting, let id = selectedID {
          try await vpn.persist(try await makePlan(nodeID: id), settings: next, allowOnDemand: commands.intent == .connected)
        } else { try await vpn.clearSavedPlan() }
        try write(next, name: "ios-settings.json")
        recovery.invalidate(configuration: true)
      } catch {
        settings = previous
        try Task.checkCancellation()
        if wasConnected, let previousPlan {
          do {
            try await vpn.replacePlan(previousPlan, settings: previous)
            try await vpn.persist(previousPlan, settings: previous, allowOnDemand: commands.intent == .connected)
          } catch { throw IOSAppError.switchRestoreFailed }
        } else if waiting, let previousPlan {
          do { try await vpn.persist(previousPlan, settings: previous, allowOnDemand: commands.intent == .connected) }
          catch { throw IOSAppError.switchRestoreFailed }
        }
        throw error
      }
    }
  }

  func updateCredentials(username: String, password: String) async throws {
    let store = try catalog()
    let ref = try store.storeInboundCredentials(username: username, password: password)
    var next = settings; next.inboundCredentialRef = ref; next.inboundAuthEnabled = true
    do {
      try await saveSettings(next)
      // Old references may still be named by an interrupted provider; retain them.
    } catch { if !vpn.active { store.removeInboundCredentials(ref: ref) }; throw error }
  }

  func savePreferences(_ next: IOSPreferences) throws {
    guard next.version == 1, (1...168).contains(next.autoUpdateHours), (1...15).contains(next.probeTimeout),
          ["GET", "HEAD"].contains(next.probeMethod), next.probeMethod != "HEAD" || next.probeExpectedBody.isEmpty else { throw IOSAppError.invalidSettings }
    try AutomationConfiguration.Target(id: "manual", url: next.probeURL, expectedStatus: next.probeExpectedStatus, expectedBody: next.probeExpectedBody).validate()
    try next.automation.validate()
    if next.automation.enabled {
      guard recoverySelectionExists(next.automation),
            next.automation.policy == .fixed || (next.automation.targets.count == 2 && next.automation.nodeIDs.count > 1)
      else { throw IOSAppError.invalidRecovery }
    }
    try write(next, name: "ios-preferences.json")
    if preferences.automation != next.automation {
      recovery.invalidate(configuration: true)
      if !next.automation.enabled { recovery.stop() }
      recoveryStatus = next.automation.enabled ? String(localized: "Ready while app is open") : String(localized: "Off")
      try saveEpisode()
    }
    preferences = next
  }

  func setReminders(_ enabled: Bool) async throws {
    if enabled {
      guard try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) else { throw IOSAppError.notificationPermission }
    }
    var next = preferences; next.expiryReminders = enabled; try savePreferences(next)
    await refreshReminders()
  }

  private func refreshReminders() async {
    let center = UNUserNotificationCenter.current()
    let signature = "\(preferences.expiryReminders)|\(Calendar.current.startOfDay(for: Date()))|" + subscriptions.map { "\($0.id):\($0.expireSeconds ?? 0)" }.sorted().joined(separator: "|")
    guard signature != reminderSnapshot else { return }
    do {
      let saved = try read([String: Double].self, name: "ios-reminders.json") ?? [:]
      let plan = IOSExpiryReminders.plan(sources: subscriptions, enabled: preferences.expiryReminders, recorded: saved, now: Date())
      let pending = await center.pendingNotificationRequests()
      let desired = Set((Array(plan.retained.keys) + plan.additions.map(\.id)).map { "elarni.expiry.\($0)" })
      center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix("elarni.expiry.") && !desired.contains($0) } + plan.removals.map { "elarni.expiry.\($0)" })
      var recorded = plan.retained
      for reminder in plan.additions {
        let content = UNMutableNotificationContent(); content.title = String(localized: "Subscription expiry")
        content.body = String(localized: "Check your subscription in Elarni before it expires."); content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: reminder.delay, repeats: false)
        try await center.add(UNNotificationRequest(identifier: "elarni.expiry.\(reminder.id)", content: content, trigger: trigger))
        recorded[reminder.id] = reminder.expiration
      }
      try write(recorded, name: "ios-reminders.json")
      reminderSnapshot = signature
    } catch { notice = String(localized: "Expiry reminders could not be updated. Check notification access in iPhone Settings.") }
  }

  func exportBackup(password: String) async throws -> String {
    let result = try await NativeAPI.perform("sealCatalogBackup", ["catalog": try catalog().backupCatalog(), "password": password])
    guard let text = result["text"] as? String else { throw IOSAppError.nativeFailure }
    return text
  }

  func restoreBackup(text: String, password: String) async throws {
    guard !vpn.active, text.utf8.count <= 12 * 1024 * 1024 else { throw IOSAppError.busy }
    let result = try await NativeAPI.perform("openCatalogBackup", ["text": text, "password": password])
    guard let payload = result["catalog"] as? [String: Any] else { throw IOSAppError.nativeFailure }
    let store = try catalog()
    do {
      _ = try store.beginBackupRestore(payload)
      try await vpn.clearSavedPlan()
      var next = preferences; next.automation = AutomationConfiguration(); try savePreferences(next)
      try commands.persist(.disconnected); recovery.stop(); try saveEpisode()
      try store.finishBackupRestore()
    } catch { try store.rollbackPublication(); throw error }
  }

  func repair() async throws {
    guard !vpn.active else { throw IOSAppError.busy }
    try await vpn.removePlan()
    try commands.persist(.disconnected)
    recovery.stop(); try saveEpisode()
    if let store, store.runtimeReconciliationRequired { try store.finishRuntimeReconciliation() }
    notice = String(localized: "VPN configuration removed. Connect to create it again.")
  }

  static let logLevels = ["none", "error", "warning", "info", "debug"]
  /// Shared with the extension: the level it applies and the lines it kept when it last stopped.
  var logsDirectory: URL? { directory?.appendingPathComponent("Logs", isDirectory: true) }

  var logLevel: String {
    guard let url = logsDirectory?.appendingPathComponent("level"),
          let level = try? String(contentsOf: url, encoding: .utf8), Self.logLevels.contains(level) else { return "warning" }
    return level
  }

  func setLogLevel(_ level: String) throws {
    guard Self.logLevels.contains(level), let directory = logsDirectory else { throw IOSAppError.invalidSettings }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(level.utf8).write(to: directory.appendingPathComponent("level"), options: .atomic)
  }

  /// The running extension's lines, or nil when it did not answer; while it does not run, the ones it kept.
  func readLogs(after: Int64) async -> [String: Any]? {
    if vpn.connected { return try? await vpn.logs(after: after) }
    guard let url = logsDirectory?.appendingPathComponent("last.json"), let data = try? Data(contentsOf: url),
          var kept = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ["entries": [Any](), "last": 0] }
    kept["entries"] = (kept["entries"] as? [[String: Any]] ?? []).filter { (($0["seq"] as? NSNumber)?.int64Value ?? 0) > after }
    return kept
  }

  /// The provider's mark lists its open connections; with no tunnel, the app's own mark still dates a failed connect.
  func markRecording() async throws {
    if !(await vpn.recording(mark: true)) {
      guard DiagnosticLog.start(role: "host") else { throw IOSAppError.recordingFailed }
      defer { DiagnosticLog.stop() }
      do { try await DiagnosticLog.perform("mark") } catch { throw IOSAppError.recordingFailed }
    }
    notice = String(localized: "Problem marked at \(Date().formatted(date: .omitted, time: .standard)). Export the recording in Troubleshooting when you are done.")
  }

  /// A ZIP in the temporary folder; the caller removes it once saved.
  func exportRecording() async throws -> URL {
    _ = await vpn.recording(mark: false)
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("Elarni-recording-\(UUID().uuidString).zip")
    do { try await DiagnosticLog.perform("export", destination: file) }
    catch DiagnosticLog.Failure.empty { throw IOSAppError.recordingEmpty }
    catch { throw IOSAppError.recordingFailed }
    return file
  }

  func diagnostics() throws -> String {
    let state: String
    switch vpn.status {
    case .connected: state = "connected"
    case .connecting: state = "connecting"
    case .disconnecting: state = "disconnecting"
    case .reasserting: state = "reasserting"
    case .invalid: state = "invalid"
    default: state = "disconnected"
    }
    var snapshot = ConnectionSupportSnapshot.make(state: state, provider: vpn.provider,
      automation: ["enabled": preferences.automation.enabled, "policy": preferences.automation.policy.rawValue,
        "pendingRetry": recovery.retryAt != nil, "exhausted": recovery.episode.exhausted,
        "pathAvailable": recovery.online, "attempts": recovery.episode.attempts,
        "status": !preferences.automation.enabled ? "disabled" : recovery.episode.exhausted ? "exhausted" : recovery.retryAt != nil ? "replacing" : vpn.providerReady ? "connectedUnchecked" : "waitingForPath"],
      issueCodes: recentIssues.map(\.code))
    snapshot["platform"] = "ios"
    snapshot["systemVersion"] = ProcessInfo.processInfo.operatingSystemVersionString
    snapshot["appVersion"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    snapshot["coreVersion"] = NativeAPI.xrayVersion
    snapshot["generatedAt"] = ISO8601DateFormatter().string(from: Date())
    return try prettyJSON(snapshot)
  }

  func acceptURL(_ url: URL) {
    Task {
      await start()
      guard loaded else { return }
    if let action = TunnelCommandCoordinator.connectionAction(from: url.absoluteString) {
        switch action {
        case "connect": await connect()
        // Links come from web pages and other apps; ContentView confirms stops and imports.
        case "disconnect": linkStopRequested = true
        case "toggle": if vpn.active { linkStopRequested = true } else { await connect() }
        default: selectedTab = 0
        }
    } else if url.isFileURL {
      do { incomingText = try IOSImport.readText(url) } catch { show(error) }
    } else { incomingText = url.absoluteString }
    }
  }

  func testServers(_ values: [ServerNode]) {
    guard probeTask == nil, !probeQuarantined else { return }
    let eligible = values.filter { $0.format != "telegram" }
    if vpn.active && (["tcp", "icmp"].contains(preferences.probeMode) || eligible.contains { $0.id != selectedID }) {
      notice = String(localized: "Disconnect before testing other servers, direct TCP, or ICMP. While connected, test the selected server to check the current VPN path.")
      return
    }
    probeTask = Task {
      defer { probeTask = nil; testingIDs = [] }
      await perform(reportError: false) {
        let mode = self.preferences.probeMode
        let intentRevision = self.commands.revision
        self.testingIDs = Set(eligible.map(\.id))
        try await withThrowingTaskGroup(of: (String, ProbeResult).self) { group in
          var lanes = ProbeLanes(eligible) { $0.raw["probeKey"] as? String ?? $0.id }
          var keys: [String: String] = [:]
          var running = 0
          func enqueue(_ node: ServerNode) {
            group.addTask { @MainActor in
              try Task.checkCancellation()
              let result: ProbeResult
              do {
                let delay = try await self.probe(node, mode: mode)
                result = ProbeResult(milliseconds: delay, status: "Passed", revision: node.revision, date: Date(), mode: mode)
              } catch is CancellationError { throw CancellationError() }
              catch {
                try Task.checkCancellation()
                if self.probeQuarantined { self.show(error); throw error }
                result = ProbeResult(milliseconds: nil, status: "Failed", revision: node.revision, date: Date(), mode: mode, failure: Self.probeFailure(error))
              }
              return (node.id, result)
            }
          }
          func fill() {
            while running < 32, let (key, node) = lanes.next() { keys[node.id] = key; running += 1; enqueue(node) }
          }
          fill()
          while let (id, result) = try await group.next() {
            try Task.checkCancellation()
            guard self.commands.revision == intentRevision,
                  self.nodes.first(where: { $0.id == id })?.revision == result.revision else { throw AutomationFailure.staleContext }
            self.probes[id] = result
            self.testingIDs.remove(id)
            if let key = keys[id] { lanes.finish(key) }
            running -= 1
            fill()
          }
        }
        self.lastCheck = Date()
      }
    }
  }

  static let exitTraceURL = "https://cp.cloudflare.com/cdn-cgi/trace"

  /// Where a server reaches the internet, from Cloudflare's trace through it.
  func checkExit(_ node: ServerNode) {
    guard probeTask == nil, !probeQuarantined, node.format != "telegram" else { return }
    if vpn.active && node.id != selectedID {
      notice = String(localized: "Disconnect before testing other servers, direct TCP, or ICMP. While connected, test the selected server to check the current VPN path.")
      return
    }
    exits[node.id] = nil
    exitFailures.remove(node.id)
    probeTask = Task {
      defer { probeTask = nil; testingIDs = [] }
      testingIDs = [node.id]
      let checked = await perform(reportError: false) {
        let exit = try await self.measure(node, mode: "proxy", target: .init(id: "exit", url: Self.exitTraceURL, expectedStatus: 200, expectedBody: ""), trace: true).exit
        guard let ip = exit?["ip"] as? String, let country = exit?["country"] as? String else { throw IOSAppError.nativeFailure }
        self.exits[node.id] = ExitResult(ip: ip, country: country, revision: node.revision)
      }
      if !checked { exitFailures.insert(node.id) }
    }
  }

  func cancelTests() { probeTask?.cancel() }
  func cancelOperations() { probeTask?.cancel(); store?.cancelRefreshes(); store?.routing.cancelManagedRefreshes() }

  /// What a failed test tells the user; the probes report these through shared error cases.
  private static func probeFailure(_ error: Error) -> String {
    switch error {
    case let failure as IOSProbeFailure:
      failure.code == "timeout" ? String(localized: "Timed out.") : failure.code == "target_dns_failed" ? String(localized: "The test address could not be resolved.")
        : failure.receivedHTTP ? String(localized: "The test address returned an unexpected response.") : String(localized: "The connection through this server failed.")
    case IOSAppError.operationTimedOut: String(localized: "Timed out.")
    case IOSAppError.providerUnavailable: String(localized: "The server could not be reached.")
    case IOSAppError.invalidSettings: String(localized: "This test type does not support this server.")
    case AutomationFailure.staleContext: String(localized: "The server or connection changed during the test.")
    default: String(localized: "The test could not run.")
    }
  }

  func nativeProbe(_ payload: [String: Any]) async throws -> Int {
    let reply = try await nativeProbeReply(payload)
    return reply["delay"] as? Int ?? 0
  }

  /// The core's whole ping reply, which for a trace names the exit.
  func nativeProbeReply(_ payload: [String: Any]) async throws -> [String: Any] {
    guard !probeQuarantined else { throw IOSAppError.busy }
    let operation = UUID().uuidString.lowercased()
    _ = try NativeAPI.invoke("prepareProbe", ["operationId": operation, "timeout": payload["timeout"] as? Int ?? 5])
    defer { _ = try? NativeAPI.invoke("releaseProbe", ["operationId": operation]) }
    var request = payload; request["operationId"] = operation
    do {
      let reply = try await withTaskCancellationHandler {
        try Task.checkCancellation()
        return try await NativeAPI.perform("ping", request)
      } onCancel: { _ = try? NativeAPI.invoke("cancelProbe", ["operationId": operation]) }
      guard let delay = reply["delay"] as? Int, delay >= 0 else { throw IOSAppError.nativeFailure }
      return reply
    } catch let error as IOSProbeFailure {
      if error.cleanupPending { probeQuarantined = true }
      try Task.checkCancellation()
      throw error
    }
  }

  private func probe(_ node: ServerNode, mode: String, target: AutomationConfiguration.Target? = nil, expectedPlan: Data? = nil) async throws -> Int {
    try await measure(node, mode: mode, target: target, expectedPlan: expectedPlan).delay
  }

  private func measure(_ node: ServerNode, mode: String, target: AutomationConfiguration.Target? = nil, expectedPlan: Data? = nil,
                       trace: Bool = false) async throws -> (delay: Int, exit: [String: Any]?) {
    let store = try catalog()
    let revision = try store.configurationRevision(nodeID: node.id)
    let intentRevision = commands.revision
    let config = try store.outbound(nodeID: node.id)
    let delay: Int
    var exit: [String: Any]?
    if mode == "tcp" || mode == "icmp" {
      guard !vpn.active else { throw IOSAppError.busy }
      let endpoints = try RoutingDomainDecoder.request("profileEndpoints", payload: ["config": config])["endpoints"] as? [[String: Any]] ?? []
      // As on macOS: the server the device dials, which for a chain is its entry.
      guard let endpoint = endpoints.first(where: { $0["physical"] as? Bool == true }),
            mode == "icmp" || endpoint["supportsTcpProbe"] as? Bool == true,
            let host = endpoint["host"] as? String, let port = endpoint["port"] as? Int,
            let number = UInt16(exactly: port) else { throw IOSAppError.invalidSettings }
      let runtime = try settings.runtime(nodePreference: store.ipPreference(nodeID: node.id))
      let preference = config["outbounds"] == nil ? runtime.preferredIP : runtime.profilePreferredIP ?? "automatic"
      if mode == "icmp" { delay = try await IOSICMP.measure(host: host, timeout: preferences.probeTimeout, preference: preference) }
      else { delay = try await IOSNetworkProbe.tcp(host: host, port: number, timeout: preferences.probeTimeout, preference: preference) }
    } else {
      var payload: [String: Any] = ["url": target?.url ?? preferences.probeURL,
        "expectedStatus": target?.expectedStatus ?? preferences.probeExpectedStatus,
        "expectedBody": target?.expectedBody ?? preferences.probeExpectedBody,
        "method": target == nil ? preferences.probeMethod : "GET", "mode": target == nil ? preferences.probeVariant : "default",
        "timeout": target == nil ? preferences.probeTimeout : 5]
      if trace { payload["trace"] = true }
      if vpn.connected {
        guard expectedPlan != nil || selectedID == node.id, let plan = expectedPlan ?? vpn.savedPlan else { throw IOSAppError.busy }
        let savedPlan = vpn.savedPlan
        try await vpn.refreshProvider()
        let before = vpn.provider
        let digest = Data(SHA256.hash(data: plan)).base64EncodedString()
        guard before["state"] as? String == "connected", before["configurationDigest"] as? String == digest,
              let instance = before["instanceID"] as? String, let generation = before["generation"] as? UInt64,
              before["resourceRecoveryRequired"] as? Bool != true else { throw AutomationFailure.providerFailure }
        payload["packetPath"] = true
        let outcome: Result<[String: Any], Error>
        do { outcome = .success(try await nativeProbeReply(payload)) } catch { outcome = .failure(error) }
        try Task.checkCancellation()
        try await vpn.refreshProvider()
        guard vpn.connected, vpn.provider["state"] as? String == "connected", vpn.provider["instanceID"] as? String == instance,
              vpn.provider["generation"] as? UInt64 == generation, vpn.provider["configurationDigest"] as? String == digest,
              vpn.provider["resourceRecoveryRequired"] as? Bool != true, vpn.savedPlan == savedPlan else { throw AutomationFailure.staleContext }
        let reply = try outcome.get()
        delay = reply["delay"] as? Int ?? 0
        exit = reply["exit"] as? [String: Any]
      } else {
        guard !vpn.active else { throw IOSAppError.busy }
        let port = try IOSNetworkProbe.freePort()
        let context = mode == "activeProxy" ? try store.routing.runtimeProbeConfiguration(subscriptionID: node.subscriptionID) : (routes: nil, assetDirectory: nil)
        var compiled = try compile(config, routes: context.routes, preference: try store.ipPreference(nodeID: node.id), port: port, probe: true)
        if let assets = context.assetDirectory { compiled["env"] = ["xray.location.asset": assets] }
        payload["configJSON"] = try prettyJSON(compiled)
        payload["proxy"] = "socks5://127.0.0.1:\(port)"
        let reply = try await nativeProbeReply(payload)
        delay = reply["delay"] as? Int ?? 0
        exit = reply["exit"] as? [String: Any]
      }
    }
    try Task.checkCancellation()
    guard commands.revision == intentRevision, try store.configurationRevision(nodeID: node.id) == revision else { throw AutomationFailure.staleContext }
    if !["tcp", "icmp"].contains(mode) { try store.recordSuccess(nodeID: node.id, revision: revision) }
    return (delay, exit)
  }

  private func saveEpisode() throws { try write(recovery.episode, name: "ios-recovery.json") }

  private func requireRecoveryPolicy(_ node: ServerNode) throws {
    guard settings.includeAllNetworks, settings.excludedRoutes.isEmpty,
          Set(settings.includedRoutes) == Set(["0.0.0.0/0", "::/0"]) else { throw AutomationFailure.unsupportedPolicy }
    let store = try catalog()
    if let route = try store.routing.runtimeProbeConfiguration(subscriptionID: node.subscriptionID).routes {
      guard route["fallbackAction"] as? String == "proxy", (route["rules"] as? [[String: Any]] ?? []).isEmpty else { throw AutomationFailure.unsupportedPolicy }
    }
    let config = try store.outbound(nodeID: node.id)
    if let rules = (config["routing"] as? [String: Any])?["rules"] as? [Any], !rules.isEmpty { throw AutomationFailure.unsupportedPolicy }
  }

  private func activeHealth(_ node: ServerNode, expectedPlan: Data? = nil) async throws {
    try requireRecoveryPolicy(node)
    // As on macOS and desktop: every target gets its probe before the check is classified.
    var timeouts = 0, invalidTarget = false
    let russianEntry = preferences.automation.russianEntryNodeIDs?.contains(node.id) == true
    for target in preferences.automation.targets {
      do {
        _ = try await probe(node, mode: "activeProxy", target: target, expectedPlan: expectedPlan)
        recovery.observe(node: node.id, passed: true, russianEntry: russianEntry); whitelistMode = recovery.whitelist
        return
      } catch let error as IOSProbeFailure {
        if error.cleanupPending { throw AutomationFailure.quarantine }
        if error.receivedHTTP || error.code == "target_dns_failed" { invalidTarget = true }
        if error.code == "timeout" { timeouts += 1 }
      } catch { throw error }
    }
    if invalidTarget { throw AutomationFailure.invalidTarget }
    guard timeouts >= preferences.automation.endpointFailureTimeouts else { throw AutomationFailure.indeterminate }
    recovery.observe(node: node.id, passed: false, russianEntry: russianEntry); whitelistMode = recovery.whitelist
    throw AutomationFailure.endpointFailure
  }

  /// Russian entries first in whitelist mode, then TCP 443 servers after a UDP or other-port failure.
  private func recoveryOrder(current: String) -> [String] {
    let config = preferences.automation, store = try? catalog()
    return recovery.recoveryOrder(config.nodeIDs, current: current,
      tcp443: Set(config.nodeIDs.filter { id in (try? store?.outbound(nodeID: id)).map(AutomationPolicy.tcp443) == true }),
      russianEntry: Set(config.russianEntryNodeIDs ?? []))
  }

  private func chooseBeforeConnecting(current: String) async throws -> String {
    let config = preferences.automation
    guard nodes.contains(where: { $0.id == current }),
          config.nodeIDs.contains(current), let target = config.targets.first else { throw IOSAppError.invalidRecovery }
    let store = try catalog()
    let epoch = recovery.epoch
    let deadline = ProcessInfo.processInfo.systemUptime + 60
    let round = recovery.round(nodes: config.nodeIDs, current: current, now: ProcessInfo.processInfo.systemUptime)
    defer { testingIDs = [] }
    for id in round {
      try Task.checkCancellation()
      guard foreground, epoch == recovery.epoch else { throw CancellationError() }
      guard ProcessInfo.processInfo.systemUptime + 5 < deadline else { break }
      guard let node = nodes.first(where: { $0.id == id }) else { continue }
      recoveryStatus = String(localized: "Comparing allowed servers")
      testingIDs = [id]
      do {
        var samples: [Double] = []
        for _ in 0..<3 {
          guard ProcessInfo.processInfo.systemUptime + 5 < deadline else { throw AutomationFailure.deadline }
          samples.append(Double(try await probe(node, mode: "activeProxy", target: target)))
          try Task.checkCancellation()
          guard foreground, epoch == recovery.epoch else { throw CancellationError() }
        }
        recovery.record(node: id, reference: try store.configurationRevision(nodeID: id), samples: samples, now: ProcessInfo.processInfo.systemUptime)
        probes[id] = ProbeResult(milliseconds: Int(samples.sorted()[1]), status: "Passed", revision: node.revision, date: Date(), mode: "activeProxy")
      } catch is CancellationError { throw CancellationError() }
      catch {
        if probeQuarantined { throw AutomationFailure.quarantine }
        recovery.reject(node: id, transient: true, now: ProcessInfo.processInfo.systemUptime)
      }
    }
    var scores: [String: Double] = [:]
    for id in round {
      scores[id] = recovery.score(node: id, reference: try store.configurationRevision(nodeID: id), now: ProcessInfo.processInfo.systemUptime)
    }
    guard let chosen = recovery.choose(policy: .lowestLatency, order: config.nodeIDs, current: current, scores: scores, healthy: false, now: ProcessInfo.processInfo.systemUptime) else {
      throw AutomationFailure.exhaustedCandidates
    }
    return chosen
  }

  private func replaceAutomatically(_ node: ServerNode) async throws {
    try await changingTunnel { [self] in
      let store = try catalog()
      let plan = try await makePlan(nodeID: node.id)
      guard let previous = vpn.savedPlan else { throw IOSAppError.providerUnavailable }
      try store.beginSelectionPublication()
      do {
        try await vpn.replacePlan(plan, settings: settings)
        try await activeHealth(node, expectedPlan: plan)
        try Task.checkCancellation()
        try await vpn.persist(plan, settings: settings, allowOnDemand: commands.intent == .connected)
        try store.finishSelectionPublication(nodeID: node.id)
        reload()
      } catch {
        try store.rollbackPublication(recoveringAfterInterruption: true)
        try Task.checkCancellation() // Stop owns cleanup; never reconnect after it.
        do {
          try await vpn.replacePlan(previous, settings: settings)
          try await vpn.persist(previous, settings: settings, allowOnDemand: commands.intent == .connected)
          try store.finishRuntimeReconciliation()
        } catch { throw IOSAppError.switchRestoreFailed }
        throw error
      }
    }
  }

  private func recoverIfNeeded() async {
    let config = preferences.automation
    guard config.enabled, foreground, commands.intent == .connected, !busy, !probeQuarantined,
          let node = selected, config.nodeIDs.contains(node.id) else { return }
    let now = ProcessInfo.processInfo.systemUptime
    guard recovery.online else { recoveryStatus = String(localized: "Waiting for network"); return }
    guard !recovery.episode.exhausted else { recoveryStatus = String(localized: "Retry limit reached. Tap Connect to retry."); return }
    // A failed provider reports reasserting until it is restarted; treat it as down.
    let failed = vpn.failed
    guard failed || ![.connecting, .disconnecting, .reasserting].contains(vpn.status) else { return }
    if (!vpn.connected || failed) && recovery.retryAt == nil { _ = recovery.scheduleRetry(now: now, jitter: Double.random(in: -1...1)); try? saveEpisode() }
    let retry = recovery.retryAt.map { now >= $0 } ?? false
    let health = vpn.connected && !failed && recovery.retryAt == nil && now >= (recovery.healthAt ?? now)
    guard retry || health else { return }
    let deadline = min(now + 60, recovery.remainingEpisodeTime ?? now + 60)
    let deadlineTask = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(max(0, deadline - ProcessInfo.processInfo.systemUptime))) }
      catch { return }
      self?.commands.invalidateAutomatic()
    }
    defer { deadlineTask.cancel() }
    await perform(automatic: true, reportError: false) {
      if retry {
        guard self.recovery.beginRetry(now: now) else { return }
        try self.saveEpisode()
        self.recoveryStatus = String(localized: "Recovery attempt \(self.recovery.episode.attempts) of 6")
      }
      do {
        var canVerifyTraffic = true
        do { try self.requireRecoveryPolicy(node) }
        catch AutomationFailure.unsupportedPolicy where config.policy == .fixed { canVerifyTraffic = false }
        if retry {
          try await self.changingTunnel { [self] in
            if vpn.active { try await vpn.disconnect() }
            try Task.checkCancellation()
            try await vpn.connect(try await makePlan(nodeID: node.id), settings: settings)
          }
        }
        if !canVerifyTraffic {
          // OS/provider readiness supports same-server reconnect with custom
          // routes, but does not establish that HTTP used the protected path.
          try await self.vpn.refreshProvider()
          guard self.vpn.providerReady else { throw AutomationFailure.providerFailure }
          self.recovery.healthy(now: ProcessInfo.processInfo.systemUptime, jitter: 0)
          self.recoveryStatus = String(localized: "Connected; traffic check unavailable with these routes")
          try self.saveEpisode()
          return
        }
        try await self.activeHealth(node)
        self.recovery.healthy(now: ProcessInfo.processInfo.systemUptime, jitter: Double.random(in: -1...1))
        self.recoveryStatus = String(localized: "Healthy"); self.lastCheck = Date(); try self.saveEpisode()
      } catch is CancellationError { throw CancellationError() }
      catch {
        let failure = error as? AutomationFailure ?? .indeterminate
        if failure == .unsupportedPolicy {
          self.recoveryStatus = String(localized: "Recovery requires Block traffic without VPN and no bypass or provider routing rules.")
          self.recovery.scheduleHealth(now: now, jitter: 0); return
        }
        let confirmedFailure = self.recovery.failedHealth(failure)
        if retry || confirmedFailure || failure == .providerFailure {
          if config.policy != .fixed && confirmedFailure {
            for id in self.recovery.recoveryCandidates(policy: config.policy, order: self.recoveryOrder(current: node.id), current: node.id, now: now) {
              guard let candidate = self.nodes.first(where: { $0.id == id }) else { continue }
              if ProcessInfo.processInfo.systemUptime + 10 >= deadline { break }
              do {
                try self.requireRecoveryPolicy(candidate)
                try await self.replaceAutomatically(candidate)
                self.recovery.switched(now: ProcessInfo.processInfo.systemUptime)
                self.recovery.healthy(now: ProcessInfo.processInfo.systemUptime, jitter: 0)
                self.recoveryStatus = String(localized: "Recovered"); try self.saveEpisode(); return
              } catch is CancellationError { throw CancellationError() }
              catch {
                if self.store?.runtimeReconciliationRequired == true { self.recovery.expireEpisode(); try self.saveEpisode(); self.recoveryStatus = String(localized: "Recovery stopped. Disconnect to reconcile the previous connection."); return }
                self.recovery.reject(node: candidate.id, transient: true, now: ProcessInfo.processInfo.systemUptime)
              }
            }
          }
          _ = self.recovery.scheduleRetry(now: ProcessInfo.processInfo.systemUptime, jitter: Double.random(in: -1...1))
          try self.saveEpisode()
          self.recoveryStatus = self.recovery.episode.exhausted ? String(localized: "Retry limit reached. Tap Connect to retry.") : String(localized: "Waiting to retry")
        } else {
          self.recovery.scheduleHealth(now: now, jitter: 0)
          self.recoveryStatus = failure == .endpointFailure ? String(localized: "Health check failed \(self.recovery.failures) of 3") : String(localized: "Check inconclusive; connection retained")
        }
      }
    }
    if ProcessInfo.processInfo.systemUptime >= deadline, commands.intent == .connected {
      recovery.expireEpisode(); try? saveEpisode()
      recoveryStatus = String(localized: "Recovery time limit reached. Disconnect, then tap Connect to retry.")
    }
  }

  func show(_ error: Error) {
    if error is CancellationError { return }
    if let cocoa = error as? CocoaError, cocoa.code == .userCancelled { return }
    let message = describe(error)
    errorMessage = message
    // As on desktop: the last eight, a repeat of the latest one folded into it.
    if recentIssues.last?.message != message {
      recentIssues.append(RecentIssue(code: Self.issueCode(error), message: message, date: Date()))
      if recentIssues.count > 8 { recentIssues.removeFirst() }
    }
  }

  /// Codes from ConnectionSupportSnapshot's allowlist; messages never leave the device.
  private static func issueCode(_ error: Error) -> String {
    switch error {
    case let failure as IOSProbeFailure: failure.receivedHTTP || failure.code == "target_dns_failed" ? "check_target_failed" : "check_failed"
    case IOSAppError.providerUnavailable: "provider_unavailable"
    case IOSAppError.cleanupFailed: "disconnect_unconfirmed"
    case IOSAppError.invalidRecovery: "invalid_recovery"
    case IOSAppError.nativeFailure, IOSAppError.invalidSettings, IOSAppError.unsupportedProcessRouting: "invalid_configuration"
    case IOSAppError.switchFailed, IOSAppError.switchRestoreFailed, IOSAppError.serverUnresolvable: "connection_failed"
    case AutomationFailure.unsupportedPolicy: "unsupported_policy"
    default: "operation_failed"
    }
  }

  private func describe(_ error: Error) -> String {
    if let error = error as? SubscriptionError {
      switch error {
      case .keychainFailure: return String(localized: "Secure storage is unavailable. Use a correctly signed build and reopen the app.")
      case .invalidURL: return String(localized: "The subscription address or download options are invalid. Check the URL and provider-supported formats.")
      case .invalidFeed, .noSupportedNodes, .incompatibleProfile: return String(localized: "No supported server configuration was found. Check the link or file format and try again.")
      case .hwidRequired: return String(localized: "This provider requires device registration. Open your provider account or contact support.")
      case .hwidLimit: return String(localized: "The provider’s device limit has been reached. Manage registered devices in your provider account.")
      case .invalidDisplayName: return String(localized: "Use a nonempty name without control characters.")
      case .feedTooLarge: return String(localized: "This subscription exceeds the supported size. Ask the provider for a smaller feed.")
      case .fetchFailed: return String(localized: "The subscription could not be downloaded. Check the provider address and try again.")
      case .fetchClass("dns_failed"): return String(localized: "The address could not be looked up. Check this device’s network and DNS, then retry.")
      case .fetchClass("provider_unreachable"): return String(localized: "The provider’s server did not answer. Your network may block it, or it is down. Retry later or ask the provider for a mirror.")
      case .fetchClass("provider_error"): return String(localized: "The provider’s server reported an error. Nothing is wrong with Elarni or this device; retry later.")
      case .fetchClass("rate_limited"): return String(localized: "The provider is limiting requests. Elarni retries later; wait before refreshing again.")
      case .fetchClass("subscription_denied"): return String(localized: "The provider refused the request. The subscription may have expired, run out of traffic or reached its device limit. Contact the provider.")
      case .fetchClass("subscription_unavailable"): return String(localized: "The provider removed or changed this link. Ask the provider for a new one.")
      case .fetchClass: return String(localized: "The subscription could not be downloaded. Check the provider address and try again.")
      default: return String(localized: "The catalog changed or could not be read. Refresh the screen and retry.")
      }
    }
    switch error as? RoutingStoreError {
    case .noSelectedSubscription?:
      return String(localized: "Select a server first. This routing link turns its profile on for the selected server’s subscription.")
    case .missingGeodata(let missing)?:
      return String(localized: "Proxy rules and servers need codes the geofiles lack: \(missing.joined(separator: ", ")). Fix the profile or its geofile links.")
    case .geofileTooLarge?:
      return String(localized: "A geofile is over 64 MB, which the core cannot load whole. Turn on Reduce routing-data size for this profile or use a smaller geofile.")
    case .routeModelTooLarge?:
      return String(localized: "This routing profile is too large for iPhone: its rules and lists exceed 2 MB. Remove some rules or managed lists.")
    default: break
    }
    return (error as? LocalizedError)?.errorDescription ?? String(localized: "The operation could not be completed. Check the configuration and try again.")
  }

  private func read<T: Decodable>(_ type: T.Type, name: String) throws -> T? {
    guard let url = directory?.appendingPathComponent(name) else { throw IOSPlatformError.signingRequired }
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try JSONDecoder().decode(type, from: Data(contentsOf: url))
  }
  private func write<T: Encodable>(_ value: T, name: String) throws {
    guard let url = directory?.appendingPathComponent(name) else { throw IOSPlatformError.signingRequired }
    try JSONEncoder().encode(value).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
  }
}
