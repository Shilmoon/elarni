import Cocoa
import Darwin
import FlutterMacOS
import UserNotifications

class MainFlutterWindow: NSWindow, UNUserNotificationCenterDelegate {
  private var headlessEngine: FlutterEngine?
  private var catalogOwner: Int32 = -1
  private var tunnelChannel: TunnelMethodChannel?
  private var desktopChannel: FlutterMethodChannel?
  private var statusItem: NSStatusItem?
  private let statusLabel = NSMenuItem(title: "Elarni", action: nil, keyEquivalent: "")
  private let connectItem = NSMenuItem(title: String(localized: "Connect"), action: #selector(desktopConnect), keyEquivalent: "")
  private let disconnectItem = NSMenuItem(title: String(localized: "Disconnect"), action: #selector(desktopDisconnect), keyEquivalent: "")

  override func awakeFromNib() {
#if DEBUG
    // Hosted integration tests own the channel; do not start a second controller.
    if ProcessInfo.processInfo.environment["ELARNI_EXTENSION_TEST_HOST"] == "1" {
      super.awakeFromNib()
      return
    }
#endif
    // The native catalog has one owner, even with different control endpoints.
    catalogOwner = open(NSHomeDirectory() + "/.elarni-owner.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
    guard catalogOwner >= 0, flock(catalogOwner, LOCK_EX | LOCK_NB) == 0 else { exit(1) }
    if ProcessInfo.processInfo.environment["ELARNI_HEADLESS"] == "1" {
      // Retain the signed host's Keychain and NetworkExtension identity, with no view.
      let engine = FlutterEngine(name: "elarni-control", project: nil, allowHeadlessExecution: true)
      headlessEngine = engine
      guard engine.run(withEntrypoint: nil) else { exit(1) }
      tunnelChannel = TunnelMethodChannel(messenger: engine.binaryMessenger)
      super.awakeFromNib()
      return
    }
#if DEBUG && ELARNI_DIAGNOSTICS
    let collecting = DiagnosticLog.start(role: "host")
    DiagnosticLog.record("app_state", ["launched": 1])
#endif
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    tunnelChannel = TunnelMethodChannel(messenger: flutterViewController.engine.binaryMessenger)
    installDesktop(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
    makeKeyAndOrderFront(nil)
#if DEBUG && ELARNI_DIAGNOSTICS
    // Wait until the main nib has finished installing the application menu.
    DispatchQueue.main.async { [weak self] in self?.installDiagnostics(collecting: collecting) }
#endif
  }

#if DEBUG && ELARNI_DIAGNOSTICS
  private func installDiagnostics(collecting: Bool) {
    let menu = NSMenu(title: "Diagnostics")
    let status = NSMenuItem(title: collecting ? "Recording locally · 72 hours / 256 MB" : "Recorder unavailable", action: nil, keyEquivalent: "")
    menu.addItem(status)
    for (title, action, key) in [("Mark a Stall", #selector(markDiagnosticStall), "m"), ("Export Diagnostic Logs…", #selector(exportDiagnosticLogs), "e")] {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
      item.keyEquivalentModifierMask = [.command, .option, .shift]
      item.target = self
      menu.addItem(item)
    }
    let item = NSMenuItem(title: "Diagnostics", action: nil, keyEquivalent: "")
    item.submenu = menu
    NSApp.mainMenu?.addItem(item)
  }

  @objc private func markDiagnosticStall() {
    Task { @MainActor in
      do {
        try await DiagnosticLog.perform("mark")
        _ = await tunnelChannel?.diagnosticProvider(mark: true)
      } catch { diagnosticFailure() }
    }
  }

  @objc private func exportDiagnosticLogs() {
    let panel = NSSavePanel()
    panel.title = "Export Diagnostic Logs"
    panel.nameFieldStringValue = "Elarni-diagnostics-\(Int(Date().timeIntervalSince1970)).zip"
    panel.message = "Local connection events and counters. Includes up to 72 hours, within the 256 MB retention budget."
    panel.beginSheetModal(for: self) { [weak self] result in
      guard let self, result == .OK, let destination = panel.url else { return }
      Task { @MainActor in
        _ = await self.tunnelChannel?.diagnosticProvider(mark: false)
        do {
          try await DiagnosticLog.perform("export", destination: destination)
          NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch { self.diagnosticFailure() }
      }
    }
  }

  private func diagnosticFailure() {
    let alert = NSAlert()
    alert.messageText = "Diagnostics could not be saved"
    alert.informativeText = "Check free disk space and choose a new export filename. Existing files are preserved."
    alert.beginSheetModal(for: self)
  }
#endif

  private func installDesktop(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "com.elarni/desktop", binaryMessenger: messenger)
    desktopChannel = channel
    UNUserNotificationCenter.current().delegate = self
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    statusItem = item
    let menuMark = NSImage(named: "ElarniMenuMark")
    menuMark?.isTemplate = true
    menuMark?.size = NSSize(width: 18, height: 18)
    item.button?.image = menuMark
    if item.button?.image == nil { item.button?.title = "E" }
    item.button?.toolTip = "Elarni"
    item.button?.setAccessibilityLabel("Elarni")
    let menu = NSMenu()
    menu.autoenablesItems = false
    statusLabel.isEnabled = false
    menu.addItem(statusLabel); menu.addItem(.separator())
    let show = NSMenuItem(title: String(localized: "Show Elarni"), action: #selector(desktopShow), keyEquivalent: "")
    show.target = self; menu.addItem(show)
    connectItem.target = self; disconnectItem.target = self
    connectItem.isEnabled = false; disconnectItem.isEnabled = false
    menu.addItem(connectItem); menu.addItem(disconnectItem); menu.addItem(.separator())
    let quit = NSMenuItem(title: String(localized: "Quit Elarni"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
    quit.target = NSApp; menu.addItem(quit)
    item.menu = menu
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(FlutterError(code: "unavailable", message: "Desktop unavailable.", details: nil)) }
      let arguments = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "routingApplications":
        var applications: [String: [String: Any]] = [:]
        for app in NSWorkspace.shared.runningApplications {
          if let url = app.bundleURL ?? app.executableURL,
             let entry = self.routingApplication(url, name: app.localizedName) {
            applications[entry["process"] as! String] = entry
          }
        }
        // Application directories only; do not walk user documents or app contents.
        for directory in FileManager.default.urls(for: .applicationDirectory, in: .allDomainsMask) {
          let children = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
          for url in children {
            if url.pathExtension == "app", let entry = self.routingApplication(url) {
              applications[entry["process"] as! String] = entry
            } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
              for nested in (try? FileManager.default.contentsOfDirectory(at: url,
                includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [] where nested.pathExtension == "app" {
                if let entry = self.routingApplication(nested) { applications[entry["process"] as! String] = entry }
              }
            }
          }
        }
        if let selected = arguments["processes"] as? [String], selected.count <= 256 {
          for path in selected where path.hasPrefix("/") && path.utf8.count <= 1024 {
            if let entry = self.routingApplication(URL(fileURLWithPath: path)) {
              let process = entry["process"] as! String
              if applications[process] == nil { applications[process] = entry }
            }
          }
        }
        result(Array(applications.values))
      case "pickRoutingApplications":
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose applications or executables")
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask).first
        guard panel.runModal() == .OK else { return result([]) }
        let entries = panel.urls.compactMap { self.routingApplication($0) }
        guard entries.count == panel.urls.count, entries.count <= 256 else {
          return result(FlutterError(code: "invalid_applications", message: "Select up to 256 applications or executable files.", details: nil))
        }
        result(entries)
      case "getPreferences":
        result(UserDefaults.standard.string(forKey: "desktopPreferencesV1") ?? "{}")
      case "setPreferences":
        guard let json = arguments["json"] as? String, json.utf8.count <= 32768 else {
          return result(FlutterError(code: "invalid_request", message: "Invalid desktop preferences.", details: nil))
        }
        UserDefaults.standard.set(json, forKey: "desktopPreferencesV1")
        result(nil)
      case "setStatus":
        guard let state = arguments["state"] as? String, state.utf8.count <= 32,
              state.allSatisfy({ $0.isASCII && ($0.isLowercase || $0 == " " || $0 == ",") }) else {
          return result(FlutterError(code: "invalid_request", message: "Invalid desktop status.", details: nil))
        }
        self.statusLabel.title = "Elarni — \(String(localized: String.LocalizationValue(state)))"
        self.statusItem?.button?.toolTip = self.statusLabel.title
        self.connectItem.isEnabled = arguments["canConnect"] as? Bool == true
        self.disconnectItem.isEnabled = arguments["canDisconnect"] as? Bool == true
        result(nil)
      case "requestNotifications":
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { allowed, _ in
          DispatchQueue.main.async { result(allowed) }
        }
      case "showExpiryReminder":
        guard let count = arguments["count"] as? Int, (1...1024).contains(count) else {
          return result(FlutterError(code: "invalid_request", message: "Invalid reminder.", details: nil))
        }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Subscription expires soon")
        content.body = String(localized: "\(count) subscription(s) expire within three days. Open Elarni for details.")
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "subscription-expiry", content: content, trigger: nil)) { error in
          DispatchQueue.main.async {
            result(error == nil ? nil : FlutterError(code: "notifications_failed", message: "Notification unavailable.", details: nil))
          }
        }
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  private func routingApplication(_ url: URL, name: String? = nil) -> [String: Any]? {
    let bundle = url.pathExtension == "app" ? Bundle(url: url) : nil
    guard url.pathExtension == "app" ? bundle?.executableURL != nil :
      ((try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true &&
       FileManager.default.isExecutableFile(atPath: url.path)) else { return nil }
    let path = url.path + (bundle == nil ? "" : "/")
    guard path.utf8.count <= 1024, !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
    var entry: [String: Any] = ["name": name ?? (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
      ?? url.deletingPathExtension().lastPathComponent, "process": path]
    // Fixed-size native artwork; never include icons in saved routing profiles.
    let image = NSWorkspace.shared.icon(forFile: url.path)
    if let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap) {
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = context
      context.cgContext.clear(CGRect(x: 0, y: 0, width: 64, height: 64))
      image.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64), from: .zero,
        operation: .copy, fraction: 1)
      NSGraphicsContext.restoreGraphicsState()
      if let png = bitmap.representation(using: .png, properties: [:]), png.count <= 65536 {
        entry["iconPng"] = FlutterStandardTypedData(bytes: png)
      }
    }
    return entry
  }

  @objc private func desktopShow() {
    deminiaturize(nil); makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
  }

  @objc func showPreferences(_ sender: Any?) {
    desktopShow()
    desktopChannel?.invokeMethod("action", arguments: "settings")
  }

  func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    completionHandler([.banner])
  }
  @objc private func desktopConnect() { desktopChannel?.invokeMethod("action", arguments: "connect") }
  @objc private func desktopDisconnect() { desktopChannel?.invokeMethod("action", arguments: "disconnect") }
}
