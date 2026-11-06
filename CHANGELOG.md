# Changelog

Notable changes to Elarni. Versions follow `pubspec.yaml`.

## Unreleased

### Performance

- Android: a connection closes as soon as the app closes it, instead of up to a second later (Xray's default
  `downlinkOnly`). A burst of short connections no longer holds hundreds of TLS sessions: in a lab churn of 2000
  connections the core peaked at 39 instead of 185 MB and opened 30% more connections per second. An app that
  half-closes a connection and then waits for the reply loses the reply, as with the mihomo-based clients; a profile's
  own `policy` value still wins.
- Android: the core now uses the CPU's AES and carry-less multiply instructions. Go, loaded as a library, could not
  read the CPU features in a release build, so TLS ran on software AES. On a Snapdragon 8 Gen 3 test phone one
  download now runs at 136 instead of 37 MB/s and eight at 907 instead of 201, at a third to a seventh of the CPU
  per MB; uploads and new connections per second gain too.
- UDP in VPN (TUN) mode: datagrams waiting on a flow go to the server together, packed into
  full TLS records, instead of one record and one write each. On the test phone UDP bulk
  rises from 4.5 to 10.7 MB/s at half the CPU per MB; on desktops by 8-12%.
- The VPN (TUN) mode on Windows, Linux and Android runs on Xray's own TCP/IP stack instead
  of gVisor. One connection downloads up to 2.5x faster (VLESS: 2.75 vs 1.08 GB/s on the
  test host) at less than half the CPU per MB, now level with upstream Xray on every protocol.
- Linux: without a GPU (virtual machines, remote desktops), the window draws with Flutter's own
  CPU renderer instead of Mesa's software OpenGL: 80 MB less memory and a quarter of the CPU
  while it repaints. Set `FLUTTER_LINUX_RENDERER=opengl` to keep OpenGL.
- The window no longer redraws every second while the connection status is unavailable.
- Windows and Linux: a connected but idle VPN uses about 40% less CPU (Linux test namespace: 65 instead of 112 ms
  per minute across the app and its core processes). The core passes its traffic counters on only when they change,
  or every 10 s, instead of every second through each process; it reads its heap size without pausing the program;
  and the Linux network check reads link state without a thread handoff.
- Android: the 2-second status refresh no longer reloads every settings title, and the screen's clock stops while
  the app is in the background. Idle CPU in the minute after heavy traffic drops by about a fifth (1020 vs 1260 ms
  per minute on the test phone); settled idle is unchanged.

### Changed

- The bundled Xray core is upstream main a52db8f6 (v26.10.31 and later), which adds Windows
  TUN fixes (starting with IPv6 disabled, reusing an adapter by name), MPTCP off on listeners
  by default, and fixes for QUIC sniffing and HTTP 100-continue.

## 0.4.1 - 2026-11-04

### Changed

- Release files are built on GitHub-hosted runners and come with build provenance
  (`gh attestation verify`) and a Sigstore-signed `SHA256SUMS`; see docs/RELEASING.md.
- Android: server tests run while connected, as on desktop. Other servers, direct
  TCP and ICMP are tested outside the tunnel; the selected server's proxy test still
  goes through it. While connected, a test runs 8 servers at a time with a health
  check between them, so failover isn't held up.

### Security

- Android: broadcasts from automation apps such as Tasker must carry the control
  key shown under Settings › General › Let other apps control the connection, as
  the string extra `key`; others are ignored. Existing automations need the key
  added (android/README.md has a Tasker example).
- Imported profiles can no longer name an address or port as `env:NAME`, which made
  the core substitute that local environment variable into server hosts and DNS
  lookups. Names, tags and passwords may still contain `env:`.

### Fixed

- RU routing from runetfreedom's geofiles works again: its geosite.dat passed the
  64 MiB limit. Downloaded geofiles (up to 256 MiB) are streamed to disk and trimmed
  to the categories your rules use; with Reduce routing-data size off, a file over
  64 MiB fails the refresh with a clear message.
- Android: connections no longer hang when the phone reuses a port the tunnel still
  held in TIME_WAIT, and connection bursts are no longer refused.
- iOS: the VPN recovers after a switch between Wi-Fi and cellular, or between two Wi-Fi
  networks. The tunnel restarts its core in place once the new network has held for
  6 s, and retries if the new network isn't ready yet.
- iOS and macOS: the packet tunnel no longer keeps every packet it wrote until it stops;
  download-heavy apps made iOS end the VPN at its 50 MB memory limit.
- iOS: diagnostics report the memory footprint iOS counts against that limit.
- A subscription refresh no longer reconnects when the active server changed only its
  REALITY shortId or SNI, which 3x-ui picks at random on every fetch. The stored values
  are kept for 24 hours after the server's last connect, so a shortId the panel retired
  is replaced at the next refresh after that.
- A JSON or Clash profile whose server has no port, or a host name with a space,
  slash or colon, is refused on import, as its share link already was, instead of
  failing to connect.
- `elarni-cli` without `HOME` (a systemd unit without `User=`) finds the root service's
  socket, or `$XDG_RUNTIME_DIR/elarni/control.sock`, instead of failing.
- Linux: a tunnel killed while it started can no longer leave a DNS redirect that the
  next start does not detect.
- Routing: a `regexp:` rule Go cannot compile (unbalanced groups or classes, a trailing
  backslash, a repeat with nothing to repeat, nested repeats, unknown escapes) is
  rejected on import instead of failing at connect.
- Windows: upgrading an install that never had the ElarniVPN service sets it up for the
  installing account once, so connecting stops asking for administrator approval. An
  install run as SYSTEM (Intune, SCCM) sets up no account.

### Performance

- Faster downloads and connects on every platform: WireGuard, QUIC (Hysteria2,
  XHTTP/3, TUIC), XHTTP and the TUN stacks got larger, bounded buffers, and a stalled
  QUIC stream no longer freezes its connection. On Windows, 8-stream downloads are
  1.2-3.3x faster on 22 of 24 protocols, with 1.5-5x less CPU per GB.
- Server-first protocols (SMTP, IMAP, MySQL, SSH and others) get their greeting at
  once instead of after up to 0.7 s.
- Per-app routing looks a connection's process up once instead of once per rule.
- The core returns memory after traffic stops (desktop) and returns freed memory to
  the system (Android).

## 0.4.0 - 2026-11-01

First open-source release.

### Added

- Release builds check this repository's releases once a day and show a notice
  when a newer version exists (Settings › General › Update feed; nothing installs).
- Settings › General has a language choice, English or Russian.
- Android: the Quick Settings tile names the connected server.

### Changed

- Every platform uses Elarni identifiers: `com.elarni.*` bundle, package and
  desktop IDs, `Elarni` data folders and registry keys, `/var/lib/elarni`,
  `/run/elarni` and `/etc/elarni` for the Linux service, and `elarni://` links.
  Builds from before this change are a separate app: remove the earlier build
  first, then install this release and re-add subscriptions. On Windows, the
  earlier build's uninstaller, or `elarni.exe --unregister` for its portable ZIP,
  releases its link handlers and login item. Backups from earlier builds cannot
  be restored.
- Desktop: per-app routing is its own Routing tab, subscriptions open with their
  servers expanded, and the Home server card is shorter.
- Connection recording is left out of release builds; it ships only in builds
  made with `ELARNI_RECORDING`.

### Security

- tokio 1.53.3 (RUSTSEC-2026-0386) and golang.org/x/net 0.62.0 (GO-2026-6860,
  GO-2026-6866).
