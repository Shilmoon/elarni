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
  #if DEBUG
  func injectExit()
  #endif
}

struct PreparedXray: Sendable {
  let config: String
  let addresses: [String]
  let memoryLimitBytes: Int
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
  private let lock = NSLock()
  private var running = false
  private var generation: UInt64 = 0

  init(flow: PacketFlow, bridge: PacketBridge, onFailure: @escaping (Error) -> Void) {
    self.flow = flow
    self.bridge = bridge
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
    // second instead of polling. A stopped pump's thread ends at its next wake, a stopped bridge's at once.
    let output = Thread { [weak self] in
      while let self, self.isCurrent(started), let ready = self.bridge.awaitOutput(timeout: .seconds(1)) {
        if ready { self.drainOutput(generation: started) }
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

  private func readNextBatch(generation: UInt64) {
    guard lock.withLock({ self.running && self.generation == generation }) else { return }
    flow.readPacketObjects { [weak self] packets in
      guard let self else { return }
      do {
        let submitted = try lock.withLock {
          guard self.running && self.generation == generation else { return false }
          for packet in packets { try self.bridge.submit(packet.data) }
          return true
        }
        guard submitted else { return }
        readNextBatch(generation: generation)
      } catch {
        fail(error, generation: generation)
      }
    }
  }

  // Writes up to 256 packets; the bridge reports more at once on the next wait.
  private func drainOutput(generation: UInt64) {
    let rejected = lock.withLock {
      guard self.running && self.generation == generation else { return false }
      var output = [NEPacket]()
      while output.count < 256, let data = bridge.receive() {
        let family = data.first.map { $0 >> 4 } == 6 ? AF_INET6 : AF_INET
        output.append(NEPacket(data: data, protocolFamily: sa_family_t(family)))
      }
      return !output.isEmpty && !flow.writePacketObjects(output)
    }
    if rejected { fail(PacketFlowError.writeRejected, generation: generation) }
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
// each interval while traffic leaves or the last check failed. The counters only
// gate the check; their downlink proves nothing, since SOCKS replies and direct
// routes move it while the server is gone.
struct ProviderLiveness {
  // The failover defaults, as on desktop and Android.
  static let targets = ["https://www.gstatic.com/generate_204", "https://cp.cloudflare.com/generate_204"]
  let interval: TimeInterval
  private(set) var state: String?
  private var checked: (at: TimeInterval, uplink: UInt64)?

  init(interval: TimeInterval = 60) { self.interval = interval }

  func due(at now: TimeInterval) -> Bool { checked.map { now - $0.at >= interval } ?? true }

  // An idle interval after a passing check starts the next interval instead.
  mutating func needsProbe(uplink: UInt64, at now: TimeInterval) -> Bool {
    if let checked, state == "ok", uplink <= checked.uplink {
      self.checked = (now, uplink)
      return false
    }
    return true
  }

  mutating func record(passed: Bool, uplink: UInt64, at now: TimeInterval) {
    state = passed ? "ok" : "noTraffic"
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
