# Changelog

Notable changes to Elarni. Versions follow `pubspec.yaml`.

## Unreleased

### Fixed

- A JSON or Clash profile whose server has no port, or a host name with a space,
  slash or colon, is refused on import, as its share link already was, instead of
  failing to connect.

### Changed

- Release files are built on GitHub-hosted runners and come with build provenance
  (`gh attestation verify`) and a Sigstore-signed `SHA256SUMS`; see docs/RELEASING.md.
- Android: server tests run while connected, as on desktop. Other servers, direct
  TCP and ICMP are tested outside the tunnel; the selected server's proxy test still
  goes through it.

### Security

- Android: broadcasts from automation apps such as Tasker must carry the control
  key shown under Settings › General › Let other apps control the connection, as
  the string extra `key`; others are ignored. Existing automations need the key
  added (android/README.md has a Tasker example).

### Fixed

- A subscription refresh no longer reconnects when the active server changed only its
  REALITY shortId, which 3x-ui picks at random on every fetch.

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
