import SwiftUI

struct SettingsView: View {
  @Environment(IOSAppModel.self) private var model
  private enum Category: String {
    case general = "General", appearance = "Appearance", connection = "Connection", dns = "DNS"
    case apps = "Apps & routes", advanced = "Advanced", tests = "Server tests"
    case backup = "Backup and repair", system = "System info", routes = "Route table"
  }
  var body: some View {
    AppForm {
      categorySection("Preferences", categories: [.general, .appearance])
      categorySection("Network", categories: [.connection, .dns, .apps, .advanced, .tests])
      categorySection("Support", categories: [.backup, .system, .routes])
    }.navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
  }
  private func categorySection(_ title: LocalizedStringKey, categories: [Category]) -> some View {
    Section(title) {
      ForEach(categories, id: \.self) { category in
        NavigationLink(LocalizedStringKey(category.rawValue)) { categoryContent(category) }
          .accessibilityIdentifier("settingsCategory.\(category.rawValue)")
      }
    }
  }
  @ViewBuilder private func categoryContent(_ category: Category) -> some View {
    switch category {
    case .general: PreferencesEditor(kind: .general, initial: model.preferences, inline: true)
    case .appearance: PreferencesEditor(kind: .appearance, initial: model.preferences, inline: true)
    case .connection: ConnectionEditor(kind: .connection, initial: model.settings, inline: true)
    case .dns: ConnectionEditor(kind: .dns, initial: model.settings, inline: true)
    case .apps: ConnectionEditor(kind: .routes, initial: model.settings, inline: true)
    case .advanced: ConnectionEditor(kind: .advanced, initial: model.settings, inline: true)
    case .tests: PreferencesEditor(kind: .tests, initial: model.preferences, inline: true)
    case .backup: BackupView()
    case .system: SystemInformationView()
    case .routes: RouteTableView()
    }
  }
}

struct LicensesView: View {
  var body: some View {
    AppList {
      ForEach([("LICENSE", String(localized: "GNU General Public License")), ("NOTICE", String(localized: "Elarni notices")), ("THIRD_PARTY_NOTICES", String(localized: "Third-party notices"))], id: \.0) { file, title in
        NavigationLink(title) {
          ScrollView {
            Text(contents(file)).font(.footnote.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding()
          }.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        }
      }
    }.navigationTitle("Licenses and notices").navigationBarTitleDisplayMode(.inline)
  }
  private func contents(_ name: String) -> String {
    guard let url = Bundle.main.url(forResource: name, withExtension: "txt"),
          let text = try? String(contentsOf: url, encoding: .utf8) else { return String(localized: "The notice could not be loaded.") }
    return text
  }
}

struct PreferencesEditor: View {
  enum Kind: String { case general = "General", appearance = "Appearance", tests = "Server tests" }
  let kind: Kind
  let inline: Bool
  @Environment(IOSAppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var value: IOSPreferences
  // What the draft started from: a save sends only what was changed here, so a server order chosen on Home since stays.
  @State private var base: IOSPreferences
  init(kind: Kind, initial: IOSPreferences, inline: Bool = false) { self.kind = kind; self.inline = inline; _value = State(initialValue: initial); _base = State(initialValue: initial) }
  private var dirty: Bool { updatedPreferences != model.preferences }
  private var valid: Bool { (try? model.validatePreferences(updatedPreferences)) != nil }
  private func save(leaving: Bool) {
    let next = updatedPreferences, sent = value
    model.launchShown { try model.savePreferences(next); base = sent; if !inline && !leaving { dismiss() } }
  }
  var body: some View {
    AppForm {
      if kind == .general {
        Section {
          NavigationLink { RecoveryEditor(initial: model.preferences.automation) } label: {
            LabeledContent("Connection recovery", value: model.preferences.automation.enabled ? String(localized: "On") : String(localized: "Off"))
          }
          Toggle("On Demand", isOn: setting(\.onDemandEnabled))
          Toggle("Connect on untrusted Wi-Fi", isOn: Binding(get: { model.settings.connectOnUntrustedWiFi == true }, set: { enabled in
            var next = model.settings; next.connectOnUntrustedWiFi = enabled
            model.launchShown { try await model.saveSettings(next) }
          })).accessibilityIdentifier("connectOnUntrustedWiFi")
          if model.settings.connectOnUntrustedWiFi == true {
            NavigationLink { TrustedWiFiEditor() } label: {
              LabeledContent("Trusted Wi-Fi networks", value: (model.settings.trustedWiFiNetworks ?? []).isEmpty ? String(localized: "None") : "\(model.settings.trustedWiFiNetworks!.count)")
            }
          }
          Toggle("Disconnect on sleep", isOn: setting(\.disconnectOnSleep))
        } header: { Text("Connection") } footer: {
          Text("Connect on untrusted Wi-Fi connects when iPhone joins a Wi-Fi network outside your trusted list, even before you tap Connect. Trusted Wi-Fi and mobile data leave the VPN as it is. Disconnect pauses it until your next Connect.")
        }
        Section {
          Picker("Auto-update", selection: $value.autoUpdateHours) {
            ForEach([1, 2, 4, 6, 12, 24, 48, 168], id: \.self) { Text($0 == 168 ? String(localized: "Weekly") : String(localized: "Every \($0) hours")).tag($0) }
          }
          Toggle("Subscription expiry reminders", isOn: Binding(get: { model.preferences.expiryReminders }, set: { enabled in
            model.launchShown { try await model.setReminders(enabled); value.expiryReminders = model.preferences.expiryReminders; base.expiryReminders = value.expiryReminders }
          }))
          Picker("Server order", selection: $value.serverOrder) { Text("Provider order").tag("provider"); Text("Alphabetical").tag("name"); Text("Lowest latency").tag("latency") }
          Toggle("Favorites first", isOn: Binding(get: { value.favoritesFirst ?? true }, set: { value.favoritesFirst = $0 }))
        } header: { Text("Subscriptions") } footer: { Text("Due subscriptions and routing data refresh while the app is open. iOS can suspend the app in the background. Expiry reminders use local notifications.") }
        Section { NavigationLink("Shortcuts") { ShortcutsView() } }
      } else if kind == .appearance {
        Section {
          Picker("Theme", selection: $value.theme) { Text("Follow system").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark") }.pickerStyle(.menu).accessibilityIdentifier("themePicker")
          Picker("Accent color", selection: $value.accent) { Text("Evergreen").tag("evergreen"); Text("Blue").tag("blue"); Text("Teal").tag("teal"); Text("Purple").tag("purple"); Text("Orange").tag("orange") }.pickerStyle(.menu).accessibilityIdentifier("accentPicker")
        } footer: { Text("Text follows your iPhone’s text size. Motion follows Reduce Motion in Accessibility settings.") }
      } else {
        Section {
          Picker("Test type", selection: $value.probeMode) {
            Text("Proxy").tag("proxy"); Text("Current rules / active tunnel").tag("activeProxy"); Text("Direct TCP").tag("tcp"); Text("Direct ICMP").tag("icmp")
          }
          Picker("Timeout", selection: $value.probeTimeout) {
            ForEach(Array(Set([5, 7, 9, 12, 15, value.probeTimeout])).sorted(), id: \.self) { Text("\($0) s timeout").tag($0) }
          }.accessibilityIdentifier("probeTimeout")
        } footer: { Text("While connected, proxy tests check the selected VPN path. Disconnect to test other servers, direct TCP, or ICMP. Results expire after five minutes or a configuration change.") }
        if ["proxy", "activeProxy"].contains(value.probeMode) {
          Section("HTTP request") {
            Picker("HTTP method", selection: $value.probeMethod) { Text("Proxy GET").tag("GET"); Text("Proxy HEAD").tag("HEAD") }
            Picker("Test mode", selection: $value.probeVariant) { Text("Default").tag("default"); Text("Double").tag("double"); Text("Keep-alive").tag("keepalive") }
            StackedField(title: "Test URL", prompt: "https://", text: $value.probeURL).keyboardType(.URL)
            NumberField(title: "Expected HTTP status", value: $value.probeExpectedStatus)
            StackedField(title: "Expected response body", prompt: "Any", text: $value.probeExpectedBody, axis: .vertical)
          }.textInputAutocapitalization(.never).autocorrectionDisabled()
        }
        Section { Button("Open server list") { model.selectedTab = 0 } }
      }
      if dirty && !valid { InvalidDraftNote() }
    }.draftPage(LocalizedStringKey(kind.rawValue), dirty: dirty, valid: valid, cancel: { value = model.preferences; base = value; dismiss() }, save: save)
    // Back on this page with nothing pending: show what is saved now.
    .onAppear { if !dirty { value = model.preferences; base = value } }
    // The switch saves itself once it has been left alone for the pause.
    .task(id: value.favoritesFirst) {
      guard kind == .general, value.favoritesFirst != base.favoritesFirst else { return }
      model.saveStatus = .saving
      try? await Task.sleep(for: autoApplyDelay)
      guard !Task.isCancelled else { return }
      var next = model.preferences; next.favoritesFirst = value.favoritesFirst
      let sent = value.favoritesFirst
      model.launchShown({ try model.savePreferences(next); base.favoritesFirst = sent }, failed: { value.favoritesFirst = base.favoritesFirst })
    }
  }
  private var updatedPreferences: IOSPreferences {
    var next = model.preferences
    func take<Value: Equatable>(_ key: WritableKeyPath<IOSPreferences, Value>) { carry(key, from: value, since: base, to: &next) }
    switch kind {
    case .general:
      take(\.autoUpdateHours); take(\.serverOrder); take(\.favoritesFirst)
    case .appearance:
      take(\.theme); take(\.accent)
    case .tests:
      take(\.probeMode); take(\.probeTimeout); take(\.probeURL); take(\.probeMethod); take(\.probeVariant)
      take(\.probeExpectedStatus); take(\.probeExpectedBody)
    }
    return next
  }
  private func setting(_ key: WritableKeyPath<IOSTunnelSettings, Bool>) -> Binding<Bool> {
    Binding(get: { model.settings[keyPath: key] }, set: { enabled in
      var next = model.settings; next[keyPath: key] = enabled
      model.launchShown { try await model.saveSettings(next) }
    })
  }
}

struct ConnectionEditor: View {
  enum Kind: String { case connection = "Connection", dns = "DNS", routes = "Apps & routes", advanced = "Advanced" }
  let kind: Kind
  let inline: Bool
  @Environment(IOSAppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var value: IOSTunnelSettings
  // What the draft started from: a save sends only what was changed here, so a setting saved on another page since stays.
  @State private var base: IOSTunnelSettings
  @State private var editingDNS: RoutingProfile?
  init(kind: Kind, initial: IOSTunnelSettings, inline: Bool = false) { self.kind = kind; self.inline = inline; _value = State(initialValue: initial); _base = State(initialValue: initial) }
  private var switches: [WritableKeyPath<IOSTunnelSettings, Bool>] {
    switch kind {
    case .connection: [\.httpInboundEnabled, \.inboundAuthEnabled, \.allowLAN]
    case .dns: [\.resolveServer]
    case .routes: [\.includeAllNetworks, \.enforceRoutes]
    case .advanced: [\.fragmentationEnabled, \.muxEnabled, \.sniffingEnabled, \.monitoringEnabled]
    }
  }
  private var flipped: [Bool?] { switches.map { Optional(value[keyPath: $0]) } + [value.recordDiagnostics] }
  /// The saved settings with the switches flipped here and, with `typed`, what was typed or picked here.
  private func merged(typed: Bool) -> IOSTunnelSettings {
    var next = model.settings
    func take<Value: Equatable>(_ key: WritableKeyPath<IOSTunnelSettings, Value>) { carry(key, from: value, since: base, to: &next) }
    switches.forEach(take); take(\.recordDiagnostics)
    guard typed else { return next }
    switch kind {
    case .connection: take(\.profilePreferredIP); take(\.preferredIP); take(\.socksPort); take(\.httpPort)
    case .dns: take(\.profileDNSMode)
    case .routes: take(\.includedRoutes); take(\.excludedRoutes)
    case .advanced:
      take(\.fragmentPackets); take(\.fragmentLength); take(\.fragmentInterval)
      take(\.idleTimeoutSeconds); take(\.tcpMaxConnections); take(\.udpMaxConnections)
    }
    return next
  }
  private var dirty: Bool { merged(typed: true) != model.settings }
  private var valid: Bool { (try? merged(typed: true).validate()) != nil }
  private func save(leaving: Bool) {
    let next = merged(typed: true), sent = value
    model.launchShown { try await model.saveSettings(next); base = sent; if !inline && !leaving { dismiss() } }
  }
  /// The flipped switches alone, once they have been left alone for the pause; a refused one goes back.
  private func saveSwitches() {
    let next = merged(typed: false), sent = value
    model.launchShown({
      try await model.saveSettings(next)
      for key in switches { base[keyPath: key] = sent[keyPath: key] }
      base.recordDiagnostics = sent.recordDiagnostics
    }, failed: {
      for key in switches where value[keyPath: key] == sent[keyPath: key] { value[keyPath: key] = base[keyPath: key] }
      if value.recordDiagnostics == sent.recordDiagnostics { value.recordDiagnostics = base.recordDiagnostics }
    })
  }
  // Its own builder keeps the body within what the type checker solves in time.
  @ViewBuilder private var routeSections: some View {
    Section {
      Toggle("Block traffic without VPN", isOn: $value.includeAllNetworks)
    } header: { Text("Protection") } footer: { Text("iOS keeps all traffic inside the tunnel, including while it reconnects.") }
    Section {
      DisclosureGroup("Advanced network routes") {
      Toggle("Enforce tunnel routes", isOn: $value.enforceRoutes)
      LinesEditor(title: "Included routes", text: Binding(get: { value.includedRoutes.joined(separator: "\n") }, set: { value.includedRoutes = lines($0) }))
      LinesEditor(title: "Excluded routes", text: Binding(get: { value.excludedRoutes.joined(separator: "\n") }, set: { value.excludedRoutes = lines($0) }))
      }
    } footer: { Text("Enforce routes is for specific networks and cannot be combined with Block traffic without VPN or a default /0 route.") }
  }
  var body: some View {
    AppForm {
      if kind == .connection {
        Section {
          Picker("Default IP type", selection: $value.profilePreferredIP) { Text("Use profile").tag("inherit"); IPChoices() }
            .onChange(of: value.profilePreferredIP) { _, preference in if preference != "inherit" { value.preferredIP = preference } }
          // As on Android: servers from share links have no profile value to use.
          if value.profilePreferredIP == "inherit" { Picker("Share-link servers", selection: $value.preferredIP) { IPChoices() } }
        } header: { Text("Server addressing") } footer: { Text("To change one server, open it from Home and use IP preference.") }
        Section {
          NumberField(title: "SOCKS port", value: $value.socksPort)
          Toggle("HTTP inbound", isOn: $value.httpInboundEnabled)
          if value.httpInboundEnabled { NumberField(title: "HTTP port", value: $value.httpPort) }
          NavigationLink("Inbound credentials") { CredentialsView() }
          Toggle("Require SOCKS5 and HTTP authentication", isOn: $value.inboundAuthEnabled).disabled(value.inboundCredentialRef == nil)
            .onChange(of: value.inboundAuthEnabled) { _, enabled in if !enabled { value.allowLAN = false } }
          Toggle("Allow LAN connections (IPv4)", isOn: $value.allowLAN).disabled(!value.inboundAuthEnabled)
        } header: { Text("Local proxy") } footer: { Text("Listeners run inside the VPN extension. LAN access requires authentication. Use different SOCKS and HTTP ports.") }
      } else if kind == .dns {
        Section {
          Picker("DNS settings", selection: $value.profileDNSMode) {
            Text("Provider profile").tag("inherit"); Text("Routing profile").tag("routing"); Text("1.1.1.1").tag("default")
          }
          Toggle("Resolve server before connecting", isOn: $value.resolveServer)
        } footer: { Text("Default DNS uses 1.1.1.1. Configure remote DNS, direct DNS, Fake DNS, and domain rules in a routing profile, then assign it to a subscription.") }
        if value.profileDNSMode == "routing" {
          Section("Routing profiles") {
            ForEach(model.routingProfiles.filter(\.enabled)) { profile in Button("Edit DNS: \(profile.name)") { editingDNS = profile } }
            if !model.routingProfiles.contains(where: \.enabled) { Text("No enabled routing profiles. Enable a profile in Routing.").foregroundStyle(AppPalette.secondary) }
          }
        }
      } else if kind == .routes {
        routeSections
      } else {
        Section("Transport") {
          Toggle("Enable fragmentation", isOn: $value.fragmentationEnabled)
          if value.fragmentationEnabled {
            TextField("Packets (tlshello or range)", text: $value.fragmentPackets)
            TextField("Length range", text: $value.fragmentLength)
            TextField("Interval range (ms)", text: $value.fragmentInterval)
          }
          Toggle("Enable default VLESS mux", isOn: $value.muxEnabled)
        }.textInputAutocapitalization(.never).autocorrectionDisabled()
        Section {
          Picker("Connection idle timeout (seconds)", selection: $value.idleTimeoutSeconds) {
            ForEach(Array(Set([30, 60, 120, 300, 600, 1800, 3600, value.idleTimeoutSeconds])).sorted(), id: \.self) { Text("\($0)").tag($0) }
          }
          Picker("TCP max connections", selection: $value.tcpMaxConnections) {
            ForEach(Array(Set([64, 128, 256, 512, 1024, 2048, 4096, value.tcpMaxConnections])).sorted(), id: \.self) { Text("\($0)").tag($0) }
          }
          Picker("UDP max connections", selection: $value.udpMaxConnections) {
            ForEach(Array(Set([32, 64, 128, 256, 512, 1024, 2048, 4096, value.udpMaxConnections])).sorted(), id: \.self) { Text("\($0)").tag($0) }
          }
          Toggle("Enable sniffing", isOn: $value.sniffingEnabled)
        } header: { Text("Resources") } footer: { Text("Idle timeout: 30–3,600 seconds. Connection limits: 1–4,096. The iPhone runtime uses a 30 MiB soft Go heap target; total extension memory also includes native buffers and framework overhead.") }
        Section("Monitoring") { Toggle("Show monitoring on main screen", isOn: $value.monitoringEnabled) }
#if ELARNI_RECORDING
        Section {
          Toggle("Record connection diagnostics", isOn: Binding(get: { value.recordDiagnostics == true }, set: { value.recordDiagnostics = $0 ? true : nil }))
        } header: { Text("Diagnostics") } footer: { Text("Records connection timing, byte counts and errors while connected, so a problem can be traced. No sites, addresses, credentials or content. Uses little battery. Mark a problem on the main screen and export the recording from Troubleshooting.") }
#endif
      }
      Section { Text("Saving these settings reconnects an active VPN.").font(.footnote).foregroundStyle(AppPalette.secondary) }
      if dirty && !valid { InvalidDraftNote() }
    }.draftPage(LocalizedStringKey(kind.rawValue), dirty: dirty, valid: valid, cancel: { value = model.settings; base = value; dismiss() }, save: save)
    // Back on this page with nothing pending: show what is saved now.
    .onAppear { if !dirty { value = model.settings; base = value } }
    .task(id: flipped) {
      guard merged(typed: false) != model.settings else { return }
      model.saveStatus = .saving
      try? await Task.sleep(for: autoApplyDelay)
      guard !Task.isCancelled else { return }
      saveSwitches()
    }
    .onChange(of: model.settings.inboundCredentialRef) { _, ref in
      value.inboundCredentialRef = ref; value.inboundAuthEnabled = model.settings.inboundAuthEnabled
      base.inboundCredentialRef = ref; base.inboundAuthEnabled = value.inboundAuthEnabled
    }
    .sheet(item: $editingDNS) { RoutingEditor(profile: $0, initialSection: "dns") }
  }
}

struct CredentialsView: View {
  @Environment(IOSAppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var username = ""
  @State private var password = ""
  var body: some View {
    AppForm {
      Section { TextField("Username", text: $username).textContentType(.username); SecureField("Password", text: $password).textContentType(.newPassword) }
        .textInputAutocapitalization(.never).autocorrectionDisabled()
      Section { Text("Each value must be 1–255 UTF-8 bytes with no control characters. The username cannot contain a colon. Saving enables authentication and reconnects an active VPN. Credentials are kept in the shared Keychain.").font(.footnote).foregroundStyle(AppPalette.secondary) }
      if dirty && !valid { InvalidDraftNote() }
    }.draftPage("Listener credentials", dirty: dirty, valid: valid, canSave: !username.isEmpty && !password.isEmpty, cancel: { username = ""; password = ""; dismiss() }) { leaving in
      let user = username, secret = password
      model.launch { try await model.updateCredentials(username: user, password: secret); username = ""; password = ""; if !leaving { dismiss() } }
    }
  }
  private var dirty: Bool { !username.isEmpty || !password.isEmpty }
  // The two values only make sense together.
  private var valid: Bool {
    (1...255).contains(username.utf8.count) && (1...255).contains(password.utf8.count) && !username.contains(":") &&
      !(username + password).unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  }
}

struct TrustedWiFiEditor: View {
  @Environment(IOSAppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var text = ""
  @State private var loaded = false
  private var saved: [String] { model.settings.trustedWiFiNetworks ?? [] }
  private var next: IOSTunnelSettings { var next = model.settings; next.trustedWiFiNetworks = lines(text); return next }
  private var dirty: Bool { loaded && lines(text) != saved }
  private var valid: Bool { (try? next.validate()) != nil }
  var body: some View {
    AppForm {
      Section {
        LinesEditor(title: "Trusted Wi-Fi networks", text: $text).accessibilityIdentifier("trustedWiFiNetworks")
      } footer: {
        Text(valid ? String(localized: "One network name per line. Joining one of these leaves the VPN as it is.") : String(localized: "Use up to 64 names of at most 32 bytes each, without tabs."))
          .foregroundStyle(valid ? AppPalette.secondary : Color.red)
      }
      if dirty && !valid { InvalidDraftNote() }
    }
    // Once: a draft left open under another tab is still there on return.
    .onAppear { if !loaded { text = saved.joined(separator: "\n"); loaded = true } }
    .draftPage("Trusted Wi-Fi", dirty: dirty, valid: valid, cancel: { text = saved.joined(separator: "\n"); dismiss() }) { leaving in
      guard valid else { return }
      let next = next
      model.launchShown { try await model.saveSettings(next); if !leaving { dismiss() } }
    }
  }
}

struct RecoveryEditor: View {
  @Environment(IOSAppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var value: AutomationConfiguration
  @State private var url1: String
  @State private var url2: String
  @State private var status1: Int
  @State private var status2: Int
  @State private var body1: String
  @State private var body2: String
  private struct Edits: Equatable { var value: AutomationConfiguration; var urls: [String]; var statuses: [Int]; var bodies: [String] }
  private var edits: Edits { Edits(value: value, urls: [url1, url2], statuses: [status1, status2], bodies: [body1, body2]) }
  // What the page opened with, moved along by each save: leaving saves only when the page differs from it.
  @State private var opened: Edits?
  private var dirty: Bool { opened != nil && edits != opened }
  private var valid: Bool { (try? model.validatePreferences(updated)) != nil }
  private var updated: IOSPreferences {
    var next = model.preferences; next.automation = value
    if value.enabled {
      next.automation.targets = [.init(id: "primary", url: url1, expectedStatus: status1, expectedBody: body1)]
      if value.policy != .fixed { next.automation.targets.append(.init(id: "secondary", url: url2, expectedStatus: status2, expectedBody: body2)) }
    }
    next.automation.subscriptionID = model.selected?.subscriptionID ?? ""
    next.automation.russianEntryNodeIDs = value.nodeIDs.filter { id in model.nodes.first { $0.id == id }.map { ServerLocation.russianEntry($0.name) } == true }
    return next
  }
  /// `stay` is the switch saving itself with the page as it stands: the page stays open, and a refused switch goes back.
  private func save(leaving: Bool, stay: Bool = false) {
    let next = updated, sent = edits
    model.launchShown({ try model.savePreferences(next); opened = sent; if !leaving && !stay { dismiss() } },
                      failed: { if stay, value.enabled == sent.value.enabled { value.enabled.toggle() } })
  }
  init(initial: AutomationConfiguration) {
    _value = State(initialValue: initial)
    _url1 = State(initialValue: initial.targets.first?.url ?? "https://www.gstatic.com/generate_204")
    _url2 = State(initialValue: initial.targets.dropFirst().first?.url ?? "")
    _status1 = State(initialValue: initial.targets.first?.expectedStatus ?? 204)
    _status2 = State(initialValue: initial.targets.dropFirst().first?.expectedStatus ?? 204)
    _body1 = State(initialValue: initial.targets.first?.expectedBody ?? "")
    _body2 = State(initialValue: initial.targets.dropFirst().first?.expectedBody ?? "")
  }
  var body: some View {
    AppForm {
      Section {
        Toggle("Automatic recovery", isOn: $value.enabled)
        Picker("Policy", selection: $value.policy) { Text("Keep selected server").tag(AutomationConfiguration.Policy.fixed); Text("Ordered fallback").tag(AutomationConfiguration.Policy.orderedFallback); Text("Lowest latency on Connect").tag(AutomationConfiguration.Policy.lowestLatency) }.accessibilityIdentifier("recoveryPolicy")
      } footer: { Text("Recovery runs while the app is open, with at most 6 attempts over 2 minutes. Verified traffic checks and fallback require Include all networks, both default routes, and no bypass or provider routing rules. Keep selected server can reconnect with custom routes without claiming verified traffic. On Demand in General settings controls iOS background reconnects.") }
      if value.policy == .lowestLatency { Section { Text("Connect compares up to 10 allowed servers for at most one minute, using the median of three proxy tests. It keeps a healthy connection and uses allowed backups after a confirmed outage. Disconnect before comparing again.").font(.footnote).foregroundStyle(AppPalette.secondary) } }
      Section {
        ForEach(value.nodeIDs, id: \.self) { id in
          let node = model.nodes.first { $0.id == id }
          HStack {
            VStack(alignment: .leading) {
              Text(node?.name ?? String(localized: "Unavailable server"))
              if let group = model.subscriptions.first(where: { $0.id == node?.subscriptionID }) { Text(group.name).font(.caption).foregroundStyle(AppPalette.secondary) }
            }
            Spacer(); Button("Remove", systemImage: "minus.circle") { value.nodeIDs.removeAll { $0 == id } }.labelStyle(.iconOnly)
          }
        }.onMove { value.nodeIDs.move(fromOffsets: $0, toOffset: $1) }
        Menu("Add server") {
          ForEach(model.subscriptions) { group in
            Section(group.name) {
              ForEach(group.nodes.filter { !value.nodeIDs.contains($0.id) && $0.format != "telegram" }) { node in
                Button(node.name) { if value.policy == .fixed { value.nodeIDs = [node.id] } else { value.nodeIDs.append(node.id) } }
              }
            }
          }
        }
      } header: { Text(value.policy == .fixed ? String(localized: "Server") : String(localized: "Allowed servers in fallback order")) } footer: {
        if value.policy != .fixed { Text("Servers may come from any subscription. Choosing another server by hand makes it the primary and keeps these backups. When a server on UDP or a port other than 443 stops answering, TCP 443 backups go first. If only Russian-entry servers get through, they go first.") }
      }
      Section("Primary health target") { target(url: $url1, status: $status1, body: $body1) }
      if value.policy != .fixed { Section { target(url: $url2, status: $status2, body: $body2) } header: { Text("Independent second target") } footer: { Text("Use a different hostname. Only repeated classified timeouts at both targets permit cycling through your allowed servers.") } }
      if dirty && !valid { InvalidDraftNote() }
    }.toolbar { ToolbarItem(placement: .topBarTrailing) { EditButton() } }
    .draftPage("Automatic recovery", dirty: dirty, valid: valid, cancel: { opened = edits; dismiss() }) { leaving in save(leaving: leaving) }
    .onAppear { if opened == nil { opened = edits } }
    .task(id: value.enabled) {
      // Recovery turned on before its servers are chosen cannot be saved yet: the switch then waits with the rest of the page.
      guard let opened, value.enabled != opened.value.enabled, valid else { return }
      model.saveStatus = .saving
      try? await Task.sleep(for: autoApplyDelay)
      guard !Task.isCancelled else { return }
      if valid { save(leaving: false, stay: true) } else { model.saveStatus = nil }
    }
  }
  private func target(url: Binding<String>, status: Binding<Int>, body: Binding<String>) -> some View {
    Group { TextField("HTTP or HTTPS URL", text: url).keyboardType(.URL); NumberField(title: "Expected status", value: status); TextField("Expected body (optional)", text: body, axis: .vertical) }.textInputAutocapitalization(.never).autocorrectionDisabled()
  }
}
