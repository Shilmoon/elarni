import 'package:elarni/elarni_app.dart';
import 'package:elarni/tunnel_channel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_tunnel_control.dart';

// A file of its own: the app keeps the resolved language in a global, which
// would carry into other tests of the same isolate.
void main() {
  testWidgets('a Russian system shows the interface in Russian', (
    tester,
  ) async {
    tester.platformDispatcher.localesTestValue = const [Locale('ru', 'RU')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ElarniApp(
        tunnelControl: FakeTunnelControl()
          ..snapshot = const SubscriptionSnapshot(subscriptions: []),
        windows: true,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Подключитесь в три шага'), findsOneWidget);
    expect(find.text('Вставить ссылку'), findsOneWidget);
    for (final page in ['Главная', 'Подписки', 'Маршрутизация', 'Настройки'])
      expect(find.text(page), findsWidgets, reason: page);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      ElarniApp(
        tunnelControl: FakeTunnelControl()
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
                    name: '🇳🇱 Amsterdam',
                    protocol: 'VLESS',
                    transport: 'tcp',
                    security: 'tls',
                    selected: true,
                  ),
                  SubscriptionNode(
                    id: 'b',
                    name: 'Germany 2',
                    protocol: 'VLESS',
                    transport: 'tcp',
                    security: 'tls',
                    selected: false,
                  ),
                ],
              ),
            ],
          ),
        windows: true,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Подключить'), findsOneWidget);
    expect(find.text('2 сервера'), findsOneWidget);
    expect(find.text('1 сервер'), findsNWidgets(2));
    expect(find.text('Нидерланды'), findsOneWidget);
    expect(find.text('Германия'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
