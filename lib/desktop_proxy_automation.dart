part of 'desktop_proxy.dart';

extension _ProxyAutomation on DesktopProxy {
  Future<void> _refreshDue() async {
    if (_disposed ||
        _automationBusy ||
        _operation != null ||
        _catalog == null ||
        _storageLost)
      return;
    final catalog = _catalog!, now = _refreshClock();
    bool ready(String key) =>
        !(_refreshBackoff[key]?.until.isAfter(now) ?? false);
    bool dueAt(Object? at) => at is num && at <= catalog.now;
    final due = catalog.sources
        .where(
          (source) =>
              dueAt(catalog.nextSubscriptionRefresh(source)) &&
              ready('source:${source['id']}'),
        )
        .firstOrNull;
    final route = due != null
        ? null
        : catalog.routes
              .where(
                (route) =>
                    dueAt(route['nextManagedRefreshAt']) &&
                    ready('managed:${route['id']}'),
              )
              .firstOrNull;
    final geo = due != null || route != null
        ? null
        : catalog.routes
              .where(
                (route) =>
                    dueAt(route['nextGeoRefreshAt']) &&
                    ready('geo:${route['id']}'),
              )
              .firstOrNull;
    final key = due != null
        ? 'source:${due['id']}'
        : route != null
        ? 'managed:${route['id']}'
        : geo != null
        ? 'geo:${geo['id']}'
        : null;
    if (key == null) return;
    // The user never started this refresh, so their edits wait for it
    // instead of failing busy, as they do behind automation.
    _automationBusy = true;
    try {
      if (due != null) {
        await _invoke('refreshSubscription', {
          'id': due['id'],
        }, automatic: true);
      } else if (route != null) {
        await _mutate((candidate) async {
          await candidate.refreshManaged(
            route['id']! as String,
            proxy: _tunnelFetchProxy(),
          );
          return candidate.routingSnapshot();
        });
      } else {
        await _invoke('refreshRoutingGeofiles', {
          'id': geo!['id'],
        }, automatic: true);
      }
      _refreshBackoff.remove(key);
    } on Object catch (error) {
      // Another operation started first or a user action cancelled this one;
      // neither is a refresh failure, and the next tick retries.
      if (error is PlatformException &&
          {'busy', 'cancelled'}.contains(error.code))
        return;
      // Failures after the fetch (validation, compiling, saving) discard the
      // candidate and its backoff; without one this item would starve the rest.
      // It follows the catalog's retry schedule, so it never delays a retry
      // that the catalog recorded.
      final failures = (_refreshBackoff[key]?.failures ?? 0) + 1;
      _refreshBackoff[key] = (
        until: now.add(Duration(seconds: DesktopCatalog.retryDelay(failures))),
        failures: failures,
      );
      _listener?.call('A scheduled subscription or routing refresh failed.');
    } finally {
      _automationBusy = false;
    }
  }

  // Connect on untrusted Wi-Fi: joining a network that is not on the trusted
  // list connects, once per join. Other networks and a Stop stay as they are.
  Future<void> _wifiTick() async {
    if (_catalog?.settings.connectOnUntrustedWiFi != true) {
      _wifi = _wifiStatus = _wifiPath = null;
      return;
    }
    if (_wifiBusy || _disposed || _storageLost) return;
    _wifiBusy = true;
    try {
      // Linux reads the name with a process; a join changes the addresses, so
      // read on a change and otherwise every 12th interval (a minute).
      final path = await _physicalPath();
      if (path == _wifiPath && ++_wifiSkips < 12) return;
      final reading = await _wifiNetwork();
      _wifiPath = path;
      _wifiSkips = 0;
      final settings = _catalog?.settings;
      if (settings == null || !settings.connectOnUntrustedWiFi) return;
      _wifiStatus = reading.denied ? 'locationDenied' : 'ok';
      // A busy controller leaves the join for the next reading.
      if (reading.denied ||
          _wifi?.name == reading.name && _wifi != null ||
          _operation != null ||
          _disconnecting != null)
        return;
      _wifi = (name: reading.name);
      final name = reading.name;
      if (name == null ||
          settings.trustedWiFiNetworks.contains(name) ||
          _catalog!.selected == null ||
          {'connected', 'connecting'}.contains(_state))
        return;
      await _invoke('connect', {});
    } on Object {
      // A failed Connect shows as the connection's own error.
    } finally {
      _wifiBusy = false;
    }
  }

  // The addresses of usable physical links, sorted; empty when offline.
  Future<String> _physicalPath() async {
    final interfaces = await NetworkInterface.list(
      includeLoopback: false,
      includeLinkLocal: false,
    );
    final paths = <String>[];
    for (final interface in interfaces) {
      if (!DesktopAutomation.physicalInterface(
        interface.name,
        linux: Platform.isLinux,
      ))
        continue;
      if (Platform.isLinux) {
        // Addresses survive an unplugged/admin-down link. Linux considers
        // UP and UNKNOWN usable; the latter supports virtual/older drivers.
        // Sync: sysfs answers from memory; an async read would hop through
        // the IO thread pool for every interface, every second.
        try {
          final state = File(
            '/sys/class/net/${interface.name}/operstate',
          ).readAsStringSync().trim();
          if (state != 'up' && state != 'unknown') continue;
        } on FileSystemException {
          continue; // The interface may disappear during enumeration.
        }
      }
      paths.addAll(
        interface.addresses.map((a) => '${interface.index}:${a.address}'),
      );
    }
    paths.sort();
    return paths.join('|');
  }

  CatalogMap _automationStatus() => {
    'schemaVersion': 1,
    'enabled': _automationConfig['enabled'],
    'policy': _automationConfig['policy'],
    'configuration': copyCatalog(_automationConfig),
    'policySupported': true,
    'healthNodeID': _verifiedHealth?.epoch == _automation.epoch
        ? _verifiedHealth?.node
        : null,
    'healthAgeSeconds': _verifiedHealth?.epoch == _automation.epoch
        ? _now - _verifiedHealth!.at
        : null,
    'status': _automation.status,
    'attempts': _automation.attempts,
    'exhausted': _automation.exhausted,
    'pendingRetry': _automation.retryAt != null,
    'pathAvailable': _automation.online,
    'wifi': _wifiStatus,
    'sleeping': _automation.sleeping,
    'targetIDs': catalogList(
      _automationConfig['targets'],
    ).map((t) => t['id']).toList(),
    'physicalPaths': [],
    'candidateFailures': Map<String, Object?>.from(_candidateFailures),
    'diagnostics': [],
    'whitelistMode': _automation.whitelist,
  };

  static String _serverRevision(DesktopCatalog catalog) {
    final node = catalog.node(catalog.selected!);
    return '${node['id']}:${node['configurationRevision']}';
  }

  bool _russianEntry(String id) =>
      (_automationConfig['russianEntryNodeIDs'] as List? ?? []).contains(id);

  List<String> _recoveryOrder(String current) {
    final order = (_automationConfig['nodeIDs']! as List).cast<String>();
    return _automation.recoveryOrder(
      order,
      current,
      {
        for (final id in order)
          if (DesktopAutomation.tcp443(
            catalogMap(_catalog!.node(id)['config'] ?? {}),
          ))
            id,
      },
      {...order.where(_russianEntry)},
    );
  }

  Future<void> _persistAutomation() async {
    if (_disposed || _storageLost) return;
    final data = _catalog!.data, episode = _automation.episode;
    final saved = catalogMap(data['automationEpisode'] ?? {});
    final writeEpisode =
        data.containsKey('automationEpisode') || _automation.recovering;
    final writeIntent =
        data.containsKey('connectionIntent') || _automation.intent;
    // An episode's start, exhaustion and end are saved, not each attempt.
    if ((!writeEpisode ||
            saved['exhausted'] == episode['exhausted'] &&
                saved['interrupted'] == episode['interrupted']) &&
        (!writeIntent || data['connectionIntent'] == _automation.intent))
      return;
    if (_operation != null) throw desktopError('busy');
    final done = _operation = Completer<void>();
    final generation = _generation;
    final candidate = _catalog!.copy();
    try {
      if (writeEpisode) candidate.data['automationEpisode'] = episode;
      if (writeIntent) candidate.data['connectionIntent'] = _automation.intent;
      await _save({'version': 1, 'committed': candidate.data});
      // Mirror the saved intent even when a Stop cancelled this save, so the
      // Stop's own save sees the difference and overwrites it.
      _catalog = candidate;
      _checkGeneration(generation);
    } finally {
      _operation = null;
      done.complete();
    }
  }

  // The 120 s budget and exhaustion end failover, not retrying the selected server.
  void _checkAutomation(int epoch, {bool failover = true}) {
    if (failover &&
        !_disposed &&
        _automation.intent &&
        epoch == _automation.epoch &&
        _automation.episodeStarted != null &&
        _now >= _automation.episodeStarted! + 120) {
      _automation.exhausted = true;
      _automation.retryAt = _automation.healthAt = null;
      _automation.status = 'exhausted';
      throw desktopError('exhausted');
    }
    if (_disposed ||
        !_automation.intent ||
        !_automation.online ||
        _automation.sleeping ||
        epoch != _automation.epoch ||
        failover && _automation.exhausted) {
      throw desktopError('cancelled');
    }
  }

  Future<void> _automaticHealth(DesktopCatalog catalog) async {
    var qualifying = 0;
    var invalidTarget = false;
    final targets = catalogList(_automationConfig['targets']);
    final runtime = _connectedAt;
    for (final target in targets) {
      try {
        await _ping(
          {
            ...target,
            'nodeId': catalog.selected,
            'protocol': 'activeProxy',
            'method': 'GET',
            'mode': 'default',
            'timeout': _automationProbeSeconds,
          },
          _generation,
          usingCatalog: catalog,
          automatic: true,
        );
        _automation.observe(
          catalog.selected!,
          true,
          _russianEntry(catalog.selected!),
        );
        _verifiedHealth = (
          node: catalog.selected!,
          at: _now,
          epoch: _automation.epoch,
        );
        // Traffic passed, so liveness need not launch its own probe core.
        if (_connectedAt == runtime && _state == 'connected') {
          _liveness = 'ok';
          _livenessFailures = 0;
          _trafficServer = _serverRevision(catalog);
          _livenessAt = _now;
          _livenessUplink = (_latestMetrics['uplinkBytes'] as num?)?.toInt();
        }
        return;
      } on PlatformException catch (error) {
        final details = error.details is Map
            ? catalogMap(error.details)
            : <String, Object?>{};
        final diagnostic = catalogMap(details['diagnostics'] ?? {});
        if (diagnostic['code'] == 'timeout' ||
            (unattended &&
                diagnostic['stage'] == 'target_request' &&
                {
                  'failed',
                  'eof',
                  'unexpected_eof',
                  'closed_pipe',
                }.contains(diagnostic['code']))) {
          qualifying++;
        }
        if (diagnostic['code'] == 'target_dns_failed' ||
            (diagnostic['httpStatus'] as num? ?? 0) != 0)
          invalidTarget = true;
        if (error.code == 'cancelled') rethrow;
      }
    }
    final code = invalidTarget
        ? 'invalidTarget'
        // Switching servers needs both targets to fail, when there are two.
        : qualifying >=
              (_automationConfig['policy'] == 'fixed' || targets.length == 1
                  ? 1
                  : 2)
        ? 'endpointFailure'
        : 'indeterminate';
    if (code == 'endpointFailure')
      _automation.observe(
        catalog.selected!,
        false,
        _russianEntry(catalog.selected!),
      );
    throw desktopError(code);
  }

  Future<void> _recoverAllowed(int epoch) async {
    final current = _catalog!.selected!;
    final candidates = _automation.recoveryCandidates(
      _automationConfig['policy']! as String,
      _recoveryOrder(current),
      current,
      _now,
    );
    final deadline = _now + 60;
    var index = 0;
    String nextCandidate() {
      _checkAutomation(epoch);
      if (index == candidates.length) throw desktopError('exhaustedCandidates');
      if (_now + 10 > deadline) throw desktopError('deadline');
      return candidates[index++];
    }

    var node = nextCandidate();
    _automation.status = 'replacing';
    // Validate traffic through the managed replacement itself. Never send a
    // direct-path candidate probe merely because the current path failed.
    // One checkpoint covers the round: a failed candidate is followed by the
    // next, not by a rollback save and a restart of the server that failed.
    await _mutate(
      (candidate) async {
        _checkAutomation(epoch);
        candidate.data['selectedNodeId'] = node;
        return {};
      },
      forceRestart: true,
      refreshAssets: false,
      verifyRuntime: (candidate) async {
        await _automaticHealth(candidate);
        _checkAutomation(epoch);
      },
      next: (error) {
        _checkAutomation(epoch);
        final code = error is PlatformException
            ? error.code
            : 'operation_failed';
        if (_storageLost ||
            {
              'elevation_denied',
              'elevation_failed',
              'listener_unavailable',
              'storage_unavailable',
            }.contains(code))
          return null;
        _automation.cooldown[node] = _now + 60;
        _candidateFailures[node] = code;
        return node = nextCandidate();
      },
    );
    _checkAutomation(epoch);
    _candidateFailures.remove(node);
    _automation.lastSwitch = _now;
    _automation.invalidate();
    _automation.healthy(_now);
    _verifiedHealth = (node: node, at: _now, epoch: _automation.epoch);
    _automation.status = 'selected';
  }

  // Checks the connection once after Connect, then each interval while traffic
  // leaves or the last check failed. Two failures in a row restart the core
  // (see _automationTick).
  Future<void> _livenessTick() async {
    if (_livenessBusy ||
        _disposed ||
        _state != 'connected' ||
        _operation != null ||
        _disconnecting != null ||
        _catalog == null)
      return;
    int? counter(String key) => (_latestMetrics[key] as num?)?.toInt();
    if (_livenessAt != null) {
      if (_now - _livenessAt! < _livenessSeconds) return;
      // The downlink proves nothing: SOCKS replies and direct routes move it
      // while the server is gone.
      final uplink = counter('uplinkBytes');
      final active = uplink != null && uplink > (_livenessUplink ?? 0);
      if (_liveness == 'ok' && !active) {
        _livenessAt = _now;
        _livenessUplink = uplink;
        return;
      }
    }
    _livenessBusy = true;
    final generation = _generation, catalog = _catalog!, runtime = _connectedAt;
    var result = 'noTraffic';
    try {
      for (final target in _livenessTargets) {
        try {
          await _ping(
            {
              ...target,
              'nodeId': catalog.selected,
              'protocol': 'activeProxy',
              'method': 'GET',
              'mode': 'default',
              'timeout': _automationProbeSeconds,
            },
            generation,
            usingCatalog: catalog,
            automatic: true,
          );
          result = 'ok';
          break;
        } on PlatformException {
          // The next target may still answer.
        }
      }
    } finally {
      _livenessBusy = false;
    }
    // A restart during the check reset liveness for the new core.
    if (generation != _generation ||
        _state != 'connected' ||
        _connectedAt != runtime)
      return;
    _liveness = result;
    _livenessFailures = result == 'ok' ? 0 : _livenessFailures + 1;
    if (result == 'ok') _trafficServer = _serverRevision(catalog);
    _livenessAt = _now;
    _livenessUplink = counter('uplinkBytes');
  }

  Future<void> _automationTick() async {
    if (_disposed ||
        _disconnecting != null ||
        _automationBusy ||
        _operation != null ||
        _catalog == null ||
        _storageLost)
      return;
    final enabled = _automationConfig['enabled'] == true;
    // Saved intent alone reconnects the selected server; only failover to
    // other servers needs automation.
    // Without a server every connect fails, so retrying only rewrites storage.
    if (!_automation.intent || _catalog!.selected == null) {
      _automation.status = 'intentRequired';
      return;
    }
    if (_automation.stillSleeping(_now)) {
      _automation.status = 'sleeping';
      return;
    }
    // The core runs, but a server that passed traffic failed two liveness
    // checks in a row. One that never passed (its exit may refuse the check
    // targets) is only reported, so it cannot restart forever.
    final dead =
        _state == 'connected' &&
        _livenessFailures >= 2 &&
        _trafficServer == _serverRevision(_catalog!);
    // A plain session that is up needs no path reads or saves; one that
    // passes traffic again ends its episode.
    if (!enabled &&
        _state == 'connected' &&
        !dead &&
        (_liveness != 'ok' || !_automation.recovering))
      return;
    _automationBusy = true;
    try {
      if (!enabled && _state == 'connected' && !dead) {
        _automation.healthy(_now);
        await _persistAutomation();
        return;
      }
      // Each read costs about a millisecond; a running session needs fewer.
      if (_state != 'connected' || _now - _pathReadAt >= 5) {
        _pathReadAt = _now;
        final path = await _physicalPath();
        _automation.pathChanged(path, path.isNotEmpty, _now);
      }
      if (!_automation.online) {
        _automation.status = 'offline';
        return;
      }
      if (_automation.exhausted) {
        _automation.status = 'exhausted';
        // A daemon allows failover again after the SNI freeze has passed.
        if (unattended && _automation.rearmUnattended(_now))
          await _persistAutomation();
      }
      if (_operation != null) return;
      final epoch = _automation.epoch;
      _checkAutomation(epoch, failover: false);
      if ((_state != 'connected' || dead) && _automation.retryAt == null) {
        _automation.scheduleRetry(_now);
        await _persistAutomation();
        return;
      }
      final retry = _automation.beginRetry(_now);
      if (!retry &&
          (_automation.retryAt != null ||
              _automation.healthAt == null ||
              _now < _automation.healthAt!))
        return;
      if (retry) await _persistAutomation();
      _checkAutomation(epoch, failover: false);
      if (enabled) DesktopAutomation.validate(_automationConfig, _catalog!);
      final policy = _automationConfig['policy']! as String;
      final failover = enabled && policy != 'fixed' && !_automation.exhausted;
      if (_state != 'connected') {
        try {
          await _invoke('connect', {}, automatic: true);
        } on PlatformException catch (error) {
          _checkAutomation(epoch, failover: false);
          if (!failover || error.code != 'connection_failed') rethrow;
          await _recoverAllowed(epoch);
          await _persistAutomation();
          return;
        }
        _checkAutomation(epoch, failover: false);
        // Liveness, or the health check, ends the episode once traffic passes.
        if (!enabled) return;
      } else if (dead) {
        await _restart();
        _automation.healthAt = _now;
        return;
      }
      var healthy = false;
      final done = _operation = Completer<void>();
      try {
        await _automaticHealth(_catalog!);
        healthy = true;
        _automation.healthy(_now);
      } on PlatformException catch (error) {
        if (error.code != 'endpointFailure') rethrow;
        if (!_automation.checkFailed(
          _now,
          retrying: retry,
          recheck: _automationRetrySeconds,
        ))
          return;
      } finally {
        _operation = null;
        done.complete();
      }
      _checkAutomation(epoch, failover: false);
      final current = _catalog!.selected!;
      if (!healthy && failover) {
        await _recoverAllowed(epoch);
        await _persistAutomation();
        return;
      }
      String? chosen = current;
      if (healthy &&
          policy != 'fixed' &&
          (_now - (_automation.lastOptimization ?? -1000) >= 300 &&
              _now - (_automation.lastSwitch ?? -1000) >= 60)) {
        _automation.lastOptimization = _now;
        final order = (_automationConfig['nodeIDs']! as List).cast<String>();
        final scores = <String, double>{};
        final deadline = _now + 60;
        for (final id in _automation.round(order, current, _now)) {
          _checkAutomation(epoch);
          // A measurement holds for the config it was taken with.
          final reference =
              '${_catalog!.node(id)['configurationRevision'] ?? id}';
          final cached = _automation.score(id, reference, _now);
          if (cached != null) {
            scores[id] = cached;
            continue;
          }
          if (_now + 5 >= deadline) continue;
          // The last measurement yielded; a user change may now own the slot.
          if (_operation != null) return;
          final done = _operation = Completer<void>();
          try {
            final samples = <int>[];
            for (var i = 0; i < 3; i++) {
              _checkAutomation(epoch);
              if (_now + 5 >= deadline) throw desktopError('deadline');
              final result = await _ping(
                {
                  ...catalogList(_automationConfig['targets']).first,
                  'nodeId': id,
                  'protocol': 'proxy',
                  'method': 'GET',
                  'mode': 'default',
                  'timeout': _automationProbeSeconds,
                },
                _generation,
                automatic: true,
              );
              samples.add(result['latencyMs']! as int);
            }
            samples.sort();
            _automation.observe(id, true, _russianEntry(id));
            scores[id] = samples[1].toDouble();
            _automation.measurements[id] = (
              score: scores[id]!,
              at: _now,
              epoch: epoch,
              reference: reference,
            );
            _candidateFailures.remove(id);
          } on PlatformException catch (error) {
            _checkAutomation(epoch);
            if (error.code != 'deadline')
              _automation.observe(id, false, _russianEntry(id));
            _automation.cooldown[id] = _now + 60;
            _candidateFailures[id] = error.code;
          } finally {
            _operation = null;
            done.complete();
          }
        }
        _checkAutomation(epoch);
        chosen = _automation.choose(
          policy,
          order,
          current,
          scores,
          healthy,
          _now,
        );
      }
      // Restarting the selected server after failed checks is no failover.
      final switching = chosen != current;
      if ((!healthy || switching) && chosen != null) {
        _automation.status = 'replacing';
        await _mutate(
          (candidate) async {
            _checkAutomation(epoch, failover: switching);
            candidate.data['selectedNodeId'] = chosen;
            return {};
          },
          forceRestart: !healthy,
          verifyRuntime: (candidate) async {
            await _automaticHealth(candidate);
            _checkAutomation(epoch, failover: switching);
          },
        );
        _checkAutomation(epoch, failover: switching);
        _automation.lastSwitch = _now;
        _automation.invalidate();
        _automation.healthy(_now);
        _verifiedHealth = (node: chosen, at: _now, epoch: _automation.epoch);
        _automation.status = 'selected';
      } else if (!healthy) {
        throw desktopError('unavailableProbePath');
      }
      await _persistAutomation();
    } on PlatformException catch (error) {
      // Another operation held the controller; that is no failed attempt.
      if (_disposed ||
          !_automation.intent ||
          _automation.sleeping ||
          {'cancelled', 'busy'}.contains(error.code))
        return;
      _automation.status = error.code;
      if ([
        'invalidTarget',
        'indeterminate',
        'invalid_automation',
      ].contains(error.code)) {
        _automation.healthAt = _now + 30;
      } else {
        _automation.scheduleRetry(_now);
      }
      if (_operation == null && !_storageLost) {
        try {
          await _persistAutomation();
        } on Object {
          _automation.status = 'storage_unavailable';
        }
      }
    } on Object {
      _automation.status = 'waitingForPath';
    } finally {
      _automationBusy = false;
    }
  }
}
