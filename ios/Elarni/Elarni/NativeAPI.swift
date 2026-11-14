import Foundation

enum NativeAPI {
  private static let queue = DispatchQueue(label: "elarni.ios.native", qos: .userInitiated)
  private static let probes = DispatchQueue(label: "elarni.ios.probes", qos: .userInitiated, attributes: .concurrent)
  static let xrayVersion = (try? invoke("xrayVersion"))?["version"] as? String ?? String(localized: "Unavailable")

  static func invoke(_ method: String, _ payload: [String: Any] = [:]) throws -> [String: Any] {
    let input = try JSONSerialization.data(withJSONObject: ["apiVersion": 1, "method": method, "payload": payload])
    return try decode(invokeData(input))
  }

  static func perform(_ method: String, _ payload: [String: Any] = [:]) async throws -> [String: Any] {
    let input = try JSONSerialization.data(withJSONObject: ["apiVersion": 1, "method": method, "payload": payload])
    let data: Data = try await withCheckedThrowingContinuation { continuation in
      (method == "ping" ? probes : queue).async { continuation.resume(with: Result { try invokeData(input) }) }
    }
    // Inspect cleanup diagnostics even if cancellation arrived during native
    // execution; otherwise an unjoined core could be mistaken for clean Stop.
    let result = try decode(data)
    try Task.checkCancellation()
    return result
  }

  private static func invokeData(_ data: Data) throws -> Data {
    guard let input = strdup(String(decoding: data, as: UTF8.self)) else { throw IOSAppError.nativeFailure }
    defer { free(input) }
    guard let output = CGoInvoke(input) else { throw IOSAppError.nativeFailure }
    defer { CGoFree(output) }
    return Data(String(cString: output).utf8)
  }

  private static func decode(_ data: Data) throws -> [String: Any] {
    guard let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw IOSAppError.nativeFailure }
    guard reply["success"] as? Bool == true else {
      if let diagnostics = (reply["data"] as? [String: Any])?["diagnostics"] as? [String: Any] {
        throw IOSProbeFailure(code: diagnostics["code"] as? String ?? "unknown", stage: diagnostics["stage"] as? String,
          cleanupPending: ["pending", "failed"].contains(diagnostics["cleanupState"] as? String ?? ""),
          receivedHTTP: (diagnostics["httpStatus"] as? Int ?? 0) != 0)
      }
      throw IOSAppError.nativeFailure
    }
    return reply["data"] as? [String: Any] ?? [:]
  }
}

struct IOSProbeFailure: LocalizedError {
  let code: String
  let stage: String?
  let cleanupPending: Bool
  let receivedHTTP: Bool
  var errorDescription: String? {
    if cleanupPending { return String(localized: "The server test could not release its resources. Close and reopen the app before another test.") }
    return code == "timeout" ? String(localized: "The server test timed out.") : String(localized: "The test target did not return the expected response. Check the target and server settings.")
  }
}

enum IOSAppError: LocalizedError, Equatable {
  case nativeFailure, noSelection, invalidSettings, unsupportedProcessRouting, unavailableSimulator
  case providerUnavailable, switchFailed, switchRestoreFailed, operationTimedOut, invalidFile, busy
  case invalidRecovery, notificationPermission, cleanupFailed, serverUnresolvable, recordingEmpty, recordingFailed
  /// A failed download whose text names the provider.
  case refreshFailed(String)
  var errorDescription: String? {
    switch self {
    case .nativeFailure: String(localized: "The configuration could not be processed. Check its format and values, then try again.")
    case .noSelection: String(localized: "Choose a server before connecting.")
    case .invalidSettings: String(localized: "Check the ports, routes, fragmentation ranges, and connection limits.")
    case .unsupportedProcessRouting: String(localized: "This profile contains desktop process rules. Remove those rules or use domain and IP routing on iPhone.")
    case .unavailableSimulator: String(localized: "VPN connections require a signed app on your iPhone. Import, routing, and settings are available in Simulator.")
    case .providerUnavailable: String(localized: "The VPN extension did not report its state. Refresh status or disconnect and try again.")
    case .switchFailed: String(localized: "The new server could not connect. The previous connection was retained.")
    case .switchRestoreFailed: String(localized: "The connection could not be restored. Disconnect before trying again.")
    case .operationTimedOut: String(localized: "The operation timed out. Refresh status before retrying.")
    case .invalidFile: String(localized: "Choose a UTF-8 configuration, supported QR image, or encrypted Elarni backup.")
    case .busy: String(localized: "Wait for the current operation to finish, or stop the connection.")
    case .invalidRecovery: String(localized: "Choose the selected server and allowed servers from the same subscription. Automatic selection needs at least two servers and health targets with different hostnames.")
    case .notificationPermission: String(localized: "Allow notifications for Elarni in iPhone Settings to receive expiry reminders.")
    case .cleanupFailed: String(localized: "The VPN could not confirm cleanup. Tap Disconnect and check the VPN status in iPhone Settings before reconnecting.")
    case .serverUnresolvable: String(localized: "Couldn’t confirm the switch. The server’s address could not be found. Check the address with your provider, or this network’s DNS.")
    case .recordingEmpty: String(localized: "Nothing is recorded yet. Turn on Record connection diagnostics, reproduce the problem, then export.")
    case .recordingFailed: String(localized: "The recording could not be updated. Check free storage and try again.")
    case .refreshFailed(let message): message
    }
  }
}

func prettyJSON(_ value: Any) throws -> String {
  String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
}
