# Headless Elarni on Linux

`elarni-cli` runs Elarni on a server without a display or desktop login. Commands
and the method reference are in [the control guide](../docs/HEADLESS.md).

## Boot service

Install `gnome-keyring`, `libsecret-tools` and `dbus-x11`, create the keyring
password, then enable the service (the package installs it disabled):

```sh
sudo install -d -m 700 /etc/elarni
sudo sh -c 'umask 077; test ! -e /etc/elarni/keyring-password && openssl rand -hex 32 > /etc/elarni/keyring-password'
sudo systemctl enable --now elarni.service
```

The service runs as root with a private Secret Service; profiles are encrypted
under `/var/lib/elarni`. Keep the password, keyring and catalog together when
moving to another machine. Starting the service doesn't connect until you set a
profile up.

Before enabling a full-tunnel VPN on a remote server, make sure SSH stays reachable.

## Example

```sh
sudo elarni-cli import /private/subscription-url.txt
sudo elarni-cli profiles
sudo elarni-cli failover 'preferred profile' 'backup profile'
sudo elarni-cli connect
sudo elarni-cli status
```

- `settings` with `{"xrayTunEnabled":false}` runs a local SOCKS/HTTP proxy instead
  of a system VPN. Its listeners require a login: `call inboundCredentials`
  prints it.
- `failover` keeps a healthy connection and switches to the backup when it fails.
  A third argument names a JSON file of custom check URLs.
- After failed retries the daemon waits 60 seconds and tries again. It reconnects
  after a restart unless you ran `disconnect`.

## Private user daemon

```sh
elarni-cli --socket /private/run/control.sock daemon \
  --core /path/elarni-core --domain /path/libelarni_domain.so
```

It needs an unlocked Secret Service in the session (or `--keyring-password-file`
for a dedicated service account). A system VPN still needs root or polkit.
