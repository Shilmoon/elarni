import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:elarni/desktop_integration.dart';
import 'package:elarni/elarni_app.dart';
import 'package:elarni/tunnel_channel.dart';
import 'support/fake_tunnel_control.dart';

const routingFixture = RoutingSnapshot(
  profiles: [
    RoutingProfile(
      id: 'route',
      name: 'Everyday routing',
      source: 'subscription',
      edited: false,
      enabled: true,
      geofileStatus: 'ready',
      reductionStatus: 'reduced',
      json:
          '{"Name":"Everyday routing","RemoteDNSType":"DoU","RemoteDNSIP":"1.1.1.1","DomesticDNSType":"DoU","DomesticDNSIP":"8.8.8.8"}',
      geofiles: [
        {
          'name': 'geoip',
          'bytes': 363273,
          'originalBytes': 430388,
          'source': 'https://example.com/geoip.dat',
          'updatedAt': '2026-09-12T00:00:00Z',
        },
      ],
    ),
  ],
  assignments: {'group': 'route'},
);

class EditableRoutingControl extends FakeTunnelControl {
  String? savedRouting;

  @override
  Future<RoutingSnapshot> updateRoutingProfile(
    String id,
    String content,
  ) async {
    savedRouting = content;
    return routingSnapshot;
  }
}

void main() {
  for (final windows in [false, true]) {
    Future<void> mount(WidgetTester tester, FakeTunnelControl control) async {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ElarniApp(tunnelControl: control, windows: windows),
      );
      await tester.pumpAndSettle();
    }

    testWidgets(
      'routing ownership groups keep duplicate names and unassociated profiles reachable ($windows)',
      (tester) async {
        RoutingProfile profile(String id, String? owner) => RoutingProfile(
          id: id,
          name: 'Same routing',
          source: owner == null ? 'custom' : 'subscription',
          providerSubscriptionId: owner,
          edited: false,
          enabled: true,
          geofileStatus: 'ready',
          json: routingFixture.profiles.single.json,
        );
        final control = FakeTunnelControl()
          ..snapshot = const SubscriptionSnapshot(
            subscriptions: [
              SubscriptionGroup(
                id: 'one',
                name: 'BoVpn',
                status: 'ready',
                nodes: [],
              ),
              SubscriptionGroup(
                id: 'two',
                name: 'Second provider',
                status: 'ready',
                nodes: [],
              ),
            ],
          )
          ..routingSnapshot = RoutingSnapshot(
            profiles: [
              profile('a', 'one'),
              profile('b', 'two'),
              profile('c', 'one'),
              profile('local', null),
              profile('orphan', 'deleted-provider'),
            ],
            assignments: const {'two': 'a'},
          );
        await mount(tester, control);
        await tester.tap(find.byKey(const Key('nav-routing')));
        await tester.pumpAndSettle();
        expect(find.text('Choose how your traffic is routed.'), findsNothing);
        final first = find.byKey(const ValueKey('routing-group:one'));
        final second = find.byKey(const ValueKey('routing-group:two'));
        for (final id in ['a', 'c']) {
          expect(
            find.descendant(
              of: first,
              matching: find.byKey(ValueKey('routing:$id')),
            ),
            findsOneWidget,
          );
        }
        expect(
          find.descendant(
            of: second,
            matching: find.byKey(const ValueKey('routing:b')),
          ),
          findsOneWidget,
        );
        for (final id in ['local', 'orphan']) {
          expect(find.byKey(ValueKey('routing:$id')), findsOneWidget);
        }
        final enabled = find.byKey(const ValueKey('routing-enabled:b'));
        expect(tester.widget(enabled), isA<Checkbox>());
        await tester.tap(enabled);
        await tester.pumpAndSettle();
        expect(control.routingActions, ['enable:b:false']);
        // Each subscription's profiles fold away under its name.
        final owner = find.descendant(of: first, matching: find.text('BoVpn'));
        await tester.tap(owner);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('routing:a')), findsNothing);
        expect(find.byKey(const ValueKey('routing:c')), findsNothing);
        expect(find.byKey(const ValueKey('routing:b')), findsOneWidget);
        await tester.tap(owner);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('routing:a')), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'routing editor retains draft across Rules DNS and Advanced sections ($windows)',
      (tester) async {
        final control = EditableRoutingControl()
          ..routingSnapshot = routingFixture;
        await mount(tester, control);
        await tester.tap(find.byKey(const Key('nav-routing')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Everyday routing'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('routing-field:DirectSites')),
          'domain:example.org',
        );
        await tester.tap(find.text('DNS'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('routing-field:RemoteDNSIP')),
          '9.9.9.9',
        );
        await tester.tap(find.text('Advanced'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextField, 'Profile name'),
          'Draft name',
        );
        await tester.tap(find.text('Rules'));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextField>(
                find.byKey(const ValueKey('routing-field:DirectSites')),
              )
              .controller!
              .text,
          'domain:example.org',
        );
        await tester.tap(find.text('Validate and save'));
        await tester.pumpAndSettle();
        final saved = jsonDecode(control.savedRouting!) as Map;
        expect(saved['Name'], 'Draft name');
        expect(saved['RemoteDNSIP'], '9.9.9.9');
        expect(saved['DirectSites'], ['domain:example.org']);
        expect(find.byType(AlertDialog), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'one import menu dispatches each source and preserves cancellation ($windows)',
      (tester) async {
        final control = FakeTunnelControl();
        await mount(tester, control);
        final messenger = tester.binding.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async => call.method == 'Clipboard.getData'
              ? {'text': '  synthetic profile\n'}
              : null,
        );
        addTearDown(
          () =>
              messenger.setMockMethodCallHandler(SystemChannels.platform, null),
        );
        expect(find.byKey(const Key('open-settings')), findsNothing);
        expect(find.byKey(const Key('add-subscription-toggle')), findsNothing);
        for (final source in ['clipboard', 'file', 'qrImage', 'camera']) {
          await tester.tap(find.byKey(const Key('import-toggle')));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(Key('import-$source')));
          await tester.pumpAndSettle();
        }
        expect(control.importedSources, ['text', 'file', 'qrImage', 'camera']);
        expect(control.importedProfiles, [
          'synthetic profile',
          null,
          null,
          null,
        ]);
        expect(find.text('synthetic profile'), findsNothing);
        control.importError = PlatformException(code: 'cancelled');
        await tester.tap(find.byKey(const Key('import-toggle')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('import-file')));
        await tester.pumpAndSettle();
        expect(find.byTooltip('Dismiss message'), findsNothing);
        expect(find.byKey(const ValueKey('node:a')), findsOneWidget);
        expect(control.connectCalls, 0);
        expect(control.disconnectCalls, 0);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'a cancelled camera scan stays silent like a cancelled file ($windows)',
      (tester) async {
        final control = FakeTunnelControl();
        await mount(tester, control);
        // macOS reports a cancelled camera scan as operation_cancelled.
        control.importError = PlatformException(code: 'operation_cancelled');
        await tester.tap(find.byKey(const Key('import-toggle')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('import-camera')));
        await tester.pumpAndSettle();
        expect(find.byTooltip('Dismiss message'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'routing stays compact while every action and file detail is available ($windows)',
      (tester) async {
        final control = FakeTunnelControl()..routingSnapshot = routingFixture;
        await mount(tester, control);
        await tester.tap(find.byKey(const Key('nav-routing')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('routing-list')), findsOneWidget);
        expect(find.text('Everyday routing'), findsOneWidget);
        expect(find.textContaining('363273'), findsNothing);
        expect(find.textContaining('https://example.com'), findsNothing);
        // Refresh sits on the title's row.
        expect(
          (tester.getCenter(find.byTooltip('Refresh profiles')).dy -
                  tester
                      .getCenter(
                        find.descendant(
                          of: find.byKey(const ValueKey('routing-list')),
                          matching: find.text('Routing'),
                        ),
                      )
                      .dy)
              .abs(),
          lessThan(8),
        );
        await tester.tap(find.byTooltip('Refresh profiles'));
        await tester.pumpAndSettle();
        expect(control.routingReads, 2);
        await tester.tap(find.byKey(const ValueKey('routing-enabled:route')));
        await tester.pumpAndSettle();
        expect(control.routingActions, ['enable:route:false']);
        Future<void> action(String label) async {
          await tester.tap(find.byKey(const ValueKey('routing-actions:route')));
          await tester.pumpAndSettle();
          await tester.tap(find.text(label));
          await tester.pumpAndSettle();
        }

        await action('Profile details');
        expect(find.textContaining('363273'), findsOneWidget);
        expect(find.text('https://example.com/geoip.dat'), findsOneWidget);
        await tester.tap(find.byTooltip('Refresh geoip'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Done'));
        await tester.pumpAndSettle();
        for (final label in ['Refresh routing data', 'Duplicate']) {
          await action(label);
        }
        // Destructive actions ask first; Cancel leaves the profile alone.
        await action('Delete');
        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text('Cancel'),
          ),
        );
        await tester.pumpAndSettle();
        for (final (label, confirm) in [
          ('Reset to subscription version', 'Reset'),
          ('Delete', 'Delete'),
        ]) {
          await action(label);
          await tester.tap(find.widgetWithText(FilledButton, confirm));
          await tester.pumpAndSettle();
        }
        expect(control.routingActions, [
          'enable:route:false',
          'refresh:route:geoip',
          'refresh:route:all',
          'duplicate:route',
          'reset:route',
          'delete:route',
        ]);
        await action('Edit JSON');
        expect(find.byType(AlertDialog), findsOneWidget);
        await tester.tap(find.text('Cancel').last);
        await tester.pumpAndSettle();
        await action('Edit routing and DNS');
        expect(find.text('Rules'), findsOneWidget);
        expect(find.text('DNS'), findsOneWidget);
        expect(find.text('Advanced'), findsOneWidget);
        await tester.tap(find.text('Cancel').last);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'routing details survive the profile being removed while open ($windows)',
      (tester) async {
        final control = FakeTunnelControl()..routingSnapshot = routingFixture;
        await mount(tester, control);
        await tester.tap(find.byKey(const Key('nav-routing')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('routing-actions:route')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Profile details'));
        await tester.pumpAndSettle();
        control.routingSnapshot = const RoutingSnapshot(
          profiles: [],
          assignments: {},
        );
        await tester.tap(find.byTooltip('Refresh geoip'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          find.text('This routing profile no longer exists.'),
          findsOneWidget,
        );
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
      },
    );

    // Windows and Linux report a provider's profile as 'provider', macOS as 'subscription'.
    testWidgets('a provider routing profile can be reset ($windows)', (
      tester,
    ) async {
      final control = FakeTunnelControl()
        ..routingSnapshot = RoutingSnapshot(
          profiles: [
            RoutingProfile.fromMap({
              'id': 'route',
              'name': 'Everyday routing',
              'source': 'provider',
              'edited': true,
              'enabled': true,
              'geofileStatus': 'ready',
              'json': routingFixture.profiles.single.json,
            }),
          ],
          assignments: const {},
        );
      await mount(tester, control);
      await tester.tap(find.byKey(const Key('nav-routing')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Subscription · Edited'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('routing-actions:route')));
      await tester.pumpAndSettle();
      expect(find.text('Reset to subscription version'), findsOneWidget);
    });

    testWidgets('a routing save waits for a tray Connect ($windows)', (
      tester,
    ) async {
      final connecting = Completer<String>();
      final control = FakeTunnelControl()
        ..routingSnapshot = routingFixture
        ..onConnect = () => connecting.future;
      await mount(tester, control);
      await tester.tap(find.byKey(const Key('nav-routing')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Everyday routing'));
      await tester.pumpAndSettle();
      const channel = DesktopIntegration.channel;
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(const MethodCall('action', 'connect')),
        null,
      );
      await tester.pump();
      expect(control.connectCalls, 1);
      await tester.tap(find.text('Validate and save'));
      await tester.pump();
      // Saving would take Connect's busy flag and drop its result.
      expect(control.routingActions, isEmpty);
      control.phase = 'connected';
      connecting.complete('connected');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Validate and save'));
      await tester.pumpAndSettle();
      expect(control.routingActions, ['update:route']);
    });

    testWidgets('routing shows why managed lists were not updated ($windows)', (
      tester,
    ) async {
      const reason = 'This source needs approval before it can be contacted.';
      final control = FakeTunnelControl()
        ..routingSnapshot = RoutingSnapshot(
          profiles: [
            RoutingProfile.fromMap({
              'id': 'route',
              'name': 'Everyday routing',
              'source': 'subscription',
              'edited': false,
              'enabled': true,
              'geofileStatus': 'ready',
              'json': routingFixture.profiles.single.json,
              'managedError': reason,
            }),
          ],
          assignments: const {},
        );
      await mount(tester, control);
      await tester.tap(find.byKey(const Key('nav-routing')));
      await tester.pumpAndSettle();
      expect(find.text('Managed lists need attention'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('routing-actions:route')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Profile details'));
      await tester.pumpAndSettle();
      expect(find.text('Managed lists: $reason'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'pending import blocks duplicates and selects newly imported routing ($windows)',
      (tester) async {
        final pending = Completer<SubscriptionOperationResult>();
        final control = FakeTunnelControl()
          ..onImport = (_, _) => pending.future;
        await mount(tester, control);
        await tester.tap(find.byKey(const Key('import-toggle')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('import-file')));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<OutlinedButton>(find.byKey(const Key('import-toggle')))
              .onPressed,
          isNull,
        );
        expect(control.importedSources, ['file']);
        control.routingSnapshot = routingFixture;
        pending.complete(
          SubscriptionOperationResult(snapshot: control.snapshot),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('routing-list')), findsOneWidget);
        expect(find.text('Everyday routing'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
