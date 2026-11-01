#if canImport(AppKit)
import AppKit
#endif
import CryptoKit
import Foundation
import Security

struct RefreshSchedule: Codable, Equatable {
  var nextRefreshAt: Date
  var retryIndex = 0
  var retryAt: Date?
  var errorCategory: String?
  var paused = false

  static func interval(_ seconds: Double?, default fallback: Double) -> Double {
    guard let seconds, seconds.isFinite else { return fallback }
    return min(7 * 86400, max(900, seconds))
  }

  static func initial(last: Date?, now: Date, interval: Double) -> Self {
    Self(nextRefreshAt: last?.addingTimeInterval(interval) ?? now)
  }

  var due: Date? { paused ? nil : (retryAt ?? nextRefreshAt) }

  mutating func succeeded(now: Date, interval: Double, jitter: Double) {
    let bounded = jitter.isFinite ? min(1, max(-1, jitter)) : 0
    nextRefreshAt = now.addingTimeInterval(interval * (1 + 0.1 * bounded))
    retryIndex = 0; retryAt = nil; errorCategory = nil; paused = false
  }

  mutating func failed(now: Date, interval: Double, category: String, authorization: Bool) {
    if nextRefreshAt <= now { nextRefreshAt = now.addingTimeInterval(interval) }
    errorCategory = category; paused = authorization
    let delays: [Double] = [60, 300, 1800]
    if !authorization && (0..<delays.count).contains(retryIndex) {
      retryAt = now.addingTimeInterval(delays[retryIndex]); retryIndex += 1
    } else { retryAt = nil; retryIndex = 0 }
  }
}

struct SubscriptionSecretAccess {
  var add: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemAdd
  var copy: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemCopyMatching
  var update: (CFDictionary, CFDictionary) -> OSStatus = SecItemUpdate
  var delete: (CFDictionary) -> OSStatus = SecItemDelete
  var accessGroup: () throws -> String = {
#if os(iOS)
    return try IOSPlatform.keychainAccessGroup()
#else
    let suffix = ".com.elarni.mac.shared"
    guard let task = SecTaskCreateFromSelf(nil),
          let groups = SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil) as? [String],
          let group = groups.first(where: { $0.count > suffix.count && $0.hasSuffix(suffix) })
    else { throw SubscriptionError.keychainFailure }
    return group
#endif
  }
}

@MainActor
final class SubscriptionStore {
#if os(iOS)
  private static let service = "com.elarni.ios.endpoint"
#else
  private static let service = "com.elarni.mac.endpoint"
#endif
  private static let maxFeedBytes = 4 * 1024 * 1024

  private var catalog: SubscriptionCatalog
  private let catalogURL: URL
  private var refreshTasks: [String: [(id: UUID, task: Task<SubscriptionOperationResult, Error>)]] = [:]
  private var refreshGenerations: [String: UUID] = [:]
  private let transactionURL: URL
  private var transaction: RefreshTransaction?
  /// The last restore's server IDs, from the backup's to the new ones.
  private(set) var restoredNodeIDs: [String: String] = [:]
  var publicationInProgress: Bool { transaction != nil }
  private(set) var publicationRecoveryRequired = false
  var runtimeReconciliationRequired: Bool { catalog.runtimeReconciliationRequired == true }
  var now: () -> Date = Date.init
  var jitter: () -> Double = { Double.random(in: -1...1) }
  var autoUpdateInterval: () -> Double = { 4 * 3600 }
  var publishRefresh: ((RefreshCandidate) async throws -> Void)?
  var compilePreview: (([String: Any], [String: Any]?, String?) throws -> [String: Any])?
  var previewContext: () -> String = { "" }
  private let challengeVault = SubscriptionApprovalChallengeVault()
  private let secretAccess: SubscriptionSecretAccess
  let routing: RoutingStore

  init(directory suppliedDirectory: URL? = nil, routing suppliedRouting: RoutingStore? = nil,
       secretAccess: SubscriptionSecretAccess = SubscriptionSecretAccess()) throws {
    self.secretAccess = secretAccess
    routing = try suppliedRouting ?? RoutingStore()
    let directory = try suppliedDirectory ?? FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    ).appendingPathComponent("Elarni", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    catalogURL = directory.appendingPathComponent("subscriptions-v1.json")
    transactionURL = directory.appendingPathComponent("refresh-transaction-v1.json")
    let recovery = try FileManager.default.fileExists(atPath: transactionURL.path)
      ? JSONDecoder().decode(RefreshTransaction.self, from: Data(contentsOf: transactionURL)) : nil
    if let recovery {
      guard recovery.schemaVersion == 1 else { throw SubscriptionError.invalidCatalog }
      catalog = try JSONDecoder().decode(SubscriptionCatalog.self, from: recovery.subscriptions)
    } else if FileManager.default.fileExists(atPath: catalogURL.path) {
      catalog = try JSONDecoder().decode(
        SubscriptionCatalog.self,
        from: Data(contentsOf: catalogURL)
      )
    } else {
      catalog = SubscriptionCatalog(schemaVersion: 1, subscriptions: [], selectedNodeID: nil)
    }
    guard catalog.schemaVersion == 1,
          catalog.subscriptions.allSatisfy({ record in
            (record.riskCodes ?? []).allSatisfy { SubscriptionRiskCode(rawValue: $0) != nil }
          }) else { throw SubscriptionError.invalidCatalog }
    if let recovery {
      transaction = recovery
      try rollbackPublication(recoveringAfterInterruption: true)
    }
    // Only full profiles carry their own rules.
    routing.serverRefs = { [weak self] subscriptions in
      self?.catalog.subscriptions.filter { subscriptions.contains($0.id) }.flatMap(\.nodes)
        .filter { $0.format == "xrayProfile" }.map(\.outboundRef).sorted() ?? []
    }
    routing.serverConfigs = { [weak self] subscriptions in
      guard let self else { return [] }
      return try self.catalog.subscriptions.filter { subscriptions.contains($0.id) }.flatMap(\.nodes)
        .filter { $0.format == "xrayProfile" }
        .map { try JSONSerialization.jsonObject(with: self.readSecret(ref: $0.outboundRef)) }
    }
  }

  func snapshot() -> [String: Any] {
    [
      "selectedNodeId": catalog.selectedNodeID ?? NSNull(),
      "subscriptions": catalog.subscriptions.map(subscriptionMap),
    ]
  }

  func register(urlText: String) throws -> String {
    let input = try normalizeClientInput(urlText)
    let url = try validatedURL(input.text)
    // Compare normalized fetch URLs, not provider labels or wrapper links. A source the
    // Keychain lacks (a catalog restored to another device) matches nothing.
    for record in catalog.subscriptions where record.isLocal != true {
      guard let saved = try? readSecret(ref: record.sourceRef), let text = String(data: saved, encoding: .utf8),
            let original = try? normalizeClientInput(text) else { continue }
      if (try? validatedURL(original.text)) == url ||
          providerLinks(record).urls["refresh"].flatMap(URL.init(string:)) == url {
        return record.id
      }
    }
    return try registerSource(Data((input.shareLink ?? url.absoluteString).utf8), local: false,
      name: input.name.flatMap(usableDisplayText))
  }

  func registerProfiles(_ content: String) throws -> String {
    let input = try normalizeClientInput(content)
    let text = input.text
    if let url = URL(string: text), ["https", "http"].contains(url.scheme?.lowercased()),
       url.user == nil, !url.path.isEmpty, url.path != "/",
       !( ["t.me", "telegram.me"].contains(url.host?.lowercased()) && url.path == "/proxy" ),
       !text.contains(where: { $0.isWhitespace }) {
      return try register(urlText: content)
    }
    let data = Data(text.utf8)
    guard data.count <= Self.maxFeedBytes else { throw SubscriptionError.feedTooLarge }
    let imported = try parseImport(data)
    // Local imports join one group and skip servers it already has or repeats. Its
    // source becomes the current server list, which the caller's refresh publishes.
    // Hidden sharing applies to a whole group, so hidden imports keep their own.
    guard !imported.hideURL else { return try registerSource(data, local: true) }
    guard transaction == nil, !runtimeReconciliationRequired else { throw SubscriptionError.invalidState }
    let index = catalog.subscriptions.firstIndex(where: { $0.isLocal == true && $0.metadata?.hideURL != true })
    var known = Set<String>()
    var nodes: [[String: Any]] = try (index.map { catalog.subscriptions[$0].nodes } ?? []).map { node in
      let stored = try readSecret(ref: node.outboundRef)
      guard var config = try JSONSerialization.jsonObject(with: stored) as? [String: Any] else { throw SubscriptionError.invalidFeed }
      if node.format != "xrayProfile" && node.format != "telegram" { config = ["outbounds": [config]] }
      known.insert(try outboundIdentity(JSONSerialization.data(withJSONObject: config)))
      return ["name": node.name, "format": node.format == "telegram" ? "telegram" : "xrayProfile",
        "config": config, "groupOverrides": node.groupOverrides ?? [:]]
    }
    for node in imported.nodes {
      guard known.insert(try outboundIdentity(node.outbound)).inserted else { continue }
      nodes.append(["name": node.name, "format": node.format, "config": try JSONSerialization.jsonObject(with: node.outbound)])
    }
    // A first import keeps its own text unless it repeats a server.
    if index == nil && nodes.count == imported.nodes.count { return try registerSource(data, local: true) }
    let source = try JSONSerialization.data(withJSONObject: ["elarniLocalNodes": nodes,
      "elarniDirectives": imported.directives])
    guard source.count <= Self.maxFeedBytes else { throw SubscriptionError.feedTooLarge }
    guard let index else { return try registerSource(source, local: true) }
    let group = catalog.subscriptions[index]
    let ref = "subscription.\(group.id).source.\(UUID().uuidString.lowercased())"
    try storeSecret(source, ref: ref)
    catalog.subscriptions[index].sourceRef = ref
    do { try saveCatalog() } catch {
      catalog.subscriptions[index].sourceRef = group.sourceRef
      deleteSecret(ref)
      throw error
    }
    deleteSecret(group.sourceRef)
    return group.id
  }

  private func registerSource(_ data: Data, local: Bool, name: String? = nil) throws -> String {
    guard transaction == nil, !runtimeReconciliationRequired else { throw SubscriptionError.invalidState }
    let id = UUID().uuidString.lowercased()
    let sourceRef = "subscription.\(id).source"
    try storeSecret(data, ref: sourceRef)
    let record = SubscriptionRecord(
      id: id,
      manualName: nil,
      providerName: name ?? (local ? "Local profiles" : fallbackName()),
      sourceRef: sourceRef,
      finalURLRef: nil,
      lastSuccessfulFetch: nil,
      contentDigest: nil,
      status: "refreshing",
      riskCodes: nil,
      nodes: [],
      isLocal: local,
      importedName: name
    )
    catalog.subscriptions.append(record)
    do {
      try saveCatalog()
    } catch {
      catalog.subscriptions.removeAll(where: { $0.id == id })
      deleteSecret(sourceRef)
      throw error
    }
    return id
  }

  func refresh(
    id: String,
    interactive: Bool = true,
    challenge: String? = nil,
    format: String? = nil
  ) async throws -> SubscriptionOperationResult {
    guard !publicationRecoveryRequired else { throw SubscriptionError.invalidState }
    guard catalog.subscriptions.contains(where: { $0.id == id }) else { throw SubscriptionError.notFound }
    try Task.checkCancellation()
    let generation = UUID()
    let predecessor = refreshTasks[id]?.last?.task
    let task = Task { @MainActor in
      // Each caller owns its options and cancellation. Await the previous
      // publication/rollback before assigning this request's generation.
      if let predecessor { _ = try? await predecessor.value }
      try Task.checkCancellation()
      guard !self.publicationRecoveryRequired else { throw SubscriptionError.invalidState }
      self.refreshGenerations[id] = generation
      defer {
        if self.refreshGenerations[id] == generation { self.refreshGenerations.removeValue(forKey: id) }
      }
      return try await self.prepareRefresh(id: id, generation: generation, interactive: interactive, challenge: challenge, format: format)
    }
    refreshTasks[id, default: []].append((generation, task))
    defer {
      refreshTasks[id]?.removeAll { $0.id == generation }
      if refreshTasks[id]?.isEmpty == true { refreshTasks.removeValue(forKey: id) }
    }
    return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
  }

  private func requireRefresh(_ id: String, _ generation: UUID) throws -> Int {
    try Task.checkCancellation()
    guard refreshGenerations[id] == generation,
          let index = catalog.subscriptions.firstIndex(where: { $0.id == id }) else {
      throw CancellationError()
    }
    return index
  }

  private func prepareRefresh(id: String, generation: UUID, interactive: Bool,
                              challenge: String?, format: String?) async throws -> SubscriptionOperationResult {
    var newRefs: [String] = []
    do {
      let initialIndex = try requireRefresh(id, generation)
      let approved = try challenge.map { try challengeVault.consume($0, subscriptionID: id) }
        ?? readApprovalChain(subscriptionID: id)
      let sourceData = try readSecret(ref: catalog.subscriptions[initialIndex].sourceRef)
      guard let sourceText = String(data: sourceData, encoding: .utf8) else {
        throw SubscriptionError.invalidURL
      }
      let requestedFormat = format ?? catalog.subscriptions[initialIndex].preferredFormat ?? "source"
      // Every fetch for this subscription sends the same device ID.
      let salt = catalog.subscriptions[initialIndex].deviceSalt
      guard ["source", "raw", "json", "clash"].contains(requestedFormat) else { throw SubscriptionError.invalidFeed }
      var fetched: FeedResponse
      var migrationSource: String?
      if catalog.subscriptions[initialIndex].isLocal == true {
        fetched = FeedResponse(data: sourceData, finalURL: URL(string: "elarni://local")!,
          profileTitle: "Local profiles", routingHeader: nil, unsafeTargetChain: [])
      } else {
      let sourceURL: URL
      if requestedFormat == "source" { sourceURL = try validatedURL(providerLinks(catalog.subscriptions[initialIndex]).urls["refresh"] ?? sourceText) }
      else {
        guard let text = providerLinks(catalog.subscriptions[initialIndex]).urls[requestedFormat] else { throw SubscriptionError.invalidURL }
        sourceURL = try validatedURL(text)
      }
      if catalog.installationID == nil {
        catalog.installationID = UUID().uuidString.lowercased()
        try saveCatalog()
      }
      let identity = catalog.installationID
      migrationSource = sourceURL.absoluteString
      fetched = try await SubscriptionFeedFetcher.fetch(
        sourceURL,
        maxBytes: Self.maxFeedBytes,
        approvedChain: approved,
        installationID: identity,
        deviceSalt: salt,
        fallbackHosts: catalog.subscriptions[initialIndex].fallbackHosts ?? [],
        // The provider's backup URL stands in for its main URL, not for other formats.
        fallbackURL: requestedFormat == "source" ? providerLinks(catalog.subscriptions[initialIndex]).urls["fallback"] : nil,
        options: (catalog.subscriptions[initialIndex].fetchOptions ?? [:]).filter { $0.key != "refreshHours" }
      )
      }
      let initialMigrationHeaders = fetched.migrationHeaders
      let suppliedInfo = (try? JSONSerialization.jsonObject(with: fetched.data)) as? [String: Any]
      if let info = suppliedInfo, info["sId"] is String, info["enabled"] is Bool {
        var links = fetched.links
        links.merge(info: info)
        guard let text = ["json", "raw", "clash"].compactMap({ links.urls[$0] }).first,
              let url = ProviderLinks.safeURL(text), url != fetched.finalURL else { throw SubscriptionError.invalidFeed }
        fetched = try await SubscriptionFeedFetcher.fetch(url, maxBytes: Self.maxFeedBytes,
          approvedChain: approved, installationID: catalog.installationID, deviceSalt: salt, encounteredChain: fetched.unsafeTargetChain,
          options: fetched.downloadOptions(for: url))
        if fetched.metadata == nil { fetched.metadata = ProviderMetadata() }
        fetched.metadata?.apply(info: info)
        fetched.links.merge(info: info)
      } else if fetched.metadata != nil, var infoURL = URLComponents(url: fetched.finalURL, resolvingAgainstBaseURL: false) {
        infoURL.queryItems = (infoURL.queryItems ?? []).filter { $0.name != "format" } + [URLQueryItem(name: "format", value: "info")]
        if let url = infoURL.url {
          do {
            let info = try await SubscriptionFeedFetcher.fetch(url, maxBytes: Self.maxFeedBytes,
              approvedChain: approved, installationID: catalog.installationID, deviceSalt: salt, encounteredChain: fetched.unsafeTargetChain,
              options: fetched.downloadOptions(for: url))
            fetched.unsafeTargetChain = info.unsafeTargetChain
            if let object = try? JSONSerialization.jsonObject(with: info.data) as? [String: Any],
               object["sId"] is String, object["enabled"] is Bool {
              fetched.metadata?.apply(info: object)
              fetched.links.merge(info: object)
              fetched.unsafeTargetChain = info.unsafeTargetChain
            }
          } catch let requirement as SubscriptionApprovalRequirement { throw requirement }
          catch is CancellationError { throw CancellationError() }
          catch { /* Optional account information must not discard a valid feed. */ }
        }
      }
      let index = try requireRefresh(id, generation)
      let imported: (nodes: [ParsedNode], directives: [String], hideURL: Bool, newSourceURL: String?, systemResolverDNS: Bool, fallbackURL: String?)
      if catalog.subscriptions[index].isLocal == true,
         let container = try? JSONSerialization.jsonObject(with: fetched.data) as? [String: Any],
         let nodes = container["elarniLocalNodes"] as? [[String: Any]] {
        // shortcut: a joined local import forgets the provider DNS notice; carry it in the container if local groups need it.
        imported = (try nodes.map(parseBackupNode), container["elarniDirectives"] as? [String] ?? [], false, nil, false, nil)
      } else {
        imported = try parseImport(fetched.data, sourceURL: migrationSource,
          migrationHeaders: fetched.migrationHeaders.merging(initialMigrationHeaders) { _, first in first })
      }
      if fetched.metadata?.hideURL == nil {
        if fetched.metadata == nil { fetched.metadata = ProviderMetadata() }
        fetched.metadata?.hideURL = imported.hideURL
      }
      let unsupportedDirectives = imported.directives.contains { !RoutingDomainDecoder.isRoutingLink($0) }
      if unsupportedDirectives {
        if fetched.metadata == nil { fetched.metadata = ProviderMetadata() }
        fetched.metadata?.directiveNotice = "This provider included Incy directives that Elarni cannot apply. Ask for Xray JSON with the intended routing and DNS settings."
      }
      if imported.systemResolverDNS {
        if fetched.metadata == nil { fetched.metadata = ProviderMetadata() }
        fetched.metadata?.dnsNotice = "The provider's DNS asks this device's resolver, outside the tunnel. Elarni uses its own DNS for these servers."
      }
      let parsed = imported.nodes
      guard !parsed.isEmpty else { throw SubscriptionError.noSupportedNodes }
      let old = catalog.subscriptions[index]
      if let migrated = imported.newSourceURL {
        fetched.links.urls["refresh"] = migrated
        for format in ["raw", "json", "clash"] { fetched.links.urls.removeValue(forKey: format) }
        fetched.unsafeTargetChain = []
      } else if let current = providerLinks(old).urls["refresh"] {
        fetched.links.urls["refresh"] = current
      }
      // Kept with the other provider URLs in the links secret: it carries the subscription token.
      if let fallback = (requestedFormat == "source" ? imported.fallbackURL : nil) ?? providerLinks(old).urls["fallback"] {
        fetched.links.urls["fallback"] = fallback
      }
      let routingContent = try selectedRoutingContent(fetched, directives: imported.directives)
      if let routingContent { _ = try routing.stageProvider(routingContent, subscriptionID: id) }
      var replacement = try buildReplacement(old: old, parsed: parsed, fetched: fetched)
      replacement.record.preferredFormat = imported.newSourceURL == nil ? requestedFormat : "source"
      replacement.record.isLocal = old.isLocal
      newRefs = replacement.newSecretRefs
      var schedule = scheduleFor(old)
      replacement.record.refreshInterval = intervalFor(replacement.record)
      schedule.succeeded(now: now(), interval: intervalFor(replacement.record), jitter: jitter())
      replacement.record.refreshSchedule = schedule
      replacement.record.lastSuccessfulFetch = now()
      replacement.record.publishedRevision = UUID().uuidString.lowercased()
      replacement.record.retiredSecretRefs = (old.retiredSecretRefs ?? [])
        + old.allNodes.map(\.outboundRef) + [old.finalURLRef].compactMap { $0 }
      let removedSelection = old.nodes.contains(where: { $0.id == catalog.selectedNodeID })
        && !replacement.record.nodes.contains(where: { $0.id == catalog.selectedNodeID })
      guard let publishRefresh else { throw SubscriptionError.invalidState }
      let candidate = RefreshCandidate(record: replacement.record, generation: generation,
        routingContent: routingContent, approvedChain: fetched.unsafeTargetChain)
      // Compiling every server validates the candidate before publication.
      let original = catalog
      let routingStage = try routing.beginStaging()
      do {
        catalog.subscriptions[index] = candidate.record
        if removedSelection { catalog.selectedNodeID = nil }
        if let content = candidate.routingContent { try routing.importProvider(content, subscriptionID: id) }
        try validateNodes()
        catalog = original
        try routing.endStaging(routingStage)
      } catch {
        catalog = original
        try routing.endStaging(routingStage)
        throw error
      }
      try await publishRefresh(candidate)
      newRefs = []
      return SubscriptionOperationResult(
        snapshot: snapshot(),
        removedSelection: removedSelection,
        warning: nil
      )
    } catch let requirement as SubscriptionApprovalRequirement {
      let index = try requireRefresh(id, generation)
      var warning: SubscriptionSafetyWarning?
      do {
        if interactive {
          warning = try challengeVault.issue(subscriptionID: id, requirement: requirement)
        }
        catalog.subscriptions[index].status = "approval_required"
        catalog.subscriptions[index].riskCodes = requirement.riskCodes.map(\.rawValue)
        recordFailure(index: index, interactive: interactive, category: "authorization", authorization: true)
        try saveCatalog()
      } catch {
        if let warning { challengeVault.revoke(warning.challenge) }
        catalog.subscriptions[index].status = "refresh_failed"
        catalog.subscriptions[index].riskCodes = nil
        try? saveCatalog()
        throw error
      }
      return SubscriptionOperationResult(
        snapshot: snapshot(),
        removedSelection: false,
        warning: warning
      )
    } catch {
      // If rollback is incomplete, retain candidate secrets for conservative recovery.
      if transaction == nil {
        let retained = Set(catalog.subscriptions.flatMap {
          $0.allNodes.map(\.outboundRef) + ($0.retiredSecretRefs ?? []) + [$0.finalURLRef].compactMap { $0 }
        })
        newRefs.filter { !retained.contains($0) }.forEach(deleteSecret)
      }
      let index = try requireRefresh(id, generation)
      catalog.subscriptions[index].status = (error as? SubscriptionError)?.hwidStatus ?? "refresh_failed"
      catalog.subscriptions[index].riskCodes = nil
      let authorization = (error as? SubscriptionError)?.hwidStatus != nil
      recordFailure(index: index, interactive: interactive,
        category: error is RoutingStoreError ? "routing" :
          (authorization ? "authorization" : (error as? SubscriptionError == .keychainFailure ? "secret" : "refresh")), authorization: authorization)
      if transaction == nil { try? saveCatalog() }
      throw error
    }
  }

  // The user's override, else the provider's Profile-Update-Interval, else the app setting.
  private func intervalFor(_ record: SubscriptionRecord) -> Double {
    if let hours = record.fetchOptions?["refreshHours"].flatMap(Double.init) { return hours * 3600 }
    if let hours = record.metadata?.updateIntervalHours, hours > 0 { return Double(min(hours, 168)) * 3600 }
    return RefreshSchedule.interval(autoUpdateInterval(), default: 4 * 3600)
  }

  private func scheduleFor(_ record: SubscriptionRecord) -> RefreshSchedule {
    if var schedule = record.refreshSchedule {
      if schedule.errorCategory == nil, record.refreshInterval != intervalFor(record),
         let last = record.lastSuccessfulFetch {
        schedule.nextRefreshAt = last.addingTimeInterval(intervalFor(record))
      }
      return schedule
    }
    var schedule = RefreshSchedule.initial(last: record.lastSuccessfulFetch, now: now(), interval: intervalFor(record))
    schedule.paused = record.status == "approval_required"
    return schedule
  }

  private func recordFailure(index: Int, interactive: Bool, category: String, authorization: Bool) {
    var schedule = scheduleFor(catalog.subscriptions[index])
    if interactive { schedule.retryIndex = 0; schedule.retryAt = nil }
    schedule.failed(now: now(), interval: intervalFor(catalog.subscriptions[index]), category: category, authorization: authorization)
    catalog.subscriptions[index].refreshSchedule = schedule
  }

  func dueSubscriptions() -> [String] {
    guard !publicationRecoveryRequired else { return [] }
    return catalog.subscriptions.filter { $0.isLocal != true && refreshTasks[$0.id] == nil && scheduleFor($0).due.map { $0 <= now() } == true }.map(\.id)
  }

  func nextRefreshDate() -> Date? {
    guard !publicationRecoveryRequired else { return nil }
    return catalog.subscriptions.filter { $0.isLocal != true && refreshTasks[$0.id] == nil }.compactMap { scheduleFor($0).due }.min()
  }

  func cancelRefreshes() {
    refreshTasks.values.forEach { $0.forEach { $0.task.cancel() } }
    refreshGenerations.removeAll()
  }

  func beginPublication(_ candidate: RefreshCandidate) throws -> Bool {
    guard transaction == nil, !runtimeReconciliationRequired else { throw SubscriptionError.invalidState }
    let index = try requireRefresh(candidate.record.id, candidate.generation)
    let prior = try JSONEncoder().encode(catalog)
    let oldRouting = try routing.checkpoint()
    let oldApproval = try readApprovalChain(subscriptionID: candidate.record.id)
    let staged = try candidate.routingContent.map {
      try routing.stageProvider($0, subscriptionID: candidate.record.id)
    } ?? oldRouting
    let marker = RefreshTransaction(schemaVersion: 1, subscriptions: prior, routing: oldRouting,
      subscriptionID: candidate.record.id, approvedChain: oldApproval,
      candidateSecretRefs: candidate.record.allNodes.map(\.outboundRef) + [candidate.record.finalURLRef].compactMap { $0 })
    try JSONEncoder().encode(marker).write(to: transactionURL, options: [.atomic])
    transaction = marker
    let removed = catalog.subscriptions[index].nodes.contains { $0.id == catalog.selectedNodeID }
      && !candidate.record.nodes.contains { $0.id == catalog.selectedNodeID }
    do {
      var record = candidate.record
      record.manualName = catalog.subscriptions[index].manualName
      catalog.subscriptions[index] = record
      catalog.publishedRevision = record.publishedRevision
      if removed { catalog.selectedNodeID = nil }
      try routing.restore(staged, publishedRevision: record.publishedRevision)
      try writeApprovalChain(candidate.approvedChain, subscriptionID: record.id)
      try saveCatalog()
      return removed
    } catch {
      try rollbackPublication()
      throw error
    }
  }

  func finishPublication(_ candidate: RefreshCandidate) throws {
    _ = try requireRefresh(candidate.record.id, candidate.generation)
    guard transaction != nil else { throw SubscriptionError.invalidState }
    try FileManager.default.removeItem(at: transactionURL)
    transaction = nil
  }

  func rollbackPublication(recoveringAfterInterruption: Bool = false) throws {
    guard let marker = transaction else { return }
    do {
      var restored = try JSONDecoder().decode(SubscriptionCatalog.self, from: marker.subscriptions)
      guard restored.schemaVersion == 1 else { throw SubscriptionError.invalidCatalog }
      if recoveringAfterInterruption { restored.runtimeReconciliationRequired = true }
      // A selection never mutates routing; avoid invalidating an unrelated
      // managed-resource generation when recovering that operation.
      if marker.selection != true { try routing.restore(marker.routing) }
      if marker.catalogReplacement != true {
        try writeApprovalChain(marker.approvedChain, subscriptionID: marker.subscriptionID)
      }
      if let index = restored.subscriptions.firstIndex(where: { $0.id == marker.subscriptionID }) {
        restored.subscriptions[index].retiredSecretRefs = (restored.subscriptions[index].retiredSecretRefs ?? []) + marker.candidateSecretRefs
      }
      try JSONEncoder().encode(restored).write(to: catalogURL, options: [.atomic])
      catalog = restored
      try FileManager.default.removeItem(at: transactionURL)
      transaction = nil
      publicationRecoveryRequired = false
      if marker.catalogReplacement == true { marker.candidateSecretRefs.forEach(deleteSecret) }
    } catch {
      publicationRecoveryRequired = true
      throw error
    }
  }

  func reclaimRetiredSecrets() throws {
    guard transaction == nil, !runtimeReconciliationRequired else { throw SubscriptionError.invalidState }
    let prior = catalog
    // Refresh and rollback may retain a node's existing reference. Never reclaim
    // a secret that the committed catalog still uses.
    let active = Set(catalog.subscriptions.flatMap {
      $0.allNodes.map(\.outboundRef) + [$0.sourceRef] + [$0.finalURLRef].compactMap { $0 }
    })
    let refs = Set(catalog.subscriptions.flatMap { $0.retiredSecretRefs ?? [] }).subtracting(active)
    for index in catalog.subscriptions.indices { catalog.subscriptions[index].retiredSecretRefs = nil }
    do { try saveCatalog() } catch { catalog = prior; throw error }
    // A crash after this save may leak an old secret, never dangle an active reference.
    refs.forEach(deleteSecret)
  }

  func finishRuntimeReconciliation() throws {
    guard transaction == nil, !publicationRecoveryRequired else { throw SubscriptionError.invalidState }
    let previous = catalog
    catalog.runtimeReconciliationRequired = nil
    do { try saveCatalog() } catch { catalog = previous; throw error }
  }

  func updateFetchOptions(id: String, options: [String: Any]) throws -> [String: Any] {
    guard let index = catalog.subscriptions.firstIndex(where: { $0.id == id }),
          catalog.subscriptions[index].isLocal != true,
          options.keys.allSatisfy({ ["fallbackHosts", "userAgent", "connectAddress", "httpHost", "fragmentLength", "fragmentInterval", "refreshHours"].contains($0) }),
          (options["refreshHours"] as? String).map({ $0.range(of: "^([1-9]|[1-9][0-9]|1[0-5][0-9]|16[0-8])$", options: .regularExpression) != nil }) ?? (options["refreshHours"] == nil),
          let hosts = options["fallbackHosts"] as? [String], hosts.count <= 8,
          hosts.allSatisfy(Self.validFallbackHost) else { throw SubscriptionError.invalidURL }
    let transport = options.filter { $0.key != "fallbackHosts" }
    guard let transport = transport as? [String: String] else { throw SubscriptionError.invalidURL }
    var validation = options.filter { $0.key != "refreshHours" }
    guard let source = try providerLinks(catalog.subscriptions[index]).urls["refresh"] ??
      String(data: readSecret(ref: catalog.subscriptions[index].sourceRef), encoding: .utf8) else { throw SubscriptionError.invalidURL }
    validation["url"] = source
    _ = try SubscriptionFeedFetcher.invoke("validateSubscriptionFetchOptions", validation)
    let old = catalog
    refreshTasks[id]?.forEach { $0.task.cancel() }
    refreshGenerations.removeValue(forKey: id)
    catalog.subscriptions[index].fallbackHosts = hosts
    catalog.subscriptions[index].fetchOptions = transport
    do { try saveCatalog() } catch { catalog = old; throw error }
    return snapshot()
  }

  nonisolated static func validFallbackHost(_ host: String) -> Bool {
    guard !host.isEmpty, host.utf8.count <= 253, host == host.trimmingCharacters(in: .whitespacesAndNewlines),
          host.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || ".-:[]".unicodeScalars.contains($0)) }),
          let parts = URLComponents(string: "https://" + host), parts.host?.isEmpty == false,
          parts.user == nil, parts.password == nil, parts.port == nil, parts.path.isEmpty,
          parts.query == nil, parts.fragment == nil else { return false }
    return true
  }

  func rename(id: String, name: String?) throws -> [String: Any] {
    guard let index = catalog.subscriptions.firstIndex(where: { $0.id == id }) else {
      throw SubscriptionError.notFound
    }
    let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let previous = catalog
    catalog.subscriptions[index].manualName = trimmed.isEmpty ? nil : try displayText(trimmed)
    do { try saveCatalog() } catch { catalog = previous; throw error }
    return snapshot()
  }

  func delete(id: String, synchronize: () async throws -> Void = {}) async throws
    -> (snapshot: [String: Any], removedSelection: Bool) {
    guard transaction == nil else { throw SubscriptionError.invalidState }
    refreshTasks[id]?.forEach { $0.task.cancel() }
    refreshGenerations.removeValue(forKey: id)
    guard let index = catalog.subscriptions.firstIndex(where: { $0.id == id }) else {
      throw SubscriptionError.notFound
    }
    let record = catalog.subscriptions[index]
    let removedSelection = record.nodes.contains(where: { $0.id == catalog.selectedNodeID })
    let marker = RefreshTransaction(schemaVersion: 1,
      subscriptions: try JSONEncoder().encode(catalog), routing: try routing.checkpoint(),
      subscriptionID: id, approvedChain: try readApprovalChain(subscriptionID: id), candidateSecretRefs: [])
    try JSONEncoder().encode(marker).write(to: transactionURL, options: [.atomic])
    transaction = marker
    challengeVault.invalidate(subscriptionID: id)
    do {
      try deleteApprovalChain(subscriptionID: id)
      try routing.removeSubscription(id: id)
      catalog.subscriptions.remove(at: index)
      if removedSelection { catalog.selectedNodeID = nil }
      try saveCatalog()
      try await synchronize()
      try Task.checkCancellation()
      try FileManager.default.removeItem(at: transactionURL)
      transaction = nil
    } catch {
      try rollbackPublication()
      throw error
    }
    deleteSecret(record.sourceRef)
    if let finalURLRef = record.finalURLRef { deleteSecret(finalURLRef) }
    (record.allNodes.map(\.outboundRef) + (record.retiredSecretRefs ?? [])).forEach(deleteSecret)
    return (snapshot(), removedSelection)
  }

  func outboundRef(nodeID: String) throws -> String {
    guard let node = catalog.subscriptions.lazy.flatMap(\.nodes).first(where: { $0.id == nodeID })
    else { throw SubscriptionError.notFound }
    guard node.format != "telegram" else { throw SubscriptionError.invalidState }
    return node.outboundRef
  }

  func outboundFormat(secretRef: String) throws -> String {
    guard let node = catalog.subscriptions.lazy.flatMap(\.nodes).first(where: { $0.outboundRef == secretRef }),
          node.format != "telegram" else { throw SubscriptionError.notFound }
    return node.format ?? "xrayOutbound"
  }

  func nodeID(secretRef: String) throws -> String {
    guard let node = catalog.subscriptions.lazy.flatMap(\.nodes).first(where: { $0.outboundRef == secretRef })
    else { throw SubscriptionError.notFound }
    return node.id
  }

  func ipPreference(nodeID: String) throws -> String? {
    guard let node = catalog.subscriptions.lazy.flatMap(\.nodes).first(where: { $0.id == nodeID }),
          node.format != "telegram" else { throw SubscriptionError.notFound }
    return node.ipPreference
  }

  func beginSelectionPublication() throws {
    guard transaction == nil, !publicationRecoveryRequired, !runtimeReconciliationRequired else {
      throw SubscriptionError.invalidState
    }
    let marker = RefreshTransaction(schemaVersion: 1,
      subscriptions: try JSONEncoder().encode(catalog), routing: try routing.checkpoint(),
      subscriptionID: "", approvedChain: [], candidateSecretRefs: [],
      catalogReplacement: true, selection: true)
    try JSONEncoder().encode(marker).write(to: transactionURL, options: [.atomic])
    transaction = marker
  }

  func finishSelectionPublication(nodeID: String) throws {
    guard transaction?.selection == true else { throw SubscriptionError.invalidState }
    try commitSelection(nodeID: nodeID)
    try FileManager.default.removeItem(at: transactionURL)
    transaction = nil
  }

  func commitSelection(nodeID: String) throws {
    _ = try outboundRef(nodeID: nodeID)
    let previous = catalog.selectedNodeID
    catalog.selectedNodeID = nodeID
    do { try saveCatalog() }
    catch {
      catalog.selectedNodeID = previous
      throw error
    }
  }

  func selectedNodeID() -> String? { catalog.selectedNodeID }

  func setFavorite(nodeID: String, favorite: Bool) throws -> [String: Any] {
    try editNode(nodeID) { $0.favorite = favorite }
    return snapshot()
  }

  /// An empty name restores the provider's.
  func renameNode(id: String, name: String) throws -> [String: Any] {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let manual = trimmed.isEmpty ? nil : try displayText(trimmed)
    try editNode(id) { $0.manualName = manual }
    return snapshot()
  }

  /// The selected server and a subscription's last one stay. A provider's server is hidden, so that its refresh keeps it out.
  func deleteNode(id: String) throws -> [String: Any] { try deleteNodes(ids: [id]) }

  /// All or none, in one save: the selected server and a subscription's last one stay.
  func deleteNodes(ids: [String]) throws -> [String: Any] {
    guard transaction == nil, !ids.isEmpty, !ids.contains(where: { $0 == catalog.selectedNodeID }) else { throw SubscriptionError.invalidState }
    let previous = catalog
    do {
      for id in ids {
        guard let index = catalog.subscriptions.firstIndex(where: { $0.nodes.contains { $0.id == id } }) else { throw SubscriptionError.notFound }
        guard catalog.subscriptions[index].nodes.count > 1 else { throw SubscriptionError.invalidState }
        let node = catalog.subscriptions[index].nodes.first { $0.id == id }!
        catalog.subscriptions[index].nodes.removeAll { $0.id == id }
        if catalog.subscriptions[index].isLocal == true {
          // Reclaimed with refresh's retired references once no tunnel can read it.
          catalog.subscriptions[index].retiredSecretRefs = (catalog.subscriptions[index].retiredSecretRefs ?? []) + [node.outboundRef]
        } else {
          catalog.subscriptions[index].hiddenNodes = (catalog.subscriptions[index].hiddenNodes ?? []) + [node]
        }
      }
      try saveCatalog()
    } catch { catalog = previous; throw error }
    return snapshot()
  }

  func showNode(id: String) throws -> [String: Any] {
    guard transaction == nil else { throw SubscriptionError.invalidState }
    guard let index = catalog.subscriptions.firstIndex(where: { $0.hiddenNodes?.contains { $0.id == id } == true }) else { throw SubscriptionError.notFound }
    let previous = catalog
    let node = catalog.subscriptions[index].hiddenNodes!.first { $0.id == id }!
    catalog.subscriptions[index].hiddenNodes!.removeAll { $0.id == id }
    catalog.subscriptions[index].nodes.append(node)
    do { try saveCatalog() } catch { catalog = previous; throw error }
    return snapshot()
  }

  /// The X-HWID this subscription's refresh sends, named by the same Go code.
  func deviceID(subscriptionID: String) throws -> String {
    guard let record = catalog.subscriptions.first(where: { $0.id == subscriptionID }), record.isLocal != true,
          let source = String(data: try readSecret(ref: record.sourceRef), encoding: .utf8) else { throw SubscriptionError.notFound }
    if catalog.installationID == nil {
      catalog.installationID = UUID().uuidString.lowercased()
      try saveCatalog()
    }
    // The URL a refresh fetches: the chosen format's link, if not the original.
    let links = providerLinks(record).urls
    let format = record.preferredFormat ?? "source"
    guard let text = format == "source" ? links["refresh"] ?? source : links[format] else { throw SubscriptionError.invalidURL }
    var request: [String: Any] = ["url": try validatedURL(text).absoluteString,
                                  "installationId": catalog.installationID ?? ""]
    if let salt = record.deviceSalt { request["deviceSalt"] = salt }
    if let host = record.fetchOptions?["httpHost"], !host.isEmpty { request["httpHost"] = host }
    guard let id = try SubscriptionFeedFetcher.invoke("subscriptionDeviceID", request)["deviceId"] as? String else {
      throw SubscriptionError.invalidState
    }
    return id
  }

  /// A new random key for this subscription only; its next refresh sends the new ID.
  func resetDeviceID(subscriptionID: String) throws -> [String: Any] {
    guard transaction == nil else { throw SubscriptionError.invalidState }
    guard let index = catalog.subscriptions.firstIndex(where: { $0.id == subscriptionID }),
          catalog.subscriptions[index].isLocal != true else { throw SubscriptionError.notFound }
    let previous = catalog
    catalog.subscriptions[index].deviceSalt = UUID().uuidString.lowercased()
    do { try saveCatalog() } catch { catalog = previous; throw error }
    return snapshot()
  }

  private func editNode(_ id: String, edit: (inout SubscriptionNode) -> Void) throws {
    for index in catalog.subscriptions.indices {
      if let node = catalog.subscriptions[index].nodes.firstIndex(where: { $0.id == id }) {
        let previous = catalog
        edit(&catalog.subscriptions[index].nodes[node])
        do { try saveCatalog() } catch { catalog = previous; throw error }
        return
      }
    }
    throw SubscriptionError.notFound
  }

  func configurationRevision(nodeID: String) throws -> String {
    guard let node = catalog.subscriptions.flatMap(\.nodes).first(where: { $0.id == nodeID }) else { throw SubscriptionError.notFound }
    return try nodeRevision(node)
  }

  private func nodeRevision(_ node: SubscriptionNode) throws -> String {
    let source = try subscriptionID(nodeID: node.id)
    let routes = try routing.previewRoutes(subscriptionID: source)
    // References are reused only for identical runtime configuration. Include
    // policy, local choices and runtime settings without returning secrets.
    let preference: String = node.ipPreference ?? "inherit"
    let context: [String: Any] = ["reference": node.outboundRef,
      "routes": routes ?? [:], "assets": routing.previewAssetRevision(subscriptionID: source) ?? NSNull(),
      "ip": preference, "context": previewContext()]
    let bytes = try JSONSerialization.data(withJSONObject: context, options: [.sortedKeys])
    return Data(SHA256.hash(data: bytes)).base64EncodedString()
  }

  func recordSuccess(nodeID: String, revision: String, session: String? = nil) throws {
    guard try configurationRevision(nodeID: nodeID) == revision else { return }
    if let session, catalog.subscriptions.flatMap(\.nodes).first(where: { $0.id == nodeID })?.lastSuccessSession == session { return }
    try editNode(nodeID) {
      $0.lastSuccessAt = now()
      $0.lastSuccessRevision = revision
      $0.lastSuccessSession = session
    }
  }

  private func compiledPreview(node: SubscriptionNode, routes: [String: Any]?) throws -> [String: Any] {
    guard let config = try JSONSerialization.jsonObject(with: readSecret(ref: node.outboundRef)) as? [String: Any] else { throw SubscriptionError.invalidFeed }
    if node.format == "telegram" { return config }
    if let compilePreview { return try compilePreview(config, routes, node.ipPreference) }
    let profile = config["outbounds"] != nil
    var payload: [String: Any] = [profile ? "profile" : "outbound": config, "socksPort": 1080]
    if let routes { payload["routes"] = routes }
    else if !profile { payload["routes"] = ["rules": [], "dnsServers": ["1.1.1.1"], "fallbackAction": "proxy"] }
    let response = try RoutingDomainDecoder.request(profile ? "compileProfile" : "compileOutbound", payload: payload)
    guard let text = response["configUtf8"] as? String,
          let compiled = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { throw SubscriptionError.invalidFeed }
    return compiled
  }

  /// Compiles every server, which validates a catalog before it is published.
  func validateNodes() throws {
    for source in catalog.subscriptions {
      let routes = try routing.previewRoutes(subscriptionID: source.id)
      for node in source.nodes { _ = try compiledPreview(node: node, routes: routes) }
    }
  }

  func selectedSubscriptionID() -> String? {
    guard let selectedNodeID = catalog.selectedNodeID else { return nil }
    return catalog.subscriptions.first(where: {
      $0.nodes.contains(where: { $0.id == selectedNodeID })
    })?.id
  }

  func subscriptionID(nodeID: String) throws -> String {
    guard let id = catalog.subscriptions.first(where: {
      $0.nodes.contains(where: { $0.id == nodeID })
    })?.id else { throw SubscriptionError.notFound }
    return id
  }

  func removesSelection(subscriptionID: String) -> Bool {
    guard let selected = catalog.selectedNodeID,
          let subscription = catalog.subscriptions.first(where: { $0.id == subscriptionID })
    else { return false }
    return subscription.nodes.contains(where: { $0.id == selected })
  }

  func selectedOutboundRef() -> String? {
    guard let selectedNodeID = catalog.selectedNodeID else { return nil }
    return catalog.subscriptions.lazy.flatMap(\.nodes)
      .first(where: { $0.id == selectedNodeID })?.outboundRef
  }

  func outbound(nodeID: String) throws -> [String: Any] {
    let data = try readSecret(ref: outboundRef(nodeID: nodeID))
    guard let outbound = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw SubscriptionError.invalidFeed
    }
    return outbound
  }

  func telegramURL(nodeID: String) throws -> URL {
    guard let node = catalog.subscriptions.lazy.flatMap(\.nodes).first(where: { $0.id == nodeID }),
          node.format == "telegram",
          let payload = try JSONSerialization.jsonObject(with: readSecret(ref: node.outboundRef)) as? [String: String],
          let value = payload["url"] else { throw SubscriptionError.invalidFeed }
    let checked = try parseImport(Data(value.utf8)).nodes
    guard checked.count == 1, checked[0].format == "telegram", let url = URL(string: value) else { throw SubscriptionError.invalidURL }
    return url
  }

  func sharingText(id: String, subscription: Bool) throws -> String {
    guard let record = catalog.subscriptions.first(where: {
      subscription ? $0.id == id : $0.nodes.contains(where: { $0.id == id })
    }) else { throw SubscriptionError.notFound }
    guard record.metadata?.hideURL != true else { throw SubscriptionError.incompatibleProfile("This provider has disabled sharing.") }
    guard record.isLocal == true || record.metadata?.hideURL != nil else { throw SubscriptionError.incompatibleProfile("Refresh this subscription before sharing.") }
    if subscription {
      guard record.isLocal != true,
            let text = String(data: try readSecret(ref: record.sourceRef), encoding: .utf8) else { throw SubscriptionError.invalidURL }
      let current = providerLinks(record).urls["refresh"] ?? text
      _ = try validatedURL(current)
      return current
    }
    guard let node = record.nodes.first(where: { $0.id == id }) else { throw SubscriptionError.notFound }
    if node.format == "telegram" { return try telegramURL(nodeID: id).absoluteString }
    var config = try outbound(nodeID: id)
    if node.format != "xrayProfile" { config = ["outbounds": [config]] }
    config["remarks"] = node.displayName
    return String(decoding: try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]), as: UTF8.self)
  }

  /// Share links for servers of a local group, which has no subscription link, in group order.
  func shareLinks(subscriptionID: String, nodeIDs: [String]) throws -> String {
    guard let record = catalog.subscriptions.first(where: { $0.id == subscriptionID }), record.isLocal == true else { throw SubscriptionError.notFound }
    guard record.metadata?.hideURL != true else { throw SubscriptionError.incompatibleProfile("This provider has disabled sharing.") }
    let links = try record.nodes.filter { nodeIDs.contains($0.id) }.map(shareLink)
    guard !links.isEmpty else { throw SubscriptionError.notFound }
    return links.joined(separator: "\n")
  }

  /// Servers of a group that have a share link: a profile with several outbounds has none,
  /// nor do protocols libXray share/generate_share.go writes no link for, such as WireGuard and HTTP.
  func linkableNodeIDs(subscriptionID: String) -> Set<String> {
    Set(catalog.subscriptions.first { $0.id == subscriptionID }?.nodes.filter { node in
      guard node.format != "telegram" else { return true }
      guard let config = try? outbound(nodeID: node.id) else { return false }
      let outbounds = node.format == "xrayProfile" ? config["outbounds"] as? [[String: Any]] ?? [] : [config]
      guard outbounds.count == 1 else { return false }
      return ["vless", "vmess", "trojan", "shadowsocks", "socks", "hysteria", "tuic"].contains(outbounds[0]["protocol"] as? String ?? "")
    }.map(\.id) ?? [])
  }

  private func shareLink(_ node: SubscriptionNode) throws -> String {
    if node.format == "telegram" { return try telegramURL(nodeID: node.id).absoluteString }
    let none = SubscriptionError.incompatibleProfile("\(node.displayName) has no share link. Share it from its own page.")
    var config = try outbound(nodeID: node.id)
    if node.format == "xrayProfile" {
      guard let outbounds = config["outbounds"] as? [[String: Any]], outbounds.count == 1 else { throw none }
      config = outbounds[0]
    }
    // The link takes its name from the outbound tag.
    config["tag"] = node.displayName
    let json = String(decoding: try JSONSerialization.data(withJSONObject: ["outbounds": [config]]), as: UTF8.self)
    // A TUIC outbound without a link comes back as the JSON it was given.
    guard let links = (try? SubscriptionFeedFetcher.invoke("convertXrayJsonToShareLinks", ["xrayJson": json]))?["links"] as? String,
          !links.hasPrefix("{") else { throw none }
    return links
  }

  func backupCatalog() throws -> [String: Any] {
    guard transaction == nil, !publicationRecoveryRequired else { throw SubscriptionError.invalidState }
    let sources: [[String: Any]] = try catalog.subscriptions.map { record in
      guard record.metadata?.hideURL != true else { throw SubscriptionError.incompatibleProfile("This provider has disabled sharing and backups.") }
      guard record.isLocal == true || record.metadata?.hideURL != nil else {
        throw SubscriptionError.incompatibleProfile("Refresh every subscription before creating a backup.")
      }
      var source: [String: Any] = ["id": record.id, "name": record.manualName ?? record.providerName,
        "fallbackHosts": record.fallbackHosts ?? [], "fetchOptions": record.fetchOptions ?? [:]]
      if record.isLocal != true {
        let shared = try sharingText(id: record.id, subscription: true)
        let input = try normalizeClientInput(shared)
        source["url"] = input.text
        if let link = input.shareLink { source["shareLink"] = link }
      }
      if routing.isManual(subscriptionID: record.id) { source["manualRouting"] = true }
      source["nodes"] = try record.nodes.map(backupNode)
      if let hidden = record.hiddenNodes, !hidden.isEmpty { source["hiddenNodes"] = try hidden.map(backupNode) }
      return source
    }
    var backup = try routing.backupCatalog()
    backup["version"] = 1
    backup["subscriptions"] = sources
    if let selected = catalog.selectedNodeID { backup["selectedNodeId"] = selected }
    return backup
  }

  private func backupNode(_ node: SubscriptionNode) throws -> [String: Any] {
    guard var config = try JSONSerialization.jsonObject(with: readSecret(ref: node.outboundRef)) as? [String: Any] else { throw SubscriptionError.invalidFeed }
    if node.format != "xrayProfile" && node.format != "telegram" { config = ["outbounds": [config]] }
    var value: [String: Any] = ["id": node.id, "name": node.displayName, "format": node.format == "telegram" ? "telegram" : "xrayProfile",
      "config": config, "groupOverrides": node.groupOverrides ?? [:],
      "ipPreference": node.ipPreference as Any? ?? NSNull()]
    // Refresh matches a renamed server on the provider's name.
    if node.manualName != nil { value["providerName"] = node.name }
    if node.favorite == true { value["favorite"] = true }
    return value
  }

  private func parseBackupNode(_ node: [String: Any]) throws -> ParsedNode {
    guard let config = node["config"] as? [String: Any], let format = node["format"] as? String,
          let name = node["name"] as? String else { throw SubscriptionError.invalidFeed }
    let content = format == "telegram" ? Data((config["url"] as? String ?? "").utf8) :
      try JSONSerialization.data(withJSONObject: config)
    let parsed = try parseImport(content).nodes
    guard parsed.count == 1 else { throw SubscriptionError.invalidFeed }
    var result = ParsedNode(name: try displayText(name), protocolName: parsed[0].protocolName,
      transport: parsed[0].transport, security: parsed[0].security, outbound: parsed[0].outbound,
      format: parsed[0].format, groups: parsed[0].groups)
    let choices = node["groupOverrides"] as? [String: String] ?? [:]
    guard choices.allSatisfy({ name, choice in result.groups?.contains(where: { $0.name == name && $0.options.contains(choice) }) == true }) else {
      throw SubscriptionError.invalidFeed
    }
    if !choices.isEmpty { result = try applyingGroups(result, selections: choices) }
    return result
  }

  // The existing durable journal covers both catalog files. All restored IDs
  // and secret references are fresh, so trust decisions cannot carry across.
  func beginBackupRestore(_ payload: [String: Any]) throws -> [String: Any] {
    guard transaction == nil, !publicationRecoveryRequired, !runtimeReconciliationRequired else { throw SubscriptionError.invalidState }
    let validated = try SubscriptionFeedFetcher.invoke("validateCatalogBackup", ["catalog": payload])
    guard let backup = validated["catalog"] as? [String: Any],
          let sources = backup["subscriptions"] as? [[String: Any]],
          let routes = backup["routes"] as? [[String: Any]],
          let assignments = backup["assignments"] as? [String: String] else { throw SubscriptionError.invalidFeed }
    cancelRefreshes()
    let previous = catalog
    var sourceIDs: [String: String] = [:], nodeIDs: [String: String] = [:]
    var records: [SubscriptionRecord] = [], refs: [String] = []
    func restoreNodes(_ rawNodes: [[String: Any]], subscriptionID id: String) throws -> [SubscriptionNode] {
      try rawNodes.map { raw in
        guard let oldNodeID = raw["id"] as? String else { throw SubscriptionError.invalidFeed }
        let node = try parseBackupNode(raw)
        let nodeID = UUID().uuidString.lowercased()
        nodeIDs[oldNodeID] = nodeID
        let ref = "subscription.\(id).node.\(UUID().uuidString.lowercased())"
        try storeSecret(node.outbound, ref: ref); refs.append(ref)
        let provider = try (raw["providerName"] as? String).map(displayText)
        return SubscriptionNode(id: nodeID, name: provider ?? node.name, protocolName: node.protocolName,
          transport: node.transport, security: node.security, outboundRef: ref, format: node.format,
          groups: node.groups, groupOverrides: raw["groupOverrides"] as? [String: String],
          ipPreference: raw["ipPreference"] as? String, favorite: raw["favorite"] as? Bool == true ? true : nil,
          manualName: provider == nil ? nil : node.name, probeKey: probeKey(outbound: node.outbound))
      }
    }
    do {
      for source in sources {
        guard let oldID = source["id"] as? String, let name = source["name"] as? String else { throw SubscriptionError.invalidFeed }
        let id = UUID().uuidString.lowercased()
        sourceIDs[oldID] = id
        let rawNodes = source["nodes"] as? [[String: Any]] ?? []
        let nodes = try restoreNodes(rawNodes, subscriptionID: id)
        let hidden = try restoreNodes(source["hiddenNodes"] as? [[String: Any]] ?? [], subscriptionID: id)
        let remote = source["url"] as? String
        let data = try remote.map { Data((source["shareLink"] as? String ?? $0).utf8) } ??
          JSONSerialization.data(withJSONObject: ["elarniLocalNodes": rawNodes])
        let ref = "subscription.\(id).source"
        try storeSecret(data, ref: ref); refs.append(ref)
        var metadata = ProviderMetadata()
        if remote == nil { metadata.hideURL = false }
        records.append(SubscriptionRecord(id: id, manualName: try displayText(name), providerName: try displayText(name),
          sourceRef: ref, status: remote == nil ? "ready" : "approval_required", nodes: nodes,
          metadata: metadata, preferredFormat: "source", isLocal: remote == nil,
          fallbackHosts: source["fallbackHosts"] as? [String], fetchOptions: source["fetchOptions"] as? [String: String],
          hiddenNodes: hidden.isEmpty ? nil : hidden))
      }
      let stagedRouting = try routing.stageBackup(routes, assignments: assignments, sourceIDs: sourceIDs,
        manual: sources.filter { $0["manualRouting"] as? Bool == true }.compactMap { $0["id"] as? String })
      let marker = RefreshTransaction(schemaVersion: 1, subscriptions: try JSONEncoder().encode(previous),
        routing: try routing.checkpoint(), subscriptionID: "", approvedChain: [], candidateSecretRefs: refs,
        catalogReplacement: true)
      try JSONEncoder().encode(marker).write(to: transactionURL, options: [.atomic])
      transaction = marker
      try routing.restore(stagedRouting)
      catalog = SubscriptionCatalog(schemaVersion: 1, subscriptions: records,
        selectedNodeID: (backup["selectedNodeId"] as? String).flatMap { nodeIDs[$0] }, installationID: previous.installationID)
      try saveCatalog()
      restoredNodeIDs = nodeIDs
      return snapshot()
    } catch {
      if transaction != nil { try rollbackPublication() }
      else { refs.forEach(deleteSecret) }
      throw error
    }
  }

  func finishBackupRestore() throws {
    guard let marker = transaction, marker.catalogReplacement == true else { throw SubscriptionError.invalidState }
    let previous = try JSONDecoder().decode(SubscriptionCatalog.self, from: marker.subscriptions)
    try FileManager.default.removeItem(at: transactionURL)
    transaction = nil
    for old in previous.subscriptions {
      challengeVault.invalidate(subscriptionID: old.id)
      (old.allNodes.map(\.outboundRef) + (old.retiredSecretRefs ?? []) +
        [old.sourceRef, approvalRef(subscriptionID: old.id)] + [old.finalURLRef].compactMap { $0 }).forEach(deleteSecret)
    }
  }

  private func buildReplacement(
    old: SubscriptionRecord,
    parsed: [ParsedNode],
    fetched: FeedResponse,
    preservingNodeIDs: Bool = false
  ) throws -> (record: SubscriptionRecord, newSecretRefs: [String]) {
    var oldIdentities: [String: [String]] = [:]
    var oldConfigurations: [String: Data] = [:]
    // Hidden servers are matched too, so that a refresh keeps them out.
    for node in old.allNodes {
      let data = try readSecret(ref: node.outboundRef)
      let identity = try outboundIdentity(data)
      oldIdentities[identity, default: []].append(node.id)
      oldConfigurations[node.id] = try runtimeConfiguration(data)
    }
    if let selected = catalog.selectedNodeID {
      for identity in Array(oldIdentities.keys) {
        oldIdentities[identity] = prioritizingSelection(
          oldIdentities[identity] ?? [],
          selected: selected
        )
      }
    }
    let oldLogicalIDs = uniqueNodeIDs(old.allNodes.map {
      (key: matchKey($0), id: $0.id)
    })
    let newLogicalCounts = Dictionary(grouping: parsed, by: matchKey).mapValues(\.count)
    let oldNamedIDs = Dictionary(grouping: old.allNodes, by: \.name).compactMapValues {
      $0.count == 1 ? $0[0].id : nil
    }
    let newNameCounts = Dictionary(grouping: parsed, by: \.name).mapValues(\.count)
    var refs: [String] = []
    var nodes: [SubscriptionNode] = []
    var usedOldIDs = Set<String>()
    var exactIDs: [Int: String] = [:]
    if !preservingNodeIDs {
      for (position, node) in parsed.enumerated() {
        let identity = try outboundIdentity(node.outbound)
        if let id = oldIdentities[identity]?.first {
          exactIDs[position] = id
          oldIdentities[identity]?.removeFirst()
          usedOldIDs.insert(id)
        }
      }
    }
    do {
      for (position, originalNode) in parsed.enumerated() {
        var parsedNode = originalNode
        let identity = try outboundIdentity(parsedNode.outbound)
        // Unique names also survive transport/profile representation changes;
        // the configuration revision keeps prior health from following them.
        let fallbackID = (newLogicalCounts[matchKey(parsedNode)] == 1 ? oldLogicalIDs[matchKey(parsedNode)] : nil)
          ?? (newNameCounts[parsedNode.name] == 1 ? oldNamedIDs[parsedNode.name] : nil)
        let nodeID: String
        if preservingNodeIDs {
          guard old.nodes.indices.contains(position), old.nodes.count == parsed.count else { throw SubscriptionError.invalidState }
          nodeID = old.nodes[position].id
        } else if let exactID = exactIDs[position] {
          nodeID = exactID
        } else if var matchingIDs = oldIdentities[identity] {
          matchingIDs.removeAll(where: usedOldIDs.contains)
          if let exactID = matchingIDs.first {
            nodeID = exactID
            matchingIDs.removeFirst()
          } else if let logicalID = fallbackID,
                    !usedOldIDs.contains(logicalID) {
            nodeID = logicalID
          } else {
            nodeID = UUID().uuidString.lowercased()
          }
          oldIdentities[identity] = matchingIDs
        } else if let logicalID = fallbackID,
                  !usedOldIDs.contains(logicalID) {
          nodeID = logicalID
        } else {
          nodeID = UUID().uuidString.lowercased()
        }
        usedOldIDs.insert(nodeID)
        let previous = old.allNodes.first(where: { $0.id == nodeID })
        let overrides = previous?.groupOverrides
        if !preservingNodeIDs, let overrides { parsedNode = try applyingGroups(parsedNode, selections: overrides) }
        let ref: String
        if let previous, (previous.format ?? "xrayOutbound") == parsedNode.format,
           try oldConfigurations[nodeID] == runtimeConfiguration(parsedNode.outbound) {
          ref = previous.outboundRef
        } else {
          ref = "subscription.\(old.id).node.\(UUID().uuidString.lowercased())"
          try storeSecret(parsedNode.outbound, ref: ref)
          refs.append(ref)
        }
        nodes.append(SubscriptionNode(
          id: nodeID,
          name: parsedNode.name,
          protocolName: parsedNode.protocolName,
          transport: parsedNode.transport,
          security: parsedNode.security,
          outboundRef: ref,
          format: parsedNode.format,
          groups: parsedNode.groups,
          groupOverrides: overrides,
          ipPreference: previous?.ipPreference,
          favorite: previous?.favorite,
          manualName: previous?.manualName,
          lastSuccessAt: previous?.lastSuccessAt,
          lastSuccessRevision: previous?.lastSuccessRevision,
          lastSuccessSession: previous?.lastSuccessSession,
          probeKey: probeKey(outbound: parsedNode.outbound)
        ))
      }
      guard !nodes.isEmpty else { throw SubscriptionError.noSupportedNodes }
      // A group choice rebuilds the shown servers only, and keeps the hidden ones as they are.
      let hiddenIDs = Set((old.hiddenNodes ?? []).map(\.id))
      let hidden = preservingNodeIDs ? old.hiddenNodes ?? [] : nodes.filter { hiddenIDs.contains($0.id) }
      let finalRef = "subscription.\(old.id).final.\(UUID().uuidString.lowercased())"
      try storeSecret(JSONEncoder().encode(fetched.links), ref: finalRef)
      refs.append(finalRef)
      let providerName = try resolvedProviderName(
        importedName: old.importedName,
        header: fetched.profileTitle,
        finalURL: fetched.finalURL,
        sourceRef: old.sourceRef,
        existingID: old.id
      )
      return (
        SubscriptionRecord(
          id: old.id,
          manualName: old.manualName,
          providerName: providerName,
          sourceRef: old.sourceRef,
          finalURLRef: finalRef,
          lastSuccessfulFetch: Date(),
          contentDigest: Data(SHA256.hash(data: fetched.data)).base64EncodedString(),
          status: "ready",
          riskCodes: nil,
          nodes: preservingNodeIDs ? nodes : nodes.filter { !hiddenIDs.contains($0.id) },
          metadata: fetched.metadata,
          fallbackHosts: old.fallbackHosts,
          fetchOptions: old.fetchOptions,
          importedName: old.importedName,
          hiddenNodes: hidden.isEmpty ? nil : hidden
        ),
        refs
      )
    } catch {
      refs.forEach(deleteSecret)
      throw error
    }
  }

  private func selectedRoutingContent(_ fetched: FeedResponse, directives: [String] = []) throws -> String? {
    if fetched.metadata?.routingEnabled == false { return nil }
    let supplied = [fetched.routingHeader].compactMap { $0 }
      + routingLinks(fetched.data) + directives.filter(RoutingDomainDecoder.isRoutingLink)
    // Panels such as 3x-ui send their Happ routing to every client (3x-ui #5999),
    // so links addressed to Elarni win when a feed has any.
    let own = supplied.filter { $0.hasPrefix("elarni://routing/") }
    let candidates = own.isEmpty ? supplied : own
    // Match Windows: process the header before body directives, with the final
    // supplied profile taking precedence. Validate every directive before publishing.
    guard candidates.allSatisfy({ RoutingDomainDecoder.canonicalImport($0) != nil }) else {
      throw RoutingStoreError.invalidImport
    }
    return candidates.last
  }

  private func routingLinks(_ data: Data) -> [String] {
    guard let text = String(data: data, encoding: .utf8) else { return [] }
    return text.split(whereSeparator: \.isNewline).compactMap { line in
      let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
      return RoutingDomainDecoder.isRoutingLink(value) ? value : nil
    }
  }

  func parseFeed(_ data: Data) throws -> [ParsedNode] {
    try parseImport(data).nodes
  }

  /// The stored server with this configuration, which a local import may have kept.
  func nodeID(subscriptionID: String, matching node: ParsedNode) throws -> String? {
    let identity = try outboundIdentity(node.outbound)
    return try catalog.subscriptions.first { $0.id == subscriptionID }?.nodes.first {
      try outboundIdentity(readSecret(ref: $0.outboundRef)) == identity
    }?.id
  }

  func normalizeClientInput(_ text: String) throws -> (text: String, name: String?, shareLink: String?) {
    guard text.utf8.count <= Self.maxFeedBytes else { throw SubscriptionError.feedTooLarge }
    let data = try JSONSerialization.data(withJSONObject: ["apiVersion": 1,
      "method": "normalizeClientInput", "payload": ["text": text]])
    guard let request = String(data: data, encoding: .utf8), let pointer = strdup(request) else {
      throw SubscriptionError.invalidFeed
    }
    defer { free(pointer) }
    guard let response = CGoInvoke(pointer) else { throw SubscriptionError.invalidFeed }
    defer { CGoFree(response) }
    guard let bytes = String(cString: response).data(using: .utf8),
          let envelope = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
          envelope["success"] as? Bool == true,
          let value = envelope["data"] as? [String: Any], let content = value["text"] as? String else {
      throw SubscriptionError.invalidFeed
    }
    return (content, value["name"] as? String, value["shareLink"] as? String)
  }

  private func parseImport(_ data: Data, sourceURL: String? = nil, migrationHeaders: [String: String] = [:]) throws -> (nodes: [ParsedNode], directives: [String], hideURL: Bool, newSourceURL: String?, systemResolverDNS: Bool, fallbackURL: String?) {
    guard let text = String(data: data, encoding: .utf8) else {
      throw SubscriptionError.invalidFeed
    }
    let request: [String: Any] = [
      "apiVersion": 1,
      "method": "importClientProfiles",
      "payload": ["text": text, "sourceURL": sourceURL ?? "", "migrationHeaders": migrationHeaders],
    ]
    let requestData = try JSONSerialization.data(withJSONObject: request)
    guard let requestText = String(data: requestData, encoding: .utf8),
          let pointer = strdup(requestText) else { throw SubscriptionError.invalidFeed }
    defer { free(pointer) }
    guard let responsePointer = CGoInvoke(pointer) else { throw SubscriptionError.invalidFeed }
    defer { CGoFree(responsePointer) }
    let response = String(cString: responsePointer)
    guard let responseData = response.data(using: .utf8),
          let envelope = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
      throw SubscriptionError.invalidFeed
    }
    guard envelope["success"] as? Bool == true else {
      // Core errors may include provider-controlled keys or credentials. Only
      // fixed descriptions cross the UI boundary.
      let detail = envelope["error"] as? String ?? ""
      let message: String
      if detail.contains("Clash") { message = "This Clash profile contains invalid or unsupported options. Use the provider’s Xray JSON format for advanced groups, rules, or DNS." }
      else if detail.contains("WireGuard") || detail.contains("Amnezia") { message = "The WireGuard or AmneziaWG configuration has invalid keys, endpoints, or unsupported interface options." }
      else { message = "The client profile is invalid or uses settings unsupported by the bundled core. The entire import was rejected." }
      throw SubscriptionError.incompatibleProfile(message)
    }
    guard
          let imported = envelope["data"] as? [String: Any],
          let profiles = imported["profiles"] as? [[String: Any]] else {
      throw SubscriptionError.invalidFeed
    }
    let nodes = try profiles.map { profile -> ParsedNode in
      guard let format = profile["format"] as? String else { throw SubscriptionError.invalidFeed }
      if format == "telegram" {
        guard let url = profile["url"] as? String else { throw SubscriptionError.invalidFeed }
        return ParsedNode(name: "Telegram proxy", protocolName: "MTProto", transport: "Telegram", security: "MTProto",
          outbound: try JSONSerialization.data(withJSONObject: ["url": url], options: [.sortedKeys]), format: format)
      }
      guard format == "xrayProfile", let config = profile["config"] as? [String: Any],
            let outbounds = config["outbounds"] as? [[String: Any]], let outbound = outbounds.first,
            let protocolName = outbound["protocol"] as? String else { throw SubscriptionError.invalidFeed }
      do { _ = try RoutingDomainDecoder.request("compileProfile", payload: ["profile": config, "socksPort": 1080]) }
      catch { throw SubscriptionError.incompatibleProfile("The profile contains an invalid or unsupported routing graph, dependency, or endpoint. The entire import was rejected.") }
      let stream = outbound["streamSettings"] as? [String: Any]
      let names = ["vless": "VLESS", "vmess": "VMess", "trojan": "Trojan", "shadowsocks": "Shadowsocks",
        "socks": "SOCKS", "http": "HTTP", "hysteria": "Hysteria2", "tuic": "TUIC", "wireguard": "WireGuard", "amneziawg": "AmneziaWG"]
      let displayProtocol = outbounds.count > 1 ? "Xray profile" : names[protocolName] ?? protocolName
      let wireguard = ["wireguard", "amneziawg"].contains(protocolName)
      let transport = protocolName == "tuic" ? "QUIC" : (stream?["network"] as? String).flatMap(usableDisplayText) ?? (wireguard ? "UDP" : protocolName)
      let security = protocolName == "tuic" ? "TLS" : (stream?["security"] as? String).flatMap(usableDisplayText) ?? (wireguard ? "encrypted" : "none")
      let name = (profile["name"] as? String).flatMap(usableDisplayText)
        ?? "\(displayProtocol) · \(transport) · \(security)"
      let encoded = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
      guard encoded.count <= Self.maxFeedBytes else { throw SubscriptionError.invalidFeed }
      return ParsedNode(
        name: name,
        protocolName: displayProtocol,
        transport: transport,
        security: security,
        outbound: encoded,
        format: format,
        groups: try profileGroups(config)
      )
    }
    return (nodes, imported["directives"] as? [String] ?? [], imported["hideURL"] as? Bool == true, imported["newSourceURL"] as? String,
      imported["systemResolverDNS"] as? Bool == true, imported["fallbackURL"] as? String)
  }

  private func profileGroups(_ config: [String: Any]) throws -> [ProfileGroupSelection]? {
    guard let groups = config["elarniGroups"] else { return nil }
    return try JSONDecoder().decode([ProfileGroupSelection].self, from: JSONSerialization.data(withJSONObject: groups))
  }

  private func applyingGroups(_ node: ParsedNode, selections: [String: String]) throws -> ParsedNode {
    guard node.format == "xrayProfile",
          var config = try JSONSerialization.jsonObject(with: node.outbound) as? [String: Any],
          var groups = config["elarniGroups"] as? [[String: Any]] else { return node }
    for index in groups.indices {
      if let name = groups[index]["name"] as? String, let choice = selections[name],
         let options = groups[index]["options"] as? [String], options.contains(choice) { groups[index]["selected"] = choice }
    }
    config["elarniGroups"] = groups
    _ = try RoutingDomainDecoder.request("compileProfile", payload: ["profile": config, "socksPort": 1080])
    var updated = node
    updated.outbound = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
    updated.groups = try profileGroups(config)
    return updated
  }

  func setNodeIPPreference(nodeID: String, preference: String?) async throws -> SubscriptionOperationResult {
    guard preference == nil || ["automatic", "ipv4", "ipv6"].contains(preference!),
          transaction == nil, !publicationRecoveryRequired,
          var record = catalog.subscriptions.first(where: { $0.nodes.contains(where: { $0.id == nodeID }) }),
          refreshTasks[record.id] == nil,
          let position = record.nodes.firstIndex(where: { $0.id == nodeID }),
          record.nodes[position].format != "telegram" else { throw SubscriptionError.invalidState }
    guard record.nodes[position].ipPreference != preference else {
      return SubscriptionOperationResult(snapshot: snapshot(), removedSelection: false, warning: nil)
    }
    record.nodes[position].ipPreference = preference
    record.publishedRevision = UUID().uuidString.lowercased()
    let generation = UUID()
    refreshGenerations[record.id] = generation
    defer { if refreshGenerations[record.id] == generation { refreshGenerations.removeValue(forKey: record.id) } }
    guard let publishRefresh else { throw SubscriptionError.invalidState }
    try await publishRefresh(RefreshCandidate(record: record, generation: generation,
      routingContent: nil, approvedChain: try readApprovalChain(subscriptionID: record.id)))
    return SubscriptionOperationResult(snapshot: snapshot(), removedSelection: false, warning: nil)
  }

  func selectProfileGroup(nodeID: String, group: String, choice: String) async throws -> SubscriptionOperationResult {
    guard transaction == nil, !publicationRecoveryRequired,
          let record = catalog.subscriptions.first(where: { $0.nodes.contains(where: { $0.id == nodeID }) }),
          refreshTasks[record.id] == nil,
          let position = record.nodes.firstIndex(where: { $0.id == nodeID }),
          record.nodes[position].groups?.contains(where: { $0.name == group && $0.options.contains(choice) }) == true else {
      throw SubscriptionError.invalidState
    }
    var parsed = try record.nodes.map { node in
      ParsedNode(name: node.name, protocolName: node.protocolName, transport: node.transport, security: node.security,
        outbound: try readSecret(ref: node.outboundRef), format: node.format ?? "xrayOutbound", groups: node.groups)
    }
    parsed[position] = try applyingGroups(parsed[position], selections: [group: choice])
    let links = providerLinks(record)
    let fetched = FeedResponse(data: try JSONEncoder().encode(parsed.map(\.outbound)),
      finalURL: links.urls["source"].flatMap(URL.init(string:)) ?? URL(string: "elarni://local")!,
      profileTitle: record.providerName, routingHeader: nil, unsafeTargetChain: try readApprovalChain(subscriptionID: record.id),
      metadata: record.metadata, links: links)
    let generation = UUID()
    refreshGenerations[record.id] = generation
    defer { if refreshGenerations[record.id] == generation { refreshGenerations.removeValue(forKey: record.id) } }
    var replacement = try buildReplacement(old: record, parsed: parsed, fetched: fetched, preservingNodeIDs: true)
    replacement.record.refreshSchedule = record.refreshSchedule
    replacement.record.refreshInterval = record.refreshInterval
    replacement.record.lastSuccessfulFetch = record.lastSuccessfulFetch
    replacement.record.isLocal = record.isLocal
    replacement.record.preferredFormat = record.preferredFormat
    replacement.record.publishedRevision = UUID().uuidString.lowercased()
    replacement.record.retiredSecretRefs = (record.retiredSecretRefs ?? []) + record.nodes.map(\.outboundRef) + [record.finalURLRef].compactMap { $0 }
    var overrides = record.nodes[position].groupOverrides ?? [:]
    overrides[group] = choice
    replacement.record.nodes[position].groupOverrides = overrides
    do {
      guard let publishRefresh else { throw SubscriptionError.invalidState }
      try await publishRefresh(RefreshCandidate(record: replacement.record, generation: generation,
        routingContent: nil, approvedChain: fetched.unsafeTargetChain))
    } catch {
      if transaction == nil {
        let retained = Set(catalog.subscriptions.flatMap { $0.allNodes.map(\.outboundRef) + ($0.retiredSecretRefs ?? []) + [$0.finalURLRef].compactMap { $0 } })
        replacement.newSecretRefs.filter { !retained.contains($0) }.forEach(deleteSecret)
      }
      throw error
    }
    return SubscriptionOperationResult(snapshot: snapshot(), removedSelection: false, warning: nil)
  }

  private func matchKey(_ node: SubscriptionNode) -> SubscriptionNodeMatchKey {
    SubscriptionNodeMatchKey(
      name: node.name,
      protocolName: node.protocolName,
      transport: node.transport,
      security: node.security
    )
  }

  private func matchKey(_ node: ParsedNode) -> SubscriptionNodeMatchKey {
    SubscriptionNodeMatchKey(
      name: node.name,
      protocolName: node.protocolName,
      transport: node.transport,
      security: node.security
    )
  }

  private func outboundIdentity(_ data: Data) throws -> String {
    guard let outbound = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let identity = try RoutingDomainDecoder.request("catalogIdentity", payload: outbound)["identity"] as? String else {
      throw SubscriptionError.invalidFeed
    }
    return identity
  }

  private func runtimeConfiguration(_ data: Data) throws -> Data {
    guard var config = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw SubscriptionError.invalidFeed
    }
    config.removeValue(forKey: "remarks")
    config.removeValue(forKey: "name")
    // Unlike node identity, group selections, tags and sendThrough affect traffic.
    return try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
  }

  private func resolvedProviderName(
    importedName: String?,
    header: String?,
    finalURL: URL,
    sourceRef: String,
    existingID: String
  ) throws -> String {
    if let title = header.flatMap(decodedProfileTitle), let valid = usableDisplayText(title) { return valid }
    if let importedName { return importedName }
    if let host = usableDisplayText(finalURL.host ?? "") { return host }
    if let source = try? readSecret(ref: sourceRef),
       let text = String(data: source, encoding: .utf8),
       let host = URL(string: text)?.host.flatMap(usableDisplayText) { return host }
    return fallbackName(excluding: existingID)
  }

  private func fallbackName(excluding id: String? = nil) -> String {
    let used = Set(catalog.subscriptions.filter { $0.id != id }.map(\.providerName))
    var number = 1
    while used.contains("Subscription \(number)") { number += 1 }
    return "Subscription \(number)"
  }

  private func subscriptionMap(_ record: SubscriptionRecord) -> [String: Any] {
    [
      "id": record.id,
      "name": record.manualName ?? record.providerName,
      "status": record.status,
      "riskCodes": record.riskCodes ?? [],
      "lastSuccessfulFetch": record.lastSuccessfulFetch?.timeIntervalSince1970 ?? NSNull(),
      "nextRefreshAt": record.isLocal == true ? NSNull() : (scheduleFor(record).due?.timeIntervalSince1970 ?? NSNull()),
      "refreshError": scheduleFor(record).errorCategory ?? NSNull(),
      "publishedRevision": record.publishedRevision ?? NSNull(),
      "metadata": record.metadata?.channelMap ?? NSNull(),
      "actions": providerLinks(record).actions,
      "format": record.preferredFormat ?? "source",
      "isLocal": record.isLocal ?? false,
      "fallbackHosts": record.fallbackHosts ?? [],
      "fetchOptions": record.fetchOptions ?? [:],
      "hiddenNodes": (record.hiddenNodes ?? []).map { ["id": $0.id, "name": $0.displayName] },
      "nodes": record.nodes.map { node in
        [
          "id": node.id,
          "name": node.displayName,
          "protocol": node.protocolName,
          "transport": node.transport,
          "security": node.security,
          "format": node.format ?? "xrayOutbound",
          "ipPreference": node.ipPreference as Any? ?? NSNull(),
          "groups": (node.groups ?? []).map { ["name": $0.name, "options": $0.options, "selected": $0.selected] as [String: Any] },
          "selected": node.id == catalog.selectedNodeID,
          "favorite": node.favorite ?? false,
          "configurationRevision": (try? nodeRevision(node)) ?? "unavailable",
          "lastSuccessAt": node.lastSuccessAt?.timeIntervalSince1970 ?? NSNull(),
          "lastSuccessCurrent": node.lastSuccessRevision != nil && node.lastSuccessRevision == (try? nodeRevision(node)),
          "probeKey": node.probeKey as Any? ?? NSNull(),
        ] as [String: Any]
      },
    ]
  }

  private func validatedURL(_ text: String) throws -> URL {
    // Normalize saved sources too, including labelled links stored by older builds.
    let text = try normalizeClientInput(text).text
    guard text.utf8.count <= 16 * 1024,
          !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
          let components = URLComponents(string: text),
          let scheme = components.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          let host = components.host,
          !host.isEmpty,
          let url = components.url else { throw SubscriptionError.invalidURL }
    return url
  }

  private func providerLinks(_ record: SubscriptionRecord) -> ProviderLinks {
    guard let ref = record.finalURLRef, let data = try? readSecret(ref: ref),
          let links = try? JSONDecoder().decode(ProviderLinks.self, from: data) else { return ProviderLinks() }
    return links
  }

  func providerURL(subscriptionID: String, action: String) throws -> URL {
    guard let record = catalog.subscriptions.first(where: { $0.id == subscriptionID }),
          ["support", "account", "banner"].contains(action),
          let text = providerLinks(record).urls[action], let url = ProviderLinks.safeURL(text) else {
      throw SubscriptionError.invalidURL
    }
    return url
  }

  private func displayText(_ text: String) throws -> String {
    guard let value = usableDisplayText(text) else { throw SubscriptionError.invalidDisplayName }
    return value
  }

  private func usableDisplayText(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 256,
          !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
      return nil
    }
    return trimmed
  }

  private func saveCatalog() throws {
    let data = try JSONEncoder().encode(catalog)
    try data.write(to: catalogURL, options: [.atomic])
  }

  private func storeSecret(_ data: Data, ref: String) throws {
    guard !data.isEmpty, data.count <= Self.maxFeedBytes else {
      throw SubscriptionError.keychainFailure
    }
    let status = secretAccess.add([
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: Self.service,
      kSecAttrAccount: ref,
      kSecAttrAccessGroup: try effectiveAccessGroup(),
      kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      kSecAttrSynchronizable: false,
      kSecUseDataProtectionKeychain: true,
      kSecValueData: data,
    ] as CFDictionary, nil)
    guard status == errSecSuccess else { throw SubscriptionError.keychainFailure }
  }

  func storeInboundCredentials(username: String, password: String) throws -> String {
    guard (1...255).contains(username.utf8.count), (1...255).contains(password.utf8.count),
          !username.contains(":"),
          !username.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
          !password.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else { throw SubscriptionError.keychainFailure }
    let ref = "inbound.\(UUID().uuidString.lowercased())"
    let data = try JSONSerialization.data(withJSONObject: ["username": username, "password": password])
    try storeSecret(data, ref: ref)
    return ref
  }

  func inboundCredentials(ref: String) throws -> [String: String] {
    guard ref.hasPrefix("inbound."),
          let value = try JSONSerialization.jsonObject(with: readSecret(ref: ref)) as? [String: String],
          let username = value["username"], let password = value["password"],
          !username.isEmpty, !password.isEmpty else { throw SubscriptionError.keychainFailure }
    return ["username": username, "password": password]
  }

  func removeInboundCredentials(ref: String) {
    guard ref.hasPrefix("inbound.") else { return }
    deleteSecret(ref)
  }

  private func readSecret(ref: String) throws -> Data {
    var value: CFTypeRef?
    let status = secretAccess.copy([
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: Self.service,
      kSecAttrAccount: ref,
      kSecAttrAccessGroup: try effectiveAccessGroup(),
      kSecUseDataProtectionKeychain: true,
      kSecReturnData: true,
      kSecMatchLimit: kSecMatchLimitOne,
    ] as CFDictionary, &value)
    if status == errSecItemNotFound {
      return try migrateLegacySecret(ref: ref)
    }
    guard status == errSecSuccess, let data = value as? Data else {
      throw SubscriptionError.keychainFailure
    }
    return data
  }

  private func deleteSecret(_ ref: String) {
    guard let accessGroup = try? effectiveAccessGroup() else { return }
    _ = secretAccess.delete([
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: Self.service,
      kSecAttrAccount: ref,
      kSecAttrAccessGroup: accessGroup,
      kSecUseDataProtectionKeychain: true,
    ] as CFDictionary)
  }

  private func approvalRef(subscriptionID: String) -> String {
    "subscription.\(subscriptionID).safety-approvals"
  }

  private func readApprovalChain(subscriptionID: String) throws -> [String] {
    var value: CFTypeRef?
    let status = secretAccess.copy([
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: Self.service,
      kSecAttrAccount: approvalRef(subscriptionID: subscriptionID),
      kSecAttrAccessGroup: try effectiveAccessGroup(),
      kSecUseDataProtectionKeychain: true,
      kSecReturnData: true,
      kSecMatchLimit: kSecMatchLimitOne,
    ] as CFDictionary, &value)
    if status == errSecItemNotFound { return [] }
    guard status == errSecSuccess,
          let data = value as? Data,
          let chain = try? JSONDecoder().decode([String].self, from: data),
          chain.count <= 64,
          chain.allSatisfy({ $0.count == 64 && $0.allSatisfy(\.isHexDigit) }) else {
      throw SubscriptionError.keychainFailure
    }
    return chain
  }

  private func writeApprovalChain(_ chain: [String], subscriptionID: String) throws {
    let ref = approvalRef(subscriptionID: subscriptionID)
    if chain.isEmpty {
      try deleteApprovalChain(subscriptionID: subscriptionID)
      return
    }
    let data = try JSONEncoder().encode(chain)
    let accessGroup = try effectiveAccessGroup()
    let query = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: Self.service,
      kSecAttrAccount: ref,
      kSecAttrAccessGroup: accessGroup,
      kSecUseDataProtectionKeychain: true,
    ] as CFDictionary
    let status = secretAccess.update(query, [kSecValueData: data] as CFDictionary)
    if status == errSecItemNotFound {
      try storeSecret(data, ref: ref)
    } else if status != errSecSuccess {
      throw SubscriptionError.keychainFailure
    }
  }

  private func deleteApprovalChain(subscriptionID: String) throws {
    let status = secretAccess.delete([
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: Self.service,
      kSecAttrAccount: approvalRef(subscriptionID: subscriptionID),
      kSecAttrAccessGroup: try effectiveAccessGroup(),
      kSecUseDataProtectionKeychain: true,
    ] as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw SubscriptionError.keychainFailure
    }
  }

  private func migrateLegacySecret(ref: String) throws -> Data {
    let accessGroup = try effectiveAccessGroup()
    var value: CFTypeRef?
    let status = secretAccess.copy([
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: Self.service,
      kSecAttrAccount: ref,
      kSecAttrAccessGroup: accessGroup,
      kSecReturnData: true,
      kSecMatchLimit: kSecMatchLimitOne,
    ] as CFDictionary, &value)
    guard status == errSecSuccess, let data = value as? Data else {
      throw SubscriptionError.keychainFailure
    }
    try storeSecret(data, ref: ref)
    _ = secretAccess.delete([
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: Self.service,
      kSecAttrAccount: ref,
      kSecAttrAccessGroup: accessGroup,
    ] as CFDictionary)
    return data
  }

  private func effectiveAccessGroup() throws -> String {
    try secretAccess.accessGroup()
  }
}

struct RefreshCandidate {
  fileprivate let record: SubscriptionRecord
  fileprivate let generation: UUID
  fileprivate let routingContent: String?
  fileprivate let approvedChain: [String]
}

private struct RefreshTransaction: Codable {
  let schemaVersion: Int
  let subscriptions: Data
  let routing: Data
  let subscriptionID: String
  let approvedChain: [String]
  let candidateSecretRefs: [String]
  var catalogReplacement: Bool?
  var selection: Bool?
}

private struct SubscriptionCatalog: Codable {
  let schemaVersion: Int
  var subscriptions: [SubscriptionRecord]
  var selectedNodeID: String?
  var publishedRevision: String?
  var installationID: String?
  var runtimeReconciliationRequired: Bool?
}

private struct SubscriptionRecord: Codable {
  let id: String
  var manualName: String?
  var providerName: String
  var sourceRef: String
  var finalURLRef: String?
  var lastSuccessfulFetch: Date?
  var contentDigest: String?
  var status: String
  var riskCodes: [String]?
  var nodes: [SubscriptionNode]
  var refreshSchedule: RefreshSchedule?
  var refreshInterval: Double?
  var publishedRevision: String?
  var retiredSecretRefs: [String]?
  var metadata: ProviderMetadata?
  var preferredFormat: String?
  var isLocal: Bool?
  var fallbackHosts: [String]?
  var fetchOptions: [String: String]?
  var importedName: String?
  /// Servers the user hid; refresh matches them, so the provider cannot add them back.
  var hiddenNodes: [SubscriptionNode]? = nil
  var allNodes: [SubscriptionNode] { nodes + (hiddenNodes ?? []) }
  /// Set by a device ID reset; without it the ID is the one this install always sent.
  var deviceSalt: String? = nil
}

private struct SubscriptionNode: Codable {
  let id: String
  let name: String
  let protocolName: String
  let transport: String
  let security: String
  let outboundRef: String
  var format: String? = nil
  var groups: [ProfileGroupSelection]? = nil
  var groupOverrides: [String: String]? = nil
  var ipPreference: String? = nil
  var favorite: Bool? = nil
  /// The user's name; `name` stays the provider's, which refresh matches on.
  var manualName: String? = nil
  var lastSuccessAt: Date? = nil
  var lastSuccessRevision: String? = nil
  var lastSuccessSession: String? = nil
  /// The SNI its probes send; nil for records saved before 0.3.7 until their next refresh.
  var probeKey: String? = nil
  var displayName: String { manualName ?? name }
}

struct ProfileGroupSelection: Codable {
  let name: String
  let options: [String]
  let selected: String
}

struct ParsedNode {
  let name: String
  let protocolName: String
  let transport: String
  let security: String
  var outbound: Data
  var format: String = "xrayProfile"
  var groups: [ProfileGroupSelection]? = nil
}

enum SubscriptionError: Error, Equatable {
  case invalidCatalog
  case invalidURL
  case invalidFeed
  case incompatibleProfile(String)
  case noSupportedNodes
  case invalidDisplayName
  case invalidState
  case notFound
  case keychainFailure
  case fetchFailed
  /// The core's download failure class, such as rate_limited, so the app can say whose fault it is.
  case fetchClass(String)
  case fetchRejected(Int)
  case feedTooLarge
  case hwidRequired
  case hwidLimit

  var hwidStatus: String? {
    switch self { case .hwidRequired: "device_required"; case .hwidLimit: "device_limit"; default: nil }
  }

  static func hwidFailure(_ response: HTTPURLResponse) -> Self? {
    guard !(200...299).contains(response.statusCode) else { return nil }
    if ["X-Hwid-Limit", "X-Hwid-Max-Devices-Reached"].contains(where: { response.value(forHTTPHeaderField: $0)?.lowercased() == "true" }) { return .hwidLimit }
    if response.value(forHTTPHeaderField: "X-Hwid-Not-Supported")?.lowercased() == "true" { return .hwidRequired }
    return nil
  }
}

struct SubscriptionOperationResult {
  let snapshot: [String: Any]
  let removedSelection: Bool
  let warning: SubscriptionSafetyWarning?

  var channelMap: [String: Any] {
    [
      "subscriptions": snapshot,
      "warning": warning?.channelMap ?? NSNull(),
    ]
  }
}

