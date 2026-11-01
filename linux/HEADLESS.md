# Headless Elarni on Linux

`elarni-cli` runs the same catalog, subscription, routing compiler, VPN helper
and recovery controller as the desktop application. It needs no Flutter engine,
display server or desktop login. Cross-platform CLI commands and GUI control are
documented in [the common control guide](../docs/HEADLESS.md).

The daemon exposes a Unix socket in a private directory (socket mode 0600). There
is no TCP control API. Run commands as the daemon's user; the supplied system
service runs as root because it creates a system VPN. Protect SSH and existing
inbound services before enabling a full-tunnel configuration on a remote server.

## Boot service

Install `gnome-keyring`, `libsecret-tools` and `dbus-x11` in addition to Elarni's
normal runtime dependencies. The supplied `elarni.service` is not enabled by
the package. Before its first start, create `/etc/elarni` with mode 0700 and a
random `/etc/elarni/keyring-password` with mode 0600, owned by root. For example:

```sh
sudo install -d -m 700 /etc/elarni
sudo sh -c 'umask 077; test ! -e /etc/elarni/keyring-password && openssl rand -hex 32 > /etc/elarni/keyring-password'
sudo systemctl enable --now elarni.service
```

The service runs a private D-Bus Secret Service. Profile encryption uses the same
native Secret Service/AES-GCM storage as the desktop, under
`/var/lib/elarni/data/Elarni`. The separate root-only password unlocks the
service keyring at boot; it is never put in command arguments or logs. This is
unattended access protection, not protection against root compromise. Keep the
service password, keyring and encrypted catalog together when migrating.

Starting the service does not connect an unconfigured VPN. Import profiles and
configure the desired connection first. Removing the package stops the service and
upgrading it restarts a running service; stop it yourself before removing a portable
install's files.

## Controls

These commands address the root service. A desktop user can use the same CLI
without `sudo` to control their GUI or private daemon. `commands` lists the full
API; `call METHOD JSON_FILE|-` also controls routing, favorites, profile groups,
subscription options, credentials, encrypted backup/restore and diagnostics.

```sh
sudo elarni-cli import /private/subscription-url.txt
sudo elarni-cli import /private/wireguard.json
sudo elarni-cli profiles
sudo elarni-cli failover 'exact preferred profile name' 'exact backup name'
sudo elarni-cli connect
sudo elarni-cli status
sudo elarni-cli disconnect
```

`import -` reads stdin, so credentials need not appear in argv or shell history.
`profiles` returns IDs, names and protocol labels without credentials. Ambiguous
names are rejected; use an ID to disambiguate. `select ID` manually chooses a
profile and resets an enabled recovery configuration to that single profile, as
in the desktop application. Configure `failover` again to authorize backups.
`probe ID [CHECK_URL]` checks HTTP 204 without changing the active connection or
system routes. The connected profile is checked through the running connection.
Any other profile runs in an isolated instance whose connection to that server
deliberately bypasses the VPN, so the local network can see that you contacted it.

`settings` reads settings; `settings FILE` or `settings -` merges a JSON object
with current settings. For a local SOCKS proxy without changing system routes,
set `{"xrayTunEnabled":false}` before connecting. For a system VPN, set it true.
A fresh install's SOCKS and HTTP listeners require a generated login, so other
local programs cannot use them unasked. `call inboundCredentials` prints it.
Set your own with
`updateInboundCredentials`, or set `{"inboundAuthEnabled":false}` to accept
programs without one. Installs from 0.3.6 and earlier keep their setting.
`refresh SUBSCRIPTION_ID` updates an imported subscription and applies the
changes at once. Fetches needing additional source approval return `subscriptionId`, `riskCodes`
and a `challenge` without contacting the unapproved destination. Review those
risks, then use `refresh SUBSCRIPTION_ID CHALLENGE_TOKEN` to approve that fetch.
Redirects can require another challenge.

Ordered failover can explicitly authorize a backup from another subscription or
a local import. A healthy current connection is kept; when it fails, the other
allowed profile is tried and must pass traffic checks. A recovered preferred
profile is used after the current backup fails or after manual selection. The
default checks use two HTTPS204 endpoints on different hosts. To supply your own,
pass a third JSON-file argument to `failover`; it contains an array of
`{"id":"check","url":"https://…","expectedStatus":204,"expectedBody":""}`
objects, with distinct hosts.

Headless recovery waits 60 seconds after an exhausted retry episode and then tries
again while connection intent remains enabled. Daemon restarts resume saved
intent; `disconnect` clears it and stays disconnected across restarts. Interactive
desktop retry limits and group selection remain unchanged. The system service
uses a separate catalog from the normal desktop user.

For a private user daemon, run `elarni-cli --socket /private/run/control.sock
daemon --core /path/elarni-core --domain /path/libelarni_domain.so` in a
session with an unlocked Secret Service. Use the same `--socket` for clients.
System VPN still needs root or an available polkit authentication agent. The
optional `--keyring-password-file` starts a private keyring within an existing
D-Bus session; use it only for a dedicated service home/keyring.

## Verification

`sudo python3 scripts/check-headless` exercises an isolated Linux daemon,
encrypted storage, CLI controls and local loopback profile traffic. It creates
private network, mount and PID namespaces and cannot use the host's VPN broker.
Shared controller regressions remain in `scripts/check-tests flutter` and
`scripts/check-windows`. Boot activation and real provider availability must be
verified separately on the deployment host; tests never use the working VPN.
