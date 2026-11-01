import 'dart:async';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:elarni/elarni_app.dart';
import 'package:elarni/elarni_widgets.dart';
import 'package:elarni/tunnel_channel.dart';
import 'elarni_app_test.dart' show openTroubleshoot;
import 'support/fake_tunnel_control.dart';

SubscriptionSnapshot fixture({
  bool favorite = false,
  String revision = 'r1',
  bool local = false,
}) => SubscriptionSnapshot(
  selectedNodeId: 'a',
  subscriptions: [
    SubscriptionGroup(
      id: 'source',
      name: 'Personal subscription',
      status: 'ready',
      isLocal: local,
      hiddenNodes: local ? const [] : const [(id: 'c', name: 'Old server')],
      nodes: [
        SubscriptionNode(
          id: 'a',
          name: 'Current server',
          protocol: 'VLESS',
          transport: 'tcp',
          security: 'tls',
          selected: true,
          favorite: favorite,
          configurationRevision: revision,
          lastSuccessAt: 1700000000,
          lastSuccessCurrent: revision == 'r1',
        ),
        const SubscriptionNode(
          id: 'b',
          selected: false,
          name: 'Replacement server',
          protocol: 'VLESS',
          transport: 'tcp',
          security: 'tls',
          lastSuccessAt: 1700000100,
          lastSuccessCurrent: false,
        ),
      ],
    ),
  ],
);

class ConvenienceControl extends FakeTunnelControl {
  final favorites = <String>[];
  @override
  Future<SubscriptionSnapshot> setNodeFavorite(
    String nodeId,
    bool favorite,
  ) async {
    favorites.add('$nodeId:$favorite');
    return snapshot = fixture(favorite: favorite);
  }
}

void main() {
  for (final platform in [TargetPlatform.macOS, TargetPlatform.windows]) {
    testWidgets(
      'active HTTP health uses measurement time and revision on ${platform.name}',
      (tester) async {
        final control = ConvenienceControl()
          ..snapshot = fixture()
          ..phase = 'connected';
        var revision = 'r1';
        var age = 91;
        control.onPing = (id) async => PingResult(
          nodeId: id,
          status: 'success',
          latencyMs: 12,
          timestamp: DateTime.now().millisecondsSinceEpoch / 1000 - age,
          configurationRevision: revision,
          protocol: 'activeProxy',
        );
        await tester.binding.setSurfaceSize(const Size(1280, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          ElarniApp(
            tunnelControl: control,
            windows: platform == TargetPlatform.windows,
          ),
        );
        await tester.pumpAndSettle();
        await openTroubleshoot(tester);
        await tester.tap(find.text('Check connection'));
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.textContaining('Stale HTTP check'),
          ),
          findsOneWidget,
        );
        expect(find.textContaining('Connection check passed'), findsNothing);
        revision = 'replaced';
        age = 0;
        await tester.tap(find.text('Check connection'));
        await tester.pumpAndSettle();
        expect(find.textContaining('Connection check passed'), findsNothing);
        expect(find.text('Checking connection…'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant.only(platform),
    );

    testWidgets(
      'favorites and recent selection on ${platform.name}',
      (tester) async {
        final control = ConvenienceControl()..snapshot = fixture();
        await tester.binding.setSurfaceSize(const Size(1280, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          ElarniApp(
            tunnelControl: control,
            windows: platform == TargetPlatform.windows,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('favorite:a')));
        await tester.pumpAndSettle();
        expect(control.favorites, ['a:true']);
        expect(control.selectedIDs, isEmpty);
        await tester.tap(find.widgetWithText(ChoiceChip, 'Favorites'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('node:a')), findsOneWidget);
        expect(find.byKey(const ValueKey('node:b')), findsNothing);
        await tester.tap(find.widgetWithText(ChoiceChip, 'Recent'));
        await tester.pumpAndSettle();
        // The row keeps only the server; its last connection is in the tooltip.
        expect(find.textContaining('configuration changed'), findsNothing);
        expect(
          find.byWidgetPredicate(
            (widget) =>
                widget is Tooltip &&
                (widget.message ?? '').contains('configuration changed'),
          ),
          findsOneWidget,
        );
        expect(control.selectedIDs, isEmpty);
        expect(control.connectCalls, 0);
        expect(control.disconnectCalls, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant.only(platform),
    );

    testWidgets(
      'a server menu renames any server and deletes only others on ${platform.name}',
      (tester) async {
        final control = ConvenienceControl()..snapshot = fixture(local: true);
        await tester.binding.setSurfaceSize(const Size(1280, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          ElarniApp(
            tunnelControl: control,
            windows: platform == TargetPlatform.windows,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('node:a')),
          buttons: kSecondaryButton,
        );
        await tester.pumpAndSettle();
        expect(find.text('Delete server'), findsNothing);
        await tester.tap(find.text('Rename server'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).last, 'Home');
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(control.renamedNodes, [('a', 'Home')]);
        await tester.ensureVisible(find.byKey(const ValueKey('node:b')));
        await tester.pumpAndSettle();
        // The name: under the test font the middle of a split-layout row is its ping button.
        await tester.longPress(
          find.descendant(
            of: find.byKey(const ValueKey('node:b')),
            matching: find.text('Replacement server'),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Delete server'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
        await tester.pumpAndSettle();
        expect(control.deletedNodes, ['b']);
        expect(control.selectedIDs, isEmpty);
        // The keyboard reaches the same menu from a focused row.
        Focus.of(
          tester.element(
            find
                .descendant(
                  of: find.byKey(const ValueKey('node:b')),
                  matching: find.byType(Text),
                )
                .first,
          ),
        ).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
        await tester.pumpAndSettle();
        expect(find.text('Delete server'), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.f10);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pumpAndSettle();
        expect(find.text('Rename server'), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(control.selectedIDs, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant.only(platform),
    );

    testWidgets(
      'a visible button opens the server menu on ${platform.name}',
      (tester) async {
        final control = ConvenienceControl()..snapshot = fixture(local: true);
        await tester.binding.setSurfaceSize(const Size(1280, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          ElarniApp(
            tunnelControl: control,
            windows: platform == TargetPlatform.windows,
          ),
        );
        await tester.pumpAndSettle();
        final menu = find.byKey(const ValueKey('server-menu:b'));
        await tester.ensureVisible(menu);
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('node:b')),
            matching: find.byTooltip('Server actions'),
          ),
          findsOneWidget,
        );
        await tester.tap(menu);
        await tester.pumpAndSettle();
        expect(find.text('Rename server'), findsOneWidget);
        await tester.tap(find.text('Delete server'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
        await tester.pumpAndSettle();
        expect(control.deletedNodes, ['b']);
        // Opening the menu does not select the row.
        expect(control.selectedIDs, isEmpty);
        // The narrowest split column keeps its width for names; the gestures remain.
        await tester.binding.setSurfaceSize(const Size(800, 600));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('node:a')), findsOneWidget);
        expect(find.byKey(const ValueKey('server-menu:a')), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant.only(platform),
    );

    testWidgets(
      'a provider server is hidden, and shown again from Hidden servers on ${platform.name}',
      (tester) async {
        final control = ConvenienceControl()..snapshot = fixture();
        await tester.binding.setSurfaceSize(const Size(1280, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          ElarniApp(
            tunnelControl: control,
            windows: platform == TargetPlatform.windows,
          ),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const ValueKey('node:b')));
        await tester.pumpAndSettle();
        // The name: under the test font the middle of a split-layout row is its ping button.
        await tester.longPress(
          find.descendant(
            of: find.byKey(const ValueKey('node:b')),
            matching: find.text('Replacement server'),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Delete server'), findsNothing);
        await tester.tap(find.text('Hide server'));
        await tester.pumpAndSettle();
        expect(
          find.text(
            'Replacement server stays hidden after refreshes. Show it again from Hidden servers.',
          ),
          findsOneWidget,
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Hide'));
        await tester.pumpAndSettle();
        expect(control.deletedNodes, ['b']);
        await tester.tap(find.byKey(const Key('nav-subscriptions')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Personal subscription'));
        await tester.pumpAndSettle();
        final hidden = find.byKey(const ValueKey('hidden-servers:source'));
        await tester.ensureVisible(hidden);
        expect(
          find.descendant(
            of: hidden,
            matching: find.text('Hidden servers · 1'),
          ),
          findsOneWidget,
        );
        await tester.tap(
          find.descendant(of: hidden, matching: find.text('Show again')),
        );
        await tester.pumpAndSettle();
        expect(find.text('Old server'), findsOneWidget);
        await tester.tap(find.widgetWithText(TextButton, 'Show again').last);
        await tester.pumpAndSettle();
        expect(control.shownNodes, ['c']);
        expect(control.selectedIDs, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant.only(platform),
    );

    testWidgets(
      'old and replaced probe results never show healthy latency on ${platform.name}',
      (tester) async {
        final control = ConvenienceControl()..snapshot = fixture();
        control.onPing = (id) async => PingResult(
          nodeId: id,
          status: 'success',
          latencyMs: 12,
          timestamp: DateTime.now().millisecondsSinceEpoch / 1000 - 301,
          configurationRevision: 'r1',
          protocol: 'tcp',
        );
        await tester.binding.setSurfaceSize(const Size(1280, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          ElarniApp(
            tunnelControl: control,
            windows: platform == TargetPlatform.windows,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('ping:a')));
        await tester.pumpAndSettle();
        expect(find.text('12 ms · stale'), findsOneWidget);
        expect(find.byType(LatencyBadge), findsNothing);
        final delayed = Completer<PingResult>();
        control.onPing = (_) => delayed.future;
        await tester.tap(find.byKey(const ValueKey('ping:a')));
        await tester.pump();
        control.snapshot = fixture(revision: 'r2');
        control.importListener?.call(null);
        await tester.pump();
        delayed.complete(
          PingResult(
            nodeId: 'a',
            status: 'success',
            latencyMs: 9,
            timestamp: DateTime.now().millisecondsSinceEpoch / 1000,
            configurationRevision: 'r1',
            protocol: 'tcp',
          ),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('9 ms'), findsNothing);
        expect(find.byType(LatencyBadge), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant.only(platform),
    );
  }
}
