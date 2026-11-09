import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:elarni/logs_view.dart';
import 'package:elarni/tunnel_channel.dart';
import 'support/fake_tunnel_control.dart';

void main() {
  testWidgets('the log follows new lines, sets its level and shares the text', (
    tester,
  ) async {
    final control = FakeTunnelControl();
    final time = DateTime.utc(2026, 10, 29, 21, 5, 7).millisecondsSinceEpoch;
    control.logLines.addAll([
      {
        'seq': 1,
        'time': time,
        'level': 'warning',
        'text': 'core: Xray started',
      },
      {
        'seq': 2,
        'time': time,
        'level': 'error',
        'text': 'dial [ip]:443 failed',
      },
    ]);
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData')
          copied = (call.arguments as Map)['text'] as String;
        return null;
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: LogsView(control: control)),
      ),
    );
    await tester.pump();
    expect(find.textContaining('core: Xray started'), findsOneWidget);
    expect(find.textContaining('ERROR'), findsOneWidget);
    expect(control.logReads.first, 0);

    control.logLines.add({
      'seq': 3,
      'time': time,
      'level': 'warning',
      'text': 'proxy/vless: tunneling to tcp:[host]:443',
    });
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(control.logReads.last, 2);
    expect(find.textContaining('tunneling to tcp:[host]:443'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('logLevel')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Debug').last);
    await tester.pumpAndSettle();
    expect(control.settings.logLevel, 'debug');
    expect(
      tester
          .widget<DropdownButton<String>>(
            find.byKey(const ValueKey('logLevel')),
          )
          .onChanged,
      isNotNull,
      reason: 'the level can be changed again on every platform',
    );

    await tester.tap(find.text('Copy'));
    await tester.pump();
    expect(copied, contains('WARNING core: Xray started'));
    expect(copied, contains('ERROR dial [ip]:443 failed'));
    expect(copied, contains('Elarni log'));
    expect(find.text('Copied'), findsOneWidget);

    await tester.tap(find.text('Save…'));
    await tester.pump();
    expect(control.savedLogs.single, copied);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('an empty or switched-off log says why it shows nothing', (
    tester,
  ) async {
    final control = FakeTunnelControl()
      ..settings = const TunnelSettings().copyWith(logLevel: 'none');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: LogsView(control: control)),
      ),
    );
    await tester.pump();
    expect(find.textContaining('Logging is off'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('an idle log does not rebuild the dialog each second', (
    tester,
  ) async {
    final control = FakeTunnelControl()
      ..logLines.add({
        'seq': 1,
        'time': 0,
        'level': 'warning',
        'text': 'core: Xray started',
      });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: LogsView(control: control)),
      ),
    );
    await tester.pump();
    var rebuilds = 0;
    debugOnRebuildDirtyWidget = (element, _) {
      if (element.widget is LogsView) rebuilds++;
    };
    try {
      await tester.pump(const Duration(seconds: 3));
      expect(control.logReads.length, greaterThan(2));
      expect(rebuilds, 0);
    } finally {
      debugOnRebuildDirtyWidget = null;
    }
    await tester.pumpWidget(const SizedBox());
  });

  test('settings keep a known log level, warning by default', () {
    expect(const TunnelSettings().logLevel, 'warning');
    expect(TunnelSettings.fromMap({}).logLevel, 'warning');
    final debug = const TunnelSettings().copyWith(logLevel: 'debug');
    expect(TunnelSettings.fromMap(debug.toMap()).logLevel, 'debug');
  });
}
