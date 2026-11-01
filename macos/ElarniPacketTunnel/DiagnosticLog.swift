import Foundation

// Only this recorder's directory is shared and exported, never the catalog.
enum DiagnosticLog {
  enum Failure: Error { case unavailable, empty }
#if DEBUG && ELARNI_DIAGNOSTICS
  // The diagnostic build records from launch, whatever the setting says.
  static let always = true
#else
  static let always = false
#endif
  private static let lock = NSLock()
  private static var collecting = false
  // Events are dropped here while idle, so a release build pays no bridge call for them.
  static var isCollecting: Bool { lock.lock(); defer { lock.unlock() }; return collecting }
  static var directory: URL? {
#if os(iOS)
    IOSPlatform.containerURL?.appendingPathComponent("Diagnostics", isDirectory: true)
#else
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.elarni.mac")?
      .appendingPathComponent("Diagnostics", isDirectory: true)
#endif
  }
  @discardableResult
  static func start(role: String) -> Bool {
    guard let directory else { return false }
    let started = (try? command(["action": "start", "directory": directory.path, "role": role]))?["collecting"] as? Bool == true
    lock.lock(); collecting = started; lock.unlock()
    if started, let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
       let build = Int64(version) {
      record("app_state", ["build": build])
    }
    return started
  }
  static func stop() {
    lock.lock(); collecting = false; lock.unlock()
    _ = try? command(["action": "stop"])
  }
  static func record(_ kind: String, _ values: [String: Int64] = [:]) {
    guard isCollecting else { return }
    _ = try? command(["action": "event", "kind": kind, "values": values])
  }
  /// `mark` and `flush` need a running recorder; `export` (with a destination) packages whatever the directory holds.
  static func perform(_ action: String, destination: URL? = nil) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      DispatchQueue.global(qos: .utility).async {
        do {
          var payload: [String: Any] = ["action": action]
          if let destination {
            guard let directory else { throw Failure.unavailable }
            payload["destination"] = destination.path
            payload["directory"] = directory.path
          }
          _ = try command(payload)
          continuation.resume()
        } catch { continuation.resume(throwing: error) }
      }
    }
  }
  private static func command(_ payload: [String: Any]) throws -> [String: Any] {
    let data = try JSONSerialization.data(withJSONObject: ["apiVersion": 1, "method": "diagnostics", "payload": payload])
    guard let json = String(data: data, encoding: .utf8), let input = strdup(json) else { throw Failure.unavailable }
    defer { free(input) }
    guard let output = CGoInvoke(input) else { throw Failure.unavailable }
    defer { CGoFree(output) }
    guard let result = try JSONSerialization.jsonObject(with: Data(String(cString: output).utf8)) as? [String: Any] else {
      throw Failure.unavailable
    }
    if result["error"] as? String == "recording_empty" { throw Failure.empty }
    guard result["success"] as? Bool == true, let value = result["data"] as? [String: Any] else { throw Failure.unavailable }
    return value
  }
}
