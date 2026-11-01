// Explicit real-Windows acceptance; run elevated with synthetic routes only.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:elarni/desktop_proxy.dart';
import 'package:elarni/desktop_catalog.dart';
import 'windows_proxy_integration.dart' as fixture;

void main() {
  test(
    'per-app TUN routing, repair and the VPN service preserve TCP UDP IPv4 IPv6 behavior',
    () async {
      expect(Platform.isWindows, isTrue);
      final bundle =
          '${Directory.current.path}/build/windows/x64/runner/Release';
      final core = '$bundle/elarni-core.exe';
      await fixture.guardUserAssets();
      final cache = await Directory.systemTemp.createTemp('elarni-vpn-cache-');
      addTearDown(() => cache.delete(recursive: true));
      // The fake catalog names no routing assets, so the core retires all it finds.
      final environment = {'LOCALAPPDATA': cache.path};
      final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      target.listen((request) async {
        request.response.write(fixture.body);
        await request.response.close();
      });
      addTearDown(() => target.close(force: true));
      final udp = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      udp.listen((event) {
        if (event == RawSocketEvent.read) {
          final packet = udp.receive();
          if (packet != null)
            udp.send(packet.data, packet.address, packet.port);
        }
      });
      addTearDown(udp.close);
      final upstreamPort = await fixture.freePort();
      // A SOCKS5 proxy on this machine for a per-app proxy target.
      final localProxyPort = await fixture.freePort();
      final upstream = await Process.start(core, [], environment: environment);
      unawaited(upstream.stderr.drain<void>());
      addTearDown(() async {
        await upstream.stdin.close();
        await upstream.exitCode.timeout(const Duration(seconds: 10));
      });
      // A broadcast copy keeps reading: the core streams log events after its
      // reply and exits when it cannot write them.
      final ready = upstream.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .asBroadcastStream()
          .first;
      Map<String, Object?> inbound(String listen) => {
        'listen': listen,
        'port': upstreamPort,
        'protocol': 'vless',
        'settings': {
          'clients': [
            {'id': fixture.userID},
          ],
          'decryption': 'none',
        },
      };
      Map<String, Object?> outbound(String tag, int port) => {
        'tag': tag,
        'protocol': 'freedom',
        'settings': {
          'redirect': '127.0.0.1:$port',
          'finalRules': [
            {
              'action': 'allow',
              'ip': ['127.0.0.1/32'],
            },
          ],
        },
      };
      upstream.stdin.writeln(
        jsonEncode({
          'apiVersion': 1,
          'method': 'runXrayFromJson',
          'payload': {
            'configJSON': jsonEncode({
              'log': {'loglevel': 'none'},
              // localhost resolves to ::1 first.
              'inbounds': [
                inbound('127.0.0.1'),
                inbound('::1'),
                {
                  'listen': '127.0.0.1',
                  'port': localProxyPort,
                  'protocol': 'socks',
                  'settings': {'udp': true},
                },
              ],
              'outbounds': [
                outbound('tcp', target.port),
                outbound('udp', udp.port),
              ],
              'routing': {
                'rules': [
                  {'type': 'field', 'network': 'udp', 'outboundTag': 'udp'},
                ],
              },
            }),
          },
        }),
      );
      await upstream.stdin.flush();
      expect(
        jsonDecode(await ready.timeout(const Duration(seconds: 10)))['success'],
        isTrue,
      );
      CatalogMap? document;
      var revision = 0;
      final children = <Process>[];
      final backend = DesktopProxy(
        corePath: core,
        domainPath: '$bundle/elarni_domain.dll',
        platformIO: (_, _) async => {},
        catalogIO: (method, args) async {
          if (method == 'staleVPNGuard') return {'stale': false};
          if (method == 'loadCatalog')
            return {'revision': '$revision', 'catalog': document};
          expect(args['revision'], '$revision');
          document = copyCatalog(catalogMap(args['catalog']));
          return {'revision': '${++revision}'};
        },
        startProcess: (path) async {
          final process = await Process.start(
            path,
            [],
            environment: environment,
          );
          children.add(process);
          return process;
        },
      );
      addTearDown(backend.dispose);
      var settings = (await backend.control.tunnelSettings()).copyWith(
        socksPort: await fixture.freePort(),
        includedRoutes: ['198.18.77.2/32', '2001:db8:77::2/128'],
      );
      await backend.control.updateTunnelSettings(settings);
      final imported = await backend.control.importClientProfiles(
        content:
            'vless://${fixture.userID}@127.0.0.1:$upstreamPort?encryption=none&security=none&type=tcp#PerAppFixture',
      );
      final id = imported.snapshot.subscriptions.single.nodes.single.id;
      await backend.control.selectNode(id);

      Future<void> traffic(bool expected) async {
        for (final host in ['198.18.77.2', '2001:db8:77::2']) {
          final client = HttpClient()
            ..connectionTimeout = const Duration(seconds: 2)
            ..findProxy = (_) => 'DIRECT';
          var received = false;
          try {
            final request = await client.getUrl(
              Uri(
                scheme: 'http',
                host: host,
                port: target.port,
                path: '/fixture',
              ),
            );
            final response = await request.close().timeout(
              const Duration(seconds: 2),
            );
            received =
                response.statusCode == 200 &&
                await response.transform(utf8.decoder).join() == fixture.body;
          } on SocketException {
          } on HttpException {
          } on TimeoutException {
          } finally {
            client.close(force: true);
          }
          expect(
            received,
            expected,
            reason:
                'TCP $host ${settings.perAppMode} ${settings.perAppProcesses} ${settings.perAppTargets}',
          );
          final address = InternetAddress(host);
          final socket = await RawDatagramSocket.bind(
            address.type == InternetAddressType.IPv6
                ? InternetAddress.anyIPv6
                : InternetAddress.anyIPv4,
            0,
          );
          final reply = Completer<List<int>>();
          final listener = socket.listen(
            (event) {
              if (event == RawSocketEvent.read) {
                final packet = socket.receive();
                if (packet != null && !reply.isCompleted)
                  reply.complete(packet.data);
              }
            },
            onError: (Object _) {
              if (!reply.isCompleted) reply.complete([]);
            },
          );
          try {
            final bytes = utf8.encode(fixture.body);
            socket.send(bytes, address, udp.port);
            expect(
              await reply.future.timeout(
                const Duration(seconds: 2),
                onTimeout: () => [],
              ),
              expected ? bytes : isEmpty,
              reason:
                  'UDP $host ${settings.perAppMode} ${settings.perAppProcesses} ${settings.perAppTargets}',
            );
          } finally {
            socket.close();
            await listener.cancel();
          }
        }
      }

      expect(await backend.control.connect(), 'connected');
      final owner = children.last;
      var ownerExited = false;
      unawaited(owner.exitCode.then((_) => ownerExited = true));
      await traffic(true);
      // The elevated helper runs this core; its lines reach the app through the pipe, redacted.
      var logs = await backend.control.readLogs();
      for (var attempt = 0; attempt < 50; attempt++) {
        if ((logs['entries']! as List).any(
          (line) => '${(line as Map)['text']}'.endsWith(' started'),
        )) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
        logs = await backend.control.readLogs();
      }
      expect([
        for (final line in logs['entries']! as List) (line as Map)['text'],
      ], contains(endsWith(' started')));
      expect(jsonEncode(logs), isNot(contains(fixture.userID)));
      // The VPN blocks DNS outside the tunnel, where latency tests of other
      // servers run, so their hostnames must not be resolved there.
      final hostname = await backend.control.importClientProfiles(
        content:
            'vless://${fixture.userID}@localhost:$upstreamPort?encryption=none&security=none&type=tcp#HostnameFixture',
      );
      printOnFailure('Reached: hostname server latency test');
      // Local imports share one source, so it also holds the first fixture.
      final other = hostname.snapshot.subscriptions.last.nodes
          .singleWhere((node) => node.name == 'HostnameFixture')
          .id;
      final latency = await backend.control.pingNode(
        other,
        protocol: 'proxy',
        method: 'GET',
        mode: 'default',
        timeout: 5,
        url: 'http://198.18.77.2:${target.port}/fixture',
        expectedStatus: 200,
        expectedBody: fixture.body,
      );
      expect(latency.status, 'success');
      final executable = Platform.resolvedExecutable;
      for (final testCase in [
        ('proxyOnly', executable, true),
        ('proxyOnly', executable.toUpperCase(), true),
        ('proxyOnly', '${File(executable).parent.path.toUpperCase()}/', true),
        ('proxyOnly', 'elarni-unmatched-fixture.exe', false),
        ('bypass', executable.split(Platform.pathSeparator).last, false),
        (
          'bypass',
          executable.split(Platform.pathSeparator).last.toUpperCase(),
          false,
        ),
        ('bypass', 'elarni-unmatched-fixture.exe', true),
      ]) {
        settings = settings.copyWith(
          perAppMode: testCase.$1,
          perAppProcesses: [testCase.$2],
        );
        await backend.control.updateTunnelSettings(settings);
        await traffic(testCase.$3);
        if (testCase.$1 == 'proxyOnly') {
          // Failover health must test the proxy even when Elarni is unlisted.
          printOnFailure('Reached: Only-listed health check ${testCase.$2}');
          final health = await backend.control.pingNode(
            id,
            protocol: 'activeProxy',
            method: 'GET',
            mode: 'default',
            timeout: 5,
            url: 'http://198.18.77.2:${target.port}/fixture',
            expectedStatus: 200,
            expectedBody: fixture.body,
          );
          expect(health.status, 'success', reason: 'health ${testCase.$2}');
        }
      }
      // A listed app's own target overrides its mode: another server, a local
      // proxy and Follow routing reach the targets; Direct and Block do not.
      for (final testCase in [
        ('proxyOnly', 'direct', false),
        ('proxyOnly', 'block', false),
        ('bypass', 'routing', true),
        ('bypass', 'node:$other', true),
        ('bypass', 'proxy:socks5://127.0.0.1:$localProxyPort', true),
      ]) {
        settings = settings.copyWith(
          perAppMode: testCase.$1,
          perAppProcesses: [executable],
          perAppTargets: {executable: testCase.$2},
        );
        await backend.control.updateTunnelSettings(settings);
        await traffic(testCase.$3);
      }
      settings = settings.copyWith(
        perAppMode: 'bypass',
        perAppProcesses: ['elarni-unmatched-fixture.exe'],
        perAppTargets: const {},
      );
      await backend.control.updateTunnelSettings(settings);
      expect(ownerExited, isFalse);
      await backend.control.repairTunnel();
      expect(await backend.control.state(), 'disconnected');
      expect(await owner.exitCode.timeout(const Duration(seconds: 10)), 0);
      expect((await backend.control.subscriptions()).selectedNodeId, id);
      expect(await backend.control.connect(), 'connected');
      expect(children.last.pid, isNot(owner.pid));
      await traffic(true);
      // Through the VPN service the helper runs as SYSTEM in session 0, with no
      // prompt, and still names its adapter after this session.
      final account =
          '${(await Process.run('whoami', ['/user', '/fo', 'csv', '/nh'])).stdout}'
              .trim()
              .split(',')
              .last
              .replaceAll('"', '');
      Future<int> vpnService(String change) async => (await Process.run(core, [
        '--vpn-service',
        change,
        account,
      ])).exitCode;
      addTearDown(() => vpnService('remove'));
      Future<String> powershell(String command) async =>
          '${(await Process.run('powershell', ['-NoProfile', '-NonInteractive', '-Command', command])).stdout}'
              .trim();
      await backend.control.repairTunnel();
      expect(await vpnService('add'), 0);
      expect((await backend.control.systemInfo())['vpnService'], isTrue);
      expect(await backend.control.connect(), 'connected');
      var helpers = <Object?>[];
      for (var attempt = 0; attempt < 50; attempt++) {
        // The previous broker's helper exits once it sees that broker gone.
        helpers =
            jsonDecode(
                  await powershell(
                    // The SID, not the account name, which Windows localizes.
                    r"ConvertTo-Json -Compress -InputObject @(Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'elarni-core.exe' -and $_.CommandLine -like '*--vpn-child*' } | ForEach-Object { [pscustomobject]@{ session = $_.SessionId; owner = (Invoke-CimMethod -InputObject $_ -MethodName GetOwnerSid).Sid } })",
                  ),
                )
                as List;
        if (helpers.length == 1) break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(helpers, [
        {'session': 0, 'owner': 'S-1-5-18'},
      ]);
      final session = await powershell('(Get-Process -Id $pid).SessionId');
      expect(
        await powershell("(Get-NetAdapter -Name 'elarni-tun-$session').Status"),
        'Up',
      );
      await traffic(true);
      final replacement = children.last;
      await backend.dispose();
      expect(
        await replacement.exitCode.timeout(const Duration(seconds: 10)),
        0,
      );
      // Turning it off for the last allowed account deletes the service.
      expect(await vpnService('remove'), 0);
      expect(
        (await Process.run('sc.exe', ['query', 'ElarniVPN'])).exitCode,
        1060,
      );
    },
    timeout: const Timeout(Duration(seconds: 300)),
  );
}
