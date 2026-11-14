# Changelog

Notable changes to Elarni. Versions follow `pubspec.yaml`.

## Unreleased

### Changed

- Settings no longer wait for **Save changes** to take effect. A switch saves itself about a
  second after you flip it (several flipped in a row make one save), and the page title shows
  **Saving…** then **Saved** on Android and iPhone. What you type or pick is saved when you
  leave the page (Back, another tab, or a page opened from it) as well as by **Save changes**;
  **Cancel** drops it, and iPhone settings pages gain a **Cancel** for that. A value the app
  refuses keeps its page open with the reason instead of being dropped. On desktop this
  applies to the per-app routing page and its route checkboxes; other desktop settings already
  saved at once. Routing-profile editors on iPhone and desktop keep their Cancel and Save.
- Removed the core's batch latency test and its start from a config file: no platform calls
  them.

### Fixed

- System info and diagnostics on Windows 11 named the system "Windows 10".
- After a network change (Wi-Fi to mobile data, a new default route), an XHTTP or TUIC connection
  on the dead path could stay open with its apps stalled until the idle timeout, 30 s or more:
  data the old network had still delivered counted as the server's answer to the check. The
  check now ignores what arrives in its first second. All platforms.
- Android: with the keyboard open, screens lost the height of the navigation bar a second time,
  and the per-app app search showed nothing it found: the results were below the visible list,
  after the selected apps. The results now come right under the search field.

## 0.6.0 - 2026-11-10

### Added

- The per-app rule list shows, on Windows, macOS and Linux, how many running programs each rule
  matches, and warns when a rule may match nothing: a missing file, a folder without its
  trailing separator, a script, link or launcher, the wrong letter case, or a rule for one
  version of an app. **Use suggested rule** fixes it where it can, including rules for one
  Squirrel or Claude Code version saved before. On Android, listed apps that are not installed
  are shown and can be removed.
- **Recent connections** in the per-app editor, on Windows, macOS, Linux and Android, lists the
  connections apps opened while connected: which program made each one, its address, and
  whether a per-app rule took it and where it went. **Add to list** adds a program that is not
  listed, such as an app's helper or updater. The list stays in memory until you disconnect.
- Per-app rules for Flatpak apps and AppImages on Linux, and for services on Windows. A Flatpak
  app matches by its app ID, with every program in its sandbox; an AppImage by its image file,
  although each start mounts it at a new path; a service by name, in the svchost process that
  runs it, so Delivery Optimization or Windows Update can take a target of its own. The app list
  offers them and **Recent connections** adds them. Before, a running AppImage was listed by its
  mount path, which the next start changes, and Flatpak apps could not be listed until running.
- **Include programs it starts** for a listed app on Windows, macOS and Linux: its rule also
  matches the programs the app starts, and theirs, such as helpers, updaters or a terminal's
  command-line tools. A program listed on its own keeps its own target, and **Recent
  connections** shows which listed app started a program.
- Listed apps that were running before Elarni connected no longer keep connections that skip
  per-app routing: on Windows (IPv4) and Linux, Elarni closes them when the tunnel starts, so
  the app reconnects through it. Where the system does not allow that (IPv6 on Windows,
  macOS), **Recent connections** lists them and asks you to restart the app.
- The Windows app list also offers the Start menu's apps and installed Microsoft Store apps,
  such as Claude, when they are not running. On Linux the list loads without freezing the
  window.
- **Presets** in the desktop per-app app list add Discord, Telegram, Claude with Claude Code,
  Steam with its games, or browsers at once, each with the rule the app list gives it.

### Changed

- The Xray core is updated to upstream v26.11.9. Its default TLS fingerprint ("chrome") now
  imitates Chrome 155, which upstream reports Russia's TSPU does not target yet. Multiplexed
  (mux) connections no longer write to their server connection from two streams at once and
  carry up to 128 streams each by default, an inbound that fails to start is closed instead of
  left half-registered, and on Windows the VPN adapter's IPv6 setup errors are only logged
  when the registry's DisabledComponents turns IPv6 off, with IPv6 outside the tunnel blocked
  when leak blocking is on.
- Per-app routing finds each new connection's app faster. Windows and Linux ask the system for
  that one connection instead of reading every socket on the computer (Windows: 0.64 ms to
  25 µs per connection), and macOS reads its socket table once for connections that open
  together, as a browser's do (64 at once: 70 ms to 2.6 ms).
- Editing a large catalog no longer compiles every server again. On Windows and Linux a favorite,
  rename, selection, settings toggle or refresh compiles only the servers it changes: with 300
  servers on a route of 20,000 rules, a favorite or a rename went from 9.4 s to 0.11 s. Android,
  macOS and iOS likewise validate and hash a server again only after its configuration, its
  routes or the settings changed.
- A TCP or ICMP ping on Windows, Linux and Android no longer compiles the server's whole
  configuration to learn its address; the address is kept until the server changes.
- macOS and iOS read, compare and reduce geofiles off the main thread, so the window stays
  responsive during a geofile refresh. Android no longer copies the stored geofiles for each
  rule edit that keeps them.
- The Subscriptions page builds the server rows of open cards only, the Settings page builds
  only the open category, and the Windows Settings page asks for the VPN service state at
  most once in 30 seconds instead of starting a core process on every reload.
- Android scans QR codes from the camera's brightness plane instead of encoding each frame
  as JPEG and decoding it again.
- The macOS and iOS tunnel resolves a profile's server hosts together when it starts.
- Removed code no platform runs: the tun2proxy command-line programs, its HTTP and SOCKS4
  proxies, virtual DNS and UDP gateway, with 90 crates from the Rust lockfile, and libXray
  methods no app calls. A routing link that starts with `://routing/`, without a scheme, is no
  longer imported on Windows, Linux, macOS and iOS; nothing writes such links and Android
  never took them.
- The per-app app list opens faster the second time on macOS and Linux: app icons are drawn
  once and kept until the app or the icon theme changes, and macOS builds the list off the
  main thread, so the window no longer freezes while it loads.

### Fixed

- On iPhone, iPad and Mac, apps' UDP traffic now reaches the server. The packet bridge's relay
  socket to the core was not bound to loopback, and iOS and macOS dropped every datagram sent
  on it, so each UDP session ended at its first datagram: games such as Brawl Stars fell back
  to TCP and lagged in battles, and QUIC fell back to TCP.
- Traffic to the VPN adapter's own subnet, other than DNS, now ends at once instead of
  following routing rules for private ranges. On Android, each connect set off 2,000-4,000
  Private DNS connections (port 853 on the VPN's resolver) in about 3 s, and the check hung
  for 16 s or more before it fell back to plain DNS; Windows sent subnet broadcasts (NetBIOS,
  Spotify device discovery) out the direct route.
- A Windows connect that the PC slept through no longer fails when it wakes. The helper's
  30 s startup wait and the app's 120 s connect wait counted the time asleep, so both ran out
  at resume, the helper exited and the app started over, although the core was ready seconds
  later. Helper and app waits on Windows now count only the time the PC is awake.
- A server test whose XHTTP connection was still connecting when the test ended no longer
  holds its cleanup for up to 16 s. The app reported "An earlier server test is still
  closing" meanwhile (iOS refused further tests until restarted), and macOS paused automatic
  server switching. The XHTTP dial now ends with the test, and with the connection it served.
- Android now names the app of short-lived connections, so per-app rules match them. About
  16% of QUIC flows to Vision servers and about 5% of TCP connections had no app, because the
  app had closed its socket by the time routing asked Android who owned it. With per-app rules
  on, the VPN now asks when the connection arrives and remembers a socket's app for 30 s after
  it closes.
- Automatic server tests on Windows, macOS and Linux start 50 ms apart instead of 40 ms, so
  uneven dial times no longer put three handshakes to one server name within 50 ms. Russia's
  TSPU freezes a server name after more than three handshakes that close together.
- Per-app rules for the Claude app on Windows, and for other Microsoft Store apps, stopped
  matching after each app update: the app runs from a folder named after its version. Rules now
  match the package in any version, including rules saved before. Claude Code, which the Claude
  app keeps in a new `claude-code\<version>\` folder with each update, is listed as one app that
  matches every version, on Windows, macOS and Linux; so are Snap apps on Linux, whose path
  changes with each refresh. Pick Claude Code and Snap apps again from the list to get the new
  rule; Store app rules need nothing.
- On Android, an app listed for per-app routing that was installed or reinstalled while
  connected missed its route until the next connect: in **Only listed** it stayed out of the
  VPN, and in **Bypass** its traffic went through it. Elarni now builds the tunnel again when a
  listed app is installed, removed or reinstalled; app updates change nothing.
- In per-app **Only listed** mode on Windows, macOS and Linux, a connection whose app could not
  be found went direct, so a listed app's connection could leave outside the VPN. It now follows
  normal routing, as on Android. Such traffic can include WSL, virtual machines and containers:
  to send it direct as before, add **Unidentified traffic** to the app list and set it to Direct.
- On Linux, per-app rules missed IPv4 connections made from IPv6 sockets, which Java apps
  (Minecraft, JetBrains IDEs) and many servers use, and rules stopped matching a program whose
  package was upgraded while it ran, until it restarted.
- macOS and iOS: an app whose connection the packet stack had given up, as during a server
  switch or at the session limit, waited for its own timeout. The stack now resets such a
  connection, so the app reconnects at once.
- macOS: an automatic switch that the provider refused (missing credentials, an invalid
  configuration, failed resolution) disconnected the VPN although the previous server was
  still running. The VPN now stays up, and the app waits 20 s for a switch reply instead of 15.
- macOS and iOS: after one failed geofile refresh, such as being offline at the weekly
  refresh, a routing profile's geofiles were never refreshed automatically again. A failed
  refresh is retried after 15 minutes.
- **Share** wrote a dead link (`<nil>:0`) for a server imported from Xray JSON in the usual
  `vnext` or `servers` form, and dropped a REALITY `publicKey` and the path, host, mode and
  seed of transports named `websocket`, `splithttp`, `mkcp` or `tcp` with an HTTP header.
- Android and iOS: saving a second new routing profile overwrote the first one's rules,
  because both started as "My routing". A new profile now takes a free name.
- Android: with **Disconnect on sleep**, a tunnel started while the screen was off (tile,
  boot, an external request) was restarted when the screen turned on.
- A subscription's connect address and HTTP Host override were also used for its mirrors and
  the provider's fallback URL, which are other hosts, so none could take over.
- A UDP flow in VPN mode could start again from a new source port after its full queue
  refused a datagram.
- Windows and Linux: a system proxy restore that failed was retried and reported every
  second, and the proxy was never set.
- macOS: the log level dropdown stayed disabled after a change.

## 0.5.1 - 2026-11-08

### Changed

- Reduce routing-data size is on for new routing profiles and for imported ones that do not
  set `UseChunkFiles`, as in Happ's routing builder: the core loads only the geofile records the
  rules use. With the full Russian geofiles this cut the Windows helper's peak memory from 478 to
  112 MB, and on macOS and iOS it lets geofiles over 64 MB load at all.
  A profile that sets `"UseChunkFiles": "false"` keeps full files.

### Fixed

- The VPN no longer relays LAN discovery (mDNS, SSDP, LLMNR, WS-Discovery) or other multicast
  and broadcast packets that Windows sends out of the VPN adapter. Windows sends a burst of them
  at each network change, enough to fill the 1024-slot UDP session table with new sessions; the
  VPN then refused every new UDP flow, DNS lookups included, for about 10 s. On a recorded
  session this happened about half the time, and pages waited up to 14 s for DNS.
  The same applies on every platform: Linux and Android share that packet stack, and the
  macOS and iOS tunnels now drop such packets as well instead of opening a UDP session for
  each, which once their table was full refused every new one.
- VLESS with XTLS Vision refuses QUIC (UDP/443) before connecting to the server, rather than
  after a full connection and TLS/REALITY handshake. Browsers retry QUIC often: one recorded
  10-minute session made 2,611 such handshakes for nothing.
- LAN discovery (mDNS, SSDP, LLMNR, WS-Discovery, DHCP-style broadcast) stays on the local
  network instead of entering the VPN, where it reached no device: apps that send it without
  choosing an interface now send it on the local network. The tunnel's routes leave out
  multicast and the limited broadcast on Windows, Linux, Android, macOS and iOS; on Windows
  the VPN adapter's own discovery routes also lose to every other interface. Block traffic
  without VPN (and Android's lockdown) keeps them in the tunnel; on Windows the adapter now
  gets its own routes to them, which Windows did not always create, so mDNS no longer left
  through the physical network there.
- Windows: after the Elarni adapter was disabled, which ends the connection, the next connect failed with
  "vpn_core_failed_2": the helper reused the disabled adapter it keeps between connects. It now replaces it.
- DNS lookups get through when the VPN's UDP session table is full (every platform). A burst of new
  UDP flows, such as the discovery packets Windows sends at each network change, refused every
  lookup for about 10 s; lookups now have up to 128 sessions of their own.
- Windows: a recording build recorded no VPN traffic when the ElarniVPN service started the
  helper (Connect without administrator approval), or when another administrator approved
  it: the helper wrote into that account's profile, which Save recording as ZIP cannot read.
  It now records under the helper's admin-only folder, readable only by the connecting account.
- Windows, Linux and macOS: in the routing editor, opening a collapsed section (Direct DNS,
  Choose DNS by domain, Proxy rules, Block rules) or reopening one showed grey boxes instead of
  its text fields.

## 0.5.0 - 2026-11-07

### Security

- Imported profiles can no longer read the core's environment through a field name
  that only matches under Unicode case folding, such as `addreſs`.
- The core's brotli and zstd decoders are updated (brotli 1.2.7, klauspost/compress 1.20.2): a crafted brotli stream
  could allocate excessive memory (GO-2026-6888) and a crafted zstd frame could crash the core (GO-2026-6865).
  The vendored quic-go forks' own module files now ask for the same versions.

### Added

- Windows and Linux: Settings › Connection › Connection mode picks System-wide VPN (the default),
  System proxy or Local proxy only. System proxy points the Windows proxy setting, or
  GNOME's and KDE Plasma's, at Elarni's HTTP listener while connected and puts the
  previous setting back on disconnect, on quit, and at the next start after a crash.
- macOS: the app warns when the VPN extension that runs is another build's (a leftover
  development build's extension used 6.6 GB).
- Android: a line above the servers on Home says when the subscriptions were last updated and that
  pulling the list down updates them; tapping it updates them too, which TalkBack users need.

### Changed

- A release is built only from a commit whose checks passed, and every main commit
  is checked (a newer push no longer cancels a pending run).
- Windows and Linux: a dropped connection is retried on the selected server without
  automation turned on: after 1, 2, 4, 8, 16 and 30 s, then every minute for as long as
  you stay connected and online. Failover to other servers still needs automation. A
  connection left on when Elarni quits comes back at the next start; Disconnect ends it.
  The On Demand switch, which did nothing there, is gone.
- Windows and Linux: the elevated helper outlives a tunnel that failed or ended by
  itself, so reconnecting asks for administrator approval only once per session.
- Windows and Linux: with automation on, a failed server check is repeated after 10 s
  instead of 30 s, so failover leaves a dead server within about 80 s instead of 120 s.
  Each backup is tried in turn without saving the catalog again or restarting the
  failed server in between; the original comes back only if no backup works.
- iOS: On Demand is on for new installs; a saved choice is kept.
- Android: apps that need no tunnel (bypassed apps going direct, and unlisted apps in
  Only listed mode) stay out of the VPN entirely while lockdown is off, and use the
  system's DNS.
- Android: after a crash the VPN comes back by itself, at most once in 10 minutes, and
  the watchdog also runs while the phone dozes.
- Android: the background refresh job runs hourly, and only when a subscription, route
  list or expiry reminder is due. Server checks run only while traffic flows.
- The bundled Xray core is upstream main a52db8f6 (v26.10.31 and later), which adds Windows
  TUN fixes (starting with IPv6 disabled, reusing an adapter by name), MPTCP off on listeners
  by default, and fixes for QUIC sniffing and HTTP 100-continue.

### Fixed

- A TLS, REALITY or HTTPUpgrade handshake that DPI swallows gives up after 16 s and frees
  its socket; a failed handshake no longer leaks it. A refused or timed-out server fails
  at once instead of after five tries.
- DNS: a lookup that fails is answered with SERVFAIL, so apps try again at once instead
  of waiting out their own timeout; a lost query is sent again after 1 s; a remote
  resolver that stalls gives up after 2 s, and expired answers are served while they
  refresh. A DoH server that stalls while connecting gives up after 16 s instead of
  holding every lookup. A plain-UDP remote resolver now goes through the proxy, and
  `+local` resolvers in imported profiles, which bypassed the tunnel, are dropped.
- After a network change, pooled XHTTP, gRPC, Hysteria, TUIC and DNS connections are
  checked and only dead ones are closed; new connections use the new network (Windows,
  Linux, Android, macOS, iOS). Android and macOS keep the core running instead of
  restarting it, and Linux and Windows also do this after sleep.
- XHTTP/3: a failed dial no longer leaks its socket, more than 100 sessions no longer
  stall for 16 s, and closing the first app no longer aborts the shared dial.
- Routing with IP rules uses the connection's own address instead of looking its domain
  up again.
- Android: an error in a background task no longer ends the app and its VPN; a failed
  save no longer undoes a connect.
- Android: in Only listed mode, a connection whose app Android cannot identify stays in
  the tunnel.
- Android: the Quick Settings tile shows a VPN paused for sleep as off.
- iOS and macOS: a stalled core is restarted after two failed checks, and packet writes
  refused while settings change no longer end the tunnel.
- Linux: a failed nft cleanup keeps the marker, so Repair VPN setup still finds the
  leftover redirect.
- Windows: a DNS setting that could not be restored on disconnect is reported, and
  retried.
- Testing many servers at once no longer fails a server now and then: two probes could be
  given the same local port and fail each other's login (Windows, Linux, macOS, Android).
- A server now gets the site name it routes by, not the app's IP, when the app
  connected to a real address (for example over IPv6). Servers that send YouTube
  through an IPv4-only exit no longer stall YouTube on IPv6 phones. Direct
  connections, UDP and names the profile pins in its DNS hosts still use the
  app's address.
- With a Fake DNS routing profile, refreshing a subscription, geofile or managed list
  while connected asked to approve a "private network address", or failed, and paused
  automatic refresh, on every platform. Downloads now look such names up over DNS over
  TLS through the VPN, which does not answer with Fake DNS addresses, and fall back to
  the VPN's own DNS where DNS over TLS is blocked.
- Windows, Linux: with a Fake DNS routing profile, testing servers other than the
  connected one failed while connected, so failover found no backup.
- Android: the update notice never appeared; the daily check failed before it fetched.
- Windows, Linux: SRV, TXT and other lookups that aren't for addresses went to a
  resolver the routing profile lists for its own domains only.
- SRV, TXT and other lookups that aren't for addresses, asked over TCP through the VPN,
  came back truncated whenever the answer passed 512 bytes, so they failed; they now
  stay on TCP.
- macOS: while connected, Direct TCP showed 1-5 ms for every server, dead ones too, because
  the tunnel itself answered; it now tests outside the tunnel. Tests the tunnel cannot run
  while connected (Direct TCP and other servers' proxy tests with Include all networks
  on, and other servers' "Current rules / active tunnel" tests) are marked Skipped with a
  hint to disconnect, instead of failing and marking the server Unavailable.
- Windows and Linux: importing a subscription or routing profile while the VPN is
  connected with FakeDNS no longer fails with "This source needs approval before it
  can be contacted." Geofile and managed-list downloads now resolve and connect
  through the VPN's SOCKS listener, as on Android.

### Performance

- iOS and macOS: faster downloads through the packet tunnel (TCP window scaling, one copy
  per segment, half the ACKs); a burst of packets waits up to 10 ms instead of being
  dropped; DNS sessions end with their answers.
- Fewer copies and allocations per UDP datagram in the TUN stack, Hysteria, TUIC and
  WireGuard; TUIC uses batched reads and GSO.
- Idle UDP flows in the TUN stack end after 2 minutes instead of 5; a full table refuses
  new connections before their handshake; near the memory limit, idle sessions are
  replaced first.
- Hysteria keeps its connection alive (10 s keepalive) and shares one dial between
  flows; XHTTP gives new flows a connection that is already up.
- Android: the core's DNS answers are cached for their TTL, routing data is not read
  again for the same route, and logs are capped at 200 lines a second.
- The core returns memory after light traffic at most once a minute instead of every
  5 s, and still at once after a large download or when many connections close.
- iOS: lower peak memory for XHTTP and QUIC downloads, and the core is not compiled
  again for a restart with the same settings.
- Desktop: no window rebuilds or catalog saves on unchanged state, direct TCP tests use
  sockets instead of a core per server, and the helper returns memory after each start.
- Windows: reconnecting with unchanged routing data no longer sends and checks the
  geofiles again (80 ms and about 100 MB of copies for 18 MiB of geodata).
- Linux: per-app routing looks up the owners of a burst of new connections in one
  pass (64 connections: 9 ms instead of 36 ms).
- Windows: an idle direct UDP flow no longer holds a 64 KiB read buffer.
- A connection closes as soon as the app closes it, instead of up to a second later (Xray's default `downlinkOnly`). A
  burst of short connections no longer holds hundreds of TLS sessions: on the test phone the app peaked at 88 instead
  of 231 MB during 2000 short connections and opened 739 instead of 633 per second; the desktop daemon peaked at 82
  instead of 225 MB on Linux and 102 instead of 265 MB on Windows. An app that half-closes a connection and then waits
  for the reply loses the reply, as with the mihomo-based clients; a profile's own `policy` value still wins.
- Android: the core now uses the CPU's AES and carry-less multiply instructions. Go, loaded as a library, could not
  read the CPU features in a release build, so TLS ran on software AES. On a Snapdragon 8 Gen 3 test phone one
  download now runs at 136 instead of 37 MB/s and eight at 907 instead of 201, at a third to a seventh of the CPU
  per MB; uploads and new connections per second gain too.
- UDP in VPN (TUN) mode: datagrams waiting on a flow go to the server together, packed into
  full TLS records, instead of one record and one write each. On the test phone UDP bulk
  rises from 4.5 to 10.7 MB/s at half the CPU per MB; on desktops by 8-12%.
- The VPN (TUN) mode on Windows, Linux and Android runs on Xray's own TCP/IP stack instead
  of gVisor. One connection downloads up to 2.5x faster (VLESS: 2.75 vs 1.08 GB/s on the
  test host) at less than half the CPU per MB, now level with upstream Xray on every protocol.
- Linux: without a GPU (virtual machines, remote desktops), the window draws with Flutter's own
  CPU renderer instead of Mesa's software OpenGL: 80 MB less memory and a quarter of the CPU
  while it repaints. Set `FLUTTER_LINUX_RENDERER=opengl` to keep OpenGL.
- The window no longer redraws every second while the connection status is unavailable.
- Windows and Linux: a connected but idle VPN uses about 40% less CPU (Linux test namespace: 65 instead of 112 ms
  per minute across the app and its core processes). The core passes its traffic counters on only when they change,
  or every 10 s, instead of every second through each process; it reads its heap size without pausing the program;
  and the Linux network check reads link state without a thread handoff.
- Android: the 2-second status refresh no longer asks the system for home screen widgets each time.
- Android: the 2-second status refresh no longer reloads every settings title, and the screen's clock stops while
  the app is in the background. Idle CPU in the minute after heavy traffic drops by about a fifth (1020 vs 1260 ms
  per minute on the test phone); settled idle is unchanged.

## 0.4.1 - 2026-11-04

### Changed

- Release files are built on GitHub-hosted runners and come with build provenance
  (`gh attestation verify`) and a Sigstore-signed `SHA256SUMS`; see docs/RELEASING.md.
- Android: server tests run while connected, as on desktop. Other servers, direct
  TCP and ICMP are tested outside the tunnel; the selected server's proxy test still
  goes through it. While connected, a test runs 8 servers at a time with a health
  check between them, so failover isn't held up.

### Security

- Android: broadcasts from automation apps such as Tasker must carry the control
  key shown under Settings › General › Let other apps control the connection, as
  the string extra `key`; others are ignored. Existing automations need the key
  added (android/README.md has a Tasker example).
- Imported profiles can no longer name an address or port as `env:NAME`, which made
  the core substitute that local environment variable into server hosts and DNS
  lookups. Names, tags and passwords may still contain `env:`.

### Fixed

- RU routing from runetfreedom's geofiles works again: its geosite.dat passed the
  64 MiB limit. Downloaded geofiles (up to 256 MiB) are streamed to disk and trimmed
  to the categories your rules use; with Reduce routing-data size off, a file over
  64 MiB fails the refresh with a clear message.
- Android: connections no longer hang when the phone reuses a port the tunnel still
  held in TIME_WAIT, and connection bursts are no longer refused.
- iOS: the VPN recovers after a switch between Wi-Fi and cellular, or between two Wi-Fi
  networks. The tunnel restarts its core in place once the new network has held for
  6 s, and retries if the new network isn't ready yet.
- iOS and macOS: the packet tunnel no longer keeps every packet it wrote until it stops;
  download-heavy apps made iOS end the VPN at its 50 MB memory limit.
- iOS: diagnostics report the memory footprint iOS counts against that limit.
- A subscription refresh no longer reconnects when the active server changed only its
  REALITY shortId or SNI, which 3x-ui picks at random on every fetch. The stored values
  are kept for 24 hours after the server's last connect, so a shortId the panel retired
  is replaced at the next refresh after that.
- A JSON or Clash profile whose server has no port, or a host name with a space,
  slash or colon, is refused on import, as its share link already was, instead of
  failing to connect.
- `elarni-cli` without `HOME` (a systemd unit without `User=`) finds the root service's
  socket, or `$XDG_RUNTIME_DIR/elarni/control.sock`, instead of failing.
- Linux: a tunnel killed while it started can no longer leave a DNS redirect that the
  next start does not detect.
- Routing: a `regexp:` rule Go cannot compile (unbalanced groups or classes, a trailing
  backslash, a repeat with nothing to repeat, nested repeats, unknown escapes) is
  rejected on import instead of failing at connect.
- Windows: upgrading an install that never had the ElarniVPN service sets it up for the
  installing account once, so connecting stops asking for administrator approval. An
  install run as SYSTEM (Intune, SCCM) sets up no account.

### Performance

- Faster downloads and connects on every platform: WireGuard, QUIC (Hysteria2,
  XHTTP/3, TUIC), XHTTP and the TUN stacks got larger, bounded buffers, and a stalled
  QUIC stream no longer freezes its connection. On Windows, 8-stream downloads are
  1.2-3.3x faster on 22 of 24 protocols, with 1.5-5x less CPU per GB.
- Server-first protocols (SMTP, IMAP, MySQL, SSH and others) get their greeting at
  once instead of after up to 0.7 s.
- Per-app routing looks a connection's process up once instead of once per rule.
- The core returns memory after traffic stops (desktop) and returns freed memory to
  the system (Android).

## 0.4.0 - 2026-11-01

First open-source release.

### Added

- Release builds check this repository's releases once a day and show a notice
  when a newer version exists (Settings › General › Update feed; nothing installs).
- Settings › General has a language choice, English or Russian.
- Android: the Quick Settings tile names the connected server.

### Changed

- Every platform uses Elarni identifiers: `com.elarni.*` bundle, package and
  desktop IDs, `Elarni` data folders and registry keys, `/var/lib/elarni`,
  `/run/elarni` and `/etc/elarni` for the Linux service, and `elarni://` links.
  Builds from before this change are a separate app: remove the earlier build
  first, then install this release and re-add subscriptions. On Windows, the
  earlier build's uninstaller, or `elarni.exe --unregister` for its portable ZIP,
  releases its link handlers and login item. Backups from earlier builds cannot
  be restored.
- Desktop: per-app routing is its own Routing tab, subscriptions open with their
  servers expanded, and the Home server card is shorter.
- Connection recording is left out of release builds; it ships only in builds
  made with `ELARNI_RECORDING`.

### Security

- tokio 1.53.3 (RUSTSEC-2026-0386) and golang.org/x/net 0.62.0 (GO-2026-6860,
  GO-2026-6866).
