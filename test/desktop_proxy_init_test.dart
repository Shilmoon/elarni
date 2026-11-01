import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:elarni/desktop_catalog.dart';
import 'package:elarni/desktop_proxy.dart';
import 'package:elarni/tunnel_channel.dart';

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
