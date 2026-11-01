import Foundation
import Network

// Test infrastructure only. The responder reports the address it actually saw;
// route/per-app tests therefore cannot pass merely because a request succeeded.
struct AcceptanceNetwork: Decodable {
  let ipv4: String
  let ipv6: String
  let tcpPort: UInt16
  let udpPort: UInt16
  let directEgress: [String]
  let nodeEgress: [String: [String]]
  // Wildcard A-only and AAAA-only records pointing at the responder. Every query
  // uses a new label; a cached result for the previous test cannot establish DNS.
  let dnsIPv4Suffix: String
  let dnsIPv6Suffix: String

  func validate(nodes: [String]) throws {
    guard IPv4Address(ipv4) != nil, IPv6Address(ipv6) != nil,
          tcpPort > 0, udpPort > 0, !directEgress.isEmpty,
          Set(nodeEgress.keys) == Set(nodes),
          nodes.allSatisfy({ !(nodeEgress[$0] ?? []).isEmpty }),
          directEgress.allSatisfy(Self.isAddress),
          nodeEgress.values.joined().allSatisfy(Self.isAddress),
          Set(directEgress.map(Self.normalized)).isDisjoint(with:
            nodeEgress.values.joined().map(Self.normalized)),
          [dnsIPv4Suffix, dnsIPv6Suffix].allSatisfy({ suffix in
            suffix.utf8.count <= 190 && suffix.split(separator: ".").count >= 2 &&
            suffix.split(separator: ".").allSatisfy { label in
              !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-" &&
              label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
            }
          }) else { throw ProbeFailure.fixture }
  }

  static func isAddress(_ value: String) -> Bool {
    IPv4Address(value) != nil || IPv6Address(value) != nil
  }
  static func normalized(_ value: String) -> String {
    if let address = IPv4Address(value) { return address.debugDescription }
    if let address = IPv6Address(value) { return address.debugDescription }
    return value
  }
}

enum ProbeFailure: Error { case fixture, transport, response, wrongEgress, streamReplaced }

struct ProbeObservation: Decodable {
  let nonce: String
  let peer: String
  let connection: String

  func check(nonce expectedNonce: String, egress: [String], connection expectedConnection: String? = nil) throws {
    guard nonce == expectedNonce, UUID(uuidString: connection) != nil else { throw ProbeFailure.response }
    guard egress.map(AcceptanceNetwork.normalized).contains(AcceptanceNetwork.normalized(peer)) else {
      throw ProbeFailure.wrongEgress
    }
    if let expectedConnection, connection != expectedConnection { throw ProbeFailure.streamReplaced }
  }
}

// NWConnection never reconnects this socket. A retained stream must return the
// responder's original connection UUID after each refresh/controller recreation.
final class AcceptanceSocket: @unchecked Sendable {
  private let connection: NWConnection
  private let queue = DispatchQueue(label: "elarni.acceptance.socket")
  private let datagram: Bool

  init(host: String, port: UInt16, datagram: Bool = false, family: NWProtocolIP.Options.Version? = nil) throws {
    guard let port = NWEndpoint.Port(rawValue: port) else { throw ProbeFailure.fixture }
    self.datagram = datagram
    let parameters: NWParameters = datagram ? .udp : .tcp
    if let family, let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
      ip.version = family
    }
    connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
  }
  deinit { connection.cancel() }
  func close() { connection.cancel() }

  private func operation<T>(_ start: (@escaping @Sendable (Result<T, Error>) -> Void) -> Void) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      let completion = ProbeCompletion(continuation)
      let timeout = DispatchWorkItem { [connection] in
        completion.finish(.failure(ProbeFailure.transport))
        connection.cancel()
      }
      queue.asyncAfter(deadline: .now() + 8, execute: timeout)
      start { result in timeout.cancel(); completion.finish(result) }
    }
  }

  func open() async throws {
    let _: Void = try await operation { finish in
      connection.stateUpdateHandler = { state in
        switch state {
        case .ready: finish(.success(()))
        case .failed, .cancelled: finish(.failure(ProbeFailure.transport))
        default: break
        }
      }
      connection.start(queue: queue)
    }
  }

  func exchange(egress: [String], connectionID: String? = nil) async throws -> ProbeObservation {
    let nonce = UUID().uuidString
    let data = Data((nonce + "\n").utf8)
    let _: Void = try await operation { finish in
      connection.send(content: data, completion: .contentProcessed { error in
        finish(error == nil ? .success(()) : .failure(ProbeFailure.transport))
      })
    }
    var received = Data()
    // Bound framing as well as each I/O. Partial TCP reads are normal.
    for _ in 0..<16 {
      let part: Data = try await operation { finish in
        let receive: @Sendable (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void = { data, _, _, error in
          guard error == nil, let data, !data.isEmpty else {
            finish(.failure(ProbeFailure.transport)); return
          }
          finish(.success(data))
        }
        if datagram { connection.receiveMessage(completion: receive) }
        else { connection.receive(minimumIncompleteLength: 1, maximumLength: 4096, completion: receive) }
      }
      received.append(part)
      guard received.count <= 4096 else { throw ProbeFailure.response }
      if datagram || received.last == 10 {
        guard let value = try? JSONDecoder().decode(ProbeObservation.self, from: received) else {
          throw ProbeFailure.response
        }
        try value.check(nonce: nonce, egress: egress, connection: connectionID)
        return value
      }
    }
    throw ProbeFailure.response
  }
}

private final class ProbeCompletion<T>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<T, Error>?
  init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }
  func finish(_ value: Result<T, Error>) {
    lock.lock()
    let pending = continuation
    continuation = nil
    lock.unlock()
    pending?.resume(with: value)
  }
}

final class AcceptanceNoRedirect: NSObject, URLSessionTaskDelegate {
  func urlSession(_ session: URLSession, task: URLSessionTask,
                  willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                  completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
