import Foundation
import Security
import UserNotifications

enum IOSPlatform {
  static var appGroup: String {
    Bundle.main.object(forInfoDictionaryKey: "ElarniAppGroup") as? String ?? "group.com.elarni.ios"
  }

  static var containerURL: URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
  }

  static func keychainAccessGroup() throws -> String {
    guard let value = Bundle.main.object(forInfoDictionaryKey: "ElarniKeychainGroup") as? String,
          !value.isEmpty, !value.contains("$"), value.hasSuffix(".com.elarni.ios.shared") else {
      throw IOSPlatformError.signingRequired
    }
    return value
  }
}

/// Tells the user when the VPN stops without their action. While the tunnel runs, the
/// extension keeps a delayed alert pending and pushes it back, so an extension that iOS
/// ends (memory limit, crash, update) still alerts unless a restarted tunnel clears it.
enum IOSConnectionAlerts {
  static let identifier = "elarni.connection.lost"
  // The pending alert must outlive several refreshes; a missed one is not a disconnect.
  static let refreshSeconds: TimeInterval = 60
  private static let armSeconds: TimeInterval = 180

  static func arm() {
    schedule(String(localized: "Elarni disconnected"), String(localized: "The VPN stopped unexpectedly. Open Elarni to reconnect."), after: armSeconds)
  }

  static func disarm() {
    UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
  }

  /// A new tunnel retires shown alerts; arming replaces any pending one.
  static func connected() {
    UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
    arm()
  }

  /// For the app, before it starts a tunnel the user asked for.
  static func clear() {
    disarm()
    UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
  }

  /// Short delay so an On Demand restart can clear the alert before it shows.
  static func stopped(_ cause: String) {
    schedule(String(localized: "Elarni disconnected"), String(localized: "iOS stopped the VPN because \(cause). Open Elarni to reconnect."), after: 15)
  }

  static func failed() {
    schedule(String(localized: "Elarni connection lost"), String(localized: "Internet traffic is blocked until the VPN reconnects. Open Elarni to reconnect."), after: 1)
  }

  // One identifier: each alert replaces the pending one instead of stacking.
  private static func schedule(_ title: String, _ body: String, after seconds: TimeInterval) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)) { _ in }
  }
}

enum IOSPlatformError: LocalizedError {
  case signingRequired
  var errorDescription: String? {
    String(localized: "Configure the app and VPN extension with the same Apple Developer team, App Group, and Keychain group in Xcode.")
  }
}
