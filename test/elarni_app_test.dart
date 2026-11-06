import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:elarni/elarni_widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:elarni/desktop_integration.dart';
import 'package:elarni/elarni_app.dart';
import 'package:elarni/tunnel_channel.dart';
import 'support/fake_tunnel_control.dart';

Future<void> pumpApp(
  WidgetTester tester,
  FakeTunnelControl control, {
  bool windows = false,
}) async {
  await tester.binding.setSurfaceSize(const Size(1200, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(ElarniApp(tunnelControl: control, windows: windows));
  await tester.pumpAndSettle();
}

Future<void> reveal(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isNotEmpty) {
    await tester.ensureVisible(finder.first);
    await tester.pumpAndSettle();
    return;
  }
  final servers = find.descendant(
    of: find.byKey(const ValueKey('servers-list')),
    matching: find.byType(Scrollable),
  );
  final settings = find.descendant(
    of: find.byWidgetPredicate(
      (widget) =>
          widget is ListView &&
          widget.key is ValueKey<String> &&
          (widget.key! as ValueKey<String>).value.startsWith('settings-list-'),
    ),
    matching: find.byType(Scrollable),
  );
  await tester.scrollUntilVisible(
    finder,
    400,
    scrollable: servers.evaluate().isNotEmpty
        ? servers
        : settings.evaluate().isNotEmpty
        ? settings.first
        : find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

Future<void> openSubscriptions(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('nav-subscriptions')));
  await tester.pumpAndSettle();
}

Future<void> openRouting(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('nav-routing')));
  await tester.pumpAndSettle();
}

Future<void> openSettings(WidgetTester tester) async {
  final button = find.byKey(const Key('nav-settings'));
  if (button.evaluate().isNotEmpty) {
    await tester.tap(button);
    await tester.pumpAndSettle();
  }
}

Future<void> closeSettings(WidgetTester tester) async {
  // Narrow windows go back; wide ones use the sidebar.
  final back = find.byKey(const Key('settings-back'));
  final button = back.evaluate().isNotEmpty
      ? back
      : find.byKey(const Key('nav-home'));
  if (button.evaluate().isNotEmpty) {
    await tester.tap(button);
    await tester.pumpAndSettle();
  }
}

Future<void> openImport(WidgetTester tester) async {
  await closeSettings(tester);
  await tester.tap(find.byKey(const Key('import-toggle')));
  await tester.pumpAndSettle();
}

Future<void> importClipboard(WidgetTester tester, String text) async {
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async => call.method == 'Clipboard.getData' ? {'text': text} : null,
  );
  addTearDown(
    () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
  );
  await openImport(tester);
  await tester.tap(find.byKey(const Key('import-clipboard')));
  await tester.pumpAndSettle();
}

Future<void> selectCategory(
  WidgetTester tester,
  SettingsCategory category,
) async {
  final tab = find.byKey(Key('settings-tab-${category.name}'));
  if (tab.evaluate().isNotEmpty) {
    await tester.ensureVisible(tab);
    await tester.tap(tab);
  } else {
    await tester.tap(find.byType(ElarniSelect<SettingsCategory>));
    await tester.pumpAndSettle();
    final item = find.widgetWithText(MenuItemButton, category.label);
    await tester.ensureVisible(item);
    await tester.tap(item);
  }
  await tester.pumpAndSettle();
}

Future<void> openPerAppRouting(WidgetTester tester) async {
  await openRouting(tester);
  await tester.tap(find.widgetWithText(Tab, 'Per-app routing'));
  await tester.pumpAndSettle();
}

// Troubleshoot and recovery live in Settings, not on Home.
Future<void> openTroubleshoot(WidgetTester tester) async {
  await openSettings(tester);
  await selectCategory(tester, SettingsCategory.system);
  await reveal(tester, find.text('Troubleshoot connection'));
  await tester.tap(find.text('Troubleshoot connection'));
  await tester.pumpAndSettle();
}

Future<void> openRecovery(WidgetTester tester) async {
  await openSettings(tester);
  await selectCategory(tester, SettingsCategory.general);
  final configure = find.widgetWithText(OutlinedButton, 'Configure').first;
  await reveal(tester, configure);
  await tester.tap(configure);
  await tester.pumpAndSettle();
}

SubscriptionOperationResult warning(String challenge) =>
    SubscriptionOperationResult(
      snapshot: fixtureSubscriptions,
      warning: SubscriptionSafetyWarning(
        subscriptionId: 'group',
        risks: [SubscriptionRisk.loopbackTarget],
        challenge: challenge,
      ),
    );

Future<void> addSubscription(WidgetTester tester) async {
  final control =
      tester.widget<ElarniApp>(find.byType(ElarniApp)).tunnelControl!
          as FakeTunnelControl;
  control.onImport = (_, content) => control.addSubscription(content!);
  await importClipboard(tester, 'https://fixture.example/feed');
}

void main() {
  for (final platform in [TargetPlatform.macOS, TargetPlatform.windows]) {
    // Native traffic checks cannot catch a help click accidentally toggling a
    // setting, inaccessible keyboard help, or overflow with enlarged text.
    testWidgets(
      'settings help preserves controls and supports pointer and keyboard on ${platform.name}',
      (tester) async {
        const fragmentationHelp =
            'VLESS over TCP or XHTTP with TLS or Reality. '
            'XHTTP over HTTP/3 and existing dialer chains are unsupported.';
        const muxHelp =
            'Imported mux settings take precedence. This preference '
            'applies only to VLESS; it does not enable mux for Hysteria.';
        const updateHelp =
            'Updates all subscriptions while Elarni is running. Default: 4 hours.';
        final control = FakeTunnelControl();
        final original = control.settings.toMap();
        await tester.binding.setSurfaceSize(const Size(1200, 900));
        addTearDown(() {
          tester.binding.setSurfaceSize(null);
          tester.platformDispatcher.clearTextScaleFactorTestValue();
        });
        await tester.pumpWidget(
          ElarniApp(
            tunnelControl: control,
            windows: platform == TargetPlatform.windows,
          ),
        );
        await tester.pumpAndSettle();
        await openSettings(tester);
        expect(find.text(updateHelp), findsNothing);
        await tester.tap(find.byTooltip(updateHelp));
        await tester.pumpAndSettle();
        expect(find.text(updateHelp), findsOneWidget);
        expect(control.settings.toMap(), original);
        Tooltip.dismissAllToolTips();
        await tester.pumpAndSettle();

        await selectCategory(tester, SettingsCategory.advanced);
        expect(find.text(fragmentationHelp), findsNothing);
        expect(find.text(muxHelp), findsNothing);
        expect(find.text('tlshello · 100-200 bytes · 0-1 ms'), findsOneWidget);
        await tester.tap(find.byTooltip(fragmentationHelp));
        await tester.pumpAndSettle();
        expect(find.text(fragmentationHelp), findsOneWidget);
        expect(control.settings.toMap(), original);
        Tooltip.dismissAllToolTips();
        await tester.pumpAndSettle();

        final muxIcon = find.descendant(
          of: find.byTooltip(muxHelp),
          matching: find.byIcon(CupertinoIcons.question_circle),
        );
        Focus.of(tester.element(muxIcon)).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(find.text(muxHelp), findsOneWidget);
        expect(control.settings.toMap(), original);
        Tooltip.dismissAllToolTips();
        await tester.pumpAndSettle();

        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        await mouse.moveTo(tester.getCenter(find.byTooltip(fragmentationHelp)));
        await tester.pumpAndSettle();
        expect(find.text(fragmentationHelp), findsOneWidget);
        await mouse.removePointer();
        Tooltip.dismissAllToolTips();
        await tester.pumpAndSettle();

        await tester.binding.setSurfaceSize(const Size(420, 760));
        tester.platformDispatcher.textScaleFactorTestValue = 1.6;
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip(fragmentationHelp));
        await tester.pumpAndSettle();
        expect(find.text(fragmentationHelp), findsOneWidget);
        expect(tester.takeException(), isNull);
        Tooltip.dismissAllToolTips();
        await tester.pumpAndSettle();
        await tester.tap(find.text('Enable fragmentation'));
        await tester.pumpAndSettle();
        expect(control.settings.fragmentationEnabled, isTrue);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'server IP choices leave app default intact on ${platform.name}',
      (tester) async {
        final control = FakeTunnelControl();
        final original = control.settings.toMap();
        await tester.binding.setSurfaceSize(const Size(1200, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          ElarniApp(
            tunnelControl: control,
            windows: platform == TargetPlatform.windows,
          ),
        );
        await tester.pumpAndSettle();
        await openSettings(tester);
        await selectCategory(tester, SettingsCategory.connection);
        final choice = find.byKey(const ValueKey('node-ip-a'));
        await reveal(tester, choice);
        expect(
          find.descendant(of: choice, matching: find.text('Use app default')),
          findsOneWidget,
        );
        for (final label in ['IPv4', 'IPv6', 'Automatic']) {
          await tester.tap(choice);
          await tester.pumpAndSettle();
          await tester.tap(find.text(label).last);
          await tester.pumpAndSettle();
        }
        expect(control.nodeIPPreferences, [
          ('a', 'ipv4'),
          ('a', 'ipv6'),
          ('a', 'automatic'),
        ]);
        expect(control.settings.toMap(), original);
      },
    );

    testWidgets('connected node selection on ${platform.name}', (tester) async {
      final pending = Completer<NodeSelectionResult>();
      final control = FakeTunnelControl()
        ..phase = 'connected'
        ..onSelect = () => pending.future;
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ElarniApp(
          tunnelControl: control,
          windows: platform == TargetPlatform.windows,
        ),
      );
      await tester.pumpAndSettle();
      await reveal(
        tester,
        find.descendant(
          of: find.byKey(const ValueKey('node:b')),
          matching: find.text('Node B'),
        ),
      );
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('node:b')),
          matching: find.text('Node B'),
        ),
      );
      await tester.pump();
      expect(control.selectedIDs, ['b']);
      expect(
        tester.widget<ListTile>(find.byKey(const ValueKey('node:a'))).onTap,
        isNull,
      );
      await tester.drag(find.byType(ListView).first, const Offset(0, 10000));
      await tester.pump();
      expect(find.text('Reconnecting…'), findsOneWidget);

      pending.complete(
        NodeSelectionResult(
          state: 'connected',
          subscriptions: SubscriptionSnapshot.fromMap({
            'selectedNodeId': 'b',
            'subscriptions': [
              {
                'id': 'group',
                'name': 'Fixture',
                'status': 'ready',
                'nodes': [
                  for (final id in ['a', 'b'])
                    {
                      'id': id,
                      'name': 'Node ${id.toUpperCase()}',
                      'protocol': 'VLESS',
                      'transport': 'tcp',
                      'security': 'tls',
                      'selected': id == 'b',
                    },
                ],
              },
            ],
          }),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Connected'), findsOneWidget);
      expect(find.text('Node switched.'), findsNothing);
      await reveal(
        tester,
        find.descendant(
          of: find.byKey(const ValueKey('node:b')),
          matching: find.text('Node B'),
        ),
      );
      expect(
        tester.widget<ListTile>(find.byKey(const ValueKey('node:b'))).selected,
        isTrue,
      );
      expect(
        tester.widget<ListTile>(find.byKey(const ValueKey('node:a'))).selected,
        isFalse,
      );
      expect(control.connectCalls, 0);
    });

    testWidgets('desktop memory choices on ${platform.name}', (tester) async {
      final control = FakeTunnelControl();
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ElarniApp(
          tunnelControl: control,
          windows: platform == TargetPlatform.windows,
        ),
      );
      await tester.pumpAndSettle();
      await openSettings(tester);
      await selectCategory(tester, SettingsCategory.advanced);
      await tester.pumpAndSettle();
      await reveal(tester, find.text('Xray memory limit (MB)'));
      final setting = find.byKey(
        const ValueKey('setting:Xray memory limit (MB)'),
      );
      final choices = tester
          .widget<ElarniSelect<int>>(setting)
          .items
          .map((item) => item.value)
          .toList();
      expect(choices, containsAll([0, 64, 256, 4096]));
      expect(choices.contains(45), platform == TargetPlatform.windows);
      await tester.tap(setting);
      await tester.pumpAndSettle();
      final option = find.widgetWithText(MenuItemButton, '256');
      await tester.ensureVisible(option);
      await tester.tap(option);
      await tester.pumpAndSettle();
      expect(control.settings.memoryLimitMB, 256);
      expect(tester.widget<ElarniSelect<int>>(setting).value, 256);
      await tester.tap(setting);
      await tester.pumpAndSettle();
      final automatic = find.widgetWithText(MenuItemButton, 'Automatic');
      await tester.ensureVisible(automatic);
      await tester.tap(automatic);
      await tester.pumpAndSettle();
      expect(control.settings.memoryLimitMB, 0);
      expect(tester.widget<ElarniSelect<int>>(setting).value, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'backup passwords and repair confirmation on ${platform.name}',
      (tester) async {
        final control = FakeTunnelControl();
        await tester.binding.setSurfaceSize(const Size(1200, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          ElarniApp(
            tunnelControl: control,
            windows: platform == TargetPlatform.windows,
          ),
        );
        await tester.pumpAndSettle();
        await openSettings(tester);
        await selectCategory(tester, SettingsCategory.backup);
        await tester.pumpAndSettle();
        await reveal(tester, find.text('Create encrypted backup'));
        await tester.tap(find.text('Create encrypted backup'));
        await tester.pumpAndSettle();
        final fields = find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        );
        expect(tester.widget<TextField>(fields.first).obscureText, isTrue);
        await tester.enterText(fields.first, 'too short');
        await tester.tap(find.text('Save backup'));
        await tester.pumpAndSettle();
        expect(control.exportedPasswords, isEmpty);
        await tester.enterText(fields.first, 'synthetic backup password');
        await tester.enterText(fields.last, 'different confirmation');
        await tester.tap(find.text('Save backup'));
        await tester.pumpAndSettle();
        expect(control.exportedPasswords, isEmpty);
        await tester.enterText(fields.last, 'synthetic backup password');
        await tester.tap(find.text('Save backup'));
        await tester.pumpAndSettle();
        expect(control.exportedPasswords, ['synthetic backup password']);
        await reveal(tester, find.text('Restore backup'));
        await tester.tap(find.text('Restore backup'));
        await tester.pumpAndSettle();
        await tester.enterText(fields, 'synthetic backup password');
        await tester.tap(find.text('Choose backup and restore'));
        await tester.pumpAndSettle();
        expect(control.restoredPasswords, ['synthetic backup password']);
        await reveal(tester, find.text('Repair VPN setup'));
        await tester.tap(find.text('Repair VPN setup'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(control.repairCalls, 0);
        await tester.tap(find.text('Repair VPN setup'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Repair'));
        await tester.pumpAndSettle();
        expect(control.repairCalls, 1);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'home import and settings remain usable in a narrow window on ${platform.name}',
      (tester) async {
        final control = FakeTunnelControl()
          ..snapshot = const SubscriptionSnapshot(subscriptions: []);
        await tester.binding.setSurfaceSize(const Size(420, 760));
        tester.platformDispatcher.textScaleFactorTestValue = 1.6;
        addTearDown(() {
          tester.binding.setSurfaceSize(null);
          tester.platformDispatcher.clearTextScaleFactorTestValue();
        });
        await tester.pumpWidget(
          ElarniApp(
            tunnelControl: control,
            windows: platform == TargetPlatform.windows,
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<FilledButton>(find.byKey(const Key('connection-toggle')))
              .onPressed,
          isNull,
        );
        await reveal(tester, find.byKey(const Key('ping-all')));
        expect(
          tester
              .widget<IconButton>(find.byKey(const Key('ping-all')))
              .onPressed,
          isNull,
        );
        await reveal(tester, find.byKey(const Key('onboarding-file')));
        expect(find.text('Get connected in three steps'), findsOneWidget);
        expect(find.text('Tunnel settings'), findsNothing);
        expect(find.byKey(const Key('ping-settings')), findsNothing);
        expect(find.byKey(const Key('routing-import')), findsNothing);
        await openImport(tester);
        for (final source in ['file', 'clipboard', 'qrImage', 'camera']) {
          expect(
            find.byKey(Key('import-$source')).hitTestable(),
            findsOneWidget,
          );
        }
        await tester.tap(find.byKey(const Key('import-toggle')));
        await tester.pumpAndSettle();
        await openSettings(tester);
        expect(find.byKey(const Key('connection-toggle')), findsNothing);
        await selectCategory(tester, SettingsCategory.ping);
        expect(find.byKey(const Key('ping-url')), findsNothing);
        await tester.tap(find.text('Direct TCP'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(MenuItemButton, 'Proxy'));
        await tester.pumpAndSettle();
        await reveal(tester, find.byKey(const Key('ping-url')));
        expect(find.byKey(const Key('ping-url')), findsOneWidget);
        await closeSettings(tester);
        control.snapshot = fixtureSubscriptions;
        await addSubscription(tester);
        expect(control.addedURLs, ['https://fixture.example/feed']);
        await reveal(
          tester,
          find.descendant(
            of: find.byKey(const ValueKey('node:b')),
            matching: find.text('Node B'),
          ),
        );
        await tester.tap(
          find.descendant(
            of: find.byKey(const ValueKey('node:b')),
            matching: find.text('Node B'),
          ),
        );
        await tester.pumpAndSettle();
        expect(control.selectedIDs, ['b']);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant.only(platform),
    );

    testWidgets(
      'a cleared expected status still tests for HTTP 204 on ${platform.name}',
      (tester) async {
        final control = FakeTunnelControl();
        await tester.binding.setSurfaceSize(const Size(1200, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          ElarniApp(
            tunnelControl: control,
            windows: platform == TargetPlatform.windows,
          ),
        );
        await tester.pumpAndSettle();
        await openSettings(tester);
        await selectCategory(tester, SettingsCategory.ping);
        await tester.tap(find.text('Direct TCP'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(MenuItemButton, 'Proxy'));
        await tester.pumpAndSettle();
        final status = find.byKey(const Key('ping-expected-status'));
        await reveal(tester, status);
        await tester.enterText(status, '');
        await tester.pumpAndSettle();
        await closeSettings(tester);
        await reveal(tester, find.byKey(const ValueKey('ping:a')));
        control.pingCalls.clear();
        await tester.tap(find.byKey(const ValueKey('ping:a')));
        await tester.pumpAndSettle();
        expect(control.pingCalls.single.expectedStatus, 204);
        await tester.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant.only(platform),
    );

    testWidgets(
      'bulk ping paints results and permits selection before completion on ${platform.name}',
      (tester) async {
        final first = Completer<PingResult>();
        final second = Completer<PingResult>();
        final selection = Completer<NodeSelectionResult>();
        final control = FakeTunnelControl()..onSelect = () => selection.future;
        await tester.binding.setSurfaceSize(const Size(1200, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          ElarniApp(
            tunnelControl: control,
            windows: platform == TargetPlatform.windows,
          ),
        );
        await tester.pumpAndSettle();
        control.onPing = (id) => id == 'a' ? first.future : second.future;
        await reveal(tester, find.byKey(const Key('ping-all')));
        await tester.tap(find.byKey(const Key('ping-all')));
        await tester.pump();
        await reveal(
          tester,
          find.descendant(
            of: find.byKey(const ValueKey('node:b')),
            matching: find.text('Node B'),
          ),
        );
        first.complete(
          PingResult(
            nodeId: 'a',
            status: 'success',
            latencyMs: 23,
            timestamp: DateTime.now().millisecondsSinceEpoch / 1000,
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 16));
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('ping:a')),
            matching: find.text('23 ms'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('ping:b')),
            matching: find.text('Testing…'),
          ),
          findsOneWidget,
        );
        expect(second.isCompleted, isFalse);
        await tester.tap(
          find.descendant(
            of: find.byKey(const ValueKey('node:b')),
            matching: find.text('Node B'),
          ),
        );
        await tester.pump();
        expect(control.selectedIDs, ['b']);
        second.complete(
          PingResult(
            nodeId: 'b',
            status: 'success',
            latencyMs: 99,
            timestamp: DateTime.now().millisecondsSinceEpoch / 1000,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining(' · 99 ms'), findsNothing);
        await tester.drag(find.byType(Scrollable).first, const Offset(0, 5000));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<FilledButton>(find.byKey(const Key('connection-toggle')))
              .onPressed,
          isNull,
        );
        selection.complete(
          const NodeSelectionResult(
            state: 'prepared',
            subscriptions: fixtureSubscriptions,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Connect'));
        await tester.pumpAndSettle();
        expect(control.connectCalls, 1);
        expect(find.textContaining('Tested '), findsNothing);
        await tester.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant.only(platform),
    );

    testWidgets(
      'bulk ping runs at most two probes per SNI at once on ${platform.name}',
      (tester) async {
        // TSPU freezes an SNI after more than 3 near-simultaneous handshakes.
        final pending = List.generate(8, (_) => Completer<PingResult>());
        final calls = <int>[];
        final control = FakeTunnelControl()
          ..snapshot = SubscriptionSnapshot(
            subscriptions: [
              SubscriptionGroup(
                id: 'group',
                name: 'Fixture',
                status: 'ready',
                nodes: [
                  for (var i = 0; i < 8; i++)
                    SubscriptionNode(
                      id: '$i',
                      name: 'Node $i',
                      protocol: 'VLESS',
                      transport: 'tcp',
                      security: 'reality',
                      selected: false,
                      probeKey: i < 6 ? 'shared.example' : 'other.example',
                    ),
                ],
              ),
            ],
          );
        await tester.binding.setSurfaceSize(const Size(1200, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          ElarniApp(
            tunnelControl: control,
            windows: platform == TargetPlatform.windows,
          ),
        );
        await tester.pumpAndSettle();
        control.onPing = (id) {
          calls.add(int.parse(id));
          return pending[int.parse(id)].future;
        };
        PingResult passed(int i) => PingResult(
          nodeId: '$i',
          status: 'success',
          latencyMs: 10,
          timestamp: DateTime.now().millisecondsSinceEpoch / 1000,
        );
        await reveal(tester, find.byKey(const Key('ping-all')));
        await tester.tap(find.byKey(const Key('ping-all')));
        await tester.pump();
        expect(calls.toSet(), {0, 1, 6, 7});
        pending[0].complete(passed(0));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 16));
        expect(calls.where((i) => i < 6).toSet(), {0, 1, 2});
        for (var i = 1; i < 8; i++) {
          if (!pending[i].isCompleted) pending[i].complete(passed(i));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 16));
        }
        await tester.pumpAndSettle();
        expect(calls.toSet(), {0, 1, 2, 3, 4, 5, 6, 7});
        await tester.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant.only(platform),
    );

    testWidgets(
      'bulk ping limits concurrent work and gives queued nodes their own deadline on ${platform.name}',
      (tester) async {
        final pending = List.generate(34, (_) => Completer<PingResult>());
        final calls = <int>[];
        final control = FakeTunnelControl()
          ..snapshot = SubscriptionSnapshot(
            subscriptions: [
              SubscriptionGroup(
                id: 'group',
                name: 'Fixture',
                status: 'ready',
                nodes: [
                  for (var i = 0; i < 34; i++)
                    SubscriptionNode(
                      id: '$i',
                      name: 'Node $i',
                      protocol: 'VLESS',
                      transport: 'tcp',
                      security: 'tls',
                      selected: false,
                    ),
                ],
              ),
            ],
          );
        await tester.binding.setSurfaceSize(const Size(1200, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          ElarniApp(
            tunnelControl: control,
            windows: platform == TargetPlatform.windows,
          ),
        );
        await tester.pumpAndSettle();
        control.onPing = (id) {
          calls.add(int.parse(id));
          return pending[int.parse(id)].future;
        };
        await reveal(tester, find.byKey(const Key('ping-all')));
        await tester.tap(find.byKey(const Key('ping-all')));
        await tester.pump();
        expect(calls, List.generate(32, (i) => i));
        await tester.pump(const Duration(seconds: 6));
        pending[0].complete(
          PingResult(
            nodeId: '0',
            status: 'success',
            latencyMs: 10,
            timestamp: DateTime.now().millisecondsSinceEpoch / 1000,
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 16));
        expect(calls, List.generate(33, (i) => i));
        await tester.pump(const Duration(seconds: 2));
        await tester.pump();
        expect(calls, List.generate(34, (i) => i));
        for (var i = 1; i < 34; i++) {
          pending[i].complete(
            PingResult(
              nodeId: '$i',
              status: 'success',
              latencyMs: 10,
              timestamp: DateTime.now().millisecondsSinceEpoch / 1000,
            ),
          );
        }
        await tester.pumpAndSettle();
        await tester.drag(find.byType(Scrollable).first, const Offset(0, 5000));
        await tester.pumpAndSettle();
        expect(find.text('Tested 3 of 34 nodes.'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant.only(platform),
    );

    testWidgets(
      'incompatible probes are skipped in single and batch tests on ${platform.name}',
      (tester) async {
        var incompatible = false;
        Future<void> openPingSettings() async {
          await openSettings(tester);
          await selectCategory(tester, SettingsCategory.ping);
        }

        final control = FakeTunnelControl();
        await tester.binding.setSurfaceSize(const Size(1200, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          ElarniApp(
            tunnelControl: control,
            windows: platform == TargetPlatform.windows,
          ),
        );
        await tester.pumpAndSettle();
        control.onPing = (id) async {
          if (incompatible && id == 'a') {
            throw PlatformException(code: 'unsupported_ping_method');
          }
          return PingResult(
            nodeId: id,
            status: 'success',
            latencyMs: 20,
            timestamp: DateTime.now().millisecondsSinceEpoch / 1000,
          );
        };
        final ping = find.byKey(const ValueKey('ping:a'));
        await closeSettings(tester);
        await reveal(tester, ping);
        await tester.tap(ping);
        await tester.pumpAndSettle();
        expect(find.widgetWithText(TextButton, '20 ms'), findsOneWidget);

        await openPingSettings();
        expect(find.text('Direct TCP'), findsOneWidget);
        incompatible = true;
        await closeSettings(tester);
        await reveal(tester, ping);
        await tester.tap(ping);
        await tester.pumpAndSettle();
        expect(find.text('Skipped'), findsOneWidget);
        expect(find.text('20 ms'), findsNothing);
        expect(
          find.descendant(of: ping, matching: find.text('Unavailable')),
          findsNothing,
        );
        await tester.drag(find.byType(Scrollable).first, const Offset(0, 5000));
        await tester.pumpAndSettle();
        expect(find.textContaining('Skipped: Direct TCP'), findsOneWidget);

        await closeSettings(tester);
        await reveal(tester, find.byKey(const Key('ping-all')));
        await tester.tap(find.byKey(const Key('ping-all')));
        await tester.pumpAndSettle();
        await tester.drag(find.byType(Scrollable).first, const Offset(0, 5000));
        await tester.pumpAndSettle();
        expect(
          find.text(
            'Tested 1 of 1 nodes. Skipped 1: incompatible with this test method.',
          ),
          findsOneWidget,
        );

        await openPingSettings();
        await reveal(tester, find.text('Direct TCP'));
        await tester.tap(find.text('Direct TCP'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Proxy').last);
        await tester.pumpAndSettle();
        incompatible = false;
        await closeSettings(tester);
        await reveal(tester, ping);
        await tester.tap(ping);
        await tester.pumpAndSettle();
        expect(find.text('Skipped'), findsNothing);
        expect(find.widgetWithText(TextButton, '20 ms'), findsNWidgets(2));
        await tester.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant.only(platform),
    );

    testWidgets(
      'tests the VPN cannot run while connected are skipped on ${platform.name}',
      (tester) async {
        final control = FakeTunnelControl()..phase = 'connected';
        await tester.binding.setSurfaceSize(const Size(1200, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          ElarniApp(
            tunnelControl: control,
            windows: platform == TargetPlatform.windows,
          ),
        );
        await tester.pumpAndSettle();
        control.onPing = (id) async {
          if (id == 'a') throw PlatformException(code: 'disconnect_to_test');
          return PingResult(
            nodeId: id,
            status: 'success',
            latencyMs: 20,
            timestamp: DateTime.now().millisecondsSinceEpoch / 1000,
          );
        };
        final ping = find.byKey(const ValueKey('ping:a'));
        await reveal(tester, ping);
        await tester.tap(ping);
        await tester.pumpAndSettle();
        expect(
          find.descendant(of: ping, matching: find.text('Skipped')),
          findsOneWidget,
        );
        await tester.drag(find.byType(Scrollable).first, const Offset(0, 5000));
        await tester.pumpAndSettle();
        expect(
          find.text(
            'Skipped: while connected, this test can’t reach the server. Disconnect to test it.',
          ),
          findsOneWidget,
        );

        await reveal(tester, find.byKey(const Key('ping-all')));
        await tester.tap(find.byKey(const Key('ping-all')));
        await tester.pumpAndSettle();
        await tester.drag(find.byType(Scrollable).first, const Offset(0, 5000));
        await tester.pumpAndSettle();
        expect(
          find.text('Tested 1 of 1 nodes. Skipped 1: disconnect to test them.'),
          findsOneWidget,
        );
        await tester.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant.only(platform),
    );

    testWidgets(
      'ICMP requires confirmation and reports restoration failure on ${platform.name}',
      (tester) async {
        var probes = 0;
        final control = FakeTunnelControl()..phase = 'connected';
        await tester.binding.setSurfaceSize(const Size(1200, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          ElarniApp(
            tunnelControl: control,
            windows: platform == TargetPlatform.windows,
          ),
        );
        await tester.pumpAndSettle();
        control.onPing = (_) async {
          probes++;
          control.phase = 'failed';
          throw PlatformException(code: 'icmp_restore_failed');
        };
        await openSettings(tester);
        await selectCategory(tester, SettingsCategory.ping);
        await tester.pumpAndSettle();
        await reveal(tester, find.text('Direct TCP'));
        await tester.tap(find.text('Direct TCP'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Direct ICMP').last);
        await tester.pumpAndSettle();
        final ping = find.byKey(const ValueKey('ping:a'));
        await closeSettings(tester);
        await reveal(tester, ping);
        await tester.tap(ping);
        await tester.pumpAndSettle();
        expect(find.text('Run ICMP test?'), findsOneWidget);
        expect(probes, 0);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(probes, 0);
        await tester.tap(ping);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Continue'));
        await tester.pumpAndSettle();
        expect(probes, 1);
        await tester.drag(find.byType(Scrollable).first, const Offset(0, 5000));
        await tester.pumpAndSettle();
        expect(find.text('Connection failed'), findsOneWidget);
        expect(
          find.text(
            'ICMP finished, but the previous tunnel connection could not be restored.',
          ),
          findsOneWidget,
        );
        await tester.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant.only(platform),
    );

    testWidgets(
      'connection layout and status are shared on ${platform.name}',
      (tester) async {
        final control = FakeTunnelControl()
          ..settings = const TunnelSettings(xrayTunEnabled: true);
        await tester.binding.setSurfaceSize(const Size(800, 600));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          ElarniApp(
            tunnelControl: control,
            windows: platform == TargetPlatform.windows,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('connection-toggle')), findsOneWidget);
        expect(find.text('Local proxy mode'), findsNothing);
        expect(find.text('System-wide VPN').hitTestable(), findsNothing);
        expect(find.text('Tunnel settings'), findsNothing);
        expect(
          find
              .descendant(
                of: find.byKey(const ValueKey('node:a')),
                matching: find.text('Node A'),
              )
              .hitTestable(),
          findsOneWidget,
        );
        await reveal(tester, find.byKey(const ValueKey('node:b')));
        expect(
          find
              .descendant(
                of: find.byKey(const ValueKey('node:b')),
                matching: find.text('Node B'),
              )
              .hitTestable(),
          findsOneWidget,
        );
        await reveal(tester, find.byKey(const Key('ping-all')));
        expect(find.byKey(const Key('ping-all')).hitTestable(), findsOneWidget);
        expect(
          find.byKey(const Key('import-toggle')).hitTestable(),
          findsOneWidget,
        );
        await tester.tap(find.text('Connect'));
        await tester.pumpAndSettle();
        expect(find.text('Connected.'), findsNothing);
        expect(find.text('Connected'), findsOneWidget);
        await tester.tap(find.text('Disconnect'));
        await tester.pumpAndSettle();
        await openSettings(tester);
        await selectCategory(tester, SettingsCategory.connection);
        await tester.pumpAndSettle();
        await reveal(tester, find.text('SOCKS5 and HTTP ports'));
        expect(find.text('SOCKS5 and HTTP ports'), findsOneWidget);
        await tester.tap(find.text('SOCKS5 and HTTP ports'));
        await tester.pumpAndSettle();
        expect(find.widgetWithText(TextField, 'SOCKS5 port'), findsOneWidget);
        expect(find.widgetWithText(TextField, 'HTTP port'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant.only(platform),
    );

    testWidgets(
      'subscription download editor validates and saves on ${platform.name}',
      (tester) async {
        final control = FakeTunnelControl();
        await tester.binding.setSurfaceSize(const Size(900, 1100));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          ElarniApp(
            tunnelControl: control,
            windows: platform == TargetPlatform.windows,
          ),
        );
        await tester.pumpAndSettle();
        await openSubscriptions(tester);
        await reveal(tester, find.text('Fixture'));
        await tester.tap(find.text('Fixture'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('subscription-actions:group')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Download options'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextField, 'Fallback hosts'),
          'https://invalid/path',
        );
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(control.savedFetchOptions, isEmpty);
        await tester.enterText(
          find.widgetWithText(TextField, 'Fallback hosts'),
          'fallback.example\nfallback.example',
        );
        await tester.enterText(
          find.widgetWithText(TextField, 'Connect address (optional)'),
          '192.0.2.1',
        );
        await tester.enterText(
          find.widgetWithText(TextField, 'HTTP Host (optional)'),
          'provider.example',
        );
        await tester.ensureVisible(find.text('Fragment TLS ClientHello'));
        await tester.tap(find.text('Fragment TLS ClientHello'));
        await tester.pumpAndSettle();
        // Without a provider interval, an empty override follows the app setting.
        expect(
          find.text('Leave empty to follow the app setting (4 h). 1–168.'),
          findsOneWidget,
        );
        for (final hours in ['0', '169', '1.5', '02']) {
          await tester.enterText(
            find.widgetWithText(TextField, 'Refresh every (hours) · override'),
            hours,
          );
          await tester.tap(find.text('Save'));
          await tester.pumpAndSettle();
          expect(control.savedFetchOptions, isEmpty, reason: hours);
          expect(
            find.text('Refresh takes whole hours from 1 to 168.'),
            findsOneWidget,
          );
        }
        await tester.enterText(
          find.widgetWithText(TextField, 'Refresh every (hours) · override'),
          '2',
        );
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(control.savedFetchOptions.single, {
          'id': 'group',
          'fallbackHosts': ['fallback.example'],
          'refreshHours': '2',
          'connectAddress': '192.0.2.1',
          'httpHost': 'provider.example',
          'fragmentLength': '80-250',
          'fragmentInterval': '10-100',
        });
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(platform),
    );

    testWidgets(
      'subscription announcement renders on ${platform.name}',
      (tester) async {
        const announcement = 'Provider notice\nService is available.';
        final control = FakeTunnelControl()
          ..snapshot = SubscriptionSnapshot(
            selectedNodeId: 'a',
            subscriptions: [
              SubscriptionGroup(
                id: 'group',
                name: 'Fixture',
                status: 'ready',
                metadata: const {
                  'announcement': announcement,
                  'online': true,
                  'bannerText': 'Free provider banner',
                  'bannerButtonText': 'Visit provider',
                  'bannerBackground': '#102030',
                  'bannerButtonColor': '#fefefe',
                },
                actions: const ['banner'],
                nodes: fixtureSubscriptions.subscriptions.single.nodes,
              ),
            ],
          );
        await tester.binding.setSurfaceSize(const Size(800, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          ElarniApp(
            tunnelControl: control,
            windows: platform == TargetPlatform.windows,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await reveal(tester, find.text('Message from Fixture'));
        await tester.tap(find.text('Message from Fixture'));
        await tester.pumpAndSettle();
        await reveal(tester, find.text(announcement));
        expect(find.text(announcement), findsOneWidget);
        await reveal(tester, find.text('Free provider banner'));
        expect(find.text('Visit provider'), findsOneWidget);
        await openSubscriptions(tester);
        for (var i = 0; i < 3; i++) {
          await reveal(tester, find.text('Fixture'));
          await tester.tap(find.text('Fixture'));
          await tester.pumpAndSettle();
        }
        await reveal(tester, find.text('Message from Fixture'));
        await tester.tap(find.text('Message from Fixture'));
        await tester.pumpAndSettle();
        await reveal(tester, find.text(announcement));
        expect(find.text(announcement), findsOneWidget);
        await reveal(
          tester,
          find.descendant(
            of: find.byKey(const ValueKey('node:b')),
            matching: find.text('Node B'),
          ),
        );
        await tester.tap(
          find.descendant(
            of: find.byKey(const ValueKey('node:b')),
            matching: find.text('Node B'),
          ),
        );
        await tester.pumpAndSettle();
        expect(control.selectedIDs, isEmpty);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(platform),
    );
  }

  for (final platform in [TargetPlatform.macOS, TargetPlatform.windows]) {
    testWidgets(
      'parallel probes each have a seven-second deadline on ${platform.name}',
      (tester) async {
        final first = Completer<PingResult>();
        final calls = <String>[];
        final control = FakeTunnelControl()..phase = 'connected';
        await tester.binding.setSurfaceSize(const Size(1200, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          ElarniApp(
            tunnelControl: control,
            windows: platform == TargetPlatform.windows,
          ),
        );
        await tester.pumpAndSettle();
        control.onPing = (id) {
          calls.add(id);
          return id == 'a'
              ? first.future
              : Future.value(
                  PingResult(
                    nodeId: id,
                    status: 'success',
                    latencyMs: 20,
                    timestamp: DateTime.now().millisecondsSinceEpoch / 1000,
                  ),
                );
        };
        await reveal(tester, find.byKey(const Key('ping-all')));
        await tester.tap(find.byKey(const Key('ping-all')));
        await tester.pump();
        expect(calls, ['a', 'b']);
        await tester.pump(const Duration(seconds: 6));
        expect(
          tester
              .widget<IconButton>(find.byKey(const Key('ping-all')))
              .onPressed,
          isNull,
        );
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<IconButton>(find.byKey(const Key('ping-all')))
              .onPressed,
          isNotNull,
        );
        first.complete(
          PingResult(
            nodeId: 'a',
            status: 'success',
            latencyMs: 10,
            timestamp: DateTime.now().millisecondsSinceEpoch / 1000,
          ),
        );
        await tester.pumpAndSettle();
        expect(calls, ['a', 'b']);
        expect(find.text('Unavailable'), findsOneWidget);
        expect(find.widgetWithText(TextButton, '20 ms'), findsOneWidget);
        await tester.drag(find.byType(Scrollable).first, const Offset(0, 5000));
        await tester.pumpAndSettle();
        expect(find.text('Tested 1 of 2 nodes.'), findsOneWidget);
        expect(control.disconnectCalls, 0);
        expect(control.connectCalls, 0);
        await tester.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant.only(platform),
    );

    testWidgets(
      'disabling clicked button keeps scroll position on ${platform.name}',
      (tester) async {
        final pending = Completer<String>();
        final control = FakeTunnelControl()..onConnect = () => pending.future;
        await pumpApp(tester, control);
        await openImport(tester);
        await tester.tap(find.byKey(const Key('import-toggle')));
        await tester.pumpAndSettle();
        final position = tester
            .state<ScrollableState>(find.byType(Scrollable).first)
            .position;
        expect(position.pixels, 0);
        final button = find.byKey(const Key('connection-toggle'));
        Focus.of(
          tester.element(
            find.descendant(of: button, matching: find.byType(InkWell)),
          ),
        ).requestFocus();
        await tester.pump();
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(position.pixels, 0);
        pending.complete('connected');
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant.only(platform),
    );
  }

  testWidgets(
    'Windows exposes catalog and VPN controls, polls failure, and disposes',
    (tester) async {
      final control = FakeTunnelControl()
        ..phase = 'connected'
        ..settings = const TunnelSettings(httpInboundEnabled: true);
      var disposed = false;
      await tester.binding.setSurfaceSize(const Size(1200, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ElarniApp(
          tunnelControl: control,
          windows: true,
          onDispose: () async {
            disposed = true;
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('connection-toggle')), findsOneWidget);
      expect(find.text('Local proxy mode'), findsOneWidget);
      expect(find.text('Tunnel settings'), findsNothing);
      await openSettings(tester);
      await selectCategory(tester, SettingsCategory.connection);
      expect(find.text('Connection mode'), findsOneWidget);
      await tester.tap(find.text('Local proxy only'));
      await tester.pumpAndSettle();
      expect(
        find.widgetWithText(MenuItemButton, 'System-wide VPN'),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(MenuItemButton, 'System proxy'));
      await tester.pumpAndSettle();
      expect(
        (control.settings.systemProxyEnabled, control.settings.xrayTunEnabled),
        (true, false),
      );
      await reveal(tester, find.text('SOCKS5 and HTTP ports'));
      expect(find.text('SOCKS5 and HTTP ports'), findsOneWidget);
      // The listeners System proxy mode needs are fixed while it is on.
      expect(
        find.text(
          'In System proxy mode, apps on this computer use the HTTP port without a login.',
        ),
        findsOneWidget,
      );
      await selectCategory(tester, SettingsCategory.ping);
      expect(find.byKey(const Key('ping-url')), findsNothing);
      await tester.tap(find.text('Direct TCP'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(MenuItemButton, 'Proxy'));
      await tester.pumpAndSettle();
      await reveal(tester, find.byKey(const Key('ping-url')));
      expect(find.byKey(const Key('ping-url')), findsOneWidget);
      await closeSettings(tester);
      await tester.tap(find.byKey(const Key('nav-routing')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('routing-list')), findsOneWidget);
      await openImport(tester);
      for (final source in ['file', 'clipboard', 'qrImage', 'camera']) {
        expect(find.byKey(Key('import-$source')).hitTestable(), findsOneWidget);
      }
      expect(find.byKey(const Key('routing-import')), findsNothing);
      expect(find.byKey(const Key('subscription-url')), findsNothing);
      await tester.tap(find.byKey(const Key('import-toggle')));
      await tester.pumpAndSettle();
      control.phase = 'failed';
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.text('Connection failed'), findsOneWidget);
      expect(
        find.text('Connection stopped unexpectedly. Reconnect to retry.'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('connection-toggle')))
            .onPressed,
        isNotNull,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(disposed, isTrue);
      expect(control.importListener, isNull);
    },
  );

  testWidgets(
    'local proxy can cancel startup without a late cancellation becoming failure',
    (tester) async {
      final started = Completer<String>();
      final control = FakeTunnelControl()..onConnect = () => started.future;
      await tester.pumpWidget(ElarniApp(tunnelControl: control, windows: true));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Connect'));
      await tester.pump();
      await tester.tap(find.text('Disconnect'));
      await tester.pumpAndSettle();
      started.completeError(PlatformException(code: 'cancelled'));
      await tester.pumpAndSettle();
      expect(control.disconnectCalls, 1);
      expect(find.text('Disconnected'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'unsupported imports explain the compatible format without exposing credentials',
    (tester) async {
      final control = FakeTunnelControl()
        ..importError = PlatformException(
          code: 'unsupported_profile',
          message: 'provider-secret',
        );
      await pumpApp(tester, control);
      await importClipboard(tester, 'fixture-client-profile');
      expect(
        find.text(
          'This profile uses unsupported settings. Try the provider’s Xray JSON format.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('provider-secret'), findsNothing);
    },
  );

  // The subscription stays saved, so calling the link invalid led to duplicates.
  testWidgets('a new subscription whose first download fails says so', (
    tester,
  ) async {
    final control = FakeTunnelControl();
    control.onImport = (_, _) async {
      control.snapshot = SubscriptionSnapshot(
        selectedNodeId: control.snapshot.selectedNodeId,
        subscriptions: [
          ...control.snapshot.subscriptions,
          const SubscriptionGroup(
            id: 'added',
            name: 'provider.example',
            status: 'refresh_failed',
            nodes: [],
          ),
        ],
      );
      throw PlatformException(code: 'fetch_failed');
    };
    await pumpApp(tester, control);
    await importClipboard(tester, 'https://provider.example/sub');
    expect(
      find.text(
        'Subscription added, but the first download failed. Refresh to retry.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('routing imports without a selected server ask for one', (
    tester,
  ) async {
    final control = FakeTunnelControl()
      ..importError = PlatformException(
        code: 'no_selected_subscription',
        message: 'provider-secret',
      );
    await pumpApp(tester, control);
    await importClipboard(tester, 'happ://routing/onadd/e30=');
    expect(
      find.text(
        'Select a server first. This routing link turns its profile on for the selected server’s subscription.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('provider-secret'), findsNothing);
  });

  testWidgets(
    'external import errors are visible and listeners detach on disposal',
    (tester) async {
      final control = FakeTunnelControl();
      await pumpApp(tester, control);
      control.importListener?.call('The client link could not be imported.');
      await tester.pumpAndSettle();
      expect(
        find.text('The client link could not be imported.'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      expect(control.importListener, isNull);
    },
  );

  testWidgets(
    'profile group selector sends the node group and selected member',
    (tester) async {
      final control = FakeTunnelControl()
        ..snapshot = const SubscriptionSnapshot(
          subscriptions: [
            SubscriptionGroup(
              id: 'provider',
              name: 'Grouped provider',
              status: 'ready',
              nodes: [
                SubscriptionNode(
                  id: 'profile',
                  name: 'Provider profile',
                  protocol: 'Xray profile',
                  transport: 'raw',
                  security: 'TLS',
                  selected: true,
                  format: 'xrayProfile',
                  groups: [
                    ProfileGroupChoice(
                      name: 'PROXY',
                      options: ['one', 'two'],
                      selected: 'one',
                    ),
                  ],
                ),
              ],
            ),
          ],
        );
      await pumpApp(tester, control);
      await openSubscriptions(tester);
      await reveal(tester, find.text('Grouped provider'));
      await tester.tap(find.text('Grouped provider'));
      await tester.pumpAndSettle();
      await reveal(tester, find.text('one'));
      await tester.tap(find.text('one'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('two').last);
      await tester.pumpAndSettle();
      expect(control.groupChoices, [
        ['profile', 'PROXY', 'two'],
      ]);
      expect(control.connectCalls, 0);
    },
  );

  testWidgets(
    'manual imports clear credentials and Telegram opens only on activation',
    (tester) async {
      final control = FakeTunnelControl()
        ..snapshot = const SubscriptionSnapshot(
          subscriptions: [
            SubscriptionGroup(
              id: 'local',
              name: 'Local profiles',
              status: 'ready',
              isLocal: true,
              nodes: [
                SubscriptionNode(
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
        );
      await pumpApp(tester, control);
      await importClipboard(tester, 'fixture-client-profile');
      expect(control.importedProfiles, ['fixture-client-profile']);
      expect(find.byKey(const Key('client-profile-import')), findsNothing);
      expect(control.telegramIDs, isEmpty);
      await reveal(tester, find.byKey(const ValueKey('ping:telegram')));
      await tester.tap(find.byKey(const ValueKey('ping:telegram')));
      await tester.pumpAndSettle();
      expect(control.telegramIDs, ['telegram']);
      expect(control.selectedIDs, isEmpty);
      expect(control.connectCalls, 0);
    },
  );

  testWidgets('connect allows Stop and polls to the native terminal state', (
    tester,
  ) async {
    final control = FakeTunnelControl();
    final pending = Completer<String>();
    control.onConnect = () => pending.future;
    await pumpApp(tester, control);
    await tester.tap(find.text('Connect'));
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('connection-toggle')))
          .onPressed,
      isNotNull,
    );
    expect(control.connectCalls, 1);
    control.phase = 'connected';
    pending.complete('connecting');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(find.text('Connected'), findsOneWidget);
    await tester.tap(find.text('Disconnect'));
    await tester.pumpAndSettle();
    expect(control.disconnectCalls, 1);
    expect(find.text('Disconnected'), findsOneWidget);
  });

  testWidgets(
    'cancelling unsafe subscription approval never retries the fetch',
    (tester) async {
      final control = FakeTunnelControl()..onAdd = () async => warning('first');
      await pumpApp(tester, control);
      await addSubscription(tester);
      expect(find.text('Approve unsafe subscription?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(control.addedURLs, ['https://fixture.example/feed']);
      expect(control.challenges, isEmpty);
      expect(find.byKey(const Key('subscription-url')), findsNothing);
    },
  );

  testWidgets('each redirect approval retries with its current challenge', (
    tester,
  ) async {
    final control = FakeTunnelControl()
      ..onAdd = (() async => warning('first'))
      ..onRefresh = (challenge) async => challenge == 'first'
          ? warning('second')
          : const SubscriptionOperationResult(snapshot: fixtureSubscriptions);
    await pumpApp(tester, control);
    await addSubscription(tester);
    for (var i = 0; i < 2; i++) {
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
    }
    expect(control.challenges, ['first', 'second']);
    expect(find.text('Approve unsafe subscription?'), findsNothing);
  });

  for (final entry in {
    'node_switch_failed_restored':
        'The replacement failed; the previous configuration was restored. Check access before retrying another server.',
    'node_switch_restore_failed':
        'The connection could not be restored safely. Disconnect before retrying. If that fails, use Repair VPN setup.',
  }.entries) {
    testWidgets(
      'node switch displays ${entry.key} and reloads native selection',
      (tester) async {
        final control = FakeTunnelControl()
          ..phase = 'connected'
          ..onSelect = () async => throw PlatformException(code: entry.key);
        await pumpApp(tester, control);
        await reveal(
          tester,
          find.descendant(
            of: find.byKey(const ValueKey('node:b')),
            matching: find.text('Node B'),
          ),
        );
        await tester.tap(
          find.descendant(
            of: find.byKey(const ValueKey('node:b')),
            matching: find.text('Node B'),
          ),
        );
        await tester.pumpAndSettle();
        expect(control.selectedIDs, ['b']);
        await tester.drag(find.byType(ListView).first, const Offset(0, 10000));
        await tester.pumpAndSettle();
        expect(find.text(entry.value), findsOneWidget);
        expect(find.text('Connected'), findsOneWidget);
      },
    );
  }

  testWidgets('per-app editor saves selections and enables the TUN backend', (
    tester,
  ) async {
    const desktop = MethodChannel('com.elarni/desktop');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      desktop,
      (call) async => call.method == 'routingApplications' ? [] : null,
    );
    addTearDown(() => messenger.setMockMethodCallHandler(desktop, null));
    final control = FakeTunnelControl();
    await pumpApp(tester, control);
    await openPerAppRouting(tester);
    expect(find.text('Routing mode'), findsNothing);
    await tester.tap(find.byKey(const Key('per-app-routing-mode')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bypass selected'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      find.widgetWithText(MenuItemButton, 'Bypass selected'),
      findsOneWidget,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add apps'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Profile & executable tools'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit executable rules'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Executable names or full paths'),
      'curl\nbrowser.exe',
    );
    await tester.tap(find.text('Update draft'));
    await tester.pumpAndSettle();
    await reveal(tester, find.text('Done'));
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    await reveal(tester, find.text('Save changes'));
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();
    expect(control.settings.perAppMode, 'bypass');
    expect(control.settings.perAppProcesses, ['curl', 'browser.exe']);
    expect(control.settings.xrayTunEnabled, isTrue);
  });

  testWidgets('route toggle keeps per-app edits made since the last rebuild', (
    tester,
  ) async {
    const desktop = MethodChannel('com.elarni/desktop');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      desktop,
      (call) async => call.method == 'routingApplications' ? [] : null,
    );
    addTearDown(() => messenger.setMockMethodCallHandler(desktop, null));
    final control = FakeTunnelControl()
      ..settings = const TunnelSettings(
        xrayTunEnabled: true,
        perAppMode: 'bypass',
        perAppProcesses: ['curl'],
        // Enforcement refuses default routes, so the fixture names specific ones.
        includedRoutes: ['10.0.0.0/8'],
      );
    await pumpApp(tester, control);
    await openPerAppRouting(tester);
    await reveal(tester, find.text('Advanced network routes'));
    await tester.tap(find.text('Advanced network routes'));
    await tester.pumpAndSettle();
    // The mode change rebuilds only the editor, not the route toggles.
    await reveal(tester, find.byKey(const Key('per-app-routing-mode')));
    await tester.tap(find.byKey(const Key('per-app-routing-mode')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, 'Only selected'));
    await tester.pumpAndSettle();
    await reveal(tester, find.text('Enforce tunnel routes'));
    await tester.tap(find.text('Enforce tunnel routes'));
    await tester.pumpAndSettle();
    await reveal(tester, find.text('Save changes'));
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();
    expect(control.settings.perAppMode, 'proxyOnly');
    expect(control.settings.perAppProcesses, ['curl']);
    expect(control.settings.enforceRoutes, isTrue);
  });

  testWidgets('trusted Wi-Fi networks are edited one name per line', (
    tester,
  ) async {
    final control = FakeTunnelControl()
      ..automation = {'wifi': 'locationDenied'};
    await pumpApp(tester, control, windows: true);
    await openSettings(tester);
    await reveal(tester, find.text('Connect on untrusted Wi-Fi'));
    await tester.tap(find.text('Connect on untrusted Wi-Fi'));
    await tester.pumpAndSettle();
    expect(control.settings.connectOnUntrustedWiFi, isTrue);
    expect(
      find.textContaining('Let desktop apps access your location'),
      findsOneWidget,
    );
    final edit = find.descendant(
      of: find.widgetWithText(ElarniSelectTile, 'Trusted Wi-Fi networks'),
      matching: find.text('Edit'),
    );
    await reveal(tester, edit);
    await tester.tap(edit);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'x' * 33);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.textContaining('at most 32 bytes'), findsOneWidget);
    await tester.enterText(
      find.byType(TextField).last,
      'Home\n Office 5G \n\nHome',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(control.settings.trustedWiFiNetworks, ['Home', 'Office 5G']);
    expect(find.text('Home, Office 5G'), findsOneWidget);
  });

  testWidgets('macOS offers Connect on untrusted Wi-Fi through On Demand', (
    tester,
  ) async {
    final control = FakeTunnelControl();
    await pumpApp(tester, control);
    await openSettings(tester);
    await reveal(tester, find.text('Connect on untrusted Wi-Fi'));
    expect(
      find.byTooltip(RegExp('even before you press Connect')),
      findsOneWidget,
    );
    await tester.tap(find.text('Connect on untrusted Wi-Fi'));
    await tester.pumpAndSettle();
    expect(control.settings.connectOnUntrustedWiFi, isTrue);
    expect(
      find.widgetWithText(ElarniSelectTile, 'Trusted Wi-Fi networks'),
      findsOneWidget,
    );
  });

  // Windows and Linux reconnect until Stop by default, so the switch would do nothing.
  testWidgets('Windows offers no On Demand switch', (tester) async {
    final control = FakeTunnelControl();
    await pumpApp(tester, control, windows: true);
    await openSettings(tester);
    await reveal(tester, find.text('Connect on untrusted Wi-Fi'));
    expect(find.text('On Demand'), findsNothing);
  });

  // While minimized the window must stay idle between catalog changes.
  testWidgets(
    'the idle Windows window neither rebuilds for a growing health age nor polls servers',
    (tester) async {
      final control = FakeTunnelControl()
        ..automation = {
          'enabled': true,
          'policySupported': true,
          'status': 'healthy',
          'healthNodeID': 'a',
          'healthAgeSeconds': 1.0,
        };
      await pumpApp(tester, control, windows: true);
      final reads = control.subscriptionReads;
      var rebuilds = 0;
      debugOnRebuildDirtyWidget = (element, _) {
        if (element.widget is ElarniHome) rebuilds++;
      };
      try {
        for (final age in [6.0, 11.0, 16.0]) {
          control.automation = {...control.automation, 'healthAgeSeconds': age};
          await tester.pump(const Duration(seconds: 5));
        }
        expect(rebuilds, 0);
        expect(control.subscriptionReads, reads);
        // Past 90 s the page says the check is stale.
        control.automation = {...control.automation, 'healthAgeSeconds': 95.0};
        await tester.pump(const Duration(seconds: 5));
        await tester.pump();
        expect(rebuilds, greaterThan(0));
      } finally {
        debugOnRebuildDirtyWidget = null;
      }
    },
  );

  testWidgets('macOS still polls servers', (tester) async {
    final control = FakeTunnelControl();
    await pumpApp(tester, control);
    final reads = control.subscriptionReads;
    await tester.pump(const Duration(seconds: 5));
    expect(control.subscriptionReads, greaterThan(reads));
  });

  testWidgets('Windows lets this account connect without the approval prompt', (
    tester,
  ) async {
    final control = FakeTunnelControl()
      ..systemInfoValue = {'vpnService': false, 'appVersion': '0.3.6+9'};
    await pumpApp(tester, control, windows: true);
    await openSettings(tester);
    await selectCategory(tester, SettingsCategory.connection);
    final row = find.widgetWithText(
      ElarniCheckboxTile,
      'Connect without administrator approval',
    );
    bool checked() => tester.widget<ElarniCheckboxTile>(row).value;
    await reveal(tester, row);
    expect(checked(), isFalse);
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(control.vpnServiceChanges, [true]);
    expect(checked(), isTrue);
    // A cancelled prompt leaves it on and says why.
    control.vpnServiceError = PlatformException(
      code: 'elevation_denied',
      message: 'Administrator permission was cancelled.',
    );
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(control.vpnServiceChanges, [true, false]);
    expect(checked(), isTrue);
    expect(find.text('Administrator permission was cancelled.'), findsWidgets);
    // The change keeps the rest of the system information.
    control.vpnServiceError = null;
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(checked(), isFalse);
    await selectCategory(tester, SettingsCategory.system);
    await tester.pumpAndSettle();
    await reveal(tester, find.textContaining('Elarni 0.3.6+9'));
    expect(find.textContaining('Elarni 0.3.6+9'), findsOneWidget);
  });

  testWidgets('Linux has no administrator approval service row', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ElarniApp(tunnelControl: FakeTunnelControl(), linux: true),
    );
    await tester.pumpAndSettle();
    await openSettings(tester);
    await selectCategory(tester, SettingsCategory.connection);
    await reveal(tester, find.text('Connection mode'));
    expect(find.text('Connection mode'), findsOneWidget);
    expect(find.text('Connect without administrator approval'), findsNothing);
  });

  testWidgets('failed settings save reloads the persisted settings', (
    tester,
  ) async {
    final control = FakeTunnelControl()
      ..onUpdate = (_) async => throw PlatformException(code: 'rejected');
    await pumpApp(tester, control);
    await openSettings(tester);
    await selectCategory(tester, SettingsCategory.advanced);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enable fragmentation'));
    await tester.pumpAndSettle();
    expect(control.settingsReads, 2);
    expect(find.textContaining('Setting could not be applied'), findsOneWidget);
    // Publishing the failure must keep the settings panel open.
    expect(
      tester
          .widget<ElarniCheckboxTile>(
            find.widgetWithText(ElarniCheckboxTile, 'Enable fragmentation'),
          )
          .value,
      isFalse,
    );
  });

  testWidgets('a known save failure tells the user what to do', (tester) async {
    final control = FakeTunnelControl()
      ..onUpdate = (_) async =>
          throw PlatformException(code: 'busy', message: 'native text');
    await pumpApp(tester, control);
    await openSettings(tester);
    await selectCategory(tester, SettingsCategory.advanced);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enable fragmentation'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Setting could not be applied. Another operation is in progress. Wait for it to finish, then retry.',
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'a change after a failed settings load keeps the stored settings',
    (tester) async {
      final updates = <TunnelSettings>[];
      final control = FakeTunnelControl()
        ..settings = const TunnelSettings(
          fragmentationEnabled: true,
          socksPort: 21080,
        )
        ..onUpdate = (value) async {
          updates.add(value);
          return value;
        };
      var loads = 0;
      control.onSettings = () async {
        if (loads++ == 0) throw PlatformException(code: 'storage_busy');
        return control.settings;
      };
      await pumpApp(tester, control);
      await openSettings(tester);
      await selectCategory(tester, SettingsCategory.advanced);
      final fragmentation = find.widgetWithText(
        ElarniCheckboxTile,
        'Enable fragmentation',
      );
      await tester.tap(find.text('Enable fragmentation'));
      await tester.pumpAndSettle();
      // The defaults shown after the failed load must not replace the store.
      expect(updates, isEmpty);
      expect(tester.widget<ElarniCheckboxTile>(fragmentation).value, isTrue);
      await tester.tap(find.text('Enable fragmentation'));
      await tester.pumpAndSettle();
      expect(updates.single.fragmentationEnabled, isFalse);
      expect(updates.single.socksPort, 21080);
    },
  );

  testWidgets('the Import button says Importing only while importing', (
    tester,
  ) async {
    final connecting = Completer<String>();
    final control = FakeTunnelControl()..onConnect = () => connecting.future;
    await pumpApp(tester, control);
    await tester.tap(find.text('Connect'));
    await tester.pump();
    final button = find.byKey(const Key('import-toggle'));
    expect(tester.widget<OutlinedButton>(button).onPressed, isNull);
    expect(
      find.descendant(of: button, matching: find.text('Import')),
      findsOneWidget,
    );
    connecting.complete('connected');
    await tester.pumpAndSettle();
  });

  testWidgets(
    'connection recording: the switch enables marks on Home and explains an empty export',
    (tester) async {
      if (!recordingBuild) {
        // Absent even for a setting saved by a recording build.
        final control = FakeTunnelControl()
          ..settings = const TunnelSettings(recordDiagnostics: true);
        await pumpApp(tester, control);
        expect(find.text('Mark problem'), findsNothing);
        await openSettings(tester);
        await selectCategory(tester, SettingsCategory.advanced);
        // The Diagnostics section would follow Monitoring, inside the built extent.
        await reveal(tester, find.text('Show monitoring on main screen'));
        expect(find.text('Record connection diagnostics'), findsNothing);
        expect(find.text('Save recording as ZIP'), findsNothing);
        return;
      }
      final control = FakeTunnelControl()
        ..recordingExportError = PlatformException(code: 'recording_empty');
      await pumpApp(tester, control);
      expect(find.text('Mark problem'), findsNothing);
      await openSettings(tester);
      await selectCategory(tester, SettingsCategory.advanced);
      final mark = find.widgetWithText(OutlinedButton, 'Mark');
      await reveal(tester, mark);
      expect(tester.widget<OutlinedButton>(mark).onPressed, isNull);
      await tester.tap(find.text('Record connection diagnostics'));
      await tester.pumpAndSettle();
      expect(control.settings.recordDiagnostics, isTrue);
      await tester.tap(mark);
      await tester.pumpAndSettle();
      expect(control.recordingMarks, 1);
      expect(find.textContaining('Problem marked at'), findsOneWidget);
      await tester.tap(find.byTooltip('Dismiss message'));
      await tester.pumpAndSettle();
      final export = find.widgetWithText(OutlinedButton, 'Export');
      await reveal(tester, export);
      await tester.tap(export);
      await tester.pumpAndSettle();
      expect(control.recordingExports, 1);
      expect(find.textContaining('Nothing is recorded yet'), findsOneWidget);
      await closeSettings(tester);
      await tester.tap(find.text('Mark problem'));
      await tester.pumpAndSettle();
      expect(control.recordingMarks, 2);
    },
  );

  testWidgets(
    'disposing the app cancels monitoring and ignores late connection results',
    (tester) async {
      final pending = Completer<String>();
      final control = FakeTunnelControl()
        ..settings = const TunnelSettings(monitoringEnabled: true)
        ..onConnect = () => pending.future;
      await pumpApp(tester, control);
      await tester.tap(find.text('Connect'));
      await tester.pump();
      final metricsReads = control.metricsReads;
      await tester.pumpWidget(const SizedBox());
      pending.complete('connecting');
      await tester.pump(const Duration(seconds: 10));
      expect(tester.takeException(), isNull);
      expect(control.metricsReads, metricsReads);
    },
  );

  // A tray Connect can start while a confirmation dialog is open. Confirming
  // must not take Connect's busy flag, or Connect's result is dropped.
  for (final (action, confirm) in [
    ('delete', 'Delete'),
    ('backup', 'Save backup'),
    ('repair', 'Repair'),
  ]) {
    testWidgets('a confirmed $action waits for a tray Connect', (tester) async {
      final connecting = Completer<String>();
      final deleted = <String>[];
      final control = _DeletingControl(deleted)
        ..onConnect = () => connecting.future;
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(ElarniApp(tunnelControl: control, windows: true));
      await tester.pumpAndSettle();
      if (action == 'delete') {
        await openSubscriptions(tester);
        await tester.tap(
          find.byKey(const ValueKey('subscription-actions:group')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Delete').last);
      } else {
        await openSettings(tester);
        await selectCategory(tester, SettingsCategory.backup);
        final title = action == 'backup'
            ? 'Create encrypted backup'
            : 'Repair VPN setup';
        await reveal(tester, find.text(title));
        await tester.tap(find.text(title));
      }
      await tester.pumpAndSettle();
      final dialog = find.byType(AlertDialog);
      if (action == 'backup') {
        final fields = find.descendant(
          of: dialog,
          matching: find.byType(TextField),
        );
        await tester.enterText(fields.first, 'synthetic backup password');
        await tester.enterText(fields.last, 'synthetic backup password');
      }
      const channel = DesktopIntegration.channel;
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(const MethodCall('action', 'connect')),
        null,
      );
      await tester.pump();
      expect(control.connectCalls, 1);
      await tester.tap(
        find.descendant(of: dialog, matching: find.text(confirm)),
      );
      // Let the dialog finish closing while Connect is still running.
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      connecting.completeError(PlatformException(code: 'elevation_denied'));
      await tester.pumpAndSettle();
      expect(find.textContaining('VPN permission was denied'), findsOneWidget);
      expect(
        [deleted, control.exportedPasswords, control.repairCalls],
        [isEmpty, isEmpty, 0],
      );
    });
  }

  // An open menu keeps the enabled flags it was built with, so its items
  // stay tappable after a tray Connect starts.
  for (final item in ['Share subscription', 'Share links', 'Rename']) {
    testWidgets('$item picked from an open menu waits for a tray Connect', (
      tester,
    ) async {
      final connecting = Completer<String>();
      final control = FakeTunnelControl()
        ..onConnect = (() => connecting.future)
        ..snapshot = SubscriptionSnapshot(
          selectedNodeId: 'a',
          subscriptions: [
            SubscriptionGroup(
              id: 'group',
              name: 'Fixture',
              status: 'ready',
              actions: const ['raw'],
              nodes: fixtureSubscriptions.subscriptions.first.nodes,
            ),
          ],
        );
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(ElarniApp(tunnelControl: control, windows: true));
      await tester.pumpAndSettle();
      await openSubscriptions(tester);
      await tester.tap(
        find.byKey(const ValueKey('subscription-actions:group')),
      );
      await tester.pumpAndSettle();
      const channel = DesktopIntegration.channel;
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(const MethodCall('action', 'connect')),
        null,
      );
      await tester.pump();
      expect(control.connectCalls, 1);
      await tester.tap(find.text(item).last);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      connecting.completeError(PlatformException(code: 'elevation_denied'));
      await tester.pumpAndSettle();
      expect(find.textContaining('VPN permission was denied'), findsOneWidget);
      expect(
        [
          control.sharedIDs,
          control.challenges,
          find.text('Rename subscription'),
        ],
        [isEmpty, isEmpty, findsNothing],
      );
    });
  }

  testWidgets(
    'a server row leaves its last connection and probe to the latency tooltip',
    (tester) async {
      final control = FakeTunnelControl()
        ..snapshot = const SubscriptionSnapshot(
          selectedNodeId: 'a',
          subscriptions: [
            SubscriptionGroup(
              id: 'group',
              name: 'Fixture',
              status: 'ready',
              nodes: [
                SubscriptionNode(
                  id: 'a',
                  name: 'Node A',
                  protocol: 'VLESS',
                  transport: 'tcp',
                  security: 'tls',
                  selected: true,
                  lastSuccessAt: 1700000000,
                  lastSuccessCurrent: true,
                ),
              ],
            ),
          ],
        )
        ..onPing = (id) async => PingResult(
          nodeId: id,
          status: 'success',
          latencyMs: 36,
          timestamp: DateTime.now().millisecondsSinceEpoch / 1000,
          protocol: 'tcp',
        );
      await pumpApp(tester, control);
      await tester.tap(find.byKey(const ValueKey('ping:a')));
      await tester.pumpAndSettle();
      final row = find.byKey(const ValueKey('node:a'));
      expect(find.descendant(of: row, matching: find.text('36 ms')), findsOne);
      for (final text in ['Connected', 'TCP endpoint']) {
        expect(
          find.descendant(of: row, matching: find.textContaining(text)),
          findsNothing,
        );
      }
      final tooltip = tester.widget<Tooltip>(
        find
            .ancestor(
              of: find.byKey(const ValueKey('ping:a')),
              matching: find.byType(Tooltip),
            )
            .first,
      );
      expect(
        tooltip.message,
        allOf(contains('Connected'), contains('TCP endpoint · ')),
      );
    },
  );

  testWidgets('Routing keeps profiles and per-app routing on their own tabs', (
    tester,
  ) async {
    const desktop = MethodChannel('com.elarni/desktop');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      desktop,
      (call) async => call.method == 'routingApplications' ? [] : null,
    );
    addTearDown(() => messenger.setMockMethodCallHandler(desktop, null));
    await pumpApp(tester, FakeTunnelControl());
    await openRouting(tester);
    expect(find.text('No routing profiles'), findsOneWidget);
    expect(find.byTooltip('Refresh profiles'), findsOneWidget);
    expect(find.byKey(const Key('per-app-routing-mode')), findsNothing);
    await tester.tap(find.widgetWithText(Tab, 'Per-app routing'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('per-app-routing-mode')), findsOneWidget);
    expect(
      find.text(
        'Choose which apps use the VPN. Applies to every subscription.',
      ),
      findsOneWidget,
    );
    expect(find.text('No routing profiles'), findsNothing);
    expect(find.byTooltip('Refresh profiles'), findsNothing);
    // The page comes back on the tab it was left on.
    await openSubscriptions(tester);
    await openRouting(tester);
    expect(find.byKey(const Key('per-app-routing-mode')), findsOneWidget);
  });

  // "No matching servers" offered a Clear search that did nothing.
  for (final status in ['pending', 'failed']) {
    testWidgets('Home says an empty $status subscription has no servers yet', (
      tester,
    ) async {
      final control = FakeTunnelControl()
        ..snapshot = SubscriptionSnapshot(
          selectedNodeId: null,
          subscriptions: [
            SubscriptionGroup(
              id: 'empty',
              name: 'Empty',
              status: status,
              nodes: const [],
            ),
          ],
        );
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(ElarniApp(tunnelControl: control));
      await tester.pumpAndSettle();
      expect(find.text('No servers yet'), findsOneWidget);
      expect(find.text('No matching servers'), findsNothing);
      expect(find.text('Clear search'), findsNothing);
    });
  }
}

final class _DeletingControl extends FakeTunnelControl {
  _DeletingControl(this.deleted);
  final List<String> deleted;

  @override
  Future<SubscriptionSnapshot> deleteSubscription(String id) async {
    deleted.add(id);
    return snapshot;
  }
}
