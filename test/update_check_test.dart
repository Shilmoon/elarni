import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:elarni/desktop_integration.dart';
import 'package:elarni/desktop_proxy.dart';
import 'package:elarni/elarni_app.dart';
import 'package:elarni/elarni_widgets.dart';
import 'package:elarni/update_check.dart';
import 'elarni_app_test.dart' show selectCategory, reveal;
import 'support/fake_tunnel_control.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = DesktopIntegration.channel;

  test(
    'a feed names a release in Elarni\'s own form or as a GitHub release',
    () {
      expect(
        parseUpdateFeed(
          '{"version":"0.4.0","url":"https://mirror.example/elarni/"}',
        ),
        (version: '0.4.0', url: 'https://mirror.example/elarni/'),
      );
      expect(
        parseUpdateFeed(
          jsonEncode({
            // GitHub's own url is the API address, not the release page.
            'url': 'https://api.github.com/repos/o/elarni/releases/1',
            'tag_name': 'v0.4.1',
            'html_url': 'https://github.com/o/elarni/releases/tag/v0.4.1',
            'assets': [],
          }),
        ),
        (
          version: '0.4.1',
          url: 'https://github.com/o/elarni/releases/tag/v0.4.1',
        ),
      );
      for (final body in [
        'not json',
        '[]',
        '{"version":"0.4.0"}',
        '{"version":"0.4.0","url":"http://mirror.example/"}',
        '{"version":"0.4.0","url":"javascript:alert(1)"}',
        '{"version":"next","url":"https://mirror.example/"}',
        '{"version":4,"url":"https://mirror.example/"}',
      ])
        expect(parseUpdateFeed(body), isNull, reason: body);
    },
  );

  test('versions compare by number and ignore the build', () {
    expect(compareVersions('0.3.10', '0.3.9'), greaterThan(0));
    expect(compareVersions('v0.4.0', '0.3.6+9'), greaterThan(0));
    expect(compareVersions('0.3.6', '0.3.6+9'), 0);
    expect(compareVersions('0.3', '0.3.0'), 0);
    expect(compareVersions('0.3.5', '0.3.6'), lessThan(0));
    expect(compareVersions('0.4.0-beta', '0.3.6'), isNull);
    expect(compareVersions('', '0.3.6'), isNull);
  });

  test('a feed is read over https only', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var requests = 0;
    server.listen((request) {
      requests++;
      request.response
        ..write('{"version":"9.0.0","url":"https://mirror.example/"}')
        ..close();
    });
    await expectLater(
      fetchUpdateFeed(Uri.parse('http://127.0.0.1:${server.port}/feed')),
      throwsA(isA<FormatException>()),
    );
    expect(requests, 0);
  });

  test('Windows and Linux open only an https release page', () async {
    final opened = <Object?>[];
    final proxy = DesktopProxy(
      corePath: 'unused-core',
      domainPath: 'unused-domain',
      catalogIO: (_, _) async => throw PlatformException(code: 'storage_busy'),
      platformIO: (method, payload) async {
        opened.add([method, payload['url']]);
        return {};
      },
    );
    addTearDown(proxy.dispose);
    await expectLater(
      proxy.control.openUpdateLink('http://mirror.example/elarni/'),
      throwsA(isA<PlatformException>()),
    );
    // The page needs no catalog, so a locked one does not stop it.
    await proxy.control.openUpdateLink('https://mirror.example/elarni/');
    expect(opened, [
      ['openURL', 'https://mirror.example/elarni/'],
    ]);
  });

  group('the update notice', () {
    late List<String> stored;
    late List<Uri> fetched;
    late String feed;
    late FakeTunnelControl control;

    setUp(() {
      stored = ['{}'];
      fetched = [];
      feed = '{"version":"0.4.0","url":"https://mirror.example/elarni/"}';
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getPreferences') return stored.last;
        if (call.method == 'setPreferences')
          stored.add((call.arguments as Map)['json'] as String);
        return null;
      });
      updateFeedFetch = (url) async {
        fetched.add(url);
        return feed;
      };
      control = FakeTunnelControl()
        ..systemInfoValue = {'appVersion': '0.3.6+9'};
    });
    tearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      updateFeedFetch = fetchUpdateFeed;
    });

    testWidgets('stays off and silent until a feed is set', (tester) async {
      await tester.pumpWidget(ElarniApp(tunnelControl: control, windows: true));
      await tester.pumpAndSettle();
      expect(fetched, isEmpty);
      expect(find.textContaining('is available'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('opens the release page, and Not now hides that version', (
      tester,
    ) async {
      stored = [
        jsonEncode({'updateFeedURL': 'https://mirror.example/feed.json'}),
      ];
      await tester.pumpWidget(ElarniApp(tunnelControl: control, windows: true));
      await tester.pumpAndSettle();
      expect(fetched, [Uri.parse('https://mirror.example/feed.json')]);
      const notice = 'Elarni 0.4.0 is available';
      expect(find.text(notice), findsOneWidget);
      expect(find.textContaining('You have 0.3.6+9'), findsOneWidget);
      await tester.tap(find.text('Download'));
      await tester.pumpAndSettle();
      expect(control.openedUpdateLinks, ['https://mirror.example/elarni/']);
      expect(find.text(notice), findsOneWidget);
      // The open local proxy's warning has its own Not now.
      final banner = find
          .ancestor(of: find.text(notice), matching: find.byType(DecoratedBox))
          .first;
      await tester.tap(
        find.descendant(of: banner, matching: find.text('Not now')),
      );
      await tester.pumpAndSettle();
      expect(find.text(notice), findsNothing);
      expect(
        find.text('Your local proxy accepts apps without a login'),
        findsOneWidget,
      );
      expect(jsonDecode(stored.last)['dismissedUpdate'], '0.4.0');
      // A restart keeps that version hidden; a newer one shows again.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(ElarniApp(tunnelControl: control, windows: true));
      await tester.pumpAndSettle();
      expect(find.text(notice), findsNothing);
      feed = '{"version":"0.4.1","url":"https://mirror.example/elarni/"}';
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(ElarniApp(tunnelControl: control, windows: true));
      await tester.pumpAndSettle();
      expect(find.text('Elarni 0.4.1 is available'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('shows nothing for the running version or an unreadable feed', (
      tester,
    ) async {
      stored = [
        jsonEncode({'updateFeedURL': 'https://mirror.example/feed.json'}),
      ];
      feed = '{"version":"0.3.6","url":"https://mirror.example/elarni/"}';
      await tester.pumpWidget(ElarniApp(tunnelControl: control, windows: true));
      await tester.pumpAndSettle();
      expect(fetched, hasLength(1));
      expect(find.textContaining('is available'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      updateFeedFetch = (url) async => throw const SocketException('blocked');
      await tester.pumpWidget(ElarniApp(tunnelControl: control, windows: true));
      await tester.pumpAndSettle();
      expect(find.textContaining('is available'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the feed is set in Settings, https only, and checked at once', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1200, 2800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(ElarniApp(tunnelControl: control, windows: true));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('nav-settings')));
      await tester.pumpAndSettle();
      await selectCategory(tester, SettingsCategory.general);
      await reveal(tester, find.text('Update feed'));
      expect(find.text('Off'), findsOneWidget);
      await tester.tap(find.widgetWithText(OutlinedButton, 'Change'));
      await tester.pumpAndSettle();
      final field = find.byKey(const Key('update-feed-url'));
      await tester.enterText(field, 'http://mirror.example/feed.json');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Enter an https:// address, or leave it empty to turn the check off.',
        ),
        findsOneWidget,
      );
      expect(stored, ['{}']);
      await tester.enterText(field, ' https://mirror.example/feed.json ');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(
        jsonDecode(stored.last)['updateFeedURL'],
        'https://mirror.example/feed.json',
      );
      expect(fetched, [Uri.parse('https://mirror.example/feed.json')]);
      expect(find.text('https://mirror.example/feed.json'), findsOneWidget);
      expect(find.text('Elarni 0.4.0 is available'), findsOneWidget);
      // Clearing the address turns the check and its notice off.
      await tester.tap(find.widgetWithText(OutlinedButton, 'Change'));
      await tester.pumpAndSettle();
      await tester.enterText(field, '');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(jsonDecode(stored.last)['updateFeedURL'], '');
      expect(find.text('Elarni 0.4.0 is available'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
