import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:elarni/desktop_automation.dart';
import 'package:elarni/desktop_catalog.dart';
import 'package:elarni/tunnel_channel.dart';

void main() {
  test('a new catalog requires a generated login for its local listeners', () {
    final first = DesktopCatalog.empty(), second = DesktopCatalog.empty();
    final catalog = DesktopCatalog(
      first,
      (method, payload) async => throw StateError(method),
      (operation, payload) => throw StateError(operation),
    )..validate();
    expect(catalog.settings.inboundAuthEnabled, isTrue);
    expect(catalog.settings.inboundCredentialsConfigured, isTrue);
    final login = catalogMap(first['inboundCredentials']);
    expect(login['username'], matches(RegExp(r'^[0-9a-f]{32}$')));
    expect(login['password'], matches(RegExp(r'^[0-9a-f]{32}$')));
    expect(second['inboundCredentials'], isNot(login));
    // Installs from before keep their listeners as they were.
    final upgraded = DesktopCatalog.empty()
      ..remove('inboundCredentials')
      ..['settings'] = const TunnelSettings(xrayTunEnabled: true).toMap();
    final kept = DesktopCatalog(
      upgraded,
      (method, payload) async => throw StateError(method),
      (operation, payload) => throw StateError(operation),
    )..validate();
    expect(kept.settings.inboundAuthEnabled, isFalse);
    expect(kept.data['inboundCredentials'], isNull);
  });

  test(
    'per-app server targets resolve to their server and survive a restore',
    () {
      final server = {
        'outbounds': [
          {
            'protocol': 'vless',
            'settings': {'address': 'nl.example.com', 'port': 443},
          },
        ],
      };
      final data = {
        ...DesktopCatalog.empty(),
        'subscriptions': [
          {
            'id': 'provider',
            'name': 'Provider',
            'nodes': [
              {
                'id': 'nl-4',
                'name': 'NL-4',
                'format': 'xrayProfile',
                'config': server,
              },
            ],
          },
        ],
      };
      final catalog = DesktopCatalog(
        data,
        (method, payload) async => throw StateError(method),
        (operation, payload) => switch (operation) {
          'catalogIdentity' => {'identity': jsonEncode(payload)},
          _ => throw StateError(operation),
        },
      );
      const settings = TunnelSettings(
        xrayTunEnabled: true,
        perAppMode: 'bypass',
        perAppProcesses: [
          'telegram.exe',
          'game.exe',
          'browser.exe',
          'steam.exe',
        ],
        perAppTargets: {
          'telegram.exe': 'node:nl-4',
          'game.exe': 'block',
          'browser.exe': 'proxy:socks5://127.0.0.1:1080',
        },
      );
      expect(catalog.perAppTargets(settings), [
        {'process': 'telegram.exe', 'target': 'server', 'server': server},
        {'process': 'game.exe', 'target': 'block'},
        {
          'process': 'browser.exe',
          'target': 'proxy',
          'proxy': 'socks5://127.0.0.1:1080',
        },
      ]);
      // Off keeps the targets but sends none, so a deleted server cannot block a connect.
      expect(
        catalog.perAppTargets(settings.copyWith(perAppMode: 'off')),
        isEmpty,
      );
      expect(
        () => catalog.perAppTargets(
          settings.copyWith(perAppTargets: {'telegram.exe': 'node:gone'}),
        ),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'per_app_target_missing',
          ),
        ),
      );
      // A restore gives servers new IDs; the targets follow them.
      data['settings'] = settings.toMap();
      final backup = catalog.backup();
      catalog.restoreBackup(backup);
      final restored = catalog.sources.single;
      final id = catalogList(restored['nodes']).single['id']! as String;
      expect(id, isNot('nl-4'));
      expect(catalog.settings.perAppTargets['telegram.exe'], 'node:$id');
      expect(catalog.settings.perAppTargets['game.exe'], 'block');
    },
  );

  // Bulk tests cap probes per SNI, the name TSPU counts handshakes by.
  test('each server names the SNI its probes handshake with', () {
    CatalogMap node(String id, CatalogMap outbound) => {
      'id': id,
      'name': id,
      'format': 'xrayProfile',
      'config': {
        'outbounds': [outbound],
      },
    };
    final catalog = DesktopCatalog(
      {
        ...DesktopCatalog.empty(),
        'subscriptions': [
          {
            'id': 'provider',
            'name': 'Provider',
            'nodes': [
              node('reality', {
                'protocol': 'vless',
                'settings': {'address': '192.0.2.1', 'port': 443},
                'streamSettings': {
                  'security': 'reality',
                  'realitySettings': {'serverName': 'Shared.Example'},
                },
              }),
              node('tls', {
                'protocol': 'trojan',
                'settings': {
                  'servers': [
                    {'address': '192.0.2.2', 'port': 443},
                  ],
                },
                'streamSettings': {
                  'security': 'tls',
                  'tlsSettings': {'serverName': 'shared.example'},
                },
              }),
              // TLS without a server name sends the address as its SNI.
              node('address', {
                'protocol': 'vmess',
                'settings': {
                  'vnext': [
                    {'address': 'Address.Example', 'port': 443},
                  ],
                },
                'streamSettings': {'security': 'tls'},
              }),
              // Without TLS there is no SNI to count.
              node('plain', {
                'protocol': 'vless',
                'settings': {'address': '192.0.2.3', 'port': 80},
              }),
            ],
          },
        ],
      },
      (method, payload) async => throw StateError(method),
      (operation, payload) => throw StateError(operation),
    );
    final nodes = catalogList(
      catalogList(catalog.snapshot()['subscriptions']).single['nodes'],
    );
    expect(nodes.map((node) => node['probeKey']), [
      'shared.example',
      'shared.example',
      'address.example',
      null,
    ]);
  });

  test('a provider rotating 1,024 server keys keeps their IDs quickly', () {
    final catalog = DesktopCatalog(
      DesktopCatalog.empty(),
      (method, payload) async => throw StateError(method),
      (operation, payload) => switch (operation) {
        'catalogIdentity' => {'identity': jsonEncode(payload)},
        'keepShortIds' => {'config': payload['config']},
        _ => throw StateError(operation),
      },
    );
    CatalogMap server(int i, String key) => {
      'format': 'xrayProfile',
      'name': 'Server $i',
      'config': {
        'outbounds': [
          {
            'protocol': 'vless',
            'settings': {'id': key},
            'streamSettings': {'network': 'tcp', 'security': 'reality'},
          },
        ],
      },
    };
    final previous = catalog.parseNodes({
      'profiles': [for (var i = 0; i < 1024; i++) server(i, 'old-$i')],
    }, []);
    final watch = Stopwatch()..start();
    final rotated = catalog.parseNodes({
      'profiles': [for (var i = 0; i < 1024; i++) server(i, 'new-$i')],
    }, previous);
    // Matching rebuilt every server's display key per server: seconds.
    expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
    expect(
      rotated.map((node) => node['id']),
      previous.map((node) => node['id']),
    );
  });

  // As on Android, a running tunnel moves to the provider's next server
  // instead of stopping silently when a refresh drops the selected one.
  test('a refresh that drops the selected server selects the next', () async {
    CatalogMap server(String name) => {
      'format': 'xrayProfile',
      'name': name,
      'config': {
        'outbounds': [
          {
            'protocol': 'vless',
            'settings': {'address': '$name.example', 'port': 443, 'id': name},
          },
        ],
      },
    };
    var feed = [server('a'), server('b')];
    final catalog = DesktopCatalog(
      DesktopCatalog.empty(),
      (method, payload) async => switch (method) {
        'fetchSubscription' => {
          'body': 'feed',
          'headers': {},
          'url': payload['url'],
        },
        'importClientProfiles' => {'profiles': feed},
        _ => throw StateError(method),
      },
      (operation, payload) => switch (operation) {
        'catalogIdentity' => {'identity': jsonEncode(payload)},
        _ => throw StateError(operation),
      },
    );
    catalog.putSource({
      'id': 'feed',
      'name': 'Feed',
      'url': 'https://feed.example/sub',
      'format': 'source',
      'status': 'ready',
      'nodes': <CatalogMap>[],
    });
    await catalog.refresh('feed');
    final nodes = catalogList(catalog.source('feed')['nodes']);
    catalog.data['selectedNodeId'] = nodes.first['id'];
    feed = [server('b')];
    await catalog.refresh('feed');
    expect(catalog.selected, nodes.last['id']);
  });

  // 3x-ui sends its Happ routing header to every client (3x-ui #5999).
  test(
    'routing addressed to Elarni wins over other clients\' routing',
    () async {
      var headers = <String, Object?>{};
      var directives = <String>[];
      final catalog = DesktopCatalog(
        DesktopCatalog.empty(),
        (method, payload) async => switch (method) {
          'fetchSubscription' => {
            'body': 'feed',
            'headers': headers,
            'url': payload['url'],
          },
          'importClientProfiles' => {
            'profiles': [
              {
                'format': 'xrayProfile',
                'name': 'a',
                'config': {
                  'outbounds': [
                    {
                      'protocol': 'vless',
                      'settings': {'address': 'a.example', 'port': 443},
                    },
                  ],
                },
              },
            ],
            'directives': directives,
          },
          _ => throw StateError(method),
        },
        (operation, payload) => switch (operation) {
          'catalogIdentity' => {'identity': jsonEncode(payload)},
          'decodeRouting' => {
            'import': {
              'action': 'add',
              'profile': {
                'Name': (payload['content']! as String).split('/').last,
              },
            },
          },
          'mergeManagedRouting' => {'routeModel': {}},
          _ => throw StateError(operation),
        },
      );
      catalog.putSource({
        'id': 'feed',
        'name': 'Feed',
        'url': 'https://feed.example/sub',
        'format': 'source',
        'status': 'ready',
        'nodes': <CatalogMap>[],
      });
      String? provided() =>
          catalog.routes
                  .where((route) => route['providerSubscriptionId'] == 'feed')
                  .singleOrNull?['name']
              as String?;
      headers = {'routing': 'elarni://routing/onadd/Elarni'};
      directives = ['happ://routing/onadd/Happ'];
      await catalog.refresh('feed');
      expect(provided(), 'Elarni');
      headers = {'routing': 'happ://routing/onadd/Happ'};
      directives = ['elarni://routing/onadd/Body'];
      await catalog.refresh('feed');
      expect(provided(), 'Body');
      // With nothing addressed to Elarni, Happ's routing still applies.
      directives = [];
      await catalog.refresh('feed');
      expect(provided(), 'Happ');
    },
  );

  // Recovery must keep working when a provider rotates its servers out.
  test('a refresh that drops failover servers keeps recovery valid', () async {
    CatalogMap server(String name) => {
      'format': 'xrayProfile',
      'name': name,
      'config': {
        'outbounds': [
          {
            'protocol': 'vless',
            'settings': {'address': '$name.example', 'port': 443, 'id': name},
          },
        ],
      },
    };
    var feed = [server('a'), server('b'), server('c')];
    final catalog = DesktopCatalog(
      DesktopCatalog.empty(),
      (method, payload) async => switch (method) {
        'fetchSubscription' => {
          'body': 'feed',
          'headers': {},
          'url': payload['url'],
        },
        'importClientProfiles' => {'profiles': feed},
        _ => throw StateError(method),
      },
      (operation, payload) => switch (operation) {
        'catalogIdentity' => {'identity': jsonEncode(payload)},
        _ => throw StateError(operation),
      },
    );
    catalog.putSource({
      'id': 'feed',
      'name': 'Feed',
      'url': 'https://feed.example/sub',
      'format': 'source',
      'status': 'ready',
      'nodes': <CatalogMap>[],
    });
    await catalog.refresh('feed');
    final ids = {
      for (final node in catalogList(catalog.source('feed')['nodes']))
        node['name']: node['id'],
    };
    catalog.data['selectedNodeId'] = ids['a'];
    catalog.data['automation'] = {
      'schemaVersion': 1,
      'enabled': true,
      'policy': 'orderedFallback',
      'subscriptionID': 'feed',
      'nodeIDs': [ids['a'], ids['b'], ids['c']],
      'targets': [
        {
          'id': 'check',
          'url': 'https://check.example/generate_204',
          'expectedStatus': 204,
          'expectedBody': '',
        },
      ],
    };
    List<Object?> automated() =>
        catalogMap(catalog.data['automation'])['nodeIDs'] as List;

    feed = [server('a'), server('c')];
    await catalog.refresh('feed');
    expect(automated(), [ids['a'], ids['c']]);
    DesktopAutomation.validate(catalogMap(catalog.data['automation']), catalog);

    // The selected server went too: the next one recovery checks takes over.
    feed = [server('d'), server('c')];
    await catalog.refresh('feed');
    expect(catalog.selected, ids['c']);
    expect(automated(), [ids['c']]);
    DesktopAutomation.validate(catalogMap(catalog.data['automation']), catalog);

    // None of its servers left: recovery turns off instead of failing.
    feed = [server('d')];
    await catalog.refresh('feed');
    expect(catalogMap(catalog.data['automation'])['enabled'], false);
    DesktopAutomation.validate(catalogMap(catalog.data['automation']), catalog);
  });

  test('deleting the failover subscription turns recovery off', () {
    final catalog = DesktopCatalog(
      DesktopCatalog.empty(),
      (method, payload) async => throw StateError(method),
      (operation, payload) => throw StateError(operation),
    );
    CatalogMap source(String id) => {
      'id': id,
      'name': id,
      'format': 'source',
      'status': 'ready',
      'nodes': [
        {'id': '$id-node', 'name': id, 'format': 'xrayProfile', 'config': {}},
      ],
    };
    catalog.putSource(source('primary'));
    catalog.putSource(source('backup'));
    catalog.data['selectedNodeId'] = 'primary-node';
    catalog.data['automation'] = {
      'schemaVersion': 1,
      'enabled': true,
      'policy': 'orderedFallback',
      'subscriptionID': 'primary',
      'nodeIDs': ['primary-node', 'backup-node'],
      'targets': [
        {
          'id': 'check',
          'url': 'https://check.example/generate_204',
          'expectedStatus': 204,
          'expectedBody': '',
        },
      ],
    };
    // Failover spans subscriptions; losing the backup's keeps the rest.
    catalog.data['subscriptions'] = [catalog.source('primary')];
    catalog.reconcileSelection();
    expect(catalogMap(catalog.data['automation'])['nodeIDs'], ['primary-node']);
    DesktopAutomation.validate(catalogMap(catalog.data['automation']), catalog);

    catalog.data['subscriptions'] = [source('other')];
    catalog.reconcileSelection();
    expect(catalogMap(catalog.data['automation'])['enabled'], false);
    DesktopAutomation.validate(catalogMap(catalog.data['automation']), catalog);
  });

  // Only the default format's response names the provider's other formats.
  test('a refresh in another format keeps the format links', () async {
    const source = 'https://feed.example/sub';
    const raw = 'https://feed.example/raw';
    final catalog = DesktopCatalog(
      DesktopCatalog.empty(),
      (method, payload) async => switch (method) {
        'fetchSubscription' => {
          'body': payload['url'] == source
              ? jsonEncode({
                  'info': {'subUrl': raw},
                })
              : 'share links',
          'headers': {},
          'url': payload['url'],
        },
        'importClientProfiles' => {
          'profiles': [
            {
              'format': 'xrayProfile',
              'name': 'Server',
              'config': {
                'outbounds': [
                  {
                    'protocol': 'vless',
                    'settings': {'id': 'server'},
                  },
                ],
              },
            },
          ],
        },
        _ => throw StateError(method),
      },
      (operation, payload) => switch (operation) {
        'catalogIdentity' => {'identity': jsonEncode(payload)},
        _ => throw StateError(operation),
      },
    );
    catalog.putSource({
      'id': 'feed',
      'name': 'Feed',
      'url': source,
      'format': 'source',
      'status': 'ready',
      'nodes': <CatalogMap>[],
    });
    await catalog.refresh('feed');
    expect(catalog.deviceIdentity('feed')['url'], source);
    await catalog.refresh('feed', format: 'raw');
    await catalog.refresh('feed');
    expect(catalog.source('feed')['format'], 'raw');
    expect(catalogMap(catalog.source('feed')['links'])['raw'], raw);
    // The device ID shown is named from the URL the chosen format fetches.
    expect(catalog.deviceIdentity('feed')['url'], raw);
  });

  test('a provider DNS that asks the system resolver is noted', () async {
    final catalog = DesktopCatalog(
      DesktopCatalog.empty(),
      (method, payload) async => switch (method) {
        'fetchSubscription' => {
          'body': 'profiles',
          'headers': {},
          'url': payload['url'],
        },
        'importClientProfiles' => {
          'profiles': [
            {
              'format': 'xrayProfile',
              'name': 'Server',
              'config': {
                'dns': {
                  'servers': ['localhost'],
                },
                'outbounds': [
                  {
                    'protocol': 'vless',
                    'settings': {'id': 'server'},
                  },
                ],
              },
            },
          ],
          'systemResolverDNS': true,
        },
        _ => throw StateError(method),
      },
      (operation, payload) => switch (operation) {
        'catalogIdentity' => {'identity': jsonEncode(payload)},
        _ => throw StateError(operation),
      },
    );
    catalog.putSource({
      'id': 'feed',
      'name': 'Feed',
      'url': 'https://feed.example/sub',
      'format': 'source',
      'status': 'ready',
      'nodes': <CatalogMap>[],
    });
    await catalog.refresh('feed');
    expect(
      catalogMap(catalog.source('feed')['metadata'])['dnsNotice'],
      startsWith("The provider's DNS asks this device's resolver"),
    );
  });

  test('a catalog over its limits says so instead of reading as corrupt', () {
    for (final (key, count) in [('subscriptions', 1025), ('profiles', 257)]) {
      final catalog = DesktopCatalog(
        {
          ...DesktopCatalog.empty(),
          key: [
            for (var i = 0; i < count; i++) {'id': '$i'},
          ],
        },
        (method, payload) async => throw StateError(method),
        (operation, payload) => throw StateError(operation),
      );
      expect(
        catalog.validate,
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'catalog_limit',
          ),
        ),
        reason: key,
      );
    }
  });
}
