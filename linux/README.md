# Elarni for Linux

Ubuntu 22.04 or newer, x86-64. Supports X11 and Wayland.

For servers without a desktop session, see [headless controls and boot service](HEADLESS.md).

Install the Debian package with `sudo apt install ./elarni_*_amd64.deb`, then
open Elarni from the application menu. System VPN asks for administrator
permission through the desktop's polkit agent. The application runs as your
normal user. Local proxy mode does not require administrator permission.

For the portable archive, extract the complete directory and run `./elarni`.
Keep `elarni-core`, `lib`, and `data` together with the executable. Run
`./install-desktop` as your normal user to add the menu entry and supported
profile-link handlers. This registers the current location; register again after
moving the directory. `./install-desktop --remove` removes that registration and
the launch-at-login entry.

Your user can replace the portable archive's own `elarni-core`, so pkexec starts
it as root only once per build. The first system VPN connection of each build
asks twice: once for it to copy itself into root-owned `/opt/elarni-vpn-helper`,
then to start that copy. Every later prompt starts only the copy. After deleting a portable archive, remove the copy with
`sudo rm -r /opt/elarni-vpn-helper`. The Debian package needs no copy.

The AppImage is one file: make it executable (`chmod +x Elarni-*.AppImage`) and
run it. It needs FUSE (Ubuntu's `fuse3` package) and the same runtime packages as
the portable archive. Its system VPN installs the same `/opt/elarni-vpn-helper`
copy on the first connection of each build. Launch at login starts the AppImage
file, so enable it again after moving or renaming the file. For a menu entry and
profile-link handlers, use a desktop integration tool such as AppImageLauncher or
Gear Lever. The AppImage carries the desktop app only; headless servers use the
Debian package or the portable archive's `elarni-cli`.

If the VPN core stops on its own, its helper removes the tunnel and traffic goes
directly again. If the helper itself is killed, its DNS redirect stays and name
lookups fail until Elarni removes it: on the next start, the next Connect, or
**Repair VPN setup**, each after an administrator prompt.

The portable bundle includes Flutter, the Elarni domain library and the VPN
core. Its Ubuntu runtime dependencies are:

```sh
sudo apt install libgtk-3-0 libayatana-appindicator3-1 libgstreamer1.0-0 \
  libgstreamer-plugins-base1.0-0 gstreamer1.0-plugins-base \
  gstreamer1.0-plugins-good libsecret-tools iproute2 nftables iputils-ping \
  pkexec xdg-utils desktop-file-utils
```

A running Secret Service keyring and a polkit authentication agent are required
for encrypted storage and system VPN permission. Ubuntu's normal GNOME desktop
provides these. Minimal desktops can install `gnome-keyring` and
`policykit-1-gnome` and start them through the desktop's login session. Unlock the
keyring when prompted; Elarni never stores the encryption key beside profiles.

Profiles live under `$XDG_DATA_HOME/Elarni` (normally
`~/.local/share/Elarni`), preferences under `$XDG_CONFIG_HOME/Elarni`, and
downloaded routing assets under `$XDG_CACHE_HOME/Elarni`. Keep the keyring and
encrypted catalog together when migrating your Linux account, or use Elarni's
password-protected backup export/import. Removing the package preserves app data.

The status icon uses the desktop's AppIndicator/StatusNotifier support. On GNOME,
enable its AppIndicator extension if the desktop does not show status icons.
Camera QR import uses an available V4L2 camera through GStreamer. Linux app
routing matches executable names, absolute paths, or folder prefixes with
case-sensitive matching. Windows drive paths and macOS application bundles are
not Linux application identifiers.

Build with Flutter 3.44.2, Go 1.27.3 and Rust 1.98.0. Run `flutter build linux
--release`, then `python3 scripts/package-linux`. The release packages (`.deb`,
AppImage and portable archive) are written to `.build/linux-release`; the
AppImage tools are downloaded once at pinned, checksummed versions. Development tests use synthetic fixtures and separate
outputs; see the repository's `docs/TESTING.md`.
