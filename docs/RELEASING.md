# Releasing

Releases are direct downloads: an unsigned Windows ZIP and MSI, a Linux `.deb`,
AppImage and portable archive, a signed Android APK and the source archives. Their
integrity comes from build provenance and a signed `SHA256SUMS`, not from platform
code signing. No macOS or iOS build is published; the macOS and Windows signing
commands below are for builds signed by hand.

## Release flow

Release files are built by `.github/workflows/release.yml` on GitHub-hosted runners, which start without
any cache from earlier builds. The self-hosted CI runners also run pull request and Dependabot code, so
nothing they build is published.

1. Run the workflow with stage `build` on the commit to release. It refuses a commit without a
   successful "checks passed" from Development checks, then builds the Linux packages, the Windows ZIP
   and MSI, the source archives and the unsigned APK, and records build provenance for each file.
2. On the release machine, which holds the Android signing key, sign the APK and upload a draft
   release at the run's commit with every file of the run plus `SHA256SUMS`. The maintainer's scripts
   for this step (`assemble.sh`, `gh_release.py`) live on that machine, not in this repository.
3. Run the workflow with stage `publish` and the tag. It checks every file against `SHA256SUMS` and,
   except for the signed APK, against the build provenance; then it signs `SHA256SUMS` (Sigstore,
   keyless) and publishes the release.

Users can check a download:

```sh
gh attestation verify Elarni-0.4.1-12-x86_64.AppImage --repo Shilmoon/elarni
cosign verify-blob SHA256SUMS --bundle SHA256SUMS.sigstore.json \
  --certificate-identity-regexp '^https://github.com/Shilmoon/elarni/\.github/workflows/release\.yml@' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
sha256sum -c SHA256SUMS
```

Upgrades are manual: nothing downloads or installs. Desktop and Android release
builds read `https://api.github.com/repos/Shilmoon/elarni/releases/latest` once a
day (hourly while it cannot be read) and show a notice when it names a newer
version; pre-release tags never do. Settings › General › Update feed changes it to
another HTTPS address, serving a GitHub `releases/latest` reply or
`{"version": "0.4.1", "url": "https://…"}`, or clears it to turn the check off;
debug builds start with it off. The default feed needs the repository to be public.

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
installs to `%ProgramFiles%\Elarni`; a fresh install also sets up the VPN helper
service for the installing account, so connecting needs no UAC prompt. An upgrade
sets it up too when no service exists and no installer offered it to that account
before (installs upgraded from 0.3.6 or earlier); otherwise upgrades keep each
account's setting (Settings › Connection › Connect without administrator approval).
An install run as SYSTEM (Intune, SCCM) sets up no account. Uninstalling removes the
service.

The portable ZIP asks for administrator approval to install the helper on the
first connection. To remove it: run `elarni.exe --unregister`, then
`elarni-core.exe --uninstall-helper` from an elevated prompt (it also closes a running
Elarni), and delete the folder.

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
- Publish the packages, `SHA256SUMS`, source archives, notices and release notes
  together.
