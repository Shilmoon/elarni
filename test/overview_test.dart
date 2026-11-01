import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:elarni/elarni_app.dart';
import 'package:elarni/elarni_widgets.dart';
import 'package:elarni/tunnel_channel.dart';
import 'support/fake_tunnel_control.dart';

void main() {
  // Provider metadata is optional. These cases guard against manufacturing a
  // quota, duration, or successful refresh from incomplete account information.
  test(
    'provider usage distinguishes absent, unlimited, exhausted and expiry',
    () {
      final now = DateTime.utc(2026, 9, 12);
      final absent = SubscriptionUsage({}, now);
      expect(absent.time, 'Not provided');
      expect(absent.data, 'Not provided');
      expect(absent.dataFraction, isNull);
      final unlimited = SubscriptionUsage({'total': 0, 'expire': 0}, now);
      expect(unlimited.time, 'No expiry');
      expect(unlimited.data, 'Unlimited');
      expect(unlimited.dataFraction, isNull);
      expect(unlimited.unlimitedData, isTrue);
      expect(unlimited.noExpiry, isTrue);
      expect(absent.unlimitedData, isFalse);
      expect(absent.noExpiry, isFalse);
      final incomplete = SubscriptionUsage({'total': 100, 'download': 10}, now);
      expect(incomplete.data, 'Not provided');
      expect(incomplete.dataFraction, isNull);
      final exhausted = SubscriptionUsage({
        'total': 100,
        'upload': 20,
        'download': 120,
        'expire': 1,
      }, now);
      expect(exhausted.data, 'Data exhausted');
      expect(exhausted.dataFraction, 0);
      expect(exhausted.time, 'Expired');
      final finite = SubscriptionUsage({
        'total': 100 * 1073741824,
        'upload': 8 * 1073741824,
        'download': 20 * 1073741824,
        'expire':
            now.add(const Duration(days: 23)).millisecondsSinceEpoch ~/ 1000,
      }, now);
      expect(finite.data, '72 GiB left');
      expect(finite.dataFraction, .72);
      expect(finite.time, '23 days left');
      final soon = SubscriptionUsage({
        'expire':
            now.add(const Duration(hours: 2)).millisecondsSinceEpoch ~/ 1000,
      }, now);
      expect(soon.time, 'Less than a day left');
      final malformed = SubscriptionUsage({
        'total': double.infinity,
        'upload': -1,
        'expire': 'tomorrow',
      }, now);
      expect(malformed.data, 'Not provided');
      expect(malformed.time, 'Not provided');
    },
  );

  for (final platform in ['macos', 'windows', 'linux']) {
    final windows = platform == 'windows';
    final linux = platform == 'linux';
    // Fixed-size screenshots missed the icon disappearing at the compact
    // breakpoint. Resize the real app with isolated tunnel data to cover it.
    testWidgets('home keeps its icon visible after resizing on $platform', (
      tester,
    ) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      await tester.pumpWidget(
        ElarniApp(
          tunnelControl: FakeTunnelControl(),
          windows: windows,
          linux: linux,
        ),
      );
      await tester.pumpAndSettle();

      for (final size in const [
        Size(700, 400),
        Size(420, 500),
        Size(900, 400),
        Size(1280, 400),
        Size(1280, 800),
      ]) {
        await tester.binding.setSurfaceSize(size);
        await tester.pumpAndSettle();
        final icon = find.byKey(const Key('connection-icon'));
        expect(icon, findsOneWidget, reason: '$size');
        final bounds = tester.getRect(icon);
        expect(bounds.top, greaterThanOrEqualTo(0));
        expect(bounds.bottom, lessThanOrEqualTo(size.height));
        expect(
          tester.getTopLeft(find.text('Elarni')).dx,
          lessThanOrEqualTo(20),
        );
        expect(
          find.byKey(const Key('import-toggle')).hitTestable(),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets(
      'account limits show full unlimited bars and measured finite progress on $platform',
      (tester) async {
        final semantics = tester.ensureSemantics();
        try {
          for (final brightness in Brightness.values) {
            for (final metadata in <Map<String, Object?>>[
              {'total': 0, 'expire': 0},
              {'total': 100, 'upload': 10, 'download': 20, 'expire': 0},
              {'total': 0, 'expire': 1},
              {'total': 100, 'upload': 100, 'download': 20, 'expire': 1},
              {},
            ]) {
              await tester.pumpWidget(
                MaterialApp(
                  theme: elarniTheme(
                    brightness: brightness,
                    accent: const Color(0xff006ef0),
                    windows: windows,
                    linux: linux,
                  ),
                  home: Scaffold(
                    body: Center(
                      child: MediaQuery(
                        data: const MediaQueryData(
                          textScaler: TextScaler.linear(1.6),
                        ),
                        child: SizedBox(
                          width: 240,
                          child: SubscriptionSummary(
                            group: SubscriptionGroup(
                              id: 'account',
                              name: 'Daily subscription',
                              status: 'ready',
                              nodes: const [],
                              metadata: metadata,
                            ),
                            onOpen: () {},
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
              await tester.pumpAndSettle();
              final finiteData = metadata['total'] == 100;
              final unlimitedData = metadata['total'] == 0;
              final noExpiry = metadata['expire'] == 0;
              expect(
                find.byType(LinearProgressIndicator),
                findsNWidgets(
                  (finiteData || unlimitedData ? 1 : 0) + (noExpiry ? 1 : 0),
                ),
              );
              expect(find.text('Unlimited'), findsNothing);
              expect(find.text('No expiry'), findsNothing);
              if (metadata['total'] == 0) {
                expect(
                  find.bySemanticsLabel('Data: Unlimited'),
                  findsOneWidget,
                );
                expect(
                  tester
                      .widget<LinearProgressIndicator>(
                        find.byKey(const Key('subscription-data-progress')),
                      )
                      .value,
                  1,
                );
              }
              if (metadata['expire'] == 0) {
                expect(
                  find.bySemanticsLabel('Time: No expiry'),
                  findsOneWidget,
                );
                expect(
                  tester
                      .widget<LinearProgressIndicator>(
                        find.byKey(const Key('subscription-time-progress')),
                      )
                      .value,
                  1,
                );
              } else if (metadata['expire'] == 1) {
                final expired = find.text('Expired');
                expect(expired, findsOneWidget);
                expect(
                  tester.widget<Text>(expired).style!.color,
                  Theme.of(tester.element(expired)).colorScheme.error,
                );
              }
              if (metadata.isEmpty) {
                expect(find.text('Not provided'), findsNWidgets(2));
              }
              if (finiteData) {
                expect(
                  tester
                      .widget<LinearProgressIndicator>(
                        find.byKey(const Key('subscription-data-progress')),
                      )
                      .value,
                  metadata['upload'] == 100 ? 0 : .7,
                );
              }
              expect(tester.takeException(), isNull);
            }
          }
        } finally {
          semantics.dispose();
        }
      },
    );

    // State transitions need intermediate-frame coverage; settled screenshots
    // alone cannot distinguish an animation from an immediate color change.
    for (final reduceMotion in [false, true]) {
      testWidgets(
        'connection icon follows state${reduceMotion ? ' with reduced motion' : ' with animation'} on $platform',
        (tester) async {
          await tester.binding.setSurfaceSize(const Size(1280, 800));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          tester.platformDispatcher.accessibilityFeaturesTestValue =
              FakeAccessibilityFeatures(disableAnimations: reduceMotion);
          addTearDown(
            tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
          );
          final control = FakeTunnelControl();
          await tester.pumpWidget(
            ElarniApp(tunnelControl: control, windows: windows, linux: linux),
          );
          await tester.pumpAndSettle();

          final icon = find.byKey(const Key('connection-icon'));
          final toggle = find.byKey(const Key('connection-toggle'));
          Color? iconColor() => tester.widget<Icon>(icon).color;
          final gray = iconColor();
          const green = Color(0xff24b83e);
          final error = Theme.of(tester.element(icon)).colorScheme.error;
          final size = tester.getSize(icon);
          final center = size.center(Offset.zero);
          Rect reveal() => tester
              .widget<ClipOval>(
                find.byKey(const Key('connection-green-reveal')),
              )
              .clipper!
              .getClip(size);
          expect(reveal().isEmpty, isTrue);
          expect(
            tester
                .widget<Icon>(
                  find.descendant(
                    of: find.byKey(const Key('connection-green-reveal')),
                    matching: find.byType(Icon),
                  ),
                )
                .color,
            green,
          );

          await tester.tap(toggle);
          await tester.pump();
          expect(find.text('Connected'), findsOneWidget);
          if (reduceMotion) {
            expect(reveal().width / 2, closeTo(center.distance, .001));
          } else {
            expect(reveal().isEmpty, isTrue);
            await tester.pump(const Duration(milliseconds: 200));
            // Rect.fromCircle can round its recomputed center by ~1e-14 pixels.
            expect((reveal().center - center).distance, lessThan(1e-9));
            expect(reveal().contains(center), isTrue);
            expect(reveal().contains(Offset(0, center.dy)), isFalse);
            expect(iconColor(), gray); // Outside the green reveal stays gray.
          }

          // Reverse before the first transition completes, then reconnect.
          final beforeDisconnect = reveal();
          await tester.tap(toggle);
          await tester.pump();
          expect(find.text('Disconnected'), findsOneWidget);
          if (reduceMotion) {
            expect(reveal().isEmpty, isTrue);
          } else {
            expect(reveal(), beforeDisconnect);
          }
          await tester.pumpAndSettle();
          expect(reveal().isEmpty, isTrue);

          await tester.tap(toggle);
          await tester.pump();
          if (!reduceMotion) {
            await tester.pump(const Duration(milliseconds: 399));
            expect(reveal().width / 2, lessThan(center.distance));
            await tester.pump(const Duration(milliseconds: 1));
          }
          expect(find.text('Connected'), findsOneWidget);
          expect(reveal().width / 2, closeTo(center.distance, .001));
          await tester.tap(toggle);
          await tester.pumpAndSettle();
          expect(reveal().isEmpty, isTrue);
          expect(iconColor(), gray);

          control.onConnect = () async => control.phase = 'failed';
          await tester.tap(toggle);
          await tester.pump();
          expect(find.text('Connection failed'), findsOneWidget);
          expect(reveal().isEmpty, isTrue);
          if (reduceMotion) {
            expect(iconColor(), error);
          } else {
            expect(iconColor(), gray);
            await tester.pump(const Duration(milliseconds: 200));
            expect(iconColor(), Color.lerp(gray, error, .5));
            expect(reveal().isEmpty, isTrue);
            await tester.pump(const Duration(milliseconds: 199));
            expect(iconColor(), isNot(error));
            await tester.pump(const Duration(milliseconds: 1));
            expect(iconColor(), error);
          }
          await tester.pumpAndSettle();
          expect(iconColor(), error);

          // Native cleanup can report disconnected after a failed attempt.
          // Keep failure feedback without changing that truthful status.
          control.onConnect = () async {
            control.phase = 'disconnected';
            throw PlatformException(code: 'connection_failed');
          };
          await tester.tap(toggle);
          await tester.pumpAndSettle();
          expect(find.text('Disconnected'), findsOneWidget);
          expect(reveal().isEmpty, isTrue);
          expect(iconColor(), error);

          control.onConnect = null;
          await tester.tap(toggle);
          await tester.pumpAndSettle();
          expect(find.text('Connected'), findsOneWidget);
          expect(iconColor(), gray);
          expect(reveal().width / 2, closeTo(center.distance, .001));
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
        variant: TargetPlatformVariant.only(
          linux
              ? TargetPlatform.linux
              : windows
              ? TargetPlatform.windows
              : TargetPlatform.macOS,
        ),
      );
    }

    testWidgets(
      'overview navigation, search and selected account on $platform',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1280, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        SubscriptionGroup group(
          String id,
          String name,
          bool selected,
          Map<String, Object?> metadata, {
          String status = 'ready',
          double? fetched,
        }) => SubscriptionGroup(
          id: id,
          name: name,
          status: status,
          metadata: metadata,
          lastSuccessfulFetch: fetched,
          nodes: [
            SubscriptionNode(
              id: id,
              name: '$name server',
              protocol: 'VLESS',
              transport: 'tcp',
              security: 'tls',
              selected: selected,
            ),
          ],
        );
        final control = FakeTunnelControl()
          ..snapshot = SubscriptionSnapshot(
            selectedNodeId: 'first',
            subscriptions: [
              group('first', 'Daily', true, {
                'total': 100 * 1073741824,
                'upload': 8 * 1073741824,
                'download': 20 * 1073741824,
              }),
              group('second', 'Travel', false, {'total': 0, 'expire': 0}),
            ],
          );
        await tester.pumpWidget(
          ElarniApp(tunnelControl: control, windows: windows, linux: linux),
        );
        await tester.pumpAndSettle();
        expect(find.text('72 GiB left'), findsOneWidget);
        expect(
          tester
              .widget<LinearProgressIndicator>(
                find.byKey(const Key('subscription-data-progress')),
              )
              .value,
          .72,
        );
        expect(
          find.byKey(const Key('subscription-time-progress')),
          findsNothing,
        );
        final selectedName = find.byKey(const Key('selected-server-name'));
        expect(tester.widget<Text>(selectedName).data, 'Daily server');
        await tester.enterText(find.byKey(const Key('node-search')), 'Travel');
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('node:first')), findsNothing);
        expect(find.byKey(const ValueKey('node:second')), findsOneWidget);
        expect(
          find.text('72 GiB left'),
          findsOneWidget,
        ); // Search is not selection.
        control.onSelect = () async {
          control.snapshot = SubscriptionSnapshot(
            selectedNodeId: 'second',
            subscriptions: [
              group('first', 'Daily', false, {}),
              group('second', 'Travel', true, {'total': 0, 'expire': 0}),
            ],
          );
          return NodeSelectionResult(
            state: 'prepared',
            subscriptions: control.snapshot,
          );
        };
        // The name: under the test font the middle of a split-layout row is its ping button.
        await tester.tap(
          find.descendant(
            of: find.byKey(const ValueKey('node:second')),
            matching: find.text('Travel server'),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Unlimited'), findsNothing);
        expect(find.text('No expiry'), findsNothing);
        expect(
          tester
              .widget<LinearProgressIndicator>(
                find.byKey(const Key('subscription-data-progress')),
              )
              .value,
          1,
        );
        expect(tester.widget<Text>(selectedName).data, 'Travel server');
        await tester.tap(find.byKey(const Key('current-subscription')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('subscriptions-list')),
          findsOneWidget,
        );
        await tester.tap(
          find.byKey(const ValueKey('subscription-actions:second')),
        );
        await tester.pumpAndSettle();
        expect(find.text('Download options').hitTestable(), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        control.onRefresh = (_) async =>
            throw StateError('synthetic fetch failure');
        await tester.tap(
          find.byKey(const ValueKey('refresh-subscription:second')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('nav-settings')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('settings-tab-connection')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const Key('nav-home')));
        await tester.pumpAndSettle();
        expect(tester.widget<Text>(selectedName).data, 'Travel server');
        expect(find.text('Unlimited'), findsNothing);
        expect(
          tester
              .widget<LinearProgressIndicator>(
                find.byKey(const Key('subscription-data-progress')),
              )
              .value,
          1,
        );
        expect(
          find.text('Refresh failed · Last reported information'),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const Key('current-subscription')));
        await tester.pumpAndSettle();
        control.onRefresh = (_) async =>
            SubscriptionOperationResult(snapshot: control.snapshot);
        await tester.tap(
          find.byKey(const ValueKey('refresh-subscription:second')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('nav-home')));
        await tester.pumpAndSettle();
        const failed = 'Refresh failed · Last reported information';
        expect(find.text(failed), findsNothing);
        Future<void> refreshFromHome() async {
          await tester.tap(find.byKey(const Key('current-subscription')));
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(const ValueKey('refresh-subscription:second')),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const Key('nav-home')));
          await tester.pumpAndSettle();
        }

        // Another operation holding the backend is not a failed download.
        control.onRefresh = (_) async => throw PlatformException(code: 'busy');
        await refreshFromHome();
        expect(find.text(failed), findsNothing);
        control.onRefresh = (_) async =>
            throw StateError('synthetic fetch failure');
        await refreshFromHome();
        expect(find.text(failed), findsOneWidget);
        // A scheduled download that succeeds later clears the mark.
        control.snapshot = SubscriptionSnapshot(
          selectedNodeId: 'second',
          subscriptions: [
            group('first', 'Daily', false, {}),
            group('second', 'Travel', true, {
              'total': 0,
              'expire': 0,
            }, fetched: 1000),
          ],
        );
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpAndSettle();
        expect(find.text(failed), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'stale account retains reported figures and local imports omit usage',
    (tester) async {
      Future<void> show(SubscriptionGroup group) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SubscriptionSummary(group: group, onOpen: () {}),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await show(
        const SubscriptionGroup(
          id: 'stale',
          name: 'Daily',
          status: 'refresh_failed',
          nodes: [],
          metadata: {'total': 100, 'upload': 10, 'download': 20},
        ),
      );
      expect(find.text('70 bytes left'), findsOneWidget);
      expect(
        find.text('Refresh failed · Last reported information'),
        findsOneWidget,
      );
      await show(
        const SubscriptionGroup(
          id: 'local',
          name: 'Imported profiles',
          status: 'ready',
          nodes: [],
          isLocal: true,
        ),
      );
      expect(find.text('Imported profiles'), findsOneWidget);
      expect(find.text('Data'), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
