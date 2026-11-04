// Run through scripts/check-windows so these checks use actual native binaries.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:elarni/connection_support.dart';
import 'package:elarni/desktop_proxy.dart';
import 'package:elarni/desktop_catalog.dart';
import 'package:elarni/tunnel_channel.dart';
import 'package:elarni/headless.dart';
import 'package:elarni/wifi_network.dart';

const userID = '00000000-0000-4000-8000-000000000001';
const body = 'elarni-windows-loopback-fixture';

Future<int> freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

// The core retires every asset revision its catalog does not name, so a test
// core on the user's own cache deletes their geofiles. This revision there must
// outlive the run (unless the user's app publishes routing changes meanwhile).
Future<void> guardUserAssets() async {
  if (!Platform.isWindows) return;
  final sentinel = await Directory(
    '${Platform.environment['LOCALAPPDATA']}/Elarni/assets/${desktopID()}',
  ).create(recursive: true);
  addTearDown(() async {
    final kept = await sentinel.exists();
    if (kept) await sentinel.delete();
    expect(
      kept,
      isTrue,
      reason: 'a test core retired the user\'s geofiles in ${sentinel.parent}',
    );
  });
}

Future<void> expectClosed(int port) async {
  await expectLater(
    Socket.connect(
      InternetAddress.loopbackIPv4,
      port,
      timeout: const Duration(seconds: 1),
    ),
    throwsA(isA<SocketException>()),
  );
}

Future<List<int>> readBytes(StreamIterator<int> input, int count) async {
  final result = <int>[];
  for (var i = 0; i < count; i++) {
    if (!await input.moveNext()) throw StateError('Truncated SOCKS response');
    result.add(input.current);
  }
  return result;
}

Future<void> checkSocks(
  int proxyPort,
  int targetPort, {
  String? username,
  String? password,
  String host = '127.0.0.1',
  String? targetDomain,
  Future<void> Function()? whileConnected,
}) async {
  final socket = await Socket.connect(InternetAddress.loopbackIPv4, proxyPort);
  final input = StreamIterator<int>(socket.expand((chunk) => chunk));
  try {
    socket.add([5, 1, username == null ? 0 : 2]);
    expect(
      await readBytes(input, 2).timeout(
        const Duration(seconds: 3),
        onTimeout: () => throw StateError('SOCKS greeting timed out'),
      ),
      [5, username == null ? 0 : 2],
    );
    if (username != null) {
      final user = utf8.encode(username), secret = utf8.encode(password!);
      socket.add([1, user.length, ...user, secret.length, ...secret]);
      expect(await readBytes(input, 2).timeout(const Duration(seconds: 3)), [
        1,
        0,
      ]);
    }
    final address = targetDomain == null
        ? [1, 127, 0, 0, 1]
        : [3, ascii.encode(targetDomain).length, ...ascii.encode(targetDomain)];
    socket.add([5, 1, 0, ...address, targetPort >> 8, targetPort & 255]);
    final header = await readBytes(input, 4).timeout(
      const Duration(seconds: 3),
      onTimeout: () => throw StateError('SOCKS connect response timed out'),
    );
    expect(header.take(3), [5, 0, 0]);
    switch (header[3]) {
      case 1:
        await readBytes(input, 6);
      case 4:
        await readBytes(input, 18);
      case 3:
        await readBytes(input, (await readBytes(input, 1)).single + 2);
      default:
        fail('Unknown SOCKS address type');
    }
    await whileConnected?.call();
    socket.add(
      ascii.encode(
        'GET /fixture HTTP/1.1\r\nHost: $host\r\nConnection: close\r\n\r\n',
      ),
    );
    final response = <int>[];
    while (await input.moveNext().timeout(
      const Duration(seconds: 3),
      onTimeout: () => throw StateError(
        'SOCKS HTTP response timed out after ${response.length} bytes',
      ),
    )) {
      response.add(input.current);
    }
    final text = utf8.decode(response);
    expect(text, startsWith('HTTP/1.1 200'));
    expect(text, contains(body));
  } finally {
    socket.destroy();
    await input.cancel();
  }
}

Future<void> checkHTTPRejected(int proxyPort, int targetPort) async {
  final client = HttpClient()..findProxy = (_) => 'PROXY 127.0.0.1:$proxyPort';
  client.connectionTimeout = const Duration(seconds: 2);
  try {
    final response = await (await client.getUrl(
      Uri.parse('http://127.0.0.1:$targetPort/fixture'),
    )).close().timeout(const Duration(seconds: 3));
    expect(response.statusCode, isNot(200));
  } on SocketException {
    // A rejected outbound may close the local proxy connection.
  } on HttpException {
    // A rejected outbound may close before an HTTP response.
  } on TimeoutException {
    // Blackhole rejection can deliberately drop traffic without a reply.
  } finally {
    client.close(force: true);
  }
}

void main() {
  final corePath = Platform.environment['ELARNI_TEST_CORE']!;
  final domainPath = Platform.environment['ELARNI_TEST_DOMAIN']!;
  final python = Platform.environment['ELARNI_TEST_PYTHON']!;
  late HttpServer target;
  late Process upstream;
  late String profile;
  late Directory temporary;
  late Map<String, String> coreEnvironment;
  late DesktopProxy backend;
  late TunnelSettings initialSettings;
  Process? lastProcess;
  String? stub;
  Completer<void>? launchGate;
  Completer<void>? launchEntered;
  var targetRequests = 0;
  var launches = 0;
  CatalogMap? storedCatalog;
  var storageRevision = 0;
  var rejectNextCommit = false;
  Completer<void>? commitGate;
  Completer<void>? commitEntered;
  String? pickedPath;
  // The Wi-Fi network the backend reads; the real one is left alone.
  WiFiReading wifi = (name: null, denied: false);
  bool? pickedImage;
  String? openedURL;
  String? savedBackup;
  String? savedLogs;
  String? pickedRecording;
  var linkAnswer = true;
  final linkPrompts = <String>[];
  var staleGuard = false;

  Future<CatalogMap> storage(String method, CatalogMap payload) async {
    // The storage lease also answers the unelevated DNS guard check.
    if (method == 'staleVPNGuard') return {'stale': staleGuard};
    if (method == 'loadCatalog')
      return {
        'revision': '$storageRevision',
        'catalog': storedCatalog == null ? null : copyCatalog(storedCatalog!),
      };
    expect(payload['revision'], '$storageRevision');
    final document = catalogMap(payload['catalog']);
    // The core refuses a catalog document over 12 MiB.
    if (utf8.encode(jsonEncode(document)).length > 12 * 1024 * 1024)
      throw desktopError('invalid_catalog');
    if (document['pending'] == null && rejectNextCommit) {
      rejectNextCommit = false;
      throw desktopError('storage_unavailable');
    }
    storedCatalog = copyCatalog(document);
    storageRevision++;
    if (document['pending'] == null && commitGate != null) {
      commitEntered!.complete();
      final gate = commitGate!;
      commitGate = null;
      await gate.future;
    }
    return {'revision': '$storageRevision'};
  }

  setUpAll(() async {
    await guardUserAssets();
    temporary = await Directory.systemTemp.createTemp('elarni-windows-check-');
    // The core retires routing assets it does not know; keep it off the user's cache.
    final cache = await Directory('${temporary.path}/cache').create();
    coreEnvironment = {
      'LOCALAPPDATA': cache.path,
      'XDG_CACHE_HOME': cache.path,
    };
    target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    target.listen((request) async {
      targetRequests++;
      request.response.persistentConnection = false;
      // As Cloudflare's trace, which Check exit reads.
      request.response.write(
        request.uri.path == '/cdn-cgi/trace'
            ? 'fl=29f\nh=cp.cloudflare.com\nip=203.0.113.7\ncolo=FRA\nloc=DE\n'
            : body,
      );
      await request.response.close();
    });
    final port = await freePort();
    final config = {
      'log': {'loglevel': 'none'},
      'inbounds': [
        {
          'listen': '127.0.0.1',
          'port': port,
          'protocol': 'vless',
          'settings': {
            'clients': [
              {'id': userID},
            ],
            'decryption': 'none',
          },
        },
      ],
      'outbounds': [
        {
          'protocol': 'freedom',
          'settings': {
            'finalRules': [
              {
                'action': 'allow',
                'ip': ['127.0.0.1/32'],
              },
            ],
          },
        },
      ],
    };
    upstream = await Process.start(
      corePath,
      const [],
      environment: coreEnvironment,
    );
    unawaited(upstream.stderr.drain<void>());
    final readiness = Completer<String>();
    upstream.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (!readiness.isCompleted) readiness.complete(line);
        });
    final ready = readiness.future;
    upstream.stdin.writeln(
      jsonEncode({
        'apiVersion': 1,
        'method': 'runXrayFromJson',
        'payload': {'configJSON': jsonEncode(config)},
      }),
    );
    await upstream.stdin.flush();
    expect(
      (jsonDecode(await ready.timeout(const Duration(seconds: 10)))
          as Map)['success'],
      isTrue,
    );
    profile =
        'vless://$userID@127.0.0.1:$port?encryption=none&security=none&type=tcp#Fixture';
  });

  tearDownAll(() async {
    await upstream.stdin.close();
    await upstream.exitCode.timeout(
      const Duration(seconds: 4),
      onTimeout: () {
        upstream.kill();
        return -1;
      },
    );
    await target.close(force: true);
    await temporary.delete(recursive: true);
  });

  Future<Process> startCore(String path) =>
      Process.start(path, const [], environment: coreEnvironment);

  DesktopProxy createBackend({
    Duration? replyTimeout,
    Duration? helperExitGrace,
    int? automationProbeSeconds,
    int? automationRetrySeconds,
    List<CatalogMap>? livenessTargets,
    Duration? livenessInterval,
    DateTime Function()? clock,
    Duration? refreshInterval,
  }) {
    final created = DesktopProxy(
      corePath: corePath,
      domainPath: domainPath,
      catalogIO: storage,
      replyTimeout: replyTimeout,
      helperExitGrace: helperExitGrace,
      automationProbeSeconds: automationProbeSeconds,
      automationRetrySeconds: automationRetrySeconds,
      livenessTargets: livenessTargets,
      livenessInterval: livenessInterval,
      clock: clock,
      refreshInterval: refreshInterval,
      wifiNetwork: () async => wifi,
      wifiInterval: const Duration(milliseconds: 50),
      confirmLink: (prompt) async {
        linkPrompts.add(prompt);
        return linkAnswer;
      },
      cameraScan: (decode) async {
        if (pickedPath == null) throw desktopError('cancelled');
        return decode(await File(pickedPath!).readAsBytes());
      },
      platformIO: (method, payload) async {
        if (method == 'saveBackup') {
          savedBackup = payload['content']! as String;
          return {'saved': true};
        }
        if (method == 'saveLogs') {
          savedLogs = payload['content']! as String;
          return {};
        }
        if (method == 'openURL') {
          openedURL = payload['url']! as String;
          return {'opened': true};
        }
        if (method == 'systemInfo') return {};
        if (method == 'pickRecordingPath') {
          if (pickedRecording == null) throw desktopError('cancelled');
          return {'path': pickedRecording};
        }
        expect(method, 'pickFile');
        pickedImage = payload['image'] as bool;
        return {if (pickedPath != null) 'path': pickedPath};
      },
      startProcess: (path) async {
        launches++;
        if (launchEntered?.isCompleted == false) launchEntered!.complete();
        await launchGate?.future;
        return lastProcess = await (stub == null
            ? startCore(path)
            : Process.start(python, [stub!], environment: coreEnvironment));
      },
    );
    return created;
  }

  // Stub helpers never exit on their own, so these checks need not wait out
  // the production reply timeout and exit grace.
  Future<void> useImpatientBackend() async {
    await backend.dispose();
    backend = createBackend(
      replyTimeout: const Duration(seconds: 2),
      helperExitGrace: const Duration(milliseconds: 500),
    );
  }

  setUp(() async {
    storedCatalog = null;
    storageRevision = 0;
    rejectNextCommit = false;
    commitGate = null;
    commitEntered = null;
    stub = null;
    launchGate = null;
    launchEntered = null;
    lastProcess = null;
    pickedPath = null;
    wifi = (name: null, denied: false);
    pickedImage = null;
    openedURL = null;
    savedBackup = null;
    linkAnswer = true;
    linkPrompts.clear();
    staleGuard = false;
    backend = createBackend();
    final settings = initialSettings = await backend.control.tunnelSettings();
    final socks = await freePort();
    var http = await freePort();
    while (http == socks) {
      http = await freePort();
    }
    await backend.control.updateTunnelSettings(
      settings.copyWith(
        socksPort: socks,
        httpPort: http,
        xrayTunEnabled: false,
        httpInboundEnabled: true,
        // The "allow apps without login" switch; a fresh install starts with a login.
        inboundAuthEnabled: false,
      ),
    );
  });

  tearDown(() async {
    await backend.dispose();
  });

  Future<void> prepare() async {
    final imported = await backend.control.importClientProfiles(
      content: profile,
    );
    expect(imported.snapshot.subscriptions.single.nodes.single.name, 'Fixture');
    await backend.control.selectNode(
      imported.snapshot.subscriptions.single.nodes.single.id,
    );
  }

  Future<void> useStub(String source) async {
    final file = File.fromUri(temporary.uri.resolve('core.py'));
    await file.writeAsString(source);
    stub = file.path;
  }

  // A core whose DNS guard clear is declined at the consent prompt. It fails
  // every other command and logs each method to the returned file.
  Future<File> declineGuardClear() async {
    final requests = File.fromUri(temporary.uri.resolve('guard-requests.txt'));
    if (await requests.exists()) await requests.delete();
    await useStub('''
import json, sys
method = json.loads(sys.stdin.readline())['method']
with open(${jsonEncode(requests.path)}, 'a') as log:
    log.write(method + '\\n')
error = 'elevation_denied' if method == 'clearVPNGuard' else 'connection_failed'
print(json.dumps({'success': False, 'error': error}), flush=True)
''');
    return requests;
  }

  for (final tun in [false, true]) {
    test(
      'SOCKS client link imports and persists with tunnel mode $tun',
      () async {
        await backend.control.updateTunnelSettings(
          (await backend.control.tunnelSettings()).copyWith(
            xrayTunEnabled: tun,
          ),
        );
        final imported = await backend.control.importClientProfiles(
          content: 'socks://127.0.0.1:18090#Linux%20fixture',
        );
        expect(
          imported.snapshot.subscriptions.single.nodes.single.name,
          'Linux fixture',
        );
        expect(storedCatalog!['pending'], isNull);
        expect(
          catalogMap(storedCatalog!['committed'])['subscriptions'],
          isNotEmpty,
        );
      },
    );
  }

  test(
    'encrypted backup restores groups routing selection and live traffic atomically',
    () async {
      const password = 'synthetic backup password';
      final port = Uri.parse(profile).port;
      final clash =
          '''
proxies:
  - {name: working, type: vless, server: 127.0.0.1, port: $port, uuid: $userID, tls: false}
proxy-groups:
  - {name: PROXY, type: select, proxies: [REJECT, working]}
rules:
  - MATCH,PROXY
''';
      final source = (await backend.control.importClientProfiles(
        content: clash,
      )).snapshot.subscriptions.single;
      await backend.control.selectProfileGroup(
        source.nodes.single.id,
        'PROXY',
        'working',
      );
      await backend.control.selectNode(source.nodes.single.id);
      await backend.control.setNodeIPPreference(source.nodes.single.id, 'ipv4');
      final routes = await backend.control.importRouting(
        jsonEncode({
          'Name': 'Backup route',
          'RemoteDNSType': 'DoU',
          'RemoteDNSIP': '1.1.1.1',
          'DomesticDNSType': 'DoU',
          'DomesticDNSIP': '8.8.8.8',
          'DirectSites': ['full:example.com'],
        }),
      );
      await backend.control.assignRoutingProfile(
        source.id,
        routes.profiles.single.id,
      );
      await backend.control.importClientProfiles(
        content:
            '$profile\ntg://proxy?server=proxy.example&port=443&secret=000102030405060708090a0b0c0d0e0f',
      );
      final before = await backend.control.subscriptions();
      final settings = await backend.control.tunnelSettings();
      await backend.control.exportCatalogBackup(password);
      expect(savedBackup, isNot(contains(userID)));
      final file = File.fromUri(temporary.uri.resolve('encrypted backup.json'));
      await file.writeAsString(savedBackup!);
      pickedPath = file.path;
      await expectLater(
        backend.control.restoreCatalogBackup('incorrect password'),
        throwsA(isA<PlatformException>()),
      );
      expect(
        (await backend.control.subscriptions()).selectedNodeId,
        before.selectedNodeId,
      );
      rejectNextCommit = true;
      await expectLater(
        backend.control.restoreCatalogBackup(password),
        throwsA(isA<PlatformException>()),
      );
      expect(
        (await backend.control.subscriptions()).selectedNodeId,
        before.selectedNodeId,
      );
      expect(
        (await backend.control.routingProfiles()).assignments[source.id],
        routes.profiles.single.id,
      );
      final restored = await backend.control.restoreCatalogBackup(password);
      // The profile and Telegram proxy joined the Clash import's local group.
      expect(restored.subscriptions.length, 1);
      expect(restored.selectedNodeId, isNot(before.selectedNodeId));
      final selected = restored.subscriptions.single.nodes.first;
      expect(selected.id, restored.selectedNodeId);
      expect(selected.groups.single.selected, 'working');
      expect(selected.ipPreference, 'ipv4');
      expect(
        restored.subscriptions.single.nodes.skip(1).map((n) => n.protocol),
        ['VLESS', 'MTProto'],
      );
      final restoredRoutes = await backend.control.routingProfiles();
      expect(restoredRoutes.profiles.single.name, 'Backup route');
      expect(
        restoredRoutes.assignments[restored.subscriptions.first.id],
        restoredRoutes.profiles.single.id,
      );
      expect(
        (await backend.control.tunnelSettings()).toMap(),
        settings.toMap(),
      );
      await backend.control.connect();
      await checkSocks(settings.socksPort, target.port);
      await expectLater(
        backend.control.restoreCatalogBackup(password),
        throwsA(isA<PlatformException>()),
      );
      await backend.control.repairTunnel();
      expect(await backend.control.state(), 'disconnected');
      await expectLater(
        Socket.connect(InternetAddress.loopbackIPv4, settings.socksPort),
        throwsA(isA<SocketException>()),
      );
      await backend.control.connect();
      await checkSocks(settings.socksPort, target.port);
    },
  );

  test(
    'connection recording follows the switch, keeps marks and exports a ZIP',
    () async {
      await prepare();
      final recordings = Directory(
        '${temporary.path}/cache/Elarni/Diagnostics',
      );
      if (await recordings.exists()) await recordings.delete(recursive: true);
      final settings = await backend.control.tunnelSettings();
      expect(settings.recordDiagnostics, isFalse);
      if (!recordingBuild) {
        // Without the build option nothing records, even with the setting on.
        await backend.control.updateTunnelSettings(
          settings.copyWith(recordDiagnostics: true),
        );
        await backend.control.connect();
        await checkSocks(settings.socksPort, target.port);
        await backend.control.disconnect();
        expect(await recordings.exists(), isFalse, reason: 'recorded');
        await expectLater(
          HeadlessControl(backend.request).call('exportRecording', {
            'destination': '${temporary.path}/empty.zip',
          }),
          throwsA(
            isA<PlatformException>().having(
              (error) => error.code,
              'code',
              'unsupported_method',
            ),
          ),
        );
        return;
      }
      await backend.control.connect();
      await checkSocks(settings.socksPort, target.port);
      await backend.control.disconnect();
      expect(await recordings.exists(), isFalse, reason: 'recorded while off');
      await expectLater(
        HeadlessControl(backend.request).call('exportRecording', {
          'destination': '${temporary.path}/empty.zip',
        }),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'recording_empty',
          ),
        ),
      );
      await backend.control.updateTunnelSettings(
        settings.copyWith(recordDiagnostics: true),
      );
      await backend.control.connect();
      await checkSocks(settings.socksPort, target.port);
      await backend.control.markRecording();
      pickedRecording = '${temporary.path}/recording.zip';
      if (await File(pickedRecording!).exists())
        await File(pickedRecording!).delete();
      await backend.control.exportRecording();
      pickedRecording = null;
      await backend.control.disconnect();
      // Deflated entries are read through Python's zipfile, the fixture's only extra tool.
      final listing = await Process.run(python, [
        '-c',
        'import sys, zipfile\n'
            'z = zipfile.ZipFile(sys.argv[1])\n'
            'print("\\n".join(z.read(n).decode() for n in z.namelist()))',
        '${temporary.path}/recording.zip',
      ]);
      expect(listing.exitCode, 0, reason: '${listing.stderr}');
      final text = listing.stdout as String;
      for (final event in [
        'collector_started',
        'runtime_config',
        'outbound_done',
        'user_stall_marker',
      ])
        expect(text, contains(event));
      for (final private in [userID, '127.0.0.1'])
        expect(text, isNot(contains(private)));
    },
  );

  test(
    'headless backup restore and diagnostics never use native file dialogs',
    () async {
      await prepare();
      final control = HeadlessControl(backend.request);
      final before = await backend.control.subscriptions();
      final sealed = await control.call('exportCatalogBackup', {
        'password': 'synthetic headless password',
      });
      expect(savedBackup, isNull);
      expect(sealed['text'], isNot(contains(userID)));
      final evidence = await control.call('exportEvidence');
      expect(evidence['schemaVersion'], 2);
      expect(jsonEncode(evidence), isNot(contains(userID)));
      await expectLater(
        control.call('restoreCatalogBackup', {
          'password': 'wrong',
          'content': sealed['text'],
        }),
        throwsA(isA<PlatformException>()),
      );
      expect(
        (await backend.control.subscriptions()).selectedNodeId,
        before.selectedNodeId,
      );
      await control.call('restoreCatalogBackup', {
        'password': 'synthetic headless password',
        'content': sealed['text'],
      });
      expect(pickedPath, isNull);
      final restored = await backend.control.subscriptions();
      expect(
        restored.subscriptions.single.nodes.single.name,
        before.subscriptions.single.nodes.single.name,
      );
      final settings = await backend.control.tunnelSettings();
      await control.call('connect');
      await checkSocks(settings.socksPort, target.port);
      await control.call('disconnect');
      await expectClosed(settings.socksPort);
    },
  );

  test(
    'system information says whether the VPN service lets this account connect without approval',
    () async {
      final account =
          '${(await Process.run('whoami', ['/user', '/fo', 'csv', '/nh'])).stdout}'
              .trim()
              .split(',')
              .last
              .replaceAll('"', '');
      expect(account, startsWith('S-1-'));
      // Only the elevated windows_vpn_features case installs the service on a test machine.
      final service = await Process.run('sc.exe', ['qc', 'ElarniVPN']);
      expect(
        (await backend.control.systemInfo())['vpnService'],
        service.exitCode == 0 && '${service.stdout}'.contains(account),
      );
    },
    skip: !Platform.isWindows,
  );

  test('export refuses a catalog that restore would reject', () async {
    await backend.control.importClientProfiles(
      content: profile.replaceFirst('#Fixture', '#${'n' * 1025}'),
    );
    await expectLater(
      backend.control.exportCatalogBackup('synthetic backup password'),
      throwsA(
        isA<PlatformException>().having(
          (e) => e.code,
          'code',
          'backup_unsupported',
        ),
      ),
    );
    expect(savedBackup, isNull);
  });

  test(
    'backup respects provider sharing restrictions and unknown subscriptions',
    () async {
      await backend.control.importClientProfiles(
        content: '#hide-url: yes\n$profile',
      );
      await expectLater(
        backend.control.exportCatalogBackup('synthetic backup password'),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'sharing_disabled',
          ),
        ),
      );
      expect(savedBackup, isNull);
      await backend.control.deleteSubscription(
        (await backend.control.subscriptions()).subscriptions.single.id,
      );
      await backend.control.addSubscription(
        'http://127.0.0.1:${target.port}/not-approved',
      );
      await expectLater(
        backend.control.exportCatalogBackup('synthetic backup password'),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'sharing_refresh_required',
          ),
        ),
      );
      expect(savedBackup, isNull);
    },
  );

  test(
    'Backup decoding excludes catalog edits and Stop cancels restoration',
    () async {
      await prepare();
      final source =
          (await backend.control.subscriptions()).subscriptions.single;
      final control = HeadlessControl(backend.request);
      const password = 'synthetic serialized restore password';
      final sealed = await control.call('exportCatalogBackup', {
        'password': password,
      });
      final before = jsonEncode(storedCatalog);
      launchEntered = Completer<void>();
      launchGate = Completer<void>();
      final gate = launchGate!;
      final restoration = expectLater(
        control.call('restoreCatalogBackup', {
          'password': password,
          'content': sealed['text'],
        }),
        throwsA(
          isA<PlatformException>().having((e) => e.code, 'code', 'cancelled'),
        ),
      );
      await launchEntered!.future;
      try {
        await expectLater(
          backend.control.renameSubscription(source.id, 'Concurrent edit'),
          throwsA(
            isA<PlatformException>().having((e) => e.code, 'code', 'busy'),
          ),
        );
      } finally {
        final stopping = backend.control.disconnect();
        gate.complete();
        await restoration;
        expect(await stopping, 'disconnected');
      }
      expect(jsonEncode(storedCatalog), before);
    },
  );

  test(
    'new catalogs use system VPN; saved local proxy choices survive relaunch',
    () async {
      expect(initialSettings.xrayTunEnabled, isTrue);
      expect(initialSettings.httpInboundEnabled, isFalse);
      final saved = await backend.control.tunnelSettings();
      await backend.dispose();
      backend = DesktopProxy(
        corePath: corePath,
        startProcess: startCore,
        domainPath: domainPath,
        catalogIO: storage,
        platformIO: (_, _) async => {},
      );
      expect((await backend.control.tunnelSettings()).toMap(), saved.toMap());
      expect(saved.xrayTunEnabled, isFalse);
      expect(saved.httpInboundEnabled, isTrue);
    },
  );

  test(
    'XHTTP fragmentation saves, starts the native helper and survives relaunch',
    () async {
      final imported = await backend.control.importClientProfiles(
        content: profile.replaceFirst(
          'security=none&type=tcp',
          'security=tls&type=xhttp&sni=fixture.test',
        ),
      );
      await backend.control.selectNode(
        imported.snapshot.subscriptions.single.nodes.single.id,
      );
      final settings = await backend.control.tunnelSettings();
      final enabled = settings.copyWith(
        fragmentationEnabled: true,
        fragmentLength: '50-150',
      );
      expect(
        (await backend.control.updateTunnelSettings(
          enabled,
        )).fragmentationEnabled,
        isTrue,
      );
      await backend.control.connect();
      expect(await backend.control.state(), 'connected');
      for (final value in [settings, enabled]) {
        final previous = lastProcess!;
        await backend.control.updateTunnelSettings(value);
        expect(lastProcess!.pid, isNot(previous.pid));
        expect(await previous.exitCode.timeout(const Duration(seconds: 10)), 0);
        expect(await backend.control.state(), 'connected');
      }
      await backend.dispose();
      backend = DesktopProxy(
        corePath: corePath,
        startProcess: startCore,
        domainPath: domainPath,
        catalogIO: storage,
        platformIO: (_, _) async => {},
      );
      final restored = await backend.control.tunnelSettings();
      expect(restored.fragmentationEnabled, isTrue);
      expect(restored.fragmentLength, '50-150');
    },
  );

  test(
    'policy settings preserve runtime; memory settings restart it',
    () async {
      await prepare();
      await backend.control.connect();
      final runtime = lastProcess!;
      final settings = await backend.control.tunnelSettings();
      expect(settings.memoryLimitMB, 0);
      expect(settings.subscriptionAutoUpdateHours, 4);
      await backend.control.updateTunnelSettings(
        settings.copyWith(subscriptionAutoUpdateHours: 12),
      );
      expect(lastProcess!.pid, runtime.pid);
      expect(
        (await backend.control.tunnelSettings()).subscriptionAutoUpdateHours,
        12,
      );
      for (final invalid in [0, 169]) {
        await expectLater(
          backend.control.updateTunnelSettings(
            settings.copyWith(subscriptionAutoUpdateHours: invalid),
          ),
          throwsA(isA<PlatformException>()),
        );
        expect(
          (await backend.control.tunnelSettings()).subscriptionAutoUpdateHours,
          12,
        );
      }
      await backend.control.updateTunnelSettings(
        settings.copyWith(
          monitoringEnabled: !settings.monitoringEnabled,
          onDemandEnabled: !settings.onDemandEnabled,
          disconnectOnSleep: !settings.disconnectOnSleep,
          connectOnUntrustedWiFi: true,
          trustedWiFiNetworks: ['Home'],
        ),
      );
      expect(lastProcess!.pid, runtime.pid);
      expect(await backend.control.state(), 'connected');
      await checkSocks(settings.socksPort, target.port);
      await backend.control.updateTunnelSettings(
        settings.copyWith(memoryLimitMB: 128),
      );
      expect(lastProcess!.pid, isNot(runtime.pid));
      expect(await runtime.exitCode.timeout(const Duration(seconds: 10)), 0);
      await checkSocks(settings.socksPort, target.port);
    },
  );

  test(
    'joining an untrusted Wi-Fi network connects; trusted ones and a Stop stay',
    () async {
      await prepare();
      final settings = await backend.control.tunnelSettings();
      for (final names in [
        ['x' * 33],
        ['tab\there'],
      ]) {
        await expectLater(
          backend.control.updateTunnelSettings(
            settings.copyWith(trustedWiFiNetworks: names),
          ),
          throwsA(isA<PlatformException>()),
        );
      }
      wifi = (name: 'Cafe', denied: false);
      await backend.control.updateTunnelSettings(
        settings.copyWith(
          connectOnUntrustedWiFi: true,
          trustedWiFiNetworks: ['Home', 'Caf\u00e9 5G'],
        ),
      );
      Future<void> until(String state) async {
        for (var i = 0; i < 200 && await backend.control.state() != state; i++)
          await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(await backend.control.state(), state);
      }

      // Turning it on while joined to an untrusted network counts as joining.
      await until('connected');
      await checkSocks(settings.socksPort, target.port);
      await backend.control.disconnect();
      wifi = (name: 'Caf\u00e9 5G', denied: false);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(await backend.control.state(), isNot('connected'));
      wifi = (name: 'Airport', denied: false);
      await until('connected');
      final restored = await backend.control.tunnelSettings();
      expect(restored.trustedWiFiNetworks, ['Home', 'Caf\u00e9 5G']);
    },
  );

  test(
    'the core log arrives redacted at its level and outlives the core',
    () async {
      await prepare();
      final settings = await backend.control.tunnelSettings();
      expect(settings.logLevel, 'warning');
      await expectLater(
        backend.control.updateTunnelSettings(
          settings.copyWith(logLevel: 'loud'),
        ),
        throwsA(isA<PlatformException>()),
      );
      Future<List<CatalogMap>> linesAfter(
        int after,
        bool Function(CatalogMap line) wanted,
      ) async {
        for (var attempt = 0; attempt < 100; attempt++) {
          final value = await backend.control.readLogs(after: after);
          final lines = [
            for (final line in value['entries']! as List) catalogMap(line),
          ];
          if (lines.any(wanted)) return lines;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        fail('no wanted log line after $after');
      }

      await backend.control.connect();
      var exited = false;
      unawaited(lastProcess!.exitCode.then((_) => exited = true));
      // Xray records its start as a warning.
      final started = await linesAfter(
        0,
        (line) =>
            line['level'] == 'warning' &&
            (line['text']! as String).endsWith(' started'),
      );
      final last = started.last['seq']! as int;
      await backend.control.updateTunnelSettings(
        settings.copyWith(logLevel: 'debug'),
      );
      expect(exited, isFalse, reason: 'a level change keeps the running core');
      expect((await backend.control.readLogs())['level'], 'debug');
      await backend.control.disconnect();
      expect(
        (await backend.control.readLogs())['entries'],
        isNotEmpty,
        reason: 'a stopped core keeps its lines',
      );
      await backend.control.connect();
      await checkSocks(settings.socksPort, target.port);
      final debug = await linesAfter(
        last,
        (line) => line['level'] == 'info' || line['level'] == 'debug',
      );
      expect(debug.first['seq']! as int, greaterThan(last));
      expect(
        jsonEncode(await backend.control.readLogs()),
        isNot(contains(userID)),
      );
      await backend.control.saveLogs('Elarni log, level debug');
      expect(savedLogs, 'Elarni log, level debug');
    },
  );

  test('configuration revisions follow each compiled-settings edit', () async {
    await prepare();
    Future<String?> revision() async => (await backend.control.subscriptions())
        .subscriptions
        .single
        .nodes
        .single
        .configurationRevision;
    final settings = await backend.control.tunnelSettings();
    final first = await revision();
    await backend.control.updateTunnelSettings(
      settings.copyWith(subscriptionAutoUpdateHours: 12),
    );
    expect(await revision(), first);
    await backend.control.updateTunnelSettings(
      settings.copyWith(sniffingEnabled: !settings.sniffingEnabled),
    );
    final second = await revision();
    expect(second, isNot(first));
    // Reverting compares against the edited configuration, not a stale one.
    await backend.control.updateTunnelSettings(settings);
    expect(await revision(), isNot(second));
  });

  test(
    'a server config edit validates, applies live and stays hidden where the provider hides it',
    () async {
      await prepare();
      final node = (await backend.control.subscriptions())
          .subscriptions
          .single
          .nodes
          .single;
      Future<SubscriptionNode> current() async =>
          (await backend.control.subscriptions()).subscriptions
              .expand((group) => group.nodes)
              .singleWhere((other) => other.id == node.id);
      final text = await backend.control.nodeConfig(node.id);
      final config = catalogMap(jsonDecode(text));
      expect(catalogList(config['outbounds']).single['protocol'], 'vless');
      // Saving the shown text unchanged is not a configuration change.
      await backend.control.updateNodeConfig(node.id, text);
      expect(
        (await current()).configurationRevision,
        node.configurationRevision,
      );
      // Broken, serverless and multi-server edits change nothing.
      for (final edit in [
        '{',
        '{"outbounds": []}',
        jsonEncode([config, config]),
      ]) {
        await expectLater(
          backend.control.updateNodeConfig(node.id, edit),
          throwsA(isA<PlatformException>()),
        );
      }
      expect(jsonDecode(await backend.control.nodeConfig(node.id)), config);
      await backend.control.connect();
      expect(await backend.control.state(), 'connected');
      try {
        final edited = jsonDecode(text) as Map;
        // Disabled mux is the compiled default for this server, so turn it on.
        (edited['outbounds'] as List).single['mux'] = {
          'enabled': true,
          'concurrency': 4,
        };
        final saved = await backend.control.updateNodeConfig(
          node.id,
          jsonEncode(edited),
        );
        final after = saved.subscriptions.single.nodes.single;
        expect(after.id, node.id);
        expect(after.configurationRevision, isNot(node.configurationRevision));
        expect(
          jsonDecode(await backend.control.nodeConfig(node.id)),
          jsonDecode(jsonEncode(edited)),
        );
        // The running connection restarted on the edited config.
        expect(await backend.control.state(), 'connected');
        await checkSocks(
          (await backend.control.tunnelSettings()).socksPort,
          target.port,
        );
      } finally {
        await backend.control.disconnect();
      }
      final hidden = await backend.control.importClientProfiles(
        content:
            '#hide-url: yes\n${profile.replaceFirst('#Fixture', '#Hidden')}',
      );
      final hiddenID = hidden.snapshot.subscriptions.last.nodes.single.id;
      await expectLater(
        backend.control.nodeConfig(hiddenID),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'sharing_disabled',
          ),
        ),
      );
      await expectLater(
        backend.control.updateNodeConfig(hiddenID, text),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'sharing_disabled',
          ),
        ),
      );
    },
  );

  test(
    'VPN session survives stop/reconnect and ends with app disposal',
    () async {
      await prepare();
      final settings = await backend.control.tunnelSettings();
      await backend.control.updateTunnelSettings(
        settings.copyWith(xrayTunEnabled: true),
      );
      final events = File.fromUri(temporary.uri.resolve('vpn-session-events'));
      final owners = File.fromUri(temporary.uri.resolve('vpn-session-owners'));
      final stopGate = File.fromUri(temporary.uri.resolve('vpn-stop-gate'));
      final failStart = File.fromUri(temporary.uri.resolve('vpn-fail-start'));
      await useStub('''
import json, os, socket, subprocess, sys, time
listeners = []
for line in sys.stdin:
    request = json.loads(line)
    method = request['method']
    if method in ('runVPN', 'stopVPN'):
        with open(${jsonEncode(events.path)}, 'a') as events: print(method, file=events)
    if method == 'runVPN':
        with open(${jsonEncode(owners.path)}, 'a') as owners: print(os.getpid(), file=owners)
        if os.path.exists(${jsonEncode(failStart.path)}):
            print(json.dumps({'success': False, 'error': 'connection_failed'}), flush=True)
            continue
        assert request['payload']['reuseSession']
        config = json.loads(request['payload']['configJSON'])
        for inbound in config['inbounds']:
            if inbound['protocol'] in ('socks', 'http'):
                listener = socket.socket()
                listener.bind(('127.0.0.1', inbound['port']))
                listener.listen(32)
                listeners.append(listener)
        print(json.dumps({'success': True, 'data': {}}), flush=True)
    elif method == 'stopVPN':
        for listener in listeners: listener.close()
        listeners.clear()
        while os.path.exists(${jsonEncode(stopGate.path)}): time.sleep(0.01)
        print(json.dumps({'event': 'metrics', 'data': {}}), flush=True)
        print(json.dumps({'success': True, 'data': {}}), flush=True)
    else:
        child = subprocess.Popen([${jsonEncode(corePath)}], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        child.stdin.write(line)
        child.stdin.flush()
        print(child.stdout.readline(), end='', flush=True)
        child.stdin.close()
        child.wait(timeout=10)
        break
''');
      await backend.control.connect();
      final owner = lastProcess!;
      final id = (await backend.control.subscriptions()).selectedNodeId!;
      // Settings hide the test URL for TCP and ICMP, so it may be empty.
      await backend.control.pingNode(
        id,
        protocol: 'tcp',
        method: 'GET',
        mode: 'default',
        timeout: 5,
        url: '',
      );
      expect(await backend.control.state(), 'connected');
      expect(await events.readAsLines(), ['runVPN']);
      final icmp = backend.control.pingNode(
        id,
        protocol: 'icmp',
        method: 'GET',
        mode: 'default',
        timeout: 5,
        url: '',
      );
      if (Platform.isWindows || Platform.isLinux) {
        expect((await icmp).status, 'success');
      } else {
        await expectLater(
          icmp,
          throwsA(
            isA<PlatformException>().having(
              (e) => e.code,
              'code',
              'icmp_failed_restored',
            ),
          ),
        );
      }
      expect(await backend.control.state(), 'connected');
      expect(await events.readAsLines(), ['runVPN', 'stopVPN', 'runVPN']);
      expect((await owners.readAsLines()).toSet(), {owner.pid.toString()});
      await stopGate.writeAsString('hold stop acknowledgement');
      final cancelled = expectLater(
        backend.control.pingNode(
          id,
          protocol: 'icmp',
          method: 'GET',
          mode: 'default',
          timeout: 5,
          url: 'https://example.com/',
        ),
        throwsA(
          isA<PlatformException>().having((e) => e.code, 'code', 'cancelled'),
        ),
      );
      Future<String>? stopping;
      try {
        for (var i = 0; i < 100; i++) {
          if ((await events.readAsLines()).length == 4) break;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect((await events.readAsLines()).length, 4);
        await expectLater(
          backend.control.pingNode(
            id,
            protocol: 'tcp',
            method: 'GET',
            mode: 'default',
            timeout: 5,
            url: 'https://example.com/',
          ),
          throwsA(
            isA<PlatformException>().having((e) => e.code, 'code', 'busy'),
          ),
        );
        stopping = backend.control.disconnect();
      } finally {
        await stopGate.delete();
      }
      await stopping;
      await cancelled;
      expect(await backend.control.state(), 'disconnected');
      await expectClosed(settings.socksPort);
      await backend.control.connect();
      // Preparation still uses one-shot workers; readiness belongs to the saved session.
      expect(await backend.control.state(), 'connected');
      await failStart.writeAsString('refuse restoration');
      await expectLater(
        backend.control.pingNode(
          id,
          protocol: 'icmp',
          method: 'GET',
          mode: 'default',
          timeout: 5,
          url: 'https://example.com/',
        ),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'icmp_restore_failed',
          ),
        ),
      );
      expect(await backend.control.state(), 'failed');
      await expectClosed(settings.socksPort);
      expect((await backend.control.subscriptions()).selectedNodeId, id);
      await failStart.delete();
      await backend.control.disconnect();
      await backend.dispose();
      expect(await owner.exitCode.timeout(const Duration(seconds: 10)), 0);
      expect(await events.readAsLines(), [
        'runVPN',
        'stopVPN',
        'runVPN',
        'stopVPN',
        'runVPN',
        'stopVPN',
        'runVPN',
      ]);
    },
  );

  // The VPN also captures this app's own lookups, so a server reached through
  // the old tunnel, dead or alive, must not resolve its replacement.
  test(
    'switching VPN servers resolves the new server after the old tunnel stops',
    () async {
      await prepare();
      final settings = await backend.control.tunnelSettings();
      await backend.control.updateTunnelSettings(
        settings.copyWith(xrayTunEnabled: true),
      );
      final events = File.fromUri(temporary.uri.resolve('vpn-switch-events'));
      await useStub('''
import json, socket, subprocess, sys
listeners = []
for line in sys.stdin:
    request = json.loads(line)
    method = request['method']
    with open(${jsonEncode(events.path)}, 'a') as events: print(method, file=events)
    if method == 'runVPN':
        config = json.loads(request['payload']['configJSON'])
        for inbound in config['inbounds']:
            if inbound['protocol'] in ('socks', 'http'):
                listener = socket.socket()
                listener.bind(('127.0.0.1', inbound['port']))
                listener.listen(32)
                listeners.append(listener)
        print(json.dumps({'success': True, 'data': {}}), flush=True)
    elif method == 'stopVPN':
        for listener in listeners: listener.close()
        listeners.clear()
        print(json.dumps({'success': True, 'data': {}}), flush=True)
    else:
        child = subprocess.Popen([${jsonEncode(corePath)}], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        child.stdin.write(line)
        child.stdin.flush()
        print(child.stdout.readline(), end='', flush=True)
        child.stdin.close()
        child.wait(timeout=10)
        break
''');
      await backend.control.connect();
      final port = Uri.parse(profile).port;
      final imported = await backend.control.importClientProfiles(
        content: jsonEncode({
          'remarks': 'Mapped',
          'dns': {
            'hosts': {'server.elarni.test': '127.0.0.1'},
          },
          'outbounds': [
            {
              'protocol': 'vless',
              'settings': {
                'vnext': [
                  {
                    'address': 'server.elarni.test',
                    'port': port,
                    'users': [
                      {'id': userID, 'encryption': 'none'},
                    ],
                  },
                ],
              },
            },
          ],
        }),
      );
      await backend.control.selectNode(
        imported.snapshot.subscriptions.single.nodes
            .singleWhere((node) => node.name == 'Mapped')
            .id,
      );
      expect(await backend.control.state(), 'connected');
      final log = await events.readAsLines();
      expect(log.where((method) => method.endsWith('VPN')), [
        'runVPN',
        'stopVPN',
        'runVPN',
      ]);
      expect(
        log.indexOf('profileHostMappings'),
        greaterThan(log.indexOf('stopVPN')),
      );
    },
  );

  // Sleep cancels an ICMP probe's stop or restore without disconnecting; the
  // stopped VPN must not stay in a transitional state that refuses Connect.
  for (final gated in ['stopVPN', 'runVPN']) {
    test(
      'sleep during an ICMP probe\'s $gated leaves the VPN connectable',
      () async {
        await prepare();
        final settings = await backend.control.tunnelSettings();
        await backend.control.updateTunnelSettings(
          settings.copyWith(xrayTunEnabled: true),
        );
        final events = File.fromUri(temporary.uri.resolve('vpn-sleep-events'));
        final gate = File.fromUri(temporary.uri.resolve('vpn-sleep-gate'));
        if (await events.exists()) await events.delete();
        await useStub('''
import json, os, socket, subprocess, sys, time
listeners = []
for line in sys.stdin:
    request = json.loads(line)
    method = request['method']
    if method in ('runVPN', 'stopVPN'):
        with open(${jsonEncode(events.path)}, 'a') as events: print(method, file=events)
        while method == ${jsonEncode(gated)} and os.path.exists(${jsonEncode(gate.path)}): time.sleep(0.01)
    if method == 'runVPN':
        config = json.loads(request['payload']['configJSON'])
        for inbound in config['inbounds']:
            if inbound['protocol'] in ('socks', 'http'):
                listener = socket.socket()
                listener.bind(('127.0.0.1', inbound['port']))
                listener.listen(32)
                listeners.append(listener)
        print(json.dumps({'success': True, 'data': {}}), flush=True)
    elif method == 'stopVPN':
        for listener in listeners: listener.close()
        listeners.clear()
        print(json.dumps({'success': True, 'data': {}}), flush=True)
    else:
        child = subprocess.Popen([${jsonEncode(corePath)}], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        child.stdin.write(line)
        child.stdin.flush()
        print(child.stdout.readline(), end='', flush=True)
        child.stdin.close()
        child.wait(timeout=10)
        break
''');
        await backend.control.connect();
        final id = (await backend.control.subscriptions()).selectedNodeId!;
        await gate.writeAsString('hold $gated');
        final ping = backend.control.pingNode(
          id,
          protocol: 'icmp',
          method: 'GET',
          mode: 'default',
          timeout: 5,
          url: '',
        );
        final reached = gated == 'stopVPN' ? 2 : 3;
        for (var i = 0; i < 500; i++) {
          if ((await events.readAsLines()).length == reached) break;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect((await events.readAsLines()).length, reached);
        await backend.handleSleep(true);
        await gate.delete();
        await expectLater(
          ping,
          throwsA(
            isA<PlatformException>().having((e) => e.code, 'code', 'cancelled'),
          ),
        );
        await backend.handleSleep(false);
        expect(await backend.control.state(), 'failed');
        await backend.control.connect();
        expect(await backend.control.state(), 'connected');
      },
    );
  }

  test(
    'file and QR imports use the native decoder and retain the catalog on cancel',
    () async {
      final file = File.fromUri(
        temporary.uri.resolve('profile with spaces.txt'),
      );
      await file.writeAsString(profile);
      pickedPath = file.path;
      final fromFile = await backend.control.importClientProfiles(
        source: 'file',
      );
      expect(pickedImage, false);
      expect(
        fromFile.snapshot.subscriptions.single.nodes.single.name,
        'Fixture',
      );
      pickedPath = File('test/windows_profile_qr.png').absolute.path;
      final fromQR = await backend.control.importClientProfiles(
        source: 'qrImage',
      );
      expect(pickedImage, true);
      expect(fromQR.snapshot.subscriptions.single.nodes.map((n) => n.name), [
        'Fixture',
        'QR fixture',
      ]);
      final qr = fromQR.snapshot.subscriptions.single.nodes.last;
      expect(qr.name, 'QR fixture');
      // The camera reads the same QR, which the group would skip as known.
      await backend.control.deleteNode(qr.id);
      final fromCamera = await backend.control.importClientProfiles(
        source: 'camera',
      );
      final cameraID = fromCamera.snapshot.subscriptions.single.nodes.last.id;
      expect(cameraID, isNot(qr.id));
      expect(fromCamera.snapshot.subscriptions.single.nodes.length, 2);
      final route = {
        'Name': 'File route',
        'RemoteDNSType': 'DoU',
        'RemoteDNSIP': '1.1.1.1',
        'DomesticDNSType': 'DoU',
        'DomesticDNSIP': '8.8.8.8',
        'DirectSites': ['full:example.com'],
      };
      await file.writeAsString(jsonEncode(route));
      pickedPath = file.path;
      await backend.control.importClientProfiles(source: 'file');
      expect(
        (await backend.control.routingProfiles()).profiles.single.name,
        'File route',
      );
      await backend.control.importClientProfiles(
        content: base64Encode(
          utf8.encode(jsonEncode({...route, 'Name': 'Base64 route'})),
        ),
      );
      expect(
        (await backend.control.routingProfiles()).profiles.map((p) => p.name),
        contains('Base64 route'),
      );
      pickedPath = File('test/windows_routing_qr.png').absolute.path;
      await backend.control.importClientProfiles(source: 'qrImage');
      expect(
        (await backend.control.routingProfiles()).profiles.map((p) => p.name),
        contains('QR route'),
      );
      expect(pickedImage, true);
      await backend.control.importClientProfiles(source: 'camera');
      expect(
        (await backend.control.routingProfiles()).profiles.map((p) => p.name),
        contains('QR route'),
      );
      pickedPath = null;
      await expectLater(
        backend.control.importClientProfiles(source: 'file'),
        throwsA(
          isA<PlatformException>().having((e) => e.code, 'code', 'cancelled'),
        ),
      );
      expect(
        (await backend.control.subscriptions())
            .subscriptions
            .single
            .nodes
            .last
            .id,
        cameraID,
      );
      pickedPath = file.path; // Valid text is not a QR image.
      await expectLater(
        backend.control.importClientProfiles(source: 'qrImage'),
        throwsA(isA<PlatformException>()),
      );
      expect(
        (await backend.control.subscriptions())
            .subscriptions
            .single
            .nodes
            .last
            .id,
        cameraID,
      );
    },
  );

  test(
    'labelled subscription QR images and camera frames import the same URL as pasted links',
    () async {
      final paths = <String>[];
      String? providerTitle;
      final feed = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => feed.close(force: true));
      final url = 'http://127.0.0.1:${feed.port}/sub/token?key=a%2Bb%23c';
      final labelled = '$url#QR%20subscription';
      feed.listen((request) async {
        paths.add(request.uri.toString());
        if (providerTitle != null)
          request.response.headers.set('Profile-Title', providerTitle);
        request.response.write(profile);
        await request.response.close();
      });
      final generator = await Process.start(
        corePath,
        const [],
        environment: coreEnvironment,
      );
      unawaited(generator.stderr.drain<void>());
      final output = generator.stdout.transform(utf8.decoder).join();
      generator.stdin.writeln(
        jsonEncode({
          'apiVersion': 1,
          'method': 'clientQR',
          'payload': {'text': labelled},
        }),
      );
      final generated = catalogMap(
        jsonDecode(await output.timeout(const Duration(seconds: 10))),
      );
      await generator.stdin.close();
      expect(await generator.exitCode, 0);
      expect(generated['success'], true);
      final image = File.fromUri(
        temporary.uri.resolve('labelled-subscription.png'),
      );
      await image.writeAsBytes(
        base64Decode(catalogMap(generated['data'])['png']! as String),
      );
      pickedPath = image.path;

      for (final source in ['qrImage', 'camera', 'text']) {
        providerTitle = source == 'qrImage' ? null : 'Fixture provider';
        var imported = await backend.control.importClientProfiles(
          source: source,
          content: source == 'text' ? labelled : null,
        );
        final id = imported.snapshot.subscriptions.single.id;
        if (imported.warning != null) {
          expect(paths, isEmpty);
          imported = await backend.control.refreshSubscription(
            id,
            challenge: imported.warning!.challenge,
          );
        }
        expect(imported.warning, isNull);
        final group = imported.snapshot.subscriptions.single;
        expect(group.name, providerTitle ?? 'QR subscription');
        expect(group.nodes.single.name, 'Fixture');
        expect(
          catalogList(
            catalogMap(storedCatalog!['committed'])['subscriptions'],
          ).single['url'],
          url,
        );
      }
      expect(paths, List.filled(3, '/sub/token?key=a%2Bb%23c'));
      final id =
          (await backend.control.subscriptions()).subscriptions.single.id;
      expect(
        catalogList(
          catalogMap(storedCatalog!['committed'])['subscriptions'],
        ).single['manualName'],
        isNull,
      );
      await backend.control.renameSubscription(id, 'My VPN');
      await backend.dispose();
      backend = DesktopProxy(
        corePath: corePath,
        startProcess: startCore,
        domainPath: domainPath,
        catalogIO: storage,
        platformIO: (method, payload) async => {},
      );
      providerTitle = 'Updated provider';
      final refreshed = await backend.control.refreshSubscription(id);
      expect(refreshed.snapshot.subscriptions.single.name, 'My VPN');
      expect(
        (await backend.control.renameSubscription(
          id,
          '   ',
        )).subscriptions.single.name,
        'Updated provider',
      );
      providerTitle = null;
      expect(
        (await backend.control.refreshSubscription(
          id,
        )).snapshot.subscriptions.single.name,
        'QR subscription',
      );
    },
  );

  test('local imports join one group and keep each server once', () async {
    final routing =
        'happ://routing/onadd/${base64Encode(utf8.encode(jsonEncode({
          'Name': 'Import route',
          'RemoteDNSType': 'DoU',
          'RemoteDNSIP': '1.1.1.1',
          'DomesticDNSType': 'DoU',
          'DomesticDNSIP': '8.8.8.8',
          'DirectSites': ['full:example.com'],
        })))}';
    final first = (await backend.control.importClientProfiles(
      content: '$profile\n$routing',
    )).snapshot.subscriptions.single;
    // A renamed copy of a server is the same server; another port is not.
    final other = Uri.parse(
      profile,
    ).replace(port: 1, fragment: 'Other').toString();
    final joined = (await backend.control.importClientProfiles(
      content: '$routing\n${profile.replaceFirst('#Fixture', '#Copy')}\n$other',
    )).snapshot.subscriptions.single;
    expect(joined.id, first.id);
    expect(joined.name, 'Local profiles');
    expect(joined.nodes.map((node) => node.name), ['Fixture', 'Other']);
    expect(joined.nodes.first.id, first.nodes.single.id);
    expect(first.nodes.single.protocol, 'VLESS');
    expect(first.nodes.single.transport, 'tcp');
    expect(first.nodes.single.security, 'none');
    final routes = await backend.control.routingProfiles();
    expect(routes.profiles.length, 1);
    expect(routes.assignments.keys, [first.id]);
    await backend.control.renameSubscription(first.id, 'My servers');
    final again = (await backend.control.importClientProfiles(
      content: other,
    )).snapshot.subscriptions.single;
    expect(again.name, 'My servers');
    expect(again.nodes.map((node) => node.id), joined.nodes.map((n) => n.id));
    await backend.control.selectNode(first.nodes.single.id);
    await backend.control.connect();
    await checkSocks(
      (await backend.control.tunnelSettings()).socksPort,
      target.port,
    );
  });

  test(
    'server IP choices survive refresh and relaunch without changing other servers',
    () async {
      final feed = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => feed.close(force: true));
      feed.listen((request) async {
        request.response.write(profile);
        await request.response.close();
      });
      final added = await backend.control.addSubscription(
        'http://127.0.0.1:${feed.port}/fixture',
      );
      await backend.control.refreshSubscription(
        added.snapshot.subscriptions.single.id,
        challenge: added.warning!.challenge,
      );
      final first =
          (await backend.control.subscriptions()).subscriptions.single;
      final a = first.nodes.single.id;
      await backend.control.selectNode(a);
      final imported = await backend.control.importClientProfiles(
        content: profile.replaceFirst('#Fixture', '#Second'),
      );
      final b = imported.snapshot.subscriptions.last.nodes.single.id;
      final settings = await backend.control.tunnelSettings();
      expect(first.nodes.single.ipPreference, isNull);
      await backend.control.setNodeIPPreference(a, 'ipv4');
      await backend.control.setNodeIPPreference(b, 'automatic');
      await backend.control.connect();
      await checkSocks(settings.socksPort, target.port);
      final previousProcess = lastProcess!;
      await backend.control.selectNode(b);
      expect(lastProcess!.pid, isNot(previousProcess.pid));
      await checkSocks(settings.socksPort, target.port);
      rejectNextCommit = true;
      await expectLater(
        backend.control.setNodeIPPreference(b, 'ipv4'),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'storage_unavailable',
          ),
        ),
      );
      expect(
        (await backend.control.subscriptions())
            .subscriptions
            .last
            .nodes
            .single
            .ipPreference,
        'automatic',
      );
      await checkSocks(settings.socksPort, target.port);
      await backend.control.disconnect();
      await backend.control.setNodeIPPreference(b, 'ipv6');
      await expectLater(
        backend.control.setNodeIPPreference(b, 'invalid'),
        throwsA(isA<PlatformException>()),
      );
      final refreshed = await backend.control.refreshSubscription(first.id);
      expect(
        refreshed.snapshot.subscriptions.first.nodes.single.ipPreference,
        'ipv4',
      );
      expect(
        refreshed.snapshot.subscriptions.last.nodes.single.ipPreference,
        'ipv6',
      );
      expect(
        (await backend.control.tunnelSettings()).toMap(),
        settings.toMap(),
      );
      await backend.dispose();
      backend = DesktopProxy(
        corePath: corePath,
        startProcess: startCore,
        domainPath: domainPath,
        catalogIO: storage,
        platformIO: (_, _) async => {},
      );
      final restored = await backend.control.subscriptions();
      expect(restored.selectedNodeId, b);
      expect(restored.subscriptions.map((s) => s.nodes.single.ipPreference), [
        'ipv4',
        'ipv6',
      ]);
      await backend.control.setNodeIPPreference(a, null);
      expect(
        (await backend.control.refreshSubscription(
          first.id,
        )).snapshot.subscriptions.first.nodes.single.ipPreference,
        isNull,
      );
    },
  );

  test('group selection changes live traffic and survives reimport', () async {
    final port = Uri.parse(profile).port;
    final clash =
        '''
proxies:
  - {name: working, type: vless, server: 127.0.0.1, port: $port, uuid: $userID, tls: false}
proxy-groups:
  - {name: PROXY, type: select, proxies: [working, REJECT]}
rules:
  - MATCH,PROXY
''';
    final imported = await backend.control.importClientProfiles(content: clash);
    final node = imported.snapshot.subscriptions.single.nodes.single;
    expect(node.groups.single.selected, 'working');
    await backend.control.selectNode(node.id);
    await backend.control.connect();
    final settings = await backend.control.tunnelSettings();
    await checkSocks(settings.socksPort, target.port);
    final rejected = await backend.control.selectProfileGroup(
      node.id,
      'PROXY',
      'REJECT',
    );
    expect(
      rejected
          .snapshot
          .subscriptions
          .single
          .nodes
          .single
          .groups
          .single
          .selected,
      'REJECT',
    );
    final before = targetRequests;
    await checkHTTPRejected(settings.httpPort, target.port);
    expect(targetRequests, before);
    // The local group already has this profile, so importing it again keeps it.
    final repeated = await backend.control.importClientProfiles(content: clash);
    expect(repeated.snapshot.subscriptions.single.nodes.single.id, node.id);
    expect(
      repeated
          .snapshot
          .subscriptions
          .single
          .nodes
          .single
          .groups
          .single
          .selected,
      'REJECT',
    );
    await backend.control.selectProfileGroup(node.id, 'PROXY', 'working');
    await checkSocks(settings.socksPort, target.port);
    await expectLater(
      backend.control.selectProfileGroup(node.id, 'PROXY', 'missing'),
      throwsA(isA<PlatformException>()),
    );
    await checkSocks(settings.socksPort, target.port);
  });

  if (Platform.isWindows) {
    test(
      'Windows DPAPI catalog persists through relaunch and excludes a second app',
      () async {
        final cache = await temporary.createTemp('encrypted catalog ');
        DesktopProxy persistent() => DesktopProxy(
          corePath: corePath,
          domainPath: domainPath,
          platformIO: (_, _) async => {},
          startProcess: (path) => Process.start(
            path,
            const [],
            environment: {'LOCALAPPDATA': cache.path},
          ),
        );
        final settings = await backend.control.tunnelSettings();
        await backend.dispose();
        backend = persistent();
        expect((await backend.control.tunnelSettings()).xrayTunEnabled, isTrue);
        await backend.control.updateTunnelSettings(settings);
        await prepare();
        final selected = (await backend.control.subscriptions()).selectedNodeId;
        final other = persistent();
        try {
          await expectLater(
            other.control.subscriptions(),
            throwsA(
              isA<PlatformException>().having(
                (e) => e.code,
                'code',
                'storage_busy',
              ),
            ),
          );
        } finally {
          await other.dispose();
        }
        await backend.dispose();
        final ciphertext = await File(
          '${cache.path}/Elarni/catalog.dpapi',
        ).readAsBytes();
        expect(
          utf8.decode(ciphertext, allowMalformed: true),
          isNot(contains(userID)),
        );
        backend = persistent();
        expect(
          (await backend.control.subscriptions()).selectedNodeId,
          selected,
        );
        expect(
          (await backend.control.tunnelSettings()).socksPort,
          settings.socksPort,
        );
        expect(
          (await backend.control.tunnelSettings()).xrayTunEnabled,
          isFalse,
        );
        await backend.control.connect();
        await checkSocks(settings.socksPort, target.port);
      },
    );

    test('Windows catalog saves reuse the storage lease core', () async {
      final cache = await temporary.createTemp('leased catalog ');
      var launches = 0;
      DesktopProxy leased() => DesktopProxy(
        corePath: corePath,
        domainPath: domainPath,
        platformIO: (_, _) async => {},
        startProcess: (path) {
          launches++;
          return Process.start(
            path,
            const [],
            environment: {'LOCALAPPDATA': cache.path},
          );
        },
      );
      final first = leased();
      try {
        final settings = await first.control.tunnelSettings();
        final before = launches;
        // A disconnected settings change saves a checkpoint, then the commit.
        // Each core launch costs about 0.5 s on a slow Windows host.
        await first.control.updateTunnelSettings(
          settings.copyWith(memoryLimitMB: 128),
        );
        expect(launches, before);
        // So does Connect's DNS guard check. No node is selected, so Connect
        // stops at invalid_profile; a lease that refused the check would end.
        await expectLater(
          first.control.connect(),
          throwsA(
            isA<PlatformException>().having(
              (e) => e.code,
              'code',
              'invalid_profile',
            ),
          ),
        );
        await first.control.disconnect();
        expect(launches, before);
        expect((await first.control.tunnelSettings()).memoryLimitMB, 128);
      } finally {
        await first.dispose();
      }
      // A writer outside the lease moves the revision under the next save.
      Future<CatalogMap> outside(String method, CatalogMap payload) async {
        final core = await Process.start(
          corePath,
          const [],
          environment: {'LOCALAPPDATA': cache.path},
        );
        core.stdin.writeln(
          jsonEncode({'apiVersion': 1, 'method': method, 'payload': payload}),
        );
        await core.stdin.flush();
        final reply = await core.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first;
        await core.stdin.close();
        await core.exitCode;
        return catalogMap(catalogMap(jsonDecode(reply))['data']);
      }

      final second = leased();
      try {
        final settings = await second.control.tunnelSettings();
        expect(settings.memoryLimitMB, 128);
        final stored = await outside('loadCatalog', {});
        await outside('saveCatalog', {
          'revision': stored['revision'],
          'catalog': stored['catalog'],
        });
        await expectLater(
          second.control.updateTunnelSettings(
            settings.copyWith(memoryLimitMB: 256),
          ),
          throwsA(
            isA<PlatformException>().having(
              (e) => e.code,
              'code',
              'storage_conflict',
            ),
          ),
        );
        // A rejected save is a reply: the lease, and the storage, stay usable.
        expect((await second.control.tunnelSettings()).memoryLimitMB, 128);
      } finally {
        await second.dispose();
      }
    });
  }

  test(
    'a fresh install refuses local programs without its generated login',
    () async {
      // Other local apps must not use the listeners unasked (v2rayNG #5457).
      expect(initialSettings.inboundAuthEnabled, isTrue);
      expect(initialSettings.inboundCredentialsConfigured, isTrue);
      await prepare();
      final settings = await backend.control.tunnelSettings();
      await backend.control.updateTunnelSettings(
        settings.copyWith(inboundAuthEnabled: true),
      );
      expect(await backend.control.connect(), 'connected');
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        settings.socksPort,
      );
      final input = StreamIterator<int>(socket.expand((chunk) => chunk));
      try {
        socket.add([5, 1, 0]);
        expect(await readBytes(input, 2).timeout(const Duration(seconds: 3)), [
          5,
          255,
        ]);
      } finally {
        socket.destroy();
      }
      // The login the app shows is the one the listener takes.
      final login = await backend.control.inboundCredentials();
      expect(login.keys, unorderedEquals(['username', 'password']));
      final user = utf8.encode(login['username']!);
      final pass = utf8.encode(login['password']!);
      final signedIn = await Socket.connect(
        InternetAddress.loopbackIPv4,
        settings.socksPort,
      );
      final reply = StreamIterator<int>(signedIn.expand((chunk) => chunk));
      try {
        signedIn.add([5, 1, 2]);
        expect(await readBytes(reply, 2).timeout(const Duration(seconds: 3)), [
          5,
          2,
        ]);
        signedIn.add([1, user.length, ...user, pass.length, ...pass]);
        expect(await readBytes(reply, 2).timeout(const Duration(seconds: 3)), [
          1,
          0,
        ]);
      } finally {
        signedIn.destroy();
      }
      await backend.control.disconnect();
    },
  );

  test(
    'real import, atomic rejection, SOCKS and HTTP traffic, stop and reconnect',
    () async {
      await prepare();
      final selected = (await backend.control.subscriptions()).selectedNodeId;
      await expectLater(
        backend.control.importClientProfiles(
          content: '$profile\nprivate-secret-invalid',
        ),
        throwsA(isA<PlatformException>()),
      );
      expect((await backend.control.subscriptions()).selectedNodeId, selected);
      await expectLater(
        backend.control.importClientProfiles(
          content: 'tg://proxy?server=127.0.0.1&port=443&secret=invalid',
        ),
        throwsA(isA<PlatformException>()),
      );
      expect((await backend.control.subscriptions()).selectedNodeId, selected);
      final settings = await backend.control.tunnelSettings();
      await expectLater(
        backend.control.updateTunnelSettings(settings.copyWith(allowLAN: true)),
        throwsA(isA<PlatformException>()),
      );
      expect((await backend.control.routingProfiles()).profiles, isEmpty);
      expect(await backend.control.connect(), 'connected');
      await expectLater(
        backend.control.connect(),
        throwsA(isA<PlatformException>()),
      );
      await backend.control.importClientProfiles(content: profile);
      expect((await backend.control.selectNode(selected!)).state, 'connected');
      final before = targetRequests;
      await checkSocks(
        settings.socksPort,
        target.port,
      ).timeout(const Duration(seconds: 10));
      final client = HttpClient()
        ..findProxy = (_) => 'PROXY 127.0.0.1:${settings.httpPort}';
      try {
        final response = await (await client.getUrl(
          Uri.parse('http://127.0.0.1:${target.port}/fixture'),
        )).close();
        expect(response.statusCode, 200);
        expect(await utf8.decoder.bind(response).join(), body);
      } finally {
        client.close(force: true);
      }
      expect(targetRequests, before + 2);
      expect(await backend.control.disconnect(), 'disconnected');
      await expectClosed(settings.socksPort);
      await expectClosed(settings.httpPort);
      expect(await backend.control.disconnect(), 'disconnected');
      expect(await backend.control.connect(), 'connected');
      await backend.dispose();
      await expectClosed(settings.socksPort);
      await expectClosed(settings.httpPort);
    },
  );

  test(
    'occupied listener fails startup without replacing the selected profile',
    () async {
      await prepare();
      final settings = await backend.control.tunnelSettings();
      final occupied = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        settings.httpPort,
      );
      final selected = (await backend.control.subscriptions()).selectedNodeId;
      final before = launches;
      try {
        await expectLater(
          backend.control.connect(),
          throwsA(
            isA<PlatformException>().having(
              (e) => e.code,
              'code',
              'listener_unavailable',
            ),
          ),
        );
        expect(launches, before, reason: 'the port is checked before launch');
        expect(await backend.control.state(), 'failed');
        expect(
          (await backend.control.subscriptions()).selectedNodeId,
          selected,
        );
        await expectClosed(settings.socksPort);
      } finally {
        await occupied.close();
      }
      expect(await backend.control.connect(), 'connected');
    },
  );

  test(
    'unexpected helper death clears connected state and permits explicit retry',
    () async {
      await prepare();
      final settings = await backend.control.tunnelSettings();
      expect(await backend.control.connect(), 'connected');
      lastProcess!.kill();
      await lastProcess!.exitCode;
      await Future<void>.delayed(Duration.zero);
      expect(await backend.control.state(), 'failed');
      await expectClosed(settings.socksPort);
      expect(await backend.control.connect(), 'connected');
    },
  );

  // On the TUN a dead helper leaves its fail-closed DNS guard, so an edit that
  // restarts nothing must not report the connection as ready again.
  test('a catalog edit after a helper death keeps the failed state', () async {
    await prepare();
    expect(await backend.control.connect(), 'connected');
    lastProcess!.kill();
    await lastProcess!.exitCode;
    await Future<void>.delayed(Duration.zero);
    expect(await backend.control.state(), 'failed');
    final id = (await backend.control.subscriptions()).selectedNodeId!;
    await backend.control.setNodeFavorite(id, true);
    expect(await backend.control.state(), 'failed');
  });

  // Only Block traffic without VPN keeps the guard after a broker exit.
  test('a VPN crash claims a block only when the kill switch is on', () async {
    await prepare();
    final messages = <String>[];
    backend.control.setImportListener((message) {
      if (message != null) messages.add(message);
    });
    final policies = File.fromUri(temporary.uri.resolve('vpn-route-policies'));
    await useStub('''
import json, socket, sys
listeners = []
for line in sys.stdin:
    request = json.loads(line)
    if request['method'] != 'runVPN':
        print(json.dumps({'success': True, 'data': {}}), flush=True)
        continue
    with open(${jsonEncode(policies.path)}, 'a') as policies:
        print(json.dumps(request['payload']['routePolicy']), file=policies)
    for inbound in json.loads(request['payload']['configJSON'])['inbounds']:
        if inbound['protocol'] in ('socks', 'http'):
            listener = socket.socket()
            listener.bind(('127.0.0.1', inbound['port']))
            listener.listen(32)
            listeners.append(listener)
    print(json.dumps({'success': True, 'data': {}}), flush=True)
''');
    final settings = await backend.control.tunnelSettings();
    for (final block in [false, true]) {
      await backend.control.updateTunnelSettings(
        settings.copyWith(xrayTunEnabled: true, blockWithoutVPN: block),
      );
      expect(await backend.control.connect(), 'connected');
      lastProcess!.kill();
      await lastProcess!.exitCode;
      await Future<void>.delayed(Duration.zero);
      expect(await backend.control.state(), 'failed');
    }
    expect(
      (await policies.readAsLines()).map(
        (line) => (jsonDecode(line) as Map)['blockWithoutVPN'],
      ),
      [false, true],
    );
    expect(messages, [
      'Connection stopped unexpectedly. Reconnect to retry; if sites stay '
          'unreachable, use Repair VPN setup.',
      'Connection stopped unexpectedly. Block traffic without VPN keeps '
          'traffic blocked until you reconnect, or use Repair VPN setup to '
          'lift the block.',
    ]);
  });

  test(
    'sleep during connect leaves a state that accepts a new connect',
    () async {
      await prepare();
      final settings = await backend.control.tunnelSettings();
      expect(settings.disconnectOnSleep, false);
      launchGate = Completer<void>();
      launchEntered = Completer<void>();
      final cancelled = expectLater(
        backend.control.connect(),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'cancelled',
          ),
        ),
      );
      await launchEntered!.future.timeout(const Duration(seconds: 5));
      await backend.handleSleep(true);
      launchGate!.complete();
      await cancelled;
      expect(await backend.control.state(), 'failed');
      await expectClosed(settings.socksPort);
      await backend.handleSleep(false);
      expect(await backend.control.connect(), 'connected');
    },
  );

  test(
    'a runtime settings change while connected is not reported as a crash',
    () async {
      await prepare();
      final reports = <String?>[];
      backend.control.setImportListener(reports.add);
      expect(await backend.control.connect(), 'connected');
      final settings = await backend.control.tunnelSettings();
      await backend.control.updateTunnelSettings(
        settings.copyWith(httpInboundEnabled: false),
      );
      expect(reports.whereType<String>(), isEmpty);
      expect(await backend.control.state(), 'connected');
      await checkSocks(settings.socksPort, target.port);
    },
  );

  test(
    'disconnect during process launch cannot revive the connection',
    () async {
      await prepare();
      final settings = await backend.control.tunnelSettings();
      launchGate = Completer<void>();
      final connecting = backend.control.connect();
      final cancelled = expectLater(
        connecting,
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'cancelled',
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final stopping = backend.control.disconnect();
      launchGate!.complete();
      expect(await stopping, 'disconnected');
      await cancelled;
      await lastProcess!.exitCode.timeout(const Duration(seconds: 1));
      await expectClosed(settings.socksPort);
      expect(await backend.control.state(), 'disconnected');
    },
  );

  test('a disconnect link cancels a pending connect link', () async {
    await prepare();
    final settings = await backend.control.tunnelSettings();
    launchGate = Completer<void>();
    launchEntered = Completer<void>();
    final connecting = backend.handleLinks(['elarni://connect']);
    await launchEntered!.future.timeout(const Duration(seconds: 5));
    final stopping = backend.handleLinks(['incy://disconnect']);
    // Let the stop pass its confirmation before the launch resumes.
    await Future<void>.delayed(Duration.zero);
    launchGate!.complete();
    await Future.wait([connecting, stopping]);
    await lastProcess!.exitCode.timeout(const Duration(seconds: 1));
    await expectClosed(settings.socksPort);
    expect(await backend.control.state(), 'disconnected');
  });

  for (final action in ['connect', 'toggle']) {
    test('$action link waits for catalog publication', () async {
      await prepare();
      final stateBefore = await backend.control.state();
      commitGate = Completer<void>();
      final gate = commitGate!;
      commitEntered = Completer<void>();
      final change = backend.control.renameSubscription(
        (await backend.control.subscriptions()).subscriptions.single.id,
        'Renamed before connect',
      );
      await commitEntered!.future;
      final connecting = backend.handleLinks(['elarni://$action']);
      // The state request lets the link reach its wait without releasing commit.
      try {
        expect(await backend.control.state(), stateBefore);
      } finally {
        gate.complete();
      }
      await change;
      await connecting;
      expect(await backend.control.state(), 'connected');
      expect(
        (await backend.control.subscriptions()).subscriptions.single.name,
        'Renamed before connect',
      );
      final settings = await backend.control.tunnelSettings();
      await checkSocks(settings.socksPort, target.port);
    });
  }

  test('Stop supersedes a connect link queued behind a catalog edit', () async {
    await prepare();
    final settings = await backend.control.tunnelSettings();
    commitGate = Completer<void>();
    final gate = commitGate!;
    commitEntered = Completer<void>();
    final change = expectLater(
      backend.control.renameSubscription(
        (await backend.control.subscriptions()).subscriptions.single.id,
        'Cancelled rename',
      ),
      throwsA(
        isA<PlatformException>().having((e) => e.code, 'code', 'cancelled'),
      ),
    );
    await commitEntered!.future;
    final connecting = backend.handleLinks(['elarni://connect']);
    final stopping = backend.handleLinks(['elarni://disconnect']);
    await Future<void>.delayed(Duration.zero);
    gate.complete();
    await Future.wait([change, connecting, stopping]);
    expect(await backend.control.state(), 'disconnected');
    await expectClosed(settings.socksPort);
  });

  test('editing an existing routing profile preserves display order', () async {
    final route = {
      'Name': 'First',
      'RemoteDNSType': 'DoU',
      'RemoteDNSIP': '1.1.1.1',
      'DomesticDNSType': 'DoU',
      'DomesticDNSIP': '8.8.8.8',
    };
    await backend.control.importClientProfiles(content: jsonEncode(route));
    await backend.control.importClientProfiles(
      content: jsonEncode({...route, 'Name': 'Second'}),
    );
    final before = (await backend.control.routingProfiles()).profiles;
    final updated = await backend.control.updateRoutingProfile(
      before.first.id,
      jsonEncode({...route, 'Name': 'Renamed'}),
    );
    expect(updated.profiles.map((p) => p.id), before.map((p) => p.id));
    expect(updated.profiles.map((p) => p.name), ['Renamed', 'Second']);
  });

  // A killed helper leaves its fail-closed DNS guard, so route planning's
  // lookups time out and Connect used to fail as invalid_routing.
  test(
    'connect clears a crashed helper\'s DNS guard before resolving names',
    () async {
      await prepare();
      staleGuard = true;
      final requests = await declineGuardClear();
      await expectLater(
        backend.control.connect(),
        throwsA(
          isA<PlatformException>()
              .having((e) => e.code, 'code', 'vpn_guard_stale')
              .having(
                (e) => ConnectionIssue.from(e).description,
                'issue',
                allOf(
                  startsWith('DNS is blocked by a crashed tunnel.'),
                  contains('Repair VPN setup'),
                ),
              ),
        ),
      );
      // Nothing else started, and recovery must not prompt again on its own.
      expect(await requests.readAsLines(), ['clearVPNGuard']);
      expect(await backend.control.state(), 'failed');
      expect(
        catalogMap(storedCatalog!['committed'])['connectionIntent'],
        false,
      );
      // When the clear succeeds, Connect goes on to start the runtime.
      stub = null;
      final before = launches;
      await backend.control.connect();
      expect(launches, before + 2);
      final settings = await backend.control.tunnelSettings();
      await checkSocks(settings.socksPort, target.port);
      await backend.control.disconnect();
    },
    // Only the Windows and Linux helpers leave a DNS guard behind.
    skip: !Platform.isWindows && !Platform.isLinux,
  );

  test(
    'app start clears a crashed helper\'s DNS guard and still opens',
    () async {
      await backend.dispose();
      staleGuard = true;
      final requests = await declineGuardClear();
      backend = DesktopProxy(
        corePath: corePath,
        domainPath: domainPath,
        catalogIO: storage,
        platformIO: (_, _) async => {},
        startProcess: (_) => Process.start(python, [stub!]),
      );
      // A declined repair leaves the app usable; the next Connect asks again.
      expect(await backend.control.state(), 'disconnected');
      expect(await requests.readAsLines(), contains('clearVPNGuard'));
    },
    skip: !Platform.isWindows && !Platform.isLinux,
  );

  test('readiness response without listeners never reports connected', () async {
    await useImpatientBackend();
    await prepare();
    await useStub(
      'import sys, time\nsys.stdin.readline()\nprint(\'{"success":true,"data":{}}\', flush=True)\ntime.sleep(60)\n',
    );
    await expectLater(
      backend.control.connect(),
      throwsA(isA<PlatformException>()),
    );
    expect(await backend.control.state(), 'failed');
    await lastProcess!.exitCode.timeout(const Duration(seconds: 1));
  });

  test('malformed output is redacted and the helper is reaped', () async {
    await prepare();
    await useStub(
      'import sys, time\nsys.stdin.readline()\nprint("private-secret-invalid-json", flush=True)\ntime.sleep(60)\n',
    );
    try {
      await backend.control.connect();
      fail('Malformed protocol was accepted');
    } on PlatformException catch (error) {
      expect(error.toString(), isNot(contains('private-secret')));
    }
    expect(await backend.control.state(), 'failed');
    await lastProcess!.exitCode.timeout(const Duration(seconds: 1));
  });

  test('startup timeout terminates and reaps the helper', () async {
    await useImpatientBackend();
    await prepare();
    await useStub('import sys, time\nsys.stdin.readline()\ntime.sleep(60)\n');
    await expectLater(
      backend.control.connect(),
      throwsA(isA<PlatformException>()),
    );
    expect(await backend.control.state(), 'failed');
    await lastProcess!.exitCode.timeout(const Duration(seconds: 1));
  });

  test(
    'missing native components fail safely without publishing profiles',
    () async {
      final missing = DesktopProxy(
        corePath: File.fromUri(temporary.uri.resolve('missing-core')).path,
        startProcess: startCore,
        domainPath: domainPath,
        catalogIO: storage,
        platformIO: (_, _) async => {},
      );
      try {
        await expectLater(
          missing.control.importClientProfiles(content: profile),
          throwsA(
            isA<PlatformException>().having(
              (error) => error.code,
              'code',
              'native_unavailable',
            ),
          ),
        );
        expect((await missing.control.subscriptions()).subscriptions, isEmpty);
      } finally {
        await missing.dispose();
      }
      final missingDomain = DesktopProxy(
        corePath: corePath,
        startProcess: startCore,
        domainPath: File.fromUri(temporary.uri.resolve('missing-library')).path,
        catalogIO: storage,
        platformIO: (_, _) async => {},
      );
      try {
        await expectLater(
          missingDomain.control.importClientProfiles(content: profile),
          throwsA(
            isA<PlatformException>().having(
              (error) => error.code,
              'code',
              'native_unavailable',
            ),
          ),
        );
        expect(
          (await missingDomain.control.subscriptions()).subscriptions,
          isEmpty,
        );
      } finally {
        await missingDomain.dispose();
      }
    },
  );

  test(
    'catalog relaunch, pending recovery and failed connected publication',
    () async {
      await prepare();
      final selected = (await backend.control.subscriptions()).selectedNodeId;
      final settings = await backend.control.tunnelSettings();
      await backend.dispose();
      storedCatalog!['pending'] = DesktopCatalog.empty();
      backend = DesktopProxy(
        corePath: corePath,
        startProcess: startCore,
        domainPath: domainPath,
        catalogIO: storage,
        platformIO: (_, _) async => {},
      );
      expect((await backend.control.subscriptions()).selectedNodeId, selected);
      expect(storedCatalog!.containsKey('pending'), isFalse);
      expect(await backend.control.connect(), 'connected');
      final before = jsonEncode(storedCatalog);
      rejectNextCommit = true;
      final changedPort = await freePort();
      await expectLater(
        backend.control.updateTunnelSettings(
          settings.copyWith(socksPort: changedPort),
        ),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'storage_unavailable',
          ),
        ),
      );
      expect(jsonEncode(storedCatalog), before);
      expect(await backend.control.state(), 'connected');
      await checkSocks(settings.socksPort, target.port);
      await expectClosed(changedPort);
    },
  );

  for (final pendingConnect in [false, true]) {
    test(
      'Stop clears saved intent during cold start (connect: $pendingConnect)',
      () async {
        await prepare();
        final settings = await backend.control.tunnelSettings();
        await backend.dispose();
        storedCatalog!['committed'] = {
          ...catalogMap(storedCatalog!['committed']),
          'connectionIntent': true,
        };
        final loading = Completer<void>(), release = Completer<void>();
        backend = DesktopProxy(
          corePath: corePath,
          startProcess: startCore,
          domainPath: domainPath,
          unattended: true,
          catalogIO: (method, payload) async {
            if (method == 'loadCatalog') {
              if (!loading.isCompleted) loading.complete();
              await release.future;
            }
            return storage(method, payload);
          },
          platformIO: (_, _) async => {},
        );
        Future<void>? connected;
        if (pendingConnect) {
          connected = expectLater(
            backend.control.connect(),
            throwsA(
              isA<PlatformException>().having(
                (e) => e.code,
                'code',
                'cancelled',
              ),
            ),
          );
          await loading.future;
        }
        final stopping = backend.control.disconnect();
        release.complete();
        await connected;
        expect(await stopping, 'disconnected');
        expect(await backend.control.state(), 'disconnected');
        expect((await backend.control.automationStatus())['status'], 'stopped');
        expect(
          catalogMap(storedCatalog!['committed'])['connectionIntent'],
          false,
        );
        await expectClosed(settings.socksPort);
      },
    );
  }

  test('daemon restart resumes saved intent without failover', () async {
    await prepare();
    final settings = await backend.control.tunnelSettings();
    await backend.dispose();
    storedCatalog!['committed'] = {
      ...catalogMap(storedCatalog!['committed']),
      'connectionIntent': true,
    };
    backend = DesktopProxy(
      corePath: corePath,
      startProcess: startCore,
      domainPath: domainPath,
      unattended: true,
      catalogIO: storage,
      platformIO: (_, _) async => {},
    );
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (await backend.control.state() != 'connected') {
      expect(DateTime.now().isBefore(deadline), true);
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    await checkSocks(settings.socksPort, target.port);
    expect(await backend.control.disconnect(), 'disconnected');
  });

  test('a daemon whose saved server was deleted stops retrying', () async {
    await prepare();
    final id = (await backend.control.subscriptions()).subscriptions.single.id;
    await backend.control.deleteSubscription(id);
    await backend.dispose();
    storedCatalog!['committed'] = {
      ...catalogMap(storedCatalog!['committed']),
      'connectionIntent': true,
    };
    backend = DesktopProxy(
      corePath: corePath,
      startProcess: startCore,
      domainPath: domainPath,
      unattended: true,
      catalogIO: storage,
      platformIO: (_, _) async => {},
    );
    expect(await backend.control.state(), 'disconnected');
    final revision = storageRevision;
    // The first retries come after one and two seconds.
    await Future<void>.delayed(const Duration(milliseconds: 3500));
    expect(storageRevision, revision);
    expect(
      (await backend.control.automationStatus())['status'],
      'intentRequired',
    );
  });

  test('Concurrent Stops share durable completion', () async {
    await prepare();
    await backend.control.connect();
    commitGate = Completer<void>();
    final gate = commitGate!;
    commitEntered = Completer<void>();
    final stopping = backend.control.disconnect();
    final first = expectLater(stopping, completion('disconnected'));
    await commitEntered!.future;
    final second = expectLater(
      backend.control.disconnect(),
      completion('disconnected'),
    );
    gate.complete();
    await Future.wait([first, second]);
    expect(catalogMap(storedCatalog!['committed'])['connectionIntent'], false);
    expect(await backend.control.state(), 'disconnected');
  });

  test(
    'cancellation crossing committed storage compensates before returning',
    () async {
      await prepare();
      final before = jsonEncode(storedCatalog);
      commitGate = Completer<void>();
      final gate = commitGate!;
      commitEntered = Completer<void>();
      final change = backend.control.renameSubscription(
        (await backend.control.subscriptions()).subscriptions.single.id,
        'Changed',
      );
      final assertion = expectLater(
        change,
        throwsA(
          isA<PlatformException>().having((e) => e.code, 'code', 'cancelled'),
        ),
      );
      await commitEntered!.future;
      final stopped = backend.control.disconnect();
      gate.complete();
      await assertion;
      expect(await stopped, 'disconnected');
      expect(jsonEncode(storedCatalog), before);
    },
  );

  test(
    'Telegram handoff preserves tunnel profiles and never selects a Telegram proxy',
    () async {
      const telegram =
          'tg://proxy?server=127.0.0.1&port=443&secret=0123456789abcdef0123456789abcdef';
      await prepare();
      final selected = (await backend.control.subscriptions()).selectedNodeId;
      final imported = await backend.control.importClientProfiles(
        content: '$profile\n$telegram',
      );
      // The local group already has the profile and gains the Telegram proxy.
      final nodes = imported.snapshot.subscriptions.single.nodes;
      expect(nodes.length, 2);
      expect(imported.snapshot.selectedNodeId, selected);
      final handoff = nodes.singleWhere((node) => node.format == 'telegram');
      await backend.control.openTelegramProxy(handoff.id);
      expect(openedURL, startsWith('tg://proxy?'));
      await expectLater(
        backend.control.selectNode(handoff.id),
        throwsA(isA<PlatformException>()),
      );
      expect((await backend.control.subscriptions()).selectedNodeId, selected);
    },
  );

  test(
    'inbound credentials protect SOCKS and HTTP, support LAN and survive relaunch',
    () async {
      await prepare();
      final saved = await backend.control.updateInboundCredentials(
        'fixture-user',
        'fixture-password',
      );
      expect(saved.inboundCredentialsConfigured, true);
      expect(saved.inboundAuthEnabled, true);
      final settings = await backend.control.updateTunnelSettings(
        saved.copyWith(allowLAN: true),
      );
      await backend.control.connect();
      final denied = HttpClient()
        ..findProxy = (_) => 'PROXY 127.0.0.1:${settings.httpPort}';
      try {
        final response = await (await denied.getUrl(
          Uri.parse('http://127.0.0.1:${target.port}/fixture'),
        )).close();
        expect(response.statusCode, 407);
        await response.drain<void>();
      } finally {
        denied.close(force: true);
      }
      await checkSocks(
        settings.socksPort,
        target.port,
        username: 'fixture-user',
        password: 'fixture-password',
      );
      final allowed = HttpClient()
        ..findProxy = (_) => 'PROXY 127.0.0.1:${settings.httpPort}';
      allowed.authenticateProxy = (host, port, scheme, realm) async {
        allowed.addProxyCredentials(
          host,
          port,
          realm ?? '',
          HttpClientBasicCredentials('fixture-user', 'fixture-password'),
        );
        return true;
      };
      try {
        final response = await (await allowed.getUrl(
          Uri.parse('http://127.0.0.1:${target.port}/fixture'),
        )).close();
        expect(response.statusCode, 200);
        expect(await utf8.decoder.bind(response).join(), body);
      } finally {
        allowed.close(force: true);
      }
      expect(
        jsonEncode((await backend.control.tunnelSettings()).toMap()),
        isNot(contains('fixture-password')),
      );
      await backend.dispose();
      backend = DesktopProxy(
        corePath: corePath,
        startProcess: startCore,
        domainPath: domainPath,
        catalogIO: storage,
        platformIO: (_, _) async => {},
      );
      expect(
        (await backend.control.tunnelSettings()).inboundCredentialsConfigured,
        true,
      );
      await backend.control.connect();
      await checkSocks(
        settings.socksPort,
        target.port,
        username: 'fixture-user',
        password: 'fixture-password',
      );
      await expectLater(
        backend.control.updateInboundCredentials('bad:user', 'secret'),
        throwsA(isA<PlatformException>()),
      );
      await checkSocks(
        settings.socksPort,
        target.port,
        username: 'fixture-user',
        password: 'fixture-password',
      );
    },
  );

  test('check exit names where a server reaches the internet', () async {
    await prepare();
    final id = (await backend.control.subscriptions()).selectedNodeId!;
    Future<PingResult> trace(String protocol) => backend.control.pingNode(
      id,
      protocol: protocol,
      method: 'GET',
      mode: 'default',
      timeout: 5,
      url: 'http://127.0.0.1:${target.port}/cdn-cgi/trace',
      expectedStatus: 200,
      trace: true,
    );
    final probe = await trace('proxy');
    expect((probe.exitIP, probe.exitCountry), ('203.0.113.7', 'DE'));
    // A plain test names no exit.
    final plain = await backend.control.pingNode(
      id,
      protocol: 'proxy',
      method: 'GET',
      mode: 'default',
      timeout: 5,
      url: 'http://127.0.0.1:${target.port}/fixture',
      expectedStatus: 200,
      expectedBody: body,
    );
    expect(plain.exitCountry, isNull);
    await backend.control.updateInboundCredentials(
      'fixture-user',
      'fixture-password',
    );
    await backend.control.connect();
    final active = await trace('activeProxy');
    expect((active.exitIP, active.exitCountry), ('203.0.113.7', 'DE'));
    // Only an HTTP test reaches the trace.
    expect(() => trace('tcp'), throwsFormatException);
    expect(await backend.control.state(), 'connected');
  });

  test(
    'ping verifies isolated and active traffic without changing selection',
    () async {
      await prepare();
      final id = (await backend.control.subscriptions()).selectedNodeId!;
      final settings = await backend.control.tunnelSettings();
      final url = 'http://127.0.0.1:${target.port}/fixture';
      for (final protocol in ['proxy', 'tcp', if (Platform.isWindows) 'icmp']) {
        final result = await backend.control.pingNode(
          id,
          protocol: protocol,
          method: 'GET',
          mode: 'default',
          timeout: 5,
          url: url,
          expectedStatus: 200,
          expectedBody: body,
        );
        expect(result.status, 'success');
        expect(result.latencyMs, greaterThanOrEqualTo(0));
      }
      expect(await backend.control.state(), 'prepared');
      await expectClosed(settings.socksPort);
      await backend.control.updateInboundCredentials(
        'fixture-user',
        'fixture-password',
      );
      await backend.control.connect();
      final result = await backend.control.pingNode(
        id,
        protocol: 'activeProxy',
        method: 'GET',
        mode: 'double',
        timeout: 5,
        url: url,
        expectedStatus: 200,
        expectedBody: body,
      );
      expect(result.status, 'success');
      await expectLater(
        backend.control.pingNode(
          id,
          protocol: 'activeProxy',
          method: 'GET',
          mode: 'default',
          timeout: 5,
          url: url,
          expectedStatus: 200,
          expectedBody: 'incorrect-body',
        ),
        throwsA(isA<PlatformException>()),
      );
      expect(await backend.control.state(), 'connected');
      expect((await backend.control.subscriptions()).selectedNodeId, id);
      CatalogMap metrics = {};
      for (var i = 0; i < 30; i++) {
        metrics = await backend.control.runtimeMetrics();
        if (metrics['metricsAvailable'] == true &&
            (catalogMap(metrics['counters'])['uplinkBytes'] as num? ?? 0) > 0)
          break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(metrics['metricsAvailable'], true);
      expect(catalogMap(metrics['counters'])['uplinkBytes'], greaterThan(0));
      expect(catalogMap(metrics['counters'])['downlinkBytes'], greaterThan(0));
      await backend.control.disconnect();
      expect(
        (await backend.control.runtimeMetrics())['metricsAvailable'],
        false,
      );
      await expectClosed(settings.socksPort);
    },
  );

  test(
    'Direct TCP skips UDP transports even with a TCP listener on their port',
    () async {
      final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      var connections = 0;
      listener.listen((socket) {
        connections++;
        socket.destroy();
      });
      addTearDown(listener.close);
      for (final content in [
        'hysteria2://fixture-secret@127.0.0.1:${listener.port}?sni=example.com#UDP',
        jsonEncode({
          'outbounds': [
            {
              'protocol': 'vless',
              'settings': {
                'address': '127.0.0.1',
                'port': listener.port,
                'id': userID,
                'encryption': 'none',
              },
              'streamSettings': {'network': 'kcp'},
            },
          ],
        }),
      ]) {
        final imported = await backend.control.importClientProfiles(
          content: content,
        );
        // Each import joins the local group as its last server.
        final id = imported.snapshot.subscriptions.single.nodes.last.id;
        await expectLater(
          backend.control.pingNode(
            id,
            protocol: 'tcp',
            method: 'GET',
            mode: 'default',
            timeout: 5,
            url: 'http://127.0.0.1:${target.port}/fixture',
          ),
          throwsA(
            isA<PlatformException>().having(
              (error) => error.code,
              'code',
              'unsupported_ping_method',
            ),
          ),
        );
      }
      expect(connections, 0);
    },
  );

  test('26 parallel HTTP probes complete in one round', () async {
    await prepare();
    final id = (await backend.control.subscriptions()).selectedNodeId!;
    final responder = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => responder.close(force: true));
    final requests = <HttpRequest>[];
    responder.listen((request) async {
      requests.add(request);
      // All helpers must reach the responder before any can finish.
      if (requests.length == 26) {
        for (final request in requests) {
          request.response.statusCode = 204;
          await request.response.close();
        }
      }
    });
    final watch = Stopwatch()..start();
    final results = await Future.wait([
      for (var i = 0; i < 26; i++)
        backend.control.pingNode(
          id,
          protocol: 'proxy',
          method: 'GET',
          mode: 'default',
          timeout: 7,
          url: 'http://127.0.0.1:${responder.port}/fixture',
        ),
    ]);
    expect(requests, hasLength(26));
    expect(results.every((result) => result.status == 'success'), isTrue);
    print('26 parallel HTTP probes: ${watch.elapsedMilliseconds} ms');
    watch.reset();
    final tcp = await Future.wait([
      for (var i = 0; i < 26; i++)
        backend.control.pingNode(
          id,
          protocol: 'tcp',
          method: 'GET',
          mode: 'default',
          timeout: 7,
          url: 'http://127.0.0.1:${responder.port}/fixture',
        ),
    ]);
    expect(tcp.every((result) => result.status == 'success'), isTrue);
    print('26 parallel TCP probes: ${watch.elapsedMilliseconds} ms');
  });

  test('Stop supersedes Connect while manual probes are cleaning up', () async {
    await prepare();
    final id = (await backend.control.subscriptions()).selectedNodeId!;
    final settings = await backend.control.tunnelSettings();
    launchEntered = Completer<void>();
    launchGate = Completer<void>();
    final cancelled = throwsA(
      isA<PlatformException>().having((e) => e.code, 'code', 'cancelled'),
    );
    final probe = expectLater(
      backend.control.pingNode(
        id,
        protocol: 'proxy',
        method: 'GET',
        mode: 'default',
        timeout: 7,
        url: 'http://127.0.0.1:${target.port}/fixture',
      ),
      cancelled,
    );
    await launchEntered!.future.timeout(const Duration(seconds: 3));
    final connecting = expectLater(backend.control.connect(), cancelled);
    await backend.control.state();
    final stopping = backend.control.disconnect();
    launchGate!.complete();
    expect(await stopping.timeout(const Duration(seconds: 3)), 'disconnected');
    await Future.wait([probe, connecting]);
    await lastProcess!.exitCode.timeout(const Duration(seconds: 1));
    await expectClosed(settings.socksPort);
    expect(await backend.control.state(), 'disconnected');
    expect(
      catalogMap(storedCatalog?['committed'])['connectionIntent'],
      isNot(true),
    );
  });

  test(
    'manual probes publish independently and yield ownership to edits and connect after cleanup',
    () async {
      await prepare();
      final id = (await backend.control.subscriptions()).selectedNodeId!;
      final responder = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final arrived = Completer<void>();
      final reconnectProbe = Completer<void>();
      final requests = <HttpRequest>[];
      responder.listen((request) {
        requests.add(request);
        if (requests.length == 26) arrived.complete();
        if (requests.length == 27) reconnectProbe.complete();
      });
      addTearDown(() => responder.close(force: true));
      final probes = [
        for (var i = 0; i < 26; i++)
          backend.control.pingNode(
            id,
            protocol: 'proxy',
            method: 'GET',
            mode: 'default',
            timeout: 7,
            url: 'http://127.0.0.1:${responder.port}/fixture',
            expectedStatus: 204,
          ),
      ];
      final results = Future.wait(
        probes.map((probe) async {
          try {
            return (await probe).status;
          } on PlatformException catch (error) {
            return error.code;
          }
        }),
      );
      await arrived.future.timeout(const Duration(seconds: 5));
      requests.first.response.statusCode = 204;
      await requests.first.response.close();
      await Future.any(probes);
      final settings = await backend.control.tunnelSettings();
      await backend.control
          .updateTunnelSettings(settings)
          .timeout(const Duration(seconds: 3));
      final outcomes = await results;
      expect(outcomes.where((value) => value == 'success'), hasLength(1));
      expect(outcomes.where((value) => value == 'cancelled'), hasLength(25));
      expect(await backend.control.state(), 'prepared');
      expect((await backend.control.subscriptions()).selectedNodeId, id);
      final interrupted = expectLater(
        backend.control.pingNode(
          id,
          protocol: 'proxy',
          method: 'GET',
          mode: 'default',
          timeout: 7,
          url: 'http://127.0.0.1:${responder.port}/fixture',
        ),
        throwsA(
          isA<PlatformException>().having((e) => e.code, 'code', 'cancelled'),
        ),
      );
      await reconnectProbe.future.timeout(const Duration(seconds: 5));
      await backend.control.connect().timeout(const Duration(seconds: 3));
      await interrupted;
      expect(await backend.control.state(), 'connected');
    },
  );

  test(
    'a hostname profile without DNS hosts starts only its runtime',
    () async {
      final imported = await backend.control.importClientProfiles(
        content: profile.replaceFirst('127.0.0.1:', 'localhost:'),
      );
      final node = imported.snapshot.subscriptions.single.nodes.single.id;
      await backend.control.selectNode(node);
      await backend.control.setNodeIPPreference(node, 'ipv4');
      final before = launches;
      await backend.control.connect();
      // Each core launch costs about a second on a slow Windows host.
      expect(launches, before + 1);
      final settings = await backend.control.tunnelSettings();
      await checkSocks(settings.socksPort, target.port);
      await backend.control.disconnect();
    },
  );

  test(
    'server mappings pin physical endpoints and incoming links retain profiles',
    () async {
      await prepare();
      final first = (await backend.control.subscriptions()).selectedNodeId;
      final pinned = jsonEncode({
        'outbounds': [
          {
            'tag': 'proxy',
            'protocol': 'vless',
            'settings': {
              'vnext': [
                {
                  'address': 'fixture.elarni.invalid',
                  'port': Uri.parse(profile).port,
                  'users': [
                    {'id': userID, 'encryption': 'none'},
                  ],
                },
              ],
            },
          },
        ],
        'dns': {
          'hosts': {'domain:elarni.invalid': '127.0.0.1'},
        },
      });
      final imported = await backend.control.importClientProfiles(
        content: pinned,
      );
      final selected = await backend.control.selectNode(
        imported.snapshot.subscriptions.single.nodes
            .firstWhere((node) => node.id != first)
            .id,
      );
      expect(selected.state, 'prepared');
      final snapshot = await backend.control.subscriptions();
      // The pinned profile joins the local group; a link adds another server.
      expect(snapshot.subscriptions.single.nodes.length, 2);
      final linked = Uri.parse(
        profile,
      ).replace(port: 1, fragment: 'Linked').toString();
      expect(snapshot.selectedNodeId, isNot(first));
      final settings = await backend.control.tunnelSettings();
      await backend.control.updateTunnelSettings(
        settings.copyWith(resolveServer: true),
      );
      await backend.control.connect();
      await checkSocks(settings.socksPort, target.port);
      await backend.control.disconnect();
      linkAnswer = false;
      await backend.handleLinks([linked]);
      expect(
        (await backend.control.subscriptions())
            .subscriptions
            .single
            .nodes
            .length,
        2,
      );
      linkAnswer = true;
      await backend.handleLinks([linked]);
      expect(
        (await backend.control.subscriptions())
            .subscriptions
            .single
            .nodes
            .length,
        3,
      );
      expect(
        (await backend.control.subscriptions()).selectedNodeId,
        snapshot.selectedNodeId,
      );
      expect(await backend.control.state(), 'prepared');
      await expectClosed(settings.socksPort);
      await backend.handleLinks(['elarni://status']);
      expect(await backend.control.state(), 'prepared');
      await backend.handleLinks(['incy://connect']);
      await checkSocks(settings.socksPort, target.port);
      await backend.handleLinks(['elarni://connect']);
      expect(await backend.control.state(), 'connected');
      linkAnswer = false;
      await backend.handleLinks(['happ://toggle']);
      expect(await backend.control.state(), 'connected');
      await checkSocks(settings.socksPort, target.port);
      linkAnswer = true;
      await backend.handleLinks(['happ://toggle']);
      await expectClosed(settings.socksPort);
      await backend.handleLinks(['elarni://toggle']);
      await checkSocks(settings.socksPort, target.port);
      await backend.handleLinks(['incy://close']);
      await expectClosed(settings.socksPort);
      expect(
        (await backend.control.subscriptions())
            .subscriptions
            .single
            .nodes
            .length,
        3,
      );
      // Connect links run directly; imports and stops ask first.
      expect(linkPrompts, [
        'importClient',
        'importClient',
        'disconnect',
        'disconnect',
        'disconnect',
      ]);
    },
  );

  test('routing links that turn a profile on ask for a server first', () async {
    final messages = <String?>[];
    backend.control.setImportListener(messages.add);
    final route = {
      'Name': 'Link route',
      'RemoteDNSType': 'DoU',
      'RemoteDNSIP': '192.0.2.53',
      'DomesticDNSType': 'DoU',
      'DomesticDNSIP': '192.0.2.53',
      'GlobalProxy': 'true',
    };
    await backend.handleLinks([
      'happ://routing/onadd/${base64Encode(utf8.encode(jsonEncode(route)))}',
    ]);
    expect(messages, [desktopError('no_selected_subscription').message]);
    expect(messages.single, contains('Select a server'));
    expect((await backend.control.routingProfiles()).profiles, isEmpty);
  });

  test('routing links in one batch all import', () async {
    await prepare();
    final messages = <String?>[];
    backend.control.setImportListener(messages.add);
    String link(String name, String dns) =>
        'happ://routing/onadd/${base64Encode(utf8.encode(jsonEncode({'Name': name, 'RemoteDNSType': 'DoU', 'RemoteDNSIP': dns, 'DomesticDNSType': 'DoU', 'DomesticDNSIP': dns})))}';
    await backend.handleLinks([
      link('First link route', '192.0.2.53'),
      link('Second link route', '198.51.100.53'),
    ]);
    expect(messages.last, isNull);
    expect(
      (await backend.control.routingProfiles()).profiles.map((p) => p.name),
      ['First link route', 'Second link route'],
    );
  });

  test(
    'TUIC incoming links persist, compile and share through native backends',
    () async {
      const link =
          'tuic://00000000-0000-4000-8000-000000000001:p%40ss%3A%E2%9C%93@[::1]:443?sni=fixture.example#TUIC%20%E2%9C%93';
      await backend.handleLinks([link]);
      final node = (await backend.control.subscriptions())
          .subscriptions
          .single
          .nodes
          .single;
      expect(node.protocol, 'TUIC');
      expect(node.transport, 'QUIC');
      expect(node.security, 'TLS');
      await backend.control.selectNode(node.id);
      expect(await backend.control.state(), 'prepared');
      final shared = await backend.control.shareClient(node.id);
      final config =
          jsonDecode(shared['text']! as String) as Map<String, dynamic>;
      final outbound =
          (config['outbounds'] as List).single as Map<String, dynamic>;
      expect(outbound['settings']['password'], 'p@ss:✓');
      expect(
        outbound['streamSettings']['tlsSettings']['serverName'],
        'fixture.example',
      );
      pickedPath = '${temporary.path}/tuic-qr.png';
      await File(
        pickedPath!,
      ).writeAsBytes(base64Decode(shared['png']! as String));
      final qr = await backend.control.importClientProfiles(source: 'qrImage');
      expect(qr.snapshot.subscriptions.last.nodes.single.protocol, 'TUIC');
      await backend.dispose();
      backend = DesktopProxy(
        corePath: corePath,
        startProcess: startCore,
        domainPath: domainPath,
        catalogIO: storage,
        platformIO: (method, payload) async => {},
      );
      final reopened = await backend.control.subscriptions();
      expect(reopened.selectedNodeId, node.id);
      expect(
        reopened.subscriptions.first.nodes.single.configurationRevision,
        node.configurationRevision,
      );
    },
  );

  test(
    'automatic recovery, sleep and manual stop preserve connection intent',
    () async {
      await prepare();
      final id = (await backend.control.subscriptions()).selectedNodeId!;
      final settings = await backend.control.tunnelSettings();
      await backend.control.updateTunnelSettings(
        settings.copyWith(onDemandEnabled: true, disconnectOnSleep: true),
      );
      final configuration = AutomationConfiguration(
        enabled: true,
        policy: AutomationSelectionPolicy.orderedFallback,
        subscriptionId:
            (await backend.control.subscriptions()).subscriptions.single.id,
        nodeIds: [id],
        targets: [
          AutomationTarget(
            id: 'fixture',
            url: 'http://127.0.0.1:${target.port}/fixture',
            expectedStatus: 200,
            expectedBody: body,
          ),
        ],
      );
      await backend.control.configureAutomation(configuration);
      await backend.control.connect();
      final running = lastProcess!;
      running.kill();
      await running.exitCode;
      Future<void> recovered() async {
        for (var i = 0; i < 80; i++) {
          if (await backend.control.state() == 'connected') break;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(await backend.control.state(), 'connected');
        await checkSocks(settings.socksPort, target.port);
      }

      await recovered();
      expect(lastProcess!.pid, isNot(running.pid));
      await backend.handleSleep(true);
      expect(await backend.control.state(), 'disconnected');
      await Future<void>.delayed(const Duration(seconds: 2));
      await expectClosed(settings.socksPort);
      expect((await backend.control.automationStatus())['sleeping'], true);
      await backend.handleSleep(false);
      await recovered();
      await backend.control.disconnect();
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(await backend.control.state(), 'disconnected');
      await expectClosed(settings.socksPort);
      expect(
        catalogMap(storedCatalog!['committed'])['connectionIntent'],
        false,
      );
    },
  );

  test('a connection to a dead server says it passes no traffic', () async {
    // Connected means only that the local core answers.
    await backend.dispose();
    backend = createBackend(
      automationProbeSeconds: 2,
      livenessInterval: const Duration(seconds: 2),
      livenessTargets: [
        {
          'id': 'fixture',
          'url': 'http://127.0.0.1:${target.port}/fixture',
          'expectedStatus': 200,
          'expectedBody': body,
        },
      ],
    );
    final relay = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final peers = <Socket>{};
    var reachable = false;
    relay.listen((client) async {
      peers.add(client);
      if (!reachable) return;
      final server = await Socket.connect('127.0.0.1', Uri.parse(profile).port);
      peers.add(server);
      unawaited(
        client.cast<List<int>>().pipe(server).catchError((Object _) => server),
      );
      unawaited(
        server.cast<List<int>>().pipe(client).catchError((Object _) => client),
      );
    });
    Future<Object?> liveness(Object? expected) async {
      for (var i = 0; i < 60; i++) {
        final value = (await backend.control.runtimeMetrics())['liveness'];
        if (value == expected) return value;
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      return (await backend.control.runtimeMetrics())['liveness'];
    }

    try {
      final imported = await backend.control.importClientProfiles(
        content: Uri.parse(profile).replace(port: relay.port).toString(),
      );
      await backend.control.selectNode(
        imported.snapshot.subscriptions.single.nodes.single.id,
      );
      expect(await backend.control.connect(), 'connected');
      expect(await liveness('noTraffic'), 'noTraffic');
      expect(await backend.control.state(), 'connected');
      // A failed check is repeated each interval and clears once traffic passes.
      reachable = true;
      expect(await liveness('ok'), 'ok');
      // The server dies while traffic still leaves. SOCKS replies (and direct
      // routes) keep the downlink moving, so they cannot keep it 'ok'.
      reachable = false;
      for (final peer in peers) peer.destroy();
      final client = await Socket.connect(
        InternetAddress.loopbackIPv4,
        (await backend.control.tunnelSettings()).socksPort,
      );
      peers.add(client);
      client.add([
        5,
        1,
        0,
        5,
        1,
        0,
        1,
        127,
        0,
        0,
        1,
        target.port >> 8,
        target.port & 255,
        ...List.filled(4096, 0x16),
      ]);
      expect(await liveness('noTraffic'), 'noTraffic');
      await backend.control.disconnect();
      expect((await backend.control.runtimeMetrics())['liveness'], isNull);
    } finally {
      for (final peer in peers) peer.destroy();
      await relay.close();
    }
  });

  // TSPU freezes an SNI after more than 3 near-simultaneous handshakes; count
  // what one Connect opens to its server (all candidates share one here).
  for (final lowestLatency in [false, true])
    test('a connect handshakes with its server a bounded number of times '
        '(lowest latency: $lowestLatency)', () async {
      await backend.dispose();
      backend = createBackend(
        automationProbeSeconds: 2,
        livenessInterval: const Duration(minutes: 5),
        livenessTargets: [
          {
            'id': 'fixture',
            'url': 'http://127.0.0.1:${target.port}/fixture',
            'expectedStatus': 200,
            'expectedBody': body,
          },
        ],
      );
      final clock = Stopwatch()..start();
      final handshakes = <int>[];
      final peers = <Socket>{};
      final relays = [
        for (var i = 0; i < 3; i++)
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
      ];
      for (final relay in relays) {
        relay.listen((client) async {
          handshakes.add(clock.elapsedMilliseconds);
          peers.add(client);
          final server = await Socket.connect(
            '127.0.0.1',
            Uri.parse(profile).port,
          );
          peers.add(server);
          unawaited(
            client
                .cast<List<int>>()
                .pipe(server)
                .catchError((Object _) => server),
          );
          unawaited(
            server
                .cast<List<int>>()
                .pipe(client)
                .catchError((Object _) => client),
          );
        });
      }
      try {
        final imported = await backend.control.importClientProfiles(
          content: [
            for (final (i, relay) in relays.indexed)
              Uri.parse(
                profile,
              ).replace(port: relay.port, fragment: 'Server $i').toString(),
          ].join('\n'),
        );
        final group = imported.snapshot.subscriptions.single;
        await backend.control.selectNode(group.nodes.first.id);
        if (lowestLatency)
          await backend.control.configureAutomation(
            AutomationConfiguration(
              enabled: true,
              policy: AutomationSelectionPolicy.lowestLatency,
              subscriptionId: group.id,
              nodeIds: [for (final node in group.nodes) node.id],
              targets: [
                AutomationTarget(
                  id: 'fixture',
                  url: 'http://127.0.0.1:${target.port}/fixture',
                  expectedStatus: 200,
                  expectedBody: body,
                ),
              ],
            ),
          );
        expect(await backend.control.connect(), 'connected');
        for (var i = 0; i < 60; i++) {
          if ((await backend.control.runtimeMetrics())['liveness'] != null)
            break;
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
        expect((await backend.control.runtimeMetrics())['liveness'], 'ok');
        await Future<void>.delayed(const Duration(seconds: 1));
        // The connection itself opens only when traffic passes; automation adds a
        // health check and three sequential samples per candidate.
        expect(
          handshakes,
          hasLength(lessThanOrEqualTo(lowestLatency ? 2 + 3 * 3 : 1)),
        );
        // TSPU counts handshakes under ~50 ms apart; never three in one window.
        for (var i = 2; i < handshakes.length; i++)
          expect(handshakes[i] - handshakes[i - 2], greaterThanOrEqualTo(50));
        await backend.control.disconnect();
      } finally {
        for (final peer in peers) peer.destroy();
        for (final relay in relays) await relay.close();
      }
    });

  for (final (warmCache, across) in [
    (true, false),
    (false, false),
    (true, true),
  ])
    test(
      'ordered fallback verifies candidate traffic (cached: $warmCache)${across ? ' from another subscription' : ''}',
      () async {
        // Each unreachable candidate costs one probe timeout per target.
        await backend.dispose();
        backend = createBackend(automationProbeSeconds: 2);
        final relay = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final peers = <Socket>{};
        var reachable = true;
        relay.listen((client) async {
          peers.add(client);
          if (!reachable) return;
          try {
            final server = await Socket.connect(
              '127.0.0.1',
              Uri.parse(profile).port,
            );
            peers.add(server);
            unawaited(
              client
                  .cast<List<int>>()
                  .pipe(server)
                  .catchError((Object _) => server),
            );
            unawaited(
              server
                  .cast<List<int>>()
                  .pipe(client)
                  .catchError((Object _) => client),
            );
          } on Object {
            client.destroy();
          }
        });
        try {
          final primary = Uri.parse(
            profile,
          ).replace(port: relay.port, fragment: 'Primary').toString();
          // The failed backup is a different server, since a local group keeps
          // each server once; nothing listens on its port.
          final imported = await backend.control.importClientProfiles(
            content:
                '$primary${across ? '' : '\n$profile'}${warmCache ? '' : '\n${Uri.parse(primary).replace(port: 1, fragment: 'Failed backup')}'}',
          );
          final local = imported.snapshot.subscriptions.single;
          final nodes = local.nodes;
          final first = nodes.singleWhere((node) => node.name == 'Primary').id;
          var fallback = '';
          if (across) {
            final feed = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
            addTearDown(() => feed.close(force: true));
            feed.listen((request) async {
              request.response.write(profile);
              await request.response.close();
            });
            final added = await backend.control.addSubscription(
              'http://127.0.0.1:${feed.port}/fixture',
            );
            final refreshed = await backend.control.refreshSubscription(
              added.snapshot.subscriptions
                  .singleWhere((group) => group.id != local.id)
                  .id,
              challenge: added.warning!.challenge,
            );
            fallback = refreshed.snapshot.subscriptions
                .singleWhere((group) => group.id != local.id)
                .nodes
                .single
                .id;
          } else {
            fallback = nodes.singleWhere((node) => node.name == 'Fixture').id;
          }
          final allowed = [
            first,
            if (!warmCache)
              nodes.singleWhere((node) => node.name == 'Failed backup').id,
            fallback,
          ];
          await backend.control.selectNode(first);
          await backend.control.configureAutomation(
            AutomationConfiguration(
              enabled: true,
              policy: AutomationSelectionPolicy.orderedFallback,
              subscriptionId: local.id,
              nodeIds: allowed,
              targets: [
                for (final host in ['127.0.0.1', 'localhost'])
                  AutomationTarget(
                    id: host,
                    url: 'http://$host:${target.port}/fixture',
                    expectedStatus: 200,
                    expectedBody: body,
                  ),
              ],
            ),
          );
          final before = targetRequests;
          if (!warmCache) reachable = false;
          await backend.control.connect();
          final runtime = lastProcess!;
          if (warmCache) {
            for (var i = 0; i < 150 && targetRequests < before + 7; i++) {
              await Future<void>.delayed(const Duration(milliseconds: 100));
            }
            expect(targetRequests, greaterThanOrEqualTo(before + 7));
            // Preserve coverage of previously verified alternatives as well.
            await Future<void>.delayed(const Duration(seconds: 1));
          } else {
            expect(
              targetRequests,
              before,
              reason: 'No candidate has been verified before this outage',
            );
          }
          reachable = false;
          for (final peer in peers) {
            peer.destroy();
          }
          runtime.kill();
          await runtime.exitCode;
          for (var i = 0; i < 700; i++) {
            expect(
              (await backend.control.subscriptions()).selectedNodeId,
              anyOf(first, fallback),
              reason: 'An unverified failed backup must never be published',
            );
            if ((await backend.control.subscriptions()).selectedNodeId ==
                    fallback &&
                await backend.control.state() == 'connected')
              break;
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          expect(
            (await backend.control.subscriptions()).selectedNodeId,
            fallback,
          );
          expect(
            catalogMap(storedCatalog!['committed'])['selectedNodeId'],
            fallback,
          );
          await checkSocks(
            (await backend.control.tunnelSettings()).socksPort,
            target.port,
          );
          // A manual selection makes that server the primary and keeps the backups.
          await backend.control.selectNode(first);
          final saved = catalogMap(
            catalogMap(storedCatalog!['committed'])['automation'],
          );
          expect(saved['policy'], 'orderedFallback');
          expect(saved['nodeIDs'], allowed);
        } finally {
          await backend.control.disconnect();
          await relay.close();
          for (final peer in peers) {
            peer.destroy();
          }
        }
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );

  // The CLI accepts a single check target; its failures alone must count.
  test(
    'ordered fallback with one check target leaves a primary that stops passing traffic',
    () async {
      await backend.dispose();
      backend = createBackend(
        automationProbeSeconds: 2,
        automationRetrySeconds: 2,
      );
      final relay = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final peers = <Socket>{};
      var reachable = true;
      relay.listen((client) async {
        peers.add(client);
        if (!reachable) return;
        try {
          final server = await Socket.connect(
            '127.0.0.1',
            Uri.parse(profile).port,
          );
          peers.add(server);
          unawaited(
            client
                .cast<List<int>>()
                .pipe(server)
                .catchError((Object _) => server),
          );
          unawaited(
            server
                .cast<List<int>>()
                .pipe(client)
                .catchError((Object _) => client),
          );
        } on Object {
          client.destroy();
        }
      });
      try {
        final primary = Uri.parse(
          profile,
        ).replace(port: relay.port, fragment: 'Primary').toString();
        final imported = await backend.control.importClientProfiles(
          content: '$primary\n$profile',
        );
        final nodes = imported.snapshot.subscriptions.single.nodes;
        final first = nodes.singleWhere((node) => node.name == 'Primary').id;
        final fallback = nodes.singleWhere((node) => node.name == 'Fixture').id;
        await backend.control.selectNode(first);
        await backend.control.configureAutomation(
          AutomationConfiguration(
            enabled: true,
            policy: AutomationSelectionPolicy.orderedFallback,
            subscriptionId: imported.snapshot.subscriptions.single.id,
            nodeIds: [first, fallback],
            targets: [
              AutomationTarget(
                id: 'fixture',
                url: 'http://127.0.0.1:${target.port}/fixture',
                expectedStatus: 200,
                expectedBody: body,
              ),
            ],
          ),
        );
        await backend.control.connect();
        final runtime = lastProcess!;
        reachable = false;
        for (final peer in peers) {
          peer.destroy();
        }
        for (var i = 0; i < 1500; i++) {
          if ((await backend.control.subscriptions()).selectedNodeId ==
                  fallback &&
              await backend.control.state() == 'connected')
            break;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(
          (await backend.control.subscriptions()).selectedNodeId,
          fallback,
        );
        expect(lastProcess!.pid, isNot(runtime.pid));
        await checkSocks(
          (await backend.control.tunnelSettings()).socksPort,
          target.port,
        );
      } finally {
        await backend.control.disconnect();
        await relay.close();
        for (final peer in peers) {
          peer.destroy();
        }
      }
    },
    timeout: const Timeout(Duration(seconds: 200)),
  );

  // An unresolvable server name is a failed connection, so failover moves on.
  test(
    'ordered fallback moves on from a primary whose server name does not resolve',
    () async {
      await backend.dispose();
      backend = createBackend(automationProbeSeconds: 2);
      Map<String, Object?> server(String name, String address) => {
        'remarks': name,
        // '#3' answers NXDOMAIN from the profile's own hosts table.
        if (address != '127.0.0.1')
          'dns': {
            'hosts': {address: '#3'},
          },
        'outbounds': [
          {
            'protocol': 'vless',
            'settings': {
              'vnext': [
                {
                  'address': address,
                  'port': Uri.parse(profile).port,
                  'users': [
                    {'id': userID, 'encryption': 'none'},
                  ],
                },
              ],
            },
          },
        ],
      };
      final imported = await backend.control.importClientProfiles(
        content: jsonEncode([
          server('Primary', 'server.elarni.test'),
          server('Backup', '127.0.0.1'),
        ]),
      );
      final group = imported.snapshot.subscriptions.single;
      final first = group.nodes
          .singleWhere((node) => node.name == 'Primary')
          .id;
      final fallback = group.nodes
          .singleWhere((node) => node.name == 'Backup')
          .id;
      await backend.control.selectNode(first);
      await backend.control.configureAutomation(
        AutomationConfiguration(
          enabled: true,
          policy: AutomationSelectionPolicy.orderedFallback,
          subscriptionId: group.id,
          nodeIds: [first, fallback],
          targets: [
            AutomationTarget(
              id: 'fixture',
              url: 'http://127.0.0.1:${target.port}/fixture',
              expectedStatus: 200,
              expectedBody: body,
            ),
          ],
        ),
      );
      try {
        await backend.control.connect();
      } on PlatformException {
        // Automation retries in the background.
      }
      try {
        // The replacement runs while its health check decides; the selection follows it.
        for (var i = 0; i < 600; i++) {
          if ((await backend.control.subscriptions()).selectedNodeId ==
                  fallback &&
              await backend.control.state() == 'connected')
            break;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(await backend.control.state(), 'connected');
        expect(
          (await backend.control.subscriptions()).selectedNodeId,
          fallback,
        );
        await checkSocks(
          (await backend.control.tunnelSettings()).socksPort,
          target.port,
        );
      } finally {
        await backend.control.disconnect();
      }
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test('a failed refresh says whose fault it is', () async {
    var status = 200;
    final feed = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    feed.listen((request) async {
      request.response.statusCode = status;
      if (status == 200) request.response.write(profile);
      await request.response.close();
    });
    try {
      final added = await backend.control.importClientProfiles(
        content: 'http://127.0.0.1:${feed.port}/synthetic-token',
      );
      final id = added.snapshot.subscriptions.singleWhere((s) => !s.isLocal).id;
      await backend.control.refreshSubscription(
        id,
        challenge: added.warning!.challenge,
      );
      for (final (code, error) in [
        (404, 'subscription_unavailable'),
        (403, 'subscription_denied'),
        (429, 'rate_limited'),
        (503, 'provider_error'),
      ]) {
        status = code;
        await expectLater(
          backend.control.refreshSubscription(id),
          throwsA(
            isA<PlatformException>()
                .having((e) => e.code, 'code', error)
                .having(
                  (e) => e.message,
                  'message',
                  desktopError(error).message,
                ),
          ),
          reason: 'HTTP $code',
        );
      }
      // Nothing listens on the feed's port any more.
      await feed.close(force: true);
      await expectLater(
        backend.control.refreshSubscription(id),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'provider_unreachable',
          ),
        ),
      );
    } finally {
      await feed.close(force: true);
    }
  });

  // The provider's Profile-Update-Interval is each subscription's default; the
  // user's refreshHours option wins and never reaches the provider.
  test(
    'a refresh follows the provider interval unless the user sets one',
    () async {
      final requests = <String>[];
      var interval = '12';
      final feed = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      feed.listen((request) async {
        requests.add('${request.uri} ${request.headers}');
        request.response.headers.set('Profile-Update-Interval', interval);
        request.response.write(profile);
        await request.response.close();
      });
      try {
        final added = await backend.control.importClientProfiles(
          content: 'http://127.0.0.1:${feed.port}/synthetic-token',
        );
        final id = added.snapshot.subscriptions
            .singleWhere((s) => !s.isLocal)
            .id;
        double hoursUntilRefresh() {
          final source = catalogList(
            catalogMap(storedCatalog!['committed'])['subscriptions'],
          ).singleWhere((source) => source['id'] == id);
          return ((source['nextRefreshAt']! as num) -
                  (source['lastSuccessfulFetch']! as num)) /
              3600;
        }

        await backend.control.refreshSubscription(
          id,
          challenge: added.warning!.challenge,
        );
        expect(hoursUntilRefresh(), inInclusiveRange(12 * 0.9, 12 * 1.1));
        await backend.control.updateSubscriptionFetchOptions(id, {
          'fallbackHosts': <String>[],
          'refreshHours': '2',
        });
        await backend.control.refreshSubscription(id);
        expect(hoursUntilRefresh(), inInclusiveRange(2 * 0.9, 2 * 1.1));
        for (final hours in ['0', '169', '1.5', 'soon']) {
          await expectLater(
            backend.control.updateSubscriptionFetchOptions(id, {
              'fallbackHosts': <String>[],
              'refreshHours': hours,
            }),
            throwsA(isA<PlatformException>()),
            reason: hours,
          );
        }
        expect(
          (await backend.control.subscriptions()).subscriptions
              .singleWhere((s) => s.id == id)
              .fetchOptions,
          {'refreshHours': '2'},
        );
        // Without an override or a usable provider value, the app setting applies.
        await backend.control.updateSubscriptionFetchOptions(id, {
          'fallbackHosts': <String>[],
        });
        interval = 'soon';
        await backend.control.refreshSubscription(id);
        expect(
          hoursUntilRefresh(),
          inInclusiveRange(
            initialSettings.subscriptionAutoUpdateHours * 0.9,
            initialSettings.subscriptionAutoUpdateHours * 1.1,
          ),
        );
        expect(requests, everyElement(isNot(contains('refresh'))));
      } finally {
        await feed.close(force: true);
      }
    },
  );

  test(
    'non-routing directives preserve local and subscription imports',
    () async {
      final content = '$profile\nincy://synthetic-provider-directive';
      final local = await backend.control.importClientProfiles(
        content: 'incy://import/${base64Encode(utf8.encode(content))}',
      );
      expect(local.snapshot.subscriptions.single.nodes.single.name, 'Fixture');
      final sharedNode = await backend.control.shareClient(
        local.snapshot.subscriptions.single.nodes.single.id,
      );
      expect(jsonDecode(sharedNode['text']! as String)['remarks'], 'Fixture');
      expect(sharedNode['png'], isA<String>());
      final hiddenLocal = await backend.control.importClientProfiles(
        content:
            '#hide-url: yes\n${profile.replaceFirst('#Fixture', '#Hidden')}',
      );
      await expectLater(
        backend.control.shareClient(
          hiddenLocal.snapshot.subscriptions.last.nodes.single.id,
        ),
        throwsA(isA<PlatformException>()),
      );
      expect((await backend.control.routingProfiles()).profiles, isEmpty);
      var routingHeader =
          'happ://routing/onadd/${base64Encode(utf8.encode(jsonEncode({
            'Name': 'Provider route',
            'RemoteDNSType': 'DoU',
            'RemoteDNSIP': '1.1.1.1',
            'DomesticDNSType': 'DoU',
            'DomesticDNSIP': '8.8.8.8',
            'DirectSites': ['full:example.com'],
          })))}';
      var hideURL = false;
      final feed = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      feed.listen((request) async {
        request.response.headers.set('Routing', routingHeader);
        request.response.headers.set('Hide-Url', hideURL ? 'yes' : 'false');
        request.response.write(content);
        await request.response.close();
      });
      try {
        final added = await backend.control.importClientProfiles(
          content: 'http://127.0.0.1:${feed.port}/synthetic-token',
        );
        final id = added.snapshot.subscriptions
            .singleWhere((s) => !s.isLocal)
            .id;
        final refreshed = await backend.control.refreshSubscription(
          id,
          challenge: added.warning!.challenge,
        );
        expect(
          refreshed.snapshot.subscriptions
              .singleWhere((s) => s.id == id)
              .nodes
              .single
              .name,
          'Fixture',
        );
        expect(
          (await backend.control.routingProfiles()).profiles.single.name,
          'Provider route',
        );
        routingHeader = routingHeader.replaceFirst('happ://', 'incy://');
        await backend.control.refreshSubscription(id);
        expect(
          (await backend.control.shareClient(id, subscription: true))['text'],
          'http://127.0.0.1:${feed.port}/synthetic-token',
        );
        hideURL = true;
        final hidden = await backend.control.refreshSubscription(id);
        expect(
          hidden.snapshot.subscriptions
              .singleWhere((s) => s.id == id)
              .metadata['hideURL'],
          true,
        );
        await expectLater(
          backend.control.shareClient(id, subscription: true),
          throwsA(isA<PlatformException>()),
        );
        await expectLater(
          backend.control.shareClient(
            hidden.snapshot.subscriptions
                .singleWhere((s) => s.id == id)
                .nodes
                .single
                .id,
          ),
          throwsA(isA<PlatformException>()),
        );
        expect(
          (await backend.control.routingProfiles()).profiles.single.name,
          'Provider route',
        );
        routingHeader = 'happ://routing/unsupported';
        await expectLater(
          backend.control.refreshSubscription(id),
          throwsA(
            isA<PlatformException>().having(
              (e) => e.code,
              'code',
              'invalid_routing',
            ),
          ),
        );
        expect(
          (await backend.control.subscriptions()).subscriptions
              .singleWhere((s) => s.id == id)
              .nodes
              .single
              .name,
          'Fixture',
        );
        expect(
          (await backend.control.routingProfiles()).profiles.single.name,
          'Provider route',
        );
      } finally {
        await feed.close(force: true);
      }
    },
  );

  test('provider routing refreshes keep the profile the user assigned', () async {
    const password = 'synthetic backup password';
    Map<String, Object?> route(String name) => {
      'Name': name,
      'RemoteDNSType': 'DoU',
      'RemoteDNSIP': '1.1.1.1',
      'DomesticDNSType': 'DoU',
      'DomesticDNSIP': '8.8.8.8',
    };
    var providerName = 'Provider route';
    final feed = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    feed.listen((request) async {
      request.response.headers.set(
        'Routing',
        'happ://routing/onadd/${base64Encode(utf8.encode(jsonEncode(route(providerName))))}',
      );
      request.response.write(profile);
      await request.response.close();
    });
    try {
      final added = await backend.control.addSubscription(
        'http://127.0.0.1:${feed.port}/feed',
      );
      final id = added.snapshot.subscriptions.single.id;
      await backend.control.refreshSubscription(
        id,
        challenge: added.warning!.challenge,
      );
      var routes = await backend.control.routingProfiles();
      final provider = routes.profiles.single.id;
      // Adding the subscription applies the provider's profile.
      expect(routes.assignments[id], provider);
      final mine = (await backend.control.importRouting(
        jsonEncode(route('My route')),
      )).profiles.singleWhere((p) => p.name == 'My route').id;
      await backend.control.assignRoutingProfile(id, mine);
      providerName = 'Updated provider route';
      await backend.control.refreshSubscription(id);
      routes = await backend.control.routingProfiles();
      expect(routes.assignments[id], mine);
      expect(
        routes.profiles.singleWhere((p) => p.id == provider).name,
        'Updated provider route',
      );
      // No profile is a choice too.
      await backend.control.assignRoutingProfile(id, null);
      await backend.control.refreshSubscription(id);
      expect((await backend.control.routingProfiles()).assignments[id], isNull);
      // A restored backup keeps the choice.
      await backend.control.assignRoutingProfile(id, mine);
      await backend.control.exportCatalogBackup(password);
      final file = File.fromUri(temporary.uri.resolve('routing backup.json'));
      await file.writeAsString(savedBackup!);
      pickedPath = file.path;
      final restored = (await backend.control.restoreCatalogBackup(
        password,
      )).subscriptions.single.id;
      final warning = (await backend.control.refreshSubscription(
        restored,
      )).warning!;
      await backend.control.refreshSubscription(
        restored,
        challenge: warning.challenge,
      );
      routes = await backend.control.routingProfiles();
      expect(
        routes.profiles
            .singleWhere((p) => p.id == routes.assignments[restored])
            .name,
        'My route',
      );
    } finally {
      await feed.close(force: true);
    }
  });

  test(
    'the provider fallback-url serves the subscription when its main URL fails',
    () async {
      final backupPaths = <String>[];
      final backup = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      backup.listen((request) async {
        backupPaths.add(request.uri.toString());
        request.response.write(profile.replaceFirst('#Fixture', '#Backup'));
        await request.response.close();
      });
      var failing = false;
      final feed = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      feed.listen((request) async {
        if (failing) {
          request.response.statusCode = 503;
        } else {
          request.response.headers.set(
            'fallback-url',
            'http://127.0.0.1:${backup.port}/backup?token=b',
          );
          request.response.write(profile);
        }
        await request.response.close();
      });
      try {
        var result = await backend.control.addSubscription(
          'http://127.0.0.1:${feed.port}/feed',
        );
        final id = result.snapshot.subscriptions.single.id;
        result = await backend.control.refreshSubscription(
          id,
          challenge: result.warning!.challenge,
        );
        expect(
          result.snapshot.subscriptions.single.nodes.single.name,
          'Fixture',
        );
        failing = true;
        result = await backend.control.refreshSubscription(id);
        // The backup is another loopback target, so it needs its own approval.
        for (
          var attempt = 0;
          result.warning != null && attempt < 4;
          attempt++
        ) {
          expect(backupPaths, isEmpty);
          result = await backend.control.refreshSubscription(
            id,
            challenge: result.warning!.challenge,
          );
        }
        expect(backupPaths, ['/backup?token=b']);
        expect(
          result.snapshot.subscriptions.single.nodes.single.name,
          'Backup',
        );
      } finally {
        await feed.close(force: true);
        await backup.close(force: true);
      }
    },
  );

  test(
    'subscription download options persist and fallback requires each approval',
    () async {
      final paths = <String>[];
      final agents = <String?>[];
      final feed = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      feed.listen((request) async {
        paths.add(request.uri.toString());
        agents.add(request.headers.value(HttpHeaders.userAgentHeader));
        request.response.write(profile);
        await request.response.close();
      });
      try {
        var result = await backend.control.addSubscription(
          'http://127.0.0.2:${feed.port}/feed?token=a%2Bb',
        );
        final id = result.snapshot.subscriptions.single.id;
        await backend.control.updateSubscriptionFetchOptions(id, {
          'fallbackHosts': ['127.0.0.1'],
        });
        for (
          var attempt = 0;
          result.warning != null && attempt < 4;
          attempt++
        ) {
          expect(paths, isEmpty);
          result = await backend.control.refreshSubscription(
            id,
            challenge: result.warning!.challenge,
          );
        }
        expect(result.warning, isNull);
        expect(paths, ['/feed?token=a%2Bb']);
        expect(result.snapshot.subscriptions.single.fallbackHosts, [
          '127.0.0.1',
        ]);
        await expectLater(
          backend.control.updateSubscriptionFetchOptions(id, {
            'fallbackHosts': [],
            'httpHost': 'provider.example',
          }),
          throwsA(isA<PlatformException>()),
        );
        expect(
          (await backend.control.subscriptions())
              .subscriptions
              .single
              .fallbackHosts,
          ['127.0.0.1'],
        );
        // As on Android: providers that check the client get the one the user named.
        await backend.control.updateSubscriptionFetchOptions(id, {
          'fallbackHosts': ['127.0.0.1'],
          'userAgent': 'FixtureClient/1.0',
        });
        await backend.control.refreshSubscription(id);
        expect(agents.last, 'FixtureClient/1.0');
        final secure = await backend.control.addSubscription(
          'https://127.0.0.1:${feed.port}/secure',
        );
        final secureID = secure.snapshot.subscriptions
            .singleWhere((s) => s.id != id)
            .id;
        const options = <String, Object?>{
          'fallbackHosts': <String>[],
          'connectAddress': '127.0.0.1',
          'httpHost': 'provider.example',
          'fragmentLength': '80-250',
          'fragmentInterval': '10-100',
        };
        await backend.control.updateSubscriptionFetchOptions(secureID, options);
        expect(
          (await backend.control.subscriptions()).subscriptions
              .singleWhere((s) => s.id == secureID)
              .fetchOptions,
          {
            for (final entry in options.entries)
              if (entry.key != 'fallbackHosts') entry.key: entry.value,
          },
        );
        // A headless client's null must not leave every snapshot unreadable.
        await expectLater(
          backend.control.updateSubscriptionFetchOptions(secureID, {
            'fallbackHosts': <String>[],
            'connectAddress': null,
          }),
          throwsA(isA<PlatformException>()),
        );
        expect(
          (await backend.control.subscriptions()).subscriptions
              .singleWhere((s) => s.id == secureID)
              .fetchOptions['connectAddress'],
          '127.0.0.1',
        );
      } finally {
        await feed.close(force: true);
      }
    },
  );

  // 3x-ui sends one of a REALITY server's shortIds and serverNames at random on each fetch.
  test(
    'a refresh that only changes the REALITY shortId or SNI keeps the core running',
    () async {
      var shortID = '0a1b', sni = 'example.com', fingerprint = 'chrome';
      final feed = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      feed.listen((request) async {
        // Connected means only that the local core answers; no server listens.
        request.response.write(
          'vless://$userID@127.0.0.1:9?encryption=none&security=reality&type=tcp&fp=$fingerprint'
          '&pbk=FCNsCTRerqst97Y-_Pc32LnnBu0g_hw-LhJYlaeiEVs&sni=$sni&sid=$shortID#Reality\n',
        );
        await request.response.close();
      });
      Future<Object?> connectedSince() async =>
          (await backend.control.runtimeMetrics())['connectedSince'];
      try {
        var result = await backend.control.addSubscription(
          'http://127.0.0.1:${feed.port}/feed',
        );
        final id = result.snapshot.subscriptions.single.id;
        for (
          var attempt = 0;
          result.warning != null && attempt < 4;
          attempt++
        ) {
          result = await backend.control.refreshSubscription(
            id,
            challenge: result.warning!.challenge,
          );
        }
        await backend.control.selectNode(
          result.snapshot.subscriptions.single.nodes.single.id,
        );
        expect(await backend.control.connect(), 'connected');
        final started = await connectedSince();
        expect(started, isNotNull);
        shortID = 'c2d3';
        sni = 'www.example.com';
        await backend.control.refreshSubscription(id);
        expect(await connectedSince(), started);
        // Any other change still restarts the core.
        fingerprint = 'firefox';
        await backend.control.refreshSubscription(id);
        expect(await backend.control.state(), 'connected');
        expect(await connectedSince(), allOf(isNotNull, isNot(started)));
      } finally {
        await feed.close(force: true);
      }
    },
  );

  test('a renamed server keeps its name and a deleted one is gone', () async {
    final feed = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    feed.listen((request) async {
      request.response.write(
        'socks://127.0.0.1:1080#First\nsocks://127.0.0.1:1081#Second\nsocks://127.0.0.1:1082#Third\n',
      );
      await request.response.close();
    });
    try {
      var result = await backend.control.addSubscription(
        'http://127.0.0.1:${feed.port}/servers',
      );
      final id = result.snapshot.subscriptions.single.id;
      for (var attempt = 0; result.warning != null && attempt < 4; attempt++) {
        result = await backend.control.refreshSubscription(
          id,
          challenge: result.warning!.challenge,
        );
      }
      final ids = [
        for (final node in result.snapshot.subscriptions.single.nodes) node.id,
      ];
      await backend.control.selectNode(ids[0]);
      await backend.control.renameNode(ids[1], ' Mine ');
      await backend.control.refreshSubscription(id);
      Future<List<SubscriptionNode>> nodes() async =>
          (await backend.control.subscriptions()).subscriptions.single.nodes;
      expect(
        [for (final node in await nodes()) node.name],
        ['First', 'Mine', 'Third'],
      );
      final shared = await backend.control.shareClient(ids[1]);
      expect(jsonDecode(shared['text']! as String)['remarks'], 'Mine');
      await backend.control.renameNode(ids[1], '');
      expect((await nodes())[1].name, 'Second');
      await expectLater(
        backend.control.deleteNode(ids[0]),
        throwsA(isA<PlatformException>()),
      );
      await backend.control.deleteNode(ids[2]);
      await backend.control.deleteNode(ids[1]);
      expect([for (final node in await nodes()) node.id], [ids[0]]);
      await expectLater(
        backend.control.deleteNode(ids[0]),
        throwsA(isA<PlatformException>()),
      );
    } finally {
      await feed.close(force: true);
    }
  });

  test(
    'the device ID shown is the one the provider gets, and a reset changes only that subscription',
    () async {
      final sent = <String, String?>{};
      final feed = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      feed.listen((request) async {
        sent[request.uri.path] = request.headers.value('x-hwid');
        request.response.write(
          'socks://127.0.0.1:1080#${request.uri.path.substring(1)}\n',
        );
        await request.response.close();
      });
      Future<String> add(String path) async {
        var result = await backend.control.addSubscription(
          'http://127.0.0.1:${feed.port}$path',
        );
        for (
          var attempt = 0;
          result.warning != null && attempt < 4;
          attempt++
        ) {
          result = await backend.control.refreshSubscription(
            result.warning!.subscriptionId,
            challenge: result.warning!.challenge,
          );
        }
        return result.snapshot.subscriptions.last.id;
      }

      try {
        final first = await add('/first'), second = await add('/second');
        final before = await backend.control.subscriptionDeviceID(first);
        expect(before, hasLength(64));
        expect(before, sent['/first']);
        // One origin, one ID, until the user resets one subscription.
        expect(await backend.control.subscriptionDeviceID(second), before);
        await backend.control.resetSubscriptionDeviceID(first);
        final after = await backend.control.subscriptionDeviceID(first);
        expect(after, allOf(hasLength(64), isNot(before)));
        expect(await backend.control.subscriptionDeviceID(second), before);
        await backend.control.refreshSubscription(first);
        await backend.control.refreshSubscription(second);
        expect(sent['/first'], after);
        expect(sent['/second'], before);
      } finally {
        await feed.close(force: true);
      }
    },
  );

  test(
    'a hidden server stays hidden across refreshes and a restore, which keeps renames and favorites',
    () async {
      final feed = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      feed.listen((request) async {
        request.response.write(
          'socks://127.0.0.1:1080#First\nsocks://127.0.0.1:1081#Second\nsocks://127.0.0.1:1082#Third\n',
        );
        await request.response.close();
      });
      const password = 'synthetic backup password';
      Future<SubscriptionGroup> approve(
        SubscriptionOperationResult result,
      ) async {
        for (
          var attempt = 0;
          result.warning != null && attempt < 4;
          attempt++
        ) {
          result = await backend.control.refreshSubscription(
            result.snapshot.subscriptions.single.id,
            challenge: result.warning!.challenge,
          );
        }
        return result.snapshot.subscriptions.single;
      }

      Future<SubscriptionGroup> group() async =>
          (await backend.control.subscriptions()).subscriptions.single;
      try {
        var source = await approve(
          await backend.control.addSubscription(
            'http://127.0.0.1:${feed.port}/servers',
          ),
        );
        final ids = [for (final node in source.nodes) node.id];
        await backend.control.selectNode(ids[0]);
        await backend.control.renameNode(ids[1], 'Mine');
        await backend.control.setNodeFavorite(ids[1], true);
        await backend.control.deleteNode(ids[2]);
        await backend.control.refreshSubscription(source.id);
        source = await group();
        expect([for (final node in source.nodes) node.name], ['First', 'Mine']);
        expect(source.hiddenNodes, [(id: ids[2], name: 'Third')]);

        await backend.control.exportCatalogBackup(password);
        final file = File.fromUri(temporary.uri.resolve('hidden backup.json'));
        await file.writeAsString(savedBackup!);
        pickedPath = file.path;
        await backend.control.restoreCatalogBackup(password);
        final restored = await group();
        await approve(await backend.control.refreshSubscription(restored.id));
        source = await group();
        expect([for (final node in source.nodes) node.name], ['First', 'Mine']);
        expect(source.nodes[1].favorite, isTrue);
        expect([for (final node in source.hiddenNodes) node.name], ['Third']);
        // The restored rename still knows the provider's name.
        await backend.control.renameNode(source.nodes[1].id, '');
        expect((await group()).nodes[1].name, 'Second');

        await backend.control.showNode(source.hiddenNodes.single.id);
        await backend.control.refreshSubscription(source.id);
        source = await group();
        expect(
          [for (final node in source.nodes) node.name],
          ['First', 'Second', 'Third'],
        );
        expect(source.hiddenNodes, isEmpty);
      } finally {
        await feed.close(force: true);
      }
    },
  );

  test(
    'hiding servers together keeps them out of refreshes, deletes local ones and refuses the selected',
    () async {
      final feed = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      feed.listen((request) async {
        request.response.write(
          'socks://127.0.0.1:1080#First\nsocks://127.0.0.1:1081#Second\nsocks://127.0.0.1:1082#Third\n',
        );
        await request.response.close();
      });
      Future<SubscriptionGroup> group(String id) async =>
          (await backend.control.subscriptions()).subscriptions.singleWhere(
            (group) => group.id == id,
          );
      try {
        var added = await backend.control.addSubscription(
          'http://127.0.0.1:${feed.port}/servers',
        );
        for (var i = 0; added.warning != null && i < 4; i++) {
          added = await backend.control.refreshSubscription(
            added.warning!.subscriptionId,
            challenge: added.warning!.challenge,
          );
        }
        final remote = added.snapshot.subscriptions.single;
        final ids = [for (final node in remote.nodes) node.id];
        await backend.control.selectNode(ids[0]);
        // The selected server refuses the whole batch, as does a subscription's last one.
        for (final batch in [
          [ids[1], ids[0]],
          [ids[1], 'missing'],
        ]) {
          await expectLater(
            backend.control.deleteNodes(batch),
            throwsA(isA<PlatformException>()),
          );
        }
        expect((await group(remote.id)).nodes, hasLength(3));
        final hidden = await backend.control.deleteNodes([ids[1], ids[2]]);
        expect(
          [for (final node in hidden.subscriptions.single.nodes) node.name],
          ['First'],
        );
        await backend.control.refreshSubscription(remote.id);
        final refreshed = await group(remote.id);
        expect([for (final node in refreshed.nodes) node.name], ['First']);
        expect(
          [for (final node in refreshed.hiddenNodes) node.name],
          ['Second', 'Third'],
        );

        final gone = Uri.parse(profile).replace(port: 9, fragment: 'Gone');
        final imported = await backend.control.importClientProfiles(
          content: '$profile\n$gone',
        );
        final local = imported.snapshot.subscriptions.singleWhere(
          (group) => group.isLocal,
        );
        await backend.control.deleteNodes([
          local.nodes.singleWhere((node) => node.name == 'Gone').id,
        ]);
        final kept = await group(local.id);
        expect([for (final node in kept.nodes) node.name], ['Fixture']);
        expect(kept.hiddenNodes, isEmpty);
      } finally {
        await feed.close(force: true);
      }
    },
  );

  test(
    'deleting a server keeps automatic recovery over the remaining ones',
    () async {
      await backend.dispose();
      backend = createBackend(automationProbeSeconds: 2);
      final gone = Uri.parse(profile).replace(port: 9, fragment: 'Gone');
      final imported = await backend.control.importClientProfiles(
        content: '$profile\n$gone',
      );
      final nodes = imported.snapshot.subscriptions.single.nodes;
      final current = nodes.singleWhere((node) => node.name == 'Fixture').id;
      final deleted = nodes.singleWhere((node) => node.name == 'Gone').id;
      await backend.control.selectNode(current);
      await backend.control.configureAutomation(
        AutomationConfiguration(
          enabled: true,
          policy: AutomationSelectionPolicy.lowestLatency,
          subscriptionId: imported.snapshot.subscriptions.single.id,
          nodeIds: [current, deleted],
          targets: [
            AutomationTarget(
              id: 'fixture',
              url: 'http://127.0.0.1:${target.port}/fixture',
              expectedStatus: 200,
              expectedBody: body,
            ),
          ],
        ),
      );
      await backend.control.deleteNode(deleted);
      final before = targetRequests;
      try {
        await backend.control.connect();
        // One health check, then three samples of the current server.
        for (var i = 0; i < 150 && targetRequests < before + 4; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(targetRequests, greaterThanOrEqualTo(before + 4));
        await Future<void>.delayed(const Duration(seconds: 1));
        final status = await backend.control.automationStatus();
        expect(status['status'], 'healthy');
        expect(status['attempts'], 0);
        expect(catalogMap(status['configuration'])['nodeIDs'], [current]);
      } finally {
        await backend.control.disconnect();
      }
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'subscription URL migration retains selection and requires new approval',
    () async {
      final paths = <String>[];
      var migrate = false;
      final feed = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final original = 'http://127.0.0.1:${feed.port}/old?token=one';
      final replacement = 'http://127.0.0.1:${feed.port}/new?token=two';
      feed.listen((request) async {
        paths.add(request.uri.toString());
        if (migrate) request.response.headers.set('New-Url', replacement);
        request.response.write(profile);
        await request.response.close();
      });
      try {
        final added = await backend.control.addSubscription(original);
        final id = added.snapshot.subscriptions.single.id;
        final ready = await backend.control.refreshSubscription(
          id,
          challenge: added.warning!.challenge,
        );
        final node = ready.snapshot.subscriptions.single.nodes.single.id;
        await backend.control.selectNode(node);
        migrate = true;
        rejectNextCommit = true;
        await expectLater(
          backend.control.refreshSubscription(id),
          throwsA(isA<PlatformException>()),
        );
        expect(
          catalogList(
            catalogMap(storedCatalog!['committed'])['subscriptions'],
          ).single['url'],
          original,
        );
        await backend.control.refreshSubscription(id);
        expect(
          catalogList(
            catalogMap(storedCatalog!['committed'])['subscriptions'],
          ).single['url'],
          replacement,
        );
        final beforeApproval = paths.length;
        final warning = await backend.control.refreshSubscription(id);
        expect(warning.warning, isNotNull);
        expect(paths.length, beforeApproval);
        await backend.control.refreshSubscription(
          id,
          challenge: warning.warning!.challenge,
        );
        expect(paths.last, '/new?token=two');
        expect((await backend.control.refreshSubscription(id)).warning, isNull);
        expect((await backend.control.subscriptions()).selectedNodeId, node);
      } finally {
        await feed.close(force: true);
      }
    },
  );

  test(
    'manual subscription update applies fetched changes without a confirmation or refetch',
    () async {
      var content = profile;
      var requests = 0;
      final feed = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      feed.listen((request) async {
        requests++;
        request.response.write(content);
        await request.response.close();
      });
      try {
        final added = await backend.control.addSubscription(
          'http://127.0.0.1:${feed.port}/feed',
        );
        final id = added.snapshot.subscriptions.single.id;
        final imported = await backend.control.refreshSubscription(
          id,
          challenge: added.warning!.challenge,
        );
        final original = imported.snapshot.subscriptions.single.nodes.single;
        await backend.control.selectNode(original.id);
        var revision = original.configurationRevision;
        for (final host in ['localhost', '127.0.0.1']) {
          content = profile.replaceFirst('127.0.0.1:', '$host:');
          final before = requests;
          final updated = await backend.control.refreshSubscription(id);
          final node = updated.snapshot.subscriptions.single.nodes.single;
          expect(requests, before + 1);
          expect(updated.warning, isNull);
          expect(updated.snapshot.selectedNodeId, original.id);
          expect(node.id, original.id);
          expect(node.configurationRevision, isNot(revision));
          revision = node.configurationRevision;
          final saved = catalogList(
            catalogList(
              catalogMap(storedCatalog!['committed'])['subscriptions'],
            ).single['nodes'],
          ).single;
          final outbound = catalogList(
            catalogMap(saved['config'])['outbounds'],
          ).single;
          expect(catalogMap(outbound['settings'])['address'], host);
          expect(saved['configurationRevision'], revision);
        }
      } finally {
        await feed.close(force: true);
      }
    },
  );

  test(
    'subscription duplicates and preferences survive relaunch and background refresh',
    () async {
      var content = profile;
      final feed = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      feed.listen((request) async {
        request.response.write(content);
        await request.response.close();
      });
      try {
        final url = 'http://127.0.0.1:${feed.port}/feed';
        final added = await backend.control.addSubscription('$url#First label');
        final id = added.snapshot.subscriptions.single.id;
        final duplicate = await backend.control.addSubscription(
          '$url#Another label',
        );
        expect(duplicate.snapshot.subscriptions.single.id, id);
        await backend.control.refreshSubscription(
          id,
          challenge: duplicate.warning!.challenge,
        );
        var node = (await backend.control.subscriptions())
            .subscriptions
            .single
            .nodes
            .single;
        final nodeId = node.id;
        await backend.control.setNodeFavorite(nodeId, true);
        await backend.control.selectNode(nodeId);
        await backend.control.connect();
        node = (await backend.control.subscriptions())
            .subscriptions
            .single
            .nodes
            .single;
        expect(node.favorite, true);
        expect(node.lastSuccessAt, isNotNull);
        expect(node.lastSuccessCurrent, true);
        final revision = node.configurationRevision;
        final success = node.lastSuccessAt;
        final running = lastProcess;
        var runtimeExited = false;
        unawaited(
          running!.exitCode.then((_) {
            runtimeExited = true;
          }),
        );
        content = profile.replaceFirst('#Fixture', '#Renamed');
        await backend.control.refreshSubscription(id);
        node = (await backend.control.subscriptions())
            .subscriptions
            .single
            .nodes
            .single;
        expect(node.id, nodeId);
        expect(node.configurationRevision, revision);
        expect(node.favorite, true);
        expect(node.lastSuccessAt, success);
        expect(runtimeExited, false);
        await backend.control.disconnect();
        await backend.dispose();
        backend = DesktopProxy(
          corePath: corePath,
          startProcess: startCore,
          domainPath: domainPath,
          catalogIO: storage,
          platformIO: (_, _) async => {},
        );
        node = (await backend.control.subscriptions())
            .subscriptions
            .single
            .nodes
            .single;
        expect(node.favorite, true);
        expect(node.lastSuccessAt, success);
        expect(node.lastSuccessCurrent, true);
        // Background refreshes use the native owner directly and apply at once.
        content = content.replaceFirst('127.0.0.1:', '127.0.0.2:');
        await backend.request('refreshSubscription', {'id': id});
        node = (await backend.control.subscriptions())
            .subscriptions
            .single
            .nodes
            .single;
        expect(node.id, nodeId);
        expect(node.favorite, true);
        expect(node.configurationRevision, isNot(revision));
        expect(node.lastSuccessAt, success);
        expect(node.lastSuccessCurrent, false);
        expect(await backend.control.state(), 'prepared');
      } finally {
        await feed.close(force: true);
      }
    },
  );

  test(
    'reordered same-name protocols retain each node preference during endpoint replacement',
    () async {
      const trojan =
          'trojan://synthetic@192.0.2.2:443?security=tls&sni=example.com#Fixture';
      var content = '$profile\n$trojan';
      final feed = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      feed.listen((request) async {
        request.response.write(content);
        await request.response.close();
      });
      try {
        final added = await backend.control.addSubscription(
          'http://127.0.0.1:${feed.port}/feed',
        );
        final id = added.snapshot.subscriptions.single.id;
        final fetched = await backend.control.refreshSubscription(
          id,
          challenge: added.warning!.challenge,
        );
        final original = fetched.snapshot.subscriptions.single.nodes;
        final vless = original.singleWhere((node) => node.protocol == 'VLESS');
        final unchanged = original.singleWhere(
          (node) => node.protocol == 'Trojan',
        );
        await backend.control.setNodeFavorite(vless.id, true);
        content =
            '$trojan\n${profile.replaceFirst('127.0.0.1:', '127.0.0.2:')}';
        final refreshed = await backend.control.refreshSubscription(id);
        final nodes = refreshed.snapshot.subscriptions.single.nodes;
        expect(nodes.map((node) => node.id), [unchanged.id, vless.id]);
        expect(nodes.last.favorite, true);
        expect(
          nodes.last.configurationRevision,
          isNot(vless.configurationRevision),
        );
        expect(
          nodes.first.configurationRevision,
          unchanged.configurationRevision,
        );
      } finally {
        await feed.close(force: true);
      }
    },
  );

  // Validation compiles each JSON server with the whole list: 40 servers x 1 MB
  // of sites must stay under the 64 MiB native limit.
  test(
    'a large routing list still saves with many JSON servers',
    () async {
      final sites = [
        for (var i = 0; i < 15000; i++) 'full:${'x' * 48}-$i.example',
      ];
      Map<String, Object?> route(List<String> direct) => {
        'Name': 'Large route',
        'RemoteDNSType': 'DoU',
        'RemoteDNSIP': '1.1.1.1',
        'DomesticDNSType': 'DoU',
        'DomesticDNSIP': '8.8.8.8',
        'DirectSites': direct,
      };
      final imported = await backend.control.importClientProfiles(
        content: jsonEncode([
          for (var i = 0; i < 40; i++)
            {
              'remarks': 'JSON $i',
              'outbounds': [
                {
                  'protocol': 'vless',
                  'settings': {
                    'address': '127.0.0.1',
                    'port': 1000 + i,
                    'id': userID,
                    'encryption': 'none',
                  },
                },
              ],
            },
        ]),
      );
      final sourceId = imported.snapshot.subscriptions.single.id;
      final routeId = (await backend.control.importRouting(
        jsonEncode(route(sites)),
      )).profiles.single.id;
      await backend.control.assignRoutingProfile(sourceId, routeId);
      await backend.control.updateRoutingProfile(
        routeId,
        jsonEncode(route([...sites.skip(1), 'full:added.example'])),
      );
      expect(jsonEncode(storedCatalog), contains('full:added.example'));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  // A route keeps its profile, original and route model, so 40,000 sites make
  // an 8 MiB catalog. Saving an edit of it must stay under the 12 MiB limit.
  test(
    'a catalog over half the save limit still saves edits',
    () async {
      final routeId = (await backend.control.importRouting(
        jsonEncode({
          'Name': 'Huge route',
          'RemoteDNSType': 'DoU',
          'RemoteDNSIP': '1.1.1.1',
          'DomesticDNSType': 'DoU',
          'DomesticDNSIP': '8.8.8.8',
          'DirectSites': [
            for (var i = 0; i < 40000; i++) 'full:${'x' * 48}-$i.example',
          ],
        }),
      )).profiles.single.id;
      final committed = utf8.encode(jsonEncode(storedCatalog)).length;
      expect(committed, greaterThan(6 * 1024 * 1024));
      final edited = await backend.control.setRoutingProfileEnabled(
        routeId,
        false,
      );
      expect(edited.profiles.single.enabled, isFalse);
      expect(storedCatalog!['pending'], isNull);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('publishing new routing assets invalidates server health', () async {
    await useStub('''
import json, subprocess, sys, uuid
line = sys.stdin.readline()
request = json.loads(line)
method = request['method']
if method == 'prepareRoutingAssets':
    data = {'assetRevision': uuid.uuid4().hex + uuid.uuid4().hex, 'geofileStatus': 'ready', 'reductionStatus': 'ready', 'geofiles': []}
    print(json.dumps({'success': True, 'data': data}), flush=True)
elif method == 'retireRoutingAssets':
    print(json.dumps({'success': True, 'data': {}}), flush=True)
else:
    child = subprocess.Popen([${jsonEncode(corePath)}], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    child.stdin.write(line)
    child.stdin.flush()
    print(child.stdout.readline(), end='', flush=True)
    child.stdin.close()
    child.wait(timeout=10)
''');
    await prepare();
    final route = {
      'Name': 'Asset revision',
      'RemoteDNSType': 'DoU',
      'RemoteDNSIP': '1.1.1.1',
      'DomesticDNSType': 'DoU',
      'DomesticDNSIP': '8.8.8.8',
      'Geositeurl': 'https://fixture.invalid/first.dat',
    };
    final routeId = (await backend.control.importRouting(
      jsonEncode(route),
    )).profiles.single.id;
    final source = (await backend.control.subscriptions()).subscriptions.single;
    await backend.control.assignRoutingProfile(source.id, routeId);
    Future<SubscriptionNode> node() async =>
        (await backend.control.subscriptions())
            .subscriptions
            .single
            .nodes
            .single;
    final before = (await node()).revision;
    await backend.control.updateRoutingProfile(
      routeId,
      jsonEncode({
        ...route,
        'Geositeurl': 'https://fixture.invalid/second.dat',
      }),
    );
    final published = (await node()).revision;
    expect(
      published,
      isNot(before),
      reason: 'newly prepared asset bytes invalidate previous health',
    );
  });

  test('connect prepares geofiles again once the cache lost them', () async {
    final assets = '${coreEnvironment['LOCALAPPDATA']}/Elarni/assets';
    final preparations = File.fromUri(temporary.uri.resolve('lost-assets'));
    final offline = File.fromUri(temporary.uri.resolve('lost-assets-offline'));
    // Only the download is simulated; the actual core reads the revision and
    // runs the route.
    await useStub('''
import json, os, subprocess, sys, threading, uuid
line = sys.stdin.readline()
request = json.loads(line)
if request['method'] == 'prepareRoutingAssets':
    with open(${jsonEncode(preparations.path)}, 'a') as log: print(request['payload']['previous'], file=log)
    if os.path.exists(${jsonEncode(offline.path)}):
        print(json.dumps({'success': False, 'error': 'fetch_failed'}), flush=True)
        sys.exit()
    revision = uuid.uuid4().hex + uuid.uuid4().hex
    os.makedirs(os.path.join(${jsonEncode(assets)}, revision))
    print(json.dumps({'success': True, 'data': {'assetRevision': revision, 'geofileStatus': 'ready', 'reductionStatus': 'ready', 'geofiles': []}}), flush=True)
    sys.exit()
child = subprocess.Popen([${jsonEncode(corePath)}], stdin=subprocess.PIPE, stderr=subprocess.DEVNULL)
child.stdin.write(line.encode())
child.stdin.flush()
# The core answers on this stdout; a runtime lasts until the controller closes this pipe.
def forward_eof():
    sys.stdin.read()
    child.stdin.close()
threading.Thread(target=forward_eof, daemon=True).start()
sys.exit(child.wait())
''');
    await prepare();
    final routeId = (await backend.control.importRouting(
      jsonEncode({
        'Name': 'Lost geofiles',
        'RemoteDNSType': 'DoU',
        'RemoteDNSIP': '1.1.1.1',
        'DomesticDNSType': 'DoU',
        'DomesticDNSIP': '8.8.8.8',
        'DirectSites': ['full:example.com'],
        'Geositeurl': 'https://fixture.invalid/geosite.dat',
      }),
    )).profiles.single.id;
    final source = (await backend.control.subscriptions()).subscriptions.single;
    await backend.control.assignRoutingProfile(source.id, routeId);
    String revision() =>
        catalogList(
              catalogMap(storedCatalog!['committed'])['profiles'],
            ).single['assetRevision']!
            as String;
    final lost = revision();
    final prepared = (await preparations.readAsLines()).length;
    // As when another process empties the cache under the catalog.
    await Directory('$assets/$lost').delete(recursive: true);
    await offline.create();
    await expectLater(
      backend.control.connect(),
      throwsA(
        isA<PlatformException>()
            .having((e) => e.code, 'code', 'assets_missing')
            .having(
              (e) => e.message,
              'message',
              desktopError('assets_missing').message,
            ),
      ),
    );
    expect(revision(), lost);
    await offline.delete();
    expect(await backend.control.connect(), 'connected');
    expect(revision(), isNot(lost));
    expect(Directory('$assets/${revision()}').existsSync(), isTrue);
    // One preparation per connect, each from the lost revision.
    expect((await preparations.readAsLines()).sublist(prepared), [lost, lost]);
    await checkSocks(
      (await backend.control.tunnelSettings()).socksPort,
      target.port,
    );
  });

  test(
    'only Direct, Block and domestic DNS rules skip codes missing from the geofiles',
    () async {
      final requests = File.fromUri(temporary.uri.resolve('missing-codes'));
      // Answers as the core does when the geofiles lack RU: Direct, Block and
      // domestic DNS rules skip it, anything else fails and names it.
      await useStub('''
import json, subprocess, sys, uuid
line = sys.stdin.readline()
request = json.loads(line)
payload = request.get('payload') or {}
if request['method'] != 'prepareRoutingAssets':
    child = subprocess.Popen([${jsonEncode(corePath)}], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    child.stdin.write(line)
    child.stdin.flush()
    print(child.stdout.readline(), end='', flush=True)
    child.stdin.close()
    child.wait(timeout=10)
elif 'geoip:ru' in payload['selectors']:
    with open(${jsonEncode(requests.path)}, 'a') as log: print(json.dumps(payload), file=log)
    print(json.dumps({'success': False, 'error': 'missing_geodata', 'data': {'missing': ['geoip:ru']}}), flush=True)
else:
    with open(${jsonEncode(requests.path)}, 'a') as log: print(json.dumps(payload), file=log)
    skipped = [selector for selector in payload['optional'] if selector == 'geoip:ru']
    print(json.dumps({'success': True, 'data': {'assetRevision': uuid.uuid4().hex + uuid.uuid4().hex, 'geofileStatus': 'ready', 'reductionStatus': 'disabled', 'geofiles': [], 'skippedGeodata': skipped}}), flush=True)
''');
      final route = {
        'Name': 'Missing codes',
        'RemoteDNSType': 'DoU',
        'RemoteDNSIP': '1.1.1.1',
        'DomesticDNSType': 'DoU',
        'DomesticDNSIP': '8.8.8.8',
        'DomesticDNSDomains': ['geosite:domestic'],
        'DirectIp': ['geoip:ru', 'geoip:!cn'],
        'BlockSites': ['geosite:ads'],
        'ProxySites': ['geosite:proxied'],
        'Geoipurl': 'https://fixture.invalid/geoip.dat',
        'Geositeurl': 'https://fixture.invalid/geosite.dat',
      };
      final imported = await backend.control.importRouting(jsonEncode(route));
      CatalogMap lastRequest() =>
          catalogMap(jsonDecode(requests.readAsLinesSync().last));
      expect(lastRequest()['selectors'], ['geosite:proxied']);
      // The core decides that a negated selector still needs its code.
      expect(lastRequest()['optional'], [
        'geoip:!cn',
        'geoip:ru',
        'geosite:ads',
        'geosite:domestic',
      ]);
      final profile = imported.profiles.single;
      expect(profile.geofileStatus, 'ready');
      expect(profile.geofileError, isNull);
      expect(profile.skippedGeodata, ['geoip:ru']);
      // Without chunked files the prepared files still depend on the rules.
      final moved = await backend.control.updateRoutingProfile(
        profile.id,
        jsonEncode({
          ...route,
          'DirectIp': ['geoip:!cn'],
          'ProxyIp': ['geoip:ru'],
        }),
      );
      expect(lastRequest()['selectors'], ['geoip:ru', 'geosite:proxied']);
      final failed = moved.profiles.single;
      expect(failed.geofileStatus, 'failed');
      expect(
        failed.geofileError,
        'Proxy rules and servers need codes the geofiles lack: geoip:ru. '
        'Fix the profile or its geofile links.',
      );
    },
  );

  test('ext-site and ext-domain rules reach the geofile preparation', () async {
    final requests = File.fromUri(temporary.uri.resolve('external-codes'));
    await useStub('''
import json, sys, uuid
request = json.loads(sys.stdin.readline())
if request['method'] == 'prepareRoutingAssets':
    with open(${jsonEncode(requests.path)}, 'a') as log: print(json.dumps(request['payload']), file=log)
    print(json.dumps({'success': True, 'data': {'assetRevision': uuid.uuid4().hex + uuid.uuid4().hex, 'geofileStatus': 'ready', 'reductionStatus': 'ready', 'geofiles': []}}), flush=True)
else:
    print(json.dumps({'success': False, 'error': 'unexpected'}), flush=True)
''');
    await backend.control.importRouting(
      jsonEncode({
        'Name': 'External codes',
        'RemoteDNSType': 'DoU',
        'RemoteDNSIP': '1.1.1.1',
        'DomesticDNSType': 'DoU',
        'DomesticDNSIP': '8.8.8.8',
        'ProxySites': ['ext-site:geosite.dat:cn', 'geosite:google'],
        'DirectSites': ['ext-domain:geosite.dat:private'],
        'Geositeurl': 'https://fixture.invalid/geosite.dat',
        'UseChunkFiles': 'true',
      }),
    );
    // Xray reads these from the file too, so the reduction must keep it whole.
    final request = catalogMap(jsonDecode(requests.readAsLinesSync().last));
    expect(request['selectors'], contains('ext-site:geosite.dat:cn'));
    expect(request['optional'], contains('ext-domain:geosite.dat:private'));
  });

  // Xray reads a leading ! on an IP rule like one before the code; server JSON
  // keeps it there, and a reduced geoip.dat without the code stops the core.
  test(
    'negated geodata rules in server JSON reach the geofile preparation',
    () async {
      final requests = File.fromUri(temporary.uri.resolve('negated-codes'));
      await useStub('''
import json, subprocess, sys, uuid
line = sys.stdin.readline()
request = json.loads(line)
if request['method'] == 'prepareRoutingAssets':
    with open(${jsonEncode(requests.path)}, 'a') as log: print(json.dumps(request['payload']), file=log)
    print(json.dumps({'success': True, 'data': {'assetRevision': uuid.uuid4().hex + uuid.uuid4().hex, 'geofileStatus': 'ready', 'reductionStatus': 'ready', 'geofiles': []}}), flush=True)
else:
    child = subprocess.Popen([${jsonEncode(corePath)}], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    child.stdin.write(line)
    child.stdin.flush()
    print(child.stdout.readline(), end='', flush=True)
    child.stdin.close()
    child.wait(timeout=10)
''');
      final imported = await backend.control.importClientProfiles(
        content: jsonEncode({
          'outbounds': [
            {
              'tag': 'proxy',
              'protocol': 'vless',
              'settings': {
                'address': '127.0.0.1',
                'port': 443,
                'id': userID,
                'encryption': 'none',
              },
            },
            {'tag': 'direct', 'protocol': 'freedom'},
          ],
          'routing': {
            'rules': [
              {
                'type': 'field',
                'ip': ['!geoip:ru', '!ext:geoip.dat:by'],
                'outboundTag': 'direct',
              },
            ],
          },
        }),
      );
      final routeId = (await backend.control.importRouting(
        jsonEncode({
          'Name': 'Negated codes',
          'RemoteDNSType': 'DoU',
          'RemoteDNSIP': '1.1.1.1',
          'DomesticDNSType': 'DoU',
          'DomesticDNSIP': '8.8.8.8',
          'ProxyIp': ['geoip:us'],
          'Geoipurl': 'https://fixture.invalid/geoip.dat',
          'UseChunkFiles': 'true',
        }),
      )).profiles.single.id;
      await backend.control.assignRoutingProfile(
        imported.snapshot.subscriptions.last.id,
        routeId,
      );
      await backend.control.refreshRoutingGeofiles(routeId);
      final request = catalogMap(jsonDecode(requests.readAsLinesSync().last));
      expect(
        request['selectors'],
        containsAll(['!geoip:ru', '!ext:geoip.dat:by', 'geoip:us']),
      );
    },
  );

  test('domain suffix and IP direct lists independently bypass the proxy', () async {
    // A closed proxy endpoint makes accidental VPN routing fail visibly.
    final closedPort = await freePort();
    final route = {
      'Name': 'Independent direct lists',
      'RemoteDNSType': 'DoU',
      'RemoteDNSIP': '192.0.2.53',
      'DomesticDNSType': 'DoU',
      'DomesticDNSIP': '192.0.2.53',
      'DirectSites': ['domain:.ru'],
      'DirectIp': ['192.0.2.0/24'],
      'GlobalProxy': 'true',
    };
    final directive =
        'elarni://routing/onadd/${base64Encode(utf8.encode(jsonEncode(route)))}';
    final imported = await backend.control.importClientProfiles(
      content:
          'vless://$userID@127.0.0.1:$closedPort?encryption=none&security=none&type=tcp#Closed\n$directive',
    );
    await backend.control.selectNode(
      imported.snapshot.subscriptions.single.nodes.single.id,
    );
    await backend.control.connect();
    final ports = await backend.control.tunnelSettings();
    // SOCKS receives an IP, as the packet bridge does; HTTP sniffing supplies .ru.
    await checkSocks(ports.socksPort, target.port, host: 'fixture.ru');
    final beforeFallback = targetRequests;
    await checkHTTPRejected(ports.httpPort, target.port);
    expect(targetRequests, beforeFallback);
    final routes = await backend.control.routingProfiles();
    await backend.control.updateRoutingProfile(
      routes.profiles.single.id,
      jsonEncode({
        ...route,
        'DomainStrategy': 'IPOnDemand',
        'DnsHosts': {'resolved.fixture.test': '127.0.0.1'},
        'DirectIp': ['127.0.0.1/32'],
      }),
    );
    await checkSocks(ports.socksPort, target.port);
    // Use the core's synthetic DNS hosts for the direct outbound as well.
    await backend.control.updateTunnelSettings(
      ports.copyWith(profilePreferredIP: 'ipv4'),
    );
    await checkSocks(
      ports.socksPort,
      target.port,
      host: 'resolved.fixture.test',
      targetDomain: 'resolved.fixture.test',
    );
  });

  test(
    'subscription refresh preserves an open connection and rejects invalid runtime configuration before stopping',
    () async {
      final assetRequests = File.fromUri(
        temporary.uri.resolve('refresh-assets'),
      );
      // Only Windows database preparation is simulated; subscriptions, validation
      // and the open SOCKS connection use the actual native helper and loopback.
      // The core runs only a route whose revision directory exists.
      final assets = '${coreEnvironment['LOCALAPPDATA']}/Elarni/assets';
      await useStub('''
import json, os, subprocess, sys, uuid
line = sys.stdin.readline()
request = json.loads(line)
if request['method'] == 'prepareRoutingAssets':
    with open(${jsonEncode(assetRequests.path)}, 'a') as log: print(line.strip(), file=log)
    revision = uuid.uuid4().hex + uuid.uuid4().hex
    os.makedirs(os.path.join(${jsonEncode(assets)}, revision))
    print(json.dumps({'success': True, 'data': {'assetRevision': revision, 'geofileStatus': 'ready', 'reductionStatus': 'ready', 'geofiles': []}}), flush=True)
else:
    child = subprocess.Popen([${jsonEncode(corePath)}], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    child.stdin.write(line)
    child.stdin.flush()
    print(child.stdout.readline(), end='', flush=True)
    child.stdin.close()
    child.wait(timeout=10)
''');
      final assetStub = stub;
      var routingName = 'Stable routing';
      String routingDirective() =>
          'happ://routing/onadd/${base64Encode(utf8.encode(jsonEncode({
            'Name': routingName,
            'RemoteDNSType': 'DoU',
            'RemoteDNSIP': '1.1.1.1',
            'DomesticDNSType': 'DoU',
            'DomesticDNSIP': '8.8.8.8',
            'DirectSites': ['full:example.com'],
            'Geositeurl': 'https://fixture.invalid/geosite.dat',
            'UseChunkFiles': 'true',
          })))}';
      var content = profile;
      final feed = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      feed.listen((request) async {
        request.response.headers.set('Routing', routingDirective());
        request.response.write(content);
        await request.response.close();
      });
      try {
        Future<String> add(String name) async {
          final added = await backend.control.addSubscription(
            'http://127.0.0.1:${feed.port}/$name',
          );
          final id = added.snapshot.subscriptions.last.id;
          await backend.control.refreshSubscription(
            id,
            challenge: added.warning!.challenge,
          );
          return id;
        }

        final selectedSource = await add('selected');
        final otherSource = await add('other');
        final subscriptions = await backend.control.subscriptions();
        final node = subscriptions.subscriptions
            .firstWhere((s) => s.id == selectedSource)
            .nodes
            .single
            .id;
        await backend.control.selectNode(node);
        final preparedRoutes = catalogList(
          catalogMap(storedCatalog!['committed'])['profiles'],
        );
        final preparations = (await assetRequests.readAsLines()).length;
        stub = null;
        await backend.control.connect();
        final settings = await backend.control.tunnelSettings();
        await checkSocks(
          settings.socksPort,
          target.port,
          whileConnected: () async {
            stub = assetStub;
            await backend.control.refreshSubscription(selectedSource);
            routingName = 'Renamed routing';
            await backend.control.refreshSubscription(otherSource);
            await backend.control.refreshSubscription(selectedSource);
            expect((await assetRequests.readAsLines()).length, preparations);
            final refreshedRoutes = catalogList(
              catalogMap(storedCatalog!['committed'])['profiles'],
            );
            expect(refreshedRoutes.length, 2);
            for (final route in refreshedRoutes) {
              final previous = preparedRoutes.singleWhere(
                (old) => old['id'] == route['id'],
              );
              expect(route['assetRevision'], previous['assetRevision']);
              expect(route['nextGeoRefreshAt'], previous['nextGeoRefreshAt']);
              expect(route['geofileStatus'], 'ready');
            }
            content = jsonEncode({
              'remarks': 'Fixture',
              // Provider hosts still reach the core under routing DNS.
              'dns': {
                'hosts': {'dotless:private-secret.invalid': '192.0.2.1'},
              },
              'outbounds': [
                {
                  'tag': 'proxy',
                  'protocol': 'vless',
                  'settings': {
                    'vnext': [
                      {
                        'address': '127.0.0.1',
                        'port': Uri.parse(profile).port,
                        'users': [
                          {'id': userID, 'encryption': 'none'},
                        ],
                      },
                    ],
                  },
                },
              ],
            });
            await expectLater(
              backend.control.refreshSubscription(selectedSource),
              throwsA(
                isA<PlatformException>().having(
                  (e) => e.code,
                  'code',
                  'invalid_configuration',
                ),
              ),
            );
            expect(await backend.control.state(), 'connected');
            expect(
              (await backend.control.subscriptions()).selectedNodeId,
              node,
            );
          },
        );
      } finally {
        await feed.close(force: true);
      }
    },
  );

  test(
    'subscription approval, provider routing transactions, stable selection and failed refresh',
    () async {
      final route = {
        'Name': 'Provider route',
        'RemoteDNSType': 'DoU',
        'RemoteDNSIP': '1.1.1.1',
        'DomesticDNSType': 'DoU',
        'DomesticDNSIP': '8.8.8.8',
        'DirectSites': ['full:example.com'],
      };
      String directive(CatalogMap value) =>
          'happ://routing/onadd/${base64Encode(utf8.encode(jsonEncode(value)))}';
      var responseBody = '$profile\n${directive(route)}';
      var requests = 0;
      final feed = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      feed.listen((request) async {
        requests++;
        request.response.headers.set('Profile-Title', 'Fixture provider');
        request.response.headers.set(
          'Banner-Text',
          'base64:${base64Encode(utf8.encode('Free provider notice'))}',
        );
        // Unpadded base64url, which Happ-style panels also send.
        request.response.headers.set(
          'Announce',
          'base64:${base64Url.encode(utf8.encode('Провайдер ✓?>!')).replaceAll('=', '')}',
        );
        request.response.headers.set('Banner-Button-Text', 'Open account');
        request.response.headers.set(
          'Banner-Button-Url',
          'https://provider.example/banner?token=synthetic',
        );
        request.response.headers.set('Banner-Bg-Color', '#102030');
        request.response.headers.set('Banner-Button-Color', 'red');
        request.response.headers.set(
          'Subscription-Userinfo',
          'upload=10; download=20; total=100',
        );
        request.response.write(responseBody);
        await request.response.close();
      });
      try {
        final added = await backend.control.addSubscription(
          'http://127.0.0.1:${feed.port}/synthetic-token',
        );
        expect(requests, 0);
        expect(added.warning, isNotNull);
        final id = added.snapshot.subscriptions.single.id;
        final refreshed = await backend.control.refreshSubscription(
          id,
          challenge: added.warning!.challenge,
        );
        expect(requests, 1);
        final group = refreshed.snapshot.subscriptions.single;
        expect(group.name, 'Fixture provider');
        final scheduledSource = catalogList(
          catalogMap(storedCatalog!['committed'])['subscriptions'],
        ).single;
        expect(
          (scheduledSource['nextRefreshAt']! as num) -
              group.lastSuccessfulFetch!,
          inInclusiveRange(4 * 3600 * .9, 4 * 3600 * 1.1),
        );
        await backend.control.updateTunnelSettings(
          (await backend.control.tunnelSettings()).copyWith(
            subscriptionAutoUpdateHours: 12,
          ),
        );
        expect(
          catalogMap(
            catalogMap(storedCatalog!['committed'])['settings'],
          )['subscriptionAutoUpdateHours'],
          12,
        );
        expect(group.metadata['download'], 20);
        expect(group.metadata['bannerText'], 'Free provider notice');
        expect(group.metadata['announcement'], 'Провайдер ✓?>!');
        expect(group.metadata['bannerBackground'], isNull);
        expect(group.metadata['bannerButtonColor'], isNull);
        expect(group.actions, contains('banner'));
        expect(group.metadata.toString(), isNot(contains('token=synthetic')));
        await backend.control.openProviderLink(id, 'banner');
        expect(openedURL, 'https://provider.example/banner?token=synthetic');
        final nodeID = group.nodes.single.id;
        await backend.control.selectNode(nodeID);
        await backend.control.connect();
        var routes = await backend.control.routingProfiles();
        final routeID = routes.profiles.single.id;
        expect(routes.profiles.single.source, 'provider');
        expect(routes.assignments[id], routeID);
        routes = await backend.control.updateRoutingProfile(
          routeID,
          jsonEncode({
            ...route,
            'Name': 'Edited route',
            'BlockIp': ['127.0.0.1/32'],
          }),
        );
        expect(routes.profiles.single.edited, true);
        final ports = await backend.control.tunnelSettings();
        final beforeBlocked = targetRequests;
        await checkHTTPRejected(ports.httpPort, target.port);
        expect(targetRequests, beforeBlocked);
        await backend.control.setRoutingProfileEnabled(routeID, false);
        await checkSocks(ports.socksPort, target.port);
        await backend.control.setRoutingProfileEnabled(routeID, true);
        expect(
          (await backend.control.importRouting(
            'happ://routing/off',
          )).assignments,
          isEmpty,
        );
        await checkSocks(ports.socksPort, target.port);
        responseBody =
            '${profile.replaceFirst('#Fixture', '#Renamed')}\n${directive({...route, 'Name': 'Provider update'})}';
        await backend.control.refreshSubscription(id);
        routes = await backend.control.routingProfiles();
        // The user turned routing off; the provider's directive keeps it off.
        expect(routes.assignments[id], isNull);
        expect(routes.profiles.single.name, 'Edited route');
        routes = await backend.control.resetRoutingProfile(routeID);
        expect(routes.profiles.single.name, 'Provider update');
        expect(routes.profiles.single.edited, false);
        await checkSocks(ports.socksPort, target.port);
        final duplicated = await backend.control.duplicateRoutingProfile(
          routeID,
        );
        final copy = duplicated.profiles.singleWhere(
          (item) => item.id != routeID,
        );
        expect(copy.source, 'local');
        expect(copy.name, 'Provider update copy');
        await backend.control.assignRoutingProfile(id, copy.id);
        final deleted = await backend.control.deleteRoutingProfile(copy.id);
        expect(deleted.assignments, isEmpty);
        await backend.control.assignRoutingProfile(id, routeID);
        expect((await backend.control.subscriptions()).selectedNodeId, nodeID);
        expect(await backend.control.state(), 'connected');
        responseBody = 'synthetic-invalid-secret';
        await expectLater(
          backend.control.refreshSubscription(id),
          throwsA(isA<PlatformException>()),
        );
        final retained =
            (await backend.control.subscriptions()).subscriptions.single;
        expect(retained.nodes.single.id, nodeID);
        expect(retained.nodes.single.name, 'Renamed');
        await checkSocks(
          (await backend.control.tunnelSettings()).socksPort,
          target.port,
        );
        await expectLater(
          backend.control.refreshSubscription(
            id,
            challenge: added.warning!.challenge,
          ),
          throwsA(isA<PlatformException>()),
        );
        expect(
          jsonEncode(catalogMap(storedCatalog!['committed'])['subscriptions']),
          isNot(contains('synthetic-invalid-secret')),
        );
      } finally {
        await feed.close(force: true);
      }
    },
  );

  test('Stop cancels the managed list downloads still to come', () async {
    await backend.dispose();
    backend = createBackend(refreshInterval: const Duration(milliseconds: 50));
    // Each download hangs, as an unreachable list does until its timeout.
    final fetches = File.fromUri(temporary.uri.resolve('managed-fetches'));
    await useStub('''
import json, sys, time
method = json.loads(sys.stdin.readline())['method']
with open(${jsonEncode(fetches.path)}, 'a') as log:
    log.write(method + '\\n')
if method == 'fetchSubscription':
    time.sleep(60)
print(json.dumps({'success': False, 'error': 'connection_failed'}), flush=True)
''');
    int count() => fetches.existsSync()
        ? fetches
              .readAsLinesSync()
              .where((line) => line == 'fetchSubscription')
              .length
        : 0;
    await backend.control.importRouting(
      jsonEncode({
        'Name': 'Managed route',
        'RemoteDNSType': 'DoU',
        'RemoteDNSIP': '1.1.1.1',
        'DomesticDNSType': 'DoU',
        'DomesticDNSIP': '8.8.8.8',
        'ManagedSources': [
          for (final id in ['first', 'second'])
            {
              'id': id,
              'url': 'https://$id.invalid/list',
              'destination': 'proxy',
              'matchMode': 'exact',
            },
        ],
      }),
    );
    for (var i = 0; count() == 0; i++) {
      expect(i, lessThan(100), reason: 'no managed list download started');
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final watch = Stopwatch()..start();
    expect(await backend.control.disconnect(), 'disconnected');
    expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
    expect(count(), 1);
  });

  test(
    'a failed scheduled refresh retries on the subscription schedule',
    () async {
      var now = DateTime.now();
      await backend.dispose();
      backend = createBackend(
        clock: () => now,
        refreshInterval: const Duration(milliseconds: 50),
      );
      var failing = false;
      final feed = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      feed.listen((request) async {
        if (failing) {
          request.response.statusCode = HttpStatus.internalServerError;
        } else {
          request.response.write(profile);
        }
        await request.response.close();
      });
      final failures = StreamController<void>.broadcast();
      backend.control.setImportListener((message) {
        if (message == 'A scheduled subscription or routing refresh failed.')
          failures.add(null);
      });
      try {
        final added = await backend.control.addSubscription(
          'http://127.0.0.1:${feed.port}/feed',
        );
        final id = added.snapshot.subscriptions.single.id;
        await backend.control.refreshSubscription(
          id,
          challenge: added.warning!.challenge,
        );
        failing = true;
        CatalogMap source() => catalogList(
          catalogMap(storedCatalog!['committed'])['subscriptions'],
        ).single;
        // Pass the regular interval, then each retry the catalog schedules.
        var failed = 0;
        for (final (wait, retry) in [(5 * 3600, 60), (61, 300), (301, 1800)]) {
          final attempt = failures.stream.first;
          now = now.add(Duration(seconds: wait));
          await attempt.timeout(
            const Duration(seconds: 10),
            onTimeout: () => fail('No scheduled refresh ${wait}s later'),
          );
          expect(source()['failures'], ++failed);
          expect(
            source()['nextRefreshAt'],
            now.millisecondsSinceEpoch / 1000 + retry,
          );
        }
      } finally {
        backend.control.setImportListener(null);
        await failures.close();
        await feed.close(force: true);
      }
    },
  );

  test('a refresh the user runs ends the scheduled refresh backoff', () async {
    var now = DateTime.now();
    await backend.dispose();
    backend = createBackend(
      clock: () => now,
      refreshInterval: const Duration(milliseconds: 50),
    );
    var failing = false;
    final feed = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    feed.listen((request) async {
      if (failing) {
        request.response.statusCode = HttpStatus.internalServerError;
      } else {
        request.response.write(profile);
      }
      await request.response.close();
    });
    final failures = StreamController<void>.broadcast();
    backend.control.setImportListener((message) {
      if (message == 'A scheduled subscription or routing refresh failed.')
        failures.add(null);
    });
    Future<void> scheduled(int wait) async {
      final attempt = failures.stream.first;
      now = now.add(Duration(seconds: wait));
      await attempt.timeout(
        const Duration(seconds: 10),
        onTimeout: () => fail('No scheduled refresh ${wait}s later'),
      );
    }

    try {
      final added = await backend.control.addSubscription(
        'http://127.0.0.1:${feed.port}/feed',
      );
      final id = added.snapshot.subscriptions.single.id;
      await backend.control.refreshSubscription(
        id,
        challenge: added.warning!.challenge,
      );
      failing = true;
      await scheduled(5 * 3600);
      failing = false;
      await backend.control.refreshSubscription(id);
      failing = true;
      await scheduled(5 * 3600);
      // The catalog counts one failure since the user's refresh, so it retries in 60 s.
      await scheduled(61);
    } finally {
      backend.control.setImportListener(null);
      await failures.close();
      await feed.close(force: true);
    }
  });

  test('a save waits for a scheduled refresh instead of failing busy', () async {
    var now = DateTime.now();
    await backend.dispose();
    backend = createBackend(
      clock: () => now,
      refreshInterval: const Duration(milliseconds: 50),
    );
    var hold = false;
    final requested = Completer<void>(), release = Completer<void>();
    final feed = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    feed.listen((request) async {
      if (hold) {
        if (!requested.isCompleted) requested.complete();
        await release.future;
      }
      request.response.write(profile);
      await request.response.close();
    });
    try {
      final added = await backend.control.addSubscription(
        'http://127.0.0.1:${feed.port}/feed',
      );
      await backend.control.refreshSubscription(
        added.snapshot.subscriptions.single.id,
        challenge: added.warning!.challenge,
      );
      hold = true;
      now = now.add(const Duration(seconds: 5 * 3600));
      await requested.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () => fail('No scheduled refresh started'),
      );
      // The user never started this refresh, so it must not reject their Save.
      final saving = backend.control.updateTunnelSettings(
        (await backend.control.tunnelSettings()).copyWith(
          perAppProcesses: [r'C:\Users\Friend\AppData\Local\Discord\'],
        ),
      );
      release.complete();
      expect((await saving).perAppProcesses, [
        r'C:\Users\Friend\AppData\Local\Discord\',
      ]);
    } finally {
      if (!release.isCompleted) release.complete();
      await feed.close(force: true);
    }
  });
}
