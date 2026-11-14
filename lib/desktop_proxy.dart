import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' show sha256;
import 'awake_timeout.dart';
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
       _automationRetrySeconds = automationRetrySeconds,
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
  String? _wifiStatus, _wifiPath;
  int _wifiSkips = 0;
  bool _wifiBusy = false;
  final int _automationProbeSeconds;
  // Replaces DesktopAutomation.recheckSeconds, the wait after a failed check.
  final int? _automationRetrySeconds;
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
  int _livenessFailures = 0;
  // The selected server and revision that last passed traffic.
  String? _trafficServer;
  bool _livenessBusy = false;
  double _pathReadAt = -1000;
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
  // A digest of what each server compiles to, by what it compiles from: the
  // route and settings it shares with other servers, then its own config. A
  // catalog edit compiles only the servers whose inputs it changed.
  final _compiledMemo = <String, Map<String, _Compiled>>{};
  var _semanticsPass = 0;
  final _probeTargets =
      <
        String,
        ({
          Object revision,
          Future<({CatalogMap endpoint, Future<Map?> mapping})> target,
        })
      >{};
  final _refreshBackoff = <String, ({DateTime until, int failures})>{};
  Future<void>? _initializing, _stopping;
  // With Block traffic without VPN the core keeps its kill switch after a
  // tunnel that ended by itself and, when asked, between a restart's two
  // tunnels. _guardKept: one is in place, so no lookup is answered.
  // _guardHeld: a restart's stop kept it, and a plain stop lifts it.
  // _guardStale: this connect left a crashed helper's in place.
  var _guardKept = false, _guardHeld = false, _guardStale = false;
  // The addresses each server name last resolved to, for starts under a kept
  // kill switch.
  final _hostAddresses = <String, List<InternetAddress>>{};
  Future<CatalogMap>? _disconnecting;
  Future<Process>? _process, _lease;
  StreamIterator<List<int>>? _leaseOutput;
  Future<int>? _leaseExit;
  Future<void> _storageQueue = Future<void>.value();
  Future<Process>? _vpnSession;
  Completer<CatalogMap>? _vpnReply;
  Process? _vpnReplyProcess;
  final Set<Process> _workers = {};
  Completer<void>? _operation;
  int _manualProbes = 0;
  bool _interruptingProbes = false;
  String? _coreVersion;
  ({Object? enabled, int at})? _vpnService;
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
  // The running core's recent connections by key, in the order of their last
  // change; a new core (epoch) starts over. Cleared when the tunnel stops.
  int _connectionsEpoch = 0;
  final Map<int, CatalogMap> _connections = {};
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
    final reply = _storageQueue.then((_) async {
      // A lease that ended after loading (a missed reply ends it) is taken
      // again once its core exited and released the lock.
      if (_lease == null && _catalog != null && !_disposed) {
        await _leaseExit?.timeout(
          const Duration(seconds: 3),
          onTimeout: () => -1,
        );
        await _native('acquireCatalog', {});
      }
      return _native(method, payload);
    });
    _storageQueue = reply.then<void>((_) {}, onError: (Object _) {});
    return reply;
  }

  Future<void> _initialize() => _initializing ??=
      () async {
        // A run that ended without restoring the OS proxy left it pointing at
        // a closed listener, which breaks every app that follows it. A second
        // instance is refused first: the setting and its backup belong to the
        // running one.
        var recovered = false;
        Future<void> recoverProxy() async {
          if (recovered) return;
          recovered = true;
          if (await _systemProxy?.recover() case final message?)
            _listener?.call(message);
        }

        final CatalogMap stored;
        try {
          if (_catalogIO == null) {
            // A retry after a failed load keeps the lease it already holds.
            if (_lease == null) await _native('acquireCatalog', {});
            // The lease excludes a second instance, and the load below can
            // wait on a keyring prompt.
            await recoverProxy();
          }
          stored = await _storage('loadCatalog', {});
        } on Object catch (error) {
          if (error is! PlatformException || error.code != 'storage_busy')
            await recoverProxy();
          rethrow;
        }
        await recoverProxy();
        _revision = stored['revision'] as String? ?? '';
        final document = stored['catalog'];
        if (document != null) {
          final Object? pending;
          try {
            final envelope = catalogMap(document);
            if (envelope['version'] != 1 || envelope['committed'] is! Map)
              throw const FormatException();
            pending = envelope['pending'];
            _catalog = DesktopCatalog(
              catalogMap(envelope['committed']),
              _native,
              _domainRequest,
              clock: _refreshClock,
            )..validate();
          } on PlatformException {
            rethrow;
          } on Object {
            // Not a catalog, whatever it is: it stays on disk untouched.
            throw desktopError('storage_corrupt');
          }
          final migrated = _catalog!.migrateSessionLimits();
          // The lifetime lease excludes another instance still publishing a change.
          if (migrated || pending != null)
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
          switch (_catalog!.data['automationEpisode']) {
            final Map episode => catalogMap(episode),
            _ => {},
          },
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

  // Each server with what it compiles from besides its own config: the route
  // and settings it shares with other servers. A server that is not compiled
  // has neither; `error` is a per-app server that is gone, which fails the
  // connect, not every catalog change.
  static Iterable<
    ({
      CatalogMap node,
      Object? assetRevision,
      CatalogMap? context,
      String? error,
    })
  >
  _compileInputs(DesktopCatalog catalog) sync* {
    final settings = catalog.settings, assignments = catalog.assignments;
    final routes = {for (final route in catalog.routes) route['id']: route};
    final contexts = <String, ({CatalogMap? context, String? error})>{};
    for (final source in catalog.sources) {
      final routeID = assignments[source['id']];
      late final routing = routeID == null
          ? null
          : routes[routeID] ?? (throw desktopError('invalid_routing'));
      late final assetRevision = routing?['enabled'] == true
          ? routing!['assetRevision']
          : null;
      for (final node in catalogList(source['nodes'])) {
        final preference = node['ipPreference'] as String?;
        final shared = node['format'] != 'xrayProfile'
            ? (context: null, error: null)
            : contexts['$routeID $preference'] ??= () {
                try {
                  return (
                    context: _compileContext(
                      catalog,
                      routing,
                      _preferring(settings, preference),
                    ),
                    error: null,
                  );
                } on PlatformException catch (error) {
                  if (error.code != 'per_app_target_missing') rethrow;
                  return (context: null, error: error.code);
                }
              }();
        yield (
          node: node,
          assetRevision: assetRevision,
          context: shared.context,
          error: shared.error,
        );
      }
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

  // Display names are left out, as in a server's identity, so a provider
  // renaming a server does not make it another one.
  static Future<Map<String, String>> _digestsOff(
    String path,
    CatalogMap data,
    Set<String> nodeIds,
  ) => Isolate.run(
    () => _withDomain(
      path,
      (request) => {
        for (final input in _compileInputs(_workerCatalog(data, request)))
          if (nodeIds.contains(input.node['id']))
            input.node['id']! as String: sha256
                .convert(
                  utf8.encode(
                    DesktopCatalog.identity(
                      jsonDecode(
                        _compileIn(request, input.context!, input.node),
                      ),
                    ),
                  ),
                )
                .toString(),
      },
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

  static TunnelSettings _nodeSettings(
    DesktopCatalog catalog,
    CatalogMap node,
  ) => _preferring(catalog.settings, node['ipPreference'] as String?);

  static TunnelSettings _preferring(
    TunnelSettings settings,
    String? preference,
  ) => preference == null
      ? settings
      : settings.copyWith(
          preferredIP: preference,
          profilePreferredIP: preference,
        );

  static String _compileWith(
    DomainRequest request,
    DesktopCatalog catalog,
    CatalogMap node,
  ) {
    final source = catalog.sources.firstWhere(
      (source) =>
          catalogList(source['nodes']).any((item) => item['id'] == node['id']),
    );
    final routeID = catalog.assignments[source['id']];
    return _compileIn(
      request,
      _compileContext(
        catalog,
        routeID == null ? null : catalog.route(routeID as String),
        _nodeSettings(catalog, node),
      ),
      node,
    );
  }

  // The compiler turns on the counters the tunnel reads.
  static String _compileIn(
    DomainRequest request,
    CatalogMap context,
    CatalogMap node,
  ) =>
      request('compileProfile', {
            ...context,
            'profile': node['config'],
          })['configUtf8']!
          as String;

  // Everything a compile takes besides the server's own config.
  static CatalogMap _compileContext(
    DesktopCatalog catalog,
    CatalogMap? routing,
    TunnelSettings nodeSettings,
  ) {
    final settings = nodeSettings.listeners;
    return {
      'routes': routing?['enabled'] == true ? routing!['routeModel'] : null,
      'socksPort': settings.socksPort,
      'packetBackend': settings.xrayTunEnabled ? 'xrayTun' : 'nativeTun2Proxy',
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
    };
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

final class _Compiled {
  _Compiled(this.digest, this.pass);
  final String digest;
  // The last pass over a catalog that used this entry; unused ones are dropped.
  int pass;
}

/// What a server's health record is bound to.
final class _Semantics {
  _Semantics(this.config, this.key, this.shared, this.assetRevision);
  final Object? config, assetRevision;
  // The compile inputs as text: the server's config, and the rest.
  final String key, shared;
  // A digest of the compiled config, the error that kept it from compiling,
  // or null for a server that is not compiled.
  String? compiled;
}
