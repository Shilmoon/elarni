import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:elarni/elarni_app.dart';
import 'package:elarni/tunnel_channel.dart';
import 'support/fake_tunnel_control.dart';

Future<FakeTunnelControl> pumpEmpty(
  WidgetTester tester, {
  bool windows = true,
  bool vpn = false,
}) async {
  await tester.binding.setSurfaceSize(const Size(1200, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final control = FakeTunnelControl()
    ..snapshot = const SubscriptionSnapshot(subscriptions: [])
    ..settings = TunnelSettings(xrayTunEnabled: vpn);
  await tester.pumpWidget(ElarniApp(tunnelControl: control, windows: windows));
  await tester.pumpAndSettle();
  return control;
}

void main() {
  // Elarni ships no servers, so an empty Home says where one comes from.
  testWidgets('an empty Home walks through adding a first server', (
    tester,
  ) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => call.method == 'Clipboard.getData'
          ? {'text': 'https://fixture.example/feed'}
          : null,
    );
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    final control = await pumpEmpty(tester);
    expect(find.text('Get connected in three steps'), findsOneWidget);
    expect(
      find.textContaining('Elarni has no servers of its own'),
      findsOneWidget,
    );
    // The desktop default is the local proxy, which connects only set-up apps.
    expect(find.textContaining('turn on System-wide VPN'), findsOneWidget);
    for (final source in ['camera', 'file']) {
      await tester.tap(find.byKey(Key('onboarding-$source')));
      await tester.pumpAndSettle();
    }
    expect(find.text('Get connected in three steps'), findsOneWidget);
    control.onImport = (_, _) async {
      control.snapshot = fixtureSubscriptions;
      return const SubscriptionOperationResult(snapshot: fixtureSubscriptions);
    };
    await tester.tap(find.byKey(const Key('onboarding-clipboard')));
    await tester.pumpAndSettle();
    expect(control.importedSources, ['camera', 'file', 'text']);
    expect(control.importedProfiles.last, 'https://fixture.example/feed');
    expect(find.text('Get connected in three steps'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  for (final (name, windows, vpn, step) in [
    (
      'Windows VPN',
      true,
      true,
      'Administrator approval is requested on the first VPN connection',
    ),
    ('macOS', false, false, 'macOS asks once to allow the VPN configuration'),
  ])
    testWidgets('the last step says what Connect asks for on $name', (
      tester,
    ) async {
      await pumpEmpty(tester, windows: windows, vpn: vpn);
      expect(find.textContaining(step), findsOneWidget);
      expect(find.textContaining('System-wide VPN'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
}
