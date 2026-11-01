import AppIntents

/// Shortcuts, Siri and the Control Center toggle connect and stop through the app's own commands.
@MainActor
enum ConnectionIntents {
  static func set(_ connected: Bool) async throws {
    let model = IOSAppModel.shared
    await model.start()
    // A VPN that runs or starts already stays as it is.
    if connected && model.vpn.active { return }
    model.errorMessage = nil
    if connected { await model.connect() } else { await model.disconnect() }
    if let message = model.errorMessage { throw ConnectionIntentError(message: message) }
  }
}

struct ConnectionIntentError: Error, CustomLocalizedStringResourceConvertible {
  let message: String
  var localizedStringResource: LocalizedStringResource { "\(message)" }
}

struct ConnectIntent: AppIntent {
  static let title: LocalizedStringResource = "Connect Elarni"
  static let description = IntentDescription("Connects to the server selected in Elarni.")
  @MainActor func perform() async throws -> some IntentResult { try await ConnectionIntents.set(true); return .result() }
}

struct DisconnectIntent: AppIntent {
  static let title: LocalizedStringResource = "Disconnect Elarni"
  static let description = IntentDescription("Disconnects Elarni and keeps On Demand from reconnecting it.")
  @MainActor func perform() async throws -> some IntentResult { try await ConnectionIntents.set(false); return .result() }
}

struct ToggleConnectionIntent: AppIntent {
  static let title: LocalizedStringResource = "Toggle Elarni"
  static let description = IntentDescription("Disconnects Elarni when it runs, and connects it otherwise.")
  @MainActor func perform() async throws -> some IntentResult {
    await IOSAppModel.shared.start()
    try await ConnectionIntents.set(!IOSAppModel.shared.vpn.active)
    return .result()
  }
}

struct ElarniShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(intent: ConnectIntent(), phrases: ["Connect \(.applicationName)"], shortTitle: "Connect", systemImageName: "lock.shield")
    AppShortcut(intent: DisconnectIntent(), phrases: ["Disconnect \(.applicationName)"], shortTitle: "Disconnect", systemImageName: "lock.open")
    AppShortcut(intent: ToggleConnectionIntent(), phrases: ["Toggle \(.applicationName)"], shortTitle: "Toggle", systemImageName: "arrow.triangle.2.circlepath")
  }
}
