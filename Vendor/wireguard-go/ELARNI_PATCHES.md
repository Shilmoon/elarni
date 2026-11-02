# Elarni patches

Upstream: golang.zx2c4.com/wireguard v0.0.0-20250521234502-f333402bd9cb (the
version Vendor/Xray-core requires), joined to the build by `go.work`.

- `device/queueconstants_default.go`, `device/queueconstants_android.go`:
  `MaxSegmentSize` is 2016 bytes as on Windows, not 64 KiB. The large buffers
  exist for UDP GSO/GRO and TUN offload, which Xray's WireGuard bind and gVisor
  TUN do not use, so every queued packet held 64 KiB for about 1.5 KB of data
  (66 MB at 200 busy connections). Xray lowers a larger tunnel MTU to
  `device.MaxContentSize` (proxy/wireguard `tunnelMTU`).
- `device/pools_test.go`: the failure message reads the atomic counter with
  `Load()`, so `go vet` (copylocks) passes on Go 1.27.
