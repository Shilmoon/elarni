import Foundation

#if DEBUG
// A single, expiring fault belongs to one provider generation and operation.
// Receipts contain only identifiers and fixed event codes, including after a failed start.
final class ProviderDebugFaults: @unchecked Sendable {
  enum Action: String, Codable { case startupFailure, coreExit, candidateFailure, restoreFailure }
  enum Point: String, Codable { case startup, coreExit, candidate, restoration }
  enum Failure: Error { case rejected, injected }
  struct Request: Codable {
    let id: UUID
    let action: Action
    let expiresAt: Double
    let instanceID: String?
    let generation: UInt64?
  }
  struct Receipt: Codable {
    let request: Request
    let instanceID: String
    let generation: UInt64
    var points: [Point] = []
    var outcome = "armed"
  }
  struct StopReceipt: Codable, Equatable {
    let instanceID: UUID
    let generation: UInt64
    let completedAtMs: Int64

    func confirmedTime(instance: UUID, generation expectedGeneration: UInt64,
                       after started: Int64, osDisconnected: Int64) -> Int64? {
      guard instanceID == instance, generation == expectedGeneration, generation > 0,
            started <= completedAtMs, completedAtMs <= osDisconnected else { return nil }
      return completedAtMs
    }
  }
  private let lock = NSLock()
  private var receipt: Receipt?
  private var owner: UUID?
  private var usedIDs = Set<UUID>()
  private let save: (Receipt) throws -> Void
  init(save: @escaping (Receipt) throws -> Void) { self.save = save }

  func arm(_ request: Request, instanceID: String, generation: UInt64, now: Double) throws {
    try lock.withLock {
      guard now.isFinite, request.expiresAt.isFinite,
            request.expiresAt > now, request.expiresAt <= now + 30,
            generation > 0,
            request.action == .startupFailure
              ? (request.instanceID == nil && request.generation == nil)
              : (request.instanceID == instanceID && request.generation == generation),
            owner == nil, !usedIDs.contains(request.id), usedIDs.count < 64 else {
        throw Failure.rejected
      }
      let next = Receipt(request: request, instanceID: instanceID, generation: generation)
      try save(next)
      receipt = next
      owner = request.id
      usedIDs.insert(request.id)
    }
  }

  func consume(_ point: Point, generation: UInt64, operationID: UUID? = nil, now: Double) throws -> Bool {
    try lock.withLock {
      guard var current = receipt, current.outcome == "armed", current.generation == generation else { return false }
      guard now.isFinite, current.request.expiresAt > now else {
        current.outcome = "expired"
        receipt = current
        try save(current)
        return false
      }
      let expected: [Point]
      switch current.request.action {
      case .startupFailure: expected = [.startup]
      case .coreExit: expected = [.coreExit]
      case .candidateFailure:
        guard operationID == current.request.id else { return false }
        expected = [.candidate]
      case .restoreFailure:
        guard operationID == current.request.id else { return false }
        expected = [.candidate, .restoration]
      }
      guard current.points.count < expected.count, expected[current.points.count] == point else { return false }
      current.points.append(point)
      try save(current)
      receipt = current
      return true
    }
  }

  func finish(_ outcome: String, generation: UInt64, requestID: UUID? = nil) {
    lock.withLock {
      guard var current = receipt, current.generation == generation, owner == current.request.id,
            requestID == current.request.id ||
              (requestID == nil && (outcome == "cancelled" ||
                (outcome == "coreExited" && current.request.action == .coreExit && current.points == [.coreExit]))) else { return }
      owner = nil
      if current.outcome == "armed" {
        current.outcome = outcome == "startupFailed" && current.points != [.startup] ? "failedBeforeInjection" : outcome
      }
      receipt = current
      // An absent/stale receipt cannot pass the runner's exact outcome assertion.
      try? save(current)
    }
  }

  static func receiptURL() throws -> URL {
#if os(iOS)
    let container = IOSPlatform.containerURL
#else
    let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.elarni.mac")
#endif
    guard let group = container else {
      throw Failure.rejected
    }
    return group.appendingPathComponent("elarni-debug-fault.json")
  }
  static func save(_ receipt: Receipt) throws {
    try JSONEncoder().encode(receipt).write(to: receiptURL(), options: .atomic)
  }
  static func read(id: UUID) throws -> Receipt {
    let data = try Data(contentsOf: receiptURL())
    guard data.count <= 4096 else { throw Failure.rejected }
    let receipt = try JSONDecoder().decode(Receipt.self, from: data)
    guard receipt.request.id == id else { throw Failure.rejected }
    return receipt
  }
  static func saveStop(_ receipt: StopReceipt) throws {
    let url = try receiptURL().deletingLastPathComponent().appendingPathComponent("elarni-debug-stop.json")
    try JSONEncoder().encode(receipt).write(to: url, options: .atomic)
  }
  static func readStop() throws -> StopReceipt {
    let url = try receiptURL().deletingLastPathComponent().appendingPathComponent("elarni-debug-stop.json")
    let data = try Data(contentsOf: url)
    guard data.count <= 4096 else { throw Failure.rejected }
    return try JSONDecoder().decode(StopReceipt.self, from: data)
  }
}
#endif
