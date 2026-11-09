import SwiftUI

struct RoutingView: View {
  @Environment(IOSAppModel.self) private var model
  @State private var creating = false
  var body: some View {
    AppList {
      if model.routingProfiles.isEmpty { AppEmptyState(title: "Your routing, your choice", systemImage: "arrow.triangle.branch", message: "Create rules for direct, proxy, and blocked traffic, or import a provider’s routing profile.") }
      ForEach(model.routingProfiles) { profile in
        NavigationLink { RoutingDetailView(profileID: profile.id) } label: {
          HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.branch").foregroundStyle(AppPalette.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
              Text(profile.name).font(.headline)
              Text([profile.enabled ? String(localized: "Enabled") : String(localized: "Disabled"), profile.owner == nil ? String(localized: "Manual") : String(localized: "Provider"), profile.edited ? String(localized: "Edited") : ""].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption).foregroundStyle(AppPalette.secondary)
            }
          }.padding(.vertical, 5)
        }
      }
      if !model.subscriptions.isEmpty { Section("Assignments") {
        ForEach(model.subscriptions) { source in VStack(alignment: .leading, spacing: 8) { Text(source.name).font(.subheadline); RoutingAssignment(sourceID: source.id) } }
      } }
      Section { Text("iPhone supports domain and IP rules. Desktop executable rules cannot identify other apps on iOS. Use network rules for the traffic you want to route.").font(.footnote).foregroundStyle(AppPalette.secondary) }
    }.navigationTitle("Routing")
    .toolbar { ToolbarItem(placement: .topBarLeading) { Button("New profile", systemImage: "square.and.pencil") { creating = true }.disabled(model.busy) } }
    .sheet(isPresented: $creating) { RoutingEditor(profile: nil) }
  }
}

struct RoutingDetailView: View {
  private static var destinations: [String: String] {
    ["block": String(localized: "Block"), "direct": String(localized: "Direct"), "proxy": String(localized: "Proxy"), "dns": String(localized: "Direct DNS")]
  }
  @Environment(IOSAppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  let profileID: String
  @State private var editing = false
  @State private var raw = false
  @State private var deleting = false
  @State private var resetting = false
  @State private var share: SharedText?
  private var profile: RoutingProfile? { model.routingProfiles.first { $0.id == profileID } }
  var body: some View {
    AppList {
      if let profile {
        Section {
          Toggle("Enabled", isOn: Binding(get: { profile.enabled }, set: { value in model.launch { try await model.editRouting { _ = try $0.setEnabled(id: profile.id, enabled: value) } } }))
          if let owner = profile.owner { LabeledContent("Provider", value: model.subscriptions.first { $0.id == owner }?.name ?? String(localized: "Unavailable")) }
          Button("Edit rules and DNS", systemImage: "slider.horizontal.3") { editing = true }
          Button("Edit JSON", systemImage: "curlybraces") { raw = true }
          Button("Share routing profile", systemImage: "square.and.arrow.up") { share = SharedText(title: profile.name, text: profile.json) }
          Button("Duplicate", systemImage: "doc.on.doc") { model.launch { try await model.editRouting { _ = try $0.duplicate(id: profile.id) } } }
        }.disabled(model.busy)
        Section("Routing data") {
          LabeledContent("Status", value: profile.raw["geofileStatus"] as? String ?? String(localized: "Not downloaded"))
          LabeledContent("Size reduction", value: profile.reductionText)
          if let skipped = profile.raw["skippedGeodata"] as? [String], !skipped.isEmpty {
            Text("Direct, Block and domestic DNS rules skip codes the geofiles lack: \(skipped.joined(separator: ", ")).").font(.caption)
          }
          if let error = profile.raw["geofileError"] as? String { Text(error).foregroundStyle(AppPalette.secondary) }
          ForEach(profile.geofiles.indices, id: \.self) { index in
            let file = profile.geofiles[index]
            VStack(alignment: .leading, spacing: 6) {
              Text(file["name"] as? String ?? String(localized: "File")).font(.headline)
              Text(file["source"] as? String ?? String(localized: "Not configured")).font(.caption).foregroundStyle(AppPalette.secondary)
              if let bytes = RoutingProfile.bytes(file) { Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)).font(.caption.monospacedDigit()) }
              Text(file["updatedAt"] as? String ?? String(localized: "Never")).font(.caption).foregroundStyle(AppPalette.secondary)
              Button("Refresh \(file["name"] as? String ?? "file")") { model.launch { try await model.refreshAssets(profile, file: file["name"] as? String) } }.disabled(model.busy)
            }.padding(.vertical, 4)
          }
          Button("Refresh all routing data") { model.launch { try await model.refreshAssets(profile) } }.disabled(model.busy)
        }
        // Reading the lists parses the profile's JSON, so the body reads them once.
        let managedSources = profile.managedSources
        if !managedSources.isEmpty {
          Section {
            ForEach(managedSources.indices, id: \.self) { index in
              let source = managedSources[index]
              VStack(alignment: .leading, spacing: 8) {
                Text(URL(string: source["url"] as? String ?? "")?.host ?? String(localized: "Domain list")).font(.headline)
                Text("\(Self.destinations[source["destination"] as? String ?? ""] ?? "") · \(source["matchMode"] as? String == "exact" ? String(localized: "Exact domains") : String(localized: "Including subdomains"))").font(.caption).foregroundStyle(AppPalette.secondary)
                let status = profile.managedStatus(source["id"] as? String)
                if let fetched = status["lastSuccessfulFetch"] as? Double {
                  LabeledContent("Updated") { Text(Date(timeIntervalSince1970: fetched), style: .relative) }.font(.caption)
                } else { Text("Not downloaded yet").font(.caption).foregroundStyle(AppPalette.secondary) }
                if status["error"] is String { Text("The last download failed. The previous list is kept.").font(.caption).foregroundStyle(AppPalette.secondary) }
                Button("Refresh list", systemImage: "arrow.clockwise") {
                  model.launch {
                    guard let id = source["id"] as? String else { throw IOSAppError.invalidSettings }
                    try await model.refreshManaged(profileID: profile.id, sourceID: id)
                    model.notice = String(localized: "Domain list refreshed.")
                  }
                }.disabled(model.busy)
              }.padding(.vertical, 4)
            }
            Button("Refresh all lists", systemImage: "arrow.clockwise") {
              model.launch {
                for source in managedSources {
                  guard let id = source["id"] as? String else { throw IOSAppError.invalidSettings }
                  try await model.refreshManaged(profileID: profile.id, sourceID: id)
                }
                model.notice = String(localized: "Domain lists refreshed.")
              }
            }.disabled(model.busy)
          } header: { Text("Managed domain lists") } footer: { Text("Lists refresh daily while the app is open. Failed downloads retain the last valid rules. Edit lists in the Advanced section of Edit rules and DNS.") }
        }
        Section {
          if profile.owner != nil { Button("Reset to provider version") { resetting = true } }
          Button("Delete routing profile", role: .destructive) { deleting = true }
        }.disabled(model.busy)
      }
    }.navigationTitle(profile?.name ?? String(localized: "Routing")).navigationBarTitleDisplayMode(.inline)
    .sheet(isPresented: $editing) { if let profile { RoutingEditor(profile: profile) } }
    .sheet(isPresented: $raw) { if let profile { RoutingJSONEditor(profile: profile) } }
    .sheet(item: $share) { ShareView(item: $0) }
    .confirmationDialog("Delete this routing profile?", isPresented: $deleting, titleVisibility: .visible) {
      Button("Delete profile", role: .destructive) { model.launch { try await model.editRouting { _ = try $0.delete(id: profileID) }; dismiss() } }
    }
    .confirmationDialog("Replace your edits with the provider’s version?", isPresented: $resetting, titleVisibility: .visible) {
      Button("Reset edits", role: .destructive) { model.launch { try await model.editRouting { _ = try $0.reset(id: profileID) } } }
    }
  }
}

struct RoutingEditor: View {
  @Environment(IOSAppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  let profile: RoutingProfile?
  @State private var value: [String: Any]
  @State private var section = "rules"
  @State private var explicitDNS: Bool
  @State private var hosts: [DNSHostDraft]
  /// Russian national zones and the other domains these services use (v2fly domain-list-community); the desktop editor has the same list.
  static let russianSitesPreset = [
    "domain:ru", "domain:xn--p1ai", "domain:su",
    "domain:ozon.com", "domain:ozonusercontent.com", "domain:ozon.kz",
    "domain:wbstatic.net", "domain:wbcontent.net", "domain:wb.kz", "domain:paywb.com",
    "domain:yandex.net", "domain:yandex.com", "domain:yastatic.net", "domain:yastat.net", "domain:yandexcloud.net",
    "domain:yandex.cloud", "domain:ya.cc", "domain:yadi.sk", "domain:naydex.net",
    "domain:vk.com", "domain:vk.me", "domain:userapi.com", "domain:vkuser.net", "domain:vk-cdn.net", "domain:vkuseraudio.net",
    "domain:vkuservideo.net", "domain:vkuserlive.net", "domain:vkcache.com", "domain:mycdn.me", "domain:mvk.com",
    "domain:sberbank.com", "domain:tbank-online.com", "domain:tinkoff-group.com", "domain:tinkoffmobile.com",
    "domain:vtb.com", "domain:vtb-direct.com", "domain:alfa.me", "domain:alfabank.st",
  ]
  init(profile: RoutingProfile?, initialSection: String = "rules") {
    self.profile = profile
    _section = State(initialValue: initialSection)
    let object = Self.draft(profile)
    _value = State(initialValue: object); _explicitDNS = State(initialValue: object["DomesticDNSDomains"] is [String])
    _hosts = State(initialValue: (object["DnsHosts"] as? [String: String] ?? [:]).sorted { $0.key < $1.key }.map { DNSHostDraft(host: $0.key, address: $0.value) })
  }
  static func draft(_ profile: RoutingProfile?) -> [String: Any] {
    var object = profile.flatMap { try? JSONSerialization.jsonObject(with: Data($0.json.utf8)) as? [String: Any] } ??
      ["Name": "My routing", "GlobalProxy": true, "RemoteDNSType": "DoU", "RemoteDNSIP": "1.1.1.1", "DomesticDNSType": "DoU", "DomesticDNSIP": "1.1.1.1", "RouteOrder": "block-direct-proxy", "DomainStrategy": "AsIs", "UseChunkFiles": "true"]
    object["FakeDNS"] = object["FakeDNS"] ?? object["FakeDns"] ?? "false"
    // A stored profile carries an empty current key beside the legacy one it was imported with.
    for keys in [["RemoteDNSIP", "RemoteDNSIp", "RemoteDns"], ["DomesticDNSIP", "DomesticDNSIp", "DomesticDns"]] {
      let address = keys.lazy.compactMap { object[$0] as? String }.first { !$0.isEmpty }
      object[keys[0]] = address ?? ""
    }
    return object
  }
  var body: some View {
    NavigationStack {
      AppForm {
        Section { Picker("Section", selection: $section) { Text("Rules").tag("rules"); Text("DNS").tag("dns"); Text("Advanced").tag("advanced") }.pickerStyle(.segmented) }
        if section == "rules" {
          Section { Toggle("Proxy unmatched traffic", isOn: flag("GlobalProxy")) } footer: { Text("When off, traffic that does not match a rule goes directly to its destination.") }
          ForEach(["Direct", "Proxy", "Block"], id: \.self) { action in
            Section {
              if action == "Direct" {
                Menu {
                  // lines() keeps the user's entries first and drops repeats.
                  Button { list("DirectSites").wrappedValue += "\n" + Self.russianSitesPreset.joined(separator: "\n") } label: {
                    Text("Russian sites direct"); Text(".ru, .рф, .su and these services' other domains")
                  }
                } label: { Label("Add preset", systemImage: "plus") }
              }
              LinesEditor(title: "Domains", text: list(action + "Sites"))
              LinesEditor(title: "IP addresses and networks", text: list(action + "Ip"))
            } header: { Text(LocalizedStringKey(action)) } footer: { Text("One target per line. Domains support domain:, full:, regexp:, and geosite:. Networks support IPv4, IPv6, CIDR, and geoip:.") }
          }
        } else if section == "dns" {
          Section { Toggle("Keep domain identity with Fake DNS", isOn: flag("FakeDNS")) } footer: { Text("With real DNS, domain rules depend on supported traffic sniffing. Encrypted hostnames and other protocols may need IP rules.") }
          ForEach(["Remote", "Domestic"], id: \.self) { role in
            Section(role == "Remote" ? String(localized: "Remote DNS") : String(localized: "Direct DNS")) {
              Picker("Resolver type", selection: string(role + "DNSType", default: "DoU")) { Text("DNS over HTTPS").tag("DoH"); Text("UDP").tag("DoU") }
              if value[role + "DNSType"] as? String == "DoH" { TextField("HTTPS URL", text: string(role + "DNSDomain")).keyboardType(.URL) }
              TextField("Resolver or bootstrap IP", text: string(role + "DNSIP"))
            }.textInputAutocapitalization(.never).autocorrectionDisabled()
          }
          Section {
            Toggle("Choose direct DNS by domain", isOn: $explicitDNS)
            if explicitDNS { LinesEditor(title: "Domains using direct DNS", text: list("DomesticDNSDomains")) }
          } footer: { Text("Matching domains use direct DNS; the others use remote DNS. Off preserves ordered fallback.") }
          Section {
            ForEach($hosts) { $entry in
              VStack(alignment: .leading, spacing: 8) {
                TextField("Hostname", text: $entry.host)
                TextField("IPv4 or IPv6 address", text: $entry.address)
                Button("Remove host", role: .destructive) { hosts.removeAll { $0.id == entry.id } }
              }
            }
            Button("Add DNS host", systemImage: "plus") { hosts.append(DNSHostDraft(host: "", address: "")) }
          } header: { Text("Static DNS hosts") } footer: { Text("Resolve these hostnames to the addresses you specify. Hostnames must be unique.") }
            .textInputAutocapitalization(.never).autocorrectionDisabled()
        } else {
          Section {
            TextField("Profile name", text: string("Name"))
            Picker("Rule order", selection: string("RouteOrder", default: "block-direct-proxy")) {
              ForEach(["block-direct-proxy", "block-proxy-direct", "direct-block-proxy", "direct-proxy-block", "proxy-block-direct", "proxy-direct-block"], id: \.self) { Text($0.replacingOccurrences(of: "-", with: " → ").capitalized).tag($0) }
            }
            Picker("Resolve domains for routing", selection: string("DomainStrategy", default: "AsIs")) { Text("Keep names").tag("AsIs"); Text("If no match").tag("IPIfNonMatch"); Text("When needed").tag("IPOnDemand") }
            Toggle("Reduce routing-data size", isOn: flag("UseChunkFiles"))
            TextField("GeoIP URL", text: string("Geoipurl")).keyboardType(.URL)
            TextField("GeoSite URL", text: string("Geositeurl")).keyboardType(.URL)
          }
          managedSourcesEditor
          Section { Text("Other provider fields are preserved. Edit JSON is available for the complete profile.").foregroundStyle(AppPalette.secondary) }
        }
      }
      .navigationTitle(profile == nil ? String(localized: "New routing profile") : String(localized: "Edit routing")).navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(model.busy) }
        ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(model.busy) }
      }.interactiveDismissDisabled(model.busy).appErrors()
    }
  }
  private func string(_ key: String, default fallback: String = "") -> Binding<String> { Binding(get: { value[key] as? String ?? fallback }, set: { value[key] = $0 }) }
  private func flag(_ key: String) -> Binding<Bool> { Binding(get: { value[key] as? Bool == true || value[key] as? String == "true" }, set: { value[key] = $0 }) }
  private func list(_ key: String) -> Binding<String> { Binding(get: { (value[key] as? [String])?.joined(separator: "\n") ?? value[key] as? String ?? "" }, set: { value[key] = lines($0) }) }
  private func save() {
    model.launch {
      var saved = value
      let entries = hosts.map { ($0.host.trimmingCharacters(in: .whitespacesAndNewlines), $0.address.trimmingCharacters(in: .whitespacesAndNewlines)) }
      guard Set(entries.map { $0.0.lowercased() }).count == entries.count, entries.allSatisfy({ !$0.0.isEmpty && !$0.1.isEmpty }) else { throw IOSAppError.invalidSettings }
      saved["DnsHosts"] = Dictionary(uniqueKeysWithValues: entries)
      for alias in ["FakeDns", "RemoteDNSIp", "DomesticDNSIp", "RemoteDns", "DomesticDns"] { saved.removeValue(forKey: alias) }
      if !explicitDNS { saved.removeValue(forKey: "DomesticDNSDomains") }
      let text = try prettyJSON(saved)
      try await model.editRouting { store in
        if let profile { _ = try store.update(id: profile.id, content: text) }
        else { _ = try store.importContent(text, selectedSubscriptionID: model.selected?.subscriptionID, asNew: true) }
      }
      dismiss()
    }
  }
  private var managedSources: [[String: Any]] { value["ManagedSources"] as? [[String: Any]] ?? [] }
  private func managed(_ index: Int, _ key: String) -> Binding<String> {
    Binding(get: { managedSources.indices.contains(index) ? managedSources[index][key] as? String ?? "" : "" }, set: { text in
      var sources = managedSources; guard sources.indices.contains(index) else { return }
      sources[index][key] = text; value["ManagedSources"] = sources
    })
  }
  private var managedSourcesEditor: some View {
    Section {
      ForEach(managedSources.indices, id: \.self) { index in
        VStack(alignment: .leading, spacing: 8) {
          TextField("List URL", text: managed(index, "url")).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
          Picker("Use domains for", selection: managed(index, "destination")) { Text("Block").tag("block"); Text("Direct").tag("direct"); Text("Proxy").tag("proxy"); Text("Direct DNS").tag("dns") }
          Picker("Match", selection: managed(index, "matchMode")) { Text("Exact domains").tag("exact"); Text("Include subdomains").tag("subdomains") }
          Button("Remove list", role: .destructive) { var sources = managedSources; sources.remove(at: index); value["ManagedSources"] = sources }
        }.padding(.vertical, 4)
      }
      Button("Add domain list", systemImage: "plus") {
        var sources = managedSources; sources.append(["id": UUID().uuidString.lowercased(), "url": "", "destination": "block", "matchMode": "subdomains"]); value["ManagedSources"] = sources
      }.disabled(managedSources.count >= 125)
    } header: { Text("Managed domain lists") } footer: { Text("Use a trusted public HTTPS source with one domain per line, a hosts file, or supported domain rules. A DNS list chooses domains for direct DNS. Private-network URLs are rejected.") }
  }
}

private struct DNSHostDraft: Identifiable { let id = UUID(); var host: String; var address: String }

struct RoutingJSONEditor: View {
  @Environment(IOSAppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  let profile: RoutingProfile
  @State private var text: String
  init(profile: RoutingProfile) { self.profile = profile; _text = State(initialValue: profile.json) }
  var body: some View {
    NavigationStack {
      TextEditor(text: $text).font(.body.monospaced()).padding().textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel("Routing JSON")
        .navigationTitle("Routing JSON").navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
          ToolbarItem(placement: .confirmationAction) { Button("Save") { model.launch { try await model.editRouting { _ = try $0.update(id: profile.id, content: text) }; dismiss() } }.disabled(model.busy) }
        }.interactiveDismissDisabled(model.busy).appErrors()
    }
  }
}
