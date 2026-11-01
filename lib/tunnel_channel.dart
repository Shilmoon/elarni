import 'dart:convert';
import 'dart:io';

import 'platform_services.dart';

/// Connection recording exists only in builds made with
/// `--dart-define=ELARNI_RECORDING=true`; release builds compile it out.
const recordingBuild = bool.fromEnvironment('ELARNI_RECORDING');

enum ConnectionAction {
  connect,
  disconnect,
  toggle,
  status;

  static ConnectionAction? fromLink(String value) {
    final uri = Uri.tryParse(value);
    if (value != value.trim() ||
        uri == null ||
        !{'elarni', 'incy', 'happ'}.contains(uri.scheme.toLowerCase()) ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/'))
      return null;
    return switch (uri.host.toLowerCase()) {
      'connect' || 'open' => connect,
      'disconnect' || 'close' => disconnect,
      'toggle' => toggle,
      'status' => status,
      _ => null,
    };
  }
}

enum AutomationSelectionPolicy { fixed, lowestLatency, orderedFallback }

final class AutomationTarget {
  const AutomationTarget({
    required this.id,
    required this.url,
    required this.expectedStatus,
    required this.expectedBody,
  });
  final String id;
  final String url;
  final int expectedStatus;
  final String expectedBody;

  Map<String, Object?> toMap() => {
    'id': id,
    'url': url,
    'expectedStatus': expectedStatus,
    'expectedBody': expectedBody,
  };
}

final class AutomationConfiguration {
  const AutomationConfiguration({
    required this.enabled,
    required this.policy,
    required this.subscriptionId,
    required this.nodeIds,
    required this.targets,
    this.russianEntryNodeIds = const [],
  });
  final bool enabled;
  final AutomationSelectionPolicy policy;
  final String subscriptionId;
  final List<String> nodeIds;
  final List<AutomationTarget> targets;

  /// Allowed servers labelled as entering through Russia, tried first while
  /// only they get through.
  final List<String> russianEntryNodeIds;

  Map<String, Object?> toMap() => {
    'schemaVersion': 1,
    'enabled': enabled,
    'policy': policy.name,
    'subscriptionID': subscriptionId,
    'nodeIDs': nodeIds,
    'russianEntryNodeIDs': russianEntryNodeIds,
    'targets': targets.map((target) => target.toMap()).toList(),
  };
}

enum TunnelState {
  disconnected,
  preparing,
  prepared,
  connecting,
  connected,
  disconnecting,
  reasserting,
  reconnecting,
  invalid,
  failed,
}

abstract interface class TunnelControl {
  void setImportListener(void Function(String? error)? listener);
  Future<SubscriptionSnapshot> setNodeFavorite(String nodeId, bool favorite);

  /// An empty name restores the provider's.
  Future<SubscriptionSnapshot> renameNode(String nodeId, String name);

  /// Refused for the selected server and a subscription's last one.
  Future<SubscriptionSnapshot> deleteNode(String nodeId);

  /// [deleteNode] for each server, all or none.
  Future<SubscriptionSnapshot> deleteNodes(List<String> nodeIds);
  Future<SubscriptionSnapshot> showNode(String nodeId);

  /// The X-HWID this subscription's provider gets.
  Future<String> subscriptionDeviceID(String id);

  /// Gives this subscription a new device ID; the others keep theirs.
  Future<SubscriptionSnapshot> resetSubscriptionDeviceID(String id);
  Future<Map<String, Object?>> configureAutomation(
    AutomationConfiguration configuration,
  );
  Future<Map<String, Object?>> automationStatus();
  Future<TunnelSettings> tunnelSettings();
  Future<TunnelSettings> updateTunnelSettings(TunnelSettings settings);
  Future<TunnelSettings> updateInboundCredentials(
    String username,
    String password,
  );

  /// The saved SOCKS/HTTP login (username, password), or empty without one.
  Future<Map<String, String>> inboundCredentials();
  Future<SubscriptionSnapshot> subscriptions();
  Future<SubscriptionOperationResult> addSubscription(String url);
  Future<SubscriptionOperationResult> refreshSubscription(
    String id, {
    String? challenge,
    String? format,
  });
  Future<void> openProviderLink(String id, String action);
  Future<void> openTelegramProxy(String id);

  /// Opens the https release page an update feed named.
  Future<void> openUpdateLink(String url);
  Future<Map<String, Object?>> shareClient(
    String id, {
    bool subscription = false,
  });

  /// The server's stored Xray JSON; refused where its provider hides it.
  Future<String> nodeConfig(String nodeId);

  /// The edit must still parse as one Xray server.
  Future<SubscriptionSnapshot> updateNodeConfig(String nodeId, String content);
  Future<SubscriptionOperationResult> importClientProfiles({
    String source = 'text',
    String? content,
  });
  Future<SubscriptionOperationResult> setNodeIPPreference(
    String nodeID,
    String? preference,
  );
  Future<SubscriptionOperationResult> selectProfileGroup(
    String nodeID,
    String group,
    String choice,
  );
  Future<SubscriptionSnapshot> renameSubscription(String id, String? name);
  Future<SubscriptionSnapshot> updateSubscriptionFetchOptions(
    String id,
    Map<String, Object?> options,
  );
  Future<void> exportCatalogBackup(String password);
  Future<SubscriptionSnapshot> restoreCatalogBackup(String password);
  Future<void> repairTunnel();
  Future<SubscriptionSnapshot> deleteSubscription(String id);
  Future<NodeSelectionResult> selectNode(String id);
  Future<RoutingSnapshot> routingProfiles();
  Future<RoutingSnapshot> importRouting(String content);
  Future<RoutingSnapshot> updateRoutingProfile(String id, String content);
  Future<RoutingSnapshot> duplicateRoutingProfile(String id);
  Future<RoutingSnapshot> deleteRoutingProfile(String id);
  Future<RoutingSnapshot> resetRoutingProfile(String id);
  Future<RoutingSnapshot> setRoutingProfileEnabled(String id, bool enabled);
  Future<RoutingSnapshot> assignRoutingProfile(
    String subscriptionId,
    String? profileId,
  );
  Future<RoutingSnapshot> refreshRoutingGeofiles(String id, {String? file});
  Future<String> connect();
  Future<String> disconnect();
  Future<String> state();

  /// Whether the connected server passes traffic, as of the last [state]:
  /// ok, noTraffic, or null when not checked yet.
  String? get liveness;
  Future<PingResult> pingNode(
    String nodeId, {
    required String protocol,
    required String method,
    required String mode,
    required int timeout,
    required String url,
    int expectedStatus = 204,
    String expectedBody = '',

    /// Reads Cloudflare's /cdn-cgi/trace at [url] to name the server's exit.
    bool trace = false,
  });
  Future<Map<String, Object?>> runtimeMetrics();

  /// The core log's redacted lines after seq [after], oldest first, with the
  /// current level: `{'level': String, 'entries': [{seq, time, level, text}]}`.
  Future<Map<String, Object?>> readLogs({int after = 0});

  /// Saves exported log text where the user chooses.
  Future<void> saveLogs(String text);
  Future<Map<String, Object?>> systemInfo();
  Future<Map<String, Object?>> routeTable();
  Future<Map<String, Object?>> setLaunchAtLogin(bool enabled);

  /// Windows: lets this account connect System-wide VPN through the Elarni VPN
  /// service, without a consent prompt each app session; changing it asks once.
  /// Returns `{'vpnService': bool}`.
  Future<Map<String, Object?>> setVPNService(bool enabled);
  Future<Map<String, Object?>> exportEvidence({
    List<String> issueCodes = const [],
  });

  /// Notes the moment the user saw a problem in the connection recording.
  Future<void> markRecording();

  /// Saves the connection recording as a ZIP the user picks a place for.
  Future<void> exportRecording();
}

final class NativeTunnelControl implements TunnelControl {
  NativeTunnelControl({
    Future<Map<String, Object?>> Function(String, Map<String, Object?>?)?
    invoke,
    void Function(void Function(String?)?)? importListener,
  }) : _invoke = invoke,
       _importListener = importListener;

  final void Function(void Function(String?)?)? _importListener;

  @override
  Future<SubscriptionSnapshot> setNodeFavorite(
    String nodeId,
    bool favorite,
  ) async => SubscriptionSnapshot.fromMap(
    await _mapResult('setNodeFavorite', {
      'nodeId': nodeId,
      'favorite': favorite,
    }),
  );

  @override
  Future<SubscriptionSnapshot> renameNode(String nodeId, String name) async =>
      SubscriptionSnapshot.fromMap(
        await _mapResult('renameNode', {'nodeId': nodeId, 'name': name}),
      );

  @override
  Future<SubscriptionSnapshot> deleteNode(String nodeId) async =>
      SubscriptionSnapshot.fromMap(
        await _mapResult('deleteNode', {'nodeId': nodeId}),
      );

  @override
  Future<SubscriptionSnapshot> deleteNodes(List<String> nodeIds) async =>
      SubscriptionSnapshot.fromMap(
        await _mapResult('deleteNodes', {'nodeIds': nodeIds}),
      );

  @override
  Future<SubscriptionSnapshot> showNode(String nodeId) async =>
      SubscriptionSnapshot.fromMap(
        await _mapResult('showNode', {'nodeId': nodeId}),
      );

  @override
  Future<String> subscriptionDeviceID(String id) async =>
      (await _mapResult('subscriptionDeviceID', {'id': id}))['deviceId']!
          as String;

  @override
  Future<SubscriptionSnapshot> resetSubscriptionDeviceID(String id) async =>
      SubscriptionSnapshot.fromMap(
        await _mapResult('resetSubscriptionDeviceID', {'id': id}),
      );

  final Future<Map<String, Object?>> Function(String, Map<String, Object?>?)?
  _invoke;
  static const MethodChannel _channel = MethodChannel('com.elarni/tunnel');

  @override
  void setImportListener(void Function(String? error)? listener) {
    if (_importListener != null) {
      _importListener(listener);
      return;
    }
    _channel.setMethodCallHandler(
      listener == null
          ? null
          : (call) async {
              if (call.method == 'subscriptionsChanged') {
                listener((call.arguments as Map?)?['error'] as String?);
              }
            },
    );
  }

  @override
  Future<Map<String, Object?>> configureAutomation(
    AutomationConfiguration configuration,
  ) => _mapResult('configureAutomation', configuration.toMap());

  @override
  Future<Map<String, Object?>> automationStatus() =>
      _mapResult('automationStatus');

  @override
  Future<TunnelSettings> updateInboundCredentials(
    String username,
    String password,
  ) async => TunnelSettings.fromMap(
    await _mapResult('updateInboundCredentials', <String, Object?>{
      'username': username,
      'password': password,
    }),
  );

  @override
  Future<Map<String, String>> inboundCredentials() async => {
    for (final MapEntry(:key, :value) in (await _mapResult(
      'inboundCredentials',
    )).entries)
      if (value is String) key: value,
  };

  @override
  Future<void> exportCatalogBackup(String password) async {
    await _mapResult('exportCatalogBackup', {'password': password});
  }

  @override
  Future<SubscriptionSnapshot> restoreCatalogBackup(String password) async =>
      SubscriptionSnapshot.fromMap(
        await _mapResult('restoreCatalogBackup', {'password': password}),
      );

  @override
  Future<void> repairTunnel() async {
    await _mapResult('repairTunnel', {});
  }

  @override
  Future<Map<String, Object?>> systemInfo() => _mapResult('systemInfo');

  @override
  Future<Map<String, Object?>> routeTable() => _mapResult('routeTable');

  @override
  Future<Map<String, Object?>> setLaunchAtLogin(bool enabled) =>
      _mapResult('setLaunchAtLogin', <String, Object?>{'enabled': enabled});

  @override
  Future<Map<String, Object?>> setVPNService(bool enabled) =>
      _mapResult('setVPNService', <String, Object?>{'enabled': enabled});

  @override
  Future<SubscriptionSnapshot> subscriptions() async =>
      SubscriptionSnapshot.fromMap(await _mapResult('subscriptions'));

  @override
  Future<SubscriptionOperationResult> addSubscription(String url) async {
    if (url.isEmpty || url.length > 16 * 1024) {
      throw const FormatException('Subscription URL is invalid.');
    }
    return SubscriptionOperationResult.fromMap(
      await _mapResult('addSubscription', <String, Object?>{'url': url}),
    );
  }

  @override
  Future<SubscriptionOperationResult> refreshSubscription(
    String id, {
    String? challenge,
    String? format,
  }) async => SubscriptionOperationResult.fromMap(
    await _mapResult('refreshSubscription', <String, Object?>{
      'id': id,
      'challenge': ?challenge,
      'format': ?format,
    }),
  );

  @override
  Future<void> openProviderLink(String id, String action) async {
    await _mapResult('openProviderLink', <String, Object?>{
      'id': id,
      'action': action,
    });
  }

  @override
  Future<void> openTelegramProxy(String id) async {
    await _mapResult('openTelegramProxy', <String, Object?>{'id': id});
  }

  @override
  Future<void> openUpdateLink(String url) async {
    await _mapResult('openUpdateLink', <String, Object?>{'url': url});
  }

  @override
  Future<Map<String, Object?>> shareClient(
    String id, {
    bool subscription = false,
  }) => _mapResult('shareClient', {'id': id, 'subscription': subscription});

  @override
  Future<String> nodeConfig(String nodeId) async =>
      const JsonEncoder.withIndent(
        '  ',
      ).convert((await _mapResult('nodeConfig', {'id': nodeId}))['config']);

  @override
  Future<SubscriptionSnapshot> updateNodeConfig(
    String nodeId,
    String content,
  ) async => SubscriptionSnapshot.fromMap(
    await _mapResult('updateNodeConfig', {
      'nodeId': nodeId,
      'content': content,
    }),
  );

  @override
  Future<SubscriptionOperationResult> importClientProfiles({
    String source = 'text',
    String? content,
  }) async => SubscriptionOperationResult.fromMap(
    await _mapResult('importClientProfiles', <String, Object?>{
      'source': source,
      'content': ?content,
    }),
  );

  @override
  Future<SubscriptionOperationResult> setNodeIPPreference(
    String nodeID,
    String? preference,
  ) async => SubscriptionOperationResult.fromMap(
    await _mapResult('setNodeIPPreference', <String, Object?>{
      'nodeId': nodeID,
      'preference': preference,
    }),
  );

  @override
  Future<SubscriptionOperationResult> selectProfileGroup(
    String nodeID,
    String group,
    String choice,
  ) async => SubscriptionOperationResult.fromMap(
    await _mapResult('selectProfileGroup', <String, Object?>{
      'nodeId': nodeID,
      'group': group,
      'choice': choice,
    }),
  );

  @override
  Future<SubscriptionSnapshot> renameSubscription(
    String id,
    String? name,
  ) async => SubscriptionSnapshot.fromMap(
    await _mapResult('renameSubscription', <String, Object?>{
      'id': id,
      'name': name,
    }),
  );

  @override
  Future<SubscriptionSnapshot> updateSubscriptionFetchOptions(
    String id,
    Map<String, Object?> options,
  ) async => SubscriptionSnapshot.fromMap(
    await _mapResult('updateSubscriptionFetchOptions', {
      'id': id,
      'options': options,
    }),
  );

  @override
  Future<SubscriptionSnapshot> deleteSubscription(String id) async =>
      SubscriptionSnapshot.fromMap(
        await _mapResult('deleteSubscription', <String, Object?>{'id': id}),
      );

  @override
  Future<NodeSelectionResult> selectNode(String id) async {
    final value = await _mapResult('selectNode', <String, Object?>{'id': id});
    return NodeSelectionResult(
      state: value['state'] as String? ?? 'failed',
      subscriptions: SubscriptionSnapshot.fromMap(
        Map<String, Object?>.from(value['subscriptions']! as Map),
      ),
    );
  }

  @override
  Future<RoutingSnapshot> routingProfiles() async =>
      RoutingSnapshot.fromMap(await _mapResult('routingProfiles'));

  @override
  Future<RoutingSnapshot> importRouting(String content) async {
    if (content.isEmpty || content.length > 4 * 1024 * 1024) {
      throw const FormatException('Routing input is invalid.');
    }
    return RoutingSnapshot.fromMap(
      await _mapResult('importRouting', <String, Object?>{'content': content}),
    );
  }

  @override
  Future<RoutingSnapshot> updateRoutingProfile(
    String id,
    String content,
  ) async => RoutingSnapshot.fromMap(
    await _mapResult('updateRoutingProfile', <String, Object?>{
      'id': id,
      'content': content,
    }),
  );

  @override
  Future<RoutingSnapshot> duplicateRoutingProfile(String id) async =>
      RoutingSnapshot.fromMap(
        await _mapResult('duplicateRoutingProfile', <String, Object?>{
          'id': id,
        }),
      );

  @override
  Future<RoutingSnapshot> deleteRoutingProfile(String id) async =>
      RoutingSnapshot.fromMap(
        await _mapResult('deleteRoutingProfile', <String, Object?>{'id': id}),
      );

  @override
  Future<RoutingSnapshot> resetRoutingProfile(String id) async =>
      RoutingSnapshot.fromMap(
        await _mapResult('resetRoutingProfile', <String, Object?>{'id': id}),
      );

  @override
  Future<RoutingSnapshot> setRoutingProfileEnabled(
    String id,
    bool enabled,
  ) async => RoutingSnapshot.fromMap(
    await _mapResult('setRoutingProfileEnabled', <String, Object?>{
      'id': id,
      'enabled': enabled,
    }),
  );

  @override
  Future<RoutingSnapshot> assignRoutingProfile(
    String subscriptionId,
    String? profileId,
  ) async => RoutingSnapshot.fromMap(
    await _mapResult('assignRoutingProfile', <String, Object?>{
      'subscriptionId': subscriptionId,
      'profileId': profileId,
    }),
  );

  @override
  Future<RoutingSnapshot> refreshRoutingGeofiles(
    String id, {
    String? file,
  }) async => RoutingSnapshot.fromMap(
    await _mapResult('refreshRoutingGeofiles', <String, Object?>{
      'id': id,
      'file': file,
    }),
  );

  @override
  Future<TunnelSettings> tunnelSettings() async =>
      TunnelSettings.fromMap(await _mapResult('tunnelSettings'));

  @override
  Future<TunnelSettings> updateTunnelSettings(TunnelSettings settings) async =>
      TunnelSettings.fromMap(
        await _mapResult('updateTunnelSettings', settings.toMap()),
      );

  @override
  Future<String> connect() => _stateResult('connect');

  @override
  Future<String> disconnect() => _stateResult('disconnect');

  @override
  Future<String> state() async {
    final value = await _mapResult('state');
    _liveness = value['liveness'] as String?;
    return value['state'] as String? ?? 'failed';
  }

  String? _liveness;
  @override
  String? get liveness => _liveness;

  @override
  Future<PingResult> pingNode(
    String nodeId, {
    required String protocol,
    required String method,
    required String mode,
    required int timeout,
    required String url,
    int expectedStatus = 204,
    String expectedBody = '',
    bool trace = false,
  }) async {
    if (nodeId.isEmpty ||
        !const <String>{
          'proxy',
          'activeProxy',
          'tcp',
          'icmp',
        }.contains(protocol) ||
        !const <String>{'GET', 'HEAD'}.contains(method) ||
        !const <String>{'default', 'double', 'keepalive'}.contains(mode) ||
        timeout < 5 ||
        timeout > 15 ||
        trace && (method != 'GET' || !protocol.endsWith('roxy'))) {
      throw const FormatException('Ping settings are invalid.');
    }
    // TCP and ICMP never use the URL, and settings hide it for them.
    final target = Uri.tryParse(url);
    if (const <String>{'proxy', 'activeProxy'}.contains(protocol) &&
        (target == null ||
            !target.isAbsolute ||
            !const <String>{'http', 'https'}.contains(target.scheme) ||
            target.userInfo.isNotEmpty)) {
      throw const FormatException('Ping URL is invalid.');
    }
    return PingResult.fromMap(
      await _mapResult('pingNode', <String, Object?>{
        'nodeId': nodeId,
        'protocol': protocol,
        'method': method,
        'mode': mode,
        'timeout': timeout,
        'url': url,
        'expectedStatus': expectedStatus,
        'expectedBody': expectedBody,
        if (trace) 'trace': true,
      }),
    );
  }

  @override
  Future<Map<String, Object?>> runtimeMetrics() => _mapResult('runtimeMetrics');

  @override
  Future<Map<String, Object?>> readLogs({int after = 0}) =>
      _mapResult('readLogs', {'after': after});

  @override
  Future<void> saveLogs(String text) async {
    await _mapResult('saveLogs', {'content': text});
  }

  @override
  Future<Map<String, Object?>> exportEvidence({
    List<String> issueCodes = const [],
  }) => _mapResult('exportEvidence', {'issueCodes': issueCodes});

  @override
  Future<void> markRecording() => _mapResult('markRecording');

  @override
  Future<void> exportRecording() => _mapResult('exportRecording');

  Future<String> _stateResult(String method) async {
    final value = await _mapResult(method);
    return value['state'] as String? ?? 'failed';
  }

  Future<Map<String, Object?>> _mapResult(
    String method, [
    Map<String, Object?>? arguments,
  ]) async => _invoke != null
      ? await _invoke(method, arguments)
      : await _channel.invokeMapMethod<String, Object?>(method, arguments) ??
            const <String, Object?>{};
}

final class PingResult {
  const PingResult({
    required this.nodeId,
    required this.status,
    required this.latencyMs,
    required this.timestamp,
    this.configurationRevision,
    this.protocol,
    this.exitIP,
    this.exitCountry,
  });

  factory PingResult.fromMap(Map<String, Object?> value) {
    final exit = value['exit'] as Map?;
    return PingResult(
      nodeId: value['nodeId'] as String,
      status: value['status'] as String,
      latencyMs: value['latencyMs'] as int,
      timestamp: (value['timestamp'] as num).toDouble(),
      configurationRevision: value['configurationRevision'] as String?,
      protocol: value['protocol'] as String?,
      exitIP: exit?['ip'] as String?,
      exitCountry: exit?['country'] as String?,
    );
  }

  final String nodeId;
  final String status;
  final int latencyMs;
  final double timestamp;
  final String? configurationRevision, protocol;

  /// Where a trace test reached the internet: an address and an ISO country code.
  final String? exitIP, exitCountry;
}

final class TunnelSettings {
  const TunnelSettings({
    this.schemaVersion = 1,
    this.fragmentationEnabled = false,
    this.fragmentPackets = 'tlshello',
    this.fragmentLength = '100-200',
    this.fragmentInterval = '0-1',
    this.muxEnabled = false,
    this.preferredIP = 'ipv4',
    this.profilePreferredIP = 'inherit',
    this.profileDNSMode = 'inherit',
    this.httpInboundEnabled = false,
    this.socksPort = 10890,
    this.httpPort = 10891,
    this.allowLAN = false,
    this.inboundAuthEnabled = false,
    this.inboundCredentialsConfigured = false,
    this.onDemandEnabled = false,
    this.connectOnUntrustedWiFi = false,
    this.trustedWiFiNetworks = const <String>[],
    this.subscriptionAutoUpdateHours = 4,
    this.enforceRoutes = false,
    this.includeAllNetworks = false,
    this.blockWithoutVPN = false,
    this.disconnectOnSleep = false,
    this.useDNSFromJSON = true,
    this.resolveServer = false,
    this.xrayTunEnabled = false,
    this.perAppMode = 'off',
    this.perAppProcesses = const <String>[],
    this.perAppTargets = const <String, String>{},
    this.memoryLimitMB = 0,
    this.idleTimeoutSeconds = 300,
    this.tcpMaxConnections = 2048,
    this.udpMaxConnections = 1024,
    this.sniffingEnabled = true,
    this.monitoringEnabled = false,
    this.logLevel = 'warning',
    this.recordDiagnostics = false,
    this.hideVPNIcon = false,
    this.includedRoutes = const <String>['0.0.0.0/0', '::/0'],
    this.excludedRoutes = const <String>[],
  });

  factory TunnelSettings.fromMap(Map<String, Object?> value) => TunnelSettings(
    schemaVersion: value['schemaVersion'] as int? ?? 1,
    fragmentationEnabled: value['fragmentationEnabled'] as bool? ?? false,
    fragmentPackets: value['fragmentPackets'] as String? ?? 'tlshello',
    fragmentLength: value['fragmentLength'] as String? ?? '100-200',
    fragmentInterval: value['fragmentInterval'] as String? ?? '0-1',
    muxEnabled: value['muxEnabled'] as bool? ?? false,
    preferredIP: value['preferredIP'] as String? ?? 'ipv4',
    profilePreferredIP: value['profilePreferredIP'] as String? ?? 'inherit',
    profileDNSMode:
        value['profileDNSMode'] as String? ??
        (value['useDNSFromJSON'] == false ? 'default' : 'inherit'),
    httpInboundEnabled: value['httpInboundEnabled'] as bool? ?? false,
    socksPort: value['socksPort'] as int? ?? 10890,
    httpPort: value['httpPort'] as int? ?? 10891,
    allowLAN: value['allowLAN'] as bool? ?? false,
    inboundAuthEnabled: value['inboundAuthEnabled'] as bool? ?? false,
    inboundCredentialsConfigured:
        value['inboundCredentialsConfigured'] as bool? ?? false,
    onDemandEnabled: value['onDemandEnabled'] as bool? ?? false,
    connectOnUntrustedWiFi: value['connectOnUntrustedWiFi'] as bool? ?? false,
    trustedWiFiNetworks: List<String>.from(
      value['trustedWiFiNetworks'] as List? ?? const <String>[],
    ),
    subscriptionAutoUpdateHours:
        value['subscriptionAutoUpdateHours'] as int? ?? 4,
    enforceRoutes: value['enforceRoutes'] as bool? ?? false,
    includeAllNetworks: value['includeAllNetworks'] as bool? ?? false,
    blockWithoutVPN: value['blockWithoutVPN'] as bool? ?? false,
    disconnectOnSleep: value['disconnectOnSleep'] as bool? ?? false,
    useDNSFromJSON: value['useDNSFromJSON'] as bool? ?? true,
    resolveServer: value['resolveServer'] as bool? ?? false,
    xrayTunEnabled: value['xrayTunEnabled'] as bool? ?? false,
    perAppMode: value['perAppMode'] as String? ?? 'off',
    perAppProcesses: List<String>.from(
      value['perAppProcesses'] as List? ?? const <String>[],
    ),
    perAppTargets: Map<String, String>.from(
      value['perAppTargets'] as Map? ?? const <String, String>{},
    ),
    memoryLimitMB: value['memoryLimitMB'] as int? ?? 0,
    idleTimeoutSeconds: value['idleTimeoutSeconds'] as int? ?? 300,
    tcpMaxConnections: value['tcpMaxConnections'] as int? ?? 2048,
    udpMaxConnections: value['udpMaxConnections'] as int? ?? 1024,
    sniffingEnabled: value['sniffingEnabled'] as bool? ?? true,
    monitoringEnabled: value['monitoringEnabled'] as bool? ?? false,
    logLevel: value['logLevel'] as String? ?? 'warning',
    // A build without the recorder drops the setting a recording build saved.
    recordDiagnostics:
        recordingBuild && (value['recordDiagnostics'] as bool? ?? false),
    hideVPNIcon: value['hideVPNIcon'] as bool? ?? false,
    includedRoutes: List<String>.from(
      value['includedRoutes'] as List? ?? const <String>['0.0.0.0/0', '::/0'],
    ),
    excludedRoutes: List<String>.from(
      value['excludedRoutes'] as List? ?? const <String>[],
    ),
  );

  final int schemaVersion;
  final bool fragmentationEnabled;
  final String fragmentPackets, fragmentLength, fragmentInterval;

  bool get validFragmentation {
    bool range(String value, int min, int max) {
      if (value.length > 11 || !RegExp(r'^[0-9]+(?:-[0-9]+)?$').hasMatch(value))
        return false;
      final parts = value.split('-').map(int.parse).toList();
      return parts.first >= min &&
          parts.first <= parts.last &&
          parts.last <= max;
    }

    return (fragmentPackets == 'tlshello' ||
            range(fragmentPackets, 1, 65535)) &&
        range(fragmentLength, 1, 65535) &&
        range(fragmentInterval, 0, 1000);
  }

  final bool muxEnabled;
  final String preferredIP;
  final String profilePreferredIP;
  final String profileDNSMode;
  final bool httpInboundEnabled;
  final int socksPort;
  final int httpPort;
  final bool allowLAN;
  final bool inboundAuthEnabled;
  final bool inboundCredentialsConfigured;
  final bool onDemandEnabled;

  /// Joining a Wi-Fi network whose name is not in [trustedWiFiNetworks] connects.
  final bool connectOnUntrustedWiFi;
  final List<String> trustedWiFiNetworks;

  /// Up to 64 names of 1-32 bytes without control characters, as Wi-Fi allows.
  bool get validTrustedWiFi =>
      trustedWiFiNetworks.length <= 64 &&
      trustedWiFiNetworks.every(
        (name) =>
            name.isNotEmpty &&
            utf8.encode(name).length <= 32 &&
            !RegExp(r'[\x00-\x1f\x7f]').hasMatch(name),
      );
  final int subscriptionAutoUpdateHours;
  final bool enforceRoutes;
  final bool includeAllNetworks;
  // Windows and Linux keep their tunnel guard after an unexpected exit.
  final bool blockWithoutVPN;
  final bool disconnectOnSleep;
  final bool useDNSFromJSON;
  final bool resolveServer;
  final bool xrayTunEnabled;
  final String perAppMode;
  final List<String> perAppProcesses;

  /// A listed app's own target: direct, routing, block, node:<server ID> or
  /// proxy:<URL>. Apps without one take the mode's.
  final Map<String, String> perAppTargets;

  bool get validPerApp =>
      {'off', 'bypass', 'proxyOnly'}.contains(perAppMode) &&
      (perAppMode == 'off' || (xrayTunEnabled && perAppProcesses.isNotEmpty)) &&
      perAppProcesses.length <= 256 &&
      perAppProcesses.every(
        (name) =>
            name.isNotEmpty &&
            utf8.encode(name).length <= 1024 &&
            name == name.trim() &&
            !RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(name),
      ) &&
      perAppTargets.entries.every(
        (entry) =>
            perAppProcesses.contains(entry.key) &&
            switch (entry.value) {
              'direct' || 'routing' || 'block' => true,
              final value when value.startsWith('node:') =>
                value.length > 5 && value.length <= 133,
              final value when value.startsWith('proxy:') =>
                perAppProxyError(value.substring(6), this) == null,
              _ => false,
            },
      );

  /// Why a per-app proxy target is refused, as a code the interface words
  /// (scheme, notLocal, noPort, extra, ownPort), or null. The core takes
  /// SOCKS5 or HTTP on this device without a login.
  static String? perAppProxyError(String text, TunnelSettings settings) {
    final uri = Uri.tryParse(text.trim());
    if (uri == null || !{'socks', 'socks5', 'http'}.contains(uri.scheme)) {
      return 'scheme';
    }
    if (uri.host != 'localhost' &&
        !(InternetAddress.tryParse(uri.host)?.isLoopback ?? false)) {
      return 'notLocal';
    }
    // HTTP defaults to port 80; SOCKS has no default.
    if (uri.port == 0) return 'noPort';
    if (uri.userInfo.isNotEmpty ||
        !{'', '/'}.contains(uri.path) ||
        uri.hasQuery ||
        uri.hasFragment) {
      return 'extra';
    }
    if (uri.port == settings.socksPort ||
        settings.httpInboundEnabled && uri.port == settings.httpPort) {
      return 'ownPort';
    }
    return null;
  }

  final int memoryLimitMB;
  final int idleTimeoutSeconds;
  final int tcpMaxConnections;
  final int udpMaxConnections;
  final bool sniffingEnabled;
  final bool monitoringEnabled;

  /// One of [logLevels]; the core keeps lines at this severity and above.
  final String logLevel;
  static const logLevels = ['none', 'error', 'warning', 'info', 'debug'];
  // Connection metadata for troubleshooting; the core records only while this is on,
  // in a [recordingBuild].
  final bool recordDiagnostics;
  final bool hideVPNIcon;
  final List<String> includedRoutes;
  final List<String> excludedRoutes;

  // Every VPN core refuses to enforce default routes, which the defaults include.
  /// What route enforcement conflicts with, as a code the interface words
  /// (includeAllNetworks, blockWithoutVPN, defaultRoutes), or null.
  String? get routeEnforcementError {
    if (!enforceRoutes) return null;
    if (includeAllNetworks) return 'includeAllNetworks';
    if (blockWithoutVPN) return 'blockWithoutVPN';
    if (includedRoutes.any((route) => RegExp(r'/0+$').hasMatch(route.trim()))) {
      return 'defaultRoutes';
    }
    return null;
  }

  Map<String, Object?> toMap() => <String, Object?>{
    'schemaVersion': schemaVersion,
    'fragmentationEnabled': fragmentationEnabled,
    'fragmentPackets': fragmentPackets,
    'fragmentLength': fragmentLength,
    'fragmentInterval': fragmentInterval,
    'muxEnabled': muxEnabled,
    'preferredIP': preferredIP,
    'profilePreferredIP': profilePreferredIP == 'inherit'
        ? null
        : profilePreferredIP,
    'profileDNSMode': profileDNSMode,
    'httpInboundEnabled': httpInboundEnabled,
    'socksPort': socksPort,
    'httpPort': httpPort,
    'allowLAN': allowLAN,
    'inboundAuthEnabled': inboundAuthEnabled,
    'onDemandEnabled': onDemandEnabled,
    'connectOnUntrustedWiFi': connectOnUntrustedWiFi,
    'trustedWiFiNetworks': trustedWiFiNetworks,
    'subscriptionAutoUpdateHours': subscriptionAutoUpdateHours,
    'enforceRoutes': enforceRoutes,
    'includeAllNetworks': includeAllNetworks,
    'blockWithoutVPN': blockWithoutVPN,
    'disconnectOnSleep': disconnectOnSleep,
    'useDNSFromJSON': useDNSFromJSON,
    'resolveServer': resolveServer,
    'xrayTunEnabled': xrayTunEnabled,
    'perAppMode': perAppMode,
    'perAppProcesses': perAppProcesses,
    'perAppTargets': perAppTargets,
    'memoryLimitMB': memoryLimitMB,
    'idleTimeoutSeconds': idleTimeoutSeconds,
    'tcpMaxConnections': tcpMaxConnections,
    'udpMaxConnections': udpMaxConnections,
    'sniffingEnabled': sniffingEnabled,
    'monitoringEnabled': monitoringEnabled,
    'logLevel': logLevel,
    'recordDiagnostics': recordDiagnostics,
    'hideVPNIcon': hideVPNIcon,
    'includedRoutes': includedRoutes,
    'excludedRoutes': excludedRoutes,
  };

  TunnelSettings copyWith({
    bool? fragmentationEnabled,
    String? fragmentPackets,
    String? fragmentLength,
    String? fragmentInterval,
    bool? muxEnabled,
    String? preferredIP,
    String? profilePreferredIP,
    String? profileDNSMode,
    bool? httpInboundEnabled,
    int? socksPort,
    int? httpPort,
    bool? allowLAN,
    bool? inboundAuthEnabled,
    bool? onDemandEnabled,
    bool? connectOnUntrustedWiFi,
    List<String>? trustedWiFiNetworks,
    int? subscriptionAutoUpdateHours,
    bool? enforceRoutes,
    bool? includeAllNetworks,
    bool? blockWithoutVPN,
    bool? disconnectOnSleep,
    bool? useDNSFromJSON,
    bool? resolveServer,
    bool? xrayTunEnabled,
    String? perAppMode,
    List<String>? perAppProcesses,
    Map<String, String>? perAppTargets,
    int? memoryLimitMB,
    int? idleTimeoutSeconds,
    int? tcpMaxConnections,
    int? udpMaxConnections,
    bool? sniffingEnabled,
    bool? monitoringEnabled,
    String? logLevel,
    bool? recordDiagnostics,
    bool? hideVPNIcon,
    List<String>? includedRoutes,
    List<String>? excludedRoutes,
  }) => TunnelSettings(
    schemaVersion: schemaVersion,
    fragmentationEnabled: fragmentationEnabled ?? this.fragmentationEnabled,
    fragmentPackets: fragmentPackets ?? this.fragmentPackets,
    fragmentLength: fragmentLength ?? this.fragmentLength,
    fragmentInterval: fragmentInterval ?? this.fragmentInterval,
    muxEnabled: muxEnabled ?? this.muxEnabled,
    preferredIP: preferredIP ?? this.preferredIP,
    profilePreferredIP: profilePreferredIP ?? this.profilePreferredIP,
    profileDNSMode: profileDNSMode ?? this.profileDNSMode,
    httpInboundEnabled: httpInboundEnabled ?? this.httpInboundEnabled,
    socksPort: socksPort ?? this.socksPort,
    httpPort: httpPort ?? this.httpPort,
    allowLAN: allowLAN ?? this.allowLAN,
    inboundAuthEnabled: inboundAuthEnabled ?? this.inboundAuthEnabled,
    inboundCredentialsConfigured: inboundCredentialsConfigured,
    onDemandEnabled: onDemandEnabled ?? this.onDemandEnabled,
    connectOnUntrustedWiFi:
        connectOnUntrustedWiFi ?? this.connectOnUntrustedWiFi,
    trustedWiFiNetworks: trustedWiFiNetworks ?? this.trustedWiFiNetworks,
    subscriptionAutoUpdateHours:
        subscriptionAutoUpdateHours ?? this.subscriptionAutoUpdateHours,
    enforceRoutes: enforceRoutes ?? this.enforceRoutes,
    includeAllNetworks: includeAllNetworks ?? this.includeAllNetworks,
    blockWithoutVPN: blockWithoutVPN ?? this.blockWithoutVPN,
    disconnectOnSleep: disconnectOnSleep ?? this.disconnectOnSleep,
    useDNSFromJSON: useDNSFromJSON ?? this.useDNSFromJSON,
    resolveServer: resolveServer ?? this.resolveServer,
    xrayTunEnabled: xrayTunEnabled ?? this.xrayTunEnabled,
    perAppMode: perAppMode ?? this.perAppMode,
    perAppProcesses: perAppProcesses ?? this.perAppProcesses,
    perAppTargets: perAppTargets ?? this.perAppTargets,
    memoryLimitMB: memoryLimitMB ?? this.memoryLimitMB,
    idleTimeoutSeconds: idleTimeoutSeconds ?? this.idleTimeoutSeconds,
    tcpMaxConnections: tcpMaxConnections ?? this.tcpMaxConnections,
    udpMaxConnections: udpMaxConnections ?? this.udpMaxConnections,
    sniffingEnabled: sniffingEnabled ?? this.sniffingEnabled,
    monitoringEnabled: monitoringEnabled ?? this.monitoringEnabled,
    logLevel: logLevel ?? this.logLevel,
    recordDiagnostics: recordDiagnostics ?? this.recordDiagnostics,
    hideVPNIcon: hideVPNIcon ?? this.hideVPNIcon,
    includedRoutes: includedRoutes ?? this.includedRoutes,
    excludedRoutes: excludedRoutes ?? this.excludedRoutes,
  );
}

final class SubscriptionSnapshot {
  const SubscriptionSnapshot({
    required this.subscriptions,
    this.selectedNodeId,
    this.signature,
  });

  factory SubscriptionSnapshot.fromMap(Map<String, Object?> value) {
    final groups =
        value['subscriptions'] as List<Object?>? ?? const <Object?>[];
    String? signature;
    try {
      signature = jsonEncode(value);
    } on Object {
      signature = null;
    }
    return SubscriptionSnapshot(
      signature: signature,
      selectedNodeId: value['selectedNodeId'] as String?,
      subscriptions: groups
          .map(
            (item) => SubscriptionGroup.fromMap(
              Map<String, Object?>.from(item! as Map),
            ),
          )
          .toList(growable: false),
    );
  }

  final List<SubscriptionGroup> subscriptions;
  final String? selectedNodeId;

  /// Encoded source map, when known; equal signatures describe equal snapshots.
  final String? signature;
}

enum SubscriptionRisk { cleartextHttp, loopbackTarget, privateTarget }

SubscriptionRisk _subscriptionRisk(Object? code) => switch (code) {
  'cleartext_http' => SubscriptionRisk.cleartextHttp,
  'loopback_target' => SubscriptionRisk.loopbackTarget,
  'private_target' => SubscriptionRisk.privateTarget,
  _ => throw const FormatException('Unknown subscription risk.'),
};

final class SubscriptionSafetyWarning {
  const SubscriptionSafetyWarning({
    required this.subscriptionId,
    required this.risks,
    required this.challenge,
  });

  factory SubscriptionSafetyWarning.fromMap(Map<String, Object?> value) {
    final codes = value['riskCodes'] as List<Object?>? ?? const <Object?>[];
    final risks = codes.map(_subscriptionRisk).toList(growable: false);
    if (risks.isEmpty) {
      throw const FormatException('Subscription warning has no risks.');
    }
    return SubscriptionSafetyWarning(
      subscriptionId: value['subscriptionId']! as String,
      risks: risks,
      challenge: value['challenge']! as String,
    );
  }

  final String subscriptionId;
  final List<SubscriptionRisk> risks;
  final String challenge;
}

final class SubscriptionOperationResult {
  const SubscriptionOperationResult({required this.snapshot, this.warning});

  factory SubscriptionOperationResult.fromMap(Map<String, Object?> value) {
    final warning = value['warning'];
    return SubscriptionOperationResult(
      snapshot: SubscriptionSnapshot.fromMap(
        Map<String, Object?>.from(value['subscriptions']! as Map),
      ),
      warning: warning == null
          ? null
          : SubscriptionSafetyWarning.fromMap(
              Map<String, Object?>.from(warning as Map),
            ),
    );
  }

  final SubscriptionSnapshot snapshot;
  final SubscriptionSafetyWarning? warning;
}

/// A subscription download failure's short label and its text, which says whether
/// the device, the network or the provider must act. Desktop errors and the interface share it.
const subscriptionFailures = <String, (String, String)>{
  'fetch_failed': (
    'Download failed',
    'The download failed. Check this device’s network, then retry.',
  ),
  'dns_failed': (
    'Address lookup failed',
    'The address could not be looked up. Check this device’s network and DNS, then retry.',
  ),
  'provider_unreachable': (
    'Provider unreachable',
    'The provider’s server did not answer. Your network may block it, or it is down. Retry later or ask the provider for a mirror.',
  ),
  'provider_error': (
    'Provider error',
    'The provider’s server reported an error. Nothing is wrong with Elarni or this device; retry later.',
  ),
  'rate_limited': (
    'Rate limited',
    'The provider is limiting requests. Elarni retries later; wait before refreshing again.',
  ),
  'subscription_denied': (
    'Access refused',
    'The provider refused the request. The subscription may have expired, run out of traffic or reached its device limit. Contact the provider.',
  ),
  'subscription_unavailable': (
    'Link removed',
    'The provider removed or changed this link. Ask the provider for a new one.',
  ),
};

final class SubscriptionGroup {
  static bool validFallbackHost(String host) {
    final uri = Uri.tryParse('https://$host');
    return host.isNotEmpty &&
        host.length <= 253 &&
        RegExp(r'^[a-zA-Z0-9.\-:\[\]]+$').hasMatch(host) &&
        uri != null &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty &&
        !uri.hasPort &&
        uri.path.isEmpty &&
        !uri.hasQuery &&
        !uri.hasFragment;
  }

  const SubscriptionGroup({
    required this.id,
    required this.name,
    required this.status,
    required this.nodes,
    this.risks = const <SubscriptionRisk>[],
    this.lastSuccessfulFetch,
    this.metadata = const <String, Object?>{},
    this.actions = const <String>[],
    this.format = 'source',
    this.isLocal = false,
    this.fallbackHosts = const <String>[],
    this.fetchOptions = const <String, String>{},
    this.hiddenNodes = const [],
  });

  factory SubscriptionGroup.fromMap(Map<String, Object?> value) {
    final nodes = value['nodes'] as List<Object?>? ?? const <Object?>[];
    // Windows and Linux use their own state words; the interface shows macOS's.
    final status = switch ((
      value['status']! as String,
      value['refreshError'],
    )) {
      ('needsApproval', _) => 'approval_required',
      ('failed', 'hwid_required') => 'device_required',
      ('failed', 'hwid_limit') => 'device_limit',
      ('failed', _) => 'refresh_failed',
      (final status, _) => status,
    };
    return SubscriptionGroup(
      id: value['id']! as String,
      name: value['name']! as String,
      status: status,
      risks: (value['riskCodes'] as List<Object?>? ?? const <Object?>[])
          .map(_subscriptionRisk)
          .toList(growable: false),
      lastSuccessfulFetch: (value['lastSuccessfulFetch'] as num?)?.toDouble(),
      metadata: Map<String, Object?>.from(
        value['metadata'] as Map? ?? const {},
      ),
      actions: (value['actions'] as List<Object?>? ?? const []).cast<String>(),
      format: value['format'] as String? ?? 'source',
      isLocal: value['isLocal'] as bool? ?? false,
      fallbackHosts: List<String>.from(
        value['fallbackHosts'] as List? ?? const <String>[],
      ),
      // 0.3.6 stored a headless client's non-text options; skip them so the catalog stays readable.
      fetchOptions: {
        for (final MapEntry(:key, value: option)
            in (value['fetchOptions'] as Map? ?? const {}).entries)
          if (option is String) key as String: option,
      },
      hiddenNodes: [
        for (final item in value['hiddenNodes'] as List? ?? const [])
          (id: item['id'] as String, name: item['name'] as String),
      ],
      nodes: nodes
          .map(
            (item) => SubscriptionNode.fromMap(
              Map<String, Object?>.from(item! as Map),
            ),
          )
          .toList(growable: false),
    );
  }

  final String id;
  final String name;
  final String status;
  final List<SubscriptionRisk> risks;
  final double? lastSuccessfulFetch;
  final List<SubscriptionNode> nodes;
  final Map<String, Object?> metadata;
  final List<String> actions;
  final String format;
  final bool isLocal;
  final List<String> fallbackHosts;
  final Map<String, String> fetchOptions;

  /// Provider servers the user hid; refreshes keep them out of [nodes].
  final List<({String id, String name})> hiddenNodes;
}

final class SubscriptionNode {
  const SubscriptionNode({
    required this.id,
    required this.name,
    required this.protocol,
    required this.transport,
    required this.security,
    required this.selected,
    this.format = 'xrayOutbound',
    this.groups = const [],
    this.ipPreference,
    this.favorite = false,
    this.configurationRevision,
    this.lastSuccessAt,
    this.lastSuccessCurrent = false,
    this.probeKey,
  });

  factory SubscriptionNode.fromMap(Map<String, Object?> value) =>
      SubscriptionNode(
        id: value['id']! as String,
        name: value['name']! as String,
        protocol: value['protocol']! as String,
        transport: value['transport']! as String,
        security: value['security']! as String,
        selected: value['selected']! as bool,
        format: value['format'] as String? ?? 'xrayOutbound',
        ipPreference: value['ipPreference'] as String?,
        favorite: value['favorite'] == true,
        configurationRevision: value['configurationRevision'] as String?,
        lastSuccessAt: (value['lastSuccessAt'] as num?)?.toDouble(),
        lastSuccessCurrent: value['lastSuccessCurrent'] == true,
        probeKey: value['probeKey'] as String?,
        groups: (value['groups'] as List<Object?>? ?? const [])
            .map(
              (item) => ProfileGroupChoice.fromMap(
                Map<String, Object?>.from(item! as Map),
              ),
            )
            .toList(),
      );

  final String id;
  final String name;
  final String protocol;
  final String transport;
  final String security;
  final bool selected;
  final String format;
  final List<ProfileGroupChoice> groups;
  final String? ipPreference;
  final bool favorite, lastSuccessCurrent;
  final String? configurationRevision;
  final double? lastSuccessAt;
  // The SNI a probe's handshake names, else its server address.
  final String? probeKey;
  String get revision => configurationRevision ?? id;
  bool get isVPN => format != 'telegram';
}

final class ProfileGroupChoice {
  const ProfileGroupChoice({
    required this.name,
    required this.options,
    required this.selected,
  });
  factory ProfileGroupChoice.fromMap(Map<String, Object?> value) =>
      ProfileGroupChoice(
        name: value['name']! as String,
        options: (value['options']! as List).cast<String>(),
        selected: value['selected']! as String,
      );
  final String name;
  final List<String> options;
  final String selected;
}

final class NodeSelectionResult {
  const NodeSelectionResult({required this.state, required this.subscriptions});

  final String state;
  final SubscriptionSnapshot subscriptions;
}

final class RoutingSnapshot {
  const RoutingSnapshot({required this.profiles, required this.assignments});

  factory RoutingSnapshot.fromMap(Map<String, Object?> value) =>
      RoutingSnapshot(
        profiles: (value['profiles'] as List<Object?>? ?? const <Object?>[])
            .map(
              (item) => RoutingProfile.fromMap(
                Map<String, Object?>.from(item! as Map),
              ),
            )
            .toList(growable: false),
        assignments: Map<String, String>.from(
          value['assignments'] as Map? ?? const <String, String>{},
        ),
      );

  final List<RoutingProfile> profiles;
  final Map<String, String> assignments;
}

final class RoutingProfile {
  const RoutingProfile({
    required this.id,
    required this.name,
    required this.source,
    required this.edited,
    required this.enabled,
    required this.geofileStatus,
    required this.json,
    this.geofiles = const [],
    this.geofileError,
    this.reductionStatus = 'disabled',
    this.skippedGeodata = const [],
    this.providerSubscriptionId,
    this.managedError,
  });

  // macOS reports a provider's profile as 'subscription', Windows and Linux as 'provider'.
  bool get fromSubscription => source == 'subscription' || source == 'provider';

  factory RoutingProfile.fromMap(Map<String, Object?> value) => RoutingProfile(
    id: value['id']! as String,
    name: value['name']! as String,
    source: value['source']! as String,
    edited: value['edited']! as bool,
    enabled: value['enabled']! as bool,
    geofileStatus: value['geofileStatus']! as String,
    json: value['json']! as String,
    geofiles: (value['geofiles'] as List? ?? const [])
        .map((item) => Map<String, Object?>.from(item as Map))
        .toList(),
    geofileError: value['geofileError'] as String?,
    reductionStatus: value['reductionStatus'] as String? ?? 'disabled',
    skippedGeodata: List<String>.from(
      value['skippedGeodata'] as List? ?? const [],
    ),
    providerSubscriptionId: value['providerSubscriptionId'] as String?,
    managedError: value['managedError'] as String?,
  );

  final String id;
  final String name;
  final String source;
  final bool edited;
  final bool enabled;
  final String geofileStatus;
  final String json;
  final List<Map<String, Object?>> geofiles;
  final String? geofileError;
  final String reductionStatus;
  // Codes the geofiles lack, which Direct, Block and domestic DNS rules skip.
  final List<String> skippedGeodata;
  final String? providerSubscriptionId;
  // Why the last managed list refresh failed; the lists in use are kept.
  final String? managedError;
}
