import CryptoKit
import Foundation
import NetworkExtension
import Observation
import WidgetKit

@MainActor @Observable
final class IOSVPNController {
  private(set) var status: NEVPNStatus = .disconnected
  private(set) var provider: [String: Any] = [:]
  private(set) var connectedAt: Date?
  /// When the connected server started failing the extension's traffic check.
  private(set) var noTrafficSince: Date?
  // Settable so unit tests can install a fixture tunnel; the simulator has no VPN.
  var manager: NETunnelProviderManager?
  @ObservationIgnored private var observer: NSObjectProtocol?
  /// Whether Connect on untrusted Wi-Fi may install its rules now; the app model decides.
  @ObservationIgnored var untrustedWiFiArmed: () -> Bool = { false }
  var active: Bool { [.connected, .connecting, .reasserting, .disconnecting].contains(status) }
  var connected: Bool { [.connected, .reasserting].contains(status) }
  var providerReady: Bool { status == .connected && provider["state"] as? String == "connected" && provider["resourceRecoveryRequired"] as? Bool != true }
  var noTraffic: Bool { providerReady && provider["liveness"] as? String == "noTraffic" }
  /// The provider holds routes but carries no traffic until it is restarted.
  var failed: Bool {
    active && (["protectedFailure", "quarantinedFailClosed"].contains(provider["state"] as? String ?? "") || provider["resourceRecoveryRequired"] as? Bool == true)
  }
  var extensionID: String { (Bundle.main.bundleIdentifier ?? "com.elarni.ios.Elarni") + ".ElarniPacketTunnel" }
  var savedPlan: Data? { (manager?.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?["planPayload"] as? Data }
  var stateLabel: String {
    if failed { return String(localized: "Connection needs attention") }
    switch status {
    case .connected: return providerReady ? (noTraffic ? String(localized: "Connected · no traffic") : String(localized: "Connected")) : String(localized: "Checking VPN status")
    case .connecting: return String(localized: "Connecting")
    case .disconnecting: return String(localized: "Disconnecting")
    case .reasserting: return String(localized: "Reconnecting")
    case .invalid, .disconnected: return String(localized: "Disconnected")
    @unknown default: return String(localized: "Status unavailable")
    }
  }

  init() {
    observer = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] note in
      Task { @MainActor in
        guard let self, let connection = note.object as? NEVPNConnection,
              connection === self.manager?.connection else { return }
        self.updateStatus()
      }
    }
  }

  func load() async throws {
#if targetEnvironment(simulator)
    status = .disconnected
#else
    let managers = try await NETunnelProviderManager.loadAllFromPreferences()
    let matches = managers.filter { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == extensionID }
    guard matches.count <= 1 else { throw IOSAppError.providerUnavailable }
    manager = matches.first
    updateStatus()
#endif
  }

  private func updateStatus() {
    let wasActive = active
    status = manager?.connection.status ?? .disconnected
    connectedAt = manager?.connection.connectedDate
    if !active { provider = [:] }
    // Control Center shows the toggle's last value until the app reloads it.
    if active != wasActive { ControlCenter.shared.reloadControls(ofKind: ConnectionControlIntent.kind) }
  }

  func persist(_ data: Data, settings: IOSTunnelSettings, allowOnDemand: Bool) async throws {
    try Task.checkCancellation()
    let selected = manager ?? NETunnelProviderManager()
    let tunnel = NETunnelProviderProtocol()
    tunnel.providerBundleIdentifier = extensionID
    tunnel.serverAddress = "Elarni"
    tunnel.providerConfiguration = ["planPayload": data, "planDigest": Data(SHA256.hash(data: data))]
    tunnel.includeAllNetworks = settings.includeAllNetworks
    tunnel.enforceRoutes = settings.enforceRoutes
    tunnel.disconnectOnSleep = settings.disconnectOnSleep
    selected.protocolConfiguration = tunnel
    selected.localizedDescription = "Elarni"
    selected.isEnabled = true
    // As on macOS, Include all networks keeps On Demand so iOS replaces a dead provider.
    if allowOnDemand && (settings.onDemandEnabled || settings.includeAllNetworks) {
      let rule = NEOnDemandRuleConnect(); rule.interfaceTypeMatch = .any
      selected.onDemandRules = [rule]; selected.isOnDemandEnabled = true
    } else if settings.connectOnUntrustedWiFi == true && untrustedWiFiArmed() {
      selected.onDemandRules = TunnelCommandCoordinator.untrustedWiFiRules(trusted: settings.trustedWiFiNetworks ?? [])
      selected.isOnDemandEnabled = true
    } else { selected.onDemandRules = nil; selected.isOnDemandEnabled = false }
    try await selected.saveToPreferences()
    manager = selected
    try await selected.loadFromPreferences()
    try Task.checkCancellation()
    updateStatus()
  }

  func connect(_ data: Data, settings: IOSTunnelSettings) async throws {
#if targetEnvironment(simulator)
    throw IOSAppError.unavailableSimulator
#else
    do {
    try await persist(data, settings: settings, allowOnDemand: true)
    guard let session = manager?.connection as? NETunnelProviderSession else { throw IOSAppError.providerUnavailable }
    try Task.checkCancellation()
    try session.startTunnel()
    updateStatus()
    let deadline = Date().addingTimeInterval(30)
    var started = active
    while true {
      try Task.checkCancellation()
      updateStatus()
      if connected {
        try await refreshProvider()
        guard providerReady else { throw IOSAppError.providerUnavailable }
        return
      }
      if active { started = true }
      if status == .invalid || started && status == .disconnected { throw IOSAppError.providerUnavailable }
      // Judge the deadline after a fresh status: an app resumed from suspension
      // must not time out, and so stop, a tunnel that connected meanwhile.
      guard Date() < deadline else { throw IOSAppError.operationTimedOut }
      try await Task.sleep(for: .milliseconds(150))
    }
    } catch {
      let failure = error
      // Join cleanup even when Connect was cancelled. The serialized Stop
      // command must never inherit a late start or enabled on-demand rule.
      do { try await Task { @MainActor in try await self.disconnect() }.value }
      catch { throw IOSAppError.cleanupFailed }
      throw failure
    }
#endif
  }

  func disconnect() async throws {
    guard let manager else { return }
    // Disable on-demand before stopping so an explicit Stop stays stopped.
    if manager.isOnDemandEnabled || !(manager.onDemandRules ?? []).isEmpty {
      manager.isOnDemandEnabled = false; manager.onDemandRules = nil
      do {
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
      } catch {
        manager.connection.stopVPNTunnel()
        updateStatus()
        throw error
      }
    }
    manager.connection.stopVPNTunnel()
    let deadline = Date().addingTimeInterval(20)
    while true {
      updateStatus()
      if !active { return }
      guard Date() < deadline else { throw IOSAppError.operationTimedOut }
      try await Task.sleep(for: .milliseconds(150))
    }
  }

  func removePlan() async throws {
    guard let manager else { return }
    guard !active else { throw IOSAppError.busy }
    try await manager.removeFromPreferences()
    self.manager = nil
    updateStatus()
  }

  func clearSavedPlan() async throws {
    guard let manager else { return }
    guard !active else { throw IOSAppError.busy }
    if let tunnel = manager.protocolConfiguration as? NETunnelProviderProtocol {
      tunnel.providerConfiguration = [:]
      manager.protocolConfiguration = tunnel
    }
    manager.isOnDemandEnabled = false; manager.onDemandRules = nil
    try await manager.saveToPreferences()
    try await manager.loadFromPreferences()
  }

  func refreshProvider() async throws {
    updateStatus()
    guard connected else { noTrafficSince = nil; return }
    do { provider = try await message(Data("state".utf8), timeout: 5) }
    catch { provider = [:]; noTrafficSince = nil; throw error }
    noTrafficSince = noTraffic ? noTrafficSince ?? Date() : nil
  }

  /// The running extension's log after a line number; it also applies the level the app last chose.
  func logs(after: Int64) async throws -> [String: Any] {
    try await message(try JSONSerialization.data(withJSONObject: ["operation": "logs", "after": after]), timeout: 5)
  }

  /// Marks or flushes the running provider's recording; false when it records nothing.
  func recording(mark: Bool) async -> Bool {
    guard connected, let reply = try? await message(Data((mark ? "diagnostics_mark" : "diagnostics_flush").utf8), timeout: 5) else { return false }
    return reply["recorded"] as? Bool == true
  }

  static func canSwitchLive(from old: Data?, to next: Data) -> Bool {
    guard let old, let previous = try? JSONDecoder().decode(TunnelPlan.self, from: old),
          let candidate = try? JSONDecoder().decode(TunnelPlan.self, from: next) else { return false }
    return previous.effectiveBackend == .nativeTun2Proxy && candidate.effectiveBackend == .nativeTun2Proxy &&
      previous.runtimeSettings == candidate.runtimeSettings && previous.socksPort == candidate.socksPort && previous.mtu == candidate.mtu
  }

  func replacePlan(_ data: Data, settings: IOSTunnelSettings) async throws {
    if connected && Self.canSwitchLive(from: savedPlan, to: data) { try await switchPlan(data) }
    else {
      if active { try await disconnect() }
      try Task.checkCancellation()
      try await connect(data, settings: settings)
    }
  }

  func switchPlan(_ data: Data) async throws {
    let id = UUID().uuidString
    let digest = Data(SHA256.hash(data: data))
    let request = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "operation": "switch", "operationID": id,
      "envelope": ["payload": data.base64EncodedString(), "digest": digest.base64EncodedString()]])
    let response: [String: Any]
    do { response = try await message(request, timeout: 20) }
    catch {
      if let session = manager?.connection as? NETunnelProviderSession,
         let cancel = try? JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "operation": "cancelSwitch", "operationID": id]) {
        try? session.sendProviderMessage(cancel) { _ in }
      }
      throw error
    }
    guard ["switched", "unchanged"].contains(response["code"] as? String ?? ""), response["digest"] as? String == digest.base64EncodedString() else {
      switch response["code"] as? String {
      case "quarantined": throw AutomationFailure.quarantine
      case "missing_credentials": throw AutomationFailure.missingCredentials
      case "invalid_configuration": throw AutomationFailure.invalidConfiguration
      // As on Android, a server name that does not resolve is a connection failure, not an unknown one.
      case "resolution_failed": throw IOSAppError.serverUnresolvable
      case "restored", "rejected": throw IOSAppError.switchFailed
      default: throw IOSAppError.switchRestoreFailed
      }
    }
    try Task.checkCancellation()
    try await refreshProvider()
  }

  /// The provider refused the candidate in these switch failures and still runs the previous plan.
  static func keptPreviousPlan(_ error: Error) -> Bool {
    if case IOSAppError.switchFailed = error { return true }
    if case IOSAppError.serverUnresolvable = error { return true }
    guard let failure = error as? AutomationFailure else { return false }
    return [.missingCredentials, .invalidConfiguration, .indeterminate].contains(failure)
  }

  private func message(_ data: Data, timeout: Double) async throws -> [String: Any] {
    guard let session = manager?.connection as? NETunnelProviderSession else { throw IOSAppError.providerUnavailable }
    let reply = MessageReply()
    let output: Data = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        reply.install(continuation)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { reply.finish(.failure(IOSAppError.operationTimedOut)) }
        do { try session.sendProviderMessage(data) { response in
          reply.finish(response.map { .success($0) } ?? .failure(IOSAppError.providerUnavailable))
        } } catch { reply.finish(.failure(error)) }
      }
    } onCancel: { reply.finish(.failure(CancellationError())) }
    guard let result = try JSONSerialization.jsonObject(with: output) as? [String: Any] else { throw IOSAppError.providerUnavailable }
    return result
  }
}

/// Cancellation may precede callback registration, and the system may reply after timeout.
private final class MessageReply: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Data, Error>?
  private var result: Result<Data, Error>?
  func install(_ value: CheckedContinuation<Data, Error>) {
    lock.lock()
    if let result { lock.unlock(); value.resume(with: result); return }
    continuation = value; lock.unlock()
  }
  func finish(_ value: Result<Data, Error>) {
    lock.lock()
    guard result == nil else { lock.unlock(); return }
    result = value; let pending = continuation; continuation = nil; lock.unlock()
    pending?.resume(with: value)
  }
}
