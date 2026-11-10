import SwiftUI

// The desktop palette in lib/elarni_widgets.dart, resolved for iOS appearance.
enum AppPalette {
  static let surface = adaptive(0xffffff, 0x202124)
  static let inset = adaptive(0xf6f7f9, 0x25272c)
  static let field = adaptive(0xe8eaf0, 0x34373e)
  static let text = adaptive(0x111827, 0xf3f4f7)
  static let secondary = adaptive(0x626a7c, 0xaeb3bf)
  static let border = adaptive(0xdfe2e9, 0x3b3e45)
  static let onAccent = adaptive(0xffffff, 0x10151d)
  static let warning = adaptive(0x854d0e, 0xfde047)

  static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
    Color(uiColor: UIColor { traits in uiColor(traits.userInterfaceStyle == .dark ? dark : light) })
  }
  static func uiColor(_ hex: UInt32) -> UIColor {
    UIColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
  }
  static func accent(_ hex: UInt32) -> Color {
    Color(uiColor: UIColor { traits in
      let mix: CGFloat = traits.userInterfaceStyle == .dark ? 0.45 : 0
      return UIColor(red: CGFloat((hex >> 16) & 255) / 255 * (1 - mix) + mix,
                     green: CGFloat((hex >> 8) & 255) / 255 * (1 - mix) + mix,
                     blue: CGFloat(hex & 255) / 255 * (1 - mix) + mix, alpha: 1)
    })
  }
}

struct ElarniBrand: View {
  var body: some View {
    Image("ElarniIcon").resizable().scaledToFit()
    .frame(width: 44, height: 44)
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .accessibilityLabel("Elarni").accessibilityIdentifier("brand")
  }
}

struct AppList<Content: View>: View {
  var sectionSpacing: CGFloat = 16
  @ViewBuilder var content: Content
  var body: some View {
    List { content.listRowBackground(AppPalette.surface).listRowSeparatorTint(AppPalette.border) }
      .listStyle(.insetGrouped).listSectionSpacing(sectionSpacing)
      .scrollContentBackground(.hidden).background(AppPalette.surface)
      .foregroundStyle(AppPalette.text)
  }
}

struct AppForm<Content: View>: View {
  @ViewBuilder var content: Content
  var body: some View {
    Form { content.listRowBackground(AppPalette.surface).listRowSeparatorTint(AppPalette.border) }
      .scrollContentBackground(.hidden).background(AppPalette.inset)
      .foregroundStyle(AppPalette.text)
  }
}

struct AppPrimaryButtonStyle: ButtonStyle {
  @Environment(IOSAppModel.self) private var model
  @Environment(\.isEnabled) private var enabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(enabled ? AppPalette.onAccent : AppPalette.secondary)
      .background(enabled ? appTint(model.preferences.accent) : AppPalette.field, in: RoundedRectangle(cornerRadius: 8))
      .opacity(configuration.isPressed ? 0.8 : 1)
      .contentShape(RoundedRectangle(cornerRadius: 8))
  }
}

struct ConnectionArtwork: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  // Small enough that Home shows servers on its first screen.
  @ScaledMetric(relativeTo: .largeTitle) private var size = 61
  let connected: Bool
  let failed: Bool
  // Connected, but the server passes no traffic.
  var warning = false
  private var glyph: some View {
    Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: min(size, 82), weight: .regular))
  }
  var body: some View {
    glyph.foregroundStyle(failed ? Color.red : warning ? AppPalette.warning : AppPalette.secondary.opacity(0.7))
      .animation(reduceMotion ? nil : .linear(duration: 0.4), value: failed || warning)
      .overlay {
        if !failed {
          glyph.foregroundStyle(Color(uiColor: AppPalette.uiColor(0x24b83e)))
            .mask {
              GeometryReader { geometry in
                let diameter = hypot(geometry.size.width, geometry.size.height)
                Circle().frame(width: diameter, height: diameter)
                  .scaleEffect(connected ? 1 : 0)
                  .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                  .animation(reduceMotion ? nil : .linear(duration: 0.4), value: connected)
              }
            }
        }
      }
      .frame(height: min(size, 82) + 4)
      .accessibilityHidden(true)
  }
}

struct AppEmptyState: View {
  let title: LocalizedStringKey
  let systemImage: String
  let message: LocalizedStringKey
  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: systemImage).font(.largeTitle.weight(.light)).foregroundStyle(AppPalette.secondary).accessibilityHidden(true)
      Text(title).font(.headline).foregroundStyle(AppPalette.text)
      Text(message).font(.subheadline).foregroundStyle(AppPalette.secondary)
    }
    .multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.vertical, 28)
  }
}

/// Elarni ships no servers, so an empty Home starts with where one comes from.
struct GettingStarted: View {
  let actions: ImportActions
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Get connected in three steps").font(.headline).foregroundStyle(AppPalette.text).accessibilityAddTraits(.isHeader)
      step(1, "Get a subscription link or QR code from your provider. Elarni has no servers of its own.")
      step(2, "Add it here.")
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) { buttons }
        VStack(alignment: .leading, spacing: 8) { buttons }
      }
      .buttonStyle(.bordered).padding(.leading, 36)
      step(3, "Press Connect. iOS asks once to allow the VPN configuration.")
    }
    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
  }
  @ViewBuilder private var buttons: some View {
    Button("Paste link", systemImage: "doc.on.clipboard", action: actions.paste)
    Button("Scan QR code", systemImage: "qrcode.viewfinder", action: actions.scan)
    Button("Open file", systemImage: "doc", action: actions.file)
  }
  private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text("\(number)").font(.footnote.weight(.semibold)).foregroundStyle(AppPalette.text)
        .frame(width: 24, height: 24).background(Circle().fill(AppPalette.field))
      Text(text).font(.subheadline).foregroundStyle(AppPalette.text).fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
  }
}


struct LocationFlag: View {
  let location: ServerLocation?
  var body: some View {
    if let location {
      Text(location.flag).font(.title2).dynamicTypeSize(.large).frame(width: 32)
        .accessibilityLabel(location.name).accessibilityIdentifier("countryFlag.\(location.code)")
    } else {
      Image(systemName: "globe").foregroundStyle(AppPalette.secondary).frame(width: 32).accessibilityLabel("Other locations")
    }
  }
}

struct LatencyBadge: View {
  let milliseconds: Int
  var label: String? = nil
  private var colors: (Color, Color) {
    switch milliseconds {
    case ..<100: (AppPalette.adaptive(0x166534, 0x86efac), AppPalette.adaptive(0xdcfce7, 0x173b29))
    case ..<300: (AppPalette.adaptive(0x854d0e, 0xfde047), AppPalette.adaptive(0xfef9c3, 0x453810))
    default: (AppPalette.adaptive(0x991b1b, 0xfca5a5), AppPalette.adaptive(0xfee2e2, 0x492326))
    }
  }
  var body: some View {
    Text("\(milliseconds) ms").font(.caption2.weight(.semibold).monospacedDigit())
      .foregroundStyle(colors.0).padding(.horizontal, 5).padding(.vertical, 2)
      .background(colors.1, in: RoundedRectangle(cornerRadius: 6))
      .fixedSize().accessibilityLabel(label ?? String(localized: "\(milliseconds) milliseconds"))
  }
}

struct IPChoices: View {
  var inherit = false
  var body: some View {
    if inherit { Text("Inherit").tag("inherit") }
    Text("Automatic").tag("automatic"); Text("IPv4").tag("ipv4"); Text("IPv6").tag("ipv6")
  }
}
struct TrafficSection: View {
  @Environment(IOSAppModel.self) private var model
  var body: some View {
    Section("Traffic") {
      let counters = model.vpn.provider["counters"] as? [String: Any] ?? [:]
      ForEach([("uplinkBytes", String(localized: "Uploaded")), ("downlinkBytes", String(localized: "Downloaded")), ("heapAllocBytes", String(localized: "Go heap"))], id: \.0) { key, title in
        if let value = counters[key] as? Int64 { LabeledContent(title, value: ByteCountFormatter.string(fromByteCount: value, countStyle: .binary)) }
      }
      ForEach([("activeTcpSessions", String(localized: "TCP sessions")), ("activeUdpSessions", String(localized: "UDP sessions")), ("droppedUdpSessions", String(localized: "UDP sessions refused at the limit")), ("packetsIn", String(localized: "Packets received")), ("packetsOut", String(localized: "Packets sent"))], id: \.0) { key, title in
        if let value = counters[key] as? Int { LabeledContent(title, value: value.formatted()) }
      }
      if counters.isEmpty { Text("Waiting for provider metrics…").foregroundStyle(AppPalette.secondary) }
    }
  }
}
struct IOSQuotaPresentation {
  let label: String
  let remainingFraction: Double?
  init(metadata: [String: Any]) {
    guard let total = metadata["total"] as? Int64, total >= 0 else {
      label = String(localized: "Not provided"); remainingFraction = nil; return
    }
    if total == 0 { label = String(localized: "Unlimited"); remainingFraction = 1; return }
    guard let upload = metadata["upload"] as? Int64, upload >= 0,
          let download = metadata["download"] as? Int64, download >= 0 else {
      label = String(localized: "Not provided"); remainingFraction = nil; return
    }
    // Subtract capped counters separately: a provider's two counters can overflow their sum.
    let remaining = max(0, total - min(total, upload) - min(total, download))
    label = remaining == 0 ? String(localized: "Data exhausted") : String(localized: "\(ByteCountFormatter.string(fromByteCount: remaining, countStyle: .binary)) left")
    remainingFraction = Double(remaining) / Double(total)
  }
}

struct QuotaView: View {
  let source: ServerSubscription
  var body: some View {
    let quota = IOSQuotaPresentation(metadata: source.metadata)
    VStack(spacing: 12) {
      LabeledContent("Time") {
        if let expires = source.expireSeconds, expires.isFinite, expires >= 0 {
          if expires == 0 { Text("No expiry") }
          else if expires <= Date().timeIntervalSince1970 { Text("Expired") }
          else { Text(Date(timeIntervalSince1970: expires), style: .date) }
        } else { Text("Not provided") }
      }
      VStack(spacing: 8) {
        LabeledContent("Data", value: quota.label)
        if let fraction = quota.remainingFraction {
          ProgressView(value: fraction).accessibilityLabel("Data remaining")
        }
      }
    }.font(.subheadline).padding(.vertical, 4)
  }
}
private struct ErrorPresentation: ViewModifier {
  @Environment(IOSAppModel.self) private var model
  @State private var identity = UUID()
  func body(content: Content) -> some View {
    content.alert("Couldn’t complete the operation", isPresented: Binding(get: { model.errorMessage != nil && model.errorPresenters.last == identity }, set: { if !$0 && model.errorPresenters.last == identity { model.errorMessage = nil } })) {
      Button("OK", role: .cancel) { model.errorMessage = nil }
    } message: { Text(model.errorMessage ?? "") }
    .alert("Subscription approval", isPresented: Binding(get: { model.approval != nil && model.errorPresenters.last == identity }, set: { if !$0 && model.errorPresenters.last == identity { model.approval = nil } })) {
      if let warning = model.approval {
        Button("Continue") { model.approval = nil; model.launch { try await model.refresh(warning.subscriptionID, challenge: warning.challenge) } }
      }
      Button("Cancel", role: .cancel) { model.approval = nil }
    } message: { Text(approvalText(model.approval)) }
    .onAppear { model.errorPresenters.removeAll { $0 == identity }; model.errorPresenters.append(identity) }
    .onDisappear { model.errorPresenters.removeAll { $0 == identity } }
  }
}
extension View { func appErrors() -> some View { modifier(ErrorPresentation()) } }
func appTint(_ name: String) -> Color {
  switch name {
  case "evergreen": AppPalette.accent(0x284d42)
  case "teal": AppPalette.accent(0x006b60)
  case "purple": AppPalette.accent(0x5546e8)
  case "orange": AppPalette.accent(0x8c5000)
  default: AppPalette.accent(0x006ef0)
  }
}
func approvalText(_ warning: SubscriptionSafetyWarning?) -> String {
  guard let warning else { return "" }
  let descriptions = warning.riskCodes.map { code in
    switch code { case .cleartextHTTP: String(localized: "The subscription uses unencrypted HTTP."); case .loopbackTarget: String(localized: "It contacts this device."); case .privateTarget: String(localized: "It contacts a private network address.") }
  }
  return (descriptions + [String(localized: "Destinations: \(warning.destinations.joined(separator: ", "))."),
    String(localized: "Continue only if you trust this subscription provider. Approval applies to this destination chain.")]).joined(separator: " ")
}
enum SaveStatus { case saving, saved }
/// How long a flipped switch waits before it saves, so several flipped in a row make one save. UI tests do not wait it out.
let autoApplyDelay: Duration = ProcessInfo.processInfo.arguments.contains("--ui-testing") ? .milliseconds(100) : .seconds(1)
/// How long the page title keeps "Saved". A UI test needs longer than one accessibility snapshot to see it.
let savedNoteDuration: Duration = ProcessInfo.processInfo.arguments.contains("--ui-testing") ? .seconds(6) : .seconds(2)
/// Copies a field into `next` only when the draft changed it since `base`, so a value saved elsewhere since stays.
func carry<Root, Value: Equatable>(_ key: WritableKeyPath<Root, Value>, from draft: Root, since base: Root, to next: inout Root) {
  if draft[keyPath: key] != base[keyPath: key] { next[keyPath: key] = draft[keyPath: key] }
}
/// A settings page with a draft. Switches save themselves; what is typed or picked is saved by Save and by leaving the page
/// (Back, another tab, a page opened from it), and Cancel drops it. A draft the app would refuse hides Back until it is
/// corrected or cancelled, so leaving never loses it unseen.
private struct DraftPage: ViewModifier {
  @Environment(IOSAppModel.self) private var model
  let title: LocalizedStringKey
  let dirty: Bool
  let valid: Bool
  let canSave: Bool
  let cancel: () -> Void
  let save: (_ leaving: Bool) -> Void
  func body(content: Content) -> some View {
    content.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
      .navigationBarBackButtonHidden(dirty && !valid)
      .toolbar {
        // Always present: a toolbar item added while the page is open does not reach the bar.
        ToolbarItem(placement: .principal) {
          VStack(spacing: 0) {
            Text(title).font(.headline)
            if let status = model.saveStatus {
              Text(status == .saving ? "Saving…" : "Saved").font(.caption2).foregroundStyle(AppPalette.secondary).accessibilityIdentifier("saveStatus")
            }
          }
        }
        if dirty { ToolbarItem(placement: .topBarTrailing) { Button("Cancel", action: cancel).disabled(model.busy) } }
        ToolbarItem(placement: .confirmationAction) { Button("Save") { save(false) }.disabled(model.busy || !canSave) }
      }
      .onDisappear {
        if dirty && valid { save(true) }
        // A switch still waiting out its pause stays in the draft.
        else if model.saveStatus == .saving { model.saveStatus = nil }
      }
  }
}
extension View {
  func draftPage(_ title: LocalizedStringKey, dirty: Bool, valid: Bool, canSave: Bool = true, cancel: @escaping () -> Void, save: @escaping (_ leaving: Bool) -> Void) -> some View {
    modifier(DraftPage(title: title, dirty: dirty, valid: valid, canSave: canSave, cancel: cancel, save: save))
  }
}
/// The last row of a page whose draft cannot be saved as it stands.
struct InvalidDraftNote: View {
  var body: some View { Section { Text("A value on this page can’t be saved. Correct it, or tap Cancel to drop your changes.").font(.footnote).foregroundStyle(.red) } }
}
struct NumberField: View {
  let title: LocalizedStringKey
  @Binding var value: Int
  // A fixed width keeps the value on its label's line, even for a long label.
  var body: some View { LabeledContent(title) { TextField(title, value: $value, format: .number.grouping(.never)).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 90) } }
}
/// A text field whose label stays above it once it has a value.
struct StackedField: View {
  let title: LocalizedStringKey
  let prompt: LocalizedStringKey
  @Binding var text: String
  var axis: Axis = .horizontal
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.subheadline).foregroundStyle(AppPalette.secondary).accessibilityHidden(true)
      TextField(title, text: $text, prompt: Text(prompt), axis: axis)
    }
  }
}
struct LinesEditor: View {
  let title: LocalizedStringKey
  @Binding var text: String
  var body: some View {
    VStack(alignment: .leading, spacing: 8) { Text(title).font(.subheadline); TextEditor(text: $text).font(.body.monospaced()).frame(minHeight: 100).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel(title) }
  }
}
