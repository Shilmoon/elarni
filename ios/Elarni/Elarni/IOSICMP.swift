import Darwin
import Foundation

/// Public Darwin datagram ICMP, following Apple's SimplePing packet conventions.
/// A connected socket limits peers; identifier, sequence and nonce match replies.
enum IOSICMP {
  static func measure(host: String, timeout: Int, preference: String) async throws -> Int {
    let job = ICMPJob()
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        job.install(continuation)
        DispatchQueue.global(qos: .userInitiated).async {
          job.finish(Result { try run(host: host, timeout: timeout, preference: preference, job: job) })
        }
      }
    } onCancel: { job.cancel() }
  }

  private static func run(host: String, timeout: Int, preference: String, job: ICMPJob) throws -> Int {
    let deadline = ProcessInfo.processInfo.systemUptime + Double(timeout)
    var hints = addrinfo()
    hints.ai_family = preference == "ipv4" ? AF_INET : preference == "ipv6" ? AF_INET6 : AF_UNSPEC
    hints.ai_socktype = SOCK_DGRAM
    var addresses: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, nil, &hints, &addresses) == 0, let first = addresses else { throw IOSAppError.providerUnavailable }
    defer { freeaddrinfo(first) }
    var candidates: [UnsafeMutablePointer<addrinfo>] = []
    var current: UnsafeMutablePointer<addrinfo>? = first
    while let item = current { if [AF_INET, AF_INET6].contains(item.pointee.ai_family) { candidates.append(item) }; current = item.pointee.ai_next }
    for (index, item) in candidates.enumerated() {
      if job.cancelled { throw CancellationError() }
      let remaining = deadline - ProcessInfo.processInfo.systemUptime
      guard remaining > 0 else { break }
      let end = ProcessInfo.processInfo.systemUptime + remaining / Double(candidates.count - index)
      if let result = try ping(item.pointee, deadline: end, job: job) { return result }
    }
    throw IOSAppError.operationTimedOut
  }

  private static func ping(_ address: addrinfo, deadline: Double, job: ICMPJob) throws -> Int? {
    let fd = socket(address.ai_family, SOCK_DGRAM, address.ai_family == AF_INET ? IPPROTO_ICMP : IPPROTO_ICMPV6)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    guard connect(fd, address.ai_addr, address.ai_addrlen) == 0 else { return nil }
    let identifier = UInt16.random(in: 1...UInt16.max)
    let sequence = UInt16.random(in: 0...UInt16.max)
    let payload = (0..<16).map { _ in UInt8.random(in: 0...255) }
    var packet: [UInt8] = [address.ai_family == AF_INET ? 8 : 128, 0, 0, 0,
      UInt8(identifier >> 8), UInt8(identifier & 255), UInt8(sequence >> 8), UInt8(sequence & 255)] + payload
    if address.ai_family == AF_INET { let sum = checksum(packet); packet[2] = UInt8(sum >> 8); packet[3] = UInt8(sum & 255) }
    if job.cancelled { throw CancellationError() }
    let started = ProcessInfo.processInfo.systemUptime
    guard send(fd, packet, packet.count, 0) == packet.count else { return nil }
    var buffer = [UInt8](repeating: 0, count: 4096)
    while ProcessInfo.processInfo.systemUptime < deadline {
      if job.cancelled { throw CancellationError() }
      var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
      let result = poll(&descriptor, 1, 50)
      if result < 0 { if errno == EINTR { continue }; return nil }
      if result == 0 { continue }
      let count = recv(fd, &buffer, buffer.count, 0)
      if count <= 0 { return nil }
      if matches(Array(buffer.prefix(count)), family: address.ai_family, identifier: identifier, sequence: sequence, payload: payload) {
        return Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
      }
    }
    return nil
  }

  static func checksum(_ bytes: [UInt8]) -> UInt16 {
    var sum: UInt32 = 0
    for i in stride(from: 0, to: bytes.count, by: 2) {
      sum += UInt32(bytes[i]) << 8
      if i + 1 < bytes.count { sum += UInt32(bytes[i + 1]) }
    }
    while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
    return ~UInt16(sum)
  }

  static func matches(_ bytes: [UInt8], family: Int32, identifier: UInt16, sequence: UInt16, payload: [UInt8]) -> Bool {
    let offset: Int
    if family == AF_INET {
      guard bytes.count >= 20, bytes[0] >> 4 == 4, bytes[9] == UInt8(IPPROTO_ICMP) else { return false }
      offset = Int(bytes[0] & 15) * 4
      guard offset >= 20, offset <= bytes.count else { return false }
      guard checksum(Array(bytes.dropFirst(offset))) == 0 else { return false }
    } else if family == AF_INET6 { offset = 0 }
    else { return false }
    guard bytes.count == offset + 8 + payload.count else { return false }
    return bytes[offset] == (family == AF_INET ? 0 : 129) && bytes[offset + 1] == 0 &&
      UInt16(bytes[offset + 4]) << 8 | UInt16(bytes[offset + 5]) == identifier &&
      UInt16(bytes[offset + 6]) << 8 | UInt16(bytes[offset + 7]) == sequence &&
      Array(bytes.dropFirst(offset + 8)) == payload
  }
}

private final class ICMPJob: @unchecked Sendable {
  private let lock = NSLock()
  private var pending: CheckedContinuation<Int, Error>?
  private var result: Result<Int, Error>?
  private var isCancelled = false
  var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return isCancelled }
  func install(_ continuation: CheckedContinuation<Int, Error>) {
    lock.lock()
    if let result { lock.unlock(); continuation.resume(with: result); return }
    pending = continuation; lock.unlock()
  }
  func finish(_ value: Result<Int, Error>) {
    lock.lock(); guard result == nil else { lock.unlock(); return }
    result = value; let continuation = pending; pending = nil; lock.unlock()
    continuation?.resume(with: value)
  }
  func cancel() { lock.lock(); isCancelled = true; lock.unlock(); finish(.failure(CancellationError())) }
}
