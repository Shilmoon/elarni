import 'dart:async';
import 'dart:convert';

import 'package:elarni/desktop_integration.dart';
import 'package:elarni/elarni_app.dart';
import 'package:elarni/elarni_widgets.dart';
import 'package:elarni/logs_view.dart';
import 'package:elarni/per_app_routing.dart';
import 'package:elarni/routing_editor.dart';
import 'package:elarni/tunnel_channel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'elarni_app_test.dart'
    show
        closeSettings,
        openRecovery,
        openRouting,
        openSettings,
        openSubscriptions,
        openTroubleshoot,
        selectCategory;
import 'support/fake_tunnel_control.dart';

// What a screen reader reads out: every control it can press has a name, and so
// does every text field (Flutter's own guideline skips text fields).
class _NamedTextFields extends AccessibilityGuideline {
  const _NamedTextFields();

  @override
  String get description => 'Text fields have a label or a hint';

  @override
  FutureOr<Evaluation> evaluate(WidgetTester tester) {
    var result = const Evaluation.pass();
    void visit(SemanticsNode node) {
      final data = node.getSemanticsData();
      if (!node.isMergedIntoParent &&
          data.flagsCollection.isTextField &&
          data.label.isEmpty &&
          data.hint.isEmpty &&
          data.tooltip.isEmpty) {
        result += Evaluation.fail('$node: a text field without a name.\n');
      }
      node.visitChildren((child) {
        visit(child);
        return true;
      });
    }

    for (final view in tester.binding.renderViews) {
      final root = view.owner?.semanticsOwner?.rootSemanticsNode;
      if (root != null) visit(root);
    }
    return result;
  }
}

Future<void> _audit(
  WidgetTester tester,
  List<String> failures,
  String screen,
) async {
  for (final guideline in const [
    labeledTapTargetGuideline,
    _NamedTextFields(),
  ]) {
    final result = await guideline.evaluate(tester);
    if (!result.passed) failures.add('$screen: ${result.reason}');
  }
}

Future<void> _tapText(WidgetTester tester, String text) async {
  await tester.ensureVisible(find.text(text).first);
  await tester.tap(find.text(text).first);
  await tester.pumpAndSettle();
}

Future<void> _dismiss(WidgetTester tester) async {
  tester.state<NavigatorState>(find.byType(Navigator).first).pop();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('every app screen names its controls for a screen reader', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final failures = <String>[];
    for (final size in const [Size(1200, 900), Size(500, 800)]) {
      await tester.binding.setSurfaceSize(size);
      final empty = FakeTunnelControl()
        ..snapshot = const SubscriptionSnapshot(subscriptions: []);
      await tester.pumpWidget(ElarniApp(tunnelControl: empty, windows: true));
      await tester.pumpAndSettle();
      await _audit(tester, failures, '$size empty Home');

      for (final phase in ['connected', 'disconnected']) {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(
          ElarniApp(
            tunnelControl: FakeTunnelControl()..phase = phase,
            windows: true,
          ),
        );
        await tester.pumpAndSettle();
        await _audit(tester, failures, '$size $phase Home');
      }
      // A narrow Home shows the selected server only.
      final row = find.byKey(const ValueKey('node:b'));
      if (row.evaluate().isNotEmpty) {
        // The name: the middle of a split-layout row is its ping button.
        await tester.longPress(
          find.descendant(of: row, matching: find.text('Node B')),
        );
        await tester.pumpAndSettle();
        await _audit(tester, failures, '$size server menu');
        await _tapText(tester, 'Rename server');
        await _audit(tester, failures, '$size rename dialog');
        await _dismiss(tester);
      }

      await tester.tap(find.byKey(const Key('import-toggle')));
      await tester.pumpAndSettle();
      await _audit(tester, failures, '$size import');
      await tester.tap(find.byKey(const Key('import-toggle')));
      await tester.pumpAndSettle();

      await openTroubleshoot(tester);
      await _audit(tester, failures, '$size Troubleshoot');
      await _dismiss(tester);
      await openRecovery(tester);
      await _audit(tester, failures, '$size Recovery settings');
      await _dismiss(tester);
      await closeSettings(tester);

      await openSubscriptions(tester);
      await _audit(tester, failures, '$size Subscriptions');
      await _tapText(tester, 'Fixture');
      await _audit(tester, failures, '$size subscription servers');
      final details = find.byKey(
        const PageStorageKey('subscription-details:group'),
      );
      await tester.ensureVisible(details);
      await tester.tap(details);
      await tester.pumpAndSettle();
      await _audit(tester, failures, '$size subscription details');

      await openRouting(tester);
      await _audit(tester, failures, '$size Routing');
      await openSettings(tester);
      for (final category in SettingsCategory.values) {
        if (find
                .byKey(Key('settings-tab-${category.name}'))
                .evaluate()
                .isEmpty &&
            find.byType(ElarniSelect<SettingsCategory>).evaluate().isEmpty) {
          continue;
        }
        await selectCategory(tester, category);
        await _audit(tester, failures, '$size Settings ${category.name}');
      }
      await tester.pumpWidget(const SizedBox());
    }
    await tester.binding.setSurfaceSize(null);
    semantics.dispose();
    expect(failures, isEmpty, reason: failures.join('\n'));
  });

  testWidgets('the editors and the log name their controls', (tester) async {
    final semantics = tester.ensureSemantics();
    final failures = <String>[];
    await tester.binding.setSurfaceSize(const Size(1100, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      DesktopIntegration.channel,
      (call) async => call.method == 'routingApplications' ? [] : null,
    );
    addTearDown(
      () =>
          messenger.setMockMethodCallHandler(DesktopIntegration.channel, null),
    );

    final profile = jsonEncode({
      'Name': 'Fixture',
      'RemoteDNSType': 'DoH',
      'RemoteDNSIP': '1.1.1.1',
      'DomesticDNSType': 'DoU',
      'DomesticDNSIP': '8.8.8.8',
      'DirectSites': ['geosite:private'],
      'ProxySites': ['example.com'],
      'BlockIp': ['192.0.2.0/24'],
    });
    for (var section = 0; section < 3; section++) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RoutingEditor(json: profile, initialSection: section),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _audit(tester, failures, 'routing editor section $section');
      await tester.pumpWidget(const SizedBox());
    }

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: PerAppRoutingEditor(
              settings: const TunnelSettings(
                xrayTunEnabled: true,
                perAppMode: 'bypass',
                perAppProcesses: ['steam.exe', 'telegram.exe'],
                perAppTargets: {'telegram.exe': 'block'},
              ),
              windows: true,
              servers: const [('nl-4', 'NL-4')],
              onSave: (_) async {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _audit(tester, failures, 'per-app routing');

    final control = FakeTunnelControl();
    control.logLines.add({
      'seq': 1,
      'time': DateTime.utc(2026, 10, 30).millisecondsSinceEpoch,
      'level': 'warning',
      'text': 'core: Xray started',
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: LogsView(control: control)),
      ),
    );
    await tester.pumpAndSettle();
    await _audit(tester, failures, 'logs');
    await tester.pumpWidget(const SizedBox());
    semantics.dispose();
    expect(failures, isEmpty, reason: failures.join('\n'));
  });
}
