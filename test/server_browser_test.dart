import 'dart:async';
import 'dart:convert';
import 'package:country_flags/country_flags.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:elarni/elarni_app.dart';
import 'package:elarni/desktop_integration.dart';
import 'package:elarni/elarni_widgets.dart';
import 'package:elarni/server_locations.dart';
import 'package:elarni/tunnel_channel.dart';
import 'support/fake_tunnel_control.dart';
import 'elarni_app_test.dart' show reveal;

const providerMessage =
    'ВПН не работает? Нажмите «Обновить подписку», '
    'чтобы восстановить доступ. 🔄\n'
    'Если не работает сервер — попробуйте все доступные сервера.';

SubscriptionNode server(
  String id,
  String name,
  String protocol, {
  bool selected = false,
}) => SubscriptionNode(
  id: id,
  name: name,
  protocol: protocol,
  transport: 'tcp',
  security: 'tls',
  selected: selected,
);

SubscriptionSnapshot countryFixture() => SubscriptionSnapshot(
  selectedNodeId: 'de',
  subscriptions: [
    SubscriptionGroup(
      id: 'daily',
      name: 'boVPN',
      status: 'ready',
      metadata: const {
        'announcement': providerMessage,
        'bannerText': 'Provider maintenance details',
        'bannerButtonText': 'Provider page',
      },
      actions: const ['banner'],
      nodes: [
        server('nl-vless', '🇳🇱 Amsterdam 01', 'VLESS'),
        server('nl-trojan', 'Netherlands • Amsterdam 02', 'Trojan'),
        server('de', '🇩🇪 Frankfurt', 'VLESS', selected: true),
        server('unknown', 'Private server', 'Shadowsocks'),
      ],
    ),
    SubscriptionGroup(
      id: 'travel',
      name: 'Travel',
      status: 'ready',
      nodes: [server('nl-vmess', 'NL Rotterdam', 'VMess')],
    ),
  ],
);

class NoticeControl extends FakeTunnelControl {
  final links = <String>[];
  final refreshes = <String>[];
  @override
  Future<RoutingSnapshot> assignRoutingProfile(
    String subscriptionId,
    String? profileId,
  ) async {
    routingActions.add('assign:$subscriptionId:$profileId');
    routingSnapshot = RoutingSnapshot(
      profiles: routingSnapshot.profiles,
      assignments: {
        ...routingSnapshot.assignments,
        subscriptionId: profileId ?? '',
      },
    );
    return routingSnapshot;
  }

  @override
  Future<void> openProviderLink(String id, String action) async =>
      links.add('$id:$action');
  @override
  Future<SubscriptionOperationResult> refreshSubscription(
    String id, {
    String? challenge,
    String? format,
  }) async {
    refreshes.add(id);
    return super.refreshSubscription(id, challenge: challenge, format: format);
  }
}

class FailedRefreshControl extends NoticeControl {
  @override
  Future<SubscriptionOperationResult> refreshSubscription(
    String id, {
    String? challenge,
    String? format,
  }) async {
    refreshes.add(id);
    throw PlatformException(
      code: 'provider_error',
      message: 'Elarni operation failed.',
    );
  }
}

class MetricsControl extends NoticeControl {
  int packets = 0;
  int stateReads = 0;
  @override
  Future<String> state() async {
    stateReads++;
    return phase;
  }

  @override
  Future<Map<String, Object?>> runtimeMetrics() async {
    metricsReads++;
    return {
      'backend': 'nativeTun2Proxy',
      'state': 'disconnected',
      'counters': {'packetsIn': packets},
    };
  }
}

void main() {
  for (final brightness in Brightness.values) {
    testWidgets(
      'ping badge thresholds and readable colors in ${brightness.name}',
      (tester) async {
        const values = [0, 99, 100, 299, 300, 410];
        final backgrounds = brightness == Brightness.dark
            ? const [Color(0xff173b29), Color(0xff453810), Color(0xff492326)]
            : const [Color(0xffdcfce7), Color(0xfffef9c3), Color(0xfffee2e2)];
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: brightness),
            home: Scaffold(
              body: Column(
                children: [for (final value in values) LatencyBadge(value)],
              ),
            ),
          ),
        );
        for (var i = 0; i < values.length; i++) {
          final badge = find.widgetWithText(LatencyBadge, '${values[i]} ms');
          final box = tester.widget<DecoratedBox>(
            find.descendant(of: badge, matching: find.byType(DecoratedBox)),
          );
          final background = (box.decoration as ShapeDecoration).color!;
          final foreground = tester
              .widget<Text>(
                find.descendant(of: badge, matching: find.byType(Text)),
              )
              .style!
              .color!;
          expect(background, backgrounds[i ~/ 2]);
          final luminances = [
            foreground.computeLuminance(),
            background.computeLuminance(),
          ]..sort();
          expect(
            (luminances.last + .05) / (luminances.first + .05),
            greaterThanOrEqualTo(4.5),
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  test(
    'location uses explicit country labels and leaves ambiguous names alone',
    () {
      for (final name in [
        '🇳🇱 Amsterdam',
        'Netherlands 01',
        'Нидерланды 02',
        'NL-03',
        '[NL] 04',
      ]) {
        expect(ServerLocation.fromName(name)?.code, 'NL', reason: name);
      }
      expect(ServerLocation.fromName('🇺🇸 New York')?.name, 'United States');
      expect(ServerLocation.fromName('United Kingdom 01')?.code, 'GB');
      for (final (name, code) in [
        ('UK London', 'GB'),
        ('[UK] 02', 'GB'),
        ('UAE Dubai', 'AE'),
        ('UAE-01', 'AE'),
        ('ОАЭ 03', 'AE'),
        ('CF | 🇩🇪 Frankfurt', 'DE'),
        ('🇺🇸 New Jersey', 'US'),
        ('🇪🇺 Europe', 'EU'),
        ('EU-01', 'EU'),
        ('European Union 02', 'EU'),
        ('Евросоюз 03', 'EU'),
        // A named member country is more specific than the EU flag.
        ('🇪🇺 🇩🇪 Frankfurt', 'DE'),
      ]) {
        expect(ServerLocation.fromName(name)?.code, code, reason: name);
      }
      for (final name in [
        'Private server',
        'Amsterdam',
        'Fast online',
        'Connect IN seconds',
        '🇳🇱 → 🇩🇪',
        'Netherlands / Germany',
        // Cloudflare and US places, not the Central African Republic or Jersey.
        'CF | Fast',
        'New Jersey 01',
        'Jersey City',
        'New Mexico',
      ]) {
        expect(ServerLocation.fromName(name), isNull, reason: name);
      }
      expect(ServerLocation.displayName('🇳🇱 Amsterdam 01'), 'Amsterdam 01');
      expect(ServerLocation.fromName('🇪🇺')?.name, 'European Union');
    },
  );

  for (final windows in [false, true]) {
    testWidgets(
      'a failed refresh names the provider, the cause and its support link on ${windows ? 'Windows' : 'macOS'}',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1280, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final fixture = countryFixture();
        final daily = fixture.subscriptions.first;
        final control = FailedRefreshControl()
          ..snapshot = SubscriptionSnapshot(
            selectedNodeId: fixture.selectedNodeId,
            subscriptions: [
              SubscriptionGroup(
                id: daily.id,
                name: daily.name,
                status: daily.status,
                metadata: {...daily.metadata, 'expire': 2000000000},
                nodes: daily.nodes,
                actions: const ['support'],
              ),
              fixture.subscriptions.last,
            ],
          );
        await tester.pumpWidget(
          ElarniApp(tunnelControl: control, windows: windows),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('nav-subscriptions')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('refresh-subscription:daily')),
        );
        await tester.pumpAndSettle();
        expect(control.refreshes, ['daily']);
        expect(
          find.text(
            'boVPN’s server reported an error. Nothing is wrong with Elarni or this device; retry later. '
            'The last working servers were kept.',
          ),
          findsOneWidget,
        );
        await tester.tap(find.text('Contact provider'));
        await tester.pumpAndSettle();
        expect(control.links, ['daily:support']);
        final expires = DateTime.fromMillisecondsSinceEpoch(2000000000000);
        expect(
          find.text(
            '4 servers · Provider error · expires ${expires.toLocal().day} May 2033',
          ),
          findsOneWidget,
        );
        await tester.tap(
          find.byKey(const ValueKey('subscription-support:daily')),
        );
        await tester.pumpAndSettle();
        expect(control.links, ['daily:support', 'daily:support']);
        // The other subscription did not fail and says nothing.
        expect(find.text('1 server'), findsOneWidget);
      },
    );
  }

  testWidgets('EU location renders the EU flag', (tester) async {
    await tester.pumpWidget(
      LocationFlag(location: ServerLocation.fromName('🇪🇺 Europe')),
    );
    expect(tester.widget<CountryFlag>(find.byType(CountryFlag)).flagCode, 'eu');
  });

  for (final windows in [false, true]) {
    testWidgets(
      'focused subscriptions disclose data and servers without selecting on ${windows ? 'Windows' : 'macOS'}',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1280, 1400));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final fixture = countryFixture();
        final control = NoticeControl()
          ..phase = 'connected'
          ..routingSnapshot = const RoutingSnapshot(
            profiles: [
              RoutingProfile(
                id: 'routing',
                name: 'RoscomVPN',
                source: 'manual',
                enabled: true,
                edited: false,
                geofileStatus: 'ready',
                reductionStatus: 'ready',
                json: '{}',
              ),
            ],
            assignments: {},
          )
          ..snapshot = SubscriptionSnapshot(
            selectedNodeId: fixture.selectedNodeId,
            subscriptions: [
              for (final group in fixture.subscriptions)
                SubscriptionGroup(
                  id: group.id,
                  name: group.name,
                  status: group.status,
                  metadata: {
                    ...group.metadata,
                    'total': 100 * 1073741824,
                    'upload': 10 * 1073741824,
                    'download': 20 * 1073741824,
                    'expire': 0,
                    'dnsNotice': 'Provider DNS fixture notice',
                    'updateIntervalHours': 6,
                  },
                  nodes: group.nodes,
                  actions: group.actions,
                ),
            ],
          )
          ..onPing = (id) async => PingResult(
            nodeId: id,
            status: 'success',
            latencyMs: 71,
            timestamp: DateTime.now().millisecondsSinceEpoch / 1000,
          );
        await tester.pumpWidget(
          ElarniApp(tunnelControl: control, windows: windows),
        );
        await tester.pumpAndSettle();
        // Launch tests only open groups; opening these tests their servers.
        for (final id in ['daily:NL', 'travel:NL']) {
          await reveal(tester, find.byKey(ValueKey('country:$id::all')));
          await tester.tap(find.byKey(ValueKey('country:$id::all')));
          await tester.pumpAndSettle();
        }
        expect(
          tester
              .widget<LinearProgressIndicator>(
                find.byKey(const Key('subscription-data-progress')),
              )
              .value,
          .7,
        );
        await tester.enterText(
          find.byKey(const Key('node-search')),
          'Netherlands',
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('nav-subscriptions')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('boVPN'));
        await tester.pumpAndSettle();
        final subscription = find.byKey(const ValueKey('subscription:daily'));
        expect(find.textContaining(RegExp(r'^Ready(?: ·|$)')), findsNothing);
        expect(find.byTooltip('Share server'), findsNothing);
        expect(find.text(providerMessage), findsNothing);
        expect(
          find.descendant(
            of: subscription,
            matching: find.byType(LinearProgressIndicator),
          ),
          findsNothing,
        );
        expect(find.text('30.00 GiB'), findsNothing);
        await tester.tap(
          find.byKey(const PageStorageKey('subscription-details:daily')),
        );
        await tester.pumpAndSettle();
        expect(find.text('Data used'), findsOneWidget);
        expect(find.text('30.00 GiB'), findsOneWidget);
        expect(find.text('Quota'), findsOneWidget);
        expect(find.text('100.00 GiB'), findsOneWidget);
        expect(find.text('Expires'), findsOneWidget);
        expect(find.text('No expiry'), findsOneWidget);
        expect(find.text('DNS'), findsOneWidget);
        expect(find.text('Provider DNS fixture notice'), findsOneWidget);
        expect(find.text('Refreshes'), findsOneWidget);
        expect(find.text('Every 6 h'), findsOneWidget);
        expect(find.text('Set by your provider'), findsOneWidget);
        await tester.tap(
          find.byKey(const PageStorageKey('subscription-details:daily')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('No custom routing'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('RoscomVPN').last);
        await tester.pumpAndSettle();
        expect(control.routingActions, ['assign:daily:routing']);
        expect(find.text('RoscomVPN'), findsOneWidget);
        // The servers open with their subscription and still fold by hand.
        final row = find.byKey(const ValueKey('node:nl-vless'));
        expect(row, findsOneWidget);
        final servers = find.descendant(
          of: subscription,
          matching: find.text('Servers'),
        );
        await tester.ensureVisible(servers);
        await tester.tap(servers);
        await tester.pumpAndSettle();
        expect(row, findsNothing);
        expect(
          find.byKey(const PageStorageKey('subscription-search:daily')),
          findsNothing,
        );
        await tester.tap(servers);
        await tester.pumpAndSettle();
        final flag = find.descendant(
          of: row,
          matching: find.byType(LocationFlag),
        );
        expect(tester.widget<LocationFlag>(flag).location?.code, 'NL');
        expect(
          find.descendant(
            of: row,
            matching: find.widgetWithText(LatencyBadge, '71 ms'),
          ),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('node:de')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('provider-notice:daily')));
        await tester.pumpAndSettle();
        expect(find.text(providerMessage), findsOneWidget);
        await tester.tap(find.text('boVPN'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('boVPN'));
        await tester.pumpAndSettle();
        expect(find.text(providerMessage), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('provider-notice:daily')));
        await tester.pumpAndSettle();
        final search = find.byKey(
          const PageStorageKey('subscription-search:daily'),
        );
        await tester.enterText(search, 'Trojan');
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('node:nl-trojan')), findsOneWidget);
        expect(row, findsNothing);
        await tester.enterText(search, 'not-present');
        await tester.pumpAndSettle();
        expect(find.text('No matching servers'), findsOneWidget);
        await tester.enterText(search, '');
        await tester.pumpAndSettle();
        control.pingCalls.clear();
        await tester.tap(
          find.byKey(const ValueKey('subscription-ping-all:daily')),
        );
        await tester.pumpAndSettle();
        expect(control.pingCalls.map((call) => call.nodeId), [
          'nl-vless',
          'nl-trojan',
          'de',
          'unknown',
        ]);
        await tester.tap(find.byKey(const ValueKey('ping:nl-vless')));
        await tester.pumpAndSettle();
        expect(control.pingCalls.last.nodeId, 'nl-vless');
        await tester.tap(row);
        await tester.pumpAndSettle();
        expect(control.selectedIDs, isEmpty);
        expect(control.phase, 'connected');
        expect(control.disconnectCalls, 0);
        await tester.tap(
          find.byKey(const ValueKey('subscription-actions:daily')),
        );
        await tester.pumpAndSettle();
        expect(find.text('Share subscription'), findsOneWidget);
        expect(find.text('Share server'), findsNothing);
        await tester.tap(find.text('Download options'));
        await tester.pumpAndSettle();
        expect(
          find.widgetWithText(TextField, 'Fallback hosts'),
          findsOneWidget,
        );
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('nav-home')));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('node-search')))
              .controller!
              .text,
          'Netherlands',
        );
        expect(find.byKey(const ValueKey('node:de')), findsNothing);
        expect(
          find.byKey(const ValueKey('country-ping:travel:NL')),
          findsOneWidget,
        );
        expect(control.connectCalls, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'unchanged state and nested metrics preserve the server list on ${windows ? 'Windows' : 'macOS'}',
      (tester) async {
        final messenger = tester.binding.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(DesktopIntegration.channel, (
          call,
        ) async {
          return call.method == 'getPreferences' ? '{}' : null;
        });
        addTearDown(
          () => messenger.setMockMethodCallHandler(
            DesktopIntegration.channel,
            null,
          ),
        );
        await tester.binding.setSurfaceSize(const Size(1280, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final control = MetricsControl()..snapshot = countryFixture();
        control.settings = control.settings.copyWith(monitoringEnabled: true);
        await tester.pumpWidget(
          ElarniApp(tunnelControl: control, windows: windows),
        );
        await tester.pumpAndSettle();
        final country = find.byKey(const ValueKey('country:daily:DE::all'));
        final initial = tester.widget(country);
        final reads = control.metricsReads;
        final stateReads = control.stateReads;
        await tester.pump(const Duration(seconds: 4));
        await tester.pumpAndSettle();
        expect(control.metricsReads, greaterThan(reads));
        expect(control.stateReads, greaterThan(stateReads));
        expect(tester.widget(country), same(initial));
        control.packets = 1;
        await tester.pump(const Duration(seconds: 2));
        await tester.pumpAndSettle();
        expect(tester.widget(country), isNot(same(initial)));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'an unchanged unavailable state does not rebuild the server list on ${windows ? 'Windows' : 'macOS'}',
      (tester) async {
        final messenger = tester.binding.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(DesktopIntegration.channel, (
          call,
        ) async {
          return call.method == 'getPreferences' ? '{}' : null;
        });
        addTearDown(
          () => messenger.setMockMethodCallHandler(
            DesktopIntegration.channel,
            null,
          ),
        );
        await tester.binding.setSurfaceSize(const Size(1280, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final control = MetricsControl()
          ..snapshot = countryFixture()
          ..phase = 'unavailable';
        await tester.pumpWidget(
          ElarniApp(tunnelControl: control, windows: windows),
        );
        await tester.pumpAndSettle();
        expect(find.text('Connection status unavailable'), findsWidgets);
        final country = find.byKey(const ValueKey('country:daily:DE::all'));
        final initial = tester.widget(country);
        final stateReads = control.stateReads;
        await tester.pump(const Duration(seconds: 4));
        await tester.pumpAndSettle();
        expect(control.stateReads, greaterThan(stateReads));
        expect(tester.widget(country), same(initial));
        control.phase = 'disconnected';
        await tester.pump(const Duration(seconds: 2));
        await tester.pumpAndSettle();
        expect(find.text('Connection status unavailable'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'state polling continues when desktop preferences are unreadable on ${windows ? 'Windows' : 'macOS'}',
      (tester) async {
        final messenger = tester.binding.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(DesktopIntegration.channel, (
          call,
        ) async {
          // An unknown accent fails validation; the native host still answers.
          return call.method == 'getPreferences'
              ? '{"accent":"unknown"}'
              : null;
        });
        addTearDown(
          () => messenger.setMockMethodCallHandler(
            DesktopIntegration.channel,
            null,
          ),
        );
        await tester.binding.setSurfaceSize(const Size(1280, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final control = MetricsControl()..snapshot = countryFixture();
        await tester.pumpWidget(
          ElarniApp(tunnelControl: control, windows: windows),
        );
        await tester.pumpAndSettle();
        final stateReads = control.stateReads;
        await tester.pump(const Duration(seconds: 3));
        await tester.pumpAndSettle();
        expect(control.stateReads, greaterThan(stateReads));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'startup TCP shows only successful country minimums on ${windows ? 'Windows' : 'macOS'}',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1280, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final pending = <String, Completer<PingResult>>{};
        final control = NoticeControl()..snapshot = countryFixture();
        control.onPing = (id) => (pending[id] = Completer<PingResult>()).future;
        await tester.pumpWidget(
          ElarniApp(tunnelControl: control, windows: windows),
        );
        await tester.pumpAndSettle();
        // Launch tests the open groups: the selected country and the unnamed server.
        expect(pending.keys, ['de', 'unknown']);
        expect(
          find.byKey(const ValueKey('country-ping:daily:NL')),
          findsNothing,
        );
        expect(
          tester
              .widget<IconButton>(find.byKey(const Key('ping-all')))
              .onPressed,
          isNull,
        );
        expect(
          tester
              .widget<FilledButton>(find.byKey(const Key('connection-toggle')))
              .onPressed,
          isNotNull,
        );
        // A group opened during the launch test is tested after it.
        await tester.tap(find.byKey(const ValueKey('country:daily:NL::all')));
        await tester.pumpAndSettle();
        expect(pending.keys, ['de', 'unknown']);
        for (final id in ['de', 'unknown']) {
          pending[id]!.complete(
            PingResult(
              nodeId: id,
              status: id == 'unknown' ? 'failed' : 'success',
              latencyMs: id == 'unknown' ? 1 : 0,
              timestamp: DateTime.now().millisecondsSinceEpoch / 1000,
            ),
          );
        }
        await tester.pumpAndSettle();
        expect(pending.keys, ['de', 'unknown', 'nl-vless', 'nl-trojan']);
        expect(
          find.byKey(const ValueKey('country-ping:daily:NL')),
          findsNothing,
        );
        pending['nl-trojan']!.complete(
          PingResult(
            nodeId: 'nl-trojan',
            status: 'success',
            latencyMs: 80,
            timestamp: DateTime.now().millisecondsSinceEpoch / 1000,
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('country-ping:daily:NL')))
              .data,
          '80 ms',
        );
        pending['nl-vless']!.complete(
          PingResult(
            nodeId: 'nl-vless',
            status: 'success',
            latencyMs: -1,
            timestamp: DateTime.now().millisecondsSinceEpoch / 1000,
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('country-ping:daily:NL')))
              .data,
          '80 ms',
        );
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('country-ping:daily:DE')))
              .data,
          '0 ms',
        );
        expect(
          find.byKey(const ValueKey('country-ping:daily:other')),
          findsNothing,
        );
        expect(find.textContaining('Tested '), findsNothing);
        expect(control.connectCalls, 0);
        expect(control.disconnectCalls, 0);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'countries disclose every provider and protocol on ${windows ? 'Windows' : 'macOS'}',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1280, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final control = NoticeControl()..snapshot = countryFixture();
        final pinged = <String>[];
        control.onPing = (id) async {
          pinged.add(id);
          return PingResult(
            nodeId: id,
            status: 'success',
            latencyMs: 24,
            timestamp: DateTime.now().millisecondsSinceEpoch / 1000,
          );
        };
        await tester.pumpWidget(
          ElarniApp(tunnelControl: control, windows: windows),
        );
        await tester.pumpAndSettle();
        expect(pinged, ['de', 'unknown']);
        expect(
          control.pingCalls.every((call) => call.protocol == 'tcp'),
          isTrue,
        );
        expect(find.textContaining('Tested '), findsNothing);
        pinged.clear();
        control.importListener!(null);
        await tester.pumpAndSettle();
        expect(
          pinged,
          isEmpty,
          reason: 'Reloads must not repeat startup probes',
        );
        expect(find.text('Netherlands'), findsOneWidget);
        expect(find.text('2 servers'), findsOneWidget);
        expect(find.textContaining('Selected'), findsNothing);
        Color? countryColor(String id) => tester
            .widget<Material>(find.byKey(ValueKey('country:$id::all')))
            .color;
        final selectedColor = countryColor('daily:DE');
        expect(selectedColor, isNot(Colors.transparent));
        // The selected country keeps its color closed and open.
        for (var i = 0; i < 2; i++) {
          await tester.tap(find.byKey(const ValueKey('country:daily:DE::all')));
          await tester.pumpAndSettle();
          expect(countryColor('daily:DE'), selectedColor);
        }
        expect(countryColor('daily:NL'), Colors.transparent);
        expect(find.byKey(const ValueKey('node:nl-vless')), findsNothing);
        expect(find.byKey(const ValueKey('node:de')), findsOneWidget);
        expect(find.text('Other locations'), findsOneWidget);
        await tester.tap(find.text('Netherlands'));
        await tester.pumpAndSettle();
        for (final id in ['nl-vless', 'nl-trojan']) {
          expect(find.byKey(ValueKey('node:$id')), findsOneWidget);
        }
        // Opening a group tests its servers.
        expect(pinged, ['nl-vless', 'nl-trojan']);
        expect(find.widgetWithText(ProtocolTag, 'Trojan'), findsOneWidget);
        await reveal(
          tester,
          find.byKey(const ValueKey('country:travel:NL::all')),
        );
        await tester.tap(find.byKey(const ValueKey('country:travel:NL::all')));
        await tester.pumpAndSettle();
        expect(pinged, ['nl-vless', 'nl-trojan', 'nl-vmess']);
        pinged.clear();
        expect(find.widgetWithText(ProtocolTag, 'VMess'), findsOneWidget);
        final foreignNode = find.byKey(const ValueKey('node:nl-vmess'));
        expect(
          find.descendant(of: foreignNode, matching: find.text('Travel')),
          findsOneWidget,
        );
        await tester.ensureVisible(find.byKey(const ValueKey('ping:nl-vmess')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('ping:nl-vmess')));
        await tester.pumpAndSettle();
        expect(pinged, ['nl-vmess']);
        await tester.tap(foreignNode);
        await tester.pumpAndSettle();
        expect(control.selectedIDs, ['nl-vmess']);
        expect(control.connectCalls, 0);
        expect(control.disconnectCalls, 0);
        await tester.tap(
          find.descendant(
            of: find.byKey(const ValueKey('country:travel:NL::all')),
            matching: find.text('Netherlands'),
          ),
        );
        await tester.pumpAndSettle();
        expect(foreignNode, findsNothing);
        await tester.enterText(
          find.byKey(const Key('node-search')),
          'Netherlands',
        );
        await tester.pumpAndSettle();
        expect(foreignNode, findsOneWidget);
        expect(find.byKey(const ValueKey('node:nl-vless')), findsOneWidget);
        expect(find.byKey(const ValueKey('node:de')), findsNothing);
        await tester.enterText(find.byKey(const Key('node-search')), 'Trojan');
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('node:nl-trojan')), findsOneWidget);
        expect(find.byKey(const ValueKey('node:nl-vless')), findsNothing);
        await tester.enterText(
          find.byKey(const Key('node-search')),
          'not-present',
        );
        await tester.pumpAndSettle();
        expect(find.text('No matching servers'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'provider notice preview, full copy and actions on ${windows ? 'Windows' : 'macOS'}',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1280, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final control = NoticeControl()..snapshot = countryFixture();
        await tester.pumpWidget(
          ElarniApp(tunnelControl: control, windows: windows),
        );
        await tester.pumpAndSettle();
        expect(find.text('Message from boVPN'), findsOneWidget);
        expect(find.byType(SelectableText), findsNothing);
        final refresh = find.byKey(
          const ValueKey('refresh-subscription:daily'),
        );
        final notice = find.byKey(const ValueKey('provider-notice:daily'));
        expect(refresh.hitTestable(), findsOneWidget);
        expect(find.descendant(of: notice, matching: refresh), findsNothing);
        expect(
          tester.getCenter(refresh).dx,
          greaterThan(tester.getCenter(find.text('Servers')).dx),
        );
        expect(
          (tester.getCenter(refresh).dy -
                  tester
                      .getCenter(
                        find.byKey(const ValueKey('server-subscription:daily')),
                      )
                      .dy)
              .abs(),
          lessThan(16),
        );
        expect(
          find.byKey(const ValueKey('notice-refresh:daily')),
          findsNothing,
        );
        await tester.tap(refresh);
        await tester.pumpAndSettle();
        expect(control.refreshes, ['daily']);
        await tester.tap(find.text('Message from boVPN'));
        await tester.pumpAndSettle();
        expect(find.text(providerMessage), findsOneWidget);
        expect(find.text('Provider maintenance details'), findsOneWidget);
        await tester.ensureVisible(find.text('Provider page'));
        await tester.tap(find.text('Provider page'));
        await tester.pumpAndSettle();
        expect(control.links, ['daily:banner']);
        await tester.tap(refresh);
        await tester.pumpAndSettle();
        expect(control.refreshes, ['daily', 'daily']);
        expect(control.connectCalls, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'latency order stays within subscriptions and keeps invalid results last',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        DesktopIntegration.channel,
        (call) async => call.method == 'getPreferences'
            ? jsonEncode({'sort': 'latency'})
            : null,
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          DesktopIntegration.channel,
          null,
        ),
      );
      final control = NoticeControl()..snapshot = countryFixture();
      control.onPing = (id) async => PingResult(
        nodeId: id,
        status: 'success',
        latencyMs: {'nl-vless': -1, 'nl-trojan': 80, 'nl-vmess': 24}[id] ?? 100,
        timestamp: DateTime.now().millisecondsSinceEpoch / 1000,
      );
      await tester.pumpWidget(ElarniApp(tunnelControl: control));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('node-search')),
        'Netherlands',
      );
      await tester.tap(find.byKey(const Key('ping-all')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('country-ping:daily:NL')))
            .data,
        '80 ms',
      );
      // Rows just past the viewport are built but offstage.
      double top(String id) => tester
          .getTopLeft(find.byKey(ValueKey('node:$id'), skipOffstage: false))
          .dy;
      expect(top('nl-vmess'), greaterThan(top('nl-vless')));
      expect(top('nl-trojan'), lessThan(top('nl-vless')));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('country and notice controls wrap at enlarged desktop text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 760));
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    addTearDown(() async {
      tester.platformDispatcher.clearTextScaleFactorTestValue();
      await tester.binding.setSurfaceSize(null);
    });
    await tester.pumpWidget(
      ElarniApp(tunnelControl: NoticeControl()..snapshot = countryFixture()),
    );
    await tester.pumpAndSettle();
    await reveal(tester, find.text('Message from boVPN'));
    expect(find.text('Message from boVPN').hitTestable(), findsOneWidget);
    await tester.tap(find.text('Message from boVPN'));
    await tester.pumpAndSettle();
    expect(find.text(providerMessage), findsOneWidget);
    await reveal(tester, find.text('Netherlands'));
    await tester.tap(find.text('Netherlands'));
    await tester.pumpAndSettle();
    await reveal(tester, find.byKey(const ValueKey('node:nl-trojan')));
    expect(tester.takeException(), isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a subscription header opens and closes its countries', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final control = NoticeControl()..snapshot = countryFixture();
    await tester.pumpWidget(ElarniApp(tunnelControl: control, windows: true));
    await tester.pumpAndSettle();
    Finder country(String id) => find.byKey(ValueKey('country:$id::all'));
    final header = find.byKey(const ValueKey('server-subscription:daily'));
    final selected = find.byKey(const ValueKey('node:de'));
    expect(country('daily:NL'), findsOneWidget);
    expect(selected, findsOneWidget);
    await tester.tap(header);
    await tester.pumpAndSettle();
    expect(country('daily:NL'), findsNothing);
    expect(selected, findsNothing);
    expect(country('travel:NL'), findsOneWidget);
    // Refreshing a closed subscription leaves it closed.
    await tester.tap(find.byKey(const ValueKey('refresh-subscription:daily')));
    await tester.pumpAndSettle();
    expect(control.refreshes, ['daily']);
    expect(selected, findsNothing);
    // A search shows every match, then the subscription closes again.
    await tester.enterText(find.byKey(const Key('node-search')), 'Frankfurt');
    await tester.pumpAndSettle();
    expect(selected, findsOneWidget);
    await tester.enterText(find.byKey(const Key('node-search')), '');
    await tester.pumpAndSettle();
    expect(selected, findsNothing);
    await tester.tap(header);
    await tester.pumpAndSettle();
    expect(selected, findsOneWidget);
    expect(control.selectedIDs, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final windows in [true, false]) {
    testWidgets(
      'server config shows, rejects and saves edits on ${windows ? 'Windows' : 'macOS'}',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1280, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final fixture = countryFixture();
        final control = NoticeControl()
          ..nodeConfigText = '{\n  "outbounds": [{"protocol": "vless"}]\n}'
          ..snapshot = SubscriptionSnapshot(
            selectedNodeId: fixture.selectedNodeId,
            subscriptions: [
              fixture.subscriptions.first,
              SubscriptionGroup(
                id: 'travel',
                name: 'Travel',
                status: 'ready',
                metadata: const {'hideURL': true},
                nodes: [server('nl-vmess', 'NL Rotterdam', 'VMess')],
              ),
            ],
          );
        await tester.pumpWidget(
          ElarniApp(tunnelControl: control, windows: windows),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('nav-subscriptions')));
        await tester.pumpAndSettle();
        for (final id in ['daily', 'travel']) {
          await tester.tap(
            find.descendant(
              of: find.byKey(ValueKey('subscription:$id')),
              matching: find.text(id == 'daily' ? 'boVPN' : 'Travel'),
            ),
          );
          await tester.pumpAndSettle();
        }
        // A provider that hides its configs gets no button.
        expect(find.byKey(const ValueKey('node:nl-vmess')), findsOneWidget);
        expect(
          find.byKey(const ValueKey('node-config:nl-vmess')),
          findsNothing,
        );
        final button = find.byKey(const ValueKey('node-config:de'));
        if (!windows) {
          expect(find.byKey(const ValueKey('node:de')), findsOneWidget);
          expect(button, findsNothing);
          await tester.pumpWidget(const SizedBox());
          return;
        }
        await reveal(tester, button);
        await tester.tap(button);
        await tester.pumpAndSettle();
        final field = find.byKey(const Key('node-config-json'));
        expect(
          tester.widget<TextField>(field).controller!.text,
          control.nodeConfigText,
        );
        expect(
          find.text('boVPN’s next refresh replaces your edits.'),
          findsOneWidget,
        );
        const edit = '{"outbounds": [{"protocol": "trojan"}]}';
        await tester.enterText(field, edit);
        control.nodeConfigError = PlatformException(code: 'invalid_profile');
        await tester.tap(find.text('Validate and save'));
        await tester.pumpAndSettle();
        // A refused edit keeps the dialog and its text.
        expect(field, findsOneWidget);
        expect(tester.widget<TextField>(field).controller!.text, edit);
        expect(
          find.text(
            'Config not saved. It must be valid Xray JSON for one server.',
          ),
          findsOneWidget,
        );
        control.nodeConfigError = null;
        await tester.tap(find.text('Validate and save'));
        await tester.pumpAndSettle();
        expect(control.nodeConfigEdits, [('de', edit), ('de', edit)]);
        expect(field, findsNothing);
        expect(control.selectedIDs, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
