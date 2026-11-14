import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:elarni/desktop_catalog.dart';
import 'package:elarni/desktop_proxy.dart';
import 'package:elarni/system_proxy.dart';
import 'package:elarni/tunnel_channel.dart';

// An OS setting that is either the user's own or a port Elarni pointed it at.
final class _FakeOS implements SystemProxy {
  ProxySettings current = {'user': 'pac'};

  @override
  Future<ProxySettings> read() async => {...current};

  @override
  Future<void> point(int port) async => current = {'port': port};

  final restored = Completer<void>();

  @override
  Future<void> write(ProxySettings settings) async {
    current = {...settings};
    if (!restored.isCompleted) restored.complete();
  }

  @override
  bool pointsAt(ProxySettings settings, int port) => settings['port'] == port;
}

// A core that answers each request line with [answer]'s reply, if any, and
// exits when its input closes.
final class _FakeCore implements Process {
  _FakeCore(FutureOr<String?> Function(String method) answer) {
    stdin = _Requests((line) async {
      final reply = await answer((jsonDecode(line) as Map)['method'] as String);
      if (reply != null && !_exit.isCompleted)
        _output.add(utf8.encode('$reply\n'));
    }, kill);
  }
  final _output = StreamController<List<int>>();
  final _exit = Completer<int>();
  @override
  late final IOSink stdin;
  @override
  Stream<List<int>> get stdout => _output.stream;
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  Future<int> get exitCode => _exit.future;
  @override
  int get pid => 1;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (!_exit.isCompleted) {
      _exit.complete(0);
      _output.close();
    }
    return true;
  }
}

final class _Requests implements IOSink {
  _Requests(this._line, this._closed);
  final void Function(String) _line;
  final void Function() _closed;
  @override
  void writeln([Object? object = '']) => _line('$object');
  @override
  Future<void> flush() async {}
  @override
  Future<void> close() async => _closed();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The UI polls state every second; a locked keyring or a second instance must
  // not respawn the core or re-prompt for the keyring on every poll.
  test('a failed catalog load is retried only after a pause', () async {
    var loads = 0;
    final proxy = DesktopProxy(
      corePath: 'unused-core',
      domainPath: 'unused-domain',
      catalogIO: (method, _) async {
        if (method == 'loadCatalog') loads++;
        throw PlatformException(code: 'storage_busy');
      },
      platformIO: (_, _) async => {},
    );
    addTearDown(proxy.dispose);
    for (var i = 0; i < 3; i++) {
      await expectLater(
        proxy.control.subscriptions(),
        throwsA(isA<PlatformException>()),
      );
    }
    expect(loads, 1);
  });

  // The proxy setting and its backup belong to the instance that holds the
  // catalog; a second one is refused before it may "recover" them.
  test('a refused second instance leaves the system proxy alone', () async {
    final temporary = await Directory.systemTemp.createTemp('elarni-second-');
    addTearDown(() => temporary.delete(recursive: true));
    final backup = File('${temporary.path}/Elarni/system-proxy.json');
    final os = _FakeOS();
    expect(await SystemProxySession(os, backup).sync(10891), isNull);

    final second = DesktopProxy(
      corePath: 'unused-core',
      domainPath: 'unused-domain',
      catalogIO: (_, _) async => throw PlatformException(code: 'storage_busy'),
      platformIO: (_, _) async => {},
      systemProxy: SystemProxySession(os, backup),
    );
    addTearDown(second.dispose);
    await expectLater(
      second.control.subscriptions(),
      throwsA(isA<PlatformException>()),
    );
    expect(os.current, {'port': 10891});
    expect(await backup.exists(), isTrue);
  });

  // A crashed run's setting is put back even while the catalog cannot be read.
  test('a locked catalog does not delay the system proxy recovery', () async {
    final temporary = await Directory.systemTemp.createTemp('elarni-locked-');
    addTearDown(() => temporary.delete(recursive: true));
    final backup = File('${temporary.path}/Elarni/system-proxy.json');
    final os = _FakeOS();
    expect(await SystemProxySession(os, backup).sync(10891), isNull);

    final next = DesktopProxy(
      corePath: 'unused-core',
      domainPath: 'unused-domain',
      catalogIO: (_, _) async =>
          throw PlatformException(code: 'storage_unavailable'),
      platformIO: (_, _) async => {},
      systemProxy: SystemProxySession(os, backup),
    );
    addTearDown(next.dispose);
    await expectLater(
      next.control.subscriptions(),
      throwsA(isA<PlatformException>()),
    );
    expect(os.current, {'user': 'pac'});
    expect(await backup.exists(), isFalse);
  });

  // Reading the catalog can wait on a keyring prompt. The lease already says
  // this is the only instance, so the dead proxy setting does not wait too.
  test(
    'a crashed run\'s proxy is put back before the catalog is read',
    () async {
      final temporary = await Directory.systemTemp.createTemp('elarni-prompt-');
      addTearDown(() => temporary.delete(recursive: true));
      final backup = File('${temporary.path}/Elarni/system-proxy.json');
      final os = _FakeOS();
      expect(await SystemProxySession(os, backup).sync(10891), isNull);

      final release = Completer<void>();
      final proxy = DesktopProxy(
        corePath: 'unused-core',
        domainPath: 'unused-domain',
        // The lease is granted; the catalog read answers when released.
        startProcess: (_) async => _FakeCore(
          (method) => method == 'acquireCatalog'
              ? '{"success":true}'
              : release.future.then(
                  (_) => '{"success":false,"error":"storage_unavailable"}',
                ),
        ),
        platformIO: (_, _) async => {},
        systemProxy: SystemProxySession(os, backup),
      );
      final loading = proxy.control.subscriptions();
      unawaited(loading.then<void>((_) {}, onError: (Object _) {}));
      await os.restored.future.timeout(const Duration(seconds: 5));
      expect(os.current, {'user': 'pac'});

      release.complete();
      await expectLater(loading, throwsA(isA<PlatformException>()));
      expect(await backup.exists(), isFalse);
      await proxy.dispose();
    },
  );

  // A catalog that decrypts but is not a catalog says so, and stays as it is
  // on disk for a later version or a repair to read.
  test('a catalog of the wrong shape is corrupt, not a crash', () async {
    for (final document in <Object>[
      'x',
      [1],
      {'version': 1, 'committed': 'x'},
      {
        'version': 1,
        'committed': {...DesktopCatalog.empty(), 'subscriptions': 'x'},
      },
      {
        'version': 1,
        'committed': {
          ...DesktopCatalog.empty(),
          'profiles': [1],
        },
      },
    ]) {
      final calls = <String>[];
      final proxy = DesktopProxy(
        corePath: 'unused-core',
        domainPath: 'unused-domain',
        catalogIO: (method, _) async {
          calls.add(method);
          return {'revision': 'r', 'catalog': document};
        },
        platformIO: (_, _) async => {},
      );
      await expectLater(
        proxy.control.subscriptions(),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'storage_corrupt',
          ),
        ),
        reason: '$document',
      );
      expect(calls, ['loadCatalog'], reason: '$document');
      await proxy.dispose();
    }
  });

  // What automation was doing when the app last stopped is not worth the catalog.
  test('an unreadable automation episode starts a new one', () async {
    for (final episode in <Object>[
      [1],
      {'attempts': '1'},
    ]) {
      final proxy = DesktopProxy(
        corePath: 'unused-core',
        domainPath: 'unused-domain',
        catalogIO: (method, _) async => {
          'revision': 'r',
          'catalog': {
            'version': 1,
            'committed': {
              ...DesktopCatalog.empty(),
              'automationEpisode': episode,
            },
          },
        },
        platformIO: (_, _) async => {},
      );
      expect(
        await proxy.control.subscriptions(),
        isA<SubscriptionSnapshot>(),
        reason: '$episode',
      );
      await proxy.dispose();
    }
  });

  // A daemon whose catalog never opened must exit at once, not after the retry pause.
  test('dispose cancels the retry pause of a failed load', () async {
    final timers = <Timer>[];
    await runZoned(
      () async {
        final proxy = DesktopProxy(
          corePath: 'unused-core',
          domainPath: 'unused-domain',
          catalogIO: (_, _) async =>
              throw PlatformException(code: 'storage_busy'),
          platformIO: (_, _) async => {},
        );
        await expectLater(
          proxy.control.subscriptions(),
          throwsA(isA<PlatformException>()),
        );
        await proxy.dispose();
      },
      zoneSpecification: ZoneSpecification(
        createTimer: (self, parent, zone, duration, callback) {
          final timer = parent.createTimer(zone, duration, callback);
          timers.add(timer);
          return timer;
        },
      ),
    );
    expect(timers.where((timer) => timer.isActive), isEmpty);
  });

  // The old 256 TCP / 128 UDP defaults refused new TUN flows and DNS under
  // daily load. Loading raises them once; later choices survive reloads.
  test('loading a catalog raises old default session limits once', () async {
    Future<(TunnelSettings, CatalogMap?)> load(
      int tcp,
      int udp, {
      required bool migrated,
    }) async {
      final committed = DesktopCatalog.empty()
        ..['settings'] = const TunnelSettings(
          xrayTunEnabled: true,
        ).copyWith(tcpMaxConnections: tcp, udpMaxConnections: udp).toMap();
      if (!migrated) committed.remove('sessionLimitsMigrated');
      CatalogMap? saved;
      final proxy = DesktopProxy(
        corePath: 'unused-core',
        domainPath: 'unused-domain',
        catalogIO: (method, payload) async {
          if (method == 'saveCatalog') {
            saved = catalogMap(catalogMap(payload['catalog'])['committed']);
            return {'revision': 'r2'};
          }
          return {
            'revision': 'r1',
            'catalog': {'version': 1, 'committed': committed},
          };
        },
        platformIO: (_, _) async => {},
      );
      addTearDown(proxy.dispose);
      return (await proxy.control.tunnelSettings(), saved);
    }

    expect(const TunnelSettings().tcpMaxConnections, 2048);
    expect(TunnelSettings.fromMap({}).udpMaxConnections, 1024);

    var (settings, saved) = await load(256, 128, migrated: false);
    expect(
      [settings.tcpMaxConnections, settings.udpMaxConnections],
      [2048, 1024],
    );
    expect(saved?['sessionLimitsMigrated'], true);
    expect(
      TunnelSettings.fromMap(catalogMap(saved?['settings'])).tcpMaxConnections,
      2048,
    );

    (settings, saved) = await load(512, 128, migrated: false);
    expect(
      [settings.tcpMaxConnections, settings.udpMaxConnections],
      [512, 1024],
    );

    (settings, saved) = await load(256, 128, migrated: true);
    expect(
      [settings.tcpMaxConnections, settings.udpMaxConnections],
      [256, 128],
    );
    expect(saved, isNull);
  });
}
