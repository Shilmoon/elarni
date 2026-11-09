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
| Windows | exact `.exe` paths, case-insensitive; Squirrel apps such as Discord by install folder |
| Linux | resolved binary paths, case-sensitive; pick Snap/Flatpak apps from running processes |
| Android | package names; apps sharing a UID share a rule |

A bare name matches in any folder, and a path ending in `/` matches everything
below it.

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
