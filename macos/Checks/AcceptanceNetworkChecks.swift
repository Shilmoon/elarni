import Foundation
import Network

// Loopback-only checks of the network test oracle, runnable without a VPN.
@main
struct AcceptanceNetworkChecks {
  static func main() async throws {
    let args = CommandLine.arguments
    guard args.count == 4, let tcp = UInt16(args[2]), let udp = UInt16(args[3]),
          ["127.0.0.1", "::1"].contains(args[1]) else { throw ProbeFailure.fixture }
    let host = args[1]
    for datagram in [false, true] {
      let stream = try AcceptanceSocket(host: host, port: datagram ? udp : tcp, datagram: datagram)
      defer { stream.close() }
      try await stream.open()
      let first = try await stream.exchange(egress: [host])
      _ = try await stream.exchange(egress: [host], connectionID: datagram ? nil : first.connection)
      do {
        _ = try await stream.exchange(egress: ["192.0.2.99"])
        throw ProbeFailure.response
      } catch ProbeFailure.wrongEgress { }
      if !datagram {
        do {
          _ = try await stream.exchange(egress: [host], connectionID: UUID().uuidString)
          throw ProbeFailure.response
        } catch ProbeFailure.streamReplaced { }
      }
      stream.close()
      do {
        _ = try await stream.exchange(egress: [host])
        throw ProbeFailure.response
      } catch ProbeFailure.transport { }
    }
    print("Swift network oracle: TCP/UDP round trips, retained stream, wrong egress, replaced stream, closed socket passed")
  }
}
