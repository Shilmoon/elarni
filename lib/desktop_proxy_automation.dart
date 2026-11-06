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
          await candidate.refreshManaged(route['id']! as String);
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
      _wifi = _wifiStatus = null;
      return;
    }
    if (_wifiBusy || _disposed || _storageLost) return;
    _wifiBusy = true;
    try {
      final reading = await _wifiNetwork();
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
    if (_operation != null) throw desktopError('busy');
    final done = _operation = Completer<void>();
    final generation = _generation;
    final candidate = _catalog!.copy();
    try {
      if (candidate.data.containsKey('automationEpisode') ||
          _automation.attempts > 0 ||
          _automation.exhausted ||
          _automation.retryAt != null)
        candidate.data['automationEpisode'] = _automation.episode;
      if (candidate.data.containsKey('connectionIntent') || _automation.intent)
        candidate.data['connectionIntent'] = _automation.intent;
      if (jsonEncode(candidate.data) == jsonEncode(_catalog!.data)) return;
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

  void _checkAutomation(int epoch) {
    if (!_disposed &&
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
        _automation.exhausted) {
      throw desktopError('cancelled');
    }
  }

  Future<void> _automaticHealth(DesktopCatalog catalog) async {
    var qualifying = 0;
    var invalidTarget = false;
    final targets = catalogList(_automationConfig['targets']);
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

  Future<void> _replaceAutomatic(String node, int epoch) async {
    _checkAutomation(epoch);
    _automation.status = 'replacing';
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
    );
    _checkAutomation(epoch);
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
    for (final node in candidates) {
      _checkAutomation(epoch);
      if (_now + 10 > deadline) throw desktopError('deadline');
      try {
        // Validate traffic through the managed replacement itself. Never send
        // a direct-path candidate probe merely because the current path failed.
        await _replaceAutomatic(node, epoch);
        _candidateFailures.remove(node);
        _automation.lastSwitch = _now;
        _automation.invalidate();
        _automation.healthy(_now);
        _verifiedHealth = (node: node, at: _now, epoch: _automation.epoch);
        _automation.status = 'selected';
        return;
      } on PlatformException catch (error) {
        _checkAutomation(epoch);
        if (_storageLost ||
            {
              'rollback_failed',
              'elevation_denied',
              'elevation_failed',
              'listener_unavailable',
              'storage_unavailable',
            }.contains(error.code))
          rethrow;
        _automation.cooldown[node] = _now + 60;
        _candidateFailures[node] = error.code;
      }
    }
    throw desktopError('exhaustedCandidates');
  }

  // Checks the connection once after Connect, then each interval while traffic
  // leaves or the last check failed. Recovery stays with failover; this only
  // reports.
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
    final generation = _generation, catalog = _catalog!;
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
    if (generation != _generation || _state != 'connected') return;
    _liveness = result;
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
    // A daemon resumes saved intent after a restart even without failover.
    if (!enabled && !_catalog!.settings.onDemandEnabled && !unattended) {
      _automation.status = 'disabled';
      return;
    }
    // Without a server every connect fails, so retrying only rewrites storage.
    if (!_automation.intent || _catalog!.selected == null) {
      _automation.status = 'intentRequired';
      return;
    }
    if (_automation.sleeping) {
      _automation.status = 'sleeping';
      return;
    }
    _automationBusy = true;
    try {
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
      _automation.pathChanged(paths.join('|'), paths.isNotEmpty, _now);
      if (!_automation.online) {
        _automation.status = 'offline';
        return;
      }
      if (_automation.exhausted) {
        _automation.status = 'exhausted';
        if (!unattended) return;
        if (!_automation.rearmUnattended(_now)) return;
        await _persistAutomation();
      }
      if (_operation != null) return;
      final epoch = _automation.epoch;
      _checkAutomation(epoch);
      if (enabled) DesktopAutomation.validate(_automationConfig, _catalog!);
      if (_state != 'connected' && _automation.retryAt == null) {
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
      _checkAutomation(epoch);
      if (_state != 'connected') {
        try {
          await _invoke('connect', {}, automatic: true);
        } on PlatformException catch (error) {
          _checkAutomation(epoch);
          if (!enabled ||
              _automationConfig['policy'] == 'fixed' ||
              error.code != 'connection_failed')
            rethrow;
          await _recoverAllowed(epoch);
          await _persistAutomation();
          return;
        }
        _checkAutomation(epoch);
      }
      if (!enabled) {
        _automation.healthy(_now);
        await _persistAutomation();
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
        _automation.failures++;
        if (_automation.failures < 3 && !retry) {
          _automation.healthAt = _now + _automationRetrySeconds;
          _automation.status = 'healthFailure';
          return;
        }
      } finally {
        _operation = null;
        done.complete();
      }
      _checkAutomation(epoch);
      final policy = _automationConfig['policy']! as String;
      final current = _catalog!.selected!;
      if (!healthy && policy != 'fixed') {
        await _recoverAllowed(epoch);
        await _persistAutomation();
        return;
      }
      String? chosen = current;
      if (policy != 'fixed' &&
          (_now - (_automation.lastOptimization ?? -1000) >= 300 &&
              _now - (_automation.lastSwitch ?? -1000) >= 60)) {
        _automation.lastOptimization = _now;
        final order = (_automationConfig['nodeIDs']! as List).cast<String>();
        final scores = <String, double>{};
        final deadline = _now + 60;
        for (final id in _automation.round(order, current, _now)) {
          _checkAutomation(epoch);
          final reference = await _compile(_catalog!, _catalog!.node(id));
          final cached = _automation.score(id, reference, _now);
          if (cached != null) {
            scores[id] = cached;
            continue;
          }
          if (_now + 5 >= deadline) continue;
          // The compile above yielded; a user change may now own the slot.
          _checkAutomation(epoch);
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
      if ((!healthy || chosen != current) && chosen != null) {
        _automation.status = 'replacing';
        await _mutate(
          (candidate) async {
            _checkAutomation(epoch);
            candidate.data['selectedNodeId'] = chosen;
            return {};
          },
          forceRestart: !healthy,
          verifyRuntime: (candidate) async {
            await _automaticHealth(candidate);
            _checkAutomation(epoch);
          },
        );
        _checkAutomation(epoch);
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
      if (_disposed ||
          !_automation.intent ||
          _automation.sleeping ||
          error.code == 'cancelled')
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
