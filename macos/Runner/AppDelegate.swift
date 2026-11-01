import Cocoa
import FlutterMacOS

#if !ELARNI_CONTROL_CHECKS
@main
#endif
class AppDelegate: FlutterAppDelegate {
  override func applicationWillFinishLaunching(_ notification: Notification) {
    if ProcessInfo.processInfo.environment["ELARNI_HEADLESS"] == "1" {
      NSApp.setActivationPolicy(.prohibited)
    }
    super.applicationWillFinishLaunching(notification)
  }
  override func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls where ["elarni", "happ", "incy", "vless", "vmess", "trojan", "ss", "socks", "socks5", "hy2", "hysteria2", "tuic", "vpn", "wireguard"].contains(url.scheme?.lowercased() ?? "") {
      RoutingDeepLinkInbox.push(url.absoluteString)
    }
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return ProcessInfo.processInfo.environment["ELARNI_HEADLESS"] != "1"
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}

enum RoutingDeepLinkInbox {
  static let notification = Notification.Name("ElarniRoutingDeepLink")
  private static let lock = NSLock()
  private static var pending: [String] = []

  static func push(_ value: String) {
    guard value.utf8.count <= 4 * 1024 * 1024 else { return }
    lock.lock()
    guard pending.count < 16 else { lock.unlock(); return }
    pending.append(value)
    lock.unlock()
    NotificationCenter.default.post(name: notification, object: value)
  }

  static func takeAll() -> [String] {
    lock.lock()
    defer { lock.unlock() }
    let values = pending
    pending.removeAll()
    return values
  }
}
