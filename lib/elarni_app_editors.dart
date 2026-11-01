part of 'elarni_app.dart';

extension _HomeEditors on _ElarniHomeState {
  Future<void> _troubleshoot() async {
    await _showEditorDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, refresh) {
          _troubleshootRefresh = (update) {
            if (context.mounted) refresh(update);
          };
          return AlertDialog(
            title: Text(l10n.connectionTroubleshooting),
            scrollable: true,
            content: SizedBox(
              width: 500,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _stateAvailable
                        ? l10n.connectionStateLine(_state.name)
                        : l10n.connectionStatusUnavailable,
                  ),
                  if (_healthLabel.isNotEmpty) Text(_healthLabel),
                  const SizedBox(height: 12),
                  Text(l10n.passingCheckScope),
                  if (_automation['enabled'] == true) ...[
                    const SizedBox(height: 12),
                    Text(
                      _automation['policy'] == 'fixed'
                          ? l10n.recoveryStaysOnServer
                          : l10n.recoveryTriesAllowedBackups,
                    ),
                    if (const {
                      'unsupportedPolicy',
                      'exhausted',
                      'exhaustedCandidates',
                      'invalidTarget',
                      'indeterminate',
                      'healthFailure',
                      'restorationFailed',
                    }.contains(_automation['status']))
                      Text(
                        ConnectionIssue.forCode(
                          _automation['status']! as String,
                        ).description,
                      ),
                  ],
                  for (final issue in _recentIssues.reversed)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(issue.description),
                    ),
                  const SizedBox(height: 16),
                  Text(l10n.diagnosticsContents),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () async {
                  await _refreshState();
                  await _refreshAutomation();
                  if (context.mounted) refresh(() {});
                },
                child: Text(l10n.refreshStatus),
              ),
              TextButton(
                onPressed:
                    _stateAvailable &&
                        _state == TunnelState.connected &&
                        !_busy &&
                        (_health != 'checking' ||
                            _healthNodeId != _selectedNode?.id)
                    ? () async {
                        final check = _checkConnection();
                        refresh(() {});
                        await check;
                        if (context.mounted) refresh(() {});
                      }
                    : null,
                child: Text(l10n.checkConnection),
              ),
              TextButton(
                onPressed:
                    !_busy &&
                        _stateAvailable &&
                        _selectedNode != null &&
                        (_canConnect || _state == TunnelState.connected)
                    ? () async {
                        final retry = _connect(retrySelected: true);
                        refresh(() {});
                        await retry;
                        if (context.mounted) refresh(() {});
                      }
                    : null,
                child: Text(l10n.retrySelectedServer),
              ),
              TextButton(
                onPressed: _exportDiagnostics,
                child: Text(l10n.exportDiagnostics),
              ),
              TextButton(onPressed: _openLogs, child: Text(l10n.logs)),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(l10n.close),
              ),
            ],
          );
        },
      ),
    );
    _troubleshootRefresh = null;
  }

  Future<void> _commitEditor(
    BuildContext dialogContext,
    Future<bool> Function() save,
  ) async {
    if (_busy) return;
    final route = ModalRoute.of(dialogContext);
    final bool saved;
    _editorSaving.value = true;
    try {
      saved = await save();
    } finally {
      _editorSaving.value = false;
    }
    if (saved && dialogContext.mounted && route?.isCurrent == true) {
      Navigator.pop(dialogContext);
    }
  }

  Future<void> _editListenerPorts() async {
    final socks = TextEditingController(text: '${_settings.socksPort}');
    final http = TextEditingController(text: '${_settings.httpPort}');
    String? error;
    await _showEditorDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(l10n.listenerPorts),
          scrollable: true,
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final entry in {
                  socks: l10n.socksPort,
                  http: l10n.httpPort,
                }.entries)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 18),
                    child: TextField(
                      controller: entry.key,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(5),
                      ],
                      decoration: InputDecoration(labelText: entry.value),
                    ),
                  ),
                if (error != null) Text(error!),
              ],
            ),
          ),
          actions: [
            _EditorCancelButton(saving: _editorSaving),
            FilledButton(
              onPressed: () async {
                if (_busy) return;
                final socksPort = int.tryParse(socks.text);
                final httpPort = int.tryParse(http.text);
                if (socksPort == null ||
                    httpPort == null ||
                    socksPort < 1 ||
                    socksPort > 65535 ||
                    httpPort < 1 ||
                    httpPort > 65535 ||
                    socksPort == httpPort) {
                  update(() => error = l10n.useDifferentPorts);
                  return;
                }
                await _commitEditor(
                  context,
                  () => _saveSettings(
                    _settings.copyWith(
                      socksPort: socksPort,
                      httpPort: httpPort,
                    ),
                  ),
                );
                if (context.mounted && _message != null)
                  update(() => error = _message);
              },
              child: Text(l10n.save),
            ),
          ],
        ),
      ),
    );
    socks.dispose();
    http.dispose();
  }

  Future<void> _editUpdateFeed() async {
    final controller = TextEditingController(
      text: widget.desktop.updateFeedURL,
    );
    String? error;
    await _showEditorDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(l10n.updateFeed),
          content: SizedBox(
            width: 420,
            child: TextField(
              key: const Key('update-feed-url'),
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                labelText: l10n.feedAddress,
                hintText: 'https://',
                helperText: l10n.feedEmptyTurnsOff,
                errorText: error,
                errorMaxLines: 3,
              ),
            ),
          ),
          actions: [
            _EditorCancelButton(saving: _editorSaving),
            FilledButton(
              onPressed: () {
                final url = controller.text.trim();
                if (url.isNotEmpty && !isHttpsURL(url)) {
                  update(() => error = l10n.feedNeedsHttps);
                  return;
                }
                _commitEditor(context, () async {
                  try {
                    await widget.desktop.update(updateFeedURL: url);
                    return true;
                  } on Object {
                    if (context.mounted)
                      update(
                        () => error = widget.desktop.error ?? l10n.feedNotSaved,
                      );
                    return false;
                  }
                });
              },
              child: Text(l10n.save),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
  }

  Future<void> _editFragmentation() async {
    final packets = TextEditingController(text: _settings.fragmentPackets);
    final length = TextEditingController(text: _settings.fragmentLength);
    final interval = TextEditingController(text: _settings.fragmentInterval);
    String? error;
    await _showEditorDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(l10n.fragmentationOptions),
          scrollable: true,
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: packets,
                  maxLength: 11,
                  decoration: InputDecoration(
                    labelText: l10n.fragmentPackets,
                    helperText: l10n.fragmentPacketsHelp,
                  ),
                ),
                const SizedBox(height: 18),
                TextField(
                  controller: length,
                  maxLength: 11,
                  decoration: InputDecoration(
                    labelText: l10n.fragmentLengthBytes,
                    helperText: l10n.fragmentLengthHelp,
                  ),
                ),
                const SizedBox(height: 18),
                TextField(
                  controller: interval,
                  maxLength: 11,
                  decoration: InputDecoration(
                    labelText: l10n.intervalMs,
                    helperText: l10n.fragmentIntervalHelp,
                  ),
                ),
                if (error != null) Text(error!),
              ],
            ),
          ),
          actions: [
            _EditorCancelButton(saving: _editorSaving),
            FilledButton(
              onPressed: () async {
                if (_busy) return;
                final value = _settings.copyWith(
                  fragmentPackets: packets.text.trim(),
                  fragmentLength: length.text.trim(),
                  fragmentInterval: interval.text.trim(),
                );
                if (!value.validFragmentation) {
                  update(() => error = l10n.useValidRanges);
                } else {
                  await _commitEditor(context, () => _saveSettings(value));
                  if (context.mounted && _message != null)
                    update(() => error = _message);
                }
              },
              child: Text(l10n.save),
            ),
          ],
        ),
      ),
    );
    packets.dispose();
    length.dispose();
    interval.dispose();
  }

  Future<void> _editInboundCredentials() async {
    final username = TextEditingController();
    final password = TextEditingController();
    String? error;
    await _showEditorDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: ElarniHelpLabel(
            l10n.proxyAuthentication,
            help: l10n.proxyCredentialsStored,
          ),
          titleTextStyle: Theme.of(context).textTheme.titleLarge,
          titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
          contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          actionsOverflowButtonSpacing: 8,
          scrollable: true,
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.setProxyCredentials,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 24),
                Semantics(
                  label: l10n.username,
                  child: TextField(
                    controller: username,
                    autocorrect: false,
                    enableSuggestions: false,
                    textInputAction: TextInputAction.next,
                    decoration: InputDecoration(hintText: l10n.enterUsername),
                  ),
                ),
                const SizedBox(height: 20),
                Semantics(
                  label: l10n.password,
                  child: TextField(
                    controller: password,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(hintText: l10n.enterPassword),
                  ),
                ),
                if (error != null) ...[
                  const SizedBox(height: 16),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      error!,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.error,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            _EditorCancelButton(
              saving: _editorSaving,
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            FilledButton(
              onPressed: () async {
                if (_busy) return;
                if ([username.text, password.text].any(
                      (text) =>
                          text.isEmpty ||
                          utf8.encode(text).length > 255 ||
                          text.runes.any((rune) => rune < 32 || rune == 127),
                    ) ||
                    username.text.contains(':')) {
                  update(() => error = l10n.credentialRules);
                  return;
                }
                await _commitEditor(
                  context,
                  () => _saveInboundCredentials(username.text, password.text),
                );
                if (context.mounted && _message != null)
                  update(() => error = _message);
              },
              child: Text(l10n.saveAndEnable),
            ),
          ],
        ),
      ),
    );
    username.clear();
    password.clear();
    username.dispose();
    password.dispose();
  }

  Future<bool> _saveInboundCredentials(String username, String password) async {
    _set(() => _busy = true);
    try {
      final settings = await widget.tunnelControl.updateInboundCredentials(
        username,
        password,
      );
      if (mounted)
        _set(() {
          _settings = settings;
          _message = null;
        });
      await _loadInboundLogin();
      return true;
    } on Object {
      await _refreshSettings();
      if (mounted) _set(() => _message = l10n.credentialsNotApplied);
      return false;
    } finally {
      if (mounted) _set(() => _busy = false);
    }
  }

  Future<bool> _confirmICMP() async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l10n.runIcmpTestQuestion),
          content: Text(l10n.icmpDisconnectsTunnel),
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
      ) ??
      false;

  Future<void> _editRoutes({required bool included}) async {
    final controller = TextEditingController(
      text:
          (included
                  ? _perAppDraft!.settings.includedRoutes
                  : _perAppDraft!.settings.excludedRoutes)
              .join('\n'),
    );
    final value = await _showEditorDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(included ? l10n.includedRoutes : l10n.excludedRoutes),
        content: TextField(
          controller: controller,
          minLines: 6,
          maxLines: 12,
          decoration: InputDecoration(
            border: OutlineInputBorder(),
            hintText: l10n.oneCidrPerLine,
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: Text(l10n.save),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null) return;
    final routes = value
        .split(RegExp(r'\s+'))
        .where((route) => route.isNotEmpty)
        .toSet()
        .toList(growable: false);
    _set(
      () => _perAppDraft!.settings = included
          ? _perAppDraft!.settings.copyWith(includedRoutes: routes)
          : _perAppDraft!.settings.copyWith(excludedRoutes: routes),
    );
  }

  Future<void> _editTrustedWiFi() async {
    final controller = TextEditingController(
      text: _settings.trustedWiFiNetworks.join('\n'),
    );
    String? error;
    final names = await _showEditorDialog<List<String>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(l10n.trustedWifiNetworks),
          content: SizedBox(
            width: 460,
            child: TextField(
              controller: controller,
              minLines: 6,
              maxLines: 12,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                hintText: l10n.oneNetworkPerLine,
                errorText: error,
              ),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              onPressed: () {
                final names = controller.text
                    .split('\n')
                    .map((line) => line.trim())
                    .where((line) => line.isNotEmpty)
                    .toSet()
                    .toList(growable: false);
                if (_settings
                    .copyWith(trustedWiFiNetworks: names)
                    .validTrustedWiFi) {
                  Navigator.pop(context, names);
                } else {
                  update(() => error = l10n.trustedWifiRules);
                }
              },
              child: Text(l10n.save),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (names != null)
      await _saveSettings(_settings.copyWith(trustedWiFiNetworks: names));
  }

  Future<void> _catalogBackup({required bool restore}) async {
    final password = TextEditingController();
    final confirmation = TextEditingController();
    String? error;
    final secret = await _showEditorDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(
            restore ? l10n.restoreBackup : l10n.createEncryptedBackup,
          ),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    restore
                        ? l10n.restoreBackupReplacesHelp
                        : l10n.createBackupHelp,
                  ),
                  TextField(
                    controller: password,
                    obscureText: true,
                    maxLength: 1024,
                    decoration: InputDecoration(
                      labelText: l10n.backupPassword,
                      helperText: l10n.atLeast12Characters,
                    ),
                  ),
                  if (!restore)
                    TextField(
                      controller: confirmation,
                      obscureText: true,
                      maxLength: 1024,
                      decoration: InputDecoration(
                        labelText: l10n.confirmPassword,
                      ),
                    ),
                  if (error != null) Text(error!),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              onPressed: () {
                final bytes = utf8.encode(password.text).length;
                if (password.text.runes.length < 12 ||
                    bytes > 1024 ||
                    !restore && password.text != confirmation.text) {
                  update(() => error = l10n.backupPasswordRules);
                } else {
                  Navigator.pop(context, password.text);
                }
              },
              child: Text(
                restore ? l10n.chooseBackupAndRestore : l10n.saveBackup,
              ),
            ),
          ],
        ),
      ),
    );
    password.dispose();
    confirmation.dispose();
    if (secret == null || !mounted || _busy) return;
    _set(() => _busy = true);
    try {
      if (restore) {
        await widget.tunnelControl.restoreCatalogBackup(secret);
        await _load();
      } else {
        await widget.tunnelControl.exportCatalogBackup(secret);
      }
      if (mounted)
        _set(
          () => _message = restore
              ? l10n.backupRestored
              : l10n.encryptedBackupSaved,
        );
    } on PlatformException catch (error) {
      if (mounted &&
          !{'cancelled', 'operation_cancelled'}.contains(error.code)) {
        _set(
          () => _message = switch (error.code) {
            'sharing_disabled' => l10n.sharingDisabledByProvider,
            'sharing_refresh_required' => l10n.refreshBeforeBackup,
            'rollback_failed' => l10n.restoreRollbackFailed,
            'backup_unsupported' => l10n.backupUnsupported,
            _ => restore ? l10n.restoreFailedCheck : l10n.backupNotSavedCheck,
          },
        );
      }
      if (restore) await _load();
    } on Object {
      if (mounted)
        _set(
          () =>
              _message = restore ? l10n.backupNotRestored : l10n.backupNotSaved,
        );
    } finally {
      if (mounted) _set(() => _busy = false);
    }
  }

  Future<void> _shareSubscription(String id) async {
    _set(() => _busy = true);
    try {
      final shared = await widget.tunnelControl.shareClient(
        id,
        subscription: true,
      );
      final text = shared['text'] as String;
      final png = shared['png'] is String
          ? base64Decode(shared['png']! as String)
          : null;
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l10n.shareSubscription),
          scrollable: true,
          content: SizedBox(
            width: 384,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (png != null)
                  Image.memory(
                    png,
                    width: 384,
                    height: 384,
                    semanticLabel: l10n.connectionQrCode,
                  )
                else
                  Text(l10n.configTooLargeForQr),
                const SizedBox(height: 12),
                Text(l10n.anyoneCanUseDetails),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l10n.close),
            ),
            TextButton(
              onPressed: () async {
                try {
                  await Clipboard.setData(ClipboardData(text: text));
                  if (context.mounted) Navigator.pop(context);
                  if (mounted) _set(() => _message = null);
                } on Object {
                  if (mounted) _set(() => _message = l10n.copyDetailsFailed);
                }
              },
              child: Text(l10n.copy),
            ),
          ],
        ),
      );
    } on Object {
      if (mounted) _set(() => _message = l10n.sharingUnavailable);
    } finally {
      if (mounted) _set(() => _busy = false);
    }
  }

  Future<void> _editSubscriptionFetch(SubscriptionGroup group) async {
    final hosts = TextEditingController(text: group.fallbackHosts.join('\n'));
    final refresh = TextEditingController(
      text: group.fetchOptions['refreshHours'] ?? '',
    );
    final providerHours = group.metadata['updateIntervalHours'];
    final agent = TextEditingController(
      text: group.fetchOptions['userAgent'] ?? '',
    );
    final address = TextEditingController(
      text: group.fetchOptions['connectAddress'] ?? '',
    );
    final httpHost = TextEditingController(
      text: group.fetchOptions['httpHost'] ?? '',
    );
    final length = TextEditingController(
      text: group.fetchOptions['fragmentLength'] ?? '80-250',
    );
    final interval = TextEditingController(
      text: group.fetchOptions['fragmentInterval'] ?? '10-100',
    );
    var fragment = (group.fetchOptions['fragmentLength'] ?? '').isNotEmpty;
    String? error;
    await _showEditorDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(l10n.subscriptionDownloads),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: refresh,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: l10n.refreshEveryHoursOverride,
                      suffixText: providerHours is int
                          ? l10n.providerHours(providerHours)
                          : null,
                      helperText: providerHours is int
                          ? l10n.refreshFollowProviderHelp
                          : l10n.refreshFollowAppHelp(
                              _settings.subscriptionAutoUpdateHours,
                            ),
                      helperMaxLines: 2,
                    ),
                  ),
                  TextField(
                    controller: hosts,
                    minLines: 3,
                    maxLines: 8,
                    maxLength: 2048,
                    decoration: InputDecoration(
                      labelText: l10n.fallbackHosts,
                      helperText: l10n.fallbackHostsHelp,
                      helperMaxLines: 3,
                    ),
                  ),
                  Text(l10n.fallbackHostsWarning),
                  TextField(
                    controller: agent,
                    maxLength: 256,
                    decoration: InputDecoration(
                      labelText: l10n.userAgentOptional,
                      helperText: l10n.userAgentHelp,
                      helperMaxLines: 3,
                    ),
                  ),
                  TextField(
                    controller: address,
                    maxLength: 253,
                    decoration: InputDecoration(
                      labelText: l10n.connectAddressOptional,
                      helperText: l10n.connectAddressHelp,
                      helperMaxLines: 3,
                    ),
                  ),
                  TextField(
                    controller: httpHost,
                    maxLength: 253,
                    decoration: InputDecoration(
                      labelText: l10n.httpHostOptional,
                      helperText: l10n.httpHostHelp,
                      helperMaxLines: 3,
                    ),
                  ),
                  ElarniSwitchTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(l10n.fragmentClientHello),
                    value: fragment,
                    onChanged: (value) => update(() => fragment = value),
                  ),
                  if (fragment) ...[
                    TextField(
                      controller: length,
                      decoration: InputDecoration(
                        labelText: l10n.fragmentLengthBytes,
                        helperText: l10n.fragmentLengthRangeHelp,
                      ),
                    ),
                    TextField(
                      controller: interval,
                      decoration: InputDecoration(
                        labelText: l10n.fragmentIntervalMs,
                        helperText: l10n.fragmentIntervalRangeHelp,
                      ),
                    ),
                  ],
                  if (error != null) Text(error!),
                ],
              ),
            ),
          ),
          actions: [
            _EditorCancelButton(saving: _editorSaving),
            FilledButton(
              onPressed: () async {
                if (_busy) return;
                final values = hosts.text
                    .split('\n')
                    .map((host) => host.trim())
                    .where((host) => host.isNotEmpty)
                    .toSet()
                    .toList();
                final hours = refresh.text.trim();
                if (hours.isNotEmpty &&
                    !RegExp(
                      r'^([1-9]|[1-9][0-9]|1[0-5][0-9]|16[0-8])$',
                    ).hasMatch(hours)) {
                  update(() => error = l10n.refreshWholeHours);
                } else if (values.length > 8 ||
                    !values.every(SubscriptionGroup.validFallbackHost) ||
                    [address.text.trim(), httpHost.text.trim()].any(
                      (host) =>
                          host.isNotEmpty &&
                          !SubscriptionGroup.validFallbackHost(host),
                    ) ||
                    fragment &&
                        !const TunnelSettings()
                            .copyWith(
                              fragmentPackets: 'tlshello',
                              fragmentLength: length.text.trim(),
                              fragmentInterval: interval.text.trim(),
                            )
                            .validFragmentation) {
                  update(() => error = l10n.checkHostsAndRanges);
                } else {
                  final options = <String, Object?>{
                    'fallbackHosts': values,
                    // Omitted when empty: the saved options replace the old ones.
                    if (hours.isNotEmpty) 'refreshHours': hours,
                    if (agent.text.trim().isNotEmpty)
                      'userAgent': agent.text.trim(),
                    'connectAddress': address.text.trim(),
                    'httpHost': httpHost.text.trim(),
                    'fragmentLength': fragment ? length.text.trim() : '',
                    'fragmentInterval': fragment ? interval.text.trim() : '',
                  };
                  await _commitEditor(
                    context,
                    () => _saveSubscription(
                      () => widget.tunnelControl.updateSubscriptionFetchOptions(
                        group.id,
                        options,
                      ),
                      l10n.downloadOptionsNotSaved,
                    ),
                  );
                  if (context.mounted && _message != null)
                    update(() => error = _message);
                }
              },
              child: Text(l10n.save),
            ),
          ],
        ),
      ),
    );
    hosts.dispose();
    refresh.dispose();
    agent.dispose();
    address.dispose();
    httpHost.dispose();
    length.dispose();
    interval.dispose();
  }

  Future<void> _renameSubscription(SubscriptionGroup group) async {
    final controller = TextEditingController(text: group.name);
    await _showEditorDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.renameSubscription),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 256,
        ),
        actions: <Widget>[
          _EditorCancelButton(saving: _editorSaving),
          FilledButton(
            onPressed: () {
              final name = controller.text;
              _commitEditor(
                context,
                () => _saveSubscription(
                  () => widget.tunnelControl.renameSubscription(group.id, name),
                  l10n.renameFailed,
                ),
              );
            },
            child: Text(l10n.save),
          ),
        ],
      ),
    );
    controller.dispose();
  }

  Future<void> _renameNode(SubscriptionNode node) async {
    final controller = TextEditingController(text: node.name);
    await _showEditorDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.renameServer),
        content: Semantics(
          label: l10n.serverName,
          child: TextField(
            controller: controller,
            autofocus: true,
            maxLength: 256,
            decoration: InputDecoration(helperText: l10n.emptyUsesProviderName),
          ),
        ),
        actions: <Widget>[
          _EditorCancelButton(saving: _editorSaving),
          FilledButton(
            onPressed: () {
              final name = controller.text;
              _commitEditor(
                context,
                () => _saveSubscription(
                  () => widget.tunnelControl.renameNode(node.id, name),
                  l10n.renameFailed,
                ),
              );
            },
            child: Text(l10n.save),
          ),
        ],
      ),
    );
    controller.dispose();
  }

  Future<void> _editNodeConfig(
    SubscriptionNode node,
    SubscriptionGroup group,
  ) async {
    final String config;
    _set(() {
      _busy = true;
      _message = null;
    });
    try {
      config = await widget.tunnelControl.nodeConfig(node.id);
    } on Object catch (error) {
      if (mounted)
        _set(
          () => _message = switch (error) {
            PlatformException(code: 'sharing_disabled') =>
              l10n.providerHidesConfig,
            PlatformException(code: 'sharing_refresh_required') =>
              l10n.refreshToShowConfig(group.name),
            _ => l10n.serverConfigUnavailable,
          },
        );
      return;
    } finally {
      if (mounted) _set(() => _busy = false);
    }
    if (!mounted) return;
    final controller = TextEditingController(text: config);
    await _showEditorDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(ServerLocation.displayName(node.name)),
        scrollable: true,
        content: SizedBox(
          width: 720,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                key: const Key('node-config-json'),
                controller: controller,
                maxLines: 22,
                minLines: 12,
                // Windows has no generic 'monospace' family; Linux resolves it.
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontFamilyFallback: ['Consolas'],
                  fontSize: 13,
                ),
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Xray JSON',
                ),
              ),
              if (!group.isLocal) ...[
                const SizedBox(height: 8),
                Text(
                  l10n.nextRefreshReplacesEdits(group.name),
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () async {
              try {
                await Clipboard.setData(ClipboardData(text: controller.text));
              } on Object {
                if (mounted) _set(() => _message = l10n.copyConfigFailed);
              }
            },
            child: Text(l10n.copy),
          ),
          _EditorCancelButton(saving: _editorSaving),
          FilledButton(
            onPressed: () {
              final content = controller.text;
              _commitEditor(
                context,
                () => _saveSubscription(
                  () => widget.tunnelControl.updateNodeConfig(node.id, content),
                  l10n.configNotSaved,
                ),
              );
            },
            child: Text(l10n.validateAndSave),
          ),
        ],
      ),
    );
    controller.dispose();
  }

  Future<void> _deleteNode(
    SubscriptionNode node,
    SubscriptionGroup group,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          group.isLocal ? l10n.deleteServerQuestion : l10n.hideServerQuestion,
        ),
        content: Text(
          group.isLocal
              ? l10n.deleteNamedQuestion(node.name)
              : l10n.serverStaysHidden(node.name),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(group.isLocal ? l10n.delete : l10n.hide),
          ),
        ],
      ),
    );
    if (confirmed != true || _busy) return;
    await _saveSubscription(
      () => widget.tunnelControl.deleteNode(node.id),
      group.isLocal ? l10n.deleteFailed : l10n.hideFailed,
    );
  }

  Future<void> _deleteSelected(SubscriptionGroup group) async {
    final ids = [
      for (final node in group.nodes)
        if (_selectedServers.contains(node.id)) node.id,
    ];
    if (ids.isEmpty) return;
    final count = l10n.serverCount(ids.length);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          group.isLocal
              ? l10n.deleteCountQuestion(count)
              : l10n.hideCountQuestion(count),
        ),
        content: Text(
          group.isLocal
              ? l10n.serversRemovedFrom(group.name)
              : l10n.serversStayHidden,
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(group.isLocal ? l10n.delete : l10n.hide),
          ),
        ],
      ),
    );
    if (confirmed != true || _busy) return;
    if (await _saveSubscription(
          () => widget.tunnelControl.deleteNodes(ids),
          group.isLocal ? l10n.deleteFailed : l10n.hideFailed,
        ) &&
        mounted) {
      _set(() {
        _selectingSubscription = null;
        _selectedServers.clear();
      });
    }
  }

  Future<void> _resetDeviceID(SubscriptionGroup group) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.resetDeviceIdQuestion(group.name)),
        content: Text(l10n.deviceIdResetHelp(group.name)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.reset),
          ),
        ],
      ),
    );
    if (confirmed != true || _busy) return;
    if (await _saveSubscription(
          () => widget.tunnelControl.resetSubscriptionDeviceID(group.id),
          l10n.deviceIdNotReset,
        ) &&
        mounted) {
      _set(
        () =>
            _deviceIDs.removeWhere((key, _) => key.startsWith('${group.id}|')),
      );
    }
  }

  Future<void> _showHiddenServers(SubscriptionGroup group) async {
    final id = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.hiddenServers),
        content: SizedBox(
          width: 360,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final node in group.hiddenNodes)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(node.name),
                  trailing: TextButton(
                    onPressed: () => Navigator.pop(context, node.id),
                    child: Text(l10n.showAgain),
                  ),
                ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.close),
          ),
        ],
      ),
    );
    if (id == null || _busy) return;
    await _saveSubscription(
      () => widget.tunnelControl.showNode(id),
      l10n.showFailed,
    );
  }

  Future<void> _deleteSubscription(SubscriptionGroup group) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.deleteSubscriptionQuestion),
        content: Text(l10n.deleteSubscriptionNamedQuestion(group.name)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
    // A tray Connect may have started while the dialog was open.
    if (confirmed != true || _busy) return;
    _set(() => _busy = true);
    try {
      final value = await widget.tunnelControl.deleteSubscription(group.id);
      if (mounted) _set(() => _applySnapshot(value));
      await _refreshState();
    } on Object {
      if (mounted) _set(() => _message = l10n.deleteFailed);
    } finally {
      if (mounted) _set(() => _busy = false);
    }
  }

  Future<void> _editRouting(RoutingProfile profile) async {
    final controller = TextEditingController(text: profile.json);
    await _showEditorDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.editNamed(profile.name)),
        content: SizedBox(
          width: 720,
          child: TextField(
            controller: controller,
            maxLines: 22,
            minLines: 12,
            decoration: InputDecoration(
              border: OutlineInputBorder(),
              labelText: l10n.happRoutingJson,
            ),
          ),
        ),
        actions: <Widget>[
          _EditorCancelButton(saving: _editorSaving),
          FilledButton(
            onPressed: () {
              final content = controller.text;
              _commitEditor(
                context,
                () => _runRouting(
                  () => widget.tunnelControl.updateRoutingProfile(
                    profile.id,
                    content,
                  ),
                ),
              );
            },
            child: Text(l10n.validateAndSave),
          ),
        ],
      ),
    );
    controller.dispose();
  }

  Future<void> _editStructuredRouting(
    RoutingProfile profile, {
    int initialSection = 0,
  }) async {
    await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => RoutingEditor(
        json: profile.json,
        initialSection: initialSection,
        onSave: (content) => _runRouting(
          () => widget.tunnelControl.updateRoutingProfile(profile.id, content),
        ),
      ),
    );
  }

  Future<bool> _confirmRouting(
    String title,
    String message,
    String action,
  ) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        ),
      ) ==
      true;

  Future<void> _showRoutingDetails(String id) async {
    String? refreshError;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) {
          final profile = _routing.profiles
              .where((profile) => profile.id == id)
              .firstOrNull;
          // A refresh or another window can remove the profile while open.
          if (profile == null)
            return AlertDialog(
              title: Text(l10n.routingProfileRemoved),
              content: Text(l10n.routingProfileGone),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(l10n.close),
                ),
              ],
            );
          return AlertDialog(
            title: Text(profile.name),
            content: SizedBox(
              width: 520,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (refreshError != null)
                      Text(
                        refreshError!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    Text(
                      '${profile.fromSubscription ? l10n.subscriptionProfile : l10n.customProfile} · ${profile.edited ? l10n.profileEdited : l10n.originalVersion}',
                    ),
                    const SizedBox(height: 16),
                    Text(l10n.routingDataStatus(profile.geofileStatus)),
                    Text(l10n.reductionStatus(profile.reductionStatus)),
                    if (profile.skippedGeodata.isNotEmpty)
                      Text(
                        l10n.skippedGeodata(profile.skippedGeodata.join(', ')),
                      ),
                    if (profile.geofileError != null)
                      Text(
                        profile.geofileError!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    if (profile.managedError != null)
                      Text(
                        l10n.managedListsError(profile.managedError!),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    for (final file in profile.geofiles) ...[
                      const SizedBox(height: 20),
                      const Divider(),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text('${file['name']}'),
                        subtitle: Text(
                          l10n.geofileDetails(
                            '${file['bytes']}',
                            '${file['originalBytes']}',
                            '${file['updatedAt'] ?? l10n.unknown}',
                          ),
                        ),
                        trailing: IconButton(
                          tooltip: l10n.refreshNamed('${file['name']}'),
                          icon: const Icon(CupertinoIcons.arrow_clockwise),
                          onPressed: _busy
                              ? null
                              : () async {
                                  final result = _runRouting(
                                    () => widget.tunnelControl
                                        .refreshRoutingGeofiles(
                                          id,
                                          file: file['name'] as String,
                                        ),
                                  );
                                  update(() {});
                                  await result;
                                  if (context.mounted)
                                    update(() => refreshError = _message);
                                },
                        ),
                      ),
                      SelectableText(
                        '${file['source'] ?? ''}',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(l10n.done),
              ),
            ],
          );
        },
      ),
    );
  }
}
