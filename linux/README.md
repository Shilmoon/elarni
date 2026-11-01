# Elarni for Linux

Ubuntu 22.04 or newer, x86-64, X11 or Wayland. For servers without a desktop, see
[headless control and boot service](HEADLESS.md).

## Install

- **Debian package:** `sudo apt install ./elarni_*_amd64.deb`, then open Elarni
  from the application menu.
- **AppImage:** `chmod +x Elarni-*.AppImage` and run it. Needs `fuse3`.
- **Portable archive:** extract it and run `./elarni`. `./install-desktop` adds a
  menu entry and link handlers (`--remove` undoes it).

The AppImage and portable archive need these packages:

```sh
sudo apt install libgtk-3-0 libayatana-appindicator3-1 libgstreamer1.0-0 \
  libgstreamer-plugins-base1.0-0 gstreamer1.0-plugins-base \
  gstreamer1.0-plugins-good libsecret-tools iproute2 nftables iputils-ping \
  pkexec xdg-utils desktop-file-utils
```

## Notes

- System VPN asks for administrator approval through polkit; local proxy mode
  doesn't. The AppImage and portable archive copy their VPN helper to
  `/opt/elarni-vpn-helper` on the first connection; remove it with
  `sudo rm -r /opt/elarni-vpn-helper` after deleting them.
- Profiles are encrypted with a key kept in the Secret Service keyring
  (gnome-keyring on GNOME). Minimal desktops need `gnome-keyring` and
  `policykit-1-gnome`.
- Data lives in `~/.local/share/Elarni`, settings in `~/.config/Elarni`. Removing
  the package keeps them.
- On GNOME, enable the AppIndicator extension to see the status icon.
- If the VPN helper is killed, DNS stays redirected until Elarni's next start,
  Connect or **Repair VPN setup**.

## Build

```sh
flutter build linux --release
python3 scripts/package-linux
```

Packages are written to `.build/linux-release`.
