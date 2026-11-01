# Elarni

A cross-platform routing client: a Flutter UI over a forked Xray core.
Human contributors: see [CONTRIBUTING.md](CONTRIBUTING.md); these notes are for coding agents.

## Layout

- `lib/`, `test/`: Flutter app and its tests. `bin/elarni.dart` is the `elarni-cli` headless controller.
- `native/`: Rust workspace. `elarni-domain` parses profiles and compiles Xray configs;
  `elarni-packet-bridge` carries TUN packets over `Vendor/tun2proxy`.
- `Vendor/Xray-core`, `Vendor/libXray`: Go forks edited in place, joined by `go.work`.
  `Vendor/libXray/cmd/elarni-core` builds the core binary.
- `macos/`, `ios/` (Swift, packet tunnel), `android/` (Kotlin), `windows/`, `linux/` (C++ runners).
- `scripts/`: build, check and packaging entry points.

## Toolchains

Versions are pinned in `mise.toml` and `rust-toolchain.toml`. Run `mise install` and
`rustup show` once; the mise shims directory must be on PATH.

## Checks

Run `python scripts/check-changed` after every change. It selects the checks your
uncommitted changes affect, runs them and prints the failing output; `--base <commit>`
also covers committed work and `--all` runs everything CI runs on this OS. Reports land in
`.build/check-results/<name>/`. [docs/TESTING.md](docs/TESTING.md) lists each suite.

- Dart: analyze only the touched files (`flutter analyze --no-pub <files>`).
- Rust: `cargo fmt --all` and `cargo clippy --workspace --all-targets --locked -- -D warnings`.
- Go: `gofmt -l Vendor` must print nothing.
- Tests must not sleep through production timeouts; inject shorter ones
  (`DesktopProxy(replyTimeout:, helperExitGrace:, automationProbeSeconds:)` in Dart,
  `splithttp.SetSetupTimeout` in Go).
- Do not weaken assertions or skip failing tests to get a pass.

## Safety

Developers often run a live VPN. Do not run `check-windows-vpn`, `check-linux-vpn`,
`check-linux-elevation`, `check-headless`, or `netsh`, `route` and DNS commands unless asked:
they change routes, DNS or adapters and belong on disposable test hosts.

## Changes

- Keep a change to one purpose; follow a changed interface through every platform that uses it.
- Conventional Commits; add a line under "Unreleased" in `CHANGELOG.md`.
- Never commit keys, signing material, real server addresses or subscription URLs; tests use
  loopback fixtures.
- Pull requests state the AI tool used and what it did (see CONTRIBUTING.md).
