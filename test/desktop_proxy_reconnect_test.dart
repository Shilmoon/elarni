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
