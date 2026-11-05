import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:elarni/desktop_catalog.dart';
import 'package:elarni/desktop_proxy.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The fixtures select no node, so a Connect that gets past the controller's
  // busy gate stops at invalid_profile.
  final pastTheGate = throwsA(
    isA<PlatformException>().having((e) => e.code, 'code', 'invalid_profile'),
  );
  Future<Process> noCore(String _) =>
      Future.error(const ProcessException('unused-core', []));

  test(
    'connect in the window after stop reports disconnected follows the stop',
    () async {
      final saving = Completer<void>(), release = Completer<void>();
      final proxy = DesktopProxy(
        corePath: 'unused-core',
        domainPath: 'unused-domain',
        startProcess: noCore,
        catalogIO: (method, _) async {
          if (method == 'loadCatalog')
            return {
              'revision': '1',
              'catalog': {
                'version': 1,
                'committed': {
                  ...DesktopCatalog.empty(),
                  'connectionIntent': true,
                },
              },
            };
          if (method == 'saveCatalog' && !saving.isCompleted) {
            saving.complete();
            await release.future;
          }
          return {'revision': '2'};
        },
        platformIO: (_, _) async => {},
      );
      addTearDown(proxy.dispose);
      await proxy.request('state');
      final stop = proxy.request('disconnect');
      // Stop now saves the cleared intent after publishing its state.
      await saving.future;
      expect(await proxy.request('state'), {'state': 'disconnected'});
      final connect = proxy.request('connect');
      release.complete();
      expect(await stop, {'state': 'disconnected'});
      await expectLater(connect, pastTheGate);
    },
  );

  test(
    'stop during the connect intent save is not undone at restart',
    () async {
      final saving = Completer<void>(), release = Completer<void>();
      CatalogMap stored = {'version': 1, 'committed': DesktopCatalog.empty()};
      final proxy = DesktopProxy(
        corePath: 'unused-core',
        domainPath: 'unused-domain',
        startProcess: noCore,
        catalogIO: (method, payload) async {
          if (method == 'loadCatalog')
            return {'revision': '1', 'catalog': copyCatalog(stored)};
          if (method != 'saveCatalog') return {};
          if (!saving.isCompleted) {
            saving.complete();
            await release.future;
          }
          stored = copyCatalog(catalogMap(payload['catalog']));
          return {'revision': '2'};
        },
        platformIO: (_, _) async => {},
      );
      addTearDown(proxy.dispose);
      await proxy.request('state');
      final connect = proxy.request('connect');
      // Connect is saving its intent when Stop arrives.
      await saving.future;
      final stop = proxy.request('disconnect');
      release.complete();
      await expectLater(
        connect,
        throwsA(
          isA<PlatformException>().having((e) => e.code, 'code', 'cancelled'),
        ),
      );
      expect(await stop, {'state': 'disconnected'});
      // The next start reads this intent and would reconnect by itself.
      expect(catalogMap(stored['committed'])['connectionIntent'], isFalse);
    },
  );

  // A selected server whose core never starts; the stale-guard check opens
  // every connect on Windows and Linux, so it counts connect attempts.
  Future<({DesktopProxy proxy, List<double> connects, List<CatalogMap> saves})>
  withServer() async {
    final catalog = DesktopCatalog(
      DesktopCatalog.empty(),
      (_, _) async => {},
      (_, _) => {},
    );
    catalog.putSource({
      'id': 'source',
      'name': 'source',
      'format': 'source',
      'status': 'ready',
      'nodes': [
        {'id': 'node', 'name': 'node', 'format': 'xrayProfile', 'config': {}},
      ],
    });
    catalog.data['selectedNodeId'] = 'node';
    catalog.data['connectionIntent'] = true;
    final clock = Stopwatch()..start(), connects = <double>[];
    final saves = <CatalogMap>[];
    final proxy = DesktopProxy(
      corePath: 'unused-core',
      domainPath: 'unused-domain',
      startProcess: noCore,
      catalogIO: (method, payload) async {
        if (method == 'loadCatalog')
          return {
            'revision': '1',
            'catalog': {'version': 1, 'committed': copyCatalog(catalog.data)},
          };
        if (method == 'saveCatalog')
          saves.add(catalogMap(catalogMap(payload['catalog'])['committed']));
        if (method == 'staleVPNGuard') {
          connects.add(clock.elapsedMilliseconds / 1000);
          return {'stale': false};
        }
        return {'revision': '2'};
      },
      platformIO: (_, _) async => {},
    );
    addTearDown(proxy.dispose);
    await proxy.request('state');
    return (proxy: proxy, connects: connects, saves: saves);
  }

  // Decision D1: the default settings (no failover, On Demand off) retry the
  // selected server while the user wants to be connected; Stop ends it.
  test(
    'a saved intent reconnects the selected server with backoff by default',
    () async {
      final (:proxy, :connects, :saves) = await withServer();
      expect(connects, hasLength(1), reason: 'the launch checks the guard');
      final before = saves.length;
      // The first retry waits a second after the 1 Hz tick sees the drop;
      // windows_automation_test checks the rest of the backoff.
      for (var i = 0; i < 500 && connects.length < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(connects, hasLength(2));
      expect(connects[1] - connects[0], greaterThan(0.9));
      var status = await proxy.request('automationStatus');
      for (var i = 0; i < 100 && status['pendingRetry'] != true; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        status = await proxy.request('automationStatus');
      }
      expect(status['attempts'], 1);
      expect(
        status['pendingRetry'],
        true,
        reason: 'the failed retry is again due',
      );
      // The episode's start is saved, not each attempt (a full catalog write).
      expect(saves.skip(before).map((saved) => saved['automationEpisode']), [
        {'attempts': 0, 'exhausted': false, 'interrupted': true},
      ]);
      await proxy.request('disconnect');
      expect((await proxy.request('automationStatus'))['pendingRetry'], false);
    },
    skip: !Platform.isWindows && !Platform.isLinux,
  );

  // A bulk test of failing servers reloaded the whole window once per server.
  test('a failed probe does not reload the window', () async {
    final (:proxy, connects: _, saves: _) = await withServer();
    await proxy.request('disconnect');
    var reloads = 0;
    proxy.control.setImportListener((_) => reloads++);
    await expectLater(
      proxy.request('pingNode', {
        'nodeId': 'node',
        'protocol': 'proxy',
        'timeout': 5,
        'url': 'https://example.test/check',
        'method': 'GET',
        'mode': 'default',
      }),
      throwsA(
        isA<PlatformException>().having((e) => e.code, 'code', 'ping_failed'),
      ),
    );
    expect(reloads, 0);
  });

  test('connect queues behind a refresh that holds the controller', () async {
    final catalog = DesktopCatalog(
      DesktopCatalog.empty(),
      (_, _) async => {},
      (_, _) => {},
    );
    final source = catalog.addSource('https://example.test/subscription');
    final fetching = Completer<void>(), fetch = Completer<Process>();
    var refreshing = false;
    final proxy = DesktopProxy(
      corePath: 'unused-core',
      domainPath: 'unused-domain',
      startProcess: (path) {
        if (!refreshing || fetching.isCompleted) return noCore(path);
        fetching.complete();
        return fetch.future;
      },
      catalogIO: (method, _) async => method == 'loadCatalog'
          ? {
              'revision': '1',
              'catalog': {'version': 1, 'committed': catalog.data},
            }
          : {'revision': '2'},
      platformIO: (_, _) async => {},
    );
    addTearDown(proxy.dispose);
    await proxy.request('state');
    refreshing = true;
    // A scheduled refresh does the same between the CLI's stop and connect.
    final refresh = proxy.request('refreshSubscription', {'id': source});
    await fetching.future;
    expect(await proxy.request('state'), {'state': 'disconnected'});
    // Two clients' Connects wake together; neither may lose the hand-off.
    final connects = [proxy.request('connect'), proxy.request('connect')];
    fetch.completeError(const ProcessException('unused-core', []));
    await expectLater(refresh, throwsA(anything));
    for (final connect in connects) await expectLater(connect, pastTheGate);
  });
}
