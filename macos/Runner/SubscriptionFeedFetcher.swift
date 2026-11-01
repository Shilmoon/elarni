import CryptoKit
import Foundation
import Security

enum SubscriptionDeviceIdentity {
#if os(iOS)
  static let operatingSystem = "iOS"
  static let model = "iPhone"
#else
  static let operatingSystem = "macOS"
  static let model = "Mac"
#endif
  static func headers(installationID: String, url: URL) -> [String: String] {
    let scheme = url.scheme?.lowercased() ?? "https"
    let origin = "\(scheme)://\(url.host?.lowercased() ?? ""):\(url.port ?? (scheme == "https" ? 443 : 80))"
    let digest = HMAC<SHA256>.authenticationCode(for: Data(origin.utf8), using: SymmetricKey(data: Data(installationID.utf8)))
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"
    return ["X-HWID": digest.map { String(format: "%02x", $0) }.joined(),
      "X-Device-OS": operatingSystem, "X-Ver-OS": ProcessInfo.processInfo.operatingSystemVersionString,
      "X-Device-Model": model, "User-Agent": "Elarni/\(version) (Xray; \(operatingSystem))"]
  }
}
struct ProviderMetadata: Codable {
  var upload: Int64?
  var download: Int64?
  var total: Int64?
  var expire: Int64?
  var enabled: Bool?
  var online: Bool?
  var announcement: String?
  var bannerText: String?
  var bannerButtonText: String?
  var routingEnabled: Bool?
  var hideSettings: Bool?
  var hideURL: Bool?
  var deviceRegistered: Bool?
  var directiveNotice: String?
  var dnsNotice: String?
  var updateIntervalHours: Int?

  init() {}

  init?(response: HTTPURLResponse) {
    let userinfo = response.value(forHTTPHeaderField: "Subscription-Userinfo")
    let announce = response.value(forHTTPHeaderField: "Announce")
    guard userinfo != nil || announce != nil || ["X-Hwid-Active", "Routing-Enable", "Hide-Settings", "Hide-Url", "Banner-Text", "Profile-Update-Interval"].contains(where: { response.value(forHTTPHeaderField: $0) != nil }) else { return nil }
    var fields: [String: Int64] = [:]
    var seen = Set<String>()
    for item in (userinfo ?? "").split(separator: ";") {
      let pieces = item.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
      guard pieces.count == 2, ["upload", "download", "total", "expire"].contains(pieces[0]) else { continue }
      if !seen.insert(pieces[0]).inserted { fields.removeValue(forKey: pieces[0]); continue }
      if pieces[1].utf8.allSatisfy({ (48...57).contains($0) }), let value = Int64(pieces[1]), value >= 0 { fields[pieces[0]] = value }
    }
    upload = fields["upload"]; download = fields["download"]; total = fields["total"]; expire = fields["expire"]
    announcement = Self.display(announce)
    bannerText = Self.display(response.value(forHTTPHeaderField: "Banner-Text"))
    bannerButtonText = Self.display(response.value(forHTTPHeaderField: "Banner-Button-Text"))
    routingEnabled = Self.flag(response.value(forHTTPHeaderField: "Routing-Enable"))
    hideSettings = Self.flag(response.value(forHTTPHeaderField: "Hide-Settings"))
    hideURL = response.value(forHTTPHeaderField: "Hide-Url").map { ["1", "true", "yes"].contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
    deviceRegistered = Self.flag(response.value(forHTTPHeaderField: "X-Hwid-Active"))
    // 3x-ui's Profile-Update-Interval is a whole number of hours.
    if let value = response.value(forHTTPHeaderField: "Profile-Update-Interval")?.trimmingCharacters(in: .whitespaces),
       (1...6).contains(value.utf8.count), value.utf8.allSatisfy({ (48...57).contains($0) }), let hours = Int(value), hours > 0 {
      updateIntervalHours = min(hours, 168)
    }
  }

  mutating func apply(info: [String: Any]) {
    if info["hide_url"] as? Bool == true { hideURL = true }
    enabled = info["enabled"] as? Bool
    online = info["isOnline"] as? Bool
    if announcement == nil { announcement = Self.display(info["announce"] as? String) }
    func bytes(_ key: String) -> Int64? {
      guard let number = info[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
            let value = Int64(number.stringValue), value >= 0 else { return nil }
      return value
    }
    upload = upload ?? bytes("uploadByte"); download = download ?? bytes("downloadByte"); total = total ?? bytes("totalByte")
  }

  static func display(_ text: String?) -> String? {
    guard var text, text.utf8.count <= 16 * 1024 else { return nil }
    if text.lowercased().hasPrefix("base64:") {
      guard let decoded = decodedBase64Text(String(text.dropFirst(7))) else { return nil }
      text = decoded
    }
    guard !text.isEmpty, !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" }) else { return nil }
    return text
  }

  static func flag(_ text: String?) -> Bool? {
    switch text?.lowercased() { case "1", "true": true; case "0", "false": false; default: nil }
  }

  var channelMap: [String: Any] {
    ["upload": upload ?? NSNull(), "download": download ?? NSNull(), "total": total ?? NSNull(),
     "expire": expire ?? NSNull(), "enabled": enabled ?? NSNull(), "online": online ?? NSNull(),
     "announcement": announcement ?? NSNull(), "routingEnabled": routingEnabled ?? NSNull(),
     "bannerText": bannerText ?? NSNull(), "bannerButtonText": bannerButtonText ?? NSNull(),
     "hideSettings": hideSettings ?? NSNull(), "hideURL": hideURL ?? NSNull(), "deviceRegistered": deviceRegistered ?? NSNull(),
     "directiveNotice": directiveNotice ?? NSNull(), "dnsNotice": dnsNotice ?? NSNull(),
     "updateIntervalHours": updateIntervalHours ?? NSNull()]
  }
}
// Provider URLs can contain subscription tokens. Keep them in the existing
// final-URL secret, and expose only action names to the UI/catalog.
struct ProviderLinks: Codable {
  var urls: [String: String] = [:]
  init() {}
  init(response: HTTPURLResponse) {
    for (name, header) in [("support", "Support-Url"), ("account", "Profile-Web-Page-Url"), ("banner", "Banner-Button-Url")] {
      if let value = response.value(forHTTPHeaderField: header), Self.safeURL(value) != nil { urls[name] = value }
    }
    if let value = response.value(forHTTPHeaderField: "Premium-Url"), Self.safeURL(value) != nil { urls["banner"] = value }
    if let url = response.url { urls["source"] = url.absoluteString }
  }
  mutating func merge(info: [String: Any]) {
    for (name, key) in [("raw", "subUrl"), ("json", "subJsonUrl"), ("clash", "subClashUrl"), ("support", "subSupportUrl")] {
      if let value = info[key] as? String, Self.safeURL(value) != nil { urls[name] = value }
    }
  }
  static func safeURL(_ text: String) -> URL? {
    guard text.utf8.count <= 16 * 1024, !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
          let url = URL(string: text), ["https", "http"].contains(url.scheme?.lowercased()),
          let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
    return url
  }
  var actions: [String] { urls.keys.filter { ["support", "account", "banner", "raw", "json", "clash"].contains($0) }.sorted() }
}
struct FeedResponse {
  var migrationHeaders: [String: String] = [:]
  let data: Data
  let finalURL: URL
  let profileTitle: String?
  let routingHeader: String?
  var unsafeTargetChain: [String]
  var metadata: ProviderMetadata? = nil
  var links = ProviderLinks()
  var transportOptions: [String: String] = [:]

  func downloadOptions(for url: URL) -> [String: String] {
    url.scheme == finalURL.scheme && url.host == finalURL.host && url.port == finalURL.port ? transportOptions : [:]
  }
}
enum SubscriptionFeedFetcher {
  static func invoke(_ method: String, _ payload: [String: Any]) throws -> [String: Any] {
    let data = try JSONSerialization.data(withJSONObject: ["apiVersion": 1, "method": method, "payload": payload])
    guard let text = String(data: data, encoding: .utf8), let pointer = strdup(text) else { throw SubscriptionError.invalidFeed }
    defer { free(pointer) }
    guard let response = CGoInvoke(pointer) else { throw SubscriptionError.fetchFailed }
    defer { CGoFree(response) }
    guard let bytes = String(cString: response).data(using: .utf8),
          let envelope = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw SubscriptionError.fetchFailed }
    guard envelope["success"] as? Bool == true else {
      switch envelope["error"] as? String {
      case "hwid_limit": throw SubscriptionError.hwidLimit
      case "hwid_required": throw SubscriptionError.hwidRequired
      case "invalid_target", "invalid_fetch_options": throw SubscriptionError.invalidURL
      case "invalid_feed": throw SubscriptionError.invalidFeed
      case "fetch_cancelled": throw CancellationError()
      case let code? where ["dns_failed", "provider_unreachable", "provider_error", "rate_limited",
                            "subscription_denied", "subscription_unavailable"].contains(code):
        throw SubscriptionError.fetchClass(code)
      default: throw SubscriptionError.fetchFailed
      }
    }
    guard let result = envelope["data"] as? [String: Any] else { throw SubscriptionError.fetchFailed }
    return result
  }

  static func fetch(_ url: URL, maxBytes: Int, approvedChain: [String], installationID: String? = nil,
                    deviceSalt: String? = nil, encounteredChain: [String] = [], fallbackHosts: [String] = [], fallbackURL: String? = nil,
                    options: [String: String] = [:]) async throws -> FeedResponse {
    let id = UUID().uuidString.lowercased()
    _ = try invoke("prepareFetch", ["operationId": id])
    defer { _ = try? invoke("releaseFetch", ["operationId": id]) }
    var request: [String: Any] = options
    request.merge(["operationId": id, "url": url.absoluteString, "approvedChain": approvedChain,
      "encounteredChain": encounteredChain, "fallbackHosts": fallbackHosts, "installationId": installationID ?? "",
      "deviceOS": SubscriptionDeviceIdentity.operatingSystem, "deviceModel": SubscriptionDeviceIdentity.model,
      "deviceVersion": ProcessInfo.processInfo.operatingSystemVersionString,
      "userAgent": SubscriptionDeviceIdentity.headers(installationID: installationID ?? "", url: url)["User-Agent"] ?? "Elarni"]) { _, new in new }
    // As on Android: a provider that checks the client gets the one the user named.
    if let agent = options["userAgent"], !agent.isEmpty { request["userAgent"] = agent }
    if let fallbackURL { request["fallbackURL"] = fallbackURL }
    if let deviceSalt { request["deviceSalt"] = deviceSalt }
    let arguments = request
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      let result = try await Task.detached { try invoke("fetchSubscription", arguments) }.value
      try Task.checkCancellation()
      if let warning = result["warning"] as? [String: Any],
         let codes = warning["riskCodes"] as? [String], let chain = warning["chain"] as? [String] {
        throw SubscriptionApprovalRequirement(riskCodes: codes.compactMap(SubscriptionRiskCode.init(rawValue:)), candidateChain: chain)
      }
      guard let body = result["body"] as? String, !body.isEmpty, body.utf8.count <= maxBytes,
            let finalText = result["url"] as? String, let finalURL = URL(string: finalText),
            let headers = result["headers"] as? [String: String], let chain = result["approvedChain"] as? [String],
            let response = HTTPURLResponse(url: finalURL, statusCode: 200, httpVersion: nil, headerFields: headers) else { throw SubscriptionError.invalidFeed }
      return FeedResponse(migrationHeaders: headers.filter { ["new-url", "new-domain", "fallback-url"].contains($0.key) },
        data: Data(body.utf8), finalURL: finalURL, profileTitle: response.value(forHTTPHeaderField: "Profile-Title"),
        routingHeader: response.value(forHTTPHeaderField: "Routing"), unsafeTargetChain: chain,
        metadata: ProviderMetadata(response: response), links: ProviderLinks(response: response),
        transportOptions: result["usedOverrides"] as? Bool == true ? options : options.filter { $0.key == "userAgent" })
    } onCancel: {
      _ = try? invoke("cancelFetch", ["operationId": id])
    }
  }
}
/// The ETag and Last-Modified a server sent with a stored geofile.
struct GeofileValidators: Codable, Equatable {
  var etag: String?
  var lastModified: String?
}

// Use the same pinned-address transport as subscriptions and desktop assets.
// No production caller supplies approvals for routing resources.
enum RoutingResourceFetcher {
  static func fetch(_ url: URL, maxBytes: Int, approvedChain: [String] = []) async throws -> Data {
    guard let data = try await fetch(url, maxBytes: maxBytes, approvedChain: approvedChain, stored: nil).data else {
      throw SubscriptionError.invalidFeed
    }
    return data
  }

  /// With the stored copy's validators, nil data means that copy is current.
  static func fetch(_ url: URL, maxBytes: Int, approvedChain: [String] = [],
    stored: GeofileValidators?) async throws -> (data: Data?, validators: GeofileValidators?) {
    guard [4 * 1024 * 1024, 64 * 1024 * 1024].contains(maxBytes) else {
      throw SubscriptionError.invalidFeed
    }
    let id = UUID().uuidString.lowercased()
    let request: [String: Any] = ["operationId": id, "url": url.absoluteString,
      "resourceKind": maxBytes == 64 * 1024 * 1024 ? "geofile" : "domains",
      "approvedChain": approvedChain, "etag": stored?.etag ?? "", "lastModified": stored?.lastModified ?? ""]
    _ = try SubscriptionFeedFetcher.invoke("prepareFetch", request)
    defer { _ = try? SubscriptionFeedFetcher.invoke("releaseFetch", ["operationId": id]) }
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      let result = try await Task.detached { try SubscriptionFeedFetcher.invoke("fetchResource", request) }.value
      try Task.checkCancellation()
      if let warning = result["warning"] as? [String: Any],
         let codes = warning["riskCodes"] as? [String], let chain = warning["chain"] as? [String] {
        throw SubscriptionApprovalRequirement(riskCodes: codes.compactMap(SubscriptionRiskCode.init(rawValue:)), candidateChain: chain)
      }
      if stored != nil, result["notModified"] as? Bool == true { return (nil, stored) }
      guard let body = result["body"] as? String, let data = Data(base64Encoded: body),
            !data.isEmpty, data.count <= maxBytes else { throw SubscriptionError.invalidFeed }
      let validators = GeofileValidators(etag: result["etag"] as? String, lastModified: result["lastModified"] as? String)
      return (data, validators == GeofileValidators() ? nil : validators)
    } onCancel: {
      _ = try? SubscriptionFeedFetcher.invoke("cancelFetch", ["operationId": id])
    }
  }
}
