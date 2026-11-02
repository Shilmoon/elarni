# Testing

While iterating, `python scripts/check-changed` runs the checks your changes
affect. Each run writes `.build/check-results/<run>/summary.json` and `output.log`.
`git config core.hooksPath scripts/git-hooks` adds a fast pre-push format and
analyze check.

## Host checks

These use loopback fixtures and never change routes, DNS or adapters.

| Changed | Command |
|---|---|
| Go under `Vendor/` | `sh scripts/check-tests go` |
| Rust under `native/` or `Vendor/tun2proxy` | `sh scripts/check-tests rust` |
| Dart under `lib/`, `bin/`, `test/` | `sh scripts/check-tests flutter` |
| Swift (macOS only) | `sh scripts/check-tests swift` |
| Kotlin logic under `android/` (needs the Android SDK and native build) | `android/gradlew -p android :app:testDebugUnitTest` |
| Release tooling in `scripts/` | `python -m unittest discover -s scripts -p package_release_test.py` |
| Windows local proxy | `python scripts/check-windows` |
| Everything CI runs on this OS | `python scripts/check-changed --all` |
| Any check on a Mac, over SSH | `python scripts/check-mac --host user@mac [-- <command>]` |

Lint, as CI runs it:

```sh
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --locked -- -D warnings
gofmt -l Vendor
```

For Go concurrency changes, also run `sh scripts/check-tests race` (needs cgo).

## Fuzzing

Subscription and link parsing reads provider bytes. The normal suites replay the
fuzz seeds: `go test` runs the `Fuzz*` targets in `Vendor/libXray/share` over the
package's test fixtures and `testdata/fuzz`, and `cargo test` runs a short
mutation pass over the hy2, routing and profile parsers (`fuzz_tests.rs`). To
fuzz longer, for example after changing a parser:

```sh
cd Vendor/libXray && go test -run='^$' -fuzz='^FuzzImportClientProfiles$' -fuzztime=90s ./share/
ELARNI_FUZZ_ITERATIONS=200000 cargo test -p elarni-domain fuzz_ -- --nocapture
```

The other Go targets are `FuzzClientLink`, `FuzzSubscriptionMigration` and
`FuzzSubscriptionFetchOptions`. Keep the input Go writes to `testdata/fuzz/` for a
failure as a regression seed; a Rust failure prints its input.

Helper tools have loopback self-tests: `scripts/check-macos-harness` (the macOS
acceptance fixture) and `scripts/check-protocol-benchmark` (the live-server
`scripts/benchmark-protocols`, with Chromium).

## Server cores

`python scripts/check-server-cores` downloads the newest Xray-core, 3x-ui and
Remnawave cores, verifies their checksums and checks that imported clients carry
TCP and UDP through each. Run it on every OS before a release.

## TUIC fixture

TUIC checks need a pinned sing-box server at `.build/tuic/tools/sing-box` (or
`ELARNI_TUIC_SERVER`):

```sh
GOBIN="$PWD/.build/tuic/tools" go install -tags=with_quic github.com/sagernet/sing-box/cmd/sing-box@v1.14.0
```

## Disposable test hosts

These change routes, DNS or adapters. Run them only on a test machine without
another VPN, against a release build.

- Linux: `scripts/check-headless`, `check-linux-vpn`, `check-linux-elevation`
  (as root), `check-linux-storage` and `check-linux-desktop` (as a normal user).
- Windows: `python scripts/check-windows-vpn` from an elevated terminal.
- macOS: `python3 scripts/check-extension --fixture <file>` on a disposable Mac
  account, with `macos/Checks/AcceptanceResponder.py` serving the network
  fixture (`--list` shows the cases, `--build-only` only compiles).
- Android: `scripts/check-android`, see [android/README.md](../android/README.md).
- iOS: `scripts/check-ios <simulator-udid>`, see [ios/README.md](../ios/README.md).
- Sleep and idle cost: with Elarni connected, `python scripts/measure-wake`
  (close and open the lid) and `python scripts/measure-idle`.
