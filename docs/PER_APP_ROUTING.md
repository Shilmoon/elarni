# Per-app routing

Desktop: Routing › Per-app routing. Android: Settings › Apps & routes. It needs
system VPN mode.

- **Bypass:** listed apps connect directly; everything else uses normal routing.
- **Only listed:** listed apps use normal routing; everything else connects directly.
- **Off:** normal routing for all apps.

Rules match the program's path or name, which any program can copy. In Bypass
mode, list only apps you trust, by exact path in folders other users can't write.
This is routing, not a firewall or kill switch.

| Platform | Rules match |
|---|---|
| macOS | `.app/` bundles, including their helpers |
| Windows | exact `.exe` paths, case-insensitive; Squirrel apps such as Discord by install folder; Microsoft Store apps such as Claude by package |
| Linux | resolved binary paths, case-sensitive; pick Snap/Flatpak apps from running processes; Snap apps by `/snap/<name>/` |
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
