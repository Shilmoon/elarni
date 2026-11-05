import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'platform_services.dart';
import 'domain_ffi.dart';
import 'tunnel_channel.dart';
import 'wifi_network.dart';
import 'desktop_catalog.dart';
import 'desktop_automation.dart';
import 'desktop_version.dart';
import 'update_check.dart' show isHttpsURL;
import 'connection_diagnostics.dart';
import 'system_proxy.dart';
import 'headless_transport.dart' show windowsPowerShell;

part 'desktop_proxy_commands.dart';
part 'desktop_proxy_probes.dart';
part 'desktop_proxy_catalog.dart';
part 'desktop_proxy_runtime.dart';
part 'desktop_proxy_automation.dart';

final class DesktopProxy {
  ({String node, double at, int epoch})? _verifiedHealth;
  DesktopProxy({
    required this.corePath,
    required this.domainPath,
    this.unattended = false,
    Future<Process> Function(String)? startProcess,
    DesktopRequest? catalogIO,
    DesktopRequest? platformIO,
    Future<String> Function(Future<String> Function(Uint8List))? cameraScan,
    void Function()? cancelCamera,
    Future<bool> Function(String prompt)? confirmLink,
    Duration? replyTimeout,
    Duration? helperExitGrace,
    int? automationProbeSeconds,
    int? automationRetrySeconds,
    List<CatalogMap>? livenessTargets,
    Duration? livenessInterval,
    DateTime Function()? clock,
    Duration? refreshInterval,
    Future<WiFiReading> Function()? wifiNetwork,
    Duration? wifiInterval,
    SystemProxySession? systemProxy,
  }) : _startProcess =
           startProcess ??
           ((path) => Process.start(path, const [], runInShell: false)),
       _catalogIO = catalogIO,
       _platformIO = platformIO,
       _cameraScan = cameraScan,
       _cancelCamera = cancelCamera,
       _confirmLink = confirmLink,
       // Tests shorten these waits; the defaults bound real helpers and networks.
       _replyTimeout = replyTimeout ?? const Duration(seconds: 20),
       _helperExitGrace = helperExitGrace ?? const Duration(seconds: 10),
       _automationProbeSeconds = automationProbeSeconds ?? 5,
       _automationRetrySeconds = automationRetrySeconds ?? 30,
       _livenessTargets = livenessTargets ?? DesktopProxy.defaultHealthTargets,
       _livenessSeconds =
           (livenessInterval ?? const Duration(minutes: 1)).inMilliseconds /
           1000,
       // Tests also move the refresh schedule's clock and check it more often.
       _refreshClock = clock ?? DateTime.now,
       _refreshInterval = refreshInterval ?? const Duration(seconds: 30),
       _wifiNetwork = wifiNetwork ?? readWiFiNetwork,
       _wifiInterval = wifiInterval ?? const Duration(seconds: 5),
       _systemProxy = systemProxy;
  final String corePath, domainPath;
  // Links come from web pages and other apps. Imports and stops wait for the
  // user; without a window to ask, they are declined. The prompt is
  // disconnect, importRouting or importClient; the window words it.
  final Future<bool> Function(String prompt)? _confirmLink;
  // A service keeps retrying and may use explicitly allowed backups from any
  // source. Interactive desktop recovery retains its existing bounded policy.
  final bool unattended;

  Future<CatalogMap> request(
    String method, [
    CatalogMap arguments = const {},
  ]) => _invoke(method, arguments);
  final Future<Process> Function(String) _startProcess;
  final DesktopRequest? _catalogIO, _platformIO;
  final Future<String> Function(Future<String> Function(Uint8List))?
  _cameraScan;
  final void Function()? _cancelCamera;
  final Duration _replyTimeout, _helperExitGrace, _refreshInterval;
  final Future<WiFiReading> Function() _wifiNetwork;
  final Duration _wifiInterval;
  // Null where System proxy mode does not apply: tests and the headless daemon.
  final SystemProxySession? _systemProxy;
  bool _proxyReleased = false;
  Timer? _wifiTimer;
  // The network last acted on; null before the first reading.
  ({String? name})? _wifi;
  String? _wifiStatus;
  bool _wifiBusy = false;
  // A failed health check is repeated after _automationRetrySeconds; the third failure fails over.
  final int _automationProbeSeconds, _automationRetrySeconds;
  static const defaultHealthTargets = <CatalogMap>[
    {
      'id': 'gstatic',
      'url': 'https://www.gstatic.com/generate_204',
      'expectedStatus': 204,
      'expectedBody': '',
    },
    {
      'id': 'cloudflare',
      'url': 'https://cp.cloudflare.com/generate_204',
      'expectedStatus': 204,
      'expectedBody': '',
    },
  ];
  // Connected means only that the local core answers. Liveness says whether the
  // server passes traffic: 'ok', 'noTraffic', or null before the first check.
  final List<CatalogMap> _livenessTargets;
  final double _livenessSeconds;
  String? _liveness;
  double? _livenessAt;
  int? _livenessUplink;
  bool _livenessBusy = false;
  final DateTime Function() _refreshClock;
  static final _platform = MethodChannel(
    Platform.isLinux ? 'com.elarni/linux' : 'com.elarni/windows',
  );
  late final TunnelControl control = NativeTunnelControl(
    invoke: _invoke,
    importListener: (listener) => _listener = listener,
  );
  ElarniDomainFfi? _domain;
  DesktopCatalog? _catalog;
  // Semantics are a pure function of catalog data, so an edit reuses the
  // committed catalog's result instead of compiling every node twice.
  final _semanticsMemo = <String, CatalogMap>{};
  final _refreshBackoff = <String, ({DateTime until, int failures})>{};
  Future<void>? _initializing, _stopping;
  Future<CatalogMap>? _disconnecting;
  Future<Process>? _process, _lease;
  StreamIterator<List<int>>? _leaseOutput;
  Future<void> _storageQueue = Future<void>.value();
  Future<Process>? _vpnSession;
  Completer<CatalogMap>? _vpnReply;
  Process? _vpnReplyProcess;
  final Set<Process> _workers = {};
  Completer<void>? _operation;
  int _manualProbes = 0;
  bool _interruptingProbes = false;
  String? _coreVersion;
  Timer? _timer, _initRetry;
  void Function(String?)? _listener;
  bool _disposed = false, _storageLost = false;
  int _generation = 0;
  Process? _metricsProcess;
  CatalogMap _latestMetrics = {};
  DateTime? _metricsAt, _connectedAt;
  // Each core numbers its own lines; these keep one sequence across cores.
  final List<CatalogMap> _logs = [];
  int _logSeq = 0;
  DesktopAutomation _automation = DesktopAutomation({});
  final Stopwatch _clock = Stopwatch()..start();
  Timer? _automationTimer;
  bool _automationBusy = false;
  final CatalogMap _candidateFailures = {};
  int _lastAutomaticProbe = -1000;
  double get _now => _clock.elapsedMilliseconds / 1000;
  CatalogMap get _automationConfig => catalogMap(
    _catalog?.data['automation'] ??
        {
          'schemaVersion': 1,
          'enabled': false,
          'policy': 'fixed',
          'subscriptionID': '',
          'nodeIDs': [],
          'targets': [],
        },
  );
  String _state = 'disconnected', _revision = '';
  // The login of the VPN's listeners when the user set none; only probes use it.
  CatalogMap? _vpnLogin;
  final Map<
    String,
    ({String id, String format, List<String> chain, DateTime expires})
  >
  _challenges = {};
  Future<void> _links = Future<void>.value();
  int _linkStopGeneration = 0;

  Future<void> handleLinks(List<String> values) {
    // A stop link must reach the command owner while a connect link is pending.
    final action = values.length == 1
        ? ConnectionAction.fromLink(values.single)
        : null;
    final generation = _linkStopGeneration;
    if (action == ConnectionAction.disconnect ||
        action == ConnectionAction.toggle && _automation.intent) {
      return _handleLinks(values, generation);
    }
    return _links = _links.then((_) => _handleLinks(values, generation));
  }

  Future<void> _handleLinks(List<String> values, int generation) async {
    String? failure;
    for (final value in values.take(16)) {
      final scheme = Uri.tryParse(value)?.scheme.toLowerCase();
      if (!{
        'elarni',
        'happ',
        'vless',
        'vmess',
        'trojan',
        'ss',
        'socks',
        'socks5',
        'hy2',
        'hysteria2',
        'tuic',
        'vpn',
        'wireguard',
        'incy',
      }.contains(scheme))
        continue;
      if (_disposed) return;
      try {
        if (utf8.encode(value).length > 4 * 1024 * 1024)
          throw desktopError('import_too_large');
        final action = ConnectionAction.fromLink(value);
        if (action != null) {
          if (action == ConnectionAction.status) continue;
          final stop =
              action == ConnectionAction.disconnect ||
              action == ConnectionAction.toggle && _automation.intent;
          if (stop && await _confirmLink?.call('disconnect') != true) continue;
          if (!stop) {
            await _operation?.future;
            if (_disposed || generation != _linkStopGeneration) continue;
          }
          if (!stop &&
              {
                'connected',
                'connecting',
                'reconnecting',
                'reasserting',
              }.contains(_state))
            continue;
          await _invoke(stop ? 'disconnect' : 'connect', {});
          continue;
        }
        final routing = DesktopCatalog.isRoutingLink(value);
        if (await _confirmLink?.call(
              routing ? 'importRouting' : 'importClient',
            ) !=
            true)
          continue;
        await _operation?.future;
        await _invoke(routing ? 'importRouting' : 'importClientProfiles', {
          'content': value,
        });
      } on Object catch (error) {
        failure ??=
            error is PlatformException &&
                error.code == 'no_selected_subscription'
            ? error.message
            : 'One or more client links could not be handled.';
      }
    }
    if (!_disposed) _listener?.call(failure);
  }

  Future<void> _takeLinks() async {
    try {
      final result = await _platformRequest('takeLinks', {});
      await handleLinks((result['links'] as List? ?? []).cast<String>());
    } on Object {
      if (!_disposed) _listener?.call('The client link could not be imported.');
    }
  }

  // On Windows the lease core answers storage requests, one at a time.
  Future<CatalogMap> _storage(String method, CatalogMap payload) {
    if (_catalogIO != null) return _catalogIO(method, payload);
    if (!Platform.isWindows) return _native(method, payload);
    final reply = _storageQueue.then((_) => _native(method, payload));
    _storageQueue = reply.then<void>((_) {}, onError: (Object _) {});
    return reply;
  }

  Future<void> _initialize() => _initializing ??=
      () async {
        // A run that ended without restoring the OS proxy left it pointing at
        // a closed listener, which breaks every app that follows it.
        if (await _systemProxy?.recover() case final message?)
          _listener?.call(message);
        // A retry after a failed load keeps the lease it already holds.
        if (_catalogIO == null && _lease == null)
          await _native('acquireCatalog', {});
        final stored = await _storage('loadCatalog', {});
        _revision = stored['revision'] as String? ?? '';
        final document = stored['catalog'];
        if (document != null) {
          final envelope = catalogMap(document);
          if (envelope['version'] != 1 || envelope['committed'] is! Map)
            throw desktopError('storage_corrupt');
          _catalog = DesktopCatalog(
            catalogMap(envelope['committed']),
            _native,
            _domainRequest,
            clock: _refreshClock,
          )..validate();
          final migrated = _catalog!.migrateSessionLimits();
          // The lifetime lease excludes another instance still publishing a change.
          if (migrated || envelope['pending'] != null)
            await _save({'version': 1, 'committed': _catalog!.data});
        } else {
          _catalog = DesktopCatalog(
            DesktopCatalog.empty(),
            _native,
            _domainRequest,
            clock: _refreshClock,
          );
          await _save({'version': 1, 'committed': _catalog!.data});
        }
        await _retireAssets();
        // Before links, refreshes or recovery resolve names. A declined repair
        // here is asked again, and reported, by the next Connect.
        if (Platform.isWindows || Platform.isLinux)
          await _clearStaleGuard().catchError((Object _) {});
        _automation = DesktopAutomation(
          catalogMap(_catalog!.data['automationEpisode'] ?? {}),
        );
        _automation.intent = _catalog!.data['connectionIntent'] == true;
        try {
          DesktopAutomation.validate(_automationConfig, _catalog!);
          if (unattended && _automation.intent) _automation.rearm(_now);
        } on Object {
          _automation.intent = false;
          _automation.status = 'unreadableConfiguration';
        }
        if (!_disposed) {
          if ((Platform.isWindows || Platform.isLinux) && _platformIO == null) {
            _platform.setMethodCallHandler((call) async {
              if (call.method == 'linksAvailable') unawaited(_takeLinks());
              if (call.method == 'sleepChanged')
                unawaited(handleSleep(call.arguments == true));
            });
            scheduleMicrotask(() => unawaited(_takeLinks()));
          }
          _state = _catalog!.selected == null ? 'disconnected' : 'prepared';
          _timer = Timer.periodic(
            _refreshInterval,
            (_) => unawaited(_refreshDue()),
          );
          _automationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
            unawaited(_automationTick());
            unawaited(_livenessTick());
            unawaited(_syncSystemProxy());
          });
          _wifiTimer = Timer.periodic(
            _wifiInterval,
            (_) => unawaited(_wifiTick()),
          );
        }
      }().onError<Object>((error, stack) {
        // A locked keyring or busy store at login must not need an app restart, but
        // the UI's 1 Hz polling must not respawn the core or re-prompt every second.
        _initRetry = Timer(
          const Duration(seconds: 10),
          () => _initializing = null,
        );
        Error.throwWithStackTrace(error, stack);
      });

  Future<void> _retireAssets() async {
    if (!(Platform.isWindows || Platform.isLinux) ||
        _storageLost ||
        _disposed ||
        _catalog == null)
      return;
    try {
      await _native('retireRoutingAssets', {
        'keep': _catalog!.routes
            .map((route) => route['assetRevision'])
            .whereType<String>()
            .toSet()
            .toList(),
      });
    } on Object {
      /* Retry reclamation at the next publication or relaunch. */
    }
  }

  Future<void> _save(CatalogMap document) async {
    if (_storageLost) throw desktopError('storage_unavailable');
    try {
      final saved = await _storage('saveCatalog', {
        'revision': _revision,
        'catalog': document,
      });
      _revision = saved['revision']! as String;
    } on Object {
      // Resolve a lost acknowledgement after atomic replacement by reading the
      // authoritative store, before attempting any compensating publication.
      final actual = await _storage('loadCatalog', {});
      if (jsonEncode(actual['catalog']) != jsonEncode(document)) rethrow;
      _revision = actual['revision']! as String;
    }
  }

  static String _compiled(CatalogMap semantics, String id) => jsonEncode(
    catalogList(
      semantics['nodes'],
    ).firstWhere((node) => node['id'] == id)['config'],
  );

  static CatalogMap _catalogSemantics(
    DomainRequest request,
    DesktopCatalog catalog,
  ) => {
    'nodes': [
      for (final source in catalog.sources)
        for (final node in catalogList(source['nodes']))
          {
            'id': node['id'],
            'identity': node['config'],
            'assetRevision': _runtimeAssets(
              catalog,
              nodeId: node['id']! as String,
            )['assetRevision'],
            'config': node['format'] == 'xrayProfile'
                ? _semanticConfig(request, catalog, node)
                : node['config'],
          },
    ],
  };

  // A deleted per-app server fails the connect, not every catalog change.
  static Object? _semanticConfig(
    DomainRequest request,
    DesktopCatalog catalog,
    CatalogMap node,
  ) {
    try {
      return jsonDecode(_compileWith(request, catalog, node));
    } on PlatformException catch (error) {
      if (error.code != 'per_app_target_missing') rethrow;
      return {'error': error.code};
    }
  }

  // Compiles and config preparation carry the routing model and can stall
  // frames, so they run on worker isolates with their own native handle.
  // Static entry points keep each sent closure free of DesktopProxy state.
  static Future<CatalogMap> _domainOff(
    String path,
    String operation,
    CatalogMap payload,
  ) => Isolate.run(
    () => _withDomain(path, (request) => request(operation, payload)),
  );

  static Future<CatalogMap> _semanticsOff(String path, CatalogMap data) =>
      Isolate.run(
        () => _withDomain(
          path,
          (request) =>
              _catalogSemantics(request, _workerCatalog(data, request)),
        ),
      );

  static Future<String> _compileOff(
    String path,
    CatalogMap data,
    String nodeId,
  ) => Isolate.run(
    () => _withDomain(path, (request) {
      final catalog = _workerCatalog(data, request);
      return _compileWith(request, catalog, catalog.node(nodeId));
    }),
  );

  static DesktopCatalog _workerCatalog(
    CatalogMap data,
    DomainRequest request,
  ) => DesktopCatalog(
    data,
    (_, _) => throw StateError('Compile workers make no platform calls.'),
    request,
  );

  static T _withDomain<T>(String path, T Function(DomainRequest) work) {
    final ElarniDomainFfi domain;
    try {
      domain = ElarniDomainFfi.openLibrary(path);
    } on Object {
      throw desktopError('native_unavailable');
    }
    try {
      return work(
        (operation, payload) => _requestWith(domain, operation, payload),
      );
    } finally {
      domain.dispose();
    }
  }

  static CatalogMap _requestWith(
    ElarniDomainFfi domain,
    String operation,
    CatalogMap payload,
  ) {
    try {
      return domain.request({
        'schemaVersion': 1,
        'operation': operation,
        'payload': payload,
      });
    } on Object {
      throw desktopError(
        operation == 'compileProfile'
            ? 'unsupported_profile'
            : 'invalid_routing',
      );
    }
  }

  static TunnelSettings _nodeSettings(DesktopCatalog catalog, CatalogMap node) {
    final preference = node['ipPreference'] as String?;
    return preference == null
        ? catalog.settings
        : catalog.settings.copyWith(
            preferredIP: preference,
            profilePreferredIP: preference,
          );
  }

  static String _compileWith(
    DomainRequest request,
    DesktopCatalog catalog,
    CatalogMap node,
  ) {
    final settings = _nodeSettings(catalog, node).listeners;
    final source = catalog.sources.firstWhere(
      (source) =>
          catalogList(source['nodes']).any((item) => item['id'] == node['id']),
    );
    final routeID = catalog.assignments[source['id']];
    final routing = routeID == null ? null : catalog.route(routeID as String);
    final raw =
        request('compileProfile', {
              'profile': node['config'],
              'routes': routing?['enabled'] == true
                  ? routing!['routeModel']
                  : null,
              'socksPort': settings.socksPort,
              'packetBackend': settings.xrayTunEnabled
                  ? 'xrayTun'
                  : 'nativeTun2Proxy',
              'tunMtu': 1500,
              if (settings.profilePreferredIP != 'inherit')
                'preferredIp': settings.profilePreferredIP,
              'runtime': {
                'httpInboundEnabled': settings.httpInboundEnabled,
                'httpPort': settings.httpPort,
                'allowLan': settings.allowLAN,
                if (settings.inboundAuthEnabled)
                  'inboundAuth': catalog.data['inboundCredentials'],
                'fragmentationEnabled': settings.fragmentationEnabled,
                'fragmentPackets': settings.fragmentPackets,
                'fragmentLength': settings.fragmentLength,
                'fragmentInterval': settings.fragmentInterval,
                'muxEnabled': settings.muxEnabled,
                'preferredIp': settings.preferredIP,
                'connectionIdleSeconds': settings.idleTimeoutSeconds,
                'sniffingEnabled': settings.sniffingEnabled,
                'useDnsFromJson': settings.useDNSFromJSON,
                'profileDnsMode': settings.profileDNSMode,
                'perAppMode': settings.perAppMode,
                'perAppProcesses': settings.perAppProcesses,
                'perAppTargets': catalog.perAppTargets(settings),
              },
            })['configUtf8']!
            as String;
    final config = catalogMap(jsonDecode(raw));
    final policy = catalogMap(config['policy'] ?? {});
    policy['system'] = {
      ...catalogMap(policy['system'] ?? {}),
      'statsInboundUplink': true,
      'statsInboundDownlink': true,
    };
    config['policy'] = policy;
    config['stats'] = <String, Object?>{};
    return jsonEncode(config);
  }

  static CatalogMap _runtimeAssets(DesktopCatalog catalog, {String? nodeId}) {
    nodeId ??= catalog.selected;
    if (nodeId == null) return {};
    final source = catalog.sources.firstWhere(
      (source) =>
          catalogList(source['nodes']).any((node) => node['id'] == nodeId),
    );
    final id = catalog.assignments[source['id']];
    if (id == null) return {};
    final route = catalog.route(id as String);
    return route['enabled'] == true && route['assetRevision'] != null
        ? {'assetRevision': route['assetRevision']}
        : {};
  }

  void _checkGeneration(int generation) {
    if (_disposed || generation != _generation) throw desktopError('cancelled');
  }

  Future<void> handleSleep(bool sleeping) async {
    _automation.sleepChanged(sleeping, _now);
    if (sleeping) {
      _cancelCamera?.call();
      // Cancel probes even when the connection is allowed to remain up.
      _generation++;
      for (final worker in _workers.toList()) {
        worker.kill();
      }
      if (_catalog?.settings.disconnectOnSleep == true) await _disconnect();
      _automation.status = 'sleeping';
    }
  }

  /// Puts the user's proxy setting back. Quitting the window does not wait
  /// for [dispose], and the OS proxy must not outlive its listener.
  Future<void> releaseSystemProxy() async {
    _proxyReleased = true;
    await _syncSystemProxy();
  }

  // The OS proxy follows a running System proxy session; any other state gives
  // the user's own setting back.
  Future<void> _syncSystemProxy() async {
    final settings = _catalog?.settings;
    final message = await _systemProxy?.sync(
      !_disposed &&
              !_proxyReleased &&
              settings != null &&
              settings.systemProxy &&
              {'connected', 'reconnecting', 'reasserting'}.contains(_state)
          ? settings.httpPort
          : null,
    );
    if (message != null) _listener?.call(message);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _syncSystemProxy();
    _timer?.cancel();
    _initRetry?.cancel();
    _automationTimer?.cancel();
    _wifiTimer?.cancel();
    _listener = null;
    await _disconnect();
    try {
      await _initializing;
    } on Object {
      /* Preserve unreadable storage. */
    }
    await _reap(_lease);
    await _reap(_vpnSession);
    _vpnSession = null;
    _lease = null;
    _catalog = null;
    _challenges.clear();
    _domain?.dispose();
    _domain = null;
  }
}
