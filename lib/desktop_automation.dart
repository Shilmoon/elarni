import 'dart:convert';
import 'dart:math';
import 'desktop_catalog.dart';

// Monotonic policy state; the owning backend serializes I/O and persists episodes.
final class DesktopAutomation {
  static bool physicalInterface(String name, {bool linux = false}) =>
      !name.toLowerCase().startsWith('elarni-') &&
      !(linux && RegExp(r'^rv[0-9a-f]{12}$').hasMatch(name));

  DesktopAutomation(CatalogMap saved) {
    attempts = saved['attempts'] as int? ?? 0;
    exhausted =
        saved['exhausted'] == true ||
        saved['interrupted'] == true ||
        attempts > 0;
  }
  bool intent = false, online = false, sleeping = false, exhausted = false;
  int epoch = 0, attempts = 0, failures = 0, rotation = 0;
  // Exhausted episodes since the last passing check or user action.
  int exhaustions = 0;
  String status = 'disabled', path = '';
  double? episodeStarted, retryAt, healthAt, lastSwitch, lastOptimization;
  double? _unattendedRearmAt;
  final Map<String, double> cooldown = {};
  final Set<String> invalid = {};
  final Map<String, ({double score, double at, int epoch, String reference})>
  measurements = {};
  // Mobile whitelists pass Russian addresses only: set when a Russian-entry
  // server passes after two foreign-entry ones failed, cleared by a foreign pass.
  bool whitelist = false;
  final Set<String> _foreignFailures = {};

  // Backups may come from any subscription; subscriptionID names the
  // selected server's, as older readers expect.
  static void validate(CatalogMap config, DesktopCatalog catalog) {
    try {
      final ids = (config['nodeIDs']! as List).cast<String>();
      final russian = (config['russianEntryNodeIDs'] as List? ?? [])
          .cast<String>();
      final targets = catalogList(config['targets']);
      final sourceID = config['subscriptionID']! as String;
      if (config['schemaVersion'] != 1 ||
          !russian.every(ids.contains) ||
          config['enabled'] is! bool ||
          !{
            'fixed',
            'lowestLatency',
            'orderedFallback',
          }.contains(config['policy']) ||
          sourceID.length > 128 ||
          ids.length > 1000 ||
          ids.toSet().length != ids.length ||
          ids.any((id) => id.isEmpty || id.length > 128) ||
          targets.length > 2 ||
          targets.map((t) => t['id']).toSet().length != targets.length ||
          config['enabled'] == true &&
              (sourceID.isEmpty || ids.isEmpty || targets.isEmpty)) {
        throw const FormatException();
      }
      final hosts = <String>{};
      for (final target in targets) {
        final id = target['id']! as String, url = target['url']! as String;
        final uri = Uri.parse(url);
        final status = target['expectedStatus']! as int;
        if (!RegExp(r'^[A-Za-z0-9._-]{1,64}$').hasMatch(id) ||
            utf8.encode(url).length > 4096 ||
            RegExp(r'[\x00-\x20\x7f]').hasMatch(url) ||
            !{'http', 'https'}.contains(uri.scheme) ||
            uri.host.isEmpty ||
            uri.userInfo.isNotEmpty ||
            uri.hasFragment ||
            uri.port < 1 ||
            uri.port > 65535 ||
            status < 200 ||
            status > 299 ||
            utf8.encode(target['expectedBody']! as String).length > 4096 ||
            !hosts.add(
              uri.host.toLowerCase().replaceFirst(RegExp(r'\.$'), ''),
            )) {
          throw const FormatException();
        }
      }
      if (config['enabled'] == true) {
        final nodes = catalog.sources
            .expand((source) => catalogList(source['nodes']))
            .toList();
        if (!ids.contains(catalog.selected) ||
            ids.any(
              (id) => !nodes.any(
                (node) => node['id'] == id && node['format'] == 'xrayProfile',
              ),
            )) {
          throw const FormatException();
        }
      }
    } on Object {
      throw desktopError('invalid_automation');
    }
  }

  CatalogMap get episode => {
    'attempts': attempts,
    'exhausted': exhausted,
    'interrupted': retryAt != null || attempts > 0,
  };

  void invalidate() {
    epoch++;
    measurements.clear();
    lastOptimization = null;
    healthAt = null;
    failures = 0;
  }

  void rearm(double now) {
    _unattendedRearmAt = null;
    invalidate();
    attempts = exhaustions = 0;
    exhausted = false;
    episodeStarted = retryAt = null;
    healthAt = now;
  }

  void manualStop() {
    intent = false;
    rearm(0);
    healthAt = null;
    status = 'stopped';
  }

  bool rearmUnattended(double now) {
    if (!intent || !exhausted || !online || sleeping) {
      _unattendedRearmAt = null;
      return false;
    }
    // TSPU freezes an SNI for about 120 s after a burst of handshakes, so
    // each unattended episode starts past that, and later ones wait longer.
    _unattendedRearmAt ??= now + const [150, 300, 600][min(exhaustions, 2)];
    if (now < _unattendedRearmAt!) return false;
    final count = exhaustions + 1;
    rearm(now);
    exhaustions = count;
    return true;
  }

  void pathChanged(String signature, bool available, double now) {
    if (signature == path && available == online) return;
    final initial = path.isEmpty;
    path = signature;
    online = available;
    invalidate();
    if (available && !exhausted) {
      if (!initial && attempts == 0)
        rearm(now);
      else
        healthAt = now;
    }
  }

  void sleepChanged(bool value, double now) {
    if (sleeping == value) return;
    sleeping = value;
    invalidate();
    if (!value && !exhausted && attempts == 0) rearm(now);
  }

  void healthy(double now) {
    attempts = failures = exhaustions = 0;
    exhausted = false;
    episodeStarted = retryAt = null;
    healthAt = now + 30;
    status = 'healthy';
  }

  double? score(String id, String reference, double now) {
    final item = measurements[id];
    return item != null &&
            item.epoch == epoch &&
            item.reference == reference &&
            now >= item.at &&
            now - item.at < 300
        ? item.score
        : null;
  }

  void scheduleRetry(double now) {
    if (retryAt != null || exhausted || !online || sleeping || !intent) return;
    episodeStarted ??= now;
    const delays = [1, 2, 4, 8, 16, 30];
    if (attempts >= delays.length ||
        now + delays[attempts] >= episodeStarted! + 120) {
      exhausted = true;
      healthAt = null;
      status = 'exhausted';
      return;
    }
    retryAt = now + delays[attempts];
    healthAt = null;
  }

  bool beginRetry(double now) {
    if (!intent ||
        !online ||
        sleeping ||
        exhausted ||
        retryAt == null ||
        now < retryAt!)
      return false;
    retryAt = null;
    if (attempts >= 6 || now >= episodeStarted! + 120) {
      exhausted = true;
      status = 'exhausted';
      return false;
    }
    attempts++;
    return true;
  }

  List<String> round(List<String> nodes, String? current, double now) {
    final eligible = nodes
        .where((id) => !invalid.contains(id) && (cooldown[id] ?? 0) <= now)
        .toList();
    final rest = eligible.where((id) => id != current).toList();
    final offset = rest.isEmpty ? 0 : rotation % rest.length;
    final result = [
      if (eligible.contains(current)) current!,
      ...rest.skip(offset),
      ...rest.take(offset),
    ].take(10).toList();
    if (rest.isNotEmpty)
      rotation =
          (offset + result.where((id) => id != current).length) % rest.length;
    return result;
  }

  // DPI cuts UDP transports and unusual ports first; TCP 443 looks like HTTPS.
  static bool tcp443(CatalogMap config) {
    try {
      final outbound = catalogList(config['outbounds']).first;
      final settings = catalogMap(outbound['settings'] ?? {});
      final stream = catalogMap(outbound['streamSettings'] ?? {});
      final servers = settings['vnext'] ?? settings['servers'];
      final port = servers is List
          ? catalogMap(servers.first)['port']
          : settings['port'];
      final alpn = catalogMap(stream['tlsSettings'] ?? {})['alpn'];
      return !{
            'hysteria',
            'tuic',
            'wireguard',
            'amneziawg',
          }.contains(outbound['protocol']) &&
          !{'kcp', 'mkcp', 'quic', 'hysteria'}.contains(stream['network']) &&
          !(alpn is List && alpn.length == 1 && alpn.first == 'h3') &&
          '$port' == '443';
    } on Object {
      return false;
    }
  }

  void observe(String id, bool passed, bool russianEntry) {
    if (!russianEntry) {
      if (passed) {
        whitelist = false;
        _foreignFailures.clear();
      } else {
        _foreignFailures.add(id);
      }
    } else if (passed && _foreignFailures.length >= 2) {
      whitelist = true;
    }
  }

  // Russian entries first in whitelist mode, then TCP 443 servers when the
  // failing one is not; otherwise the user's order.
  List<String> recoveryOrder(
    List<String> order,
    String current,
    Set<String> tcp443,
    Set<String> russianEntry,
  ) {
    int rank(String id) =>
        (whitelist && !russianEntry.contains(id) ? 2 : 0) +
        (!tcp443.contains(current) && !tcp443.contains(id) ? 1 : 0);
    return [
      for (var value = 0; value < 4; value++)
        ...order.where((id) => rank(id) == value),
    ];
  }

  List<String> recoveryCandidates(
    String policy,
    List<String> order,
    String current,
    double now,
  ) => policy == 'fixed'
      ? []
      : order
            .where(
              (id) =>
                  id != current &&
                  !invalid.contains(id) &&
                  (cooldown[id] ?? 0) <= now,
            )
            .take(10)
            .toList();

  String? choose(
    String policy,
    List<String> order,
    String? current,
    Map<String, double> scores,
    bool healthy,
    double now,
  ) {
    final eligible = order
        .where((id) => scores.containsKey(id) && (healthy || id != current))
        .toList();
    if (policy == 'fixed') return eligible.contains(current) ? current : null;
    // A failed latency sample must not move a connection that passed its health check.
    if (policy == 'orderedFallback')
      return healthy && current != null ? current : eligible.firstOrNull;
    eligible.sort(
      (a, b) => scores[a] == scores[b]
          ? (a == current
                ? -1
                : b == current
                ? 1
                : 0)
          : scores[a]!.compareTo(scores[b]!),
    );
    final best = eligible.firstOrNull;
    if (healthy && current != null && best != null && best != current) {
      final old = scores[current];
      if (old == null ||
          now - (lastSwitch ?? -1000) < 60 ||
          old - scores[best]! < 20 ||
          old - scores[best]! < old * .2)
        return current;
    }
    return best;
  }
}
