import Foundation

struct ProviderLifecycleGeneration: Equatable, Sendable {
  let rawValue: UInt64
}

enum ProviderLifecycleState: Equatable, Sendable {
  case idle
  case starting(ProviderLifecycleGeneration)
  case running(ProviderLifecycleGeneration)
  case switching(ProviderLifecycleGeneration)
  case protectedFailure(ProviderLifecycleGeneration)
  case stopping(ProviderLifecycleGeneration)
  case quarantinedFailClosed(ProviderLifecycleGeneration)

  var label: String {
    switch self {
    case .idle: "disconnected"
    case .starting: "connecting"
    case .running: "connected"
    case .switching: "reasserting"
    case .protectedFailure: "protectedFailure"
    case .stopping: "disconnecting"
    case .quarantinedFailClosed: "quarantinedFailClosed"
    }
  }

  var generation: UInt64? {
    switch self {
    case .idle: return nil
    case .starting(let value), .running(let value), .switching(let value),
         .protectedFailure(let value), .stopping(let value), .quarantinedFailClosed(let value):
      return value.rawValue
    }
  }
}

enum ProviderLifecycleStopAction: Equatable, Sendable {
  case cleanup(ProviderLifecycleGeneration)
  case joined
  case completed
  case rejected
}

final class ProviderLifecycleCoordinator: @unchecked Sendable {
  private let lock = NSLock()
  private var nextGeneration: UInt64 = 0
  private var currentState: ProviderLifecycleState = .idle
  private var switchOrigin: ProviderLifecycleState = .idle
  private var stopCompletions: [() -> Void] = []

  var state: ProviderLifecycleState {
    withLock { currentState }
  }

  func beginStart(
    reserving reserve: (ProviderLifecycleGeneration) -> Bool = { _ in true }
  ) -> ProviderLifecycleGeneration? {
    withLock {
      guard currentState == .idle else { return nil }
      nextGeneration &+= 1
      if nextGeneration == 0 { nextGeneration = 1 }
      let generation = ProviderLifecycleGeneration(rawValue: nextGeneration)
      guard reserve(generation) else { return nil }
      currentState = .starting(generation)
      return generation
    }
  }

  func isActive(_ generation: ProviderLifecycleGeneration) -> Bool {
    withLock {
      currentState == .starting(generation) || currentState == .running(generation)
        || currentState == .switching(generation)
    }
  }

  func beginSwitch(requiringRunning: Bool = false) -> ProviderLifecycleGeneration? {
    withLock {
      let generation: ProviderLifecycleGeneration
      switch currentState {
      case .running(let value): generation = value
      case .protectedFailure(let value) where !requiringRunning: generation = value
      default: return nil
      }
      switchOrigin = currentState
      currentState = .switching(generation)
      return generation
    }
  }

  @discardableResult
  func protectFailure(_ generation: ProviderLifecycleGeneration) -> Bool {
    withLock {
      guard currentState == .running(generation) else { return false }
      currentState = .protectedFailure(generation)
      return true
    }
  }

  /// `restored` returns to the state the switch began in; `started` means a core now carries traffic.
  @discardableResult
  func finishSwitch(_ generation: ProviderLifecycleGeneration, restored: Bool, started: Bool = false,
                    quarantined: Bool = false) -> Bool {
    withLock {
      guard currentState == .switching(generation) else { return false }
      currentState = quarantined ? .quarantinedFailClosed(generation) :
        (started || restored && switchOrigin == .running(generation) ? .running(generation) : .protectedFailure(generation))
      return true
    }
  }

  @discardableResult
  func markRunning(_ generation: ProviderLifecycleGeneration) -> Bool {
    withLock {
      guard currentState == .starting(generation) else { return false }
      currentState = .running(generation)
      return true
    }
  }

  @discardableResult
  func beginFailureCleanup(_ generation: ProviderLifecycleGeneration) -> Bool {
    withLock {
      guard currentState == .starting(generation) || currentState == .running(generation) else {
        return false
      }
      currentState = .stopping(generation)
      return true
    }
  }

  func beginStop(expectedGeneration: UInt64? = nil, completion: @escaping () -> Void) -> ProviderLifecycleStopAction {
    let result: ProviderLifecycleStopAction = withLock {
      if let expectedGeneration, expectedGeneration != (currentState.generation ?? 0) { return .rejected }
      switch currentState {
      case let .starting(generation), let .running(generation),
           let .switching(generation), let .protectedFailure(generation):
        currentState = .stopping(generation)
        stopCompletions.append(completion)
        return .cleanup(generation)
      case .stopping:
        stopCompletions.append(completion)
        return .joined
      case .idle, .quarantinedFailClosed:
        return .completed
      }
    }
    if result == .completed { completion() }
    return result
  }

  func finishStop(_ generation: ProviderLifecycleGeneration, ownersRemain: Bool) {
    let completions: [() -> Void] = withLock {
      guard currentState == .stopping(generation) else { return [] }
      currentState = ownersRemain ? .quarantinedFailClosed(generation) : .idle
      let result = stopCompletions
      stopCompletions.removeAll(keepingCapacity: false)
      return result
    }
    completions.forEach { $0() }
  }

  private func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }
}
