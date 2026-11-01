import Foundation

// Cancellation may arrive before the switch message. Keep its identity until
// admission; saturation rejects further work instead of forgetting cancellation.
final class ProviderSwitchCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var active: UUID?
  private var cancelled: Set<UUID> = []

  var saturated: Bool { lock.withLock { cancelled.count >= 64 } }

  func admit(_ id: UUID) -> Bool {
    lock.withLock {
      guard active == nil, cancelled.count < 64, !cancelled.contains(id) else { return false }
      active = id
      return true
    }
  }

  func cancel(_ id: UUID) -> Bool {
    lock.withLock {
      if cancelled.count < 64 || active == id { cancelled.insert(id) }
      return active == id
    }
  }

  func isCancelled(_ id: UUID) -> Bool {
    lock.withLock { active != id || cancelled.contains(id) }
  }

  func finish(_ id: UUID) {
    lock.withLock {
      if active == id { active = nil }
      // Keep cancelled identities: a delayed duplicate cannot revive an attempt.
    }
  }
}
