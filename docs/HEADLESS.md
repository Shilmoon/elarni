# Local and headless control

`elarni-cli` controls Elarni on Linux, macOS and Windows. The running GUI
and the background host expose the same catalog and connection controller. Run
the CLI as the same OS user. Starting another host does not take over an existing
catalog; use the existing host or close it before starting a daemon.

The CLI is bundled beside `elarni` / `elarni.exe`, and inside
`Elarni.app/Contents/MacOS` on macOS. The macOS CLI link resolves to its own
background helper bundle so CLI queries cannot re-register the VPN host app.
From a source checkout, the client also
runs with `dart run bin/elarni.dart`; building a standalone executable uses
`dart compile exe bin/elarni.dart -o elarni-cli` on the target OS.

## Start and stop

With the GUI running, commands work immediately:

```sh
elarni-cli status
elarni-cli profiles
elarni-cli connect
elarni-cli disconnect
```

For a foreground daemon, close the GUI and run `elarni-cli daemon` in another
terminal. Stop it with `elarni-cli shutdown` or Ctrl+C. `shutdown` stops only
daemon hosts; it refuses to close a GUI session. On macOS and Windows, `daemon`
launches the bundled native app without its window or tray. To select a different
bundle, pass `daemon --app /absolute/path/to/Elarni` (macOS app executable) or
`daemon --app C:\path\elarni.exe` (Windows). Keep the entire bundle together.
These hosts still require the OS user session and the normal VPN permissions;
headless control does not bypass macOS VPN consent. On Windows the first VPN
connection of each run asks for administrator approval, unless an administrator
allowed the account in the ElarniVPN service (Settings › Connection › Connect
without administrator approval; the MSI allows the installing account on a new
install). The service then starts the VPN helper without a prompt; it does not
run the daemon. Configure headless supervision using the OS session manager; the
CLI does not install a launchd job or a service that runs the daemon.

Linux's standalone daemon needs no display or desktop login. Its encrypted
storage and optional systemd boot service are documented in
[linux/HEADLESS.md](../linux/HEADLESS.md). `daemon --core PATH --domain PATH` chooses
its native binaries. Only Linux supports `--keyring-password-file PATH`.

Daemon shutdown releases its connection resources. Linux and Windows daemons
retain saved connection intent across process restarts and reconnect when the
next daemon starts; `disconnect` explicitly clears it. macOS preserves its native
controller's recovery rules. Use `disconnect` before shutdown when the next host
must remain disconnected.

On macOS, Disconnect also succeeds when no saved VPN profile exists. If the
host exits during subscription publication or backup restoration, the next host
rolls back the catalog and reconciles the saved VPN plan before accepting new
work. It stops the provider and disables On Demand; it does not automatically
reconnect after this recovery. A failed reconciliation remains pending across
relaunches. Explicit Connect is available after recovery succeeds.

## Endpoint and security

| System | Default endpoint |
|---|---|
| Linux root/system service | `/run/elarni/control.sock` |
| Linux desktop user | `$XDG_RUNTIME_DIR/elarni/control.sock`, otherwise `$HOME/.local/state/Elarni/control/control.sock` |
| macOS | `$HOME/Library/Containers/com.elarni.mac/Data/.elarni/control.sock` |
| Windows | `%LOCALAPPDATA%\Elarni\control\endpoint.json` |

`--socket PATH` selects a client/daemon endpoint. Set `ELARNI_CONTROL_SOCKET`
before launching the GUI to override its endpoint too. On macOS, a custom path
must be accessible to the sandboxed app. Use a dedicated private directory.

Unix uses a mode-0600 socket inside a mode-0700 directory. Windows uses an
ephemeral IPv4 loopback port and a random 256-bit token, stored in a directory
whose ACL permits only the current user. Windows PowerShell is used to establish
and verify that ACL; failure leaves the control server disabled. The CLI handles
authentication; the token is never a command argument or logged. No control port
is bound to LAN interfaces. A lock excludes a second owner and permits recovery
of stale endpoints after a crash. Requests are bounded and errors omit profile
secrets. OS administrator access and other programs running as your user remain
within the local trust boundary.

## Commands

Every response is a JSON object: `{"success":true,"data":{...}}` or
`{"success":false,"error":"code"}`. Exit status is 0 for success/help and 1
for failure. Inputs with credentials belong in private files or stdin, not shell
arguments. `profiles` is a redacted list; explicit `call` exports may contain
sensitive configuration, so protect redirected output.

```sh
elarni-cli import profile.txt                 # use - to read stdin
elarni-cli select PROFILE_ID_OR_EXACT_NAME
elarni-cli probe PROFILE_ID_OR_NAME           # optional HTTP-204 check URL
elarni-cli settings                          # read settings
elarni-cli settings changes.json             # merge a partial settings object
elarni-cli refresh SUBSCRIPTION_ID
elarni-cli failover PRIMARY BACKUP            # optional third targets JSON file
elarni-cli commands                          # supported native method names
elarni-cli call METHOD arguments.json         # use - for a JSON object on stdin
```

Source-fetch approval returns `subscriptionId`, `riskCodes` and `challenge`.
Inspect the risks, then send `refresh SUBSCRIPTION_ID CHALLENGE_TOKEN`.
No command silently approves a source. Catalog changes apply at once.

`failover` retains the controller's policy boundaries: Linux/Windows daemon hosts
may authorize profiles across sources; GUI sessions and macOS require profiles
from the same subscription, with PRIMARY already selected. Advanced recovery configurations use
`call configureAutomation`. Profile IDs avoid ambiguity when names repeat.

`connected` means the local core answers. Windows and Linux also check that the
server passes traffic: once after Connect, then each minute while traffic leaves
or the last check failed. `state` and `runtimeMetrics` report the result
as `liveness`: `ok`, `noTraffic`, or null before the first check. The check
fetches the default failover endpoints through the connection and changes nothing.

With `connectOnUntrustedWiFi` on, Windows and Linux connect when the host joins a
Wi-Fi network whose name is not in `trustedWiFiNetworks` (up to 64 names of 1–32
bytes). Trusted networks, wired links and a Disconnect stay as they are until the
next network. Linux reads the name with `nmcli`, then `iw`. Windows needs location
access for desktop apps; without it `automationStatus` reports `wifi` as
`locationDenied`.

## Full method reference

The `call` command exposes these existing native contracts. Arguments are JSON
objects; omit the input file for methods with no arguments. Validation, active
connection transitions, publication rollback and provider sharing restrictions
are enforced by the same controllers as the GUI.

| Methods | Arguments |
|---|---|
| `state`, `subscriptions`, `routingProfiles`, `tunnelSettings`, `automationStatus`, `runtimeMetrics` | None |
| `inboundCredentials` | None; returns the saved SOCKS/HTTP `username` and `password`, or `{}` |
| `connect`, `disconnect`, `repairTunnel` | None |
| `systemInfo`, `routeTable` | None |
| `setLaunchAtLogin` | `enabled` (boolean); controls desktop login registration. Not exposed by the Linux standalone service: manage it with systemd. |
| `importClientProfiles` | `content` (profile text or subscription URL); imports always use supplied text, without a picker/camera. |
| `addSubscription` | `url` |
| `refreshSubscription` | `id`, optional `challenge`, `format` |
| `selectNode` | `id` |
| `setNodeFavorite` | `nodeId`, `favorite` (boolean) |
| `setNodeIPPreference` | `nodeId`, `preference` (`ipv4`, `ipv6`, or null for app default) |
| `selectProfileGroup` | `nodeId`, `group`, `choice` |
| `renameSubscription` | `id`, `name` (null restores its automatic name) |
| `deleteSubscription` | `id` |
| `updateSubscriptionFetchOptions` | `id`, `options` containing `fallbackHosts`, and optional `connectAddress`, `httpHost`, `fragmentLength`, `fragmentInterval` |
| `updateTunnelSettings` | Full settings object from `tunnelSettings`; use the `settings` shortcut for partial updates. |
| `updateInboundCredentials` | `username`, `password` |
| `importRouting` | `content` (routing text) |
| `updateRoutingProfile` | `id`, `content` (routing text) |
| `duplicateRoutingProfile`, `deleteRoutingProfile`, `resetRoutingProfile` | `id` |
| `setRoutingProfileEnabled` | `id`, `enabled` (boolean) |
| `assignRoutingProfile` | `subscriptionId`, `profileId` (null removes the assignment) |
| `refreshRoutingGeofiles` | `id`, optional `file` |
| `configureAutomation` | `schemaVersion:1`, `enabled`, `policy` (`fixed`, `lowestLatency`, `orderedFallback`), `subscriptionID`, `nodeIDs`, `targets`; each target has `id`, `url`, `expectedStatus`, `expectedBody`. Select a member node first. |
| `pingNode` | `nodeId`, `protocol`, `method`, `mode`, `timeout`, `url`, `expectedStatus`, `expectedBody`; same options as the GUI. An ICMP probe may stop and restore a system VPN. |
| `shareClient` | `id`, optional `subscription:true`; returns export text and QR data subject to provider restrictions. |
| `exportCatalogBackup` | `password`; returns encrypted backup in `data.text`. |
| `restoreCatalogBackup` | `password`, `content` (the encrypted text returned above). Disconnect before restoring. |
| `exportEvidence` | Optional `issueCodes` array; returns redacted diagnostics directly. |
| `markRecording` | Recording builds only (DIAGNOSTICS.md). None; notes "problem seen now" in the connection recording (setting `recordDiagnostics`). |
| `exportRecording` | Recording builds only. `destination`: absolute path of a new ZIP, written on the controller's host as the controller's user. macOS ignores it and returns `path`, a ZIP in the sandboxed app's temporary folder. See DIAGNOSTICS.md. |

Backup and diagnostic methods never open file dialogs through this API. Save
`data.text` from a backup response, not the surrounding JSON envelope. Restore
uses that text in `content`. Passwords are passed via private JSON files/stdin.
Restoring follows the existing encrypted, validated catalog transaction and its
sharing restrictions; a bad password does not replace the catalog.

## Verification

`scripts/check-tests flutter` includes isolated transport, authentication, CLI,
JSON/size limits, duplicate-owner, shutdown and concurrent-stop regressions.
On macOS, `scripts/check-macos-control` (also in the Swift suite) exercises the
registered Swift handler with isolated catalogs and injected VPN preferences. It
checks Stop during pending startup, recovery failures and retry, and unreadable
storage. It also runs the production Dart transport in an ad-hoc signed App
Sandbox fixture, checking Unix permissions, separate-process ownership, crash
recovery and endpoint cleanup. It never starts a VPN or reads the real catalog.
`scripts/check-windows` covers native encrypted backup/restore, diagnostic export
and loopback traffic through the shared controller. Linux daemon acceptance is
`python3 scripts/check-headless`, which creates private network/mount/PID
namespaces and a disposable keyring/catalog. See `TESTING.md` for prerequisites.

Target builds and actual Windows ACL/UAC/session behavior and macOS signed
Keychain/NetworkExtension behavior must be checked on their respective OSes.
Loopback or cross-platform unit tests do not establish installed-VPN acceptance.
