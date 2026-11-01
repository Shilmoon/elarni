# Per-app routing profiles

On desktop, open Routing → Per-app routing; on Android, Settings → Apps & routes.
The editor identifies the current OS as **macOS profile**, **Windows profile** or
**Linux profile**. Select applications, browse for executables, or enter process rules. Save applies the policy through the
existing tunnel settings transaction and enables Xray TUN when needed.

- **Bypass:** listed apps connect directly; other apps use normal routing.
- **Only listed:** listed apps use normal routing; other and unidentified
  processes connect directly.
- **Off:** normal routing for all apps.

DNS and local SOCKS/HTTP listeners keep their existing rules. This feature routes
identified TUN traffic; it is not an application firewall or a kill switch.
Rules match the process image, which is not an identity: any program you run can
copy or rename itself to a listed path or name. In **Bypass** mode that lets it
leave the tunnel, so list only apps you trust and prefer exact paths in folders
other users cannot write.
macOS `.app/` selections include executables and helpers within that bundle.
Windows selections use an exact executable path. Select additional helpers when
they run from other paths. Apps that install each update into a new
`app-<version>` folder beside `Update.exe`, such as Discord, are selected as
their install folder so the rule survives updates; select such an app again if
its rule was saved by an earlier version. Windows names and paths match without
case sensitivity.
A process name matches that name in any directory;
a path ending in `/` matches executables beneath that directory.
Linux selections use the running binary's resolved path and match names and paths
case-sensitively. Snap, Flatpak and
script launchers are not listed because they never run as the matched process;
start the app and select it from the running processes instead.

On Android, open Settings → Per-app routing and select installed applications.
Rules use package names such as `com.example.browser`; apps sharing a UID also
share their routing policy. Saving an active policy enables system VPN mode.
The app's own protected connections bypass its VPN, and Android work profiles
have a separate VPN domain.

## Sharing

Each OS uses a separate profile: macOS app bundles and Windows executables are
not interchangeable. **Copy macOS profile** or **Copy Windows profile** copies
routing-only JSON tagged for that OS. Send it as text or save it as a `.json`
file using any sharing service. The recipient copies the JSON and selects
**Paste macOS profile** or **Paste Windows profile**, reviews the rules, then
chooses **Save**. Cancel discards the
draft. Copying does not apply unsaved edits. Profiles contain application paths,
which may contain usernames; they contain no server credentials or subscriptions.

Version 1 example:

```json
{
  "format": "elarni-per-app",
  "version": 1,
  "platform": "macos",
  "mode": "bypass",
  "processes": ["/Applications/Example.app/", "curl"]
}
```

`platform` is `macos`, `windows`, `linux`, or `android`; `mode` is `off`,
`bypass`, or `proxyOnly`.
Windows JSON paths escape backslashes, e.g. `"C:\\Apps\\Example.exe"`.
Android profiles require package names and reject executable paths, wildcards
and other platforms' identities. In Android's **Package & profile tools**, paste
JSON and choose **Load into draft**, then **Save changes** to apply it. **Export
draft profile** saves the current draft through Android's file picker without
applying it. Android profiles retain the same version 1 envelope.
Imports reject another platform, unknown fields/versions, invalid modes, control
characters, padded or empty rules, more than 256 rules, rules exceeding 1024 UTF-8
bytes, and input exceeding 512 KiB. An active policy needs at least one rule.
Import, copy and Save also reject Windows drive/UNC paths in macOS profiles and
absolute macOS/Unix paths in Windows profiles, even if the JSON platform tag was
changed by hand. Rejected imports leave the draft's mode and app list unchanged.
Bare process names are not translated or guessed from another OS. Existing
version 1 profiles with valid local rules remain compatible; no migration is
needed.
Paths must match the recipient's installation; use executable names deliberately
when portability within the same platform matters more than path specificity.
