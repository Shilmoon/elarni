import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:elarni/desktop_catalog.dart';
import 'package:elarni/desktop_proxy.dart';
import 'package:elarni/tunnel_channel.dart';
import 'package:elarni/wifi_network.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<Process> noCore(String _) =>
      Future.error(const ProcessException('unused-core', []));

  // A selected server whose core never starts: a Connect shows as the
  // connection intent it saves before starting one. Saving settings needs the
  // native library, so they start stored; windows_proxy_integration saves them.
  Future<({DesktopProxy proxy, List<bool> intents})> start(
    WiFiReading Function() network, {
    TunnelSettings settings = const TunnelSettings(
      connectOnUntrustedWiFi: true,
      trustedWiFiNetworks: ['Home'],
    ),
  }) async {
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
    catalog.data['settings'] = settings.toMap();
    final intents = <bool>[];
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
          intents.add(
            catalogMap(
                  catalogMap(payload['catalog'])['committed'],
                )['connectionIntent'] ==
                true,
          );
        return {'revision': '2'};
      },
      platformIO: (_, _) async => {},
      wifiNetwork: () async => network(),
      wifiInterval: const Duration(milliseconds: 20),
    );
    addTearDown(proxy.dispose);
    await proxy.request('state');
    return (proxy: proxy, intents: intents);
  }

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 200));
  Future<void> until(bool Function() condition) async {
    for (var i = 0; i < 200 && !condition(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(condition(), isTrue);
  }

  test('joining an untrusted Wi-Fi network connects once per join', () async {
    WiFiReading network = (name: 'Home', denied: false);
    final (:proxy, :intents) = await start(() => network);
    await settle();
    expect(intents, isNot(contains(true)), reason: 'Home is trusted');
    network = (name: 'Cafe', denied: false);
    await until(() => intents.isNotEmpty && intents.last);
    await proxy.request('disconnect');
    expect(intents.last, isFalse);
    await settle();
    expect(intents.last, isFalse, reason: 'Stop holds until the next network');
    network = (name: 'Home', denied: false);
    await settle();
    expect(intents.last, isFalse, reason: 'Trusted networks stay as they are');
    // Wired and mobile connections have no Wi-Fi name.
    network = (name: null, denied: false);
    await settle();
    expect(intents.last, isFalse);
    network = (name: 'Cafe', denied: false);
    await until(() => intents.last);
  });

  test('the rule is off unless the user turns it on', () async {
    var reads = 0;
    final (proxy: _, :intents) = await start(() {
      reads++;
      return (name: 'Cafe', denied: false);
    }, settings: const TunnelSettings());
    await settle();
    expect(intents, isNot(contains(true)));
    // Windows may ask for location access on the first read.
    expect(reads, 0, reason: 'Off, Elarni never reads the Wi-Fi name');
  });

  test('a Wi-Fi name Windows keeps from Elarni is reported', () async {
    final (:proxy, :intents) = await start(() => (name: null, denied: true));
    var status = <String, Object?>{};
    await until(() {
      unawaited(proxy.request('automationStatus').then((s) => status = s));
      return status['wifi'] == 'locationDenied';
    });
    expect(intents, isNot(contains(true)));
  });

  test('trusted Wi-Fi names keep to Wi-Fi limits', () {
    bool valid(List<String> names) =>
        TunnelSettings(trustedWiFiNetworks: names).validTrustedWiFi;
    for (final names in [
      ['x' * 33],
      ['\u00e9' * 17],
      ['tab\there'],
      [''],
      [for (var i = 0; i < 65; i++) 'n$i'],
    ]) {
      expect(valid(names), isFalse, reason: '$names');
    }
    expect(
      valid(['x' * 32, 'Caf\u00e9 5G', for (var i = 0; i < 62; i++) 'n$i']),
      isTrue,
    );
    final saved = TunnelSettings.fromMap(
      const TunnelSettings(
        connectOnUntrustedWiFi: true,
        trustedWiFiNetworks: ['Home'],
      ).toMap(),
    );
    expect(saved.connectOnUntrustedWiFi, isTrue);
    expect(saved.trustedWiFiNetworks, ['Home']);
  });

  test('Linux reads the Wi-Fi name from nmcli or iw', () {
    expect(nmcliWiFi('no:Neighbour\nyes:Caf\\:e \\\\ 5G\n'), 'Caf:e \\ 5G');
    expect(nmcliWiFi('no:Neighbour\n'), isNull);
    expect(
      iwWiFi(
        'Connected to 00:11:22:33:44:55 (on wlan0)\n'
        '\tSSID: Caf\\xc3\\xa9 net\n\tfreq: 2412\n',
      ),
      'Caf\u00e9 net',
    );
    expect(iwWiFi('Not connected.\n'), isNull);
  });

  test(
    "this desktop's Wi-Fi reader answers",
    () async {
      final reading = await readWiFiNetwork();
      expect(reading.name == null || reading.name!.isNotEmpty, isTrue);
    },
    skip: !Platform.isWindows && !Platform.isLinux,
  );
}
