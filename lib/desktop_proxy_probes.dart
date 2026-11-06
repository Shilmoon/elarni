part of 'desktop_proxy.dart';

extension _ProxyProbes on DesktopProxy {
  Future<CatalogMap> _pingICMP(CatalogMap args, int generation) async {
    final catalog = _catalog!;
    if (_state != 'connected' || !catalog.settings.xrayTunEnabled)
      return _ping(args, generation);
    _state = 'disconnecting';
    try {
      await _stopProcess();
      _checkGeneration(generation);
      _state = 'prepared';
    } on Object {
      // Sleep cancels without disconnecting; the runtime is down either way.
      _state = 'failed';
      _checkGeneration(generation);
      rethrow;
    }
    try {
      return await _ping(args, generation);
    } on Object {
      _checkGeneration(generation);
      throw desktopError('icmp_failed_restored');
    } finally {
      // A user's Stop, sleep or disposal cancels restoration as well as probing.
      if (!_disposed && !_storageLost && generation == _generation) {
        try {
          await _start(catalog, generation);
        } on Object {
          await _stopProcess();
          _state = 'failed';
          _checkGeneration(generation);
          throw desktopError('icmp_restore_failed');
        }
      }
    }
  }

  Future<CatalogMap> _ping(
    CatalogMap args,
    int generation, {
    DesktopCatalog? usingCatalog,
    bool automatic = false,
  }) async {
    final catalog = usingCatalog ?? _catalog!;
    final protocol = args['protocol']! as String;
    final id = protocol == 'activeProxy' ? catalog.selected : args['nodeId'];
    if (id is! String || catalog.node(id)['format'] != 'xrayProfile')
      throw desktopError('invalid_profile');
    final timeout = args['timeout']! as int;
    if (automatic) {
      // TSPU counts handshakes to one server under ~50 ms apart, and the core
      // finishes a probe of a near server sooner than that.
      final wait = _lastAutomaticProbe + 40 - _clock.elapsedMilliseconds;
      if (wait > 0) await Future<void>.delayed(Duration(milliseconds: wait));
      _lastAutomaticProbe = _clock.elapsedMilliseconds;
    }
    final clock = Stopwatch()..start();
    Duration timeLeft() {
      _checkGeneration(generation);
      final remaining = Duration(seconds: timeout) - clock.elapsed;
      if (remaining <= Duration.zero) throw desktopError('ping_failed');
      return remaining;
    }

    final active =
        _state == 'connected' &&
        id == catalog.selected &&
        {'proxy', 'activeProxy'}.contains(protocol);
    // Xray's userspace ICMP echo does not measure the remote endpoint.
    if (protocol == 'icmp' &&
        _state == 'connected' &&
        catalog.settings.xrayTunEnabled)
      throw desktopError('unavailableProbePath');
    var failed = false;
    try {
      int latency;
      Object? exit;
      if (protocol == 'tcp' || protocol == 'icmp') {
        final probeConfig = await _compile(catalog, catalog.node(id));
        final endpoints = catalogList(
          (await DesktopProxy._domainOff(domainPath, 'profileEndpoints', {
            'config': jsonDecode(probeConfig),
          }))['endpoints'],
        );
        final endpoint = endpoints
            .where((e) => e['physical'] == true)
            .firstOrNull;
        if (endpoint == null) throw desktopError('invalid_profile');
        if (protocol == 'tcp' && endpoint['supportsTcpProbe'] != true) {
          throw PlatformException(
            code: 'unsupported_ping_method',
            message:
                "Direct TCP is not supported by this endpoint's transport. Use Proxy testing.",
          );
        }
        final mappings = await _hostMappings(probeConfig, [endpoint]);
        final addresses = await _endpointAddresses(
          endpoint,
          DesktopProxy._nodeSettings(catalog, catalog.node(id)),
          mapping: mappings[endpoint['host']] as Map?,
        );
        _checkGeneration(generation);
        if (protocol == 'tcp') {
          if (Platform.isWindows || Platform.isLinux) {
            final result = await _native('pingEndpoint', {
              'address': addresses.first.address,
              'port': endpoint['port'],
              'timeout': timeout,
            }, timeout: timeLeft());
            latency = result['delay']! as int;
          } else {
            final watch = Stopwatch()..start();
            final socket = await Socket.connect(
              addresses.first,
              endpoint['port']! as int,
              timeout: timeLeft(),
            );
            latency = watch.elapsedMilliseconds;
            socket.destroy();
          }
        } else {
          latency = await _icmp(addresses.first, timeout, generation);
        }
      } else {
        final payload = <String, Object?>{
          for (final key in [
            'url',
            'timeout',
            'method',
            'mode',
            'expectedStatus',
            'expectedBody',
          ])
            key: args[key],
          if (args['trace'] == true) 'trace': true,
        };
        // Only-listed mode sends the probe process direct, so it uses the proxy listener.
        if (active &&
            catalog.settings.xrayTunEnabled &&
            catalog.settings.perAppMode != 'proxyOnly') {
          payload['packetPath'] = true;
        } else if (active) {
          final credentials = catalog.settings.inboundAuthEnabled
              ? catalogMap(catalog.data['inboundCredentials'] ?? {})
              : catalog.settings.xrayTunEnabled
              ? _vpnLogin
              : null;
          final userInfo = credentials != null
              ? '${Uri.encodeComponent(credentials['username']! as String)}:${Uri.encodeComponent(credentials['password']! as String)}'
              : '';
          payload['proxy'] = Uri(
            scheme: 'socks5',
            host: '127.0.0.1',
            port: catalog.settings.socksPort,
            userInfo: userInfo,
          ).toString();
          payload['configJSON'] = jsonEncode({
            'inbounds': [],
            'outbounds': [
              {'protocol': 'freedom'},
            ],
          });
        } else {
          final socket = await ServerSocket.bind(
            InternetAddress.loopbackIPv4,
            0,
          );
          final port = socket.port;
          await socket.close();
          final probe = catalog.copy();
          // Other local apps, including ones the VPN excludes, must not
          // borrow this listener while the probe runs.
          final username = desktopID(), password = desktopID();
          probe.data['selectedNodeId'] = id;
          probe.data['inboundCredentials'] = {
            'username': username,
            'password': password,
          };
          probe.data['settings'] = catalog.settings
              .copyWith(
                xrayTunEnabled: false,
                perAppMode: 'off',
                socksPort: port,
                httpInboundEnabled: false,
                allowLAN: false,
                inboundAuthEnabled: true,
                // The VPN blocks DNS outside the tunnel, so the probe core
                // dials the address the app resolved through it.
                resolveServer:
                    catalog.settings.resolveServer ||
                    _state == 'connected' && catalog.settings.xrayTunEnabled,
              )
              .toMap();
          payload.addAll(DesktopProxy._runtimeAssets(probe));
          payload['configJSON'] = await _prepareConfig(probe, probe.node(id));
          payload['proxy'] = 'socks5://$username:$password@127.0.0.1:$port';
        }
        _checkGeneration(generation);
        final response = await _native(
          'ping',
          payload,
          timeout: automatic ? null : timeLeft(),
        );
        latency = response['delay']! as int;
        if (latency < 0) throw desktopError('ping_failed');
        exit = response['exit'];
      }
      _checkGeneration(generation);
      return {
        'nodeId': id,
        'configurationRevision':
            catalog.node(id)['configurationRevision'] ?? id,
        'protocol': protocol,
        'status': 'success',
        'latencyMs': latency,
        'timestamp': DateTime.now().millisecondsSinceEpoch / 1000,
        'exit': ?exit,
      };
    } on Object catch (error) {
      if (error is PlatformException &&
          error.code == 'unsupported_ping_method') {
        _checkGeneration(generation);
        rethrow;
      }
      failed = true;
      _checkGeneration(generation);
      const code = 'ping_failed';
      throw PlatformException(
        code: code,
        message: desktopError(code).message,
        details: error is PlatformException ? error.details : null,
      );
    } finally {
      if (failed) _listener?.call(null);
    }
  }

  Future<int> _icmp(
    InternetAddress address,
    int timeout,
    int generation,
  ) async {
    if (Platform.isLinux) {
      final result = await _native('pingICMP', {
        'address': address.address,
        'timeout': timeout,
      }, timeout: Duration(seconds: timeout + 5));
      _checkGeneration(generation);
      return result['milliseconds']! as int;
    }
    if (!Platform.isWindows) throw desktopError('unsupported_operation');
    // Only a parsed numeric IP and bounded integer enter this fixed script.
    final script =
        r"$ErrorActionPreference='Stop'; $p=New-Object System.Net.NetworkInformation.Ping; try { $r=$p.Send('" +
        address.address +
        "', ${timeout * 1000}); if (\$r.Status -ne 'Success') {exit 1}; \$r.RoundtripTime } finally {\$p.Dispose()}";
    final encoded = ByteData(script.length * 2);
    for (var i = 0; i < script.length; i++) {
      encoded.setUint16(i * 2, script.codeUnitAt(i), Endian.little);
    }
    final process = await Process.start(windowsPowerShell, [
      '-NoProfile',
      '-NonInteractive',
      '-EncodedCommand',
      base64Encode(encoded.buffer.asUint8List()),
    ]);
    _workers.add(process);
    try {
      _checkGeneration(generation);
      final output = process.stdout.transform(utf8.decoder).join();
      unawaited(process.stderr.drain<void>());
      final code = await process.exitCode.timeout(
        Duration(seconds: timeout + 5),
      );
      if (code != 0) throw desktopError('ping_failed');
      return int.parse((await output).trim());
    } finally {
      _workers.remove(process);
      process.kill();
    }
  }

  Future<List<InternetAddress>> _endpointAddresses(
    CatalogMap endpoint,
    TunnelSettings settings, {
    Map? mapping,
  }) async {
    if (mapping?['blocked'] == true) throw desktopError('connection_failed');
    final host = mapping?['alias'] as String? ?? endpoint['host']! as String;
    final hints =
        (mapping?['addresses'] as List? ?? endpoint['addresses'] as List? ?? [])
            .cast<String>();
    final literal = InternetAddress.tryParse(host);
    var addresses = hints.isNotEmpty
        ? hints.map(InternetAddress.new).toList()
        : literal != null
        ? [literal]
        // The VPN answers this app's lookups, with Fake DNS addresses that lead
        // nowhere outside it; the core asks a real resolver instead.
        : _state == 'connected' && _catalog?.settings.xrayTunEnabled == true
        ? [
            for (final address
                in (await _native('lookupHost', {'host': host}))['addresses']!
                    as List)
              InternetAddress(address as String),
          ]
        : await InternetAddress.lookup(
            host,
          ).timeout(const Duration(seconds: 5));
    final preferred = settings.profilePreferredIP == 'inherit'
        ? settings.preferredIP
        : settings.profilePreferredIP;
    if (preferred != 'automatic') {
      addresses = addresses
          .where(
            (address) =>
                address.type ==
                (preferred == 'ipv6'
                    ? InternetAddressType.IPv6
                    : InternetAddressType.IPv4),
          )
          .toList();
    } else {
      final ipv4 = addresses
          .where((a) => a.type == InternetAddressType.IPv4)
          .toList();
      final ipv6 = addresses
          .where((a) => a.type == InternetAddressType.IPv6)
          .toList();
      addresses = switch ((endpoint['domainStrategy'] as String? ?? '')
          .toLowerCase()) {
        'forceipv4' => ipv4,
        'forceipv6' => ipv6,
        'useipv4' => ipv4.isEmpty ? addresses : ipv4,
        'useipv6' => ipv6.isEmpty ? addresses : ipv6,
        'useipv4v6' || 'forceipv4v6' => [...ipv4, ...ipv6],
        'useipv6v4' || 'forceipv6v4' => [...ipv6, ...ipv4],
        _ => addresses,
      };
    }
    if (addresses.isEmpty) throw desktopError('connection_failed');
    return addresses;
  }

  Future<CatalogMap> _hostMappings(String config, List<CatalogMap> endpoints) {
    final hosts = endpoints
        .map((e) => e['host']! as String)
        .where((host) => InternetAddress.tryParse(host) == null)
        .toSet()
        .toList();
    return hosts.isEmpty || !_mayMapHosts(config)
        ? Future.value({})
        : _native('profileHostMappings', {
            'configJSON': config,
            'hosts': hosts,
          });
  }

  // Skips a core launch only where the core would return no mappings: null or
  // empty dns.hosts. Go matches keys case-insensitively, folding some non-ASCII.
  static bool _mayMapHosts(String config) {
    bool named(Object? key, String name) {
      final text = key.toString();
      return text.toLowerCase() == name || text.codeUnits.any((c) => c > 127);
    }

    bool empty(Object? value) => value == null || value is Map && value.isEmpty;
    final Object? root;
    try {
      root = jsonDecode(config);
    } on FormatException {
      return true;
    }
    if (root is! Map) return true;
    for (final MapEntry(:key, :value) in root.entries) {
      if (!named(key, 'dns') || value == null) continue;
      if (value is! Map ||
          value.entries.any((e) => named(e.key, 'hosts') && !empty(e.value)))
        return true;
    }
    return false;
  }

  // Callers validate this revision after awaiting cleanup so a newer Stop wins.
  Future<int> _interruptManualProbes() async {
    if (_manualProbes == 0) return _generation;
    _interruptingProbes = true;
    final generation = ++_generation;
    try {
      for (final worker in _workers.toList()) {
        worker.kill();
      }
      await _operation?.future;
      return generation;
    } finally {
      _interruptingProbes = false;
    }
  }
}
