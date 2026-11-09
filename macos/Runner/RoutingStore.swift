import CryptoKit
import Foundation
import Security

enum RoutingStoreError: Error {
  case invalidCatalog
  case invalidImport
  case notFound
  case noSelectedSubscription
  case sharedContainerUnavailable
  // Selectors whose codes the geofiles lack although a Proxy rule or another reference needs them.
  case missingGeodata([String])
  case routeModelTooLarge
  // A geofile the core would load whole is over maxGeofileBytes.
  case geofileTooLarge
}
struct RuntimeRoutingRevision: Equatable {
  let name: String
  let digest: String
  let assetRevision: String?
}
@MainActor
final class RoutingStore {
#if os(iOS)
  // The iOS extension parses and copies the route model several times within about 50 MB.
  // shortcut: estimated, not measured on a device; measure the extension's peak memory at connect and adjust.
  static let maxRouteModelBytes = 2 * 1024 * 1024
#else
  static let maxRouteModelBytes = 8 * 1024 * 1024
#endif
  // The core reads each geofile whole; a downloaded original may be up to libXray's geo.MaxSourceBytes.
  static let maxGeofileBytes = 64 * 1024 * 1024
  static let maxOriginalGeofileBytes = 256 * 1024 * 1024
  nonisolated static let geofileTooLargeMessage = "A geofile is over 64 MB, which the core cannot load whole. " +
    "Turn on Reduce routing-data size for this profile or use a smaller geofile."
  private var staging = false

  func beginStaging() throws -> Data {
    guard !staging else { throw RoutingStoreError.invalidCatalog }
    let before = try checkpoint()
    staging = true
    return before
  }

  func endStaging(_ before: Data) throws {
    catalog = try JSONDecoder().decode(RoutingCatalog.self, from: before)
    staging = false
  }

  func previewRoutes(subscriptionID: String) throws -> [String: Any]? {
    guard let id = catalog.assignments[subscriptionID],
          let record = catalog.profiles.first(where: { $0.id == id && $0.enabled }) else { return nil }
    return try JSONSerialization.jsonObject(with: record.routeModel) as? [String: Any]
  }

  func previewAssetRevision(subscriptionID: String) -> String? {
    guard let id = catalog.assignments[subscriptionID],
          let record = catalog.profiles.first(where: { $0.id == id && $0.enabled }) else { return nil }
    return record.assetRevision
  }
#if os(iOS)
  private static var appGroup: String { IOSPlatform.appGroup }
#else
  private static let appGroup = "group.com.elarni.mac"
#endif
  private var catalog: RoutingCatalog
  private let catalogURL: URL
  private let revisionsURL: URL
  private let assetsURL: URL
  private var refreshingGeofiles = Set<String>()
  // A failed publication restores the old record, which is due again at once;
  // without this backoff maintenance re-downloads the geofiles in a tight loop.
  private var geofileRetryAfter: [String: Date] = [:]
  private var pendingAssetRevisions: [String: Set<String>] = [:]
  private var managedTasks: [String: Task<Void, Error>] = [:]
  var publishManaged: ((ManagedCandidate) async throws -> Void)?
  var now: () -> Date = Date.init
  var jitter: () -> Double = { Double.random(in: -1...1) }
  // Saves the download to the given file. Given the stored file's validators, false means that file is current.
  var fetchGeofile: (URL, GeofileValidators?, URL) async throws -> (downloaded: Bool, validators: GeofileValidators?) = { url, stored, file in
    try await RoutingResourceFetcher.fetchGeofile(url, stored: stored, to: file)
  }
  // The server configs of these subscriptions; their own rules may name geodata codes.
  var serverConfigs: ([String]) throws -> [Any] = { _ in [] }
  // Their secret references, which change whenever a config does; reading them costs nothing.
  var serverRefs: ([String]) -> [String] = { _ in [] }

  init(directory: URL? = nil) throws {
    let root: URL
    if let directory {
      root = directory
    } else {
      guard let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: Self.appGroup
      ) else { throw RoutingStoreError.sharedContainerUnavailable }
      root = container.appendingPathComponent("Routing", isDirectory: true)
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    revisionsURL = root.appendingPathComponent("Revisions", isDirectory: true)
    try FileManager.default.createDirectory(at: revisionsURL, withIntermediateDirectories: true)
    assetsURL = root.appendingPathComponent("Assets", isDirectory: true)
    try FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true)
    catalogURL = root.appendingPathComponent("routing-v1.json")
    if FileManager.default.fileExists(atPath: catalogURL.path) {
      let data = try Data(contentsOf: catalogURL, options: [.mappedIfSafe])
      guard let decoded = try? JSONDecoder().decode(RoutingCatalog.self, from: data),
            decoded.schemaVersion == 1 else {
        throw RoutingStoreError.invalidCatalog
      }
      catalog = decoded
    } else {
      catalog = RoutingCatalog(schemaVersion: 1, profiles: [], assignments: [:])
      try save()
    }
  }

  func snapshot() -> [String: Any] {
    [
      "profiles": catalog.profiles.map(profileMap),
      "assignments": catalog.assignments,
    ]
  }

  func checkpoint() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(catalog)
  }

  func backupCatalog() throws -> [String: Any] {
    let routes: [[String: Any]] = try catalog.profiles.map { record in
      var result: [String: Any] = ["id": record.id, "enabled": record.enabled, "edited": record.edited,
        "profile": try JSONSerialization.jsonObject(with: record.workingProfile)]
      if let source = record.providerSubscriptionID, let original = record.providerProfile {
        result["providerSubscriptionId"] = source
        result["providerProfile"] = try JSONSerialization.jsonObject(with: original)
      }
      return result
    }
    return ["routes": routes, "assignments": catalog.assignments]
  }

  func stageBackup(_ routes: [[String: Any]], assignments: [String: String], sourceIDs: [String: String], manual: [String] = []) throws -> Data {
    let previous = catalog
    defer { catalog = previous }
    catalog = RoutingCatalog(schemaVersion: 1, profiles: [], assignments: [:])
    var ids: [String: String] = [:]
    for entry in routes {
      guard let oldID = entry["id"] as? String, let enabled = entry["enabled"] as? Bool,
            let edited = entry["edited"] as? Bool, let raw = entry["profile"] as? [String: Any] else { throw RoutingStoreError.invalidImport }
      let decoded = try RoutingDomainDecoder.decode(String(decoding: JSONSerialization.data(withJSONObject: raw), as: UTF8.self))
      guard let profile = decoded.profile, let model = decoded.routeModel else { throw RoutingStoreError.invalidImport }
      var originalProfile: Data?, originalModel: Data?
      if let raw = entry["providerProfile"] as? [String: Any] {
        let original = try RoutingDomainDecoder.decode(String(decoding: JSONSerialization.data(withJSONObject: raw), as: UTF8.self))
        guard let profile = original.profile, let model = original.routeModel else { throw RoutingStoreError.invalidImport }
        originalProfile = try JSONSerialization.data(withJSONObject: profile, options: [.sortedKeys])
        originalModel = try JSONSerialization.data(withJSONObject: model, options: [.sortedKeys])
      }
      let id = UUID().uuidString.lowercased()
      ids[oldID] = id
      let hasGeo = ["Geoipurl", "Geositeurl"].contains { (profile[$0] as? String)?.isEmpty == false }
      catalog.profiles.append(RoutingRecord(id: id, name: profile["Name"] as? String ?? "Routing Profile",
        providerSubscriptionID: (entry["providerSubscriptionId"] as? String).flatMap { sourceIDs[$0] },
        providerProfile: originalProfile, providerRouteModel: originalModel,
        workingProfile: try JSONSerialization.data(withJSONObject: profile, options: [.sortedKeys]),
        routeModel: try JSONSerialization.data(withJSONObject: model, options: [.sortedKeys]),
        edited: edited, enabled: enabled, updatedAt: Date(), geofileStatus: hasGeo ? "pending" : "ready",
        geoipURL: profile["Geoipurl"] as? String, geositeURL: profile["Geositeurl"] as? String))
      try rebuildManaged(index: catalog.profiles.count - 1)
    }
    for (source, route) in assignments {
      guard let newSource = sourceIDs[source], let newRoute = ids[route] else { throw RoutingStoreError.invalidImport }
      catalog.assignments[newSource] = newRoute
    }
    catalog.manualAssignments = manual.compactMap { sourceIDs[$0] }
    return try checkpoint()
  }

  func restore(_ checkpoint: Data, publishedRevision: String? = nil) throws {
    var restored = try JSONDecoder().decode(RoutingCatalog.self, from: checkpoint)
    guard restored.schemaVersion == 1 else { throw RoutingStoreError.invalidCatalog }
    if let publishedRevision { restored.publishedRevision = publishedRevision }
    for index in restored.profiles.indices { restored.profiles[index].publicationGeneration = UUID() }
    let previous = catalog
    catalog = restored
    do { try save() } catch { catalog = previous; throw error }
  }

  func stageProvider(_ content: String, subscriptionID: String) throws -> Data {
    let previous = catalog
    defer { catalog = previous }
    try importProvider(content, subscriptionID: subscriptionID, persist: false)
    return try checkpoint()
  }

  func importContent(_ content: String, selectedSubscriptionID: String?) throws -> [String: Any] {
    let decoded = try RoutingDomainDecoder.decode(content)
    if decoded.action == "off" {
      guard let selectedSubscriptionID else { throw RoutingStoreError.noSelectedSubscription }
      assignByUser(selectedSubscriptionID, nil)
      try save()
      return snapshot()
    }
    guard let profile = decoded.profile,
          let routeModel = decoded.routeModel else {
      throw RoutingStoreError.invalidImport
    }
    let name = (profile["Name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
      ?? "Routing Profile"
    let profileData = try JSONSerialization.data(withJSONObject: profile, options: [.sortedKeys])
    let routeData = try JSONSerialization.data(withJSONObject: routeModel, options: [.sortedKeys])
    let id: String
    let previous: RoutingRecord?
    if let index = catalog.profiles.firstIndex(where: {
      $0.providerSubscriptionID == nil && $0.name == name
    }) {
      previous = catalog.profiles[index]
      id = catalog.profiles[index].id
      catalog.profiles[index].workingProfile = profileData
      catalog.profiles[index].routeModel = routeData
      catalog.profiles[index].edited = true
      catalog.profiles[index].enabled = true
      catalog.profiles[index].updatedAt = Date()
    } else {
      previous = nil
      id = UUID().uuidString.lowercased()
      catalog.profiles.append(RoutingRecord(
        id: id,
        name: name,
        providerSubscriptionID: nil,
        providerProfile: nil,
        providerRouteModel: nil,
        workingProfile: profileData,
        routeModel: routeData,
        edited: true,
        enabled: true,
        updatedAt: Date(),
        geofileStatus: "pending",
        geoipURL: profile["Geoipurl"] as? String,
        geositeURL: profile["Geositeurl"] as? String,
        lastGeoRefresh: nil,
        assetRevision: nil
      ))
    }
    if decoded.activate {
      guard let selectedSubscriptionID else { throw RoutingStoreError.noSelectedSubscription }
      assignByUser(selectedSubscriptionID, id)
    }
    if let index = catalog.profiles.firstIndex(where: { $0.id == id }) {
      try rebuildManaged(index: index)
      if let previous { invalidateReduction(index: index, profile: profile, previous: previous) }
    }
    try save()
    return snapshot()
  }

  func importProvider(_ content: String, subscriptionID: String, persist: Bool = true) throws {
    let decoded = try RoutingDomainDecoder.decode(content)
    if decoded.action == "off" {
      if !isManual(subscriptionID: subscriptionID) { catalog.assignments.removeValue(forKey: subscriptionID) }
      if persist { try save() }
      return
    }
    guard let profile = decoded.profile,
          let routeModel = decoded.routeModel else {
      throw RoutingStoreError.invalidImport
    }
    let name = (profile["Name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
      ?? "Routing Profile"
    let profileData = try JSONSerialization.data(withJSONObject: profile, options: [.sortedKeys])
    let routeData = try JSONSerialization.data(withJSONObject: routeModel, options: [.sortedKeys])
    var previous: RoutingRecord?
    if let index = catalog.profiles.firstIndex(where: {
      $0.providerSubscriptionID == subscriptionID
    }) {
      previous = catalog.profiles[index]
      catalog.profiles[index].name = name
      catalog.profiles[index].providerProfile = profileData
      catalog.profiles[index].providerRouteModel = routeData
      catalog.profiles[index].updatedAt = Date()
      if !catalog.profiles[index].edited {
        catalog.profiles[index].workingProfile = profileData
        catalog.profiles[index].routeModel = routeData
      }
    } else {
      let id = UUID().uuidString.lowercased()
      catalog.profiles.append(RoutingRecord(
        id: id,
        name: name,
        providerSubscriptionID: subscriptionID,
        providerProfile: profileData,
        providerRouteModel: routeData,
        workingProfile: profileData,
        routeModel: routeData,
        edited: false,
        enabled: true,
        updatedAt: Date(),
        geofileStatus: "pending",
        geoipURL: profile["Geoipurl"] as? String,
        geositeURL: profile["Geositeurl"] as? String,
        lastGeoRefresh: nil,
        assetRevision: nil
      ))
      if catalog.assignments[subscriptionID] == nil, !isManual(subscriptionID: subscriptionID) {
        catalog.assignments[subscriptionID] = id
      }
    }
    for index in catalog.profiles.indices where catalog.profiles[index].providerSubscriptionID == subscriptionID {
      try rebuildManaged(index: index)
      if let previous, !previous.edited {
        invalidateReduction(index: index, profile: profile, previous: previous)
      }
    }
    if persist { try save() }
  }

  func update(id: String, content: String) throws -> [String: Any] {
    guard let index = catalog.profiles.firstIndex(where: { $0.id == id }) else {
      throw RoutingStoreError.notFound
    }
    let decoded = try RoutingDomainDecoder.decode(content)
    guard decoded.action == "add", let profile = decoded.profile,
          let routeModel = decoded.routeModel else {
      throw RoutingStoreError.invalidImport
    }
    let name = (profile["Name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
      ?? "Routing Profile"
    let previous = catalog.profiles[index]
    catalog.profiles[index].name = name
    catalog.profiles[index].workingProfile = try JSONSerialization.data(
      withJSONObject: profile,
      options: [.sortedKeys]
    )
    catalog.profiles[index].routeModel = try JSONSerialization.data(
      withJSONObject: routeModel,
      options: [.sortedKeys]
    )
    catalog.profiles[index].edited = true
    catalog.profiles[index].updatedAt = Date()
    try rebuildManaged(index: index)
    invalidateReduction(index: index, profile: profile, previous: previous)
    try save()
    return snapshot()
  }

  private func invalidateReduction(index: Int, profile: [String: Any], previous: RoutingRecord) {
    let oldProfile = (try? JSONSerialization.jsonObject(with: previous.workingProfile)) as? [String: Any] ?? [:]
    func reduced(_ value: [String: Any]) -> Bool {
      value["UseChunkFiles"] as? Bool == true || value["UseChunkFiles"] as? String == "true"
    }
    guard catalog.profiles[index].routeModel != previous.routeModel ||
      profile["Geoipurl"] as? String != previous.geoipURL ||
      profile["Geositeurl"] as? String != previous.geositeURL ||
      reduced(profile) != reduced(oldProfile) else { return }
    catalog.profiles[index].publicationGeneration = UUID()
    catalog.profiles[index].geoipURL = profile["Geoipurl"] as? String
    catalog.profiles[index].geositeURL = profile["Geositeurl"] as? String
    catalog.profiles[index].geofileStatus = "pending"
    // The active plan keeps its usable revision until preparation succeeds.
    catalog.profiles[index].reductionStatus = "Awaiting routing data update."
  }

  func duplicate(id: String) throws -> [String: Any] {
    guard let source = catalog.profiles.first(where: { $0.id == id }) else {
      throw RoutingStoreError.notFound
    }
    var copy = source
    copy.id = UUID().uuidString.lowercased()
    copy.name = "\(source.name) Copy"
    copy.providerSubscriptionID = nil
    copy.providerProfile = nil
    copy.providerRouteModel = nil
    copy.edited = true
    copy.updatedAt = Date()
    let previous = catalog
    catalog.profiles.append(copy)
    do { try save() } catch { catalog = previous; throw error }
    return snapshot()
  }

  func delete(id: String) throws -> [String: Any] {
    guard let index = catalog.profiles.firstIndex(where: { $0.id == id }) else {
      throw RoutingStoreError.notFound
    }
    catalog.profiles.remove(at: index)
    catalog.assignments = catalog.assignments.filter { $0.value != id }
    try save()
    return snapshot()
  }

  func removeSubscription(id: String) throws {
    let previous = catalog
    let removed = Set(catalog.profiles.filter { $0.providerSubscriptionID == id }.map(\.id))
    catalog.profiles.removeAll { removed.contains($0.id) }
    catalog.assignments = catalog.assignments.filter { $0.key != id && !removed.contains($0.value) }
    catalog.manualAssignments?.removeAll { $0 == id }
    do { try save() } catch { catalog = previous; throw error }
  }

  func reset(id: String) throws -> [String: Any] {
    guard let index = catalog.profiles.firstIndex(where: { $0.id == id }),
          let providerProfile = catalog.profiles[index].providerProfile,
          let providerRouteModel = catalog.profiles[index].providerRouteModel else {
      throw RoutingStoreError.notFound
    }
    let previous = catalog.profiles[index]
    catalog.profiles[index].workingProfile = providerProfile
    catalog.profiles[index].routeModel = providerRouteModel
    guard let profile = try JSONSerialization.jsonObject(with: providerProfile) as? [String: Any]
    else { throw RoutingStoreError.invalidCatalog }
    catalog.profiles[index].edited = false
    catalog.profiles[index].updatedAt = Date()
    try rebuildManaged(index: index)
    invalidateReduction(index: index, profile: profile, previous: previous)
    try save()
    return snapshot()
  }

  func setEnabled(id: String, enabled: Bool) throws -> [String: Any] {
    guard let index = catalog.profiles.firstIndex(where: { $0.id == id }) else {
      throw RoutingStoreError.notFound
    }
    catalog.profiles[index].enabled = enabled
    catalog.profiles[index].publicationGeneration = UUID()
    try save()
    return snapshot()
  }

  func assign(subscriptionID: String, profileID: String?) throws -> [String: Any] {
    if let profileID {
      guard catalog.profiles.contains(where: { $0.id == profileID }) else {
        throw RoutingStoreError.notFound
      }
    }
    assignByUser(subscriptionID, profileID)
    try save()
    return snapshot()
  }

  func isManual(subscriptionID: String) -> Bool { catalog.manualAssignments?.contains(subscriptionID) == true }

  private func assignByUser(_ subscriptionID: String, _ profileID: String?) {
    catalog.assignments[subscriptionID] = profileID
    if !isManual(subscriptionID: subscriptionID) { catalog.manualAssignments = (catalog.manualAssignments ?? []) + [subscriptionID] }
  }

  func runtimeRevision(subscriptionID: String?) throws -> RuntimeRoutingRevision? {
    guard let subscriptionID,
          let profileID = catalog.assignments[subscriptionID],
          let profile = catalog.profiles.first(where: { $0.id == profileID }),
          profile.enabled else { return nil }
    guard profile.routeModel.count <= Self.maxRouteModelBytes else { throw RoutingStoreError.routeModelTooLarge }
    let digest = SHA256.hash(data: profile.routeModel).map { String(format: "%02x", $0) }.joined()
    let name = "route-model-\(digest).json"
    let url = revisionsURL.appendingPathComponent(name, isDirectory: false)
    if !FileManager.default.fileExists(atPath: url.path) {
      try profile.routeModel.write(to: url, options: [.atomic])
    }
    return RuntimeRoutingRevision(
      name: name,
      digest: digest,
      assetRevision: profile.assetRevision
    )
  }

  // The caller must first stop the provider and retain its persisted plan.
  func reclaimUnusedFiles(routeNames: Set<String>, assetRevisions: Set<String>) throws {
    let keptRoutes = routeNames.union(catalog.profiles.map {
      "route-model-" + SHA256.hash(data: $0.routeModel).map { String(format: "%02x", $0) }.joined() + ".json"
    })
    let keptAssets = assetRevisions
      .union(catalog.profiles.flatMap { [$0.assetRevision, $0.originalAssetRevision].compactMap { $0 } })
      .union(pendingAssetRevisions.values.flatMap { $0 })
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
    for (directory, kept, assets) in [(revisionsURL, keptRoutes, false), (assetsURL, keptAssets, true)] {
      for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) {
        let name = url.lastPathComponent
        guard !kept.contains(name) else { continue }
        let values = try url.resourceValues(forKeys: keys)
        guard values.isSymbolicLink != true else { continue }
        if assets {
          guard values.isDirectory == true, UUID(uuidString: name)?.uuidString.lowercased() == name else { continue }
        } else {
          guard values.isRegularFile == true, name.hasPrefix("route-model-"), name.hasSuffix(".json") else { continue }
          let digest = name.dropFirst("route-model-".count).dropLast(".json".count)
          guard digest.count == 64, digest.allSatisfy(\.isHexDigit) else { continue }
        }
        try FileManager.default.removeItem(at: url)
      }
    }
  }

  func runtimeProbeConfiguration(subscriptionID: String) throws
    -> (routes: [String: Any]?, assetDirectory: String?) {
    guard let revision = try runtimeRevision(subscriptionID: subscriptionID) else {
      return (nil, nil)
    }
    let data = try Data(contentsOf: revisionsURL.appendingPathComponent(revision.name))
    guard data.count <= 8 * 1024 * 1024,
          SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == revision.digest,
          let routes = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw RoutingStoreError.invalidCatalog
    }
    var assetDirectory: String?
    if let revision = revision.assetRevision {
      guard revision.count <= 64,
            revision.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0)) })
      else { throw RoutingStoreError.invalidCatalog }
      let url = assetsURL.appendingPathComponent(revision, isDirectory: true)
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
            isDirectory.boolValue else { throw RoutingStoreError.invalidCatalog }
      assetDirectory = url.path
    }
    return (routes, assetDirectory)
  }

  func refreshGeofiles(id: String, force: Bool = false, file: String? = nil) async throws -> [String: Any] {
    try await refreshGeofiles(id: id, force: force, file: file, publish: publishManaged)
  }

  // Called inside the existing catalog transaction, before changing the active plan.
  func prepareAssets(subscriptionID: String?) async throws {
    guard let subscriptionID, let id = catalog.assignments[subscriptionID],
          let record = catalog.profiles.first(where: { $0.id == id }), record.enabled else { return }
    // Servers whose own rules name other codes need the geofiles reduced again. Their configs
    // are read only after one changed, so connecting reads no secrets of servers it does not use.
    var reapply = false
    let refs = serverRefs(assignedSubscriptions(id))
    if record.geofileStatus == "ready", record.originalAssetRevision != nil, !refreshingGeofiles.contains(id),
       refs != (record.serverGeodataRefs ?? []) {
      reapply = try serverSelectors(id) != (record.serverGeodata ?? [])
      if !reapply, let index = catalog.profiles.firstIndex(where: { $0.id == id }) {
        catalog.profiles[index].serverGeodataRefs = refs
        try save()
      }
    }
    guard record.geofileStatus == "pending" || reapply else { return }
    guard !refreshingGeofiles.contains(id) else { throw RoutingStoreError.invalidImport }
    _ = try await refreshGeofiles(id: id, force: false, file: nil, reapply: reapply) { candidate in
      try self.publish(candidate)
    }
  }

  private func serverSelectors(_ id: String) throws -> [String] {
    func selectors(_ value: Any) -> Set<String> {
      if let values = value as? [String: Any] { return values.values.reduce(into: []) { $0.formUnion(selectors($1)) } }
      if let values = value as? [Any] { return values.reduce(into: []) { $0.formUnion(selectors($1)) } }
      // Xray reads a leading ! on an IP rule like one before the code.
      guard let value = value as? String, ["geoip:", "geosite:", "ext:", "ext-ip:", "ext-site:", "ext-domain:"].contains(where: String(value.drop(while: { $0 == "!" })).hasPrefix) else { return [] }
      return [value]
    }
    return try serverConfigs(assignedSubscriptions(id)).reduce(into: Set<String>()) { $0.formUnion(selectors($1)) }.sorted()
  }

  private func assignedSubscriptions(_ id: String) -> [String] {
    catalog.assignments.filter { $0.value == id }.map(\.key).sorted()
  }

  private func refreshGeofiles(id: String, force: Bool, file: String?, reapply: Bool = false,
    publish: ((ManagedCandidate) async throws -> Void)?) async throws -> [String: Any] {
    guard let index = catalog.profiles.firstIndex(where: { $0.id == id }) else {
      throw RoutingStoreError.notFound
    }
    guard file == nil || file == "geoip" || file == "geosite" else {
      throw RoutingStoreError.invalidImport
    }
    guard refreshingGeofiles.insert(id).inserted else { return snapshot() }
    defer { refreshingGeofiles.remove(id) }
    if catalog.profiles[index].publicationGeneration == nil { catalog.profiles[index].publicationGeneration = UUID() }
    let previous = catalog.profiles[index]
    pendingAssetRevisions[id] = Set([previous.assetRevision, previous.originalAssetRevision].compactMap { $0 })
    defer { pendingAssetRevisions.removeValue(forKey: id) }
    let fresh = previous.lastGeoRefresh.map { now().timeIntervalSince($0) < 7 * 24 * 60 * 60 } ?? false
    // A failed refresh runs again when it is retried, also within the week of an earlier success.
    if !force, !reapply, fresh, previous.geofileStatus == "ready" {
      return snapshot()
    }
    guard let publish else { throw RoutingStoreError.invalidImport }
    let sources = [
      (catalog.profiles[index].geoipURL, "geoip.dat", "geoip", "ip"),
      (catalog.profiles[index].geositeURL, "geosite.dat", "geosite", "domain"),
    ].compactMap { source, filename, name, kind in
      source.flatMap { $0.isEmpty ? nil : ($0, filename, name, kind) }
    }
    if sources.isEmpty {
      var updated = previous
      updated.geofileStatus = "ready"
      updated.lastGeoRefresh = now()
      updated.assetRevision = nil
      updated.originalAssetRevision = nil
      updated.reductionStatus = "disabled"
      updated.skippedGeodata = nil
      try await publish(ManagedCandidate(record: updated, generation: previous.publicationGeneration))
      return snapshot()
    }
    let staging = assetsURL.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
      var updated = previous
      for (source, filename, name, kind) in sources {
        let oldFile = (previous.originalAssetRevision ?? previous.assetRevision).map {
          assetsURL.appendingPathComponent($0).appendingPathComponent(filename)
        }
        let downloadedSource = name == "geoip" ? previous.geoipDownloadedSource : previous.geositeDownloadedSource
        if ((!force && fresh) || (file != nil && file != name)), source == downloadedSource, let oldFile,
           FileManager.default.fileExists(atPath: oldFile.path) {
          try FileManager.default.copyItem(at: oldFile, to: staging.appendingPathComponent(filename))
        } else {
          guard let url = URL(string: source) else { throw RoutingStoreError.invalidImport }
          // The stored file's validators hold only for the link it came from.
          let current = source == downloadedSource ? oldFile.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } : nil
          let stored = current == nil ? nil : (name == "geoip" ? previous.geoipValidators : previous.geositeValidators)
          let download = try await fetchGeofile(url, stored, staging.appendingPathComponent(filename))
          try Task.checkCancellation()
          guard catalog.profiles.first(where: { $0.id == id })?.publicationGeneration == previous.publicationGeneration else {
            throw CancellationError()
          }
          if download.downloaded {
            guard FileManager.default.fileExists(atPath: staging.appendingPathComponent(filename).path) else { throw RoutingStoreError.invalidImport }
          } else if let current, stored != nil {
            try FileManager.default.copyItem(at: current, to: staging.appendingPathComponent(filename))
          } else {
            throw RoutingStoreError.invalidImport
          }
          if name == "geoip" {
            updated.geoipUpdatedAt = now(); updated.geoipDownloadedSource = source; updated.geoipValidators = download.validators
          } else {
            updated.geositeUpdatedAt = now(); updated.geositeDownloadedSource = source; updated.geositeValidators = download.validators
          }
        }
        try validateGeofile(directory: staging, name: name, kind: kind)
      }
      guard let currentIndex = catalog.profiles.firstIndex(where: { $0.id == id }),
            catalog.profiles[currentIndex].publicationGeneration == previous.publicationGeneration else {
        throw RoutingStoreError.invalidImport
      }
      let beforePublish = catalog.profiles[currentIndex]
      let downloadMetadata = updated
      updated = beforePublish
      updated.geoipUpdatedAt = downloadMetadata.geoipUpdatedAt
      updated.geositeUpdatedAt = downloadMetadata.geositeUpdatedAt
      updated.geoipDownloadedSource = downloadMetadata.geoipDownloadedSource
      updated.geositeDownloadedSource = downloadMetadata.geositeDownloadedSource
      updated.geoipValidators = downloadMetadata.geoipValidators
      updated.geositeValidators = downloadMetadata.geositeValidators
      let revision: String
      if let retained = previous.originalAssetRevision ?? previous.assetRevision,
         sameGeofiles(staging, assetsURL.appendingPathComponent(retained)) {
        revision = retained
        try FileManager.default.removeItem(at: staging)
      } else {
        revision = UUID().uuidString.lowercased()
        pendingAssetRevisions[id, default: []].insert(revision)
        try FileManager.default.moveItem(at: staging, to: assetsURL.appendingPathComponent(revision))
      }
      let destination = assetsURL.appendingPathComponent(revision, isDirectory: true)
      updated.originalAssetRevision = revision
      updated.assetRevision = revision
      updated.reductionStatus = "disabled"
      updated.skippedGeodata = nil
      let profile = try JSONSerialization.jsonObject(with: previous.workingProfile) as? [String: Any]
      let chunked = profile?["UseChunkFiles"] as? Bool == true || profile?["UseChunkFiles"] as? String == "true"
      updated.serverGeodataRefs = serverRefs(assignedSubscriptions(id))
      let servers = try serverSelectors(id)
      updated.serverGeodata = servers
      do {
        // Complete files need a derived revision only to hold empty records for skipped codes.
        if let derived = try reduceGeofiles(original: destination, routes: previous.routeModel, servers: servers, reduce: chunked) {
          if let retained = previous.assetRevision,
             sameGeofiles(assetsURL.appendingPathComponent(derived.revision), assetsURL.appendingPathComponent(retained)) {
            try FileManager.default.removeItem(at: assetsURL.appendingPathComponent(derived.revision))
            updated.assetRevision = retained
          } else {
            updated.assetRevision = derived.revision
            pendingAssetRevisions[id, default: []].insert(derived.revision)
          }
          updated.skippedGeodata = derived.skipped
        }
        if chunked { updated.reductionStatus = "reduced" }
      } catch RoutingStoreError.missingGeodata(let missing) {
        throw RoutingStoreError.missingGeodata(missing)
      } catch RoutingStoreError.geofileTooLarge {
        throw RoutingStoreError.geofileTooLarge
      } catch {
        if chunked { updated.reductionStatus = "Using complete files: reduction could not preserve every reference." }
      }
      // Complete files serve when reduction is off or fails.
      let loaded = assetsURL.appendingPathComponent(updated.assetRevision ?? revision)
      guard ["geoip.dat", "geosite.dat"].allSatisfy({
        ((try? loaded.appendingPathComponent($0).resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) <= Self.maxGeofileBytes
      }) else { throw RoutingStoreError.geofileTooLarge }
      updated.lastGeoRefresh = now()
      updated.geofileStatus = "ready"
      updated.geofileError = nil
      updated.publicationGeneration = UUID()
      try await publish(ManagedCandidate(record: updated, generation: previous.publicationGeneration))
      geofileRetryAfter.removeValue(forKey: id)
      return snapshot()
    } catch {
      geofileRetryAfter[id] = now().addingTimeInterval(15 * 60)
      try? FileManager.default.removeItem(at: staging)
      if let currentIndex = catalog.profiles.firstIndex(where: { $0.id == id }),
         catalog.profiles[currentIndex].publicationGeneration == previous.publicationGeneration {
        catalog.profiles[currentIndex].geofileStatus = "failed"
        catalog.profiles[currentIndex].geofileError = "Refresh failed; the previous usable revision is retained."
        if case RoutingStoreError.missingGeodata(let missing) = error {
          catalog.profiles[currentIndex].geofileError = "Proxy rules and servers need codes the geofiles lack: " +
            "\(missing.joined(separator: ", ")). Fix the profile or its geofile links."
        }
        if case RoutingStoreError.geofileTooLarge = error { catalog.profiles[currentIndex].geofileError = Self.geofileTooLargeMessage }
        try? save()
      }
      throw error
    }
  }

  private func sameGeofiles(_ first: URL, _ second: URL) -> Bool {
    ["geoip.dat", "geosite.dat"].allSatisfy { name in
      let a = first.appendingPathComponent(name).path, b = second.appendingPathComponent(name).path
      let exists = FileManager.default.fileExists(atPath: a)
      return exists == FileManager.default.fileExists(atPath: b) &&
        (!exists || FileManager.default.contentsEqual(atPath: a, andPath: b))
    }
  }

  // A failed refresh is due again after its retry delay, like a pending one: one failure (offline at the
  // weekly refresh, a server error) used to end automatic refreshes for the profile.
  func dueGeofiles() -> [String] {
    catalog.profiles.filter { record in
      !refreshingGeofiles.contains(record.id) && record.enabled &&
        (geofileRetryAfter[record.id].map { $0 <= now() } ?? true) &&
        (record.geofileStatus == "pending" || record.geofileStatus == "failed" || (record.geofileStatus == "ready" &&
          record.lastGeoRefresh.map { $0.addingTimeInterval(7 * 86400) <= now() } == true))
    }.map(\.id)
  }

  func nextGeofileDate() -> Date? {
    catalog.profiles.filter { $0.enabled && !refreshingGeofiles.contains($0.id) }.compactMap { record in
      let due = record.geofileStatus == "pending" || record.geofileStatus == "failed" ? now() :
        (record.geofileStatus == "ready" ? record.lastGeoRefresh?.addingTimeInterval(7 * 86400) : nil)
      return due.map { max($0, geofileRetryAfter[record.id] ?? $0) }
    }.min()
  }

  private func managedSources(_ profile: Data) throws -> [ManagedSourceConfiguration] {
    guard let object = try JSONSerialization.jsonObject(with: profile) as? [String: Any] else {
      throw RoutingStoreError.invalidImport
    }
    return try JSONDecoder().decode([ManagedSourceConfiguration].self,
      from: JSONSerialization.data(withJSONObject: object["ManagedSources"] ?? []))
  }

  private func rebuildManaged(index: Int) throws {
    let sources = try managedSources(catalog.profiles[index].workingProfile)
    let previous = catalog.profiles[index].managedSources
    catalog.profiles[index].managedSources = sources.map { source in
      if let unchanged = previous?.first(where: { $0.source == source }) { return unchanged }
      // A URL edit keeps the last downloaded policy until its replacement validates.
      let retained = previous?.first(where: { $0.source.id == source.id &&
        $0.source.destination == source.destination && $0.source.matchMode == source.matchMode })
      return ManagedSourceState(source: source, domains: retained?.domains ?? [], revision: retained?.revision,
        lastSuccessfulFetch: retained?.lastSuccessfulFetch,
        schedule: .initial(last: nil, now: now(), interval: 86400))
    }
    catalog.profiles[index].routeModel = try effectiveManagedRoute(catalog.profiles[index])
  }

  private func effectiveManagedRoute(_ record: RoutingRecord) throws -> Data {
    let profile = try JSONSerialization.jsonObject(with: record.workingProfile)
    let lists = Dictionary(uniqueKeysWithValues: (record.managedSources ?? []).map { ($0.source.id, $0.domains) })
    let response = try RoutingDomainDecoder.request("mergeManagedRouting", payload: ["profile": profile, "lists": lists])
    guard let route = response["routeModel"] as? [String: Any] else { throw RoutingStoreError.invalidImport }
    let data = try JSONSerialization.data(withJSONObject: route, options: [.sortedKeys])
    guard data.count <= Self.maxRouteModelBytes else { throw RoutingStoreError.routeModelTooLarge }
    return data
  }

  func dueManagedSources() -> [(profileID: String, sourceID: String)] {
    catalog.profiles.filter { $0.enabled && managedTasks[$0.id] == nil }.flatMap { record in
      (record.managedSources ?? []).filter { $0.schedule.due.map { $0 <= now() } == true }
        .map { (record.id, $0.source.id) }
    }
  }

  func nextManagedDate() -> Date? {
    catalog.profiles.filter { $0.enabled && managedTasks[$0.id] == nil }
      .flatMap { $0.managedSources ?? [] }.compactMap { $0.schedule.due }.min()
  }

  func cancelManagedRefreshes() {
    managedTasks.values.forEach { $0.cancel() }
    // Advance generations so even a dependency ignoring cancellation cannot publish.
    for index in catalog.profiles.indices { catalog.profiles[index].publicationGeneration = UUID() }
  }

  func refreshManaged(id: String, sourceID: String) async throws {
    if let task = managedTasks[id] { return try await task.value }
    let task = Task { @MainActor in try await self.prepareManaged(id: id, sourceID: sourceID) }
    managedTasks[id] = task
    defer { managedTasks.removeValue(forKey: id) }
    try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
  }

  private func prepareManaged(id: String, sourceID: String) async throws {
    guard let index = catalog.profiles.firstIndex(where: { $0.id == id }),
          let sourceIndex = catalog.profiles[index].managedSources?.firstIndex(where: { $0.source.id == sourceID }) else {
      throw RoutingStoreError.notFound
    }
    if catalog.profiles[index].publicationGeneration == nil { catalog.profiles[index].publicationGeneration = UUID() }
    var candidate = catalog.profiles[index]
    let generation = candidate.publicationGeneration
    let previousRevision = candidate.managedRevision
    let source = candidate.managedSources![sourceIndex].source
    do {
      guard let url = URL(string: source.url) else { throw RoutingStoreError.invalidImport }
      let fetched = try await RoutingResourceFetcher.fetch(url, maxBytes: 4 * 1024 * 1024)
      try Task.checkCancellation()
      guard catalog.profiles.first(where: { $0.id == id })?.publicationGeneration == generation else { throw CancellationError() }
      guard let text = String(data: fetched, encoding: .utf8),
            let domains = try RoutingDomainDecoder.request("parseManagedDomains",
              payload: ["text": text, "matchMode": source.matchMode])["domains"] as? [String] else {
        throw RoutingStoreError.invalidImport
      }
      candidate.managedSources![sourceIndex].domains = domains
      candidate.managedSources![sourceIndex].revision = UUID().uuidString.lowercased()
      candidate.managedSources![sourceIndex].lastSuccessfulFetch = now()
      candidate.managedSources![sourceIndex].schedule.succeeded(now: now(), interval: 86400, jitter: jitter())
      candidate.routeModel = try effectiveManagedRoute(candidate)
      candidate.managedRevision = UUID().uuidString.lowercased()
      guard let publishManaged else { throw RoutingStoreError.invalidImport }
      try await publishManaged(ManagedCandidate(record: candidate, generation: generation))
    } catch is CancellationError { throw CancellationError() }
    catch {
      try Task.checkCancellation()
      if let index = catalog.profiles.firstIndex(where: { $0.id == id &&
          $0.workingProfile == candidate.workingProfile && $0.managedRevision == previousRevision }),
         let sourceIndex = catalog.profiles[index].managedSources?.firstIndex(where: { $0.source == source }) {
        let prior = catalog
        let authorization = error is SubscriptionApprovalRequirement
        catalog.profiles[index].managedSources![sourceIndex].schedule.failed(now: now(), interval: 86400,
          category: authorization ? "authorization" : "refresh", authorization: authorization)
        do { try save() } catch { catalog = prior; throw error }
      }
      throw error
    }
  }

  func publish(_ candidate: ManagedCandidate) throws {
    try requireCandidate(candidate)
    guard let index = catalog.profiles.firstIndex(where: { $0.id == candidate.record.id }) else {
      throw CancellationError()
    }
    let prior = catalog
    catalog.profiles[index] = candidate.record
    catalog.profiles[index].publicationGeneration = UUID()
    do { try save() } catch { catalog = prior; throw error }
  }

  func requireCandidate(_ candidate: ManagedCandidate) throws {
    try Task.checkCancellation()
    guard catalog.profiles.contains(where: {
      $0.id == candidate.record.id && $0.publicationGeneration == candidate.generation
    }) else { throw CancellationError() }
  }

  // Returns nil when complete files serve unchanged. Direct and Block rules and domestic DNS
  // domains may name codes the geofiles lack: those get empty records, which Xray loads as
  // matching nothing. Every other reference needs its record.
  private func reduceGeofiles(original: URL, routes: Data, servers: [String], reduce: Bool) throws -> (revision: String, skipped: [String])? {
    var references: [String: Set<String>] = ["geoip": [], "geosite": []]
    var optional: [String: Set<String>] = ["geoip": [], "geosite": []]
    func collect(_ value: Any, skippable: Bool = false) throws {
      if let values = value as? [String: Any] { for value in values.values { try collect(value, skippable: skippable) } }
      else if let values = value as? [Any] { for value in values { try collect(value, skippable: skippable) } }
      else if let value = value as? String {
        // Xray reads a leading ! on an IP rule like one before the code.
        let bare = String(value.drop(while: { $0 == "!" }))
        // Xray reads ext-site: and ext-domain: from the named file as it does ext:.
        guard !["ext:", "ext-ip:", "ext-site:", "ext-domain:"].contains(where: bare.hasPrefix) else {
          throw RoutingStoreError.invalidImport
        }
        for kind in ["geoip", "geosite"] where bare.hasPrefix(kind + ":") {
          let selector = bare.dropFirst(kind.count + 1)
          let code = selector.split(separator: "@", maxSplits: 1).first
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "!" )).uppercased() } ?? ""
          guard !code.isEmpty else { throw RoutingStoreError.invalidImport }
          // An empty record would make a negated selector match everything.
          if skippable && bare == value && !selector.hasPrefix("!") { optional[kind, default: []].insert(code) }
          else { references[kind, default: []].insert(code) }
        }
      }
    }
    var model = try JSONSerialization.jsonObject(with: routes) as? [String: Any] ?? [:]
    for rule in model.removeValue(forKey: "rules") as? [Any] ?? [] {
      try collect(rule, skippable: ["direct", "block"].contains((rule as? [String: Any])?["action"] as? String ?? ""))
    }
    if var dns = model["dnsPolicy"] as? [String: Any] {
      try collect(dns.removeValue(forKey: "domesticDomains") ?? [], skippable: true)
      model["dnsPolicy"] = dns
    }
    try collect(model)
    try collect(servers)
    var outputs: [(name: String, kind: String, data: Data)] = []
    var skipped: [String] = []
    for (name, kind) in [("geoip", "ip"), ("geosite", "domain")] {
      let file = original.appendingPathComponent(name + ".dat")
      let wanted = references[name, default: []].union(optional[name, default: []])
      guard FileManager.default.fileExists(atPath: file.path) else {
        guard wanted.isEmpty else { throw RoutingStoreError.invalidImport }
        continue
      }
      // Mapped, the original's pages stay file-backed and evictable instead of filling the heap.
      let retained = try Self.retainGeodataRecords(Data(contentsOf: file, options: .alwaysMapped), codes: wanted, keepAll: !reduce)
      guard retained.data.count <= Self.maxGeofileBytes else { throw RoutingStoreError.geofileTooLarge }
      let missing = retained.missing.intersection(references[name, default: []])
      guard missing.isEmpty else {
        throw RoutingStoreError.missingGeodata(missing.sorted().map { "\(name):\($0.lowercased())" })
      }
      var data = retained.data
      for code in retained.missing.sorted() {
        // Field 1 holding a record whose only field is the code; Xray needs one-byte lengths.
        let bytes = Data(code.utf8)
        guard bytes.count < 126 else { throw RoutingStoreError.invalidImport }
        data.append(contentsOf: [10, UInt8(bytes.count + 2), 10, UInt8(bytes.count)])
        data.append(bytes)
        skipped.append("\(name):\(code.lowercased())")
      }
      outputs.append((name: name, kind: kind, data: data))
    }
    guard reduce || !skipped.isEmpty else { return nil }
    let revision = UUID().uuidString.lowercased()
    let derived = assetsURL.appendingPathComponent(revision, isDirectory: true)
    try FileManager.default.createDirectory(at: derived, withIntermediateDirectories: true)
    do {
      for (name, kind, data) in outputs {
        try data.write(to: derived.appendingPathComponent(name + ".dat"), options: [.atomic])
        try validateGeofile(directory: derived, name: name, kind: kind)
      }
      return (revision, skipped)
    } catch {
      try? FileManager.default.removeItem(at: derived)
      throw error
    }
  }

  // Keep complete protobuf records for `codes`, or every record with `keepAll`, including
  // attributes and unknown nested fields. Also returns the requested codes the data lacks.
  static func retainGeodataRecords(_ data: Data, codes: Set<String>, keepAll: Bool = false) throws -> (data: Data, missing: Set<String>) {
    guard data.count <= maxOriginalGeofileBytes else { throw RoutingStoreError.invalidImport }
    var offset = 0
    func varint(end: Int) throws -> Int {
      var value: UInt64 = 0
      for shift in stride(from: 0, through: 63, by: 7) {
        guard offset < end else { throw RoutingStoreError.invalidImport }
        let byte = data[offset]; offset += 1
        guard shift != 63 || byte <= 1 else { throw RoutingStoreError.invalidImport }
        value |= UInt64(byte & 127) << shift
        if byte & 128 == 0 {
          guard value <= UInt64(Int.max) else { throw RoutingStoreError.invalidImport }
          return Int(value)
        }
      }
      throw RoutingStoreError.invalidImport
    }
    var result = Data()
    var found = Set<String>()
    while offset < data.count {
      let start = offset
      guard try varint(end: data.count) == 10 else { throw RoutingStoreError.invalidImport }
      let length = try varint(end: data.count)
      guard length <= data.count - offset else { throw RoutingStoreError.invalidImport }
      let end = offset + length
      guard try varint(end: end) == 10 else { throw RoutingStoreError.invalidImport }
      let codeLength = try varint(end: end)
      guard codeLength <= end - offset,
            let code = String(data: data[offset..<(offset + codeLength)], encoding: .utf8) else {
        throw RoutingStoreError.invalidImport
      }
      if codes.contains(code.uppercased()) {
        if !keepAll { result.append(data[start..<end]) }
        found.insert(code.uppercased())
      }
      offset = end
    }
    return (keepAll ? data : result, codes.subtracting(found))
  }

  private func profileMap(_ profile: RoutingRecord) -> [String: Any] {
    let json = String(data: profile.workingProfile, encoding: .utf8) ?? "{}"
    return [
      "id": profile.id,
      "name": profile.name,
      "source": profile.providerSubscriptionID == nil ? "manual" : "subscription",
      "providerSubscriptionId": profile.providerSubscriptionID ?? NSNull(),
      "edited": profile.edited,
      "enabled": profile.enabled,
      "updatedAt": ISO8601DateFormatter().string(from: profile.updatedAt),
      "geofileStatus": profile.geofileStatus,
      "geofileError": profile.geofileError ?? NSNull(),
      "reductionStatus": profile.reductionStatus ?? "disabled",
      "skippedGeodata": profile.skippedGeodata ?? [],
      "assetRevision": profile.assetRevision ?? NSNull(),
      "managedStatus": (profile.managedSources ?? []).map { state in
        ["id": state.source.id, "lastSuccessfulFetch": state.lastSuccessfulFetch?.timeIntervalSince1970 ?? NSNull(),
         "error": state.schedule.errorCategory ?? NSNull()] as [String: Any]
      },
      "geofiles": [("geoip", profile.geoipURL, profile.geoipUpdatedAt),
                   ("geosite", profile.geositeURL, profile.geositeUpdatedAt)].map { name, source, updated in
        func bytes(_ revision: String?) -> Int {
          guard let revision else { return 0 }
          let file = assetsURL.appendingPathComponent(revision).appendingPathComponent(name + ".dat")
          return (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        var url = source.flatMap { URLComponents(string: $0) }
        url?.user = nil; url?.password = nil; url?.query = nil; url?.fragment = nil
        return ["name": name, "source": url?.string ?? "Not configured",
                "bytes": bytes(profile.assetRevision),
                "originalBytes": bytes(profile.originalAssetRevision ?? profile.assetRevision),
                "updatedAt": updated.map { ISO8601DateFormatter().string(from: $0) } ?? "Never"] as [String: Any]
      },
      "json": json,
    ]
  }

  private func save() throws {
    if staging { return }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(catalog).write(to: catalogURL, options: [.atomic])
  }

  private func validateGeofile(directory: URL, name: String, kind: String) throws {
    let request: [String: Any] = [
      "apiVersion": 1,
      "method": "countGeoData",
      "payload": ["datDir": directory.path, "name": name, "geoType": kind],
    ]
    let data = try JSONSerialization.data(withJSONObject: request)
    guard let text = String(data: data, encoding: .utf8),
          let pointer = strdup(text) else { throw RoutingStoreError.invalidImport }
    defer { free(pointer) }
    guard let responsePointer = CGoInvoke(pointer) else { throw RoutingStoreError.invalidImport }
    defer { CGoFree(responsePointer) }
    let response = String(cString: responsePointer)
    guard let responseData = response.data(using: .utf8),
          let envelope = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
          envelope["success"] as? Bool == true else {
      throw RoutingStoreError.invalidImport
    }
  }
}
enum RoutingDomainDecoder {
  // Do not classify a mixed feed by its first line. The strict decoder accepts
  // complete routing JSON, Base64, and links without mutating the saved catalog.
  static func isRoutingInput(_ value: String) -> Bool {
    (try? decode(value)) != nil
  }

  static func isRoutingLink(_ value: String) -> Bool {
    ["happ://routing/", "incy://routing/", "elarni://routing/", "://routing/"].contains(where: value.hasPrefix)
  }
  struct Result {
    let action: String
    let activate: Bool
    let profile: [String: Any]?
    let routeModel: [String: Any]?
  }

  static func decode(_ content: String) throws -> Result {
    let response = try request("decodeRouting", payload: ["content": content])
    guard let decoded = response["import"] as? [String: Any],
          let action = decoded["action"] as? String else { throw RoutingStoreError.invalidImport }
    return Result(action: action, activate: decoded["activate"] as? Bool ?? false,
      profile: decoded["profile"] as? [String: Any], routeModel: decoded["routeModel"] as? [String: Any])
  }

  static func request(_ operation: String, payload: [String: Any]) throws -> [String: Any] {
    guard elarni_abi_version() == ELARNI_ABI_VERSION else {
      throw RoutingStoreError.invalidImport
    }
    let request = try JSONSerialization.data(withJSONObject: [
      "schemaVersion": 1,
      "operation": operation,
      "payload": payload,
    ])
    guard let handle = elarni_handle_new() else { throw RoutingStoreError.invalidImport }
    defer { elarni_handle_free(handle) }
    var output = ElarniBuffer(data: nil, len: 0, capacity: 0)
    let status = request.withUnsafeBytes { bytes in
      elarni_request(
        handle,
        bytes.bindMemory(to: UInt8.self).baseAddress,
        request.count,
        &output
      )
    }
    defer { elarni_buffer_free(output) }
    guard status == ELARNI_STATUS_OK, let bytes = output.data else {
      throw RoutingStoreError.invalidImport
    }
    let data = Data(bytes: bytes, count: output.len)
    guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw RoutingStoreError.invalidImport
    }
    return response
  }

  static func canonicalImport(_ content: String) -> Data? {
    guard let decoded = try? decode(content) else { return nil }
    if decoded.action == "off" { return Data("off".utf8) }
    guard let profile = decoded.profile else { return nil }
    return try? JSONSerialization.data(withJSONObject: profile, options: [.sortedKeys])
  }
}
private struct RoutingCatalog: Codable {
  let schemaVersion: Int
  var profiles: [RoutingRecord]
  var assignments: [String: String]
  var publishedRevision: String?
  /// Subscriptions whose routing the user chose; the provider's directives no longer change it.
  var manualAssignments: [String]?
}
private struct ManagedSourceConfiguration: Codable, Equatable {
  let id: String
  let url: String
  let destination: String
  let matchMode: String
}
private struct ManagedSourceState: Codable {
  let source: ManagedSourceConfiguration
  var domains: [String]
  var revision: String?
  var lastSuccessfulFetch: Date?
  var schedule: RefreshSchedule
}
struct ManagedCandidate {
  fileprivate let record: RoutingRecord
  fileprivate let generation: UUID?
}
private struct RoutingRecord: Codable {
  var id: String
  var name: String
  var providerSubscriptionID: String?
  var providerProfile: Data?
  var providerRouteModel: Data?
  var workingProfile: Data
  var routeModel: Data
  var edited: Bool
  var enabled: Bool
  var updatedAt: Date
  var geofileStatus: String
  var geoipURL: String?
  var geositeURL: String?
  var lastGeoRefresh: Date?
  var assetRevision: String?
  var originalAssetRevision: String?
  var geoipUpdatedAt: Date?
  var geositeUpdatedAt: Date?
  var geoipDownloadedSource: String?
  var geositeDownloadedSource: String?
  var geoipValidators: GeofileValidators?
  var geositeValidators: GeofileValidators?
  var geofileError: String?
  var reductionStatus: String?
  // Codes the geofiles lack, which Direct, Block and domestic DNS rules skip.
  var skippedGeodata: [String]?
  // Selectors the assigned servers' own configs name; the reduced files keep them.
  var serverGeodata: [String]?
  var serverGeodataRefs: [String]?
  var managedSources: [ManagedSourceState]?
  var managedRevision: String?
  var publicationGeneration: UUID?
}
