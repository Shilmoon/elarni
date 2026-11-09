import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:elarni/desktop_integration.dart';
import 'package:elarni/elarni_widgets.dart';
import 'package:elarni/per_app_routing.dart';
import 'package:elarni/tunnel_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'routing-only profile round trip validates version, platform and rules',
    () {
      for (final platform in ['macos', 'windows', 'linux', 'android']) {
        final processes = platform == 'android'
            ? ['com.example.browser', 'org.example.app_2']
            : platform == 'linux'
            ? ['/usr/bin/Example', '/opt/example/']
            : platform == 'macos'
            ? ['/Applications/Example.app/', '/usr/bin/curl']
            : [r'C:\Program Files\Example\Example.exe', 'curl.exe'];
        final profile = PerAppProfile(platform, 'bypass', processes);
        final json = profile.encode();
        final imported = PerAppProfile.decode(json, platform: platform);
        expect(imported.mode, 'bypass');
        expect(imported.processes, processes);
        expect((jsonDecode(json) as Map).keys.toSet(), {
          'format',
          'version',
          'platform',
          'mode',
          'processes',
        });
        expect(
          () => PerAppProfile.decode(
            json,
            platform: platform == 'macos' ? 'windows' : 'macos',
          ),
          throwsFormatException,
        );
        for (final patch in [
          {'version': 2},
          {'format': 'other'},
          {'platform': 'unsupported'},
          {'mode': 'block'},
          {'processes': []},
          {
            'processes': [false],
          },
          {
            'processes': ['bad\nname'],
          },
          {
            'processes': [' padded'],
          },
          {
            'processes': ['é' * 513],
          },
          {'processes': List.filled(257, 'curl')},
          {'unexpected': 'value'},
        ]) {
          expect(
            () => PerAppProfile.decode(
              jsonEncode({...jsonDecode(json) as Map, ...patch}),
              platform: platform,
            ),
            throwsFormatException,
          );
        }
      }
      expect(
        () => PerAppProfile.decode('x' * (512 * 1024 + 1), platform: 'macos'),
        throwsFormatException,
      );
    },
  );

  test(
    'a routing profile carries app targets but not servers, which stay on this device',
    () {
      final profile = PerAppProfile(
        'windows',
        'bypass',
        ['steam.exe', 'game.exe', 'telegram.exe'],
        {
          'game.exe': 'block',
          'telegram.exe': 'node:abc',
          'steam.exe': 'proxy:socks5://127.0.0.1:1080',
        },
      );
      final json = jsonDecode(profile.encode()) as Map;
      expect(json['version'], 2);
      expect(json['targets'], {
        'game.exe': 'block',
        'steam.exe': 'proxy:socks5://127.0.0.1:1080',
      });
      expect(
        PerAppProfile.decode(profile.encode(), platform: 'windows').targets,
        json['targets'],
      );
      // A profile without targets keeps the format older versions read.
      expect(
        (jsonDecode(PerAppProfile('windows', 'bypass', ['steam.exe']).encode())
            as Map)['version'],
        1,
      );
      for (final targets in [
        {'other.exe': 'block'},
        {'game.exe': 'node:abc'},
        {'game.exe': 'tor'},
        ['block'],
      ]) {
        expect(
          () => PerAppProfile.decode(
            jsonEncode({...json, 'targets': targets}),
            platform: 'windows',
          ),
          throwsFormatException,
          reason: '$targets',
        );
      }
    },
  );

  testWidgets('each app picks its own target and other apps keep the mode', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1400));
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
    TunnelSettings? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: PerAppRoutingEditor(
              settings: const TunnelSettings(
                xrayTunEnabled: true,
                perAppMode: 'bypass',
                perAppProcesses: [
                  'steam.exe',
                  'telegram.exe',
                  'game.exe',
                  'browser.exe',
                ],
                perAppTargets: {'telegram.exe': 'node:gone'},
              ),
              windows: true,
              servers: const [('nl-4', 'NL-4')],
              onSave: (value) async => saved = value,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    Finder row(String process) => find.byKey(Key('per-app-target:$process'));
    String shown(String process) =>
        (tester
                    .widget<ElarniSelect<String>>(row(process))
                    .items
                    .firstWhere(
                      (item) =>
                          item.value ==
                          tester
                              .widget<ElarniSelect<String>>(row(process))
                              .value,
                    )
                    .child
                as Text)
            .data!;
    Future<void> choose(String process, String label) async {
      await tester.tap(row(process));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(MenuItemButton, label).last);
      await tester.pumpAndSettle();
    }

    // Untouched apps follow the mode; a deleted server says so.
    expect(shown('steam.exe'), 'Direct');
    expect(shown('telegram.exe'), 'Missing server');
    expect(find.text('Other apps'), findsOneWidget);
    expect(find.text('Follow routing rules'), findsOneWidget);
    await choose('game.exe', 'Block');
    await choose('telegram.exe', 'Server · NL-4');
    await choose('browser.exe', 'Local proxy…');
    final address = find.widgetWithText(TextField, 'Proxy address');
    await tester.enterText(address, 'socks5://192.0.2.1:1080');
    await tester.tap(find.text('Use proxy'));
    await tester.pumpAndSettle();
    expect(find.textContaining('this device'), findsOneWidget);
    await tester.enterText(address, 'socks5://127.0.0.1:1080');
    await tester.tap(find.text('Use proxy'));
    await tester.pumpAndSettle();
    expect(shown('browser.exe'), 'Local proxy · 127.0.0.1:1080');
    // A removed app takes its target with it.
    await tester.tap(find.byTooltip('Remove game.exe'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('per-app-routing-mode')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Only selected').last);
    await tester.pumpAndSettle();
    expect(shown('steam.exe'), 'Follow routing rules');
    expect(
      find.descendant(
        of: find.byKey(const Key('per-app-other-apps')),
        matching: find.text('Direct'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();
    expect(saved!.perAppProcesses, [
      'steam.exe',
      'telegram.exe',
      'browser.exe',
    ]);
    expect(saved!.perAppTargets, {
      'telegram.exe': 'node:nl-4',
      'browser.exe': 'proxy:socks5://127.0.0.1:1080',
    });
  });

  test('profile OS validation rejects foreign paths even with a local tag', () {
    for (final (platform, paths) in [
      (
        'macos',
        [
          r'C:\Apps\Browser.exe',
          'c:/Apps/Browser.exe',
          r'\\server\Apps\Browser.exe',
        ],
      ),
      ('windows', ['/Applications/Browser.app/', '/usr/bin/curl']),
      (
        'linux',
        [
          r'C:\Apps\Browser.exe',
          r'\\server\Apps\Browser.exe',
          '/Applications/Browser.app/',
        ],
      ),
      (
        'android',
        [
          '/Applications/Browser.app/',
          '/usr/bin/curl',
          r'C:\Apps\Browser.exe',
          'Browser',
          'com.example/app',
          'com..example',
          'com.example.*',
        ],
      ),
    ]) {
      for (final path in paths) {
        final profile = PerAppProfile(platform, 'bypass', [path]);
        expect(profile.valid, isFalse);
        expect(profile.encode, throwsFormatException);
        expect(
          () => PerAppProfile.decode(
            jsonEncode({
              'format': 'elarni-per-app',
              'version': 1,
              'platform': platform,
              'mode': 'bypass',
              'processes': [path],
            }),
            platform: platform,
          ),
          throwsFormatException,
        );
      }
    }
    for (final platform in ['macos', 'windows', 'linux']) {
      expect(PerAppProfile(platform, 'off', []).valid, isTrue);
      expect(
        PerAppProfile(platform, 'bypass', [
          'curl',
          'browser.exe',
          'self/',
          'xray/',
        ]).valid,
        isTrue,
      );
    }
    expect(
      PerAppProfile('windows', 'bypass', [
        'C:/Apps/Browser.exe',
        r'\\server\Apps\Browser.exe',
        '//server/Apps/',
      ]).valid,
      isTrue,
    );
    expect(PerAppProfile('android', 'off', []).valid, isTrue);
    expect(PerAppProfile.platformLabel('android'), 'Android');
    final android = PerAppProfile('android', 'proxyOnly', ['com.example.app']);
    for (final desktop in ['macos', 'windows', 'linux']) {
      expect(
        () => PerAppProfile.decode(android.encode(), platform: desktop),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'platform-specific guidance',
            contains('Android profile'),
          ),
        ),
      );
    }
  });

  for (final platform in ['macos', 'windows', 'linux']) {
    final windows = platform == 'windows';
    final linux = platform == 'linux';
    testWidgets(
      'select, browse, share and preview import on ${PerAppProfile.platformLabel(platform)}',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1000, 1100));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final otherPlatform = windows ? 'macos' : 'windows';
        final otherPlatformName = windows ? 'macOS' : 'Windows';
        final browser = linux
            ? '/usr/bin/Browser'
            : windows
            ? r'C:\Apps\Browser.exe'
            : '/Applications/Browser.app/';
        final helper = linux
            ? '/opt/helper/bin/Helper'
            : windows
            ? r'C:\Apps\Helper.exe'
            : '/Applications/Helper.app/';
        messenger.setMockMethodCallHandler(DesktopIntegration.channel, (
          call,
        ) async {
          if (call.method == 'routingApplications')
            return [
              {'name': 'Browser', 'process': browser},
              {'name': 'Other', 'process': 'other'},
            ];
          if (call.method == 'pickRoutingApplications')
            return [
              {'name': 'Helper', 'process': helper},
            ];
          throw MissingPluginException();
        });
        addTearDown(
          () => messenger.setMockMethodCallHandler(
            DesktopIntegration.channel,
            null,
          ),
        );
        String? clipboard;
        messenger.setMockMethodCallHandler(SystemChannels.platform, (
          call,
        ) async {
          if (call.method == 'Clipboard.setData')
            clipboard = (call.arguments as Map)['text'] as String;
          if (call.method == 'Clipboard.getData') return {'text': clipboard};
          return null;
        });
        addTearDown(
          () =>
              messenger.setMockMethodCallHandler(SystemChannels.platform, null),
        );
        TunnelSettings? saved;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: PerAppRoutingEditor(
                  settings: const TunnelSettings(
                    perAppMode: 'bypass',
                    perAppProcesses: ['existing'],
                    xrayTunEnabled: true,
                  ),
                  windows: windows,
                  linux: linux,
                  onSave: (value) async => saved = value,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Selected apps'), findsOneWidget);
        expect(find.text('existing'), findsOneWidget);
        expect(find.byType(TextField), findsNothing);
        await tester.tap(find.text('Add apps'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextField, 'Search apps'),
          'browser',
        );
        await tester.pumpAndSettle();
        expect(find.text('Other'), findsNothing);
        await tester.tap(find.text('Browser'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Choose app file'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Profile & executable tools'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Copy routing profile'));
        await tester.pumpAndSettle();
        expect(PerAppProfile.decode(clipboard!, platform: platform).processes, [
          'existing',
          browser,
          helper,
        ]);
        Future<void> paste(String text) async {
          clipboard = text;
          await tester.ensureVisible(find.text('Paste routing profile'));
          await tester.tap(find.text('Paste routing profile'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Load profile'));
          await tester.pumpAndSettle();
        }

        await paste(PerAppProfile(platform, 'proxyOnly', [helper]).encode());
        expect(saved, isNull);
        expect(find.textContaining('Review the apps'), findsOneWidget);
        await paste(
          PerAppProfile(otherPlatform, 'bypass', ['foreign-app']).encode(),
        );
        expect(
          find.textContaining('This is a $otherPlatformName profile.'),
          findsOneWidget,
        );
        expect(saved, isNull);
        await tester.tap(find.text('Back to apps'));
        await tester.pumpAndSettle();
        await paste('{"version":999}');
        expect(saved, isNull);
        await tester.tap(find.text('Back to apps'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Edit executable rules'));
        await tester.pumpAndSettle();
        final input = find.widgetWithText(
          TextField,
          'Executable names or full paths',
        );
        expect(tester.widget<TextField>(input).controller!.text, helper);
        final foreignPath = windows
            ? '/Applications/Other.app/'
            : r'C:\Apps\Other.exe';
        await tester.enterText(input, foreignPath);
        await tester.tap(find.text('Update draft'));
        await tester.pumpAndSettle();
        expect(saved, isNull);
        expect(find.byKey(const Key('per-app-notice')), findsOneWidget);
        expect(tester.widget<TextField>(input).controller!.text, foreignPath);
        await tester.enterText(input, helper);
        await tester.tap(find.text('Update draft'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Done'));
        await tester.pumpAndSettle();
        expect(find.text('Helper'), findsOneWidget);
        await tester.tap(find.text('Save changes'));
        await tester.pumpAndSettle();
        expect(saved!.perAppMode, 'proxyOnly');
        expect(saved!.perAppProcesses, [helper]);
        expect(saved!.xrayTunEnabled, isTrue);
      },
    );
  }

  testWidgets(
    'discovery and invalid icons preserve rules; cancel discards draft',
    (tester) async {
      final messenger = tester.binding.defaultBinaryMessenger;
      bool unavailable = false;
      messenger.setMockMethodCallHandler(DesktopIntegration.channel, (_) async {
        if (unavailable) throw PlatformException(code: 'unavailable');
        return [
          {
            'name': 'Browser',
            'process': '/Applications/Browser.app/',
            'iconPng': Uint8List.fromList([1, 2, 3]),
          },
        ];
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          DesktopIntegration.channel,
          null,
        ),
      );
      TunnelSettings? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: PerAppRoutingEditor(
                settings: const TunnelSettings(
                  perAppMode: 'bypass',
                  perAppProcesses: ['missing'],
                ),
                windows: false,
                onSave: (value) async => saved = value,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add apps'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Browser'));
      unavailable = true;
      await tester.tap(find.byTooltip('Refresh app list'));
      await tester.pumpAndSettle();
      expect(find.textContaining('app list is unavailable'), findsOneWidget);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.text('Browser'), findsOneWidget);
      expect(find.text('missing'), findsOneWidget);
      // The Other apps row and the target note push the footer below the fold.
      await tester.ensureVisible(find.text('Cancel'));
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Browser'), findsNothing);
      expect(find.text('missing'), findsOneWidget);
      expect(saved, isNull);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Windows chooser matches saved paths without case duplicates', (
    tester,
  ) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      DesktopIntegration.channel,
      (_) async => [
        {'name': 'Browser', 'process': r'C:\Apps\Browser.exe'},
      ],
    );
    addTearDown(
      () =>
          messenger.setMockMethodCallHandler(DesktopIntegration.channel, null),
    );
    TunnelSettings? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: PerAppRoutingEditor(
              settings: const TunnelSettings(
                perAppMode: 'bypass',
                perAppProcesses: [r'c:\apps\browser.exe'],
              ),
              windows: true,
              onSave: (value) async => saved = value,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add apps'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<CheckboxListTile>(
            find.widgetWithText(CheckboxListTile, 'Browser'),
          )
          .value,
      isTrue,
    );
    await tester.tap(find.text('Browser'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Browser'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();
    expect(saved!.perAppProcesses, [r'C:\Apps\Browser.exe']);
  });

  // WSL, virtual machines and closed connections have no app. "Only listed" keeps such
  // traffic in the tunnel; listing it with a target sends it elsewhere.
  testWidgets('unidentified traffic leads the app list and takes a target', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      DesktopIntegration.channel,
      (call) async => call.method == 'routingApplications'
          ? [
              {'name': 'Aardvark', 'process': '/usr/bin/aardvark'},
              // A host lists a saved "-1" as a rule of its own.
              {'name': '-1', 'process': '-1'},
            ]
          : null,
    );
    addTearDown(
      () =>
          messenger.setMockMethodCallHandler(DesktopIntegration.channel, null),
    );
    TunnelSettings? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: PerAppRoutingEditor(
              settings: const TunnelSettings(
                xrayTunEnabled: true,
                perAppMode: 'proxyOnly',
                perAppProcesses: ['/usr/bin/curl'],
              ),
              windows: false,
              linux: true,
              onSave: (value) async => saved = value,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add apps'));
    await tester.pumpAndSettle();
    final tiles = tester
        .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
        .toList();
    expect(
      tiles
          .map(
            (tile) => find
                .descendant(
                  of: find.byWidget(tile),
                  matching: find.textContaining(
                    RegExp('Unidentified|Aardvark'),
                  ),
                )
                .evaluate()
                .map((element) => (element.widget as Text).data)
                .first,
          )
          .take(2),
      ['Unidentified traffic', 'Aardvark'],
    );
    expect(find.text('-1'), findsNothing);
    await tester.tap(find.text('Unidentified traffic'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('Unidentified traffic'), findsOneWidget);
    await tester.tap(find.byKey(const Key('per-app-target:-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, 'Direct').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();
    expect(saved!.perAppProcesses, ['/usr/bin/curl', '-1']);
    expect(saved!.perAppTargets, {'-1': 'direct'});
  });

  // A rule that matches nothing used to look like any other. Each rule shows how many
  // running programs it matches and why it may match none, with a fix where one exists.
  testWidgets('rules show running programs, warnings and suggested fixes', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const versions = '/home/u/.local/share/claude/versions/';
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      DesktopIntegration.channel,
      (call) async => call.method == 'routingApplications'
          ? [
              {
                'name': '2.1.300',
                'process': '${versions}2.1.300',
                'suggested': versions,
              },
            ]
          : null,
    );
    addTearDown(
      () =>
          messenger.setMockMethodCallHandler(DesktopIntegration.channel, null),
    );
    final asked = <List<String>>[];
    TunnelSettings? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: PerAppRoutingEditor(
              settings: const TunnelSettings(
                xrayTunEnabled: true,
                perAppMode: 'bypass',
                perAppProcesses: [
                  '/usr/bin/curl',
                  '/opt/tools',
                  '${versions}2.1.300',
                  '-1',
                ],
                perAppTargets: {'/opt/tools': 'block'},
              ),
              windows: false,
              linux: true,
              checkRules: (rules) async {
                asked.add(rules);
                return ProcessRuleChecks({
                  '/usr/bin/curl': const ProcessRuleCheck(
                    '/usr/bin/curl',
                    2,
                    [],
                  ),
                  '/opt/tools': const ProcessRuleCheck('/opt/tools', 0, [
                    ('folder', '/opt/tools/'),
                  ]),
                  '/opt/tools/': const ProcessRuleCheck('/opt/tools/', 3, []),
                });
              },
              onSave: (value) async => saved = value,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // "-1" is no program to look for.
    expect(asked.first, ['/usr/bin/curl', '/opt/tools', '${versions}2.1.300']);
    expect(find.textContaining('2 programs running'), findsOneWidget);
    expect(find.textContaining('Not running now'), findsOneWidget);
    expect(
      find.byKey(const Key('per-app-warning:/opt/tools:folder')),
      findsOneWidget,
    );
    expect(
      find.byKey(Key('per-app-warning:${versions}2.1.300:versioned')),
      findsOneWidget,
    );
    expect(find.text('Suggested rule: /opt/tools/'), findsOneWidget);
    await tester.tap(find.byKey(const Key('per-app-use:/opt/tools:folder')));
    await tester.pumpAndSettle();
    // The fixed rule keeps its place and target, and is checked again.
    expect(asked.last, ['/usr/bin/curl', '/opt/tools/', '${versions}2.1.300']);
    expect(find.textContaining('3 programs running'), findsOneWidget);
    await tester.tap(
      find.byKey(Key('per-app-use:${versions}2.1.300:versioned')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();
    expect(saved!.perAppProcesses, [
      '/usr/bin/curl',
      '/opt/tools/',
      versions,
      '-1',
    ]);
    expect(saved!.perAppTargets, {'/opt/tools/': 'block'});
  });

  testWidgets('recent connections name the app and add its program', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const versions = '/home/u/.local/share/claude/versions/';
    final messenger = tester.binding.defaultBinaryMessenger;
    final hosted = <Object?>[];
    messenger.setMockMethodCallHandler(DesktopIntegration.channel, (
      call,
    ) async {
      if (call.method != 'routingApplications') return null;
      hosted.add((call.arguments as Map)['processes']);
      return [
        {
          'name': '2.1.300',
          'process': '${versions}2.1.300',
          'suggested': versions,
        },
      ];
    });
    addTearDown(
      () =>
          messenger.setMockMethodCallHandler(DesktopIntegration.channel, null),
    );
    Map<String, Object?> entry(
      int key,
      int seq, {
      String owner = 'found',
      String path = '',
      String kind = 'proxy',
      List<String> rules = const [],
      String host = '192.0.2.10',
    }) => {
      'key': key,
      'seq': seq,
      'time': DateTime(2026, 11, 9, 12, 0, key).millisecondsSinceEpoch,
      'network': 'tcp',
      'host': host,
      'port': 443,
      'inbound': 'elarni-tun',
      'outbound': 'elarni-proxy',
      'kind': kind,
      'rules': rules,
      'owner': owner,
      'path': path,
    };
    var list = [
      entry(
        1,
        1,
        path: '${versions}2.1.300',
        rules: ['elarni-per-app-other'],
        host: 'api.example.com',
      ),
      entry(
        2,
        2,
        path: '/usr/bin/curl',
        kind: 'direct',
        rules: ['elarni-per-app-listed'],
      ),
      entry(3, 3, owner: 'unknown', rules: ['elarni-per-app-listed']),
      entry(4, 4, owner: ''),
    ];
    final reads = <(int, int)>[];
    TunnelSettings? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: PerAppRoutingEditor(
              settings: const TunnelSettings(
                xrayTunEnabled: true,
                perAppMode: 'bypass',
                perAppProcesses: ['/usr/bin/curl'],
              ),
              windows: false,
              linux: true,
              readConnections: ({int epoch = 0, int after = 0}) async {
                reads.add((epoch, after));
                final since = epoch == 7 ? after : 0;
                return RecentConnections.fromMap({
                  'epoch': 7,
                  'seq': list.last['seq'],
                  'connections': [
                    for (final item in list)
                      if ((item['seq']! as int) > since) item,
                  ],
                });
              },
              onSave: (value) async => saved = value,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('per-app-connections')));
    await tester.pumpAndSettle();
    expect(reads.first, (0, 0));
    // Newest first; each names its app, address and where it went.
    final rows = [4, 3, 2, 1]
        .map(
          (key) =>
              tester.getTopLeft(find.byKey(Key('per-app-connection-$key'))).dy,
        )
        .toList();
    expect(rows, [...rows]..sort());
    expect(find.text('claude'), findsOneWidget);
    expect(find.text('Unidentified traffic'), findsOneWidget);
    expect(find.text('App not looked up'), findsOneWidget);
    expect(find.text('api.example.com:443 · TCP'), findsOneWidget);
    expect(find.text('Direct · Per-app rule'), findsOneWidget);
    expect(find.text('Through a server · Not listed'), findsOneWidget);
    // Only a found program outside the list can be added.
    expect(find.byKey(const Key('per-app-add-connection-1')), findsOneWidget);
    for (final key in [2, 3, 4]) {
      expect(find.byKey(Key('per-app-add-connection-$key')), findsNothing);
    }
    // A later decision updates its entry in place.
    list = [...list.take(3), entry(4, 5, owner: '', kind: 'block')];
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(reads.last, (7, 4));
    expect(find.text('Blocked'), findsOneWidget);
    expect(find.byKey(const Key('per-app-connection-4')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('per-app-connections-search')),
      'example.com',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('per-app-connection-2')), findsNothing);
    await tester.tap(find.byKey(const Key('per-app-add-connection-1')));
    await tester.pumpAndSettle();
    // The host gives a version's program the folder of versions.
    expect(hosted.last, ['/usr/bin/curl', '${versions}2.1.300']);
    expect(find.text('claude added. Save changes to apply.'), findsOneWidget);
    expect(find.byKey(const Key('per-app-add-connection-1')), findsNothing);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();
    expect(saved!.perAppProcesses, ['/usr/bin/curl', versions]);
  });

  testWidgets('recent connections ask for a tunnel when none answers', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1400));
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
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: PerAppRoutingEditor(
              settings: const TunnelSettings(xrayTunEnabled: true),
              windows: false,
              readConnections: ({int epoch = 0, int after = 0}) async =>
                  throw PlatformException(code: 'not_running'),
              onSave: (_) async {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('per-app-connections')));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Connect to see which apps open connections and where they go.',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('per-app-connections-off')), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
  });

  // A Snap or script launcher's rule would name /usr/bin/snap or /bin/sh.
  testWidgets('a launcher chosen on Linux explains why it is refused', (
    tester,
  ) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(DesktopIntegration.channel, (
      call,
    ) async {
      if (call.method == 'routingApplications') return [];
      if (call.method == 'pickRoutingApplications')
        throw PlatformException(code: 'launcher_application');
      throw MissingPluginException();
    });
    addTearDown(
      () =>
          messenger.setMockMethodCallHandler(DesktopIntegration.channel, null),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: PerAppRoutingEditor(
              settings: const TunnelSettings(
                perAppMode: 'bypass',
                xrayTunEnabled: true,
              ),
              windows: false,
              linux: true,
              onSave: (_) async {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add apps'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose app file'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Snap, Flatpak and script launchers'),
      findsOneWidget,
    );
  });
}
