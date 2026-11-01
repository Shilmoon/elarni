import Foundation
import Security

enum SubscriptionRiskCode: String, Codable, CaseIterable {
  case cleartextHTTP = "cleartext_http"
  case loopbackTarget = "loopback_target"
  case privateTarget = "private_target"
}

struct SubscriptionApprovalRequirement: Error {
  let riskCodes: [SubscriptionRiskCode]
  let candidateChain: [String]
}

struct SubscriptionSafetyWarning {
  let subscriptionID: String
  let riskCodes: [SubscriptionRiskCode]
  let challenge: String
  /// Scheme, host and port of each fetch in the chain; paths can carry the token.
  var destinations: [String] = []

  var channelMap: [String: Any] {
    [
      "subscriptionId": subscriptionID,
      "riskCodes": riskCodes.map(\.rawValue),
      "challenge": challenge,
    ]
  }
}

enum SubscriptionSafetyError: Error {
  case invalidChallenge
}

@MainActor
final class SubscriptionApprovalChallengeVault {
  private struct Entry {
    let subscriptionID: String
    let candidateChain: [String]
    let expiry: Date
  }

  private let lifetime: TimeInterval
  private let now: () -> Date
  private let randomBytes: (Int) throws -> Data
  private var entries: [String: Entry] = [:]

  init(
    lifetime: TimeInterval = 5 * 60,
    now: @escaping () -> Date = Date.init,
    randomBytes: @escaping (Int) throws -> Data = SubscriptionApprovalChallengeVault.secureRandom
  ) {
    self.lifetime = lifetime
    self.now = now
    self.randomBytes = randomBytes
  }

  func issue(
    subscriptionID: String,
    requirement: SubscriptionApprovalRequirement
  ) throws -> SubscriptionSafetyWarning {
    entries = entries.filter { $0.value.subscriptionID != subscriptionID && $0.value.expiry > now() }
    let token = try randomBytes(32)
      .base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    entries[token] = Entry(
      subscriptionID: subscriptionID,
      candidateChain: requirement.candidateChain,
      expiry: now().addingTimeInterval(lifetime)
    )
    return SubscriptionSafetyWarning(
      subscriptionID: subscriptionID,
      riskCodes: requirement.riskCodes,
      challenge: token,
      destinations: requirement.candidateChain.map { text in
        guard let url = URLComponents(string: text), let scheme = url.scheme, let host = url.host else { return "Invalid destination" }
        // Foundation keeps an IPv6 literal's brackets in `host`.
        return "\(scheme)://\(host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host)" + (url.port.map { ":\($0)" } ?? "")
      }
    )
  }

  func consume(_ token: String, subscriptionID: String) throws -> [String] {
    guard let entry = entries[token] else { throw SubscriptionSafetyError.invalidChallenge }
    guard entry.subscriptionID == subscriptionID else {
      throw SubscriptionSafetyError.invalidChallenge
    }
    guard entry.expiry > now() else {
      entries.removeValue(forKey: token)
      throw SubscriptionSafetyError.invalidChallenge
    }
    entries.removeValue(forKey: token)
    return entry.candidateChain
  }

  func revoke(_ token: String) {
    entries.removeValue(forKey: token)
  }

  func invalidate(subscriptionID: String) {
    entries = entries.filter { $0.value.subscriptionID != subscriptionID }
  }

  nonisolated private static func secureRandom(count: Int) throws -> Data {
    var data = Data(count: count)
    let status = data.withUnsafeMutableBytes { bytes in
      SecRandomCopyBytes(kSecRandomDefault, count, bytes.baseAddress!)
    }
    guard status == errSecSuccess else { throw SubscriptionSafetyError.invalidChallenge }
    return data
  }
}
