part of 'desktop_proxy.dart';

extension _ProxyRuntime on DesktopProxy {
  Future<CatalogMap> _connect() async {
    if (_operation != null ||
        !{'disconnected', 'prepared', 'failed'}.contains(_state))
      throw desktopError('busy');
    final done = _operation = Completer<void>(), generation = _generation;
    try {
      await _stopProcess(hold: true);
      _checkGeneration(generation);
      if (Platform.isWindows || Platform.isLinux) {
        final settings = _catalog!.settings;
        // A crashed Windows helper's kill switch lets the next helper through,
        // so with Block traffic without VPN it stays until the new tunnel
        // replaces it. A dead Linux supervisor's rejects the next one's traffic.
        if (Platform.isWindows &&
            settings.xrayTunEnabled &&
            settings.blockWithoutVPN &&
            await _staleGuard()) {
          _guardKept = _guardStale = true;
        } else {
          await _clearStaleGuard();
        }
        _checkGeneration(generation);
      }
      final candidate = _catalog!.copy();
      await _start(candidate, generation);
      candidate.recordSuccess(candidate.selected!);
      // Only bookkeeping: a storage hiccup must not stop a working connection.
      String? unsaved;
      try {
        await _save({'version': 1, 'committed': candidate.data});
      } on Object catch (error) {
        unsaved =
            (error is PlatformException ? error.message : null) ??
            desktopError('storage_unavailable').message;
      }
      _checkGeneration(generation);
      if (unsaved == null) _catalog = candidate;
      _listener?.call(unsaved);
      await _syncSystemProxy();
      return {'state': _state};
    } on Object catch (error) {
      await _stopProcess(hold: true);
      // A newer generation (sleep, probe interruption) can cancel this connect
      // after it set connecting or connected; the runtime is stopped either way.
      if (generation == _generation ||
          {'connecting', 'connected'}.contains(_state))
        _state = 'failed';
      _checkGeneration(generation);
      if (error is PlatformException) rethrow;
      throw desktopError('connection_failed');
    } finally {
      _guardStale = false;
      _operation = null;
      done.complete();
    }
  }

  // Another process can empty the geofile cache under the catalog. Prepare the
  // selected route's files again once, as Refresh routing data would.
  Future<CatalogMap> _connectPreparingLostAssets() async {
    try {
      return await _connect();
    } on PlatformException catch (error) {
      if (error.code != 'assets_missing') rethrow;
    }
    final lost = DesktopProxy._runtimeAssets(_catalog!)['assetRevision'];
    final stops = _linkStopGeneration;
    while (_operation != null) await _operation!.future;
    try {
      await _mutate((candidate) async {
        for (final route in candidate.routes.where(
          (route) => route['assetRevision'] == lost,
        ))
          await _refreshGeofiles(candidate, route['id']! as String);
        return {};
      });
    } on PlatformException catch (error) {
      if (error.code == 'cancelled') rethrow;
      // The routing profile's own refresh reports the download error.
      throw desktopError('assets_missing');
    }
    // A Stop while the old revision was being retired still wins.
    if (stops != _linkStopGeneration) throw desktopError('cancelled');
    return _connect();
  }

  // A helper killed during this boot leaves its fail-closed DNS guard (on Linux,
  // a redirect to its dead resolver), which blocks every lookup, route
  // planning's included, until a helper removes it.
  Future<bool> _staleGuard() async =>
      (await _storage('staleVPNGuard', {}))['stale'] == true;

  Future<void> _clearStaleGuard() async {
    if (!await _staleGuard()) return;
    try {
      await _native('clearVPNGuard', {}, timeout: const Duration(seconds: 90));
      _guardKept = _guardHeld = false;
    } on PlatformException catch (error) {
      if (error.code == 'cancelled') rethrow;
      // The cause tells a declined prompt from one nobody answered.
      final stale = desktopError('vpn_guard_stale');
      throw PlatformException(
        code: stale.code,
        message: stale.message,
        details: error.code,
      );
    }
  }

  // A core whose server stopped passing traffic starts again on the same
  // server. The catalog is unchanged, so nothing is saved.
  Future<void> _restart() async {
    if (_operation != null || _state != 'connected') throw desktopError('busy');
    final done = _operation = Completer<void>(), generation = _generation;
    try {
      _state = 'reconnecting';
      await _stopProcess(hold: true);
      _checkGeneration(generation);
      await _start(_catalog!, generation);
    } on Object catch (error) {
      await _stopProcess(hold: true);
      if (generation == _generation ||
          {'reconnecting', 'connecting', 'connected'}.contains(_state))
        _state = 'failed';
      _checkGeneration(generation);
      if (error is PlatformException) rethrow;
      throw desktopError('connection_failed');
    } finally {
      _operation = null;
      done.complete();
    }
  }

  Future<void> _start(
    DesktopCatalog catalog,
    int generation, {
    String? preparedConfig,
  }) async {
    if (catalog.selected == null) throw desktopError('invalid_profile');
    _state = 'connecting';
    final config =
        preparedConfig ??
        await _prepareConfig(catalog, catalog.node(catalog.selected!));
    _checkGeneration(generation);
    final listeners = catalog.settings.listeners;
    // The core reports a taken port like any start failure, which would blame
    // the server and send failover through every backup.
    for (final port in [
      listeners.socksPort,
      if (listeners.httpInboundEnabled) listeners.httpPort,
    ]) {
      try {
        await (await ServerSocket.bind(
          listeners.allowLAN
              ? InternetAddress.anyIPv4
              : InternetAddress.loopbackIPv4,
          port,
        )).close();
      } on SocketException catch (error) {
        // Linux EACCES only means a low port, which the elevated VPN core may
        // bind. The local proxy core runs as this user and would fail the same way.
        if (error.osError?.errorCode != 13 || !catalog.settings.xrayTunEnabled)
          throw desktopError('listener_unavailable');
      }
    }
    final tunnel = catalog.settings.xrayTunEnabled;
    try {
      await _startCore(catalog, config);
      // The new tunnel's kill switch replaced any kept one.
      if (tunnel) _guardKept = _guardHeld = false;
    } on Object {
      // A start that fails leaves the kill switch its request asks for, as a
      // lost tunnel does. _guardHeld stays: the start may not have reached the
      // helper, and a plain stop to an idle one lifts only what a restart kept.
      if (tunnel && catalog.settings.blockWithoutVPN) _guardKept = true;
      rethrow;
    }
    _checkGeneration(generation);
    for (final port in [
      listeners.socksPort,
      if (listeners.httpInboundEnabled) listeners.httpPort,
    ]) {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(seconds: 2),
      );
      socket.destroy();
      _checkGeneration(generation);
    }
    if (_process == null) throw desktopError('connection_failed');
    _state = 'connected';
    _connectedAt = DateTime.now();
    _liveness = _livenessAt = null;
    _livenessFailures = 0;
  }

  Future<void> _startCore(DesktopCatalog catalog, String config) =>
      _native(catalog.settings.xrayTunEnabled ? 'runVPN' : 'runXrayFromJson', {
        'configJSON': config,
        'memoryLimitMB': catalog.settings.memoryLimitMB,
        'logLevel': catalog.settings.logLevel,
        'streamMetrics': true,
        'recordDiagnostics': catalog.settings.recordDiagnostics,
        if (catalog.settings.xrayTunEnabled) ...{
          'tcpMaxConnections': catalog.settings.tcpMaxConnections,
          'udpMaxConnections': catalog.settings.udpMaxConnections,
          'routePolicy': {
            'includedRoutes': catalog.settings.includedRoutes,
            'excludedRoutes': catalog.settings.excludedRoutes,
            'includeAllNetworks': catalog.settings.includeAllNetworks,
            'blockWithoutVPN': catalog.settings.blockWithoutVPN,
            'enforceRoutes': catalog.settings.enforceRoutes,
            'hideVPNIcon': catalog.settings.hideVPNIcon,
          },
        },
        ...DesktopProxy._runtimeAssets(catalog),
      });

  Future<CatalogMap> _native(
    String method,
    CatalogMap payload, {
    Duration? timeout,
  }) async {
    final generation = _generation;
    final session = method == 'runVPN' || method == 'stopVPN';
    final request = jsonEncode({
      'apiVersion': 1,
      'method': method,
      'payload': {...payload, if (method == 'runVPN') 'reuseSession': true},
    });
    // UTF-8 takes at most three bytes for a UTF-16 unit, so only a request
    // that could be too large is encoded to be measured.
    const limit = 16 * 1024 * 1024;
    if (request.length * 3 > limit && utf8.encode(request).length > limit)
      throw desktopError('request_too_large');
    final runtime = {'runXrayFromJson', 'runVPN'}.contains(method),
        lease = method == 'acquireCatalog',
        storage = {
          'loadCatalog',
          'saveCatalog',
          'staleVPNGuard',
        }.contains(method);
    final cancellable = !runtime && !session && !lease && !storage;
    // Each Windows core launch costs about 0.5 s, and a connect saves twice.
    // Linux keeps one-shot storage cores for its Secret Service sessions.
    final leased = storage && Platform.isWindows && _lease != null;
    final reused = session && _vpnSession != null || leased;
    final launch = leased
        ? _lease!
        : reused
        ? _vpnSession!
        : _startProcess(corePath);
    if (session) _vpnSession = launch;
    if (runtime) _process = launch;
    if (lease) _lease = launch;
    final Process process;
    try {
      process = await launch;
    } on Object {
      if (runtime) _process = null;
      if (lease) _lease = null;
      if (_vpnSession == launch) _vpnSession = null;
      throw desktopError('native_unavailable');
    }
    if (lease) {
      _leaseOutput = StreamIterator(process.stdout);
      _leaseExit = process.exitCode;
    }
    if (!reused)
      unawaited(process.stderr.drain<void>().catchError((Object _) {}));
    if (cancellable) _workers.add(process);
    var retained = leased;
    if (!reused)
      unawaited(
        process.exitCode.then((_) {
          if (_vpnSession == launch) _vpnSession = null;
          if (runtime && _process == launch) {
            _process = null;
            // _stopProcess reaps on purpose; its caller reports the outcome.
            if (_state == 'connected' && _stopping == null)
              _reportUnexpectedStop(session: session);
          }
          // The next storage request takes the lease again; the connection
          // stays up meanwhile.
          if (lease) _detachLease(launch);
        }),
      );
    try {
      if (cancellable) _checkGeneration(generation);
      if (runtime) {
        _metricsProcess = process;
        _latestMetrics = {};
        _metricsAt = null;
        _connections.clear();
      }
      if (session) {
        // A session whose output ended answers nothing more; its exit clears it.
        if (reused && _vpnReplyProcess != process)
          throw desktopError('native_unavailable');
        _vpnReplyProcess = process;
      }
      // Awake time: a connect that straddles a sleep must not run out at resume.
      final response = awakeTimeout(
        lease || leased
            ? _readLine(_leaseOutput!)
            : reused
            ? (_vpnReply = Completer<CatalogMap>()).future
            : runtime
            ? _readRuntimeResponse(process, session: session)
            : _readResponse(process),
        timeout ??
            (method == 'fetchSubscription'
                ? const Duration(seconds: 35)
                : method == 'prepareRoutingAssets'
                ? const Duration(seconds: 370)
                : method == 'runVPN'
                ? const Duration(seconds: 120)
                : _replyTimeout),
      );
      // A lease that missed a reply can no longer pair replies with requests,
      // so it ends; the next storage request takes a new one.
      if (leased)
        unawaited(
          response.then<void>(
            (_) {},
            onError: (Object _) {
              process.kill();
              _detachLease(launch);
            },
          ),
        );
      final write = Future<void>(() async {
        process.stdin.writeln(request);
        await process.stdin.flush();
      });
      final values = await Future.wait<Object?>([
        response,
        write,
      ], eagerError: true);
      final reply = catalogMap(values.first);
      if (reply['success'] != true) {
        final code = reply['error'];
        const safe = {
          'invalid_assets',
          'invalid_geodata',
          'input_too_large',
          'missing_geodata',
          'assets_missing',
          'assets_unavailable',
          'approval_required',
          'invalid_target',
          'storage_busy',
          'storage_corrupt',
          'storage_unavailable',
          'storage_conflict',
          'invalid_catalog',
          'invalid_configuration',
          'unsupported_profile',
          'connection_failed',
          'elevation_denied',
          'elevation_failed',
          'vpn_firewall_unavailable',
          'vpn_guard_busy',
          'invalid_url',
          'fetch_failed',
          'dns_failed',
          'provider_unreachable',
          'provider_error',
          'rate_limited',
          'subscription_denied',
          'subscription_unavailable',
          'hwid_limit',
          'hwid_required',
          'invalid_qr_image',
          'invalid_request',
          'invalid_backup',
          'invalid_backup_password',
          'recording_empty',
          'recording_failed',
        };
        final failure = safe.contains(code)
            ? code! as String
            : runtime
            ? 'connection_failed'
            : 'operation_failed';
        // The helper answered, so its elevated owner lives on for the next
        // command; if it exits instead, its exit clears the session.
        if (session) retained = true;
        throw PlatformException(
          code: failure,
          message: desktopError(
            failure,
            missing: (reply['data'] as Map?)?['missing'],
          ).message,
          details: method == 'ping' ? reply['data'] : null,
        );
      }
      if (runtime || session || lease || leased) {
        retained = true;
      } else if (await process.exitCode.timeout(const Duration(seconds: 3)) !=
          0) {
        throw desktopError('operation_failed');
      }
      return catalogMap(reply['data'] ?? {});
    } on Object catch (error) {
      // A worker ended by Stop must stop its caller's loop, not read as failed.
      if (cancellable && generation != _generation)
        throw desktopError('cancelled');
      if (error is PlatformException) rethrow;
      throw desktopError('operation_failed');
    } finally {
      _workers.remove(process);
      if (!retained) {
        if (timeout != null && !runtime && !lease) process.kill();
        await _reap(launch);
        if (_process == launch) _process = null;
        if (_lease == launch) _lease = null;
        if (_vpnSession == launch) _vpnSession = null;
      }
    }
  }

  void _detachLease(Future<Process> launch) {
    if (_lease != launch) return;
    _lease = null;
    _leaseOutput = null;
  }

  Future<CatalogMap> _readResponse(Process process) async {
    final output = StreamIterator(process.stdout);
    try {
      return await _readLine(output);
    } finally {
      await output.cancel();
    }
  }

  // The core sends nothing after a reply until the next request.
  Future<CatalogMap> _readLine(StreamIterator<List<int>> output) async {
    final bytes = BytesBuilder(copy: false);
    while (await output.moveNext()) {
      final chunk = output.current;
      if (bytes.length + chunk.length > 16 * 1024 * 1024 + 1)
        throw desktopError('operation_failed');
      final end = chunk.indexOf(10);
      bytes.add(end < 0 ? chunk : chunk.sublist(0, end));
      if (end >= 0)
        return catalogMap(jsonDecode(utf8.decode(bytes.takeBytes())));
    }
    throw desktopError('operation_failed');
  }

  Future<CatalogMap> _readRuntimeResponse(
    Process process, {
    bool session = false,
  }) {
    final ready = Completer<CatalogMap>();
    if (session) _vpnReply = ready;
    final bytes = BytesBuilder(copy: false);
    void failed() {
      if (!ready.isCompleted)
        ready.completeError(desktopError('operation_failed'));
      if (session &&
          _vpnReplyProcess == process &&
          _vpnReply != null &&
          !_vpnReply!.isCompleted) {
        _vpnReply!.completeError(desktopError('operation_failed'));
        _vpnReply = null;
      }
      if (session && _vpnReplyProcess == process) _vpnReplyProcess = null;
      process.kill();
    }

    process.stdout.listen(
      (chunk) {
        try {
          var offset = 0;
          while (offset < chunk.length) {
            final end = chunk.indexOf(10, offset);
            final stop = end < 0 ? chunk.length : end;
            if (bytes.length + stop - offset > 16 * 1024 * 1024)
              throw const FormatException();
            bytes.add(chunk.sublist(offset, stop));
            offset = end < 0 ? chunk.length : end + 1;
            if (end < 0) continue;
            final value = catalogMap(
              jsonDecode(utf8.decode(bytes.takeBytes())),
            );
            final event = value['event'];
            if (event != 'metrics' &&
                event != 'logs' &&
                event != 'connections' &&
                event != 'stopped' &&
                session) {
              final pending = _vpnReply;
              if (_vpnReplyProcess != process ||
                  pending == null ||
                  pending.isCompleted)
                throw const FormatException();
              _vpnReply = null;
              pending.complete(value);
            } else if (!ready.isCompleted && !session) {
              ready.complete(value);
            } else if (event == 'stopped' && session) {
              // The tunnel ended by itself. Its elevated owner waits for the
              // next connect, which then needs no new consent.
              if (_vpnReplyProcess == process &&
                  _process != null &&
                  _process == _vpnSession) {
                _process = null;
                _metricsProcess = null;
                if (_state == 'connected' && _stopping == null)
                  _reportUnexpectedStop(session: true);
              }
            } else if (event == 'logs' && value['data'] is Map) {
              _appendLogs(catalogMap(value['data']));
            } else if (event == 'connections' && value['data'] is Map) {
              if (_metricsProcess == process)
                _appendConnections(catalogMap(value['data']));
            } else {
              if (event != 'metrics' || value['data'] is! Map)
                throw const FormatException();
              if (_metricsProcess == process) {
                _latestMetrics = catalogMap(value['data']);
                _metricsAt = DateTime.now();
              }
            }
          }
        } on Object {
          failed();
        }
      },
      onError: (Object _) => failed(),
      onDone: () {
        failed();
      },
      cancelOnError: true,
    );
    return ready.future;
  }

  void _reportUnexpectedStop({required bool session}) {
    _state = 'failed';
    if (session && _catalog?.settings.blockWithoutVPN == true)
      _guardKept = true;
    // The listener shows text; codes are for exceptions.
    // Settings edits reconnect, so the catalog matches the running session.
    _listener?.call(
      !session
          ? 'Connection stopped unexpectedly. Reconnect to retry.'
          : _catalog?.settings.blockWithoutVPN == true
          ? 'Connection stopped unexpectedly. Block traffic without VPN keeps traffic blocked until you reconnect, or use Repair VPN setup to lift the block.'
          // A killed helper can leave its DNS guard; Repair VPN setup clears it.
          : 'Connection stopped unexpectedly. Reconnect to retry; if sites stay unreachable, use Repair VPN setup.',
    );
  }

  Future<void> _reap(Future<Process>? launch) async {
    if (launch == null) return;
    final Process process;
    try {
      process = await launch;
    } on Object {
      return;
    }
    unawaited(process.stdin.close().catchError((Object _) {}));
    try {
      // The VPN broker waits for its elevated child and owned network cleanup.
      await process.exitCode.timeout(_helperExitGrace);
    } on TimeoutException {
      process.kill();
      try {
        await process.exitCode.timeout(const Duration(seconds: 3));
      } on TimeoutException {
        // Shutdown and later stops must still complete.
      }
    }
  }

  // hold: another start follows. With Block traffic without VPN the core then
  // keeps its kill switch between the two tunnels, so nothing leaves outside
  // while a server switch, a settings change or failover restarts the tunnel.
  // The plain stop of a disconnect lifts it.
  Future<void> _stopProcess({bool hold = false}) => _stopping ??= () async {
    final launch = _process;
    if (launch != null &&
        launch == _vpnSession &&
        _vpnReply == null &&
        !_disposed &&
        !_storageLost) {
      try {
        final stopped = await _native('stopVPN', {if (hold) 'hold': true});
        _guardKept = _guardHeld =
            hold &&
            _catalog?.settings.xrayTunEnabled == true &&
            _catalog?.settings.blockWithoutVPN == true;
        // The helper keeps retrying the release; until it works, names may not resolve.
        if (stopped['warning'] == 'vpn_dns_release_failed')
          _listener?.call(
            'Disconnected, but Windows DNS could not be restored yet. If sites stay unreachable, use Repair VPN setup.',
          );
      } on Object {
        // The helper's routes and guards end with its broker. A failed stop
        // must not leave Stop, intent and reconnect stuck behind it.
        await _reap(launch);
        if (_vpnSession == launch) _vpnSession = null;
      }
    } else {
      await _reap(launch);
      if (_vpnSession == launch) _vpnSession = null;
      if (!hold) await _liftHeldGuard();
    }
    if (_process == launch) _process = null;
    _metricsProcess = null;
    _connections.clear();
  }().whenComplete(() => _stopping = null);

  // Lifts the kill switch a restart's stop kept, when no tunnel follows it: a
  // disconnect during the restart, or a server name nothing can resolve.
  Future<void> _liftHeldGuard() async {
    if (!_guardHeld) return;
    _guardKept = _guardHeld = false;
    final session = _vpnSession;
    if (session == null || _vpnReply != null || _disposed || _storageLost)
      return;
    try {
      await _native('stopVPN', {});
    } on Object {
      await _reap(session);
      if (_vpnSession == session) _vpnSession = null;
    }
  }

  Future<void> _disconnect() async {
    _cancelCamera?.call();
    _linkStopGeneration++;
    _generation++;
    _state = 'disconnecting';
    for (final worker in _workers.toList()) {
      worker.kill();
    }
    await _stopProcess();
    await _operation?.future;
    await _stopProcess(); // A launch can cross the first cancellation.
    _state = 'disconnected';
    await _syncSystemProxy();
  }
}
