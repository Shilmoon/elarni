import XCTest
import UIKit

final class ElarniUITests: XCTestCase {
  @MainActor
  func testImportSelectionPersistenceAndSettings() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    let isolation = UUID().uuidString
    app.launchArguments = ["--ui-testing", isolation]
    app.launch()
    assertBrandHeader(app)
    XCTAssertFalse(app.buttons["Check connection"].exists)
    importClipboard(app, text: "socks://127.0.0.1:1080#Fixture\nsocks://127.0.0.1:1081#Germany%20Demo\nsocks://127.0.0.1:1082#Netherlands%20Demo\nsocks://127.0.0.1:1083#Germany%20Backup")
    XCTAssertTrue(app.buttons["selectedServer"].waitForExistence(timeout: 15))
    XCTAssertEqual(app.buttons["selectedServer"].label, "Fixture")
    importClipboard(app, text: "socks://127.0.0.1:1084#Germany%20Second%20provider\nsocks://127.0.0.1:1085#Germany%20Netherlands%20chain")
    XCTAssertFalse(app.tabBars.buttons["Servers"].exists)
    XCTAssertLessThan(app.buttons["connect"].frame.maxY, app.textFields["serverSearch"].frame.minY)
    app.buttons["selectedServer"].tap()
    let search = app.textFields["serverSearch"]
    XCTAssertTrue(search.waitForExistence(timeout: 5))
    search.tap(); search.typeText("Germany\n")
    let germany = app.buttons["server.Germany Demo"]
    XCTAssertTrue(germany.waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["server.Fixture"].exists)
    XCTAssertFalse(app.buttons["server.Netherlands Demo"].exists)
    XCTAssertTrue(app.staticTexts["countryFlag.DE"].firstMatch.exists)
    XCTAssertEqual(app.staticTexts.matching(identifier: "country.DE").count, 1)
    XCTAssertTrue(app.buttons.containing(.staticText, identifier: "country.DE").firstMatch.label.contains("3 servers"))
    XCTAssertTrue(app.buttons["server.Germany Second provider"].exists)
    XCTAssertTrue(app.staticTexts["country.other"].exists)
    XCTAssertTrue(app.buttons["server.Germany Netherlands chain"].exists)
    germany.tap()
    app.buttons["Clear search"].tap()
    germany.press(forDuration: 1)
    app.buttons["Favorite"].tap()
    serverFilter(app, "Favorites")
    XCTAssertTrue(germany.waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["server.Fixture"].exists)
    germany.press(forDuration: 1)
    XCTAssertTrue(app.buttons["Share"].exists)
    XCTAssertTrue(app.buttons["Test server"].exists)
    app.buttons["Details"].tap()
    XCTAssertTrue(app.navigationBars["Germany Demo"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.switches["Favorite"].value as? String, "1")
    app.buttons["Done"].tap()
    // The info button opens the same details without a long press.
    app.buttons["details.Germany Demo"].tap()
    XCTAssertTrue(app.navigationBars["Germany Demo"].waitForExistence(timeout: 5))
    app.buttons["Done"].tap()
    serverFilter(app, "All")
    reveal(app.buttons["server.Fixture"], in: app)
    XCTAssertTrue(app.buttons["server.Fixture"].waitForExistence(timeout: 5))
    app.terminate()
    app.launch()
    XCTAssertTrue(app.buttons["selectedServer"].waitForExistence(timeout: 10))
    XCTAssertEqual(app.buttons["selectedServer"].label, "Germany Demo")
    for tab in ["Home", "Subscriptions"] {
      app.tabBars.buttons[tab].tap()
      if tab == "Home" { app.buttons["selectedServer"].tap() }
      let image = XCTAttachment(screenshot: app.screenshot()); image.name = "Desktop style light - \(tab)"; image.lifetime = .keepAlways; add(image)
    }
    // Both clipboard imports joined one local group, which has no subscription
    // link: Share picks its servers and shares them as links.
    XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "Local profiles")).count, 1)
    app.staticTexts["Local profiles"].firstMatch.tap()
    let shareGroup = app.buttons["Share"]
    reveal(shareGroup, in: app)
    shareGroup.tap()
    XCTAssertTrue(app.navigationBars["Share servers"].waitForExistence(timeout: 5))
    app.buttons["shareServer.Fixture"].tap()
    app.buttons["shareServer.Germany Demo"].tap()
    let picker = XCTAttachment(screenshot: app.screenshot()); picker.name = "Share servers picker"; picker.lifetime = .keepAlways; add(picker)
    app.buttons["Share 2 links"].tap()
    XCTAssertTrue(app.buttons["Copy"].waitForExistence(timeout: 5))
    let links = XCTAttachment(screenshot: app.screenshot()); links.name = "Shared server links"; links.lifetime = .keepAlways; add(links)
    app.buttons["Done"].tap()
    app.navigationBars["Share servers"].buttons["Cancel"].tap()
    app.navigationBars.buttons["Subscriptions"].tap()
    app.tabBars.buttons["Settings"].tap()
    settingsCategory(app, "Appearance")
    XCTAssertTrue(app.buttons["themePicker"].waitForExistence(timeout: 5))
    app.buttons["themePicker"].tap()
    app.buttons["Dark"].tap()
    XCTAssertTrue(app.buttons["accentPicker"].label.contains("Evergreen"))
    app.buttons["accentPicker"].tap()
    app.buttons["Blue"].tap()
    app.buttons["Save"].tap()
    settingsCategory(app, "General")
    settingsCategory(app, "Appearance")
    XCTAssertTrue(app.buttons["themePicker"].label.contains("Dark"))
    XCTAssertTrue(app.buttons["accentPicker"].label.contains("Blue"))
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = "Native iPhone settings"
    attachment.lifetime = .keepAlways
    add(attachment)
    app.navigationBars["Appearance"].buttons["Settings"].tap()
    XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    let settingsList = XCTAttachment(screenshot: app.screenshot()); settingsList.name = "Dark Settings category list"; settingsList.lifetime = .keepAlways; add(settingsList)
    for tab in ["Home", "Subscriptions"] {
      app.tabBars.buttons[tab].tap()
      if tab == "Home" {
        let selected = app.buttons["selectedServer"]
        if selected.isHittable { selected.tap() }
      }
      let image = XCTAttachment(screenshot: app.screenshot()); image.name = "Desktop style dark - \(tab)"; image.lifetime = .keepAlways; add(image)
    }
    app.open(URL(string: "elarni://status")!)
    assertBrandHeader(app)
    XCTAssertFalse(app.textViews["importText"].exists)
  }

  @MainActor
  func testMalformedImportKeepsAppUsable() throws {
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing", UUID().uuidString]
    app.launch()
    importClipboard(app, text: "not a configuration")
    XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 10))
    app.alerts.buttons["OK"].tap()
    XCTAssertFalse(app.textViews["importText"].exists)
    importClipboard(app, text: "  \n ")
    XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
    XCTAssertTrue(app.alerts.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "clipboard is empty")).firstMatch.exists)
    app.alerts.buttons["OK"].tap()
    importClipboard(app, text: "socks://127.0.0.1:1080#Recovered")
    XCTAssertTrue(app.buttons["selectedServer"].waitForExistence(timeout: 10))
    XCTAssertEqual(app.buttons["selectedServer"].label, "Recovered")
  }

  // Elarni ships no servers, so an empty Home says where one comes from and adds it from there.
  @MainActor
  func testEmptyHomeWalksThroughTheFirstServer() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing", UUID().uuidString]
    app.launch()
    let steps = app.staticTexts["Get connected in three steps"]
    XCTAssertTrue(steps.waitForExistence(timeout: 10))
    for text in ["Elarni has no servers of its own", "iOS asks once to allow the VPN configuration"] {
      XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch.exists, text)
    }
    XCTAssertTrue(app.buttons["Open file"].exists)
    XCTAssertTrue(app.buttons["Scan QR code"].exists)
    let monitor = addUIInterruptionMonitor(withDescription: "Clipboard permission") { alert in
      let allow = alert.buttons["Allow Paste"]
      guard allow.exists else { return false }
      allow.tap(); return true
    }
    defer { removeUIInterruptionMonitor(monitor) }
    UIPasteboard.general.string = "socks://127.0.0.1:1080#Onboarding"
    app.buttons["Paste link"].tap()
    let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow Paste"]
    if allow.waitForExistence(timeout: 2) { allow.tap() }
    XCTAssertTrue(app.buttons["selectedServer"].waitForExistence(timeout: 15))
    XCTAssertEqual(app.buttons["selectedServer"].label, "Onboarding")
    XCTAssertFalse(steps.exists)
  }

  // A lock sends the app to the background and an unlock brings back the same Home. The Simulator has no
  // tunnel, so this covers the app's side; the VPN across a lock needs a signed iPhone build.
  @MainActor
  func testLockAndUnlockReturnToTheSameHome() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing", UUID().uuidString]
    app.launch()
    importClipboard(app, text: "socks://127.0.0.1:1080#Lock%20fixture")
    XCTAssertTrue(app.buttons["selectedServer"].waitForExistence(timeout: 15))
    // XCUIDevice has no public lock button.
    XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
    let locked = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.state != .runningForeground }, object: nil)
    XCTAssertEqual(XCTWaiter().wait(for: [locked], timeout: 10), .completed, "The lock left the app in the foreground")
    // The first press wakes the lock screen, the second unlocks it (the Simulator has no passcode).
    XCUIDevice.shared.press(.home)
    XCUIDevice.shared.press(.home)
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "The unlock did not return to the app")
    XCTAssertEqual(app.buttons["selectedServer"].label, "Lock fixture")
    XCTAssertTrue(app.buttons["connect"].isEnabled)
    XCTAssertFalse(app.alerts.firstMatch.exists)
  }

  // The interface follows the device language, including titles the app names at run time.
  @MainActor
  func testRussianInterfaceFollowsTheDeviceLanguage() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing", UUID().uuidString, "-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU"]
    app.launch()
    XCTAssertTrue(app.staticTexts["Подключитесь в три шага"].waitForExistence(timeout: 10))
    for button in ["Вставить ссылку", "Сканировать QR-код", "Открыть файл"] {
      XCTAssertTrue(app.buttons[button].exists, button)
    }
    for tab in ["Главная", "Подписки", "Маршрутизация"] {
      XCTAssertTrue(app.tabBars.buttons[tab].exists, tab)
    }
    app.tabBars.buttons["Настройки"].tap()
    XCTAssertTrue(app.navigationBars["Настройки"].waitForExistence(timeout: 5))
    let general = app.buttons["settingsCategory.General"]
    XCTAssertTrue(general.waitForExistence(timeout: 5))
    XCTAssertTrue(general.label.contains("Общие"), general.label)
    general.tap()
    XCTAssertTrue(app.navigationBars["Общие"].waitForExistence(timeout: 5))
    let image = XCTAttachment(screenshot: app.screenshot()); image.name = "Russian - General settings"; image.lifetime = .keepAlways; add(image)
  }

  @MainActor
  func testRoutingStructuredAndJSONEditorsPreserveRules() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing", UUID().uuidString]
    app.launch()
    app.tabBars.buttons["Routing"].tap()
    app.buttons["New profile"].tap()
    app.buttons["Advanced"].tap()
    let name = app.textFields["Profile name"]
    XCTAssertTrue(name.waitForExistence(timeout: 5))
    replace(name, text: "Acceptance rules")
    app.buttons["Save"].tap()
    let profile = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Acceptance rules")).firstMatch
    XCTAssertTrue(profile.waitForExistence(timeout: 10))
    profile.tap()
    app.buttons["Edit JSON"].tap()
    let json = app.textViews["Routing JSON"]
    XCTAssertTrue(json.waitForExistence(timeout: 5))
    let source = "{\"Name\":\"Acceptance rules\",\"GlobalProxy\":true,\"RemoteDNSType\":\"DoU\",\"RemoteDNSIP\":\"1.1.1.1\",\"DomesticDNSType\":\"DoU\",\"DomesticDNSIP\":\"1.1.1.1\",\"BlockSites\":[\"example.invalid\"],\"DnsHosts\":{\"fixture.test\":\"192.0.2.10\"}}"
    replace(json, text: source)
    app.buttons["Save"].tap()
    app.buttons["Edit rules and DNS"].tap()
    app.buttons["DNS"].tap()
    let host = app.textFields["Hostname"]
    for _ in 0..<6 where !host.isHittable { app.swipeUp() }
    XCTAssertTrue(host.isHittable)
    XCTAssertEqual(host.value as? String, "fixture.test")
    XCTAssertEqual(app.textFields["IPv4 or IPv6 address"].value as? String, "192.0.2.10")
    app.buttons["Save"].tap()
    app.buttons["Edit JSON"].tap()
    XCTAssertTrue(json.waitForExistence(timeout: 5))
    let saved = try XCTUnwrap((json.value as? String)?.data(using: .utf8))
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
    XCTAssertEqual(object["BlockSites"] as? [String], ["example.invalid"])
    XCTAssertEqual(object["DnsHosts"] as? [String: String], ["fixture.test": "192.0.2.10"])
    app.buttons["Cancel"].tap()
    app.terminate(); app.launch()
    app.tabBars.buttons["Routing"].tap()
    XCTAssertTrue(profile.waitForExistence(timeout: 10))
    let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Routing profiles"; attachment.lifetime = .keepAlways; add(attachment)
  }

  @MainActor
  func testHomeSupportNavigationAndLandscape() throws {
    // Home keeps its first screen for servers in both orientations;
    // Troubleshooting is in Settings > System info and recovery in General.
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing", UUID().uuidString]
    XCUIDevice.shared.orientation = .portrait
    defer { XCUIDevice.shared.orientation = .portrait }
    app.launch()
    for landscape in [false, true] {
      XCUIDevice.shared.orientation = landscape ? .landscapeLeft : .portrait
      let layout = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
        let frame = app.windows.firstMatch.frame
        return landscape ? frame.width > frame.height : frame.height > frame.width
      }, object: nil)
      wait(for: [layout], timeout: 5)
      assertBrandHeader(app)
      XCTAssertFalse(app.buttons["Check connection"].exists)
      let attachment = XCTAttachment(screenshot: app.screenshot())
      attachment.name = landscape ? "Home landscape" : "Home portrait"
      attachment.lifetime = .keepAlways
      add(attachment)
      XCTAssertTrue(app.buttons["connect"].exists)
      XCTAssertFalse(app.buttons["Troubleshoot"].exists)
      XCTAssertFalse(app.buttons["Recovery settings"].exists)
    }
    XCUIDevice.shared.orientation = .portrait
    app.tabBars.buttons["Settings"].tap()
    settingsCategory(app, "System info")
    let troubleshoot = app.buttons["Troubleshoot connection"]
    reveal(troubleshoot, in: app)
    troubleshoot.tap()
    XCTAssertTrue(app.navigationBars["Troubleshooting"].waitForExistence(timeout: 5))
    let logs = app.buttons["Logs"]
    reveal(logs, in: app)
    logs.tap()
    XCTAssertTrue(app.navigationBars["Logs"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["No log lines yet. The core records them while it runs."].waitForExistence(timeout: 5))
  }

  @MainActor
  func testSettingsRejectInvalidPortAndRetainSavedValue() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing", UUID().uuidString]
    app.launch()
    app.tabBars.buttons["Settings"].tap()
    settingsCategory(app, "Connection")
    let port = app.textFields["SOCKS port"]
    XCTAssertTrue(port.waitForExistence(timeout: 5))
    // The number-pad field takes neither the hardware Select All command nor, since iOS 26, the
    // edit menu's Select All after a long press: put the cursor after the value and delete it.
    port.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
    let saved = port.value as? String ?? ""
    XCTAssertEqual(saved, "10890")
    port.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: saved.count) + "0")
    XCTAssertEqual(port.value as? String, "0")
    app.buttons["Save"].tap()
    XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 10))
    app.alerts.buttons["OK"].tap()
    settingsCategory(app, "General")
    settingsCategory(app, "Connection")
    XCTAssertEqual(port.value as? String, "10890")
    for tab in ["Home", "Subscriptions", "Routing", "Settings"] {
      app.tabBars.buttons[tab].tap()
      let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Light - \(tab)"; attachment.lifetime = .keepAlways; add(attachment)
    }
  }

  @MainActor
  func testDesktopSettingsCategoriesAndQRImagePlacement() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing", UUID().uuidString]
    app.launch()
    importClipboard(app, text: "socks://127.0.0.1:1080#DEU%20Berlin")
    XCTAssertTrue(app.buttons["selectedServer"].waitForExistence(timeout: 15))
    app.buttons["selectedServer"].tap()
    XCTAssertTrue(app.staticTexts["countryFlag.DE"].firstMatch.waitForExistence(timeout: 5))
    let countryImage = XCTAttachment(screenshot: app.screenshot()); countryImage.name = "Country groups - current text size"; countryImage.lifetime = .keepAlways; add(countryImage)
    app.tabBars.buttons["Settings"].tap()
    XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["settingsCategory"].exists)
    let categoriesTopImage = XCTAttachment(screenshot: app.screenshot()); categoriesTopImage.name = "Settings category list - top"; categoriesTopImage.lifetime = .keepAlways; add(categoriesTopImage)
    for group in ["Preferences", "Network", "Support"] {
      reveal(app.staticTexts[group].firstMatch, in: app)
    }
    let categoriesImage = XCTAttachment(screenshot: app.screenshot()); categoriesImage.name = "Settings category list"; categoriesImage.lifetime = .keepAlways; add(categoriesImage)
    for (category, content) in [
      ("General", "Connection recovery"), ("Appearance", "themePicker"),
      ("Connection", "SOCKS port"), ("DNS", "DNS settings"),
      ("Apps & routes", "Block traffic without VPN"), ("Advanced", "Enable fragmentation"),
      ("Server tests", "Test type"), ("Backup and repair", "Create encrypted backup"),
      ("System info", "Operating system"), ("Route table", "Configured included routes")
    ] {
      settingsCategory(app, category)
      if category == "Apps & routes" { app.buttons["Advanced network routes"].tap() }
      let field = app.descendants(matching: .any).matching(identifier: content).firstMatch
      for _ in 0..<12 where !field.exists {
        let list = app.collectionViews.firstMatch
        list.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.8))
          .press(forDuration: 0.05, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.35)), withVelocity: .slow, thenHoldForDuration: 0.2)
      }
      XCTAssertTrue(field.waitForExistence(timeout: 5), "Missing \(content) in \(category)")
      let image = XCTAttachment(screenshot: app.screenshot()); image.name = "Settings - \(category)"; image.lifetime = .keepAlways; add(image)
    }
    settingsCategory(app, "General")
    XCTAssertFalse(app.switches["Launch app at login"].exists)
    XCTAssertFalse(app.buttons["Automatic recovery"].exists)
    // Recovery is now nested under General. Saving General afterward must not
    // overwrite preferences committed by that nested editor.
    let recovery = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Connection recovery,")).firstMatch
    recovery.tap()
    app.buttons["recoveryPolicy"].tap()
    menuChoice(app, "Ordered fallback", forward: true)
    app.buttons["Save"].tap()
    app.buttons["Save"].tap()
    recovery.tap()
    XCTAssertTrue(app.buttons["recoveryPolicy"].label.contains("Ordered fallback"))
    app.navigationBars.buttons.firstMatch.tap()
    settingsCategory(app, "Server tests")
    app.buttons["probeTimeout"].tap()
    menuChoice(app, "15 s timeout", forward: true)
    app.buttons["Save"].tap()
    settingsCategory(app, "General")
    settingsCategory(app, "Server tests")
    XCTAssertTrue(app.buttons["probeTimeout"].label.contains("15 s timeout"))
    app.tabBars.buttons["Home"].tap()
    app.buttons["import"].tap()
    XCTAssertFalse(app.buttons["QR image"].exists)
    XCTAssertFalse(app.buttons["Paste or type"].exists)
    app.buttons["Scan QR code"].tap()
    XCTAssertTrue(app.buttons["qrImage"].waitForExistence(timeout: 5))
    let image = XCTAttachment(screenshot: app.screenshot()); image.name = "Scan QR image action"; image.lifetime = .keepAlways; add(image)
    app.buttons["qrImage"].tap()
    let photos = app.navigationBars["Photos"]
    XCTAssertTrue(photos.waitForExistence(timeout: 5))
    photos.buttons["Cancel"].tap()
    XCTAssertTrue(photos.waitForNonExistence(timeout: 5))
    XCTAssertTrue(app.buttons["qrImage"].waitForExistence(timeout: 5))
    app.navigationBars["Scan QR code"].buttons["Cancel"].tap()
    assertBrandHeader(app)
  }

  // Xcode's accessibility audit on each screen. VoiceOver's findings (missing or poor
  // descriptions, wrong traits, elements it cannot reach) fail; visual ones are attached.
  @MainActor
  func testAccessibilityAuditOnEveryScreen() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing", UUID().uuidString]
    app.launch()
    var voiceOver: [String] = [], visual: [String] = []
    func audit(_ screen: String) throws {
      try app.performAccessibilityAudit(for: .all) { issue in
        let line = "\(screen): [\(issue.auditType.rawValue)] \(issue.compactDescription) — \(issue.element.map { "\($0.elementType.rawValue) '\($0.label)' \($0.identifier)" } ?? "no element")"
        if issue.auditType.isSubset(of: [.sufficientElementDescription, .elementDetection, .trait]) { voiceOver.append(line) } else { visual.append(line) }
        return true
      }
    }
    XCTAssertTrue(app.staticTexts["Get connected in three steps"].waitForExistence(timeout: 10))
    try audit("empty Home")
    importClipboard(app, text: "socks://127.0.0.1:1080#Fixture\nsocks://127.0.0.1:1081#Germany%20Demo")
    XCTAssertTrue(app.buttons["selectedServer"].waitForExistence(timeout: 15))
    try audit("Home")
    app.buttons["selectedServer"].tap()
    XCTAssertTrue(app.textFields["serverSearch"].waitForExistence(timeout: 5))
    try audit("servers")
    for tab in ["Subscriptions", "Routing"] {
      app.tabBars.buttons[tab].tap()
      XCTAssertTrue(app.navigationBars[tab].waitForExistence(timeout: 5))
      try audit(tab)
    }
    app.tabBars.buttons["Settings"].tap()
    XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    try audit("Settings")
    for category in ["General", "Appearance", "Connection", "DNS", "Apps & routes", "Advanced", "Server tests", "Backup and repair", "System info", "Route table"] {
      settingsCategory(app, category)
      try audit("Settings \(category)")
    }
    settingsCategory(app, "System info")
    let troubleshoot = app.buttons["Troubleshoot connection"]
    reveal(troubleshoot, in: app)
    troubleshoot.tap()
    XCTAssertTrue(app.navigationBars["Troubleshooting"].waitForExistence(timeout: 5))
    try audit("Troubleshooting")
    let report = XCTAttachment(string: (["VoiceOver"] + voiceOver + ["", "Visual"] + visual).joined(separator: "\n"))
    report.name = "Accessibility audit"; report.lifetime = .keepAlways; add(report)
    XCTAssertTrue(voiceOver.isEmpty, voiceOver.joined(separator: "\n"))
  }

  @MainActor
  private func settingsCategory(_ app: XCUIApplication, _ category: String) {
    if !app.navigationBars["Settings"].exists {
      let back = app.navigationBars.buttons["Settings"]
      XCTAssertTrue(back.waitForExistence(timeout: 5))
      back.tap()
    }
    XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    let row = app.buttons["settingsCategory.\(category)"]
    let list = app.collectionViews.firstMatch
    let firstCategory = app.buttons["settingsCategory.General"]
    for _ in 0..<12 where !row.isHittable && !firstCategory.isHittable { list.swipeDown() }
    reveal(row, in: app)
    row.tap()
    XCTAssertTrue(app.navigationBars[category].waitForExistence(timeout: 5))
    XCTAssertTrue(app.navigationBars[category].buttons["Settings"].exists)
    XCTAssertTrue(app.tabBars.buttons["Settings"].isSelected)
  }

  @MainActor
  private func menuChoice(_ app: XCUIApplication, _ choice: String, forward: Bool) {
    // Native menus virtualize their rows at accessibility text sizes. Use a
    // swipe instead of the press-and-hold gesture used for the server list.
    for _ in 0..<12 where !app.buttons[choice].exists {
      let menu = app.collectionViews.element(boundBy: app.collectionViews.count - 1)
      if forward { menu.swipeUp() } else { menu.swipeDown() }
    }
    if !app.buttons[choice].exists {
      let hierarchy = XCTAttachment(string: app.debugDescription); hierarchy.name = "Menu lookup - \(choice)"; hierarchy.lifetime = .keepAlways; add(hierarchy)
      let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Menu lookup - \(choice)"; screenshot.lifetime = .keepAlways; add(screenshot)
    }
    XCTAssertTrue(app.buttons[choice].exists)
    app.buttons[choice].tap()
  }

  @MainActor
  private func serverFilter(_ app: XCUIApplication, _ filter: String) {
    let segment = app.segmentedControls.buttons[filter]
    if segment.exists { segment.tap() }
    else { app.buttons["serverFilter"].tap(); app.buttons[filter].tap() }
  }

  @MainActor
  private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
    let list = app.collectionViews.firstMatch
    for _ in 0..<12 where !element.isHittable {
      list.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.8))
        .press(forDuration: 0.05, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.35)), withVelocity: .slow, thenHoldForDuration: 0.2)
    }
    XCTAssertTrue(element.isHittable)
  }

  @MainActor
  private func importClipboard(_ app: XCUIApplication, text: String) {
    let monitor = addUIInterruptionMonitor(withDescription: "Clipboard permission") { alert in
      let allow = alert.buttons["Allow Paste"]
      guard allow.exists else { return false }
      allow.tap(); return true
    }
    defer { removeUIInterruptionMonitor(monitor) }
    UIPasteboard.general.string = text
    app.buttons["import"].tap()
    app.buttons["Import from clipboard"].tap()
    let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow Paste"]
    if allow.waitForExistence(timeout: 2) { allow.tap() }
    XCTAssertFalse(app.textViews["importText"].exists)
  }

  @MainActor
  private func assertBrandHeader(_ app: XCUIApplication) {
    let brand = app.images["brand"]
    XCTAssertTrue(brand.waitForExistence(timeout: 5))
    XCTAssertEqual(brand.label, "Elarni")
    let importButton = app.buttons["import"]
    XCTAssertTrue(importButton.exists)
    XCTAssertEqual(brand.frame.midY, importButton.frame.midY, accuracy: 1)
    // Import's visible system capsule is 44 points tall; its accessibility
    // frame excludes the outer padding. Match the artwork to the capsule.
    XCTAssertEqual(brand.frame.height, 44, accuracy: 1)
    XCTAssertLessThan(brand.frame.maxX, importButton.frame.minX)
    XCTAssertFalse(app.staticTexts["Elarni"].exists)
  }

  @MainActor
  private func replace(_ field: XCUIElement, text: String) {
    field.tap()
    // The name and compact JSON fixtures each contain one paragraph. Use
    // iOS paragraph selection without keyboard shortcuts or edit-menu timing.
    field.tap(withNumberOfTaps: 3, numberOfTouches: 1)
    field.typeText(text)
    XCTAssertEqual(field.value as? String, text)
  }
}
