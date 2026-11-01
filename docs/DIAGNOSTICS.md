# Diagnostics

## Connection recording

Recording is a build option and is off by default: release builds don't contain
it. In a recording build, **Record connection diagnostics** (Settings › Advanced,
or `recordDiagnostics` headless) logs connection metadata locally. Nothing is
sent anywhere, and recordings never include credentials, addresses, DNS names or
payloads.

- **Mark problem** (`markRecording`) marks the moment a problem was seen.
- **Save recording as ZIP** (`exportRecording`) exports what is kept: up to 256 MiB
  on desktop and 64 MiB on phones, for at most 72 hours.

Recordings are stored in `%LOCALAPPDATA%\Elarni\Diagnostics` (Windows),
`~/.cache/Elarni/Diagnostics` and `/var/log/elarni/<uid>` (Linux), the app group's
`Diagnostics` folder (macOS, iOS) or the app's no-backup files (Android).

Build with the `ELARNI_RECORDING` switch:

| Build | Command |
|---|---|
| Windows, Linux, macOS | `flutter build <platform> --dart-define=ELARNI_RECORDING=true` |
| Android | `ELARNI_RECORDING=1` for `scripts/build-android-native` and Gradle |
| iOS | `ELARNI_RECORDING=1 scripts/build-ios-native <platform>`, then `xcodebuild` with `SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) ELARNI_RECORDING'` |
| Core only | `go build -tags=elarni_recording ./Vendor/libXray/cmd/elarni-core` |

`check-tests go`, `check-tests flutter` and `check-windows` test both variants.

## Diagnostic builds

Diagnostic builds record from launch, with no setting, for chasing an
intermittent problem with a user. They need the `elarni_diagnostics` Go tag.

- **macOS:** `python3 scripts/build-diagnostics-macos [--output <dir>]` builds a
  signed Debug app with a Diagnostics menu (Mark a Stall, Export Diagnostic Logs).
- **Windows:** `python scripts/build-diagnostics-windows --bundle <release bundle>
  --output <empty dir> --go <go.exe>` rebuilds the core into an unsigned diagnostic
  ZIP. The user reproduces the problem and runs **Export diagnostics.cmd**.
  `python scripts/check-windows-diagnostics --core <elarni-core.exe>` checks it.

Each diagnostic build gets its own build number; check that the app and tunnel
report the same one before reading a recording.
