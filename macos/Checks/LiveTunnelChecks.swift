import Darwin
import Foundation

@main
struct LiveTunnelChecks {
  struct Failure: Error { let message: String }

  static func main() async {
    setbuf(stdout, nil)
    // Includes one real 60-second fragment-expiry observation.
    DispatchQueue.global().asyncAfter(deadline: .now() + 120) {
      fputs("FAIL live tunnel check timed out\n", stderr)
      exit(1)
    }
    do { try await run() }
    catch let error as Failure { fputs("FAIL \(error.message)\n", stderr); exit(1) }
    catch { fputs("FAIL live tunnel check: \(error)\n", stderr); exit(1) }
  }

  static func run() async throws {
    try await resolverCancellation()
    try require(elarni_packet_abi_version() == ELARNI_PACKET_ABI_VERSION, "packet bridge ABI")
    let hosts = try invoke("profileHostMappings", ["configJSON": "{\"dns\":{\"hosts\":{\"domain:provider.test\":\"192.0.2.8\"}}}", "hosts": ["edge.provider.test"]]) as! [String: Any]
    let host = hosts["edge.provider.test"] as? [String: Any]
    try require(host?["addresses"] as? [String] == ["192.0.2.8"], "core DNS bootstrap matcher FFI")
    print("PASS provider DNS bootstrap matcher through native FFI")
    try coreLogFiles()
    let socks = try boundSocket(SOCK_STREAM)
    let server = try boundSocket(SOCK_STREAM)
    let echo = try boundSocket(SOCK_DGRAM)
    let echo6 = try boundSocket(SOCK_DGRAM, ipv6: true)
    defer { Darwin.close(echo.fd) }
    defer { Darwin.close(echo6.fd) }
    let uri = "vless://00000000-0000-4000-8000-000000000001@127.0.0.1:\(server.port)?encryption=none&security=none&type=tcp#Live-test"
    let converted = try invoke("convertShareLinksToXrayJson", ["text": uri]) as! [String: Any]
    let outbound = (converted["outbounds"] as! [[String: Any]])[0]
    var config = try compiledConfig(outbound: outbound, socksPort: socks.port)
    // The test server may reach only the loopback echo target. Xray otherwise
    // blocks private destinations received from a VLESS inbound by default.
    var outbounds = config["outbounds"] as! [[String: Any]]
    let direct = outbounds.firstIndex { $0["tag"] as? String == "elarni-direct" }!
    var settings = outbounds[direct]["settings"] as! [String: Any]
    settings["finalRules"] = [["action": "allow", "ip": ["127.0.0.1/32", "::1/128"]]]
    outbounds[direct]["settings"] = settings
    config["outbounds"] = outbounds
    var inbounds = config["inbounds"] as! [[String: Any]]
    inbounds.append([
      "tag": "test-vless-server", "listen": "127.0.0.1", "port": Int(server.port),
      "protocol": "vless", "settings": [
        "clients": [["id": "00000000-0000-4000-8000-000000000001"]], "decryption": "none",
      ], "streamSettings": ["network": "tcp", "security": "none"],
    ])
    config["inbounds"] = inbounds
    var routing = config["routing"] as! [String: Any]
    var rules = routing["rules"] as! [[String: Any]]
    rules.insert(["type": "field", "inboundTag": ["test-vless-server"], "outboundTag": "elarni-direct"], at: 0)
    routing["rules"] = rules
    config["routing"] = routing
    let configJSON = String(decoding: try JSONSerialization.data(withJSONObject: config), as: UTF8.self)
    Darwin.close(socks.fd); Darwin.close(server.fd)
    defer { _ = try? invoke("stopXray") }

    let adapter = NativePacketBridge()
    for cycle in 1...2 {
      _ = try invoke("runXrayFromJson", ["configJSON": configJSON])
      let state = try invoke("getXrayState") as! [String: Any]
      try require(state["running"] as? Bool == true, "Xray did not start")
      try tcpRoundTrip(socksPort: socks.port)
      print("PASS live VLESS TCP round trip \(cycle)")
      try packetRoundTrip(socksPort: socks.port, echo: echo, cycle: cycle)
      try await adapterRoundTrip(adapter, socksPort: socks.port, echo: echo, cycle: cycle)
      if cycle == 1 { try await coreSwitchDatagram(adapter, socksPort: socks.port, echo: echo, configJSON: configJSON) }
      try await largeDatagramReplies(adapter, socksPort: socks.port, echo: echo)
      try await largeDatagramReplies(adapter, socksPort: socks.port, echo: echo6, ipv6: true)
      try await fragmentedDatagramRequests(adapter, socksPort: socks.port, echo: echo)
      try await fragmentedDatagramRequests(adapter, socksPort: socks.port, echo: echo6, ipv6: true)
      if cycle == 1 {
        try await fragmentBounds(adapter, socksPort: socks.port, echo: echo, checkExpiry: true)
        try await fragmentBounds(adapter, socksPort: socks.port, echo: echo6, ipv6: true)
      }
      if cycle == 1 { try liveness(socksPort: socks.port, outbound: outbound) }
      _ = try invoke("stopXray")
      let stopped = try invoke("getXrayState") as! [String: Any]
      try require(stopped["running"] as? Bool == false, "Xray did not stop")
    }
    print("PASS tunnel stop/restart with real TCP and UDP traffic")
  }

  // The provider checks a server with a request through the running core,
  // gated by traffic leaving; the counters alone cannot tell a dead server.
  static func liveness(socksPort: UInt16, outbound: [String: Any]) throws {
    let target = try boundSocket(SOCK_STREAM)
    defer { Darwin.close(target.fd) }
    try require(listen(target.fd, 8) == 0, "HTTP target listen")
    Thread.detachNewThread {
      let reply = Array("HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
      while true {
        let peer = accept(target.fd, nil, nil)
        guard peer >= 0 else { return }
        var request = [UInt8](repeating: 0, count: 4096)
        _ = read(peer, &request, request.count)
        _ = reply.withUnsafeBytes { write(peer, $0.baseAddress, $0.count) }
        Darwin.close(peer)
      }
    }
    func passes() -> Bool {
      (try? invoke("ping", ["runningCore": true, "url": "http://127.0.0.1:\(target.port)/", "method": "GET",
                            "timeout": 3, "expectedStatus": 204, "expectedBody": ""])) != nil
    }
    func uplink() throws -> UInt64 {
      ((try invoke("getRuntimeMetrics") as! [String: Any])["uplinkBytes"] as? NSNumber)?.uint64Value ?? 0
    }
    var tracker = ProviderLiveness(interval: 0)
    try require(tracker.state == nil && tracker.needsProbe(uplink: try uplink(), at: 0), "Connect was not checked")
    tracker.record(passed: passes(), uplink: try uplink(), at: 0)
    try require(tracker.state == "ok", "a working server was not reported as passing traffic")
    try require(!tracker.needsProbe(uplink: try uplink(), at: 1), "an idle interval was checked again")
    try tcpRoundTrip(socksPort: socksPort)
    try require(tracker.needsProbe(uplink: try uplink(), at: 2), "an interval with traffic was not checked")
    // The same core with its server gone: nothing listens on the outbound's port.
    let closed = try boundSocket(SOCK_STREAM)
    Darwin.close(closed.fd)
    var dead = outbound
    var settings = dead["settings"] as! [String: Any]
    var servers = (settings["vnext"] as? [[String: Any]]) ?? []
    if !servers.isEmpty {
      servers[0]["port"] = Int(closed.port)
      settings["vnext"] = servers
    } else {
      settings["port"] = Int(closed.port)
    }
    dead["settings"] = settings
    let deadConfig = try compiledConfig(outbound: dead, socksPort: socksPort)
    _ = try invoke("stopXray")
    _ = try invoke("runXrayFromJson", ["configJSON": String(decoding: try JSONSerialization.data(withJSONObject: deadConfig), as: UTF8.self)])
    tracker.record(passed: passes(), uplink: try uplink(), at: 3)
    try require(tracker.state == "noTraffic", "a dead server was not reported: \(tracker.state ?? "nil")")
    try require(tracker.needsProbe(uplink: try uplink(), at: 4), "a failed check was not repeated")
    print("PASS liveness tells a working server from one that passes no traffic")
  }

  static func adapterRoundTrip(_ bridge: NativePacketBridge, socksPort: UInt16,
                               echo: (fd: Int32, port: UInt16), cycle: Int) async throws {
    let attempt = ProviderBoundaryEvidence.reset()
    defer { ProviderBoundaryEvidence.finish(attempt) }
    try await bridge.start(socksPort: socksPort, mtu: 1500, tcpMaxConnections: 8,
      udpMaxConnections: 8, inboundCredentials: nil, attempt: attempt)
    do {
      // A bad packet from the OS is dropped like line noise; it must not stop the pump and its tunnel.
      try bridge.submit(Data())
      try bridge.submit(Data([0x45, 0, 0]))
      var retained: [Data] = []
      let payloads = [Array("adapter-\(cycle)".utf8), Array(repeating: UInt8(65 + cycle), count: 1024)]
      for payload in payloads {
        try bridge.submit(Data(udpPacket(port: echo.port, payload: payload)))
        try echoDatagram(echo.fd, expected: payload)
        try require(bridge.awaitOutput(timeout: .seconds(5)) == true, "native adapter did not wake for its response")
        guard let response = bridge.receive() else { throw Failure(message: "native adapter response missing") }
        try require(response.count >= payload.count + 28 && Array(response.suffix(payload.count)) == payload,
          "native adapter truncated or changed the datagram")
        retained.append(response)
      }
      for _ in 0..<10 { try require(bridge.receive() == nil, "empty receive returned an old packet") }
      for (response, payload) in zip(retained, payloads) {
        try require(Array(response.suffix(payload.count)) == payload, "receive buffer reuse changed a retained packet")
      }
      try require(bridge.awaitOutput(timeout: .milliseconds(50)) == false, "idle native adapter reported output")
      // The packet pump waits on its own thread; Stop must wake it before the bridge is freed.
      let waiting = Task.detached { () -> (Bool?, Date) in (bridge.awaitOutput(timeout: .seconds(10)), Date()) }
      try await Task.sleep(for: .milliseconds(50))
      let stopping = Date()
      try await bridge.stop(deadline: .seconds(5))
      let (woke, at) = await waiting.value
      try require(woke == nil && at.timeIntervalSince(stopping) < 5, "Stop did not wake a waiting packet pump")
      try require(bridge.receive() == nil && bridge.awaitOutput(timeout: .seconds(1)) == nil,
        "stopped native adapter returned or waited for a packet")
      print("PASS native packet adapter drops bad input, wakes for output and on Stop, and retains independent datagrams across scratch-buffer reuse and restart \(cycle)")
    } catch {
      try await bridge.stop(deadline: .seconds(5))
      throw error
    }
  }

  // A short request isolates downlink framing from the OS's outbound fragmentation.
  // An oversized reply must remain one UDP datagram, including across IP fragments.
  static func largeDatagramReplies(_ bridge: NativePacketBridge, socksPort: UInt16,
                                   echo: (fd: Int32, port: UInt16), ipv6: Bool = false) async throws {
    let attempt = ProviderBoundaryEvidence.reset()
    defer { ProviderBoundaryEvidence.finish(attempt) }
    try await bridge.start(socksPort: socksPort, mtu: 1500, tcpMaxConnections: 8,
      udpMaxConnections: 8, inboundCredentials: nil, attempt: attempt)
    do {
      for size in [ipv6 ? 1452 : 1472, 1800, 8192, 32768] {
        let request = Array("large-reply-\(size)".utf8)
        let expected = (0..<size).map { UInt8($0 % 251) }
        try bridge.submit(Data(udpPacket(port: echo.port, payload: request, ipv6: ipv6)))
        try echoDatagram(echo.fd, expected: request, reply: expected)
        var received = [UInt8](repeating: 0, count: size + 8)
        var covered = Set<Int>()
        var identifier: UInt32?
        let deadline = Date().addingTimeInterval(5)
        while covered.count < received.count && Date() < deadline {
          guard let data = bridge.receive() else {
            try await Task.sleep(for: .milliseconds(5))
            continue
          }
          let packet = Array(data)
          try require(packet.count >= (ipv6 ? 48 : 28) && packet.count <= 1500,
            "large UDP reply has invalid IP framing")
          let word: (Int) -> UInt16 = { UInt16(packet[$0]) << 8 | UInt16(packet[$0 + 1]) }
          let headerLength: Int
          let offset: Int
          let more: Bool
          if ipv6 {
            try require(packet[0] >> 4 == 6 && Int(word(4)) + 40 == packet.count,
              "large UDP reply IPv6 framing")
            try require(Array(packet[8..<40]) == ipv6Destination + ipv6Source, "IPv6 reply addresses")
            if packet[6] == 44 {
              try require(packet[40] == 17 && packet[41] == 0, "IPv6 fragment next header")
              let id = UInt32(word(44)) << 16 | UInt32(word(46))
              if identifier == nil { identifier = id }
              try require(id == identifier, "IPv6 reply split into independent packets")
              headerLength = 48
              offset = Int(word(42) & 0xfff8)
              more = word(42) & 1 != 0
            } else {
              try require(packet[6] == 17, "IPv6 UDP next header")
              headerLength = 40; offset = 0; more = false
            }
          } else {
            try require(packet[0] == 0x45 && packet[9] == 17 && Int(word(2)) == packet.count
              && checksum(Array(packet.prefix(20))) == 0, "large UDP reply IP length/checksum")
            try require(Array(packet[12..<20]) == [127, 0, 0, 1, 10, 0, 0, 2], "large UDP reply addresses")
            if identifier == nil { identifier = UInt32(word(4)) }
            try require(UInt32(word(4)) == identifier, "large UDP reply split into independent IP packets")
            headerLength = 20; offset = Int(word(6) & 0x1fff) * 8; more = word(6) & 0x2000 != 0
          }
          let fragment = Array(packet.dropFirst(headerLength))
          try require(!more || fragment.count % 8 == 0, "unaligned IP fragment")
          try require(offset + fragment.count <= received.count, "large UDP reply exceeds expected datagram")
          try require(more || offset + fragment.count == received.count, "premature final IP fragment")
          if offset == 0 {
            try require(word(headerLength) == echo.port && word(headerLength + 2) == 53000, "large UDP reply ports")
            try require(Int(word(headerLength + 4)) == received.count, "large UDP reply was truncated or split into separate datagrams")
          }
          for (index, byte) in fragment.enumerated() {
            try require(covered.insert(offset + index).inserted, "overlapping UDP reply fragments")
            received[offset + index] = byte
          }
        }
        try require(covered.count == received.count && Array(received.dropFirst(8)) == expected,
          "large UDP reply incomplete or corrupted (payload=\(size), received=\(covered.count)/\(received.count), counters=\(bridge.counters))")
        var pseudo: [UInt8] = ipv6 ? ipv6Destination + ipv6Source + [0, 0] : [127, 0, 0, 1, 10, 0, 0, 2, 0, 17]
        appendWord(UInt16(received.count), to: &pseudo)
        if ipv6 { pseudo += [0, 0, 0, 17] }
        try require(checksum(pseudo + received) == 0, "large UDP reply checksum")
        try require(bridge.receive() == nil, "large UDP reply emitted an extra datagram")
      }
      try await bridge.stop(deadline: .seconds(5))
      print("PASS IPv\(ipv6 ? 6 : 4) MTU-boundary, 1800/8192/32768-byte UDP replies retain exact datagram framing")
    } catch {
      try await bridge.stop(deadline: .seconds(5))
      throw error
    }
  }

  // The installed native backend retains its packet bridge while replacing Xray.
  // Reuse the same UDP tuple; a fresh client socket would hide a stale relay.
  static func coreSwitchDatagram(_ bridge: NativePacketBridge, socksPort: UInt16,
                                echo: (fd: Int32, port: UInt16), configJSON: String) async throws {
    let attempt = ProviderBoundaryEvidence.reset()
    defer { ProviderBoundaryEvidence.finish(attempt) }
    try await bridge.start(socksPort: socksPort, mtu: 1500, tcpMaxConnections: 8,
      udpMaxConnections: 8, inboundCredentials: nil, attempt: attempt)
    do {
      for generation in 1...2 {
        let payload = Array("same-udp-tuple-core-\(generation)".utf8)
        try bridge.submit(Data(udpPacket(port: echo.port, payload: payload)))
        try echoDatagram(echo.fd, expected: payload)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        var response = bridge.receive()
        while response == nil && ContinuousClock.now < deadline {
          try await Task.sleep(for: .milliseconds(5)); response = bridge.receive()
        }
        try require(response.map { Array($0.suffix(payload.count)) } == payload,
          "same UDP tuple failed across core-only replacement")
        if generation == 1 {
          _ = try invoke("stopXray")
          _ = try invoke("runXrayFromJson", ["configJSON": configJSON])
          let deadline = ContinuousClock.now.advanced(by: .seconds(1))
          while bridge.counters["activeUdpSessions", default: 0] != 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
          }
          try require(bridge.counters["activeUdpSessions", default: 0] == 0,
            "native UDP session retained a closed core's SOCKS relay")
        }
      }
      try await bridge.stop(deadline: .seconds(5))
      print("PASS same UDP tuple re-associates after core-only replacement")
    } catch {
      try await bridge.stop(deadline: .seconds(5))
      throw error
    }
  }

  actor ResolverCompletion {
    var done = false
    var cancelled = false
    func finish(cancelled: Bool = false) { done = true; self.cancelled = cancelled }
  }

  // A fresh mDNS name creates real pending OS resolver work without changing DNS.
  static func resolverCancellation() async throws {
    let attempt = ProviderBoundaryEvidence.reset()
    defer { ProviderBoundaryEvidence.finish(attempt) }
    let completion = ResolverCompletion()
    let host = "elarni-check-\(UUID().uuidString.lowercased()).local"
    let pending = Task.detached { () -> Result<[String], Error> in
      let result: Result<[String], Error>
      do { result = .success(try await SystemEndpointResolver.resolve(host, preferredIP: "auto", attempt: attempt)) }
      catch { result = .failure(error) }
      await completion.finish()
      return result
    }
    try await Task.sleep(for: .milliseconds(200))
    let wasPending = await !completion.done
    let started = ContinuousClock.now
    pending.cancel()
    let result = await pending.value
    try require(wasPending, "DNS cancellation fixture did not establish pending resolver work")
    try require(started.duration(to: .now) < .seconds(1), "cancelled endpoint DNS retained startup work")
    guard case .failure(let error) = result, error is CancellationError else {
      throw Failure(message: "cancelled endpoint DNS did not report cancellation")
    }
    let addresses = try await SystemEndpointResolver.resolve("localhost", preferredIP: "ipv4", attempt: attempt)
    try require(addresses.contains("127.0.0.1") && addresses.allSatisfy { !$0.contains(":") },
      "resolver failed after cancellation or ignored IPv4 preference")
    let ipv6 = try await SystemEndpointResolver.resolve("::1", preferredIP: "ipv6", attempt: attempt)
    try require(ipv6 == ["::1"], "resolver lost literal IPv6 or its family preference")
    let preCancelled = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await SystemEndpointResolver.resolve("localhost", preferredIP: "ipv4", attempt: attempt)
    }
    do { _ = try await preCancelled.value; throw Failure(message: "pre-cancelled DNS started work") }
    catch is CancellationError {}
    print("PASS real pending endpoint DNS cancels promptly and subsequent lookup succeeds")

    let plan = TunnelPlan(schemaVersion: 1, secretRef: "resolver-check", socksPort: 18080, mtu: 1500,
      dnsServers: ["192.0.2.53"], controlledRoutes: [], staticHosts: [:], outboundFormat: .xrayOutbound,
      fallbackAction: .proxy, routingRevision: nil, routingDigest: nil, assetRevision: nil,
      backend: .nativeTun2Proxy, settings: nil)
    let core = NativeXrayCore()
    func endpoint(_ host: String) throws -> SecretValue {
      SecretValue(bytes: try JSONSerialization.data(withJSONObject: ["protocol": "socks",
        "settings": ["servers": [["address": host, "port": 9]]]]))
    }
    var local = try endpoint("localhost")
    let prepared = try await core.prepare(plan: plan, endpoint: &local, servers: [:], inboundCredentials: nil, attempt: attempt)
    try require(prepared.addresses.contains("127.0.0.1"), "native preparation did not resolve its endpoint")
    let preparation = ResolverCompletion()
    let startup = Task {
      do {
        var secret = try endpoint("elarni-prepare-\(UUID().uuidString.lowercased()).local")
        _ = try await core.prepare(plan: plan, endpoint: &secret, servers: [:], inboundCredentials: nil, attempt: attempt)
        await preparation.finish()
      } catch { await preparation.finish(cancelled: error is CancellationError) }
    }
    try await Task.sleep(for: .milliseconds(200))
    let preparing = await !preparation.done
    let stopStarted = ContinuousClock.now
    let ownersRemain = await withCheckedContinuation { continuation in
      _ = ProviderLifecycleRuntime.cleanup(
        detached: ProviderDetachedResources(attempt: attempt, startupTask: startup, monitorTask: nil, pump: nil),
        clearSettings: { true }, stopBridge: { true }, stopXray: {
          do { try await core.stop(); return await !core.isRunning() }
          catch { return false }
        },
        completion: { continuation.resume(returning: $0) })
    }
    let cancelled = await preparation.cancelled
    try require(preparing && cancelled && !ownersRemain && stopStarted.duration(to: .now) < .seconds(1),
      "provider cleanup failed to join real pending endpoint preparation promptly")
    print("PASS provider Stop joins real pending DNS preparation without quarantine")
  }

  // Packet-flow readers must accept complete offloaded packets and IP fragments.
  // Deliver fragments backwards so a first-fragment-only parser cannot pass.
  // VLESS sends UDP as XUDP frames that standard servers cap at 8 KiB, so a
  // larger request is dropped whole instead of being split into wrong datagrams.
  static func fragmentedDatagramRequests(_ bridge: NativePacketBridge, socksPort: UInt16,
                                        echo: (fd: Int32, port: UInt16), ipv6: Bool = false) async throws {
    let attempt = ProviderBoundaryEvidence.reset()
    defer { ProviderBoundaryEvidence.finish(attempt) }
    try await bridge.start(socksPort: socksPort, mtu: 1500, tcpMaxConnections: 8,
      udpMaxConnections: 8, inboundCredentials: nil, attempt: attempt)
    do {
      for size in [1800, 7000] {
        let payload = (0..<size).map { UInt8($0 % 251) }
        let packet = udpPacket(port: echo.port, payload: payload, ipv6: ipv6)
        let ipLength = ipv6 ? 40 : 20
        let datagram = Array(packet.dropFirst(ipLength))
        let capacity = ipv6 ? 1448 : 1480
        var fragments: [[UInt8]] = []
        for offset in stride(from: 0, to: datagram.count, by: capacity) {
          let end = min(offset + capacity, datagram.count)
          fragments.append(ipFragment(packet, range: offset..<end, id: UInt16(size), ipv6: ipv6))
        }
        for packets in [[packet], Array(fragments.reversed())] {
          print("CHECK IPv\(ipv6 ? 6 : 4) \(size)-byte UDP request, packets=\(packets.count)")
          for fragment in packets { try bridge.submit(Data(fragment)) }
          let acknowledgement: [UInt8] = [0x31, 0x72]
          try echoDatagram(echo.fd, expected: payload, reply: acknowledgement)
          let deadline = Date().addingTimeInterval(5)
          var response = bridge.receive()
          while response == nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(5)); response = bridge.receive()
          }
          try require(response?.count == ipLength + 8 + acknowledgement.count
            && response.map { Array($0.suffix(acknowledgement.count)) } == acknowledgement,
            "IPv\(ipv6 ? 6 : 4) \(size)-byte request lost its datagram boundary (fragments=\(packets.count))")
        }
      }
      // A split oversized request would reach the echo server before the probe.
      try bridge.submit(Data(udpPacket(port: echo.port, payload: (0..<32768).map { UInt8($0 % 251) }, ipv6: ipv6)))
      let probe: [UInt8] = [0x32, 0x73]
      try bridge.submit(Data(udpPacket(port: echo.port, payload: probe, ipv6: ipv6)))
      try echoDatagram(echo.fd, expected: probe)
      try await bridge.stop(deadline: .seconds(5))
      print("PASS IPv\(ipv6 ? 6 : 4) complete and reversed-fragment UDP requests retain exact payloads; oversized requests are dropped whole")
    } catch {
      try await bridge.stop(deadline: .seconds(5))
      throw error
    }
  }

  static func ipFragment(_ packet: [UInt8], range: Range<Int>, id: UInt16, ipv6: Bool) -> [UInt8] {
    let ipLength = ipv6 ? 40 : 20
    let datagram = Array(packet.dropFirst(ipLength))
    let more = range.upperBound < datagram.count
    var ip = Array(packet.prefix(ipLength))
    let length = UInt16((ipv6 ? 8 : 20) + range.count)
    ip[ipv6 ? 4 : 2] = UInt8(length >> 8); ip[ipv6 ? 5 : 3] = UInt8(length & 255)
    if ipv6 {
      ip[6] = 44; ip += [17, 0]
      appendWord(UInt16(range.lowerBound) | (more ? 1 : 0), to: &ip)
      ip += [0, 0, UInt8(id >> 8), UInt8(id & 255)]
    } else {
      ip[4] = UInt8(id >> 8); ip[5] = UInt8(id & 255)
      let flags = UInt16(range.lowerBound / 8) | (more ? 0x2000 : 0)
      ip[6] = UInt8(flags >> 8); ip[7] = UInt8(flags & 255)
      ip[10] = 0; ip[11] = 0
      let sum = checksum(ip)
      ip[10] = UInt8(sum >> 8); ip[11] = UInt8(sum & 255)
    }
    return ip + datagram[range]
  }

  static func fragmentBounds(_ bridge: NativePacketBridge, socksPort: UInt16,
                             echo: (fd: Int32, port: UInt16), ipv6: Bool = false,
                             checkExpiry: Bool = false) async throws {
    let attempt = ProviderBoundaryEvidence.reset()
    defer { ProviderBoundaryEvidence.finish(attempt) }
    let payload = Array(repeating: UInt8(0x37), count: 32)
    let packet = udpPacket(port: echo.port, payload: payload, ipv6: ipv6)
    func submit(_ id: UInt16, _ range: Range<Int>) throws {
      try bridge.submit(Data(ipFragment(packet, range: range, id: id, ipv6: ipv6)))
    }
    func noForward(_ message: String) throws {
      var descriptor = pollfd(fd: echo.fd, events: Int16(POLLIN), revents: 0)
      try require(Darwin.poll(&descriptor, 1, 150) == 0, message)
    }
    func receive() async throws {
      try echoDatagram(echo.fd, expected: payload, reply: [0x72])
      let deadline = Date().addingTimeInterval(5)
      var response = bridge.receive()
      while response == nil && Date() < deadline {
        try await Task.sleep(for: .milliseconds(5)); response = bridge.receive()
      }
      try require(response?.count == (ipv6 ? 49 : 29) && response?.last == 0x72,
        "fragment boundary reply missing")
    }
    func start() async throws {
      try await bridge.start(socksPort: socksPort, mtu: 1500, tcpMaxConnections: 8,
        udpMaxConnections: 8, inboundCredentials: nil, attempt: attempt)
    }
    try await start()
    do {
      for id: UInt16 in 1...64 {
        try submit(id, 0..<16)
        try await Task.sleep(for: .milliseconds(2))
      }
      try submit(65, 0..<16); try submit(65, 16..<40)
      try noForward("fragment admission exceeded the 64-datagram bound")
      try submit(1, 16..<40); try await receive()
      try submit(65, 0..<16); try submit(65, 16..<40); try await receive()
      try submit(66, 0..<16); try submit(66, 8..<24); try submit(66, 16..<40)
      try noForward("overlapping fragment datagram was forwarded")
      try submit(66, 0..<16)
      try noForward("later fragments revived an overlapping datagram")
      if checkExpiry {
        print("CHECK incomplete fragment lifetime: waiting beyond 60 seconds")
        try await Task.sleep(for: .seconds(61))
        try submit(2, 16..<40)
        try noForward("expired first fragment survived its lifetime")
        try submit(67, 0..<16); try submit(67, 16..<40); try await receive()
        print("PASS incomplete fragments expire and admission capacity is reclaimed")
      }
      try await bridge.stop(deadline: .seconds(5))
      try await start()
      try submit(3, 16..<40)
      try noForward("incomplete fragment survived Stop/restart")
      try submit(3, 0..<16); try await receive()
      try await bridge.stop(deadline: .seconds(5))
      print("PASS IPv\(ipv6 ? 6 : 4) fragment cap, slot reuse, overlap rejection and Stop cleanup")
    } catch {
      try await bridge.stop(deadline: .seconds(5))
      throw error
    }
  }

  static func compiledConfig(outbound: [String: Any], socksPort: UInt16) throws -> [String: Any] {
    let request = try JSONSerialization.data(withJSONObject: [
      "schemaVersion": 1, "operation": "compileOutbound", "payload": [
        "outbound": outbound, "socksPort": Int(socksPort),
        "routes": ["rules": [], "dnsServers": ["192.0.2.53"], "fallbackAction": "proxy"],
      ],
    ])
    guard let handle = elarni_handle_new() else { throw Failure(message: "domain handle") }
    defer { elarni_handle_free(handle) }
    var output = ElarniBuffer(data: nil, len: 0, capacity: 0)
    let status = request.withUnsafeBytes {
      elarni_request(handle, $0.bindMemory(to: UInt8.self).baseAddress, request.count, &output)
    }
    defer { elarni_buffer_free(output) }
    try require(status == ELARNI_STATUS_OK && output.data != nil, "VLESS config compilation")
    let response = try JSONSerialization.jsonObject(with: Data(bytes: output.data!, count: output.len)) as! [String: Any]
    let configText = response["configUtf8"] as! String
    return try JSONSerialization.jsonObject(with: Data(configText.utf8)) as! [String: Any]
  }

  static func packetRoundTrip(socksPort: UInt16, echo: (fd: Int32, port: UInt16), cycle: Int) throws {
    // 10 s UDP idle timeout, not the production 60 s, so the idle check below ends within its 12 s.
    guard let bridge = elarni_packet_bridge_new_with_udp_timeout(socksPort, 1500, 1, 1, 64, 65535, 10) else {
      throw Failure(message: "packet bridge creation")
    }
    defer { elarni_packet_bridge_free(bridge) }
    let startDeadline = Date().addingTimeInterval(5)
    while elarni_packet_bridge_state(bridge) == ELARNI_PACKET_STATE_STARTING && Date() < startDeadline { usleep(5000) }
    try require(elarni_packet_bridge_state(bridge) == ELARNI_PACKET_STATE_RUNNING, "packet bridge did not start")

    let malformed: [UInt8] = [0x45, 0, 0]
    let invalidStatus = malformed.withUnsafeBufferPointer {
      elarni_packet_bridge_submit(bridge, $0.baseAddress, $0.count)
    }
    try require(invalidStatus == ELARNI_PACKET_STATUS_MALFORMED_PACKET, "malformed packet accepted")
    let payload = Array("elarni-live-udp-\(cycle)".utf8)
    let packet = udpPacket(port: echo.port, payload: payload)
    let submitted = packet.withUnsafeBufferPointer {
      elarni_packet_bridge_submit(bridge, $0.baseAddress, $0.count)
    }
    try require(submitted == ELARNI_PACKET_STATUS_OK, "UDP packet submission")
    try echoDatagram(echo.fd, expected: payload)

    var written = 0
    var status = ELARNI_PACKET_STATUS_EMPTY
    let deadline = Date().addingTimeInterval(5)
    repeat {
      status = elarni_packet_bridge_receive(bridge, nil, 0, &written)
      if status == ELARNI_PACKET_STATUS_EMPTY { usleep(5000) }
    } while status == ELARNI_PACKET_STATUS_EMPTY && Date() < deadline
    try require(status == ELARNI_PACKET_STATUS_BUFFER_TOO_SMALL && written >= 28 + payload.count, "UDP response missing")
    var response = [UInt8](repeating: 0, count: written)
    status = response.withUnsafeMutableBufferPointer {
      elarni_packet_bridge_receive(bridge, $0.baseAddress, $0.count, &written)
    }
    try require(status == ELARNI_PACKET_STATUS_OK, "receive did not preserve the queued packet")
    let headerLength = Int(response[0] & 15) * 4
    try require(response[0] >> 4 == 4 && response[9] == 17 && headerLength >= 20 && headerLength + 8 <= written, "response IP/UDP header")
    try require(Array(response[12..<16]) == [127, 0, 0, 1] && Array(response[16..<20]) == [10, 0, 0, 2], "response endpoints")
    try require(Array(response[(headerLength + 8)..<written]) == payload, "UDP response payload")
    var counters = ElarniPacketCounters()
    try require(elarni_packet_bridge_counters(bridge, &counters) == ELARNI_PACKET_STATUS_OK, "packet counters unavailable")
    try require(counters.packets_in == 1 && counters.packets_out == 1 && counters.malformed == 1 && counters.overflows == 0, "packet counters")
    try require(counters.bytes_in == packet.count && counters.bytes_out == written, "packet byte counters")
    try require(counters.active_udp_sessions == 1,
      "initial UDP session count is \(counters.active_udp_sessions), expected 1")
    print("PASS live packet bridge/VLESS UDP round trip \(cycle)")

    let excess = udpPacket(port: echo.port, payload: Array("excess-session".utf8), sourcePort: 53001)
    let excessStatus = excess.withUnsafeBufferPointer {
      elarni_packet_bridge_submit(bridge, $0.baseAddress, $0.count)
    }
    try require(excessStatus == ELARNI_PACKET_STATUS_OK, "excess session packet submission")
    usleep(100_000)
    try require(elarni_packet_bridge_state(bridge) == ELARNI_PACKET_STATE_RUNNING,
      "reaching the UDP session limit stopped the whole bridge")
    let retry = packet.withUnsafeBufferPointer {
      elarni_packet_bridge_submit(bridge, $0.baseAddress, $0.count)
    }
    try require(retry == ELARNI_PACKET_STATUS_OK, "existing UDP session rejected at capacity")
    try echoDatagram(echo.fd, expected: payload)
    let retryDeadline = Date().addingTimeInterval(5)
    repeat {
      status = response.withUnsafeMutableBufferPointer {
        elarni_packet_bridge_receive(bridge, $0.baseAddress, $0.count, &written)
      }
      if status == ELARNI_PACKET_STATUS_EMPTY { usleep(5000) }
    } while status == ELARNI_PACKET_STATUS_EMPTY && Date() < retryDeadline
    try require(status == ELARNI_PACKET_STATUS_OK && written == packet.count
      && Array(response[(headerLength + 8)..<written]) == payload,
      "established UDP session failed after capacity rejection")
    try require(elarni_packet_bridge_counters(bridge, &counters) == ELARNI_PACKET_STATUS_OK, "admission counters")
    try require(counters.active_udp_sessions == 1,
      "UDP session limit was not preserved: \(counters.active_udp_sessions) active")
    try require(counters.dropped_udp_sessions == 1 && counters.dropped_tcp_sessions == 0,
      "the refused UDP session was not counted: \(counters.dropped_udp_sessions) dropped")
    print("PASS UDP admission rejection preserves bridge and established traffic \(cycle)")

    if cycle == 1 {
      let idleDeadline = Date().addingTimeInterval(12)
      repeat {
        usleep(20_000)
        try require(elarni_packet_bridge_counters(bridge, &counters) == ELARNI_PACKET_STATUS_OK, "idle counters")
      } while counters.active_udp_sessions > 0 && Date() < idleDeadline
      try require(counters.active_udp_sessions == 0, "idle UDP session did not release capacity")
      let fresh = udpPacket(port: echo.port, payload: payload, sourcePort: 53001)
      let freshStatus = fresh.withUnsafeBufferPointer {
        elarni_packet_bridge_submit(bridge, $0.baseAddress, $0.count)
      }
      try require(freshStatus == ELARNI_PACKET_STATUS_OK, "fresh session rejected after idle cleanup")
      try echoDatagram(echo.fd, expected: payload)
      let freshDeadline = Date().addingTimeInterval(5)
      repeat {
        status = response.withUnsafeMutableBufferPointer {
          elarni_packet_bridge_receive(bridge, $0.baseAddress, $0.count, &written)
        }
        if status == ELARNI_PACKET_STATUS_EMPTY { usleep(5000) }
      } while status == ELARNI_PACKET_STATUS_EMPTY && Date() < freshDeadline
      try require(status == ELARNI_PACKET_STATUS_OK && written == fresh.count
        && response[headerLength + 2] == UInt8(53001 >> 8)
        && response[headerLength + 3] == UInt8(53001 & 255)
        && Array(response[(headerLength + 8)..<written]) == payload,
        "new UDP session failed after idle capacity reuse")
      print("PASS idle UDP capacity is reused by a previously rejected source")
    }

    try require(elarni_packet_bridge_stop(bridge) == ELARNI_PACKET_STATUS_OK, "packet bridge stop")
    try require(elarni_packet_bridge_state(bridge) == ELARNI_PACKET_STATE_STOPPED, "packet bridge remains active after stop")
    let afterStop = packet.withUnsafeBufferPointer {
      elarni_packet_bridge_submit(bridge, $0.baseAddress, $0.count)
    }
    try require(afterStop == ELARNI_PACKET_STATUS_STOPPED, "stopped bridge accepted traffic")
    try require(elarni_packet_bridge_stop(bridge) == ELARNI_PACKET_STATUS_OK, "repeated stop is not idempotent")
    var stoppedCounters = ElarniPacketCounters()
    try require(elarni_packet_bridge_counters(bridge, &stoppedCounters) == ELARNI_PACKET_STATUS_OK, "stopped counters")
    try require(stoppedCounters.active_tcp_sessions == 0 && stoppedCounters.active_udp_sessions == 0, "sessions survived stop")
  }

  static func tcpRoundTrip(socksPort: UInt16) throws {
    let server = try boundSocket(SOCK_STREAM)
    defer { Darwin.close(server.fd) }
    try require(listen(server.fd, 1) == 0, "TCP echo listen")
    let client = try boundSocket(SOCK_STREAM)
    defer { Darwin.close(client.fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = socksPort.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(client.fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    try require(connected == 0, "SOCKS connection")
    try writeAll(client.fd, [5, 1, 0])
    try require(try readExactly(client.fd, 2) == [5, 0], "SOCKS authentication")
    var request: [UInt8] = [5, 1, 0, 1, 127, 0, 0, 1]
    appendWord(server.port, to: &request)
    try writeAll(client.fd, request)
    let reply = try readExactly(client.fd, 4)
    try require(reply == [5, 0, 0, 1], "SOCKS connect reply")
    _ = try readExactly(client.fd, 6)
    // Xray can defer upstream dialing until the client sends its first bytes.
    let payload = Array("elarni-live-tcp".utf8)
    try writeAll(client.fd, payload)
    let peer = accept(server.fd, nil, nil)
    try require(peer >= 0, "VLESS did not connect to the echo server")
    defer { Darwin.close(peer) }
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    try require(setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0, "echo timeout")
    try require(try readExactly(peer, payload.count) == payload, "VLESS TCP uplink")
    try writeAll(peer, payload)
    try require(try readExactly(client.fd, payload.count) == payload, "VLESS TCP downlink")
  }

  static func writeAll(_ fd: Int32, _ bytes: [UInt8]) throws {
    var offset = 0
    while offset < bytes.count {
      let count = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!.advanced(by: offset), bytes.count - offset, 0) }
      try require(count > 0, "socket write")
      offset += count
    }
  }

  static func readExactly(_ fd: Int32, _ length: Int) throws -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: length)
    var offset = 0
    while offset < length {
      let count = bytes.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress!.advanced(by: offset), length - offset, 0) }
      try require(count > 0, "socket read")
      offset += count
    }
    return bytes
  }

  static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw Failure(message: message) }
  }

  // The extension takes the app's level from the shared container and leaves its lines there when it stops.
  static func coreLogFiles() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("elarni-core-log-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    defer { _ = try? invoke("setLogLevel", ["level": "warning"]) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("error\n".utf8).write(to: directory.appendingPathComponent("level"))
    CoreLog.applyLevel(from: directory)
    try require((try invoke("readLogs") as! [String: Any])["level"] as? String == "error", "the shared log level was not applied")
    _ = try invoke("setLogLevel", ["level": "warning"])
    defer { _ = try? invoke("stopXray") }
    _ = try invoke("runXrayFromJson", ["configJSON": #"{"outbounds":[{"protocol":"freedom"}]}"#])
    let live = try CoreLog.read(after: 0)
    let last = (live["last"] as? NSNumber)?.int64Value ?? 0
    try require(last > 0 && (live["entries"] as? [[String: Any]])?.contains(where: { ($0["text"] as? String)?.hasSuffix(" started") == true }) == true,
      "the core did not log its start")
    CoreLog.persist(to: directory)
    let kept = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("last.json"))) as! [String: Any]
    try require((kept["last"] as? NSNumber)?.int64Value == last, "the stopped extension did not keep its lines")
    print("PASS the core log level comes from the shared container and its lines outlive the extension")
  }

  static func invoke(_ method: String, _ payload: [String: Any] = [:]) throws -> Any {
    let request = try JSONSerialization.data(withJSONObject: [
      "apiVersion": 1, "method": method, "payload": payload,
    ])
    let text = String(decoding: request, as: UTF8.self)
    guard let pointer = strdup(text) else { throw Failure(message: "request allocation") }
    defer { free(pointer) }
    guard let result = CGoInvoke(pointer) else { throw Failure(message: "libXray response missing") }
    defer { CGoFree(result) }
    let response = try JSONSerialization.jsonObject(with: Data(String(cString: result).utf8)) as! [String: Any]
    try require(response["success"] as? Bool == true, "libXray \(method) failed: \(response["error"] ?? "unknown")")
    return response["data"] ?? NSNull()
  }

  static func boundSocket(_ type: Int32, ipv6: Bool = false) throws -> (fd: Int32, port: UInt16) {
    let fd = Darwin.socket(ipv6 ? AF_INET6 : AF_INET, type, 0)
    try require(fd >= 0, "socket creation")
    do {
      if type == SOCK_DGRAM {
        var capacity: Int32 = 65535
        try require(setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &capacity, socklen_t(MemoryLayout<Int32>.size)) == 0,
          "UDP fixture send capacity")
      }
      if ipv6 {
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        _ = inet_pton(AF_INET6, "::1", &address.sin6_addr)
        let bound = withUnsafePointer(to: &address) {
          $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
          }
        }
        try require(bound == 0, "IPv6 loopback bind")
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        let named = withUnsafeMutablePointer(to: &address) {
          $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        try require(named == 0, "IPv6 bound socket address")
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        try require(setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0, "IPv6 socket timeout")
        return (fd, UInt16(bigEndian: address.sin6_port))
      }
      var address = sockaddr_in()
      address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
      address.sin_family = sa_family_t(AF_INET)
      address.sin_addr.s_addr = inet_addr("127.0.0.1")
      let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
      }
      try require(bound == 0, "loopback bind")
      var length = socklen_t(MemoryLayout<sockaddr_in>.size)
      let named = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
      }
      try require(named == 0, "bound socket address")
      var timeout = timeval(tv_sec: 5, tv_usec: 0)
      try require(setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0, "socket timeout")
      return (fd, UInt16(bigEndian: address.sin_port))
    } catch {
      Darwin.close(fd)
      throw error
    }
  }

  static func appendWord(_ value: UInt16, to bytes: inout [UInt8]) {
    bytes.append(UInt8(value >> 8))
    bytes.append(UInt8(value & 255))
  }

  static func checksum(_ bytes: [UInt8]) -> UInt16 {
    var sum: UInt32 = 0
    for offset in stride(from: 0, to: bytes.count, by: 2) {
      sum += UInt32(bytes[offset]) << 8
      if offset + 1 < bytes.count { sum += UInt32(bytes[offset + 1]) }
    }
    while sum >> 16 != 0 { sum = (sum & 65535) + (sum >> 16) }
    return ~UInt16(sum)
  }

  static let ipv6Source: [UInt8] = [0xfd] + [UInt8](repeating: 0, count: 14) + [2]
  static let ipv6Destination: [UInt8] = [UInt8](repeating: 0, count: 15) + [1]

  static func udpPacket(port: UInt16, payload: [UInt8], sourcePort: UInt16 = 53000, ipv6: Bool = false) -> [UInt8] {
    let source: [UInt8] = ipv6 ? ipv6Source : [10, 0, 0, 2]
    let destination: [UInt8] = ipv6 ? ipv6Destination : [127, 0, 0, 1]
    let udpLength = UInt16(8 + payload.count)
    var udp: [UInt8] = []
    appendWord(sourcePort, to: &udp)
    appendWord(port, to: &udp)
    appendWord(udpLength, to: &udp)
    appendWord(0, to: &udp)
    udp += payload
    var pseudo = source + destination + (ipv6 ? [0, 0] : [0, 17])
    appendWord(udpLength, to: &pseudo)
    if ipv6 { pseudo += [0, 0, 0, 17] }
    let udpChecksum = checksum(pseudo + udp)
    udp[6] = UInt8(udpChecksum >> 8); udp[7] = UInt8(udpChecksum & 255)
    if ipv6 {
      var ip: [UInt8] = [0x60, 0, 0, 0]
      appendWord(udpLength, to: &ip)
      return ip + [17, 64] + source + destination + udp
    }
    var ip: [UInt8] = [0x45, 0]
    appendWord(UInt16(20 + udp.count), to: &ip)
    ip += [0, 1, 0, 0, 64, 17, 0, 0] + source + destination
    let ipChecksum = checksum(ip)
    ip[10] = UInt8(ipChecksum >> 8); ip[11] = UInt8(ipChecksum & 255)
    return ip + udp
  }

  static func echoDatagram(_ fd: Int32, expected: [UInt8], reply: [UInt8]? = nil) throws {
    var payload = [UInt8](repeating: 0, count: 65535)
    var peer = sockaddr_storage()
    var peerLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
    let count = withUnsafeMutablePointer(to: &peer) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        recvfrom(fd, &payload, payload.count, 0, $0, &peerLength)
      }
    }
    try require(count == expected.count && Array(payload.prefix(max(0, count))) == expected,
      "UDP payload did not reach the echo server through VLESS (expected=\(expected.count), received=\(count), errno=\(errno))")
    let response = reply ?? Array(payload.prefix(count))
    let sent = withUnsafePointer(to: &peer) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        sendto(fd, response, response.count, 0, $0, peerLength)
      }
    }
    try require(sent == response.count, "UDP echo response (bytes=\(response.count), sent=\(sent), errno=\(errno))")
  }
}
