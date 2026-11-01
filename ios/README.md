# Elarni for iPhone

Native SwiftUI app for **iOS 18+**, with a packet-tunnel Network Extension. It
uses the same Go/Xray importer and runtime, Rust compiler and packet bridge,
catalog, routing store, and provider lifecycle as the desktop app. No Flutter
engine is embedded. Apple Silicon simulators and arm64 iPhones are supported.

The iPhone UI uses Elarni's chosen arch-and-oval icon, white/charcoal palette,
Evergreen default and four saved accent options, system typography, connection
antenna and server badges. Home places the logo alone on the left, opposite Import,
matching its height without a toolbar background. Server tests stay in the
server list and its context menus.
Bottom tabs and native navigation/forms adapt those elements for touch,
Dynamic Type and Reduce Motion.
The connected antenna retains the desktop's green radial reveal and 400 ms timing.
Home puts the searchable server catalog below Connect, matching the desktop's
compact window. Favorites, recent servers, location/sort options, tests and server
actions stay in that list; the remaining tabs are Subscriptions, Routing and Settings.
Servers are grouped across providers under country flags, names and counts;
unknown or conflicting country labels stay under Other locations.
Settings lists the desktop's ten categories under Preferences, Network and Support.
Each category opens inside Settings with native back navigation, with unsupported
desktop-only controls hidden. Recovery is in General; backup
and repair share one category; configured iOS routes are under Route table.
Import from clipboard adds copied configurations directly, without a text editor.
Files remain available; the photo icon inside Scan QR imports QR images.

## Build and test

Use the repository's pinned Rust toolchain and Go version from `go.work`, and
Xcode 26.4 or newer with the iOS SDK and a Simulator runtime. Select the intended
Xcode using `DEVELOPER_DIR` if several versions are installed. Install the Rust
targets once:

```sh
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
scripts/build-ios-native iphonesimulator
```

Open `ios/Elarni/Elarni.xcodeproj`, choose the **Elarni** scheme and an
iPhone simulator, then Run. Build the native libraries before the first Xcode
build, and rebuild them after changing Rust, Go, their dependencies, or headers.
Generated libraries are in `.build/ios/Native/<platform>`; the Xcode targets link
the matching platform. Keep device and simulator archives separate. Set
`ELARNI_GO` to the pinned Go executable if it is not the `go` on PATH.

Run the complete iOS acceptance suite against an owned simulator:

```sh
xcrun simctl list devices available
scripts/check-ios SIMULATOR-UDID
```

This builds native dependencies, runs the native and UI suites serially, retains
the command transcript under `.build/check-results`, and saves the XCTest result
bundle and counts under `.build/ios/checks`. Simulator tests need ad-hoc signing
for real Keychain access. `CODE_SIGNING_ALLOWED=NO` is for compile-only checks;
it causes Keychain access to fail in a running simulator app.

Tests use synthetic profiles, app-local isolated catalogs, and loopback traffic.
They exercise real import/compile/backup/QR/Keychain paths, native proxy HTTP and
cancellation, ICMP, routing and settings UI, error handling and persistence.
They never start a system VPN. Shared Swift changes also require
`scripts/check-tests swift` on macOS. Run native builds and checks
serially.

For an unsigned device build:

```sh
scripts/build-ios-native iphoneos
python3 scripts/check_report.py -- xcodebuild -quiet \
  -project ios/Elarni/Elarni.xcodeproj -scheme Elarni \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath .build/ios/Device CODE_SIGNING_ALLOWED=NO build
```

## Signing and physical testing

All three targets use the project's Apple Developer team (`D6T4QS5TP8`). To
sign with your own paid team, select it for every target. The targets use these
identifiers:

| Item | Value |
| --- | --- |
| App | `com.elarni.ios.Elarni` |
| Extension | `com.elarni.ios.Elarni.ElarniPacketTunnel` |
| Control Center widget | `com.elarni.ios.Elarni.ElarniWidgets` |
| App Group | `group.com.elarni.ios` |
| Shared Keychain | `$(AppIdentifierPrefix)com.elarni.ios.shared` |
| Network Extension capability | `packet-tunnel-provider` |

If identifiers must change for the team, update every target, every entitlements file,
and the `ElarniAppGroup`/`ElarniKeychainGroup` Info values together. Keep
the extension's bundle identifier equal to the app identifier plus
`.ElarniPacketTunnel`. Provision the App Group and Network Extension
capabilities for the app and the packet tunnel, and the App Group for the widget
extension. Credentials and provisioning profiles stay local.

If Xcode reports **PLA Update available**, the account holder must review and
accept Apple's updated Program License Agreement before automatic provisioning
can create profiles containing App Groups and Network Extensions. A wildcard
profile cannot substitute for these capabilities.

Run on an unlocked, trusted iPhone with Developer Mode enabled. Use an isolated
test profile and have the device owner approve VPN installation and activation.
Do not use a working Mac VPN for acceptance. A successful simulator test or
device build does **not** verify iPhone tunnel traffic.

Physical acceptance must verify shared Keychain access, TCP/UDP and DNS over
IPv4/IPv6, included/excluded routes, listener authentication, Stop during
startup/switching, server replacement and rollback, app relaunch with an active
tunnel, background/lock, Wi-Fi/cellular changes, on-demand behavior and cleanup.
Measure extension memory/energy under sustained traffic and repeated reconnects.
Camera scanning, local-network/notification permission denial, Files/share
handoffs, and the Control Center toggle and Shortcuts actions also need device checks. Keep private profiles out of reports and Git.

## Feature coverage

TUIC v5 shares the same Go adapter and strict URI/Clash/app-profile importer as
desktop and Android. The Simulator catalog regression covers encrypted
persistence, compilation, sharing and the original TLS identity. TUIC uses
QUIC / TLS, and direct TCP port ping is unsupported. The shared loopback traffic
fixtures cover both relay modes, authentication/certificate failures, IPv4/IPv6,
concurrent cancellation and cleanup. Those checks do not establish iPhone VPN
traffic, network replacement or sustained extension memory/energy; run the signed
physical-device matrix above before claiming that acceptance.

| Desktop function | iPhone implementation |
| --- | --- |
| Server and subscription imports | Clipboard, Files, QR photo inside camera scanning and incoming URLs; direct shared importer for server links, Xray/Clash/WireGuard configurations and subscriptions, retaining source approval |
| Subscription management | Source approval, refresh, staged update review, rename/delete, pinning, provider actions/metadata/quotas, formats and fetch options |
| Server catalog | Country flags/disclosure across providers, provider attribution, selection, favorites, search, country/sort filters, recent successful tests, node IP overrides, full-profile groups, sharing and Telegram handoff |
| Routing | Profiles, assignments, structured rules/DNS/static hosts, full JSON, duplicate/reset/delete, managed domain lists and routing-data refresh |
| VPN control | OS/provider status, start/Stop, compatible live switch or restart, persisted intent, transactions and interrupted-publication reconciliation; Connect, Disconnect and Toggle actions for Shortcuts and Siri, and a Control Center toggle |
| Network/runtime settings | IPv4/IPv6, profile DNS, included/excluded routes, on-demand, sleep behavior, authenticated SOCKS/HTTP and LAN listeners, fragmentation, mux, sniffing, traffic counters and connection limits |
| Connectivity tests | Up to 32 parallel foreground proxy/proxy-with-routing, TCP and correlated ICMP probes; incremental colored latency badges, timeout/cancellation and stale-result handling |
| Automatic recovery | Bounded foreground same-server retry or allowed fallback; lowest latency chooses on Connect and retains a healthy connection |
| Portability and support | Desktop-compatible encrypted catalog backup, redacted diagnostics, repair, native appearance/accent preferences, expiry notifications, URL commands for Shortcuts |

Important platform adaptations:

- iOS suspends the foreground app. Subscription/list refresh, health checks and
  candidate comparisons run while it is open. iOS on-demand handles configured
  background reconnects (Include all networks turns it on, as on macOS); app
  timers do not claim background execution. A started connection change finishes
  in background time instead of stopping half-way.
- With notification permission, the VPN extension alerts when the tunnel stops
  without the user's Stop: a failure that blocks traffic, an unexpected iOS stop
  reason, or an extension that iOS ends. For the last case the extension keeps a
  delayed alert pending and pushes it back every minute while running, so the
  alert can arrive up to three minutes late. A tunnel that restarts clears it.
- Desktop executable-based per-app routing is rejected. An ordinary personal
  iPhone app cannot identify/control arbitrary other apps through that mechanism.
  Domain/IP routing is available; managed per-app VPN would be a separate MDM
  product. The desktop "Hide VPN icon" route exclusions belong to per-app
  routing and are not offered either; iOS always shows its VPN indicator.
- The iPhone uses the packet-flow bridge, not the desktop Xray TUN descriptor
  backend. Local proxy listeners run with the VPN extension and always require a
  login: the saved credentials when authentication is on, otherwise a random one
  per tunnel session, so other apps cannot use them. There is no desktop
  helper-process/standalone background proxy mode, system tray or launch-at-login.
- Alternate/direct tests require disconnecting. While connected, proxy testing
  checks the selected packet path and provider generation. Verified automatic
  fallback requires full included routes, Include all networks, and no bypass or
  provider routing rules. Fixed recovery can reconnect under custom routing but
  labels traffic as unchecked.
- iOS uses a **30 MiB soft Go heap target** on every runtime start. This is not a
  total extension-memory guarantee. Desktop memory settings are not imported.
- System information uses public network-path APIs. It shows configured routes,
  not an unsupported system routing-table dump.
- Backups include catalog credentials and routing, not app settings, listener
  credentials, favorites or probe history. Restore disables automatic recovery
  and resets source approvals.

The Swift files under each target's `Shared` folder are relative symlinks to the
existing implementation. Preserve symlinks when copying the checkout. iOS guards
in shared sources leave desktop behavior intact. Keep runtime errors, provider
status and cleanup failures visible; never substitute plaintext secrets or a
simulated successful VPN.

Distribution is a separate step. Preserve the repository's GPL license and
vendored notices; this development target does not imply App Store, licensing,
provisioning or real-device acceptance.
