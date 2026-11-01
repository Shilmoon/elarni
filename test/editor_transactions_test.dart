import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:elarni/elarni_app.dart';
import 'package:elarni/elarni_widgets.dart';
import 'package:elarni/tunnel_channel.dart';
import 'interface_cleanup_test.dart' show routingFixture;
import 'elarni_app_test.dart'
    show openPerAppRouting, openRouting, openSettings, selectCategory, reveal;
import 'support/fake_tunnel_control.dart';

class RejectableEditors extends FakeTunnelControl {
  bool reject = true;
  int writes = 0;
  Completer<void>? pending;
  String? submitted;

  Future<void> write(String value) async {
    writes++;
    submitted = value;
    await pending?.future;
    if (reject) throw PlatformException(code: 'rejected');
  }

  @override
  Future<RoutingSnapshot> updateRoutingProfile(
    String id,
    String content,
  ) async {
    await write(content);
    return routingSnapshot;
  }

  @override
  Future<TunnelSettings> updateTunnelSettings(TunnelSettings value) async {
    await write(value.toMap().toString());
    return settings = value;
  }

  @override
  Future<SubscriptionSnapshot> renameSubscription(
    String id,
    String? name,
  ) async {
    await write(name ?? '');
    return snapshot;
  }

  @override
  Future<SubscriptionSnapshot> updateSubscriptionFetchOptions(
    String id,
    Map<String, Object?> options,
  ) async {
    await write(options.toString());
    return snapshot;
  }

  @override
  Future<TunnelSettings> updateInboundCredentials(
    String user,
    String pass,
  ) async {
    await write(user);
    return settings;
  }
}

void main() {
  for (final windows in [false, true]) {
    // On macOS, Include all networks is Block traffic without VPN, outside this editor.
    final routeToggle = windows
        ? 'Include all networks'
        : 'Enforce tunnel routes';
    Future<void> mount(WidgetTester tester, FakeTunnelControl control) async {
      await tester.binding.setSurfaceSize(const Size(1280, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const channel = MethodChannel('com.elarni/desktop');
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'routingApplications') {
          return [
            {'name': 'Example Browser', 'process': 'browser.exe'},
          ];
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await tester.pumpWidget(
        ElarniApp(tunnelControl: control, windows: windows),
      );
      await tester.pumpAndSettle();
    }

    testWidgets(
      'app and network draft survives navigation, rejects, retries and cancels ($windows)',
      (tester) async {
        final control = RejectableEditors();
        await mount(tester, control);
        await openPerAppRouting(tester);
        await tester.tap(find.text('Add apps'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Example Browser'));
        await tester.tap(find.text('Profile & executable tools'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Edit executable rules'));
        await tester.pumpAndSettle();
        final rules = find.widgetWithText(
          TextField,
          'Executable names or full paths',
        );
        await tester.enterText(rules, 'browser.exe');
        await openSettings(tester);
        await openRouting(tester);
        expect(tester.widget<TextField>(rules).controller!.text, 'browser.exe');
        await tester.tap(find.text('Update draft'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Done'));
        await tester.pumpAndSettle();
        await openSettings(tester);
        await openRouting(tester);
        expect(find.text('Example Browser'), findsOneWidget);
        await tester.tap(find.text('Advanced network routes'));
        await tester.pumpAndSettle();
        await reveal(tester, find.text(routeToggle));
        await tester.tap(find.text(routeToggle));
        await tester.pumpAndSettle();
        await reveal(tester, find.text('Included routes'));
        await tester.tap(find.text('Included routes'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), '10.0.0.0/8');
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(control.writes, 0);
        await tester.tap(find.byKey(const Key('nav-home')));
        await tester.pumpAndSettle();
        // Simulate another setting being saved while this draft is retained.
        control.settings = control.settings.copyWith(
          resolveServer: true,
          excludedRoutes: ['192.168.0.0/16'],
        );
        control.importListener?.call(null);
        await tester.pumpAndSettle();
        await openRouting(tester);
        await reveal(tester, find.text('Save changes'));
        await tester.tap(find.text('Save changes'));
        await tester.pumpAndSettle();
        expect(control.writes, 1);
        expect(find.text('Example Browser'), findsOneWidget);
        expect(find.textContaining('draft is kept'), findsOneWidget);
        control.reject = false;
        await tester.tap(find.text('Save changes'));
        await tester.pumpAndSettle();
        expect(control.settings.perAppProcesses, ['browser.exe']);
        expect(
          windows
              ? control.settings.includeAllNetworks
              : control.settings.enforceRoutes,
          isTrue,
        );
        expect(control.settings.includedRoutes, ['10.0.0.0/8']);
        expect(control.settings.resolveServer, isTrue);
        expect(control.settings.excludedRoutes, ['192.168.0.0/16']);
        await reveal(tester, find.text('Advanced network routes'));
        // Expansion state need not survive navigation.
        if (find.text(routeToggle).hitTestable().evaluate().isEmpty) {
          await tester.tap(find.text('Advanced network routes'));
          await tester.pumpAndSettle();
        }
        await reveal(tester, find.text(routeToggle));
        await tester.tap(find.text(routeToggle));
        await tester.pumpAndSettle();
        await reveal(tester, find.text('Cancel'));
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<ElarniCheckboxTile>(
                find.widgetWithText(ElarniCheckboxTile, routeToggle),
              )
              .value,
          isTrue,
        );
        expect(control.writes, 2);
        expect(control.connectCalls + control.disconnectCalls, 0);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets('enforced routes need specific included routes ($windows)', (
      tester,
    ) async {
      final control = RejectableEditors()..reject = false;
      await mount(tester, control);
      await openPerAppRouting(tester);
      await tester.tap(find.text('Advanced network routes'));
      await tester.pumpAndSettle();
      await reveal(tester, find.text('Enforce tunnel routes'));
      await tester.tap(find.text('Enforce tunnel routes'));
      await tester.pumpAndSettle();
      await reveal(tester, find.text('Save changes'));
      await tester.tap(find.text('Save changes'));
      await tester.pumpAndSettle();
      // The default routes include 0.0.0.0/0 and ::/0, which every core refuses.
      expect(control.writes, 0);
      expect(
        find.textContaining('Enforce tunnel routes needs specific'),
        findsOneWidget,
      );
      await reveal(tester, find.text('Included routes'));
      await tester.tap(find.text('Included routes'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        '10.0.0.0/8',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      await reveal(tester, find.text('Save changes'));
      await tester.tap(find.text('Save changes'));
      await tester.pumpAndSettle();
      expect(control.writes, 1);
      expect(control.settings.enforceRoutes, isTrue);
      expect(control.settings.includedRoutes, ['10.0.0.0/8']);
      await tester.pumpWidget(const SizedBox());
    });

    for (final kind in ['credentials', 'rename', 'download']) {
      testWidgets('editor retains native-rejected $kind input ($windows)', (
        tester,
      ) async {
        final control = RejectableEditors();
        await mount(tester, control);
        if (kind == 'credentials') {
          await openSettings(tester);
          await selectCategory(tester, SettingsCategory.connection);
          await reveal(tester, find.text('Proxy login'));
          await tester.tap(find.text('Proxy login'));
        } else {
          await tester.tap(find.byKey(const Key('nav-subscriptions')));
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(const ValueKey('subscription-actions:group')),
          );
          await tester.pumpAndSettle();
          await tester.tap(
            find.text(kind == 'rename' ? 'Rename' : 'Download options'),
          );
        }
        await tester.pumpAndSettle();
        final field = kind == 'download'
            ? find.widgetWithText(TextField, 'Fallback hosts')
            : find.byType(TextField).first;
        final value = kind == 'download'
            ? 'fallback.example.com'
            : 'Example draft';
        await tester.enterText(field, value);
        if (kind == 'credentials')
          await tester.enterText(
            find.byType(TextField).last,
            'synthetic-password',
          );
        final save = find.widgetWithText(
          FilledButton,
          kind == 'credentials' ? 'Save & enable' : 'Save',
        );
        await tester.tap(save);
        await tester.pumpAndSettle();
        expect(control.writes, 1);
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(tester.widget<TextField>(field).controller!.text, value);
        control.reject = false;
        await tester.tap(save);
        await tester.pumpAndSettle();
        expect(control.writes, 2);
        expect(find.byType(AlertDialog), findsNothing);
        await tester.pumpWidget(const SizedBox());
      });
    }

    for (final structured in [false, true]) {
      testWidgets(
        'routing editor retains rejected draft and blocks duplicate save ($windows, $structured)',
        (tester) async {
          final control = RejectableEditors()..routingSnapshot = routingFixture;
          await mount(tester, control);
          await tester.tap(find.byKey(const Key('nav-routing')));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('routing-actions:route')));
          await tester.pumpAndSettle();
          await tester.tap(
            find.text(structured ? 'Edit routing and DNS' : 'Edit JSON'),
          );
          await tester.pumpAndSettle();
          if (structured) {
            await tester.tap(find.text('Advanced'));
            await tester.pumpAndSettle();
          }
          final field = structured
              ? find.widgetWithText(TextField, 'Profile name')
              : find.byType(TextField);
          final value = structured ? 'My draft' : '{"Name":"My draft"}';
          await tester.enterText(field, value);
          final save = find.widgetWithText(FilledButton, 'Validate and save');
          control.pending = Completer<void>();
          await tester.tap(save);
          await tester.pump();
          await tester.tap(save);
          await tester.pump();
          expect(control.writes, 1);
          control.pending!.complete();
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsOneWidget);
          expect(tester.widget<TextField>(field).controller!.text, value);
          control.reject = false;
          await tester.tap(save);
          await tester.pumpAndSettle();
          expect(control.writes, 2);
          expect(control.submitted, contains('My draft'));
          expect(find.byType(AlertDialog), findsNothing);
          // A completed write must not close a later dialog after Cancel.
          Future<void> reopen() async {
            await tester.tap(
              find.byKey(const ValueKey('routing-actions:route')),
            );
            await tester.pumpAndSettle();
            await tester.tap(
              find.text(structured ? 'Edit routing and DNS' : 'Edit JSON'),
            );
            await tester.pumpAndSettle();
          }

          // Cancel cannot hide a save that is still being applied.
          await reopen();
          control.pending = Completer<void>();
          await tester.tap(save);
          await tester.pump();
          await tester.tap(
            find.descendant(
              of: find.byType(AlertDialog),
              matching: find.text('Cancel'),
            ),
            warnIfMissed: false,
          );
          await tester.pump();
          expect(find.byType(AlertDialog), findsOneWidget);
          control.pending!.complete();
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsNothing);
          // Esc and an outside click must not discard an open editor's draft.
          await reopen();
          expect(find.byType(AlertDialog), findsOneWidget);
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.tapAt(const Offset(4, 4));
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsOneWidget);
          await tester.tap(find.text('Cancel').last);
          await tester.pumpAndSettle();

          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }

    for (final fragmentation in [false, true]) {
      testWidgets(
        'settings editor keeps rejected values ($windows, $fragmentation)',
        (tester) async {
          final control = RejectableEditors();
          await mount(tester, control);
          await openSettings(tester);
          await selectCategory(
            tester,
            fragmentation
                ? SettingsCategory.advanced
                : SettingsCategory.connection,
          );
          final title = fragmentation
              ? 'Fragmentation options'
              : 'SOCKS5 and HTTP ports';
          await reveal(tester, find.text(title));
          await tester.tap(find.text(title));
          await tester.pumpAndSettle();
          final field = find.widgetWithText(
            TextField,
            fragmentation ? 'Fragment length (bytes)' : 'SOCKS5 port',
          );
          final value = fragmentation ? '90-200' : '12080';
          await tester.enterText(field, value);
          await tester.tap(find.widgetWithText(FilledButton, 'Save'));
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsOneWidget);
          expect(tester.widget<TextField>(field).controller!.text, value);
          control.reject = false;
          await tester.tap(find.widgetWithText(FilledButton, 'Save'));
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsNothing);
          expect(control.writes, 2);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
}
