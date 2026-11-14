import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:elarni/tunnel_channel.dart';
import 'package:elarni/desktop_catalog.dart';

void main() {
  test(
    'managed lists refresh independently and keep the last good download',
    () async {
      var now = DateTime.fromMillisecondsSinceEpoch(100000 * 1000);
      var reachable = false;
      final catalog = DesktopCatalog(
        DesktopCatalog.empty(),
        (method, payload) async {
          final host = Uri.parse(payload['url']! as String).host;
          if (host == 'broken.example' && !reachable)
            throw PlatformException(code: 'fetch_failed');
          return {'body': host};
        },
        (operation, payload) => switch (operation) {
          'parseManagedDomains' => {
            'domains': ['full:${payload['text']}'],
          },
          'mergeManagedRouting' => {
            'routeModel': {'lists': payload['lists']},
          },
          _ => throw StateError(operation),
        },
        clock: () => now,
      );
      CatalogMap source(String id) => {
        'id': id,
        'url': 'https://$id.example/list',
        'destination': 'proxy',
        'matchMode': 'exact',
      };
      catalog.putRoute({
        'id': 'route',
        'profile': {
          'ManagedSources': [source('broken'), source('fresh')],
        },
        'lists': {
          'broken': ['full:kept.example'],
        },
        'routeModel': <String, Object?>{},
      });
      String? shownError() =>
          catalogList(
                catalog.routingSnapshot()['profiles'],
              ).single['managedError']
              as String?;
      final kept = {
        'broken': ['full:kept.example'],
        'fresh': ['full:fresh.example'],
      };
      // The failed list keeps its last download and retries on the
      // subscription schedule while the other list still updates.
      for (final delay in [60, 300, 1800, 1800]) {
        await catalog.refreshManaged('route');
        final route = catalog.route('route');
        expect(route['lists'], kept);
        expect(route['routeModel'], {'lists': kept});
        expect(route['managedError'], 'fetch_failed');
        expect(route['nextManagedRefreshAt'], catalog.now + delay);
        expect(shownError(), desktopError('fetch_failed').message);
        now = now.add(Duration(seconds: delay));
      }
      reachable = true;
      await catalog.refreshManaged('route');
      final route = catalog.route('route');
      expect(route['lists'], {
        ...kept,
        'broken': ['full:broken.example'],
      });
      expect(route['managedError'], isNull);
      expect(route['nextManagedRefreshAt'], catalog.now + 86400);
      expect(shownError(), isNull);
      reachable = false;
      await catalog.refreshManaged('route');
      expect(
        catalog.route('route')['nextManagedRefreshAt'],
        catalog.now + 60,
        reason: 'A success restarts the retry schedule',
      );
    },
  );

  // A refresh under a clock set years ahead writes a time years away; once
  // the clock is right again, the schedule must not wait for it.
  test('a schedule written under a clock that was ahead is due again', () {
    var now = DateTime.utc(2036);
    final catalog = DesktopCatalog(
      DesktopCatalog.empty(),
      (_, _) async => {},
      (_, _) => {},
      clock: () => now,
    );
    final written = catalog.now + 86400;
    expect(catalog.refreshDue(written, 86400), isFalse);
    expect(catalog.refreshDue(null, 86400), isFalse, reason: 'a paused one');

    now = DateTime.utc(2026, 11, 13);
    expect(catalog.refreshDue(written, 86400), isTrue);
    expect(catalog.refreshDue(catalog.now + 86400, 86400), isFalse);
    expect(
      catalog.refreshDue(catalog.now + 86400 + 600, 86400),
      isFalse,
      reason: 'a clock corrected by minutes refreshes nothing early',
    );
    expect(catalog.refreshDue(catalog.now - 1, 86400), isTrue);
  });

  // A refresh is scheduled its interval ahead, give or take a tenth: a
  // provider's 24 hours can be 26.4 hours away and still be on time.
  test('a refresh scheduled with its jitter is not due before its time', () {
    final now = DateTime.utc(2026, 11, 13);
    final catalog = DesktopCatalog(
      DesktopCatalog.empty(),
      (_, _) async => {},
      (_, _) => {},
      clock: () => now,
    );
    for (final hours in [0, 4, 24, 168, 1000]) {
      final next =
          catalog.now +
          (hours.clamp(1, 168) * 3600 * 1.0999).clamp(900, 604800);
      final source = {
        'id': 'source',
        'url': 'https://example.com/subscription',
        'status': 'ready',
        'metadata': {'updateIntervalHours': hours},
        'lastSuccessfulFetch': catalog.now,
        'refreshInterval': hours * 3600,
        'nextRefreshAt': next,
      };
      expect(
        catalog.subscriptionRefreshDue(source),
        isFalse,
        reason: '$hours hours',
      );
      expect(
        catalog.subscriptionRefreshDue({
          ...source,
          'nextRefreshAt': next + 2 * 86400,
        }),
        isTrue,
        reason: '$hours hours, written under a clock two days ahead',
      );
    }
  });

  test('failed routing downloads retry on the subscription schedule', () {
    var now = DateTime.fromMillisecondsSinceEpoch(100000 * 1000);
    final catalog = DesktopCatalog(
      DesktopCatalog.empty(),
      (_, _) async => {},
      (_, _) => {},
      clock: () => now,
    );
    catalog.putRoute({
      'id': 'route',
      'profile': <String, Object?>{},
      'routeModel': <String, Object?>{},
      'geofileStatus': 'ready',
    });
    for (final delay in [60, 300, 1800, 1800]) {
      catalog.geofilesFailed('route', 'The download failed.');
      final route = catalog.route('route');
      expect(route['geofileStatus'], 'failed');
      expect(route['geofileError'], 'The download failed.');
      expect(route['nextGeoRefreshAt'], catalog.now + delay);
      now = now.add(Duration(seconds: delay));
    }
  });

  test(
    'Windows refresh deadlines apply saved intervals to existing catalogs',
    () {
      const last = 100000;
      final data = DesktopCatalog.empty()..['settings'] = <String, Object?>{};
      final catalog = DesktopCatalog(data, (_, _) async => {}, (_, _) => {});
      final source = <String, Object?>{
        'id': 'fixture',
        'url': 'https://provider.example/feed',
        'status': 'ready',
        'lastSuccessfulFetch': last,
        'nextRefreshAt': last + 86400,
      };
      catalog.putSource(source);
      expect(catalog.nextSubscriptionRefresh(source), last + 4 * 3600);
      expect(
        catalogList(
          catalog.snapshot()['subscriptions'],
        ).single['nextRefreshAt'],
        last + 4 * 3600,
      );
      data['settings'] = const TunnelSettings(
        subscriptionAutoUpdateHours: 12,
      ).toMap();
      final reopened = catalog.copy();
      expect(reopened.settings.subscriptionAutoUpdateHours, 12);
      expect(
        reopened.nextSubscriptionRefresh(reopened.sources.single),
        last + 12 * 3600,
      );
      expect(
        reopened.nextSubscriptionRefresh({
          ...source,
          'refreshInterval': 12 * 3600,
          'nextRefreshAt': last + 44000,
        }),
        last + 44000,
        reason:
            'A successful refresh retains its jitter until the interval changes',
      );
      expect(
        reopened.nextSubscriptionRefresh({...source, 'url': null}),
        isNull,
      );
      expect(
        reopened.nextSubscriptionRefresh({
          ...source,
          'status': 'needsApproval',
        }),
        isNull,
      );
      expect(
        reopened.nextSubscriptionRefresh({
          ...source,
          'refreshError': 'hwid_required',
          'nextRefreshAt': null,
        }),
        isNull,
      );
      expect(
        reopened.nextSubscriptionRefresh({
          ...source,
          'refreshError': 'refresh_failed',
          'failures': 1,
          'nextRefreshAt': last + 60,
        }),
        last + 60,
      );
    },
  );
}
