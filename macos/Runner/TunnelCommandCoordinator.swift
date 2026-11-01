import Foundation
import NetworkExtension

final class TunnelCommandCoordinator {
  static func connectionAction(from value: String) -> String? {
    guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
          let url = URLComponents(string: value),
          ["elarni", "incy", "happ"].contains(url.scheme?.lowercased() ?? ""),
          url.user == nil, url.password == nil, url.port == nil,
          url.query == nil, url.fragment == nil, ["", "/"].contains(url.path) else { return nil }
    switch url.host?.lowercased() {
    case "connect", "open": return "connect"
    case "disconnect", "close": return "disconnect"
    case "toggle": return "toggle"
    case "status": return "status"
    default: return nil
    }
  }

  enum Intent: String, Codable { case connected, disconnected }
  enum Failure: Error { case unreadableIntent }
  enum ReconnectFailure: Error { case restored, restoreFailed }

  @MainActor
  static func reconnect(from previousPlan: Data, to candidatePlan: Data,
                        stop: () async throws -> Void,
                        start: () async throws -> Void,
                        restore: () async throws -> Void) async throws {
    try Task.checkCancellation()
    // Canonical plans stay identical when an import only adds an unselected group.
    guard candidatePlan != previousPlan else { return }
    try await stop()
    try Task.checkCancellation()
    do {
      try await start()
      try Task.checkCancellation()
    } catch {
      // Explicit Stop owns cancellation; it must never trigger restoration.
      try Task.checkCancellation()
      do {
        try await stop()
        try Task.checkCancellation()
        try await restore()
        try Task.checkCancellation()
      } catch {
        try Task.checkCancellation()
        throw ReconnectFailure.restoreFailed
      }
      throw ReconnectFailure.restored
    }
  }

  private struct Record: Codable {
    let version: Int
    let revision: UInt64
    let intent: Intent
    let source: String
  }

  private static let key = "ElarniConnectionIntentV1"
  private let defaults: UserDefaults
  private var record: Record?
  private var unreadable = false
  private(set) var intent: Intent?
  private var pending: [UUID: Task<Void, Error>] = [:]
  private var tail: Task<Void, Never>?
  private var concurrentPredecessor: Task<Void, Never>?
  private var concurrentTail = false
  private var automatic: Set<UUID> = []
  private var probes: Set<UUID> = []
  var revision: UInt64 { record?.revision ?? 0 }

  @MainActor
  func invalidateAutomatic() {
    for id in automatic { pending[id]?.cancel() }
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    if let data = defaults.object(forKey: Self.key) {
      if let data = data as? Data,
         let saved = try? JSONDecoder().decode(Record.self, from: data),
         saved.version == 1, saved.source == "manual" {
        record = saved
        intent = saved.intent
      } else {
        unreadable = true
      }
    }
  }

  func requireReadableIntent() throws {
    if unreadable { throw Failure.unreadableIntent }
  }

  private static let untrustedWiFiKey = "ElarniUntrustedWiFiArmedV1"
  /// Turning Connect on untrusted Wi-Fi on arms it, even before a Connect.
  func armUntrustedWiFi() { defaults.set(NSNumber(value: revision), forKey: Self.untrustedWiFiKey) }
  /// Armed while connected, and since it was turned on until a Stop: a Stop pauses it until the next Connect.
  var untrustedWiFiArmed: Bool {
    intent == .connected || (defaults.object(forKey: Self.untrustedWiFiKey) as? NSNumber)?.uint64Value == revision
  }

  /// Wi-Fi outside the trusted names connects; trusted Wi-Fi, wired and mobile networks leave the VPN as it is.
  static func untrustedWiFiRules(trusted: [String]) -> [NEOnDemandRule] {
    var rules: [NEOnDemandRule] = []
    if !trusted.isEmpty {
      let home = NEOnDemandRuleIgnore()
      home.interfaceTypeMatch = .wiFi
      home.ssidMatch = trusted
      rules.append(home)
    }
    let join = NEOnDemandRuleConnect()
    join.interfaceTypeMatch = .wiFi
    rules.append(join)
    let other = NEOnDemandRuleIgnore()
    other.interfaceTypeMatch = .any
    rules.append(other)
    return rules
  }

  static func sameRules(_ installed: [NEOnDemandRule], _ expected: [NEOnDemandRule]) -> Bool {
    installed.count == expected.count && zip(installed, expected).allSatisfy { rule, wanted in
      rule.action == wanted.action && rule.interfaceTypeMatch == wanted.interfaceTypeMatch &&
        rule.ssidMatch == wanted.ssidMatch && rule.dnsSearchDomainMatch == nil &&
        rule.dnsServerAddressMatch == nil && rule.probeURL == nil
    }
  }

  func persist(_ intent: Intent) throws {
    try requireReadableIntent()
    let revision = record?.revision ?? 0
    guard revision < UInt64.max else { throw Failure.unreadableIntent }
    let next = Record(version: 1, revision: revision + 1, intent: intent, source: "manual")
    defaults.set(try JSONEncoder().encode(next), forKey: Self.key)
    record = next
    self.intent = intent
  }

  @MainActor
  func perform(intent requested: Intent? = nil, automatic isAutomatic: Bool = false, concurrent: Bool = false,
               readOnly: Bool = false,
               _ operation: @escaping @MainActor () async throws -> Void) async throws {
    if requested == .disconnected {
      // Stop supersedes active and queued work before waiting for ownership.
      for task in pending.values { task.cancel() }
      do { try persist(.disconnected) }
      catch {
        // Still allow an orderly stop; never overwrite an unknown durable schema.
        intent = .disconnected
        unreadable = true
      }
    } else {
      try requireReadableIntent()
    }
    if !concurrent && !readOnly && !isAutomatic {
      // Foreground work takes priority, but still joins probe cleanup below.
      for id in probes { pending[id]?.cancel() }
    }
    let shared = concurrent || readOnly
    let id = UUID()
    let previousTail = tail
    if shared && !concurrentTail { concurrentPredecessor = tail }
    let predecessor = shared ? concurrentPredecessor : tail
    concurrentTail = shared
    let task = Task { @MainActor in
      await predecessor?.value
      try Task.checkCancellation()
      if requested == .connected { try self.persist(.connected) }
      try await operation()
    }
    pending[id] = task
    if isAutomatic { automatic.insert(id) }
    if concurrent { probes.insert(id) }
    // Probes share their predecessor; the next mutation waits for every probe.
    tail = Task {
      if shared { await previousTail?.value }
      _ = await task.result
    }
    defer { pending.removeValue(forKey: id); automatic.remove(id); probes.remove(id) }
    try await withTaskCancellationHandler {
      try await task.value
    } onCancel: { task.cancel() }
  }
}
