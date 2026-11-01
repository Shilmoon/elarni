# Contributing to Elarni

Bug reports, fixes and improvements are welcome. Open an issue before large
changes so the approach can be agreed first. Report security problems privately
as described in [SECURITY.md](SECURITY.md), not in public issues.

## Layout

- `lib/`, `test/`: Flutter desktop app and its tests. `bin/elarni.dart` is the `elarni-cli` headless controller.
- `native/`: Rust workspace with `elarni-domain` (profile parsing and Xray config compiling) and `elarni-packet-bridge` (TUN packets over `Vendor/tun2proxy`).
- `Vendor/Xray-core`, `Vendor/libXray`: Go forks edited in place, joined by `go.work`. `Vendor/libXray/cmd/elarni-core` builds the core binary. `third_party/modifications.json` records the changes to vendored code.
- `macos/`, `ios/` (Swift, packet tunnel), `android/` (Kotlin), `windows/`, `linux/` (C++ runners).
- `scripts/`: build, check and packaging entry points (sh and Python).
- `docs/`: guides for headless control, routing, diagnostics, testing and releases.

## Toolchains

Versions are pinned in `mise.toml` (Flutter, Go, Node, just) and
`rust-toolchain.toml` (Rust through rustup). Run `mise install` and `rustup show`
once, with the mise shims directory on PATH. Platform builds need their native
SDKs: Xcode for macOS and iPhone, the Android SDK and NDK for Android, Visual
Studio with the C++ workload for Windows.

## Checks

While iterating, run `python scripts/check-changed`. It picks the checks that
your uncommitted changes affect, runs them in parallel, and prints one line per
passing check and the output tail of each failing one. `--base <commit>` also
covers committed work, and `--dry-run` only lists the selection. Each run writes
`.build/check-results/<name>/summary.json` and `output.log`.

Before opening a pull request, run the full check for each area you touched:

| Changed | Command |
|---|---|
| Go under `Vendor/` | `sh scripts/check-tests go` |
| Rust under `native/` or `Vendor/tun2proxy` | `sh scripts/check-tests rust` |
| Dart under `lib/`, `bin/`, `test/` | `sh scripts/check-tests flutter` |
| Swift (macOS only) | `sh scripts/check-tests swift` |
| Release tooling in `scripts/` | `python scripts/check_report.py -- python -m unittest discover -s scripts -p package_release_test.py -v` |
| Windows local-proxy flow | `python scripts/check-windows` |
| Everything CI checks on this OS | `python scripts/check-changed --all` |
| Linux CI checks, from Windows or macOS (needs Docker) | `python scripts/check-linux-container` |

CI (`.github/workflows/checks.yml`) runs these on Ubuntu, Windows and macOS and
adds `check-tests lint` and `check-tests race` on Linux. Format Rust with
`cargo fmt`, Go with `gofmt` and Dart with `dart format`.

Tests use synthetic loopback fixtures. They must not sleep through production
timeouts; inject shorter ones instead, for example
`DesktopProxy(replyTimeout:, helperExitGrace:, automationProbeSeconds:)` in
Dart, `splithttp.SetSetupTimeout` in Go and `Automation.healthInterval` in
Android instrumentation.

### Suites that change the host network

`check-windows-vpn`, `check-linux-vpn`, `check-linux-elevation` and
`check-headless` change routes, DNS, adapters or system services. Run them only
on a disposable test machine, never beside a VPN you depend on.
[docs/TESTING.md](docs/TESTING.md) describes them and the Android, iPhone and
macOS acceptance suites.

## Pull requests

- Keep each pull request to one change, with tests for new behavior and bug fixes.
- Write commit messages in the Conventional Commits style used in the history,
  for example `fix(android): keep the tile state after a reconnect`.
- Update the guide in `docs/` or the platform README when behavior changes, and
  add a line under "Unreleased" in [CHANGELOG.md](CHANGELOG.md).
- By contributing you agree that your work is licensed under GPL-3.0-or-later.
