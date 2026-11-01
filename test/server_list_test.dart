import 'dart:async';
import 'dart:convert';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:elarni/desktop_integration.dart';
import 'package:elarni/elarni_app.dart';
import 'package:elarni/elarni_widgets.dart';
import 'package:elarni/tunnel_channel.dart';
import 'elarni_app_test.dart' show reveal, selectCategory;
import 'server_browser_test.dart' show NoticeControl, countryFixture, server;

PingResult reply(String id, {int latency = 30}) => PingResult(
  nodeId: id,
  status: 'success',
  latencyMs: latency,
  timestamp: DateTime.now().millisecondsSinceEpoch / 1000,
);

Future<void> openServers(WidgetTester tester, String id, String name) async {
  await tester.tap(find.byKey(const Key('nav-subscriptions')));
  await tester.pumpAndSettle();
  await tester.tap(
    find.descendant(
      of: find.byKey(ValueKey('subscription:$id')),
      matching: find.text(name),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'launch tests only open groups, and opening a group tests its stale servers',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final control = NoticeControl()..snapshot = countryFixture();
      control.onPing = (id) async => id == 'nl-vmess'
          ? throw StateError('Synthetic endpoint unavailable')
          : reply(id);
      List<String> pinged() =>
          control.pingCalls.map((call) => call.nodeId).toList();
      await tester.pumpWidget(ElarniApp(tunnelControl: control, windows: true));
      await tester.pumpAndSettle();
      // Frankfurt is selected and the unnamed server has no country, so both groups start open.
      expect(pinged(), ['de', 'unknown']);
      final netherlands = find.byKey(const ValueKey('country:daily:NL::all'));
      await tester.tap(netherlands);
      await tester.pumpAndSettle();
      expect(pinged(), ['de', 'unknown', 'nl-vless', 'nl-trojan']);
      // Reopening within five minutes repeats nothing.
      await tester.tap(netherlands);
      await tester.pumpAndSettle();
      await tester.tap(netherlands);
      await tester.pumpAndSettle();
      expect(pinged(), hasLength(4));
      final travel = find.byKey(const ValueKey('country:travel:NL::all'));
      await reveal(tester, travel);
      await tester.tap(travel);
      await tester.pumpAndSettle();
      expect(pinged().last, 'nl-vmess');
      expect(find.text('Unavailable'), findsOneWidget);
      // A server that just failed is not retried by every open.
      await tester.tap(travel);
      await tester.pumpAndSettle();
      await tester.tap(travel);
      await tester.pumpAndSettle();
      expect(pinged(), hasLength(5));
      // Test all still tests every server.
      control.pingCalls.clear();
      await tester.tap(find.byKey(const Key('ping-all')));
      await tester.pumpAndSettle();
      expect(pinged()..sort(), [
        'de',
        'nl-trojan',
        'nl-vless',
        'nl-vmess',
        'unknown',
      ]);
      expect(control.connectCalls, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('a group opened during a test is tested when the test ends', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final pending = <String, Completer<PingResult>>{};
    final control = NoticeControl()..snapshot = countryFixture();
    control.onPing = (id) => (pending[id] = Completer<PingResult>()).future;
    await tester.pumpWidget(ElarniApp(tunnelControl: control, windows: true));
    await tester.pumpAndSettle();
    expect(pending.keys, ['de', 'unknown']);
    await tester.tap(find.byKey(const ValueKey('country:daily:NL::all')));
    await tester.pumpAndSettle();
    expect(pending.keys, ['de', 'unknown']);
    pending['de']!.complete(reply('de'));
    pending['unknown']!.complete(reply('unknown'));
    await tester.pumpAndSettle();
    expect(pending.keys, ['de', 'unknown', 'nl-vless', 'nl-trojan']);
    pending['nl-vless']!.complete(reply('nl-vless', latency: 80));
    pending['nl-trojan']!.complete(reply('nl-trojan', latency: 90));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('country-ping:daily:NL')))
          .data,
      '80 ms',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a long list builds only the rows on screen', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final control = NoticeControl()
      ..snapshot = SubscriptionSnapshot(
        selectedNodeId: 's0',
        subscriptions: [
          SubscriptionGroup(
            id: 'big',
            name: 'Big provider',
            status: 'ready',
            nodes: [
              for (var i = 0; i < 2000; i++)
                server('s$i', 'Server $i', 'VLESS', selected: i == 0),
            ],
          ),
        ],
      );
    control.onPing = (id) async => reply(id);
    await tester.pumpWidget(ElarniApp(tunnelControl: control, windows: true));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('node:s0')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('node:s1999'), skipOffstage: false),
      findsNothing,
    );
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('node:s200')),
      600,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('servers-list')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(
      find.byKey(const ValueKey('node:s0'), skipOffstage: false),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('favorites come first unless turned off', (tester) async {
    var stored = '{}';
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(DesktopIntegration.channel, (
      call,
    ) async {
      if (call.method == 'getPreferences') return stored;
      if (call.method == 'setPreferences')
        stored = (call.arguments as Map)['json'] as String;
      return null;
    });
    addTearDown(
      () =>
          messenger.setMockMethodCallHandler(DesktopIntegration.channel, null),
    );
    await tester.binding.setSurfaceSize(const Size(1280, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = countryFixture();
    final daily = fixture.subscriptions.first;
    final control = NoticeControl()
      ..snapshot = SubscriptionSnapshot(
        selectedNodeId: fixture.selectedNodeId,
        subscriptions: [
          SubscriptionGroup(
            id: daily.id,
            name: daily.name,
            status: daily.status,
            nodes: [
              for (final node in daily.nodes)
                SubscriptionNode(
                  id: node.id,
                  name: node.name,
                  protocol: node.protocol,
                  transport: node.transport,
                  security: node.security,
                  selected: node.selected,
                  favorite: node.id == 'nl-trojan',
                ),
            ],
          ),
        ],
      );
    await tester.pumpWidget(ElarniApp(tunnelControl: control, windows: true));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('country:daily:NL::all')));
    await tester.pumpAndSettle();
    double top(String id) =>
        tester.getTopLeft(find.byKey(ValueKey('node:$id'))).dy;
    expect(top('nl-trojan'), lessThan(top('nl-vless')));
    await tester.tap(find.byKey(const Key('nav-settings')));
    await tester.pumpAndSettle();
    await selectCategory(tester, SettingsCategory.general);
    await reveal(tester, find.text('Favorites first'));
    await tester.tap(find.text('Favorites first'));
    await tester.pumpAndSettle();
    expect(jsonDecode(stored)['favoritesFirst'], isFalse);
    await tester.tap(find.byKey(const Key('nav-home')));
    await tester.pumpAndSettle();
    expect(top('nl-vless'), lessThan(top('nl-trojan')));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('select unreachable hides the failed servers together', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final control = NoticeControl()..snapshot = countryFixture();
    control.onPing = (id) async => const {'nl-trojan', 'de'}.contains(id)
        ? throw StateError('Synthetic endpoint unavailable')
        : reply(id);
    await tester.pumpWidget(ElarniApp(tunnelControl: control, windows: true));
    await tester.pumpAndSettle();
    await openServers(tester, 'daily', 'boVPN');
    await tester.tap(find.byKey(const ValueKey('subscription-ping-all:daily')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('select-servers:daily')));
    await tester.pumpAndSettle();
    // The connected server cannot be removed, so it cannot be selected.
    expect(
      tester
          .widget<Checkbox>(find.byKey(const ValueKey('select-node:de')))
          .onChanged,
      isNull,
    );
    await tester.tap(find.text('Select unreachable'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('select-node:unknown')));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Hide'));
    await tester.pumpAndSettle();
    expect(find.text('Hide 2 servers?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Hide'));
    await tester.pumpAndSettle();
    expect(control.deletedBatches, [
      ['nl-trojan', 'unknown'],
    ]);
    expect(find.text('2 selected'), findsNothing);
    expect(find.byKey(const ValueKey('select-node:unknown')), findsNothing);
    expect(control.selectedIDs, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'check exit names where a server reaches the internet and flags a name that disagrees',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final control = NoticeControl()..snapshot = countryFixture();
      control.onPing = (id) async => control.pingCalls.last.trace
          ? PingResult(
              nodeId: id,
              status: 'success',
              latencyMs: 40,
              timestamp: DateTime.now().millisecondsSinceEpoch / 1000,
              exitIP: '203.0.113.7',
              exitCountry: 'DE',
            )
          : reply(id);
      await tester.pumpWidget(ElarniApp(tunnelControl: control, windows: true));
      await tester.pumpAndSettle();
      await openServers(tester, 'daily', 'boVPN');
      await tester.tap(find.byKey(const ValueKey('check-exit:nl-vless')));
      await tester.pumpAndSettle();
      final call = control.pingCalls.last;
      expect(call.nodeId, 'nl-vless');
      expect(call.trace, isTrue);
      expect(call.protocol, 'proxy');
      expect(call.url, 'https://cp.cloudflare.com/cdn-cgi/trace');
      expect(call.expectedStatus, 200);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('node:nl-vless')),
          matching: find.text('Exit: Germany · 203.0.113.7'),
        ),
        findsOneWidget,
      );
      expect(
        find.text(
          "Amsterdam 01's name says Netherlands, but its exit is in Germany.",
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('check-exit:nl-vless')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('check-exit:de')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('node:de')),
          matching: find.text('Exit: Germany · 203.0.113.7'),
        ),
        findsOneWidget,
      );
      expect(find.textContaining("Frankfurt's name says"), findsNothing);
      // Home offers the same check from a server's menu.
      await tester.tap(find.byKey(const Key('nav-home')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('node:unknown')),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Check exit'));
      await tester.pumpAndSettle();
      expect(control.pingCalls.last.nodeId, 'unknown');
      expect(control.pingCalls.last.trace, isTrue);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('node:unknown')),
          matching: find.text('Exit: Germany · 203.0.113.7'),
        ),
        findsOneWidget,
      );
      expect(control.connectCalls, 0);
      expect(control.selectedIDs, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
