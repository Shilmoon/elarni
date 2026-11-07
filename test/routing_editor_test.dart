import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:elarni/routing_editor.dart';

Map<String, Object?> profile() => {
  'Name': 'Fixture',
  'RemoteDNSType': 'DoU',
  'RemoteDNSIP': '1.1.1.1',
  'DomesticDNSType': 'DoU',
  'DomesticDNSIP': '8.8.8.8',
};

Future<void> openEditor(
  WidgetTester tester,
  Map<String, Object?> value,
  void Function(String?) saved,
) async {
  await tester.binding.setSurfaceSize(const Size(1100, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async => saved(
              await showDialog<String>(
                context: context,
                builder: (_) => RoutingEditor(json: jsonEncode(value)),
              ),
            ),
            child: const Text('Open editor'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open editor'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'saving normalizes aliases and duplicates while preserving routing metadata',
    (tester) async {
      final value = profile()..remove('RemoteDNSIP');
      value.addAll({
        'RemoteDNSIp': '9.9.9.9',
        'FakeDns': 'true',
        'UseChunkFiles': true,
        'GeoipUrl': 'https://example.com/geoip.dat',
        'DnsHosts': {'example.com': '192.0.2.1'},
        'DirectIp': ['192.0.2.0/24', '192.0.2.0/24', '2001:db8::/32'],
      });
      String? saved;
      await openEditor(tester, value, (result) => saved = result);
      await tester.tap(find.text('Validate and save'));
      await tester.pumpAndSettle();
      final result = jsonDecode(saved!) as Map;
      expect(result['RemoteDNSIP'], '9.9.9.9');
      expect(result['FakeDNS'], 'true');
      expect(result.containsKey('RemoteDNSIp'), isFalse);
      expect(result.containsKey('FakeDns'), isFalse);
      expect(result.containsKey('DomesticDNSDomains'), isFalse);
      expect(result['DirectIp'], ['192.0.2.0/24', '2001:db8::/32']);
      expect(result['UseChunkFiles'], isTrue);
      expect(result['GeoipUrl'], 'https://example.com/geoip.dat');
      expect(result['DnsHosts'], {'example.com': '192.0.2.1'});
    },
  );

  testWidgets(
    'the Russian sites preset adds its domains to Direct after the user\'s own, once',
    (tester) async {
      String? saved;
      await openEditor(
        tester,
        profile()..['DirectSites'] = ['example.com', 'domain:ru'],
        (result) => saved = result,
      );
      for (var i = 0; i < 2; i++) {
        await tester.tap(find.byKey(const Key('routing-preset:Direct')));
        await tester.pumpAndSettle();
        expect(
          find.text(".ru, .рф, .su and these services' other domains"),
          findsOneWidget,
        );
        await tester.tap(find.text('Russian sites direct'));
        await tester.pumpAndSettle();
      }
      final expected = ['example.com', ...russianSitesPreset];
      expect(russianSitesPreset.take(3), [
        'domain:ru',
        'domain:xn--p1ai',
        'domain:su',
      ]);
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('routing-field:DirectSites')),
      );
      expect(field.controller!.text.split('\n'), expected);
      await tester.tap(find.text('Validate and save'));
      await tester.pumpAndSettle();
      expect((jsonDecode(saved!) as Map)['DirectSites'], expected);
    },
  );

  // The compiler (native/elarni-domain) rejects every target below.
  for (final target in [
    '192.0.2.1/33',
    '2001:db8::/129',
    '192.0.2.1/-1',
    '192.0.2.1/24/1',
    '192.0.2.1/-0',
    '192.0.2.1/0x20',
    '192.0.2.01',
    'fe80::1%1',
    '!',
    '!not-an-ip',
    '!192.0.2.1/33',
    'geosite:cn',
    'GEOIP:cn',
    'geoip:x${'\u00e9' * 253}',
  ]) {
    final name = target.length > 32
        ? 'of ${utf8.encode(target).length} bytes'
        : target;
    testWidgets('invalid IP target $name keeps the editor open', (
      tester,
    ) async {
      String? saved;
      await openEditor(
        tester,
        profile()..['DirectIp'] = [target],
        (value) => saved = value,
      );
      await tester.tap(find.text('Validate and save'));
      await tester.pumpAndSettle();
      expect(saved, isNull);
      expect(
        find.textContaining('DirectIp needs IP addresses'),
        findsOneWidget,
      );
    });
  }

  testWidgets('boundary IP targets and explicit DNS domains survive a save', (
    tester,
  ) async {
    String? saved;
    final value = profile()
      ..addAll({
        // The compiler accepts every target below.
        'DirectIp': [
          '0.0.0.0/0',
          '192.0.2.1/32',
          '::/0',
          '2001:db8::1/128',
          '::ffff:192.0.2.1',
          '192.0.2.0/+24',
          '!192.0.2.2',
          '!!2001:db8::/32',
          '!geoip:cn',
          'geoip:!cn',
          'ext:lists/geoip.dat:cn',
          'ext-ip:geoip.dat:private',
          '!ext-ip:geoip.dat:private',
          'geoip:${'\u00e9' * 253}',
        ],
        'DomesticDNSDomains': ['full:example.cn', 'full:example.cn'],
      });
    await openEditor(tester, value, (result) => saved = result);
    await tester.tap(find.text('Validate and save'));
    await tester.pumpAndSettle();
    final result = jsonDecode(saved!) as Map;
    expect(result['DirectIp'], value['DirectIp']);
    expect(result['DomesticDNSDomains'], ['full:example.cn']);
  });

  for (final url in [
    'http://resolver.example/dns-query',
    'https://user:pass@resolver.example/dns-query',
    'https://resolver.example/dns-query#fragment',
  ]) {
    testWidgets('unsafe DoH URL $url is rejected', (tester) async {
      String? saved;
      await openEditor(
        tester,
        profile()..addAll({'RemoteDNSType': 'DoH', 'RemoteDNSDomain': url}),
        (result) => saved = result,
      );
      await tester.tap(find.text('Validate and save'));
      await tester.pumpAndSettle();
      expect(saved, isNull);
      expect(
        find.textContaining('Remote DNS needs an HTTPS URL'),
        findsOneWidget,
      );
    });
  }

  // The compiler reads a legacy RemoteDns or DomesticDns when the current key is
  // empty, so a cleared bootstrap IP would come back.
  testWidgets('a cleared legacy bootstrap IP stays cleared', (tester) async {
    String? saved;
    await openEditor(
      tester,
      profile()
        ..remove('RemoteDNSIP')
        ..remove('DomesticDNSIP')
        ..addAll({
          'RemoteDNSType': 'DoH',
          'RemoteDNSDomain': 'https://resolver.example/dns-query',
          'RemoteDns': '9.9.9.9',
          'DomesticDns': '8.8.8.8',
        }),
      (result) => saved = result,
    );
    await tester.tap(find.text('DNS'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('routing-field:RemoteDNSIP')),
      '',
    );
    await tester.tap(find.text('Validate and save'));
    await tester.pumpAndSettle();
    final result = jsonDecode(saved!) as Map;
    expect(result['RemoteDNSIP'], '');
    expect(result['DomesticDNSIP'], '8.8.8.8');
    expect(result.containsKey('RemoteDns'), isFalse);
    expect(result.containsKey('DomesticDns'), isFalse);
  });

  // The native validator accepts DoH without a bootstrap IP (the proxy resolves
  // the resolver's name) and refuses scoped addresses on every platform.
  testWidgets('DoH saves without a bootstrap IP', (tester) async {
    String? saved;
    await openEditor(
      tester,
      profile()..addAll({
        'RemoteDNSType': 'DoH',
        'RemoteDNSDomain': 'https://resolver.example/dns-query',
        'RemoteDNSIP': '',
      }),
      (result) => saved = result,
    );
    await tester.tap(find.text('Validate and save'));
    await tester.pumpAndSettle();
    expect((jsonDecode(saved!) as Map)['RemoteDNSIP'], '');
  });

  for (final (type, ip) in [
    ('DoU', ''),
    ('DoU', 'fe80::1%1'),
    ('DoH', 'fe80::1%1'),
  ]) {
    testWidgets('$type resolver IP "$ip" keeps the editor open', (
      tester,
    ) async {
      String? saved;
      await openEditor(
        tester,
        profile()..addAll({
          'RemoteDNSType': type,
          'RemoteDNSDomain': 'https://resolver.example/dns-query',
          'RemoteDNSIP': ip,
        }),
        (result) => saved = result,
      );
      await tester.tap(find.text('Validate and save'));
      await tester.pumpAndSettle();
      expect(saved, isNull);
      expect(find.textContaining('Remote DNS needs'), findsOneWidget);
    });
  }

  // An expanded section stored its open state under its PageStorageKey, which the text fields inside
  // also resolved to: their scroll position read the bool as an offset and each field became a grey
  // error box (Direct DNS on Windows, 2026-11-08). Collapsed sections must open with working fields.
  testWidgets('sections opened or reopened keep their text fields', (
    tester,
  ) async {
    await openEditor(
      tester,
      profile()..addAll({
        'RemoteDNSType': 'DoH',
        'RemoteDNSDomain': 'https://8.8.8.8/dns-query',
        'DomesticDNSType': 'DoH',
        'DomesticDNSDomain': 'https://77.88.8.8/dns-query',
        'ProxySites': ['geosite:youtube'],
        'BlockSites': ['geosite:category-ads'],
      }),
      (_) {},
    );
    Future<void> toggle(String title) async {
      await tester.ensureVisible(find.text(title));
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
    }

    for (final title in ['Proxy rules', 'Block rules']) {
      await toggle(title);
    }
    expect(find.text('geosite:youtube'), findsOneWidget);
    expect(find.text('geosite:category-ads'), findsOneWidget);
    await tester.tap(find.text('DNS'));
    await tester.pumpAndSettle();
    await toggle('Direct DNS');
    await toggle('Choose DNS by domain');
    await toggle('Remote DNS'); // collapse and reopen one that started open
    await toggle('Remote DNS');
    expect(find.text('https://77.88.8.8/dns-query'), findsOneWidget);
    expect(find.text('https://8.8.8.8/dns-query'), findsOneWidget);
    expect(find.byType(ErrorWidget), findsNothing);
  });
}
