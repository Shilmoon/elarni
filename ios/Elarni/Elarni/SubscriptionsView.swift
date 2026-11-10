import SwiftUI

struct SubscriptionsView: View {
  @Environment(IOSAppModel.self) private var model
  var body: some View {
    AppList {
      if model.subscriptions.isEmpty { AppEmptyState(title: "No subscriptions", systemImage: "rectangle.stack", message: "Import a provider link or local server configuration.") }
      ForEach(ordered) { source in
        NavigationLink { SubscriptionDetailView(sourceID: source.id) } label: {
          HStack(alignment: .top, spacing: 12) {
            Image(systemName: source.local ? "folder" : "checkmark.shield").font(.title3).foregroundStyle(AppPalette.secondary).frame(width: 24).padding(.top, 2)
            VStack(alignment: .leading, spacing: 8) {
              HStack { Text(source.name).font(.headline); if model.preferences.pinned.contains(source.id) { Image(systemName: "pin.fill").font(.caption).foregroundStyle(AppPalette.secondary) } }
              let count = String(localized: "\(source.nodes.count) servers")
              // A working provider shows only its server count; one that needs attention says why.
              Group {
                if source.local { Text("\(count) · Local group") }
                else if source.attention.needed { Text("\(count) · \(Text(source.statusText).fontWeight(.medium).foregroundStyle(source.attention.severe ? Color.red : AppPalette.warning))") }
                else { Text(count) }
              }.font(.subheadline).foregroundStyle(AppPalette.secondary)
              if !source.local { QuotaView(source: source) }
            }
          }.padding(.vertical, 6)
        }
      }
    }.navigationTitle("Subscriptions")
    .refreshable { await model.refreshAll() }
  }
  private var ordered: [ServerSubscription] {
    model.subscriptions.sorted { model.preferences.pinned.contains($0.id) && !model.preferences.pinned.contains($1.id) }
  }
}

struct SubscriptionDetailView: View {
  @Environment(IOSAppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openURL) private var openURL
  let sourceID: String
  @State private var renaming = false
  @State private var name = ""
  @State private var deleting = false
  @State private var share: SharedText?
  @State private var pickingShare = false
  @State private var search = ""
  @State private var showingHidden = false
  @State private var deviceID: String?
  @State private var resettingDevice = false
  @State private var selecting = false
  @State private var chosen = Set<String>()
  @State private var removingChosen = false
  private var source: ServerSubscription? { model.subscriptions.first { $0.id == sourceID } }
  private var chosenCount: Int { source?.nodes.filter { chosen.contains($0.id) }.count ?? 0 }
  private func servers(_ count: Int) -> String { String(localized: "\(count) servers") }
  // Which interval schedules this subscription, as on desktop and Android.
  private func refreshes(_ source: ServerSubscription) -> (value: String, caption: String) {
    if let hours = (source.raw["fetchOptions"] as? [String: String])?["refreshHours"].flatMap(Int.init) { return (String(localized: "Every \(hours) h"), String(localized: "Your override")) }
    if let hours = source.metadata["updateIntervalHours"] as? Int, hours > 0 { return (String(localized: "Every \(hours) h"), String(localized: "Set by your provider")) }
    return (String(localized: "Every \(model.preferences.autoUpdateHours) h"), String(localized: "App setting"))
  }
  var body: some View {
    AppList {
      if let source {
        Section {
          LabeledContent("Servers", value: source.nodes.count.formatted())
          LabeledContent("Status", value: source.statusText)
          if let last = source.lastRefresh { LabeledContent("Updated") { Text(last, style: .relative) } }
          if let due = source.raw["nextRefreshAt"] as? Double { LabeledContent("Next refresh") { Text(Date(timeIntervalSince1970: due), style: .relative) } }
          if !source.local {
            let interval = refreshes(source)
            NavigationLink { SubscriptionFetchView(source: source) } label: {
              LabeledContent("Refreshes") {
                VStack(alignment: .trailing) { Text(interval.value); Text(interval.caption).font(.caption) }
              }
            }
          }
          if let error = source.refreshErrorText { Text(error).foregroundStyle(AppPalette.secondary) }
          if !source.local { QuotaView(source: source) }
        }
        if !source.local { Section {
          ForEach([("announcement", String(localized: "Notice")), ("directiveNotice", String(localized: "Configuration notice")), ("dnsNotice", "DNS"), ("bannerText", String(localized: "Message"))], id: \.0) { key, title in
            if let text = source.metadata[key] as? String, !text.isEmpty { VStack(alignment: .leading, spacing: 4) { Text(title).font(.caption).foregroundStyle(AppPalette.secondary); Text(text) } }
          }
          ForEach([("enabled", String(localized: "Account enabled")), ("online", String(localized: "Online"))], id: \.0) { key, title in
            if let value = source.metadata[key] as? Bool { LabeledContent(title, value: value ? String(localized: "Yes") : String(localized: "No")) }
          }
          LabeledContent("Device ID") {
            VStack(alignment: .trailing) {
              Text(deviceID.map { "\($0.prefix(8))…\($0.suffix(4))" } ?? String(localized: "Loading")).monospaced()
              if source.metadata["deviceRegistered"] as? Bool == true { Text("Registered · set by your provider").font(.caption) }
            }
          }
          HStack {
            Button("Copy", systemImage: "doc.on.doc") {
              if let deviceID { UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: deviceID]], options: [.localOnly: true]) }
            }.disabled(deviceID == nil)
            Spacer()
            Button("Reset device ID", role: .destructive) { resettingDevice = true }.disabled(model.busy)
          }.buttonStyle(.borderless)
          if source.metadata["routingEnabled"] as? Bool == false { LabeledContent("Provider routing", value: String(localized: "Disabled")) }
          if source.metadata["hideSettings"] as? Bool == true { Text("Your provider asks you to keep its settings. You can still change them.").font(.footnote).foregroundStyle(AppPalette.secondary) }
          ForEach(source.actions.filter { ["support", "account", "banner"].contains($0) }, id: \.self) { action in
            Button(action == "banner" ? source.metadata["bannerButtonText"] as? String ?? String(localized: "Open provider page") : action.capitalized, systemImage: "arrow.up.right") {
              do { openURL(try model.providerURL(source, action: action)) } catch { model.show(error) }
            }
          }
        } header: { Text("Provider") } footer: {
          Text("Elarni sends each provider a different device ID, made from a random key on this device. Providers can't link your IDs to each other. A renamed subscription, a changed refresh interval and your routing choice stay after a refresh.")
        } }
        Section {
          RoutingAssignment(sourceID: source.id)
        } header: { Text("Routing") } footer: {
          if model.routingProfiles.first(where: { $0.id == model.assignments[source.id] })?.owner == source.id { Text("Set by your provider") }
        }
        Section {
          if !source.local {
            Button("Refresh", systemImage: "arrow.clockwise") { model.launch { try await model.refresh(source.id) } }
            Picker("Download format", selection: Binding(get: { source.format }, set: { value in model.launch { try await model.refresh(source.id, format: value) } })) {
              // As on Android: only formats the provider offers, and the one in use.
              ForEach([("source", String(localized: "Original")), ("raw", String(localized: "Share links")), ("json", "Xray JSON"), ("clash", "Clash")].filter { $0.0 == "source" || $0.0 == source.format || source.actions.contains($0.0) }, id: \.0) { Text($0.1).tag($0.0) }
            }
            NavigationLink("Download options") { SubscriptionFetchView(source: source) }
          }
          Toggle("Pin subscription", isOn: Binding(get: { model.preferences.pinned.contains(source.id) }, set: { value in
            var next = model.preferences; next.pinned.removeAll { $0 == source.id }; if value { next.pinned.append(source.id) }
            do { try model.savePreferences(next) } catch { model.show(error) }
          }))
          Button("Rename", systemImage: "pencil") { name = source.name; renaming = true }
          Button("Share", systemImage: "square.and.arrow.up") {
            // A local group has no subscription link; its servers are shared as links instead.
            if source.local { pickingShare = true; return }
            do { share = SharedText(title: source.name, text: try model.share(id: source.id, subscription: true)) } catch { model.show(error) }
          }
          Button("Delete subscription", role: .destructive) { deleting = true }
        }.disabled(model.busy)
        Section {
          let visible = source.nodes.filter { $0.matches(search, provider: source.name) }
          if selecting {
            HStack {
              Text("\(chosenCount) selected").foregroundStyle(AppPalette.secondary)
              Spacer()
              Button("Cancel") { selecting = false; chosen = [] }.buttonStyle(.borderless).frame(minHeight: 44)
            }
            // The selected server stays, as the store requires.
            Button("Select unreachable") {
              chosen.formUnion(visible.filter { $0.id != model.selectedID && model.probes[$0.id]?.status == "Failed" }.map(\.id))
            }
            Button(source.local ? String(localized: "Delete \(servers(chosenCount))") : String(localized: "Hide \(servers(chosenCount))"), role: .destructive) { removingChosen = true }
              .disabled(model.busy || chosenCount == 0 || chosenCount >= source.nodes.count)
          } else if model.testingIDs.isEmpty {
            Button("Test servers", systemImage: "waveform.path.ecg") { model.testServers(visible) }.disabled(model.busy || model.vpn.active || visible.isEmpty)
            if source.nodes.count > 1 { Button("Select servers", systemImage: "checkmark.circle") { selecting = true; chosen = [] }.disabled(model.busy) }
          } else { Button("Cancel tests", role: .cancel) { model.cancelTests() } }
          ForEach(visible) { node in
            if selecting {
              Button {
                if chosen.remove(node.id) == nil { chosen.insert(node.id) }
              } label: {
                HStack(spacing: 12) {
                  Image(systemName: chosen.contains(node.id) ? "checkmark.circle.fill" : "circle").font(.title3)
                    .foregroundStyle(chosen.contains(node.id) ? appTint(model.preferences.accent) : AppPalette.secondary)
                  ServerRow(node: node, selected: model.selectedID == node.id)
                }
              }.buttonStyle(.plain).disabled(model.selectedID == node.id)
              .accessibilityAddTraits(chosen.contains(node.id) ? .isSelected : [])
              .accessibilityIdentifier("selectServer.\(node.name)")
            } else {
              NavigationLink { ServerDetailView(nodeID: node.id) } label: { ServerRow(node: node, selected: model.selectedID == node.id) }
            }
          }
          if !source.hiddenNodes.isEmpty {
            LabeledContent("Hidden servers · \(source.hiddenNodes.count)") { Button("Show again") { showingHidden = true }.disabled(model.busy) }
          }
        } header: { Text("Servers") } footer: { if model.vpn.active { Text("Disconnect to test these servers.") } }
      }
    }
    .navigationTitle(source?.name ?? String(localized: "Subscription")).navigationBarTitleDisplayMode(.inline)
    // The HTTP host override is part of the ID.
    .task(id: (source?.raw["fetchOptions"] as? [String: String])?["httpHost"] ?? "") {
      if source?.local == false { deviceID = try? model.deviceID(subscriptionID: sourceID) }
    }
    .alert("Reset device ID for \(source?.name ?? "this subscription")?", isPresented: $resettingDevice) {
      Button("Reset", role: .destructive) {
        model.launch { try model.resetDeviceID(subscriptionID: sourceID); deviceID = try model.deviceID(subscriptionID: sourceID) }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      let name = source?.name ?? String(localized: "The provider")
      Text("\(name) will see this device as new. If it limits devices, the new ID needs a free slot, and the old one may hold a slot until \(name) removes it. Your other subscriptions keep their IDs.")
    }
    .searchable(text: $search, prompt: "Search servers")
    .alert("Rename subscription", isPresented: $renaming) {
      TextField("Name", text: $name)
      Button("Save") { if let source { model.launch { try model.rename(source, name: name) } } }
      Button("Cancel", role: .cancel) {}
    }
    .confirmationDialog(source?.local == true ? String(localized: "Delete \(servers(chosenCount))?") : String(localized: "Hide \(servers(chosenCount))?"), isPresented: $removingChosen, titleVisibility: .visible) {
      Button(source?.local == true ? String(localized: "Delete") : String(localized: "Hide"), role: .destructive) {
        guard let source else { return }
        let values = source.nodes.filter { chosen.contains($0.id) }
        model.launch { try model.deleteNodes(values); selecting = false; chosen = [] }
      }
    } message: {
      Text(source?.local == true ? String(localized: "They are removed from \(source?.name ?? String(localized: "this group")).") : String(localized: "They stay hidden after refreshes. Show them again from Hidden servers."))
    }
    .confirmationDialog("Hidden servers", isPresented: $showingHidden, titleVisibility: .visible) {
      ForEach(source?.hiddenNodes ?? []) { hidden in Button(hidden.name) { model.launch { try model.showNode(id: hidden.id) } } }
    } message: { Text("Choose a server to show again.") }
    .confirmationDialog("Delete this subscription and its servers?", isPresented: $deleting, titleVisibility: .visible) {
      Button("Delete subscription", role: .destructive) { if let source { model.launch { try await model.delete(source); dismiss() } } }
    } message: { Text("If it contains the selected server, the VPN will disconnect. Provider routing owned by this subscription is removed too.") }
    .sheet(item: $share) { ShareView(item: $0) }
    .sheet(isPresented: $pickingShare) { if let source { ShareServersView(source: source) } }
  }
}

/// Picks servers of a local group to share as links.
struct ShareServersView: View {
  @Environment(IOSAppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  let source: ServerSubscription
  @State private var chosen = Set<String>()
  @State private var linkable = Set<String>()
  @State private var share: SharedText?
  var body: some View {
    NavigationStack {
      AppList {
        Section {
          ForEach(source.nodes.filter { linkable.contains($0.id) }) { node in
            Button {
              if chosen.remove(node.id) == nil { chosen.insert(node.id) }
            } label: {
              HStack(spacing: 12) {
                Image(systemName: chosen.contains(node.id) ? "checkmark.circle.fill" : "circle").font(.title3)
                  .foregroundStyle(chosen.contains(node.id) ? appTint(model.preferences.accent) : AppPalette.secondary)
                Text(node.name).foregroundStyle(AppPalette.text)
                Spacer()
                Text(node.protocolName.uppercased()).font(.caption).foregroundStyle(AppPalette.secondary)
              }.frame(minHeight: 44).contentShape(.rect)
            }.buttonStyle(.plain)
            .accessibilityAddTraits(chosen.contains(node.id) ? .isSelected : [])
            .accessibilityIdentifier("shareServer.\(node.name)")
          }
        } footer: {
          Text(String(localized: "Local groups have no subscription link. Choose the servers to share as links.")
            + (linkable.count < source.nodes.count ? String(localized: " Profiles with several outbounds are shared from their own page.") : ""))
        }
      }
      .navigationTitle("Share servers").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button(chosen.count == 1 ? String(localized: "Share 1 link") : String(localized: "Share \(chosen.count) links")) {
            do { share = SharedText(title: source.name, text: try model.shareLinks(source, nodeIDs: Array(chosen))) } catch { model.show(error) }
          }.disabled(chosen.isEmpty)
        }
      }
      .onAppear { linkable = model.linkableNodeIDs(source) }
      .sheet(item: $share) { ShareView(item: $0) }
      .appErrors()
    }
  }
}

struct SubscriptionFetchView: View {
  @Environment(IOSAppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  let source: ServerSubscription
  @State private var hosts: String
  @State private var refresh: String
  @State private var agent: String
  @State private var address: String
  @State private var httpHost: String
  @State private var length: String
  @State private var interval: String
  private var fields: [String] { [hosts, refresh, agent, address, httpHost, length, interval] }
  // What the page opened with, moved along by each save: leaving saves only when the page differs from it.
  @State private var opened: [String]?
  private var dirty: Bool { opened != nil && fields != opened }
  init(source: ServerSubscription) {
    self.source = source
    let options = source.raw["fetchOptions"] as? [String: String] ?? [:]
    _hosts = State(initialValue: (source.raw["fallbackHosts"] as? [String] ?? []).joined(separator: "\n"))
    _refresh = State(initialValue: options["refreshHours"] ?? "")
    _agent = State(initialValue: options["userAgent"] ?? "")
    _address = State(initialValue: options["connectAddress"] ?? "")
    _httpHost = State(initialValue: options["httpHost"] ?? "")
    _length = State(initialValue: options["fragmentLength"] ?? "")
    _interval = State(initialValue: options["fragmentInterval"] ?? "")
  }
  var body: some View {
    AppForm {
      Section {
        TextField("Refresh every (hours) · override", text: $refresh).keyboardType(.numberPad)
      } footer: {
        Text((source.metadata["updateIntervalHours"] as? Int).map { String(localized: "Leave empty to follow the provider (\($0) h). 1–168.") }
          ?? String(localized: "Leave empty to follow the app setting (\(model.preferences.autoUpdateHours) h). 1–168."))
      }
      Section { LinesEditor(title: "Fallback hosts", text: $hosts) } footer: { Text("One hostname per line, up to 8. Your subscription token will also be sent to these hosts. Add only hosts you trust.") }
      Section {
        TextField("User agent", text: $agent)
      } footer: { Text("Leave empty to identify as Elarni. Some providers serve only the clients they recognize.") }
      .textInputAutocapitalization(.never).autocorrectionDisabled()
      Section("Transport overrides") {
        TextField("Connect address", text: $address); TextField("HTTP Host", text: $httpHost)
        TextField("Fragment length", text: $length); TextField("Fragment interval", text: $interval)
      }.textInputAutocapitalization(.never).autocorrectionDisabled()
    }.onAppear { if opened == nil { opened = fields } }
    .draftPage("Download options", dirty: dirty, valid: true, cancel: { opened = fields; dismiss() }) { leaving in
      let sent = fields
      model.launch {
        var options: [String: Any] = ["fallbackHosts": lines(hosts)]
        for (key, value) in [("refreshHours", refresh), ("userAgent", agent), ("connectAddress", address), ("httpHost", httpHost), ("fragmentLength", length), ("fragmentInterval", interval)] where !value.isEmpty { options[key] = value }
        try model.updateFetch(source.id, options: options); opened = sent; if !leaving { dismiss() }
      }
    }
  }
}

struct RoutingAssignment: View {
  @Environment(IOSAppModel.self) private var model
  let sourceID: String
  var body: some View {
    Picker("Routing profile", selection: Binding(get: { model.assignments[sourceID] ?? "" }, set: { value in
      model.launch { try await model.editRouting { _ = try $0.assign(subscriptionID: sourceID, profileID: value.isEmpty ? nil : value) } }
    })) {
      Text("Provider defaults").tag("")
      ForEach(model.routingProfiles) { Text($0.name).tag($0.id) }
    }.disabled(model.busy)
  }
}

func lines(_ text: String) -> [String] {
  var seen = Set<String>()
  return text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && seen.insert($0).inserted }
}
