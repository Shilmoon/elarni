import Foundation

extension ServerSubscription {
  /// SubscriptionStore stores expire as Int64, which `as? Double` never matches.
  var expireSeconds: Double? { (metadata["expire"] as? NSNumber)?.doubleValue }
}

enum IOSExpiryReminders {
  struct Reminder { let id: String; let expiration: Double; let delay: TimeInterval }
  struct Plan { let additions: [Reminder]; let removals: [String]; let retained: [String: Double] }

  static func plan(sources: [ServerSubscription], enabled: Bool, recorded: [String: Double], now: Date) -> Plan {
    let eligible: [(String, Double)] = enabled ? sources.compactMap { source in
      guard !source.local, let expiration = source.expireSeconds,
            expiration.isFinite, expiration > now.timeIntervalSince1970 else { return nil }
      return (source.id, expiration)
    }.sorted { $0.1 < $1.1 } : []
    // Leave room for future app notifications in iOS's pending-request queue.
    let desired = Dictionary(uniqueKeysWithValues: eligible.prefix(60))
    let retained = recorded.filter { desired[$0.key] == $0.value }
    let removals = recorded.keys.filter { retained[$0] == nil }.sorted()
    let additions = desired.filter { recorded[$0.key] != $0.value }.map { id, expiration in
      Reminder(id: id, expiration: expiration, delay: max(60, expiration - 3 * 86400 - now.timeIntervalSince1970))
    }.sorted { $0.expiration < $1.expiration }
    return Plan(additions: additions, removals: removals, retained: retained)
  }
}
