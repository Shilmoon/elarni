# Disposable macOS acceptance suite

This suite fills the installed-provider and desktop acceptance layer above the
existing Go, Rust, Swift and Flutter checks. It has **11 selectable automated
XCTest cases** plus the operator matrix below. A full macOS acceptance result
requires both. Build-only and harness checks execute no installed VPN tests.

Run installed cases only on a disposable Apple Silicon Mac with a disposable
macOS account, no personal catalogs and no other VPNs. A second account on the
working Mac is not sufficient isolation for machine-wide routes and networking.
The runner never stops a pre-existing app or VPN to make its prerequisites pass.
Do not run these commands through a connection that the tested VPN carries.

## Prepare the disposable Mac

1. Use a fresh source checkout containing all three Vendor trees, native crates,
   Flutter files, macos, scripts, include, manifests and lockfiles. Include the
   intended uncommitted source changes if testing them. Exclude `.git`, `.build`,
   `target`, `build`, `.toolchains`, `Evidence`, artifacts and credentials when
   transferring a source snapshot. Review the file list: local exclusions can hide
   required test files. Install dependencies on the test Mac itself.
2. Install Xcode with its macOS SDK and command-line tools, Python 3.10+, Flutter
   matching the project (currently 3.44.2), Rust from `rust-toolchain.toml`, Go
   matching `go.work` (1.27.3), cbindgen, and XcodeBuildMCP. This project builds
   arm64 native archives; Intel Macs are not supported by this runner. The app's
   deployment target is macOS 13, but use an OS supported by the installed Xcode
   XCTest runtime; a current-Xcode pass is not a minimum-OS pass.
3. The existing native scripts expect `.toolchains/go/bin/go` and
   `.toolchains/cbindgen/bin/cbindgen`. On the disposable checkout only, point
   those locations at the newly installed tools. For example, after confirming
   `go` and `cbindgen` resolve correctly on PATH:

   ```sh
   mkdir -p .toolchains/cbindgen/bin
   ln -s "$(go env GOROOT)" .toolchains/go
   ln -s "$(command -v cbindgen)" .toolchains/cbindgen/bin/cbindgen
   flutter pub get
   flutter build macos --debug --config-only
   ```

   Do not replace an existing directory/symlink with these commands. Use the
   existing installation if already provisioned. Run gates serially: native
   archives and Flutter's generated files are shared between build commands.
4. Configure signing in Xcode for Runner, ElarniPacketTunnel and
   ExtensionIntegrationTests, using a development team authorized for the
   identifiers in the project. Keep the application group, shared Keychain
   access groups and packet-tunnel entitlements consistent. The checked-in team
   is not automatically available on another machine. Set up signing before
   the runtime command; the runner does not register devices or modify accounts.
5. In Xcode's Runner scheme, build and launch the test app. Provision exactly one
   two-node subscription containing stable, working Xray-compatible fixture
   profiles with distinct effective configurations. Both nodes must support IPv4/IPv6 TCP and UDP destinations, both
   backends, and access to the responder. A simple SOCKS TCP/UDP or VLESS fixture
   is suitable; HTTP-only outbounds cannot pass UDP acceptance. The source must
   return unchanged effective configurations during the automatic refresh case.
   Keep the test feed independent of personal providers and hidden/expiring URLs.
6. Select one node; create/approve the VPN profile; connect once to approve VPN
   permission, then disconnect. Set Include all networks on; Xray TUN, On Demand,
   automation, HTTP inbound, LAN access and per-app routing off. Use default full
   included routes (`0.0.0.0/0`, `::/0`), no excluded routes, route enforcement off,
   no inbound credentials and no custom routing assignments. Refresh the feed
   immediately before testing; its next maintenance refresh must be at least ten
   minutes away. Quit every Elarni host. The suite validates the real persisted
   automation policy before installing its temporary command-intent defaults.

## Prepare controlled traffic infrastructure

Use a separate dual-stack responder reachable directly from the Mac and through
both nodes. Its address must not be a proxy endpoint, excluded route, loopback,
link-local address, or the tunnel's own `192.0.2.0/30` / `2001:db8::/126` subnet.
The Mac's direct public egress and the nodes' egress addresses must be different.
Record actual addresses; do not infer them from node names. If NAT is involved,
use the address the responder sees. Allow all expected v4/v6 egress addresses in
the responder and its firewall. Do not place a TCP load balancer in front of the
raw TCP listener: it would hide the client's egress address.

`macos/Checks/AcceptanceResponder.py` provides an exact-body HTTP `/check`, a
source-observing HTTP `/observe?nonce=<UUID>`, and separate TCP/UDP JSON responders.
TCP accepts newline-terminated UUID requests and keeps a connection UUID across
requests. UDP accepts the same request framing. Responses echo the nonce, peer
address and connection UUID. It neither proxies requests nor writes request logs;
an explicit source allowlist is required.

On the responder, substitute real local bind addresses and permitted egresses:

```sh
python3 macos/Checks/AcceptanceResponder.py \
  --bind '<responder-v4>' --bind '<responder-v6>' \
  --allow '<direct-egress-v4>/32' --allow '<direct-egress-v6>/128' \
  --allow '<node-egress-v4>/32' --allow '<node-egress-v6>/128' \
  --http-port 18080 --tcp-port 18081 --udp-port 18082
```

Repeat `--allow` for the second node if needed. Ports shown are fixture choices,
not required product settings. Expose `/check` through a valid HTTPS frontend
with a trusted certificate if needed for macOS App Transport Security. Do not
disable certificate verification or change app entitlements to get a pass.
`/check` must return exactly `elarni-fixture`, status 200, no newline and no
redirect; it ignores `nonce`. The HTTP frontend does not serve the raw TCP/UDP
tests, which connect directly to their numeric addresses and ports.

Create two DNS wildcard zones: `*.v4.<your-test-domain>` with **only A** records
pointing to the responder IPv4 address, and `*.v6.<your-test-domain>` with **only
AAAA** records pointing to its IPv6 address. The suite generates a new random
label for each request and requires successful traffic using that address family.
This establishes DNS functionality; DNS capture/leak policy additionally requires
operator case M03.

## Create the fixture

Inside the test app's container, create a JSON file, for example
`~/Library/Containers/com.elarni.mac/Data/acceptance.json`. Obtain IDs from
**only the disposable account's** `subscriptions-v1.json` catalog. Do not export
the catalog, endpoint keys, subscription URL or credentials into the fixture.
The addresses below are documentation placeholders and must be replaced.

```json
{
  "disposableAccount": "elarni-test",
  "subscriptionID": "test-source-id",
  "nodeIDs": ["first-node-id", "second-node-id"],
  "probeURL": "https://check.your-test-domain.example/check",
  "expectedBody": "elarni-fixture",
  "network": {
    "ipv4": "198.51.100.10",
    "ipv6": "2001:db8:100::10",
    "tcpPort": 18081,
    "udpPort": 18082,
    "directEgress": ["198.51.100.20", "2001:db8:200::20"],
    "nodeEgress": {
      "first-node-id": ["203.0.113.30", "2001:db8:300::30"],
      "second-node-id": ["203.0.113.40", "2001:db8:400::40"]
    },
    "dnsIPv4Suffix": "v4.your-test-domain.example",
    "dnsIPv6Suffix": "v6.your-test-domain.example"
  }
}
```

## Run and interpret results

From the repository root on the disposable Mac, run each command separately and
stop on a nonzero exit. Prefix with `rtk proxy` when RTK is installed.

```sh
scripts/check-tests
scripts/check-macos-harness
scripts/check-extension --build-only
scripts/check-extension --suite full --validate-fixture "$HOME/Library/Containers/com.elarni.mac/Data/acceptance.json"
scripts/check-extension --suite full --fixture "$HOME/Library/Containers/com.elarni.mac/Data/acceptance.json" --disposable-machine
```

The first command executes the existing four host suites. Keep the race commands
in `TESTING.md` for changes affecting those boundaries. The harness command uses
synthetic loopback TCP/UDP/HTTP only, including a compiled Swift network client.
Build-only compiles all installed tests unsigned in `.build/macos-acceptance/unsigned`
without launching the app. Fixture validation checks schema only.

Runtime requires the explicit disposable-machine flag and refuses an existing
Elarni process or active VPN visible to `scutil`. XCTest additionally checks
the account, exactly one disconnected Elarni profile, the exact test catalog
and settings. OS VPN APIs do not enumerate every possible third-party network
filter; the disposable-machine requirement still applies.

Runtime builds a signed Debug host, extension and test bundle in a fresh
`.build/macos-acceptance/run-<timestamp>-<id>` directory. Each run gets
`TestResults.xcresult` and `summary.json`. The runner accepts success only if the
command succeeds and the result bundle reports exactly the selected number of
passing tests, with zero failed, skipped or expected-failure tests. An incomplete
run stays incomplete. Operator acceptance is always recorded separately as
pending. No profile/configuration dump is written by the runner.

All installed cases run serially. Normal completion and caught failures attempt
to stop the provider, remove temporary cloned sources, restore the original node
and settings, and leave the profile disconnected. Refresh timestamps are not
rolled back. A process kill or XCTest execution timeout can prevent cleanup:
stop the test VPN, disable On Demand/automation, inspect the test catalog and
routes/DNS before another run. Never treat failed cleanup as a pass.

List or rerun a selected boundary:

```sh
scripts/check-extension --list
scripts/check-extension --case refresh --case per-app --fixture "$HOME/Library/Containers/com.elarni.mac/Data/acceptance.json" --disposable-machine
```

Without `--suite full` or `--case`, the runner retains the original lifecycle-only
selection and accepts the original five-field fixture. A selected-case pass is
not a full-suite pass. No test is implicitly skipped because IPv6, signing,
Keychain, routes or the responder is unavailable.

| Case | Installed assertions |
|---|---|
| `lifecycle` | Native bridge startup fault; shared Keychain; HTTP body and growing counters; candidate restoration with exact receipts; switching/restart; protected core/restoration failure; cleanup preceding OS disconnect. |
| `traffic` | Direct baseline, both backends, both nodes, IPv4/IPv6 TCP and UDP with observed proxy egress; fresh A/AAAA resolution; counters; backend-appropriate switch identity; reconnect and direct connectivity after Stop. |
| `refresh` | Three real unchanged refreshes per backend; same provider generation and configuration digest, retained selection, the same established TCP socket and responder connection UUID, fresh TCP/UDP traffic. |
| `controller` | Destroy/recreate the real Swift controller, retain VPN identity and a TCP stream, persist Stop intent across another recreation. This does not kill the app process. |
| `reconnect` | Ordered concurrent Start/Stop submissions, allowed cancellation only, idempotent Stop, six reconnect cycles with real traffic and no on-demand rearming. Startup timing itself is nondeterministic. |
| `on-demand-repair` | On Demand installed without replacing the provider, Stop disarms OS rules, repair removes the saved profile, reconnect creates a fresh provider with working traffic on both backends. |
| `per-app` | Installed Xray TUN attributes sockets from the sandboxed host, matching executable name, exact path and app-folder prefix; selected/unselected bypass and only-listed cases; TCP/UDP over IPv4/IPv6 with direct/proxy egress assertions. Real Chrome subprocess attribution is M02. |
| `routes` | Specific included v4/v6 routes with enforcement and excluded v4/v6 routes under a full route list, both backends, observed egress for all four traffic combinations. |
| `xray-failure` | Xray TUN startup fault, exact core-exit receipt, retained protection, no TCP/UDP responder access over either family, Stop and recovery. Only transport failures satisfy the negative assertion. |
| `deletion` | Create a temporary source through the real share/import channel, select/connect it, enable On Demand, delete it, assert the saved profile and selection are gone and do not rearm, then reconnect the original node. Provisioned source survives. |
| `settings` | Occupied listener update returns its specific error and rolls back settings/traffic; invalid port is rejected without replacing the restored provider, both backends. |

## Operator matrix: physical, UI and externally induced failures

These are executable test procedures, not automatic passes. Run on the same
disposable machine after the automated suite, using the actual Flutter UI.
Repeat backend-dependent cases with native tun2proxy and Xray TUN. Use a Release
build as well as Debug for UI/traffic and performance checks: Debug XCTest results
do not establish Release behavior, signing distribution, or minimum-OS support.
Use only generated test credentials and a controlled network/server. Restore the
baseline fixture after every case that changes its catalog or policy.

For each row record `PASS`, `FAIL` or `BLOCKED`, macOS/Xcode/app version and build
configuration, backend, steps actually executed, observed result and a short
sanitized diagnostic. Record unavailable cameras/networks as BLOCKED. Preserve
failures and partial runs. Store test reports only in the disposable run directory;
never export personal Keychain data or packet payloads. All rows start **PENDING**.

| ID | Procedure | Required result |
|---|---|---|
| M01 VPN consent/signing | From a fresh disposable account/profile, deny the first VPN permission request; retry and allow. Test an intentionally unsigned test build separately. | Denial/signing failure is visible; no stuck Connecting or leaked listeners; signed retry connects and passes traffic. Do not bypass macOS security settings to mark unsigned execution successful. |
| M02 Actual browser per-app | Fully quit Chrome and its helpers. Add its actual `.app/` path using the native app picker. Test bypass and only-listed with Chrome selected/unselected; restart it between changes. Disable browser secure-DNS overrides for the system-DNS test. Visit responder `/observe` with a new UUID for IPv4-only and IPv6-only hosts; also exercise controlled UDP/HTTP3 traffic if supported by the browser fixture. Compare with an unlisted client. | Egress matches each policy for browser helper processes; unlisted client follows complementary policy. No stale browser connection is counted after a rule change. UI app selection persists. Mark unavailable HTTP3 infrastructure explicitly. |
| M03 DNS capture/blocking/leaks | On a controlled physical link, monitor only the disposable fixture's DNS names/server addresses using a packet capture outside the Mac (gateway preferred). Query fresh A/AAAA names through the system resolver while connected, after reconnect, under a routing DNS override and with a blocking rule. Test UDP and TCP DNS, and browser DNS settings separately. | Answers/blocks match routing policy. No unapproved plaintext physical DNS escapes while policy requires tunnel DNS. A blocked name does not resolve by another configured resolver. Post-Stop DNS returns to the baseline. Functional DNS XCTest alone cannot prove this. |
| M04 Sleep/wake | Keep a steady responder flow, sleep the physical Mac, wake it. Repeat with Disconnect on sleep off/on and On Demand off/on. | Behavior matches the chosen policy; wake resumes working traffic or visibly remains stopped as configured. No stale Connected UI with unusable traffic, duplicate owners or unbounded reconnect loop. Record wake-to-first-success time. |
| M05 Physical paths | While sending timestamped fixture traffic, move Wi-Fi to Ethernet and back; unplug/replug the active cable; briefly remove all connectivity; change Wi-Fi networks. Repeat during Connecting and a node switch. | State reflects loss/recovery, selected node/policy remain coherent, new traffic eventually succeeds when connectivity returns. Stop during recovery prevents a later reconnect. Record outages instead of inventing a fixed recovery threshold. |
| M06 Captive portal/offline | Join a controlled captive network and deny its portal access, then complete login. Repeat offline startup. | Failure remains visible and bounded; no silent switch to direct traffic while claiming protected operation; explicit retry succeeds after access is restored. |
| M07 Host close/quit/kill | With working traffic, close the last window, quit normally and force-quit only the test host in separate runs; relaunch. Repeat host termination during Connecting and switching. | A running Network Extension can outlive the UI: its traffic/state is recovered on relaunch. In-flight intent is reconciled and UI is truthful. Stop after relaunch cleans up. The controller recreation XCTest is not a substitute for process death. |
| M08 Provider termination | Force-quit only the disposable packet-tunnel provider while sending fixture traffic; repeat with On Demand/automation disabled and enabled. Observe from an independent gateway/client. | No silent direct traffic while UI claims protected/connected operation. Failure/recovery is visible; explicit Stop disarms retry and restores baseline; reconnect succeeds. Record actual OS behavior and any protection gap. Debug core-exit injection is not an OS-process kill. |
| M09 OS controls/reboot | Disconnect through System Settings while UI is open; reconnect explicitly. Repeat reboot/login with launch at login off/on and with persisted Stop intent. | UI follows OS state, Stop does not unexpectedly rearm, login registration matches the UI and can be removed. An enabled intentional recovery policy behaves consistently with its saved settings. |
| M10 Refresh variants | Hold an established fixture TCP stream. On the controlled feed, publish display-name-only changes, identical data, a changed valid selected runtime, changed unselected node, and a structurally invalid selected runtime in separate rounds. Trigger both manual and naturally scheduled refresh, including a different subscription refreshing. | Unchanged effective selected configuration preserves stream/provider; invalid candidate does not stop the working runtime; a valid changed plan takes effect with expected backend transition. Failed publication preserves usable prior selection/credentials and displays failure. Record stream outage for actual changed plans. |
| M11 Refresh HTTP/transactions | Serve 401/403/500, timeout, malformed/oversized/truncated feed, redirect and address-risk challenge; cancel while fetching and while a publication is queued. Then serve the valid feed again. | Existing catalog/traffic survive failed or unapproved updates; challenges apply only to their originating operation; cancellation completes; retry works without duplicate sources, stale selection or credentials in errors. |
| M12 Selected-node removal | With a fixture connection and On Demand, publish a feed removing the selected node. Repeat fixed selection and configured ordered fallback. | Fixed policy stops/removes selection safely; fallback chooses only a valid remaining configured candidate after its health check. No reconnection to removed credentials. Explicit Stop wins over an in-flight refresh. |
| M13 Provider-owned routing deletion | Add disposable sources A/B; select B. Assign routing from A to B, duplicate it as an independent copy, and retain another independent route. Delete A while connected. Repeat deleting the selected source with On Demand. | B is synchronized to the remaining valid routing; deleted-provider assets are detached; independent copies survive; traffic follows the final policy. Selected deletion removes its saved plan and cannot rearm. |
| M14 Routing/DNS editors | Import a routing profile by text, file, QR image and routing-only clipboard exchange. Test direct/proxy/block domains and IP ranges, group/balancer choice, geofile refresh and invalid data. Change rules while connected. | UI, persisted rules, runtime digest and observed direct/proxy/block traffic agree; failures preserve the previous usable rules; no endpoint secrets appear in routing-only export. |
| M15 Imports/native pickers | Import synthetic VLESS/VMess/Trojan/SS/SOCKS/Xray/Clash/WireGuard client inputs, files under a path with spaces and QR images; cancel file/app pickers; select unsupported files. Exercise incoming client/routing links with the app closed and open. | Supported inputs reach the correct source/group; unsupported input has a bounded error; cancel makes no change; links arrive once and selection persists after relaunch. Protocol transport correctness remains covered by the existing Go fixtures and actual runtime cases for configured transports. |
| M16 Camera lifecycle | With a real camera, allow access and scan; cover the lens/no QR; press Cancel; close the red window button; cancel immediately; cancel while first permission prompt is pending; deny permission and retry after changing it. Start another scan/command after each. | Exactly one completion per scan, camera indicator turns off, no orphan window or blocked command, next scan can work. Record hardware/permission-dependent cases separately. |
| M17 Backup/restore | Create a password-protected backup of test-only mixed profiles, groups, routing and selection using the native save panel. Cancel save/open; attempt wrong password, malformed backup and valid restore while connected. Relaunch. | Cancel/wrong password do not replace catalog. Valid restore safely stops/reconciles runtime, restores supported data/selection and fresh trust decisions, keeps automation disabled and can reconnect. Do not export the backup off the disposable machine. |
| M18 Inbounds/LAN authentication | Test SOCKS5 and enabled HTTP proxy with real clients. Test wrong/correct synthetic credentials; with authentication off, a client without credentials while connected; unauthenticated LAN enablement; another machine's allowed LAN access. Occupy each TCP/UDP listener port, including HTTP; release and retry. | Settings reject unauthenticated LAN access; wrong credentials fail, correct ones work; with authentication off the connected listeners still refuse clients without the per-session login; local-only mode is not reachable from another machine; conflicts are visible and rollback preserves usability; Stop leaves no test listener. |
| M19 Ping and cancellation | While connected, run direct TCP and proxy probes over supported endpoints; cancel a batch. Confirm ICMP's interruption prompt; deny once, allow once, then press Stop during testing. Use a test endpoint known not to answer real ICMP. | TCP/proxy tests do not replace the working provider; no synthetic TUN echo is reported as endpoint RTT; failure/restoration failure are distinguished; cancel completes and Stop prevents restoration. |
| M20 Automation/failover | Configure fixed, lowest-latency and ordered fallback policies against controlled healthy/unhealthy nodes/targets. Fail the active node, restore it, exhaust candidates; change policy and press Stop during recovery. | Candidate selection follows policy/health, retries/backoff remain bounded, errors are visible, no overlapping providers or stale late activation. Recovery uses a valid node and Stop cancels/disarms it. |
| M21 Desktop integration | Exercise status menu Connect/Disconnect/Show/Quit, launch at login registration/denial, expiry notification allow/deny, minimize/reopen, clipboard sharing and Telegram handoff with a test target. | Controls agree with current state, preference changes persist, denied permissions produce actionable errors, notifications/handoff do not duplicate or expose credential-bearing content. |
| M22 Release soak/resource limits | In Release, run both backends for at least 60 minutes with idle intervals, repeated reconnects, TCP/UDP load and refresh. Exercise Automatic/explicit memory settings, TCP/UDP admission limits and idle capacity reuse using isolated fixture clients. | No sustained resource growth, spinning idle CPU, traffic stalls, descriptor/listener accumulation or hidden reconnect loop. Admission limits reject excess sessions and idle expiry permits new sessions. Record baseline/peak/final metrics and latency; do not use Debug footprint as the Release baseline. |
| M23 Fragmentation/transports | Against matching controlled servers, exercise the actually shipped transport/security combinations (including VLESS XHTTP/REALITY), fragmentation, mux, preferred IP and profile DNS controls. Include large transfers/MTU-sensitive traffic and UDP after reconnect. | Real traffic is correct, unsupported combinations report errors without harming the previous configuration, no silent family fallback defeats explicit policy. Enumerate which server combinations were actually tested. |
| M24 Final cleanup | After normal Stop, failure, repair and source deletion, compare the test-specific routes, DNS and listeners with baseline; relaunch once and remain idle. Restore test network settings, remove login registration and stop the responder. | No Elarni-owned listener/provider or unexpected rearming remains. Direct IPv4/IPv6/DNS work. Do not delete unrelated macOS `utun` interfaces merely because their count changed. |
| M25 Minimum OS/distribution | Repeat build/install/consent and traffic smoke on the oldest supported real macOS and on the intended signed distribution build. Launch from a path with spaces and test upgrade over a disposable prior catalog. | Supported OS/runtime works; signature/entitlements and persisted fixture data survive intended installation/upgrade. Current Debug build-only does not establish this result. |
| M26 GUI/CLI/daemon ownership | Use the bundled CLI against the signed test GUI, then against the headless host. Race Connect, Disconnect, recovery and refresh. Start a second host with the same catalog and with an alternate socket; terminate only the owning test host and relaunch. From another disposable OS user, attempt to connect to its Unix socket. | Exactly one catalog owner; the other user cannot control it. Stop cancels pending startup/recovery and remains stopped after relaunch. Stale-owner shutdown cannot terminate the replacement. Native signed host behavior is required in addition to the isolated IPC fixture. |
| M27 Interrupted publication | In the disposable Debug host, use debugger breakpoints to terminate after the new selected plan is applied but before `finishPublication`, then relaunch; repeat during backup restore and while saving settings. Deny OS preference writes during recovery and retry after restoring access. | An interrupted publication rolls back the catalog, stops/disarms the provider and reconciles the saved plan before new work. Failure retains the recovery marker and candidate credentials; retry finishes recovery. No automatic reconnect uses the interrupted candidate. Verify actual traffic, saved selection and routes after explicit reconnect. Backup/settings retain their documented transaction behavior. |

No row is considered complete solely because its unit tests passed. A full
acceptance report identifies every blocked/failed row and the exact installed
automated selection that ran; it does not collapse them into one green build.
