import Foundation
import LocalAuthentication
import Security

struct SecretValue {
  private(set) var bytes: Data

  mutating func clear() {
    bytes.resetBytes(in: 0..<bytes.count)
    bytes.removeAll(keepingCapacity: false)
  }
}

protocol KeychainSecretStore: Sendable {
  func resolve(
    secretRef: String,
    attempt: ProviderBoundaryAttempt
  ) throws -> SecretValue
}

struct SystemKeychainSecretStore: KeychainSecretStore {
#if os(iOS)
  private let service = "com.elarni.ios.endpoint"
#else
  private let service = "com.elarni.mac.endpoint"
#endif

  func resolve(
    secretRef: String,
    attempt: ProviderBoundaryAttempt
  ) throws -> SecretValue {
    ProviderBoundaryEvidence.begin(.keychainLookup, attempt: attempt)
    let accessGroup: String
    do {
      accessGroup = try effectiveAccessGroup()
    } catch {
      ProviderBoundaryEvidence.failure(
        .keychainLookup,
        code: .keychainAccessGroupMissing,
        statusClass: .missingEntitlement,
        status: Int32(errSecMissingEntitlement),
        attempt: attempt
      )
      throw error
    }
    let authenticationContext = LAContext()
    authenticationContext.interactionNotAllowed = true
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: secretRef,
      kSecAttrAccessGroup: accessGroup,
      kSecUseDataProtectionKeychain: true,
      kSecUseAuthenticationContext: authenticationContext,
      kSecReturnData: true,
      kSecMatchLimit: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess, let data = result as? Data else {
      ProviderBoundaryEvidence.failure(
        .keychainLookup,
        code: .keychainLookupFailed,
        statusClass: ProviderBoundaryEvidence.keychainStatusClass(for: Int32(status)),
        status: Int32(status),
        attempt: attempt
      )
      throw KeychainError.lookupFailed(status)
    }
    guard !data.isEmpty, data.count <= 4 * 1024 * 1024 else {
      ProviderBoundaryEvidence.failure(
        .keychainLookup,
        code: .keychainInvalidSecret,
        attempt: attempt
      )
      throw KeychainError.invalidSecret
    }
    ProviderBoundaryEvidence.success(.keychainLookup, attempt: attempt)
    return SecretValue(bytes: data)
  }

  private func effectiveAccessGroup() throws -> String {
#if os(iOS)
    return try IOSPlatform.keychainAccessGroup()
#else
    let suffix = ".com.elarni.mac.shared"
    guard let task = SecTaskCreateFromSelf(nil),
          let groups = SecTaskCopyValueForEntitlement(
            task,
            "keychain-access-groups" as CFString,
            nil
          ) as? [String],
          let accessGroup = groups.first(where: {
            $0.count > suffix.count && $0.hasSuffix(suffix)
          }) else {
      throw KeychainError.missingAccessGroup
    }
    return accessGroup
#endif
  }
}

enum KeychainError: Error {
  case lookupFailed(OSStatus)
  case invalidSecret
  case missingAccessGroup
}
