# Elarni for Android

Native Kotlin/Jetpack Compose interface with the same source-built Rust domain
and Go/Xray engines as the desktop app. Android 11 (API 30) or newer and an
ARM64 device are required. The debug application ID is `com.elarni.debug`;
the unsigned release variant uses `com.elarni`. Version: 0.3.7 (10).

## Features

- System VPN and local SOCKS/HTTP proxy; optional authenticated LAN listeners,
  IPv4/IPv6 routes, DNS, per-app bypass/only-listed rules and session limits.
- Text, clipboard, files, incoming links, shared QR images and system-camera QR
  capture; profile/QR sharing and Android document export.
- Subscriptions, local groups, country grouping, search, favorites/recent servers,
  group-scoped browsing and probes, provider metadata/name restoration, credentials,
  refresh schedules and destination approval.
- Routing profiles with form/JSON editors, DNS hosts, direct/proxy/block rules,
  provider policies, managed domain lists, separate GeoIP/Geosite refresh and reduction.
- Connection metrics, server probes, automatic fallback/latency selection,
  bounded reconnects, screen-off behavior, troubleshooting and redacted diagnostics.
- Keystore-encrypted atomic storage and interruption recovery; portable encrypted
  backups compatible with the shared desktop format.
- Persistent connection notification, Quick Settings tile, control links,
  optional boot connection, background maintenance, light/dark themes, font scaling
and compact/expanded navigation. License notices are available in Settings.

Android's installed package names replace desktop executable paths. Applications
sharing a UID share its routing policy. The app can enumerate only the current
Android user's/profile's installed packages; a separate work profile remains a
separate Android VPN domain. The app's own sockets are excluded/protected from
the VPN to avoid loops. Per-app and network-route settings require system VPN
mode; local proxy mode affects clients configured to use its listeners.

Background maintenance uses persisted, network-constrained JobScheduler work
with a 15-minute minimum; Android may defer it. Force-stop prevents background
execution until the user opens the app again. Always-on and blocking connections
without VPN are controlled in Android VPN settings. Screen-off pause should stay
disabled when uninterrupted VPN service is required. Hotspot/tethered traffic and
other Android user profiles are not promised to use this VPN.

## Interface

Home, Subscriptions, Routing and Settings follow the iPhone app's hierarchy with
native Compose Material 3 controls. Solid neutral surfaces, the Elarni mark and
evergreen actions work in light and dark themes; saved accent choices remain
available. Home places connection state, the selected server and Connect above
server filters, search and testing. Troubleshoot and Recovery settings are in
Settings, so servers start on the first screen.

Phones use a four-destination navigation bar. Expanded windows use a navigation
rail; wide Home layouts place connection and servers side by side. Filters wrap
at enlarged text sizes, controls follow Android text scaling, and editors retain
system Back and keyboard insets. Settings groups related options under
Preferences, Network and Support, including the Android VPN and battery controls.
The ten Settings destinations match iOS. Connection recovery and Android platform
tools live in General; per-app rules stay in Apps & routes. Category saves remain
on screen, nested Back preserves the parent draft, and tabs retain their own
navigation. Server tests saves the test type, timeout and HTTP expectations used
by Home's visible-server action. Appearance, sorting and test preferences do not
restart an active connection or invalidate its current probe results.

Import offers clipboard, file and QR actions and sends their results directly to
the existing validated importer. QR photo selection is inside Scan QR code;
Android camera capture remains native. Country/sort options and each server's
Details, Favorite, Test and Share actions are available from Home. Routing
profiles open their status/actions before the form or JSON editor.
Routing and Subscriptions use the iPhone screen sections and action order.
Routing includes subscription assignments, routing-data status and individual
managed-list refresh; its form separates Rules, DNS and Advanced. Subscriptions
shows Time and Data remaining, quota progress, provider information, routing,
download options, pinning, rename and server access. Pull down to refresh feeds.
Per-app routing opens from a full-width 56dp control. Real installed-app icons
identify each row; selected apps remain first even while searching. The initial
unselected list shows eight apps, and Show more adds eight at a time. Save changes
and Cancel stay visible while the list scrolls. Draft selections survive rotation.
Enabled profiles apply only to assigned subscriptions. Routing shows assignment
status; open a profile and choose Assign to subscription to apply it to a group.
Disabling a profile preserves its assignments for re-enabling. Branded
`elarni://routing/add/`, `onadd/` and `off` links follow the same explicit
activation rules as Happ links.

## Build

The standalone Gradle project does not package Flutter or use Flutter's Android
generated plugin registrant. Run commands from the repository root. The current
build has been exercised on macOS and Ubuntu 22.04 (CI) with JDK 17, Android SDK platform 37/build-tools
36.0.0, NDK 28.2.13676358, Go 1.27.3 and Rust 1.98.0. Gradle 9.6.0, AGP 9.4.0,
Kotlin 2.4.10 and Compose BOM 2026.09.00 are pinned in this directory. Target API
36 is intentional; compile API 37 does not claim Android 17 runtime acceptance.

Set `JAVA_HOME` to your JDK 17 installation and `ANDROID_HOME` to your installed
SDK. Install the Android packages and accept their licenses with the SDK's tools.
Install the Rust target and the exact mobile bindings used by the checked source:

```sh
rustup target add aarch64-linux-android
mkdir -p .build/android-tools
GOBIN="$PWD/.build/android-tools" go install golang.org/x/mobile/cmd/gomobile@v0.0.0-20260709172247-6129f5bee9d5
GOBIN="$PWD/.build/android-tools" go install golang.org/x/mobile/cmd/gobind@v0.0.0-20260709172247-6129f5bee9d5
export GOMOBILE="$PWD/.build/android-tools/gomobile"
python3 scripts/check_report.py -- python3 scripts/build-android-native
python3 scripts/check_report.py -- android/gradlew -p android :app:assembleDebug :app:lintDebug --no-daemon --console=plain
```

The native script consumes the repository's Cargo lockfile and Go workspace;
it does not replace the vendored cores with upstream binaries. It builds one Go
runtime, the Rust domain library and its JNI adapter in `.build/android-native`.
The pinned `anet` dependency requires the documented Go linker option
`-checklinkname=0`; reassess its private Go interface dependency before changing
the Go, x/net or anet versions. NDK/JNI and packaged ELF segments support 16-KiB
pages. This target currently produces only `arm64-v8a`, not an x86 ChromeOS APK.

Output: `android/app/build/outputs/apk/debug/app-debug.apk`. Install on an
explicitly selected device with `adb -s SERIAL install -r APK_PATH`; Android asks
for VPN consent when first connecting. The debug key is for development only.

`android/gradlew -p android :app:assembleRelease` produces the optimized,
resource-shrunk **unsigned** APK at
`android/app/build/outputs/apk/release/app-release-unsigned.apk`. Production key
custody and private distribution are separate steps. No keystore, signing secret,
production signing configuration or publishing account is included in source.
Keep the signing certificate stable for upgrade compatibility.

## Replay acceptance

Use disposable AVDs named `Elarni_API_30` and `Elarni_API_36_16K`, the latter
with an actual 16-KiB ARM64 system image. The runner checks the AVD name, completed
boot, API and page size, and refuses physical devices. It creates synthetic
loopback peers; never run it against a working VPN or real subscription.

```sh
python3 scripts/check-android --serial emulator-5554
```

The serial above is an example: select the verified AVD serial from `adb devices`.
Repeat `--serial` (for example `--serial emulator-5554 --serial emulator-5556`) to
replay both AVDs at once: the runner builds once, then runs each emulator in its
own process and prints each transcript whole when it finishes.
`--avd NAME` instead boots a read-only instance of that AVD for the run and stops
it afterwards. Naming one AVD twice boots two instances that split its catalog, ui
and vpn tests between them (instrumentation shards); the native suite, the catalog
restart sequence and the process-death pairs run on the first. The runner checks
that the shards together ran every test:

```sh
python3 scripts/check-android --avd Elarni_API_36_16K --avd Elarni_API_36_16K --avd Elarni_API_30 --avd Elarni_API_30
```

A failing step does not stop the run: every suite still runs, each failed test is
rerun once alone, and the closing summary labels it `FLAKY` (passed when rerun) or
`FAILED` (failed again). Either makes the run exit 1. The vpn suite's Doze test
sleeps `--sleep-minutes` (a quarter minute by default; release acceptance uses 10).
From Windows or WSL, `python scripts/check-mac --host user@mac -- python3 scripts/check-android ...`
runs it on the Mac in a kept workspace (see [docs/TESTING.md](../docs/TESTING.md)).
On an x86_64 Linux host with KVM (CI's container), `python scripts/prepare-android-linux --emulators`
creates x86_64 AVDs of the same names, and the runner builds x86_64 native code for them
(`build-android-native --abi x86_64`, Gradle `-Pelarni.abi=x86_64`): ARM translation crashes the Go
test binaries. Releases still ship arm64-v8a.
The default run builds native binaries, app, instrumentation and two disposable
traffic clients. `--case native|catalog|ui|vpn` selects a boundary; `--skip-build`
reuses existing artifacts only when their relevant source is unchanged. Every run
retains a transcript and source/configuration summary under `.build/check-results`.
Use `--case ui|catalog|vpn --test-method METHOD_NAME` for one focused instrumentation
method; the catalog restart/journal sequence runs only with the whole catalog suite.
The runner verifies executed counts and rejects failures, skips and incomplete
instrumentation results, even when Android's shell command itself exits zero.

The UI suite contains twenty workflows, including 26 simultaneous real proxy
probes, incremental results, and light/dark country/row latency badges. Its
`iosHierarchyKeepsAndroidNavigationAndAppearance` case captures the native tabs,
import screen and saved light/dark appearance using synthetic local profiles.
PNG captures are written to the debug app's external files directory as
`design-*.png`; replay at normal and 1.3 font scale and an expanded window for
visual checks. Restore emulator font scale and display overrides afterward.

Coverage includes native ownership/protection, protocol traffic and userspace
WireGuard/Amnezia peers; real encrypted catalog/restart/interrupted-save recovery;
Compose form/rotation/file-picker flows; and actual VpnService traffic from
two distinct UIDs, DNS, routing changes, rollback, recovery and platform controls.
Native protocol traffic and the VPN lifecycle are separate checks: a native
protocol pass does not claim every protocol has been exercised through the whole
Android VPN stack. The test traffic clients contain no launcher or production
functionality and are not bundled in the application.

TUIC v5 uses the shared Xray outbound backed by sing-quic v0.7.1. Links, supported
Clash profiles and app JSON retain UUID/password, TLS identity, ALPN and relay
policy. The UI displays TUIC / QUIC / TLS; direct TCP port ping is unavailable.
The VPN fixture covers both `native` and `quic` relays, foreign-UID TCP/UDP to
both address families, DNS and repeated reconnects with a trusted synthetic CA.
Build its separate server before running VPN acceptance:

```sh
GOBIN="$PWD/.build/tuic/tools" go install -tags=with_quic github.com/sagernet/sing-box/cmd/sing-box@v1.14.0
```

The runner expects that binary or an explicit `ELARNI_TUIC_SERVER` path. It
never includes the test server in the app. Full native acceptance expects
2 TUN, 2 protection/geodata-restore, 62 importer/traffic and 3 WireGuard passes; instrumentation
expects 56 catalog, 3 restart/journal, 24 UI, 16 VPN and 3 process-death
pairs without skips.
The assigned-routing VPN case checks direct/proxy/block domain policy, disabled
and unassigned fallback, branded off/onadd activation, UDP IP rules and reconnect.

After signing a copy of the optimized release APK with a development key, replay
the non-debuggable build separately on an owned AVD:

```sh
python3 scripts/check-android-release --serial emulator-5554 --apk /absolute/path/to/development-signed-release.apk
python3 scripts/check-android-release --serial emulator-5554 --apk /absolute/path/to/development-signed-release.apk --protocol tuic-native
python3 scripts/check-android-release --serial emulator-5554 --apk /absolute/path/to/development-signed-release.apk --protocol tuic-quic
```

This check clears only the test AVD's `com.elarni` package, imports a synthetic
profile through the UI, verifies foreign-UID VPN traffic and disconnect cleanup,
then reinstalls the same signed APK and verifies encrypted catalog persistence
and reconnect traffic. It retains the APK digest, transcript and screenshots.
The synthetic SOCKS peer never opens outbound connections. A development signature
does not establish production signing or physical-device acceptance.

Hardware acceptance remains necessary for the physical camera, OnePlus battery
management, sustained Doze/sleep, Wi-Fi/cellular handoff and reboot/always-on
behavior. Emulator evidence does not establish those OEM behaviors.

## Packaging and notices

Gradle bundles the root `LICENSE`, `NOTICE`, `THIRD_PARTY_NOTICES` and
`android/OPEN_SOURCE_NOTICES`; Settings exposes the complete bundled documents.
The source archive tooling includes the Android source and build scripts while
excluding generated APKs, caches, local SDK configuration and signing keys.
Preserve the existing engine licenses and corresponding-source requirements
when preparing any distribution. The native host's Android runtime dependency
notices supplement the root inventory.

The private APK requests `QUERY_ALL_PACKAGES` so per-app routing can list network
apps that have no launcher activity. This requires a separate eligibility and
declaration review before Google Play submission. The manifest's narrowly scoped
lint exceptions document that requirement and the consented-VPN eligibility for
`systemExempted`; exact-alarm permissions are not needed for a VPN. Local proxy
mode uses the separately declared `specialUse` foreground-service type.
