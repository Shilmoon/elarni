part of 'desktop_proxy.dart';

extension _ProxyCommands on DesktopProxy {
  Future<CatalogMap> _invoke(
    String method,
    CatalogMap? arguments, {
    bool automatic = false,
  }) async {
    if (_disposed) throw desktopError('cancelled');
    if (method == 'disconnect') {
      return _disconnecting ??= () async {
        _automation.manualStop();
        await _disconnect();
        // Stop must clear persisted intent even as the first command. Loading
        // replaces the automation object, so stop the restored episode too.
        await _initialize();
        _automation.manualStop();
        _state = 'disconnected';
        if (!_storageLost) await _persistAutomation();
        return <String, Object?>{'state': _state};
      }().whenComplete(() => _disconnecting = null);
    }
    if (method == 'openUpdateLink') {
      // The page an update feed named needs no catalog.
      final url = arguments?['url'];
      if (url is! String || !isHttpsURL(url)) throw desktopError('invalid_url');
      return _platformRequest('openURL', {'url': url});
    }
    final readOnly = {
      'state',
      'subscriptions',
      'routingProfiles',
      'tunnelSettings',
      'automationStatus',
      'runtimeMetrics',
      'readLogs',
      'nodeConfig',
      'inboundCredentials',
    }.contains(method);
    // Stop publishes "disconnected" before it saves the cleared intent; a
    // Connect issued in that window follows the Stop instead of failing busy.
    if (method == 'connect' && !automatic && _disconnecting != null)
      await _disconnecting!.catchError((Object _) => <String, Object?>{});
    if (_disconnecting != null && !readOnly) throw desktopError('busy');
    final stopGeneration = _linkStopGeneration;
    await _initialize();
    if (_disposed || !readOnly && stopGeneration != _linkStopGeneration)
      throw desktopError('cancelled');
    if (_storageLost) throw desktopError('storage_unavailable');
    final args = arguments ?? <String, Object?>{};
    switch (method) {
      case 'state':
        return {
          'state': _state,
          if (_state == 'connected') 'liveness': _liveness,
        };
      case 'subscriptions':
        return _catalog!.snapshot();
      case 'routingProfiles':
        return _catalog!.routingSnapshot();
      case 'tunnelSettings':
        return _catalog!.settingsSnapshot();
      case 'inboundCredentials':
        return catalogMap(_catalog!.data['inboundCredentials'] ?? {});
      case 'connect':
        if (!automatic) {
          final generation = await _interruptManualProbes();
          // A scheduled refresh can hold the controller while it reads
          // disconnected; queue behind it instead of failing busy.
          while (_operation != null) await _operation!.future;
          _checkGeneration(generation);
          _automation.intent = true;
          _automation.rearm(_now);
          await _persistAutomation();
        }
        try {
          return await _connectPreparingLostAssets();
        } on PlatformException catch (error) {
          // Recovery must not repeat a consent prompt the user declined; one
          // that timed out unanswered is asked again by the next retry.
          if (error.code == 'elevation_denied' ||
              error.code == 'vpn_guard_stale' &&
                  error.details == 'elevation_denied') {
            _automation.manualStop();
            await _persistAutomation();
          }
          rethrow;
        }
      case 'configureAutomation':
        final configuration = {...args}..remove('selectedNodeId');
        final selected = unattended ? args['selectedNodeId'] as String? : null;
        final proposed = _catalog!.copy();
        if (selected != null) proposed.data['selectedNodeId'] = selected;
        DesktopAutomation.validate(configuration, proposed);
        _automation.invalidate();
        if (_automationBusy) await _operation?.future;
        await _mutate((candidate) async {
          if (selected != null) candidate.data['selectedNodeId'] = selected;
          candidate.data['automation'] = copyCatalog(configuration);
          return {};
        });
        _automation.rearm(_now);
        _automation.status = args['enabled'] == true
            ? 'waitingForPath'
            : 'disabled';
        _candidateFailures.clear();
        await _persistAutomation();
        return _automationStatus();
      case 'automationStatus':
        return _automationStatus();
      case 'systemInfo':
        // Asked once: each question starts a core process.
        try {
          _coreVersion ??=
              (await _native('xrayVersion', {}))['version'] as String?;
        } on Object {
          // The page is still useful without the core's version.
        }
        Object? vpnService;
        if (Platform.isWindows) {
          try {
            vpnService = (await _native('vpnServiceStatus', {}))['enabled'];
          } on Object {
            // The row then reads as off.
          }
        }
        return {
          ...await _platformRequest(method, args),
          'os': Platform.operatingSystemVersion,
          'appVersion': ?desktopAppVersion,
          'coreVersion': ?_coreVersion,
          'vpnService': ?vpnService,
        };
      case 'setVPNService':
        if (!Platform.isWindows) throw desktopError('unsupported_method');
        // The consent prompt waits for the user.
        final service = await _native('setVPNService', {
          'enabled': args['enabled'] == true,
        }, timeout: const Duration(seconds: 90));
        return {'vpnService': service['enabled']};
      // Settings replace their system info with this reply.
      case 'setLaunchAtLogin':
        return {
          ...await _platformRequest(method, args),
          'appVersion': ?desktopAppVersion,
        };
      case 'routeTable':
        return _platformRequest(method, args);
      case 'runtimeMetrics':
        return _runtimeMetrics();
      case 'pingNode':
        // The timeout reaches PowerShell and process deadlines; the UI offers 5-15 s.
        final pingTimeout = args['timeout'];
        if (pingTimeout is! int || pingTimeout < 1 || pingTimeout > 60)
          throw desktopError('invalid_request');
        final exclusive = args['protocol'] == 'icmp';
        if (_interruptingProbes ||
            (_operation != null && (exclusive || _manualProbes == 0)) ||
            {'connecting', 'disconnecting'}.contains(_state))
          throw desktopError('busy');
        final done = _operation ??= Completer<void>();
        if (!exclusive) _manualProbes++;
        try {
          return await (exclusive
              ? _pingICMP(args, _generation)
              : _ping(args, _generation));
        } finally {
          if (exclusive || --_manualProbes == 0) {
            _operation = null;
            done.complete();
          }
        }
      case 'readLogs':
        final after = args['after'] is int ? args['after']! as int : 0;
        return {
          'level': _catalog!.settings.logLevel,
          'entries': [
            for (final line in _logs)
              if ((line['seq']! as int) > after) line,
          ],
          'last': _logSeq,
        };
      case 'saveLogs':
        final content = args['content'];
        if (content is! String || content.isEmpty)
          throw desktopError('invalid_settings');
        await _platformRequest('saveLogs', {'content': content});
        return {};
      case 'exportEvidence':
        final evidence = connectionDiagnostics(
          platform: Platform.isLinux ? 'linux' : 'windows',
          state: _state,
          provider: _runtimeMetrics(),
          automation: _automationStatus(),
          issueCodes: (args['issueCodes'] as List? ?? []).whereType<String>(),
        );
        if (args['headless'] != true)
          await _platformRequest('saveEvidence', {
            'content': jsonEncode(evidence),
          });
        return evidence;
      case 'markRecording' when recordingBuild:
        await _native('diagnostics', {'action': 'mark'});
        return {};
      case 'exportRecording' when recordingBuild:
        if (args['headless'] == true) {
          await _native('diagnostics', {
            'action': 'export',
            'destination': args['destination'],
          });
          return {};
        }
        // The ZIP is built first, so an empty recording says so before any dialog.
        final temporary = await Directory.systemTemp.createTemp('elarni-');
        try {
          final source = '${temporary.path}${Platform.pathSeparator}rec.zip';
          await _native('diagnostics', {
            'action': 'export',
            'destination': source,
          });
          final picked = await _platformRequest('pickRecordingPath', {});
          try {
            await File(source).copy(picked['path']! as String);
          } on FileSystemException {
            throw desktopError('recording_failed');
          }
        } finally {
          await temporary.delete(recursive: true).catchError((Object _) {
            return temporary;
          });
        }
        return {};
      case 'exportCatalogBackup':
        final backup = _catalog!.backup();
        final CatalogMap sealed;
        try {
          sealed = await _native('sealCatalogBackup', {
            'catalog': backup,
            'password': args['password'],
          });
        } on PlatformException catch (error) {
          // Sealing validates like restore; the UI checks the password first.
          if (error.code == 'invalid_backup')
            throw desktopError('backup_unsupported');
          rethrow;
        }
        if (args['headless'] == true) return {'text': sealed['text']};
        await _platformRequest('saveBackup', {'content': sealed['text']});
        return {};
      case 'restoreCatalogBackup':
        if (_operation != null ||
            !{'disconnected', 'prepared', 'failed'}.contains(_state)) {
          throw desktopError('busy');
        }
        await _invoke('disconnect', {});
        final generation = _generation;
        final text = args['headless'] == true
            ? args['content'] as String
            : await _importContent('backup', null);
        _checkGeneration(generation);
        if (!{'disconnected', 'prepared', 'failed'}.contains(_state))
          throw desktopError('busy');
        final restored = await _mutate((candidate) async {
          final opened = await _native('openCatalogBackup', {
            'text': text,
            'password': args['password'],
          });
          final validated = await _native('validateCatalogBackup', {
            'catalog': opened['catalog'],
          });
          candidate.restoreBackup(catalogMap(validated['catalog']));
          return candidate.snapshot();
        }, refreshAssets: false);
        _challenges.clear();
        return restored;
      case 'repairTunnel':
        await _invoke('disconnect', {});
        if (_operation != null || _state != 'disconnected')
          throw desktopError('busy');
        final done = _operation = Completer<void>();
        try {
          final session = _vpnSession;
          await _reap(session);
          if (_vpnSession == session) _vpnSession = null;
          // A stopped helper's DNS guard stays until a helper removes it.
          if (Platform.isWindows || Platform.isLinux)
            await _native(
              'clearVPNGuard',
              {},
              timeout: const Duration(seconds: 90),
            );
          return {'state': _state};
        } finally {
          _operation = null;
          done.complete();
        }
      // Showing a server's config is subject to the same provider limits as sharing it.
      case 'shareClient':
      case 'nodeConfig':
        final id = args['id']! as String;
        final subscription =
            method == 'shareClient' && args['subscription'] == true;
        final source = subscription
            ? _catalog!.source(id)
            : _catalog!.sources.firstWhere(
                (source) => catalogList(
                  source['nodes'],
                ).any((node) => node['id'] == id),
                orElse: () => throw desktopError('not_found'),
              );
        if (catalogMap(source['metadata'] ?? {})['hideURL'] == true)
          throw desktopError('sharing_disabled');
        if (source['url'] != null &&
            catalogMap(source['metadata'] ?? {})['hideURL'] == null)
          throw desktopError('sharing_refresh_required');
        String text;
        if (subscription) {
          if (source['url'] == null) throw desktopError('invalid_profile');
          text = (source['shareLink'] ?? source['url'])! as String;
        } else {
          final node = _catalog!.node(id);
          if (node['hideURL'] == true) throw desktopError('sharing_disabled');
          if (method == 'nodeConfig') {
            if (node['format'] != 'xrayProfile')
              throw desktopError('unsupported_profile');
            return {'config': node['config']};
          }
          if (node['format'] == 'telegram') {
            text = catalogMap(node['config'])['url']! as String;
          } else {
            text = jsonEncode({
              ...catalogMap(node['config']),
              'remarks': node['manualName'] ?? node['name'],
            });
          }
        }
        return {
          'text': text,
          ...await _native('clientQR', {'text': text}),
        };
      case 'openTelegramProxy':
        final node = _catalog!.node(args['id']! as String);
        if (node['format'] != 'telegram') throw desktopError('invalid_profile');
        final url = catalogMap(node['config'])['url']! as String;
        final parsed = catalogList(
          (await _native('importClientProfiles', {'text': url}))['profiles'],
        );
        if (parsed.length != 1 || parsed.single['format'] != 'telegram')
          throw desktopError('invalid_url');
        return _platformRequest('openURL', {'url': parsed.single['url']});
      case 'subscriptionDeviceID':
        return _native(
          'subscriptionDeviceID',
          _catalog!.deviceIdentity(args['id']! as String),
        );
      case 'openProviderLink':
        final source = _catalog!.source(args['id']! as String);
        if (!{'support', 'account', 'banner'}.contains(args['action']))
          throw desktopError('invalid_action');
        final url = DesktopCatalog.safeURL(
          catalogMap(source['links'] ?? {})[args['action']],
        );
        if (url == null) throw desktopError('invalid_url');
        return _platformRequest('openURL', {'url': url});
    }
    const mutations = {
      'importClientProfiles',
      'addSubscription',
      'refreshSubscription',
      'selectNode',
      'selectProfileGroup',
      'setNodeIPPreference',
      'setNodeFavorite',
      'renameNode',
      'deleteNode',
      'deleteNodes',
      'showNode',
      'updateNodeConfig',
      'renameSubscription',
      'resetSubscriptionDeviceID',
      'updateSubscriptionFetchOptions',
      'deleteSubscription',
      'updateTunnelSettings',
      'updateInboundCredentials',
      'importRouting',
      'updateRoutingProfile',
      'duplicateRoutingProfile',
      'deleteRoutingProfile',
      'resetRoutingProfile',
      'setRoutingProfileEnabled',
      'assignRoutingProfile',
      'refreshRoutingGeofiles',
    };
    if (!mutations.contains(method))
      throw desktopError('unsupported_operation');
    if (!automatic) {
      _automation.invalidate();
      if (_automationBusy) await _operation?.future;
      if (_automation.intent) _automation.healthAt = _now;
    }
    PlatformException? refreshError;
    final result = await _mutate((candidate) async {
      CatalogMap? warning;
      String addSource(CatalogMap input) {
        final id = candidate.addSource(input['text']! as String);
        final source = candidate.source(id);
        final name = candidate.display(input['name']);
        candidate.putSource({
          ...source,
          if (input['shareLink'] is String) 'shareLink': input['shareLink'],
          if (name != null) ...{
            'importedName': name,
            if (source['manualName'] == null && source['providerName'] == null)
              'name': name,
          },
        });
        return id;
      }

      Future<void> refresh(String id) async {
        List<String>? approval;
        var format = args['format'] as String?;
        if (args['challenge'] != null) {
          final challenge = _challenges.remove(args['challenge']);
          if (challenge == null ||
              challenge.id != id ||
              DateTime.now().isAfter(challenge.expires) ||
              format != null && format != challenge.format)
            throw desktopError('invalid_challenge');
          approval = challenge.chain;
          format = challenge.format;
        }
        final beforeRefresh = copyCatalog(candidate.data);
        try {
          warning = await candidate.refresh(
            id,
            approval: approval,
            format: format,
          );
        } on PlatformException catch (error) {
          candidate.data
            ..clear()
            ..addAll(beforeRefresh);
          candidate.refreshFailed(id, error.code);
          refreshError = error;
        }
        final pending = warning;
        if (pending != null) {
          _challenges.removeWhere(
            (_, value) =>
                value.id == id || DateTime.now().isAfter(value.expires),
          );
          final token = desktopID();
          _challenges[token] = (
            id: id,
            format: pending['format']! as String,
            chain: List<String>.from(pending['chain']! as List),
            expires: DateTime.now().add(const Duration(minutes: 5)),
          );
          warning = {
            'subscriptionId': id,
            'riskCodes': pending['riskCodes'],
            'challenge': token,
          };
        }
      }

      switch (method) {
        case 'importClientProfiles':
          final input = await _native('normalizeClientInput', {
            'text': await _importContent(
              args['source'] as String? ?? 'text',
              args['content'],
            ),
          });
          final content = input['text']! as String;
          final url = DesktopCatalog.safeURL(content.trim());
          final parsed = url == null ? null : Uri.parse(url);
          if (candidate.isRoutingInput(content)) {
            candidate.importRouting(content);
          } else if (parsed != null &&
              parsed.path.isNotEmpty &&
              parsed.path != '/' &&
              !({'t.me', 'telegram.me'}.contains(parsed.host) &&
                  parsed.path == '/proxy')) {
            await refresh(addSource({...input, 'text': url!}));
          } else {
            await candidate.importLocal(content);
          }
        case 'addSubscription':
        case 'refreshSubscription':
          final id = method == 'addSubscription'
              ? addSource(
                  await _native('normalizeClientInput', {'text': args['url']}),
                )
              : args['id']! as String;
          await refresh(id);
        case 'selectNode':
          if (candidate.node(args['id']! as String)['format'] != 'xrayProfile')
            throw desktopError('unsupported_profile');
          candidate.data['selectedNodeId'] = args['id'];
          if (_automationConfig['enabled'] == true) {
            final source = candidate.sources.firstWhere(
              (source) => catalogList(
                source['nodes'],
              ).any((node) => node['id'] == args['id']),
            );
            // The picked server becomes the primary; the allowed backups stay.
            final ids = [
              args['id']! as String,
              if (_automationConfig['policy'] != 'fixed')
                ...(_automationConfig['nodeIDs']! as List).cast<String>().where(
                  (id) => id != args['id'],
                ),
            ].take(1000).toList();
            candidate.data['automation'] = {
              ..._automationConfig,
              'subscriptionID': source['id'],
              'nodeIDs': ids,
              if (_automationConfig['russianEntryNodeIDs'] case final List old)
                'russianEntryNodeIDs': old.where(ids.contains).toList(),
            };
          }
        case 'setNodeIPPreference':
          candidate.setNodeIPPreference(
            args['nodeId']! as String,
            args['preference'],
          );
        case 'setNodeFavorite':
          if (args['favorite'] is! bool) throw desktopError('invalid_settings');
          candidate.updateNode(args['nodeId']! as String, {
            'favorite': args['favorite'],
          });
        case 'renameNode':
          final text = (args['name'] as String?)?.trim() ?? '';
          final name = candidate.display(text);
          if (text.isNotEmpty && (name == null || name.length > 256))
            throw desktopError('invalid_name');
          // `name` stays the provider's, which refresh matches on.
          candidate.updateNode(args['nodeId']! as String, {'manualName': name});
        case 'deleteNode':
          candidate.deleteNode(args['nodeId']! as String);
        case 'deleteNodes':
          // One save for a whole selection; any refusal keeps every server.
          for (final id in args['nodeIds']! as List)
            candidate.deleteNode(id as String);
        case 'showNode':
          candidate.showNode(args['nodeId']! as String);
        case 'updateNodeConfig':
          await candidate.replaceNodeConfig(
            args['nodeId']! as String,
            args['content']! as String,
          );
        case 'selectProfileGroup':
          candidate.selectGroup(
            args['nodeId']! as String,
            args['group']! as String,
            args['choice']! as String,
          );
        case 'updateSubscriptionFetchOptions':
          final source = candidate.source(args['id']! as String);
          final options = catalogMap(args['options']);
          final hosts = List<String>.from(
            options['fallbackHosts'] as List? ?? [],
          );
          if (source['url'] == null ||
              options.keys.any(
                (key) => !{
                  'fallbackHosts',
                  'userAgent',
                  'connectAddress',
                  'httpHost',
                  'fragmentLength',
                  'fragmentInterval',
                  'refreshHours',
                }.contains(key),
              ) ||
              // Snapshots read the stored options as text.
              options.entries.any(
                (entry) =>
                    entry.key != 'fallbackHosts' && entry.value is! String,
              ) ||
              hosts.length > 8 ||
              hosts.any((host) => !SubscriptionGroup.validFallbackHost(host)) ||
              options['refreshHours'] != null &&
                  !RegExp(
                    r'^([1-9]|[1-9][0-9]|1[0-5][0-9]|16[0-8])$',
                  ).hasMatch(options['refreshHours']! as String)) {
            throw desktopError('invalid_settings');
          }
          await _native('validateSubscriptionFetchOptions', {
            'url': source['url'],
            for (final entry in options.entries)
              if (entry.key != 'refreshHours') entry.key: entry.value,
          });
          candidate.putSource({
            ...source,
            'fallbackHosts': hosts.toSet().toList(),
            'fetchOptions': {
              for (final entry in options.entries)
                if (entry.key != 'fallbackHosts') entry.key: entry.value,
            },
          });
        case 'resetSubscriptionDeviceID':
          final source = candidate.source(args['id']! as String);
          if (source['url'] == null) throw desktopError('invalid_profile');
          // A random key of the subscription's own; every refresh sends the ID it makes.
          candidate.putSource({...source, 'deviceSalt': desktopID()});
        case 'renameSubscription':
          final source = candidate.source(args['id']! as String);
          final text = (args['name'] as String?)?.trim();
          final name = candidate.display(text);
          if (text != null &&
              text.isNotEmpty &&
              (name == null || name.length > 256))
            throw desktopError('invalid_name');
          candidate.putSource({
            ...source,
            'manualName': name,
            'name':
                name ??
                source['providerName'] ??
                source['importedName'] ??
                (source['url'] == null
                    ? 'Local profiles'
                    : Uri.parse(source['url']! as String).host),
          });
        case 'deleteSubscription':
          final id = candidate.source(args['id']! as String)['id'];
          candidate.data['subscriptions'] = candidate.sources
              .where((item) => item['id'] != id)
              .toList();
          candidate.data['assignments'] = candidate.assignments..remove(id);
          candidate.data['profiles'] = candidate.routes
              .where((item) => item['providerSubscriptionId'] != id)
              .toList();
          final validRoutes = candidate.routes
              .map((item) => item['id'])
              .toSet();
          candidate.data['assignments'] = candidate.assignments
            ..removeWhere((_, value) => !validRoutes.contains(value));
          candidate.reconcileSelection();
          // Recovery starts from the selected server, so it turns off with it.
          if (candidate.selected == null &&
              _automationConfig['enabled'] == true)
            candidate.data['automation'] = {
              ...catalogMap(candidate.data['automation']),
              'enabled': false,
            };
        case 'updateTunnelSettings':
          final settings = TunnelSettings.fromMap(args);
          candidate.data['settings'] = settings
              .copyWith(
                includedRoutes: _canonicalRoutes(settings.includedRoutes),
                excludedRoutes: _canonicalRoutes(settings.excludedRoutes),
              )
              .toMap();
        case 'updateInboundCredentials':
          final username = args['username'], password = args['password'];
          final controls = RegExp(r'[\x00-\x1f\x7f-\x9f]');
          if (username is! String ||
              password is! String ||
              utf8.encode(username).isEmpty ||
              utf8.encode(username).length > 255 ||
              utf8.encode(password).isEmpty ||
              utf8.encode(password).length > 255 ||
              username.contains(':') ||
              controls.hasMatch(username) ||
              controls.hasMatch(password))
            throw desktopError('invalid_settings');
          candidate.data['inboundCredentials'] = {
            'username': username,
            'password': password,
          };
          candidate.data['settings'] = candidate.settings
              .copyWith(inboundAuthEnabled: true)
              .toMap();
        case 'importRouting':
        case 'updateRoutingProfile':
          candidate.importRouting(
            await _importContent('text', args['content']),
            update: method == 'updateRoutingProfile'
                ? args['id']! as String
                : null,
          );
        case 'duplicateRoutingProfile':
          final old = candidate.route(args['id']! as String);
          final profile = {
            ...catalogMap(old['profile']),
            'Name': '${old['name']} copy',
          };
          candidate.putRoute({
            ...copyCatalog(old),
            'id': desktopID(),
            'name': '${old['name']} copy',
            'profile': profile,
            'original': profile,
            'source': 'local',
            'providerSubscriptionId': null,
            'edited': false,
          });
        case 'deleteRoutingProfile':
          final id = candidate.route(args['id']! as String)['id'];
          candidate.data['profiles'] = candidate.routes
              .where((item) => item['id'] != id)
              .toList();
          candidate.data['assignments'] = candidate.assignments
            ..removeWhere((_, value) => value == id);
        case 'resetRoutingProfile':
          final old = candidate.route(args['id']! as String);
          candidate.importRouting(
            jsonEncode(old['original']),
            update: old['id']! as String,
          );
          candidate.putRoute({
            ...candidate.route(old['id']! as String),
            'edited': false,
          });
        case 'setRoutingProfileEnabled':
          if (args['enabled'] is! bool) throw desktopError('invalid_routing');
          candidate.putRoute({
            ...candidate.route(args['id']! as String),
            'enabled': args['enabled'],
          });
        case 'assignRoutingProfile':
          candidate.assignRouting(
            candidate.source(args['subscriptionId']! as String)['id']!
                as String,
            args['profileId'] == null
                ? null
                : candidate.route(args['profileId']! as String)['id']!
                      as String,
          );
        case 'refreshRoutingGeofiles':
          try {
            await _refreshGeofiles(
              candidate,
              args['id']! as String,
              refresh: true,
              file: args['file'] as String?,
            );
          } on PlatformException catch (error) {
            candidate.geofilesFailed(args['id']! as String, error.message);
            refreshError = error;
          }
      }
      return switch (method) {
        'importClientProfiles' ||
        'addSubscription' ||
        'refreshSubscription' ||
        'setNodeIPPreference' ||
        'selectProfileGroup' => {
          'subscriptions': candidate.snapshot(),
          'warning': warning,
        },
        'selectNode' => {'subscriptions': candidate.snapshot()},
        'renameSubscription' ||
        'resetSubscriptionDeviceID' ||
        'setNodeFavorite' ||
        'renameNode' ||
        'deleteNode' ||
        'deleteNodes' ||
        'showNode' ||
        'updateNodeConfig' ||
        'deleteSubscription' ||
        'updateSubscriptionFetchOptions' => candidate.snapshot(),
        'updateTunnelSettings' ||
        'updateInboundCredentials' => candidate.settingsSnapshot(),
        _ => candidate.routingSnapshot(),
      };
    });
    if (refreshError != null) throw refreshError!;
    // A refresh that succeeded, scheduled or not, restarts the scheduled one's backoff.
    if (method == 'refreshSubscription')
      _refreshBackoff.remove('source:${args['id']}');
    if (method == 'refreshRoutingGeofiles')
      _refreshBackoff.remove('geo:${args['id']}');
    if (method == 'selectNode') result['state'] = _state;
    if (result.containsKey('profiles')) return _catalog!.routingSnapshot();
    return result;
  }

  Future<CatalogMap> _platformRequest(
    String method,
    CatalogMap payload,
  ) async => _platformIO != null
      ? _platformIO(method, payload)
      : await DesktopProxy._platform.invokeMapMethod<String, Object?>(
              method,
              payload,
            ) ??
            {};

  // The core sends lines already filtered and redacted; malformed ones are dropped.
  void _appendLogs(CatalogMap data) {
    for (final line in data['entries'] as List? ?? const []) {
      if (line is! Map ||
          line['time'] is! int ||
          !TunnelSettings.logLevels.contains(line['level']) ||
          line['text'] is! String)
        continue;
      _logs.add({
        'seq': ++_logSeq,
        'time': line['time'],
        'level': line['level'],
        'text': line['text'],
      });
    }
    if (_logs.length > 1000) _logs.removeRange(0, _logs.length - 1000);
  }

  CatalogMap _runtimeMetrics() => {
    'schemaVersion': 1,
    'state': _state,
    'backend': _catalog!.settings.xrayTunEnabled ? 'xrayTun' : 'xrayProxy',
    'timestamp': (_metricsAt ?? DateTime.now()).millisecondsSinceEpoch / 1000,
    'metricsAvailable':
        _state == 'connected' &&
        _metricsAt != null &&
        DateTime.now().difference(_metricsAt!).inSeconds < 5,
    'connectedSince': _state == 'connected'
        ? _connectedAt?.millisecondsSinceEpoch
        : null,
    'counters': _state == 'connected' ? _latestMetrics : <String, Object?>{},
    'liveness': _state == 'connected' ? _liveness : null,
  };
}
