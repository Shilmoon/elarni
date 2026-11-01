<div align="center">

<img src="assets/branding/elarni-mark.png" alt="Elarni" width="112">

# Elarni

A cross-platform routing client on a forked Xray core.

[![Checks](https://github.com/Shilmoon/elarni/actions/workflows/checks.yml/badge.svg)](https://github.com/Shilmoon/elarni/actions/workflows/checks.yml)
[![License: GPL-3.0-or-later](https://img.shields.io/badge/license-GPL--3.0--or--later-blue.svg)](LICENSE)

</div>

## Features

- VLESS, VMess, Trojan, Shadowsocks, SOCKS, Hysteria2, TUIC and WireGuard: links, subscriptions, QR codes and config files
- System VPN (TUN) or local SOCKS/HTTP proxy, with per-app routing
- Routing profiles with rules, DNS and Happ-compatible provider routing
- Encrypted profile storage and portable encrypted backups
- `elarni-cli` for headless control, and a boot service for Linux servers

## Download

Builds are on the [Releases](../../releases) page, each with a `SHA256SUMS` file.
Desktop and Android release builds check that page once a day and only show a
notice when a newer version exists; clear **Update feed** in Settings to turn it off.

| Platform | Requires | Guide |
|---|---|---|
| macOS | Apple Silicon, macOS 13+ | [docs/RELEASING.md](docs/RELEASING.md) |
| Windows | x64 | [docs/RELEASING.md](docs/RELEASING.md) |
| Linux | Ubuntu 22.04+, x86-64 | [linux/README.md](linux/README.md) |
| iPhone | iOS 18+ | [ios/README.md](ios/README.md) |
| Android | Android 11+, ARM64 | [android/README.md](android/README.md) |

## Build from source

See [CONTRIBUTING.md](CONTRIBUTING.md) for the layout, toolchains and checks.

## Documentation

[Headless control](docs/HEADLESS.md) ·
[Per-app routing](docs/PER_APP_ROUTING.md) ·
[Subscription providers](docs/PROVIDERS.md) ·
[Diagnostics](docs/DIAGNOSTICS.md) ·
[Testing](docs/TESTING.md) ·
[Releasing](docs/RELEASING.md)

## License

[GPL-3.0-or-later](LICENSE). Vendored components keep their own licenses; see [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES).
Report vulnerabilities privately: [SECURITY.md](SECURITY.md).
