import AppIntents

/// The Control Center toggle's action, built into the app and the widget extension. As a Live Activity
/// intent it runs in the app, which connects and stops as its own buttons do.
struct ConnectionControlIntent: SetValueIntent, LiveActivityIntent {
  static let kind = "com.elarni.ios.connection"
  static let title: LocalizedStringResource = "Elarni VPN"
  // Shortcuts lists Connect, Disconnect and Toggle instead.
  static let isDiscoverable = false
  @Parameter(title: "Connected") var value: Bool
  init() {}
  @MainActor func perform() async throws -> some IntentResult {
#if !ELARNI_WIDGET
    try await ConnectionIntents.set(value)
#endif
    return .result()
  }
}
