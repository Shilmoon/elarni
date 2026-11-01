import Darwin
import Foundation

// HTTP probes and config preflight use isolated processes for Xray's global state.
enum ProbeProcess {
  enum Failure: Error { case invalidRequest, failed }

  private final class Lifetime: @unchecked Sendable {
    let process = Process()
    private let lock = NSLock()
    private var cancelled = false

    func start() throws {
      lock.lock()
      defer { lock.unlock() }
      if cancelled { throw CancellationError() }
      try process.run()
    }

    func cancel() {
      lock.lock()
      defer { lock.unlock() }
      cancelled = true
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
  }

  static func run(_ payload: [String: Any], executable: URL) async throws -> Data {
    guard let timeout = payload["timeout"] as? Int, (5...15).contains(timeout) else {
      throw Failure.invalidRequest
    }
    return try await run(method: "ping", payload: payload, timeout: timeout, executable: executable)
  }

  static func validate(config: String, executable: URL) async throws {
    let data = try await run(method: "validateConfig", payload: ["configJSON": config],
      timeout: 15, executable: executable)
    guard let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          reply["success"] as? Bool == true,
          (reply["data"] as? [String: Any])?["valid"] as? Bool == true else {
      throw Failure.invalidRequest
    }
  }

  private static func run(method: String, payload: [String: Any], timeout: Int, executable: URL) async throws -> Data {
    var request = try JSONSerialization.data(withJSONObject: [
      "apiVersion": 1, "method": method, "payload": payload,
    ])
    guard request.count <= 16 * 1024 * 1024 else { throw Failure.invalidRequest }
    request.append(10)
    let input = request
    let lifetime = Lifetime()
    let response: Data
    do {
      response = try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          // Blocking pipe I/O must not occupy Swift's cooperative executor.
          DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(with: Result {
              let process = lifetime.process
              let stdin = Pipe(), stdout = Pipe()
              process.executableURL = executable
#if DEBUG && ELARNI_DIAGNOSTICS
              if let directory = DiagnosticLog.directory {
                var environment = ProcessInfo.processInfo.environment
                environment["ELARNI_DIAGNOSTICS_DIR"] = directory.path
                process.environment = environment
              }
#endif
              process.standardInput = stdin
              process.standardOutput = stdout
              process.standardError = FileHandle.nullDevice
              try lifetime.start()
              // An unresponsive core must not retain listeners beyond this probe.
              let deadline = DispatchWorkItem { lifetime.cancel() }
              DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeout), execute: deadline)
              defer {
                deadline.cancel()
                try? stdin.fileHandleForWriting.close()
                try? stdout.fileHandleForReading.close()
                lifetime.cancel()
                process.waitUntilExit()
              }
              try stdin.fileHandleForWriting.write(contentsOf: input)
              // Keep stdin open: EOF is the helper's parent-death signal.
              var response = Data()
              while let chunk = try stdout.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
                response.append(chunk)
                guard response.count <= 16 * 1024 * 1024 else { throw Failure.failed }
              }
              process.waitUntilExit()
              guard process.terminationStatus == 0 else { throw Failure.failed }
              return response
            })
          }
        }
      } onCancel: { lifetime.cancel() }
    } catch {
      try Task.checkCancellation()
      throw error
    }
    try Task.checkCancellation()
    return response
  }
}
