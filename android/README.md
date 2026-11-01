# Elarni for Android

Native Kotlin and Jetpack Compose app on the same Go/Xray engine and Rust profile
compiler as the desktop app. Requires Android 11 (API 30) or newer on ARM64.
Application IDs: `com.elarni` (release) and `com.elarni.debug`.

## Build

Requirements: JDK 17, Android SDK platform 37 with build-tools 36.0.0, NDK
28.2.13676358, and the Go and Rust versions pinned in the repository root. Set
`JAVA_HOME` and `ANDROID_HOME`, then from the repository root:

```sh
rustup target add aarch64-linux-android
GOBIN="$PWD/.build/android-tools" go install golang.org/x/mobile/cmd/gomobile@v0.0.0-20260709172247-6129f5bee9d5
GOBIN="$PWD/.build/android-tools" go install golang.org/x/mobile/cmd/gobind@v0.0.0-20260709172247-6129f5bee9d5
export GOMOBILE="$PWD/.build/android-tools/gomobile"
python3 scripts/build-android-native
android/gradlew -p android :app:assembleDebug
```

The debug APK lands in `android/app/build/outputs/apk/debug/`. Install it with
`adb install -r <apk>`; Android asks for VPN consent on the first connection.

`:app:assembleRelease` builds an **unsigned** release APK. No signing key or
configuration is included in the repository; keep the signing certificate stable
across releases so updates install.

## Test

`scripts/check-android` runs the native, catalog, UI and VPN suites on disposable
emulators named `Elarni_API_30` and `Elarni_API_36_16K` (16 KB pages). It refuses
physical devices and only uses synthetic local servers.

```sh
python3 scripts/check-android --avd Elarni_API_36_16K --avd Elarni_API_30
```

- `--serial <id>` uses an emulator that is already running.
- Naming an AVD twice boots two instances that split its suites.
- `--case native|catalog|ui|vpn` and `--test-method <name>` narrow the run.
- A failed test is rerun once alone and reported as `FLAKY` or `FAILED`.

The VPN suite needs the TUIC test server described in
[docs/TESTING.md](../docs/TESTING.md). On x86_64 Linux with KVM,
`python scripts/prepare-android-linux --emulators` creates x86_64 AVDs with the
same names. `scripts/check-android-release --serial <id> --apk <signed apk>` checks
a release build signed with a development key.

Emulators don't cover the camera, OEM battery management, long Doze periods,
Wi-Fi/cellular handoff or always-on VPN after reboot; check those on a device.

## Notes

- Per-app routing and network routes need system VPN mode. Apps that share a UID
  share a rule, and work profiles are separate VPNs.
- The app requests `QUERY_ALL_PACKAGES` to list apps without a launcher; Google
  Play requires a declaration for it.
- License notices are bundled from the root `LICENSE`, `NOTICE`,
  `THIRD_PARTY_NOTICES` and `android/OPEN_SOURCE_NOTICES`, and shown in Settings.
