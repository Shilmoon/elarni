import FlutterMacOS
import Foundation
import NetworkExtension
import XCTest
@testable import Elarni

// Deliberately separate from the default suite: this exercises the installed VPN.
// The entire macOS account and its two-node subscription must be test fixtures.
@MainActor
class InstalledVPNTestCase: XCTestCase {
  struct Fixture: Decodable {
    let disposableAccount: String
    let subscriptionID: String
    let nodeIDs: [String]
    let probeURL: URL
    let expectedBody: String
    let network: AcceptanceNetwork?
  }
  struct Failure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
  }
  let messenger = NativeTestMessenger()
  var channel: TunnelMethodChannel?
  var controllerDefaults: UserDefaults?
  var temporarySources: [String] = []

  func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw Failure(message: message) }
  }

  func call(_ method: String, _ arguments: [String: Any] = [:], submitted: (() -> Void)? = nil) async throws -> [String: Any] {
    let reply = expectation(description: method)
    reply.assertForOverFulfill = true
    var response: Data?
    let codec = FlutterStandardMethodCodec.sharedInstance()
    try require(messenger.handler != nil, "native handler was not registered")
    messenger.handler?(codec.encode(FlutterMethodCall(methodName: method, arguments: arguments))) {
      response = $0
      reply.fulfill()
    }
    submitted?()
    await fulfillment(of: [reply], timeout: method == "refreshSubscription" ? 90 : 25)
    guard let response else { throw Failure(message: "native reply missing: \(method)") }
    let decoded = codec.decodeEnvelope(response)
    if let error = decoded as? FlutterError { throw Failure(message: error.code) }
    guard let value = decoded as? [String: Any] else { throw Failure(message: "invalid native reply") }
    return value
  }

  func waitFor(_ method: String, arguments: [String: Any] = [:],
                       key: String, value: String) async throws -> [String: Any] {
    let deadline = Date().addingTimeInterval(25)
    repeat {
      let reply = try await call(method, arguments)
      if reply[key] as? String == value { return reply }
      try await Task.sleep(for: .milliseconds(100))
    } while Date() < deadline
    throw Failure(message: "timed out waiting for \(method).\(key)=\(value)")
  }

  func probe(_ fixture: Fixture) async throws {
    var components = URLComponents(url: fixture.probeURL, resolvingAgainstBaseURL: false)!
    components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "nonce", value: UUID().uuidString)]
    var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 5)
    request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
    let session = URLSession(configuration: .ephemeral, delegate: AcceptanceNoRedirect(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let (data, response) = try await session.data(for: request)
    try require((response as? HTTPURLResponse)?.statusCode == 200, "routed fixture HTTP status")
    try require(data == Data(fixture.expectedBody.utf8), "routed fixture response body")
  }

  func receipt(_ id: UUID, outcome: String, points: [String], owner: [String: Any]? = nil) async throws {
    let value = try await waitFor("debugFaultReceipt", arguments: ["id": id.uuidString], key: "outcome", value: outcome)
    try require((value["request"] as? [String: Any])?["id"] as? String == id.uuidString, "receipt request identity")
    try require(value["points"] as? [String] == points, "fault missed its injection points")
    try require((value["generation"] as? NSNumber)?.uint64Value ?? 0 > 0, "receipt generation")
    if let owner {
      try require(value["instanceID"] as? String == owner["instanceID"] as? String &&
        value["generation"] as? NSNumber == owner["generation"] as? NSNumber, "receipt belongs to another provider")
    }
  }

  func traffic(_ fixture: Fixture) async throws {
    let before = try await call("runtimeMetrics")
    try await probe(fixture)
    let keys = before["backend"] as? String == "xrayTun"
      ? ["uplinkBytes", "downlinkBytes"] : ["bytesIn", "bytesOut"]
    let baseline = before["counters"] as? [String: NSNumber] ?? [:]
    let deadline = Date().addingTimeInterval(3)
    repeat {
      let current = try await call("runtimeMetrics")
      try require(current["instanceID"] as? String == before["instanceID"] as? String &&
        current["generation"] as? NSNumber == before["generation"] as? NSNumber, "probe crossed a provider generation")
      let counters = current["counters"] as? [String: NSNumber] ?? [:]
      if keys.allSatisfy({ counters[$0] != nil && baseline[$0] != nil && counters[$0]!.uint64Value > baseline[$0]!.uint64Value }) { return }
      try await Task.sleep(for: .milliseconds(100))
    } while Date() < deadline
    throw Failure(message: "fixture probe did not increase tunnel traffic counters")
  }

  func fault(_ action: String, node: String, owner: [String: Any], code: String?) async throws -> UUID {
    let id = UUID()
    let instance = try XCTUnwrap(owner["instanceID"] as? String)
    let generation = try XCTUnwrap(owner["generation"] as? NSNumber)
    try require(UUID(uuidString: instance) != nil && generation.uint64Value > 0, "invalid provider identity")
    do {
      _ = try await call("debugFault", ["id": id.uuidString, "action": action, "nodeId": node,
        "instanceID": instance, "generation": generation])
      try require(code == nil, "fault unexpectedly succeeded")
    } catch let error as Failure {
      guard let code, error.message == code else { throw error }
    }
    return id
  }

  func disconnect() async throws {
    let result = try await call("disconnect")
    let stopped = (result["stoppedAtMs"] as? NSNumber)?.int64Value ?? 0
    let disconnected = (result["osDisconnectedAtMs"] as? NSNumber)?.int64Value ?? 0
    try require(result["state"] as? String == "disconnected" && stopped > 0 && stopped <= disconnected,
                "provider cleanup must precede OS disconnection")
  }

  func withFixture(_ body: (Fixture, String, String) async throws -> Void) async throws {
    guard let path = ProcessInfo.processInfo.environment["ELARNI_EXTENSION_FIXTURE"] else {
      throw Failure(message: "Run scripts/check-extension with a disposable-account fixture; no tests were skipped")
    }
    let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    try require(fixture.disposableAccount == NSUserName(), "fixture does not authorize this disposable account")
    try require(fixture.nodeIDs.count == 2 && Set(fixture.nodeIDs).count == 2 && !fixture.expectedBody.isEmpty,
                "fixture needs two distinct working nodes and an exact response body")
    try require(["http", "https"].contains(fixture.probeURL.scheme) && fixture.probeURL.user == nil &&
      fixture.probeURL.password == nil && fixture.probeURL.fragment == nil, "invalid fixture probe URL")
    let managers = try await NETunnelProviderManager.loadAllFromPreferences()
    try require(managers.count == 1 && managers[0].connection.status == .disconnected &&
      (managers[0].protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == "com.elarni.mac.packet-tunnel",
      "fixture requires exactly one disconnected Elarni profile")

    let suite = "com.elarni.extension-tests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    // Isolate command intent while retaining the fixture's actual tunnel policy.
    if let settings = UserDefaults.standard.data(forKey: "ElarniTunnelSettingsV1") {
      defaults.set(settings, forKey: "ElarniTunnelSettingsV1")
    }
    let storedAutomation = UserDefaults.standard.object(forKey: "ElarniAutomationV1")
    // Verify the actual persisted policy before using isolated command intent below.
    if let storedAutomation {
      let data = try XCTUnwrap(storedAutomation as? Data, "unreadable persisted automation")
      let policy = try JSONDecoder().decode(AutomationConfiguration.self, from: data)
      try require(!policy.enabled, "disable automation in the disposable account")
    }
    channel = TunnelMethodChannel(messenger: messenger, defaults: defaults)
    controllerDefaults = defaults
    temporarySources = []
    defer { channel = nil; controllerDefaults = nil; defaults.removePersistentDomain(forName: suite) }
    let snapshot = try await call("subscriptions")
    let groups = snapshot["subscriptions"] as? [[String: Any]] ?? []
    let nodes = groups.first?["nodes"] as? [[String: Any]] ?? []
    try require(groups.count == 1 && nodes.count == 2 && groups.first?["id"] as? String == fixture.subscriptionID &&
      Set(nodes.compactMap { $0["id"] as? String }) == Set(fixture.nodeIDs), "catalog contains non-fixture data")
    try require(groups.first?["isLocal"] as? Bool == false && groups.first?["status"] as? String == "ready",
      "fixture requires a successfully refreshed remote subscription")
    let nextRefresh = try XCTUnwrap(groups.first?["nextRefreshAt"] as? Double, "fixture maintenance is paused or unavailable")
    try require(nextRefresh.isFinite && nextRefresh > Date().timeIntervalSince1970 + 600,
      "refresh the fixture before testing; maintenance is due soon")
    let initialNode = try XCTUnwrap(snapshot["selectedNodeId"] as? String)
    try require(fixture.nodeIDs.contains(initialNode), "fixture needs an initially selected node")
    let candidate = fixture.nodeIDs.first { $0 != initialNode }!
    let settings = try await call("tunnelSettings")
    try require(settings["includeAllNetworks"] as? Bool == true && settings["onDemandEnabled"] as? Bool == false &&
      settings["xrayTunEnabled"] as? Bool == false,
      "fixture needs full-tunnel protection, native tun2proxy, and on-demand disabled")
    let automation = try await call("automationStatus")
    try require(automation["enabled"] as? Bool == false, "disable automation in fixture")

    try require(settings["inboundCredentialsConfigured"] as? Bool == false &&
      settings["allowLAN"] as? Bool == false && (settings["perAppMode"] as? String ?? "off") == "off",
      "fixture must have no inbound credentials, LAN listeners or per-app rules")
    var testError: Error?
    do { try await body(fixture, initialNode, candidate) } catch {
      let failure = error as NSError
      print("Installed VPN failure: \(type(of: error)) (\(failure.domain):\(failure.code))")
      if let failure = error as? Failure { print(failure.message) }
      testError = error
    }
    // Every case, including success, restores settings and selection while disconnected.
    // Attempt each cleanup independently so one failure cannot suppress the next.
    do {
      let profiles = try await NETunnelProviderManager.loadAllFromPreferences()
      if !profiles.isEmpty { try await disconnect() }
    } catch { XCTFail("cleanup: stop failed; inspect the disposable VPN before continuing") }
    for id in temporarySources {
      do {
        let snapshot = try await call("subscriptions")
        if (snapshot["subscriptions"] as? [[String: Any]] ?? []).contains(where: { $0["id"] as? String == id }) {
          _ = try await call("deleteSubscription", ["id": id])
        }
      } catch { XCTFail("cleanup: could not remove a temporary test source") }
    }
    do { _ = try await call("selectNode", ["id": initialNode]) }
    catch { XCTFail("cleanup: could not restore the original fixture selection") }
    var restoredSettings = settings
    // Omitted optional keys must explicitly clear per-app values set by a case.
    for key in ["perAppMode", "perAppProcesses", "profilePreferredIP"] where settings[key] == nil {
      restoredSettings[key] = NSNull()
    }
    do { _ = try await call("updateTunnelSettings", restoredSettings) }
    catch { XCTFail("cleanup: could not restore the original fixture settings") }
    do {
      let profiles = try await NETunnelProviderManager.loadAllFromPreferences()
      try require(profiles.count == 1 && profiles[0].connection.status == .disconnected &&
        !profiles[0].isOnDemandEnabled && (profiles[0].onDemandRules ?? []).isEmpty,
        "fixture cleanup left an active or rearming profile")
      let restored = try await call("subscriptions")
      try require(restored["selectedNodeId"] as? String == initialNode, "fixture cleanup retained the wrong selection")
    } catch { XCTFail("cleanup verification failed; inspect the disposable account") }
    if let testError { throw testError }
  }
}

@MainActor
final class ExtensionIntegrationTests: InstalledVPNTestCase {
  func testInstalledProviderLifecycleAndTraffic() async throws {
    try await withFixture { fixture, initialNode, candidate in
      let startup = UUID()
      _ = try await call("connect", ["debugFaultID": startup.uuidString])
      try await receipt(startup, outcome: "startupFailed", points: ["startup"])
      _ = try await waitFor("state", key: "state", value: "disconnected")

      _ = try await call("connect")
      let first = try await waitFor("runtimeMetrics", key: "state", value: "connected")
      try require(first["sharedKeychainResolved"] as? Bool == true, "extension did not resolve shared credentials")
      try await traffic(fixture)

      let restored = try await fault("candidateFailure", node: candidate, owner: first, code: "node_switch_failed_restored")
      try await receipt(restored, outcome: "restored", points: ["candidate"], owner: first)
      let after = try await waitFor("runtimeMetrics", key: "state", value: "connected")
      try require(after["configurationDigest"] as? String == first["configurationDigest"] as? String,
                  "failed candidate changed the active plan")
      let retained = try await call("subscriptions")
      try require(retained["selectedNodeId"] as? String == initialNode, "failed switch committed selection")
      try await traffic(fixture)

      _ = try await call("selectNode", ["id": candidate])
      try await traffic(fixture)
      _ = try await call("selectNode", ["id": initialNode])
      try await disconnect()
      _ = try await call("connect")
      let restarted = try await waitFor("runtimeMetrics", key: "state", value: "connected")
      try require(restarted["instanceID"] as? String != first["instanceID"] as? String ||
        restarted["generation"] as? NSNumber != first["generation"] as? NSNumber, "restart reused stale provider identity")
      try await traffic(fixture)

      for action in ["coreExit", "restoreFailure"] {
        let owner = try await call("runtimeMetrics")
        let id = try await fault(action, node: candidate, owner: owner,
          code: action == "restoreFailure" ? "node_switch_restore_failed" : nil)
        try await receipt(id, outcome: action == "coreExit" ? "coreExited" : "restore_failed",
          points: action == "coreExit" ? ["coreExit"] : ["candidate", "restoration"], owner: owner)
        _ = try await waitFor("runtimeMetrics", key: "state", value: "protectedFailure")
        let state = try await call("state")
        try require(["connected", "reasserting"].contains(state["state"] as? String ?? ""), "protection routes were removed")
        do { try await probe(fixture); XCTFail("traffic escaped protected failure") }
        catch is URLError { /* Expected transport timeout/refusal, never an HTTP/body mismatch. */ }
        try await disconnect()
        _ = try await call("connect")
        _ = try await waitFor("runtimeMetrics", key: "state", value: "connected")
        try await traffic(fixture)
      }
      try await disconnect()
    }
  }
}

// Delivers encoded calls to the real registered Swift handler. It supplies no native results.
final class NativeTestMessenger: NSObject, FlutterBinaryMessenger {
  var handler: FlutterBinaryMessageHandler?
  func send(onChannel channel: String, message: Data?) {}
  func send(onChannel channel: String, message: Data?, binaryReply callback: FlutterBinaryReply?) { callback?(nil) }
  func setMessageHandlerOnChannel(_ channel: String, binaryMessageHandler handler: FlutterBinaryMessageHandler?) -> FlutterBinaryMessengerConnection {
    self.handler = handler
    return 1
  }
  func cleanUpConnection(_ connection: FlutterBinaryMessengerConnection) { handler = nil }
}
