import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:elarni/connection_support.dart';
import 'package:elarni/connection_recovery.dart';
import 'package:elarni/desktop_integration.dart';
import 'package:elarni/elarni_app.dart';
import 'package:elarni/tunnel_channel.dart';

import 'elarni_app_test.dart'
    show closeSettings, openRecovery, openTroubleshoot;
import 'support/fake_tunnel_control.dart';

Future<void> start(
  WidgetTester tester,
  FakeTunnelControl control,
  bool windows,
) async {
  await tester.binding.setSurfaceSize(const Size(1200, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(ElarniApp(tunnelControl: control, windows: windows));
  await tester.pumpAndSettle();
}

void main() {
  test('diagnostics preserve Linux platform identity', () {
    final report = connectionDiagnostics(
      platform: 'linux',
      state: 'disconnected',
      provider: const {},
      automation: const {},
    );
    expect(report['platform'], 'linux');
  });

  test('diagnostics and error copy retain cause without native secrets', () {
    const secret = 'https://private-secret.example/token';
    final report = connectionDiagnostics(
      platform: 'windows',
      state: secret,
      provider: {
        'endpoint': secret,
        'generation': 3,
        'memoryBytes': secret,
        'counters': {'uplinkBytes': 12, 'destination': secret},
      },
      automation: {
        'policy': secret,
        'status': secret,
        'configuration': {
          'targets': [secret],
        },
        'attempts': 2,
      },
      issueCodes: ['permission_denied', secret],
    );
    expect(jsonEncode(report), isNot(contains(secret)));
    expect(report['state'], 'unavailable');
    expect((report['provider']! as Map)['generation'], 3);
    expect(report['recentIssues'], ['permission_denied', 'operation_failed']);
    final denied = ConnectionIssue.from(
      PlatformException(code: 'elevation_denied', message: secret),
    );
    expect(denied.description, contains('permission was denied'));
    expect(denied.description, isNot(contains(secret)));
    final dns = ConnectionIssue.from(
      PlatformException(
        code: 'operation_failed',
        details: {
          'diagnostics': {'code': 'target_dns_failed', 'host': secret},
        },
      ),
    );
    expect(dns.remedy, contains('DNS'));
    expect(dns.description, isNot(contains(secret)));
    final missing = ConnectionIssue.from(
      PlatformException(code: 'per_app_target_missing'),
    );
    expect(missing.description, contains('Per-app routing'));
  });

  // These used to read as "The connection operation failed", which names
  // neither the cause nor what to do.
  test('routing data and route failures name their cause and remedy', () {
    final generic = ConnectionIssue.forCode('operation_failed').description;
    final descriptions = <String>{};
    for (final (code, cause, remedy) in [
      ('assets_missing', 'geofiles are missing', 'Refresh routing data'),
      ('missing_geodata', 'lack codes', 'Refresh routing data'),
      (
        'invalid_route_enforcement',
        'Enforce tunnel routes needs specific included routes',
        'turn enforcement off',
      ),
      ('route_model_too_large', 'exceed 8 MB', 'Remove some rules'),
    ]) {
      final issue = ConnectionIssue.from(
        PlatformException(code: code, message: 'secret'),
      );
      expect(issue.description, isNot(generic), reason: code);
      expect(issue.message, contains(cause), reason: code);
      expect(issue.remedy, contains(remedy), reason: code);
      expect(issue.description, isNot(contains('secret')), reason: code);
      descriptions.add(issue.description);
    }
    expect(descriptions, hasLength(4));
  });

  for (final windows in [false, true]) {
    testWidgets(
      'initial status failure does not invent a last-known state ($windows)',
      (tester) async {
        final control = FakeTunnelControl()
          ..onState = () async =>
              throw PlatformException(code: 'operation_failed');
        await start(tester, control, windows);
        expect(find.text('Connection status unavailable'), findsOneWidget);
        expect(find.textContaining('Last known state:'), findsNothing);
        expect(find.text('Disconnected'), findsNothing);
      },
    );

    testWidgets('status read failure preserves last-known state ($windows)', (
      tester,
    ) async {
      final control = FakeTunnelControl()..phase = 'connected';
      await start(tester, control, windows);
      expect(find.text('Connected'), findsOneWidget);
      await openTroubleshoot(tester);
      control.onState = () async =>
          throw PlatformException(code: 'operation_failed');
      await tester.tap(find.text('Refresh status'));
      await tester.pumpAndSettle();
      expect(find.text('Connection status unavailable'), findsWidgets);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      await closeSettings(tester);
      expect(find.text('Last known state: connected'), findsOneWidget);
      expect(find.text('Disconnected'), findsNothing);
      expect(control.disconnectCalls, 0);
    });

    testWidgets(
      'permission errors explain the remedy and permit same-server retry ($windows)',
      (tester) async {
        final control = FakeTunnelControl()
          ..onConnect = () async => throw PlatformException(
            code: 'elevation_denied',
            message: 'secret-password',
          );
        await start(tester, control, windows);
        await tester.tap(find.byKey(const Key('connection-toggle')));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('VPN permission was denied.'),
          findsOneWidget,
        );
        expect(find.textContaining('secret-password'), findsNothing);
        expect(control.selectedIDs, isEmpty);
        await openTroubleshoot(tester);
        expect(
          tester
              .widget<TextButton>(
                find.widgetWithText(TextButton, 'Retry selected server'),
              )
              .onPressed,
          isNotNull,
        );
        // The dialog's button, above the Settings tile of the same name.
        await tester.tap(find.text('Export diagnostics').last);
        await tester.pumpAndSettle();
        expect(control.diagnosticExports, 1);
        expect(control.exportedIssueCodes, ['permission_denied']);
      },
    );

    testWidgets(
      'Stop owns the final state after a late connect reply ($windows)',
      (tester) async {
        final reply = Completer<String>();
        final control = FakeTunnelControl()..onConnect = () => reply.future;
        await start(tester, control, windows);
        await tester.tap(find.byKey(const Key('connection-toggle')));
        await tester.pump();
        await tester.tap(find.byKey(const Key('connection-toggle')));
        await tester.pumpAndSettle();
        expect(control.disconnectCalls, 1);
        reply.complete('connected');
        await tester.pumpAndSettle();
        expect(find.text('Disconnected'), findsOneWidget);
        expect(find.text('Connected'), findsNothing);
      },
    );

    testWidgets(
      'retry restarts the selected server after a failed check ($windows)',
      (tester) async {
        final control = FakeTunnelControl()..phase = 'connected';
        await start(tester, control, windows);
        control.onPing = (_) async =>
            throw PlatformException(code: 'automation_healthFailure');
        await openTroubleshoot(tester);
        await tester.tap(find.text('Check connection'));
        await tester.pumpAndSettle();
        expect(find.textContaining('Connection check failed'), findsWidgets);
        await tester.tap(find.text('Retry selected server'));
        await tester.pumpAndSettle();
        expect(control.disconnectCalls, 1);
        expect(control.selectedIDs, ['a']);
        expect(control.connectCalls, 1);
        expect(find.text('Connection: connected'), findsOneWidget);
      },
    );

    testWidgets(
      'checks are explicit and late success cannot survive Stop ($windows)',
      (tester) async {
        final control = FakeTunnelControl()..phase = 'connected';
        await start(tester, control, windows);
        expect(find.text('Connection has not been checked'), findsOneWidget);
        final reply = Completer<PingResult>();
        control.onPing = (_) => reply.future;
        await openTroubleshoot(tester);
        await tester.tap(find.text('Check connection'));
        await tester.pump();
        expect(control.pingCalls.last.protocol, 'activeProxy');
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
        await closeSettings(tester);
        await tester.tap(find.byKey(const Key('connection-toggle')));
        await tester.pumpAndSettle();
        reply.complete(
          const PingResult(
            nodeId: 'a',
            status: 'ok',
            latencyMs: 10,
            timestamp: 1,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('Connection check passed'), findsNothing);
        expect(control.disconnectCalls, 1);
      },
    );

    testWidgets(
      'same-server recovery is the safe choice and backups require selection ($windows)',
      (tester) async {
        final control = FakeTunnelControl();
        await start(tester, control, windows);
        await openRecovery(tester);
        await tester.tap(find.byKey(const Key('recovery-mode')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Reconnect to this server').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(
          control.recoverySaves.single.policy,
          AutomationSelectionPolicy.fixed,
        );
        expect(control.recoverySaves.single.nodeIds, ['a']);
        expect(control.connectCalls, 0);
        await openRecovery(tester);
        await tester.tap(find.byKey(const Key('recovery-mode')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Use allowed backups').last);
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const ValueKey('recovery-url:1')),
        );
        await tester.enterText(
          find.byKey(const ValueKey('recovery-url:1')),
          'https://fixture.example/check',
        );
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(
          control.recoverySaves.length,
          1,
          reason: 'Backup permission must be explicit',
        );
        await tester.ensureVisible(find.byKey(const ValueKey('backup:b')));
        await tester.tap(find.byKey(const ValueKey('backup:b')));
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(
          control.recoverySaves.last.policy,
          AutomationSelectionPolicy.orderedFallback,
        );
        expect(control.recoverySaves.last.nodeIds, ['a', 'b']);
        expect(control.recoverySaves.last.targets.length, 2);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'unsupported routing permits same-server recovery with enlarged text',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final saves = <AutomationConfiguration>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (context) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: const TextScaler.linear(1.5)),
                  child: ConnectionRecoveryDialog(
                    groups: fixtureSubscriptions.subscriptions,
                    selectedId: 'a',
                    snapshot: const {'policySupported': false},
                    save: (configuration) async => saves.add(configuration),
                  ),
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('recovery-mode')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use allowed backups').last);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
            .onPressed,
        isNull,
      );
      await tester.ensureVisible(find.byKey(const Key('recovery-mode')));
      await tester.tap(find.byKey(const Key('recovery-mode')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reconnect to this server').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(saves.single.policy, AutomationSelectionPolicy.fixed);
      expect(tester.takeException(), isNull);
    },
  );

  // The dialog is its own route; a Connect from the tray must still disable its Retry.
  testWidgets('Troubleshoot follows a Connect started from the tray', (
    tester,
  ) async {
    final reply = Completer<String>();
    final control = FakeTunnelControl()
      ..phase = 'prepared'
      ..onConnect = () => reply.future;
    await start(tester, control, true);
    await openTroubleshoot(tester);
    const channel = DesktopIntegration.channel;
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(const MethodCall('action', 'connect')),
      null,
    );
    await tester.pump();
    expect(control.connectCalls, 1);
    expect(
      tester
          .widget<TextButton>(
            find.widgetWithText(TextButton, 'Retry selected server'),
          )
          .onPressed,
      isNull,
    );
    reply.complete('connected');
    await tester.pumpAndSettle();
    expect(control.connectCalls, 1);
  });

  testWidgets('a lowest-latency policy set elsewhere survives Save', (
    tester,
  ) async {
    final saves = <AutomationConfiguration>[];
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (context) => ConnectionRecoveryDialog(
                groups: fixtureSubscriptions.subscriptions,
                selectedId: 'a',
                snapshot: const {
                  'configuration': {
                    'enabled': true,
                    'policy': 'lowestLatency',
                    'nodeIDs': ['a', 'b'],
                    'targets': [
                      {
                        'url': 'https://one.example/check',
                        'expectedStatus': 204,
                      },
                      {
                        'url': 'https://two.example/check',
                        'expectedStatus': 204,
                      },
                    ],
                  },
                },
                save: (configuration) async => saves.add(configuration),
              ),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Lowest latency'), findsOneWidget);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(saves.single.policy, AutomationSelectionPolicy.lowestLatency);
    expect(saves.single.nodeIds, ['a', 'b']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Telegram proxies are not offered as backups', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final group = fixtureSubscriptions.subscriptions.single;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (context) => ConnectionRecoveryDialog(
                groups: [
                  SubscriptionGroup(
                    id: group.id,
                    name: group.name,
                    status: group.status,
                    nodes: [
                      ...group.nodes,
                      const SubscriptionNode(
                        id: 'telegram',
                        name: 'Telegram proxy',
                        protocol: 'MTProto',
                        transport: 'Telegram',
                        security: 'MTProto',
                        selected: false,
                        format: 'telegram',
                      ),
                    ],
                  ),
                ],
                selectedId: 'a',
                snapshot: const {},
                save: (_) async {},
              ),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('recovery-mode')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use allowed backups').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('backup:b')), findsOneWidget);
    expect(find.byKey(const ValueKey('backup:telegram')), findsNothing);
  });

  testWidgets('backups come from every subscription, grouped by it', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final saves = <AutomationConfiguration>[];
    SubscriptionNode node(String id, String name) => SubscriptionNode(
      id: id,
      name: name,
      protocol: 'VLESS',
      transport: 'tcp',
      security: 'tls',
      selected: false,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (context) => ConnectionRecoveryDialog(
                groups: [
                  ...fixtureSubscriptions.subscriptions,
                  SubscriptionGroup(
                    id: 'second',
                    name: 'Second provider',
                    status: 'ready',
                    nodes: [
                      node('relay', '🇷🇺 Moscow relay'),
                      node('chain', 'RU → NL'),
                      node('us', 'US New York'),
                    ],
                  ),
                ],
                selectedId: 'a',
                snapshot: const {},
                save: (configuration) async => saves.add(configuration),
              ),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('recovery-mode')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use allowed backups').last);
    await tester.pumpAndSettle();
    expect(find.text('Second provider'), findsOneWidget);
    expect(find.textContaining('keeps these backups'), findsOneWidget);
    expect(find.textContaining('TCP 443 backups go first'), findsOneWidget);
    for (final id in ['relay', 'b', 'chain', 'us']) {
      await tester.tap(find.byKey(ValueKey('backup:$id')));
      await tester.pumpAndSettle();
    }
    await tester.enterText(
      find.byKey(const ValueKey('recovery-url:1')),
      'https://cp.cloudflare.com/generate_204',
    );
    await tester.ensureVisible(find.text('Save'));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(saves.single.subscriptionId, 'group');
    expect(saves.single.nodeIds, ['a', 'relay', 'b', 'chain', 'us']);
    expect(saves.single.russianEntryNodeIds, ['relay', 'chain']);
    expect(saves.single.toMap()['russianEntryNodeIDs'], ['relay', 'chain']);
  });

  testWidgets('whitelist mode shows under the automatic check', (tester) async {
    final control = FakeTunnelControl()
      ..phase = 'connected'
      ..automation = {
        'enabled': true,
        'policy': 'orderedFallback',
        'policySupported': true,
        'status': 'healthy',
        'healthNodeID': 'a',
        'healthAgeSeconds': 5,
        'whitelistMode': true,
      };
    await start(tester, control, false);
    expect(
      find.text(
        'Latest automatic check passed\nWhitelist mode: Russian-entry servers first',
      ),
      findsOneWidget,
    );
  });
}
