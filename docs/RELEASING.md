# Releasing

Desktop releases are direct downloads: a notarized macOS ZIP (optionally a DMG),
a signed Windows ZIP and MSI, and a Linux `.deb`, AppImage and portable archive.
CI builds **unsigned** candidates only; signing happens on a release machine.

Upgrades are manual. Release builds read
`https://api.github.com/repos/Shilmoon/elarni/releases/latest` once a day and show
a notice when a newer version exists (Settings › General › Update feed changes or
clears it; debug builds start with it off). It needs the repository to be public.

## Before you package

1. Bump `version` in `pubspec.yaml`; never reuse a published version.
2. Build with the pinned toolchains (`mise.toml`, `rust-toolchain.toml`) from a
   clean checkout, using `lib/main.dart`.
3. Run the checks in [TESTING.md](TESTING.md), including
   `python scripts/check-server-cores` on each OS.

Each packager refuses a non-empty output directory and writes
`release-manifest.json`, `project-source-manifest.json` and `SHA256SUMS`.

Source archives for the GPL obligations:

```sh
python3 scripts/package-source --output .build/release-source
python3 scripts/package-dependencies --output .build/release-dependency-source
```

## macOS

Needs a Developer ID identity with the app's Network Extension, App Group and
Keychain entitlements, and a `notarytool` keychain profile.

```sh
flutter build macos --release --config-only --target=lib/main.dart
xcodebuild -workspace macos/Runner.xcworkspace -scheme Runner -configuration Release \
  -archivePath .build/release/Elarni.xcarchive ARCHS=arm64 archive
python3 scripts/package-macos --archive .build/release/Elarni.xcarchive \
  --export-options /path/ExportOptions.plist --notary-profile PROFILE \
  --output /path/release [--dmg]
```

The script notarizes, staples and runs a Gatekeeper check. `--unsigned` and
`--development` build packages for testing only.

## Windows

```powershell
flutter build windows --release --target=lib/main.dart
python scripts/package-windows --bundle build/windows/x64/runner/Release `
  --output C:\release\new --signtool C:\path\to\signtool.exe `
  --certificate-thumbprint THUMBPRINT --timestamp-url RFC3161_URL --msi
```

The script signs and verifies every EXE and DLL and keeps Wintun's own signature.
`--msi` needs WiX 5 (`dotnet tool install --global wix --version 5.0.2`). The MSI
installs to `%ProgramFiles%\Elarni` and sets up the VPN helper service so
connecting needs no UAC prompt; uninstalling removes it.

The portable ZIP asks for administrator approval to install the helper on the
first connection. To remove it: quit Elarni, run `elarni.exe --unregister`, then
`elarni-core.exe --uninstall-helper` from an elevated prompt, and delete the folder.

## Linux

On Ubuntu 22.04:

```sh
flutter build linux --release --target=lib/main.dart
python3 scripts/package-linux --output .build/linux-release
```

See [linux/README.md](../linux/README.md) for installation.

## Checklist

- Install the previous release, add data, upgrade, then connect and disconnect.
  Check that settings, servers and routing survive and no routes or DNS changes
  are left behind.
- Check that uninstall keeps user data.
- Record idle cost with `python scripts/measure-idle --seconds 300`.
- Publish signed packages, `SHA256SUMS`, source archives, notices and release
  notes together.
