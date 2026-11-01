# Elarni for iPhone

Native SwiftUI app with a packet-tunnel Network Extension, on the same Go/Xray
engine and Rust profile compiler as the desktop app. Requires iOS 18 or newer.

## Build

Requirements: Xcode 26.4 or newer with the iOS SDK and a Simulator runtime, and
the Go and Rust versions pinned in the repository root.

```sh
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
scripts/build-ios-native iphonesimulator   # or iphoneos for a device
```

Open `ios/Elarni/Elarni.xcodeproj`, choose the **Elarni** scheme and Run. Rebuild
the native libraries after changing Rust, Go or their headers. Set `ELARNI_GO` if
the pinned Go isn't the `go` on `PATH`.

The `Shared` folders hold relative symlinks to the macOS sources; keep symlinks
when copying the checkout.

## Test

```sh
scripts/check-ios <simulator-udid>   # from `xcrun simctl list devices available`
```

It runs the native and UI suites with synthetic profiles and loopback traffic; it
never starts a system VPN. Simulator runs need ad-hoc signing for Keychain access.
Shared Swift changes also need `scripts/check-tests swift`.

Simulator tests don't cover tunnel traffic. On a device, check TCP/UDP and DNS over
IPv4/IPv6, routes, reconnects across Wi-Fi/cellular, background and lock, and the
Control Center and Shortcuts actions.

## Signing

To sign with your own team, select it for all three targets and keep these
identifiers consistent across targets, entitlements and the
`ElarniAppGroup`/`ElarniKeychainGroup` Info values:

| Item | Value |
| --- | --- |
| App | `com.elarni.ios.Elarni` |
| Packet tunnel | `com.elarni.ios.Elarni.ElarniPacketTunnel` |
| Control Center widget | `com.elarni.ios.Elarni.ElarniWidgets` |
| App Group | `group.com.elarni.ios` |
| Shared Keychain | `$(AppIdentifierPrefix)com.elarni.ios.shared` |

The app and packet tunnel need the App Group and Network Extension
(`packet-tunnel-provider`) capabilities; the widget needs the App Group.

## Differences from desktop

- Per-app routing isn't available: iOS apps can't see other apps' traffic.
- Background refresh and health checks run only while the app is open; on-demand
  rules handle background reconnects.
- Local proxy listeners always require a login.
- The packet tunnel targets a 30 MiB Go heap.
- Backups carry servers, credentials and routing, not app settings.
