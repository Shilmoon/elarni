part of 'desktop_proxy.dart';

extension _ProxyCatalog on DesktopProxy {
  Future<String> _prepareConfig(DesktopCatalog catalog, CatalogMap node) async {
    if (catalog.settings.xrayTunEnabled &&
        !catalog.settings.inboundAuthEnabled) {
      // Other apps, including ones excluded from the VPN, must not proxy
      // through its listeners to learn the exit address. Nothing in the app
      // uses them while the VPN runs, so a login for this start is enough.
      final random = Random.secure();
      String token() => List.generate(
        16,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      catalog = catalog.copy();
      catalog.data['settings'] = catalog.settings
          .copyWith(inboundAuthEnabled: true)
          .toMap();
      catalog.data['inboundCredentials'] = _vpnLogin = {
        'username': token(),
        'password': token(),
      };
    }
    final raw = await _compile(catalog, node);
    final config = catalogMap(jsonDecode(raw));
    final endpoints = catalogList(
      (await DesktopProxy._domainOff(domainPath, 'profileEndpoints', {
        'config': config,
      }))['endpoints'],
    );
    final resolved = <String, Object?>{}, unavailable = <String>[];
    final mappings = await _hostMappings(
      raw,
      endpoints.where((e) => e['physical'] == true).toList(),
    );
    for (final endpoint in endpoints.where((e) => e['physical'] == true)) {
      final path = endpoint['addressPath']! as String;
      try {
        resolved[path] = (await _endpointAddresses(
          endpoint,
          DesktopProxy._nodeSettings(catalog, node),
          mapping: mappings[endpoint['host']] as Map?,
        )).first.address;
      } on Object {
        unavailable.add(path);
      }
    }
    final CatalogMap prepared;
    try {
      prepared = await DesktopProxy._domainOff(domainPath, 'prepareConfig', {
        'config': config,
        'resolved': resolved,
        'unavailable': unavailable,
        'pin': catalog.settings.resolveServer,
        'pinHosts': mappings.keys.toList(),
      });
    } on PlatformException catch (error) {
      // Without the servers that did not resolve, nothing is left to connect
      // through; that is a failed connection, which failover moves on from.
      if (unavailable.isEmpty || error.code != 'invalid_routing') rethrow;
      throw desktopError('connection_failed');
    }
    return jsonEncode(prepared['config']);
  }

  Future<String> _importContent(String source, Object? text) async {
    if (source == 'camera') {
      if (_cameraScan == null) throw desktopError('camera_unavailable');
      return _cameraScan(
        (bytes) async =>
            (await _native('decodeQRImage', {
                  'image': base64.encode(bytes),
                }))['text']!
                as String,
      );
    }
    if (source == 'text') {
      if (text is! String ||
          text.isEmpty ||
          utf8.encode(text).length > 4 * 1024 * 1024)
        throw desktopError('unsupported_profile');
      return text;
    }
    if (!{'file', 'qrImage', 'backup'}.contains(source))
      throw desktopError('unsupported_operation');
    final picked = await _platformRequest('pickFile', {
      'image': source == 'qrImage',
      'backup': source == 'backup',
    });
    if (picked['path'] == null) throw desktopError('cancelled');
    final bytes = BytesBuilder(copy: false);
    final limit =
        (source == 'backup'
            ? 12
            : source == 'file'
            ? 4
            : 8) *
        1024 *
        1024;
    await for (final chunk in File(picked['path']! as String).openRead()) {
      if (bytes.length + chunk.length > limit)
        throw desktopError('import_too_large');
      bytes.add(chunk);
    }
    if (source != 'qrImage') return utf8.decode(bytes.takeBytes());
    return (await _native('decodeQRImage', {
          'image': base64.encode(bytes.takeBytes()),
        }))['text']!
        as String;
  }

  // The SOCKS listener of the running core.
  String _listenerProxy(DesktopCatalog catalog) {
    final credentials = catalog.settings.listeners.inboundAuthEnabled
        ? catalogMap(catalog.data['inboundCredentials'] ?? {})
        : catalog.settings.xrayTunEnabled
        ? _vpnLogin
        : null;
    final userInfo = credentials != null
        ? '${Uri.encodeComponent(credentials['username']! as String)}:${Uri.encodeComponent(credentials['password']! as String)}'
        : '';
    return Uri(
      scheme: 'socks5',
      host: '127.0.0.1',
      port: catalog.settings.socksPort,
      userInfo: userInfo,
    ).toString();
  }

  // While the VPN runs, the system resolver can be its FakeDNS, whose
  // 198.18.0.0/15 answers a download rejects as private; through the listener
  // it resolves inside the tunnel, as on Android.
  String? _tunnelFetchProxy() =>
      _state == 'connected' && _catalog!.settings.xrayTunEnabled
      ? _listenerProxy(_catalog!)
      : null;

  Future<void> _refreshGeofiles(
    DesktopCatalog candidate,
    String id, {
    bool refresh = false,
    String? file,
  }) async {
    final route = candidate.route(id),
        profile = catalogMap(candidate.route(id)['profile']);
    final files = <String, Object?>{};
    for (final entry in {
      'geoip': 'Geoipurl',
      'geosite': 'Geositeurl',
    }.entries) {
      final url = profile[entry.value];
      if (url is String && url.isNotEmpty) files[entry.key] = url;
    }
    if (files.isEmpty) {
      candidate.putRoute({
        ...route,
        'assetRevision': null,
        'geofiles': <Object?>[],
        'geofileStatus': 'ready',
        'skippedGeodata': <Object?>[],
        'nextGeoRefreshAt': null,
        'geoFailures': 0,
      });
      return;
    }
    final proxy = _tunnelFetchProxy();
    final assets = await _native('prepareRoutingAssets', {
      'files': files,
      'previous': route['assetRevision'] ?? '',
      ..._assetSelectors(candidate, route),
      'reduce': profile['UseChunkFiles'] == 'true',
      'refresh': refresh,
      'file': file ?? '',
      if (proxy != null) 'proxy': proxy,
    });
    candidate.putRoute({
      ...route,
      ...assets,
      'geofileError': null,
      'nextGeoRefreshAt': candidate.now + 604800,
      'geoFailures': 0,
    });
  }

  // Direct and Block rules and domestic DNS domains may name codes the geofiles
  // lack, which the core then skips; Proxy rules and servers need their codes.
  CatalogMap _assetSelectors(DesktopCatalog catalog, CatalogMap route) {
    final selectors = <String>{}, optional = <String>{};
    void collect(Object? value, Set<String> into) {
      if (value is Map) {
        for (final item in value.values) collect(item, into);
      }
      if (value is List) {
        for (final item in value) collect(item, into);
      }
      // Xray reads a leading ! on an IP rule like one before the code.
      if (value is String &&
          RegExp(
            r'^!*(geoip:|geosite:|ext:|ext-ip:|ext-site:|ext-domain:)',
          ).hasMatch(value))
        into.add(value);
    }

    final model = catalogMap(route['routeModel'] ?? <String, Object?>{});
    final dns = catalogMap(model['dnsPolicy'] ?? <String, Object?>{});
    for (final rule in catalogList(model['rules'])) {
      collect(
        rule,
        {'direct', 'block'}.contains(rule['action']) ? optional : selectors,
      );
    }
    collect(dns['domesticDomains'], optional);
    collect({
      ...model,
      'rules': null,
      'dnsPolicy': {...dns, 'domesticDomains': null},
    }, selectors);
    for (final source in catalog.sources) {
      if (catalog.assignments[source['id']] == route['id']) {
        for (final node in catalogList(source['nodes'])) {
          collect(node['config'], selectors);
        }
      }
    }
    return {
      'selectors': selectors.toList()..sort(),
      'optional': optional.toList()..sort(),
    };
  }

  Future<CatalogMap> _mutate(
    Future<CatalogMap> Function(DesktopCatalog) edit, {
    bool forceRestart = false,
    bool refreshAssets = true,
    Future<void> Function(DesktopCatalog)? verifyRuntime,
    // Failover: the server to start instead of one that failed to start or
    // verify, or null to roll back.
    String? Function(Object error)? next,
  }) async {
    _checkGeneration(await _interruptManualProbes());
    if (_operation != null || {'connecting', 'disconnecting'}.contains(_state))
      throw desktopError('busy');
    final done = _operation = Completer<void>();
    final generation = _generation,
        before = _catalog!,
        candidate = _catalog!.copy();
    final previousState = _state;
    final wasConnected = previousState == 'connected';
    var checkpoint = false, runtimeChanged = false;
    try {
      final result = await edit(candidate);
      _checkGeneration(generation);
      // Validate before fetching assets, journaling, or touching the runtime.
      candidate.validate();
      _validateSettings(candidate.settings);
      final beforeSemantics = await _semantics(before);
      for (final route in refreshAssets ? candidate.routes : <CatalogMap>[]) {
        final old = before.routes
            .where((old) => old['id'] == route['id'])
            .firstOrNull;
        if (old?['assetRevision'] != route['assetRevision']) continue;
        final profile = catalogMap(route['profile']);
        final oldProfile = catalogMap(old?['profile'] ?? {});
        final changedURLs = [
          'Geoipurl',
          'Geositeurl',
        ].any((key) => profile[key] != oldProfile[key]);
        // Skipped codes depend on the rules with complete files too.
        final assetInputsChanged =
            profile['UseChunkFiles'] != oldProfile['UseChunkFiles'] ||
            jsonEncode(_assetSelectors(candidate, route)) !=
                jsonEncode(old == null ? {} : _assetSelectors(before, old));
        if (old != null && !changedURLs && !assetInputsChanged) continue;
        try {
          await _refreshGeofiles(
            candidate,
            route['id']! as String,
            refresh: changedURLs,
          );
        } on PlatformException catch (error) {
          _checkGeneration(generation);
          candidate.geofilesFailed(route['id']! as String, error.message);
        }
      }
      candidate.validate();
      _validateSettings(candidate.settings);
      // Bind health to the final compiled configuration and prepared assets.
      final oldNodes = {
        for (final node in catalogList(beforeSemantics['nodes']))
          node['id']: node,
      };
      final candidateSemantics = await _semantics(candidate);
      for (final node in catalogList(candidateSemantics['nodes'])) {
        final old = oldNodes[node['id']];
        if (old != null &&
            (old['assetRevision'] != node['assetRevision'] ||
                DesktopCatalog.identity(old['config']) !=
                    DesktopCatalog.identity(node['config']) ||
                DesktopCatalog.identity(old['identity']) !=
                    DesktopCatalog.identity(node['identity']))) {
          candidate.updateNode(node['id']! as String, {
            'configurationRevision': desktopID(),
          });
        }
      }
      _checkGeneration(generation);
      if (!forceRestart &&
          jsonEncode(candidate.data) == jsonEncode(before.data))
        return result;
      // Loading discards an interrupted change, so a marker is enough; a second
      // catalog copy would push large catalogs past the core's save limit.
      await _save({'version': 1, 'committed': before.data, 'pending': true});
      checkpoint = true;
      _checkGeneration(generation);
      if ((wasConnected || forceRestart) &&
          (forceRestart ||
              candidate.selected == null ||
              jsonEncode(DesktopProxy._runtimeAssets(candidate)) !=
                  jsonEncode(DesktopProxy._runtimeAssets(before)) ||
              jsonEncode(_runtimeSettings(candidate.settings)) !=
                  jsonEncode(_runtimeSettings(before.settings)) ||
              DesktopProxy._compiled(candidateSemantics, candidate.selected!) !=
                  DesktopProxy._compiled(beforeSemantics, before.selected!))) {
        Future<void> stop() async {
          runtimeChanged = true;
          // The exit of a deliberately stopped core is not a connection failure.
          if (_state == 'connected') _state = 'connecting';
          await _stopProcess();
          _checkGeneration(generation);
        }

        // Semantics do not depend on the selection, so they hold for each try.
        for (;;) {
          try {
            // A running VPN captures this app's lookups too, so the
            // replacement's servers would resolve through the old tunnel,
            // which may be dead.
            final tunnel = _process != null && before.settings.xrayTunEnabled;
            if (tunnel) await stop();
            String? prepared;
            if (candidate.selected != null) {
              prepared = await _prepareConfig(
                candidate,
                candidate.node(candidate.selected!),
              );
              final validation = await _native('validateConfig', {
                'configJSON': prepared,
                ...DesktopProxy._runtimeAssets(candidate),
              });
              if (validation['valid'] != true)
                throw desktopError('invalid_configuration');
              _checkGeneration(generation);
            }
            if (!tunnel) await stop();
            if (candidate.selected != null)
              await _start(candidate, generation, preparedConfig: prepared);
            else {
              _state = 'disconnected';
            }
            if (candidate.selected != null)
              await verifyRuntime?.call(candidate);
            break;
          } on Object catch (error) {
            final node = generation == _generation ? next?.call(error) : null;
            if (node == null) rethrow;
            candidate.data['selectedNodeId'] = node;
            candidate.validate();
          }
        }
      }
      _checkGeneration(generation);
      if (runtimeChanged && candidate.selected != null && _state == 'connected')
        candidate.recordSuccess(candidate.selected!);
      await _save({'version': 1, 'committed': candidate.data});
      _checkGeneration(generation);
      _catalog = candidate;
      // Revision and success bookkeeping written since compiling are not
      // semantic inputs, so the result also describes the committed data.
      _rememberSemantics(jsonEncode(candidate.data), candidateSemantics);
      // A failure stays reported until Connect, Disconnect or Repair: a dead
      // TUN helper leaves its fail-closed DNS guard.
      if (!wasConnected && !runtimeChanged && previousState != 'failed')
        _state = candidate.selected == null ? 'disconnected' : 'prepared';
      _listener?.call(null);
      return _currentResult(result, candidate);
    } on Object catch (error) {
      if (checkpoint) {
        try {
          if (runtimeChanged) await _stopProcess();
          await _save({'version': 1, 'committed': before.data});
        } on Object {
          _storageLost = true;
          _state = 'failed';
          throw desktopError('rollback_failed');
        }
        // The saved catalog is restored, so a failed or cancelled restart leaves
        // only the runtime down; Disconnect and Repair must keep working.
        try {
          if (runtimeChanged &&
              wasConnected &&
              generation == _generation &&
              !_disposed)
            await _start(before, generation);
          if (runtimeChanged &&
              !wasConnected &&
              generation == _generation &&
              !_disposed)
            _state = previousState;
        } on Object {
          // After a Stop, a newer operation may already own the runtime.
          if (generation == _generation) {
            try {
              await _stopProcess();
            } on Object {
              // 'failed' below already reports the runtime as unusable.
            }
            _state = 'failed';
            throw desktopError('rollback_failed');
          }
        }
        // A cancelled restart stopped the runtime without restoring it.
        if (runtimeChanged &&
            generation != _generation &&
            {'connecting', 'connected'}.contains(_state))
          _state = 'failed';
      }
      _checkGeneration(generation);
      if (error is PlatformException) rethrow;
      throw desktopError('operation_failed');
    } finally {
      if (jsonEncode(
            candidate.routes.map((route) => route['assetRevision']).toList(),
          ) !=
          jsonEncode(
            before.routes.map((route) => route['assetRevision']).toList(),
          ))
        await _retireAssets();
      _operation = null;
      done.complete();
    }
  }

  CatalogMap _currentResult(CatalogMap result, DesktopCatalog catalog) => {
    ...result,
    if (result['subscriptions'] is Map) 'subscriptions': catalog.snapshot(),
    if (result['subscriptions'] is List) ...catalog.snapshot(),
    if (result.containsKey('profiles')) ...catalog.routingSnapshot(),
  };

  Future<CatalogMap> _semantics(DesktopCatalog catalog) async {
    final key = jsonEncode(catalog.data);
    final known = _semanticsMemo[key];
    if (known != null) return known;
    final semantics = await DesktopProxy._semanticsOff(
      domainPath,
      catalog.data,
    );
    _rememberSemantics(key, semantics);
    return semantics;
  }

  void _rememberSemantics(String key, CatalogMap semantics) {
    _semanticsMemo
      ..remove(key)
      ..[key] = semantics;
    while (_semanticsMemo.length > 2) {
      _semanticsMemo.remove(_semanticsMemo.keys.first);
    }
  }

  CatalogMap _runtimeSettings(TunnelSettings settings) => settings.toMap()
    ..remove('subscriptionAutoUpdateHours')
    ..remove('monitoringEnabled')
    ..remove('logLevel')
    ..remove('onDemandEnabled')
    ..remove('connectOnUntrustedWiFi')
    ..remove('trustedWiFiNetworks')
    ..remove('disconnectOnSleep');

  void _validateSettings(TunnelSettings settings) {
    if (!settings.validFragmentation) throw desktopError('invalid_settings');
    if (settings.schemaVersion != 1 ||
        settings.subscriptionAutoUpdateHours < 1 ||
        settings.subscriptionAutoUpdateHours > 168 ||
        settings.socksPort < 1 ||
        settings.socksPort > 65535 ||
        settings.httpPort < 1 ||
        settings.httpPort > 65535 ||
        settings.httpPort == settings.socksPort ||
        settings.allowLAN && !settings.inboundAuthEnabled ||
        settings.inboundAuthEnabled && !settings.inboundCredentialsConfigured ||
        (settings.memoryLimitMB != 0 && settings.memoryLimitMB < 40) ||
        settings.memoryLimitMB > 4096 ||
        settings.idleTimeoutSeconds < 30 ||
        settings.idleTimeoutSeconds > 3600 ||
        settings.tcpMaxConnections < 1 ||
        settings.tcpMaxConnections > 4096 ||
        settings.udpMaxConnections < 1 ||
        settings.udpMaxConnections > 4096 ||
        settings.includedRoutes.isEmpty ||
        settings.includedRoutes.length > 64 ||
        settings.excludedRoutes.length > 64 ||
        settings.routeEnforcementError != null ||
        !{'ipv4', 'ipv6', 'automatic'}.contains(settings.preferredIP) ||
        !TunnelSettings.logLevels.contains(settings.logLevel) ||
        !{
          'inherit',
          'ipv4',
          'ipv6',
          'automatic',
        }.contains(settings.profilePreferredIP) ||
        !{'inherit', 'default', 'routing'}.contains(settings.profileDNSMode) ||
        !settings.validPerApp ||
        !settings.validTrustedWiFi)
      throw desktopError('invalid_settings');
    _canonicalRoutes(settings.includedRoutes);
    _canonicalRoutes(settings.excludedRoutes);
  }

  List<String> _canonicalRoutes(List<String> routes) => routes
      .map((value) {
        final parts = value.trim().split('/');
        final ip = parts.length == 2
            ? InternetAddress.tryParse(parts.first)
            : null;
        final bits =
            parts.length == 2 && RegExp(r'^\d{1,3}$').hasMatch(parts.last)
            ? int.tryParse(parts.last)
            : null;
        if (ip == null ||
            bits == null ||
            bits > ip.rawAddress.length * 8 ||
            (ip.rawAddress.length == 16 &&
                ip.rawAddress.take(10).every((b) => b == 0) &&
                ip.rawAddress[10] == 255 &&
                ip.rawAddress[11] == 255))
          throw desktopError('invalid_settings');
        final bytes = Uint8List.fromList(ip.rawAddress);
        for (var bit = bits; bit < bytes.length * 8; bit++) {
          bytes[bit ~/ 8] &= ~(1 << (7 - bit % 8));
        }
        return '${InternetAddress.fromRawAddress(bytes).address}/$bits';
      })
      .toSet()
      .toList();

  CatalogMap _domainRequest(String operation, CatalogMap payload) {
    try {
      _domain ??= ElarniDomainFfi.openLibrary(domainPath);
    } on Object {
      throw desktopError('native_unavailable');
    }
    return DesktopProxy._requestWith(_domain!, operation, payload);
  }

  Future<String> _compile(DesktopCatalog catalog, CatalogMap node) =>
      DesktopProxy._compileOff(domainPath, catalog.data, node['id']! as String);
}
