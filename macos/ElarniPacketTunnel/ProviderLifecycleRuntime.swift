import Foundation

extension SecretValue: @unchecked Sendable {}

struct ProviderDetachedResources: @unchecked Sendable {
  let attempt: ProviderBoundaryAttempt?
  let startupTask: Task<Void, Never>?
  let monitorTask: Task<Void, Never>?
  let pump: PacketFlowPump?
}

final class ProviderLifecycleRuntime: @unchecked Sendable {
  private let lock = NSLock()
  private var generation: ProviderLifecycleGeneration?
  private var attempt: ProviderBoundaryAttempt?
  private var startupTask: Task<Void, Never>?
  private var monitorTask: Task<Void, Never>?
  private var pump: PacketFlowPump?
  private var keychainGeneration: ProviderLifecycleGeneration?
  private var highestReservedGeneration: UInt64 = 0

  func reserve(_ generation: ProviderLifecycleGeneration) -> Bool {
    withLock {
      guard
        self.generation == nil,
        generation.rawValue > highestReservedGeneration
      else { return false }
      self.generation = generation
      highestReservedGeneration = generation.rawValue
      attempt = nil
      startupTask = nil
      monitorTask = nil
      pump = nil
      keychainGeneration = nil
      return true
    }
  }

  @discardableResult
  func setAttempt(
    _ attempt: ProviderBoundaryAttempt,
    generation: ProviderLifecycleGeneration
  ) -> Bool {
    withLock {
      guard self.generation == generation, self.attempt == nil else { return false }
      self.attempt = attempt
      return true
    }
  }

  func launchStartup(
    generation: ProviderLifecycleGeneration,
    operation: @escaping @Sendable () async -> Void
  ) -> Bool {
    withLock {
      guard self.generation == generation, startupTask == nil else { return false }
      startupTask = Task { await operation() }
      return true
    }
  }

  func pauseMonitor(_ generation: ProviderLifecycleGeneration) async {
    let task: Task<Void, Never>? = withLock {
      guard self.generation == generation else { return nil }
      let task = monitorTask
      monitorTask = nil
      task?.cancel()
      return task
    }
    await task?.value
  }

  func launchMonitor(
    generation: ProviderLifecycleGeneration,
    operation: @escaping @Sendable () async -> Void
  ) -> Bool {
    withLock {
      guard self.generation == generation else { return false }
      monitorTask = Task { await operation() }
      return true
    }
  }

  @discardableResult
  func installAndStartPump(
    _ pump: PacketFlowPump,
    generation: ProviderLifecycleGeneration
  ) -> Bool {
    withLock {
      guard self.generation == generation else { return false }
      pump.start()
      self.pump = pump
      return true
    }
  }

  func markKeychainResolved(_ generation: ProviderLifecycleGeneration) {
    withLock {
      if self.generation == generation { keychainGeneration = generation }
    }
  }

  var sharedKeychainResolved: Bool {
    withLock { generation != nil && keychainGeneration == generation }
  }

  var currentAttempt: ProviderBoundaryAttempt? { withLock { attempt } }

  func startupFinished(_ finishedGeneration: ProviderLifecycleGeneration) {
    withLock {
      if generation == finishedGeneration { startupTask = nil }
    }
  }

  func cancelStartup(_ cancelledGeneration: ProviderLifecycleGeneration) {
    lock.withLock {
      if generation == cancelledGeneration { startupTask?.cancel() }
    }
  }

  func detach(_ detachedGeneration: ProviderLifecycleGeneration) -> ProviderDetachedResources {
    withLock {
      guard generation == detachedGeneration else {
        return ProviderDetachedResources(
          attempt: nil,
          startupTask: nil,
          monitorTask: nil,
          pump: nil
        )
      }
      let resources = ProviderDetachedResources(
        attempt: attempt,
        startupTask: startupTask,
        monitorTask: monitorTask,
        pump: pump
      )
      generation = nil
      attempt = nil
      startupTask = nil
      monitorTask = nil
      pump = nil
      keychainGeneration = nil
      return resources
    }
  }

  static func runBlocking<T: Sendable>(
    _ operation: @escaping @Sendable () throws -> T
  ) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          continuation.resume(returning: try operation())
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  @discardableResult
  static func cleanup(
    detached: ProviderDetachedResources,
    clearSettings: @escaping @Sendable () async -> Bool,
    stopBridge: @escaping @Sendable () async -> Bool,
    stopXray: @escaping @Sendable () async -> Bool,
    scheduleDeadline: (@escaping @Sendable () -> Void) -> Void = { action in
      DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .seconds(3), execute: action)
    },
    completion: @escaping @Sendable (_ ownersRemain: Bool) -> Void
  ) -> Task<Void, Never> {
    detached.startupTask?.cancel()
    detached.monitorTask?.cancel()
    detached.pump?.stop()

    let join = ProviderCleanupJoin(remaining: 1, completion: completion)
    let work = Task.detached {
      // Producers can finish a blocking native start after cancellation.
      // Join them before the final stop so no late core can outlive cleanup.
      await detached.startupTask?.value
      await detached.monitorTask?.value
      let bridgeConfirmed = await stopBridge()
      let xrayConfirmed = await stopXray()
      let settingsConfirmed = await clearSettings()
      join.operationFinished(
        confirmed: bridgeConfirmed && xrayConfirmed && settingsConfirmed
      )
    }
    scheduleDeadline {
      join.deadlineReached()
    }
    return work
  }

  private func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }
}

private final class ProviderCleanupJoin: @unchecked Sendable {
  private let lock = NSLock()
  private var remaining: Int
  private var hasUnconfirmedCleanup = false
  private var completed = false
  private let completion: @Sendable (Bool) -> Void

  init(remaining: Int, completion: @escaping @Sendable (Bool) -> Void) {
    self.remaining = remaining
    self.completion = completion
  }

  func operationFinished(confirmed: Bool) {
    let result: Bool? = withLock {
      guard !completed, remaining > 0 else { return nil }
      if !confirmed { hasUnconfirmedCleanup = true }
      remaining -= 1
      if remaining == 0 {
        completed = true
        return hasUnconfirmedCleanup
      }
      return nil
    }
    if let mustQuarantine = result { completion(mustQuarantine) }
  }

  func deadlineReached() {
    let ownersRemain: Bool? = withLock {
      guard !completed else { return nil }
      completed = true
      return remaining > 0 || hasUnconfirmedCleanup
    }
    if let ownersRemain { completion(ownersRemain) }
  }

  private func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }
}
