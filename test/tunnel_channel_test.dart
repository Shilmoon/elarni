import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:elarni/tunnel_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.elarni/tunnel');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final control = NativeTunnelControl();
  final calls = <MethodCall>[];
  Object? reply;
  setUp(() {
    calls.clear();
    reply = {
      'subscriptions': {'subscriptions': [], 'selectedNodeId': null},
    };
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return reply;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  // Windows and Linux name subscription states differently from macOS, whose
  // words the interface shows; a device answer arrives as a refresh error.
  test('desktop subscription states read in the interface vocabulary', () {
    String status(String status, [String? error]) => SubscriptionGroup.fromMap({
      'id': 'source',
      'name': 'Provider',
      'status': status,
      'refreshError': error,
    }).status;
    expect(status('needsApproval'), 'approval_required');
    expect(status('failed', 'fetch_failed'), 'refresh_failed');
    expect(status('failed', 'hwid_required'), 'device_required');
    expect(status('failed', 'hwid_limit'), 'device_limit');
    expect(status('pending'), 'pending');
    for (final same in ['ready', 'refreshing', 'device_limit']) {
      expect(status(same), same);
    }
  });

  // 0.3.6 stored a headless client's null as is; every snapshot then failed.
  test('a stored non-text download option leaves the snapshot readable', () {
    final group = SubscriptionGroup.fromMap({
      'id': 'source',
      'name': 'Provider',
      'status': 'ready',
      'fetchOptions': {'connectAddress': null, 'userAgent': 'Fixture/1'},
    });
    expect(group.fetchOptions, {'userAgent': 'Fixture/1'});
  });

  test(
    'subscription interval defaults to four hours and round-trips through the channel',
    () async {
      expect(const TunnelSettings().subscriptionAutoUpdateHours, 4);
      expect(TunnelSettings.fromMap({}).subscriptionAutoUpdateHours, 4);
      final settings = const TunnelSettings().copyWith(
        subscriptionAutoUpdateHours: 12,
      );
      reply = settings.toMap();
      expect(
        (await control.updateTunnelSettings(
          settings,
        )).subscriptionAutoUpdateHours,
        12,
      );
      expect(
        (calls.single.arguments as Map)['subscriptionAutoUpdateHours'],
        12,
      );
      expect(
        TunnelSettings.fromMap(
          settings.toMap(),
        ).copyWith(muxEnabled: true).subscriptionAutoUpdateHours,
        12,
      );
    },
  );

  test(
    'connection recording: the switch is off by default and round-trips',
    () {
      expect(TunnelSettings.fromMap({}).recordDiagnostics, isFalse);
      final on = const TunnelSettings().copyWith(recordDiagnostics: true);
      expect(on.toMap()['recordDiagnostics'], isTrue);
      // A build without the recorder drops the switch a recording build saved.
      expect(
        TunnelSettings.fromMap(on.toMap()).recordDiagnostics,
        recordingBuild,
      );
      expect(on.copyWith(muxEnabled: true).recordDiagnostics, isTrue);
    },
  );

  test(
    'connection links accept commands without accepting import data or URL options',
    () {
      for (final scheme in ['elarni', 'incy', 'happ']) {
        expect(
          ConnectionAction.fromLink('$scheme://open'),
          ConnectionAction.connect,
        );
        expect(
          ConnectionAction.fromLink('$scheme://close/'),
          ConnectionAction.disconnect,
        );
        expect(
          ConnectionAction.fromLink('$scheme://toggle'),
          ConnectionAction.toggle,
        );
        expect(
          ConnectionAction.fromLink('$scheme://status'),
          ConnectionAction.status,
        );
      }
      expect(
        ConnectionAction.fromLink('INCY://CONNECT'),
        ConnectionAction.connect,
      );
      for (final link in [
        'https://connect',
        'incy://connect?data=secret',
        'incy://connect#secret',
        'incy://user@connect',
        'incy://connect:443',
        'incy://connect/profile',
        'incy://import/https://example.com',
        'incy://disconnect\n',
      ]) {
        expect(ConnectionAction.fromLink(link), isNull, reason: link);
      }
    },
  );

  test(
    'per-app settings preserve old catalogs and reject invalid selections',
    () {
      expect(TunnelSettings.fromMap({}).perAppMode, 'off');
      const selected = TunnelSettings(
        xrayTunEnabled: true,
        perAppMode: 'proxyOnly',
        perAppProcesses: ['browser.exe', '/usr/bin/curl'],
      );
      final saved = TunnelSettings.fromMap(selected.toMap());
      expect(saved.perAppProcesses, selected.perAppProcesses);
      expect(saved.validPerApp, isTrue);
      expect(saved.copyWith(xrayTunEnabled: false).validPerApp, isFalse);
      expect(saved.copyWith(perAppProcesses: []).validPerApp, isFalse);
      expect(
        saved.copyWith(perAppProcesses: ['curl\nother']).validPerApp,
        isFalse,
      );
    },
  );

  test('per-app targets round trip and refuse what the core cannot honour', () {
    const settings = TunnelSettings(
      xrayTunEnabled: true,
      perAppMode: 'bypass',
      perAppProcesses: ['steam.exe', 'telegram.exe', 'game.exe', 'browser.exe'],
      perAppTargets: {
        'steam.exe': 'routing',
        'telegram.exe': 'node:nl-4',
        'game.exe': 'block',
        'browser.exe': 'proxy:socks5://127.0.0.1:1080',
      },
    );
    final saved = TunnelSettings.fromMap(settings.toMap());
    expect(saved.perAppTargets, settings.perAppTargets);
    expect(saved.validPerApp, isTrue);
    expect(TunnelSettings.fromMap({}).perAppTargets, isEmpty);
    for (final proxy in [
      'http://localhost:8080',
      'socks://[::1]:1080',
      'http://127.0.0.1:3128/',
    ]) {
      expect(
        TunnelSettings.perAppProxyError(proxy, settings),
        isNull,
        reason: proxy,
      );
    }
    for (final targets in [
      {'unlisted.exe': 'block'},
      {'game.exe': 'tor'},
      {'game.exe': 'node:'},
      {'game.exe': 'proxy:socks5://192.0.2.1:1080'},
      {'game.exe': 'proxy:socks5://user:pass@127.0.0.1:1080'},
      {'game.exe': 'proxy:ftp://127.0.0.1:21'},
      {'game.exe': 'proxy:socks5://127.0.0.1'},
      {'game.exe': 'proxy:socks5://127.0.0.1:1080/path'},
      // Elarni's own listener would loop.
      {'game.exe': 'proxy:socks5://127.0.0.1:10890'},
    ]) {
      expect(
        settings.copyWith(perAppTargets: targets).validPerApp,
        isFalse,
        reason: '$targets',
      );
    }
  });

  test(
    'provider IP settings inherit by default and can return to inheritance',
    () {
      final legacy = TunnelSettings.fromMap({'preferredIP': 'ipv4'});
      expect(legacy.profilePreferredIP, 'inherit');
      expect(legacy.toMap()['profilePreferredIP'], isNull);
      final overridden = legacy.copyWith(profilePreferredIP: 'ipv6');
      expect(overridden.toMap()['profilePreferredIP'], 'ipv6');
      expect(
        overridden
            .copyWith(profilePreferredIP: 'inherit')
            .toMap()['profilePreferredIP'],
        isNull,
      );
      expect(overridden.preferredIP, 'ipv4');
    },
  );

  test(
    'desktop memory defaults to automatic and preserves explicit values',
    () {
      expect(const TunnelSettings().memoryLimitMB, 0);
      expect(TunnelSettings.fromMap({}).memoryLimitMB, 0);
      // macOS migrates its old values in native settings; Windows retains them.
      for (final limit in [0, 40, 45, 50, 64, 256, 4096]) {
        final value = const TunnelSettings().copyWith(memoryLimitMB: limit);
        expect(TunnelSettings.fromMap(value.toMap()).memoryLimitMB, limit);
      }
    },
  );

  test(
    'client import and format selection retain native request contracts',
    () async {
      await control.importClientProfiles(content: 'fixture-client-profile');
      await control.importClientProfiles(source: 'qrImage');
      await control.refreshSubscription(
        'group',
        challenge: 'approval',
        format: 'json',
      );
      expect(calls.map((call) => call.arguments), [
        {'source': 'text', 'content': 'fixture-client-profile'},
        {'source': 'qrImage'},
        {'id': 'group', 'challenge': 'approval', 'format': 'json'},
      ]);
    },
  );

  test(
    'node selection decodes state and selection from the native snapshot',
    () async {
      reply = {
        'state': 'connected',
        'subscriptions': {'selectedNodeId': 'node', 'subscriptions': []},
      };
      final result = await control.selectNode('node');
      expect(calls.single.method, 'selectNode');
      expect(calls.single.arguments, {'id': 'node'});
      expect(result.state, 'connected');
      expect(result.subscriptions.selectedNodeId, 'node');
    },
  );

  test(
    'settings preserve routes and runtime flags without sending credential state',
    () async {
      const settings = TunnelSettings(
        allowLAN: true,
        inboundAuthEnabled: true,
        inboundCredentialsConfigured: true,
        preferredIP: 'automatic',
        includedRoutes: ['192.0.2.0/24', '2001:db8::/32'],
        excludedRoutes: ['203.0.113.1/32'],
      );
      reply = settings.toMap();
      final result = await control.updateTunnelSettings(settings);
      final sent = calls.single.arguments as Map;
      expect(calls.single.method, 'updateTunnelSettings');
      expect(sent['includedRoutes'], ['192.0.2.0/24', '2001:db8::/32']);
      expect(sent['excludedRoutes'], ['203.0.113.1/32']);
      expect(sent['allowLAN'], isTrue);
      expect(sent['inboundAuthEnabled'], isTrue);
      expect(sent.containsKey('inboundCredentialsConfigured'), isFalse);
      expect(result.preferredIP, 'automatic');
    },
  );

  test(
    'invalid ping options are rejected before invoking native code',
    () async {
      for (final value in [
        (protocol: 'invalid', timeout: 7, url: 'https://example.com'),
        (protocol: 'proxy', timeout: 4, url: 'https://example.com'),
        (protocol: 'proxy', timeout: 16, url: 'https://example.com'),
        (protocol: 'proxy', timeout: 7, url: 'https://user:pass@example.com'),
        (protocol: 'proxy', timeout: 7, url: ''),
        (protocol: 'activeProxy', timeout: 7, url: ''),
      ]) {
        await expectLater(
          control.pingNode(
            'node',
            protocol: value.protocol,
            method: 'GET',
            mode: 'default',
            timeout: value.timeout,
            url: value.url,
          ),
          throwsFormatException,
        );
      }
      expect(calls, isEmpty);
    },
  );

  test('TCP and ICMP ping need no test URL', () async {
    reply = {'nodeId': 'node', 'status': 'ok', 'latencyMs': 3, 'timestamp': 1};
    for (final protocol in ['tcp', 'icmp']) {
      // The settings hide the URL for these protocols, so it can be empty.
      final result = await control.pingNode(
        'node',
        protocol: protocol,
        method: 'GET',
        mode: 'default',
        timeout: 5,
        url: '',
      );
      expect(result.latencyMs, 3);
    }
    expect(calls.map((call) => (call.arguments as Map)['protocol']), [
      'tcp',
      'icmp',
    ]);
  });

  test(
    'ping forwards response expectations and decodes numeric timestamps',
    () async {
      reply = {
        'nodeId': 'node',
        'status': 'ok',
        'latencyMs': 12,
        'timestamp': 1000,
      };
      final result = await control.pingNode(
        'node',
        protocol: 'activeProxy',
        method: 'HEAD',
        mode: 'double',
        timeout: 15,
        url: 'https://example.com/probe',
        expectedStatus: 200,
        expectedBody: 'fixture',
      );
      expect(calls.single.arguments, {
        'nodeId': 'node',
        'protocol': 'activeProxy',
        'method': 'HEAD',
        'mode': 'double',
        'timeout': 15,
        'url': 'https://example.com/probe',
        'expectedStatus': 200,
        'expectedBody': 'fixture',
      });
      expect(result.latencyMs, 12);
      expect(result.timestamp, 1000.0);
    },
  );

  test(
    'unknown or empty warning risks fail instead of bypassing approval',
    () async {
      for (final risks in [
        <String>[],
        ['unknown-risk'],
      ]) {
        reply = {
          'subscriptions': {'subscriptions': []},
          'warning': {
            'subscriptionId': 'group',
            'challenge': 'token',
            'riskCodes': risks,
          },
        };
        await expectLater(
          control.addSubscription('https://example.com/feed'),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'native failures keep their error codes and null state replies fail closed',
    () async {
      messenger.setMockMethodCallHandler(
        channel,
        (_) async =>
            throw PlatformException(code: 'node_switch_failed_restored'),
      );
      await expectLater(
        control.selectNode('node'),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'node_switch_failed_restored',
          ),
        ),
      );
      messenger.setMockMethodCallHandler(channel, (_) async => null);
      expect(await control.connect(), 'failed');
    },
  );
}
