import Foundation
import NetworkExtension

protocol XrayCore: AnyObject, Sendable {
  func prepare(
    plan: TunnelPlan,
    endpoint: inout SecretValue,
    servers: [String: SecretValue],
    inboundCredentials: InboundCredentials?,
    attempt: ProviderBoundaryAttempt
  ) async throws -> PreparedXray
  func start(_ prepared: PreparedXray, attempt: ProviderBoundaryAttempt) async throws
  func stop() async throws
  func isRunning() async -> Bool
  func metrics() async -> [String: UInt64]
  // A request through the running core's routing, the way app traffic goes.
  func passesTraffic(url: String, timeout: Int) async -> Bool
  /// Tells the running core its network moved, so it checks pooled connections and dials new ones on the
  /// current path. False when the core cannot take the signal.
  func socketPathChanged() async -> Bool
  #if DEBUG
  func injectExit()
  #endif
}

struct PreparedXray: Sendable {
  let config: String
  let addresses: [String]
  let memoryLimitBytes: Int
  /// Digest of everything that produced `config`; equal digests mean an equal configuration.
  var source: Data? = nil
}

protocol PacketBridge: AnyObject, Sendable {
  func start(
    socksPort: UInt16,
    mtu: UInt16,
    tcpMaxConnections: Int,
    udpMaxConnections: Int,
    inboundCredentials: InboundCredentials?,
    attempt: ProviderBoundaryAttempt
  ) async throws
  func submit(_ packet: Data) throws
  func receive() -> Data?
  /// Blocks until receive() has a packet (true), the timeout passes (false) or the bridge stopped (nil).
  func awaitOutput(timeout: Duration) -> Bool?
  func stop(deadline: Duration) async throws
  var counters: [String: UInt64] { get }
}

protocol PacketFlow: AnyObject {
  func readPacketObjects(completionHandler: @escaping @Sendable ([NEPacket]) -> Void)
  func writePacketObjects(_ packets: [NEPacket]) -> Bool
}

extension NEPacketTunnelFlow: PacketFlow {}

final class PacketFlowPump: @unchecked Sendable {
  private let flow: PacketFlow
  private let bridge: PacketBridge
  private let onFailure: (Error) -> Void
  // NetworkExtension may refuse writes while settings are re-applied (well under a second); refusals
  // that last this long, across at least two batches, mean the tunnel is gone.
  private let rejectionGrace: TimeInterval
  private let lock = NSLock()
  private var running = false
  private var generation: UInt64 = 0

  init(flow: PacketFlow, bridge: PacketBridge, rejectionGrace: TimeInterval = 5, onFailure: @escaping (Error) -> Void) {
    self.flow = flow
    self.bridge = bridge
    self.rejectionGrace = rejectionGrace
    self.onFailure = onFailure
  }

  func start() {
    let started = lock.withLock { () -> UInt64? in
      guard !self.running else { return nil }
      self.generation &+= 1
      self.running = true
      return self.generation
    }
    guard let started else { return }
    // The output thread sleeps in the bridge until a packet is ready: an idle tunnel wakes once a
    // minute instead of polling. A stopped pump's thread ends at its next wake, a stopped bridge's at once.
    let output = Thread { [weak self] in
      var rejectedSince: TimeInterval?
      while let self, self.isCurrent(started), let ready = self.bridge.awaitOutput(timeout: .seconds(60)) {
        // A thread's own pool drains only when the thread ends; without one per wake every written NEPacket stays alive.
        if ready { autoreleasepool { self.drainOutput(generation: started, rejectedSince: &rejectedSince) } }
      }
    }
    output.name = "com.elarni.packet-output"
    output.qualityOfService = .userInitiated
    output.start()
    readNextBatch(generation: started)
  }

  func stop() {
    lock.withLock { self.running = false }
  }

  private func isCurrent(_ generation: UInt64) -> Bool {
    lock.withLock { self.running && self.generation == generation }
  }

  // The pump's lock covers only the generation check: the bridge locks itself, and holding this one
  // across submit or a write would make each direction wait for the other. A submit that races a stop
  // throws notRunning, which fail() ignores for a stopped pump.
  private func readNextBatch(generation: UInt64) {
    guard isCurrent(generation) else { return }
    flow.readPacketObjects { [weak self] packets in
      guard let self, self.isCurrent(generation) else { return }
      do {
        for packet in packets { try self.bridge.submit(packet.data) }
      } catch {
        self.fail(error, generation: generation)
        return
      }
      self.readNextBatch(generation: generation)
    }
  }

  // Writes up to 256 packets; the bridge reports more at once on the next wait. A refused batch is
  // dropped like a congested link drops it; only refusals for rejectionGrace fail the pump.
  private func drainOutput(generation: UInt64, rejectedSince: inout TimeInterval?) {
    guard isCurrent(generation) else { return }
    var output = [NEPacket]()
    while output.count < 256, let data = bridge.receive() {
      let family = data.first.map { $0 >> 4 } == 6 ? AF_INET6 : AF_INET
      output.append(NEPacket(data: data, protocolFamily: sa_family_t(family)))
    }
    guard !output.isEmpty else { return }
    if flow.writePacketObjects(output) {
      rejectedSince = nil
      return
    }
    let now = ProcessInfo.processInfo.systemUptime
    DiagnosticLog.record("packet_write_rejected", ["packets": Int64(output.count)])
    guard let since = rejectedSince else {
      rejectedSince = now
      return
    }
    if now - since >= rejectionGrace { fail(PacketFlowError.writeRejected, generation: generation) }
  }

  private func fail(_ error: Error, generation: UInt64) {
    let failed = lock.withLock { () -> Bool in
      guard self.running && self.generation == generation else { return false }
      self.running = false
      return true
    }
    if failed { onFailure(error) }
  }
}

enum PacketFlowError: Error { case writeRejected }

// Whether the connected server passes traffic: checked once after Connect, then
// each interval while traffic leaves. An idle tunnel is not checked, even after a
// failed check: nothing needs the server, and each check keeps the radio awake.
// The counters only gate the check; their downlink proves nothing, since SOCKS
// replies and direct routes move it while the server is gone.
struct ProviderLiveness {
  // The failover defaults, as on desktop and Android.
  static let targets = ["https://www.gstatic.com/generate_204", "https://cp.cloudflare.com/generate_204"]
  let interval: TimeInterval
  private(set) var state: String?
  /// Failed checks since the last one that passed.
  private(set) var failures = 0
  private var checked: (at: TimeInterval, uplink: UInt64)?

  init(interval: TimeInterval = 60) { self.interval = interval }

  func due(at now: TimeInterval) -> Bool { checked.map { now - $0.at >= interval } ?? true }

  // An idle interval starts the next interval instead.
  mutating func needsProbe(uplink: UInt64, at now: TimeInterval) -> Bool {
    if let checked, uplink <= checked.uplink {
      self.checked = (now, uplink)
      return false
    }
    return true
  }

  mutating func record(passed: Bool, uplink: UInt64, at now: TimeInterval) {
    state = passed ? "ok" : "noTraffic"
    failures = passed ? 0 : failures + 1
    checked = (now, uplink)
  }
}

private extension NSLock {
  func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
