import CryptoKit
import AppKit
import Darwin
import FlutterMacOS
import Foundation
import Network
import NetworkExtension
import ServiceManagement

@MainActor
final class TunnelMethodChannel {
  let channel: FlutterMethodChannel
  var manager: NETunnelProviderManager?
  var subscriptions: SubscriptionStore?
  let settingsStore: TunnelSettingsStore
  let commands: TunnelCommandCoordinator
  let automationDefaults: UserDefaults
  let observesSystem: Bool
  let loadPreferences: () async throws -> [NETunnelProviderManager]
  private let makeSubscriptions: @MainActor () throws -> SubscriptionStore
  private var deepLinkObserver: NSObjectProtocol?
  var automation = AutomationPolicy()
  var automationConfiguration = AutomationConfiguration()
  var automationUnreadable = false
  var automationStatus = "disabled"
  var automationCandidateFailures: [String: String] = [:]
  var healthDiagnostics: [ProbeDiagnostic] = []
  var verifiedHealth: (node: String, at: Double, epoch: UInt64)?
  var automationPaused = false
  var automationRefreshPath = false
  var automationFailover = false
  var automationTimer: Task<Void, Never>?
  var automationWork: Task<Void, Never>?
  private var maintenanceTimer: Task<Void, Never>?
  private var maintenanceWork: Task<Void, Never>?
  private var maintenanceNow: () -> Date = Date.init
  var automationObservers: [NSObjectProtocol] = []
  let pathMonitors = [NWPathMonitor(requiredInterfaceType: .wifi),
                              NWPathMonitor(requiredInterfaceType: .wiredEthernet)]
  var physicalPaths: [Int: (signature: String, available: Bool,
                                   status: String, unsatisfiedReason: String)] = [:]
  var observedProviderStatus: NEVPNStatus?
  var automationNow: () -> Double = { ProcessInfo.processInfo.systemUptime }
  var automationSleep: (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
  var automationJitter: () -> Double = { Double.random(in: -1...1) }
  /// Shared with the extension: the log level it reads and the lines it kept when it stopped.
  var logsDirectory: () -> URL? = {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.elarni.mac")?
      .appendingPathComponent("Logs", isDirectory: true)
  }
#if DEBUG
  var debugStopCompletedAtMs: Int64?
  var debugOSDisconnectedAtMs: Int64?
  var debugStopIdentity: (UUID, UInt64)?
  var debugReadStop: () -> ProviderDebugFaults.StopReceipt? = { try? ProviderDebugFaults.readStop() }
#endif

  init(messenger: FlutterBinaryMessenger, defaults: UserDefaults = .standard,
       observesSystem: Bool = true,
       makeSubscriptions: @escaping @MainActor () throws -> SubscriptionStore = { try SubscriptionStore() },
       loadPreferences: @escaping () async throws -> [NETunnelProviderManager] = {
         try await NETunnelProviderManager.loadAllFromPreferences()
       }) {
    commands = TunnelCommandCoordinator(defaults: defaults)
    settingsStore = TunnelSettingsStore(defaults: defaults)
    automationDefaults = defaults
    self.observesSystem = observesSystem
    self.loadPreferences = loadPreferences
    self.makeSubscriptions = makeSubscriptions
    channel = FlutterMethodChannel(name: "com.elarni/tunnel", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(Self.flutterError("unavailable")) }
      Task { @MainActor in
        let checksRevision = Self.automationMutationMethods.contains(call.method)
        let revision = checksRevision ? self.automationRevision() : nil
        defer { self.scheduleAutomation(); self.scheduleMaintenance() }
        do {
          // The recording stays reachable when the catalog cannot be opened, and never reconciles a connection.
          if call.method == "markRecording" {
            try await self.markRecording()
            return result([:])
          }
          if call.method == "exportRecording" {
            return result(try await self.exportRecording(headless: (call.arguments as? [String: Any])?["headless"] as? Bool == true))
          }
          // Stop must remain available even if the catalog cannot be opened.
          let stopping = ["disconnect", "repairTunnel"].contains(call.method)
          let store = stopping ? try? self.subscriptionStore() : try self.subscriptionStore()
          if store?.runtimeReconciliationRequired == true {
            try await self.commands.perform(intent: .disconnected) {
              try await self.reconcileInterruptedPublication()
            }
          }
          self.automationCommandReceived(call.method)
          if call.method == "setNodeIPPreference" {
            let arguments = try Self.arguments(call)
            guard let nodeID = arguments["nodeId"] as? String,
                  arguments["preference"] == nil || arguments["preference"] is NSNull || arguments["preference"] is String
            else { throw SubscriptionError.invalidFeed }
            result(try await self.subscriptionStore().setNodeIPPreference(nodeID: nodeID,
              preference: arguments["preference"] as? String).channelMap)
            return
          }
          if call.method == "selectProfileGroup" {
            let arguments = try Self.arguments(call)
            guard let nodeID = arguments["nodeId"] as? String, let group = arguments["group"] as? String,
                  let choice = arguments["choice"] as? String else { throw SubscriptionError.invalidFeed }
            result(try await self.subscriptionStore().selectProfileGroup(nodeID: nodeID, group: group, choice: choice).channelMap)
            return
          }
          if call.method == "importClientProfiles" {
            let arguments = try Self.arguments(call)
            let content: String
            switch arguments["source"] as? String ?? "text" {
            case "text":
              guard let value = arguments["content"] as? String else { throw SubscriptionError.invalidFeed }; content = value
            case "file": content = try RoutingImportReader.file()
            case "qrImage": content = try RoutingImportReader.qrImage()
            case "camera": content = try await RoutingImportReader.camera()
            default: throw SubscriptionError.invalidFeed
            }
            let store = try self.subscriptionStore()
            let input = try store.normalizeClientInput(content)
            if RoutingDomainDecoder.isRoutingInput(input.text) {
              try await self.commands.perform { _ = try await self.importRoutingContent(input.text) }
              result(SubscriptionOperationResult(snapshot: store.snapshot(), removedSelection: false, warning: nil).channelMap)
              return
            }
            var id = ""
            try await self.commands.perform { id = try store.registerProfiles(content) }
            result(try await store.refresh(id: id).channelMap)
            return
          }
          // Downloads must not occupy the connection command owner.
          if ["refreshSubscription", "addSubscription", "refreshRoutingGeofiles"].contains(call.method) {
            let arguments = try Self.arguments(call)
            let store = try self.subscriptionStore()
            if call.method == "addSubscription" {
              guard let url = arguments["url"] as? String else { throw SubscriptionError.invalidURL }
              var id = ""
              try await self.commands.perform { id = try store.register(urlText: url) }
              result(try await store.refresh(id: id).channelMap)
            } else {
              guard let id = arguments["id"] as? String else { throw SubscriptionError.notFound }
              if call.method == "refreshSubscription" {
                result(try await store.refresh(id: id, challenge: arguments["challenge"] as? String, format: arguments["format"] as? String).channelMap)
              } else {
                let refreshed = try await store.routing.refreshGeofiles(id: id, force: true, file: arguments["file"] as? String)
                try await self.commands.perform { await self.reclaimRoutingFiles() }
                result(refreshed)
              }
            }
            return
          }
          let intent: TunnelCommandCoordinator.Intent? = ["disconnect", "restoreCatalogBackup", "repairTunnel"].contains(call.method)
            ? .disconnected : (call.method == "connect" ? .connected : nil)
          let concurrentProbe = call.method == "pingNode" &&
            (call.arguments as? [String: Any])?["protocol"] as? String != "icmp"
          let readOnly = ["state", "subscriptions", "routingProfiles", "tunnelSettings", "inboundCredentials",
                          "automationStatus", "runtimeMetrics", "readLogs", "systemInfo", "routeTable"].contains(call.method)
          try await self.commands.perform(intent: intent, concurrent: concurrentProbe, readOnly: readOnly) {
            if !["disconnect", "restoreCatalogBackup", "repairTunnel"].contains(call.method) { try await self.reconcileDisconnectedIntent() }
            switch call.method {
            case "configureAutomation":
              result(try await self.configureAutomation(Self.arguments(call)))
            case "automationStatus":
              result(self.automationSnapshot())
            case "tunnelSettings":
              result(self.settingsStore.current.channelMap)
            case "inboundCredentials":
              result(try self.settingsStore.current.inboundCredentialRef.map { try self.subscriptionStore().inboundCredentials(ref: $0) } ?? [:])
            case "systemInfo":
              result(Self.systemInfo())
            case "setLaunchAtLogin":
              guard let enabled = try Self.arguments(call)["enabled"] as? Bool else {
                throw RunnerTunnelError.invalidSettings
              }
              do {
                let service = SMAppService.mainApp
                if enabled {
                  if service.status != .enabled && service.status != .requiresApproval {
                    try service.register()
                  }
                } else if service.status != .notRegistered {
                  try await service.unregister()
                }
                result(Self.systemInfo())
              } catch {
                let failure = error as NSError
                result(FlutterError(
                  code: "login_registration_failed",
                  message: "macOS could not update launch at login (\(failure.domain): \(failure.code)).",
                  details: Self.systemInfo()
                ))
              }
            case "routeTable":
              result(try await Task.detached { try Self.routeTable() }.value)
            case "updateTunnelSettings":
              let settings = try AppTunnelSettings(arguments: Self.arguments(call), base: self.settingsStore.current)
              let applied = try await self.apply(settings: settings)
              self.syncHostRecording()
              result(applied)
            case "updateInboundCredentials":
              let arguments = try Self.arguments(call)
              guard let username = arguments["username"] as? String,
                    let password = arguments["password"] as? String else {
                throw RunnerTunnelError.invalidSettings
              }
              let store = try self.subscriptionStore()
              let reference = try store.storeInboundCredentials(username: username, password: password)
              let previous = self.settingsStore.current.inboundCredentialRef
              var settings = self.settingsStore.current
              settings.inboundCredentialRef = reference
              settings.inboundAuthEnabled = true
              do {
                result(try await self.apply(settings: settings))
                if let previous { store.removeInboundCredentials(ref: previous) }
              } catch {
                if self.settingsStore.current.inboundCredentialRef != reference {
                  store.removeInboundCredentials(ref: reference)
                }
                throw error
              }
            case "subscriptions":
              result(try self.subscriptionStore().snapshot())
            case "setNodeFavorite":
              let arguments = try Self.arguments(call)
              guard let id = arguments["nodeId"] as? String, let favorite = arguments["favorite"] as? Bool else { throw SubscriptionError.invalidState }
              result(try self.subscriptionStore().setFavorite(nodeID: id, favorite: favorite))
            case "renameNode":
              let arguments = try Self.arguments(call)
              guard let id = arguments["nodeId"] as? String, let name = arguments["name"] as? String else { throw SubscriptionError.invalidState }
              result(try self.subscriptionStore().renameNode(id: id, name: name))
            case "deleteNode":
              let arguments = try Self.arguments(call)
              guard let id = arguments["nodeId"] as? String else { throw SubscriptionError.invalidState }
              result(try self.subscriptionStore().deleteNode(id: id))
            case "deleteNodes":
              let arguments = try Self.arguments(call)
              guard let ids = arguments["nodeIds"] as? [String] else { throw SubscriptionError.invalidState }
              result(try self.subscriptionStore().deleteNodes(ids: ids))
            case "showNode":
              let arguments = try Self.arguments(call)
              guard let id = arguments["nodeId"] as? String else { throw SubscriptionError.invalidState }
              result(try self.subscriptionStore().showNode(id: id))
            case "subscriptionDeviceID":
              let arguments = try Self.arguments(call)
              guard let id = arguments["id"] as? String else { throw SubscriptionError.invalidState }
              result(["deviceId": try self.subscriptionStore().deviceID(subscriptionID: id)])
            case "resetSubscriptionDeviceID":
              let arguments = try Self.arguments(call)
              guard let id = arguments["id"] as? String else { throw SubscriptionError.invalidState }
              result(try self.subscriptionStore().resetDeviceID(subscriptionID: id))
            case "routingProfiles":
              result(try self.subscriptionStore().routing.snapshot())
            case "importRouting":
              let arguments = try Self.arguments(call)
              guard let content = arguments["content"] as? String else {
                throw RoutingStoreError.invalidImport
              }
              result(try await self.importRoutingContent(content))
            case "updateRoutingProfile":
              let arguments = try Self.arguments(call)
              guard let id = arguments["id"] as? String,
                    let content = arguments["content"] as? String else {
                throw RoutingStoreError.invalidImport
              }
              let store = try self.subscriptionStore()
              result(try await self.performRoutingMutation(store) {
                try store.routing.update(id: id, content: content)
              })
            case "duplicateRoutingProfile":
              let arguments = try Self.arguments(call)
              guard let id = arguments["id"] as? String else { throw RoutingStoreError.notFound }
              result(try self.subscriptionStore().routing.duplicate(id: id))
            case "deleteRoutingProfile":
              let arguments = try Self.arguments(call)
              guard let id = arguments["id"] as? String else { throw RoutingStoreError.notFound }
              let store = try self.subscriptionStore()
              result(try await self.performRoutingMutation(store) {
                try store.routing.delete(id: id)
              })
            case "resetRoutingProfile":
              let arguments = try Self.arguments(call)
              guard let id = arguments["id"] as? String else { throw RoutingStoreError.notFound }
              let store = try self.subscriptionStore()
              result(try await self.performRoutingMutation(store) {
                try store.routing.reset(id: id)
              })
            case "setRoutingProfileEnabled":
              let arguments = try Self.arguments(call)
              guard let id = arguments["id"] as? String,
                    let enabled = arguments["enabled"] as? Bool else {
                throw RoutingStoreError.notFound
              }
              let store = try self.subscriptionStore()
              result(try await self.performRoutingMutation(store) {
                try store.routing.setEnabled(id: id, enabled: enabled)
              })
            case "assignRoutingProfile":
              let arguments = try Self.arguments(call)
              guard let subscriptionID = arguments["subscriptionId"] as? String else {
                throw RoutingStoreError.notFound
              }
              let store = try self.subscriptionStore()
              result(try await self.performRoutingMutation(store) {
                try store.routing.assign(
                  subscriptionID: subscriptionID,
                  profileID: arguments["profileId"] as? String
                )
              })
            case "updateSubscriptionFetchOptions":
              let arguments = try Self.arguments(call)
              guard let id = arguments["id"] as? String, let options = arguments["options"] as? [String: Any] else {
                throw SubscriptionError.invalidURL
              }
              result(try self.subscriptionStore().updateFetchOptions(id: id, options: options))
            case "exportCatalogBackup":
              guard let password = try Self.arguments(call)["password"] as? String else { throw SubscriptionError.invalidFeed }
              let sealed = try Self.invokeLibXray(method: "sealCatalogBackup",
                payload: ["catalog": try self.subscriptionStore().backupCatalog(), "password": password])
              guard let text = sealed["text"] as? String else { throw SubscriptionError.invalidFeed }
              if (call.arguments as? [String: Any])?["headless"] as? Bool == true {
                result(["text": text])
              } else {
                try CatalogBackupFile.save(text)
                result([:])
              }
            case "restoreCatalogBackup":
              try await self.stopForCatalogChange()
              guard let password = try Self.arguments(call)["password"] as? String else { throw SubscriptionError.invalidFeed }
              let arguments = try Self.arguments(call)
              let text: String
              if arguments["headless"] as? Bool == true {
                guard let content = arguments["content"] as? String,
                      content.utf8.count <= 12 * 1024 * 1024 else { throw SubscriptionError.invalidFeed }
                text = content
              } else { text = try CatalogBackupFile.open() }
              let opened = try Self.invokeLibXray(method: "openCatalogBackup",
                payload: ["text": text, "password": password])
              guard let payload = opened["catalog"] as? [String: Any] else { throw SubscriptionError.invalidFeed }
              let disabled = AutomationConfiguration()
              let disabledData = try JSONEncoder().encode(disabled)
              let store = try self.subscriptionStore()
              do {
                _ = try store.beginBackupRestore(payload)
                try await self.removeSavedPlan()
                try Task.checkCancellation()
                try store.finishBackupRestore()
              } catch {
                try store.rollbackPublication()
                throw error
              }
              // Per-app server targets name servers by ID, which the restore renumbered.
              try? self.settingsStore.save(self.settingsStore.current.remappingPerAppServers(store.restoredNodeIDs))
              self.invalidateAutomation(configuration: true)
              self.automationConfiguration = disabled
              self.automationDefaults.set(disabledData, forKey: Self.automationKey)
              self.automationUnreadable = false
              self.automationPaused = false
              self.automationStatus = "disabled"
              self.saveEpisode()
              self.scheduleMaintenance()
              await self.reclaimRoutingFiles()
              result(store.snapshot())
            case "repairTunnel":
              try await self.stopForCatalogChange()
              try await self.removeSavedPlan()
              result(["state": "disconnected"])
            case "renameSubscription":
              let arguments = try Self.arguments(call)
              guard let id = arguments["id"] as? String else {
                throw SubscriptionError.notFound
              }
              result(try self.subscriptionStore().rename(id: id, name: arguments["name"] as? String))
            case "openProviderLink":
              let arguments = try Self.arguments(call)
              guard let id = arguments["id"] as? String, let action = arguments["action"] as? String else { throw SubscriptionError.notFound }
              let url = try self.subscriptionStore().providerURL(subscriptionID: id, action: action)
              guard NSWorkspace.shared.open(url) else { throw SubscriptionError.invalidURL }
              result(["opened": true])
            case "shareClient":
              let args = try Self.arguments(call)
              guard let id = args["id"] as? String else { throw SubscriptionError.notFound }
              let text = try self.subscriptionStore().sharingText(id: id, subscription: args["subscription"] as? Bool == true)
              var shared = try Self.invokeLibXray(method: "clientQR", payload: ["text": text])
              shared["text"] = text
              result(shared)
            case "openTelegramProxy":
              guard let id = try Self.arguments(call)["id"] as? String else { throw SubscriptionError.notFound }
              let url = try self.subscriptionStore().telegramURL(nodeID: id)
              guard NSWorkspace.shared.open(url) else { throw SubscriptionError.invalidURL }
              result(["opened": true])
            case "openUpdateLink":
              // Only the https page an update feed named; the Flutter UI reads the feed itself.
              guard let text = try Self.arguments(call)["url"] as? String, text.utf8.count <= 2048,
                    let url = URL(string: text), url.scheme == "https", url.host?.isEmpty == false else {
                throw SubscriptionError.invalidURL
              }
              guard NSWorkspace.shared.open(url) else { throw SubscriptionError.invalidURL }
              result(["opened": true])
            case "deleteSubscription":
              let arguments = try Self.arguments(call)
              guard let id = arguments["id"] as? String else {
                throw SubscriptionError.notFound
              }
              let store = try self.subscriptionStore()
              let previousRouting = try store.routing.checkpoint()
              let previousRevision = try store.routing.runtimeRevision(subscriptionID: store.selectedSubscriptionID())
              if store.removesSelection(subscriptionID: id) {
                try self.commands.persist(.disconnected)
                try await self.stopForCatalogChange()
                try await self.removeSavedPlan()
              }
              var synchronized = false
              let deleted: (snapshot: [String: Any], removedSelection: Bool)
              do {
                deleted = try await store.delete(id: id) {
                  let revision = try store.routing.runtimeRevision(subscriptionID: store.selectedSubscriptionID())
                  if store.selectedNodeID() != nil && revision != previousRevision {
                    _ = try await self.performRoutingMutation(store, checkpoint: previousRouting) {
                      store.routing.snapshot()
                    }
                    synchronized = true
                  }
                }
              } catch {
                if synchronized && !Task.isCancelled {
                  _ = try await self.performRoutingMutation(store) { store.routing.snapshot() }
                }
                throw error
              }
              self.scheduleMaintenance()
              await self.reclaimRoutingFiles()
              result(deleted.snapshot)
            case "selectNode":
              let arguments = try Self.arguments(call)
              guard let id = arguments["id"] as? String else {
                throw SubscriptionError.notFound
              }
              let selection = try await self.selectNode(id: id)
              // The picked server becomes the primary; the allowed backups stay.
              if self.automationConfiguration.enabled {
                var next = self.automationConfiguration
                next.nodeIDs = [id] + (next.policy == .fixed ? [] : next.nodeIDs.filter { $0 != id }.prefix(999))
                next.russianEntryNodeIDs = next.russianEntryNodeIDs?.filter(next.nodeIDs.contains)
                next.subscriptionID = try self.subscriptionStore().subscriptionID(nodeID: id)
                self.automationConfiguration = next
                self.automationDefaults.set(try JSONEncoder().encode(next), forKey: Self.automationKey)
              }
              result(selection)
            case "connect":
              try await self.prepareSelectedConnection()
#if DEBUG
              if let text = (call.arguments as? [String: Any])?["debugFaultID"] as? String {
                guard let id = UUID(uuidString: text), !self.automationConfiguration.enabled,
                      (try? ProviderDebugFaults.read(id: id)) == nil else {
                  throw RunnerTunnelError.invalidSettings
                }
                let fault = ProviderDebugFaults.Request(id: id, action: .startupFailure,
                  expiresAt: ProcessInfo.processInfo.systemUptime + 30, instanceID: nil, generation: nil)
                try await self.connect(options: ["elarniDebugFault": try JSONEncoder().encode(fault) as NSData])
              } else {
                try await self.connect()
              }
#else
              try await self.connect()
#endif
              result(["state": "connecting"])
#if DEBUG
            case "debugFault":
              result(try await self.debugFault(Self.arguments(call)))
            case "debugFaultReceipt":
              guard let text = try Self.arguments(call)["id"] as? String, let id = UUID(uuidString: text) else {
                throw RunnerTunnelError.invalidSettings
              }
              if let receipt = try? ProviderDebugFaults.read(id: id) {
                result(try JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)))
              } else { result(["outcome": "pending"]) }
#endif
            case "disconnect":
              try await self.disconnect()
#if DEBUG
              guard let stoppedAt = self.debugStopCompletedAtMs,
                    let osDisconnectedAt = self.debugOSDisconnectedAtMs else { throw RunnerTunnelError.invalidState }
              result(["state": self.stateName(self.manager?.connection.status ?? .disconnected),
                      "stoppedAtMs": stoppedAt, "osDisconnectedAtMs": osDisconnectedAt])
#else
              result(["state": self.stateName(self.manager?.connection.status ?? .disconnected)])
#endif
            case "state":
              let state: String
              do { state = self.stateName(try await self.loadManager().connection.status) }
              // A successful preferences read with no Elarni profile is a
              // known disconnected state. Actual query errors still propagate.
              catch RunnerTunnelError.notPrepared { state = "disconnected" }
              let metrics = state == "connected" ? try? await self.runtimeMetrics() : nil
              result(["state": state,
                      "connectionIntent": self.commands.intent?.rawValue ?? "unknown",
                      "liveness": (metrics?["liveness"] as? String).map { $0 as Any } ?? NSNull()])
            case "runtimeMetrics":
              result(try await self.runtimeMetrics())
            case "readLogs":
              let after = ((call.arguments as? [String: Any])?["after"] as? NSNumber)?.int64Value ?? 0
              result(try await self.readLogs(after: after))
            case "saveLogs":
              try self.saveLogs((call.arguments as? [String: Any])?["content"] as? String)
              result([:])
            case "pingNode":
              result(try await self.pingNode(arguments: Self.arguments(call)))
            case "exportEvidence":
              result(try await self.exportEvidence(issueCodes: (call.arguments as? [String: Any])?["issueCodes"] as? [String] ?? [],
                headless: (call.arguments as? [String: Any])?["headless"] as? Bool == true))
            default:
              result(FlutterMethodNotImplemented)
            }
          }
          if checksRevision && self.automationRevision() != revision {
            self.invalidateAutomation(configuration: true)
            self.automation.rearm(now: self.automationNow())
            self.automationPaused = false
            self.saveEpisode()
          }
        } catch is CancellationError {
          result(Self.flutterError("operation_cancelled"))
        } catch DiagnosticLog.Failure.empty {
          result(Self.flutterError("recording_empty"))
        } catch TunnelCommandCoordinator.Failure.unreadableIntent {
          result(Self.flutterError("connection_intent_unreadable"))
        } catch RunnerTunnelError.onDemandSuspensionFailed {
          result(Self.flutterError("on_demand_suspension_failed"))
        } catch RunnerTunnelError.disconnectTimedOut {
          result(Self.flutterError("disconnect_timed_out"))
        } catch RunnerTunnelError.connectionIntentRequired {
          result(Self.flutterError("connection_intent_required"))
        } catch RunnerTunnelError.nodeSwitchFailedRestored {
          result(Self.flutterError("node_switch_failed_restored"))
        } catch RunnerTunnelError.nodeSwitchRestoreFailed {
          result(Self.flutterError("node_switch_restore_failed"))
        } catch RunnerTunnelError.icmpFailedRestored {
          result(Self.flutterError("icmp_failed_restored"))
        } catch RunnerTunnelError.icmpRestoreFailed {
          result(Self.flutterError("icmp_restore_failed"))
        } catch RunnerTunnelError.unsupportedPingMethod {
          result(FlutterError(code: "unsupported_ping_method", message: "Direct TCP is not supported by this endpoint's transport. Use Proxy testing.", details: nil))
        } catch RunnerTunnelError.listenerUnavailable(let port) {
          result(FlutterError(code: "listener_unavailable", message: "Port \(port) is occupied or unavailable. Choose another listener port.", details: nil))
        } catch RunnerTunnelError.perAppTargetMissing {
          result(FlutterError(code: "per_app_target_missing", message: "An app in Per-app routing uses a server that no longer exists. Choose another target for it in Per-app routing.", details: nil))
        } catch RunnerTunnelError.invalidRouteEnforcement {
          result(FlutterError(code: "invalid_route_enforcement", message: "Route enforcement requires specific included routes and Include all networks off. For a full tunnel, turn enforcement off and use Include all networks.", details: nil))
        } catch let failure as RunnerProbeFailure {
          result(FlutterError(code: "operation_failed", message: "Proxy probe failed", details: failure.details))
        } catch let failure as AutomationFailure {
          result(Self.flutterError("automation_" + failure.rawValue))
        } catch RoutingStoreError.noSelectedSubscription {
          result(FlutterError(code: "no_selected_subscription", message: Self.noSelectionMessage, details: nil))
        } catch RoutingStoreError.routeModelTooLarge {
          result(FlutterError(code: "route_model_too_large", message: "This routing profile is too large: its rules and lists exceed 8 MB. Remove some rules or managed lists.", details: nil))
        } catch RoutingStoreError.missingGeodata(let missing) {
          result(FlutterError(code: "missing_geodata", message: "Proxy rules and servers need codes the geofiles lack: \(missing.joined(separator: ", ")). Fix the profile or its geofile links.", details: nil))
        } catch SubscriptionError.incompatibleProfile(let message) {
          result(FlutterError(code: "unsupported_profile", message: message, details: nil))
        } catch SubscriptionError.invalidFeed {
          result(FlutterError(code: "invalid_profile", message: "The input is not a valid client profile or subscription.", details: nil))
        } catch RunnerTunnelError.invalidState {
          result(Self.flutterError("connection_failed"))
        } catch RunnerTunnelError.notPrepared {
          result(Self.flutterError("native_unavailable"))
        } catch SubscriptionError.keychainFailure {
          result(Self.flutterError("missing_credentials"))
        } catch SubscriptionError.fetchClass(let code) {
          result(Self.flutterError(code))
        } catch SubscriptionError.fetchFailed {
          result(Self.flutterError("fetch_failed"))
        } catch RunnerTunnelError.invalidSettings {
          result(Self.flutterError("invalid_settings"))
        } catch {
          let failure = error as NSError
          result(Self.flutterError(failure.domain == NEVPNErrorDomain ? "vpn_configuration_failed" : "operation_failed"))
        }
      }
    }
    guard observesSystem else { return }
    syncHostRecording()
    deepLinkObserver = NotificationCenter.default.addObserver(
      forName: RoutingDeepLinkInbox.notification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        await self?.processDeepLinks(RoutingDeepLinkInbox.takeAll())
      }
    }
    Task { @MainActor [weak self] in
      await self?.processDeepLinks(RoutingDeepLinkInbox.takeAll())
    }
    Task { @MainActor [weak self] in
      guard let self else { return }
      try? await self.commands.perform {
        try await self.reconcileDisconnectedIntent()
        try await self.reconcileInterruptedPublication()
      }
      self.startAutomationObservation()
      self.scheduleMaintenance()
    }
  }

  deinit {
    channel.setMethodCallHandler(nil)
    if let deepLinkObserver { NotificationCenter.default.removeObserver(deepLinkObserver) }
    automationTimer?.cancel()
    maintenanceTimer?.cancel()
    maintenanceWork?.cancel()
    automationWork?.cancel()
    pathMonitors.forEach { $0.cancel() }
    for observer in automationObservers {
      NotificationCenter.default.removeObserver(observer)
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
    }
  }

  @MainActor
  private func processDeepLinks(_ values: [String]) async {
    var failure: String?
    for value in values {
      do {
        try Task.checkCancellation()
        let action = TunnelCommandCoordinator.connectionAction(from: value)
        // Capture Toggle before recovery changes intent; a requested Stop must
        // not turn into Connect after the interrupted publication is reconciled.
        let requestedMethod = action == "toggle" ? (commands.intent == .connected ? "disconnect" : "connect") : action
        let stopping = requestedMethod == "disconnect"
        if stopping { guard await confirmLink(String(localized: "A link asks Elarni to disconnect."), action: String(localized: "Disconnect")) else { continue } }
        let recoveryStore = stopping ? try? subscriptionStore() : try subscriptionStore()
        if recoveryStore?.runtimeReconciliationRequired == true {
          try await commands.perform(intent: .disconnected) {
            try await self.reconcileInterruptedPublication()
          }
        }
        if let method = requestedMethod {
          NSApp.mainWindow?.deminiaturize(nil)
          NSApp.activate(ignoringOtherApps: true)
          if method == "status" { continue }
          automationCommandReceived(method)
          defer { scheduleAutomation(); scheduleMaintenance() }
          try await commands.perform(intent: method == "disconnect" ? .disconnected : .connected) {
            if method == "disconnect" {
              try await self.disconnect()
            } else {
              try await self.reconcileDisconnectedIntent()
              try await self.prepareSelectedConnection()
              try await self.connect()
            }
          }
          continue
        }
        let store = try subscriptionStore()
        let input = try store.normalizeClientInput(value)
        let routing = RoutingDomainDecoder.isRoutingLink(input.text)
        guard await confirmLink(routing ? String(localized: "A link wants to import a routing profile.") : String(localized: "A link wants to import a client profile."),
                                action: String(localized: "Import")) else { continue }
        if routing {
          try await commands.perform { _ = try await self.importRoutingContent(input.text) }
        } else {
          var id = ""
          try await commands.perform { id = try store.registerProfiles(value) }
          _ = try await store.refresh(id: id)
        }
      } catch RoutingStoreError.noSelectedSubscription { failure = failure ?? Self.noSelectionMessage }
      catch { failure = failure ?? "One or more client links could not be handled. Check the link and connection status." }
    }
    channel.invokeMethod("subscriptionsChanged", arguments: failure.map { ["error": $0] })
  }

  // Links come from web pages and other apps; imports and stops wait for the user.
  @MainActor
  private func confirmLink(_ message: String, action: String) async -> Bool {
    let alert = NSAlert()
    alert.messageText = String(localized: "Open Elarni link?")
    alert.informativeText = message
    alert.addButton(withTitle: action)
    alert.addButton(withTitle: String(localized: "Cancel"))
    NSApp.activate(ignoringOtherApps: true)
    guard let window = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.canBecomeMain }) else {
      return alert.runModal() == .alertFirstButtonReturn
    }
    window.deminiaturize(nil)
    window.makeKeyAndOrderFront(nil)
    return await withCheckedContinuation { done in
      alert.beginSheetModal(for: window) { done.resume(returning: $0 == .alertFirstButtonReturn) }
    }
  }

  @MainActor
  private func exportEvidence(issueCodes: [String], headless: Bool = false) async throws -> [String: Any] {
    let state: String
    do { state = stateName(try await loadManager().connection.status) }
    catch RunnerTunnelError.notPrepared { state = "disconnected" }
    catch { state = "unavailable" }
    let evidence = ConnectionSupportSnapshot.make(state: state,
      provider: (try? await runtimeMetrics()) ?? [:], automation: automationSnapshot(), issueCodes: issueCodes)
    if headless { return evidence }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "elarni-diagnostics.json"
    panel.title = String(localized: "Save connection diagnostics")
    guard panel.runModal() == .OK, let url = panel.url else { throw CancellationError() }
    let data = try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys, .prettyPrinted])
    try data.write(to: url, options: [.atomic])
    return evidence
  }

  func writeLogLevel(_ level: String) {
    guard let directory = logsDirectory() else { return }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? Data(level.utf8).write(to: directory.appendingPathComponent("level"), options: [.atomic])
  }

  @MainActor
  func readLogs(after: Int64) async throws -> [String: Any] {
    var value: [String: Any] = [:]
    if let selected = try? await loadManager(), let session = selected.connection as? NETunnelProviderSession,
       [.connected, .reasserting].contains(selected.connection.status) {
      // A running extension that did not answer is asked again, not mistaken for one that stopped.
      let request = try JSONSerialization.data(withJSONObject: ["operation": "logs", "after": after])
      guard let response = try await sendProviderMessage(request, session: session),
            let object = try JSONSerialization.jsonObject(with: response) as? [String: Any] else {
        throw RunnerTunnelError.invalidState
      }
      value = object
    } else if let url = logsDirectory()?.appendingPathComponent("last.json"),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      value = object
      value["entries"] = (object["entries"] as? [[String: Any]] ?? []).filter {
        (($0["seq"] as? NSNumber)?.int64Value ?? 0) > after
      }
    }
    value["level"] = settingsStore.current.logLevel
    if value["entries"] == nil { value["entries"] = [[String: Any]]() }
    return value
  }

  @MainActor
  func saveLogs(_ content: String?) throws {
    guard let content, !content.isEmpty, content.utf8.count <= 4 * 1024 * 1024 else {
      throw RunnerTunnelError.invalidSettings
    }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "elarni-log.txt"
    panel.title = String(localized: "Save the Elarni log")
    guard panel.runModal() == .OK, let url = panel.url else { throw CancellationError() }
    try Data(content.utf8).write(to: url, options: [.atomic])
  }

  @MainActor
  func runtimeMetrics() async throws -> [String: Any] {
    let selected: NETunnelProviderManager
    do { selected = try await loadManager() }
    catch RunnerTunnelError.notPrepared { return [:] }
    guard let session = selected.connection as? NETunnelProviderSession,
          [.connected, .reasserting].contains(selected.connection.status),
          let response = try await sendProviderMessage(Data("state".utf8), session: session),
          let object = try JSONSerialization.jsonObject(with: response) as? [String: Any] else {
      return [:]
    }
    if object["state"] as? String == "connected", commands.intent == .connected,
       let instance = object["instanceID"] as? String, let generation = object["generation"] as? UInt64,
       let store = try? subscriptionStore(), let node = store.selectedNodeID() {
      do {
        let routing = try store.routing.runtimeRevision(subscriptionID: store.subscriptionID(nodeID: node))
        let plan = try makePlan(secretRef: store.outboundRef(nodeID: node), routingRevision: routing)
        if object["configurationDigest"] as? String == Data(SHA256.hash(data: plan)).base64EncodedString() {
          try store.recordSuccess(nodeID: node, revision: store.configurationRevision(nodeID: node), session: "\(instance):\(generation)")
        }
      } catch { /* A failed history write must not change the connection. */ }
    }
    return object
  }

  @MainActor
  private func importRoutingContent(_ content: String) async throws -> [String: Any] {
    let store = try subscriptionStore()
    return try await performRoutingMutation(store) {
      _ = try store.routing.importContent(
        content,
        selectedSubscriptionID: store.selectedSubscriptionID()
      )
      return store.routing.snapshot()
    }
  }

  @MainActor
  private func performRoutingMutation(
    _ store: SubscriptionStore,
    checkpoint savedCheckpoint: Data? = nil,
    mutation: () async throws -> [String: Any]
  ) async throws -> [String: Any] {
    let checkpoint = try savedCheckpoint ?? store.routing.checkpoint()
    if savedCheckpoint == nil {
      // Compiling every server validates the edit before it reaches the tunnel.
      let stage = try store.routing.beginStaging()
      let proposed: Data
      do {
        _ = try await mutation()
        try store.validateNodes()
        proposed = try store.routing.checkpoint()
        try store.routing.endStaging(stage)
      } catch {
        try store.routing.endStaging(stage)
        throw error
      }
      return try await performRoutingMutation(store, checkpoint: checkpoint) {
        try store.routing.restore(proposed)
        return store.routing.snapshot()
      }
    }
    let selected: NETunnelProviderManager?
    do { selected = try await loadManager() }
    catch RunnerTunnelError.notPrepared { selected = nil }
    try Task.checkCancellation()
    let active = selected.map { [.connected, .reasserting].contains($0.connection.status) } ?? false
    if active && commands.intent != .connected { throw RunnerTunnelError.connectionIntentRequired }
    if let selected, !active && ![.disconnected, .invalid].contains(selected.connection.status) {
      throw RunnerTunnelError.invalidState
    }
    let previousPlan = (selected?.protocolConfiguration as? NETunnelProviderProtocol)?
      .providerConfiguration?["planPayload"] as? Data
    defer { scheduleMaintenance() }
    do {
      _ = try await mutation()
      try await store.routing.prepareAssets(subscriptionID: store.selectedSubscriptionID())
      try Task.checkCancellation()
      if let node = store.selectedNodeID() {
        let revision = try store.routing.runtimeRevision(subscriptionID: store.subscriptionID(nodeID: node))
        if let plan = try planUnlessTargetMissing(secretRef: store.outboundRef(nodeID: node),
                                                  routingRevision: revision, active: active) {
          try await applyRefreshPlan(plan, previous: previousPlan, selected: active ? selected : nil, health: nil)
        }
      }
      await reclaimRoutingFiles()
      return store.routing.snapshot()
    } catch {
      try store.routing.restore(checkpoint)
      throw error
    }
  }

  @MainActor
  func reclaimRoutingFiles() async {
    guard let store = subscriptions, !store.publicationInProgress, !store.publicationRecoveryRequired else { return }
    do {
      let selected: NETunnelProviderManager?
      do { selected = try await loadManager() }
      catch RunnerTunnelError.notPrepared { selected = nil }
      guard selected == nil || [.disconnected, .invalid].contains(selected!.connection.status),
            !store.publicationInProgress, !store.publicationRecoveryRequired else { return }
      var routes = Set<String>(), assets = Set<String>()
      if let selected {
        guard let configuration = (selected.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration,
              let payload = configuration["planPayload"] as? Data,
              let digest = configuration["planDigest"] as? Data else { return }
        guard Data(SHA256.hash(data: payload)) == digest,
              let plan = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              plan["schemaVersion"] as? Int == 1,
              plan["routingRevision"] == nil || plan["routingRevision"] is String,
              plan["assetRevision"] == nil || plan["assetRevision"] is String else { return }
        if let name = plan["routingRevision"] as? String { routes.insert(name) }
        if let revision = plan["assetRevision"] as? String { assets.insert(revision) }
      }
      try store.routing.reclaimUnusedFiles(routeNames: routes, assetRevisions: assets)
    } catch { /* Retain files when the live/durable references cannot be established. */ }
  }

  /// The host records network changes and the marks made while no tunnel runs.
  func syncHostRecording() {
    if DiagnosticLog.always || settingsStore.current.recordDiagnostics {
      DiagnosticLog.start(role: "host")
    } else {
      DiagnosticLog.stop()
    }
  }

  func diagnosticProvider(mark: Bool) async -> Bool {
    guard let selected = try? await loadManager(),
          [.connected, .reasserting].contains(selected.connection.status),
          let session = selected.connection as? NETunnelProviderSession,
          let response = try? await sendProviderMessage(Data((mark ? "diagnostics_mark" : "diagnostics_flush").utf8), session: session),
          let reply = try? JSONSerialization.jsonObject(with: response) as? [String: Any] else { return false }
    let recorded = reply["recorded"] as? Bool == true
    DiagnosticLog.record("app_state", ["provider_flush_ok": recorded ? 1 : 0])
    return recorded
  }

  /// The provider's mark lists its open connections; the host's still dates a failed connect.
  func markRecording() async throws {
    if await diagnosticProvider(mark: true) { return }
    try await DiagnosticLog.perform("mark")
  }

  /// The sandboxed app cannot write a CLI's path, so a headless export returns a file in its temporary folder.
  private func exportRecording(headless: Bool) async throws -> [String: Any] {
    _ = await diagnosticProvider(mark: false)
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("Elarni-recording-\(UUID().uuidString).zip")
    try await DiagnosticLog.perform("export", destination: file)
    if headless { return ["path": file.path] }
    defer { try? FileManager.default.removeItem(at: file) }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "Elarni-recording.zip"
    panel.title = String(localized: "Save connection recording")
    guard panel.runModal() == .OK, let url = panel.url else { throw CancellationError() }
    try Data(contentsOf: file, options: .mappedIfSafe).write(to: url, options: [.atomic])
    return [:]
  }

  @MainActor
  func subscriptionStore() throws -> SubscriptionStore {
    if let subscriptions {
      guard !subscriptions.publicationRecoveryRequired else { throw SubscriptionError.invalidState }
      return subscriptions
    }
    let store = try makeSubscriptions()
    store.autoUpdateInterval = { [weak self] in
      Double(self?.settingsStore.current.subscriptionAutoUpdateHours ?? 4) * 3600
    }
    store.previewContext = { [weak self] in
      guard let self else { return "" }
      let settings = self.settingsStore.current
      let value: [String: Any] = ["runtime": settings.compilerRuntime,
        "backend": settings.xrayTunEnabled, "profileIP": settings.profilePreferredIP ?? "inherit"]
      return (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).base64EncodedString()) ?? ""
    }
    store.compilePreview = { [weak self, weak store] outbound, routes, preference in
      guard let self, let store else { throw CancellationError() }
      let settings = self.settingsStore.current.applyingIPPreference(preference)
      var runtime = settings.compilerRuntime
      if settings.inboundAuthEnabled, let ref = settings.inboundCredentialRef {
        runtime["inboundAuth"] = try store.inboundCredentials(ref: ref)
      }
      let text = try Self.compilePingConfig(outbound: outbound, socksPort: settings.socksPort, routes: routes,
        runtime: runtime, profilePreferredIP: settings.profilePreferredIP,
        packetBackend: settings.xrayTunEnabled ? "xrayTun" : "nativeTun2Proxy")
      guard let config = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { throw SubscriptionError.invalidFeed }
      return config
    }
    subscriptions = store
    // Other local apps must not reach a fresh install's listeners without a login (v2rayNG #5457).
    // Without a keychain the install keeps unauthenticated listeners rather than failing to open.
    if settingsStore.isFresh, settingsStore.current.inboundCredentialRef == nil {
      let token = { (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined() }
      if let reference = try? store.storeInboundCredentials(username: token(), password: token()) {
        var settings = settingsStore.current
        settings.inboundCredentialRef = reference
        settings.inboundAuthEnabled = true
        if (try? settingsStore.save(settings)) == nil { store.removeInboundCredentials(ref: reference) }
      }
    }
    store.publishRefresh = { [weak self, weak store] candidate in
      guard let self, let store else { throw CancellationError() }
      try await self.commands.perform {
        try await self.publishSubscription(candidate, store: store)
      }
    }
    store.routing.publishManaged = { [weak self, weak store] candidate in
      guard let self, let store else { throw CancellationError() }
      try await self.commands.perform {
        guard !store.publicationRecoveryRequired else { throw SubscriptionError.invalidState }
        try store.routing.requireCandidate(candidate)
        _ = try await self.performRoutingMutation(store) {
          try store.routing.publish(candidate)
          return store.routing.snapshot()
        }
      }
    }
    return store
  }

  @MainActor
  private func reconcileInterruptedPublication() async throws {
    let store = try subscriptionStore()
    guard store.runtimeReconciliationRequired else { return }
    // The provider can outlive a host crash after candidate activation. A rolled
    // back catalog is not proof that the runtime or OS-saved plan rolled back.
    if commands.intent != .disconnected { try commands.persist(.disconnected) }
    invalidateAutomation()
    automation.stop()
    automationStatus = "stopped"
    saveEpisode()
    let selected: NETunnelProviderManager?
    do { selected = try await loadManager() }
    catch RunnerTunnelError.notPrepared { selected = nil }
    if let selected {
      if selected.connection.status == .invalid {
        // There is no active tunnel to stop; discard the unusable saved plan.
        try await removeSavedPlan()
      } else {
        try await disconnect()
        if store.selectedNodeID() != nil { try await synchronizeSelectedPlan(store) }
        else { try await removeSavedPlan() }
      }
    }
    try Task.checkCancellation()
    try commands.requireReadableIntent()
    try store.finishRuntimeReconciliation()
    try? store.reclaimRetiredSecrets()
    await reclaimRoutingFiles()
  }

  @MainActor
  private func publishSubscription(_ candidate: RefreshCandidate, store: SubscriptionStore) async throws {
    let selected: NETunnelProviderManager?
    do { selected = try await loadManager() }
    catch RunnerTunnelError.notPrepared { selected = nil }
    try Task.checkCancellation()
    let previousPlan = (selected?.protocolConfiguration as? NETunnelProviderProtocol)?
      .providerConfiguration?["planPayload"] as? Data
    let active = selected.map { [.connected, .reasserting].contains($0.connection.status) } ?? false
    if active && commands.intent != .connected { throw RunnerTunnelError.connectionIntentRequired }
    if let selected, !active && ![.disconnected, .invalid].contains(selected.connection.status) {
      throw RunnerTunnelError.invalidState
    }
    let removed = try store.beginPublication(candidate)
    var released = selected == nil || selected?.connection.status == .disconnected || selected?.connection.status == .invalid
    var applied = false
    var stopped = false
    var stoppedIntent = false
    do {
      try await store.routing.prepareAssets(subscriptionID: store.selectedSubscriptionID())
      if removed {
        var replaced = false
        if active, automationConfiguration.enabled, automationConfiguration.policy != .fixed {
          let deadline = automationNow() + 60
          let nodes = automation.round(nodes: automationConfiguration.nodeIDs, current: nil, now: automationNow())
          for node in nodes {
            try Task.checkCancellation()
            guard automationNow() < deadline else { break }
            guard let context = try? automationContext(nodeID: node) else { continue }
            do {
              try requireProbePolicy(subscriptionID: store.subscriptionID(nodeID: node))
              try await applyRefreshPlan(context.plan, previous: previousPlan, selected: selected, health: context)
              applied = true
              try store.commitSelection(nodeID: node)
              replaced = true
              released = true
              break
            } catch is CancellationError { throw CancellationError() }
            catch RunnerTunnelError.nodeSwitchRestoreFailed { throw RunnerTunnelError.nodeSwitchRestoreFailed }
            catch { automationCandidateFailures[node] = "refreshReplacementFailed" }
          }
        }
        if !replaced {
          if selected != nil { try await disconnect() }
          stopped = true
          released = true
          automationStatus = "selectedNodeRemoved"
        }
      } else if let node = store.selectedNodeID() {
        let revision = try store.routing.runtimeRevision(subscriptionID: store.subscriptionID(nodeID: node))
        if let plan = try planUnlessTargetMissing(secretRef: store.outboundRef(nodeID: node),
                                                  routingRevision: revision, active: active) {
          try await applyRefreshPlan(plan, previous: previousPlan, selected: active ? selected : nil, health: nil)
        }
        applied = true
        released = true
      }
      try Task.checkCancellation()
      if stopped, commands.intent == .connected {
        try commands.persist(.disconnected)
        stoppedIntent = true
      }
      try store.finishPublication(candidate)
    } catch {
      // Restore durable state even when Stop cancelled this operation. Stop owns the next transition.
      try store.rollbackPublication()
      if !Task.isCancelled, stoppedIntent { try commands.persist(.connected) }
      if !Task.isCancelled, active, applied || stopped, let selected, let previousPlan {
        if !stopped { try await switchProvider(plan: previousPlan, selected: selected) }
        try await persistPlan(previousPlan)
        if stopped { try await connect(); try await waitForConnected() }
      }
      throw error
    }
    if released {
      try? store.reclaimRetiredSecrets()
      await reclaimRoutingFiles()
    }
    invalidateAutomation(configuration: true)
  }

  @MainActor
  private func applyRefreshPlan(_ plan: Data, previous: Data?, selected: NETunnelProviderManager?,
                                health: AutomationContext?) async throws {
    // Feed timestamps and display metadata must not interrupt the active tunnel.
    guard plan != previous else { return }
    try await validateRefreshPlan(plan)
    var activated = false
    do {
      if let selected {
        try await switchProvider(plan: plan, selected: selected)
        activated = true
        if let health { _ = try await activeHealth(health) }
      }
      try Task.checkCancellation()
      try await persistPlan(plan)
    } catch {
      if activated, !Task.isCancelled, let selected, let previous {
        do {
          try await switchProvider(plan: previous, selected: selected)
          try await persistPlan(previous)
        } catch { throw RunnerTunnelError.nodeSwitchRestoreFailed }
      }
      throw error
    }
  }

  @MainActor
  private func validateRefreshPlan(_ plan: Data) async throws {
    guard let object = try JSONSerialization.jsonObject(with: plan) as? [String: Any],
          let reference = object["secretRef"] as? String,
          let executable = Bundle.main.url(forAuxiliaryExecutable: "elarni-core") else {
      throw RunnerTunnelError.invalidSettings
    }
    let store = try subscriptionStore()
    let nodeID = try store.nodeID(secretRef: reference)
    let outbound = try store.outbound(nodeID: nodeID)
    let routing = try store.routing.runtimeProbeConfiguration(subscriptionID: store.subscriptionID(nodeID: nodeID))
    let settings = settingsStore.current.applyingIPPreference(try store.ipPreference(nodeID: nodeID))
    var runtime = settings.compilerRuntime
    if settings.inboundAuthEnabled, let ref = settings.inboundCredentialRef {
      runtime["inboundAuth"] = try store.inboundCredentials(ref: ref)
    }
    let config = try Self.compilePingConfig(outbound: outbound, socksPort: settings.socksPort,
      routes: routing.routes, runtime: runtime, assetDirectory: routing.assetDirectory,
      profilePreferredIP: settings.profilePreferredIP,
      packetBackend: object["backend"] as? String ?? "nativeTun2Proxy")
    do { try await ProbeProcess.validate(config: config, executable: executable) }
    catch is CancellationError { throw CancellationError() }
    catch { throw RunnerTunnelError.invalidSettings }
    try Task.checkCancellation()
  }

  @MainActor
  func suspendMaintenance() {
    maintenanceTimer?.cancel(); maintenanceTimer = nil
    // Publishing may change the observed path itself; Stop still cancels its command owner.
    if subscriptions?.publicationInProgress != true {
      maintenanceWork?.cancel()
      subscriptions?.cancelRefreshes()
    }
    subscriptions?.routing.cancelManagedRefreshes()
  }

  @MainActor
  func scheduleMaintenance() {
    guard observesSystem else { return }
    maintenanceTimer?.cancel(); maintenanceTimer = nil
    guard maintenanceWork == nil, !automation.sleeping, automation.online,
          let store = try? subscriptionStore(), !store.runtimeReconciliationRequired else { return }
    guard let due = [store.nextRefreshDate(), store.routing.nextManagedDate(), store.routing.nextGeofileDate()]
      .compactMap({ $0 }).min() else { return }
    let delay = max(0, due.timeIntervalSince(maintenanceNow()))
    let sleep = automationSleep
    maintenanceTimer = Task { @MainActor [weak self] in
      do { try await sleep(delay) } catch { return }
      guard let self, !Task.isCancelled else { return }
      self.maintenanceTimer = nil
      self.maintenanceWork = Task { @MainActor in
        defer { self.maintenanceWork = nil; self.scheduleMaintenance() }
        // Snapshot once: wake/startup never replays missed periodic intervals.
        let subscriptions = store.dueSubscriptions()
        let sources = store.routing.dueManagedSources()
        let geofiles = store.routing.dueGeofiles()
        for id in subscriptions {
          if Task.isCancelled || store.publicationRecoveryRequired { return }
          _ = try? await store.refresh(id: id, interactive: false)
          self.channel.invokeMethod("subscriptionsChanged", arguments: nil)
        }
        for source in sources {
          if Task.isCancelled || store.publicationRecoveryRequired { return }
          try? await store.routing.refreshManaged(id: source.profileID, sourceID: source.sourceID)
        }
        for id in geofiles {
          if Task.isCancelled || store.publicationRecoveryRequired { return }
          _ = try? await store.routing.refreshGeofiles(id: id)
        }
        try? await self.commands.perform { await self.reclaimRoutingFiles() }
      }
    }
  }

  nonisolated private static func systemInfo() -> [String: Any] {
    let process = ProcessInfo.processInfo
    let loginStatus: String
    switch SMAppService.mainApp.status {
    case .notRegistered: loginStatus = "notRegistered"
    case .enabled: loginStatus = "enabled"
    case .requiresApproval: loginStatus = "requiresApproval"
    case .notFound: loginStatus = "notFound"
    @unknown default: loginStatus = "unknown"
    }
    #if arch(arm64)
    let architecture = "arm64"
    #elseif arch(x86_64)
    let architecture = "x86_64"
    #else
    let architecture = "unknown"
    #endif
    var info: [String: Any] = [
      "os": process.operatingSystemVersionString,
      "architecture": architecture,
      "processorCount": process.processorCount,
      "activeProcessorCount": process.activeProcessorCount,
      "physicalMemoryBytes": process.physicalMemory,
      "launchAtLoginStatus": loginStatus,
    ]
    // The pubspec version, in the version+build form the desktop builds report.
    if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, !version.isEmpty {
      let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
      info["appVersion"] = build.isEmpty ? version : "\(version)+\(build)"
    }
    if let version = (try? SubscriptionFeedFetcher.invoke("xrayVersion", [:]))?["version"] as? String { info["coreVersion"] = version }
    return info
  }

  nonisolated private static func routeTable() throws -> [String: Any] {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
    process.arguments = ["-r", "-n"]
    process.environment = ["LC_ALL": "C"]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    var output = Data()
    while let chunk = try pipe.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty {
      output.append(chunk)
      if output.count > 512 * 1024 {
        process.terminate()
        process.waitUntilExit()
        throw RunnerTunnelError.evidenceFailure
      }
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0,
          let text = String(data: output, encoding: .utf8),
          text.contains("Destination"), text.contains("Gateway") else {
      throw RunnerTunnelError.evidenceFailure
    }
    return ["table": text, "timestamp": Date().timeIntervalSince1970]
  }

  nonisolated private static func arguments(_ call: FlutterMethodCall) throws -> [String: Any] {
    guard let arguments = call.arguments as? [String: Any] else {
      throw RunnerTunnelError.invalidEndpoint
    }
    return arguments
  }

  private func stateName(_ state: NEVPNStatus) -> String {
    switch state {
    case .invalid: "invalid"
    case .disconnected: "disconnected"
    case .connecting: "connecting"
    case .connected: "connected"
    case .reasserting: "reasserting"
    case .disconnecting: "disconnecting"
    @unknown default: "unknown"
    }
  }

  nonisolated static let noSelectionMessage = "Select a server first. This routing link turns its profile on for the selected server’s subscription."

  nonisolated private static func flutterError(_ code: String) -> FlutterError {
    FlutterError(code: code, message: "Elarni operation failed.", details: nil)
  }
}

enum RunnerTunnelError: Error {
  case onDemandSuspensionFailed
  case disconnectTimedOut
  case connectionIntentRequired
  case listenerUnavailable(Int)
  case invalidRouteEnforcement
  case evidenceFailure
  case invalidEndpoint
  case invalidSettings
  case perAppTargetMissing
  case invalidState
  case notPrepared
  case nodeSwitchFailedRestored
  case nodeSwitchRestoreFailed
  case pingFailure
  case unsupportedPingMethod
  case icmpFailedRestored
  case icmpRestoreFailed
}
