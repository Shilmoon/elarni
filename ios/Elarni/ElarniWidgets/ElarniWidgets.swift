import AppIntents
import NetworkExtension
import SwiftUI
import WidgetKit

@main
struct ElarniWidgets: WidgetBundle {
  var body: some Widget { ConnectionControl() }
}

/// Control Center's Elarni toggle: on while the VPN runs or starts.
struct ConnectionControl: ControlWidget {
  var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(kind: ConnectionControlIntent.kind, provider: ConnectionState()) { active in
      ControlWidgetToggle("Elarni", isOn: active, action: ConnectionControlIntent()) { on in
        Label(on ? String(localized: "Connected") : String(localized: "Disconnected"), systemImage: on ? "lock.shield.fill" : "lock.shield")
      }
    }
    .displayName("Elarni VPN")
    .description("Connects to the server selected in Elarni, or disconnects.")
  }
}

struct ConnectionState: ControlValueProvider {
  var previewValue: Bool { false }
  // The app reloads the control when the VPN changes; the extension reads the app's VPN configuration.
  func currentValue() async throws -> Bool {
    try await NETunnelProviderManager.loadAllFromPreferences().contains { [.connected, .connecting, .reasserting].contains($0.connection.status) }
  }
}
