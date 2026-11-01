import Darwin
import Foundation
import Network

@main
struct ProbeChecks {
  struct Failure: Error { var message = "invalid fixture state" }

  // Access is confined to the fixture's serial queue, including teardown.
  final class Connections: @unchecked Sendable {
    var all: [NWConnection] = []
    var waiting: [NWConnection] = []
    var onStall: (() -> Void)?
  }

  static func freePort() throws -> Int {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw Failure() }
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    var length = socklen_t(address.sin_len)
    let port = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer -> Int in
        guard bind(fd, pointer, length) == 0, getsockname(fd, pointer, &length) == 0 else { return 0 }
        return 1
      }
    }
    guard port != 0 else { throw Failure() }
    return Int(UInt16(bigEndian: address.sin_port))
  }

  static func main() async throws {
    setbuf(stdout, nil)
    let executable = URL(fileURLWithPath: CommandLine.arguments[1])
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    let server = try NWListener(using: parameters)
    let queue = DispatchQueue(label: "probe-fixture")
    let connections = Connections()
    server.newConnectionHandler = { connection in
      connections.all.append(connection)
      connection.start(queue: queue)
      connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
        guard let data else { return }
        if String(decoding: data, as: UTF8.self).contains("/stall") {
          connections.onStall?()
          return
        }
        // Cloudflare's trace format, answered at once, for Check exit.
        if String(decoding: data, as: UTF8.self).contains("/cdn-cgi/trace") {
          let body = "fl=29f\nip=203.0.113.7\nloc=DE\n"
          connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8),
            completion: .contentProcessed { _ in connection.cancel() })
          return
        }
        connections.waiting.append(connection)
        // No probe can finish until all 26 actually reach the responder.
        if connections.waiting.count == 26 {
          for peer in connections.waiting {
            peer.send(content: Data("HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n".utf8),
              completion: .contentProcessed { _ in peer.cancel() })
          }
        }
      }
    }
    let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
      server.stateUpdateHandler = { state in
        switch state {
        case .ready: continuation.resume(returning: server.port!.rawValue)
        case .failed(let error): continuation.resume(throwing: error)
        default: break
        }
      }
      server.start(queue: queue)
    }
    defer { queue.sync { connections.all.forEach { $0.cancel() }; server.cancel() } }
    func payload(_ path: String, _ socks: Int) throws -> [String: Any] {
      let config: [String: Any] = [
        "log": ["loglevel": "none"],
        "dns": ["hosts": ["probe.test": "127.0.0.1"]],
        "inbounds": [["listen": "127.0.0.1", "port": socks, "protocol": "socks", "settings": ["auth": "noauth"]]],
        "outbounds": [["protocol": "freedom", "settings": ["domainStrategy": "UseIPv4"]]],
      ]
      return ["configJSON": String(decoding: try JSONSerialization.data(withJSONObject: config), as: UTF8.self),
        "proxy": "socks5://127.0.0.1:\(socks)", "url": "http://probe.test:\(port)/\(path)",
        "timeout": 5, "method": "GET", "mode": "default", "expectedStatus": 204, "expectedBody": ""]
    }
    // Validation must tolerate a listener owned by the running connection and
    // confine Xray's environment changes to its disposable child process.
    let validationPayload = try payload("ok", Int(port))
    var validationConfig = try JSONSerialization.jsonObject(with: Data((validationPayload["configJSON"] as! String).utf8)) as! [String: Any]
    validationConfig["env"] = ["ELARNI_PREFLIGHT_FIXTURE": "child"]
    setenv("ELARNI_PREFLIGHT_FIXTURE", "parent", 1)
    defer { unsetenv("ELARNI_PREFLIGHT_FIXTURE") }
    try await ProbeProcess.validate(config: String(decoding: JSONSerialization.data(withJSONObject: validationConfig), as: UTF8.self), executable: executable)
    guard String(cString: getenv("ELARNI_PREFLIGHT_FIXTURE")) == "parent" else {
      throw Failure(message: "validation changed the parent environment")
    }
    do { try await ProbeProcess.validate(config: "{", executable: executable); throw Failure(message: "invalid candidate passed validation") }
    catch ProbeProcess.Failure.invalidRequest { }
    print("PASS candidate preflight rejects invalid configuration without binding the occupied port or changing parent environment")
    let started = ProcessInfo.processInfo.systemUptime
    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<26 {
        let request = try payload("ok", freePort())
        group.addTask {
          let data = try await ProbeProcess.run(request, executable: executable)
          let response = try JSONSerialization.jsonObject(with: data) as? [String: Any]
          guard response?["success"] as? Bool == true else {
            throw Failure(message: "synthetic probe reply: \(String(decoding: data, as: UTF8.self))")
          }
        }
      }
      try await group.waitForAll()
    }
    guard ProcessInfo.processInfo.systemUptime - started < 5 else { throw Failure(message: "parallel probes exceeded deadline") }
    print("PASS 26 simultaneous full-profile probes with isolated DNS in \(String(format: "%.3f", ProcessInfo.processInfo.systemUptime - started))s")
    let (arrivals, arrival) = AsyncStream<Void>.makeStream()
    queue.sync { connections.onStall = { arrival.yield(()) } }
    let request = try payload("stall-cancel", freePort())
    let cancelled = Task { try await ProbeProcess.run(request, executable: executable) }
    for await _ in arrivals { break }
    arrival.finish()
    queue.sync { connections.onStall = nil }
    let interrupted = ProcessInfo.processInfo.systemUptime
    cancelled.cancel()
    do { _ = try await cancelled.value; throw Failure(message: "cancelled helper succeeded") }
    catch is CancellationError {}
    guard ProcessInfo.processInfo.systemUptime - interrupted < 2 else {
      throw Failure(message: "cancellation waited for the probe deadline")
    }
    print("PASS cancelled helper exits and joins cleanup immediately")
    let stalled = ProcessInfo.processInfo.systemUptime
    do {
      let data = try await ProbeProcess.run(payload("stall", freePort()), executable: executable)
      let response = try JSONSerialization.jsonObject(with: data) as? [String: Any]
      guard response?["success"] as? Bool == false else { throw Failure(message: "stalled probe succeeded") }
    } catch is ProbeProcess.Failure {}
    let duration = ProcessInfo.processInfo.systemUptime - stalled
    guard duration >= 4.9, duration < 6 else { throw Failure(message: "timeout duration: \(duration)") }
    print("PASS stalled helper terminates at its deadline (\(String(format: "%.2f", duration))s)")
    var trace = try payload("cdn-cgi/trace", freePort())
    trace["expectedStatus"] = 200
    trace["trace"] = true
    let traced = try JSONSerialization.jsonObject(with: try await ProbeProcess.run(trace, executable: executable)) as? [String: Any]
    let exit = (traced?["data"] as? [String: Any])?["exit"] as? [String: Any]
    guard exit?["ip"] as? String == "203.0.113.7", exit?["country"] as? String == "DE" else {
      throw Failure(message: "trace probe reply: \(String(describing: traced))")
    }
    print("PASS a trace probe through the helper names the exit address and country")
  }
}
