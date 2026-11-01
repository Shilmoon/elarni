import Foundation
import Network
import NetworkExtension
import XCTest
@testable import Elarni

// Each method starts from, and restores, the same disconnected two-node fixture.
// Run serially. Missing IPv6, responders or fixture data are failures, never skips.
@MainActor
final class MacOSAcceptanceTests: InstalledVPNTestCase {
  private func network(_ fixture: Fixture) throws -> AcceptanceNetwork {
    let value = try XCTUnwrap(fixture.network, "full suite requires the network fixture; see docs/MACOS_ACCEPTANCE.md")
    try value.validate(nodes: fixture.nodeIDs)
    return value
  }

  private func start(xray: Bool) async throws -> [String: Any] {
    _ = try await call("updateTunnelSettings", ["xrayTunEnabled": xray,
      "preferredIP": "automatic", "profilePreferredIP": "automatic"])
    _ = try await call("connect")
    let metrics = try await waitFor("runtimeMetrics", key: "state", value: "connected")
    try require(metrics["backend"] as? String == (xray ? "xrayTun" : "nativeTun2Proxy"), "wrong installed backend")
    try require(metrics["sharedKeychainResolved"] as? Bool == true, "installed provider did not resolve fixture credentials")
    return metrics
  }

  private func sameProvider(_ before: [String: Any], _ after: [String: Any], plan: Bool = true) throws {
    for key in ["instanceID", "generation"] + (plan ? ["configurationDigest"] : []) {
      let lhs = try XCTUnwrap(before[key] as? NSObject, "missing provider identity")
      let rhs = try XCTUnwrap(after[key] as? NSObject, "missing provider identity")
      try require(lhs.isEqual(rhs), "operation replaced provider identity/plan: \(key)")
    }
  }

  private func differentProvider(_ before: [String: Any], _ after: [String: Any]) throws {
    try require(before["instanceID"] as? String != after["instanceID"] as? String ||
      before["generation"] as? NSNumber != after["generation"] as? NSNumber, "restart retained a stale provider identity")
  }

  private func socket(_ network: AcceptanceNetwork, host: String, udp: Bool = false,
                      family: NWProtocolIP.Options.Version? = nil) async throws -> AcceptanceSocket {
    let socket = try AcceptanceSocket(host: host, port: udp ? network.udpPort : network.tcpPort,
      datagram: udp, family: family)
    do { try await socket.open(); return socket } catch { socket.close(); throw error }
  }

  private func flows(_ network: AcceptanceNetwork, egress: [String]) async throws {
    for host in [network.ipv4, network.ipv6] {
      for udp in [false, true] {
        let stream = try await socket(network, host: host, udp: udp)
        defer { stream.close() }
        _ = try await stream.exchange(egress: egress)
      }
    }
  }

  private func dns(_ network: AcceptanceNetwork, egress: [String]) async throws {
    for (suffix, version) in [(network.dnsIPv4Suffix, NWProtocolIP.Options.Version.v4),
                              (network.dnsIPv6Suffix, .v6)] {
      let host = UUID().uuidString.lowercased() + "." + suffix
      let stream = try await socket(network, host: host, family: version)
      defer { stream.close() }
      _ = try await stream.exchange(egress: egress)
    }
  }

  private func remainsStopped(seconds: Double = 3) async throws {
    let deadline = Date().addingTimeInterval(seconds)
    repeat {
      let profiles = try await NETunnelProviderManager.loadAllFromPreferences()
      try require(profiles.allSatisfy { $0.connection.status == .disconnected && !$0.isOnDemandEnabled &&
        ($0.onDemandRules ?? []).isEmpty }, "Stop left an active/rearming profile")
      try await Task.sleep(for: .milliseconds(150))
    } while Date() < deadline
  }

  func testBothBackendsDualStackTrafficDNSAndSwitch() async throws {
    try await withFixture { fixture, original, candidate in
      let net = try network(fixture)
      // Establish direct connectivity/egress before installing any test routes.
      try await flows(net, egress: net.directEgress)
      for xray in [false, true] {
        let first = try await start(xray: xray)
        try await flows(net, egress: net.nodeEgress[original]!)
        try await dns(net, egress: net.nodeEgress[original]!)
        try await traffic(fixture)
        _ = try await call("selectNode", ["id": candidate])
        let switched = try await waitFor("runtimeMetrics", key: "state", value: "connected")
        if xray { try differentProvider(first, switched) }
        else { try sameProvider(first, switched, plan: false) }
        try require(first["configurationDigest"] as? String != switched["configurationDigest"] as? String,
          "fixture needs distinct effective node configurations to prove a switch")
        let selection = try await call("subscriptions")
        try require(selection["selectedNodeId"] as? String == candidate, "switch did not commit selection")
        try await flows(net, egress: net.nodeEgress[candidate]!)
        try await dns(net, egress: net.nodeEgress[candidate]!)
        try await disconnect()
        _ = try await call("selectNode", ["id": original])
        _ = try await start(xray: xray)
        try await flows(net, egress: net.nodeEgress[original]!)
        try await dns(net, egress: net.nodeEgress[original]!)
        try await disconnect()
        try await remainsStopped()
        try await flows(net, egress: net.directEgress)
      }
    }
  }

  func testUnchangedRefreshRetainsTCPStreamOnBothBackends() async throws {
    try await withFixture { fixture, original, _ in
      let net = try network(fixture)
      for xray in [false, true] {
        let owner = try await start(xray: xray)
        let stream = try await socket(net, host: net.ipv4)
        defer { stream.close() }
        let first = try await stream.exchange(egress: net.nodeEgress[original]!)
        for _ in 0..<3 {
          let result = try await call("refreshSubscription", ["id": fixture.subscriptionID])
          try require(result["warning"] is NSNull, "refresh requires operator intervention")
          let after = try await call("runtimeMetrics")
          try sameProvider(owner, after)
          let catalog = try await call("subscriptions")
          try require(catalog["selectedNodeId"] as? String == original, "refresh changed selection")
          _ = try await stream.exchange(egress: net.nodeEgress[original]!, connectionID: first.connection)
          try await flows(net, egress: net.nodeEgress[original]!)
        }
        stream.close()
        try await disconnect()
      }
    }
  }

  func testControllerRecreationRetainsConnectionAndStopIntent() async throws {
    try await withFixture { fixture, original, _ in
      let net = try network(fixture)
      for xray in [false, true] {
        let owner = try await start(xray: xray)
        let stream = try await socket(net, host: net.ipv4)
        defer { stream.close() }
        let first = try await stream.exchange(egress: net.nodeEgress[original]!)
        channel = nil
        channel = TunnelMethodChannel(messenger: messenger, defaults: try XCTUnwrap(controllerDefaults))
        let state = try await call("state")
        try require(state["state"] as? String == "connected", "controller recreation stopped the installed VPN")
        try sameProvider(owner, try await call("runtimeMetrics"))
        _ = try await stream.exchange(egress: net.nodeEgress[original]!, connectionID: first.connection)
        try await disconnect()
        channel = nil
        channel = TunnelMethodChannel(messenger: messenger, defaults: try XCTUnwrap(controllerDefaults))
        let stopped = try await call("state")
        try require(stopped["connectionIntent"] as? String == "disconnected", "Stop intent did not survive controller recreation")
        try await remainsStopped()
      }
    }
  }

  func testStopDuringStartupAndRepeatedReconnect() async throws {
    try await withFixture { fixture, original, _ in
      let net = try network(fixture)
      for xray in [false, true] {
        _ = try await call("updateTunnelSettings", ["xrayTunEnabled": xray])
        for _ in 0..<3 {
          // Submit Start before Stop without waiting for Start's native reply.
          let submitted = expectation(description: "Start submitted before Stop")
          let starting = Task { @MainActor in
            try await self.call("connect", submitted: { submitted.fulfill() })
          }
          await fulfillment(of: [submitted], timeout: 5)
          let stopping = Task { @MainActor in try await self.call("disconnect") }
          let started = await starting.result
          _ = try await stopping.value
          if case .failure(let error) = started {
            try require((error as? Failure)?.message == "operation_cancelled", "unexpected startup-race failure")
          }
          _ = try await waitFor("state", key: "state", value: "disconnected")
          try await remainsStopped()
          _ = try await start(xray: xray)
          try await flows(net, egress: net.nodeEgress[original]!)
          try await disconnect()
          try await disconnect() // Idempotence after a completed stop.
        }
      }
    }
  }

  func testOnDemandStopAndRepairOnBothBackends() async throws {
    try await withFixture { fixture, original, _ in
      let net = try network(fixture)
      for xray in [false, true] {
        let owner = try await start(xray: xray)
        _ = try await call("updateTunnelSettings", ["onDemandEnabled": true])
        try sameProvider(owner, try await call("runtimeMetrics"))
        let profiles = try await NETunnelProviderManager.loadAllFromPreferences()
        try require(profiles.count == 1 && profiles[0].isOnDemandEnabled &&
          !(profiles[0].onDemandRules ?? []).isEmpty, "On Demand was not installed")
        try await disconnect()
        try await remainsStopped()
        _ = try await start(xray: xray)
        let repairedOwner = try await call("runtimeMetrics")
        _ = try await call("repairTunnel")
        let removed = try await NETunnelProviderManager.loadAllFromPreferences()
        try require(removed.isEmpty, "repair retained the saved VPN profile")
        try await remainsStopped()
        let recreated = try await start(xray: xray)
        try differentProvider(repairedOwner, recreated)
        try await flows(net, egress: net.nodeEgress[original]!)
        try await disconnect()
        _ = try await call("updateTunnelSettings", ["onDemandEnabled": false])
      }
    }
  }

  func testPerAppRoutingTCPAndUDPBothFamilies() async throws {
    try await withFixture { fixture, original, _ in
      let net = try network(fixture)
      let executable = try XCTUnwrap(Bundle.main.executableURL)
      let patterns = [executable.lastPathComponent, executable.path, Bundle.main.bundleURL.path + "/"]
      for pattern in patterns {
        for mode in ["bypass", "proxyOnly"] {
          for selected in [true, false] {
            _ = try await call("updateTunnelSettings", ["xrayTunEnabled": true, "includeAllNetworks": false,
              "perAppMode": mode, "perAppProcesses": [selected ? pattern : "/elarni-no-such-app-\(UUID().uuidString)/"]])
            _ = try await start(xray: true)
            let proxy = mode == "bypass" ? !selected : selected
            try await flows(net, egress: proxy ? net.nodeEgress[original]! : net.directEgress)
            try await disconnect()
          }
        }
      }
    }
  }

  func testIncludedExcludedRoutesBothBackends() async throws {
    try await withFixture { fixture, original, _ in
      let net = try network(fixture)
      for xray in [false, true] {
        let routes = [net.ipv4 + "/32", net.ipv6 + "/128"]
        _ = try await call("updateTunnelSettings", ["includeAllNetworks": false, "enforceRoutes": true,
          "includedRoutes": routes, "excludedRoutes": []])
        _ = try await start(xray: xray)
        try await flows(net, egress: net.nodeEgress[original]!)
        try await disconnect()
        _ = try await call("updateTunnelSettings", ["enforceRoutes": false,
          "includedRoutes": ["0.0.0.0/0", "::/0"], "excludedRoutes": routes])
        _ = try await start(xray: xray)
        try await flows(net, egress: net.directEgress)
        try await disconnect()
        _ = try await call("updateTunnelSettings", ["excludedRoutes": [], "includeAllNetworks": true])
      }
    }
  }

  func testXrayStartupAndProtectedCoreFailure() async throws {
    try await withFixture { fixture, original, candidate in
      let net = try network(fixture)
      try await flows(net, egress: net.directEgress)
      _ = try await call("updateTunnelSettings", ["xrayTunEnabled": true])
      let startup = UUID()
      _ = try await call("connect", ["debugFaultID": startup.uuidString])
      try await receipt(startup, outcome: "startupFailed", points: ["startup"])
      _ = try await waitFor("state", key: "state", value: "disconnected")
      let owner = try await start(xray: true)
      try await flows(net, egress: net.nodeEgress[original]!)
      let id = try await fault("coreExit", node: candidate, owner: owner, code: nil)
      try await receipt(id, outcome: "coreExited", points: ["coreExit"], owner: owner)
      _ = try await waitFor("runtimeMetrics", key: "state", value: "protectedFailure")
      let state = try await call("state")
      try require(["connected", "reasserting"].contains(state["state"] as? String ?? ""), "failure removed protection")
      for host in [net.ipv4, net.ipv6] {
        for udp in [false, true] {
          do {
            let stream = try await socket(net, host: host, udp: udp)
            defer { stream.close() }
            _ = try await stream.exchange(egress: net.directEgress + net.nodeEgress[original]!)
            throw Failure(message: "TCP/UDP traffic escaped the protected failure")
          } catch ProbeFailure.transport { /* Only a transport failure proves this negative check. */ }
        }
      }
      try await disconnect()
      _ = try await start(xray: true)
      try await flows(net, egress: net.nodeEgress[original]!)
    }
  }

  func testSelectedSourceDeletionDisarmsOnDemand() async throws {
    try await withFixture { fixture, original, _ in
      let net = try network(fixture)
      // Clone only the disposable node through public channel operations. Never
      // print or persist the share text, and never delete the provisioned source.
      let shared = try await call("shareClient", ["id": original])
      let content = try XCTUnwrap(shared["text"] as? String)
      let imported = try await call("importClientProfiles", ["source": "text", "content": content])
      let catalog = try XCTUnwrap(imported["subscriptions"] as? [String: Any])
      let groups = try XCTUnwrap(catalog["subscriptions"] as? [[String: Any]])
      let clone = try XCTUnwrap(groups.first { $0["id"] as? String != fixture.subscriptionID })
      let cloneID = try XCTUnwrap(clone["id"] as? String)
      temporarySources.append(cloneID)
      let nodes = try XCTUnwrap(clone["nodes"] as? [[String: Any]])
      let cloneNode = try XCTUnwrap(nodes.first?["id"] as? String)
      _ = try await call("selectNode", ["id": cloneNode])
      _ = try await start(xray: true)
      _ = try await call("updateTunnelSettings", ["onDemandEnabled": true])
      try await flows(net, egress: net.nodeEgress[original]!)
      _ = try await call("deleteSubscription", ["id": cloneID])
      let profiles = try await NETunnelProviderManager.loadAllFromPreferences()
      try require(profiles.isEmpty, "selected source deletion retained its saved plan")
      let deleted = try await call("subscriptions")
      try require(deleted["selectedNodeId"] is NSNull, "deletion retained selected node")
      try await remainsStopped()
      channel = nil
      channel = TunnelMethodChannel(messenger: messenger, defaults: try XCTUnwrap(controllerDefaults))
      try await remainsStopped()
      _ = try await call("selectNode", ["id": original])
      _ = try await start(xray: true)
      try await flows(net, egress: net.nodeEgress[original]!)
    }
  }

  func testOccupiedListenerAndInvalidSettingsRecover() async throws {
    try await withFixture { fixture, original, _ in
      let net = try network(fixture)
      for xray in [false, true] {
        _ = try await start(xray: xray)
        let before = try await call("tunnelSettings")
        let listener = try NWListener(using: .tcp, on: .any)
        defer { listener.cancel() }
        let ready = expectation(description: "reserved test listener")
        listener.newConnectionHandler = { $0.cancel() }
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: DispatchQueue(label: "elarni.acceptance.occupied-port"))
        await fulfillment(of: [ready], timeout: 5)
        let port = try XCTUnwrap(listener.port).rawValue
        do {
          _ = try await call("updateTunnelSettings", ["socksPort": Int(port)])
          throw Failure(message: "occupied listener was accepted")
        } catch let error as Failure {
          try require(error.message == "listener_unavailable", "wrong occupied-port error")
        }
        let restored = try await call("tunnelSettings")
        try require(restored["socksPort"] as? Int == before["socksPort"] as? Int,
          "failed listener update persisted the unusable port")
        _ = try await waitFor("runtimeMetrics", key: "state", value: "connected")
        try await flows(net, egress: net.nodeEgress[original]!)
        let owner = try await call("runtimeMetrics")
        do {
          _ = try await call("updateTunnelSettings", ["socksPort": 0])
          throw Failure(message: "invalid settings accepted")
        } catch let error as Failure {
          try require(error.message == "invalid_settings", "wrong invalid-settings error")
        }
        try sameProvider(owner, try await call("runtimeMetrics"))
        try await disconnect()
      }
    }
  }
}
