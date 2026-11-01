import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:elarni/desktop_integration.dart';
import 'package:elarni/elarni_app.dart';
import 'package:elarni/elarni_widgets.dart';
import 'package:elarni/strings.dart' show appLocale;
import 'elarni_app_test.dart' show openPerAppRouting, selectCategory, reveal;
import 'package:elarni/tunnel_channel.dart';
import 'support/fake_tunnel_control.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = DesktopIntegration.channel;

  testWidgets(
    'the language chosen in Settings applies at once, reaches the tray and persists',
    (tester) async {
      var stored = '{}';
      Map<Object?, Object?>? status;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getPreferences') return stored;
        if (call.method == 'setPreferences')
          stored = (call.arguments as Map)['json'] as String;
        if (call.method == 'setStatus') status = call.arguments as Map;
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      addTearDown(() => appLocale = const Locale('en'));
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      Future<void> choose(String language) async {
        await tester.tap(find.byKey(const Key('language')));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(MenuItemButton, language).last);
        await tester.pumpAndSettle();
      }

      await tester.pumpWidget(
        ElarniApp(tunnelControl: FakeTunnelControl(), windows: true),
      );
      await tester.pumpAndSettle();
      expect(status?['language'], 'en');
      await tester.tap(find.byKey(const Key('nav-settings')));
      await tester.pumpAndSettle();
      await choose('Русский');
      expect(jsonDecode(stored)['language'], 'ru');
      expect(find.text('Язык'), findsOneWidget);
      expect(find.text('Настройки'), findsWidgets);
      expect(status?['language'], 'ru');
      // A restart starts in the saved language.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        ElarniApp(tunnelControl: FakeTunnelControl(), windows: true),
      );
      await tester.pumpAndSettle();
      expect(find.text('Подписки'), findsWidgets);
      await tester.tap(find.byKey(const Key('nav-settings')));
      await tester.pumpAndSettle();
      await choose('Как в системе');
      expect(jsonDecode(stored)['language'], 'system');
      expect(find.text('Language'), findsOneWidget);
      expect(status?['language'], 'en');
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a connected server that passes no traffic says so on Home and in the tray',
    (tester) async {
      Map<Object?, Object?>? status;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getPreferences') return '{}';
        if (call.method == 'setStatus') status = call.arguments as Map;
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final control = FakeTunnelControl()
        ..phase = 'connected'
        ..liveness = 'noTraffic';
      await tester.pumpWidget(ElarniApp(tunnelControl: control, windows: true));
      await tester.pumpAndSettle();
      expect(find.text('Connected · no traffic'), findsOneWidget);
      expect(
        find.textContaining('The server passed no traffic at '),
        findsOneWidget,
      );
      expect(status?['state'], 'connected, no traffic');
      control.liveness = 'ok';
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.text('Connected'), findsOneWidget);
      expect(find.textContaining('no traffic'), findsNothing);
      expect(status?['state'], 'connected');
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final windows in [true, false])
    testWidgets(
      'Block traffic without VPN shows a red Home banner only while it blocks (${windows ? 'Windows' : 'macOS'})',
      (tester) async {
        messenger.setMockMethodCallHandler(
          channel,
          (call) async => call.method == 'getPreferences' ? '{}' : null,
        );
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        await tester.binding.setSurfaceSize(const Size(1200, 2800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final control = FakeTunnelControl()
          ..phase = 'failed'
          ..settings = const TunnelSettings(xrayTunEnabled: true);
        await tester.pumpWidget(
          ElarniApp(tunnelControl: control, windows: windows),
        );
        await tester.pumpAndSettle();
        const banner = 'Traffic blocked until you reconnect';
        // Off, a failed connection blocks nothing.
        expect(find.text(banner), findsNothing);
        await tester.tap(find.byKey(const Key('nav-settings')));
        await tester.pumpAndSettle();
        await selectCategory(tester, SettingsCategory.connection);
        await reveal(tester, find.text('Block traffic without VPN'));
        await tester.tap(find.text('Block traffic without VPN'));
        await tester.pumpAndSettle();
        // macOS has no guard of its own: the switch is Include all networks.
        expect(control.settings.blockWithoutVPN, windows);
        expect(control.settings.includeAllNetworks, !windows);
        if (!windows) {
          await openPerAppRouting(tester);
          await tester.tap(find.text('Advanced network routes'));
          await tester.pumpAndSettle();
          expect(find.text('Include all networks'), findsNothing);
        }
        await tester.tap(find.byKey(const Key('nav-home')));
        await tester.pumpAndSettle();
        expect(find.text(banner), findsOneWidget);
        await tester.tap(find.text('Reconnect'));
        await tester.pumpAndSettle();
        expect(control.connectCalls, 1);
        expect(find.text(banner), findsNothing);
        control.phase = 'failed';
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpAndSettle();
        expect(find.text(banner), findsOneWidget);
        // Repair VPN setup removes the guard, or on macOS the VPN setup.
        await tester.tap(find.text('Lift block'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Repair'));
        await tester.pumpAndSettle();
        expect(control.repairCalls, 1);
        expect(find.text(banner), findsNothing);
        await tester.pumpWidget(const SizedBox());
      },
    );

  testWidgets(
    'the local proxy login shows and copies, and dropping it needs a warning',
    (tester) async {
      String? copied;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData')
          copied = (call.arguments as Map)['text'] as String;
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => call.method == 'getPreferences' ? '{}' : null,
      );
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await tester.binding.setSurfaceSize(const Size(1200, 2800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final control = FakeTunnelControl()
        ..settings = const TunnelSettings(
          xrayTunEnabled: false,
          inboundAuthEnabled: true,
          inboundCredentialsConfigured: true,
        )
        ..inboundLogin = {'username': 'elarni-7f3k', 'password': 's3cret-pass'};
      await tester.pumpWidget(ElarniApp(tunnelControl: control, windows: true));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('nav-settings')));
      await tester.pumpAndSettle();
      await selectCategory(tester, SettingsCategory.connection);
      await reveal(tester, find.text('Proxy login'));
      expect(find.textContaining('elarni-7f3k'), findsOneWidget);
      expect(find.textContaining('s3cret-pass'), findsNothing);
      await tester.tap(find.text('Show'));
      await tester.pumpAndSettle();
      expect(find.textContaining('s3cret-pass'), findsOneWidget);
      await tester.tap(find.text('Copy'));
      await tester.pumpAndSettle();
      expect(copied, 's3cret-pass');
      await reveal(tester, find.text('Allow apps without a login'));
      await tester.tap(find.text('Allow apps without a login'));
      await tester.pumpAndSettle();
      expect(find.text('Allow apps without a login?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(control.settings.inboundAuthEnabled, isTrue);
      await tester.tap(find.text('Allow apps without a login'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Allow without login'));
      await tester.pumpAndSettle();
      expect(control.settings.inboundAuthEnabled, isFalse);
      // Home warns while the local proxy accepts any program.
      await tester.tap(find.byKey(const Key('nav-home')));
      await tester.pumpAndSettle();
      const banner = 'Your local proxy accepts apps without a login';
      expect(find.text(banner), findsOneWidget);
      await tester.tap(find.text('Require a login'));
      await tester.pumpAndSettle();
      expect(control.settings.inboundAuthEnabled, isTrue);
      expect(control.inboundLogin['username'], 'elarni-7f3k');
      expect(find.text(banner), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'an install without a login can wait on the warning or get a generated one',
    (tester) async {
      final stored = ['{}'];
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getPreferences') return stored.last;
        if (call.method == 'setPreferences')
          stored.add((call.arguments as Map)['json'] as String);
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await tester.binding.setSurfaceSize(const Size(1200, 2800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final control = FakeTunnelControl()
        ..settings = const TunnelSettings(xrayTunEnabled: false);
      await tester.pumpWidget(ElarniApp(tunnelControl: control, windows: true));
      await tester.pumpAndSettle();
      const banner = 'Your local proxy accepts apps without a login';
      expect(find.text(banner), findsOneWidget);
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      expect(find.text(banner), findsNothing);
      expect(jsonDecode(stored.last)['loginWarningDismissed'], isTrue);
      // The choice survives a restart.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(ElarniApp(tunnelControl: control, windows: true));
      await tester.pumpAndSettle();
      expect(find.text(banner), findsNothing);
      // Requiring a login with none saved generates one.
      await tester.tap(find.byKey(const Key('nav-settings')));
      await tester.pumpAndSettle();
      await selectCategory(tester, SettingsCategory.connection);
      await reveal(tester, find.text('Allow apps without a login'));
      await tester.tap(find.text('Allow apps without a login'));
      await tester.pumpAndSettle();
      expect(control.settings.inboundAuthEnabled, isTrue);
      expect(control.inboundLogin['username'], matches(r'^[0-9a-f]{32}$'));
      expect(control.inboundLogin['password'], matches(r'^[0-9a-f]{32}$'));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('tray retries a failed status without a rebuild loop', (
    tester,
  ) async {
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getPreferences') return '{}';
      if (call.method == 'setStatus' && ++calls == 1) {
        throw PlatformException(code: 'transient_failure');
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final desktop = DesktopIntegration();
    await desktop.load();
    desktop.addListener(
      () => desktop.status('connected', canConnect: false, canDisconnect: true),
    );
    desktop.status('connected', canConnect: false, canDisconnect: true);
    await tester.pump();
    expect(calls, 1);
    expect(desktop.error, 'Desktop status could not be updated.');
    await tester.pump(const Duration(milliseconds: 999));
    expect(calls, 1);
    await tester.pump(const Duration(milliseconds: 1));
    expect(calls, 2);
    expect(desktop.error, isNull);
    await tester.pump(const Duration(seconds: 60));
    expect(calls, 2);
    desktop.dispose();
  });

  testWidgets(
    'tray serializes newer state and ignores completion after disposal',
    (tester) async {
      final sent = <String>[];
      final replies = [Completer<void>(), Completer<void>()];
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getPreferences') return '{}';
        if (call.method == 'setStatus') {
          sent.add((call.arguments as Map)['state'] as String);
          await replies[sent.length - 1].future;
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final desktop = DesktopIntegration();
      await desktop.load();
      desktop.status('connected', canConnect: false, canDisconnect: true);
      desktop.status('disconnected', canConnect: true, canDisconnect: false);
      await tester.pump();
      expect(sent, ['connected']);
      replies[0].complete();
      await tester.pump();
      expect(sent, ['connected', 'disconnected']);
      desktop.dispose();
      replies[1].completeError(PlatformException(code: 'late_failure'));
      await tester.pump(const Duration(seconds: 60));
      expect(sent, ['connected', 'disconnected']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'persistent tray failures back off and disposal cancels retries',
    (tester) async {
      var calls = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getPreferences') return '{}';
        if (call.method == 'setStatus') {
          calls++;
          throw PlatformException(code: 'unavailable');
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final desktop = DesktopIntegration();
      await desktop.load();
      desktop.status('connected', canConnect: false, canDisconnect: true);
      await tester.pump();
      for (final seconds in [1, 2, 4, 8, 16, 30]) {
        final before = calls;
        await tester.pump(Duration(seconds: seconds - 1));
        expect(calls, before);
        await tester.pump(const Duration(seconds: 1));
        expect(calls, before + 1);
      }
      desktop.dispose();
      final before = calls;
      await tester.pump(const Duration(minutes: 2));
      expect(calls, before);
    },
  );

  test(
    'expiry reminders are opt-in, due within three days, and limited across relaunch',
    () async {
      var stored = '{}';
      var notifications = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'getPreferences':
            return stored;
          case 'requestNotifications':
            return true;
          case 'setPreferences':
            stored = (call.arguments as Map)['json'] as String;
          case 'showExpiryReminder':
            notifications++;
            expect((call.arguments as Map)['count'], 1);
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final now = DateTime.utc(2026, 9, 11);
      SubscriptionGroup group(String id, int days) => SubscriptionGroup(
        id: id,
        name: id,
        status: 'ready',
        metadata: {
          'expire':
              now.add(Duration(days: days)).millisecondsSinceEpoch ~/ 1000,
        },
        nodes: const [],
      );
      final snapshot = SubscriptionSnapshot(
        subscriptions: [
          group('soon', 2),
          group('later', 5),
          group('expired', -1),
        ],
      );
      final desktop = DesktopIntegration();
      await desktop.load();
      await desktop.remindExpiring(snapshot, now: now);
      expect(notifications, 0);
      await desktop.update(expiryReminders: true);
      await desktop.remindExpiring(snapshot, now: now);
      await desktop.remindExpiring(snapshot, now: now);
      expect(notifications, 1);
      desktop.dispose();
      final reopened = DesktopIntegration();
      await reopened.load();
      await reopened.remindExpiring(snapshot, now: now);
      expect(notifications, 1);
      await reopened.remindExpiring(
        snapshot,
        now: now.add(const Duration(days: 1)),
      );
      expect(notifications, 2);
      reopened.dispose();
    },
  );

  test(
    'desktop preferences survive relaunch and failed writes preserve prior choices',
    () async {
      var stored = '{}', fail = false;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getPreferences') return stored;
        if (fail) throw PlatformException(code: 'preferences_failed');
        stored = (call.arguments as Map)['json'] as String;
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final first = DesktopIntegration();
      await first.load();
      expect(first.theme, ThemeMode.system);
      expect(first.accent, 'evergreen');
      await first.update(
        theme: ThemeMode.dark,
        accent: 'teal',
        sort: 'alphabet',
        pinned: {'fixture'},
      );
      fail = true;
      await expectLater(
        first.update(theme: ThemeMode.light),
        throwsA(isA<PlatformException>()),
      );
      expect(first.theme, ThemeMode.dark);
      first.dispose();
      final reopened = DesktopIntegration();
      await reopened.load();
      expect(reopened.theme, ThemeMode.dark);
      expect(reopened.accent, 'teal');
      expect(reopened.sort, 'alphabet');
      expect(reopened.pinned, {'fixture'});
      reopened.dispose();
    },
  );

  for (final windows in [false, true]) {
    // Native traffic checks cannot expose lost keyboard focus, unchecked saved
    // choices or a selector remaining interactive while preferences are saving.
    testWidgets(
      'checked theme menu preserves keyboard, saving and restored selection (${windows ? 'Windows' : 'macOS'})',
      (tester) async {
        var stored = '{"theme":"dark"}';
        Completer<void>? pending;
        var writes = 0;
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getPreferences') return stored;
          if (call.method == 'setPreferences') {
            writes++;
            await pending?.future;
            stored = (call.arguments as Map)['json'] as String;
          }
          return null;
        });
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        await tester.binding.setSurfaceSize(const Size(1200, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          ElarniApp(tunnelControl: FakeTunnelControl(), windows: windows),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('nav-settings')));
        await tester.pumpAndSettle();
        await selectCategory(tester, SettingsCategory.appearance);
        final themeButton = find.widgetWithText(OutlinedButton, 'Dark');
        expect(themeButton, findsOneWidget);
        await tester.tap(themeButton);
        await tester.pumpAndSettle();
        final darkOption = find.widgetWithText(MenuItemButton, 'Dark');
        expect(darkOption, findsOneWidget);
        expect(
          find.descendant(
            of: darkOption,
            matching: find.byIcon(CupertinoIcons.check_mark),
          ),
          findsOneWidget,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byType(MenuItemButton), findsNothing);
        expect(writes, 0);
        // Escape returns focus to the trigger; arrow opens at the saved choice.
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        expect(darkOption, findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pumpAndSettle();
        pending = Completer<void>();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(writes, 1);
        expect(find.byType(MenuItemButton), findsNothing);
        expect(tester.widget<OutlinedButton>(themeButton).onPressed, isNull);
        await tester.tap(themeButton);
        await tester.pumpAndSettle();
        expect(find.byType(MenuItemButton), findsNothing);
        pending.complete();
        await tester.pumpAndSettle();
        expect(jsonDecode(stored)['theme'], 'light');
        expect(
          tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
          ThemeMode.light,
        );
        await tester.tap(find.widgetWithText(OutlinedButton, 'Light'));
        await tester.pumpAndSettle();
        final lightOption = find.widgetWithText(MenuItemButton, 'Light');
        expect(
          find.descendant(
            of: lightOption,
            matching: find.byIcon(CupertinoIcons.check_mark),
          ),
          findsOneWidget,
        );
        await tester.tapAt(const Offset(250, 150));
        await tester.pumpAndSettle();
        expect(find.byType(MenuItemButton), findsNothing);
        expect(writes, 1);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'desktop theme, sorting, search, pin, fragmentation and tray actions (${windows ? 'Windows' : 'macOS'})',
      (tester) async {
        var stored = '{}';
        String? copied;
        messenger.setMockMethodCallHandler(SystemChannels.platform, (
          call,
        ) async {
          if (call.method == 'Clipboard.setData')
            copied = (call.arguments as Map)['text'] as String;
          return null;
        });
        addTearDown(
          () =>
              messenger.setMockMethodCallHandler(SystemChannels.platform, null),
        );
        Map<Object?, Object?>? status;
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getPreferences') return stored;
          if (call.method == 'setPreferences')
            stored = (call.arguments as Map)['json'] as String;
          if (call.method == 'setStatus') status = call.arguments as Map;
          return null;
        });
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        await tester.binding.setSurfaceSize(const Size(1200, 2800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final control = FakeTunnelControl()
          ..snapshot = const SubscriptionSnapshot(
            selectedNodeId: 'z',
            subscriptions: [
              SubscriptionGroup(
                id: 'first',
                name: 'First subscription',
                status: 'ready',
                nodes: [
                  SubscriptionNode(
                    id: 'z',
                    name: 'Zeta',
                    protocol: 'VLESS',
                    transport: 'tcp',
                    security: 'tls',
                    selected: true,
                  ),
                  SubscriptionNode(
                    id: 'a',
                    name: 'Alpha',
                    protocol: 'VLESS',
                    transport: 'tcp',
                    security: 'tls',
                    selected: false,
                  ),
                ],
              ),
              SubscriptionGroup(
                id: 'second',
                name: 'Second subscription',
                status: 'ready',
                nodes: [
                  SubscriptionNode(
                    id: 'beta',
                    name: 'Beta',
                    protocol: 'Trojan',
                    transport: 'tcp',
                    security: 'tls',
                    selected: false,
                  ),
                ],
              ),
            ],
          );
        await tester.pumpWidget(
          ElarniApp(tunnelControl: control, windows: windows),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('nav-settings')));
        await tester.pumpAndSettle();
        await selectCategory(tester, SettingsCategory.appearance);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Follow system'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Light').last);
        await tester.pumpAndSettle();
        expect(
          tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
          ThemeMode.light,
        );
        await selectCategory(tester, SettingsCategory.general);
        final interval = find.byKey(
          const ValueKey('setting:Subscription auto-update (hours)'),
        );
        await reveal(tester, interval);
        expect(tester.widget<ElarniSelect<int>>(interval).value, 4);
        await tester.tap(interval);
        await tester.pumpAndSettle();
        await tester.tap(find.text('12').last);
        await tester.pumpAndSettle();
        expect(control.settings.subscriptionAutoUpdateHours, 12);
        expect(tester.widget<ElarniSelect<int>>(interval).value, 12);
        await reveal(tester, find.text('Provider order'));
        await tester.tap(find.text('Provider order'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Alphabetical').last);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('nav-home')));
        await tester.pumpAndSettle();
        expect(
          tester.getTopLeft(find.text('Alpha')).dy,
          lessThan(tester.getTopLeft(find.byKey(const ValueKey('node:z'))).dy),
        );
        await tester.tap(find.byKey(const Key('nav-subscriptions')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('First subscription'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('subscription-actions:first')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Share subscription').first);
        await tester.pumpAndSettle();
        expect(control.sharedIDs, ['first']);
        expect(
          find.text('This configuration is too large for a QR code. Use Copy.'),
          findsOneWidget,
        );
        await tester.tap(find.text('Copy'));
        await tester.pumpAndSettle();
        expect(copied, 'https://sub.example.com/test-vector');
        expect(find.byType(AlertDialog), findsNothing);
        control.sharingPNG = base64Encode(
          File('test/windows_profile_qr.png').readAsBytesSync(),
        );
        await tester.tap(
          find.byKey(const ValueKey('subscription-actions:first')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Share subscription').first);
        await tester.pumpAndSettle();
        await tester.binding.setSurfaceSize(const Size(800, 600));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.bySemanticsLabel('Connection QR code'), findsOneWidget);
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
        await tester.binding.setSurfaceSize(const Size(1200, 2800));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('nav-home')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextField, 'Search servers'),
          'Alpha',
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('node:z')), findsNothing);
        expect(find.text('Second subscription'), findsNothing);
        await tester.enterText(
          find.widgetWithText(TextField, 'Search servers'),
          '',
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('nav-subscriptions')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('subscription-actions:second')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Pin subscription'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('nav-home')));
        await tester.pumpAndSettle();
        expect(
          tester.getTopLeft(find.byKey(const ValueKey('node:beta'))).dy,
          lessThan(tester.getTopLeft(find.byKey(const ValueKey('node:a'))).dy),
        );
        expect(jsonDecode(stored)['pinned'], ['second']);
        await tester.tap(find.byKey(const Key('nav-settings')));
        await tester.pumpAndSettle();
        await selectCategory(tester, SettingsCategory.advanced);
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Fragmentation options'));
        await tester.tap(find.text('Fragmentation options'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextField, 'Packets'),
          '1-3',
        );
        await tester.enterText(
          find.widgetWithText(TextField, 'Fragment length (bytes)'),
          '200-100',
        );
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(
          find.text('Use valid increasing ranges within the displayed limits.'),
          findsOneWidget,
        );
        await tester.enterText(
          find.widgetWithText(TextField, 'Fragment length (bytes)'),
          '50-150',
        );
        await tester.enterText(
          find.widgetWithText(TextField, 'Interval (ms)'),
          '2-5',
        );
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(control.settings.fragmentPackets, '1-3');
        expect(control.settings.fragmentLength, '50-150');
        expect(control.settings.fragmentInterval, '2-5');
        for (final action in ['connect', 'disconnect']) {
          await messenger.handlePlatformMessage(
            channel.name,
            channel.codec.encodeMethodCall(MethodCall('action', action)),
            null,
          );
          await tester.pumpAndSettle();
        }
        expect(control.connectCalls, 1);
        expect(control.disconnectCalls, 1);
        expect(status?['state'], 'disconnected');
        expect(status?.keys.toSet(), {
          'state',
          'canConnect',
          'canDisconnect',
          'language',
        });
        expect(status?['language'], 'en');
        await tester.tap(find.byKey(const Key('nav-home')));
        await tester.pumpAndSettle();
        await messenger.handlePlatformMessage(
          channel.name,
          channel.codec.encodeMethodCall(
            const MethodCall('action', 'settings'),
          ),
          null,
        );
        await tester.pumpAndSettle();
        expect(find.byType(ElarniSettings), findsOneWidget);
        expect(control.connectCalls, 1);
        expect(control.disconnectCalls, 1);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
