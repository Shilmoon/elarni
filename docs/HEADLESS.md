# Headless control

`elarni-cli` controls Elarni on Linux, macOS and Windows. It ships next to the app
(inside `Elarni.app/Contents/MacOS` on macOS); from source, run
`dart run bin/elarni.dart`. Run it as the same user as the app.

## Usage

With the app running, commands work right away:

```sh
elarni-cli status
elarni-cli profiles
elarni-cli connect
elarni-cli disconnect
```

Without the app, `elarni-cli daemon` runs it without a window; stop it with
`elarni-cli shutdown` or Ctrl+C. On macOS and Windows, `--app <path>` picks the
app bundle. A Linux daemon needs no desktop session; see
[linux/HEADLESS.md](../linux/HEADLESS.md) for its keyring and boot service.
Linux and Windows daemons reconnect on the next start unless you ran `disconnect`.

```sh
elarni-cli import profile.txt          # - reads stdin
elarni-cli select <profile id or name>
elarni-cli probe <profile id or name>
elarni-cli settings [changes.json]     # read, or merge a partial object
elarni-cli refresh <subscription id> [challenge]
elarni-cli failover <primary> <backup>
elarni-cli commands                    # all method names
elarni-cli call <method> [args.json]   # - reads a JSON object from stdin
```

Responses are JSON: `{"success":true,"data":{...}}` or
`{"success":false,"error":"code"}`; the exit status is 0 or 1. Pass credentials
in files or stdin, not as arguments. A new subscription source returns
`riskCodes` and a `challenge`; review them, then `refresh <id> <challenge>`.

## Endpoint

| System | Default endpoint |
|---|---|
| Linux (root service) | `/run/elarni/control.sock` |
| Linux (user) | `$XDG_RUNTIME_DIR/elarni/control.sock` |
| macOS | `~/Library/Containers/com.elarni.mac/Data/.elarni/control.sock` |
| Windows | `%LOCALAPPDATA%\Elarni\control\endpoint.json` |

`--socket <path>` (or `ELARNI_CONTROL_SOCKET` for the app) changes it. Unix uses
a 0600 socket; Windows uses a loopback port with a random token readable only by
your user. Nothing listens on the network.

## Methods

`call` exposes the same operations as the app, with JSON object arguments.

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
| `markRecording` | Recording builds only ([DIAGNOSTICS.md](DIAGNOSTICS.md)). None; notes "problem seen now" in the connection recording (setting `recordDiagnostics`). |
| `exportRecording` | Recording builds only. `destination`: absolute path of a new ZIP, written on the controller's host as the controller's user. macOS ignores it and returns `path`, a ZIP in the sandboxed app's temporary folder. |

Backups and diagnostics are returned in `data.text`; nothing opens a file dialog.
