# Per-app routing

Desktop: Routing › Per-app routing. Android: Settings › Apps & routes. It needs
system VPN mode.

- **Bypass:** listed apps connect directly; everything else uses normal routing.
- **Only listed:** listed apps use normal routing; everything else connects directly.
- **Off:** normal routing for all apps.

Each listed app can also take a target of its own: Direct, Follow routing rules, Block,
a server from any subscription, or a local SOCKS5 or HTTP proxy without a login (for
example ByeByeDPI). Per-app routing covers only traffic that enters the VPN:

- DNS queries are not per-app: every app's queries that enter the VPN go to the
  resolver your routing profile sets. On Android, apps kept out of the VPN use the
  system resolver.
- Apps that use Elarni's own SOCKS or HTTP listener follow normal routing.

Rules match the program's path or name, which any program can copy. In Bypass
mode, list only apps you trust, by exact path in folders other users can't write.
This is routing, not a firewall or kill switch.

| Platform | Rules match |
|---|---|
| macOS | `.app/` bundles, including their helpers |
| Windows | exact `.exe` paths, case-insensitive; Squirrel apps such as Discord by install folder; Microsoft Store apps such as Claude by package; services by name |
| Linux | resolved binary paths, case-sensitive; Snap apps by `/snap/<name>/`; Flatpak apps by app ID; AppImages by image file |
| Android | package names; apps sharing a UID share a rule |

A bare name matches in any folder, and a path ending in `/` matches everything
below it.

Apps picked from the list get a rule that still matches after the app updates. On
desktop platforms an app that keeps each version in its own folder beside the
previous one matches that folder of versions, when it holds nothing else. Claude
Code, which the Claude app installs as `claude-code/<version>/<build>/`, is one; on
Linux, so is `~/.local/share/claude/versions/`. On Windows, a Microsoft Store app's
folder `WindowsApps\<name>_<version>_<arch>_<resource>_<publisher>\` matches as
`WindowsApps\<name>_<publisher>\`, its package family, so rules saved for an earlier
version match too.

## Apps a path does not name

Some apps run from a path that says nothing about them. Their rules name the app instead,
and the app list gives them these rules:

- `flatpak:<app id>` (Linux), such as `flatpak:org.mozilla.firefox`: a Flatpak app's
  programs run inside its sandbox, from paths like `/app/bin/...`. The rule matches every
  program in that app's sandbox, found as the desktop portal finds it.
- `appimage:<file>` (Linux): an AppImage mounts itself at a new `/tmp/.mount_...` folder each
  time it starts. The rule names the image file and matches the programs in its mount,
  not programs it starts from elsewhere, such as a browser it opens. `appimage:<folder>/`
  matches every AppImage in that folder.
- `service:<name>` (Windows), such as `service:DoSvc` for Delivery Optimization: svchost runs
  most Windows services, so a rule for `svchost.exe` would take all of them. The rule matches
  the process that runs the service. Most PCs run each service in its own process; where
  services share one, they are routed together. The app list shows running services by
  their display names.

## Checking rules

On desktop, each listed rule shows how many running programs it matches now, counted
with the same matcher routing uses, and warns when it may match nothing:

- the file or folder is not on this computer;
- a folder rule lacks its trailing separator, or names a file;
- the file is a script, a link or a launcher (`.lnk`, `.bat`, a Squirrel app's root
  `.exe`), so another program makes the connections;
- the letter case differs from the disk (macOS and Linux compare it);
- a bare `Example.app` on macOS, which names no program;
- the rule names one version of an app that keeps each version in its own folder;
- a Flatpak app or Windows service that is not installed, or an AppImage file that is gone.

Where a better rule exists, **Use suggested rule** replaces it, keeping its target.
On Windows only rules on local fixed drives are checked, so a network path in an
imported profile is never opened. On Android, a listed app that is not installed is
shown as such.

## Recent connections

**Recent connections** in the per-app editor lists the connections apps opened while
Elarni is connected, newest first: the app per-app routing found for each, its address,
and where it went (direct, through a server, blocked or DNS), with **Per-app rule** when a
listed app's rule took it and **Not listed** when it was passed on. It shows which program
makes an app's connections, such as a helper, updater or a new version's folder, and
**Add to list** adds that program with the same update-proof rule as the app list gives it,
including a Flatpak, AppImage or service rule. A svchost process that runs several services
has no service rule to add.

The app is the one routing already looked up, so the list adds no lookups: with per-app
routing off, or for connections through the local SOCKS or HTTP listener, no app is named.
It keeps the last 500 connections in memory and empties when the tunnel stops; nothing is
written to disk. On Android, apps are named by their user ID.

## Traffic without an app

Some traffic reaches the VPN without an app Elarni can find: connections that closed
before routing looked them up, and traffic the computer forwards for WSL, virtual
machines or containers under its own address. Such traffic may come from a listed app, so in **Only listed** it follows normal
routing; in **Bypass** it does too. To send it elsewhere, add **Unidentified traffic**
from the app list (rule `-1`) and give it a target, such as Direct. Traffic from other
devices on the network is not an app on this computer and is not affected.
On Android only listed apps enter the VPN in **Only listed**, so there is nothing to choose.

## Sharing

**Copy routing profile** copies the rules as JSON; **Paste routing profile** loads them into the
editor for review before Save. Profiles contain app paths (which may include your
username) but no servers or credentials. Each platform has its own profile.

```json
{
  "format": "elarni-per-app",
  "version": 1,
  "platform": "macos",
  "mode": "bypass",
  "processes": ["/Applications/Example.app/", "curl"]
}
```

`platform` is `macos`, `windows`, `linux` or `android`; `mode` is `off`, `bypass`
or `proxyOnly`. Imports accept up to 256 rules of 1024 bytes each and reject paths
from another platform.
