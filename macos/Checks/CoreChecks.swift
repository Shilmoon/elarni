import CryptoKit
import Foundation
import NetworkExtension

private final class Locked<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value
  init(_ value: Value) { self.value = value }
  func withValue<T>(_ body: (inout Value) -> T) -> T { lock.withLock { body(&value) } }
  var snapshot: Value { lock.withLock { value } }
}

private actor Signal {
  private var fired = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  func wait() async {
    if !fired { await withCheckedContinuation { waiters.append($0) } }
  }
  func fire() {
    fired = true
    let pending = waiters
    waiters.removeAll()
    pending.forEach { $0.resume() }
  }
}

private final class PumpFlow: PacketFlow {
  struct State {
    var reads: [@Sendable ([NEPacket]) -> Void] = []
    var written: [NEPacket] = []
    var acceptsWrites = true
    var refused = 0
  }
  let state = Locked(State())
  let delivered = Signal()
  func readPacketObjects(completionHandler: @escaping @Sendable ([NEPacket]) -> Void) {
    state.withValue { $0.reads.append(completionHandler) }
  }
  func writePacketObjects(_ packets: [NEPacket]) -> Bool {
    let accepted = state.withValue {
      guard $0.acceptsWrites else { $0.refused += 1; return false }
      $0.written.append(contentsOf: packets)
      return true
    }
    if state.snapshot.written.count == 600 { Task { await delivered.fire() } }
    return accepted
  }
  func deliver(_ data: Data) {
    let callback = state.withValue { $0.reads.isEmpty ? nil : $0.reads.removeFirst() }
    callback?([NEPacket(data: data, protocolFamily: sa_family_t(AF_INET))])
  }
}

private final class PumpBridge: PacketBridge, @unchecked Sendable {
  struct State {
    var packets: [Data] = []
    var offset = 0
    var polls = 0
    var submitted: [Data] = []
  }
  let state = Locked(State())
  private let output = NSCondition()
  func start(socksPort: UInt16, mtu: UInt16, tcpMaxConnections: Int, udpMaxConnections: Int,
             inboundCredentials: InboundCredentials?, attempt: ProviderBoundaryAttempt) async throws {}
  func submit(_ packet: Data) throws { state.withValue { $0.submitted.append(packet) } }
  func receive() -> Data? {
    state.withValue { value in
      value.polls += 1
      guard value.offset < value.packets.count else { return nil }
      defer { value.offset += 1 }
      return value.packets[value.offset]
    }
  }
  func push(_ packets: [Data]) {
    output.withLock { state.withValue { $0.packets += packets }; output.broadcast() }
  }
  func awaitOutput(timeout: Duration) -> Bool? {
    output.withLock {
      let ready = { self.state.withValue { $0.offset < $0.packets.count } }
      let (seconds, attoseconds) = timeout.components
      if !ready() { _ = output.wait(until: Date(timeIntervalSinceNow: Double(seconds) + Double(attoseconds) / 1e18)) }
      return ready()
    }
  }
  func stop(deadline: Duration) async throws {}
  var counters: [String: UInt64] { [:] }
}

@main
struct CoreChecks {
  struct Failure: Error { let message: String }
  static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw Failure(message: message) }
  }
  static func rejects(_ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw Failure(message: "invalid input was accepted")
  }
  static func until(_ message: String, _ condition: () -> Bool) async throws {
    var waited = 0
    while !condition() {
      waited += 1
      try expect(waited < 500, message)
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  static func main() async {
    DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
      fputs("FAIL core checks timed out\n", stderr)
      exit(1)
    }
    do { try await run() }
    catch let failure as Failure { fputs("FAIL \(failure.message)\n", stderr); exit(1) }
    catch { fputs("FAIL unexpected core check error\n", stderr); exit(1) }
  }

  static func plan(_ changes: [String: Any] = [:], settings: [String: Any] = [:]) throws -> TunnelPlan {
    var runtime = try JSONSerialization.jsonObject(with: JSONEncoder().encode(TunnelRuntimeSettings.defaults)) as! [String: Any]
    runtime.merge(settings) { _, new in new }
    var data: [String: Any] = ["schemaVersion": 1, "secretRef": "fixture.auth", "socksPort": 10890,
      "mtu": 1500, "dnsServers": ["198.18.0.1"], "controlledRoutes": [], "staticHosts": [:], "settings": runtime]
    data.merge(changes) { _, new in new }
    return try JSONDecoder().decode(TunnelPlan.self, from: JSONSerialization.data(withJSONObject: data))
  }

  static func run() async throws {
    var passed = 0
    func check(_ name: String, _ body: () throws -> Void) throws {
      try body(); passed += 1; print("PASS \(name)")
    }
    try check("Xray failures retain safe configuration, initialization and resource categories") {
      let cases: [(String, ProviderBoundaryReason)] = [
        ("xray_config_invalid: private-secret", .xrayValidationFailed),
        ("xray_initialization_failed: private-secret", .xrayInitializationFailed),
        ("xray_start_failed: private-secret", .xrayStartFailed),
        ("xray_start_failed: bind private-secret: address already in use", .xrayAddressInUse),
        ("xray_initialization_failed: open private-secret: permission denied", .xrayPermissionDenied),
        ("xray_config_invalid: open private-secret: no such file or directory", .xrayFileMissing),
      ]
      for (message, expected) in cases {
        let (reason, path) = ProviderBoundaryReason.xrayDiagnostic(message)
        try expect(reason == expected && path == .root, "incorrect startup category")
        try expect(!reason.rawValue.contains("private-secret"), "diagnostic exposed input")
      }
    }
    try check("connection links accept only bounded control commands") {
      for scheme in ["elarni", "incy", "happ"] {
        for (name, action) in ["connect": "connect", "open": "connect", "disconnect": "disconnect",
                               "close": "disconnect", "toggle": "toggle", "status": "status"] {
          try expect(TunnelCommandCoordinator.connectionAction(from: "\(scheme)://\(name)") == action, "control link")
          try expect(TunnelCommandCoordinator.connectionAction(from: "\(scheme)://\(name)/") == action, "control link slash")
        }
      }
      try expect(TunnelCommandCoordinator.connectionAction(from: "INCY://CONNECT") == "connect", "case-insensitive scheme")
      for value in ["https://connect", "incy://connect?data=secret", "incy://connect#secret",
                    "incy://user@connect", "incy://connect:443", "incy://connect/profile",
                    "incy://import/https://example.com", "incy://disconnect\n"] {
        try expect(TunnelCommandCoordinator.connectionAction(from: value) == nil, "non-control link accepted")
      }
    }

    try await checkConcurrentCommands()
    passed += 1
    print("PASS concurrent probes retain command ordering and stop cancellation")

    try await checkReconnectCommands()
    passed += 1
    print("PASS reconnect switches, restores failures, and yields to Stop")

    try check("concurrent stop joins and invokes every completion once outside its lock") {
      let lifecycle = ProviderLifecycleCoordinator()
      let generation = lifecycle.beginStart()!
      let completions = Locked(0)
      let cleanups = Locked(0)
      DispatchQueue.concurrentPerform(iterations: 16) { _ in
        let action = lifecycle.beginStop {
          _ = lifecycle.state // Reentrancy must not deadlock.
          completions.withValue { $0 += 1 }
        }
        if action == .cleanup(generation) { cleanups.withValue { $0 += 1 } }
      }
      try expect(cleanups.snapshot == 1 && completions.snapshot == 0, "stop cleanup ownership")
      try expect(!lifecycle.markRunning(generation), "late startup revived stopping generation")
      lifecycle.finishStop(generation, ownersRemain: false)
      lifecycle.finishStop(generation, ownersRemain: false)
      try expect(completions.snapshot == 16 && lifecycle.state == .idle, "stop completion count/state")
      let next = lifecycle.beginStart()!
      try expect(!lifecycle.markRunning(generation), "old generation became running")
      lifecycle.finishStop(generation, ownersRemain: false)
      try expect(lifecycle.state == .starting(next), "old cleanup altered new generation")
    }

    try check("switch restoration and quarantine preserve lifecycle protection") {
      for restored in [false, true] {
        let lifecycle = ProviderLifecycleCoordinator()
        let generation = lifecycle.beginStart()!
        try expect(lifecycle.markRunning(generation), "startup transition")
        try expect(lifecycle.beginSwitch() == generation, "switch admission")
        try expect(lifecycle.finishSwitch(generation, restored: restored), "switch completion")
        try expect(lifecycle.state == (restored ? .running(generation) : .protectedFailure(generation)), "restore outcome")
        if !restored {
          try expect(lifecycle.beginSwitch(requiringRunning: true) == nil, "unhealthy generation admitted")
          // A switch that changes nothing must not report a failed tunnel as running.
          try expect(lifecycle.beginSwitch() == generation, "recovery switch admission")
          try expect(lifecycle.finishSwitch(generation, restored: true), "unchanged recovery switch")
          try expect(lifecycle.state == .protectedFailure(generation), "unchanged switch claimed recovery")
          try expect(lifecycle.beginSwitch() == generation, "second recovery switch admission")
          try expect(lifecycle.finishSwitch(generation, restored: true, started: true), "recovered switch")
          try expect(lifecycle.state == .running(generation), "started core not running")
          try expect(lifecycle.protectFailure(generation), "failure after recovery")
        }
        _ = lifecycle.beginStop {}
        lifecycle.finishStop(generation, ownersRemain: true)
        try expect(lifecycle.state == .quarantinedFailClosed(generation), "unconfirmed cleanup lost protection")
        try expect(lifecycle.beginStart() == nil && lifecycle.beginSwitch() == nil, "quarantine admitted new work")
      }
    }

    try check("cancelled switch identities reject late messages and saturation") {
      let cancellations = ProviderSwitchCancellation()
      let early = UUID()
      try expect(!cancellations.cancel(early), "pre-admission cancellation became active")
      try expect(!cancellations.admit(early), "late cancelled message admitted")
      let active = UUID()
      try expect(cancellations.admit(active), "fresh switch rejected")
      try expect(!cancellations.admit(UUID()), "parallel switch admitted")
      try expect(cancellations.cancel(active) && cancellations.isCancelled(active), "active cancellation lost")
      cancellations.finish(active)
      try expect(!cancellations.admit(active), "duplicate revived finished cancellation")
      for _ in 0..<62 { _ = cancellations.cancel(UUID()) }
      try expect(cancellations.saturated && !cancellations.admit(UUID()), "saturated cancellation cache forgot identity")
    }

    try check("runtime rejects stale reservations and late callbacks") {
      let runtime = ProviderLifecycleRuntime()
      let first = ProviderLifecycleGeneration(rawValue: 1)
      let second = ProviderLifecycleGeneration(rawValue: 2)
      try expect(runtime.reserve(first), "first reservation")
      runtime.markKeychainResolved(first)
      try expect(runtime.sharedKeychainResolved, "keychain generation not recorded")
      _ = runtime.detach(first)
      try expect(!runtime.reserve(first) && runtime.reserve(second), "stale generation reservation")
      runtime.markKeychainResolved(first)
      runtime.startupFinished(first)
      _ = runtime.detach(first)
      try expect(!runtime.sharedKeychainResolved && !runtime.reserve(ProviderLifecycleGeneration(rawValue: 3)), "stale callback detached current generation")
    }

    try await cleanupChecks()
    passed += 2

    try check("plan envelopes reject tampering, schema and bounds") {
      let valid = try plan()
      let bytes = try JSONEncoder().encode(valid)
      let envelope = TunnelPlanEnvelope(payload: bytes, digest: Data(SHA256.hash(data: bytes)))
      try expect(try envelope.validatedPlan().secretRef == "fixture.auth", "valid envelope")
      try rejects { _ = try TunnelPlanEnvelope(payload: bytes + Data([32]), digest: envelope.digest).validatedPlan() }
      try rejects { _ = try TunnelPlanEnvelope(payload: bytes, digest: Data()).validatedPlan() }
      for changes: [String: Any] in [["schemaVersion": 2], ["secretRef": "../secret"], ["mtu": 1279], ["socksPort": 0], ["dnsServers": []], ["routingRevision": "r1"], ["assetRevision": "../asset"]] {
        try rejects { try plan(changes).validate() }
      }
      for settings: [String: Any] in [["allowLAN": true], ["inboundAuthEnabled": true], ["memoryLimitMB": 39], ["idleTimeoutSeconds": 29], ["includedRoutes": ["0.0.0.0/0", "0.0.0.0/0"]]] {
        try rejects { try plan(settings: settings).validate() }
      }
      let perApp: [String: Any] = ["perAppMode": "bypass", "xrayTunEnabled": true, "perAppProcesses": ["/Applications/A.app/"]]
      for targets: [String: String] in [["/Applications/B.app/": "direct"], ["/Applications/A.app/": "node:server"],
        ["/Applications/A.app/": "server:../secret"], ["/Applications/A.app/": "server:inbound.login"], ["/Applications/A.app/": "other"]] {
        try rejects { try plan(settings: perApp.merging(["perAppTargets": targets]) { $1 }).validate() }
      }
      try plan(settings: perApp.merging(["perAppTargets": ["/Applications/A.app/": "server:subscription.s.node.n"]]) { $1 }).validate()
    }

    try check("per-app targets reach the compiler with each server's configuration") {
      let processes = ["/Applications/A.app/", "/Applications/B.app/", "/Applications/C.app/"]
      let targets = [processes[0]: "server:subscription.s.node.n", processes[1]: "proxy:socks5://127.0.0.1:1080", processes[2]: "block"]
      let value = try plan(settings: ["perAppMode": "proxyOnly", "xrayTunEnabled": true, "perAppProcesses": processes, "perAppTargets": targets])
      try value.validate()
      try expect(value.runtimeSettings.perAppServerRefs == ["subscription.s.node.n"], "server targets to resolve")
      let server = SecretValue(bytes: Data(#"{"protocol":"socks","settings":{"servers":[{"address":"127.0.0.1","port":1081}]}}"#.utf8))
      let compiled = try value.runtimeSettings.compilerPerAppTargets(servers: ["subscription.s.node.n": server])
      try expect(compiled.count == 3 && compiled[0]["process"] as? String == processes[0] && compiled[0]["target"] as? String == "server" &&
        (compiled[0]["server"] as? [String: Any])?["protocol"] as? String == "socks", "server target lost its configuration")
      try expect(compiled[1]["target"] as? String == "proxy" && compiled[1]["proxy"] as? String == "socks5://127.0.0.1:1080", "proxy target")
      try expect(compiled[2]["target"] as? String == "block" && compiled[2]["server"] == nil, "plain target")
      try rejects { _ = try value.runtimeSettings.compilerPerAppTargets(servers: [:]) }
      let off = try plan(settings: ["perAppMode": "off", "perAppProcesses": processes, "perAppTargets": targets])
      try expect(off.runtimeSettings.perAppServerRefs.isEmpty && (try off.runtimeSettings.compilerPerAppTargets(servers: [:])).isEmpty,
        "per-app routing off still sent targets")
    }

    try check("desktop memory policy migrates old plans without forcing zero-byte GC") {
      try expect(TunnelRuntimeSettings.defaults.memoryLimitMB == 0, "desktop default must be automatic")
      for limit in [0, 40, 45, 50] {
        let value = try plan(settings: ["memoryLimitMB": limit])
        try value.validate()
        try expect(value.runtimeSettings.memoryLimitBytes == Int.max, "legacy/automatic limit still forces GC")
        try expect(value.runtimeSettings.tcpMaxConnections == 256, "unrelated setting changed")
      }
      for limit in [64, 256, 4096] {
        let value = try plan(settings: ["memoryLimitMB": limit])
        try value.validate()
        try expect(value.runtimeSettings.memoryLimitBytes == limit * 1_024 * 1_024, "explicit limit lost")
      }
      for limit in [-1, 1, 39, 4097, Int.max] {
        try rejects { try plan(settings: ["memoryLimitMB": limit]).validate() }
      }
    }

    try check("routing revision and assets resolve only when present and intact") {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent("elarni-plan-check-\(UUID())")
      defer { try? FileManager.default.removeItem(at: root) }
      let revisions = root.appendingPathComponent("Routing/Revisions")
      let assets = root.appendingPathComponent("Routing/Assets/a1")
      try FileManager.default.createDirectory(at: revisions, withIntermediateDirectories: true)
      let data = Data("{\"rules\":[],\"fallbackAction\":\"block\"}".utf8)
      let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
      let value = try plan(["routingRevision": "r1", "routingDigest": digest, "assetRevision": "a1"])
      try rejects { _ = try value.runtimeRouteModel(containerURL: { root }) }
      try data.write(to: revisions.appendingPathComponent("r1"))
      try expect(try value.runtimeRouteModel(containerURL: { root })?["fallbackAction"] as? String == "block", "valid routing model")
      try Data("{}".utf8).write(to: revisions.appendingPathComponent("r1"))
      try rejects { _ = try value.runtimeRouteModel(containerURL: { root }) }
      try rejects { _ = try value.runtimeRouteModel(containerURL: { nil }) }
      try rejects { _ = try value.assetDirectory(containerURL: { root }) }
      try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
      try expect(try value.assetDirectory(containerURL: { root }) == assets.path, "asset directory resolution")
    }

    try check("provider endpoint address families and direct profiles preserve routing") {
      let candidates = ["192.0.2.4", "2001:db8::6"]
      try expect(TunnelSettingsFactory.endpointAddresses(candidates, strategy: "ForceIPv6", preferredIP: "automatic") == ["2001:db8::6"], "provider IPv6 requirement lost")
      try expect(TunnelSettingsFactory.endpointAddresses(["192.0.2.4"], strategy: "ForceIPv6", preferredIP: "automatic").isEmpty, "forced IPv6 silently downgraded")
      try expect(TunnelSettingsFactory.endpointAddresses(["192.0.2.4"], strategy: "UseIPv6", preferredIP: "automatic") == ["192.0.2.4"], "optional family fallback lost")
      try expect(TunnelSettingsFactory.endpointAddresses(candidates, strategy: "UseIPv6v4", preferredIP: "automatic") == candidates.reversed(), "provider family priority lost")
      try expect(TunnelSettingsFactory.endpointAddresses(candidates, strategy: "ForceIPv6", preferredIP: "ipv4") == ["192.0.2.4"], "explicit app override lost")
      let direct = try plan(["outboundFormat":"xrayProfile"])
      let network = try TunnelSettingsFactory.make(plan: direct, excludedEndpointAddresses: [])
      try expect(network.ipv4Settings?.includedRoutes?.isEmpty == false && network.dnsSettings != nil, "DIRECT profile lost tunnel routing or DNS")
    }

    try check("network settings retain IPv4 IPv6 endpoint exclusions and DNS") {
      let value = try plan(settings: ["preferredIP": "automatic", "includedRoutes": ["0.0.0.0/0", "2001:db8::/32"], "excludedRoutes": ["192.0.2.0/24", "2001:db8:1::/48"]])
      let settings = try TunnelSettingsFactory.make(plan: value, excludedEndpointAddresses: ["203.0.113.1", "2001:db8::1"])
      try expect(settings.mtu == 1500 && settings.dnsSettings?.servers == ["198.18.0.1"] && settings.dnsSettings?.matchDomains == [""], "MTU/DNS settings")
      let v4 = settings.ipv4Settings!
      let v6 = settings.ipv6Settings!
      try expect(v4.includedRoutes?.first?.destinationSubnetMask == "0.0.0.0", "IPv4 default mask")
      // LAN discovery stays on the physical network: multicast and the limited broadcast are excluded.
      try expect(v4.excludedRoutes?.map(\.destinationAddress) == ["203.0.113.1", "192.0.2.0", "224.0.0.0", "255.255.255.255"], "IPv4 exclusions")
      try expect(v4.excludedRoutes?.map(\.destinationSubnetMask) == ["255.255.255.255", "255.255.255.0", "240.0.0.0", "255.255.255.255"], "IPv4 exclusion masks")
      try expect(v6.includedRoutes?.first?.destinationNetworkPrefixLength == 32, "IPv6 included prefix")
      try expect(v6.excludedRoutes?.map(\.destinationNetworkPrefixLength) == [128, 48, 8], "IPv6 exclusions")
      try expect(v6.excludedRoutes?.last?.destinationAddress == "ff00::", "IPv6 multicast exclusion")
      // Block traffic without VPN (includeAllNetworks) keeps discovery in the tunnel.
      let blocked = try TunnelSettingsFactory.make(plan: value, excludedEndpointAddresses: ["203.0.113.1", "2001:db8::1"], keepDiscovery: true)
      try expect(blocked.ipv4Settings?.excludedRoutes?.map(\.destinationAddress) == ["203.0.113.1", "192.0.2.0"], "blocked IPv4 exclusions")
      try expect(blocked.ipv6Settings?.excludedRoutes?.map(\.destinationNetworkPrefixLength) == [128, 48], "blocked IPv6 exclusions")
      try rejects { _ = try TunnelSettingsFactory.make(plan: value, excludedEndpointAddresses: []) }
      for family in ["ipv4", "ipv6"] {
        let one = try TunnelSettingsFactory.make(plan: plan(settings: ["preferredIP": family]), excludedEndpointAddresses: ["203.0.113.1", "2001:db8::1"])
        try expect(one.ipv4Settings != nil && one.ipv6Settings != nil, "preferred family still routes both families")
      }
    }

    // elarni-cli accepts a single check target; its timeouts alone must count.
    try check("one check target is enough to fail over") {
      var configuration = AutomationConfiguration(policy: .orderedFallback, targets: [
        .init(id: "a", url: "https://a.example/", expectedStatus: 204, expectedBody: "")])
      try expect(configuration.endpointFailureTimeouts == 1, "one target")
      configuration.targets.append(.init(id: "b", url: "https://b.example/", expectedStatus: 204, expectedBody: ""))
      try expect(configuration.endpointFailureTimeouts == 2, "two independent targets")
      configuration.policy = .fixed
      try expect(configuration.endpointFailureTimeouts == 1, "fixed policy")
    }

    // A server that worked and now refuses or resets connections is down, as one that times out
    // is. Failover never left it: only timeouts counted.
    try check("a refused request counts against a server that passed before") {
      let counts = AutomationConfiguration.countsAgainstServer
      for code in ["failed", "eof", "unexpected_eof", "closed_pipe"] {
        try expect(counts(code, "target_request", true), code)
        // It may be rejecting the credentials, which another server does not fix.
        try expect(!counts(code, "target_request", false), code + " on a server that never passed")
        try expect(!counts(code, "instance_start", true), code + " before the request")
      }
      try expect(counts("timeout", "target_request", false) && counts("timeout", nil, false), "timeouts always count")
      try expect(!counts("target_dns_failed", "target_dns", true) && !counts(nil, nil, true), "other failures")
    }

    try check("automation thresholds and retry deadlines are bounded") {
      var policy = AutomationPolicy()
      policy.pathChanged("wifi", available: true, now: 0)
      try expect(!policy.failedHealth(.endpointFailure) && !policy.failedHealth(.endpointFailure), "early failover")
      try expect(!policy.failedHealth(.providerFailure), "provider failure triggered endpoint failover")
      try expect(!policy.failedHealth(.endpointFailure) && !policy.failedHealth(.endpointFailure) && policy.failedHealth(.endpointFailure), "endpoint threshold")
      var now = 0.0
      for delay in [1.0, 2, 4, 8, 16, 30] {
        let due = policy.scheduleRetry(now: now, jitter: 0)!
        try expect(due == now + delay, "retry backoff")
        try expect(!policy.beginRetry(now: due - 0.001), "retry before due")
        try expect(policy.beginRetry(now: due), "retry at due")
        now = due
      }
      try expect(policy.scheduleRetry(now: now, jitter: 0) == nil && policy.episode.exhausted, "attempt budget")
      policy.rearm(now: 0)
      _ = policy.scheduleRetry(now: 0, jitter: 0)
      try expect(!policy.beginRetry(now: 120) && policy.episode.exhausted, "episode deadline")
      for (jitter, delay) in [(-100.0, 0.8), (100.0, 1.2)] {
        policy.rearm(now: 0)
        try expect(policy.scheduleRetry(now: 0, jitter: jitter) == delay, "jitter clamping")
      }
    }

    try check("automation invalidates stale measurements without renewing interrupted budget") {
      var policy = AutomationPolicy()
      policy.pathChanged("wifi", available: true, now: 0)
      policy.record(node: "a", reference: "r1", samples: [30, 10, 20], now: 1)
      try expect(policy.score(node: "a", reference: "r1", now: 2) == 20, "median score")
      try expect(policy.score(node: "a", reference: "r2", now: 2) == nil && policy.score(node: "a", reference: "r1", now: 301) == nil, "stale measurement accepted")
      let due = policy.scheduleRetry(now: 2, jitter: 0)
      let epoch = policy.epoch
      policy.pathChanged("ethernet", available: true, now: 2)
      try expect(policy.epoch != epoch && policy.measurements.isEmpty && policy.retryAt == due, "path invalidation renewed budget")
      policy.sleepChanged(true, now: 2)
      try expect(!policy.beginRetry(now: 3), "retry while asleep")
      policy.sleepChanged(false, now: 3)
      try expect(policy.retryAt == due && policy.episode.interrupted, "wake renewed episode")
      let saved = try JSONDecoder().decode(AutomationPolicy.Episode.self, from: JSONEncoder().encode(policy.episode))
      var restored = AutomationPolicy(savedEpisode: saved)
      restored.pathChanged("wifi", available: true, now: 0)
      try expect(restored.episode.exhausted && restored.scheduleRetry(now: 0, jitter: 0) == nil, "relaunch renewed budget")
      policy.stop()
      try expect(policy.retryAt == nil && policy.measurements.isEmpty, "stop retained work")
    }

    try check("automatic selection requires a measured improvement and respects cooldown") {
      var policy = AutomationPolicy()
      let scores = ["a": 100.0, "b": 81.0]
      try expect(policy.choose(policy: .lowestLatency, order: ["a", "b"], current: "a", scores: scores, healthy: true, now: 0) == "a", "insufficient improvement switched")
      try expect(policy.choose(policy: .lowestLatency, order: ["a", "b"], current: "a", scores: ["a": 100, "b": 80], healthy: true, now: 0) == "b", "threshold improvement rejected")
      policy.switched(now: 0)
      try expect(policy.choose(policy: .lowestLatency, order: ["a", "b"], current: "a", scores: ["a": 100, "b": 20], healthy: true, now: 59) == "a", "switch cooldown")
      try expect(policy.choose(policy: .orderedFallback, order: ["a", "b"], current: "b", scores: scores, healthy: true, now: 100) == "b", "healthy ordered node churn")
      try expect(policy.choose(policy: .orderedFallback, order: ["a", "b"], current: "b", scores: scores, healthy: false, now: 100) == "a", "ordered fallback")
      try expect(policy.choose(policy: .fixed, order: ["a", "b"], current: "a", scores: ["b": 20], healthy: false, now: 100) == nil, "fixed policy selected another node")
    }
    try check("outage candidates require explicit permission but no cached measurement") {
      var policy = AutomationPolicy()
      try expect(policy.recoveryCandidates(policy: .fixed, order: ["a", "b"], current: "a", now: 0).isEmpty, "fixed selection escaped")
      try expect(policy.recoveryCandidates(policy: .orderedFallback, order: ["a", "b", "c"], current: "a", now: 0) == ["b", "c"], "cold fallback unavailable")
      policy.record(node: "b", reference: "old", samples: [10, 10, 10], now: 0)
      try expect(policy.recoveryCandidates(policy: .orderedFallback, order: ["a", "b"], current: "a", now: 301) == ["b"], "expired score blocked a permitted trial")
      policy.reject(node: "b", transient: true, now: 301)
      policy.reject(node: "c", transient: false, now: 301)
      try expect(policy.recoveryCandidates(policy: .orderedFallback, order: ["a", "b", "c"], current: "a", now: 302).isEmpty, "candidate cooldown/invalid rejection lost")
    }
    try check("recovery tries TCP 443 first after a UDP or other-port failure, and Russian entries in whitelist mode") {
      func server(_ protocolName: String, _ port: Any, network: String = "tcp", alpn: [String]? = nil) -> [String: Any] {
        var stream: [String: Any] = ["network": network, "security": "tls"]
        if let alpn { stream["tlsSettings"] = ["alpn": alpn] }
        let endpoint: [String: Any] = ["address": "server.test", "port": port]
        return ["protocol": protocolName, "streamSettings": stream,
                "settings": protocolName == "vless" ? ["vnext": [endpoint]] : ["servers": [endpoint]]]
      }
      try expect(AutomationPolicy.tcp443(server("vless", 443)), "TCP 443 not recognized")
      try expect(AutomationPolicy.tcp443(server("vless", "443", network: "ws")), "WebSocket on 443 not recognized")
      try expect(AutomationPolicy.tcp443(["outbounds": [server("trojan", 443, network: "xhttp")]]), "a profile's first outbound was ignored")
      try expect(!AutomationPolicy.tcp443(server("vless", 8443)), "another port counted as 443")
      try expect(!AutomationPolicy.tcp443(server("hysteria", 443, network: "hysteria")), "Hysteria counted as TCP")
      try expect(!AutomationPolicy.tcp443(server("vless", 443, network: "kcp")), "mKCP counted as TCP")
      try expect(!AutomationPolicy.tcp443(server("vless", 443, network: "xhttp", alpn: ["h3"])), "HTTP/3 counted as TCP")
      try expect(!AutomationPolicy.tcp443([:]), "an empty outbound counted as TCP 443")
      var policy = AutomationPolicy()
      let order = ["a", "b", "c", "d", "e"], tcp: Set = ["c", "e"], russia: Set = ["d"]
      try expect(policy.recoveryOrder(order, current: "a", tcp443: tcp, russianEntry: russia) == ["c", "e", "a", "b", "d"], "TCP 443 not first after a UDP failure")
      try expect(policy.recoveryOrder(order, current: "c", tcp443: tcp, russianEntry: russia) == order, "order changed after a TCP 443 failure")
      policy.observe(node: "a", passed: false, russianEntry: false)
      policy.observe(node: "d", passed: true, russianEntry: true)
      try expect(!policy.whitelist, "one foreign server down was taken for a whitelist")
      policy.observe(node: "b", passed: false, russianEntry: false)
      policy.observe(node: "d", passed: true, russianEntry: true)
      try expect(policy.whitelist, "whitelist mode not detected")
      try expect(policy.recoveryOrder(order, current: "c", tcp443: tcp, russianEntry: russia) == ["d", "a", "b", "c", "e"], "Russian entry not first in whitelist mode")
      try expect(policy.recoveryOrder(order, current: "a", tcp443: tcp, russianEntry: russia) == ["d", "c", "e", "a", "b"], "whitelist and TCP 443 order combined wrongly")
      policy.observe(node: "c", passed: true, russianEntry: false)
      try expect(!policy.whitelist, "a foreign pass did not end whitelist mode")
      policy.observe(node: "a", passed: false, russianEntry: false)
      policy.observe(node: "d", passed: true, russianEntry: true)
      try expect(!policy.whitelist, "failures from before a foreign pass still counted")
      // Saved configurations from before the field still decode, and the field names allowed servers only.
      var configuration = try JSONDecoder().decode(AutomationConfiguration.self, from: Data(#"{"schemaVersion":1,"enabled":false,"policy":"fixed","subscriptionID":"","nodeIDs":["a"],"targets":[]}"#.utf8))
      try configuration.validate()
      configuration.russianEntryNodeIDs = ["b"]
      do { try configuration.validate(); throw Failure(message: "a Russian entry outside the allowed servers was accepted") }
      catch AutomationFailure.invalidConfiguration {}
    }
    try check("support snapshots retain useful counters and exclude injected secrets") {
      let secret = "synthetic-private-secret"
      let snapshot = ConnectionSupportSnapshot.make(state: secret,
        provider: ["endpoint": secret, "generation": 7, "memoryBytes": secret,
          "counters": ["uplinkBytes": 12, "destination": secret]],
        automation: ["policy": secret, "status": secret, "configuration": ["targets": [secret]], "attempts": 2],
        issueCodes: ["permission_denied", secret])
      let text = String(data: try JSONSerialization.data(withJSONObject: snapshot), encoding: .utf8)!
      try expect(!text.contains(secret), "support export exposed a secret")
      try expect(snapshot["state"] as? String == "unavailable", "unknown state became disconnected")
      try expect((snapshot["provider"] as? [String: Any])?["generation"] as? Int == 7, "useful diagnostic lost")
      try expect(snapshot["recentIssues"] as? [String] == ["permission_denied", "operation_failed"], "safe cause codes lost")
    }
    try check("debug switch faults bind to one operation, generation and expiry") {
      let instance = UUID().uuidString
      for action in [ProviderDebugFaults.Action.candidateFailure, .restoreFailure] {
        let saved = Locked<ProviderDebugFaults.Receipt?>(nil)
        let faults = ProviderDebugFaults { receipt in saved.withValue { $0 = receipt } }
        let id = UUID()
        let request = ProviderDebugFaults.Request(id: id, action: action, expiresAt: 30,
          instanceID: instance, generation: 2)
        try rejects { try faults.arm(request, instanceID: instance, generation: 1, now: 1) }
        try faults.arm(request, instanceID: instance, generation: 2, now: 1)
        try expect(!faults.consume(.candidate, generation: 1, operationID: id, now: 2), "wrong generation injected")
        try expect(!faults.consume(.candidate, generation: 2, operationID: UUID(), now: 2), "wrong operation injected")
        try expect(faults.consume(.candidate, generation: 2, operationID: id, now: 2), "candidate injection missing")
        try expect(!faults.consume(.candidate, generation: 2, operationID: id, now: 2), "candidate injected twice")
        try expect(faults.consume(.restoration, generation: 2, operationID: id, now: 2) == (action == .restoreFailure),
                   "candidate-only fault prevented restoration")
        faults.finish("restored", generation: 2, requestID: UUID())
        try expect(saved.snapshot?.outcome == "armed", "wrong operation finished receipt")
        faults.finish("restored", generation: 2, requestID: id)
        try expect(saved.snapshot?.outcome == "restored", "receipt not finalized")
        try rejects { try faults.arm(request, instanceID: instance, generation: 2, now: 3) }
        let expired = ProviderDebugFaults.Request(id: UUID(), action: action, expiresAt: 30,
          instanceID: instance, generation: 2)
        try faults.arm(expired, instanceID: instance, generation: 2, now: 3)
        try expect(!faults.consume(.candidate, generation: 2, operationID: expired.id, now: 30), "expired injection accepted")
        try expect(saved.snapshot?.outcome == "expired", "expiry receipt missing")
      }
    }
    try check("liveness checks only while traffic leaves and counts failures in a row") {
      var tracker = ProviderLiveness(interval: 0)
      try expect(tracker.needsProbe(uplink: 0, at: 0), "Connect was not checked")
      tracker.record(passed: false, uplink: 0, at: 0)
      try expect(tracker.state == "noTraffic" && tracker.failures == 1, "failed check not counted")
      // A dead server on an idle phone was checked every minute, keeping the radio awake.
      try expect(!tracker.needsProbe(uplink: 0, at: 1), "an idle tunnel was checked again after a failure")
      try expect(tracker.needsProbe(uplink: 1, at: 2), "traffic after a failed check was not checked")
      tracker.record(passed: false, uplink: 1, at: 2)
      try expect(tracker.failures == 2, "failures in a row not counted")
      tracker.record(passed: true, uplink: 1, at: 3)
      try expect(tracker.state == "ok" && tracker.failures == 0, "a passing check did not end the failures")
      try expect(!tracker.needsProbe(uplink: 1, at: 4) && tracker.needsProbe(uplink: 2, at: 5), "idle and busy intervals after a pass")
    }
    try await packetFlowChecks()
    passed += 2
    print("\(passed) core checks passed")
  }

  static func packetFlowChecks() async throws {
    let flow = PumpFlow(), bridge = PumpBridge()
    let failed = Signal(), failures = Locked(0)
    let pump = PacketFlowPump(flow: flow, bridge: bridge, rejectionGrace: 0.3) { _ in
      failures.withValue { $0 += 1 }
      Task { await failed.fire() }
    }
    defer { pump.stop() }
    pump.start()
    pump.start() // An already running pump must not register another reader.
    try expect(flow.state.snapshot.reads.count == 1, "pump registered duplicate reads")
    try await Task.sleep(for: .milliseconds(250))
    try expect(bridge.state.snapshot.polls == 0, "idle pump polled the bridge without output")
    let packets = (0..<600).map { Data([($0 % 2 == 0 ? 0x45 : 0x60), UInt8($0 % 256)]) }
    bridge.push(packets)
    let input = Data([0x45, 1])
    flow.deliver(input)
    await flow.delivered.wait()
    try expect(flow.state.snapshot.written.map(\.data) == packets, "burst drain lost or reordered packets")
    try expect(bridge.state.snapshot.submitted == [input] && failures.snapshot == 0, "input wakeup failed")
    pump.stop()
    let stoppedPolls = bridge.state.snapshot.polls
    try await Task.sleep(for: .milliseconds(50))
    try expect(bridge.state.snapshot.polls == stoppedPolls, "stopped pump continued polling")
    print("PASS packet pump sleeps while idle, wakes on output and drains ordered bursts")

    pump.start()
    flow.deliver(Data([0x45, 2])) // Pending read from the stopped generation.
    try expect(bridge.state.snapshot.submitted == [input], "old read entered a restarted pump")
    // One refused write drops its batch; the pump keeps reading and writing.
    flow.state.withValue { $0.acceptsWrites = false }
    bridge.push([Data([0x45, 3])])
    try await until("refused write not attempted") { flow.state.snapshot.refused == 1 }
    flow.deliver(Data([0x45, 4]))
    // A written batch ends the refusals, however long they lasted.
    try await Task.sleep(for: .milliseconds(400))
    flow.state.withValue { $0.acceptsWrites = true }
    bridge.push([Data([0x45, 5])])
    try await until("write after a refusal lost") { flow.state.snapshot.written.last?.data == Data([0x45, 5]) }
    flow.state.withValue { $0.acceptsWrites = false }
    bridge.push([Data([0x45, 6])])
    try await until("second refusal not attempted") { flow.state.snapshot.refused == 2 }
    try expect(failures.snapshot == 0 && bridge.state.snapshot.submitted == [input, Data([0x45, 4])],
      "a refused write, or refusals that a written batch ended, stopped the pump")
    // Refusals through the whole grace stop the current pump exactly once.
    try await Task.sleep(for: .milliseconds(400))
    bridge.push([Data([0x45, 7])])
    await failed.wait()
    let failedPolls = bridge.state.snapshot.polls
    flow.deliver(Data([0x45, 8]))
    try await Task.sleep(for: .milliseconds(50))
    try expect(failures.snapshot == 1 && bridge.state.snapshot.polls == failedPolls &&
      bridge.state.snapshot.submitted == [input, Data([0x45, 4])], "refused writes did not stop the current pump exactly once")
    print("PASS packet pump rejects stale reads after restart, drops refused writes and stops when refusals last")
  }

  @MainActor
  static func checkReconnectCommands() async throws {
    let previous = Data("previous fixture plan".utf8), candidate = Data("candidate fixture plan".utf8)
    var events: [String] = []
    try await TunnelCommandCoordinator.reconnect(
      from: previous, to: previous,
      stop: { events.append("stop") },
      start: { events.append("candidate") },
      restore: { events.append("previous") })
    try expect(events.isEmpty, "unchanged plan from an import restarted the connection")
    try await TunnelCommandCoordinator.reconnect(
      from: previous, to: candidate,
      stop: { events.append("stop") },
      start: { events.append("candidate") },
      restore: { events.append("previous") })
    try expect(events == ["stop", "candidate"], "reconnect did not start candidate after stopping")

    events = []
    do {
      try await TunnelCommandCoordinator.reconnect(
        from: previous, to: candidate,
        stop: { events.append("stop"); throw Failure(message: "fixture stop") },
        start: { events.append("candidate") },
        restore: { events.append("previous") })
      throw Failure(message: "failed stop accepted")
    } catch let error as Failure {
      try expect(error.message == "fixture stop" && events == ["stop"], "reconnect continued after failed stop")
    }
    for restoreFails in [false, true] {
      events = []
      do {
        try await TunnelCommandCoordinator.reconnect(
          from: previous, to: candidate,
          stop: { events.append("stop") },
          start: { events.append("candidate"); throw Failure(message: "fixture startup") },
          restore: {
            events.append("previous")
            if restoreFails { throw Failure(message: "fixture restoration") }
          })
        throw Failure(message: "failed candidate accepted")
      } catch let failure as TunnelCommandCoordinator.ReconnectFailure {
        try expect(failure == (restoreFails ? .restoreFailed : .restored), "incorrect restoration outcome")
      }
      try expect(events == ["stop", "candidate", "stop", "previous"], "restoration did not stop candidate first")
    }

    for cancelDuring in ["stop", "candidate", "previous"] {
      let suite = "elarni-reconnect-\(UUID().uuidString)"
      let defaults = UserDefaults(suiteName: suite)!
      defer { defaults.removePersistentDomain(forName: suite) }
      let commands = TunnelCommandCoordinator(defaults: defaults)
      let entered = Signal()
      events = []
      let reconnect = Task { @MainActor in
        try await commands.perform(intent: .connected) {
          try await TunnelCommandCoordinator.reconnect(from: previous, to: candidate, stop: {
            events.append("stop")
            if cancelDuring == "stop" {
              await entered.fire()
              try await Task.sleep(for: .seconds(20))
            }
          }, start: {
            events.append("candidate")
            if cancelDuring == "candidate" {
              await entered.fire()
              try await Task.sleep(for: .seconds(20))
            }
            throw Failure(message: "fixture startup")
          }, restore: {
            events.append("previous")
            await entered.fire()
            try await Task.sleep(for: .seconds(20))
          })
        }
      }
      await entered.wait()
      try await commands.perform(intent: .disconnected) { events.append("user stop") }
      do { try await reconnect.value; throw Failure(message: "Stop did not cancel reconnect") }
      catch is CancellationError {}
      let expected = cancelDuring == "stop" ? ["stop"] :
        (cancelDuring == "candidate" ? ["stop", "candidate"] : ["stop", "candidate", "stop", "previous"])
      try expect(events == expected + ["user stop"], "reconnect continued after Stop")
      try expect(commands.intent == .disconnected, "reconnect replaced Stop intent")
    }
  }

  @MainActor
  static func checkConcurrentCommands() async throws {
    let suite = "elarni-probe-commands-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let commands = TunnelCommandCoordinator(defaults: defaults)
    let entered = Signal(), release = Signal()
    var started = 0, mutated = false
    let probes = (0..<8).map { _ in Task { @MainActor in
      try await commands.perform(concurrent: true) {
        started += 1
        if started == 8 { await entered.fire() }
        await release.wait()
        try Task.checkCancellation()
      }
    } }
    await entered.wait()
    var read = false
    try await commands.perform(readOnly: true) { read = true }
    try expect(read && started == 8, "read waited for probes")
    let mutation = Task { @MainActor in
      try await commands.perform(automatic: true) { mutated = true }
    }
    await Task.yield()
    try expect(!mutated, "mutation overtook unfinished probes")
    await release.fire()
    for task in probes { try await task.value }
    try await mutation.value
    try expect(mutated, "mutation did not resume")
    for intent: TunnelCommandCoordinator.Intent? in [.connected, nil, .disconnected] {
      let cancelledEntry = Signal()
      let pending = Task { @MainActor in
        try await commands.perform(concurrent: true) {
          await cancelledEntry.fire()
          try await Task.sleep(for: .seconds(20))
        }
      }
      await cancelledEntry.wait()
      let started = ProcessInfo.processInfo.systemUptime
      try await commands.perform(intent: intent) {}
      do { try await pending.value; throw Failure(message: "foreground command did not cancel probe") }
      catch is CancellationError {}
      try expect(ProcessInfo.processInfo.systemUptime - started < 2, "foreground command waited for probe deadline")
    }
    try expect(commands.intent == .disconnected, "stop intent changed")
    try await commands.perform(concurrent: true) {}
  }

  static func cleanupChecks() async throws {
    for deadlineFirst in [false, true] {
      let started = Signal(), release = Signal(), completed = Signal(), drained = Signal()
      let events = Locked<[String]>([])
      let outcomes = Locked<[Bool]>([])
      let deadline = Locked<(@Sendable () -> Void)?>(nil)
      let startup = Task {
        await started.fire()
        await release.wait() // Models blocking native work completing after cancellation.
        events.withValue { $0.append("startup") }
      }
      await started.wait()
      let cleanup = ProviderLifecycleRuntime.cleanup(
        detached: ProviderDetachedResources(attempt: nil, startupTask: startup, monitorTask: nil, pump: nil),
        clearSettings: { events.withValue { $0.append("settings") }; await drained.fire(); return true },
        stopBridge: { events.withValue { $0.append("bridge") }; return true },
        stopXray: { events.withValue { $0.append("xray") }; return true },
        scheduleDeadline: { action in deadline.withValue { $0 = action } },
        completion: { owners in outcomes.withValue { $0.append(owners) }; Task { await completed.fire() } })
      try expect(events.snapshot.isEmpty && outcomes.snapshot.isEmpty, "cleanup ran before startup joined")
      if deadlineFirst { deadline.snapshot!(); await completed.wait() }
      await release.fire()
      await drained.wait()
      await cleanup.value
      if !deadlineFirst { await completed.wait() }
      deadline.snapshot!()
      try expect(events.snapshot == ["startup", "bridge", "xray", "settings"], "cleanup order")
      try expect(outcomes.snapshot == [deadlineFirst], "cleanup completed twice or lost quarantine")
      print("PASS cleanup \(deadlineFirst ? "deadline quarantines late owners" : "joins startup before stopping resources")")
    }
  }
}
