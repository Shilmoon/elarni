import Foundation
import CoreImage
import Security

@main
@MainActor
struct SubscriptionChecks {
  struct Failure: Error { let message: String }

  static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw Failure(message: message) }
  }

  static func main() async {
    do { try await run() }
    catch let failure as Failure {
      fputs("FAIL \(failure.message)\n", stderr)
      exit(1)
    } catch {
      // Network and converter errors can include credentials. Never print them.
      fputs("FAIL subscription check failed (details withheld)\n", stderr)
      exit(1)
    }
  }

  static func run() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("elarni-subscription-checks-\(UUID())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let routing = try RoutingStore(directory: directory.appendingPathComponent("routing"))
    let store = try SubscriptionStore(directory: directory, routing: routing)
    let vless = "vless://00000000-0000-4000-8000-000000000001@192.0.2.1:443?encryption=none&security=tls&sni=example.com&type=tcp#Test"
    let hy2 = "hysteria2://fixture-password@192.0.2.2:443?sni=example.com#Hysteria"
    let feed = "# provider comment\n\(vless)\nincy://settings/ignored-provider-metadata\n\(hy2)\n"
    var passed = 0
    passed += try routingRefreshChecks(directory: directory.appendingPathComponent("routing-refresh"))
    passed += try await routingAssetChecks(directory: directory.appendingPathComponent("routing-assets"))
    passed += try await missingGeodataChecks(directory: directory.appendingPathComponent("routing-missing-geodata"))
    passed += try await externalGeodataChecks(directory: directory.appendingPathComponent("routing-external-geodata"))
    func check(_ name: String, _ body: () throws -> Void) throws {
      try body()
      passed += 1
      print("PASS \(name)")
    }

    // Force atomic replacement to fail without permissions assumptions. Only
    // these disposable fixture files are moved, and the original bytes survive.
    func blockedPublication(_ url: URL, _ body: () throws -> Void) throws {
      let saved = url.appendingPathExtension("saved")
      try FileManager.default.moveItem(at: url, to: saved)
      defer {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.moveItem(at: saved, to: url)
      }
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
      do {
        try body()
        throw Failure(message: "blocked catalog publication succeeded")
      } catch let error as NSError where error.domain == NSCocoaErrorDomain { }
    }

    try check("failed subscription rename preserves memory, disk and later publication") {
      let root = directory.appendingPathComponent("rename-failure")
      let secrets = MemorySecrets()
      let candidate = try SubscriptionStore(directory: root,
        routing: RoutingStore(directory: root.appendingPathComponent("routing")), secretAccess: secrets.access())
      candidate.now = { Date(timeIntervalSince1970: 1_700_000_000) }
      let id = try candidate.register(urlText: "https://example.org/fixture")
      _ = try candidate.rename(id: id, name: "Original")
      let original = candidate.snapshot() as NSDictionary
      let file = root.appendingPathComponent("subscriptions-v1.json")
      let bytes = try Data(contentsOf: file)
      try blockedPublication(file) { _ = try candidate.rename(id: id, name: "Rejected") }
      try expect((candidate.snapshot() as NSDictionary).isEqual(original), "failed rename changed memory")
      try expect(Data(contentsOf: file) == bytes, "failed rename changed disk")
      _ = try candidate.register(urlText: "https://example.org/another-fixture")
      let reopened = try SubscriptionStore(directory: root,
        routing: RoutingStore(directory: root.appendingPathComponent("routing")), secretAccess: secrets.access())
      let groups = reopened.snapshot()["subscriptions"] as! [[String: Any]]
      try expect(groups.first { $0["id"] as? String == id }?["name"] as? String == "Original",
        "later save committed a rejected rename")
    }

    try check("a subscription whose source is gone does not block adding another") {
      // Secrets stay on their device, so a restored catalog can name sources the Keychain lacks.
      let root = directory.appendingPathComponent("missing-source")
      let secrets = MemorySecrets()
      let candidate = try SubscriptionStore(directory: root,
        routing: RoutingStore(directory: root.appendingPathComponent("routing")), secretAccess: secrets.access())
      let restored = try candidate.register(urlText: "https://example.org/restored")
      secrets.values.removeValue(forKey: "true:subscription.\(restored).source")
      let added = try candidate.register(urlText: "https://example.org/added")
      try expect(added != restored, "the new URL matched the unreadable subscription")
      try expect(candidate.register(urlText: "https://example.org/added") == added, "a readable duplicate was added again")
    }

    try check("bulk tests run at most two probes per SNI, keyed by the name the handshake sends") {
      func key(_ outbound: [String: Any]) throws -> String? { probeKey(outbound: try JSONSerialization.data(withJSONObject: outbound)) }
      try expect(key(["protocol": "vless", "settings": ["address": "192.0.2.1"],
        "streamSettings": ["security": "reality", "realitySettings": ["serverName": "Shared.Example"]]]) == "shared.example",
        "the REALITY server name is not the probe key")
      try expect(key(["outbounds": [["protocol": "vmess", "settings": ["vnext": [["address": "Address.Example"]]],
        "streamSettings": ["security": "tls"]]]]) == "address.example", "TLS without a name did not key by its address")
      try expect(key(["protocol": "vless", "settings": ["address": "192.0.2.3"]]) == nil, "a plain server got an SNI key")
      var lanes = ProbeLanes(Array(0..<8)) { $0 < 6 ? "shared" : "other" }
      var started: [Int] = []
      while let next = lanes.next() { started.append(next.item) }
      try expect(started == [0, 1, 6, 7], "more than two probes shared one SNI")
      lanes.finish("shared")
      try expect(lanes.next()?.item == 2 && lanes.next() == nil, "a finished probe did not free its SNI")
    }
    try check("an undecodable base64 profile title is not shown") {
      try expect(decodedProfileTitle("base64:%%%") == nil, "the raw base64 header became the provider name")
      try expect(decodedProfileTitle(" base64:" + Data("Provider".utf8).base64EncodedString()) == "Provider", "an encoded title was lost")
      try expect(decodedProfileTitle(" Plain title ") == "Plain title", "a plain title was lost")
      // Unpadded base64url, which Happ-style panels also send.
      let urlSafe = Data("Провайдер ✓?>!".utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
      try expect(decodedProfileTitle("base64:" + urlSafe) == "Провайдер ✓?>!", "an unpadded base64url title was lost")
      try expect(ProviderMetadata.display("base64:" + urlSafe) == "Провайдер ✓?>!", "an unpadded base64url announcement was lost")
    }

    try check("failed routing duplicate preserves memory, disk and retry") {
      let root = directory.appendingPathComponent("duplicate-failure")
      let routes = try RoutingStore(directory: root)
      try routes.importProvider(#"{"Name":"Original","RemoteDNSType":"DoU","RemoteDNSIP":"1.1.1.1","DomesticDNSType":"DoU","DomesticDNSIP":"8.8.8.8"}"#,
        subscriptionID: "fixture")
      let id = (routes.snapshot()["assignments"] as! [String: String])["fixture"]!
      let original = routes.snapshot() as NSDictionary
      let file = root.appendingPathComponent("routing-v1.json")
      let bytes = try Data(contentsOf: file)
      try blockedPublication(file) { _ = try routes.duplicate(id: id) }
      try expect((routes.snapshot() as NSDictionary).isEqual(original), "failed duplicate left a ghost profile")
      try expect(Data(contentsOf: file) == bytes, "failed duplicate changed disk")
      _ = try routes.duplicate(id: id)
      let reopened = try RoutingStore(directory: root)
      try expect((reopened.snapshot()["profiles"] as! [[String: Any]]).count == 2,
        "retry persisted the rejected duplicate")
    }

    let cancelledScan = Task { @MainActor in try await CameraQRScanner().scan() }
    cancelledScan.cancel()
    do {
      _ = try await cancelledScan.value
      throw Failure(message: "cancelled camera scan succeeded")
    } catch is CancellationError { }
    passed += 1
    print("PASS cancelled camera scan does not request access or start capture")

    try check("camera video frames decode QR without camera metadata and ignore blank frames") {
      let size = 512
      var buffer: CVPixelBuffer?
      try expect(CVPixelBufferCreate(kCFAllocatorDefault, size, size,
        kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess, "camera fixture allocation")
      guard let buffer else { throw Failure(message: "camera fixture buffer missing") }
      let context = CIContext()
      let background = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
      context.render(background, to: buffer)
      try expect(CameraQRScanner.decodeFrame(buffer) == nil, "blank camera frame ended scanning")
      let generator = CIFilter(name: "CIQRCodeGenerator")!
      generator.setValue(Data(vless.utf8), forKey: "inputMessage")
      let qr = generator.outputImage!.transformed(by: CGAffineTransform(scaleX: 6, y: 6))
      let centered = qr.transformed(by: CGAffineTransform(
        translationX: (CGFloat(size) - qr.extent.width) / 2,
        y: (CGFloat(size) - qr.extent.height) / 2))
      context.render(centered.composited(over: background), to: buffer)
      try expect(CameraQRScanner.decodeFrame(buffer) == vless, "camera QR payload changed")
    }

    try check("a routing choice the user made outlasts the provider's directives") {
      let routeDirectory = directory.appendingPathComponent("routing-manual")
      let routes = try RoutingStore(directory: routeDirectory)
      let provider = #"{"Name":"Provider fixture","RemoteDNSType":"DoU","RemoteDNSIP":"1.1.1.1","DomesticDNSType":"DoU","DomesticDNSIP":"8.8.8.8"}"#
      let user = #"{"Name":"User fixture","RemoteDNSType":"DoU","RemoteDNSIP":"9.9.9.9","DomesticDNSType":"DoU","DomesticDNSIP":"8.8.8.8"}"#
      try routes.importProvider(provider, subscriptionID: "chosen")
      try routes.importProvider(provider, subscriptionID: "followed")
      let mine = (try routes.importContent(user, selectedSubscriptionID: nil)["profiles"] as! [[String: Any]])
        .first { $0["name"] as? String == "User fixture" }!["id"] as! String
      _ = try routes.assign(subscriptionID: "chosen", profileID: mine)
      _ = try routes.assign(subscriptionID: "cleared", profileID: nil)
      for subscription in ["chosen", "followed", "cleared"] { try routes.importProvider("happ://routing/off", subscriptionID: subscription) }
      try routes.importProvider(provider, subscriptionID: "cleared")
      let reloaded = try RoutingStore(directory: routeDirectory)
      try expect(reloaded.snapshot()["assignments"] as? [String: String] == ["chosen": mine],
        "the provider's routing directives replaced the user's choice, or a followed subscription kept its routing")
      try expect(reloaded.isManual(subscriptionID: "chosen") && !reloaded.isManual(subscriptionID: "followed"), "the user's choice was not recorded")
      try reloaded.removeSubscription(id: "chosen")
      try expect(!reloaded.isManual(subscriptionID: "chosen"), "a deleted subscription kept the user's choice")
    }

    try check("assigned routing deletion persists detachment and supports rollback") {
      let routeDirectory = directory.appendingPathComponent("routing-delete")
      let routes = try RoutingStore(directory: routeDirectory)
      let content = #"{"Name":"Delete fixture","RemoteDNSType":"DoU","RemoteDNSIP":"1.1.1.1","DomesticDNSType":"DoU","DomesticDNSIP":"8.8.8.8","DirectSites":["full:example.com"]}"#
      try routes.importProvider(content, subscriptionID: "first")
      let id = (routes.snapshot()["assignments"] as! [String: String])["first"]!
      _ = try routes.assign(subscriptionID: "second", profileID: id)
      let copies = try routes.duplicate(id: id)["profiles"] as! [[String: Any]]
      let keptID = copies.first { $0["id"] as? String != id }!["id"] as! String
      _ = try routes.assign(subscriptionID: "unrelated", profileID: keptID)
      let original = routes.snapshot() as NSDictionary
      let revision = try routes.runtimeRevision(subscriptionID: "first")!.digest
      let checkpoint = try routes.checkpoint()

      let deleted = try routes.delete(id: id)
      try expect((deleted["profiles"] as! [[String: Any]]).map { $0["id"] as! String } == [keptID], "deletion removed an unrelated profile")
      try expect(deleted["assignments"] as? [String: String] == ["unrelated": keptID], "deletion retained assignments or detached an unrelated profile")
      try expect(routes.runtimeRevision(subscriptionID: "first") == nil && routes.runtimeRevision(subscriptionID: "second") == nil, "deleted routing is still active")
      try expect(routes.runtimeRevision(subscriptionID: "unrelated")?.digest == revision, "deletion changed unrelated runtime routing")
      let reloaded = try RoutingStore(directory: routeDirectory)
      try expect((reloaded.snapshot() as NSDictionary).isEqual(deleted), "deleted routing reappeared after relaunch")

      try reloaded.restore(checkpoint)
      try expect((reloaded.snapshot() as NSDictionary).isEqual(original), "rollback lost the deleted profile or its assignments")
      try expect(reloaded.runtimeRevision(subscriptionID: "first")?.digest == revision, "rollback did not restore runtime routing")
      do {
        _ = try reloaded.delete(id: "missing")
        throw Failure(message: "unknown routing profile deletion succeeded")
      } catch RoutingStoreError.notFound { }
      try expect((reloaded.snapshot() as NSDictionary).isEqual(original), "unknown deletion changed routing")
    }

    try check("plaintext subscription accepts companion metadata") {
      let nodes = try store.parseFeed(Data(feed.utf8))
      try expect(nodes.map(\.protocolName) == ["VLESS", "Hysteria2"], "mixed feed node count/protocols")
    }
    try check("base64 subscription accepts companion metadata") {
      let nodes = try store.parseFeed(Data(feed.utf8).base64EncodedData())
      try expect(nodes.map(\.protocolName) == ["VLESS", "Hysteria2"], "base64 mixed feed node count/protocols")
    }
    try check("INCY wrappers and crypt1 use the shared importer without exposing source URLs") {
      let wrapped = "incy://import/" + Data(vless.utf8).base64EncodedString()
      try expect(store.parseFeed(Data(wrapped.utf8)).first?.name == "Test", "INCY wrapper profile")
      let wire = "incy://crypt1/AAECAwQFBgcICQoLNyIQL3rDwRZqnyoD8pGKSLXP6o8NdSXQVSSALNbbUyIr__tWGFUexdIfKvvmDnuDGbmBvuppfNef6aKNZUwOm4c-Sg"
      let normalized = try store.normalizeClientInput(wire)
      try expect(normalized.text == "https://sub.example.com/test-vector" && normalized.shareLink == wire, "crypt1 source preservation")
    }
    try check("VLESS TLS conversion preserves endpoint and credentials") {
      let node = try store.parseFeed(Data(vless.utf8))[0]
      let profile = try JSONSerialization.jsonObject(with: node.outbound) as! [String: Any]
      try expect(node.format == "xrayProfile", "complete profile format")
      let outbound = (profile["outbounds"] as! [[String: Any]])[0]
      let settings = outbound["settings"] as! [String: Any]
      let stream = outbound["streamSettings"] as! [String: Any]
      let tls = stream["tlsSettings"] as! [String: Any]
      try expect(settings["address"] as? String == "192.0.2.1", "VLESS server")
      try expect(settings["port"] as? Int == 443, "VLESS port")
      try expect(settings["id"] as? String == "00000000-0000-4000-8000-000000000001", "VLESS UUID")
      try expect(settings["encryption"] as? String == "none", "VLESS encryption")
      try expect(stream["security"] as? String == "tls", "VLESS security")
      try expect(tls["serverName"] as? String == "example.com", "VLESS SNI")
    }
    try check("metadata cannot hide a malformed supported proxy link") {
      for broken in ["vless://", "hysteria2://"] {
        let input = Data("\(feed)\(broken)\n".utf8).base64EncodedData()
        do {
          _ = try store.parseFeed(input)
          throw Failure(message: "malformed supported node was accepted")
        } catch SubscriptionError.incompatibleProfile(let message) {
          try expect(!message.contains("malformed") && message.contains("entire import"), "unsafe or unclear profile diagnostic")
        }
      }
    }
    try check("unexpected non-metadata lines still reject partial conversion") {
      do {
        _ = try store.parseFeed(Data("\(vless)\nunrecognized broken node\n".utf8))
        throw Failure(message: "partial conversion was accepted")
      } catch SubscriptionError.incompatibleProfile { }
    }
    try check("refresh parses updated nodes without retaining stale outbounds") {
      let original = try store.parseFeed(Data(feed.utf8).base64EncodedData())
      let updatedFeed = feed.replacingOccurrences(of: "192.0.2.1:443", with: "192.0.2.3:8443")
      let updated = try store.parseFeed(Data(updatedFeed.utf8).base64EncodedData())
      try expect(updated.count == original.count, "updated node count")
      try expect(updated[0].name == original[0].name, "refresh display identity")
      try expect(updated[0].outbound != original[0].outbound, "updated outbound did not change")
      try expect(updated[1].outbound == original[1].outbound, "unchanged outbound changed")
    }
    try check("refresh scheduling recovers after a previous failure") {
      let now = Date(timeIntervalSince1970: 1000)
      var schedule = RefreshSchedule.initial(last: nil, now: now, interval: 3600)
      schedule.failed(now: now, interval: 3600, category: "refresh", authorization: false)
      try expect(schedule.retryAt == now.addingTimeInterval(60), "first retry delay")
      schedule.succeeded(now: now, interval: 3600, jitter: 0)
      try expect(schedule.due == now.addingTimeInterval(3600), "next successful refresh")
      try expect(schedule.retryIndex == 0 && schedule.retryAt == nil && schedule.errorCategory == nil && !schedule.paused, "refresh error state was retained")
    }
    try check("subscription intervals update persisted deadlines without clearing retries or approval pauses") {
      let scheduleDirectory = directory.appendingPathComponent("intervals")
      try FileManager.default.createDirectory(at: scheduleDirectory, withIntermediateDirectories: true)
      let last = Date(timeIntervalSince1970: 1_700_000_000)
      let cases: [(String, Bool, Bool)] = [
        ("ready", false, false), ("retry", true, false), ("paused", true, true), ("local", false, false)
      ]
      let records: [[String: Any]] = cases.map { id, failed, paused in
        var schedule: [String: Any] = [
          "nextRefreshAt": last.addingTimeInterval(86400).timeIntervalSinceReferenceDate,
          "retryIndex": failed ? 1 : 0, "paused": paused]
        if failed {
          schedule["retryAt"] = last.addingTimeInterval(60).timeIntervalSinceReferenceDate
          schedule["errorCategory"] = "refresh"
        }
        return ["id": id, "providerName": id, "sourceRef": "synthetic", "nodes": [],
         "status": paused ? "approval_required" : (failed ? "refresh_failed" : "ready"),
         "isLocal": id == "local", "lastSuccessfulFetch": last.timeIntervalSinceReferenceDate,
         "refreshInterval": 86400, "refreshSchedule": schedule]
      }
      try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "subscriptions": records])
        .write(to: scheduleDirectory.appendingPathComponent("subscriptions-v1.json"))
      let secrets = MemorySecrets()
      @MainActor func open() throws -> SubscriptionStore {
        try SubscriptionStore(directory: scheduleDirectory, routing: routing, secretAccess: secrets.access())
      }
      let saved = try open()
      saved.now = { last.addingTimeInterval(5 * 3600) }
      try expect(Set(saved.dueSubscriptions()) == ["ready", "retry"], "four-hour default not applied to old catalog")
      saved.autoUpdateInterval = { 12 * 3600 }
      try expect(saved.dueSubscriptions() == ["retry"], "interval change cleared retry or approval state")
      let snapshots = saved.snapshot()["subscriptions"] as! [[String: Any]]
      try expect(snapshots.first { $0["id"] as? String == "ready" }?["nextRefreshAt"] as? Double == last.timeIntervalSince1970 + 12 * 3600,
        "displayed deadline disagrees with scheduler")
      let reopened = try open()
      reopened.autoUpdateInterval = { 12 * 3600 }
      reopened.now = { last.addingTimeInterval(13 * 3600) }
      try expect(Set(reopened.dueSubscriptions()) == ["ready", "retry"], "new interval lost after reopening")
      try expect(reopened.nextRefreshDate() == last.addingTimeInterval(60), "retry deadline changed with interval")
    }
    try check("duplicate node matching retains the selected node first") {
      try expect(prioritizingSelection(["first", "selected"], selected: "selected") == ["selected", "first"], "selected duplicate priority")
      let key = SubscriptionNodeMatchKey(name: "Test", protocolName: "VLESS", transport: "tcp", security: "tls")
      try expect(uniqueNodeIDs([(key, "a"), (key, "b")]).isEmpty, "ambiguous node identity")
      try expect(uniqueNodeIDs([(key, "a")])[key] == "a", "unique node identity")
    }

    try check("metadata handles byte counters Unix expiry and malformed fields") {
      let response = HTTPURLResponse(url: URL(string: "https://provider.example/feed")!, statusCode: 200,
        httpVersion: nil, headerFields: ["Subscription-Userinfo": "upload=1; download=2; total=0; expire=2000000000",
          "Announce": "base64:" + Data("News\nSecond line".utf8).base64EncodedString(), "Hide-Settings": "1"])!
      let metadata = ProviderMetadata(response: response)!
      try expect(metadata.upload == 1 && metadata.download == 2 && metadata.total == 0 && metadata.expire == 2000000000, "counter units changed")
      try expect(metadata.announcement == "News\nSecond line" && metadata.hideSettings == true, "encoded provider metadata lost")
      let malformed = HTTPURLResponse(url: response.url!, statusCode: 200, httpVersion: nil,
        headerFields: ["Subscription-Userinfo": "upload=-1; download=99999999999999999999999; total=1; total=2", "Announce": "base64:%%%"])!
      let invalid = ProviderMetadata(response: malformed)!
      try expect(invalid.upload == nil && invalid.download == nil && invalid.total == nil && invalid.announcement == nil, "invalid accounting was presented as valid")
      let banner = ProviderMetadata(response: HTTPURLResponse(url: response.url!, statusCode: 200, httpVersion: nil,
        headerFields: ["Banner-Text": "base64:" + Data("Free provider notice".utf8).base64EncodedString(),
          "Banner-Button-Text": "Open account", "Banner-Bg-Color": "#102030", "Banner-Button-Color": "red"])!)!
      try expect(banner.bannerText == "Free provider notice" && banner.bannerButtonText == "Open account", "public banner headers were lost")
    }
    try check("device identity is stable per provider without hardware identifiers") {
      let first = SubscriptionDeviceIdentity.headers(installationID: "fixture-install", url: URL(string: "https://provider.example/feed?token=a")!)
      let same = SubscriptionDeviceIdentity.headers(installationID: "fixture-install", url: URL(string: "https://provider.example:443/json?token=b")!)
      let other = SubscriptionDeviceIdentity.headers(installationID: "fixture-install", url: URL(string: "https://other.example/feed")!)
      try expect(first["X-HWID"] == same["X-HWID"] && first["X-HWID"] != other["X-HWID"], "HWID origin scoping")
      try expect(first["X-HWID"]?.count == 64 && first["X-Device-OS"] == "macOS", "device request contract")
    }

    passed += try safetyChecks()
    passed += try await deletionChecks(directory: directory.appendingPathComponent("deletion"), profile: vless)
    passed += try reclamationChecks(directory: directory.appendingPathComponent("reclamation"))
    let localSecrets = MemorySecrets()
    let localDirectory = directory.appendingPathComponent("local")
    let localStore = try SubscriptionStore(directory: localDirectory,
      routing: RoutingStore(directory: localDirectory.appendingPathComponent("routing")), secretAccess: localSecrets.access())
    localStore.publishRefresh = { candidate in
      _ = try localStore.beginPublication(candidate)
      try localStore.finishPublication(candidate)
    }
    let tuicRoot = directory.appendingPathComponent("tuic")
    let tuicSecrets = MemorySecrets()
    let tuicStore = try SubscriptionStore(directory: tuicRoot,
      routing: RoutingStore(directory: tuicRoot.appendingPathComponent("routing")), secretAccess: tuicSecrets.access())
    tuicStore.publishRefresh = { candidate in
      _ = try tuicStore.beginPublication(candidate)
      try tuicStore.finishPublication(candidate)
    }
    let tuicID = try tuicStore.registerProfiles("tuic://00000000-0000-4000-8000-000000000001:p%40ss%3A%E2%9C%93@[::1]:443?sni=fixture.example#TUIC%20%E2%9C%93")
    _ = try await tuicStore.refresh(id: tuicID)
    let tuicNode = ((tuicStore.snapshot()["subscriptions"] as! [[String: Any]])[0]["nodes"] as! [[String: Any]])[0]
    let tuicNodeID = tuicNode["id"] as! String
    try tuicStore.commitSelection(nodeID: tuicNodeID)
    let tuicRef = try tuicStore.outboundRef(nodeID: tuicNodeID)
    _ = try await tuicStore.refresh(id: tuicID)
    try check("TUIC encrypted catalog, unchanged refresh and share retain TLS identity") {
      try expect(tuicNode["protocol"] as? String == "TUIC" && tuicNode["transport"] as? String == "QUIC" && tuicNode["security"] as? String == "TLS", "TUIC labels changed")
      try expect(try tuicStore.outboundRef(nodeID: tuicNodeID) == tuicRef, "unchanged TUIC refresh replaced credentials")
      let reopened = try SubscriptionStore(directory: tuicRoot,
        routing: RoutingStore(directory: tuicRoot.appendingPathComponent("routing")), secretAccess: tuicSecrets.access())
      try expect(reopened.selectedNodeID() == tuicNodeID && reopened.selectedOutboundRef() == tuicRef, "TUIC selection did not survive relaunch")
      let shared = try reopened.sharingText(id: tuicNodeID, subscription: false)
      let parsed = try reopened.parseFeed(Data(shared.utf8))
      try expect(parsed.count == 1 && parsed[0].name == "TUIC ✓", "TUIC share cannot be reimported")
      let sharedProfile = try JSONSerialization.jsonObject(with: Data(shared.utf8)) as! [String: Any]
      let sharedOutbound = (sharedProfile["outbounds"] as! [[String: Any]])[0]
      let sharedTLS = (sharedOutbound["streamSettings"] as! [String: Any])["tlsSettings"] as! [String: Any]
      try expect(sharedTLS["serverName"] as? String == "fixture.example" && sharedTLS["alpn"] as? [String] == ["h3"], "TUIC sharing lost its TLS identity")
    }
    let telegram = "tg://proxy?server=proxy.example&port=443&secret=000102030405060708090a0b0c0d0e0f"
    try check("unified imports classify complete routing inputs with the shared parser") {
      let json = #"{"Name":"Import fixture","RemoteDNSType":"DoU","RemoteDNSIP":"1.1.1.1","DomesticDNSType":"DoU","DomesticDNSIP":"8.8.8.8","DirectSites":["full:example.com"]}"#
      let encoded = Data(json.utf8).base64EncodedString()
      let link = "happ://routing/add/" + encoded
      for input in [json, encoded, link, "happ://routing/off", "elarni://routing/add/" + encoded, "elarni://routing/onadd/" + encoded, "elarni://routing/off"] {
        try expect(RoutingDomainDecoder.isRoutingInput(input), "routing input was sent to the client parser")
      }
      try expect(RoutingDomainDecoder.isRoutingLink("elarni://routing/onadd/" + encoded), "primary routing directive was filtered out")
      for input in [vless, vless + "\n" + link, link + "\n" + vless, #"{"outbounds":[]}"#, "invalid"] {
        try expect(!RoutingDomainDecoder.isRoutingInput(input), "non-routing input was misclassified")
      }
    }
    let localID = try localStore.registerProfiles(vless + "\n" + telegram + "\nincy://settings/fixture")
    _ = try await localStore.refresh(id: localID)
    try check("local profiles use durable publication and Telegram remains a handoff") {
      let group = (localStore.snapshot()["subscriptions"] as! [[String: Any]])[0]
      let nodes = group["nodes"] as! [[String: Any]]
      try expect(group["isLocal"] as? Bool == true && nodes.count == 2, "local import did not publish all members")
      try expect((group["metadata"] as? [String: Any])?["directiveNotice"] is String, "unsupported provider directives were hidden")
      localStore.now = { Date.distantFuture }
      try expect(localStore.dueSubscriptions().isEmpty && localStore.nextRefreshDate() == nil, "local profiles scheduled a network refresh")
      let vpnID = nodes[0]["id"] as! String, telegramID = nodes[1]["id"] as! String
      try localStore.commitSelection(nodeID: vpnID)
      try rejects { try localStore.commitSelection(nodeID: telegramID) }
      try expect(try localStore.telegramURL(nodeID: telegramID).scheme == "tg", "Telegram action lost its validated URL")
      let sharedTelegram = try localStore.sharingText(id: telegramID, subscription: false)
      let telegramFields = Dictionary(uniqueKeysWithValues: URLComponents(string: sharedTelegram)!.queryItems!.map { ($0.name, $0.value ?? "") })
      try expect(telegramFields == ["server": "proxy.example", "port": "443", "secret": "000102030405060708090a0b0c0d0e0f"], "Telegram sharing altered connection details")
      let shared = try localStore.sharingText(id: vpnID, subscription: false)
      try expect(try localStore.parseFeed(Data(shared.utf8)).first?.name == "Test", "shared server cannot be imported")
      try expect(localStore.selectedNodeID() == vpnID, "Telegram action changed VPN selection")
      let reopened = try SubscriptionStore(directory: localDirectory,
        routing: RoutingStore(directory: localDirectory.appendingPathComponent("routing")), secretAccess: localSecrets.access())
      try expect(reopened.selectedNodeID() == vpnID && reopened.dueSubscriptions().isEmpty, "local profiles did not survive relaunch")
    }
    let hiddenID = try localStore.registerProfiles("#hide-url: yes\n" + vless)
    _ = try await localStore.refresh(id: hiddenID)
    try check("provider hidden URL also prevents server export") {
      let group = (localStore.snapshot()["subscriptions"] as! [[String: Any]]).first { $0["id"] as? String == hiddenID }!
      let nodeID = (group["nodes"] as! [[String: Any]])[0]["id"] as! String
      try rejects { _ = try localStore.sharingText(id: nodeID, subscription: false) }
      try rejects { _ = try localStore.sharingText(id: hiddenID, subscription: true) }
    }
    let clash = "proxies:\n  - {name: one, type: socks5, server: 127.0.0.1, port: 1080}\n  - {name: two, type: socks5, server: 127.0.0.1, port: 1081}\nproxy-groups:\n  - {name: PROXY, type: select, proxies: [one, two, DIRECT]}\nrules:\n  - MATCH,PROXY\n"
    let clashID = try localStore.registerProfiles(clash)
    _ = try await localStore.refresh(id: clashID)
    let repeatedID = try localStore.registerProfiles(vless)
    _ = try await localStore.refresh(id: repeatedID)
    try check("local imports join one group and skip servers it already has") {
      try expect(clashID == localID && repeatedID == localID, "a local import made another group")
      let groups = localStore.snapshot()["subscriptions"] as! [[String: Any]]
      let group = groups.first { $0["id"] as? String == localID }!
      try expect(groups.filter { $0["isLocal"] as? Bool == true }.count == 2, "the hidden import joined a shared group")
      try expect((group["nodes"] as! [[String: Any]]).map { $0["name"] as! String }.count == 3, "the joined group lost or repeated servers")
      try expect(localStore.selectedNodeID() == (group["nodes"] as! [[String: Any]])[0]["id"] as? String, "joining moved the selected server")
    }
    let repeatRoot = directory.appendingPathComponent("repeat")
    let repeatSecrets = MemorySecrets()
    let repeatStore = try SubscriptionStore(directory: repeatRoot,
      routing: RoutingStore(directory: repeatRoot.appendingPathComponent("routing")), secretAccess: repeatSecrets.access())
    repeatStore.publishRefresh = { candidate in
      _ = try repeatStore.beginPublication(candidate)
      try repeatStore.finishPublication(candidate)
    }
    let repeatID = try repeatStore.registerProfiles("socks://127.0.0.1:1080#One\nsocks://127.0.0.1:1080#Copy\nsocks://127.0.0.1:1081#Two")
    _ = try await repeatStore.refresh(id: repeatID)
    try check("a first local import skips the servers it repeats") {
      let group = (repeatStore.snapshot()["subscriptions"] as! [[String: Any]])[0]
      try expect((group["nodes"] as! [[String: Any]]).map { $0["name"] as! String } == ["One", "Two"], "a repeated server was kept")
    }
    try check("a local group shares its servers as links in group order") {
      let group = (localStore.snapshot()["subscriptions"] as! [[String: Any]]).first { $0["id"] as? String == localID }!
      let ids = (group["nodes"] as! [[String: Any]]).map { $0["id"] as! String }
      try expect(localStore.linkableNodeIDs(subscriptionID: localID) == Set(ids.prefix(2)), "a profile with several outbounds was offered as a link")
      let links = try localStore.shareLinks(subscriptionID: localID, nodeIDs: [ids[1], ids[0]]).components(separatedBy: "\n")
      try expect(links.map { URL(string: $0)?.scheme } == ["vless", "tg"], "shared links lost their group order")
      try expect(try localStore.parseFeed(Data(links[0].utf8)).first?.name == "Test", "a shared link lost its server name")
      try rejects { _ = try localStore.shareLinks(subscriptionID: localID, nodeIDs: [ids[2]]) }
      try rejects { _ = try localStore.shareLinks(subscriptionID: hiddenID, nodeIDs: [ids[0]]) }
    }
    let wireRoot = directory.appendingPathComponent("wireguard")
    let wireSecrets = MemorySecrets()
    let wireStore = try SubscriptionStore(directory: wireRoot,
      routing: RoutingStore(directory: wireRoot.appendingPathComponent("routing")), secretAccess: wireSecrets.access())
    wireStore.publishRefresh = { candidate in
      _ = try wireStore.beginPublication(candidate)
      try wireStore.finishPublication(candidate)
    }
    let wireKey = "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE="
    let wireID = try wireStore.registerProfiles("socks://127.0.0.1:1080#One\nwireguard://\(wireKey)@127.0.0.1:51820?publickey=\(wireKey.replacingOccurrences(of: "=", with: "%3D"))&address=10.0.0.2%2F32#WG")
    _ = try await wireStore.refresh(id: wireID)
    try check("the share sheet offers no server the share code has no link for") {
      let nodes = (wireStore.snapshot()["subscriptions"] as! [[String: Any]])[0]["nodes"] as! [[String: Any]]
      try expect(nodes.count == 2, "the WireGuard fixture was not imported")
      // Offering one made the whole batch fail.
      try expect(wireStore.linkableNodeIDs(subscriptionID: wireID) == [nodes[0]["id"] as! String], "a WireGuard server was offered as a link")
    }
    func clashNode() -> [String: Any] {
      let group = (localStore.snapshot()["subscriptions"] as! [[String: Any]]).first { $0["id"] as? String == clashID }!
      return (group["nodes"] as! [[String: Any]]).first { ($0["groups"] as! [[String: Any]]).isEmpty == false }!
    }
    let clashNodeID = clashNode()["id"] as! String
    try localStore.commitSelection(nodeID: clashNodeID)
    let beforeGroupRef = try localStore.outboundRef(nodeID: clashNodeID)
    try expect(try localStore.ipPreference(nodeID: clashNodeID) == nil, "legacy node gained an IP override")
    _ = try await localStore.setNodeIPPreference(nodeID: clashNodeID, preference: "ipv4")
    try expect(try localStore.outboundRef(nodeID: clashNodeID) == beforeGroupRef, "IP preference copied credentials")
    _ = try await localStore.selectProfileGroup(nodeID: clashNodeID, group: "PROXY", choice: "two")
    let selectedGroupRef = try localStore.outboundRef(nodeID: clashNodeID)
    try expect(selectedGroupRef != beforeGroupRef, "changed group reused the previous runtime configuration")
    _ = try await localStore.refresh(id: clashID)
    try check("Clash group choice survives publication and refresh with the same selected node") {
      try expect(try localStore.outboundRef(nodeID: clashNodeID) == selectedGroupRef,
        "unchanged refresh replaced the selected runtime reference")
      let choices = clashNode()["groups"] as! [[String: Any]]
      try expect(choices[0]["selected"] as? String == "two" && localStore.selectedNodeID() == clashNodeID, "refresh reset the group choice")
      try expect(clashNode()["ipPreference"] as? String == "ipv4", "refresh reset server IP preference")
      let reopened = try SubscriptionStore(directory: localDirectory,
        routing: RoutingStore(directory: localDirectory.appendingPathComponent("routing")), secretAccess: localSecrets.access())
      try expect(try reopened.ipPreference(nodeID: clashNodeID) == "ipv4", "IP preference did not survive relaunch")
      let profile = try localStore.outbound(nodeID: clashNodeID)
      let compiled = try RoutingDomainDecoder.request("compileProfile", payload: ["profile": profile, "socksPort": 1080])
      let config = try JSONSerialization.jsonObject(with: Data((compiled["configUtf8"] as! String).utf8)) as! [String: Any]
      let group = (config["outbounds"] as! [[String: Any]]).first { $0["tag"] as? String == "PROXY" }!
      try expect((group["settings"] as! [String: Any])["port"] as? Int == 1081, "chosen proxy was not compiled into the group")
    }
    localStore.publishRefresh = { candidate in
      _ = try localStore.beginPublication(candidate)
      try localStore.rollbackPublication()
      throw SubscriptionError.fetchFailed
    }
    do { _ = try await localStore.setNodeIPPreference(nodeID: clashNodeID, preference: "ipv6"); throw Failure(message: "failed IP publication succeeded") }
    catch SubscriptionError.fetchFailed { }
    try expect(try localStore.ipPreference(nodeID: clashNodeID) == "ipv4", "failed IP publication did not roll back")
    do { _ = try await localStore.setNodeIPPreference(nodeID: clashNodeID, preference: "invalid"); throw Failure(message: "invalid IP preference accepted") }
    catch SubscriptionError.invalidState { }
    do { _ = try await localStore.selectProfileGroup(nodeID: clashNodeID, group: "PROXY", choice: "one"); throw Failure(message: "failed group publication succeeded") }
    catch SubscriptionError.fetchFailed { }
    try check("failed Clash group publication restores its previous choice") {
      let choices = clashNode()["groups"] as! [[String: Any]]
      try expect(choices[0]["selected"] as? String == "two", "group choice did not roll back")
      _ = try localStore.outbound(nodeID: clashNodeID)
    }
    guard let fixture = ProcessInfo.processInfo.environment["ELARNI_TEST_FIXTURE"], let url = URL(string: fixture) else {
      throw Failure(message: "run scripts/check-subscriptions to start the isolated HTTP fixture")
    }
    let resourceURL = url.appendingPathComponent("binary-resource")
    var resourceApproval: [String] = []
    do {
      _ = try await RoutingResourceFetcher.fetch(resourceURL, maxBytes: 64 * 1024 * 1024)
      throw Failure(message: "routing resource bypassed private-address approval")
    } catch let requirement as SubscriptionApprovalRequirement {
      resourceApproval = requirement.candidateChain
    }
    let resource = try await RoutingResourceFetcher.fetch(resourceURL, maxBytes: 64 * 1024 * 1024,
      approvedChain: resourceApproval)
    try expect(resource == Data(Array(repeating: [UInt8(0), 255, 128, 7], count: 1024).flatMap { $0 }),
      "native routing resource bridge changed binary bytes")
    print("PASS routing resources use the native address policy and preserve binary bytes")
    passed += 1
    let infoDirectory = directory.appendingPathComponent("info-input")
    let infoSecrets = MemorySecrets()
    let infoStore = try SubscriptionStore(directory: infoDirectory,
      routing: RoutingStore(directory: infoDirectory.appendingPathComponent("routing")), secretAccess: infoSecrets.access())
    infoStore.publishRefresh = { candidate in
      _ = try infoStore.beginPublication(candidate)
      try infoStore.finishPublication(candidate)
    }
    let infoURL = url.appendingPathComponent("feed").appending(queryItems: [URLQueryItem(name: "format", value: "info")]).absoluteString
    let infoID = try infoStore.registerProfiles(infoURL + "#QR%20subscription")
    try expect((infoStore.snapshot()["subscriptions"] as! [[String: Any]])[0]["name"] as? String == "QR subscription",
      "link label was not used before fetching the provider title")
    let infoFirst = try await infoStore.refresh(id: infoID)
    try expect(infoFirst.warning != nil, "info input bypassed unsafe source approval")
    let infoSecond = try await infoStore.refresh(id: infoID, challenge: infoFirst.warning!.challenge)
    try expect(infoSecond.warning != nil, "advertised format bypassed target approval")
    _ = try await infoStore.refresh(id: infoID, challenge: infoSecond.warning!.challenge)
    try check("subscription URLs from profile input follow advertised info formats") {
      let group = (infoStore.snapshot()["subscriptions"] as! [[String: Any]])[0]
      try expect(group["isLocal"] as? Bool == false && (group["nodes"] as! [[String: Any]]).count == 1, "info URL was stored as a local proxy")
      try expect((group["metadata"] as! [String: Any])["enabled"] as? Bool == true, "info account status lost")
      try expect(group["name"] as? String == "Fixture", "QR label overrode the provider title")
      try expect(infoSecrets.data("subscription.\(infoID).source") == Data(infoURL.utf8), "QR fragment reached stored download URL")
    }
    let legacyURL = url.appendingPathComponent("feed").absoluteString + "#Legacy%20QR"
    let legacyID = try infoStore.registerProfiles(legacyURL)
    // Older builds stored the whole scanned URL before rejecting it at fetch time.
    infoSecrets.values["true:subscription.\(legacyID).source"] = Data(legacyURL.utf8)
    var legacyResult = try await infoStore.refresh(id: legacyID)
    for _ in 0..<8 {
      guard let challenge = legacyResult.warning?.challenge else { break }
      legacyResult = try await infoStore.refresh(id: legacyID, challenge: challenge)
    }
    try check("previously stored labelled QR subscriptions can be refreshed") {
      let group = (infoStore.snapshot()["subscriptions"] as! [[String: Any]])[1]
      try expect(legacyResult.warning == nil && group["status"] as? String == "ready" &&
        !(group["nodes"] as! [[String: Any]]).isEmpty, "legacy QR source still fails to refresh")
    }
    passed += try await subscriptionNameChecks(fixture: url)
    passed += try await refreshChecks(fixture: url)
    passed += try await transactionChecks(fixture: url)
    passed += try await selectionPublicationChecks()
    passed += try await nodeEditChecks()
    passed += try await hiddenServerChecks(fixture: url)
    passed += try await refreshConcurrencyChecks(fixture: url)
    passed += try await backupChecks(vless: vless, telegram: telegram, clash: clash, fixture: url)

    if CommandLine.arguments.dropFirst().contains("--live-subscription") {
      // Supply private subscription URLs through stdin; never store test credentials.
      guard let input = readLine(), let url = URL(string: input), url.scheme == "https" else {
        throw Failure(message: "live check requires an HTTPS subscription URL on stdin")
      }
      let configuration = URLSessionConfiguration.ephemeral
      configuration.timeoutIntervalForResource = 30
      let session = URLSession(configuration: configuration)
      defer { session.invalidateAndCancel() }
      for attempt in 1...2 {
        let (data, response) = try await session.data(from: url)
        try expect((response as? HTTPURLResponse)?.statusCode == 200 && data.count <= 4 * 1024 * 1024, "live feed response")
        let nodes = try store.parseFeed(data)
        try expect(!nodes.isEmpty, "live feed has no supported nodes")
        if let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "routing") {
          _ = try routing.stageProvider(header, subscriptionID: "live-check")
        }
        passed += 1
        print("PASS live subscription fetch/decode \(attempt): \(nodes.count) nodes")
      }
    }
    print("\(passed) subscription checks passed")
  }

  static func routingRefreshChecks(directory: URL) throws -> Int {
    let routes = try RoutingStore(directory: directory)
    let content = #"{"Name":"Stable routing","RemoteDNSType":"DoU","RemoteDNSIP":"1.1.1.1","DomesticDNSType":"DoU","DomesticDNSIP":"8.8.8.8","DirectSites":["full:example.com"],"Geoipurl":"https://fixture.invalid/geoip.dat","Geositeurl":"https://fixture.invalid/geosite.dat","UseChunkFiles":"true"}"#
    try routes.importProvider(content, subscriptionID: "source")
    var checkpoint = try JSONSerialization.jsonObject(with: routes.checkpoint()) as! [String: Any]
    var profiles = checkpoint["profiles"] as! [[String: Any]]
    profiles[0]["assetRevision"] = "fixture-reduced"
    profiles[0]["originalAssetRevision"] = "fixture-full"
    profiles[0]["lastGeoRefresh"] = Date().timeIntervalSinceReferenceDate
    profiles[0]["geofileStatus"] = "ready"
    profiles[0]["reductionStatus"] = "reduced"
    checkpoint["profiles"] = profiles
    let seeded = try JSONSerialization.data(withJSONObject: checkpoint)
    try routes.restore(seeded)
    let original = try routes.runtimeRevision(subscriptionID: "source")!
    for text in [content, content.replacingOccurrences(of: "Stable routing", with: "Renamed routing")] {
      let staged = try routes.stageProvider(text, subscriptionID: "source")
      try expect(routes.runtimeRevision(subscriptionID: "source") == original, "staging changed live routing")
      try routes.restore(staged)
      try expect(routes.runtimeRevision(subscriptionID: "source") == original,
        "unchanged provider routing replaced its reduced assets")
      try expect(routes.dueGeofiles().isEmpty, "unchanged provider routing discarded database freshness")
    }
    print("PASS identical and renamed provider routing preserve reduced assets and freshness")

    try routes.restore(seeded)
    try routes.restore(routes.stageProvider(content.replacingOccurrences(of: "full:example.com", with: "full:changed.example"),
      subscriptionID: "source"))
    try expect(routes.runtimeRevision(subscriptionID: "source")?.assetRevision == original.assetRevision,
      "changed routing discarded usable assets before replacement was prepared")
    try expect(routes.dueGeofiles().count == 1, "changed routing did not request database preparation")
    print("PASS changed provider routing retains usable assets while replacement is pending")

    profiles[0]["edited"] = true
    checkpoint["profiles"] = profiles
    try routes.restore(JSONSerialization.data(withJSONObject: checkpoint))
    try routes.restore(routes.stageProvider(content.replacingOccurrences(of: "full:example.com", with: "full:changed.example"),
      subscriptionID: "source"))
    try expect(routes.runtimeRevision(subscriptionID: "source") == original && routes.dueGeofiles().isEmpty,
      "provider refresh invalidated user-edited routing")
    print("PASS provider refresh preserves user-edited routing assets")
    return 3
  }

  static func missingGeodataChecks(directory: URL) async throws -> Int {
    func field(_ number: UInt8, _ bytes: Data) -> Data {
      precondition(bytes.count < 128)
      return Data([number << 3 | 2, UInt8(bytes.count)]) + bytes
    }
    let complete = field(1, field(1, Data("TEST".utf8)) + field(2, Data([8, 3]) + field(2, Data("example.com".utf8))))
    let routes = try RoutingStore(directory: directory)
    routes.fetchGeofile = { _, _ in (complete, nil) }
    routes.publishManaged = { try routes.publish($0) }
    func profile(_ rules: String, chunked: Bool) -> String {
      #"{"Name":"Missing codes","RemoteDNSType":"DoU","RemoteDNSIP":"1.1.1.1","DomesticDNSType":"DoU","DomesticDNSIP":"8.8.8.8",\#(rules),"Geositeurl":"https://fixture.invalid/geosite.dat","UseChunkFiles":"\#(chunked)"}"#
    }
    func record() -> [String: Any] { (routes.snapshot()["profiles"] as! [[String: Any]])[0] }
    for chunked in [true, false] {
      try routes.importProvider(profile(#""DirectSites":["geosite:missing"],"BlockSites":["geosite:missing@ads"],"DomesticDNSDomains":["geosite:missing"],"ProxySites":["geosite:test"]"#,
        chunked: chunked), subscriptionID: "source")
      try await routes.prepareAssets(subscriptionID: "source")
      try expect(record()["geofileStatus"] as? String == "ready" && record()["skippedGeodata"] as? [String] == ["geosite:missing"],
        "missing Direct, Block and domestic DNS code was not skipped (chunked: \(chunked))")
      let revision = try routes.runtimeRevision(subscriptionID: "source")!.assetRevision!
      let runtime = try Data(contentsOf: directory.appendingPathComponent("Assets/\(revision)/geosite.dat"))
      // Xray loads the empty MISSING record as a category that matches nothing.
      try expect(runtime == complete + field(1, field(1, Data("MISSING".utf8))),
        "runtime geodata lacks the empty skipped record (chunked: \(chunked))")
    }
    print("PASS Direct, Block and domestic DNS rules skip codes missing from the geofiles")
    try routes.importProvider(profile(#""DirectSites":["geosite:missing"],"ProxySites":["geosite:missing"]"#, chunked: true),
      subscriptionID: "source")
    do {
      try await routes.prepareAssets(subscriptionID: "source")
      throw Failure(message: "a Proxy rule's missing code was skipped")
    } catch RoutingStoreError.missingGeodata(let missing) {
      try expect(missing == ["geosite:missing"], "wrong missing codes \(missing)")
    }
    try expect(record()["geofileStatus"] as? String == "failed" && record()["geofileError"] as? String ==
      "Proxy rules and servers need codes the geofiles lack: geosite:missing. Fix the profile or its geofile links.",
      "a Proxy rule's missing code did not name the code")
    print("PASS a Proxy rule's missing geodata code fails and names the code")
    return 2
  }

  static func externalGeodataChecks(directory: URL) async throws -> Int {
    func field(_ number: UInt8, _ bytes: Data) -> Data {
      precondition(bytes.count < 128)
      return Data([number << 3 | 2, UInt8(bytes.count)]) + bytes
    }
    func site(_ code: String) -> Data {
      field(1, field(1, Data(code.utf8)) + field(2, Data([8, 3]) + field(2, Data("\(code.lowercased()).example".utf8))))
    }
    // Xray reads ext-site: and ext-domain: from the named file, as it does ext:, so reduction keeps the complete files.
    for selector in ["ext-site:geosite.dat:other", "ext-domain:geosite.dat:other"] {
      for inServer in [false, true] {
        let routes = try RoutingStore(directory: directory.appendingPathComponent("\(selector.prefix(8))-\(inServer)"))
        routes.fetchGeofile = { _, _ in (site("TEST") + site("OTHER"), nil) }
        routes.publishManaged = { try routes.publish($0) }
        let servers: [Any] = inServer ? [["routing": ["rules": [["domain": [selector], "outboundTag": "proxy"]]]]] : []
        routes.serverConfigs = { ids in ids == ["source"] ? servers : [] }
        routes.serverRefs = { ids in ids == ["source"] ? ["server"] : [] }
        let sites = inServer ? #""geosite:test""# : #""geosite:test","\#(selector)""#
        try routes.importProvider(#"{"Name":"External codes","RemoteDNSType":"DoU","RemoteDNSIP":"1.1.1.1","DomesticDNSType":"DoU","DomesticDNSIP":"8.8.8.8","ProxySites":[\#(sites)],"Geositeurl":"https://fixture.invalid/geosite.dat","UseChunkFiles":"true"}"#,
          subscriptionID: "source")
        try await routes.prepareAssets(subscriptionID: "source")
        let status = (routes.snapshot()["profiles"] as! [[String: Any]])[0]["reductionStatus"] as? String ?? ""
        try expect(status.hasPrefix("Using complete files"), "\(selector) was reduced away (server rule: \(inServer)): \(status)")
      }
    }
    // Xray reads a leading ! on an IP rule like one before the code; provider JSON keeps it there.
    func ip(_ code: String, _ first: UInt8) -> Data {
      field(1, field(1, Data(code.utf8)) + field(2, field(1, Data([first, 0, 2, 0])) + Data([0x10, 24])))
    }
    for (selector, file) in [("!geoip:ru", ip("US", 198) + ip("OTHER", 203)), ("!ext:geoip.dat:ru", ip("RU", 192) + ip("US", 198))] {
      let routes = try RoutingStore(directory: directory.appendingPathComponent(selector.hasPrefix("!ext") ? "negated-ext" : "negated-geoip"))
      routes.fetchGeofile = { _, _ in (file, nil) }
      routes.publishManaged = { try routes.publish($0) }
      let servers: [Any] = [["routing": ["rules": [["ip": [selector], "outboundTag": "direct"]]]]]
      routes.serverConfigs = { ids in ids == ["source"] ? servers : [] }
      routes.serverRefs = { ids in ids == ["source"] ? ["server"] : [] }
      try routes.importProvider(#"{"Name":"Negated codes","RemoteDNSType":"DoU","RemoteDNSIP":"1.1.1.1","DomesticDNSType":"DoU","DomesticDNSIP":"8.8.8.8","ProxyIp":["geoip:us"],"Geoipurl":"https://fixture.invalid/geoip.dat","UseChunkFiles":"true"}"#,
        subscriptionID: "source")
      do {
        try await routes.prepareAssets(subscriptionID: "source")
        let status = (routes.snapshot()["profiles"] as! [[String: Any]])[0]["reductionStatus"] as? String ?? ""
        try expect(selector.hasPrefix("!ext:") && status.hasPrefix("Using complete files"), "server rule \(selector) was reduced away: \(status)")
      } catch RoutingStoreError.missingGeodata(let missing) {
        // The file lacks RU, which Xray would then fail to load.
        try expect(selector == "!geoip:ru" && missing == ["geoip:ru"], "server rule \(selector): missing \(missing)")
      }
    }
    print("PASS ext-site and ext-domain geodata selectors keep the complete files like ext:; negated server selectors keep their codes")
    return 1
  }

  static func routingAssetChecks(directory: URL) async throws -> Int {
    // Small synthetic protobuf databases; no network or installed catalog is used.
    func field(_ number: UInt8, _ bytes: Data) -> Data {
      precondition(bytes.count < 128)
      return Data([number << 3 | 2, UInt8(bytes.count)]) + bytes
    }
    func site(_ code: String, _ domain: String) -> Data {
      field(1, field(1, Data(code.utf8)) + field(2, Data([8, 3]) + field(2, Data(domain.utf8))))
    }
    let routes = try RoutingStore(directory: directory)
    let content = #"{"Name":"Asset fixture","RemoteDNSType":"DoU","RemoteDNSIP":"1.1.1.1","DomesticDNSType":"DoU","DomesticDNSIP":"8.8.8.8","DirectSites":["geosite:TEST"],"Geositeurl":"https://fixture.invalid/geosite.dat","UseChunkFiles":"true"}"#
    var data = site("TEST", "example.com") + site("UNUSED", "unused.example")
    var fetches = 0, publications = 0
    routes.fetchGeofile = { _, _ in fetches += 1; return (data, nil) }
    routes.publishManaged = { candidate in
      publications += 1
      try routes.publish(candidate)
    }
    try routes.importProvider(content, subscriptionID: "source")
    try await routes.prepareAssets(subscriptionID: "source")
    let original = try routes.runtimeRevision(subscriptionID: "source")!
    let id = (routes.snapshot()["profiles"] as! [[String: Any]])[0]["id"] as! String
    try expect(original.assetRevision != nil && fetches == 1 && publications == 0 && routes.dueGeofiles().isEmpty,
      "transaction preparation did not finish assets before runtime publication")
    _ = try await routes.refreshGeofiles(id: id, force: true)
    try expect(routes.runtimeRevision(subscriptionID: "source") == original && fetches == 2 && publications == 1,
      "identical downloaded data changed the runtime revision")
    data = site("TEST", "example.com") + site("UNUSED", "updated.example")
    _ = try await routes.refreshGeofiles(id: id, force: true)
    try expect(routes.runtimeRevision(subscriptionID: "source") == original,
      "unused database records changed the effective runtime assets")
    print("PASS prepared and refreshed geodata retain byte-identical effective revisions")

    // A refresh sends the stored file's validators, and nil data keeps that file.
    let conditional = try RoutingStore(directory: directory.appendingPathComponent("conditional"))
    var sent: [GeofileValidators?] = []
    var reply: (Data?, GeofileValidators?) = (data, GeofileValidators(etag: "\"v1\""))
    conditional.fetchGeofile = { _, stored in sent.append(stored); return reply }
    conditional.publishManaged = { try conditional.publish($0) }
    try conditional.importProvider(content, subscriptionID: "source")
    try await conditional.prepareAssets(subscriptionID: "source")
    let conditionalID = (conditional.snapshot()["profiles"] as! [[String: Any]])[0]["id"] as! String
    let stored = try conditional.runtimeRevision(subscriptionID: "source")
    reply = (nil, nil)
    _ = try await conditional.refreshGeofiles(id: conditionalID, force: true)
    try expect(sent == [nil, GeofileValidators(etag: "\"v1\"")] && conditional.runtimeRevision(subscriptionID: "source") == stored,
      "a refresh did not send the stored validators or replaced the unchanged file")
    reply = (site("TEST", "changed.example"), GeofileValidators(etag: "\"v2\""))
    _ = try await conditional.refreshGeofiles(id: conditionalID, force: true)
    try expect(conditional.runtimeRevision(subscriptionID: "source") != stored, "a changed geofile kept the old revision")
    reply = (nil, nil)
    _ = try await conditional.refreshGeofiles(id: conditionalID, force: true)
    try expect(sent.count == 4 && sent[3] == GeofileValidators(etag: "\"v2\""), "the new validators were not stored")
    print("PASS geofile refresh downloads only a changed file")

    let retained = try routes.checkpoint()
    try routes.importProvider(content.replacingOccurrences(of: "geosite:TEST", with: "geosite:UNUSED"), subscriptionID: "source")
    try expect(routes.runtimeRevision(subscriptionID: "source")?.assetRevision == original.assetRevision,
      "changed selector released the last usable assets")
    try await routes.prepareAssets(subscriptionID: "source")
    let changed = try routes.runtimeRevision(subscriptionID: "source")!
    try expect(changed.assetRevision != original.assetRevision && fetches == 3 && routes.dueGeofiles().isEmpty,
      "changed selectors did not prepare from fresh original data")
    try routes.restore(retained)
    try expect(routes.runtimeRevision(subscriptionID: "source") == original,
      "rollback could not restore assets after preparation")
    print("PASS changed selectors prepare once from retained originals and support rollback")

    routes.fetchGeofile = { _, _ in throw Failure(message: "synthetic download failure") }
    try routes.importProvider(content.replacingOccurrences(of: "fixture.invalid", with: "changed.invalid"), subscriptionID: "source")
    do {
      try await routes.prepareAssets(subscriptionID: "source")
      throw Failure(message: "failed database preparation succeeded")
    } catch let failure as Failure {
      try expect(failure.message == "synthetic download failure", failure.message)
    }
    try expect(routes.runtimeRevision(subscriptionID: "source")?.assetRevision == original.assetRevision,
      "failed preparation discarded usable assets")
    try routes.restore(retained)
    routes.fetchGeofile = { _, _ in throw CancellationError() }
    do {
      _ = try await routes.refreshGeofiles(id: id, force: true)
      throw Failure(message: "cancelled database refresh succeeded")
    } catch is CancellationError { }
    try expect(routes.runtimeRevision(subscriptionID: "source") == original && publications == 2,
      "failed or cancelled preparation published assets")
    print("PASS failed and cancelled geodata refresh preserve the usable runtime revision")

    try routes.restore(retained)
    var download: CheckedContinuation<Data, Error>?
    routes.fetchGeofile = { _, _ in
      let body: Data = try await withCheckedThrowingContinuation { download = $0 }
      return (body, nil)
    }
    let pending = Task { @MainActor in try await routes.refreshGeofiles(id: id, force: true) }
    let deadline = Date().addingTimeInterval(2)
    while download == nil && Date() < deadline { await Task.yield() }
    guard let download else { pending.cancel(); throw Failure(message: "database download did not start") }
    try routes.importProvider(content.replacingOccurrences(of: "geosite:TEST", with: "geosite:UNUSED"), subscriptionID: "source")
    let pendingRevision = try routes.runtimeRevision(subscriptionID: "source")
    do {
      try await routes.prepareAssets(subscriptionID: "source")
      throw Failure(message: "concurrent preparation accepted an obsolete download")
    } catch RoutingStoreError.invalidImport { }
    download.resume(returning: data)
    do {
      _ = try await pending.value
      throw Failure(message: "obsolete database download published")
    } catch is CancellationError { }
    try expect(routes.runtimeRevision(subscriptionID: "source") == pendingRevision && publications == 2,
      "obsolete download overwrote a newer routing generation")
    print("PASS overlapping preparation rejects stale downloads without changing the runtime assets")

    // A provider's JSON server can have its own rule on a code the routing profile never names.
    try routes.restore(retained)
    routes.fetchGeofile = { _, _ in (data, nil) }
    var servers: [Any] = []
    var refs = ["server-1"]
    var reads = 0
    routes.serverConfigs = { ids in reads += 1; return ids == ["source"] ? servers : [] }
    routes.serverRefs = { ids in ids == ["source"] ? refs : [] }
    servers = [["routing": ["rules": [["domain": ["geosite:UNUSED"], "outboundTag": "block"]]]]]
    let downloads = fetches
    try await routes.prepareAssets(subscriptionID: "source")
    let serverAssets = try routes.runtimeRevision(subscriptionID: "source")!
    let reduced = try Data(contentsOf: directory.appendingPathComponent("Assets/\(serverAssets.assetRevision!)/geosite.dat"))
    try expect(reduced.range(of: Data("UNUSED".utf8)) != nil && fetches == downloads,
      "reduced geodata dropped a code a server's own rule needs")
    // Unchanged servers cost no secret reads at connect.
    var counted = reads
    try await routes.prepareAssets(subscriptionID: "source")
    try expect(routes.runtimeRevision(subscriptionID: "source") == serverAssets && reads == counted,
      "unchanged servers were read or reduced the geofiles again")
    // A changed server with the same codes is read once and reduces nothing.
    refs = ["server-2"]
    try await routes.prepareAssets(subscriptionID: "source")
    try expect(routes.runtimeRevision(subscriptionID: "source") == serverAssets && reads == counted + 1,
      "a server change with the same codes reduced the geofiles again")
    counted = reads
    try await routes.prepareAssets(subscriptionID: "source")
    try expect(reads == counted, "the checked server change was read again")
    servers = [["routing": ["rules": [["domain": ["geosite:absent"], "outboundTag": "proxy"]]]]]
    refs = ["server-3"]
    do {
      try await routes.prepareAssets(subscriptionID: "source")
      throw Failure(message: "a server's missing code was dropped")
    } catch RoutingStoreError.missingGeodata(let missing) {
      try expect(missing == ["geosite:absent"], "wrong missing server codes \(missing)")
    }
    print("PASS reduced geodata keeps the codes the assigned servers' own rules name")
    return 6
  }

  static func subscriptionNameChecks(fixture: URL) async throws -> Int {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("elarni-names-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let secrets = MemorySecrets()
    func openStore() throws -> SubscriptionStore {
      let store = try SubscriptionStore(directory: directory,
        routing: RoutingStore(directory: directory.appendingPathComponent("routing")), secretAccess: secrets.access())
      store.publishRefresh = { [weak store] candidate in
        guard let store else { throw Failure(message: "name fixture store released") }
        _ = try store.beginPublication(candidate)
        try store.finishPublication(candidate)
      }
      return store
    }
    func mode(_ value: String) async throws {
      let session = URLSession(configuration: .ephemeral)
      defer { session.invalidateAndCancel() }
      _ = try await session.data(from: fixture.appendingPathComponent("mode")
        .appending(queryItems: [URLQueryItem(name: "value", value: value)]))
    }
    func name(_ store: SubscriptionStore) -> String? {
      (store.snapshot()["subscriptions"] as! [[String: Any]]).first?["name"] as? String
    }
    var store = try openStore()
    let id = try store.register(urlText: fixture.appendingPathComponent("feed").absoluteString + "#Hysteria2")
    try await mode("untitled")
    var result = try await store.refresh(id: id)
    for _ in 0..<8 {
      guard let challenge = result.warning?.challenge else { break }
      result = try await store.refresh(id: id, challenge: challenge)
    }
    try expect(result.warning == nil && name(store) == "Hysteria2", "missing provider title lost the link label")
    store = try openStore()
    _ = try await store.refresh(id: id)
    try expect(name(store) == "Hysteria2", "link fallback did not survive relaunch and refresh")
    try await mode("baseline")
    _ = try await store.refresh(id: id)
    try expect(name(store) == "Fixture", "link label became a persistent manual name")
    _ = try store.rename(id: id, name: "My VPN")
    store = try openStore()
    try await mode("renamed")
    _ = try await store.refresh(id: id)
    try expect(name(store) == "My VPN", "provider title replaced an explicit rename")
    _ = try store.rename(id: id, name: nil)
    try expect(name(store) == "Updated provider", "clearing a rename did not restore the latest provider title")
    try await mode("untitled")
    _ = try await store.refresh(id: id)
    try expect(name(store) == "Hysteria2", "link fallback was lost after a provider title change")
    try await mode("baseline")
    print("PASS subscription link labels stay below provider titles and explicit renames across relaunch")
    return 1
  }

  static func refreshChecks(fixture: URL) async throws -> Int {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("elarni-refresh-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let secrets = MemorySecrets()
    var publications = 0
    func openStore() throws -> SubscriptionStore {
      let store = try SubscriptionStore(directory: directory,
        routing: RoutingStore(directory: directory.appendingPathComponent("routing")), secretAccess: secrets.access())
      store.publishRefresh = { [weak store] candidate in
        guard let store else { throw Failure(message: "refresh store released") }
        _ = try store.beginPublication(candidate)
        try store.finishPublication(candidate)
        publications += 1
      }
      return store
    }
    func mode(_ value: String) async throws {
      _ = try await URLSession.shared.data(from: fixture.appendingPathComponent("mode")
        .appending(queryItems: [URLQueryItem(name: "value", value: value)]))
    }
    func node(_ store: SubscriptionStore) -> [String: Any] {
      ((store.snapshot()["subscriptions"] as! [[String: Any]])[0]["nodes"] as! [[String: Any]])[0]
    }
    try await mode("baseline")
    var store = try openStore()
    let url = fixture.appendingPathComponent("feed").absoluteString
    let id = try store.register(urlText: url + "#First")
    try expect(store.register(urlText: url + "#Second") == id, "labelled duplicate created another subscription")
    try expect(store.registerProfiles("incy://import/" + Data(url.utf8).base64EncodedString()) == id,
      "wrapped duplicate created another subscription")
    var result = try await store.refresh(id: id)
    for _ in 0..<8 {
      guard let challenge = result.warning?.challenge else { break }
      result = try await store.refresh(id: id, challenge: challenge)
    }
    try expect(result.warning == nil && publications == 1, "initial refresh fixture did not publish")
    try expect(node(store)["probeKey"] as? String == "example.com", "the snapshot does not name the server's SNI")
    let nodeID = node(store)["id"] as! String
    try store.commitSelection(nodeID: nodeID)
    _ = try store.setFavorite(nodeID: nodeID, favorite: true)
    let revision = try store.configurationRevision(nodeID: nodeID)
    try store.recordSuccess(nodeID: nodeID, revision: revision, session: "fixture-session")
    let success = node(store)["lastSuccessAt"] as! Double
    _ = try await store.refresh(id: id)
    store = try openStore()
    try expect(node(store)["favorite"] as? Bool == true && node(store)["lastSuccessAt"] as? Double == success &&
      node(store)["lastSuccessCurrent"] as? Bool == true && node(store)["configurationRevision"] as? String == revision,
      "preferences or compatible success lost across refresh and relaunch")
    print("PASS duplicate wrappers and labels retain one subscription; favorites and success survive refresh/relaunch")

    let published = publications
    try await mode("updated")
    _ = try await store.refresh(id: id)
    try expect(publications == published + 1 && node(store)["id"] as? String == nodeID && node(store)["favorite"] as? Bool == true &&
      node(store)["lastSuccessAt"] as? Double == success && node(store)["lastSuccessCurrent"] as? Bool == false &&
      node(store)["configurationRevision"] as? String != revision, "changed refresh did not publish, reused prior health or lost preferences")
    try expect(String(data: JSONSerialization.data(withJSONObject: store.outbound(nodeID: nodeID)), encoding: .utf8)!.contains("8443"),
      "refresh did not apply the fetched bytes")
    try await mode("full_profile")
    _ = try await store.refresh(id: id)
    try expect(store.selectedNodeID() == nodeID && node(store)["favorite"] as? Bool == true &&
      node(store)["lastSuccessCurrent"] as? Bool == false,
      "unique-name profile representation change lost selection/preferences or retained health")
    print("PASS a changed refresh publishes at once, keeps selection and preferences, and invalidates old success")
    // The tunnel plan names the outbound's secret, so a kept reference keeps the running tunnel.
    try await mode("reality_0a1b")
    _ = try await store.refresh(id: id)
    let realityRef = try store.outboundRef(nodeID: nodeID)
    try await mode("reality_c2d3")
    _ = try await store.refresh(id: id)
    try expect(store.selectedNodeID() == nodeID && store.outboundRef(nodeID: nodeID) == realityRef,
      "a refresh that changed only the REALITY shortId and SNI replaced the stored outbound")
    try await mode("reality_fp")
    _ = try await store.refresh(id: id)
    try expect(store.outboundRef(nodeID: nodeID) != realityRef, "a refresh that changed the fingerprint kept the stored outbound")
    print("PASS a refresh that changes only the REALITY shortId and SNI keeps the stored outbound; a fingerprint change replaces it")
    func dnsNotice() -> String? {
      ((store.snapshot()["subscriptions"] as! [[String: Any]])[0]["metadata"] as? [String: Any])?["dnsNotice"] as? String
    }
    try await mode("system_dns")
    _ = try await store.refresh(id: id)
    try expect(dnsNotice() == "The provider's DNS asks this device's resolver, outside the tunnel. Elarni uses its own DNS for these servers.", "the dropped provider DNS was not mentioned")
    try await mode("baseline")
    _ = try await store.refresh(id: id)
    try expect(dnsNotice() == nil, "the DNS notice outlived the provider DNS")
    print("PASS a provider DNS that asks the system resolver is noted until the provider changes it")
    return 4
  }

  static func rejects(_ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw Failure(message: "invalid operation was accepted")
  }

  static func deletionChecks(directory: URL, profile: String) async throws -> Int {
    let secrets = MemorySecrets()
    let store = try SubscriptionStore(directory: directory,
      routing: RoutingStore(directory: directory.appendingPathComponent("routing")), secretAccess: secrets.access())
    store.publishRefresh = { candidate in
      _ = try store.beginPublication(candidate)
      try store.finishPublication(candidate)
    }
    // A hidden import keeps its own group, which gives this check two local sources.
    let first = try store.registerProfiles(profile), second = try store.registerProfiles("#hide-url: yes\n" + profile)
    _ = try await store.refresh(id: first)
    _ = try await store.refresh(id: second)
    let route = #"{"Name":"Provider route","RemoteDNSType":"DoU","RemoteDNSIP":"1.1.1.1","DomesticDNSType":"DoU","DomesticDNSIP":"8.8.8.8","DirectSites":["full:example.com"]}"#
    try store.routing.importProvider(route, subscriptionID: first)
    let routeID = (store.routing.snapshot()["assignments"] as! [String: String])[first]!
    let copies = try store.routing.duplicate(id: routeID)["profiles"] as! [[String: Any]]
    let independent = copies.first { $0["id"] as? String != routeID }!["id"] as! String
    _ = try store.routing.assign(subscriptionID: second, profileID: independent)
    let before = store.snapshot() as NSDictionary, routingBefore = store.routing.snapshot() as NSDictionary
    let secretsBefore = secrets.values
    do {
      _ = try await store.delete(id: first) { throw SubscriptionError.fetchFailed }
      throw Failure(message: "deletion ignored runtime synchronization failure")
    } catch SubscriptionError.fetchFailed { }
    try expect((store.snapshot() as NSDictionary).isEqual(before) &&
      (store.routing.snapshot() as NSDictionary).isEqual(routingBefore) && secrets.values == secretsBefore,
      "failed deletion lost source, routing or credentials")
    _ = try await store.delete(id: first)
    let reopened = try SubscriptionStore(directory: directory,
      routing: RoutingStore(directory: directory.appendingPathComponent("routing")), secretAccess: secrets.access())
    try expect((reopened.snapshot()["subscriptions"] as! [[String: Any]]).map { $0["id"] as! String } == [second],
      "deleted source survived relaunch")
    try expect((reopened.routing.snapshot()["profiles"] as! [[String: Any]]).map { $0["id"] as! String } == [independent] &&
      reopened.routing.snapshot()["assignments"] as? [String: String] == [second: independent],
      "source deletion retained provider routing or removed an independent copy")
    print("PASS source deletion rolls back both catalogs and removes only provider-owned routing")
    return 1
  }

  static func reclamationChecks(directory: URL) throws -> Int {
    let routes = try RoutingStore(directory: directory)
    let content = #"{"Name":"Retained route","RemoteDNSType":"DoU","RemoteDNSIP":"1.1.1.1","DomesticDNSType":"DoU","DomesticDNSIP":"8.8.8.8","DirectSites":["full:example.com"]}"#
    try routes.importProvider(content, subscriptionID: "source")
    let current = try routes.runtimeRevision(subscriptionID: "source")!
    let assets = directory.appendingPathComponent("Assets"), revisions = directory.appendingPathComponent("Revisions")
    let assetNames = (0..<4).map { _ in UUID().uuidString.lowercased() }
    for name in assetNames + ["unrelated", ".staging-test"] {
      try FileManager.default.createDirectory(at: assets.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    var checkpoint = try JSONSerialization.jsonObject(with: routes.checkpoint()) as! [String: Any]
    var profiles = checkpoint["profiles"] as! [[String: Any]]
    profiles[0]["assetRevision"] = assetNames[0]
    profiles[0]["originalAssetRevision"] = assetNames[1]
    checkpoint["profiles"] = profiles
    try routes.restore(JSONSerialization.data(withJSONObject: checkpoint))
    let savedPlan = "route-model-" + String(repeating: "1", count: 64) + ".json"
    let obsolete = "route-model-" + String(repeating: "2", count: 64) + ".json"
    for name in [savedPlan, obsolete, "unrelated.json"] {
      try Data("{}".utf8).write(to: revisions.appendingPathComponent(name))
    }
    let link = assets.appendingPathComponent(UUID().uuidString.lowercased())
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: assets.appendingPathComponent("unrelated"))
    try routes.reclaimUnusedFiles(routeNames: [savedPlan], assetRevisions: [assetNames[2]])
    try expect(!FileManager.default.fileExists(atPath: assets.appendingPathComponent(assetNames[3]).path) &&
      !FileManager.default.fileExists(atPath: revisions.appendingPathComponent(obsolete).path), "obsolete revisions were retained")
    for url in assetNames.prefix(3).map({ assets.appendingPathComponent($0) }) +
      [assets.appendingPathComponent("unrelated"), assets.appendingPathComponent(".staging-test"), link,
       revisions.appendingPathComponent(savedPlan), revisions.appendingPathComponent(current.name), revisions.appendingPathComponent("unrelated.json")] {
      try expect(FileManager.default.fileExists(atPath: url.path), "reclamation removed a live, pending or unrelated file")
    }
    print("PASS routing file reclamation preserves catalog originals, saved plans and unrelated files")
    return 1
  }

  static func safetyChecks() throws -> Int {
    var now = Date(timeIntervalSince1970: 1000)
    var nonce: UInt8 = 0
    let vault = SubscriptionApprovalChallengeVault(lifetime: 300, now: { now }, randomBytes: { count in
      nonce += 1; return Data(repeating: nonce, count: count)
    })
    let requirement = SubscriptionApprovalRequirement(riskCodes: [.cleartextHTTP, .loopbackTarget], candidateChain: ["target"])
    let token = try vault.issue(subscriptionID: "a", requirement: requirement).challenge
    try rejects { _ = try vault.consume(token, subscriptionID: "b") }
    try expect(try vault.consume(token, subscriptionID: "a") == ["target"], "wrong-subscription attempt consumed valid token")
    try rejects { _ = try vault.consume(token, subscriptionID: "a") }
    let expired = try vault.issue(subscriptionID: "a", requirement: requirement).challenge
    now = now.addingTimeInterval(300)
    try rejects { _ = try vault.consume(expired, subscriptionID: "a") }
    let old = try vault.issue(subscriptionID: "a", requirement: requirement).challenge
    let replacement = try vault.issue(subscriptionID: "a", requirement: requirement).challenge
    try rejects { _ = try vault.consume(old, subscriptionID: "a") }
    vault.invalidate(subscriptionID: "a")
    try rejects { _ = try vault.consume(replacement, subscriptionID: "a") }
    let shown = try vault.issue(subscriptionID: "c", requirement: SubscriptionApprovalRequirement(riskCodes: [.privateTarget],
      candidateChain: ["https://[2001:db8::1]:8443/secret-token", "http://user:pass@feed.example/path?key=1", "not a url"])).destinations
    try expect(shown == ["https://[2001:db8::1]:8443", "http://feed.example", "Invalid destination"], "approval destinations were \(shown)")
    print("PASS subscription challenges are scoped single-use expiring and invalidated")
    return 1
  }

  final class MemorySecrets {
    var values: [String: Data] = [:]
    var failApprovalWrites = false
    func key(_ query: CFDictionary) -> String {
      let query = query as NSDictionary
      return "\(query[kSecUseDataProtectionKeychain] as? Bool ?? false):\(query[kSecAttrAccount] as! String)"
    }
    func data(_ ref: String) -> Data? { values["true:\(ref)"] }
    func access() -> SubscriptionSecretAccess {
      SubscriptionSecretAccess(add: { query, _ in
        let key = self.key(query)
        if self.failApprovalWrites && key.hasSuffix("safety-approvals") { return errSecAuthFailed }
        guard self.values[key] == nil else { return errSecDuplicateItem }
        self.values[key] = (query as NSDictionary)[kSecValueData] as? Data
        return errSecSuccess
      }, copy: { query, output in
        guard let value = self.values[self.key(query)] else { return errSecItemNotFound }
        output?.pointee = value as CFData
        return errSecSuccess
      }, update: { query, attributes in
        let key = self.key(query)
        if self.failApprovalWrites && key.hasSuffix("safety-approvals") { return errSecAuthFailed }
        guard self.values[key] != nil else { return errSecItemNotFound }
        self.values[key] = (attributes as NSDictionary)[kSecValueData] as? Data
        return errSecSuccess
      }, delete: { query in
        self.values.removeValue(forKey: self.key(query)) == nil ? errSecItemNotFound : errSecSuccess
      }, accessGroup: { "TEST.com.elarni.mac.shared" })
    }
  }

  static func backupChecks(vless: String, telegram: String, clash: String, fixture: URL) async throws -> Int {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("elarni-backup-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let secrets = MemorySecrets()
    func open() throws -> SubscriptionStore {
      let store = try SubscriptionStore(directory: directory,
        routing: RoutingStore(directory: directory.appendingPathComponent("routing")), secretAccess: secrets.access())
      store.publishRefresh = { [weak store] candidate in
        guard let store else { throw SubscriptionError.invalidState }
        _ = try store.beginPublication(candidate)
        try store.finishPublication(candidate)
      }
      return store
    }
    let store = try open()
    let localID = try store.registerProfiles(vless + "\n" + telegram)
    _ = try await store.refresh(id: localID)
    let clashID = try store.registerProfiles(clash)
    _ = try await store.refresh(id: clashID)
    let groups = store.snapshot()["subscriptions"] as! [[String: Any]]
    // The Clash import joins the local group.
    let clashNode = (groups[0]["nodes"] as! [[String: Any]]).first { ($0["groups"] as! [[String: Any]]).isEmpty == false }!["id"] as! String
    try store.commitSelection(nodeID: clashNode)
    _ = try await store.selectProfileGroup(nodeID: clashNode, group: "PROXY", choice: "two")
    _ = try await store.setNodeIPPreference(nodeID: clashNode, preference: "ipv6")
    let remoteID = try store.register(urlText: fixture.appendingPathComponent("feed").absoluteString)
    try rejects { _ = try store.backupCatalog() }
    var operation = try await store.refresh(id: remoteID)
    for _ in 0..<8 {
      guard let challenge = operation.warning?.challenge else { break }
      operation = try await store.refresh(id: remoteID, challenge: challenge)
    }
    try expect(operation.warning == nil, "backup fixture approvals did not converge")
    let backup = try store.backupCatalog()
    let previous = store.snapshot() as NSDictionary
    let routes = store.routing.snapshot() as NSDictionary
    let oldSecrets = secrets.values
    _ = try store.beginBackupRestore(backup)
    try expect(store.publicationInProgress && store.selectedNodeID() != clashNode, "restore did not stage fresh identities")
    try store.rollbackPublication()
    try expect((store.snapshot() as NSDictionary).isEqual(previous) &&
      (store.routing.snapshot() as NSDictionary).isEqual(routes) && secrets.values == oldSecrets,
      "backup rollback changed existing catalog, routes or secrets")
    _ = try store.beginBackupRestore(backup)
    let recovered = try open()
    try expect(!recovered.publicationInProgress && (recovered.snapshot() as NSDictionary).isEqual(previous) &&
      (recovered.routing.snapshot() as NSDictionary).isEqual(routes) && secrets.values == oldSecrets,
      "interrupted backup restore was not recovered")
    print("PASS backup rollback and relaunch preserve catalog routing selection and secrets")

    try expect(recovered.runtimeReconciliationRequired, "interrupted restore forgot saved-plan reconciliation")
    try rejects { _ = try recovered.beginBackupRestore(backup) }
    try recovered.finishRuntimeReconciliation()
    _ = try recovered.beginBackupRestore(backup)
    try recovered.finishBackupRestore()
    let restored = recovered.snapshot()["subscriptions"] as! [[String: Any]]
    try expect(restored.count == 2 && !secrets.values.keys.contains(where: { oldSecrets[$0] != nil }), "restore kept obsolete secrets")
    let restoredClash = (restored[0]["nodes"] as! [[String: Any]]).filter { ($0["groups"] as! [[String: Any]]).isEmpty == false }
    try expect(restoredClash[0]["ipPreference"] as? String == "ipv6", "backup lost IP preference")
    let restoredNodeID = restoredClash[0]["id"] as! String
    _ = try await recovered.refresh(id: restored[0]["id"] as! String)
    try expect(try recovered.ipPreference(nodeID: restoredNodeID) == "ipv6", "restored refresh lost IP preference")
    _ = try await recovered.setNodeIPPreference(nodeID: restoredNodeID, preference: nil)
    _ = try await recovered.refresh(id: restored[0]["id"] as! String)
    try expect(try recovered.ipPreference(nodeID: restoredNodeID) == nil, "refresh resurrected cleared IP preference")
    try expect((restoredClash[0]["groups"] as! [[String: Any]])[0]["selected"] as? String == "two" &&
      recovered.selectedNodeID() == restoredClash[0]["id"] as? String, "backup lost group choice or selection")
    try expect((recovered.routing.snapshot()["profiles"] as! [[String: Any]]).count ==
      (routes["profiles"] as! [[String: Any]]).count, "backup lost routing profiles")
    let restoredRemote = restored[1]["id"] as! String
    try expect((recovered.routing.snapshot()["assignments"] as! [String: String])[restoredRemote] != nil, "routing assignment was not remapped")
    let refresh = try await recovered.refresh(id: restoredRemote)
    try expect(refresh.warning != nil, "restore reused a source trust approval")
    let mixedID = restored[0]["id"] as! String
    _ = try await recovered.refresh(id: mixedID)
    let mixed = (recovered.snapshot()["subscriptions"] as! [[String: Any]])[0]["nodes"] as! [[String: Any]]
    try expect(mixed.count == 3 && recovered.telegramURL(nodeID: mixed[1]["id"] as! String).scheme == "tg", "restored mixed local source failed refresh")
    _ = try open().outbound(nodeID: restoredClash[0]["id"] as! String)
    print("PASS backup restores mixed profiles groups routing and selection with fresh trust")

    var malformed = backup
    malformed["selectedNodeId"] = "missing"
    let before = recovered.snapshot() as NSDictionary
    try rejects { _ = try recovered.beginBackupRestore(malformed) }
    try expect((recovered.snapshot() as NSDictionary).isEqual(before), "invalid backup partially published")
    let hidden = try recovered.registerProfiles("#hide-url: yes\n" + vless)
    _ = try await recovered.refresh(id: hidden)
    try rejects { _ = try recovered.backupCatalog() }
    print("PASS unknown and hidden provider backup restrictions and invalid restore are enforced")
    return 3
  }

  static func refreshConcurrencyChecks(fixture: URL) async throws -> Int {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("elarni-refresh-queue-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let secrets = MemorySecrets()
    let store = try SubscriptionStore(directory: directory,
      routing: RoutingStore(directory: directory.appendingPathComponent("routing")), secretAccess: secrets.access())
    var blockNext = false
    var release: CheckedContinuation<Void, Never>?
    let (entered, enteredEvents) = AsyncStream<Void>.makeStream()
    var enteredIterator = entered.makeAsyncIterator()
    let (enqueued, enqueuedEvents) = AsyncStream<Void>.makeStream()
    var enqueuedIterator = enqueued.makeAsyncIterator()
    defer { enteredEvents.finish(); enqueuedEvents.finish() }
    var formats: [String] = []
    store.publishRefresh = { candidate in
      if blockNext {
        blockNext = false
        await withCheckedContinuation { continuation in
          release = continuation
          enteredEvents.yield(())
        }
      }
      try Task.checkCancellation()
      _ = try store.beginPublication(candidate)
      try store.finishPublication(candidate)
      let groups = store.snapshot()["subscriptions"] as! [[String: Any]]
      formats.append(groups[0]["format"] as! String)
    }
    let id = try store.register(urlText: fixture.appendingPathComponent("feed").absoluteString)
    var result = try await store.refresh(id: id)
    for _ in 0..<8 {
      guard let challenge = result.warning?.challenge else { break }
      result = try await store.refresh(id: id, challenge: challenge)
    }
    try expect(result.warning == nil && formats == ["source"], "refresh queue fixture did not publish")
    func enqueue(format: String? = nil, challenge: String? = nil) -> Task<SubscriptionOperationResult, Error> {
      Task { @MainActor in
        enqueuedEvents.yield(())
        return try await store.refresh(id: id, challenge: challenge, format: format)
      }
    }

    blockNext = true
    let owner = Task { try await store.refresh(id: id, interactive: false) }
    _ = await enteredIterator.next()
    let cancelledWaiter = enqueue(format: "json")
    _ = await enqueuedIterator.next()
    cancelledWaiter.cancel()
    release!.resume()
    _ = try await owner.value
    do { _ = try await cancelledWaiter.value; throw Failure(message: "cancelled refresh waiter succeeded") }
    catch is CancellationError { }
    try expect(formats == ["source", "source"], "waiter cancellation cancelled the owner or published another format")
    print("PASS cancelling a queued refresh leaves its current owner running")

    blockNext = true
    let automatic = Task { try await store.refresh(id: id, interactive: false) }
    _ = await enteredIterator.next()
    let foreground = enqueue(format: "json")
    _ = await enqueuedIterator.next()
    release!.resume()
    let backgroundResult = try await automatic.value
    let foregroundResult = try await foreground.value
    try expect(backgroundResult.warning == nil && foregroundResult.warning != nil,
      "foreground format or interactive approval was replaced by the background result")
    print("PASS queued foreground refresh retains its format and interactive approval")

    blockNext = true
    let beforeApproval = Task { try await store.refresh(id: id, interactive: false) }
    _ = await enteredIterator.next()
    let approved = enqueue(format: "json", challenge: foregroundResult.warning!.challenge)
    _ = await enqueuedIterator.next()
    release!.resume()
    _ = try await beforeApproval.value
    var approvedResult = try await approved.value
    for _ in 0..<8 {
      guard let challenge = approvedResult.warning?.challenge else { break }
      approvedResult = try await store.refresh(id: id, challenge: challenge, format: "json")
    }
    try expect(approvedResult.warning == nil && formats.last == "json", "queued refresh discarded its approval challenge")
    print("PASS queued refresh consumes its own approval challenge")

    blockNext = true
    let optionsOwner = Task { try await store.refresh(id: id) }
    _ = await enteredIterator.next()
    _ = try store.updateFetchOptions(id: id, options: ["fallbackHosts": [String]()])
    release!.resume()
    do { _ = try await optionsOwner.value; throw Failure(message: "obsolete fetch options published") }
    catch is CancellationError { }
    let afterOptions = try await store.refresh(id: id)
    try expect(afterOptions.warning == nil, "changed fetch options left a cancelled refresh cached")
    print("PASS changing fetch options cancels obsolete work and permits the next refresh")

    blockNext = true
    let lastOwner = Task { try await store.refresh(id: id) }
    _ = await enteredIterator.next()
    let lastWaiter = enqueue()
    _ = await enqueuedIterator.next()
    store.cancelRefreshes()
    release!.resume()
    for task in [lastOwner, lastWaiter] {
      do { _ = try await task.value; throw Failure(message: "cancel-all allowed queued refresh to restart") }
      catch is CancellationError { }
    }
    _ = try await store.refresh(id: id)
    print("PASS cancel-all stops current and queued refreshes without blocking future requests")
    return 5
  }

  static func nodeEditChecks() async throws -> Int {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("elarni-node-edit-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let secrets = MemorySecrets()
    func open() throws -> SubscriptionStore {
      let store = try SubscriptionStore(directory: directory,
        routing: RoutingStore(directory: directory.appendingPathComponent("routing")), secretAccess: secrets.access())
      store.publishRefresh = { [weak store] candidate in
        guard let store else { throw SubscriptionError.invalidState }
        _ = try store.beginPublication(candidate)
        try store.finishPublication(candidate)
      }
      return store
    }
    func nodes(_ store: SubscriptionStore) -> [[String: Any]] {
      (store.snapshot()["subscriptions"] as! [[String: Any]])[0]["nodes"] as! [[String: Any]]
    }
    var store = try open()
    let id = try store.registerProfiles("socks://127.0.0.1:1080#First\nsocks://127.0.0.1:1081#Second\nsocks://127.0.0.1:1082#Third")
    _ = try await store.refresh(id: id)
    let ids = nodes(store).map { $0["id"] as! String }
    try store.commitSelection(nodeID: ids[0])
    _ = try store.renameNode(id: ids[1], name: " Mine ")
    try rejects { _ = try store.renameNode(id: ids[1], name: "bad\u{0}name") }
    _ = try await store.refresh(id: id)
    store = try open()
    try expect(nodes(store).map { $0["name"] as! String } == ["First", "Mine", "Third"], "a server name was lost across refresh and relaunch")
    try expect(try store.sharingText(id: ids[1], subscription: false).contains(#""remarks":"Mine""#), "sharing used the provider name")
    _ = try store.renameNode(id: ids[1], name: "")
    try expect(nodes(store)[1]["name"] as? String == "Second", "an empty name did not restore the provider's")
    print("PASS a renamed server keeps its name across refresh and relaunch, and an empty name restores the provider's")

    let ref = try store.outboundRef(nodeID: ids[2])
    try rejects { _ = try store.deleteNode(id: ids[0]) }
    // A selection with the selected server, or one that would empty the group, deletes nothing.
    try rejects { _ = try store.deleteNodes(ids: [ids[2], ids[0]]) }
    try rejects { _ = try store.deleteNodes(ids: [ids[2], ids[1], ids[0]]) }
    try expect(nodes(store).count == 3, "a refused selection deleted servers")
    _ = try store.deleteNode(id: ids[2])
    store = try open()
    try expect(nodes(store).map { $0["id"] as! String } == Array(ids[0...1]) && store.selectedNodeID() == ids[0],
      "deleting a server changed the others or the selection")
    try store.reclaimRetiredSecrets()
    try expect(secrets.values.keys.allSatisfy { !$0.hasSuffix(ref) }, "a deleted server's secret was kept")
    _ = try store.deleteNode(id: ids[1])
    try rejects { _ = try store.deleteNode(id: ids[0]) }
    print("PASS deleting a server keeps the selected and last ones and reclaims its secret")
    return 2
  }

  static func hiddenServerChecks(fixture: URL) async throws -> Int {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("elarni-hidden-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let secrets = MemorySecrets()
    func open() throws -> SubscriptionStore {
      let store = try SubscriptionStore(directory: directory,
        routing: RoutingStore(directory: directory.appendingPathComponent("routing")), secretAccess: secrets.access())
      store.publishRefresh = { [weak store] candidate in
        guard let store else { throw SubscriptionError.invalidState }
        _ = try store.beginPublication(candidate)
        try store.finishPublication(candidate)
      }
      return store
    }
    func mode(_ value: String) async throws {
      _ = try await URLSession.shared.data(from: fixture.appendingPathComponent("mode")
        .appending(queryItems: [URLQueryItem(name: "value", value: value)]))
    }
    func group(_ store: SubscriptionStore) -> [String: Any] { (store.snapshot()["subscriptions"] as! [[String: Any]])[0] }
    func names(_ store: SubscriptionStore) -> [String] { (group(store)["nodes"] as! [[String: Any]]).map { $0["name"] as! String } }
    try await mode("three_servers")
    var store = try open()
    let id = try store.register(urlText: fixture.appendingPathComponent("feed").absoluteString)
    var operation = try await store.refresh(id: id)
    for _ in 0..<8 {
      guard let challenge = operation.warning?.challenge else { break }
      operation = try await store.refresh(id: id, challenge: challenge)
    }
    try expect(operation.warning == nil && names(store) == ["First", "Second", "Third"], "the three-server feed did not import")
    let ids = (group(store)["nodes"] as! [[String: Any]]).map { $0["id"] as! String }
    try store.commitSelection(nodeID: ids[0])
    _ = try store.renameNode(id: ids[1], name: "Mine")
    _ = try store.setFavorite(nodeID: ids[1], favorite: true)
    let ref = try store.outboundRef(nodeID: ids[2])
    _ = try store.deleteNode(id: ids[2])
    _ = try await store.refresh(id: id)
    store = try open()
    try store.reclaimRetiredSecrets()
    try expect(names(store) == ["First", "Mine"], "a refresh added a hidden server back")
    try expect((group(store)["hiddenNodes"] as! [[String: Any]]).map { $0["id"] as! String } == [ids[2]], "the hidden server was not listed")
    try expect(secrets.values.keys.contains { $0.hasSuffix(ref) }, "a hidden server's secret was reclaimed")
    _ = try store.beginBackupRestore(try store.backupCatalog())
    try store.finishBackupRestore()
    guard let mine = (group(store)["nodes"] as! [[String: Any]]).first(where: { $0["name"] as? String == "Mine" }) else {
      throw Failure(message: "a restore lost a renamed server")
    }
    try expect(mine["favorite"] as? Bool == true, "a restore lost a favorite")
    let hidden = group(store)["hiddenNodes"] as! [[String: Any]]
    try expect(hidden.map { $0["name"] as! String } == ["Third"], "a restore lost the hidden server")
    _ = try store.renameNode(id: mine["id"] as! String, name: "")
    try expect(names(store) == ["First", "Second"], "a restore lost the provider's name of a renamed server")
    _ = try store.showNode(id: hidden[0]["id"] as! String)
    try expect(names(store) == ["First", "Second", "Third"] && (group(store)["hiddenNodes"] as! [[String: Any]]).isEmpty,
      "a hidden server was not shown again")
    print("PASS a hidden provider server stays hidden across refresh, relaunch and restore, which keeps renames and favorites")
    // The restore gave the subscription and its servers new IDs.
    let current = (group(store)["nodes"] as! [[String: Any]]).map { $0["id"] as! String }
    try expect(store.selectedNodeID() == current[0], "a restore lost the selection")
    try rejects { _ = try store.deleteNodes(ids: [current[1], current[0]]) }
    try expect(names(store) == ["First", "Second", "Third"], "a refused selection hid servers")
    _ = try store.deleteNodes(ids: [current[1], current[2]])
    _ = try await store.refresh(id: group(store)["id"] as! String)
    try expect(names(store) == ["First"] && (group(store)["hiddenNodes"] as! [[String: Any]]).count == 2,
      "servers hidden together came back with a refresh")
    try await mode("baseline")
    print("PASS servers hidden together stay hidden, and a selection with the selected server hides none")
    return 2
  }

  static func selectionPublicationChecks() async throws -> Int {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("elarni-selection-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let secrets = MemorySecrets()
    func open() throws -> SubscriptionStore {
      try SubscriptionStore(directory: directory,
        routing: RoutingStore(directory: directory.appendingPathComponent("routing")), secretAccess: secrets.access())
    }
    var store = try open()
    store.publishRefresh = { [weak store] candidate in
      guard let store else { throw SubscriptionError.invalidState }
      _ = try store.beginPublication(candidate)
      try store.finishPublication(candidate)
    }
    let id = try store.registerProfiles("socks://127.0.0.1:1080#First\nsocks://127.0.0.1:1081#Second")
    _ = try await store.refresh(id: id)
    let group = (store.snapshot()["subscriptions"] as! [[String: Any]])[0]
    let nodes = group["nodes"] as! [[String: Any]]
    let first = nodes[0]["id"] as! String, second = nodes[1]["id"] as! String
    try store.commitSelection(nodeID: first)
    _ = try store.routing.importContent(#"{"Name":"Selection rules","RemoteDNSType":"DoU","RemoteDNSIP":"1.1.1.1","DomesticDNSType":"DoU","DomesticDNSIP":"8.8.8.8","DirectSites":["full:example.com"]}"#,
      selectedSubscriptionID: id)
    let originalRouting = try store.routing.checkpoint()
    // Reopening models host termination at either side of the catalog write.
    // No installed provider is needed to expose loss of the durable marker.
    for catalogWritten in [false, true] {
      try store.beginSelectionPublication()
      try rejects { try store.beginSelectionPublication() }
      if catalogWritten { try store.commitSelection(nodeID: second) }
      store = try open()
      try expect(store.selectedNodeID() == first && store.runtimeReconciliationRequired,
        "interrupted selection lost prior node or runtime recovery obligation")
      try expect(try store.routing.checkpoint() == originalRouting, "selection recovery changed routing")
      try rejects { try store.beginSelectionPublication() }
      try store.finishRuntimeReconciliation()
    }
    print("PASS interrupted selection before/after catalog write restores prior node and requires runtime reconciliation")
    try store.beginSelectionPublication()
    try store.finishSelectionPublication(nodeID: second)
    store = try open()
    try expect(store.selectedNodeID() == second && !store.runtimeReconciliationRequired && !store.publicationInProgress,
      "completed selection did not survive reopening")
    print("PASS completed selection removes journal only after durable catalog commit")
    try store.beginSelectionPublication()
    try rejects { try store.finishSelectionPublication(nodeID: "missing-node") }
    try expect(store.publicationInProgress, "failed selection commit discarded journal")
    try store.rollbackPublication(recoveringAfterInterruption: true)
    store = try open()
    try expect(store.selectedNodeID() == second && store.runtimeReconciliationRequired,
      "cancelled selection did not retain recovery state")
    print("PASS failed or cancelled selection retains runtime recovery until explicitly reconciled")
    return 3
  }

  static func transactionChecks(fixture: URL) async throws -> Int {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("elarni-transactions-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let secrets = MemorySecrets()
    func open() throws -> SubscriptionStore {
      try SubscriptionStore(directory: directory, routing: RoutingStore(directory: directory.appendingPathComponent("routing")), secretAccess: secrets.access())
    }
    let store = try open()
    store.jitter = { 0 }
    store.now = { Date(timeIntervalSince1970: 1_700_000_000) }
    var publications = 0
    store.publishRefresh = { candidate in
      publications += 1
      _ = try store.beginPublication(candidate)
      try store.finishPublication(candidate)
    }
    func nodes(_ store: SubscriptionStore) -> [[String: Any]] {
      let groups = store.snapshot()["subscriptions"] as! [[String: Any]]
      return groups.flatMap { $0["nodes"] as! [[String: Any]] }
    }
    func mode(_ value: String) async throws {
      let (_, response) = try await URLSession.shared.data(from: fixture.appendingPathComponent("mode").appending(queryItems: [URLQueryItem(name: "value", value: value)]))
      try expect((response as? HTTPURLResponse)?.statusCode == 200, "fixture mode update")
    }
    let id = try store.register(urlText: fixture.appendingPathComponent("redirect").absoluteString)
    let first = try await store.refresh(id: id)
    try expect(first.warning != nil && publications == 0 && nodes(store).isEmpty, "unsafe source fetched before approval")
    let second = try await store.refresh(id: id, challenge: first.warning!.challenge)
    try expect(second.warning != nil && publications == 0, "unsafe redirect bypassed approval")
    let third = try await store.refresh(id: id, challenge: second.warning!.challenge)
    try expect(third.warning != nil && publications == 0, "unsafe account-info request bypassed approval")
    _ = try await store.refresh(id: id, challenge: third.warning!.challenge)
    try expect(publications == 1 && nodes(store).count == 1, "approved redirect did not publish")
    let selected = nodes(store)[0]["id"] as! String
    try store.commitSelection(nodeID: selected)
    let originalRef = try store.outboundRef(nodeID: selected)
    let originalData = secrets.data(originalRef)
    let approvalsRef = "subscription.\(id).safety-approvals"
    let originalApprovals = secrets.data(approvalsRef)
    try expect(originalData != nil && originalApprovals != nil, "published secret/approval missing")
    let group = (store.snapshot()["subscriptions"] as! [[String: Any]])[0]
    try expect((group["nextRefreshAt"] as! Double) - (group["lastSuccessfulFetch"] as! Double) == 6 * 3600,
      "successful subscription refresh did not follow the provider's six-hour interval")
    try expect((group["metadata"] as? [String: Any])?["updateIntervalHours"] as? Int == 6, "the provider's interval is not shown")
    func scheduledHours() -> Double {
      let current = (store.snapshot()["subscriptions"] as! [[String: Any]])[0]
      return ((current["nextRefreshAt"] as! Double) - (current["lastSuccessfulFetch"] as! Double)) / 3600
    }
    _ = try store.updateFetchOptions(id: id, options: ["fallbackHosts": [String](), "refreshHours": "2"])
    try expect(scheduledHours() == 2, "the user's refresh interval did not override the provider's")
    let overridden = try await store.refresh(id: id)
    try expect(overridden.warning == nil && scheduledHours() == 2, "a refresh with the override did not keep it")
    for bad in ["0", "169", "1.5", "soon", "02"] {
      do {
        _ = try store.updateFetchOptions(id: id, options: ["fallbackHosts": [String](), "refreshHours": bad])
        throw Failure(message: "refresh interval \(bad) accepted")
      } catch SubscriptionError.invalidURL {}
    }
    _ = try store.updateFetchOptions(id: id, options: ["fallbackHosts": [String]()])
    try expect(scheduledHours() == 6, "clearing the override did not restore the provider's interval")
    print("PASS a refresh follows the provider interval unless the user sets one")
    let metadata = group["metadata"] as! [String: Any]
    try expect(metadata["upload"] as? Int64 == 1024 && metadata["expire"] as? Int64 == 2000000000 && metadata["enabled"] as? Bool == true, "provider metadata not published")
    try expect(Set(group["actions"] as! [String]) == Set(["account", "support", "raw", "json", "clash", "banner"]), "advertised provider formats missing")
    try expect(metadata["bannerText"] as? String == "Free provider notice" &&
      store.providerURL(subscriptionID: id, action: "banner").absoluteString == "https://provider.example/notice?fixture=token", "banner action missing")
    let serializedCatalog = try String(contentsOf: directory.appendingPathComponent("subscriptions-v1.json"), encoding: .utf8)
    try expect(!serializedCatalog.contains("fixture=token") && !serializedCatalog.contains("provider.example"), "provider action token leaked to catalog")
    try expect(try store.providerURL(subscriptionID: id, action: "support").host == "provider.example", "provider link not available through secret reference")
    print("PASS approved source redirect and account-info publish metadata with secure provider links")

    _ = try await store.refresh(id: id)
    try expect(try store.outboundRef(nodeID: selected) == originalRef,
      "unchanged remote refresh replaced the active configuration")
    try store.reclaimRetiredSecrets()
    try expect(secrets.data(originalRef) == originalData, "refresh reclaimed a reused active secret")
    _ = try open().outbound(nodeID: selected)
    store.publishRefresh = { candidate in
      _ = try store.beginPublication(candidate)
      try store.rollbackPublication()
      throw SubscriptionError.fetchFailed
    }
    do { _ = try await store.refresh(id: id); throw Failure(message: "rollback fixture succeeded") }
    catch SubscriptionError.fetchFailed { }
    try store.reclaimRetiredSecrets()
    try expect(secrets.data(originalRef) == originalData, "rollback reclaimed a reused active secret")
    _ = try open().outbound(nodeID: selected)
    print("PASS unchanged refresh and rollback preserve the selected runtime and credentials")
    let originalRouting = store.routing.snapshot() as NSDictionary

    do {
      try await mode("updated")
      store.publishRefresh = { candidate in
        _ = try store.beginPublication(candidate)
        try store.rollbackPublication()
        throw SubscriptionError.fetchFailed
      }
      do { _ = try await store.refresh(id: id); throw Failure(message: "publication failure succeeded") }
      catch SubscriptionError.fetchFailed { }
      try expect(store.selectedNodeID() == selected && store.selectedOutboundRef() == originalRef, "rollback changed selected node")
      try expect((store.routing.snapshot() as NSDictionary).isEqual(originalRouting), "rollback changed routing")
      try expect(secrets.data(approvalsRef) == originalApprovals && secrets.data(originalRef) == originalData, "rollback changed approval/active secret")
      try store.reclaimRetiredSecrets()
      try expect(secrets.data(originalRef) == originalData, "rollback reclaimed active secret")
    }
    print("PASS failed publication restores selection routing approvals and active credentials")

    // Leave the real transaction marker on disk, as if the process stopped mid-publication.
    store.publishRefresh = { candidate in
      _ = try store.beginPublication(candidate)
      throw SubscriptionError.fetchFailed
    }
    do { _ = try await store.refresh(id: id); throw Failure(message: "interrupted publication succeeded") }
    catch SubscriptionError.fetchFailed { }
    try expect(store.publicationInProgress, "pending transaction marker missing")
    let recovered = try open()
    try expect(!recovered.publicationInProgress && recovered.selectedOutboundRef() == originalRef, "relaunch did not recover transaction")
    try expect((recovered.routing.snapshot() as NSDictionary).isEqual(originalRouting), "relaunch routing rollback")
    try expect(recovered.runtimeReconciliationRequired && (try open()).runtimeReconciliationRequired,
      "relaunch forgot that a candidate provider or saved plan may still be active")
    let retainedSecrets = secrets.values
    try rejects { try recovered.reclaimRetiredSecrets() }
    do { _ = try await recovered.refresh(id: id); throw Failure(message: "unreconciled runtime accepted publication") }
    catch SubscriptionError.invalidState { }
    try expect(secrets.values == retainedSecrets, "recovery reclaimed credentials before runtime reconciliation")
    // The native controller must first stop/disarm and replace the saved plan.
    try recovered.finishRuntimeReconciliation()
    try expect(!(try open()).runtimeReconciliationRequired, "confirmed runtime recovery was not durable")
    try recovered.reclaimRetiredSecrets()
    try expect(secrets.data(originalRef) == originalData && secrets.data(approvalsRef) == originalApprovals, "recovery deleted active credentials")
    print("PASS reopening the store recovers interrupted durable publication")

    recovered.publishRefresh = { candidate in
      _ = try recovered.beginPublication(candidate)
      try recovered.finishPublication(candidate)
    }
    _ = try await recovered.refresh(id: id)
    let updatedRef = try recovered.outboundRef(nodeID: selected)
    try expect(updatedRef != originalRef && secrets.data(updatedRef) != nil && secrets.data(originalRef) != nil, "old credentials retired before owner release")
    try recovered.reclaimRetiredSecrets()
    try expect(secrets.data(originalRef) == nil && secrets.data(updatedRef) != nil, "successful publication reclamation")
    print("PASS successful publication delays reclamation until active owners release")

    for value in ["malformed", "oversized", "device_limit"] {
      try await mode(value)
      do { _ = try await recovered.refresh(id: id); throw Failure(message: "invalid feed published") }
      catch is Failure { throw Failure(message: "invalid feed published") }
      catch { }
      try expect(recovered.selectedOutboundRef() == updatedRef && secrets.data(updatedRef) != nil, "invalid feed discarded last working node")
      if value == "device_limit" {
        let group = (recovered.snapshot()["subscriptions"] as! [[String: Any]])[0]
        try expect(group["status"] as? String == "device_limit", "HWID rejection reported as generic 404")
      }
    }
    print("PASS malformed and oversized HTTP responses preserve working nodes")

    for (value, code) in [("status_404", "subscription_unavailable"), ("status_403", "subscription_denied"),
                          ("status_429", "rate_limited"), ("status_503", "provider_error")] {
      try await mode(value)
      do { _ = try await recovered.refresh(id: id); throw Failure(message: "failed feed published") }
      catch SubscriptionError.fetchClass(let cause) where cause == code { }
      catch let failure as Failure { throw failure }
      catch { throw Failure(message: "\(value) refresh failed as \(error), not \(code)") }
    }
    print("PASS a failed refresh keeps its cause: removed, refused, rate-limited or provider error")

    try await mode("baseline")
    secrets.failApprovalWrites = true
    do { _ = try await recovered.refresh(id: id); throw Failure(message: "failed approval write published") }
    catch SubscriptionError.keychainFailure { }
    try expect(recovered.publicationRecoveryRequired && recovered.publicationInProgress, "incomplete rollback did not block publication")
    try expect(recovered.dueSubscriptions().isEmpty && secrets.data(updatedRef) != nil, "recovery-required store scheduled work or lost active secret")
    do { _ = try await recovered.refresh(id: id); throw Failure(message: "refresh bypassed recovery guard") }
    catch SubscriptionError.invalidState { }
    secrets.failApprovalWrites = false
    let repaired = try open()
    try expect(!repaired.publicationRecoveryRequired && repaired.selectedOutboundRef() == updatedRef, "recovery could not retry after secret store recovered")
    try repaired.finishRuntimeReconciliation()
    print("PASS unconfirmed rollback blocks refresh until durable recovery succeeds")

    let (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
    var resumePublication: CheckedContinuation<Void, Never>?
    repaired.publishRefresh = { candidate in
      _ = try repaired.beginPublication(candidate)
      await withCheckedContinuation { continuation in
        resumePublication = continuation
        enteredContinuation.yield(())
      }
      do {
        try Task.checkCancellation()
        try repaired.finishPublication(candidate)
      } catch {
        try repaired.rollbackPublication()
        throw error
      }
    }
    let refresh = Task { try await repaired.refresh(id: id) }
    var iterator = entered.makeAsyncIterator()
    _ = await iterator.next()
    refresh.cancel()
    resumePublication!.resume()
    do { _ = try await refresh.value; throw Failure(message: "cancelled publication succeeded") }
    catch is CancellationError { }
    enteredContinuation.finish()
    try expect(!repaired.publicationInProgress && repaired.selectedOutboundRef() == updatedRef, "cancelled publication retained candidate")
    try repaired.reclaimRetiredSecrets()
    try expect(secrets.data(updatedRef) != nil, "cancellation reclaimed active secret")
    print("PASS cancellation during publication rolls back before reclaiming candidates")

    repaired.publishRefresh = { candidate in
      _ = try repaired.beginPublication(candidate)
      try repaired.finishPublication(candidate)
    }
    for value in ["dual_routing", "base64_dual_routing", "body_routing"] {
      try await mode(value)
      _ = try await repaired.refresh(id: id)
      let snapshot = repaired.routing.snapshot()
      let profiles = snapshot["profiles"] as! [[String: Any]]
      try expect(profiles.count == 1, "provider routing was duplicated")
      let profile = try JSONSerialization.jsonObject(with: Data((profiles[0]["json"] as! String).utf8)) as! [String: Any]
      try expect(profile["RemoteDNSIP"] as? String == "9.9.9.9" &&
        profile["DirectSites"] as? [String] == ["full:body.example"], "body routing did not take precedence")
      try expect((snapshot["assignments"] as! [String: String])[id] == profiles[0]["id"] as? String &&
        repaired.selectedNodeID() == selected, "routing publication lost assignment or server selection")
    }
    print("PASS header and body routing publish in order for plaintext and base64 feeds")
    // 3x-ui sends its Happ routing header to every client (3x-ui #5999).
    try await mode("addressed_routing")
    _ = try await repaired.refresh(id: id)
    let addressed = (repaired.routing.snapshot()["profiles"] as! [[String: Any]])[0]
    let addressedProfile = try JSONSerialization.jsonObject(with: Data((addressed["json"] as! String).utf8)) as! [String: Any]
    try expect(addressedProfile["RemoteDNSIP"] as? String == "1.1.1.1", "another client's routing won over routing addressed to Elarni")
    print("PASS routing addressed to Elarni wins over other clients' routing")

    let acceptedRef = repaired.selectedOutboundRef()
    let acceptedRouting = repaired.routing.snapshot() as NSDictionary
    for value in ["bad_header_routing", "bad_body_routing"] {
      try await mode(value)
      do { _ = try await repaired.refresh(id: id); throw Failure(message: "malformed routing directive published") }
      catch RoutingStoreError.invalidImport { }
      try expect(repaired.selectedOutboundRef() == acceptedRef &&
        (repaired.routing.snapshot() as NSDictionary).isEqual(acceptedRouting), "invalid routing replaced working state")
    }
    print("PASS malformed header or body routing preserves the published catalog")

    try await mode("body_routing_off")
    _ = try await repaired.refresh(id: id)
    try expect((repaired.routing.snapshot()["assignments"] as! [String: String])[id] == nil &&
      repaired.selectedNodeID() == selected, "final routing-off directive was not applied")
    print("PASS final body routing-off overrides the header without removing servers")
    let beforeMigration = try repaired.sharingText(id: id, subscription: true)
    try await mode("migration")
    repaired.publishRefresh = { candidate in
      _ = try repaired.beginPublication(candidate)
      try repaired.rollbackPublication()
      throw Failure(message: "migration publication fixture")
    }
    do { _ = try await repaired.refresh(id: id); throw Failure(message: "migration rollback not exercised") }
    catch let error as Failure { try expect(error.message == "migration publication fixture", "unexpected migration failure") }
    try expect(repaired.sharingText(id: id, subscription: true) == beforeMigration && repaired.selectedNodeID() == selected,
      "failed migration replaced source or selection")
    repaired.publishRefresh = { candidate in
      _ = try repaired.beginPublication(candidate)
      try repaired.finishPublication(candidate)
    }
    _ = try await repaired.refresh(id: id)
    try expect(repaired.sharingText(id: id, subscription: true).contains("migrated=token"), "new source URL not published")
    try expect(!(repaired.snapshot()["subscriptions"] as! [[String: Any]])[0].description.contains("migrated=token"), "migration URL exposed in snapshot")
    let migrated = try await repaired.refresh(id: id)
    try expect(migrated.warning != nil, "new source reused old approval")
    var challenge = migrated.warning?.challenge
    for _ in 0..<8 {
      guard let current = challenge else { break }
      challenge = try await repaired.refresh(id: id, challenge: current).warning?.challenge
    }
    try expect(challenge == nil, "migration approval did not converge")
    let idempotent = try await repaired.refresh(id: id)
    try expect(idempotent.warning == nil && repaired.selectedNodeID() == selected, "migration was not idempotent")
    print("PASS URL migration publishes atomically and needs distinct source approval")
    try await mode("baseline")
    let unavailable = fixture.appendingPathComponent("feed").absoluteString.replacingOccurrences(of: "127.0.0.1", with: "127.0.0.2")
    let fallbackID = try repaired.register(urlText: unavailable)
    _ = try repaired.updateFetchOptions(id: fallbackID, options: ["fallbackHosts": ["127.0.0.1"]])
    var fallbackResult = try await repaired.refresh(id: fallbackID)
    for _ in 0..<8 {
      guard let warning = fallbackResult.warning else { break }
      fallbackResult = try await repaired.refresh(id: fallbackID, challenge: warning.challenge)
    }
    let fallbackGroup = (repaired.snapshot()["subscriptions"] as! [[String: Any]]).first { $0["id"] as? String == fallbackID }!
    try expect(fallbackResult.warning == nil && (fallbackGroup["nodes"] as! [[String: Any]]).count == 1 &&
      fallbackGroup["fallbackHosts"] as? [String] == ["127.0.0.1"], "fallback did not retain ordered approvals or settings")
    let reusedFallback = try await repaired.refresh(id: fallbackID)
    try expect(reusedFallback.warning == nil, "fallback approvals were not reusable")
    do {
      _ = try repaired.updateFetchOptions(id: fallbackID, options: ["fallbackHosts": [], "httpHost": "provider.example"])
      throw Failure(message: "HTTP fronting accepted")
    } catch SubscriptionError.invalidURL {}
    let secureID = try repaired.register(urlText: "https://127.0.0.1:443/secure")
    let secureOptions: [String: Any] = ["fallbackHosts": [String](), "connectAddress": "127.0.0.1",
      "httpHost": "provider.example", "fragmentLength": "80-250", "fragmentInterval": "10-100"]
    _ = try repaired.updateFetchOptions(id: secureID, options: secureOptions)
    let secureGroup = (repaired.snapshot()["subscriptions"] as! [[String: Any]]).first { $0["id"] as? String == secureID }!
    try expect((secureGroup["fetchOptions"] as? [String: String])?["fragmentLength"] == "80-250", "download options did not persist")
    print("PASS subscription fallback preserves settings and approves each attempted target")
    try await mode("user_agent")
    let agentID = try repaired.register(urlText: fixture.appendingPathComponent("feed").absoluteString + "?agent=1")
    _ = try repaired.updateFetchOptions(id: agentID, options: ["fallbackHosts": [String](), "userAgent": "FixtureClient/1.0"])
    do {
      var agentResult = try await repaired.refresh(id: agentID)
      for _ in 0..<8 {
        guard let warning = agentResult.warning else { break }
        agentResult = try await repaired.refresh(id: agentID, challenge: warning.challenge)
      }
    } catch { throw Failure(message: "the subscription's user agent was not sent") }
    try await mode("baseline")
    print("PASS a subscription's user agent replaces Elarni's")
    let longID = try repaired.register(urlText: fixture.appendingPathComponent("long/0").absoluteString)
    var longResult = try await repaired.refresh(id: longID)
    for _ in 0..<8 {
      guard let warning = longResult.warning else { break }
      longResult = try await repaired.refresh(id: longID, challenge: warning.challenge)
    }
    try expect(longResult.warning == nil, "redirect and info approvals did not converge")
    let reusedLong = try await repaired.refresh(id: longID)
    try expect(reusedLong.warning == nil, "more than six approvals could not be reloaded")
    print("PASS redirect and companion-info approval chains persist beyond six targets")
    // Happ's fallback-url: the provider's backup URL serves the subscription while its main URL fails.
    let backupID = try repaired.register(urlText: fixture.appendingPathComponent("feed").absoluteString + "?provider=backup")
    for value in ["fallback", "status_503"] {
      try await mode(value)
      var backupResult = try await repaired.refresh(id: backupID)
      for _ in 0..<8 {
        guard let warning = backupResult.warning else { break }
        backupResult = try await repaired.refresh(id: backupID, challenge: warning.challenge)
      }
      try expect(backupResult.warning == nil, "\(value) approvals did not converge")
    }
    try await mode("baseline")
    let backupGroup = (repaired.snapshot()["subscriptions"] as! [[String: Any]]).first { $0["id"] as? String == backupID }!
    try expect((backupGroup["nodes"] as! [[String: Any]]).map { $0["name"] as? String } == ["Backup"],
      "the provider's fallback URL did not serve the subscription")
    try expect(!backupGroup.description.contains("fallback=token"), "fallback URL exposed in snapshot")
    print("PASS the provider's fallback URL serves the subscription while its main URL fails")
    return 18
  }
}
