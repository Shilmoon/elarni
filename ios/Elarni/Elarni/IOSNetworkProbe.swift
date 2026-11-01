import Darwin
import Foundation
import Network

enum IOSNetworkProbe {
  static func freePort() throws -> Int {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw IOSAppError.nativeFailure }
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard bound == 0 else { throw IOSAppError.nativeFailure }
    var size = socklen_t(MemoryLayout<sockaddr_in>.size)
    let result = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
    }
    guard result == 0 else { throw IOSAppError.nativeFailure }
    return Int(UInt16(bigEndian: address.sin_port))
  }

  static func tcp(host: String, port: UInt16, timeout: Int, preference: String) async throws -> Int {
    let parameters = NWParameters.tcp
    if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
      if preference == "ipv4" { ip.version = .v4 }
      if preference == "ipv6" { ip.version = .v6 }
    }
    guard let endpointPort = NWEndpoint.Port(rawValue: port) else { throw IOSAppError.invalidSettings }
    let connection = NWConnection(host: .init(host), port: endpointPort, using: parameters)
    let result = NetworkProbeReply()
    let queue = DispatchQueue(label: "elarni.ios.tcp-probe")
    let start = ProcessInfo.processInfo.systemUptime
    defer { connection.cancel() }
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        result.install(continuation)
        connection.stateUpdateHandler = { state in
          switch state {
          case .ready: result.finish(.success(Int((ProcessInfo.processInfo.systemUptime - start) * 1000)))
          case .failed: result.finish(.failure(IOSAppError.providerUnavailable))
          case .cancelled: result.finish(.failure(CancellationError()))
          default: break
          }
        }
        queue.asyncAfter(deadline: .now() + .seconds(timeout)) { result.finish(.failure(IOSAppError.operationTimedOut)); connection.cancel() }
        connection.start(queue: queue)
      }
    } onCancel: { result.finish(.failure(CancellationError())); connection.cancel() }
  }
}

private final class NetworkProbeReply: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Int, Error>?
  private var result: Result<Int, Error>?
  func install(_ pending: CheckedContinuation<Int, Error>) {
    lock.lock()
    if let result { lock.unlock(); pending.resume(with: result); return }
    continuation = pending; lock.unlock()
  }
  func finish(_ value: Result<Int, Error>) {
    lock.lock(); guard result == nil else { lock.unlock(); return }
    result = value; let pending = continuation; continuation = nil; lock.unlock()
    pending?.resume(with: value)
  }
}
