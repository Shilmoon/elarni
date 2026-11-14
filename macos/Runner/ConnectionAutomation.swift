import Foundation

struct AutomationConfiguration: Codable, Equatable {
  enum Policy: String, Codable { case fixed, lowestLatency, orderedFallback }
  struct Target: Codable, Equatable {
    let id: String
    let url: String
    let expectedStatus: Int
    let expectedBody: String

    func validate() throws {
      guard !id.isEmpty, id.count <= 64, url.utf8.count <= 4096,
            id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }),
            !url.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
            let parsed = URL(string: url), ["http", "https"].contains(parsed.scheme),
            let host = parsed.host, !host.isEmpty,
            parsed.port.map({ (1...65_535).contains($0) }) ?? true,
            parsed.user == nil, parsed.password == nil, parsed.fragment == nil,
            (200...299).contains(expectedStatus), expectedBody.utf8.count <= 4096 else {
        throw AutomationFailure.invalidConfiguration
      }
    }
  }

  var schemaVersion = 1
  var enabled = false
  var policy = Policy.fixed
  /// The selected server's subscription; backups may come from any.
  var subscriptionID = ""
  var nodeIDs: [String] = []
  var targets: [Target] = []
  /// Allowed servers labelled as entering through Russia; absent from older saves.
  var russianEntryNodeIDs: [String]?

  func validate() throws {
    guard schemaVersion == 1, subscriptionID.count <= 128, nodeIDs.count <= 1000,
          Set(nodeIDs).count == nodeIDs.count, (russianEntryNodeIDs ?? []).allSatisfy(nodeIDs.contains),
          nodeIDs.allSatisfy({ !$0.isEmpty && $0.count <= 128 }),
          targets.count <= 2,
          Set(targets.map(\.id)).count == targets.count,
          !enabled || (!subscriptionID.isEmpty && !nodeIDs.isEmpty && !targets.isEmpty) else {
      throw AutomationFailure.invalidConfiguration
    }
    for target in targets { try target.validate() }
    if targets.count == 2 {
      let identities = targets.map {
        URL(string: $0.url)?.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
      }
      guard identities[0] != identities[1] else {
        throw AutomationFailure.invalidConfiguration
      }
    }
  }

  /// Probe timeouts that make a health check an endpoint failure. Switching servers
  /// needs both targets to time out when there are two, as on desktop and Android.
  var endpointFailureTimeouts: Int { policy == .fixed || targets.count == 1 ? 1 : 2 }

  /// Whether a failed health probe counts against the server. A timeout always does. A request
  /// that was refused, reset or closed counts only for a server whose check passed before on this
  /// connection: its service or its route has gone since. One that never passed may be rejecting
  /// the credentials, which no other moment changes.
  static func countsAgainstServer(code: String?, stage: String?, passedBefore: Bool) -> Bool {
    code == "timeout" || passedBefore && stage == "target_request"
      && ["failed", "eof", "unexpected_eof", "closed_pipe"].contains(code ?? "")
  }
}

enum AutomationFailure: String, Error {
  case invalidConfiguration, missingCredentials, unsupportedPolicy, unavailableProbePath
  case invalidTarget, indeterminate, endpointFailure, providerFailure, quarantine
  case exhaustedCandidates, staleContext, deadline, replacementRestored, restorationFailed
}

struct AutomationContext: Equatable {
  let epoch: UInt64
  let intentRevision: UInt64
  let nodeID: String
  let reference: String
  let plan: Data
}

enum ConnectionSupportSnapshot {
  static func make(state: String, provider: [String: Any], automation: [String: Any], issueCodes: [String] = []) -> [String: Any] {
    let states: Set<String> = ["disconnected", "prepared", "preparing", "connecting", "connected",
      "disconnecting", "reasserting", "reconnecting", "invalid", "failed", "unavailable"]
    var counters: [String: Any] = [:]
    for key in ["generation", "uptimeSeconds", "uplinkBytes", "downlinkBytes", "txBytes", "rxBytes",
                "tcpConnections", "udpConnections", "memoryBytes", "metricsAvailable", "resourceRecoveryRequired"] {
      if let value = provider[key] as? NSNumber, value.doubleValue.isFinite { counters[key] = value }
    }
    if let source = provider["counters"] as? [String: Any] {
      var safe: [String: Any] = [:]
      for key in ["uplinkBytes", "downlinkBytes", "packetsIn", "packetsOut", "activeTcpSessions",
                  "activeUdpSessions", "droppedTcpSessions", "droppedUdpSessions", "heapAllocBytes", "memoryLimitBytes"] {
        if let value = source[key] as? NSNumber, value.doubleValue.isFinite { safe[key] = value }
      }
      counters["counters"] = safe
    }
    let policy = automation["policy"] as? String ?? ""
    let status = automation["status"] as? String ?? ""
    let statuses: Set<String> = ["healthy", "recovered", "selected", "disabled", "stopped", "waitingForPath",
      "offline", "sleeping", "replacing", "exhausted", "healthFailure", "intentRequired", "connectedUnchecked"]
    let issueAllowlist: Set<String> = ["permission_denied", "vpn_configuration_failed", "listener_unavailable", "check_target_failed",
      "connection_failed", "unsupported_policy", "recovery_exhausted", "missing_credentials", "invalid_recovery",
      "invalid_configuration", "recovery_required", "previous_restored", "status_unavailable", "check_failed",
      "provider_unavailable", "disconnect_unconfirmed", "cancelled", "operation_failed", "export_failed"]
    return ["schemaVersion": 2, "platform": "macos", "state": states.contains(state) ? state : "unavailable",
      "recentIssues": issueCodes.prefix(8).map { issueAllowlist.contains($0) ? $0 : "operation_failed" },
      "endpoint": "[REDACTED]", "provider": counters,
      "recovery": ["enabled": automation["enabled"] as? Bool ?? false,
        "policy": ["fixed", "orderedFallback", "lowestLatency"].contains(policy) ? policy : "unknown",
        "pendingRetry": automation["pendingRetry"] as? Bool ?? false,
        "exhausted": automation["exhausted"] as? Bool ?? false,
        "pathAvailable": automation["pathAvailable"] as? Bool ?? false,
        "attempts": automation["attempts"] as? Int ?? 0,
        "lastResult": statuses.contains(status) || AutomationFailure(rawValue: status) != nil ? status : "unknown"]]
  }
}

struct ProbeDiagnostic {
  enum Stage: String, CaseIterable { case localPath, requiredDNS, endpointTCP, authentication, providerBridge, activeTraffic }
  enum Outcome: String { case passed, failed, cancelled, timedOut, unreachable, notTested, unknown }
  let targetOrdinal: Int
  let revision: UInt64
  let deadline: Double
  let started: Double
  var generation: UInt64?
  var duration = 0.0
  var outcomes: [Stage: Outcome] = [:]

  mutating func recordNative(_ details: [String: Any], outcome: Outcome) {
    outcomes[.activeTraffic] = outcome
    // A successful HTTP request does not identify the DNS, endpoint or
    // authentication work performed by the provider's shared connections.
    for stage in [Stage.requiredDNS, .endpointTCP, .authentication] { outcomes[stage] = .unknown }
    for event in (details["events"] as? [[String: Any]] ?? []).prefix(256) {
      if event["stage"] as? String == "target_dns_done", event["role"] as? String == "target" {
        outcomes[.requiredDNS] = Self.outcome(code: event["code"] as? String)
      }
    }
  }

  static func outcome(code: String?) -> Outcome {
    switch code {
    case "ok": .passed
    case "timeout": .timedOut
    case "canceled": .cancelled
    case "failed", "target_dns_failed", "eof", "unexpected_eof", "closed_pipe": .failed
    default: .unknown
    }
  }

  var channelMap: [String: Any] {
    ["targetOrdinal": targetOrdinal, "revision": revision, "deadline": deadline,
     "duration": duration, "generation": generation as Any? ?? NSNull(),
     "stages": Stage.allCases.map { stage in
       ["stage": stage.rawValue, "outcome": (outcomes[stage] ?? .notTested).rawValue]
     }]
  }
}

// Pure policy. All scheduling uses monotonic seconds supplied by the owning app.
struct AutomationPolicy {
  struct Episode: Codable {
    var schemaVersion = 1
    var attempts = 0
    var exhausted = false
    var interrupted = false
  }
  struct Measurement {
    let samples: [Double]
    let measuredAt: Double
    let epoch: UInt64
    let reference: String
    var median: Double? {
      guard samples.count == 3, samples.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
      return samples.sorted()[1]
    }
  }

  private(set) var epoch: UInt64 = 0
  private(set) var path: String?
  private(set) var online = false
  private(set) var sleeping = false
  private(set) var episode = Episode()
  private(set) var episodeStarted: Double?
  private(set) var retryAt: Double?
  private(set) var healthAt: Double?
  private(set) var failures = 0
  private(set) var measurements: [String: Measurement] = [:]
  private(set) var cooldown: [String: Double] = [:]
  private(set) var invalid: Set<String> = []
  private(set) var lastSwitch: Double?
  private(set) var lastOptimization: Double?
  private var rotation = 0
  // Mobile whitelists pass Russian addresses only: set when a Russian-entry
  // server passes after two foreign-entry ones failed, cleared by a foreign pass.
  private(set) var whitelist = false
  private var foreignFailures: Set<String> = []

  init(savedEpisode: Episode? = nil) {
    if var savedEpisode {
      // An interrupted process cannot obtain a fresh budget by relaunching.
      if savedEpisode.interrupted || savedEpisode.attempts > 0 { savedEpisode.exhausted = true }
      episode = savedEpisode
    }
  }

  mutating func invalidate(configuration: Bool = false) {
    epoch &+= 1
    measurements.removeAll()
    // Context cancellation must not renew or postpone an unfinished retry episode.
    healthAt = nil
    failures = 0
    if configuration {
      cooldown.removeAll()
      invalid.removeAll()
      rotation = 0
      lastSwitch = nil
      lastOptimization = nil
    }
  }

  mutating func rearm(now: Double) {
    episode = Episode()
    episodeStarted = nil
    retryAt = nil
    healthAt = now
  }

  @discardableResult
  mutating func pathChanged(_ signature: String, available: Bool, now: Double) -> Bool {
    guard path != signature || online != available else { return false }
    let initial = path == nil
    path = signature
    online = available
    invalidate()
    // The first monitor callback after relaunch is reconciliation, not a re-arm.
    if available && !initial && !episode.interrupted && !episode.exhausted { rearm(now: now) }
    else if available && !episode.exhausted { healthAt = now }
    return true
  }

  @discardableResult
  mutating func sleepChanged(_ value: Bool, now: Double) -> Bool {
    guard sleeping != value else { return false }
    sleeping = value
    invalidate()
    if !value && !episode.interrupted && !episode.exhausted { rearm(now: now) }
    return true
  }

  mutating func stop() {
    invalidate()
    retryAt = nil
    episode = Episode()
    episodeStarted = nil
  }

  mutating func scheduleHealth(now: Double, jitter: Double) {
    guard online, !sleeping, !episode.exhausted else { healthAt = nil; return }
    healthAt = now + 30 * (1 + max(-1, min(1, jitter)) * 0.1)
  }

  mutating func healthy(now: Double, jitter: Double) {
    failures = 0
    episode = Episode()
    episodeStarted = nil
    retryAt = nil
    scheduleHealth(now: now, jitter: jitter)
  }

  mutating func failedHealth(_ failure: AutomationFailure) -> Bool {
    guard online, !sleeping else { return false }
    if failure == .endpointFailure { failures += 1 }
    else { failures = 0 }
    return failures >= 3
  }

  mutating func scheduleRetry(now: Double, jitter: Double, allowOffline: Bool = false) -> Double? {
    guard online || allowOffline, !sleeping, !episode.exhausted else { return nil }
    if let retryAt { return retryAt }
    if episodeStarted == nil { episodeStarted = now }
    guard episode.attempts < 6, now - episodeStarted! < 120 else {
      episode.exhausted = true
      healthAt = nil
      return nil
    }
    let delays: [Double] = [1, 2, 4, 8, 16, 30]
    let delay = min(30, delays[episode.attempts] * (1 + max(-1, min(1, jitter)) * 0.2))
    guard now + delay < episodeStarted! + 120 else {
      episode.exhausted = true
      healthAt = nil
      return nil
    }
    retryAt = now + delay
    episode.interrupted = true
    healthAt = nil
    return retryAt
  }

  mutating func beginRetry(now: Double, allowOffline: Bool = false) -> Bool {
    guard online || allowOffline, !sleeping, !episode.exhausted,
          let due = retryAt, now >= due, let started = episodeStarted else { return false }
    retryAt = nil
    guard episode.attempts < 6, now < started + 120 else {
      episode.exhausted = true
      return false
    }
    episode.attempts += 1
    episode.interrupted = true
    return true
  }

  var remainingEpisodeTime: Double? {
    episodeStarted.map { $0 + 120 }
  }

  mutating func expireEpisode() {
    episode.exhausted = true
    retryAt = nil
    healthAt = nil
  }

  mutating func record(node: String, reference: String, samples: [Double], now: Double) {
    let result = Measurement(samples: samples, measuredAt: now, epoch: epoch, reference: reference)
    if result.median != nil { measurements[node] = result }
    else { measurements.removeValue(forKey: node) }
  }

  mutating func reject(node: String, transient: Bool, now: Double) {
    measurements.removeValue(forKey: node)
    if transient { cooldown[node] = now + 60 }
    else { invalid.insert(node) }
  }

  func score(node: String, reference: String, now: Double) -> Double? {
    guard let result = measurements[node], result.epoch == epoch,
          result.reference == reference, now >= result.measuredAt,
          now - result.measuredAt < 300 else { return nil }
    return result.median
  }

  mutating func round(nodes: [String], current: String?, now: Double) -> [String] {
    let eligible = nodes.filter { !invalid.contains($0) && (cooldown[$0] ?? 0) <= now }
    let rest = eligible.filter { $0 != current }
    let offset = rest.isEmpty ? 0 : rotation % rest.count
    let ordered = Array(rest.dropFirst(offset)) + Array(rest.prefix(offset))
    let first = current.flatMap { eligible.contains($0) ? [$0] : nil } ?? []
    let result = Array((first + ordered).prefix(10))
    if !rest.isEmpty { rotation = (offset + max(0, result.count - first.count)) % rest.count }
    return result
  }

  /// DPI cuts UDP transports and unusual ports first; TCP 443 looks like HTTPS.
  static func tcp443(_ outbound: [String: Any]) -> Bool {
    let outbound = (outbound["outbounds"] as? [[String: Any]])?.first ?? outbound
    let settings = outbound["settings"] as? [String: Any] ?? [:]
    let stream = outbound["streamSettings"] as? [String: Any] ?? [:]
    let server = ((settings["vnext"] ?? settings["servers"]) as? [[String: Any]])?.first
    guard let protocolName = outbound["protocol"] as? String,
          !["hysteria", "tuic", "wireguard", "amneziawg"].contains(protocolName),
          !["kcp", "mkcp", "quic", "hysteria"].contains(stream["network"] as? String ?? ""),
          (stream["tlsSettings"] as? [String: Any])?["alpn"] as? [String] != ["h3"] else { return false }
    return (server?["port"] ?? settings["port"]).map { "\($0)" } == "443"
  }

  mutating func observe(node: String, passed: Bool, russianEntry: Bool) {
    if !russianEntry {
      if passed { whitelist = false; foreignFailures.removeAll() }
      else { foreignFailures.insert(node) }
    } else if passed && foreignFailures.count >= 2 {
      whitelist = true
    }
  }

  /// Russian entries first in whitelist mode, then TCP 443 servers when the
  /// failing one is not; otherwise the user's order.
  func recoveryOrder(_ order: [String], current: String, tcp443: Set<String>, russianEntry: Set<String>) -> [String] {
    func rank(_ id: String) -> Int {
      (whitelist && !russianEntry.contains(id) ? 2 : 0) + (!tcp443.contains(current) && !tcp443.contains(id) ? 1 : 0)
    }
    return (0..<4).flatMap { value in order.filter { rank($0) == value } }
  }

  // Outage recovery tries only explicitly allowed alternatives. Measurements
  // optimize a healthy connection; they are not permission to use a backup.
  func recoveryCandidates(policy: AutomationConfiguration.Policy, order: [String],
                          current: String, now: Double) -> [String] {
    guard policy != .fixed else { return [] }
    return Array(order.filter {
      $0 != current && !invalid.contains($0) && (cooldown[$0] ?? 0) <= now
    }.prefix(10))
  }

  func choose(policy: AutomationConfiguration.Policy, order: [String], current: String?,
              scores: [String: Double], healthy: Bool, now: Double) -> String? {
    let eligible = order.filter { scores[$0]?.isFinite == true && scores[$0]! >= 0 }
    if policy == .fixed { return current.flatMap { eligible.contains($0) ? $0 : nil } }
    if policy == .orderedFallback {
      if healthy, let current, eligible.contains(current) { return current }
      return eligible.first
    }
    let best = eligible.min { a, b in
      if scores[a] == scores[b] { return a == current && b != current }
      return scores[a]! < scores[b]!
    }
    if healthy, let current, order.contains(current), best != nil,
        !(scores[current].map { $0.isFinite && $0 >= 0 } ?? false) {
      return current // No comparable baseline means no proven healthy improvement.
    }
    guard healthy, let current, let old = scores[current], old.isFinite, old >= 0,
          let best, best != current else { return best }
    guard now - (lastSwitch ?? -.infinity) >= 60,
          old - scores[best]! >= max(20, old * 0.2) else { return current }
    return best
  }

  mutating func beginOptimization(now: Double) -> Bool {
    guard now - (lastOptimization ?? -.infinity) >= 300,
          now - (lastSwitch ?? -.infinity) >= 60 else { return false }
    lastOptimization = now
    return true
  }

  mutating func switched(now: Double) {
    lastSwitch = now
    // Nested candidate measurements depend on the active node too.
    invalidate()
  }
}
