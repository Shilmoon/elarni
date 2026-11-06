part of 'elarni_app.dart';

extension _HomeController on _ElarniHomeState {
  Future<void> _load({bool pingOnLoad = false}) async {
    await Future.wait(<Future<void>>[
      _refreshState(),
      _refreshSubscriptions(),
      _refreshRouting(),
      _refreshSettings(),
      _refreshSystemInfo(),
      _refreshAutomation(),
    ]);
    if (mounted && pingOnLoad)
      await _pingAllNodes(report: false, only: _openServerIds());
  }

  void _recordIssue(ConnectionIssue issue) {
    _message = issue.description;
    if (_recentIssues.isEmpty || _recentIssues.last.code != issue.code) {
      _recentIssues.add(issue);
      if (_recentIssues.length > 8) _recentIssues.removeAt(0);
    }
  }

  Future<void> _refreshAutomation() async {
    final revision = _stateRevision;
    try {
      final value = await widget.tunnelControl.automationStatus();
      if (!mounted || revision != _stateRevision) return;
      final changed = value['status'] != _automation['status'];
      // The age grows every poll; the page shows only whether it is under 90 s.
      Map<String, Object?> shown(Map<String, Object?> status) => {
        ...status,
        'healthAgeSeconds': switch (status['healthAgeSeconds']) {
          final num age => age < 90,
          _ => null,
        },
      };
      if (!_sameJson(shown(value), shown(_automation)))
        _set(() => _automation = value);
      if (changed && value['status'] == 'selected')
        await _refreshSubscriptions();
    } on Object {
      // Failure to read recovery settings is not proof of connection failure.
      if (mounted && revision == _stateRevision) _set(() => _automation = {});
    }
  }

  Future<void> _configureRecovery() async {
    await _refreshAutomation();
    final node = _selectedNode;
    if (!mounted || node == null) return;
    await _showEditorDialog<void>(
      context: context,
      builder: (context) => ConnectionRecoveryDialog(
        groups: _subscriptions.subscriptions,
        selectedId: node.id,
        snapshot: _automation,
        save: (configuration) async {
          final result = await widget.tunnelControl.configureAutomation(
            configuration,
          );
          if (mounted) _set(() => _automation = result);
        },
      ),
    );
  }

  Future<void> _checkConnection() async {
    final node = _selectedNode;
    if (_busy ||
        node == null ||
        !_stateAvailable ||
        _state != TunnelState.connected ||
        (_health == 'checking' && _healthNodeId == node.id))
      return;
    final run = ++_healthRun;
    _set(() {
      _health = 'checking';
      _healthNodeId = node.id;
      _healthRevision = node.revision;
      _healthAt = null;
    });
    try {
      final result = await widget.tunnelControl.pingNode(
        node.id,
        protocol: 'activeProxy',
        method: 'GET',
        mode: 'default',
        timeout: _pingTimeout,
        url: _pingURL.text.trim(),
        expectedStatus: _expectedStatus,
        expectedBody: _pingExpectedBody.text,
      );
      if (mounted &&
          run == _healthRun &&
          _selectedNode?.id == node.id &&
          _selectedNode?.revision == node.revision &&
          _stateAvailable &&
          _state == TunnelState.connected) {
        _set(() {
          final compatible =
              result.nodeId == node.id &&
              (result.configurationRevision == null ||
                  result.configurationRevision == node.revision);
          _health = compatible
              ? (result.status == 'success' ? 'passed' : 'failed')
              : 'unknown';
          _healthAt = compatible
              ? DateTime.fromMillisecondsSinceEpoch(
                  (result.timestamp * 1000).round(),
                )
              : null;
        });
      }
    } on Object catch (error) {
      if (mounted && run == _healthRun)
        _set(() {
          final unavailable =
              error is PlatformException &&
              error.code == 'automation_unsupportedPolicy';
          _health = unavailable ? 'unavailable' : 'failed';
          _healthAt = unavailable ? null : DateTime.now();
          _recordIssue(ConnectionIssue.from(error));
        });
    }
  }

  Future<void> _exportDiagnostics() async {
    try {
      await widget.tunnelControl.exportEvidence(
        issueCodes: _recentIssues.map((issue) => issue.code).toList(),
      );
    } on Object catch (error) {
      if (error is PlatformException &&
          const {'cancelled', 'operation_cancelled'}.contains(error.code))
        return;
      if (mounted)
        _set(
          () => _recordIssue(
            ConnectionIssue(
              'export_failed',
              l10n.diagnosticsNotSaved,
              l10n.chooseWritableLocation,
            ),
          ),
        );
    }
  }

  // The log view saves its level; reload so a later settings save keeps it.
  Future<void> _openLogs() async {
    await showLogsDialog(context, widget.tunnelControl);
    if (mounted) await _refreshSettings();
  }

  Future<void> _markRecording() async {
    try {
      await widget.tunnelControl.markRecording();
      final now = DateTime.now();
      final time = [
        now.hour,
        now.minute,
        now.second,
      ].map((part) => '$part'.padLeft(2, '0')).join(':');
      if (mounted) _set(() => _message = l10n.problemMarkedAt(time));
    } on Object {
      if (mounted) _set(() => _message = l10n.markNotSaved);
    }
  }

  Future<void> _exportRecording() async {
    try {
      await widget.tunnelControl.exportRecording();
      if (mounted) _set(() => _message = l10n.recordingSaved);
    } on Object catch (error) {
      final code = error is PlatformException ? error.code : '';
      if (const {'cancelled', 'operation_cancelled'}.contains(code)) return;
      if (mounted)
        _set(
          () => _message = code == 'recording_empty'
              ? l10n.recordingEmpty
              : l10n.recordingNotSaved,
        );
    }
  }

  Future<void> _refreshSettings() async {
    try {
      final value = await widget.tunnelControl.tunnelSettings();
      if (mounted) {
        _set(() {
          _settings = value;
          _settingsLoaded = true;
        });
        _configureMonitoring();
        await _loadInboundLogin();
      }
    } on Object {
      if (mounted) {
        _set(() => _message = l10n.tunnelSettingsNotLoaded);
      }
    }
  }

  Future<void> _loadInboundLogin() async {
    var value = const <String, String>{};
    if (_settings.inboundCredentialsConfigured) {
      try {
        value = await widget.tunnelControl.inboundCredentials();
      } on Object {
        // The row then offers Set; saving new credentials still works.
      }
    }
    if (mounted && !mapEquals(value, _inboundLogin))
      _set(() => _inboundLogin = value);
  }

  // Only Windows and Linux have a local-proxy mode; with the VPN on, the
  // listeners always need a login.
  bool get _openLocalProxy =>
      widget.desktopCore &&
      _settingsLoaded &&
      !_settings.xrayTunEnabled &&
      !_settings.inboundAuthEnabled;

  // Only while it blocks: the connection failed and the guard, or on macOS
  // Include all networks, keeps traffic from leaving outside the tunnel.
  bool get _blockingWithoutVPN =>
      _stateAvailable &&
      _state == TunnelState.failed &&
      (widget.desktopCore
          ? _settings.xrayTunEnabled && _settings.blockWithoutVPN
          : _settings.includeAllNetworks);

  Future<void> _allowAppsWithoutLogin() async {
    final ports = _settings.httpInboundEnabled
        ? l10n.portsPair(_settings.socksPort, _settings.httpPort)
        : l10n.portSingle(_settings.socksPort);
    final allow = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.allowAppsWithoutLogin),
        content: Text(l10n.allowWithoutLoginBody(ports)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.allowWithoutLogin),
          ),
        ],
      ),
    );
    if (allow == true && mounted)
      await _saveSettings(
        _settings.copyWith(inboundAuthEnabled: false, allowLAN: false),
      );
  }

  // Without a saved login, a random one is generated, as on a fresh install.
  Future<void> _requireLogin() async {
    if (_settings.inboundCredentialsConfigured) {
      await _saveSettings(_settings.copyWith(inboundAuthEnabled: true));
      return;
    }
    final random = Random.secure();
    String token() => [
      for (var i = 0; i < 16; i++)
        random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
    await _saveInboundCredentials(token(), token());
  }

  Future<void> _refreshSystemInfo({
    bool? launchAtLogin,
    bool? vpnService,
  }) async {
    if (_systemBusy) return;
    _set(() {
      _systemBusy = true;
      _systemError = null;
    });
    try {
      final value = vpnService != null
          ? {
              ..._systemInfo,
              ...await widget.tunnelControl.setVPNService(vpnService),
            }
          : launchAtLogin == null
          ? await widget.tunnelControl.systemInfo()
          : await widget.tunnelControl.setLaunchAtLogin(launchAtLogin);
      if (mounted) {
        _set(() => _systemInfo = value);
        final version = value['appVersion'];
        widget.desktop.appVersion = version is String ? version : null;
      }
    } on PlatformException catch (error) {
      if (mounted)
        _set(() {
          _systemError = error.message ?? l10n.systemSettingsNotLoaded;
          if (error.details is Map) {
            _systemInfo = Map<String, Object?>.from(error.details as Map);
          }
        });
    } on Object {
      if (mounted) _set(() => _systemError = l10n.systemInfoUnavailable);
    } finally {
      if (mounted) _set(() => _systemBusy = false);
    }
  }

  Future<void> _refreshRouteTable() async {
    if (_routesBusy) return;
    _set(() {
      _routesBusy = true;
      _routesError = null;
    });
    try {
      final value = await widget.tunnelControl.routeTable();
      if (mounted) _set(() => _routeTable = value['table'] as String?);
    } on Object {
      if (mounted) _set(() => _routesError = l10n.routeTableUnreadable);
    } finally {
      if (mounted) _set(() => _routesBusy = false);
    }
  }

  Future<void> _saveDesktop({
    ThemeMode? theme,
    String? accent,
    String? language,
    String? sort,
    Set<String>? pinned,
    bool? expiryReminders,
    bool? favoritesFirst,
  }) async {
    try {
      await widget.desktop.update(
        theme: theme,
        accent: accent,
        language: language,
        sort: sort,
        pinned: pinned,
        expiryReminders: expiryReminders,
        favoritesFirst: favoritesFirst,
      );
    } on Object {
      /* The desktop owner publishes its fixed error beside the controls. */
    }
  }

  Future<void> _pingNode(String nodeId) async {
    if (_pingControlsDisabled) return;
    if (_pingProtocol == 'icmp' && !await _confirmICMP()) return;
    if (!mounted || _pingControlsDisabled) return;
    final exclusive = _pingProtocol == 'icmp';
    _set(() {
      if (exclusive) _busy = true;
      _pinging = true;
      _pingPending.add(nodeId);
      _message = null;
      _pingResults.remove(nodeId);
      _pingUnavailable.remove(nodeId);
      _pingSkipped.remove(nodeId);
    });
    final run = ++_pingRun;
    try {
      final result = await _measureNode(nodeId);
      if (mounted && run == _pingRun) {
        _set(() {
          _pingResults[nodeId] = result;
          _pingUnavailable.remove(nodeId);
        });
      }
    } on PlatformException catch (error) {
      if (mounted && run == _pingRun) {
        _set(() {
          if (_skippedProbe(error)) {
            _pingSkipped.add(nodeId);
          } else {
            _pingUnavailable.add(nodeId);
          }
          _message = switch (error.code) {
            'unsupported_ping_method' => l10n.pingDirectTcpUnsupported,
            'disconnect_to_test' => l10n.pingNeedsDisconnect,
            'unavailableProbePath' => l10n.pingIcmpUnavailable,
            'icmp_failed_restored' => l10n.pingIcmpNoReplyRestored,
            'icmp_restore_failed' => l10n.pingIcmpRestoreFailed,
            _ => l10n.pingFailedForNode,
          };
        });
      }
    } on Object {
      if (mounted && run == _pingRun) {
        _set(() {
          _pingUnavailable.add(nodeId);
          _message = l10n.pingFailedForNode;
        });
      }
    } finally {
      if (exclusive) await _refreshState();
      if (mounted) {
        _set(() {
          _pingPending.remove(nodeId);
          _pinging = false;
          if (exclusive) _busy = false;
        });
        _pingQueuedServers();
      }
    }
  }

  // macOS refuses what its tunnel would answer itself while connected.
  bool _skippedProbe(Object error) =>
      error is PlatformException &&
      const {
        'unsupported_ping_method',
        'disconnect_to_test',
      }.contains(error.code);

  // The core accepts only a successful status, so a cleared or bad field
  // falls back to the default check instead of failing every server.
  int get _expectedStatus {
    final status = int.tryParse(_pingExpectedStatus.text.trim());
    return status != null && status >= 200 && status <= 299 ? status : 204;
  }

  Future<PingResult> _measureNode(String nodeId, {int? timeout}) async {
    final node = _findNode(nodeId);
    if (node == null) throw PlatformException(code: 'stale_probe');
    final protocol = _pingProtocol;
    final result = await widget.tunnelControl.pingNode(
      nodeId,
      protocol: _pingProtocol,
      method: _pingMethod,
      mode: _pingMode,
      timeout: timeout ?? _pingTimeout,
      url: _pingURL.text.trim(),
      expectedStatus: _expectedStatus,
      expectedBody: _pingExpectedBody.text,
    );
    if (_findNode(nodeId)?.revision != node.revision ||
        result.nodeId != nodeId ||
        (result.configurationRevision != null &&
            result.configurationRevision != node.revision))
      throw PlatformException(code: 'stale_probe');
    return PingResult(
      nodeId: nodeId,
      status: result.status,
      latencyMs: result.latencyMs,
      timestamp: result.timestamp,
      configurationRevision: node.revision,
      protocol: result.protocol ?? protocol,
    );
  }

  SubscriptionNode? _findNode(String id) {
    if (!identical(_indexedSubscriptions, _subscriptions)) {
      final nodes = <String, SubscriptionNode>{};
      for (final group in _subscriptions.subscriptions)
        for (final node in group.nodes) nodes.putIfAbsent(node.id, () => node);
      _indexedSubscriptions = _subscriptions;
      _nodesById = nodes;
    }
    return _nodesById[id];
  }

  bool _probeFresh(PingResult result) {
    final age = DateTime.now().millisecondsSinceEpoch / 1000 - result.timestamp;
    return age >= 0 &&
        age < 300 &&
        _findNode(result.nodeId)?.revision == result.configurationRevision;
  }

  /// Whether a server's result is older than five minutes, or it has none and was not just tried.
  bool _pingStale(String id) {
    if (_pingPending.contains(id)) return false;
    final result = _pingResults[id];
    if (result != null) return !_probeFresh(result);
    final tried = _pingTriedAt[id];
    return tried == null ||
        DateTime.now().millisecondsSinceEpoch / 1000 - tried >= 300;
  }

  /// Opening a group tests its stale servers, after any test already running.
  void _pingOpened(Iterable<SubscriptionNode> nodes) {
    final stale = [
      for (final node in nodes)
        if (node.isVPN && _pingStale(node.id)) node.id,
    ];
    if (stale.isEmpty) return;
    if (_pingControlsDisabled) {
      _pingQueued.addAll(stale);
    } else {
      unawaited(_pingAllNodes(report: false, only: stale));
    }
  }

  void _pingQueuedServers() {
    if (_pingControlsDisabled || _pingQueued.isEmpty) return;
    final stale = _pingQueued.where(_pingStale).toList();
    _pingQueued.clear();
    if (stale.isNotEmpty) unawaited(_pingAllNodes(report: false, only: stale));
  }

  Future<void> _pingAllNodes({
    bool report = true,
    String? subscriptionId,
    Iterable<String>? only,
  }) async {
    if (_pingControlsDisabled || _pingProtocol == 'icmp') return;
    final wanted = only?.toSet();
    final nodeIds = <String>[
      for (final group in _subscriptions.subscriptions)
        if (subscriptionId == null || group.id == subscriptionId)
          for (final node in group.nodes.where((node) => node.isVPN))
            if (wanted == null || wanted.contains(node.id)) node.id,
    ];
    if (nodeIds.isEmpty) return;
    final run = ++_pingRun;
    final now = DateTime.now().millisecondsSinceEpoch / 1000;
    _set(() {
      _pinging = true;
      if (report) _message = null;
      for (final id in nodeIds) {
        _pingTriedAt[id] = now;
      }
      if (subscriptionId == null && wanted == null) {
        _pingResults.clear();
        _pingUnavailable.clear();
        _pingSkipped.clear();
      } else {
        for (final id in nodeIds) {
          _pingResults.remove(id);
          _pingUnavailable.remove(id);
          _pingSkipped.remove(id);
        }
      }
      _pingPending.addAll(nodeIds);
    });
    // TSPU freezes an SNI after more than 3 near-simultaneous handshakes, so
    // at most two probes share one at a time.
    final queues = <String, List<String>>{};
    for (final id in nodeIds) {
      (queues[_findNode(id)?.probeKey ?? id] ??= []).add(id);
    }
    final busy = <String, int>{};
    var needsDisconnect = false;
    Completer<void>? freed;
    Future<void> worker() async {
      while (mounted && run == _pingRun && queues.isNotEmpty) {
        String? key;
        for (final candidate in queues.keys) {
          if ((busy[candidate] ?? 0) < 2) {
            key = candidate;
            break;
          }
        }
        if (key == null) {
          await (freed ??= Completer<void>()).future;
          continue;
        }
        final waiting = queues[key]!;
        final nodeId = waiting.removeAt(0);
        if (waiting.isEmpty) queues.remove(key);
        busy[key] = (busy[key] ?? 0) + 1;
        try {
          final result = await _measureNode(
            nodeId,
            timeout: _pingTimeout.clamp(5, 7),
          ).timeout(const Duration(seconds: 7));
          if (mounted && run == _pingRun) {
            _set(() {
              _pingResults[nodeId] = result;
            });
          }
        } on Object catch (error) {
          if (mounted && run == _pingRun) {
            _set(() {
              if (_skippedProbe(error)) {
                _pingSkipped.add(nodeId);
                needsDisconnect |=
                    (error as PlatformException).code == 'disconnect_to_test';
              } else {
                _pingUnavailable.add(nodeId);
              }
            });
          }
        } finally {
          busy[key] = busy[key]! - 1;
          final released = freed;
          freed = null;
          released?.complete();
          if (mounted && run == _pingRun) {
            _set(() => _pingPending.remove(nodeId));
          }
        }
        // Let input and result frames run before preparing another node.
        await Future<void>.delayed(Duration.zero);
      }
    }

    try {
      // While the Linux VPN runs, its root probe service starts 8 probe cores at
      // a time; probes queued behind them would run out their 7 s bound.
      final width =
          widget.linux &&
              _settings.xrayTunEnabled &&
              !{TunnelState.disconnected, TunnelState.prepared}.contains(_state)
          ? 8
          : 32;
      await Future.wait(
        List.generate(nodeIds.length.clamp(0, width), (_) => worker()),
      );
      if (mounted && run == _pingRun) {
        _set(() {
          _pingUnavailable.addAll(
            nodeIds.where(
              (id) =>
                  !_pingResults.containsKey(id) && !_pingSkipped.contains(id),
            ),
          );
          if (report) {
            final tested = nodeIds.where(_pingResults.containsKey).length;
            final skipped = nodeIds.where(_pingSkipped.contains).length;
            _message = [
              l10n.pingTested(tested, nodeIds.length - skipped),
              if (skipped != 0)
                needsDisconnect
                    ? l10n.pingSkippedWhileConnected(skipped)
                    : l10n.pingSkippedIncompatible(skipped),
            ].join(' ');
          }
        });
      }
    } finally {
      if (mounted) {
        _set(() => _pinging = false);
        _pingQueuedServers();
      }
    }
  }

  /// Where a server reaches the internet, from Cloudflare's trace through it.
  Future<void> _checkExit(SubscriptionNode node) async {
    if (_busy || _exitPending.contains(node.id)) return;
    _set(() {
      _exitPending.add(node.id);
      _exitResults.remove(node.id);
      _exitFailed.remove(node.id);
    });
    try {
      final result = await widget.tunnelControl.pingNode(
        node.id,
        protocol: 'proxy',
        method: 'GET',
        mode: 'default',
        timeout: _pingTimeout,
        url: 'https://cp.cloudflare.com/cdn-cgi/trace',
        expectedStatus: 200,
        trace: true,
      );
      if (!mounted) return;
      _set(() {
        if (result.status == 'success' &&
            result.exitCountry != null &&
            _findNode(node.id)?.revision == node.revision) {
          _exitResults[node.id] = PingResult(
            nodeId: node.id,
            status: result.status,
            latencyMs: result.latencyMs,
            timestamp: result.timestamp,
            configurationRevision: node.revision,
            exitIP: result.exitIP,
            exitCountry: result.exitCountry,
          );
        } else {
          _exitFailed.add(node.id);
        }
      });
    } on Object {
      if (mounted) _set(() => _exitFailed.add(node.id));
    } finally {
      if (mounted) _set(() => _exitPending.remove(node.id));
    }
  }

  Future<bool> _saveSettings(TunnelSettings value) async {
    if (!_settingsLoaded) {
      // The change was made on defaults; show the stored settings instead.
      await _refreshSettings();
      if (mounted && _settingsLoaded)
        _set(() => _message = l10n.settingsReloaded);
      return false;
    }
    _set(() {
      _busy = true;
      _message = null;
    });
    try {
      final saved = await widget.tunnelControl.updateTunnelSettings(value);
      if (mounted) {
        _set(() => _settings = saved);
        _configureMonitoring();
      }
      await _refreshState();
      return true;
    } on Object catch (error) {
      if (mounted) {
        final issue = ConnectionIssue.from(error);
        _set(
          () => _message =
              error is PlatformException && error.code == 'listener_unavailable'
              ? error.message
              : issue.code == 'operation_failed'
              ? l10n.settingNotAppliedCheck
              : l10n.settingNotApplied(issue.description),
        );
      }
      await _refreshSettings();
      return false;
    } finally {
      if (mounted) _set(() => _busy = false);
    }
  }

  void _configureMonitoring() {
    _monitorTimer?.cancel();
    if (!_settings.monitoringEnabled) {
      _set(() => _metrics = const <String, Object?>{});
      return;
    }
    _refreshMetrics();
    _monitorTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _refreshMetrics(),
    );
  }

  Future<void> _refreshMetrics() async {
    if (_metricsLoading) return;
    _metricsLoading = true;
    Map<String, Object?> value;
    try {
      value = await widget.tunnelControl.runtimeMetrics();
    } on Object {
      value = const <String, Object?>{};
    } finally {
      _metricsLoading = false;
    }
    if (!mounted || !_settings.monitoringEnabled) return;
    if (!mapEquals(_metrics['counters'] as Map?, value['counters'] as Map?) ||
        !mapEquals(
          {..._metrics}..remove('counters'),
          {...value}..remove('counters'),
        )) {
      _set(() => _metrics = value);
    }
  }

  Future<void> _toggleHideVPNIcon(bool enabled) async {
    if (enabled) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l10n.hideVpnIconQuestion),
          content: Text(l10n.hideVpnIconBody),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(l10n.continueAction),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    if (mounted)
      _set(
        () => _perAppDraft!.settings = _perAppDraft!.settings.copyWith(
          hideVPNIcon: enabled,
        ),
      );
  }

  Future<void> _refreshSubscriptions() async {
    try {
      final value = await widget.tunnelControl.subscriptions();
      _subscriptionsLoaded = true;
      // An unchanged periodic snapshot must not rebuild every server row.
      if (mounted &&
          (value.signature == null ||
              value.signature != _subscriptions.signature))
        _set(() => _applySnapshot(value));
    } on Object {
      _subscriptionsLoaded = false;
      if (mounted) {
        _set(() => _message = l10n.subscriptionsNotLoaded);
      }
    }
  }

  void _applySnapshot(SubscriptionSnapshot value) {
    final oldNodes = {
      for (final group in _subscriptions.subscriptions)
        for (final node in group.nodes) node.id: node.revision,
    };
    final newNodes = {
      for (final group in value.subscriptions)
        for (final node in group.nodes) node.id: node.revision,
    };
    final changed = oldNodes.entries.any(
      (entry) => newNodes[entry.key] != entry.value,
    );
    if (changed) {
      _pingRun++;
      _pingPending.clear();
      _pingUnavailable.removeWhere((id) => oldNodes[id] != newNodes[id]);
      _pingSkipped.removeWhere((id) => oldNodes[id] != newNodes[id]);
    }
    _pingResults.removeWhere(
      (id, result) => newNodes[id] != result.configurationRevision,
    );
    // A later successful download, such as a scheduled one, ends the failure.
    final fetched = {
      for (final group in _subscriptions.subscriptions)
        group.id: group.lastSuccessfulFetch ?? 0,
    };
    _failedRefreshes.removeWhere((id, _) {
      final group = value.subscriptions.where((g) => g.id == id).firstOrNull;
      return group == null ||
          (group.lastSuccessfulFetch ?? 0) > (fetched[id] ?? 0);
    });
    _subscriptions = value;
    if (_healthRevision != _selectedNode?.revision) {
      _healthRun++;
      _health = 'unknown';
      _healthAt = null;
    }
  }

  Future<void> _toggleFavorite(SubscriptionNode node) async {
    try {
      final snapshot = await widget.tunnelControl.setNodeFavorite(
        node.id,
        !node.favorite,
      );
      if (mounted) _set(() => _applySnapshot(snapshot));
    } on Object {
      if (mounted) _set(() => _message = l10n.favoriteNotSaved);
    }
  }

  Future<void> _repairTunnel() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.repairVpnSetupQuestion),
        content: Text(
          widget.desktopCore
              ? l10n.repairVpnDesktopBody
              : l10n.repairVpnMacBody,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.repair),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || _busy) return;
    _set(() => _busy = true);
    try {
      await widget.tunnelControl.repairTunnel();
      await _refreshState();
      if (mounted) _set(() => _message = l10n.vpnSetupReset);
    } on Object {
      if (mounted) _set(() => _message = l10n.vpnSetupNotRepaired);
    } finally {
      if (mounted) _set(() => _busy = false);
    }
  }

  Future<void> _refreshSubscription(String id, {String? format}) async {
    _set(() => _busy = true);
    try {
      final completed = await _applySubscriptionOperation(
        await widget.tunnelControl.refreshSubscription(id, format: format),
        format: format,
      );
      if (mounted && completed) _set(() => _failedRefreshes.remove(id));
      await _refreshState();
    } on Object catch (error) {
      if (mounted) {
        _set(() {
          // Another operation holding the backend is not a failed download.
          if (error is PlatformException && error.code == 'busy') {
            _message = l10n.issueBusy;
            return;
          }
          final code = error is PlatformException ? error.code : '';
          _failedRefreshes[id] = code;
          final group = _subscriptions.subscriptions
              .where((group) => group.id == id)
              .firstOrNull;
          final message =
              '${group == null ? l10n.refreshFailedSentence : _refreshFailure(group, code)} '
              '${l10n.lastWorkingServersKept}';
          _message = message;
          if (group != null &&
              _HomePages._providerFaults.contains(code) &&
              group.actions.contains('support'))
            _messageAction = (
              message: message,
              label: l10n.contactProvider,
              onPressed: () => _openProviderLink(id, 'support'),
            );
        });
      }
    } finally {
      if (mounted) _set(() => _busy = false);
    }
  }

  Future<bool> _applySubscriptionOperation(
    SubscriptionOperationResult operation, {
    String? format,
  }) async {
    var current = operation;
    while (true) {
      if (!mounted) return false;
      _set(() => _applySnapshot(current.snapshot));
      final warning = current.warning;
      if (warning == null) return true;
      final approved = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l10n.approveUnsafeSubscription),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: warning.risks
                .map((risk) => Text(_riskMessage(risk)))
                .toList(growable: false),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(l10n.continueAction),
            ),
          ],
        ),
      );
      if (approved != true) return false;
      current = await widget.tunnelControl.refreshSubscription(
        warning.subscriptionId,
        challenge: warning.challenge,
        format: format,
      );
    }
  }

  Future<void> _openProviderLink(String id, String action) async {
    try {
      await widget.tunnelControl.openProviderLink(id, action);
    } on Object {
      if (mounted) _set(() => _message = l10n.providerLinkNotOpened);
    }
  }

  Future<void> _openUpdateLink(String url) async {
    try {
      await widget.tunnelControl.openUpdateLink(url);
    } on Object {
      if (mounted) _set(() => _message = l10n.downloadPageNotOpened);
    }
  }

  Future<void> _importProfiles(String source) async {
    if (_busy) return;
    _set(() {
      _busy = _importing = true;
      _message = null;
    });
    final previousSubscriptions = {
      for (final group in _subscriptions.subscriptions) group.id,
    };
    try {
      final previousRouting = _routing.profiles
          .map((profile) => profile.id)
          .toSet();
      final clipboard = source == 'clipboard'
          ? (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim()
          : null;
      if (!mounted) return;
      if (source == 'clipboard' && (clipboard == null || clipboard.isEmpty)) {
        _set(() => _message = l10n.clipboardEmpty);
        return;
      }
      final result = await widget.tunnelControl.importClientProfiles(
        source: source == 'clipboard' ? 'text' : source,
        content: clipboard,
      );
      if (await _applySubscriptionOperation(result)) {
        await _refreshRouting();
        if (mounted)
          _set(() {
            _routingTab = 0;
            _page =
                _routing.profiles.any(
                  (profile) => !previousRouting.contains(profile.id),
                )
                ? DesktopPage.routing
                : DesktopPage.home;
          });
      }
    } on Object catch (error) {
      if (mounted &&
          !(error is PlatformException &&
              const {
                'cancelled',
                'operation_cancelled',
              }.contains(error.code))) {
        // A new subscription stays saved when its first download fails.
        await _refreshSubscriptions();
        if (!mounted) return;
        final added = _subscriptions.subscriptions.any(
          (group) => !previousSubscriptions.contains(group.id),
        );
        final message = switch (error) {
          _ when added => l10n.subscriptionAddedFirstDownloadFailed,
          PlatformException(code: 'unsupported_profile') =>
            l10n.unsupportedProfileTryJson,
          PlatformException(code: 'catalog_limit') => l10n.catalogLimit,
          PlatformException(code: 'no_selected_subscription') =>
            l10n.selectServerFirstRoutingLink,
          _ => l10n.couldNotImport,
        };
        _set(() => _message = message);
      }
    } finally {
      if (mounted) _set(() => _busy = _importing = false);
    }
  }

  Future<void> _openTelegram(String id) async {
    try {
      await widget.tunnelControl.openTelegramProxy(id);
    } on Object {
      if (mounted) _set(() => _message = l10n.telegramNotOpened);
    }
  }

  Future<void> _setNodeIPPreference(String nodeID, String? preference) async {
    _set(() => _busy = true);
    try {
      await _applySubscriptionOperation(
        await widget.tunnelControl.setNodeIPPreference(nodeID, preference),
      );
      await _refreshState();
    } on Object {
      await _refreshSubscriptions();
      if (mounted) _set(() => _message = l10n.serverIpPreferenceNotApplied);
    } finally {
      if (mounted) _set(() => _busy = false);
    }
  }

  Future<void> _selectProfileGroup(
    String nodeID,
    String group,
    String choice,
  ) async {
    _set(() => _busy = true);
    try {
      await _applySubscriptionOperation(
        await widget.tunnelControl.selectProfileGroup(nodeID, group, choice),
      );
      await _refreshState();
    } on Object {
      await _refreshSubscriptions();
      if (mounted) _set(() => _message = l10n.groupSelectionFailed);
    } finally {
      if (mounted) _set(() => _busy = false);
    }
  }

  Future<bool> _saveSubscription(
    Future<SubscriptionSnapshot> Function() save,
    String failure,
  ) async {
    _set(() {
      _busy = true;
      _message = null;
    });
    try {
      final value = await save();
      if (mounted) _set(() => _applySnapshot(value));
      return true;
    } on Object {
      if (mounted) _set(() => _message = failure);
      return false;
    } finally {
      if (mounted) _set(() => _busy = false);
    }
  }

  Future<void> _selectNode(String id) async {
    _set(() {
      _connectFailed = false;
      _busy = true;
      if (_state == TunnelState.connected) _state = TunnelState.reconnecting;
      _message = null;
    });
    final revision = _stateRevision;
    try {
      final value = await widget.tunnelControl.selectNode(id);
      if (mounted && revision == _stateRevision) {
        _set(() {
          _applySnapshot(value.subscriptions);
          _state = _parseState(value.state);
          _stateAvailable = true;
          _lastKnownState = _state;
          _message = null;
        });
      }
    } on Object catch (error) {
      if (!mounted || revision != _stateRevision) return;
      _set(() => _recordIssue(ConnectionIssue.from(error)));
      await _refreshState();
      if (!mounted || revision != _stateRevision) return;
      await _refreshSubscriptions();
    } finally {
      if (mounted && revision == _stateRevision) {
        _set(() => _busy = false);
        await _refreshAutomation();
      }
    }
  }

  Future<void> _connect({bool retrySelected = false}) async {
    final selectedId = _selectedNode?.id;
    final needsStop = retrySelected && _state == TunnelState.connected;
    _set(() {
      _connectFailed = false;
      _state = needsStop ? TunnelState.reconnecting : TunnelState.connecting;
      _busy = true;
      _message = null;
    });
    final revision = _stateRevision;
    try {
      if (needsStop) {
        final stopped = await widget.tunnelControl.disconnect();
        if (!mounted || revision != _stateRevision) return;
        if (stopped != 'disconnected') {
          throw PlatformException(code: 'disconnect_timed_out');
        }
      }
      if (retrySelected && selectedId != null) {
        final selected = await widget.tunnelControl.selectNode(selectedId);
        if (!mounted || revision != _stateRevision) return;
        _set(() => _applySnapshot(selected.subscriptions));
      }
      final state = await widget.tunnelControl.connect();
      if (mounted && revision == _stateRevision) {
        _set(() {
          _state = _parseState(state);
          _stateAvailable = true;
          _lastKnownState = _state;
          _message = null;
        });
        await _pollTransition(revision);
        if (mounted && revision == _stateRevision) {
          _set(() {
            _connectFailed =
                _stateAvailable &&
                const {
                  TunnelState.disconnected,
                  TunnelState.failed,
                  TunnelState.invalid,
                }.contains(_state);
            _message = switch (_state) {
              TunnelState.connected => null,
              TunnelState.failed ||
              TunnelState.invalid ||
              TunnelState.disconnected => ConnectionIssue.forCode(
                'connection_failed',
              ).description,
              _ => _message,
            };
          });
        }
      }
    } on Object catch (error) {
      if (mounted &&
          revision == _stateRevision &&
          !(error is PlatformException &&
              const {
                'cancelled',
                'operation_cancelled',
              }.contains(error.code))) {
        _set(() {
          _connectFailed = true;
          _state = TunnelState.failed;
          _stateAvailable = false;
          _recordIssue(ConnectionIssue.from(error));
        });
        await _refreshState();
      }
    } finally {
      if (mounted && revision == _stateRevision) {
        _set(() => _busy = false);
        if (retrySelected) await _refreshAutomation();
      }
    }
  }

  Future<void> _disconnect() async {
    _set(() {
      _connectFailed = false;
      _state = TunnelState.disconnecting;
      _busy = true;
    });
    final revision = _stateRevision;
    try {
      final state = await widget.tunnelControl.disconnect();
      if (mounted && revision == _stateRevision) {
        _set(() {
          _state = _parseState(state);
          _stateAvailable = true;
          _lastKnownState = _state;
          _message = null;
        });
        await _pollTransition(revision);
      }
    } on Object catch (error) {
      if (mounted && revision == _stateRevision)
        _set(() {
          _stateAvailable = false;
          _recordIssue(ConnectionIssue.from(error));
        });
    } finally {
      if (mounted && revision == _stateRevision) _set(() => _busy = false);
    }
  }

  TunnelState _parseState(String value) => TunnelState.values.firstWhere(
    (state) => state.name == value,
    orElse: () => TunnelState.failed,
  );

  Future<void> _refreshState({bool onlyWhenIdle = false}) async {
    if (_statePolling) return;
    _statePolling = true;
    final revision = _stateRevision;
    try {
      final value = await widget.tunnelControl.state();
      if (!mounted || revision != _stateRevision || onlyWhenIdle && _busy)
        return;
      final state = _parseState(value);
      final liveness = state == TunnelState.connected
          ? widget.tunnelControl.liveness
          : null;
      if (_state != state || !_stateAvailable || _liveness != liveness)
        _set(() {
          if (liveness == 'noTraffic' && _liveness != 'noTraffic')
            _noTrafficAt = DateTime.now();
          _liveness = liveness;
          if (state == TunnelState.connected) _connectFailed = false;
          if (const {
                TunnelState.connecting,
                TunnelState.reconnecting,
                TunnelState.reasserting,
              }.contains(_state) &&
              state == TunnelState.disconnected)
            _connectFailed = true;
          if (widget.desktopCore &&
              !_busy &&
              _state == TunnelState.connected &&
              state == TunnelState.failed) {
            _message = l10n.connectionStoppedUnexpectedly;
          }
          if (_state != state) {
            _healthRun++;
            _health = 'unknown';
            _healthAt = null;
          }
          _state = state;
          _stateAvailable =
              supportStates.contains(value) && value != 'unavailable';
          if (_stateAvailable) _lastKnownState = state;
        });
    } on Object {
      if (!mounted || revision != _stateRevision || onlyWhenIdle && _busy)
        return;
      if (_stateAvailable)
        _set(() {
          _stateAvailable = false;
          _healthRun++;
          _health = 'unknown';
          _healthAt = null;
          _recordIssue(ConnectionIssue.forCode('status_unavailable'));
        });
    } finally {
      _statePolling = false;
    }
  }

  Future<void> _pollTransition(int revision) async {
    for (
      var attempt = 0;
      attempt < 20 && mounted && revision == _stateRevision;
      attempt++
    ) {
      if (_state != TunnelState.connecting &&
          _state != TunnelState.disconnecting &&
          _state != TunnelState.reasserting &&
          _state != TunnelState.reconnecting) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (!mounted || revision != _stateRevision) return;
      await _refreshState();
    }
  }

  Future<void> _refreshRouting() async {
    try {
      final value = await widget.tunnelControl.routingProfiles();
      if (mounted) _set(() => _routing = value);
    } on Object {
      if (mounted) {
        _set(() => _message = l10n.routingProfilesNotLoaded);
      }
    }
  }

  Future<bool> _runRouting(Future<RoutingSnapshot> Function() operation) async {
    // An open editor can save while the tray runs Connect.
    if (_busy) return false;
    _set(() {
      _busy = true;
      _message = null;
    });
    try {
      final value = await operation();
      if (mounted) _set(() => _routing = value);
      await _refreshState();
      return true;
    } on Object {
      if (mounted) {
        _set(() => _message = l10n.routingChangeFailed);
      }
      return false;
    } finally {
      if (mounted) _set(() => _busy = false);
    }
  }

  void _selectSettingsCategory(SettingsCategory category) {
    _set(() => _settingsCategory = category);
    if (category == SettingsCategory.system ||
        category == SettingsCategory.general) {
      unawaited(_refreshSystemInfo());
    }
    if (category == SettingsCategory.routes) unawaited(_refreshRouteTable());
  }
}
