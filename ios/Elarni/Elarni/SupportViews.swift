import SwiftUI
import UniformTypeIdentifiers

struct BackupView: View {
  @Environment(IOSAppModel.self) private var model
  @State private var password = ""
  @State private var confirmation = ""
  @State private var restoreText: String?
  @State private var importing = false
  @State private var exporting = false
  @State private var confirmingRestore = false
  @State private var repairing = false
  @State private var document = TextFile("")
  var body: some View {
    AppForm {
      Section {
        SecureField("Backup password", text: $password).textContentType(.newPassword)
        SecureField("Confirm password for export", text: $confirmation).textContentType(.newPassword)
      } footer: { Text("Use a password of 12–1,024 UTF-8 bytes. Keep it safe: a lost password cannot be recovered.") }
      Section {
        Button("Create encrypted backup", systemImage: "square.and.arrow.up") {
          model.launch {
            guard password == confirmation else { throw IOSAppError.invalidSettings }
            document = TextFile(try await model.exportBackup(password: password)); exporting = true
            password = ""; confirmation = ""
          }
        }.disabled(model.busy || password.utf8.count < 12 || password.utf8.count > 1024 || password != confirmation)
        Button("Restore backup", systemImage: "square.and.arrow.down") { importing = true }.disabled(model.busy || model.vpn.active)
        if restoreText != nil {
          Label("Backup selected", systemImage: "doc.badge.checkmark")
          Button("Replace with backup", role: .destructive) { confirmingRestore = true }.disabled(model.busy || model.vpn.active || password.isEmpty)
        }
      } footer: { Text("Backups work with the desktop app and contain subscriptions, server credentials, favorites, selection, and routing. They exclude tunnel settings, listener credentials, and test history. Restore replaces the catalog, disables automatic recovery, and requests new source approvals. Disconnect first.") }
      Section {
        Button("Repair VPN setup", role: .destructive) { repairing = true }.disabled(model.busy || model.vpn.active)
      } header: { Text("Connection repair") } footer: { Text("Repair removes only Elarni’s saved iOS VPN configuration. Your catalog and credentials remain. Disconnect first, then connect afterward to create the configuration again.") }
    }.navigationTitle("Backup and repair").navigationBarTitleDisplayMode(.inline)
    .confirmationDialog("Remove Elarni’s saved VPN configuration?", isPresented: $repairing, titleVisibility: .visible) {
      Button("Repair configuration", role: .destructive) { model.launch { try await model.repair() } }
    }
    .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .plainText, .json]) { result in
      do { restoreText = try IOSImport.readText(result.get(), limit: 12 * 1024 * 1024) } catch { model.show(error) }
    }
    .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "Elarni-backup") { result in
      if case .failure(let error) = result { model.show(error) }
      document = TextFile("")
    }
    .confirmationDialog("Replace your current subscriptions and routing?", isPresented: $confirmingRestore, titleVisibility: .visible) {
      Button("Replace with backup", role: .destructive) { model.launch {
        guard let restoreText else { throw IOSAppError.invalidFile }
        try await model.restoreBackup(text: restoreText, password: password)
        self.restoreText = nil; password = ""; confirmation = ""
        model.notice = String(localized: "Backup restored. Check your server selection and routing before connecting.")
      } }
    }
  }
}

struct TroubleshootingView: View {
  @Environment(IOSAppModel.self) private var model
  @State private var repairing = false
  @State private var diagnostics: SharedText?
  @State private var recording = RecordingFile()
  @State private var savingRecording = false
  var body: some View {
    AppList {
      Section("Connection") {
        LabeledContent("iOS status", value: model.vpn.stateLabel)
        if let state = model.vpn.provider["state"] as? String { LabeledContent("Provider state", value: state) }
        if let backend = model.vpn.provider["backend"] as? String { LabeledContent("Backend", value: backend) }
        if let shared = model.vpn.provider["sharedKeychainResolved"] as? Bool { LabeledContent("Shared credentials", value: shared ? String(localized: "Accessible") : String(localized: "Unavailable")) }
        if let date = model.lastCheck { LabeledContent("Last check") { Text(date, style: .relative) } }
        Text(model.recoveryStatus).foregroundStyle(AppPalette.secondary)
        if model.preferences.automation.enabled && model.whitelistMode {
          Text("Whitelist mode: Russian-entry servers first").foregroundStyle(AppPalette.secondary)
        }
      }
      Section {
        Button("Refresh status", systemImage: "arrow.clockwise") { model.launch { try await model.vpn.load(); try await model.vpn.refreshProvider() } }.disabled(model.busy)
        Button("Test selected server", systemImage: "waveform.path.ecg") { if let node = model.selected { model.testServers([node]) } }.disabled(model.selected == nil || model.busy)
        if !model.testingIDs.isEmpty { Button("Cancel tests") { model.cancelTests() } }
        Button(model.vpn.active ? String(localized: "Disconnect") : String(localized: "Retry connection")) { Task { if model.vpn.active { await model.disconnect() } else { await model.connect() } } }
          .disabled(!model.vpn.active && model.selected == nil)
        Button("Export diagnostics", systemImage: "square.and.arrow.up") { do { diagnostics = SharedText(title: String(localized: "Diagnostics"), text: try model.diagnostics()) } catch { model.show(error) } }
        NavigationLink("Logs") { LogsView() }
      }
      if !model.recentIssues.isEmpty {
        Section("Recent issues") {
          ForEach(model.recentIssues.reversed()) { issue in
            VStack(alignment: .leading, spacing: 4) {
              Text(issue.message)
              Text(issue.date, format: .relative(presentation: .named)).font(.caption).foregroundStyle(AppPalette.secondary)
            }
          }
        }
      }
      TrafficSection()
#if ELARNI_RECORDING
      Section {
        Button("Mark a problem now", systemImage: "flag") { model.launch { try await model.markRecording() } }
          .disabled(model.settings.recordDiagnostics != true)
        Button("Save recording as ZIP", systemImage: "square.and.arrow.up") {
          model.launch { recording = RecordingFile(url: try await model.exportRecording()); savingRecording = true }
        }
      } header: { Text("Connection recording") } footer: { Text("Turn on Record connection diagnostics in Advanced settings, reproduce the problem, mark it, then save the recording for support.") }
#endif
      Section {
        Button("Repair VPN configuration", role: .destructive) { repairing = true }.disabled(model.vpn.active || model.busy)
      } footer: { Text("Repair removes only this app’s saved iOS VPN configuration. Your catalog and credentials remain. Connect afterward to create the configuration again.") }
      Section("If a connection fails") {
        Text("Confirm the subscription is current, choose another server, and check its IP preference. If a test fails, verify the HTTP target and expected response in Server tests.")
        Text("If iOS asks, allow the VPN configuration. Camera access is needed only for scanning; local-network permission is needed when accessing a local server or provider.")
        Text("Provider routing can intentionally send some traffic directly. Check routing and excluded networks before interpreting a successful HTTP check as proof that all traffic uses the proxy.")
      }
    }.navigationTitle("Troubleshooting").navigationBarTitleDisplayMode(.inline)
    .sheet(item: $diagnostics) { ShareView(item: $0) }
    .fileExporter(isPresented: $savingRecording, document: recording, contentType: .zip, defaultFilename: "Elarni-recording") { result in
      if case .failure(let error) = result { model.show(error) }
      if let url = recording.url { try? FileManager.default.removeItem(at: url) }
      recording = RecordingFile()
    }
    .confirmationDialog("Remove Elarni’s saved VPN configuration?", isPresented: $repairing, titleVisibility: .visible) {
      Button("Repair configuration", role: .destructive) { model.launch { try await model.repair() } }
    }
  }
}

/// The core log the extension keeps, already redacted, at the level chosen here.
struct LogsView: View {
  @Environment(IOSAppModel.self) private var model
  @State private var level = "warning"
  @State private var lines: [LogLine] = []
  @State private var after: Int64 = 0
  private static let names = ["none": String(localized: "Off"), "error": String(localized: "Error"), "warning": String(localized: "Warning"), "info": String(localized: "Info"), "debug": String(localized: "Debug")]

  var body: some View {
    AppList {
      Section {
        Picker("Level", selection: $level) {
          ForEach(IOSAppModel.logLevels, id: \.self) { Text(Self.names[$0] ?? $0).tag($0) }
        }
        .onChange(of: level) { _, value in do { try model.setLogLevel(value) } catch { model.show(error) } }
      } footer: { Text("Keys, addresses, host names and user names are hidden before a line is kept.") }
      Section {
        if lines.isEmpty {
          Text(level == "none" ? String(localized: "Logging is off. Choose a level to record the core log.") : String(localized: "No log lines yet. The core records them while it runs."))
            .foregroundStyle(AppPalette.secondary)
        }
        ForEach(lines.reversed()) { line in
          VStack(alignment: .leading, spacing: 2) {
            Text("\(line.time.formatted(date: .omitted, time: .standard)) \(line.level.uppercased())")
              .font(.caption).foregroundStyle(AppPalette.secondary)
            Text(line.text).font(.caption.monospaced()).textSelection(.enabled)
          }
        }
      } header: { if !lines.isEmpty { Text("Newest first") } }
    }
    .navigationTitle("Logs").navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        ShareLink(item: shared) { Label("Share", systemImage: "square.and.arrow.up") }.disabled(lines.isEmpty)
      }
    }
    .task {
      level = model.logLevel
      while !Task.isCancelled {
        await refresh()
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  private var shared: String {
    (["Elarni log, level \(level)"] + lines.map { "\($0.time.ISO8601Format()) \($0.level.uppercased()) \($0.text)" })
      .joined(separator: "\n")
  }

  private func refresh() async {
    guard var result = await model.readLogs(after: after) else { return }
    // A restarted extension numbers its lines from one again.
    // shortcut: a new extension that logs past this view's last line between two polls goes unnoticed; add an instance ID to the reply if that matters.
    if ((result["last"] as? NSNumber)?.int64Value ?? 0) < after {
      lines = []
      after = 0
      guard let fresh = await model.readLogs(after: 0) else { return }
      result = fresh
    }
    lines = Array((lines + (result["entries"] as? [[String: Any]] ?? []).compactMap(LogLine.init)).suffix(1000))
    after = lines.last?.id ?? after
  }
}

struct LogLine: Identifiable {
  let id: Int64
  let time: Date
  let level: String
  let text: String

  init?(_ raw: [String: Any]) {
    guard let seq = (raw["seq"] as? NSNumber)?.int64Value, let time = (raw["time"] as? NSNumber)?.doubleValue,
          let level = raw["level"] as? String, let text = raw["text"] as? String else { return nil }
    id = seq
    self.time = Date(timeIntervalSince1970: time / 1000)
    self.level = level
    self.text = text
  }
}

struct SystemInformationView: View {
  @Environment(IOSAppModel.self) private var model
  @State private var diagnostics: SharedText?
  var body: some View {
    AppList {
      Section("Device") {
        LabeledContent("Operating system", value: ProcessInfo.processInfo.operatingSystemVersionString)
        LabeledContent("Model", value: UIDevice.current.model)
        LabeledContent("App architecture", value: "arm64")
        LabeledContent("CPU count", value: ProcessInfo.processInfo.processorCount.formatted())
        LabeledContent("Active CPUs", value: ProcessInfo.processInfo.activeProcessorCount.formatted())
        LabeledContent("Physical memory", value: ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .binary))
        LabeledContent("Low Power Mode", value: ProcessInfo.processInfo.isLowPowerModeEnabled ? String(localized: "On") : String(localized: "Off"))
#if targetEnvironment(simulator)
        Text("Running in Simulator. VPN traffic and device permissions require a signed iPhone build.").foregroundStyle(AppPalette.secondary)
#endif
      }
      Section("Current network path") {
        ForEach(model.networkInfo.keys.sorted(), id: \.self) { key in LabeledContent(LocalizedStringKey(key), value: model.networkInfo[key] ?? "") }
      }
      Section {
        NavigationLink("Troubleshoot connection") { TroubleshootingView() }
        NavigationLink("Logs") { LogsView() }
        Button("Export diagnostics", systemImage: "square.and.arrow.up") { do { diagnostics = SharedText(title: String(localized: "Diagnostics"), text: try model.diagnostics()) } catch { model.show(error) } }
      }
      Section {
        NavigationLink("Licenses and notices") { LicensesView() }
        LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
        LabeledContent("Xray core", value: NativeAPI.xrayVersion)
      }
    }.navigationTitle("System info").navigationBarTitleDisplayMode(.inline)
      .sheet(item: $diagnostics) { ShareView(item: $0) }
  }
}

struct RouteTableView: View {
  @Environment(IOSAppModel.self) private var model
  var body: some View {
    AppList {
      Section("Configured included routes") { ForEach(model.settings.includedRoutes, id: \.self) { route($0) } }
      Section("Configured excluded routes") {
        if model.settings.excludedRoutes.isEmpty { Text("None").foregroundStyle(AppPalette.secondary) }
        ForEach(model.settings.excludedRoutes, id: \.self) { route($0) }
      }
      Section { Text("iOS has no supported system routing-table API. These are Elarni’s configured networks.").font(.footnote).foregroundStyle(AppPalette.secondary) }
    }.navigationTitle("Route table").navigationBarTitleDisplayMode(.inline)
  }

  // VoiceOver skips the slash of "0.0.0.0/0", so it hears the prefix length in words.
  private func route(_ cidr: String) -> some View {
    let parts = cidr.split(separator: "/", maxSplits: 1).map(String.init)
    return Text(cidr).font(.body.monospaced())
      .accessibilityLabel(parts.count == 2 ? String(localized: "\(parts[0]), prefix length \(parts[1])") : cidr)
  }
}

struct ShortcutsView: View {
  @State private var copied: String?
  var body: some View {
    AppList {
      Section {
        Text("In Apple Shortcuts, add a URL action with one of these links, followed by Open URLs. Opening a connection command brings Elarni to the foreground and uses your saved server.")
        ForEach(["connect", "disconnect", "toggle", "status"], id: \.self) { action in
          Button {
            UIPasteboard.general.string = "elarni://\(action)"; copied = action
          } label: {
            LabeledContent(action.capitalized) { Text(copied == action ? String(localized: "Copied") : "elarni://\(action)").font(.caption.monospaced()) }
          }
        }
      } footer: { Text("Disconnect also cancels pending work and disables on-demand reconnect. Import links use the same importer as the clipboard. Subscriptions still request source approval when needed.") }
    }.navigationTitle("Shortcuts").navigationBarTitleDisplayMode(.inline)
  }
}
