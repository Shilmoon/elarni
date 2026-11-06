# Elarni

A cross-platform routing client: a Flutter UI over a forked Xray core.
Human contributors: see [CONTRIBUTING.md](CONTRIBUTING.md); these notes are for coding agents.

## Toolchains

Versions are pinned in `mise.toml` and `rust-toolchain.toml`. Run `mise install` and
`rustup show` once; the mise shims directory must be on PATH.

## Checks

Run `python scripts/check-changed` after every change. It selects the checks your
uncommitted changes affect (on Linux, with the lint CI runs for Go and Rust), runs them and
prints the failing output; `--base <commit>` also covers committed work and `--all` runs
everything CI runs on this OS. It exits non-zero when a changed file has no local check
(`android/`, `.github/`, ...): only CI covers those. A `FLAKY` line means a check passed only
on its retry; report it. Each run writes `.build/check-results/<UTC time>-<id>/summary.json`
and `output.log`. [docs/TESTING.md](docs/TESTING.md) lists each suite.

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

## Concurrency and remote runs

- Several agents may share one checkout. Check `git status`, `git log` and `git reflog` right
  before committing, and never switch branches or reset files you did not change. Work in a
  git worktree inside the session's folder (for example `claude -w`), one per task, removed
  when its pull request merges.
- `scripts/check-linux-container` (Linux CI in a warm Ubuntu 22.04 container, local Docker or
  `--host`) and `scripts/check-mac --host` (a kept workspace on a Mac) run one at a time per
  host: a second run is refused, not queued. Start one in the background and wait for it to
  exit; do not poll with `sleep`.
- The CI runs on one self-hosted Linux runner and one Windows VM, so pull requests queue behind
  main. Wait for a run with `gh run watch <id> --exit-status` in the background.

## Changes

- Keep a change to one purpose; follow a changed interface through every platform that uses it.
- Conventional Commits; add a line under "Unreleased" in `CHANGELOG.md`.
- Never commit keys, signing material, real server addresses or subscription URLs; tests use
  loopback fixtures.
- Pull requests state the AI tool used and what it did (see CONTRIBUTING.md).
