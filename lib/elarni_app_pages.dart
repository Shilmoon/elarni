part of 'elarni_app.dart';

typedef _CountryGroup = ({
  String key,
  ServerLocation? location,
  List<({SubscriptionNode node, SubscriptionGroup group})> nodes,
  bool selected,
  bool open,
});

/// [subscriptionFailures] in the interface language, and other refresh
/// failures: the short label, and the text with [provider] in place of "The
/// provider".
(String, String)? subscriptionFailureText(String code, String provider) =>
    switch (code) {
      'fetch_failed' => (l10n.failureFetch, l10n.failureFetchText),
      'dns_failed' => (l10n.failureDns, l10n.failureDnsText),
      'provider_unreachable' => (
        l10n.failureProviderUnreachable,
        l10n.failureProviderUnreachableText(provider),
      ),
      'provider_error' => (
        l10n.failureProviderError,
        l10n.failureProviderErrorText(provider),
      ),
      'rate_limited' => (
        l10n.failureRateLimited,
        l10n.failureRateLimitedText(provider),
      ),
      'subscription_denied' => (
        l10n.failureDenied,
        l10n.failureDeniedText(provider),
      ),
      'subscription_unavailable' => (
        l10n.failureLinkRemoved,
        l10n.failureLinkRemovedText(provider),
      ),
      'unsupported_profile' => (
        l10n.failureUnsupported,
        l10n.failureUnsupportedText(provider),
      ),
      'hwid_limit' => (
        l10n.statusDeviceLimit,
        l10n.failureDeviceLimitText(provider),
      ),
      _ => null,
    };

extension _HomePages on _ElarniHomeState {
  bool get _noTraffic =>
      _stateAvailable &&
      _state == TunnelState.connected &&
      _liveness == 'noTraffic';

  String get _healthLabel {
    final label = _checkLabel;
    return _stateAvailable &&
            label.isNotEmpty &&
            _automation['enabled'] == true &&
            _automation['whitelistMode'] == true
        ? '$label\n${l10n.whitelistModeRussianFirst}'
        : label;
  }

  String get _checkLabel {
    if (!_stateAvailable)
      return _lastKnownState == null
          ? l10n.refreshStatusToCheck
          : l10n.lastKnownState(_lastKnownState!.name);
    if (_state != TunnelState.connected) return '';
    final currentCheck =
        _healthNodeId == _selectedNode?.id &&
        _healthRevision == _selectedNode?.revision;
    if (currentCheck && _health == 'checking') return l10n.checkingConnection;
    if (currentCheck && _health == 'unavailable')
      return l10n.connectionCheckUnavailable;
    if (currentCheck && _healthAt != null) {
      final time = MaterialLocalizations.of(
        context,
      ).formatTimeOfDay(TimeOfDay.fromDateTime(_healthAt!));
      final age = DateTime.now().difference(_healthAt!).inSeconds;
      final stale = age < 0 || age >= 90;
      return stale
          ? l10n.staleHttpCheckAt(time)
          : _health == 'passed'
          ? l10n.connectionCheckPassedAt(time)
          : l10n.connectionCheckFailedAt(time);
    }
    if (_noTraffic && _noTrafficAt != null) {
      final time = MaterialLocalizations.of(
        context,
      ).formatTimeOfDay(TimeOfDay.fromDateTime(_noTrafficAt!));
      return l10n.serverPassedNoTraffic(time);
    }
    if (_automation['enabled'] == true) {
      final status = _automation['status'];
      if (_automation['policySupported'] == false)
        return l10n.automaticTrafficChecksUnavailable;
      if (const {'healthy', 'recovered', 'selected'}.contains(status) &&
          _automation['healthNodeID'] == _selectedNode?.id &&
          _automation['healthAgeSeconds'] is num &&
          (_automation['healthAgeSeconds']! as num) < 90) {
        return l10n.latestAutomaticCheckPassed;
      }
      if (const {
        'healthFailure',
        'endpointFailure',
        'invalidTarget',
        'indeterminate',
        'exhausted',
        'exhaustedCandidates',
      }.contains(status)) {
        return l10n.automaticCheckFailed;
      }
      if (status == 'unsupportedPolicy') return l10n.automaticChecksUnavailable;
      if (status == 'replacing' || _automation['pendingRetry'] == true)
        return l10n.recoveryInProgress;
    }
    return _liveness == 'ok'
        ? l10n.trafficPassesThroughServer
        : l10n.connectionNotChecked;
  }

  List<SubscriptionGroup> _displayGroups() {
    final groups = _subscriptions.subscriptions
        .where(
          (group) =>
              _search.isEmpty ||
              group.name.toLowerCase().contains(_search) ||
              _displayNodes(group).isNotEmpty,
        )
        .toList();
    return [
      for (final group in groups)
        if (widget.desktop.pinned.contains(group.id)) group,
      for (final group in groups)
        if (!widget.desktop.pinned.contains(group.id)) group,
    ];
  }

  // State cannot change while a frame is built; a handler computes afresh.
  List<SubscriptionNode> _displayNodes(SubscriptionGroup group) =>
      SchedulerBinding.instance.schedulerPhase ==
          SchedulerPhase.persistentCallbacks
      ? _displayNodesMemo[group.id] ??= _filteredNodes(group)
      : _filteredNodes(group);

  List<SubscriptionNode> _filteredNodes(SubscriptionGroup group) {
    final nodes = group.nodes
        .where(
          (node) => _nodeFilter == 'favorites'
              ? node.favorite
              : _nodeFilter == 'recent'
              ? node.lastSuccessAt != null
              : true,
        )
        .where(
          (node) =>
              _search.isEmpty ||
              group.name.toLowerCase().contains(_search) ||
              '${node.name} ${ServerLocation.fromName(node.name)?.name ?? ''} ${node.protocol} ${node.transport} ${node.security}'
                  .toLowerCase()
                  .contains(_search),
        )
        .toList();
    if (_nodeFilter == 'recent') {
      nodes.sort((a, b) => b.lastSuccessAt!.compareTo(a.lastSuccessAt!));
      return nodes;
    }
    if (widget.desktop.sort != 'provider') {
      final positions = {
        for (var i = 0; i < group.nodes.length; i++) group.nodes[i].id: i,
      };
      nodes.sort((a, b) {
        final compared = widget.desktop.sort == 'latency'
            ? _nodeLatency(a.id).compareTo(_nodeLatency(b.id))
            : a.name.toLowerCase().compareTo(b.name.toLowerCase());
        return compared != 0
            ? compared
            : positions[a.id]!.compareTo(positions[b.id]!);
      });
    }
    return widget.desktop.favoritesFirst
        ? [
            ...nodes.where((node) => node.favorite),
            ...nodes.where((node) => !node.favorite),
          ]
        : nodes;
  }

  int _nodeLatency(String id) {
    final result = _pingResults[id];
    final value = result != null && _probeFresh(result)
        ? result.latencyMs
        : null;
    return value != null && value >= 0 ? value : 1 << 62;
  }

  String _probeDescription(PingResult result) {
    final age =
        (DateTime.now().millisecondsSinceEpoch / 1000 - result.timestamp)
            .floor();
    final scope = switch (result.protocol) {
      'tcp' => l10n.probeTcpEndpoint,
      'icmp' => l10n.probeIcmpEndpoint,
      'activeProxy' => l10n.probeActiveConnectionHttp,
      _ => l10n.probeProxyHttp,
    };
    return '$scope · ${age < 0
        ? l10n.timeUnavailable
        : age < 60
        ? l10n.secondsAgo(age)
        : l10n.minutesAgo(age ~/ 60)}${_probeFresh(result) ? '' : ' · ${l10n.stale}'}';
  }

  String _successDescription(SubscriptionNode node) {
    final date = DateTime.fromMillisecondsSinceEpoch(
      (node.lastSuccessAt! * 1000).round(),
    );
    final locale = MaterialLocalizations.of(context);
    final when =
        '${locale.formatShortDate(date)} ${locale.formatTimeOfDay(TimeOfDay.fromDateTime(date))}';
    return '${l10n.connectedAt(when)}'
        '${node.lastSuccessCurrent ? '' : ' · ${l10n.configurationChanged}'}';
  }

  String _riskMessage(SubscriptionRisk risk) => switch (risk) {
    SubscriptionRisk.cleartextHttp => l10n.riskCleartextHttp,
    SubscriptionRisk.loopbackTarget => l10n.riskLoopbackTarget,
    SubscriptionRisk.privateTarget => l10n.riskPrivateTarget,
  };

  String _subscriptionStatus(String status) => switch (status) {
    'approval_required' => l10n.statusApprovalRequired,
    'refresh_failed' => l10n.refreshFailed,
    'refreshing' => l10n.statusRefreshing,
    'pending' => l10n.notDownloadedYet,
    'device_required' => l10n.statusDeviceRequired,
    'device_limit' => l10n.statusDeviceLimit,
    'ready' => l10n.statusReady,
    _ => l10n.unavailable,
  };

  /// A failed download in words that name the provider, so its outages are not reported as app bugs.
  String _refreshFailure(SubscriptionGroup group, String code) =>
      subscriptionFailureText(code, group.name)?.$2 ??
      l10n.refreshFailedSentence;

  /// Failures only the provider can fix, which offer its support link.
  static const _providerFaults = {
    'provider_unreachable',
    'provider_error',
    'subscription_denied',
    'subscription_unavailable',
    'hwid_required',
    'hwid_limit',
  };

  String? _shortExpiry(SubscriptionGroup group) {
    final expire = group.metadata['expire'];
    if (expire is! num || expire <= 0 || expire > 253402300799) return null;
    final date = DateTime.fromMillisecondsSinceEpoch(
      (expire * 1000).toInt(),
    ).toLocal();
    final months = l10n.shortMonths.split(' ');
    final now = DateTime.now();
    final day =
        '${date.day} ${months[date.month - 1]}'
        '${date.year == now.year ? '' : ' ${date.year}'}';
    return date.isBefore(now) ? l10n.expiredOn(day) : l10n.expiresOn(day);
  }

  List<(String, String)> _subscriptionDetails(SubscriptionGroup group) {
    final info = group.metadata;
    final details = <(String, String)>[];
    if (info.isNotEmpty &&
        (group.status != 'ready' || _failedRefreshes.containsKey(group.id)))
      details.add((l10n.detailInformation, l10n.lastReportedProviderInfo));
    if (info['enabled'] == false)
      details.add((l10n.detailAccount, l10n.accountDisabledValue));
    if (info['online'] is bool)
      details.add((
        l10n.providerStatus,
        info['online'] == true ? l10n.online : l10n.offline,
      ));
    String bytes(num count) {
      if (count >= 1073741824)
        return '${(count / 1073741824).toStringAsFixed(2)} ${l10n.gibibytes}';
      if (count >= 1048576)
        return '${(count / 1048576).toStringAsFixed(1)} ${l10n.mebibytes}';
      return l10n.bytesCount(count.toStringAsFixed(0));
    }

    final upload = info['upload'] as num?;
    final download = info['download'] as num?;
    final total = info['total'] as num?;
    if (upload != null && download != null) {
      final used = upload.toDouble() + download.toDouble();
      details.add((l10n.dataUsed, bytes(used)));
      if (total != null)
        details.add((
          l10n.quota,
          total == 0
              ? l10n.unlimited
              : '${bytes(total)}${total > 0 && used >= total ? ' · ${l10n.exhausted}' : ''}',
        ));
    }
    final expire = info['expire'] as num?;
    if (expire == 0) details.add((l10n.expires, l10n.noExpiry));
    if (expire != null && expire > 0 && expire <= 253402300799) {
      final date = DateTime.fromMillisecondsSinceEpoch((expire * 1000).toInt());
      details.add((
        date.isBefore(DateTime.now()) ? l10n.expired : l10n.expires,
        date.toLocal().toString().split('.').first,
      ));
    }
    if (info['routingEnabled'] == false)
      details.add((l10n.providerRouting, l10n.providerRoutingDisabled));
    if (info['hideSettings'] == true)
      details.add((l10n.settings, l10n.providerAsksKeepSettings));
    if (info['directiveNotice'] case final String notice)
      details.add((l10n.providerNotice, notice));
    // Android stores the count as text.
    final skipped = switch (info['skippedServers']) {
      final num count => count.toInt(),
      final String count => int.tryParse(count),
      _ => null,
    };
    if (skipped != null && skipped > 0)
      details.add((
        l10n.serversNotAdded,
        l10n.serversNotAddedText(skipped, switch (info['skippedKinds']) {
          final String kinds => kinds,
          _ => '',
        }),
      ));
    if (info['dnsNotice'] case final String notice)
      details.add(('DNS', notice));
    final fetched = group.lastSuccessfulFetch;
    if (fetched != null &&
        fetched.isFinite &&
        fetched > 0 &&
        fetched <= 253402300799) {
      final date = DateTime.fromMillisecondsSinceEpoch(
        (fetched * 1000).toInt(),
      ).toLocal();
      details.add((l10n.updated, date.toString().split('.').first));
    }
    return details;
  }

  Widget _detailRow(
    String label,
    String value, {
    String? caption,
    List<Widget> actions = const [],
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Wrap(
                  alignment: WrapAlignment.end,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 4,
                  children: [
                    Text(
                      value,
                      textAlign: TextAlign.end,
                      style: TextStyle(color: scheme.onSurface),
                    ),
                    ...actions,
                  ],
                ),
                if (caption != null)
                  Text(
                    caption,
                    textAlign: TextAlign.end,
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The refresh interval and the device ID, which the user can change.
  List<Widget> _providerDetailRows(SubscriptionGroup group) {
    final info = group.metadata;
    final (hours, caption) = switch ((
      int.tryParse(group.fetchOptions['refreshHours'] ?? ''),
      info['updateIntervalHours'],
    )) {
      (final int hours, _) => (hours, l10n.yourOverride),
      (_, final int hours) => (hours, l10n.setByYourProvider),
      _ => (_settings.subscriptionAutoUpdateHours, l10n.appSetting),
    };
    final key = '${group.id}|${group.fetchOptions['httpHost'] ?? ''}';
    final deviceID = _deviceIDs[key] ??= widget.tunnelControl
        .subscriptionDeviceID(group.id);
    return [
      _detailRow(
        l10n.refreshes,
        l10n.everyHours(hours),
        caption: caption,
        actions: [
          TextButton(
            key: ValueKey('change-refresh:${group.id}'),
            onPressed: _busy ? null : () => _editSubscriptionFetch(group),
            child: Text(l10n.change),
          ),
        ],
      ),
      FutureBuilder<String>(
        future: deviceID,
        builder: (context, snapshot) {
          final id = snapshot.data;
          return _detailRow(
            l10n.deviceId,
            id == null
                ? (snapshot.hasError ? l10n.unavailable : l10n.loading)
                : '${id.substring(0, 8)}…${id.substring(id.length - 4)}',
            caption: info['deviceRegistered'] == true
                ? l10n.registeredByProvider
                : null,
            actions: [
              TextButton(
                key: ValueKey('copy-device-id:${group.id}'),
                onPressed: id == null
                    ? null
                    : () => Clipboard.setData(ClipboardData(text: id)),
                child: Text(l10n.copy),
              ),
              TextButton(
                key: ValueKey('reset-device-id:${group.id}'),
                onPressed: _busy ? null : () => _resetDeviceID(group),
                child: Text(l10n.reset),
              ),
            ],
          );
        },
      ),
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(
          l10n.deviceIdHelp,
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    ];
  }

  Widget _providerNotice(SubscriptionGroup group, {bool compact = false}) =>
      ProviderNotice(
        key: PageStorageKey('notice:${group.id}'),
        group: group,
        compact: compact,
        onOpenLink: _busy ? null : () => _openProviderLink(group.id, 'banner'),
      );

  List<Widget> _routingItems() {
    final scheme = Theme.of(context).colorScheme;
    final subscriptions = {
      for (final group in _subscriptions.subscriptions) group.id: group.name,
    };
    final groups = <String?, List<RoutingProfile>>{};
    for (final profile in _routing.profiles) {
      final owner = subscriptions.containsKey(profile.providerSubscriptionId)
          ? profile.providerSubscriptionId
          : null;
      (groups[owner] ??= []).add(profile);
    }
    return [
      if (_routing.profiles.isEmpty)
        Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const Icon(CupertinoIcons.arrow_branch, size: 28),
              const SizedBox(height: 16),
              Text(l10n.noRoutingProfiles),
              const SizedBox(height: 8),
              Text(
                l10n.routingEmptyHelp,
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      for (final group in groups.entries)
        Padding(
          key: ValueKey('routing-group:${group.key ?? "unassociated"}'),
          padding: const EdgeInsets.only(top: 8, bottom: 8),
          child: ExpansionTile(
            key: PageStorageKey<String>(
              'routing-group-tile:${group.key ?? "unassociated"}',
            ),
            initiallyExpanded: true,
            tilePadding: const EdgeInsets.symmetric(horizontal: 20),
            shape: const Border(),
            collapsedShape: const Border(),
            expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
            title: Row(
              children: [
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      subscriptions[group.key] ?? l10n.otherProfiles,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                Text(
                  l10n.profileCount(group.value.length),
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            children: [
              for (final profile in group.value) ...[
                Padding(
                  key: ValueKey('routing:${profile.id}'),
                  padding: const EdgeInsets.fromLTRB(40, 2, 8, 2),
                  child: Row(
                    children: [
                      Expanded(
                        child: InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: _busy
                              ? null
                              : () => _editStructuredRouting(profile),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Tooltip(
                                  message: profile.name,
                                  child: Text(
                                    profile.name,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  profile.geofileError != null
                                      ? l10n.downloadNeedsAttention
                                      : profile.managedError != null
                                      ? l10n.managedListsNeedAttention
                                      : '${profile.fromSubscription ? l10n.profileFromSubscription : l10n.profileCustom}${profile.edited ? ' · ${l10n.profileEdited}' : ''}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color:
                                        profile.geofileError != null ||
                                            profile.managedError != null
                                        ? scheme.error
                                        : scheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      Semantics(
                        label: l10n.enableProfile(profile.name),
                        child: Checkbox(
                          key: ValueKey('routing-enabled:${profile.id}'),
                          value: profile.enabled,
                          onChanged: _busy
                              ? null
                              : (enabled) => _runRouting(
                                  () => widget.tunnelControl
                                      .setRoutingProfileEnabled(
                                        profile.id,
                                        enabled!,
                                      ),
                                ),
                        ),
                      ),
                      PopupMenuButton<String>(
                        key: ValueKey('routing-actions:${profile.id}'),
                        tooltip: l10n.actionsFor(profile.name),
                        enabled: !_busy,
                        icon: const Icon(CupertinoIcons.ellipsis, size: 20),
                        itemBuilder: (_) => [
                          PopupMenuItem(
                            value: 'edit',
                            child: Text(l10n.editRoutingAndDns),
                          ),
                          PopupMenuItem(
                            value: 'details',
                            child: Text(l10n.profileDetails),
                          ),
                          PopupMenuItem(
                            value: 'refresh',
                            child: Text(l10n.refreshRoutingData),
                          ),
                          PopupMenuItem(
                            value: 'json',
                            child: Text(l10n.editJson),
                          ),
                          PopupMenuItem(
                            value: 'duplicate',
                            child: Text(l10n.duplicate),
                          ),
                          if (profile.fromSubscription)
                            PopupMenuItem(
                              value: 'reset',
                              child: Text(l10n.resetToSubscriptionVersion),
                            ),
                          const PopupMenuDivider(),
                          PopupMenuItem(
                            value: 'delete',
                            child: Text(l10n.delete),
                          ),
                        ],
                        onSelected: (action) async {
                          switch (action) {
                            case 'edit':
                              _editStructuredRouting(profile);
                            case 'details':
                              _showRoutingDetails(profile.id);
                            case 'json':
                              _editRouting(profile);
                            case 'refresh':
                              _runRouting(
                                () => widget.tunnelControl
                                    .refreshRoutingGeofiles(profile.id),
                              );
                            case 'duplicate':
                              _runRouting(
                                () => widget.tunnelControl
                                    .duplicateRoutingProfile(profile.id),
                              );
                            case 'reset':
                              if (await _confirmRouting(
                                l10n.resetRoutingProfileQuestion,
                                l10n.replaceEditsQuestion(profile.name),
                                l10n.reset,
                              ))
                                _runRouting(
                                  () => widget.tunnelControl
                                      .resetRoutingProfile(profile.id),
                                );
                            case 'delete':
                              if (await _confirmRouting(
                                l10n.deleteRoutingProfileQuestion,
                                l10n.deleteProfileAndRulesQuestion(
                                  profile.name,
                                ),
                                l10n.delete,
                              ))
                                _runRouting(
                                  () => widget.tunnelControl
                                      .deleteRoutingProfile(profile.id),
                                );
                          }
                        },
                      ),
                    ],
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.only(left: 40, right: 20),
                  child: Divider(),
                ),
              ],
            ],
          ),
        ),
    ];
  }

  SubscriptionGroup? get _selectedSubscription {
    for (final group in _subscriptions.subscriptions) {
      if (group.nodes.any((node) => node.id == _subscriptions.selectedNodeId))
        return group;
    }
    return null;
  }

  SubscriptionNode? get _selectedNode {
    for (final node in _selectedSubscription?.nodes ?? <SubscriptionNode>[]) {
      if (node.id == _subscriptions.selectedNodeId) return node;
    }
    return null;
  }

  // A notice above the connection control: amber warns, red reports a block.
  Widget _homeNotice(
    BuildContext context, {
    required String title,
    required String body,
    required List<Widget> actions,
    bool severe = false,
  }) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final (foreground, background) = severe
        ? dark
              ? (const Color(0xfffca5a5), const Color(0xff492326))
              : (const Color(0xff991b1b), const Color(0xfffee2e2))
        : dark
        ? (const Color(0xfffde047), const Color(0xff453810))
        : (const Color(0xff854d0e), const Color(0xfffef9c3));
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Semantics(
        container: true,
        liveRegion: true,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: foreground,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(body, style: TextStyle(color: foreground)),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final action in actions)
                      TextButtonTheme(
                        data: TextButtonThemeData(
                          style: TextButton.styleFrom(
                            foregroundColor: foreground,
                          ),
                        ),
                        child: action,
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _homeNotices(BuildContext context) => [
    if (_blockingWithoutVPN)
      _homeNotice(
        context,
        title: l10n.trafficBlockedUntilReconnect,
        body: l10n.connectionStoppedUnexpectedlyShort,
        severe: true,
        actions: [
          TextButton(
            onPressed: _busy ? null : _connect,
            child: Text(l10n.reconnect),
          ),
          TextButton(
            onPressed: _busy ? null : _repairTunnel,
            child: Text(l10n.liftBlock),
          ),
        ],
      ),
    if (_openLocalProxy &&
        !_loginNoticeHidden &&
        !widget.desktop.loginWarningDismissed)
      _homeNotice(
        context,
        title: l10n.localProxyWithoutLogin,
        body: l10n.anyProgramCanUseProxy,
        actions: [
          TextButton(
            onPressed: _busy ? null : _requireLogin,
            child: Text(l10n.requireLogin),
          ),
          TextButton(
            onPressed: () {
              _set(() => _loginNoticeHidden = true);
              if (widget.desktop.available)
                unawaited(
                  widget.desktop
                      .update(loginWarningDismissed: true)
                      .catchError((Object _) {}),
                );
            },
            child: Text(l10n.notNow),
          ),
        ],
      ),
    if (widget.desktop.availableUpdate case final update?
        when update.version != widget.desktop.dismissedUpdate)
      _homeNotice(
        context,
        title: l10n.updateAvailable(update.version),
        body: l10n.youHaveVersion('${_systemInfo['appVersion']}'),
        actions: [
          TextButton(
            onPressed: () => _openUpdateLink(update.url),
            child: Text(l10n.download),
          ),
          TextButton(
            onPressed: widget.desktop.saving
                ? null
                : () => unawaited(
                    widget.desktop
                        .update(dismissedUpdate: update.version)
                        .catchError((Object _) {}),
                  ),
            child: Text(l10n.notNow),
          ),
        ],
      ),
  ];

  Widget _connectionControl(BuildContext context, {bool compact = false}) {
    final scheme = Theme.of(context).colorScheme;
    final iconSize = compact ? 80.0 : 108.0;
    final failed =
        _connectFailed ||
        _stateAvailable &&
            const {TunnelState.failed, TunnelState.invalid}.contains(_state);
    final warning = Theme.of(context).brightness == Brightness.dark
        ? const Color(0xfffde047)
        : const Color(0xff854d0e);
    final iconColor = failed
        ? scheme.error
        : _noTraffic
        ? warning
        : scheme.onSurfaceVariant.withValues(alpha: .7);
    final disconnect =
        !_stateAvailable ||
        !_canConnect &&
            _state != TunnelState.disconnected &&
            _state != TunnelState.prepared;
    final label = disconnect ? l10n.disconnect : l10n.connect;
    final status = !_stateAvailable
        ? l10n.connectionStatusUnavailable
        : switch (_state) {
            TunnelState.disconnected => l10n.stateDisconnected,
            TunnelState.prepared => l10n.stateReadyToConnect,
            TunnelState.preparing => l10n.statePreparing,
            TunnelState.connecting => l10n.stateConnecting,
            TunnelState.connected =>
              _noTraffic ? l10n.stateConnectedNoTraffic : l10n.stateConnected,
            TunnelState.disconnecting => l10n.stateDisconnecting,
            TunnelState.reasserting ||
            TunnelState.reconnecting => l10n.stateReconnecting,
            TunnelState.invalid ||
            TunnelState.failed => l10n.stateConnectionFailed,
          };
    final group = _selectedSubscription;
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: 28,
        vertical: compact ? 18 : 32,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TweenAnimationBuilder<double>(
            tween: Tween(
              end:
                  !failed &&
                      !_noTraffic &&
                      _stateAvailable &&
                      _state == TunnelState.connected
                  ? 1.0
                  : 0.0,
            ),
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 400),
            builder: (context, progress, child) => Stack(
              alignment: Alignment.center,
              children: [
                TweenAnimationBuilder<Color?>(
                  tween: ColorTween(end: iconColor),
                  duration: MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : const Duration(milliseconds: 400),
                  builder: (context, color, child) => Icon(
                    CupertinoIcons.antenna_radiowaves_left_right,
                    key: const Key('connection-icon'),
                    size: iconSize,
                    color: color,
                  ),
                ),
                ClipOval(
                  key: const Key('connection-green-reveal'),
                  clipper: _ConnectionRevealClipper(failed ? 0 : progress),
                  child: child,
                ),
              ],
            ),
            child: ExcludeSemantics(
              child: Icon(
                CupertinoIcons.antenna_radiowaves_left_right,
                size: iconSize,
                color: const Color(0xff24b83e),
              ),
            ),
          ),
          SizedBox(height: compact ? 12 : 18),
          Semantics(
            liveRegion: true,
            label: l10n.connectionStateSemantics(
              _stateAvailable ? _state.name : 'unavailable',
            ),
            child: Text(
              status,
              key: const Key('connection-state'),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: _noTraffic ? warning : null,
              ),
            ),
          ),
          if (_healthLabel.isNotEmpty) ...[
            const SizedBox(height: 8),
            Semantics(
              liveRegion: true,
              child: Text(
                _healthLabel,
                key: const Key('connection-health'),
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ),
          ],
          const SizedBox(height: 14),
          Text(
            _selectedNode == null
                ? l10n.chooseServer
                : ServerLocation.displayName(_selectedNode!.name),
            key: const Key('selected-server-name'),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineLarge?.copyWith(
              fontSize: compact ? 22 : 30,
              fontWeight: FontWeight.w600,
              letterSpacing: -.8,
            ),
          ),
          if (_selectedNode == null) ...[
            const SizedBox(height: 10),
            Text(
              l10n.selectServerToConnect,
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
          if (widget.desktopCore && !_settings.xrayTunEnabled) ...[
            const SizedBox(height: 10),
            Text(
              _settings.systemProxy
                  ? l10n.systemProxyMode
                  : l10n.localProxyMode,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: 28),
          SizedBox(
            width: 220,
            child: FilledButton(
              key: const Key('connection-toggle'),
              onPressed: _canConnect
                  ? _connect
                  : _canDisconnect
                  ? _disconnect
                  : null,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 15,
                ),
              ),
              child: Text(label, style: const TextStyle(fontSize: 16)),
            ),
          ),
          if (group != null) ...[
            const SizedBox(height: 24),
            SubscriptionSummary(
              group: group,
              refreshFailed: _failedRefreshes.containsKey(group.id),
              onOpen: () => _set(() {
                _expandedSubscription = group.id;
                _page = DesktopPage.subscriptions;
              }),
            ),
            if (ProviderNotice.messages(group).isNotEmpty) ...[
              const SizedBox(height: 16),
              _providerNotice(group),
            ],
          ],
        ],
      ),
    );
  }

  Widget _serverRow(
    SubscriptionNode node,
    SubscriptionGroup group, {
    bool subscriptionView = false,
    bool selecting = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final result = _pingResults[node.id];
    final exit = _exitResults[node.id]?.configurationRevision == node.revision
        ? _exitResults[node.id]
        : null;
    final exitCountry = exit == null
        ? null
        : ServerLocation.fromCode(exit.exitCountry!);
    final named = ServerLocation.fromName(node.name);
    final dark = Theme.of(context).brightness == Brightness.dark;
    void toggleSelected() => _set(() {
      if (!_selectedServers.remove(node.id)) _selectedServers.add(node.id);
    });
    final pingLabel = result != null
        ? '${l10n.latencyMs(result.latencyMs)}${_probeFresh(result) ? '' : ' · ${l10n.stale}'}'
        : _pingPending.contains(node.id)
        ? l10n.testing
        : _pingSkipped.contains(node.id)
        ? l10n.skipped
        : _pingUnavailable.contains(node.id)
        ? l10n.unavailable
        : l10n.ping;
    // Rename any server; remove any but the selected or last one. A
    // provider's server is hidden, so that its refresh keeps it out.
    Future<void> serverMenu(Offset position) async {
      if (_busy || _profileEditsDisabled) return;
      final action = await showMenu<String>(
        context: context,
        position: RelativeRect.fromLTRB(
          position.dx,
          position.dy,
          position.dx,
          position.dy,
        ),
        items: [
          PopupMenuItem(value: 'rename', child: Text(l10n.renameServer)),
          if (node.isVPN)
            PopupMenuItem(value: 'exit', child: Text(l10n.checkExit)),
          if (!node.selected && group.nodes.length > 1)
            PopupMenuItem(
              value: 'delete',
              child: Text(group.isLocal ? l10n.deleteServer : l10n.hideServer),
            ),
        ],
      );
      if (!mounted || _busy) return;
      if (action == 'rename') await _renameNode(node);
      if (action == 'exit') await _checkExit(node);
      if (action == 'delete') await _deleteNode(node, group);
    }

    // The actions button only where the name keeps room beside it: the split Home column can be 320 px.
    return LayoutBuilder(
      builder: (context, constraints) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Material(
          color: node.selected
              ? scheme.primary.withValues(alpha: .14)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          child: GestureDetector(
            onSecondaryTapUp: (details) => serverMenu(details.globalPosition),
            onLongPressStart: (details) => serverMenu(details.globalPosition),
            // A screen reader gets the long press on the row itself, below.
            excludeFromSemantics: true,
            child: Builder(
              builder: (row) {
                void rowMenu() {
                  final box = row.findRenderObject()! as RenderBox;
                  serverMenu(box.localToGlobal(box.size.center(Offset.zero)));
                }

                // The menu key, Shift+F10 and a screen reader's long press open it.
                return CallbackShortcuts(
                  bindings: {
                    for (final key in const [
                      SingleActivator(LogicalKeyboardKey.contextMenu),
                      SingleActivator(LogicalKeyboardKey.f10, shift: true),
                    ])
                      key: rowMenu,
                  },
                  child: Semantics(
                    onLongPress: rowMenu,
                    child: ListTile(
                      key: ValueKey('node:${node.id}'),
                      selected: node.selected,
                      selectedColor: scheme.onSurface,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 5,
                      ),
                      leading: selecting
                          ? Checkbox(
                              key: ValueKey('select-node:${node.id}'),
                              semanticLabel: l10n.selectNamed(node.name),
                              value: _selectedServers.contains(node.id),
                              // The selected server cannot be hidden or deleted.
                              onChanged: node.selected
                                  ? null
                                  : (_) => toggleSelected(),
                            )
                          : subscriptionView
                          ? Tooltip(
                              message:
                                  ServerLocation.fromName(node.name)?.name ??
                                  l10n.unknownLocation,
                              child: LocationFlag(
                                location: ServerLocation.fromName(node.name),
                              ),
                            )
                          : IconButton(
                              key: ValueKey('favorite:${node.id}'),
                              tooltip: node.favorite
                                  ? l10n.removeFavorite
                                  : l10n.addFavorite,
                              isSelected: node.favorite,
                              onPressed: _busy
                                  ? null
                                  : () => _toggleFavorite(node),
                              icon: const Icon(CupertinoIcons.star, size: 19),
                              selectedIcon: const Icon(
                                CupertinoIcons.star_fill,
                                size: 19,
                              ),
                            ),
                      title: Text(
                        ServerLocation.displayName(node.name),
                        style: const TextStyle(fontSize: 16),
                      ),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Wrap(
                              spacing: 8,
                              runSpacing: 4,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                ProtocolTag(node.protocol),
                                Text(
                                  subscriptionView
                                      ? '${node.transport} · ${node.security}'
                                      : group.name,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                                if (exit != null ||
                                    _exitPending.contains(node.id) ||
                                    _exitFailed.contains(node.id))
                                  Text(
                                    exit != null
                                        ? l10n.exitAt(
                                            switch (exit.exitCountry!) {
                                              'XX' => l10n.unknownCountry,
                                              'T1' => 'Tor',
                                              final code =>
                                                exitCountry?.name ?? code,
                                            },
                                            exit.exitIP ?? '',
                                          )
                                        : _exitPending.contains(node.id)
                                        ? l10n.checkingExit
                                        : l10n.exitCheckFailed,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                              ],
                            ),
                            // A provider's label is not evidence; the trace is.
                            if (exitCountry != null &&
                                named != null &&
                                named.code != 'EU' &&
                                named.code != exitCountry.code)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(
                                  l10n.exitMismatch(
                                    ServerLocation.displayName(node.name),
                                    named.name,
                                    exitCountry.name,
                                  ),
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: dark
                                        ? const Color(0xfffde047)
                                        : const Color(0xff854d0e),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      onTap: selecting
                          ? (node.selected ? null : toggleSelected)
                          : subscriptionView || _profileEditsDisabled
                          ? null
                          : node.isVPN
                          ? () => _selectNode(node.id)
                          : () => _openTelegram(node.id),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Only the Windows and Linux backends can show and replace a config.
                          if (subscriptionView &&
                              widget.desktopCore &&
                              node.isVPN &&
                              group.metadata['hideURL'] != true)
                            IconButton(
                              key: ValueKey('node-config:${node.id}'),
                              tooltip: l10n.serverConfig,
                              onPressed: _busy
                                  ? null
                                  : () => _editNodeConfig(node, group),
                              icon: const Icon(
                                CupertinoIcons.chevron_left_slash_chevron_right,
                                size: 18,
                              ),
                            ),
                          if (subscriptionView &&
                              !selecting &&
                              node.isVPN &&
                              exit == null)
                            TextButton(
                              key: ValueKey('check-exit:${node.id}'),
                              onPressed: _busy || _exitPending.contains(node.id)
                                  ? null
                                  : () => _checkExit(node),
                              child: Text(
                                _exitPending.contains(node.id)
                                    ? l10n.checking
                                    : l10n.checkExit,
                              ),
                            ),
                          Tooltip(
                            message: node.isVPN
                                ? [
                                    '${node.protocol} · ${node.transport} · ${node.security}',
                                    if (node.lastSuccessAt != null)
                                      _successDescription(node),
                                    if (result != null)
                                      _probeDescription(result),
                                    _pingSkipped.contains(node.id)
                                        ? l10n.unsupportedTest
                                        : l10n.testServerLatency,
                                  ].join('\n')
                                : l10n.openInTelegram,
                            child: TextButton(
                              key: ValueKey('ping:${node.id}'),
                              onPressed: (_busy || node.isVPN && _pinging)
                                  ? null
                                  : node.isVPN
                                  ? () => _pingNode(node.id)
                                  : () => _openTelegram(node.id),
                              style: TextButton.styleFrom(
                                foregroundColor: scheme.onSurfaceVariant,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                ),
                                // Room for the actions button without narrowing the name.
                                minimumSize: const Size(36, 40),
                              ),
                              child:
                                  node.isVPN &&
                                      result != null &&
                                      result.status == 'success' &&
                                      result.latencyMs >= 0 &&
                                      _probeFresh(result)
                                  ? LatencyBadge(result.latencyMs)
                                  : Text(node.isVPN ? pingLabel : l10n.open),
                            ),
                          ),
                          if (node.selected)
                            Icon(
                              CupertinoIcons.checkmark_circle_fill,
                              size: 18,
                              color: scheme.primary,
                            ),
                          // The same menu as a right click or long press, for those who never try one.
                          if (!subscriptionView &&
                              !selecting &&
                              constraints.maxWidth >= 360)
                            Builder(
                              builder: (button) => IconButton(
                                key: ValueKey('server-menu:${node.id}'),
                                tooltip: l10n.serverActions,
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(
                                  minWidth: 28,
                                  minHeight: 32,
                                ),
                                onPressed: _busy || _profileEditsDisabled
                                    ? null
                                    : () {
                                        final box =
                                            button.findRenderObject()!
                                                as RenderBox;
                                        serverMenu(
                                          box.localToGlobal(
                                            box.size.bottomLeft(Offset.zero),
                                          ),
                                        );
                                      },
                                icon: const Icon(
                                  CupertinoIcons.ellipsis_vertical,
                                  size: 18,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  // Elarni ships no servers, so a new install starts with where one comes from.
  Widget _gettingStarted(ColorScheme scheme) {
    Widget step(int number, String text, [Widget? actions]) => Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 12,
            backgroundColor: scheme.secondaryContainer,
            child: Text(
              '$number',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: scheme.onSecondaryContainer,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(text, style: const TextStyle(height: 1.45)),
                ),
                if (actions != null) ...[const SizedBox(height: 10), actions],
              ],
            ),
          ),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(
              l10n.onboardingTitle,
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(height: 16),
          step(1, l10n.onboardingStep1),
          step(
            2,
            l10n.onboardingStep2,
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (source, label, icon) in [
                  (
                    'clipboard',
                    l10n.pasteLink,
                    CupertinoIcons.doc_on_clipboard,
                  ),
                  ('camera', l10n.scanQrCode, CupertinoIcons.viewfinder),
                  ('file', l10n.openFile, CupertinoIcons.doc),
                ])
                  OutlinedButton.icon(
                    key: Key('onboarding-$source'),
                    onPressed: _busy ? null : () => _importProfiles(source),
                    icon: Icon(icon, size: 18),
                    label: Text(label),
                  ),
              ],
            ),
          ),
          step(
            3,
            !widget.desktopCore
                ? l10n.onboardingStep3Mac
                : _settings.xrayTunEnabled
                ? l10n.onboardingStep3Vpn
                : l10n.onboardingStep3Proxy,
          ),
        ],
      ),
    );
  }

  Widget _serverSubscriptionHeader(
    SubscriptionGroup group, {
    required bool open,
  }) => Semantics(
    expanded: open,
    child: ListTile(
      key: ValueKey('server-subscription:${group.id}'),
      contentPadding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
      onTap: _search.isNotEmpty
          ? null
          : () => _set(() {
              if (!_collapsedSubscriptions.remove(group.id))
                _collapsedSubscriptions.add(group.id);
            }),
      title: Text(
        group.name,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(l10n.serverCount(group.nodes.length)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!group.isLocal)
            IconButton(
              key: ValueKey('refresh-subscription:${group.id}'),
              tooltip: l10n.refreshNamed(group.name),
              onPressed: _busy ? null : () => _refreshSubscription(group.id),
              icon: const Icon(CupertinoIcons.arrow_clockwise, size: 20),
            ),
          // Matches the country tiles' expansion arrow.
          Icon(open ? Icons.expand_less : Icons.expand_more),
        ],
      ),
    ),
  );

  /// Each country's servers in display order, and whether its group is open.
  List<_CountryGroup> _countryGroups(SubscriptionGroup? subscription) {
    final countries = <String, ServerLocation?>{};
    final byCountry =
        <String, List<({SubscriptionNode node, SubscriptionGroup group})>>{};
    for (final group
        in subscription == null ? _displayGroups() : [subscription]) {
      for (final node in _displayNodes(group)) {
        final location = ServerLocation.fromName(node.name);
        final code = location?.code ?? 'other';
        countries[code] = location;
        (byCountry[code] ??= []).add((node: node, group: group));
      }
    }
    final codes = countries.keys.toList()
      ..sort((a, b) {
        if (a == 'other') return 1;
        if (b == 'other') return -1;
        return countries[a]!.name.compareTo(countries[b]!.name);
      });
    return [
      for (final code in codes)
        _countryGroup(
          '${subscription?.id}:$code',
          countries[code],
          byCountry[code]!,
        ),
    ];
  }

  _CountryGroup _countryGroup(
    String key,
    ServerLocation? location,
    List<({SubscriptionNode node, SubscriptionGroup group})> nodes,
  ) {
    final positions = {
      for (var i = 0; i < nodes.length; i++) nodes[i].node.id: i,
    };
    if (widget.desktop.sort != 'provider' && _nodeFilter != 'recent') {
      nodes.sort((a, b) {
        final pinned = (widget.desktop.pinned.contains(a.group.id) ? 0 : 1)
            .compareTo(widget.desktop.pinned.contains(b.group.id) ? 0 : 1);
        if (pinned != 0) return pinned;
        final favorite = widget.desktop.favoritesFirst
            ? (a.node.favorite ? 0 : 1).compareTo(b.node.favorite ? 0 : 1)
            : 0;
        if (favorite != 0) return favorite;
        final compared = widget.desktop.sort == 'latency'
            ? _nodeLatency(a.node.id).compareTo(_nodeLatency(b.node.id))
            : a.node.name.toLowerCase().compareTo(b.node.name.toLowerCase());
        return compared != 0
            ? compared
            : positions[a.node.id]!.compareTo(positions[b.node.id]!);
      });
    }
    final selected = nodes.any((entry) => entry.node.selected);
    return (
      key: key,
      location: location,
      nodes: nodes,
      selected: selected,
      open:
          _search.isNotEmpty ||
          (_expandedCountries[key] ?? (selected || location == null)),
    );
  }

  /// The servers in Home's open groups, which a launch tests.
  List<String> _openServerIds() => [
    for (final group in _displayGroups())
      if (_search.isNotEmpty || !_collapsedSubscriptions.contains(group.id))
        for (final country in _countryGroups(group))
          if (country.open)
            for (final entry in country.nodes) entry.node.id,
  ];

  // Builders, so that a long list makes only the rows on screen.
  List<Widget Function()> _serverItems({SubscriptionGroup? subscription}) {
    final scheme = Theme.of(context).colorScheme;
    if (subscription == null && _subscriptions.subscriptions.isNotEmpty) {
      final groups = _displayGroups()
          .where(
            (group) =>
                _displayNodes(group).isNotEmpty ||
                (_nodeFilter == 'all' && _search.isEmpty),
          )
          .toList();
      if (groups.isEmpty)
        return [
          () => Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              children: [
                Text(
                  _nodeFilter == 'favorites'
                      ? l10n.noFavoriteServers
                      : _nodeFilter == 'recent'
                      ? l10n.noSuccessfulConnections
                      : l10n.noMatchingServers,
                ),
                TextButton(
                  onPressed: () => _set(() {
                    _search = '';
                    _nodeSearch.clear();
                    _nodeFilter = 'all';
                  }),
                  child: Text(l10n.showAllServers),
                ),
              ],
            ),
          ),
        ];
      return [
        for (final group in groups)
          // A search shows every match, so it opens closed subscriptions.
          if (_search.isNotEmpty ||
              !_collapsedSubscriptions.contains(group.id)) ...[
            () => _serverSubscriptionHeader(group, open: true),
            ..._serverItems(subscription: group),
          ] else
            () => _serverSubscriptionHeader(group, open: false),
      ];
    }
    final countries = _countryGroups(subscription);
    return [
      if (_subscriptions.subscriptions.isEmpty) () => _gettingStarted(scheme),
      if (countries.isEmpty && _subscriptions.subscriptions.isNotEmpty)
        () => Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            children: [
              // A new or failed subscription has no servers to match yet.
              Text(
                _search.isEmpty && _nodeFilter == 'all'
                    ? l10n.noServersYet
                    : l10n.noMatchingServers,
              ),
              if (_search.isNotEmpty)
                TextButton(
                  onPressed: () => _set(() {
                    _nodeSearch.clear();
                    _search = '';
                  }),
                  child: Text(l10n.clearSearch),
                ),
            ],
          ),
        ),
      for (final country in countries) ...[
        () => _countryHeader(country),
        if (country.open) ...[
          for (final entry in country.nodes)
            () => country.selected
                ? ColoredBox(
                    color: scheme.primary.withValues(alpha: .08),
                    child: _serverRow(entry.node, entry.group),
                  )
                : _serverRow(entry.node, entry.group),
          () => Container(
            height: 8,
            decoration: BoxDecoration(
              color: country.selected
                  ? scheme.primary.withValues(alpha: .08)
                  : null,
              border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
            ),
          ),
        ],
      ],
    ];
  }

  Widget _countryHeader(_CountryGroup country) {
    final scheme = Theme.of(context).colorScheme;
    int? lowestLatency;
    for (final entry in country.nodes) {
      final result = _pingResults[entry.node.id];
      if (entry.node.isVPN &&
          result != null &&
          result.status == 'success' &&
          _probeFresh(result) &&
          result.latencyMs >= 0 &&
          (lowestLatency == null || result.latencyMs < lowestLatency)) {
        lowestLatency = result.latencyMs;
      }
    }
    return Semantics(
      selected: country.selected,
      expanded: country.open,
      child: Material(
        key: ValueKey('country:${country.key}:$_search:$_nodeFilter'),
        color: country.selected
            ? scheme.primary.withValues(alpha: .08)
            : Colors.transparent,
        shape: country.open
            ? const Border()
            : Border(bottom: BorderSide(color: scheme.outlineVariant)),
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 4,
          ),
          // A search shows every match, so its groups stay open.
          onTap: _search.isNotEmpty
              ? null
              : () {
                  final open = !country.open;
                  _set(() => _expandedCountries[country.key] = open);
                  if (open)
                    _pingOpened(country.nodes.map((entry) => entry.node));
                },
          leading: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LocationFlag(location: country.location),
              if (lowestLatency != null) ...[
                const SizedBox(height: 4),
                LatencyBadge(
                  lowestLatency,
                  labelKey: ValueKey('country-ping:${country.key}'),
                  semanticsLabel: l10n.lowestLatencySemantics(lowestLatency),
                ),
              ],
            ],
          ),
          title: Text(
            country.location?.name ?? l10n.otherLocations,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            l10n.serverCount(country.nodes.length),
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          trailing: Icon(country.open ? Icons.expand_less : Icons.expand_more),
        ),
      ),
    );
  }

  Widget _pingAllButton({String? subscriptionId}) => IconButton(
    key: subscriptionId == null
        ? const Key('ping-all')
        : ValueKey('subscription-ping-all:$subscriptionId'),
    tooltip: _pinging
        ? l10n.testing
        : _pingProtocol == 'icmp'
        ? l10n.useNodePingForIcmp
        : subscriptionId == null
        ? l10n.testAllNodes
        : l10n.testSubscriptionNodes,
    onPressed:
        _pingControlsDisabled ||
            _pingProtocol == 'icmp' ||
            !_subscriptions.subscriptions.any(
              (group) =>
                  (subscriptionId == null || group.id == subscriptionId) &&
                  group.nodes.any((node) => node.isVPN),
            )
        ? null
        : () => _pingAllNodes(subscriptionId: subscriptionId),
    icon: const Icon(CupertinoIcons.gauge, size: 20),
  );

  Widget _subscriptionActions(
    SubscriptionGroup group,
  ) => PopupMenuButton<String>(
    key: ValueKey('subscription-actions:${group.id}'),
    tooltip: l10n.subscriptionActions,
    icon: const Icon(CupertinoIcons.ellipsis),
    onSelected: (action) {
      // Item flags were read when the menu opened; a tray Connect may have started since.
      if (_busy && action != 'pin') return;
      switch (action) {
        case 'pin':
          final pins = {...widget.desktop.pinned};
          if (!pins.remove(group.id)) pins.add(group.id);
          _saveDesktop(pinned: pins);
        case 'account':
        case 'support':
          _openProviderLink(group.id, action);
        case 'share':
          _shareSubscription(group.id);
        case 'download':
          _editSubscriptionFetch(group);
        case 'rename':
          _renameSubscription(group);
        case 'delete':
          _deleteSubscription(group);
        default:
          if (action.startsWith('format:')) {
            _refreshSubscription(group.id, format: action.substring(7));
          }
      }
    },
    itemBuilder: (context) => [
      if (widget.desktop.available)
        PopupMenuItem(
          value: 'pin',
          enabled: !widget.desktop.saving,
          child: Text(
            widget.desktop.pinned.contains(group.id)
                ? l10n.unpinSubscription
                : l10n.pinSubscription,
          ),
        ),
      for (final action in group.actions.where(
        (action) => action == 'account' || action == 'support',
      ))
        PopupMenuItem(
          value: action,
          enabled: !_busy,
          child: Text(
            action == 'account' ? l10n.accountDetails : l10n.providerSupport,
          ),
        ),
      if (!group.isLocal && group.metadata['hideURL'] != true)
        PopupMenuItem(
          value: 'share',
          enabled: !_busy,
          child: Text(l10n.shareSubscription),
        ),
      if (!group.isLocal)
        PopupMenuItem(
          value: 'download',
          enabled: !_busy,
          child: Text(l10n.downloadOptions),
        ),
      if (group.actions.any(
        (action) => const ['raw', 'json', 'clash'].contains(action),
      )) ...[
        const PopupMenuDivider(),
        PopupMenuItem(enabled: false, child: Text(l10n.subscriptionFormat)),
        PopupMenuItem(
          value: 'format:source',
          enabled: !_busy,
          child: Text(l10n.originalSubscription),
        ),
        for (final format in group.actions.where(
          (action) => const ['raw', 'json', 'clash'].contains(action),
        ))
          PopupMenuItem(
            value: 'format:$format',
            enabled: !_busy,
            child: Text(switch (format) {
              'json' => 'Xray JSON',
              'clash' => 'Clash YAML',
              _ => l10n.shareLinksFormat,
            }),
          ),
      ],
      const PopupMenuDivider(),
      PopupMenuItem(value: 'rename', enabled: !_busy, child: Text(l10n.rename)),
      PopupMenuItem(
        value: 'delete',
        enabled: !_profileEditsDisabled,
        child: Text(
          l10n.delete,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      ),
    ],
  );

  Widget _subscriptionCard(SubscriptionGroup group) {
    final scheme = Theme.of(context).colorScheme;
    final search = _subscriptionSearches[group.id] ?? '';
    final nodes = group.nodes
        .where(
          (node) =>
              search.isEmpty ||
              '${node.name} ${ServerLocation.fromName(node.name)?.name ?? ''} ${node.protocol} ${node.transport} ${node.security}'
                  .toLowerCase()
                  .contains(search),
        )
        .toList();
    final details = _subscriptionDetails(group);
    final selecting = _selectingSubscription == group.id;
    final selectedCount = group.nodes
        .where((node) => _selectedServers.contains(node.id))
        .length;
    bool unreachable(String id) {
      final result = _pingResults[id];
      return _pingUnavailable.contains(id) ||
          result != null &&
              (result.status != 'success' || result.latencyMs < 0);
    }

    final failure = _failedRefreshes[group.id];
    final status = group.metadata['enabled'] == false
        ? l10n.accountDisabled
        : failure != null
        ? [
            subscriptionFailureText(failure, group.name)?.$1 ??
                l10n.refreshFailed,
            ?_shortExpiry(group),
          ].join(' · ')
        : group.status == 'ready'
        ? null
        : _subscriptionStatus(group.status);
    return Card(
      key: ValueKey('subscription:${group.id}'),
      child: ExpansionTile(
        key: PageStorageKey<String>(
          'subscriptions:${group.id}:$_expandedSubscription',
        ),
        initiallyExpanded: _expandedSubscription == group.id,
        tilePadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        shape: const Border(),
        collapsedShape: const Border(),
        title: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    group.name,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${l10n.serverCount(group.nodes.length)}'
                    '${status == null ? '' : ' · $status'}',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
            if (failure != null && group.actions.contains('support'))
              TextButton(
                key: ValueKey('subscription-support:${group.id}'),
                onPressed: _busy
                    ? null
                    : () => _openProviderLink(group.id, 'support'),
                child: Text(l10n.settingsGroupSupport),
              ),
            if (!group.isLocal)
              IconButton(
                key: ValueKey('refresh-subscription:${group.id}'),
                tooltip: l10n.refreshNamed(group.name),
                onPressed: _busy ? null : () => _refreshSubscription(group.id),
                icon: const Icon(CupertinoIcons.arrow_clockwise, size: 19),
              ),
            _subscriptionActions(group),
          ],
        ),
        // A closed card does not make its rows.
        children: [
          Builder(
            builder: (_) => Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (details.isNotEmpty || !group.isLocal)
                        ExpansionTile(
                          key: PageStorageKey(
                            'subscription-details:${group.id}',
                          ),
                          title: Text(
                            l10n.details,
                            style: TextStyle(fontSize: 13),
                          ),
                          tilePadding: EdgeInsets.zero,
                          shape: const Border(),
                          collapsedShape: const Border(),
                          childrenPadding: const EdgeInsets.only(bottom: 16),
                          children: [
                            SelectionArea(
                              child: Column(
                                key: PageStorageKey(
                                  'subscription-metadata:${group.id}',
                                ),
                                children: [
                                  for (final (label, value) in details)
                                    _detailRow(label, value),
                                  if (!group.isLocal)
                                    ..._providerDetailRows(group),
                                ],
                              ),
                            ),
                          ],
                        ),
                      if (ProviderNotice.messages(group).isNotEmpty) ...[
                        const SizedBox(height: 8),
                        _providerNotice(group, compact: true),
                      ],
                      const SizedBox(height: 16),
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final label = Text(
                            l10n.routingProfile,
                            style: TextStyle(color: scheme.onSurfaceVariant),
                          );
                          final picker = ElarniSelect<String>(
                            key: ValueKey('subscription-routing:${group.id}'),
                            value: _routing.assignments[group.id] ?? '',
                            isExpanded: true,
                            items: [
                              DropdownMenuItem(
                                value: '',
                                child: Text(l10n.noCustomRouting),
                              ),
                              for (final profile in _routing.profiles)
                                DropdownMenuItem(
                                  value: profile.id,
                                  child: Text(profile.name),
                                ),
                            ],
                            onChanged: _busy
                                ? null
                                : (value) => _runRouting(
                                    () => widget.tunnelControl
                                        .assignRoutingProfile(
                                          group.id,
                                          value == null || value.isEmpty
                                              ? null
                                              : value,
                                        ),
                                  ),
                          );
                          if (constraints.maxWidth < 400 ||
                              MediaQuery.textScalerOf(context).scale(1) >=
                                  1.5) {
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [label, picker],
                            );
                          }
                          return Row(
                            children: [
                              Expanded(child: label),
                              const SizedBox(width: 16),
                              Flexible(child: picker),
                            ],
                          );
                        },
                      ),
                      if (_routing.profiles.any(
                        (profile) =>
                            profile.id == _routing.assignments[group.id] &&
                            profile.providerSubscriptionId == group.id,
                      ))
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            l10n.setByYourProvider,
                            textAlign: TextAlign.end,
                            style: TextStyle(
                              fontSize: 12,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      const Divider(height: 24),
                    ],
                  ),
                ),
                ExpansionTile(
                  key: PageStorageKey('subscription-servers:${group.id}'),
                  initiallyExpanded: true,
                  title: Text(l10n.servers),
                  tilePadding: const EdgeInsets.symmetric(horizontal: 20),
                  shape: const Border(),
                  collapsedShape: const Border(),
                  children: [
                    if (selecting)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Semantics(
                              liveRegion: true,
                              child: Text(l10n.selectedCount(selectedCount)),
                            ),
                            TextButton(
                              onPressed: () => _set(
                                () => _selectedServers.addAll([
                                  for (final node in nodes)
                                    if (!node.selected &&
                                        node.isVPN &&
                                        unreachable(node.id))
                                      node.id,
                                ]),
                              ),
                              child: Text(l10n.selectUnreachable),
                            ),
                            TextButton(
                              // A subscription keeps at least one server.
                              onPressed:
                                  _busy ||
                                      selectedCount == 0 ||
                                      selectedCount >= group.nodes.length
                                  ? null
                                  : () => _deleteSelected(group),
                              child: Text(
                                group.isLocal ? l10n.delete : l10n.hide,
                              ),
                            ),
                            TextButton(
                              onPressed: () => _set(() {
                                _selectingSubscription = null;
                                _selectedServers.clear();
                              }),
                              child: Text(l10n.cancel),
                            ),
                          ],
                        ),
                      )
                    else
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                        child: Row(
                          children: [
                            Expanded(
                              child: TextFormField(
                                key: PageStorageKey(
                                  'subscription-search:${group.id}',
                                ),
                                initialValue: search,
                                decoration: InputDecoration(
                                  hintText: l10n.searchServers,
                                  prefixIcon: Icon(
                                    CupertinoIcons.search,
                                    size: 19,
                                  ),
                                ),
                                onChanged: (value) => _set(
                                  () => _subscriptionSearches[group.id] = value
                                      .trim()
                                      .toLowerCase(),
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            if (group.nodes.length > 1)
                              TextButton(
                                key: ValueKey('select-servers:${group.id}'),
                                onPressed: _busy
                                    ? null
                                    : () => _set(() {
                                        _selectingSubscription = group.id;
                                        _selectedServers.clear();
                                      }),
                                child: Text(l10n.select),
                              ),
                            _pingAllButton(subscriptionId: group.id),
                          ],
                        ),
                      ),
                    if (nodes.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          group.nodes.isEmpty
                              ? l10n.noServersInSubscription
                              : l10n.noMatchingServers,
                        ),
                      ),
                    for (final node in nodes) ...[
                      _serverRow(
                        node,
                        group,
                        subscriptionView: true,
                        selecting: selecting,
                      ),
                      for (final choice in node.groups)
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 8,
                          ),
                          child: ElarniSelect<String>(
                            key: ValueKey('${node.id}:${choice.name}'),
                            value: choice.selected,
                            isExpanded: true,
                            label: choice.name,
                            items: choice.options
                                .map(
                                  (option) => DropdownMenuItem(
                                    value: option,
                                    child: Text(option),
                                  ),
                                )
                                .toList(),
                            onChanged: _busy
                                ? null
                                : (value) {
                                    if (value != null)
                                      _selectProfileGroup(
                                        node.id,
                                        choice.name,
                                        value,
                                      );
                                  },
                          ),
                        ),
                    ],
                    if (group.hiddenNodes.isNotEmpty)
                      ListTile(
                        key: ValueKey('hidden-servers:${group.id}'),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 20,
                        ),
                        leading: const Icon(CupertinoIcons.eye_slash, size: 19),
                        title: Text(
                          l10n.hiddenServersCount(group.hiddenNodes.length),
                        ),
                        trailing: TextButton(
                          onPressed: _busy
                              ? null
                              : () => _showHiddenServers(group),
                          child: Text(l10n.showAgain),
                        ),
                      ),
                    const SizedBox(height: 16),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _serverHeader() => Padding(
    padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                l10n.servers,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final entry in {
              'all': l10n.filterAll,
              'favorites': l10n.filterFavorites,
              'recent': l10n.filterRecent,
            }.entries)
              ChoiceChip(
                label: Text(entry.value),
                selected: _nodeFilter == entry.key,
                onSelected: (_) => _set(() => _nodeFilter = entry.key),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const Key('node-search'),
                controller: _nodeSearch,
                decoration: InputDecoration(
                  hintText: l10n.searchServers,
                  prefixIcon: Icon(CupertinoIcons.search, size: 19),
                ),
                onChanged: (value) =>
                    _set(() => _search = value.trim().toLowerCase()),
              ),
            ),
            const SizedBox(width: 10),
            _pingAllButton(),
          ],
        ),
      ],
    ),
  );

  Widget _homeContent(String memory, String activity) {
    final scheme = Theme.of(context).colorScheme;
    Widget monitoring() => Padding(
      padding: const EdgeInsets.all(24),
      child: Text(
        '${l10n.runtime}: ${_metrics['backend'] ?? 'disconnected'} · ${_metrics['state'] ?? 'unavailable'}\n$memory\n$activity',
        style: TextStyle(
          color: scheme.onSurfaceVariant,
          fontSize: 12,
          height: 1.5,
        ),
      ),
    );
    // Marking from Home catches the moment a problem shows.
    Widget recording() => Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      children: [
        Text(
          l10n.recordingConnectionDiagnostics,
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
        ),
        TextButton.icon(
          onPressed: _markRecording,
          icon: const Icon(Icons.flag_outlined, size: 18),
          label: Text(l10n.markProblem),
        ),
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final split =
            constraints.maxWidth >= 720 &&
            MediaQuery.textScalerOf(context).scale(1) < 1.5;
        if (!split) {
          final items = <Widget Function()>[
            for (final notice in _homeNotices(context)) () => notice,
            () => _connectionControl(context, compact: true),
            if (recordingBuild && _settings.recordDiagnostics) recording,
            if (_settings.monitoringEnabled) monitoring,
            () => const Divider(),
            () => _serverHeader(),
            ..._serverItems(),
            () => const SizedBox(height: 16),
          ];
          return ListView.builder(
            key: const ValueKey('home-list'),
            itemCount: items.length,
            itemBuilder: (context, index) => items[index](),
          );
        }
        final servers = _serverItems();
        final serverWidth = (constraints.maxWidth * .37).clamp(320.0, 410.0);
        return Row(
          children: [
            Expanded(
              child: LayoutBuilder(
                builder: (context, centerConstraints) => SingleChildScrollView(
                  key: const ValueKey('home-list'),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: centerConstraints.maxHeight,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        ..._homeNotices(context),
                        _connectionControl(context),
                        if (recordingBuild && _settings.recordDiagnostics)
                          recording(),
                        if (_settings.monitoringEnabled) monitoring(),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            VerticalDivider(width: 1, color: scheme.outlineVariant),
            SizedBox(
              width: serverWidth,
              child: Column(
                children: [
                  _serverHeader(),
                  Expanded(
                    child: ListView.builder(
                      key: const ValueKey('servers-list'),
                      padding: const EdgeInsets.only(bottom: 16),
                      itemCount: servers.length,
                      itemBuilder: (context, index) => servers[index](),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
