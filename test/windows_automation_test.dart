import 'package:flutter_test/flutter_test.dart';
import 'package:elarni/desktop_automation.dart';
import 'package:elarni/desktop_catalog.dart';

void main() {
  test(
    'unattended retry waits past the SNI freeze, longer each time, and honors manual stop',
    () {
      final policy = DesktopAutomation({'attempts': 6})..intent = true;
      policy.pathChanged('ethernet', true, 0);
      // TSPU freezes an SNI for about 120 s after a burst of handshakes.
      var now = 0.0;
      for (final wait in [150, 300, 600, 600]) {
        expect(policy.rearmUnattended(now), false);
        expect(policy.rearmUnattended(now + wait - 1), false);
        expect(policy.exhausted, true);
        expect(policy.rearmUnattended(now + wait), true);
        expect(policy.exhausted, false);
        expect(policy.attempts, 0);
        now += wait;
        // The next episode fails too.
        policy.exhausted = true;
      }
      // A passing check starts the waits over.
      policy.healthy(now);
      policy.exhausted = true;
      expect(policy.rearmUnattended(now), false);
      expect(policy.rearmUnattended(now + 150), true);
      now += 150;
      policy.scheduleRetry(now);
      expect(policy.retryAt, now + 1);
      policy.exhausted = true;
      expect(policy.rearmUnattended(now + 40), false);
      policy.manualStop();
      expect(policy.rearmUnattended(200), false);
      expect(policy.intent, false);
      expect(policy.retryAt, null);
    },
  );

  test('backups can come from any subscription that still lists them', () {
    final catalog = DesktopCatalog(
      {
        'selectedNodeId': 'a',
        'subscriptions': [
          {
            'id': 'provider',
            'nodes': [
              {'id': 'a', 'format': 'xrayProfile'},
            ],
          },
          {
            'id': 'local',
            'nodes': [
              {'id': 'b', 'format': 'xrayProfile'},
            ],
          },
        ],
      },
      (_, _) async => {},
      (_, _) => {},
    );
    final config = <String, Object?>{
      'schemaVersion': 1,
      'enabled': true,
      'policy': 'orderedFallback',
      'subscriptionID': 'provider',
      'nodeIDs': ['a', 'b'],
      'russianEntryNodeIDs': ['b'],
      'targets': [
        {
          'id': 'test',
          'url': 'https://example.test/check',
          'expectedStatus': 204,
          'expectedBody': '',
        },
      ],
    };
    expect(() => DesktopAutomation.validate(config, catalog), returnsNormally);
    config['russianEntryNodeIDs'] = ['c'];
    expect(
      () => DesktopAutomation.validate(config, catalog),
      throwsA(isA<Exception>()),
    );
    config['russianEntryNodeIDs'] = ['b'];
    config['nodeIDs'] = ['a', 'missing'];
    expect(
      () => DesktopAutomation.validate(config, catalog),
      throwsA(isA<Exception>()),
    );
  });

  test(
    'recovery tries TCP 443 first after a UDP or other-port failure, and Russian entries in whitelist mode',
    () {
      CatalogMap server(
        String protocol,
        int port, {
        String network = 'tcp',
        List<String>? alpn,
      }) => {
        'outbounds': [
          {
            'protocol': protocol,
            'settings': protocol == 'vless'
                ? {
                    'vnext': [
                      {'address': 'server.test', 'port': port},
                    ],
                  }
                : {
                    'servers': [
                      {'address': 'server.test', 'port': port},
                    ],
                  },
            'streamSettings': {
              'network': network,
              'security': 'tls',
              if (alpn != null) 'tlsSettings': {'alpn': alpn},
            },
          },
        ],
      };
      expect(DesktopAutomation.tcp443(server('vless', 443)), true);
      expect(
        DesktopAutomation.tcp443(server('vless', 443, network: 'ws')),
        true,
      );
      expect(
        DesktopAutomation.tcp443(server('trojan', 443, network: 'xhttp')),
        true,
      );
      expect(DesktopAutomation.tcp443(server('vless', 8443)), false);
      expect(
        DesktopAutomation.tcp443(server('hysteria', 443, network: 'hysteria')),
        false,
      );
      expect(
        DesktopAutomation.tcp443(server('vless', 443, network: 'kcp')),
        false,
      );
      expect(
        DesktopAutomation.tcp443(
          server('vless', 443, network: 'xhttp', alpn: ['h3']),
        ),
        false,
      );
      expect(DesktopAutomation.tcp443({'outbounds': []}), false);

      final policy = DesktopAutomation({});
      const order = ['a', 'b', 'c', 'd', 'e'], tcp = {'c', 'e'}, russia = {'d'};
      expect(policy.recoveryOrder(order, 'a', tcp, russia), [
        'c',
        'e',
        'a',
        'b',
        'd',
      ]);
      expect(policy.recoveryOrder(order, 'c', tcp, russia), order);
      // One foreign server down is an outage, not a whitelist.
      policy.observe('a', false, false);
      policy.observe('d', true, true);
      expect(policy.whitelist, false);
      policy.observe('b', false, false);
      policy.observe('d', true, true);
      expect(policy.whitelist, true);
      expect(policy.recoveryOrder(order, 'c', tcp, russia), [
        'd',
        'a',
        'b',
        'c',
        'e',
      ]);
      expect(policy.recoveryOrder(order, 'a', tcp, russia), [
        'd',
        'c',
        'e',
        'a',
        'b',
      ]);
      policy.observe('c', true, false);
      expect(policy.whitelist, false);
      // Failures from before a foreign server passed again count for nothing.
      policy.observe('a', false, false);
      policy.observe('d', true, true);
      expect(policy.whitelist, false);
    },
  );

  test('Linux tunnel alone cannot keep physical connectivity online', () {
    final policy = DesktopAutomation({})..intent = true;
    final remaining = [
      'rv0123456789ab',
    ].where((name) => DesktopAutomation.physicalInterface(name, linux: true));
    policy.pathChanged(remaining.join('|'), remaining.isNotEmpty, 0);
    expect(policy.online, false);
    expect(DesktopAutomation.physicalInterface('enp1s0', linux: true), true);
    expect(DesktopAutomation.physicalInterface('wlp2s0', linux: true), true);
    expect(DesktopAutomation.physicalInterface('rv-lan', linux: true), true);
    expect(DesktopAutomation.physicalInterface('Elarni-fixture'), false);
    expect(DesktopAutomation.physicalInterface('Ethernet'), true);
  });

  test('outage trials need permission, not cached measurements', () {
    final policy = DesktopAutomation({});
    expect(policy.recoveryCandidates('fixed', ['a', 'b'], 'a', 0), isEmpty);
    expect(
      policy.recoveryCandidates('orderedFallback', ['a', 'b', 'c'], 'a', 0),
      ['b', 'c'],
    );
    policy.measurements['b'] = (score: 10, at: 0, epoch: 0, reference: 'old');
    expect(policy.recoveryCandidates('orderedFallback', ['a', 'b'], 'a', 301), [
      'b',
    ]);
    policy.cooldown['b'] = 400;
    expect(
      policy.recoveryCandidates('orderedFallback', ['a', 'b', 'c'], 'a', 301),
      ['c'],
    );
    policy.cooldown['c'] = 400;
    expect(
      policy.recoveryCandidates('orderedFallback', ['a', 'b', 'c'], 'a', 301),
      isEmpty,
    );
  });
  test(
    'retry budget survives relaunch and sleep; manual stop cancels intent',
    () {
      final policy = DesktopAutomation({})..intent = true;
      policy.pathChanged('ethernet', true, 0);
      var now = 0.0;
      for (var attempt = 0; attempt < 6; attempt++) {
        policy.scheduleRetry(now);
        expect(policy.retryAt, isNotNull);
        expect(DesktopAutomation(policy.episode).exhausted, true);
        policy.sleepChanged(true, now);
        expect(policy.beginRetry(now + 40), false);
        policy.sleepChanged(false, now);
        // Wake can reset an episode only before an attempt has begun.
        policy.scheduleRetry(now);
        now = policy.retryAt!;
        expect(policy.beginRetry(now), true);
        expect(policy.attempts, attempt + 1);
      }
      policy.scheduleRetry(now);
      expect(policy.exhausted, true);
      policy.pathChanged('wifi', true, now + 1);
      expect(policy.exhausted, true);
      policy.manualStop();
      policy.scheduleRetry(now + 2);
      expect(policy.intent, false);
      expect(policy.retryAt, null);
      expect(policy.status, 'stopped');
    },
  );

  // A drop longer than the failover budget must not leave the VPN down while
  // the user still wants it: the selected server is retried every minute.
  test('plain retries back off to a minute and never give up', () {
    final policy = DesktopAutomation({})..intent = true;
    policy.pathChanged('ethernet', true, 0);
    var now = 0.0;
    final delays = <double>[];
    for (var attempt = 0; attempt < 10; attempt++) {
      policy.scheduleRetry(now);
      delays.add(policy.retryAt! - now);
      now = policy.retryAt!;
      expect(policy.beginRetry(now), true);
    }
    expect(delays, [1, 2, 4, 8, 16, 30, 60, 60, 60, 60]);
    // Exhausted ends only failover to other servers.
    expect(policy.exhausted, true);
    expect(policy.attempts, 10);
    policy.manualStop();
    policy.scheduleRetry(now);
    expect(policy.retryAt, null);
  });

  test(
    'a network that returns starts a new episode; an address change keeps it',
    () {
      final policy = DesktopAutomation({})..intent = true;
      policy.pathChanged('1:10.0.0.2', true, 0);
      policy.scheduleRetry(0);
      expect(policy.beginRetry(1), true);
      policy.pathChanged('1:10.0.0.3', true, 2);
      expect(policy.attempts, 1, reason: 'a flapping link keeps the budget');
      var now = 3.0;
      while (!policy.exhausted) {
        policy.scheduleRetry(now);
        now = policy.retryAt!;
        policy.beginRetry(now);
      }
      policy.pathChanged('', false, 200);
      expect(policy.online, false);
      policy.pathChanged('1:10.0.0.3', true, 900);
      expect(policy.exhausted, false);
      expect(policy.attempts, 0);
      expect(policy.retryAt, null);
      expect(policy.healthAt, 900);
    },
  );

  // Three failed checks in a row fail over. They were 30 s apart, so failover
  // began up to 120 s after the server died.
  test(
    'a dead server is left within 80 s; one failed check never switches',
    () {
      final policy = DesktopAutomation({})..intent = true;
      policy.pathChanged('ethernet', true, 0);
      policy.healthy(0);
      expect(policy.healthAt, 30, reason: 'passing checks stay 30 s apart');
      // The server dies just after that pass; a failed check runs out two 5 s
      // probe timeouts.
      var now = 0.0, checks = 0;
      do {
        now = policy.healthAt! + 10;
        checks++;
      } while (!policy.checkFailed(now, retrying: false));
      expect(checks, 3);
      expect(now, lessThanOrEqualTo(80));
      // A pass between failures starts the count over.
      policy.healthy(now);
      for (var i = 0; i < 4; i++) {
        now = policy.healthAt! + 10;
        expect(policy.checkFailed(now, retrying: false), false);
        expect(policy.status, 'healthFailure');
        policy.healthy(now);
      }
      // A scheduled retry after a failed connect switches on its first failure.
      expect(policy.checkFailed(now, retrying: true), true);
    },
  );

  test('a sleep whose wake event never came ends after a minute of ticks', () {
    final policy = DesktopAutomation({})..intent = true;
    policy.pathChanged('ethernet', true, 0);
    policy.sleepChanged(true, 0);
    for (var tick = 1; tick < 60; tick++) {
      expect(policy.stillSleeping(tick.toDouble()), true);
    }
    expect(policy.stillSleeping(60), false);
    expect(policy.sleeping, false);
    policy.scheduleRetry(60);
    expect(policy.retryAt, 61);
  });

  test(
    'selection uses valid measurements, bounded rounds and latency hysteresis',
    () {
      final policy = DesktopAutomation({});
      final nodes = List.generate(20, (i) => '$i');
      final first = policy.round(nodes, '0', 0);
      final second = policy.round(nodes, '0', 0);
      expect(first.length, 10);
      expect(second.toSet().difference(first.toSet()), isNotEmpty);
      expect(policy.choose('fixed', nodes, '0', {'1': 10}, false, 0), null);
      expect(
        policy.choose(
          'orderedFallback',
          nodes,
          '0',
          {'0': 10, '1': 20},
          false,
          0,
        ),
        '1',
      );
      expect(
        policy.choose(
          'orderedFallback',
          nodes,
          '1',
          {'0': 100, '1': 150},
          true,
          0,
        ),
        '1',
      );
      expect(
        policy.choose('orderedFallback', nodes, '0', {'1': 20}, true, 0),
        '0',
      );
      expect(
        policy.choose(
          'orderedFallback',
          nodes,
          '1',
          {'0': 100, '1': 150},
          false,
          0,
        ),
        '0',
      );
      expect(
        policy.choose(
          'lowestLatency',
          nodes,
          '0',
          {'0': 100, '1': 90},
          true,
          0,
        ),
        '0',
      );
      expect(
        policy.choose(
          'lowestLatency',
          nodes,
          '0',
          {'0': 100, '1': 70},
          true,
          0,
        ),
        '1',
      );
      policy.lastSwitch = 0;
      expect(
        policy.choose(
          'lowestLatency',
          nodes,
          '0',
          {'0': 100, '1': 70},
          true,
          59,
        ),
        '0',
      );
      policy.measurements['0'] = (
        score: 100,
        at: 0,
        epoch: 0,
        reference: 'config',
      );
      expect(policy.score('0', 'other-config', 1), null);
      expect(policy.score('0', 'config', 300), null);
      expect(policy.score('0', 'config', 1), 100);
      policy.pathChanged('new-network', true, 1);
      expect(policy.score('0', 'config', 1), null);
    },
  );
}
