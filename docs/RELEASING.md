# Direct-download releases

Supported build targets are macOS arm64 (minimum 13.0), Windows x64, and Ubuntu
22.04+ x64. The existing shared UI is unchanged. Distribution consists of a
notarized macOS application ZIP, a signed complete Windows portable ZIP, and the
Linux `.deb`, AppImage and portable archive. Upgrades are manual: nothing downloads or installs
by itself. Release builds read
`https://api.github.com/repos/Shilmoon/elarni/releases/latest` once a day and
show a notice on Home when it names a newer version (Settings > General >
Update feed changes or clears it; debug builds start with it off). That address
needs the repository to be public.

## Candidate and source identity

Build with the repository's `mise.toml` and `rust-toolchain.toml` versions and
locked dependencies. Use `lib/main.dart`, never a desktop acceptance harness.
Run the relevant checks in `TESTING.md` on the exact candidate source, including
`python scripts/check-server-cores` on each OS. Current
CI builds and retains **unsigned candidates**, not public releases. A green CI
run does not establish installed VPN, signing, upgrade or physical-device acceptance.

The packagers validate required components, retain the complete bundle, and emit
`release-manifest.json`, `project-source-manifest.json` and `SHA256SUMS`. New
macOS/Windows/Linux output directories must be empty. Signing and stapling occur in a
temporary copy, never in an installed application or the original input bundle.
Unsigned ZIP filenames contain `UNSIGNED`; do not distribute them to end users.

`sourceAtPackaging` records the current public source files, including permitted
uncommitted source. It is not proof that an arbitrary input binary was built from
those files. Build and package in the same immutable source checkout; retain its
build/check transcripts, source archive and artifact hashes together. Toolchain
metadata describes the packaging environment, not a reconstructed binary history.

Review and snapshot the selected public project files with:

```sh
python3 scripts/package-source --list
python3 scripts/package-source --output .build/release-source
```

The explicit source selection excludes local working files, build artifacts,
toolchains, credentials and generated output. It includes modified vendored source
and lockfiles. **This is project source, not a complete transitive dependency source
release.** Assemble matching external dependency source and license notices before
shipping, and retain the build instructions. Follow the source obligations in
`THIRD_PARTY_NOTICES`.

Collect the exact external Go module ZIP sources, sums and embedded license
inventory alongside the matching project snapshot:

```sh
python3 scripts/package-dependencies --output .build/new-release-dependency-source
```

This verifies the resolved Go workspace and includes TUIC's pinned sing-quic and
both runtime QUIC dependencies. Local workspace modules are in the project
archive. The manifest states its Go-runtime scope; retain the existing Rust,
Flutter/plugin source and licensing obligations as well. SDKs and disposable
sing-box/Mihomo fixture binaries are excluded from these source archives.

## macOS

Use a provisioned Developer ID identity with the application's existing
NetworkExtension, app-group and Keychain entitlements. Do not change those IDs
for an upgrade. Create an archive in a separate output directory:

```sh
flutter build macos --release --config-only --target=lib/main.dart
xcodebuild -workspace macos/Runner.xcworkspace -scheme Runner -configuration Release \
  -archivePath .build/release/Elarni.xcarchive ARCHS=arm64 archive
```

Export once in Xcode using Developer ID and retain the resulting
`ExportOptions.plist` outside source control. Store notarization credentials with
Apple's `notarytool store-credentials`; never put passwords or private keys in
scripts, logs or this repository. Package with the paths/profile you created:

```sh
python3 scripts/package-macos --archive /absolute/path/Elarni.xcarchive \
  --export-options /absolute/path/ExportOptions.plist \
  --notary-profile YOUR_KEYCHAIN_PROFILE --output /absolute/path/new-release-directory
```

Alternatively pass `--app /absolute/path/exported/Elarni.app`. The script checks
app/extension versions, resources, Developer ID/hardened runtime, notarizes the
staged app, retains the service receipt/log, staples and validates the ticket,
runs Gatekeeper assessment, and archives the stapled result. Inspect warnings in
`notarization-log.json`, even when Apple's status is Accepted.

An unsigned build can be packed with `--app ... --unsigned` for CI structure checks.
It does not qualify distribution. Run the installed suite and operator matrix in
`MACOS_ACCEPTANCE.md` on a disposable account/machine using the actual signed release.
Do not replace or retest the working VPN carrying a development session.

`--app ... --development` packs an app built with the team's Apple Development
identity (the archive commands above with `build` and `-derivedDataPath` in place
of `archive`, from a session with an unlocked login keychain). It is
not notarized, and its packet tunnel loads only on Macs in its provisioning
profile. Add `--dmg` in any mode for a drag-to-Applications disk image next to the
ZIP.

## Windows

On Windows, build `flutter build windows --release --target=lib/main.dart`. Keep
the entire `build/windows/x64/runner/Release` folder. Use Windows SDK SignTool and
an installed production signing certificate. The timestamp URL comes from the
certificate provider; the thumbprint identifies a certificate and is not a key.

```powershell
python scripts/package-windows --bundle build/windows/x64/runner/Release `
  --output C:\release\new-candidate --signtool C:\path\to\signtool.exe `
  --certificate-thumbprint YOUR_CERTIFICATE_THUMBPRINT --timestamp-url YOUR_RFC3161_URL
```

The script signs staged EXE/DLL files and verifies Authenticode on every EXE/DLL.
It preserves and verifies the official Wintun signature. Omit signing arguments
only when the input files are already signed; verification still runs. `--unsigned`
creates a development candidate and never performs or claims signature validation.
`--msi` also builds a per-machine MSI from the staged (and signed) files with WiX
Toolset v5 (`dotnet tool install --global wix --version 5.0.2`; v6 and later add a
maintenance-fee EULA). It installs to `%ProgramFiles%\Elarni` with a Start menu
shortcut, upgrades in place through a fixed UpgradeCode, and runs
`elarni.exe --unregister` for the uninstalling user. Each install or upgrade also
runs `elarni-core.exe --install-helper` to set up the VPN helper copy described
below, so the first connection after it asks only once. A new install (not an
upgrade or repair) then runs `elarni-core.exe --vpn-service add [UserSID]`: the
demand-start ElarniVPN service (LocalSystem, run from the helper copy) starts the
helper for the installing account without a consent prompt; Settings › Connection
› Connect without administrator approval adds or removes the current account
behind one prompt, and the service is deleted when no account is left.
`--install-helper` points an existing service at the new build. A real uninstall
(not an upgrade) runs `elarni-core.exe --uninstall-helper`, which deletes the
service, stops a running helper, removes a DNS block it left and deletes
`%ProgramFiles%\Elarni VPN Helper`.

The ZIP and the MSI ship the VC++ runtime (`msvcp140.dll`, `vcruntime140.dll`,
`vcruntime140_1.dll`) next to `elarni.exe`, so users need no VC++ redistributable.
The build takes them from Visual Studio's C++ workload, and the script rejects a
bundle without them. Validate clean extraction, launch from a path with spaces,
encrypted persistence, UAC denial/approval, traffic/DNS and cleanup on the real
Windows target.

The ZIP's own `elarni-core.exe` can be replaced by its user, so UAC starts it only
once per build. The first VPN connection of each build asks twice: once for that
`elarni-core.exe` to copy itself and `wintun.dll` into
`%ProgramFiles%\Elarni VPN Helper` (writable only by administrators), then to start
that copy. Every later prompt starts only the copy, so keep the ZIP in a folder
other programs cannot change until that first connection. A helper that stops
unexpectedly leaves its DNS block in place, so DNS cannot leak around the
tunnel. Elarni's next start or connection asks once (one UAC prompt) to remove it
before resolving any name; **Repair VPN setup** or a restart also removes it.

## Linux

On the supported Ubuntu build host:

```sh
flutter build linux --release --target=lib/main.dart
python3 scripts/package-linux --output .build/new-linux-release
```

Publish checksums through the authenticated release channel and sign the published
release metadata with the release operator's established key. A checksum alone
does not authenticate a download. Test the actual `.deb` installation, AppImage and
portable archive on the supported desktop/keyring/polkit environments; `sudo python3
scripts/check-linux-elevation --user USER --appimage Elarni-*.AppImage` runs the
elevated VPN from the AppImage's FUSE mount. Follow
`linux/README.md` and the isolated Linux checks in `TESTING.md`.

## Upgrade, rollback and publication checklist

- Choose one official HTTPS download/support location and a security-report contact.
  Publish supported platforms, privacy/data handling, protection boundaries and
  known limitations alongside downloads; do not promise an always-on kill switch.
- Increment `pubspec.yaml` version/build once for each public release. Do not reuse
  a public version for different bytes. App/extension/native bundle versions must agree.
- Retain the complete prior signed release. Before upgrade, disconnect and quit the
  test app; replace only the application bundle/folder or upgrade the `.deb`. Keep
  application data, Keychain/DPAPI/Secret Service identity, and bundle IDs intact.
- In a disposable fixture, install the old build, import data, save selections,
  settings and routing, upgrade to the new build, relaunch, connect and disconnect.
  Check backup restore, rejected/corrupt data and interrupted replacement. Verify
  no orphan helpers/routes/DNS remain. For a portable ZIP, extract the whole new
  directory before replacement; never mix old and new DLL/helper files.
- Test rollback against the new catalog. If a future migration is not backward
  compatible, restore the pre-upgrade encrypted backup with its matching old build.
  Never advertise downgrade safety from a successful forward build alone.
- Verify uninstall removes application components while preserving user data unless
  the user explicitly requests its removal. The Windows portable ZIP has no
  uninstaller: quit Elarni and run `elarni.exe --unregister` before deleting the
  folder. It removes the link handlers and launch-at-login entry under HKCU and keeps
  `%LOCALAPPDATA%\Elarni` and saved preferences. Then run
  `elarni-core.exe --uninstall-helper` from an administrator command prompt in that
  folder to remove the ElarniVPN service and `%ProgramFiles%\Elarni VPN Helper`; without elevation it exits 1
  and changes nothing. A portable Linux archive or AppImage leaves `/opt/elarni-vpn-helper`.
- Record what a connected, idle Elarni costs on each desktop: `python scripts/measure-idle
  --seconds 300` prints each Elarni process's share of one CPU core (the battery cost)
  and its memory; `--cpu-limit` and `--memory-limit` fail past a budget. On Windows
  run it from an elevated terminal to read the service too. Android's vpn suite, run
  with `--sleep-minutes 10` for a release, reports the app's CPU time and PSS for an
  idle minute and per minute asleep in its `Measured:` lines. iOS needs a signed device and Xcode's energy gauges.
- Complete exact-release OS acceptance and source/license review. Publish the signed
  packages, corresponding source, notices, checksums and release notes together.
  Packaging scripts do not upload releases or select signing credentials.

Native-tool references: [Apple notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow),
[Microsoft SignTool](https://learn.microsoft.com/en-us/windows/win32/seccrypto/signtool),
[Windows packaging options](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/packaging/).
