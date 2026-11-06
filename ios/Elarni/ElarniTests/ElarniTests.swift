import XCTest
import CryptoKit
import Security
import Darwin
import Network
import NetworkExtension
import SwiftUI
@testable import Elarni

/// Real Swift catalog → Go importer → Rust compiler. No VPN activation.
@MainActor
final class ElarniTests: XCTestCase {
  func testImportPersistSelectAndShare() async throws {
    let fixture = try CatalogFixture()
    defer { fixture.remove() }
    let store = try fixture.store()
    let source = try store.registerProfiles("socks://127.0.0.1:1080#Fixture")
    let result = try await store.refresh(id: source)
    XCTAssertNil(result.warning)
    let groups = try XCTUnwrap(store.snapshot()["subscriptions"] as? [[String: Any]])
    let nodes = try XCTUnwrap(groups.first?["nodes"] as? [[String: Any]])
    let id = try XCTUnwrap(nodes.first?["id"] as? String)
    try store.commitSelection(nodeID: id)
    _ = try store.setFavorite(nodeID: id, favorite: true)
    XCTAssertFalse(try store.sharingText(id: id, subscription: false).isEmpty)
    let reopened = try fixture.store()
    XCTAssertEqual(reopened.selectedNodeID(), id)
    let saved = try XCTUnwrap(reopened.snapshot()["subscriptions"] as? [[String: Any]])
    XCTAssertEqual((saved.first?["nodes"] as? [[String: Any]])?.first?["favorite"] as? Bool, true)
  }

  func testMalformedImportDoesNotCreateGroup() throws {
    let fixture = try CatalogFixture()
    defer { fixture.remove() }
    let store = try fixture.store()
    XCTAssertThrowsError(try store.registerProfiles("not a configuration"))
    XCTAssertEqual((store.snapshot()["subscriptions"] as? [[String: Any]])?.count, 0)
  }

  func testTUICPersistsSharesCompilesAndRetainsTLSIdentity() async throws {
    let fixture = try CatalogFixture()
    defer { fixture.remove() }
    let store = try fixture.store()
    let source = try store.registerProfiles("tuic://00000000-0000-4000-8000-000000000001:p%40ss%3A%E2%9C%93@[::1]:443?sni=tuic.example&udp_relay_mode=quic#TUIC%20fixture")
    let refreshed = try await store.refresh(id: source)
    XCTAssertNil(refreshed.warning)
    let groups = try XCTUnwrap(store.snapshot()["subscriptions"] as? [[String: Any]])
    let node = try XCTUnwrap((groups.first?["nodes"] as? [[String: Any]])?.first)
    XCTAssertEqual(node["protocol"] as? String, "TUIC")
    XCTAssertEqual(node["transport"] as? String, "QUIC")
    XCTAssertEqual(node["security"] as? String, "TLS")
    let id = try XCTUnwrap(node["id"] as? String)
    try store.commitSelection(nodeID: id)
    let reopened = try fixture.store()
    XCTAssertEqual(reopened.selectedNodeID(), id)
    let profile = try reopened.outbound(nodeID: id)
    let compiled = try RoutingDomainDecoder.request("compileProfile", payload: ["profile": profile, "socksPort": 10890])
    let config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(compiled["configUtf8"] as? String).utf8)) as? [String: Any])
    let proxy = try XCTUnwrap((config["outbounds"] as? [[String: Any]])?.first { $0["protocol"] as? String == "tuic" })
    XCTAssertEqual((proxy["settings"] as? [String: Any])?["password"] as? String, "p@ss:✓")
    XCTAssertEqual(((proxy["streamSettings"] as? [String: Any])?["tlsSettings"] as? [String: Any])?["serverName"] as? String, "tuic.example")
    let endpoints = try RoutingDomainDecoder.request("profileEndpoints", payload: ["config": config])["endpoints"] as? [[String: Any]]
    XCTAssertEqual(endpoints?.first?["supportsTcpProbe"] as? Bool, false)
    let shared = try reopened.sharingText(id: id, subscription: false)
    XCTAssertTrue(shared.contains("tuic"))
  }

  // UI cannot prove provider-only validation or first-start/restart heap policy.
  func testIOSPlanRejectsDesktopOnlyRuntimeAndBoundsMemory() throws {
    var runtime = TunnelRuntimeSettings.defaults
    runtime.perAppMode = "bypass"
    runtime.perAppProcesses = ["Safari"]
    XCTAssertThrowsError(try runtime.validate())
    XCTAssertEqual(TunnelRuntimeSettings.defaults.memoryLimitBytes, 30 * 1024 * 1024)
    XCTAssertEqual(try JSONDecoder().decode(TunnelRuntimeSettings.self,
      from: JSONEncoder().encode(TunnelRuntimeSettings.defaults)).memoryLimitBytes, 30 * 1024 * 1024)
    let descriptorPlan = TunnelPlan(schemaVersion: 1, secretRef: "fixture", socksPort: 1080, mtu: 1500,
      dnsServers: ["198.18.0.1"], controlledRoutes: [], staticHosts: [:], outboundFormat: .xrayOutbound,
      fallbackAction: .proxy, routingRevision: nil, routingDigest: nil, assetRevision: nil,
      backend: .xrayTun, settings: .defaults)
    XCTAssertThrowsError(try descriptorPlan.validate())
  }

  func testIOSIdentityDoesNotClaimMacOS() {
    let headers = SubscriptionDeviceIdentity.headers(installationID: "fixture", url: URL(string: "https://example.com/feed")!)
    XCTAssertEqual(headers["X-Device-OS"], "iOS")
    XCTAssertEqual(headers["X-Device-Model"], "iPhone")
  }

  // Link-import UI fixtures have no quota metadata. They cannot catch missing
  // counters being rendered as zero usage, unlimited quotas, or Int64 overflow.
  func testProviderQuotaDoesNotInventMissingUsage() {
    XCTAssertEqual(IOSQuotaPresentation(metadata: [:]).label, "Not provided")
    XCTAssertNil(IOSQuotaPresentation(metadata: ["total": Int64(100), "download": Int64(10)]).remainingFraction)
    XCTAssertEqual(IOSQuotaPresentation(metadata: ["total": Int64(0)]).label, "Unlimited")
    XCTAssertEqual(IOSQuotaPresentation(metadata: ["total": Int64(0)]).remainingFraction, 1)
    let finite = IOSQuotaPresentation(metadata: ["total": Int64(100), "upload": Int64(8), "download": Int64(20)])
    XCTAssertEqual(finite.remainingFraction, 0.72)
    XCTAssertEqual(IOSQuotaPresentation(metadata: ["total": Int64(100), "upload": Int64(50), "download": Int64(80)]).label, "Data exhausted")
    XCTAssertEqual(IOSQuotaPresentation(metadata: ["total": Int64.max, "upload": Int64.max, "download": Int64.max]).label, "Data exhausted")
    XCTAssertNil(IOSQuotaPresentation(metadata: ["total": Int64(100), "upload": Int64(-1), "download": Int64(20)]).remainingFraction)
  }

  // An ordinary successful ping cannot expose a reply from another socket or
  // an unrelated sequence being misreported as this probe's round-trip time.
  func testICMPReplyCorrelationAndOddChecksum() {
    let reply: [UInt8] = [129, 0, 0, 0, 0x12, 0x34, 0, 7, 1, 2, 3]
    XCTAssertTrue(IOSICMP.matches(reply, family: AF_INET6, identifier: 0x1234, sequence: 7, payload: [1, 2, 3]))
    XCTAssertFalse(IOSICMP.matches(reply, family: AF_INET6, identifier: 0x1235, sequence: 7, payload: [1, 2, 3]))
    XCTAssertFalse(IOSICMP.matches(reply, family: AF_INET6, identifier: 0x1234, sequence: 8, payload: [1, 2, 3]))
    XCTAssertFalse(IOSICMP.matches(reply, family: AF_INET6, identifier: 0x1234, sequence: 7, payload: [1, 2, 4]))
    XCTAssertFalse(IOSICMP.matches([0x45, 0], family: AF_INET, identifier: 0x1234, sequence: 7, payload: []))
    XCTAssertEqual(IOSICMP.checksum([0x00, 0x01, 0xf2, 0x03, 0xf4]), 0x19fa)
  }

  func testNativeICMPLoopbackBothFamilies() async throws {
    let v4 = try await IOSICMP.measure(host: "127.0.0.1", timeout: 3, preference: "ipv4")
    let v6 = try await IOSICMP.measure(host: "::1", timeout: 3, preference: "ipv6")
    XCTAssertGreaterThanOrEqual(v4, 0)
    XCTAssertGreaterThanOrEqual(v6, 0)
  }

  // Provider labels are not geolocation. Conflicting labels must stay unknown.
  func testProviderCountryLabelsDoNotInventAnExit() {
    XCTAssertEqual(ServerLocation.fromName("DE Berlin")?.code, "DE")
    XCTAssertEqual(ServerLocation.fromName("[DEU] Berlin")?.code, "DE")
    XCTAssertEqual(ServerLocation.fromName("USA New York")?.code, "US")
    XCTAssertEqual(ServerLocation.fromName("CZE Prague")?.code, "CZ")
    XCTAssertNil(ServerLocation.fromName("DEU Netherlands chain"))
    XCTAssertNil(ServerLocation.fromName("ZZZ unknown"))
    XCTAssertEqual(ServerLocation.fromName("🇯🇵 Tokyo")?.code, "JP")
    XCTAssertEqual(ServerLocation.fromName("🇪🇺 Europe")?.code, "EU")
    XCTAssertEqual(ServerLocation.fromName("EU-01")?.code, "EU")
    XCTAssertEqual(ServerLocation.fromName("Евросоюз 03")?.code, "EU")
    XCTAssertEqual(ServerLocation.fromName("🇪🇺 🇩🇪 Frankfurt")?.code, "DE")
    XCTAssertNil(ServerLocation.fromName("🇩🇪 Germany → 🇺🇸 United States"))
    XCTAssertNil(ServerLocation.fromName("Server in the cloud"))
    // The desktop's cases in test/server_browser_test.dart, as on Android.
    for (name, code) in [("United Kingdom 01", "GB"), ("UK London", "GB"), ("[UK] 02", "GB"), ("UAE Dubai", "AE"), ("UAE-01", "AE"),
      ("ОАЭ 03", "AE"), ("CF | 🇩🇪 Frankfurt", "DE"), ("🇺🇸 New Jersey", "US"), ("Netherlands 01", "NL"), ("[NL] 04", "NL")] {
      XCTAssertEqual(ServerLocation.fromName(name)?.code, code, name)
    }
    for name in ["CF | Fast", "New Jersey 01", "Jersey City", "New Mexico", "Amsterdam", "Netherlands / Germany"] {
      XCTAssertNil(ServerLocation.fromName(name), name)
    }
  }

  func testApplicationKeychainRoundTrip() throws {
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "elarni.ios.acceptance", kSecAttrAccount as String: UUID().uuidString]
    defer { SecItemDelete(query as CFDictionary) }
    var add = query; add[kSecValueData as String] = Data("synthetic secret".utf8)
    XCTAssertEqual(SecItemAdd(add as CFDictionary, nil), errSecSuccess)
    var read = query; read[kSecReturnData as String] = true
    var result: CFTypeRef?
    XCTAssertEqual(SecItemCopyMatching(read as CFDictionary, &result), errSecSuccess)
    XCTAssertEqual(result as? Data, Data("synthetic secret".utf8))
  }

  func testQRImageUsesTheNativeImportPath() async throws {
    let text = "socks://127.0.0.1:1080#QR%20Fixture"
    let image = try XCTUnwrap(IOSImport.qr(text)?.pngData())
    let decoded = try await IOSImport.decodeQR(image)
    XCTAssertEqual(decoded, text)
    let fixture = try CatalogFixture(); defer { fixture.remove() }
    let store = try fixture.store()
    let id = try store.registerProfiles(decoded)
    _ = try await store.refresh(id: id)
    let groups = try XCTUnwrap(store.snapshot()["subscriptions"] as? [[String: Any]])
    XCTAssertEqual((groups.first?["nodes"] as? [[String: Any]])?.first?["name"] as? String, "QR Fixture")
  }

  func testEncryptedBackupRestoresSelectionRoutingAndCredentials() async throws {
    let fixture = try CatalogFixture(); defer { fixture.remove() }
    let store = try fixture.store()
    let source = try store.registerProfiles("socks://test-user:test-password@127.0.0.1:1080#Backup")
    _ = try await store.refresh(id: source)
    let groups = try XCTUnwrap(store.snapshot()["subscriptions"] as? [[String: Any]])
    let node = try XCTUnwrap((groups.first?["nodes"] as? [[String: Any]])?.first?["id"] as? String)
    try store.commitSelection(nodeID: node)
    _ = try store.routing.importContent("{\"Name\":\"Backup rules\",\"GlobalProxy\":true,\"BlockSites\":[\"example.invalid\"],\"RemoteDNSType\":\"DoU\",\"DomesticDNSType\":\"DoU\",\"RemoteDNSIP\":\"1.1.1.1\",\"DomesticDNSIP\":\"1.1.1.1\"}", selectedSubscriptionID: source)
    let routes = try XCTUnwrap(store.routing.snapshot()["profiles"] as? [[String: Any]])
    _ = try store.routing.assign(subscriptionID: source, profileID: XCTUnwrap(routes.first?["id"] as? String))
    let payload = try store.backupCatalog()
    let password = "synthetic-backup-password"
    let encrypted = try await NativeAPI.perform("sealCatalogBackup", ["catalog": payload, "password": password])
    let text = try XCTUnwrap(encrypted["text"] as? String)
    XCTAssertFalse(text.contains("test-password"))
    do {
      _ = try await NativeAPI.perform("openCatalogBackup", ["text": text, "password": "wrong-password"])
      XCTFail("A wrong password must not open the catalog")
    } catch { XCTAssertEqual(store.selectedNodeID(), node) }
    let opened = try await NativeAPI.perform("openCatalogBackup", ["text": text, "password": password])
    _ = try store.beginBackupRestore(XCTUnwrap(opened["catalog"] as? [String: Any]))
    try store.finishBackupRestore()
    let restored = try fixture.store()
    let restoredNode = try XCTUnwrap(restored.selectedNodeID())
    XCTAssertNotEqual(restoredNode, node)
    XCTAssertFalse(try restored.sharingText(id: restoredNode, subscription: false).isEmpty)
    let restoredRoutes = try XCTUnwrap(restored.routing.snapshot()["profiles"] as? [[String: Any]])
    XCTAssertEqual(restoredRoutes.first?["name"] as? String, "Backup rules")
    XCTAssertEqual((restored.routing.snapshot()["assignments"] as? [String: String])?.count, 1)
  }

  // Notification delivery cannot be time-travelled in the UI. Reconciliation
  // must remove deleted/changed sources and must not repeat a delivered reminder.
  func testExpiryRemindersReconcileWithoutRepeating() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let expiry = now.addingTimeInterval(5 * 86400).timeIntervalSince1970
    // SubscriptionStore publishes expire as Int64, as this fixture does.
    let source = ServerSubscription(raw: ["id": "a", "isLocal": false, "metadata": ["expire": Int64(expiry)]])
    let first = IOSExpiryReminders.plan(sources: [source], enabled: true, recorded: [:], now: now)
    XCTAssertEqual(first.additions.count, 1)
    XCTAssertEqual(first.additions.first?.delay, 2 * 86400)
    XCTAssertTrue(IOSExpiryReminders.plan(sources: [source], enabled: true, recorded: ["a": expiry], now: now.addingTimeInterval(3 * 86400)).additions.isEmpty)
    let removed = IOSExpiryReminders.plan(sources: [], enabled: true, recorded: ["a": expiry], now: now)
    XCTAssertEqual(removed.removals, ["a"])
    XCTAssertTrue(removed.retained.isEmpty)
    let disabled = IOSExpiryReminders.plan(sources: [source], enabled: false, recorded: ["a": expiry], now: now)
    XCTAssertEqual(disabled.removals, ["a"])
    let updated = IOSExpiryReminders.plan(sources: [source], enabled: true, recorded: ["a": expiry - 86400], now: now)
    XCTAssertEqual(updated.removals, ["a"])
    XCTAssertEqual(updated.additions.first?.expiration, expiry)
    XCTAssertTrue(IOSExpiryReminders.plan(sources: [source], enabled: true, recorded: [:], now: now.addingTimeInterval(6 * 86400)).additions.isEmpty)
  }

  // Exercise the iOS adapter against the actual Rust ABI. Provider traffic
  // cannot establish that preflight uses the same IP and DNS settings.
  func testCompilerPreservesNodeIPAndRoutingDNS() throws {
    let model = IOSAppModel()
    let outbound: [String: Any] = ["protocol": "socks", "settings": ["servers": [["address": "example.invalid", "port": 1080]]]]
    let compiled = try model.compile(outbound, routes: nil, preference: "ipv6", port: 10890)
    let proxy = try XCTUnwrap((compiled["outbounds"] as? [[String: Any]])?.first { $0["protocol"] as? String == "socks" })
    // The preference pins the server address; it must not resolve proxied destinations.
    XCTAssertNil(proxy["targetStrategy"])
    var settings = IOSTunnelSettings(); settings.profileDNSMode = "routing"
    XCTAssertEqual(try settings.runtime().useDNSFromJSON, true)
    let result = try RoutingDomainDecoder.request("compileProfile", payload: [
      "profile": ["outbounds": [outbound], "dns": ["servers": ["192.0.2.1"]]],
      "routes": ["rules": [], "dnsServers": ["192.0.2.53"], "fallbackAction": "proxy"],
      "socksPort": 10890, "packetBackend": "nativeTun2Proxy", "runtime": settings.compilerRuntime])
    let json = try XCTUnwrap(result["configUtf8"] as? String)
    let config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    XCTAssertEqual((config["dns"] as? [String: Any])?["servers"] as? [String], ["192.0.2.53"])
  }

  func testChangedIPPreferenceRequiresProviderRestart() throws {
    func plan(_ settings: TunnelRuntimeSettings, secret: String) throws -> Data {
      try JSONEncoder().encode(TunnelPlan(schemaVersion: 1, secretRef: secret, socksPort: 10890, mtu: 1500,
        dnsServers: ["198.18.0.1"], controlledRoutes: [], staticHosts: [:], outboundFormat: .xrayOutbound,
        fallbackAction: .proxy, routingRevision: nil, routingDigest: nil, assetRevision: nil,
        backend: .nativeTun2Proxy, settings: settings))
    }
    let original = try plan(.defaults, secret: "first")
    XCTAssertTrue(IOSVPNController.canSwitchLive(from: original, to: try plan(.defaults, secret: "second")))
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(TunnelRuntimeSettings.defaults)) as? [String: Any])
    json["preferredIP"] = "ipv6"
    let ipv6 = try JSONDecoder().decode(TunnelRuntimeSettings.self, from: JSONSerialization.data(withJSONObject: json))
    XCTAssertFalse(IOSVPNController.canSwitchLive(from: original, to: try plan(ipv6, secret: "second")))
  }

  // The extension checks that the server passes traffic; Home says when it does not.
  func testConnectedServerWithoutTrafficSaysSo() async throws {
    let vpn = IOSVPNController()
    let tunnel = FixtureTunnel(plan: Data())
    tunnel.session.liveness = "noTraffic"
    vpn.manager = tunnel
    try await vpn.refreshProvider()
    XCTAssertEqual(vpn.stateLabel, "Connected · no traffic")
    tunnel.session.liveness = "ok"
    try await vpn.refreshProvider()
    XCTAssertEqual(vpn.stateLabel, "Connected")
  }

  // A full-profile override must not alter ordinary outbound preferences.
  func testFullProfileIPOverrideStaysScopedToFullProfiles() throws {
    var settings = IOSTunnelSettings()
    settings.preferredIP = "ipv4"; settings.profilePreferredIP = "ipv6"
    let runtime = try settings.runtime()
    XCTAssertEqual(runtime.preferredIP, "ipv4")
    XCTAssertEqual(runtime.profilePreferredIP, "ipv6")
    let node = try settings.runtime(nodePreference: "automatic")
    XCTAssertEqual(node.preferredIP, "automatic")
    XCTAssertEqual(node.profilePreferredIP, "automatic")
  }

  // Real HTTP through the in-process Xray SOCKS listener proves response
  // validation, cancellation latency, and listener reuse after joined cleanup.
  func testNativeProxyTrafficValidationCancellationAndCleanup() async throws {
    let queue = DispatchQueue(label: "ios-probe-fixture")
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    let server = try NWListener(using: parameters)
    let connections = ProbeConnections()
    let arrived = expectation(description: "Stalled HTTP request reached the responder")
    server.newConnectionHandler = { peer in
      connections.all.append(peer)
      peer.start(queue: queue)
      peer.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
        guard let data else { return }
        if String(decoding: data, as: UTF8.self).contains("/stall") { arrived.fulfill(); return }
        let body = String(decoding: data, as: UTF8.self).contains("/cdn-cgi/trace") ? "fl=29f\nip=203.0.113.7\nloc=DE\n" : "elarniOK"
        let reply = {
          peer.send(content: Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8),
            completion: .contentProcessed { _ in peer.cancel() })
        }
        // A manual desktop-compatible timeout must survive the old five-second
        // operation deadline. This crosses the real Swift/Go/HTTP boundary.
        if String(decoding: data, as: UTF8.self).contains("/slow") { queue.asyncAfter(deadline: .now() + 6, execute: reply) }
        else { reply() }
      }
    }
    let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
      server.stateUpdateHandler = { state in
        switch state {
        case .ready: server.stateUpdateHandler = nil; continuation.resume(returning: server.port!.rawValue)
        case .failed(let error): server.stateUpdateHandler = nil; continuation.resume(throwing: error)
        default: break
        }
      }
      server.start(queue: queue)
    }
    defer { queue.sync { connections.all.forEach { $0.cancel() }; server.cancel() } }
    let socks = try IOSNetworkProbe.freePort()
    let config: [String: Any] = ["log": ["loglevel": "none"],
      "dns": ["hosts": ["probe.test": "127.0.0.1"]],
      "inbounds": [["listen": "127.0.0.1", "port": socks, "protocol": "socks", "settings": ["auth": "noauth"]]],
      "outbounds": [["protocol": "freedom", "settings": ["domainStrategy": "UseIPv4"]]]]
    var request: [String: Any] = ["configJSON": try prettyJSON(config), "proxy": "socks5://127.0.0.1:\(socks)",
      "url": "http://probe.test:\(port)/ok", "method": "GET", "mode": "default", "timeout": 5,
      "expectedStatus": 200, "expectedBody": "elarniOK"]
    let model = IOSAppModel()
    let delay = try await model.nativeProbe(request)
    XCTAssertGreaterThanOrEqual(delay, 0)
    request["expectedBody"] = "incorrect"
    do { _ = try await model.nativeProbe(request); XCTFail("Wrong body must fail") }
    catch let failure as IOSProbeFailure { XCTAssertTrue(failure.receivedHTTP); XCTAssertFalse(failure.cleanupPending) }
    request["expectedBody"] = "elarniOK"
    request["url"] = "http://probe.test:\(port)/stall"
    let stalledRequest = request
    let stalled = Task { try await model.nativeProbe(stalledRequest) }
    await fulfillment(of: [arrived], timeout: 5)
    let started = ProcessInfo.processInfo.systemUptime
    stalled.cancel()
    do { _ = try await stalled.value; XCTFail("Cancelled probe must not succeed") }
    catch is CancellationError {}
    XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 2)
    XCTAssertFalse(model.probeQuarantined)
    request["url"] = "http://probe.test:\(port)/ok"
    let recovered = try await model.nativeProbe(request)
    XCTAssertGreaterThanOrEqual(recovered, 0)
    request["url"] = "http://probe.test:\(port)/slow"
    request["timeout"] = 7
    let slow = try await model.nativeProbe(request)
    XCTAssertGreaterThanOrEqual(slow, 5_000)
    // Check exit reads Cloudflare's trace through the server instead of comparing it.
    var trace = request
    trace["url"] = "http://probe.test:\(port)/cdn-cgi/trace"
    trace["expectedBody"] = ""
    trace["timeout"] = 5
    trace["trace"] = true
    let exit = try await model.nativeProbeReply(trace)["exit"] as? [String: Any]
    XCTAssertEqual(exit?["ip"] as? String, "203.0.113.7")
    XCTAssertEqual(exit?["country"] as? String, "DE")
  }

  // A name's country is a label and the trace is evidence, so a disagreement is said.
  func testExitCheckFlagsANameThatDisagrees() {
    let exit = ExitResult(ip: "203.0.113.7", country: "DE", revision: "r")
    XCTAssertEqual(exit.mismatch(name: "🇳🇱 Amsterdam")?.named.code, "NL")
    XCTAssertEqual(exit.mismatch(name: "🇳🇱 Amsterdam")?.exit.code, "DE")
    XCTAssertNil(exit.mismatch(name: "🇩🇪 Frankfurt"))
    XCTAssertNil(exit.mismatch(name: "Private server"))
    XCTAssertNil(exit.mismatch(name: "🇪🇺 Europe"))
    XCTAssertNil(ExitResult(ip: "203.0.113.7", country: "XX", revision: "r").mismatch(name: "🇳🇱 Amsterdam"))
    XCTAssertEqual(ExitResult(ip: "203.0.113.7", country: "T1", revision: "r").countryName, "Tor")
  }

  // Home groups its servers once per change, with favorites first unless turned off.
  func testServerListGroupsOncePerChangeWithFavoritesFirst() {
    func node(_ id: String, _ name: String, favorite: Bool = false) -> [String: Any] { ["id": id, "name": name, "protocol": "vless", "favorite": favorite] }
    let source = ServerSubscription(raw: ["id": "s", "name": "Provider",
      "nodes": [node("a", "🇳🇱 Amsterdam"), node("b", "🇳🇱 Rotterdam", favorite: true), node("c", "🇩🇪 Berlin")]])
    let cache = ServerListCache()
    var key = ServerListCache.Key(catalog: 1, search: "", country: "", filter: "all", order: "provider", favoritesFirst: true, pinned: [], latencies: [:])
    cache.update(key, subscriptions: [source], probes: [:])
    cache.update(key, subscriptions: [source], probes: [:])
    XCTAssertEqual(cache.builds, 1)
    XCTAssertEqual(cache.visible.map(\.id), ["b", "a", "c"])
    XCTAssertEqual(cache.groups.map(\.code), ["DE", "NL"])
    XCTAssertEqual(cache.groups.last?.nodes.map(\.id), ["b", "a"])
    XCTAssertEqual(cache.locations.map(\.code), ["DE", "NL"])
    XCTAssertFalse(cache.hasOther)
    key.favoritesFirst = false
    cache.update(key, subscriptions: [source], probes: [:])
    XCTAssertEqual(cache.builds, 2)
    XCTAssertEqual(cache.groups.last?.nodes.map(\.id), ["a", "b"])
    key.catalog = 2
    key.search = "Berlin"
    cache.update(key, subscriptions: [source], probes: [:])
    XCTAssertEqual(cache.builds, 3)
    XCTAssertEqual(cache.visible.map(\.id), ["c"])
  }

  // Xray-core #6663: Go's HTTP/2 client gave each XHTTP upload a buffer as large as the
  // server's frames, 512 KiB against Xray, and 35 uploads got iOS extensions killed at
  // their 50 MB limit. The extension's core, with category-ads-all loaded and 40 uploads
  // open, must stay inside the 30 MiB heap it runs under.
  func testXHTTPUploadsWithAdBlockingFitTheExtensionHeap() async throws {
    let queue = DispatchQueue(label: "ios-memory-fixture")
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    let sink = try NWListener(using: parameters)
    let connections = ProbeConnections()
    sink.newConnectionHandler = { peer in
      connections.all.append(peer); peer.start(queue: queue); connections.drain(peer)
    }
    let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
      sink.stateUpdateHandler = { state in
        switch state {
        case .ready: sink.stateUpdateHandler = nil; continuation.resume(returning: sink.port!.rawValue)
        case .failed(let error): sink.stateUpdateHandler = nil; continuation.resume(throwing: error)
        default: break
        }
      }
      sink.start(queue: queue)
    }
    defer { queue.sync { connections.all.forEach { $0.cancel() }; sink.cancel() } }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ios-memory-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    // As large as the real list: v2rayN's geosite.dat holds 68,960 domain rules in it.
    try fixtureGeosite(category: "CATEGORY-ADS-ALL", count: 68_960).write(to: directory.appendingPathComponent("geosite.dat"))
    let tls = try fixtureCertificate()
    let id = "00000000-0000-4000-8000-000000000001"
    let server = try IOSNetworkProbe.freePort(), client = try IOSNetworkProbe.freePort()
    // Stream-up keeps every upload's request body, and so its buffer, open.
    let xhttp: [String: Any] = ["path": "/memory", "mode": "stream-up"]
    let config: [String: Any] = ["log": ["loglevel": "none"], "env": ["xray.location.asset": directory.path],
      "inbounds": [
        ["tag": "fixture-server", "listen": "127.0.0.1", "port": server, "protocol": "vless",
         "settings": ["clients": [["id": id]], "decryption": "none"],
         "streamSettings": ["network": "xhttp", "xhttpSettings": xhttp, "security": "tls", "tlsSettings": ["certificates": [[
           "certificate": tls.certificate.components(separatedBy: "\n"), "key": tls.key.components(separatedBy: "\n")]]]]],
        ["listen": "127.0.0.1", "port": client, "protocol": "dokodemo-door",
         "settings": ["address": "127.0.0.1", "port": Int(port), "network": "tcp"]]],
      "outbounds": [
        ["protocol": "vless", "settings": ["address": "127.0.0.1", "port": server, "id": id, "encryption": "none"],
         "streamSettings": ["network": "xhttp", "xhttpSettings": xhttp, "security": "tls",
           "tlsSettings": ["pinnedPeerCertSha256": tls.pin]]],
        ["tag": "direct", "protocol": "freedom", "settings": ["finalRules": [["action": "allow", "ip": ["127.0.0.1/32"]]]]],
        ["tag": "block", "protocol": "blackhole"]],
      "routing": ["rules": [
        ["inboundTag": ["fixture-server"], "outboundTag": "direct"],
        ["domain": ["geosite:category-ads-all"], "outboundTag": "block"]]]]
    _ = try NativeAPI.invoke("setMemoryLimit", ["bytes": TunnelRuntimeSettings.defaults.memoryLimitBytes])
    _ = try NativeAPI.invoke("runXrayFromJson", ["configJSON": try prettyJSON(config)])
    defer { _ = try? NativeAPI.invoke("stopXray") }
    // The iOS core collects every second, so two seconds of samples see its settled heap.
    func peakHeap() async throws -> Int {
      var peak = 0
      let end = ProcessInfo.processInfo.systemUptime + 2
      while ProcessInfo.processInfo.systemUptime < end {
        peak = max(peak, try NativeAPI.invoke("getRuntimeMetrics")["heapAllocBytes"] as? Int ?? 0)
        try await Task.sleep(for: .milliseconds(20))
      }
      return peak
    }
    let idle = try await peakHeap()
    let chunk = Data(count: 64 * 1024)
    let uploads = (0..<40).map { _ in NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(client))!, using: .tcp) }
    defer { uploads.forEach { $0.cancel() } }
    for upload in uploads { upload.start(queue: queue); upload.send(content: chunk, completion: .idempotent) }
    let started = ProcessInfo.processInfo.systemUptime
    while queue.sync(execute: { connections.received }) < uploads.count * chunk.count && ProcessInfo.processInfo.systemUptime - started < 10 {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertEqual(queue.sync { connections.received }, uploads.count * chunk.count)
    let open = try await peakHeap()
    print("iOS XHTTP heap: idle \(idle) B, with \(uploads.count) uploads \(open) B")
    XCTAssertLessThan(open, TunnelRuntimeSettings.defaults.memoryLimitBytes)
    // This core runs both ends of each upload: about 140 KB together, and 650 KB when
    // the client sizes its buffer by the server's frames.
    XCTAssertLessThan(open - idle, uploads.count * 256 * 1024, "an open upload holds more than 256 KiB")
  }

  // Production catalog/model -> native cores -> delayed HTTP responder. A
  // single native probe cannot expose serial model scheduling or blocked updates.
  func testManualProbesRunTogetherAndPublishBeforeSlowPeer() async throws {
    let queue = DispatchQueue(label: "ios-parallel-model-fixture")
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    let server = try NWListener(using: parameters)
    let connections = ProbeConnections()
    server.newConnectionHandler = { peer in
      connections.all.append(peer); peer.start(queue: queue)
      peer.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
        guard data != nil else { return }
        connections.waiting.append(peer)
        guard connections.waiting.count == 26 else { return }
        for (index, connection) in connections.waiting.enumerated() {
          queue.asyncAfter(deadline: .now() + (index == 25 ? 1.0 : 0.2)) {
            connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Length: 8\r\nConnection: close\r\n\r\nelarniOK".utf8),
              completion: .contentProcessed { _ in connection.cancel() })
          }
        }
      }
    }
    let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
      server.stateUpdateHandler = { state in
        switch state {
        case .ready: server.stateUpdateHandler = nil; continuation.resume(returning: server.port!.rawValue)
        case .failed(let error): server.stateUpdateHandler = nil; continuation.resume(throwing: error)
        default: break
        }
      }
      server.start(queue: queue)
    }
    defer { queue.sync { connections.all.forEach { $0.cancel() }; server.cancel() } }
    // A local group keeps each server once, so each test server has its own port.
    var upstreams = Set<Int>()
    while upstreams.count < 26 { upstreams.insert(try IOSNetworkProbe.freePort()) }
    _ = try NativeAPI.invoke("runXrayFromJson", ["configJSON": try prettyJSON([
      "log": ["loglevel": "none"],
      "inbounds": upstreams.map { ["listen": "127.0.0.1", "port": $0, "protocol": "socks", "settings": ["auth": "noauth"]] as [String: Any] },
      "outbounds": [["protocol": "freedom"]]])])
    defer { _ = try? NativeAPI.invoke("stopXray") }
    let model = IOSAppModel()
    await model.start()
    let values = try await importLocal(model, upstreams.enumerated().map { "socks://127.0.0.1:\($1)#Germany%20Parallel%20\($0)" }.joined(separator: "\n")).nodes
    XCTAssertEqual(values.count, 26)
    let previous = model.preferences
    defer { model.cancelTests(); try? model.savePreferences(previous) }
    var preferences = previous
    preferences.probeMode = "proxy"; preferences.probeURL = "http://127.0.0.1:\(port)/parallel"
    preferences.probeExpectedStatus = 200; preferences.probeExpectedBody = "elarniOK"
    try model.savePreferences(preferences)
    let started = ProcessInfo.processInfo.systemUptime
    model.testServers(values)
    while model.probes.count < 25 && ProcessInfo.processInfo.systemUptime - started < 3 {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(model.probes.count, 25)
    XCTAssertEqual(model.testingIDs.count, 1)
    while model.busy && ProcessInfo.processInfo.systemUptime - started < 4 {
      try await Task.sleep(for: .milliseconds(10))
    }
    let elapsed = ProcessInfo.processInfo.systemUptime - started
    print("iOS 26 manual proxy probes: \(elapsed)s")
    XCTAssertLessThan(elapsed, 2.5)
    XCTAssertTrue(model.testingIDs.isEmpty)
    XCTAssertEqual(model.probes.count, 26)
    XCTAssertTrue(values.allSatisfy { model.probes[$0.id]?.milliseconds != nil })
    if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
      let previousWindow = scene.windows.first(where: \.isKeyWindow)
      let window = UIWindow(windowScene: scene)
      for (name, scheme) in [("Light", ColorScheme.light), ("Dark", ColorScheme.dark)] {
        window.rootViewController = UIHostingController(rootView: NavigationStack { HomeView() }
          .environment(model).preferredColorScheme(scheme))
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(200))
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Parallel ping \(name)"; attachment.lifetime = .keepAlways; add(attachment)
      }
      window.isHidden = true; previousWindow?.makeKeyAndVisible()
    } else { XCTFail("No real application window for badge captures") }
    let completedDates = model.probes.mapValues(\.date)
    model.testServers(values)
    let arrivalsStarted = ProcessInfo.processInfo.systemUptime
    while queue.sync(execute: { connections.waiting.count }) < 52 && ProcessInfo.processInfo.systemUptime - arrivalsStarted < 3 {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(queue.sync { connections.waiting.count }, 52)
    let cancelledAt = ProcessInfo.processInfo.systemUptime
    model.cancelTests()
    while model.busy && ProcessInfo.processInfo.systemUptime - cancelledAt < 2 {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertFalse(model.busy)
    XCTAssertTrue(model.testingIDs.isEmpty)
    XCTAssertEqual(model.probes.mapValues(\.date), completedDates)
    XCTAssertFalse(model.probeQuarantined)
    for source in model.subscriptions where source.nodes.contains(where: { values.map(\.id).contains($0.id) }) {
      try await model.delete(source)
    }
  }

  // The simulator has no VPN, so a fixture tunnel replies as the provider does.
  // A refused switch leaves the previous plan running and saved: restoring it
  // again is a second switch, and a pending recovery blocks the next change.
  // The level reaches the extension through the shared folder. A running extension serves its own lines;
  // while it does not run, the app shows the ones it kept when it stopped.
  func testCoreLogLevelAndLinesComeFromTheExtension() async throws {
    let model = IOSAppModel()
    await model.start()
    let logs = try XCTUnwrap(model.logsDirectory)
    try? FileManager.default.removeItem(at: logs)
    defer { try? FileManager.default.removeItem(at: logs) }
    XCTAssertEqual(model.logLevel, "warning")
    XCTAssertThrowsError(try model.setLogLevel("loud"))
    try model.setLogLevel("debug")
    XCTAssertEqual(model.logLevel, "debug")
    XCTAssertEqual(try String(contentsOf: logs.appendingPathComponent("level"), encoding: .utf8), "debug")

    let tunnel = FixtureTunnel(plan: Data("{}".utf8))
    model.vpn.manager = tunnel
    defer { model.vpn.manager = nil }
    try await model.vpn.refreshProvider()
    let liveReply = await model.readLogs(after: 4)
    let live = try XCTUnwrap(liveReply)
    XCTAssertEqual(tunnel.session.logReads, [4])
    XCTAssertEqual((live["entries"] as? [[String: Any]])?.compactMap { $0["seq"] as? Int }, [5])

    tunnel.session.fixtureStatus = .disconnected
    try await model.vpn.refreshProvider()
    let emptyReply = await model.readLogs(after: 0)
    let empty = try XCTUnwrap(emptyReply)
    XCTAssertEqual((empty["entries"] as? [Any])?.count, 0)
    let kept: [String: Any] = ["level": "warning", "last": 3, "entries": [1, 2, 3].map {
      ["seq": $0, "time": 1_700_000_000_000, "level": "warning", "text": "line \($0)"] as [String: Any] }]
    try JSONSerialization.data(withJSONObject: kept).write(to: logs.appendingPathComponent("last.json"))
    let stoppedReply = await model.readLogs(after: 1)
    let stopped = try XCTUnwrap(stoppedReply)
    XCTAssertEqual(tunnel.session.logReads, [4])
    XCTAssertEqual(stopped["last"] as? Int, 3)
    XCTAssertEqual((stopped["entries"] as? [[String: Any]])?.compactMap { $0["seq"] as? Int }, [2, 3])
  }

  func testRefusedSwitchKeepsPreviousPlanWithoutRestoreOrRecovery() async throws {
    let model = IOSAppModel()
    await model.start()
    let group = try await importLocal(model, "socks://127.0.0.1:1080#Switch%20First\nsocks://127.0.0.1:1081#Switch%20Second")
    XCTAssertEqual(group.nodes.count, 2)
    let first = try XCTUnwrap(group.nodes.first), second = try XCTUnwrap(group.nodes.last)
    try await model.select(first)
    let tunnel = FixtureTunnel(plan: try await model.makePlan(nodeID: first.id))
    model.vpn.manager = tunnel
    try await model.vpn.refreshProvider()
    XCTAssertTrue(model.vpn.connected)
    let previous = try XCTUnwrap(model.vpn.savedPlan)
    let candidate = try await model.makePlan(nodeID: second.id)
    let unrestored: [(String, Error)] = [("quarantined", AutomationFailure.quarantine), ("restore_failed", IOSAppError.switchRestoreFailed)]
    for (code, expected) in unrestored {
      tunnel.session.reply = code
      do { try await model.vpn.switchPlan(candidate); XCTFail("\(code) switched") }
      catch { XCTAssertEqual(String(reflecting: error), String(reflecting: expected), code) }
    }
    let refused: [(String, Error)] = [("restored", IOSAppError.switchFailed), ("rejected", IOSAppError.switchFailed),
      ("missing_credentials", AutomationFailure.missingCredentials),
      ("invalid_configuration", AutomationFailure.invalidConfiguration),
      ("resolution_failed", IOSAppError.serverUnresolvable)]
    for (code, expected) in refused {
      tunnel.session.reply = code
      tunnel.session.switches = 0
      do { try await model.select(second); XCTFail("\(code) selected the new server") }
      catch { XCTAssertEqual(String(reflecting: error), String(reflecting: expected), code) }
      model.reload()
      XCTAssertEqual(tunnel.session.switches, 1, code)
      XCTAssertEqual(model.selectedID, first.id, code)
      XCTAssertEqual(model.vpn.savedPlan, previous, code)
    }
    // A catalog change whose plan differs from the saved one switches live the same way.
    var stale = try XCTUnwrap(JSONSerialization.jsonObject(with: previous) as? [String: Any])
    stale["dnsServers"] = ["198.18.0.1"]
    let stalePlan = try JSONSerialization.data(withJSONObject: stale, options: [.sortedKeys])
    tunnel.setPlan(stalePlan)
    tunnel.session.reply = "restored"
    tunnel.session.switches = 0
    do { try await model.setIP(second, value: "ipv4"); XCTFail("A refused switch published the change") }
    catch { XCTAssertEqual(error as? IOSAppError, .switchFailed) }
    XCTAssertEqual(tunnel.session.switches, 1)
    XCTAssertEqual(model.vpn.savedPlan, stalePlan)
    tunnel.session.reply = "switched"
    tunnel.session.switches = 0
    do { try await model.select(second) } catch { XCTFail("A refused switch blocked the next change: \(error)") }
    XCTAssertEqual(model.selectedID, second.id)
    XCTAssertEqual(tunnel.session.switches, 1)
    model.vpn.manager = nil
    try await model.delete(group)
  }

  // Deleting a listed server keeps automatic recovery over the ones that remain.
  func testDeletingARecoveryServerKeepsRecovery() async throws {
    let model = IOSAppModel()
    await model.start()
    let previous = model.preferences
    defer { try? model.savePreferences(previous) }
    let group = try await importLocal(model, "socks://127.0.0.1:1080#Keep%20A\nsocks://127.0.0.1:1081#Keep%20B\nsocks://127.0.0.1:1082#Keep%20C")
    let nodes = group.nodes
    XCTAssertEqual(nodes.count, 3)
    try await model.select(nodes[0])
    var next = model.preferences
    next.automation = AutomationConfiguration(enabled: true, policy: .lowestLatency, subscriptionID: group.id, nodeIDs: nodes.map(\.id),
      targets: [.init(id: "a", url: "https://check-a.example/204", expectedStatus: 204, expectedBody: ""),
                .init(id: "b", url: "https://check-b.example/204", expectedStatus: 204, expectedBody: "")])
    try model.savePreferences(next)
    let deleted2 = await model.perform { try model.deleteNode(nodes[2]) }
    XCTAssertTrue(deleted2)
    XCTAssertTrue(model.preferences.automation.enabled)
    XCTAssertEqual(model.preferences.automation.policy, .lowestLatency)
    XCTAssertEqual(model.preferences.automation.nodeIDs, [nodes[0].id, nodes[1].id])
    // One server left is fixed recovery, which needs no alternatives.
    let deleted1 = await model.perform { try model.deleteNode(nodes[1]) }
    XCTAssertTrue(deleted1)
    XCTAssertTrue(model.preferences.automation.enabled)
    XCTAssertEqual(model.preferences.automation.policy, .fixed)
    XCTAssertEqual(model.preferences.automation.nodeIDs, [nodes[0].id])
    try await model.delete(group)
  }

  // Servers removed together keep recovery over the ones that remain, and a selection
  // that includes the selected server removes none.
  func testDeletingServersTogetherKeepsRecoveryAndTheSelectedServer() async throws {
    let model = IOSAppModel()
    await model.start()
    let previous = model.preferences
    defer { try? model.savePreferences(previous) }
    let group = try await importLocal(model, "socks://127.0.0.1:1080#Batch%20A\nsocks://127.0.0.1:1081#Batch%20B\nsocks://127.0.0.1:1082#Batch%20C")
    let nodes = group.nodes
    XCTAssertEqual(nodes.count, 3)
    try await model.select(nodes[0])
    var next = model.preferences
    next.automation = AutomationConfiguration(enabled: true, policy: .lowestLatency, subscriptionID: group.id, nodeIDs: nodes.map(\.id),
      targets: [.init(id: "a", url: "https://check-a.example/204", expectedStatus: 204, expectedBody: ""),
                .init(id: "b", url: "https://check-b.example/204", expectedStatus: 204, expectedBody: "")])
    try model.savePreferences(next)
    let refused = await model.perform(reportError: false) { try model.deleteNodes([nodes[1], nodes[0]]) }
    XCTAssertFalse(refused)
    XCTAssertEqual(model.subscriptions.first { $0.id == group.id }?.nodes.count, 3, "a refused selection deleted servers")
    let deleted = await model.perform { try model.deleteNodes([nodes[1], nodes[2]]) }
    XCTAssertTrue(deleted)
    XCTAssertEqual(model.subscriptions.first { $0.id == group.id }?.nodes.map(\.id), [nodes[0].id])
    XCTAssertEqual(model.preferences.automation.nodeIDs, [nodes[0].id])
    XCTAssertEqual(model.preferences.automation.policy, .fixed)
    try await model.delete(try XCTUnwrap(model.subscriptions.first { $0.id == group.id }))
  }

  // Backups may come from another subscription, and choosing a server by hand makes
  // it the primary without dropping them.
  func testRecoveryBackupsSpanSubscriptionsAndSurviveAManualChoice() async throws {
    let model = IOSAppModel()
    await model.start()
    let previous = model.preferences
    defer { try? model.savePreferences(previous) }
    let first = try await importLocal(model, "socks://127.0.0.1:1080#Span%20A")
    let existing = Set(model.subscriptions.map(\.id))
    try await model.importInput("#hide-url: yes\nsocks://127.0.0.1:1081#%F0%9F%87%B7%F0%9F%87%BA%20Span%20B")
    let second = try XCTUnwrap(model.subscriptions.first { !existing.contains($0.id) })
    let a = try XCTUnwrap(first.nodes.first), b = try XCTUnwrap(second.nodes.first)
    XCTAssertTrue(ServerLocation.russianEntry(b.name))
    XCTAssertFalse(ServerLocation.russianEntry(a.name))
    try await model.select(a)
    var next = model.preferences
    next.automation = AutomationConfiguration(enabled: true, policy: .orderedFallback, subscriptionID: first.id, nodeIDs: [a.id, b.id],
      targets: [.init(id: "a", url: "https://check-a.example/204", expectedStatus: 204, expectedBody: ""),
                .init(id: "b", url: "https://check-b.example/204", expectedStatus: 204, expectedBody: "")])
    next.automation.russianEntryNodeIDs = [b.id]
    try model.savePreferences(next)
    try await model.select(b)
    XCTAssertEqual(model.preferences.automation.policy, .orderedFallback)
    XCTAssertEqual(model.preferences.automation.subscriptionID, second.id)
    XCTAssertEqual(model.preferences.automation.nodeIDs, [b.id, a.id])
    XCTAssertEqual(model.preferences.automation.russianEntryNodeIDs, [b.id])
    try await model.delete(second)
    try await model.delete(first)
  }

  // The old 256 TCP / 128 UDP limits dropped DNS queries under load. They are raised
  // once on upgrade; limits picked afterwards stay.
  func testOldSessionLimitsAreRaisedOnce() async throws {
    let model = IOSAppModel()
    await model.start()
    let original = model.settings
    var old = original; old.tcpMaxConnections = 256; old.udpMaxConnections = 128
    try await model.saveSettings(old)
    UserDefaults.standard.removeObject(forKey: "ElarniSessionLimitsMigrated")
    let upgraded = IOSAppModel()
    await upgraded.start()
    XCTAssertEqual([upgraded.settings.tcpMaxConnections, upgraded.settings.udpMaxConnections], [2_048, 1_024])
    try await upgraded.saveSettings(old)
    let kept = IOSAppModel()
    await kept.start()
    XCTAssertEqual([kept.settings.tcpMaxConnections, kept.settings.udpMaxConnections], [256, 128],
      "limits picked after the upgrade were raised again")
    try await kept.saveSettings(original)
  }

  // iOS starts a killed extension again only through On Demand, so a new install has it on;
  // settings saved with it off keep that choice.
  func testOnDemandIsOnForNewInstallsAndKeepsASavedChoice() throws {
    XCTAssertTrue(IOSTunnelSettings().onDemandEnabled, "a new install leaves a killed VPN down")
    var off = IOSTunnelSettings(); off.onDemandEnabled = false
    XCTAssertFalse(try JSONDecoder().decode(IOSTunnelSettings.self, from: JSONEncoder().encode(off)).onDemandEnabled,
      "a saved choice to keep On Demand off was overridden")
  }

  // The extension has about 50 MB and copies the route model several times, so a
  // model over the iOS cap stops before the extension with its own message.
  func testOversizedRoutingProfileFailsWithClearError() async throws {
    let model = IOSAppModel()
    await model.start()
    let group = try await importLocal(model, "socks://127.0.0.1:1080#Large%20Routing")
    let node = try XCTUnwrap(group.nodes.first)
    try await model.select(node)
    // About 2.8 MB: over the 2 MB iOS cap, under the 8 MB import limit.
    let sites = (0..<90_000).map { String(format: "full:site-%06ld.example.com", $0) }
    let profile = try JSONSerialization.data(withJSONObject: ["Name": "Large routing", "RemoteDNSType": "DoU", "RemoteDNSIP": "1.1.1.1",
      "DomesticDNSType": "DoU", "DomesticDNSIP": "8.8.8.8", "DirectSites": sites])
    // The import or the next plan refuses it, whichever builds the route model first.
    do {
      try await model.importInput("happ://routing/onadd/" + profile.base64EncodedString())
      model.reload()
      _ = try await model.makePlan(nodeID: node.id)
      XCTFail("an oversized route model reached the extension")
    } catch {
      XCTAssertEqual(String(reflecting: error), String(reflecting: RoutingStoreError.routeModelTooLarge))
      model.show(error)
    }
    XCTAssertEqual(model.errorMessage, "This routing profile is too large for iPhone: its rules and lists exceed 2 MB. Remove some rules or managed lists.")
    try await model.delete(group)
    model.reload()
    for large in model.routingProfiles where large.name == "Large routing" {
      try await model.editRouting { _ = try $0.delete(id: large.id) }
      model.reload()
    }
  }

  // Every preset entry is a target the native compiler takes, so a profile using the preset connects.
  func testRussianSitesPresetCompiles() async throws {
    XCTAssertEqual(Array(RoutingEditor.russianSitesPreset.prefix(3)), ["domain:ru", "domain:xn--p1ai", "domain:su"])
    XCTAssertEqual(lines((["example.com", "domain:ru"] + RoutingEditor.russianSitesPreset).joined(separator: "\n")),
      ["example.com"] + RoutingEditor.russianSitesPreset, "the preset added a repeat or moved the user's entries")
    let model = IOSAppModel()
    await model.start()
    let group = try await importLocal(model, "socks://127.0.0.1:1080#Russian%20Sites")
    let node = try XCTUnwrap(group.nodes.first)
    try await model.select(node)
    let profile = try JSONSerialization.data(withJSONObject: ["Name": "Russian sites", "RemoteDNSType": "DoU", "RemoteDNSIP": "1.1.1.1",
      "DomesticDNSType": "DoU", "DomesticDNSIP": "8.8.8.8", "DirectSites": RoutingEditor.russianSitesPreset])
    try await model.importInput("happ://routing/onadd/" + profile.base64EncodedString())
    model.reload()
    _ = try await model.makePlan(nodeID: node.id)
    try await model.delete(group)
    model.reload()
    for preset in model.routingProfiles where preset.name == "Russian sites" {
      try await model.editRouting { _ = try $0.delete(id: preset.id) }
      model.reload()
    }
  }

  // A routing link that turns a profile on needs a selected server, and says so.
  func testRoutingLinkWithoutSelectedServerAsksForOne() async throws {
    let model = IOSAppModel()
    await model.start()
    let group = try await importLocal(model, "socks://127.0.0.1:1080#Routing%20Link%20Selection")
    try await model.select(try XCTUnwrap(group.nodes.first))
    // Deleting the selected server's group clears the selection.
    try await model.delete(group)
    model.reload()
    XCTAssertNil(model.selectedID)
    await model.perform { try await model.importInput("happ://routing/off") }
    XCTAssertEqual(model.errorMessage, "Select a server first. This routing link turns its profile on for the selected server’s subscription.")
  }

  // On Demand waiting offline reads as disconnected. A catalog change then saves a
  // fresh plan and leaves On Demand on instead of clearing both.
  func testCatalogChangeWhileOnDemandWaitsKeepsOnDemand() async throws {
    let model = IOSAppModel()
    await model.start()
    let group = try await importLocal(model, "socks://127.0.0.1:1080#On%20Demand%20Waiting")
    let node = try XCTUnwrap(group.nodes.first)
    try await model.select(node)
    let original = model.settings
    var next = original; next.onDemandEnabled = true
    try await model.saveSettings(next)
    let tunnel = FixtureTunnel(plan: try await model.makePlan(nodeID: node.id))
    tunnel.session.fixtureStatus = .disconnected
    tunnel.isOnDemandEnabled = true
    model.vpn.manager = tunnel
    try await model.vpn.refreshProvider()
    // The simulator cannot start a tunnel, but Connect still records the intent.
    await model.connect()
    let before = try XCTUnwrap(model.vpn.savedPlan)
    try await model.setIP(node, value: "ipv4")
    XCTAssertTrue(tunnel.isOnDemandEnabled)
    let saved = try XCTUnwrap(model.vpn.savedPlan, "The waiting On Demand rule lost its plan")
    XCTAssertNotEqual(saved, before)
    let current = try await model.makePlan(nodeID: node.id)
    XCTAssertEqual(saved, current)
    var off = model.settings; off.onDemandEnabled = false
    try await model.saveSettings(off)
    XCTAssertFalse(tunnel.isOnDemandEnabled, "Turning On Demand off in Settings left it on")
    await model.disconnect()
    try await model.saveSettings(original)
    model.vpn.manager = nil
    try await model.delete(group)
  }

  // Connect on untrusted Wi-Fi arms On Demand before any Connect and keeps the plan iOS starts.
  // A connection it makes becomes the app's; Disconnect pauses the rule until the next Connect.
  func testUntrustedWiFiArmsOnDemandUntilAStop() async throws {
    let model = IOSAppModel()
    await model.start()
    let original = model.settings
    // Settings saved before the rule existed lack both keys and still load.
    var old = original; old.connectOnUntrustedWiFi = nil; old.trustedWiFiNetworks = nil
    let json = try JSONEncoder().encode(old)
    XCTAssertFalse(String(decoding: json, as: UTF8.self).contains("WiFi"))
    XCTAssertEqual(try JSONDecoder().decode(IOSTunnelSettings.self, from: json), old)
    var long = original; long.trustedWiFiNetworks = [String(repeating: "a", count: 33)]
    XCTAssertThrowsError(try long.validate(), "A Wi-Fi name over 32 bytes was accepted")
    let group = try await importLocal(model, "socks://127.0.0.1:1080#Untrusted%20WiFi")
    let node = try XCTUnwrap(group.nodes.first)
    try await model.select(node)
    let tunnel = FixtureTunnel(plan: try await model.makePlan(nodeID: node.id))
    tunnel.session.fixtureStatus = .disconnected
    model.vpn.manager = tunnel
    try await model.vpn.refreshProvider()
    await model.disconnect()
    // The rule applies while On Demand itself is off, which a new install no longer is.
    var next = original; next.onDemandEnabled = false; next.connectOnUntrustedWiFi = true; next.trustedWiFiNetworks = ["Home"]
    try await model.saveSettings(next)
    let rules = tunnel.onDemandRules ?? []
    XCTAssertTrue(tunnel.isOnDemandEnabled, "Turning the rule on did not arm it before Connect")
    XCTAssertEqual(rules.map(\.action), [.ignore, .connect, .ignore])
    XCTAssertEqual(rules.map(\.interfaceTypeMatch), [.wiFi, .wiFi, .any])
    XCTAssertEqual(rules.first?.ssidMatch, ["Home"])
    XCTAssertNotNil(model.vpn.savedPlan, "The armed rule lost the plan iOS starts it with")
    try await model.setIP(node, value: "ipv4")
    XCTAssertTrue(tunnel.isOnDemandEnabled, "A catalog change dropped the armed rule")
    // On Demand connected an untrusted network while the app was stopped.
    tunnel.session.fixtureStatus = .connected
    try await model.vpn.refreshProvider()
    model.adoptUntrustedWiFiConnection()
    XCTAssertEqual(TunnelCommandCoordinator().intent, .connected, "The app did not take over the On Demand connection")
    await model.disconnect()
    XCTAssertFalse(tunnel.isOnDemandEnabled, "Disconnect left the Wi-Fi rule armed")
    try await model.setIP(node, value: "inherit")
    XCTAssertFalse(tunnel.isOnDemandEnabled, "A catalog change re-armed a paused rule")
    // The simulator cannot start a tunnel, but Connect still records the intent.
    await model.connect()
    try await model.setIP(node, value: "ipv6")
    XCTAssertEqual(tunnel.onDemandRules?.count, 3, "Connect did not re-arm the Wi-Fi rule")
    await model.disconnect()
    var off = model.settings; off.connectOnUntrustedWiFi = false
    try await model.saveSettings(off)
    XCTAssertFalse(tunnel.isOnDemandEnabled, "Turning the rule off left On Demand on")
    try await model.saveSettings(original)
    model.vpn.manager = nil
    try await model.delete(group)
  }

  // Stop frees route models and asset revisions that nothing names. The files
  // of the saved plan stay: iOS can start the provider with it at any time.
  func testStopReclaimsRoutingFilesTheSavedPlanDoesNotName() async throws {
    let model = IOSAppModel()
    await model.start()
    let routing = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
      .appendingPathComponent("Elarni/Routing", isDirectory: true)
    let route = "route-model-" + String(repeating: "a", count: 64) + ".json"
    let asset = UUID().uuidString.lowercased()
    let files = [routing.appendingPathComponent("Revisions/" + route),
                 routing.appendingPathComponent("Revisions/route-model-" + String(repeating: "b", count: 64) + ".json"),
                 routing.appendingPathComponent("Assets/" + asset),
                 routing.appendingPathComponent("Assets/" + UUID().uuidString.lowercased())]
    defer { files.forEach { try? FileManager.default.removeItem(at: $0) } }
    for file in files[0...1] { try Data("{}".utf8).write(to: file) }
    for directory in files[2...3] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false) }
    let plan = TunnelPlan(schemaVersion: 1, secretRef: "fixture", socksPort: 10890, mtu: 1500,
      dnsServers: ["198.18.0.1"], controlledRoutes: [], staticHosts: [:], outboundFormat: .xrayOutbound,
      fallbackAction: .proxy, routingRevision: route, routingDigest: String(repeating: "a", count: 64),
      assetRevision: asset, backend: .nativeTun2Proxy, settings: .defaults)
    model.vpn.manager = FixtureTunnel(plan: try JSONEncoder().encode(plan))
    defer { model.vpn.manager = nil }
    try await model.vpn.refreshProvider()
    await model.perform {}
    XCTAssertEqual(files.map { FileManager.default.fileExists(atPath: $0.path) }, [true, true, true, true],
      "A running provider may still read any of these files")
    await model.disconnect()
    XCTAssertNil(model.errorMessage)
    XCTAssertEqual(files.map { FileManager.default.fileExists(atPath: $0.path) }, [true, false, true, false])
  }

  // On Demand waiting reads as disconnected, but iOS starts the provider from the
  // saved plan, so a server picked meanwhile must reach that plan.
  func testSelectWhileOnDemandWaitsSavesNewServerPlan() async throws {
    let model = IOSAppModel()
    await model.start()
    let group = try await importLocal(model, "socks://127.0.0.1:1080#Waiting%20First\nsocks://127.0.0.1:1081#Waiting%20Second")
    let first = try XCTUnwrap(group.nodes.first), second = try XCTUnwrap(group.nodes.last)
    try await model.select(first)
    let original = model.settings
    var next = original; next.onDemandEnabled = true
    try await model.saveSettings(next)
    let firstPlan = try await model.makePlan(nodeID: first.id)
    let tunnel = FixtureTunnel(plan: firstPlan)
    tunnel.session.fixtureStatus = .disconnected
    tunnel.isOnDemandEnabled = true
    model.vpn.manager = tunnel
    try await model.vpn.refreshProvider()
    // The simulator cannot start a tunnel, but Connect still records the intent.
    await model.connect()
    XCTAssertEqual(model.vpn.savedPlan, firstPlan)
    try await model.select(second)
    XCTAssertEqual(model.selectedID, second.id)
    let secondPlan = try await model.makePlan(nodeID: second.id)
    XCTAssertNotEqual(firstPlan, secondPlan)
    XCTAssertEqual(model.vpn.savedPlan, secondPlan, "On Demand would start the previously selected server")
    await model.disconnect()
    try await model.saveSettings(original)
    model.vpn.manager = nil
    try await model.delete(group)
  }

  // Shortcuts, Siri and the Control Center toggle run the app's own Connect and Stop.
  func testConnectionIntentsConnectAndStopThroughTheApp() async throws {
    let app = IOSAppModel.shared, model = IOSAppModel()
    IOSAppModel.shared = model
    defer { IOSAppModel.shared = app }
    await model.start()
    let group = try await importLocal(model, "socks://127.0.0.1:1080#Shortcut%20Server")
    try await model.select(try XCTUnwrap(group.nodes.first))
    let tunnel = FixtureTunnel(plan: Data())
    tunnel.session.fixtureStatus = .disconnected
    model.vpn.manager = tunnel
    try await model.vpn.refreshProvider()
    // The simulator cannot start a tunnel; Shortcuts shows the app's reason instead of a success.
    do { _ = try await ConnectIntent().perform(); XCTFail("Connect succeeded without a tunnel") }
    catch let error as ConnectionIntentError { XCTAssertTrue(error.message.contains("signed app"), error.message) }
    tunnel.session.fixtureStatus = .connected
    try await model.vpn.refreshProvider()
    _ = try await ConnectIntent().perform()
    XCTAssertEqual(tunnel.session.fixtureStatus, .connected, "Connect stopped the running VPN")
    var control = ConnectionControlIntent(); control.value = false
    _ = try await control.perform()
    XCTAssertEqual(tunnel.session.fixtureStatus, .disconnected)
    XCTAssertFalse(model.vpn.active)
    tunnel.session.fixtureStatus = .connected
    try await model.vpn.refreshProvider()
    _ = try await ToggleConnectionIntent().perform()
    XCTAssertEqual(tunnel.session.fixtureStatus, .disconnected)
    _ = try await DisconnectIntent().perform()
    XCTAssertNil(model.errorMessage)
    XCTAssertEqual(ElarniShortcuts.appShortcuts.count, 3)
    model.vpn.manager = nil
    try await model.delete(group)
  }

  // A publish while iOS is still connecting is refused as busy. Its rollback must
  // not leave runtime reconciliation pending, or every later switch is refused.
  func testPublishWhileConnectingDoesNotBlockLaterSwitch() async throws {
    let model = IOSAppModel()
    await model.start()
    let group = try await importLocal(model, "socks://127.0.0.1:1080#Connecting%20First\nsocks://127.0.0.1:1081#Connecting%20Second")
    let first = try XCTUnwrap(group.nodes.first), second = try XCTUnwrap(group.nodes.last)
    try await model.select(first)
    let tunnel = FixtureTunnel(plan: try await model.makePlan(nodeID: first.id))
    tunnel.session.fixtureStatus = .connecting
    model.vpn.manager = tunnel
    try await model.vpn.refreshProvider()
    XCTAssertTrue(model.vpn.active && !model.vpn.connected)
    // setIP publishes through the same path as a subscription refresh.
    do { try await model.setIP(first, value: "ipv4") } catch { XCTAssertEqual(error as? IOSAppError, .busy) }
    tunnel.session.fixtureStatus = .connected
    try await model.vpn.refreshProvider()
    do { try await model.select(second) } catch { XCTFail("A publish refused while connecting left later switches blocked: \(error)") }
    XCTAssertEqual(model.selectedID, second.id)
    await model.disconnect()
    model.vpn.manager = nil
    try await model.delete(group)
  }

  // On Demand starting the tunnel reads as connecting. Saving a setting then must not
  // stop the VPN and drop its plan and On Demand without reconnecting or saying so.
  func testSaveSettingsWhileConnectingKeepsTunnelOrTellsUser() async throws {
    let model = IOSAppModel()
    await model.start()
    let group = try await importLocal(model, "socks://127.0.0.1:1080#Settings%20While%20Connecting")
    let node = try XCTUnwrap(group.nodes.first)
    try await model.select(node)
    let original = model.settings
    var onDemand = original; onDemand.onDemandEnabled = true
    try await model.saveSettings(onDemand)
    let tunnel = FixtureTunnel(plan: try await model.makePlan(nodeID: node.id))
    tunnel.session.fixtureStatus = .disconnected
    tunnel.isOnDemandEnabled = true
    model.vpn.manager = tunnel
    try await model.vpn.refreshProvider()
    await model.connect()
    tunnel.session.fixtureStatus = .connecting
    try await model.vpn.refreshProvider()
    model.notice = nil
    var changed = model.settings; changed.disconnectOnSleep.toggle()
    var failure: Error?
    do { try await model.saveSettings(changed) } catch { failure = error }
    let kept = model.vpn.savedPlan != nil && tunnel.isOnDemandEnabled
    XCTAssertTrue(kept || failure != nil || model.notice != nil,
      "Saving a setting while On Demand connected stopped the VPN, cleared its plan and On Demand, and said nothing")
    await model.disconnect()
    try await model.saveSettings(original)
    model.vpn.manager = nil
    try await model.delete(group)
  }

  // A routing change while iOS is still connecting is refused through the same kind of
  // rollback as a publish, and must not leave later switches refused either.
  func testRoutingChangeWhileConnectingDoesNotBlockLaterSwitch() async throws {
    let model = IOSAppModel()
    await model.start()
    let group = try await importLocal(model, "socks://127.0.0.1:1080#Routing%20First\nsocks://127.0.0.1:1081#Routing%20Second")
    let first = try XCTUnwrap(group.nodes.first), second = try XCTUnwrap(group.nodes.last)
    try await model.select(first)
    let tunnel = FixtureTunnel(plan: try await model.makePlan(nodeID: first.id))
    tunnel.session.fixtureStatus = .connecting
    model.vpn.manager = tunnel
    try await model.vpn.refreshProvider()
    let profile = try JSONSerialization.data(withJSONObject: ["Name": "Routing while connecting", "RemoteDNSType": "DoU",
      "RemoteDNSIP": "1.1.1.1", "DomesticDNSType": "DoU", "DomesticDNSIP": "8.8.8.8", "DirectSites": ["full:direct.example"]])
    do {
      try await model.importInput("happ://routing/onadd/" + profile.base64EncodedString())
      model.reload()
    } catch { XCTAssertEqual(error as? IOSAppError, .busy) }
    tunnel.session.fixtureStatus = .connected
    try await model.vpn.refreshProvider()
    do { try await model.select(second) } catch { XCTFail("A routing change refused while connecting left later switches blocked: \(error)") }
    XCTAssertEqual(model.selectedID, second.id)
    await model.disconnect()
    model.vpn.manager = nil
    try await model.delete(group)
    model.reload()
    for routing in model.routingProfiles where routing.name == "Routing while connecting" {
      try await model.editRouting { _ = try $0.delete(id: routing.id) }
      model.reload()
    }
  }

  // A selection marks the publication, whose rollback restores no routing: a refused
  // routing change must still restore the previous rules.
  func testRefusedRoutingChangeWithASelectionKeepsThePreviousRules() async throws {
    let model = IOSAppModel()
    await model.start()
    let group = try await importLocal(model, "socks://127.0.0.1:1080#Refused%20Routing")
    let node = try XCTUnwrap(group.nodes.first)
    try await model.select(node)
    let tunnel = FixtureTunnel(plan: try await model.makePlan(nodeID: node.id))
    tunnel.session.fixtureStatus = .connecting
    model.vpn.manager = tunnel
    try await model.vpn.refreshProvider()
    let before = model.routingProfiles.map(\.id)
    let profile = try JSONSerialization.data(withJSONObject: ["Name": "Refused routing", "RemoteDNSType": "DoU",
      "RemoteDNSIP": "1.1.1.1", "DomesticDNSType": "DoU", "DomesticDNSIP": "8.8.8.8", "DirectSites": ["full:direct.example"]])
    do {
      try await model.importInput("happ://routing/onadd/" + profile.base64EncodedString())
      XCTFail("a routing change was accepted while iOS was connecting")
    } catch { XCTAssertEqual(error as? IOSAppError, .busy) }
    model.reload()
    XCTAssertEqual(model.routingProfiles.map(\.id), before, "the refused routing change kept its rules")
    tunnel.session.fixtureStatus = .disconnected
    try await model.vpn.refreshProvider()
    model.vpn.manager = nil
    try await model.delete(group)
    model.reload()
    for routing in model.routingProfiles where routing.name == "Refused routing" {
      try await model.editRouting { _ = try $0.delete(id: routing.id) }
      model.reload()
    }
  }

  // Routing data shows each geofile's size, which RoutingStore publishes as Int.
  func testRoutingDataShowsGeofileSizes() async throws {
    let model = IOSAppModel()
    await model.start()
    let group = try await importLocal(model, "socks://127.0.0.1:1080#Geofile%20Sizes")
    try await model.select(try XCTUnwrap(group.nodes.first))
    let profile = try JSONSerialization.data(withJSONObject: ["Name": "Geofile sizes", "RemoteDNSType": "DoU", "RemoteDNSIP": "1.1.1.1",
      "DomesticDNSType": "DoU", "DomesticDNSIP": "8.8.8.8", "DirectSites": ["full:direct.example"]])
    try await model.importInput("happ://routing/onadd/" + profile.base64EncodedString())
    model.reload()
    let routing = try XCTUnwrap(model.routingProfiles.first { $0.name == "Geofile sizes" })
    XCTAssertEqual(routing.geofiles.count, 2)
    for file in routing.geofiles { XCTAssertNotNil(RoutingProfile.bytes(file), "\(file["name"] ?? "geofile") shows no size") }
    try await model.delete(group)
    model.reload()
    for routing in model.routingProfiles where routing.name == "Geofile sizes" {
      try await model.editRouting { _ = try $0.delete(id: routing.id) }
      model.reload()
    }
  }

  // A chained full profile dials its entry server. Direct TCP must measure that
  // server, not the exit the entry relays to.
  func testDirectTCPProbesTheEntryOfAChainedProfile() async throws {
    let queue = DispatchQueue(label: "ios-chained-probe-fixture")
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    let server = try NWListener(using: parameters)
    let connections = ProbeConnections()
    server.newConnectionHandler = { peer in connections.all.append(peer); peer.start(queue: queue) }
    let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
      server.stateUpdateHandler = { state in
        switch state {
        case .ready: server.stateUpdateHandler = nil; continuation.resume(returning: server.port!.rawValue)
        case .failed(let error): server.stateUpdateHandler = nil; continuation.resume(throwing: error)
        default: break
        }
      }
      server.start(queue: queue)
    }
    defer { queue.sync { connections.all.forEach { $0.cancel() }; server.cancel() } }
    func outbound(_ tag: String, _ address: String, _ port: Int) -> [String: Any] {
      ["tag": tag, "protocol": "vless", "settings": ["address": address, "port": port,
        "id": "00000000-0000-4000-8000-000000000001", "encryption": "none"],
       "streamSettings": ["network": "raw", "security": "tls", "tlsSettings": ["serverName": "peer.example.com"]]]
    }
    var exit = outbound("proxy", "192.0.2.1", 443)
    exit["proxySettings"] = ["tag": "entry"]
    let model = IOSAppModel()
    await model.start()
    let group = try await importLocal(model, prettyJSON(["remarks": "Chained probe", "outbounds": [exit, outbound("entry", "127.0.0.1", Int(port))]]))
    let node = try XCTUnwrap(group.nodes.first)
    let previous = model.preferences
    defer { model.cancelTests(); try? model.savePreferences(previous) }
    var preferences = previous
    preferences.probeMode = "tcp"; preferences.probeTimeout = 5
    try model.savePreferences(preferences)
    let started = ProcessInfo.processInfo.systemUptime
    model.testServers([node])
    while model.probes[node.id] == nil && ProcessInfo.processInfo.systemUptime - started < 12 {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertEqual(model.probes[node.id]?.status, "Passed", "Direct TCP measured the exit behind the entry server")
    try await model.delete(group)
  }

  // Pull to refresh refreshes each subscription in turn. One that needs approval
  // keeps its prompt when a later one succeeds.
  func testLaterRefreshKeepsAPendingApproval() async throws {
    let feed = try await serveFeed()
    defer { feed.stop() }
    let model = IOSAppModel()
    await model.start()
    let existing = Set(model.subscriptions.map(\.id))
    defer { model.approval = nil }
    try await model.importInput("http://127.0.0.1:\(feed.port)/pending")
    let pending = try XCTUnwrap(model.approval?.subscriptionID)
    model.approval = nil
    try await model.importInput("http://127.0.0.1:\(feed.port)/approved")
    let first = try XCTUnwrap(model.approval)
    try await model.refresh(first.subscriptionID, challenge: first.challenge)
    XCTAssertNil(model.approval)
    try await model.refresh(pending)
    XCTAssertEqual(model.approval?.subscriptionID, pending)
    try await model.refresh(first.subscriptionID)
    XCTAssertEqual(model.approval?.subscriptionID, pending, "a later success hid the pending approval")
    model.reload()
    for source in model.subscriptions where !existing.contains(source.id) { try await model.delete(source) }
  }

  // A failed refresh names its provider and the cause, so provider outages are not reported as app bugs.
  func testFailedRefreshNamesTheProvider() async throws {
    let feed = try await serveFeed()
    defer { feed.stop() }
    let model = IOSAppModel()
    await model.start()
    let existing = Set(model.subscriptions.map(\.id))
    defer { model.approval = nil }
    try await model.importInput("http://127.0.0.1:\(feed.port)/flaky")
    for _ in 0..<2 {
      guard let warning = model.approval else { break }
      try await model.refresh(warning.subscriptionID, challenge: warning.challenge)
    }
    model.reload()
    let source = try XCTUnwrap(model.subscriptions.first { !existing.contains($0.id) })
    XCTAssertEqual(source.name, "Northwind")
    feed.fail()
    do { try await model.refresh(source.id); XCTFail("the failing refresh succeeded") }
    catch {
      XCTAssertEqual(error.localizedDescription, "Northwind’s server reported an error. Nothing is wrong with Elarni or this device; retry later. The last working servers were kept.")
    }
    model.reload()
    XCTAssertEqual(model.subscriptions.first { $0.id == source.id }?.nodes.count, 1, "the last working servers were not kept")
    for source in model.subscriptions where !existing.contains(source.id) { try await model.delete(source) }
  }

  // A provider that drops the connected server hands over to its next one instead of disconnecting.
  func testProviderDroppingTheConnectedServerFallsBackToTheNextOne() async throws {
    let feed = try await serveFeed()
    defer { feed.stop() }
    let model = IOSAppModel()
    await model.start()
    let existing = Set(model.subscriptions.map(\.id))
    defer { model.approval = nil }
    try await model.importInput("http://127.0.0.1:\(feed.port)/shrink")
    for _ in 0..<2 {
      guard let warning = model.approval else { break }
      try await model.refresh(warning.subscriptionID, challenge: warning.challenge)
    }
    model.reload()
    let source = try XCTUnwrap(model.subscriptions.first { !existing.contains($0.id) })
    let first = try XCTUnwrap(source.nodes.first { $0.name == "Shrink First" })
    let second = try XCTUnwrap(source.nodes.first { $0.name == "Shrink Second" })
    try await model.select(first)
    model.vpn.manager = FixtureTunnel(plan: try await model.makePlan(nodeID: first.id))
    try await model.vpn.refreshProvider()
    feed.fail()
    try await model.refresh(source.id)
    model.reload()
    XCTAssertEqual(model.selectedID, second.id, "the tunnel did not fall back to the provider's next server")
    let plan = try await model.makePlan(nodeID: second.id)
    XCTAssertEqual(model.vpn.savedPlan, plan)
    XCTAssertEqual(model.notice, "Shrink First is gone from \(source.name). Connected to Shrink Second.")
    model.notice = nil
    await model.disconnect()
    model.vpn.manager = nil
    for source in model.subscriptions where !existing.contains(source.id) { try await model.delete(source) }
  }

  // A provider's server the user hides stays out after a refresh and can be shown again.
  func testHiddenProviderServerStaysHiddenAndCanBeShownAgain() async throws {
    let feed = try await serveFeed()
    defer { feed.stop() }
    let model = IOSAppModel()
    await model.start()
    let existing = Set(model.subscriptions.map(\.id))
    defer { model.approval = nil }
    try await model.importInput("http://127.0.0.1:\(feed.port)/shrink")
    for _ in 0..<2 {
      guard let warning = model.approval else { break }
      try await model.refresh(warning.subscriptionID, challenge: warning.challenge)
    }
    model.reload()
    let source = try XCTUnwrap(model.subscriptions.first { !existing.contains($0.id) })
    let first = try XCTUnwrap(source.nodes.first { $0.name == "Shrink First" })
    let second = try XCTUnwrap(source.nodes.first { $0.name == "Shrink Second" })
    try await model.select(first)
    try model.deleteNode(second)
    try await model.refresh(source.id)
    model.reload()
    let refreshed = try XCTUnwrap(model.subscriptions.first { $0.id == source.id })
    XCTAssertEqual(refreshed.nodes.map(\.name), ["Shrink First"], "a refresh added a hidden server back")
    XCTAssertEqual(refreshed.hiddenNodes.map(\.name), ["Shrink Second"])
    try model.showNode(id: second.id)
    model.reload()
    XCTAssertEqual(model.subscriptions.first { $0.id == source.id }?.nodes.map(\.name), ["Shrink First", "Shrink Second"])
    for source in model.subscriptions where !existing.contains(source.id) { try await model.delete(source) }
  }

  // The device ID a subscription shows is the X-HWID its refresh sends. A reset
  // changes only that subscription's ID, and its next refresh sends the new one.
  func testDeviceIDIsTheOneSentAndResetsOnlyItsSubscription() async throws {
    let feed = try await serveFeed()
    defer { feed.stop() }
    let model = IOSAppModel()
    await model.start()
    let existing = Set(model.subscriptions.map(\.id))
    defer { model.approval = nil }
    var added: [String] = []
    for path in ["/hwid-a", "/hwid-b"] {
      try await model.importInput("http://127.0.0.1:\(feed.port)\(path)")
      for _ in 0..<2 {
        guard let warning = model.approval else { break }
        try await model.refresh(warning.subscriptionID, challenge: warning.challenge)
      }
      model.reload()
      added.append(try XCTUnwrap(model.subscriptions.first { !existing.contains($0.id) && !added.contains($0.id) }).id)
    }
    let before = try model.deviceID(subscriptionID: added[0])
    XCTAssertEqual(before.count, 64)
    XCTAssertEqual(feed.hwid("/hwid-a"), before, "the shown ID is not the one the provider got")
    XCTAssertEqual(try model.deviceID(subscriptionID: added[1]), before, "one origin got two IDs")
    try model.resetDeviceID(subscriptionID: added[0])
    let after = try model.deviceID(subscriptionID: added[0])
    XCTAssertNotEqual(after, before)
    XCTAssertEqual(try model.deviceID(subscriptionID: added[1]), before, "a reset changed another subscription's ID")
    try await model.refresh(added[0])
    try await model.refresh(added[1])
    XCTAssertEqual(feed.hwid("/hwid-a"), after)
    XCTAssertEqual(feed.hwid("/hwid-b"), before)
    for source in model.subscriptions where !existing.contains(source.id) { try await model.delete(source) }
  }

  // The approval prompt's Continue sends only the challenge. The refresh it answers
  // must still use the download format that asked for approval.
  func testApprovalKeepsTheRequestedFormat() async throws {
    let feed = try await serveFeed()
    defer { feed.stop() }
    let model = IOSAppModel()
    await model.start()
    let existing = Set(model.subscriptions.map(\.id))
    defer { model.approval = nil }
    try await model.importInput("http://127.0.0.1:\(feed.port)/meta")
    // The feed and its info link each need approval once.
    for _ in 0..<2 {
      let warning = try XCTUnwrap(model.approval)
      try await model.refresh(warning.subscriptionID, challenge: warning.challenge)
    }
    XCTAssertNil(model.approval)
    model.reload()
    let id = try XCTUnwrap(model.subscriptions.first { !existing.contains($0.id) }?.id)
    try await model.refresh(id, format: "raw")
    let warning = try XCTUnwrap(model.approval, "the raw link needs its own approval")
    try await model.refresh(warning.subscriptionID, challenge: warning.challenge)
    model.reload()
    XCTAssertEqual(model.subscriptions.first { $0.id == id }?.format, "raw", "the approved refresh fell back to the previous format")
    for source in model.subscriptions where !existing.contains(source.id) { try await model.delete(source) }
  }

  // A stored profile keeps an empty current DNS key beside the legacy one it was
  // imported with. The editor must show the legacy address, not an empty field.
  func testRoutingEditorShowsALegacyRemoteDNSAddress() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ios-legacy-dns-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let routing = try RoutingStore(directory: directory)
    try routing.importProvider(#"{"Name":"Legacy DNS","RemoteDNSType":"DoU","RemoteDns":"8.8.8.8","DomesticDNSType":"DoU","DomesticDNSIP":"1.1.1.1"}"#,
      subscriptionID: "fixture")
    let profile = RoutingProfile(raw: try XCTUnwrap((routing.snapshot()["profiles"] as? [[String: Any]])?.first))
    XCTAssertEqual(RoutingEditor.draft(profile)["RemoteDNSIP"] as? String, "8.8.8.8")
    XCTAssertEqual(RoutingEditor.draft(profile)["DomesticDNSIP"] as? String, "1.1.1.1")
  }

  // Deleting a provider removes its routing profile, also where another subscription
  // uses it. The running tunnel and its saved plan must not keep the deleted rules.
  func testDeletingAProviderUpdatesTheTunnelThatUsedItsRouting() async throws {
    let model = IOSAppModel()
    await model.start()
    let provider = try await importLocal(model, "socks://127.0.0.1:1080#Routing%20Provider")
    // A hidden import keeps its own group, so the user is another subscription.
    let existing = Set(model.subscriptions.map(\.id))
    try await model.importInput("#hide-url: yes\nsocks://127.0.0.1:1081#Routing%20User")
    let user = try XCTUnwrap(model.subscriptions.first { !existing.contains($0.id) })
    let node = try XCTUnwrap(user.nodes.first)
    try await model.select(node)
    let rules = #"{"Name":"Provider routing","RemoteDNSType":"DoU","RemoteDNSIP":"1.1.1.1","DomesticDNSType":"DoU","DomesticDNSIP":"8.8.8.8","DirectSites":["full:direct.example"]}"#
    try await model.editRouting { routing in
      try routing.importProvider(rules, subscriptionID: provider.id)
      let id = try XCTUnwrap((routing.snapshot()["assignments"] as? [String: String])?[provider.id])
      _ = try routing.assign(subscriptionID: user.id, profileID: id)
    }
    let routed = try await model.makePlan(nodeID: node.id)
    let tunnel = FixtureTunnel(plan: routed)
    model.vpn.manager = tunnel
    try await model.vpn.refreshProvider()
    try await model.delete(provider)
    let current = try await model.makePlan(nodeID: node.id)
    XCTAssertNotEqual(routed, current)
    XCTAssertEqual(model.vpn.savedPlan, current, "the tunnel kept the deleted provider's routing")
    await model.disconnect()
    model.vpn.manager = nil
    try await model.delete(user)
  }

  // Local imports join one local group, which an earlier run may have left behind.
  // Starting without it gives the test a group that holds only its own servers.
  private func importLocal(_ model: IOSAppModel, _ input: String) async throws -> ServerSubscription {
    for source in model.subscriptions where source.local { try await model.delete(source) }
    let existing = Set(model.subscriptions.map(\.id))
    try await model.importInput(input)
    return try XCTUnwrap(model.subscriptions.first { !existing.contains($0.id) })
  }

  // Loopback HTTP needs approval once per URL. A "/meta" feed advertises a raw-format
  // link through its info response.
  private func serveFeed() async throws -> (port: UInt16, stop: () -> Void, fail: () -> Void, hwid: (String) -> String?) {
    let queue = DispatchQueue(label: "ios-feed-fixture")
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    let server = try NWListener(using: parameters)
    let connections = ProbeConnections()
    server.newConnectionHandler = { peer in
      connections.all.append(peer); peer.start(queue: queue)
      peer.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
        guard let data else { return }
        let request = String(decoding: data, as: UTF8.self)
        let lines = request.components(separatedBy: "\r\n")
        if let path = lines.first?.split(separator: " ").dropFirst().first,
           let hwid = lines.first(where: { $0.lowercased().hasPrefix("x-hwid:") }) {
          connections.hwids[String(path)] = hwid.dropFirst("x-hwid:".count).trimmingCharacters(in: .whitespaces)
        }
        var headers = "Connection: close\r\n", body = "socks://127.0.0.1:1080#Feed%20Fixture\n"
        if request.contains("/flaky") && connections.failing {
          peer.send(content: Data("HTTP/1.1 503 Service Unavailable\r\n\(headers)Content-Length: 0\r\n\r\n".utf8),
            completion: .contentProcessed { _ in peer.cancel() })
          return
        } else if request.contains("/flaky") {
          headers += "Profile-Title: Northwind\r\n"
        } else if request.contains("/shrink") {
          body = (connections.failing ? "" : "socks://127.0.0.1:1080#Shrink%20First\n") + "socks://127.0.0.1:1081#Shrink%20Second\n"
        } else if request.contains("format=info") {
          body = #"{"sId":"fixture","enabled":true,"subUrl":"http://127.0.0.1:\#(connections.port)/raw"}"#
        } else if request.contains("/meta") {
          headers += "Subscription-Userinfo: upload=0; download=0; total=0; expire=0\r\n"
        }
        peer.send(content: Data("HTTP/1.1 200 OK\r\n\(headers)Content-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8),
          completion: .contentProcessed { _ in peer.cancel() })
      }
    }
    connections.port = try await withCheckedThrowingContinuation { continuation in
      server.stateUpdateHandler = { state in
        switch state {
        case .ready: server.stateUpdateHandler = nil; continuation.resume(returning: server.port!.rawValue)
        case .failed(let error): server.stateUpdateHandler = nil; continuation.resume(throwing: error)
        default: break
        }
      }
      server.start(queue: queue)
    }
    return (connections.port, { queue.sync { connections.all.forEach { $0.cancel() }; server.cancel() } }, { queue.sync { connections.failing = true } },
            { path in queue.sync { connections.hwids[path] } })
  }
}

// A geosite.dat holding one category of domain rules.
private func fixtureGeosite(category: String, count: Int) -> Data {
  func field(_ tag: UInt8, _ body: [UInt8]) -> [UInt8] {
    var length = body.count, varint: [UInt8] = []
    while length >= 0x80 { varint.append(UInt8(length & 0x7f | 0x80)); length >>= 7 }
    return [tag] + varint + [UInt8(length)] + body
  }
  var site = field(0x0a, Array(category.utf8))
  for index in 0..<count {
    // Domain{type: Domain, value}; the real list averages 16 characters a name.
    site += field(0x12, [0x08, 0x02] + field(0x12, Array(String(format: "ads%05d.example", index).utf8)))
  }
  return Data(field(0x0a, site))
}

// A self-signed P-256 certificate, its PKCS#8 key and its SHA-256 pin.
private func fixtureCertificate() throws -> (certificate: String, key: String, pin: String) {
  let key = P256.Signing.PrivateKey()
  func der(_ tag: UInt8, _ body: [UInt8]) -> [UInt8] {
    let count = body.count
    return [tag] + (count < 0x80 ? [UInt8(count)] : count < 0x100 ? [0x81, UInt8(count)] : [0x82, UInt8(count >> 8), UInt8(count & 0xff)]) + body
  }
  let ecdsaSHA256 = der(0x30, [0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02])
  let name = der(0x30, der(0x31, der(0x30, [0x06, 0x03, 0x55, 0x04, 0x03] + der(0x0c, Array("fixture".utf8)))))
  let validity = der(0x30, der(0x17, Array("250101000000Z".utf8)) + der(0x17, Array("491231000000Z".utf8)))
  let tbs = der(0x30, der(0xa0, der(0x02, [2])) + der(0x02, [1]) + ecdsaSHA256 + name + validity + name +
    Array(key.publicKey.derRepresentation))
  let signature = try key.signature(for: Data(tbs)).derRepresentation
  let certificate = Data(der(0x30, tbs + ecdsaSHA256 + der(0x03, [0] + Array(signature))))
  let pem = "-----BEGIN CERTIFICATE-----\n" +
    certificate.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed]) + "\n-----END CERTIFICATE-----"
  return (pem, key.pemRepresentation, SHA256.hash(data: certificate).map { String(format: "%02x", $0) }.joined())
}

private final class ProbeConnections: @unchecked Sendable {
  var all: [NWConnection] = []
  var waiting: [NWConnection] = []
  var port: UInt16 = 0
  var failing = false
  var received = 0
  var hwids: [String: String] = [:]
  // Reads until the peer closes, counting the bytes; call on the connections' queue.
  func drain(_ peer: NWConnection) {
    peer.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
      self.received += data?.count ?? 0
      if !done && error == nil { self.drain(peer) }
    }
  }
}

// Every OS preference call is overridden; the fixture never saves a VPN profile.
private final class FixtureTunnel: NETunnelProviderManager {
  let session = FixtureSession()
  init(plan: Data) { super.init(); setPlan(plan) }
  required init?(coder: NSCoder) { fatalError("unused fixture initializer") }
  func setPlan(_ plan: Data) {
    let tunnel = NETunnelProviderProtocol()
    tunnel.providerConfiguration = ["planPayload": plan]
    protocolConfiguration = tunnel
  }
  override var connection: NEVPNConnection { session }
  override func saveToPreferences(completionHandler: ((Error?) -> Void)? = nil) { completionHandler?(nil) }
  override func loadFromPreferences(completionHandler: @escaping (Error?) -> Void) { completionHandler(nil) }
}

private final class FixtureSession: NETunnelProviderSession {
  var fixtureStatus = NEVPNStatus.connected
  var reply = "switched"
  var liveness: String?
  var switches = 0
  var logReads: [Int] = []
  override var status: NEVPNStatus { fixtureStatus }
  override var connectedDate: Date? { nil }
  override func stopVPNTunnel() { fixtureStatus = .disconnected }
  override func sendProviderMessage(_ messageData: Data, responseHandler: ((Data?) -> Void)? = nil) throws {
    var response: [String: Any] = ["state": "connected", "liveness": liveness.map { $0 as Any } ?? NSNull()]
    if let request = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any], request["operation"] as? String == "switch" {
      switches += 1
      response = ["code": reply, "digest": (request["envelope"] as? [String: Any])?["digest"] ?? ""]
    } else if let request = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any], request["operation"] as? String == "logs" {
      let after = request["after"] as? Int ?? 0
      logReads.append(after)
      response = ["level": "debug", "last": after + 1, "entries": [["seq": after + 1, "time": 1_700_000_000_000, "level": "info", "text": "fixture"]]]
    }
    responseHandler?(try JSONSerialization.data(withJSONObject: response))
  }
}

@MainActor
private final class CatalogFixture {
  let directory: URL
  var secrets: [String: Data] = [:]
  init() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("ios-catalog-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }
  func remove() { try? FileManager.default.removeItem(at: directory) }
  func store() throws -> SubscriptionStore {
    func account(_ query: CFDictionary) -> String { (query as NSDictionary)[kSecAttrAccount] as? String ?? "" }
    let access = SubscriptionSecretAccess(
      add: { [self] query, _ in
        let key = account(query)
        guard secrets[key] == nil else { return errSecDuplicateItem }
        secrets[key] = (query as NSDictionary)[kSecValueData] as? Data
        return errSecSuccess
      }, copy: { [self] query, result in
        guard let value = secrets[account(query)] else { return errSecItemNotFound }
        result?.pointee = value as CFData
        return errSecSuccess
      }, update: { [self] query, attributes in
        let key = account(query)
        guard secrets[key] != nil else { return errSecItemNotFound }
        secrets[key] = (attributes as NSDictionary)[kSecValueData] as? Data
        return errSecSuccess
      }, delete: { [self] query in
        secrets.removeValue(forKey: account(query)) == nil ? errSecItemNotFound : errSecSuccess
      }, accessGroup: { "fixture.ios.shared" })
    let routing = try RoutingStore(directory: directory.appendingPathComponent("Routing"))
    let store = try SubscriptionStore(directory: directory, routing: routing, secretAccess: access)
    store.publishRefresh = { [weak store] candidate in
      guard let store else { throw SubscriptionError.invalidState }
      _ = try store.beginPublication(candidate)
      try store.finishPublication(candidate)
    }
    return store
  }
}
