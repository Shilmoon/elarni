# Testing

Run the checks for what you changed. Each run through `scripts/check-tests` or
`scripts/check_report.py` writes `.build/check-results/<run>/summary.json` and
`output.log`. CI (`.github/workflows/checks.yml`) runs the host checks below on
Ubuntu, Windows and macOS. Its release jobs build unsigned candidates without
secrets: the Linux, Windows (ZIP and MSI) and macOS (ZIP and DMG) packages, the
Windows and macOS diagnostic builds and an iOS device build. They also run the
Linux desktop host test, the pinned Wintun load test and the server core gate.
The Linux job runs on a self-hosted runner (label `elarni-linux`, on the Linux
server) through `scripts/check-linux-container`, all Linux checks at once. When
a branch changed anything Android builds from (always on main), it also builds
the unsigned Android release APK and runs the Android acceptance on x86_64
emulators over the server's KVM in the same container, whose volumes keep the
SDK, AVDs and Gradle caches. The Windows jobs run on a self-hosted runner
(label `elarni-windows`) in a Windows Server 2022 VM on the same server
([scripts/windows-ci-vm](scripts/windows-ci-vm/README.md)). The release Android
acceptance (signed APK, 10-minute Doze) and macOS stay on the Mac
(`scripts/check-mac`).

`git config core.hooksPath scripts/git-hooks` once per clone turns on a pre-push
hook that runs `flutter analyze` on changed Dart files, `gofmt` on changed Go
files and `cargo fmt --check` when Rust changed, in a few seconds.

## Host checks

These use synthetic loopback fixtures and never change routes, DNS or adapters.

| Changed | Command |
|---|---|
| Go under `Vendor/` | `sh scripts/check-tests go` (runs `go vet`, then `go test`) |
| Rust under `native/` or `Vendor/tun2proxy` | `sh scripts/check-tests rust` |
| Dart under `lib/`, `bin/`, `test/` | `sh scripts/check-tests flutter` |
| Swift (macOS only) | `sh scripts/check-tests swift` |
| Release tooling in `scripts/` | `python scripts/check_report.py -- python -m unittest discover -s scripts -p package_release_test.py -v` |
| Windows local-proxy flow | `python scripts/check-windows` |

Static checks, also run by CI on Ubuntu:

```sh
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --locked -- -D warnings
gofmt -l Vendor
```

`gofmt -l` reports every file in a CRLF checkout; run it where Go files have LF
line endings, as committed.

## Race checks

For changes to packet, session, timer, connection-tracking or diagnostics concurrency
in the Go core.
`-race` needs cgo and a C compiler (Linux and macOS; MinGW on Windows).

```sh
go test -race -count=1 ./Vendor/Xray-core/common/buf ./Vendor/Xray-core/common/signal ./Vendor/Xray-core/common/mux ./Vendor/Xray-core/app/proxyman/inbound ./Vendor/Xray-core/app/proxyman/outbound ./Vendor/Xray-core/transport/internet/hysteria ./Vendor/Xray-core/transport/internet/splithttp ./Vendor/Xray-core/transport/internet/grpc ./Vendor/Xray-core/proxy/tun ./Vendor/Xray-core/proxy/socks ./Vendor/libXray/cmd/elarni-core
go test -race -tags=elarni_diagnostics ./Vendor/Xray-core/common/flightrecorder ./Vendor/libXray/share -run 'TestCollector|TestXHTTP|TestImportedClientsCarryLoopbackTraffic' -count=1 -timeout=120s
```

## Server core gate

Every release candidate must reach the newest upstream server cores. On each OS,
`python scripts/check-server-cores` downloads the latest Xray-core, 3x-ui and
Remnawave node cores for that host, checks them against their published SHA-256
digests, prints their versions and runs `TestImportedClientsReachUpstreamServerCores`:
clients imported from subscription links and JSON (REALITY with the ML-KEM key
share, pinned and `allowInsecure` TLS, XHTTP, VLESS encryption, Trojan,
Shadowsocks 2022, Hysteria2 with salamander and port hopping) carry TCP and UDP
through each core. Remnawave ships only for Linux and 3x-ui not for macOS, so the
Linux run covers all three. The cores stay in `.build/server-cores`; `--cached`
reruns the last downloads offline.

## TUIC fixture

TUIC traffic checks need the pinned sing-box server, built separately and never
bundled with the app. The runners look for it at `.build/tuic/tools/sing-box`, or
at the path in `ELARNI_TUIC_SERVER`.

```sh
GOBIN="$PWD/.build/tuic/tools" go install -tags=with_quic github.com/sagernet/sing-box/cmd/sing-box@v1.14.0
```

## Disposable test hosts

These suites change routes, DNS, adapters or system services, or need
privileges. Run them only on a disposable test machine, never beside a working
VPN. Build the platform release first.

Linux (`flutter build linux --release`):

- `sudo python3 scripts/check-headless [--bundle DIR]` — headless daemon acceptance
  with a disposable keyring and catalog. It re-runs itself in private mount,
  network and PID namespaces (`unshare`) and refuses host networking.
- `sudo python3 scripts/check-linux-vpn [--case NAME] [--protocol vless|tuic-native|tuic-quic]`
  — VPN acceptance; every network change happens in new namespaces.
- `sudo python3 scripts/check-linux-elevation --user USER [--appimage FILE]` — real
  pkexec denial and VPN ownership on a private polkit/system bus; `--appimage`
  runs the user side from that AppImage's FUSE mount (needs `fuse3`).
- `python3 scripts/check-linux-storage` — the real Secret Service with a
  disposable home and private D-Bus. Run it unelevated.
- `python3 scripts/check-linux-desktop [--display x11|wayland]` — native GTK
  channels and the release UI in private sessions. Run it as the normal test user.
  It builds the `test/linux_desktop_acceptance.dart` harness unless
  `--harness DIR` names a prebuilt one.

Windows: `python scripts/check-windows-vpn` from an elevated terminal on the test
host (TUN acceptance with synthetic HTTP and DNS peers). Its `per-app` case runs
`test/windows_vpn_features.dart` and needs Flutter.

macOS: follow [MACOS_ACCEPTANCE.md](MACOS_ACCEPTANCE.md).

Android: `python3 scripts/check-android --serial EMULATOR [--case native|catalog|ui|vpn]`
on the named disposable emulators described in [android/README.md](../android/README.md).
The vpn suite times a Wi-Fi to mobile data handover and the wake after `--sleep-minutes`
(a quarter by default, 10 for release acceptance) with the screen off in Doze; its `Measured:`
lines report both, and the app's CPU time and PSS for an idle connected minute and per
minute asleep. `--avd NAME` (repeatable, also with one name twice to shard its suites)
boots the emulators for the run.

iOS: `sh scripts/check-ios SIMULATOR-UDID`. The Simulator has no tunnel, so its
lock/unlock test covers the app only; the VPN across a lock needs a signed iPhone.

Lid close and open (Windows, macOS, Linux) need a person: with Elarni connected, run
`python scripts/measure-wake [--proxy http://127.0.0.1:PORT] [--sleeps N]`, close the
lid, open it. It prints the time from the wake to the first working request and fails
past `--limit` (30 s). `python scripts/measure-idle` reports what a connected, idle
Elarni costs in CPU and memory; see [RELEASING.md](RELEASING.md).
