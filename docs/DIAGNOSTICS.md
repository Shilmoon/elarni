# Connection recording

Connection recording is a build option, off by default: release builds contain
neither the collector nor its controls. A build made with the option can record
connection metadata to trace connect problems. It is off until
**Record connection diagnostics** is switched on: Settings → Advanced on
desktop, Android and iPhone, or `recordDiagnostics` in headless settings.
Changing it reconnects. While it is on, the process that carries traffic runs the
collector described below; nothing is sent anywhere.

**Mark problem** (on the main screen while recording, in Troubleshooting on phones,
`markRecording` headless) notes the moment the user saw a problem. With a tunnel
running, the mark also lists each open connection's byte counts and pending I/O
on Android, iOS and macOS. Without one, or on Windows and Linux, it is a timestamp
written by the app itself, which still dates a connect that failed.
**Save recording as ZIP** (`exportRecording` headless) packages what is retained.
It works after the switch is turned off, until the files age out.

| Platform | Recording directory |
|---|---|
| Windows | `%LOCALAPPDATA%\Elarni\Diagnostics` of the user running the core. A VPN core elevated with another administrator's credentials records in that account's profile, which an export from the signed-in user cannot read. |
| Linux | `~/.cache/Elarni/Diagnostics` for proxy mode and marks; `/var/log/elarni/<uid>` for the root VPN worker. That directory belongs to the user, and each segment is created exclusively and handed to them. |
| macOS, iOS | The app group's `Diagnostics` directory, shared by the app and its tunnel extension. |
| Android | `diagnostics` in the app's no-backup files. |

Retention is 256 MiB on desktop and 64 MiB on phones, in 8 MiB segments, pruned
after 72 hours.

Cost, measured with a Go benchmark on a Windows desktop: about 4 µs of CPU per
recorded event with the segment kept open (140 µs when it reopened the file per
event), and 8 ns per read or write for byte counting. Estimated from these, a busy
session costs about 0.1% of a desktop core and 0.3–0.5% of a phone core. An idle
one costs nearly nothing. Disk writes are bounded by the retention budget.

On macOS the sandboxed app cannot write a path chosen by `elarni-cli`, so a
headless `exportRecording` saves the ZIP in the app's temporary folder and
returns that `path`.

## Building with recording

One switch, `ELARNI_RECORDING`, turns the option on at every layer:

| Build | Command |
|---|---|
| Windows, Linux, macOS | `flutter build <platform> --dart-define=ELARNI_RECORDING=true`. The define adds the controls and the headless methods; the Windows and Linux build files and the macOS Go build phase see it and compile the core (and `elarni-cli`) with the `elarni_recording` Go tag. |
| Android | `ELARNI_RECORDING=1` for both `scripts/build-android-native` (the core) and Gradle (`BuildConfig.ELARNI_RECORDING`, the controls). |
| iOS | `ELARNI_RECORDING=1 scripts/build-ios-native <platform>`, then `xcodebuild` with `SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) ELARNI_RECORDING'`. |
| Core alone | `go build -tags=elarni_recording ./Vendor/libXray/cmd/elarni-core` |

Without the option the core's `diagnostics` request answers `status` with
`enabled: false` and refuses every other action, and a `recordDiagnostics` saved
by a recording build is ignored. `sh scripts/check-tests go` and `flutter`, and
`python scripts/check-windows`, test both builds.

# Daily diagnostic build

Build on Apple Silicon macOS with `python3 scripts/build-diagnostics-macos`.
The signed Debug app is written separately to
`.build/xhttp-diagnostics/macos/Build/Products/Debug/Elarni.app`.
The script does not install, launch, or stop any app or VPN.
Use `--output /absolute/path/to/new/build-folder` to keep a running diagnostic
bundle untouched while preparing an updated build.
Each diagnostic build receives a distinct release/build version. macOS may
otherwise launch an older registered tunnel extension with the same version,
even when the new app window is open. Both processes record their build number
as an `app_state` event; check that these match before attributing an incident.

When ready, disconnect and quit the old app yourself, then open this bundle and
connect normally. The **Diagnostics** menu confirms recording is enabled.
Use **Mark a Stall** when traffic freezes (Command–Option–Shift–M), then
**Export Diagnostic Logs…** after recovery. Send the resulting ZIP and a short
description of the incident. Export also works after restarting the app; retained
logs from older host/provider processes are included. A marker is helpful but not
required: recording runs continuously while the diagnostic app is in use.

The collector records UTC and monotonic times, process/session/connection IDs,
XHTTP mode and pool settings, socket/security/HTTP phases and error categories,
per-second stream/socket byte counts and pending I/O, DNS timings, Go memory/GC,
native counters, network-path changes and provider lifecycle/sleep/wake events.
WireGuard/AmneziaWG additionally record tunnel DNS timings, selected IP family,
TCP dial outcomes and separate inner TCP/UDP and outer transport byte/operation
counts. Flow IDs link DNS/dial events to streams; tunnel IDs link flows to the
shared transport. These are application I/O measurements, not packet captures
or decoded TLS handshakes. The normal core metrics count inbound app traffic.
Pending I/O and idle counters are evidence, not automatic proof of a network fault.
It sends no test traffic and does not reconnect the VPN automatically.

Logs remain local in the app group's `Diagnostics` directory. Retention is a
rolling 256 MiB budget in 8 MiB segments, with files older than 72 hours pruned
at rotation. Multiple processes may temporarily exceed the budget by their active
segments. Busy sessions may retain less than 72 hours. Exports include only the
collector's regular JSONL files and a manifest. Credentials, profiles, endpoint
URLs/IPs, DNS names, headers, payloads and ordinary raw Xray logs are excluded.
Dropped events are counted. An unresponsive provider can prevent its flush reply;
the host records that outcome and still exports already-written provider files.

The diagnostic build records from launch, whatever the setting says. It needs the
`elarni_diagnostics` Go tag, and on macOS also `DEBUG` and `ELARNI_DIAGNOSTICS`,
which add the Diagnostics menu. Diagnostic Go archives use their own output
directory; the Xcode build rejects them outside Debug. Recording builds record
only while the setting is on; release builds never record.

The shared helper can also be built with `go build -tags=elarni_diagnostics`
on Windows. It records under the user's cache directory `Elarni/Diagnostics`
(or `ELARNI_DIAGNOSTICS_DIR` when supplied) and accepts
`elarni-core --diagnostics-export <new-absolute-path.zip>`. Normal helpers lack
this export switch; the app exports through the `diagnostics` request instead.

## Windows diagnostic candidate

Use `python scripts/build-diagnostics-windows --bundle <complete-existing-x64-bundle>
--output <new-empty-directory> --go <go.exe>` on Windows. This preserves the input
bundle and reuses its UI/libraries while rebuilding the core from the current
source with the earlier routing fixes and `elarni_diagnostics`. `BUILD-INFO.json`
identifies that provenance and the numeric build ID recorded by every helper.
The builder runs the diagnostic proxy/export acceptance check and the existing
complete-bundle packager, producing a clearly labeled unsigned diagnostic ZIP.
The input bundle must be built from the same release as the source checkout:
the packager refuses one whose `elarni.exe` version differs from `pubspec.yaml`,
because the ZIP is named after that version. To diagnose an older release,
check out its tag, or build a fresh bundle from the current source first.

The recipient extracts the app, opens `elarni.exe`, connects and reproduces the
problem, then double-clicks **Export diagnostics.cmd**. One timestamped ZIP
appears beside the app, and Explorer opens that folder. No enable switch or
environment variable is required. The exporter can also run after the app exits.
The existing in-app export button remains the small JSON status snapshot.

Windows records physical-route/default-route counts, interface binding results,
DNS-server availability and dial outcomes, raw TUN packet/byte counters and
packet-loop failures, per-app lookup/match outcomes, socket/outbound errors,
startup/readiness/shutdown, and a numeric summary of runtime configuration.
These extend the existing protocol/DNS/runtime recorder. No addresses, process
paths, profile tags, raw errors or payloads are written. The collector observes
real traffic; it does not generate probes or change the selected routing policy.

Validate a tagged helper with `python scripts/check-windows-diagnostics --core
<elarni-core.exe>`. It uses a real loopback proxy and a failing socket, then checks
automatic collection, a complete one-file export, redaction and no-overwrite.

Regression checks:

```
go test ./Vendor/libXray/share -run TestXHTTP -count=1 -timeout=60s
go test -tags=elarni_recording ./Vendor/Xray-core/common/flightrecorder
go test -race -tags=elarni_diagnostics ./Vendor/Xray-core/common/flightrecorder ./Vendor/libXray/share -run 'TestCollector|TestXHTTP|TestImportedClientsCarryLoopbackTraffic' -count=1 -timeout=120s
```

These use synthetic loopback fixtures. Real unattended-stall attribution needs
an incident captured by the diagnostic build. Building it does not establish
installed-extension or real-Windows VPN acceptance.
