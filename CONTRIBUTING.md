# Contributing

Bug reports and pull requests are welcome. For larger changes, open an issue first.
Report security problems privately (see [SECURITY.md](SECURITY.md)).

## Layout

- `lib/`, `test/`: Flutter desktop app; `bin/elarni.dart` is `elarni-cli`.
- `native/`: Rust profile compiler (`elarni-domain`) and TUN packet bridge.
- `Vendor/`: forks of Xray-core, libXray and tun2proxy, edited in place.
- `macos/`, `ios/`, `android/`, `windows/`, `linux/`: platform code.
- `scripts/`: build, check and packaging scripts.

## Setup

Toolchains are pinned in `mise.toml` and `rust-toolchain.toml`:

```sh
mise install
rustup show
git config core.hooksPath scripts/git-hooks
```

Platform builds also need their SDKs: Xcode, the Android SDK and NDK, or Visual
Studio with the C++ workload.

## Checks

```sh
python scripts/check-changed          # checks affected by your changes
python scripts/check-changed --all    # everything CI runs on this OS
```

See [docs/TESTING.md](docs/TESTING.md) for each suite. Tests use loopback
fixtures and must inject short timeouts instead of sleeping.

## Pull requests

- One change per pull request, with tests for new behavior and fixes.
- Conventional Commits, e.g. `fix(android): keep the tile state after a reconnect`.
- Add a line under "Unreleased" in [CHANGELOG.md](CHANGELOG.md).
- Contributions are licensed under GPL-3.0-or-later.
