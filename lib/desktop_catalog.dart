import 'dart:convert';
import 'dart:math';

import 'platform_services.dart';

import 'tunnel_channel.dart';

typedef CatalogMap = Map<String, Object?>;
typedef DesktopRequest = Future<CatalogMap> Function(String, CatalogMap);
typedef DomainRequest = CatalogMap Function(String, CatalogMap);

CatalogMap catalogMap(Object? value) =>
    Map<String, Object?>.from(value! as Map);
List<CatalogMap> catalogList(Object? value) =>
    (value as List? ?? []).map(catalogMap).toList();
CatalogMap copyCatalog(CatalogMap value) =>
    catalogMap(jsonDecode(jsonEncode(value)));
String desktopID() => List.generate(
  32,
  (_) => Random.secure().nextInt(256),
).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
PlatformException desktopError(
  String code, {
  Object? missing,
}) => PlatformException(
  code: code,
  message: switch (code) {
    'missing_geodata' =>
      'Proxy rules and servers need codes the geofiles lack: '
          '${(missing as List? ?? []).join(', ')}. '
          'Fix the profile or its geofile links.',
    'assets_missing' =>
      'The routing profile’s geofiles are missing. Use Refresh routing data, then connect again.',
    'storage_busy' => 'Elarni is already open for this user.',
    'catalog_limit' =>
      'Elarni keeps up to 1,024 subscriptions and 256 routing profiles. Delete some, then retry.',
    'storage_corrupt' =>
      'The saved catalog cannot be read. It has been preserved.',
    'storage_conflict' =>
      'The catalog changed in another process. Restart Elarni.',
    'storage_unavailable' => 'The encrypted catalog could not be saved.',
    'busy' => 'Another operation is in progress.',
    'listener_unavailable' =>
      'A local proxy port is occupied or not allowed. Close the app that uses it or change the port in Connection settings.',
    'cancelled' => 'The operation was cancelled.',
    'elevation_denied' => 'Administrator permission was cancelled.',
    'elevation_failed' => 'The system could not start the VPN helper.',
    'connection_failed' =>
      'The connection failed. Check the selected profile and try again.',
    'native_unavailable' =>
      'The native components are unavailable. Reinstall Elarni.',
    'rollback_failed' =>
      'The change failed and recovery is incomplete. Restart Elarni.',
    'invalid_settings' => 'The connection settings are invalid.',
    'per_app_target_missing' =>
      'An app in Per-app routing uses a server that no longer exists. Choose another target for it in Per-app routing.',
    'invalid_configuration' => 'The connection configuration is invalid.',
    'approval_required' =>
      'This source needs approval before it can be contacted.',
    'sharing_disabled' => 'A provider has disabled sharing and backups.',
    'sharing_refresh_required' =>
      'Refresh every subscription before sharing or creating a backup.',
    'vpn_firewall_unavailable' =>
      'The VPN needs nftables. Install the nft command, then retry.',
    'vpn_guard_busy' =>
      'Another Elarni VPN is connected on this computer, by another user or the system service. Disconnect it, then retry.',
    'vpn_guard_stale' =>
      'DNS is blocked by a crashed tunnel. Use Repair VPN setup to remove the block.',
    'invalid_backup_password' => 'Backup passwords need 12 to 1024 characters.',
    'invalid_backup' =>
      'The backup could not be opened. Check the password and the file.',
    'backup_unsupported' =>
      'This catalog cannot be backed up: a restore accepts at most 4,096 servers and names up to 1,024 bytes.',
    'recording_empty' =>
      'Nothing is recorded yet. Turn on Record connection diagnostics, reproduce the problem, then export.',
    'recording_failed' => 'The connection recording could not be saved.',
    'recording_destination_required' =>
      'Give an absolute path for the new recording ZIP.',
    'invalid_url' => 'Enter a valid http or https URL.',
    // A download failure says whose fault it is, so provider outages are not reported as app bugs.
    _ when subscriptionFailures.containsKey(code) =>
      subscriptionFailures[code]!.$2,
    'import_too_large' => 'The import is too large.',
    'no_selected_subscription' =>
      'Select a server first. This routing link turns its profile on for the selected server’s subscription.',
    _ => 'The operation failed. Endpoint details were redacted.',
  },
);

// The encrypted catalog is a value: edit a copy, validate it, then publish it.
// Runtime and storage ownership remain in DesktopProxy.
final class DesktopCatalog {
  DesktopCatalog(
    this.data,
    this.native,
    this.domain, {
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;
  final CatalogMap data;
  final DesktopRequest native;
  final DomainRequest domain;
  // Tests move the refresh schedule's clock instead of waiting for it.
  final DateTime Function() clock;
  static CatalogMap empty() => {
    'version': 1,
    'installationID': desktopID(),
    'selectedNodeId': null,
    // Other local apps must not reach the listeners without a login (v2rayNG #5457).
    'settings': const TunnelSettings(
      xrayTunEnabled: true,
      memoryLimitMB: 0,
      inboundAuthEnabled: true,
    ).toMap(),
    'inboundCredentials': {
      'username': desktopID().substring(0, 32),
      'password': desktopID().substring(0, 32),
    },
    'sessionLimitsMigrated': true,
    'subscriptions': <Object?>[],
    'profiles': <Object?>[],
    'assignments': <String, Object?>{},
  };
  DesktopCatalog copy() =>
      DesktopCatalog(copyCatalog(data), native, domain, clock: clock);

  CatalogMap backup() {
    for (final source in sources) {
      if (catalogMap(source['metadata'] ?? {})['hideURL'] == true ||
          catalogList(source['nodes']).any((node) => node['hideURL'] == true)) {
        throw desktopError('sharing_disabled');
      }
      if (source['url'] != null &&
          catalogMap(source['metadata'] ?? {})['hideURL'] == null) {
        throw desktopError('sharing_refresh_required');
      }
    }
    return {
      'version': 1,
      if (selected != null) 'selectedNodeId': selected,
      'subscriptions': [
        for (final source in sources)
          {
            for (final key in [
              'id',
              'name',
              'url',
              'shareLink',
              'fallbackHosts',
              'fetchOptions',
              'manualRouting',
            ])
              if (source[key] != null) key: source[key],
            'nodes': [
              for (final node in catalogList(source['nodes'])) backupNode(node),
            ],
            'hiddenNodes': [
              for (final node in catalogList(source['hiddenNodes'] ?? []))
                backupNode(node),
            ],
          },
      ],
      'routes': [
        for (final route in routes)
          {
            for (final key in [
              'id',
              'profile',
              'enabled',
              'edited',
              'providerSubscriptionId',
            ])
              if (route[key] != null) key: route[key],
            if (route['providerSubscriptionId'] != null)
              'providerProfile': route['original'],
          },
      ],
      'assignments': assignments,
    };
  }

  // A renamed server carries the provider's name beside the user's.
  static CatalogMap backupNode(CatalogMap node) => {
    for (final key in [
      'id',
      'format',
      'config',
      'groupOverrides',
      'ipPreference',
    ])
      if (node[key] != null) key: node[key],
    'name': node['manualName'] ?? node['name'],
    if (node['manualName'] != null) 'providerName': node['name'],
    if (node['favorite'] == true) 'favorite': true,
  };

  void restoreBackup(CatalogMap backup) {
    final sourceIDs = <String, String>{},
        nodeIDs = <String, String>{},
        routeIDs = <String, String>{};
    data['subscriptions'] = <Object?>[];
    data['profiles'] = <Object?>[];
    data['assignments'] = <String, Object?>{};
    data['selectedNodeId'] = null;
    for (final source in catalogList(backup['subscriptions'])) {
      final id = sourceIDs[source['id']! as String] = desktopID();
      // Hidden servers restore with the rest, then leave the list below.
      final hiddenCount = catalogList(source['hiddenNodes'] ?? []).length;
      final rawNodes = [
        ...catalogList(source['nodes']),
        ...catalogList(source['hiddenNodes'] ?? []),
      ];
      final nodes = rawNodes.isEmpty
          ? <CatalogMap>[]
          : parseNodes({'profiles': rawNodes}, []);
      for (var index = 0; index < nodes.length; index++) {
        final raw = rawNodes[index], node = nodes[index];
        nodeIDs[raw['id']! as String] = node['id']! as String;
        node
          ..remove('providerName')
          ..['favorite'] = raw['favorite'] == true;
        if (raw['providerName'] case final String provider) {
          node
            ..['manualName'] = raw['name']
            ..['name'] = provider;
        }
      }
      final local = source['url'] == null;
      putSource({
        ...source,
        'id': id,
        'manualName': source['name'],
        'nodes': nodes,
        'hiddenNodes': <Object?>[],
        'format': 'source',
        'status': local ? 'ready' : 'needsApproval',
        'metadata': local ? {'hideURL': false} : <String, Object?>{},
        'approvedChain': <String>[],
        'links': {if (!local) 'source': source['url']},
      });
      for (var index = 0; index < nodes.length; index++) {
        for (final choice in catalogMap(
          rawNodes[index]['groupOverrides'] ?? {},
        ).entries) {
          try {
            selectGroup(
              nodes[index]['id']! as String,
              choice.key,
              choice.value! as String,
            );
          } on PlatformException catch (error) {
            // Overrides outlive provider group edits; a stale one must not
            // make the whole backup unrestorable.
            if (error.code != 'invalid_group') rethrow;
          }
        }
      }
      if (hiddenCount > 0) {
        final restored = sources.firstWhere((item) => item['id'] == id);
        final all = catalogList(restored['nodes']);
        putSource({
          ...restored,
          'nodes': all.sublist(0, all.length - hiddenCount),
          'hiddenNodes': all.sublist(all.length - hiddenCount),
        });
      }
    }
    for (final route in catalogList(backup['routes'])) {
      final decoded = catalogMap(
        domain('decodeRouting', {
          'content': jsonEncode(route['profile']),
        })['import'],
      );
      final profile = catalogMap(decoded['profile']);
      CatalogMap? original;
      if (route['providerProfile'] != null) {
        original = catalogMap(
          catalogMap(
            domain('decodeRouting', {
              'content': jsonEncode(route['providerProfile']),
            })['import'],
          )['profile'],
        );
      }
      final id = routeIDs[route['id']! as String] = desktopID();
      putRoute({
        'id': id,
        'name': display(profile['Name']) ?? 'Routing profile',
        'profile': profile,
        'original': original ?? profile,
        'providerSubscriptionId': sourceIDs[route['providerSubscriptionId']],
        'source': original == null ? 'local' : 'provider',
        'edited': route['edited'],
        'enabled': route['enabled'],
        'lists': <String, Object?>{},
        'routeModel': domain('mergeManagedRouting', {
          'profile': profile,
          'lists': <String, Object?>{},
        })['routeModel'],
        'geofileStatus':
            [
              'Geoipurl',
              'Geositeurl',
            ].any((key) => (profile[key] as String? ?? '').isNotEmpty)
            ? 'pending'
            : 'ready',
        'geofiles': <Object?>[],
        'reductionStatus': profile['UseChunkFiles'] == 'true'
            ? 'pending'
            : 'disabled',
        // Backups hold no lists or assets; schedule them as an import would.
        'nextManagedRefreshAt': catalogList(profile['ManagedSources']).isEmpty
            ? null
            : now,
        'nextGeoRefreshAt':
            [
              'Geoipurl',
              'Geositeurl',
            ].any((key) => (profile[key] as String? ?? '').isNotEmpty)
            ? now
            : null,
      });
    }
    data['assignments'] = {
      for (final entry in catalogMap(backup['assignments']).entries)
        sourceIDs[entry.key]!: routeIDs[entry.value]!,
    };
    data['selectedNodeId'] = nodeIDs[backup['selectedNodeId']];
    // Per-app server targets name servers by ID, which the restore renumbered.
    final settings = catalogMap(data['settings'] ?? {});
    if (settings['perAppTargets'] case final Map targets) {
      settings['perAppTargets'] = {
        for (final MapEntry(:key, :value) in targets.entries)
          key: value is String && value.startsWith('node:')
              ? 'node:${nodeIDs[value.substring(5)] ?? value.substring(5)}'
              : value,
      };
      data['settings'] = settings;
    }
    data.remove('automation');
    data.remove('automationEpisode');
    data['connectionIntent'] = false;
  }

  /// The core's per-app targets for these settings, with each server's profile.
  List<CatalogMap> perAppTargets(TunnelSettings settings) => [
    if (settings.perAppMode != 'off')
      for (final MapEntry(key: process, :value)
          in settings.perAppTargets.entries)
        if (value.startsWith('node:'))
          {
            'process': process,
            'target': 'server',
            'server':
                sources
                    .expand((source) => catalogList(source['nodes']))
                    .where((node) => node['id'] == value.substring(5))
                    .firstOrNull?['config'] ??
                (throw desktopError('per_app_target_missing')),
          }
        else if (value.startsWith('proxy:'))
          {'process': process, 'target': 'proxy', 'proxy': value.substring(6)}
        else
          {'process': process, 'target': value},
  ];

  List<CatalogMap> get sources => catalogList(data['subscriptions']);
  List<CatalogMap> get routes => catalogList(data['profiles']);
  CatalogMap get assignments => catalogMap(data['assignments']);
  String? get selected => data['selectedNodeId'] as String?;
  TunnelSettings get settings => TunnelSettings.fromMap({
    ...catalogMap(data['settings']),
    'inboundCredentialsConfigured': data['inboundCredentials'] is Map,
  });
  CatalogMap settingsSnapshot() => {
    ...settings.toMap(),
    'inboundCredentialsConfigured': data['inboundCredentials'] is Map,
  };
  double get now => clock().millisecondsSinceEpoch / 1000;

  // The old 256 TCP / 128 UDP defaults refuse new TUN flows under daily load.
  // Raise them once; a value the user picks afterwards is kept.
  bool migrateSessionLimits() {
    if (data['sessionLimitsMigrated'] == true) return false;
    final value = settings;
    data['settings'] = value
        .copyWith(
          tcpMaxConnections: value.tcpMaxConnections == 256 ? 2048 : null,
          udpMaxConnections: value.udpMaxConnections == 128 ? 1024 : null,
        )
        .toMap();
    data['sessionLimitsMigrated'] = true;
    return true;
  }

  void validate() {
    // Edits reach the limits; only an unreadable catalog is corrupt.
    if (sources.length > 1024 || routes.length > 256)
      throw desktopError('catalog_limit');
    try {
      if (data['version'] != 1 ||
          (data['installationID'] as String).length != 64)
        throw const FormatException();
      final sourceIDs = <String>{}, nodeIDs = <String>{}, routeIDs = <String>{};
      for (final source in sources) {
        if (!sourceIDs.add(source['id'] as String) ||
            source['name'] is! String ||
            (source['url'] != null && safeURL(source['url']) == null))
          throw const FormatException();
        for (final node in catalogList(source['nodes'])) {
          if (!nodeIDs.add(node['id'] as String) ||
              (node['ipPreference'] != null &&
                  (node['format'] != 'xrayProfile' ||
                      !{
                        'automatic',
                        'ipv4',
                        'ipv6',
                      }.contains(node['ipPreference']))) ||
              node['name'] is! String ||
              (node['manualName'] != null && node['manualName'] is! String) ||
              !{'xrayProfile', 'telegram'}.contains(node['format']) ||
              node['config'] is! Map ||
              node['format'] == 'telegram' &&
                  !(catalogMap(node['config'])['url'] as String).startsWith(
                    'tg://proxy?',
                  ))
            throw const FormatException();
        }
      }
      for (final route in routes) {
        if (!routeIDs.add(route['id'] as String) ||
            route['profile'] is! Map ||
            route['routeModel'] is! Map)
          throw const FormatException();
      }
      if (selected != null && !nodeIDs.contains(selected) ||
          assignments.entries.any(
            (entry) =>
                !sourceIDs.contains(entry.key) ||
                !routeIDs.contains(entry.value),
          ))
        throw const FormatException();
      settings.toMap();
    } on Object {
      throw desktopError('storage_corrupt');
    }
  }

  CatalogMap source(String id) => sources.firstWhere(
    (item) => item['id'] == id,
    orElse: () => throw desktopError('invalid_profile'),
  );

  /// What the core needs to name the X-HWID a refresh of [id] sends.
  CatalogMap deviceIdentity(String id) {
    final current = source(id);
    if (current['url'] == null) throw desktopError('invalid_profile');
    final host = catalogMap(current['fetchOptions'] ?? {})['httpHost'];
    // The URL a refresh fetches: the chosen format's link, if not the original.
    final format = current['format'] as String? ?? 'source';
    return {
      'url': format == 'source'
          ? current['url']
          : catalogMap(current['links'] ?? {})[format],
      'installationId': data['installationID'],
      if (current['deviceSalt'] is String) 'deviceSalt': current['deviceSalt'],
      if (host is String && host.isNotEmpty) 'httpHost': host,
    };
  }

  CatalogMap route(String id) => routes.firstWhere(
    (item) => item['id'] == id,
    orElse: () => throw desktopError('invalid_routing'),
  );
  CatalogMap node(String id) => sources
      .expand((item) => catalogList(item['nodes']))
      .firstWhere(
        (item) => item['id'] == id,
        orElse: () => throw desktopError('invalid_profile'),
      );
  void putSource(CatalogMap value) {
    final items = sources;
    final index = items.indexWhere((item) => item['id'] == value['id']);
    if (index < 0) {
      items.add(value);
    } else {
      items[index] = value;
    }
    data['subscriptions'] = items;
  }

  void putRoute(CatalogMap value) {
    final items = routes;
    final index = items.indexWhere((item) => item['id'] == value['id']);
    if (index < 0) {
      items.add(value);
    } else {
      items[index] = value;
    }
    data['profiles'] = items;
  }

  CatalogMap snapshot() => {
    'selectedNodeId': selected,
    'subscriptions': [
      for (final source in sources)
        {
          for (final key in [
            'id',
            'name',
            'status',
            'riskCodes',
            'lastSuccessfulFetch',
            'refreshError',
            'metadata',
            'format',
            'fallbackHosts',
            'fetchOptions',
          ])
            key: source[key],
          'isLocal': source['url'] == null,
          'nextRefreshAt': nextSubscriptionRefresh(source),
          'actions': catalogMap(
            source['links'] ?? {},
          ).keys.where((key) => key != 'source').toList()..sort(),
          'nodes': [
            for (final node in catalogList(source['nodes']))
              {
                'id': node['id'],
                'name': node['manualName'] ?? node['name'],
                ..._nodeDisplay(node),
                'format': node['format'],
                'ipPreference': node['ipPreference'],
                'selected': node['id'] == selected,
                'favorite': node['favorite'] == true,
                'configurationRevision':
                    node['configurationRevision'] ?? node['id'],
                'lastSuccessAt': node['lastSuccessAt'],
                'lastSuccessCurrent':
                    node['lastSuccessRevision'] != null &&
                    node['lastSuccessRevision'] ==
                        (node['configurationRevision'] ?? node['id']),
                'groups': catalogMap(node['config'])['elarniGroups'] ?? [],
              },
          ],
          'hiddenNodes': [
            for (final node in catalogList(source['hiddenNodes'] ?? []))
              {'id': node['id'], 'name': node['manualName'] ?? node['name']},
          ],
        },
    ],
  };

  CatalogMap _nodeDisplay(CatalogMap node) {
    if (node['format'] == 'telegram') {
      return {
        'protocol': 'MTProto',
        'transport': 'Telegram',
        'security': 'MTProto',
      };
    }
    final outbounds = catalogList(catalogMap(node['config'])['outbounds']);
    final outbound = outbounds.first;
    final protocol = outbound['protocol']! as String;
    final stream = catalogMap(outbound['streamSettings'] ?? {});
    final wireguard = {'wireguard', 'amneziawg'}.contains(protocol);
    return {
      'protocol': outbounds.length > 1
          ? 'Xray profile'
          : const {
                  'vless': 'VLESS',
                  'vmess': 'VMess',
                  'trojan': 'Trojan',
                  'shadowsocks': 'Shadowsocks',
                  'socks': 'SOCKS',
                  'http': 'HTTP',
                  'hysteria': 'Hysteria2',
                  'tuic': 'TUIC',
                  'wireguard': 'WireGuard',
                  'amneziawg': 'AmneziaWG',
                }[protocol] ??
                protocol,
      'transport': protocol == 'tuic'
          ? 'QUIC'
          : display(stream['network']) ?? (wireguard ? 'UDP' : protocol),
      'security': protocol == 'tuic'
          ? 'TLS'
          : display(stream['security']) ?? (wireguard ? 'encrypted' : 'none'),
      'probeKey': _probeKey(outbounds),
    };
  }

  // The SNI a probe's handshake sends: bulk tests run at most two probes per
  // SNI, as TSPU counts handshakes per SNI. TLS without a name sends the address.
  static String? _probeKey(List<CatalogMap> outbounds) {
    Object? field(Object? map, String key) => map is Map ? map[key] : null;
    for (final outbound in outbounds) {
      final stream = outbound['streamSettings'],
          settings = outbound['settings'];
      final servers = field(settings, 'vnext') ?? field(settings, 'servers');
      final key =
          field(field(stream, 'realitySettings'), 'serverName') ??
          field(field(stream, 'tlsSettings'), 'serverName') ??
          (!{'tls', 'reality'}.contains(field(stream, 'security'))
              ? null
              : field(settings, 'address') ??
                    (servers is List && servers.isNotEmpty
                        ? field(servers.first, 'address')
                        : null));
      if (key is String && key.isNotEmpty) return key.toLowerCase();
    }
    return null;
  }

  CatalogMap routingSnapshot() => {
    'assignments': assignments,
    'profiles': [
      for (final item in routes)
        {
          for (final key in [
            'id',
            'name',
            'source',
            'edited',
            'enabled',
            'geofileStatus',
            'geofileError',
            'geofiles',
            'reductionStatus',
            'skippedGeodata',
            'providerSubscriptionId',
          ])
            key: item[key],
          'json': jsonEncode(item['profile']),
          if (item['managedError'] case final String code)
            'managedError': desktopError(code).message,
        },
    ],
  };

  // Canonical identities omit only root display fields. Matching
  // exact identities first preserves selection when a provider reorders nodes.
  static String identity(Object? value) {
    Object? canonical(Object? item) {
      if (item is List) return item.map(canonical).toList();
      if (item is Map) {
        final keys = item.keys.cast<String>().toList()..sort();
        return {for (final key in keys) key: canonical(item[key])};
      }
      return item;
    }

    final root = value is Map ? catalogMap(value) : value;
    if (root is Map) {
      root.remove('name');
      root.remove('remarks');
    }
    return jsonEncode(canonical(root));
  }

  List<CatalogMap> parseNodes(CatalogMap imported, List<CatalogMap> previous) {
    final keys =
        Map<CatalogMap, (Object?, Object?, Object?, Object?)>.identity();
    (Object?, Object?, Object?, Object?) logicalKey(CatalogMap node) =>
        keys[node] ??= () {
          final display = _nodeDisplay(node);
          return (
            node['name'],
            display['protocol'],
            display['transport'],
            display['security'],
          );
        }();
    Map<Object?, int> counts(Iterable<Object?> values) {
      final counts = <Object?, int>{};
      for (final value in values) {
        counts.update(value, (count) => count + 1, ifAbsent: () => 1);
      }
      return counts;
    }

    // Each node's identity is computed once, not once per candidate pair.
    final identities = Map<CatalogMap, String>.identity();
    String nodeIdentity(CatalogMap node) => identities[node] ??=
        domain('catalogIdentity', catalogMap(node['config']))['identity']!
            as String;
    final parsed = catalogList(imported['profiles'])
        .map(
          (item) => item['format'] == 'telegram' && item['url'] is String
              ? <String, Object?>{
                  ...item,
                  'config': {'url': item['url']},
                }
              : item,
        )
        .toList();
    if (parsed.isEmpty) throw desktopError('unsupported_profile');
    final available = [...previous]
      ..sort(
        (a, b) => a['id'] == selected
            ? -1
            : b['id'] == selected
            ? 1
            : 0,
      );
    // Reserve all exact matches before attempting a same-name replacement.
    // Otherwise an earlier replacement can steal a later unchanged node's ID.
    final matches = <int, CatalogMap>{};
    for (var i = 0; i < parsed.length; i++) {
      final index = available.indexWhere(
        (old) =>
            old['format'] == parsed[i]['format'] &&
            nodeIdentity(old) == nodeIdentity(parsed[i]),
      );
      if (index >= 0) matches[i] = available.removeAt(index);
    }
    final parsedKeys = counts(parsed.map(logicalKey)),
        parsedNames = counts(parsed.map((item) => item['name'])),
        previousNames = counts(previous.map((item) => item['name']));
    final result = <CatalogMap>[];
    for (var i = 0; i < parsed.length; i++) {
      final item = parsed[i];
      if (!{'xrayProfile', 'telegram'}.contains(item['format']) ||
          item['config'] is! Map)
        throw desktopError('unsupported_profile');
      var old = matches[i];
      if (old == null &&
          parsedKeys[logicalKey(item)] == 1 &&
          available
                  .where(
                    (old) =>
                        logicalKey(old) == logicalKey(item) &&
                        old['format'] == item['format'],
                  )
                  .length ==
              1) {
        old = available.removeAt(
          available.indexWhere(
            (old) =>
                logicalKey(old) == logicalKey(item) &&
                old['format'] == item['format'],
          ),
        );
      }
      // A unique provider name remains a stable identity when its transport or
      // profile representation changes. The separate revision invalidates health.
      if (old == null &&
          parsedNames[item['name']] == 1 &&
          previousNames[item['name']] == 1) {
        final index = available.indexWhere(
          (other) =>
              other['name'] == item['name'] &&
              other['format'] == item['format'],
        );
        if (index >= 0) old = available.removeAt(index);
      }
      final config = catalogMap(item['config']);
      final groups = catalogList(config['elarniGroups']);
      for (final group in groups) {
        final choice = catalogMap(old?['groupOverrides'] ?? {})[group['name']];
        if ((group['options'] as List).contains(choice))
          group['selected'] = choice;
      }
      if (config.containsKey('elarniGroups')) config['elarniGroups'] = groups;
      result.add({
        ...item,
        'id': old?['id'] ?? desktopID(),
        'config': config,
        'favorite': old?['favorite'] == true,
        'configurationRevision':
            old != null && identity(old['config']) == identity(config)
            ? old['configurationRevision'] ?? old['id']
            : desktopID(),
        if (old?['lastSuccessAt'] != null)
          'lastSuccessAt': old!['lastSuccessAt'],
        if (old?['lastSuccessRevision'] != null)
          'lastSuccessRevision': old!['lastSuccessRevision'],
        if (old?['groupOverrides'] != null)
          'groupOverrides': old!['groupOverrides'],
        if (old != null) 'ipPreference': old['ipPreference'],
        if (old?['manualName'] != null) 'manualName': old!['manualName'],
      });
    }
    return result;
  }

  /// The selected server and a subscription's last one stay. A provider's
  /// server is hidden instead, so that its next refresh keeps it out.
  void deleteNode(String id) {
    if (id == selected) throw desktopError('invalid_profile');
    for (final source in sources) {
      final nodes = catalogList(source['nodes']);
      if (!nodes.any((node) => node['id'] == id)) continue;
      if (nodes.length == 1) throw desktopError('invalid_profile');
      putSource({
        ...source,
        'nodes': [
          for (final node in nodes)
            if (node['id'] != id) node,
        ],
        if (source['url'] != null)
          'hiddenNodes': [
            ...catalogList(source['hiddenNodes'] ?? []),
            nodes.firstWhere((node) => node['id'] == id),
          ],
      });
      reconcileSelection();
      return;
    }
    throw desktopError('invalid_profile');
  }

  void showNode(String id) {
    for (final source in sources) {
      final hidden = catalogList(source['hiddenNodes'] ?? []);
      final node = hidden.where((node) => node['id'] == id).firstOrNull;
      if (node == null) continue;
      putSource({
        ...source,
        'nodes': [...catalogList(source['nodes']), node],
        'hiddenNodes': [
          for (final other in hidden)
            if (other['id'] != id) other,
        ],
      });
      return;
    }
    throw desktopError('invalid_profile');
  }

  void updateNode(String id, CatalogMap fields) {
    for (final source in sources) {
      final nodes = catalogList(source['nodes']);
      final index = nodes.indexWhere((node) => node['id'] == id);
      if (index < 0) continue;
      nodes[index] = {...nodes[index], ...fields};
      putSource({...source, 'nodes': nodes});
      return;
    }
    throw desktopError('invalid_profile');
  }

  /// A hand edit must still parse as one Xray server; the provider's next
  /// refresh replaces it like any other change.
  Future<void> replaceNodeConfig(String id, String content) async {
    final current = node(id);
    if (current['hideURL'] == true ||
        sources.any(
          (source) =>
              catalogMap(source['metadata'] ?? {})['hideURL'] == true &&
              catalogList(source['nodes']).any((node) => node['id'] == id),
        ))
      throw desktopError('sharing_disabled');
    if (current['format'] != 'xrayProfile')
      throw desktopError('unsupported_profile');
    final profiles = catalogList(
      (await native('importClientProfiles', {'text': content}))['profiles'],
    );
    if (profiles.length != 1 || profiles.single['format'] != 'xrayProfile')
      throw desktopError('unsupported_profile');
    updateNode(id, {'config': catalogMap(profiles.single['config'])});
  }

  void recordSuccess(String id) {
    final current = node(id);
    updateNode(id, {
      'lastSuccessAt': now,
      'lastSuccessRevision': current['configurationRevision'] ?? current['id'],
    });
  }

  void reconcileSelection() {
    final known = {
      for (final source in sources)
        for (final node in catalogList(source['nodes'])) node['id'],
    };
    if (!known.contains(selected)) data['selectedNodeId'] = null;
    // Automation checks every listed server; keep it working with the rest,
    // and off rather than invalid once none is left.
    if (data['automation'] case {'nodeIDs': final List ids}) {
      final kept = [
        for (final id in ids)
          if (known.contains(id)) id,
      ];
      final russian = catalogMap(data['automation'])['russianEntryNodeIDs'];
      data['automation'] = {
        ...catalogMap(data['automation']),
        'nodeIDs': kept,
        if (russian is List)
          'russianEntryNodeIDs': russian.where(kept.contains).toList(),
        if (kept.isEmpty) 'enabled': false,
      };
    }
  }

  /// Local imports join one group and skip servers it already has; the
  /// result lists each imported server as it is stored. Hidden imports keep
  /// their own group so their sharing limit doesn't spread to other servers.
  Future<List<CatalogMap>> importLocal(String content) async {
    final imported = await native('importClientProfiles', {'text': content});
    final group = imported['hideURL'] == true
        ? null
        : sources
              .where(
                (source) =>
                    source['url'] == null &&
                    !catalogList(
                      source['nodes'],
                    ).any((node) => node['hideURL'] == true),
              )
              .firstOrNull;
    final id = group?['id'] as String? ?? desktopID();
    final kept = catalogList(group?['nodes']);
    String key(CatalogMap node) =>
        '${node['format']}\n${domain('catalogIdentity', catalogMap(node['config']))['identity']}';
    final known = {for (final node in kept) key(node): node};
    final added = <CatalogMap>[];
    final nodes = <CatalogMap>[];
    for (final node in parseNodes(imported, [])) {
      nodes.add(
        known.putIfAbsent(key(node), () {
          added.add(node..['hideURL'] = imported['hideURL'] == true);
          return node;
        }),
      );
    }
    putSource({
      ...?group,
      'id': id,
      'name': group?['name'] ?? 'Local profiles',
      'status': 'ready',
      'format': 'source',
      'nodes': [...kept, ...added],
    });
    for (final directive in addressedRouting([
      ...(imported['directives'] as List? ?? []).cast<String>().where(
        isRoutingLink,
      ),
    ])) {
      importRouting(directive, provider: id);
    }
    reconcileSelection();
    return nodes;
  }

  static String? safeURL(Object? value) {
    if (value is! String ||
        value.length > 16384 ||
        value.contains(RegExp(r'[\x00-\x20\x7f]')))
      return null;
    final url = Uri.tryParse(value);
    return url != null &&
            {'http', 'https'}.contains(url.scheme) &&
            url.host.isNotEmpty &&
            url.userInfo.isEmpty &&
            !url.hasFragment
        ? value
        : null;
  }

  static bool isRoutingLink(String value) => [
    'happ://routing/',
    'incy://routing/',
    'elarni://routing/',
    '://routing/',
  ].any(value.startsWith);

  // Panels such as 3x-ui send their Happ routing to every client
  // (3x-ui #5999), so links addressed to Elarni win when a feed has any.
  static List<String> addressedRouting(List<String> links) {
    final own = links
        .where((link) => link.startsWith('elarni://routing/'))
        .toList();
    return own.isEmpty ? links : own;
  }

  // Classification uses the strict, shared parser without changing the catalog.
  // A mixed feed falls through to the client parser regardless of line order.
  bool isRoutingInput(String value) {
    try {
      domain('decodeRouting', {'content': value});
      return true;
    } on Object {
      return false;
    }
  }

  String? display(Object? value) {
    if (value is! String || utf8.encode(value).length > 16384) return null;
    if (value.toLowerCase().startsWith('base64:')) {
      try {
        value =
            domain('decodeBase64Text', {'text': value.substring(7)})['text']!
                as String;
      } on Object {
        return null;
      }
    }
    return value.isNotEmpty &&
            !value.contains(RegExp(r'[\x00-\x08\x0b-\x1f\x7f]'))
        ? value
        : null;
  }

  String addSource(String url) {
    if (safeURL(url) == null) throw desktopError('invalid_url');
    final normalized = Uri.parse(url);
    final duplicate = sources
        .where(
          (item) =>
              item['url'] is String &&
              Uri.parse(item['url']! as String) == normalized,
        )
        .firstOrNull;
    if (duplicate != null) return duplicate['id']! as String;
    final id = desktopID();
    putSource({
      'id': id,
      'name': Uri.parse(url).host,
      'url': url,
      'format': 'source',
      'status': 'pending',
      'nodes': <Object?>[],
      'links': {'source': url},
    });
    return id;
  }

  Future<CatalogMap?> refresh(
    String id, {
    List<String>? approval,
    String? format,
  }) async {
    final current = source(id);
    if (current['url'] == null) throw desktopError('invalid_profile');
    final targetFormat = format ?? current['format'] as String? ?? 'source';
    if (!{'source', 'raw', 'json', 'clash'}.contains(targetFormat))
      throw desktopError('invalid_format');
    final links = catalogMap(current['links'] ?? {});
    final url = targetFormat == 'source' ? current['url'] : links[targetFormat];
    if (url is! String) throw desktopError('invalid_format');
    final feed = await native('fetchSubscription', {
      'url': url,
      'installationID': data['installationID'],
      if (current['deviceSalt'] is String) 'deviceSalt': current['deviceSalt'],
      'fallbackHosts': current['fallbackHosts'] ?? <String>[],
      // The provider's backup URL stands in for its main URL, not for other formats.
      if (targetFormat == 'source' && current['fallbackURL'] is String)
        'fallbackURL': current['fallbackURL'],
      ...catalogMap(current['fetchOptions'] ?? {})..remove('refreshHours'),
      'approvedChain':
          approval ??
          (targetFormat == current['format']
              ? current['approvedChain'] ?? []
              : []),
    });
    if (feed['warning'] case final Map warning) {
      putSource({
        ...current,
        'status': 'needsApproval',
        'riskCodes': warning['riskCodes'],
      });
      return {
        ...catalogMap(warning),
        'subscriptionId': id,
        'format': targetFormat,
      };
    }
    final body = feed['body']! as String;
    final headers = catalogMap(feed['headers']);
    final imported = await native('importClientProfiles', {
      'text': body,
      'sourceURL': url,
      'migrationHeaders': {
        for (final key in ['new-url', 'new-domain', 'fallback-url'])
          if (headers[key] is String) key: headers[key],
      },
    });
    final migratedURL = imported['newSourceURL'] as String?;
    // Hidden servers match like the rest, and stay hidden while the provider lists them.
    final hidden = {
      for (final node in catalogList(current['hiddenNodes'] ?? [])) node['id'],
    };
    final merged = parseNodes(imported, [
      ...catalogList(current['nodes']),
      ...catalogList(current['hiddenNodes'] ?? []),
    ]);
    final nodes = [
      for (final node in merged)
        if (!hidden.contains(node['id'])) node,
    ];
    final metadata = <String, Object?>{};
    if ((imported['directives'] as List? ?? []).any(
      (value) => !isRoutingLink(value as String),
    ))
      metadata['directiveNotice'] = 'Unsupported provider directives';
    if (imported['systemResolverDNS'] == true)
      metadata['dnsNotice'] =
          "The provider's DNS asks this device's resolver, outside the tunnel. "
          'Elarni uses its own DNS for these servers.';
    metadata['hideURL'] = headers.containsKey('hide-url')
        ? {
            '1',
            'true',
            'yes',
          }.contains((headers['hide-url'] as String).trim().toLowerCase())
        : imported['hideURL'] == true;
    final seen = <String>{};
    for (final part
        in (headers['subscription-userinfo'] as String? ?? '').split(';')) {
      final pair = part.split('=').map((item) => item.trim()).toList();
      if (pair.length != 2 ||
          !{'upload', 'download', 'total', 'expire'}.contains(pair.first))
        continue;
      if (!seen.add(pair.first)) {
        metadata.remove(pair.first);
        continue;
      }
      final number = RegExp(r'^\d+$').hasMatch(pair.last)
          ? int.tryParse(pair.last)
          : null;
      if (number != null && number >= 0) metadata[pair.first] = number;
    }
    // 3x-ui's Profile-Update-Interval is a whole number of hours.
    final providerHours = headers['profile-update-interval'] is String
        ? RegExp(
            r'^\s*(\d{1,6})\s*$',
          ).firstMatch(headers['profile-update-interval']! as String)?.group(1)
        : null;
    if (providerHours != null && int.parse(providerHours) > 0)
      metadata['updateIntervalHours'] = int.parse(providerHours).clamp(1, 168);
    metadata['announcement'] = display(headers['announce']);
    metadata['bannerText'] = display(headers['banner-text']);
    metadata['bannerButtonText'] = display(headers['banner-button-text']);
    for (final entry in {
      'routingEnabled': 'routing-enable',
      'hideSettings': 'hide-settings',
      'deviceRegistered': 'x-hwid-active',
    }.entries) {
      metadata[entry.key] = switch ((headers[entry.value] as String?)
          ?.toLowerCase()) {
        '1' || 'true' => true,
        '0' || 'false' => false,
        _ => null,
      };
    }
    final newLinks = <String, Object?>{'source': feed['url']};
    for (final entry in {
      'support': 'support-url',
      'account': 'profile-web-page-url',
      'banner': 'banner-button-url',
    }.entries) {
      final link = safeURL(headers[entry.value]);
      if (link != null) newLinks[entry.key] = link;
    }
    final premiumURL = safeURL(headers['premium-url']);
    if (premiumURL != null) newLinks['banner'] = premiumURL;
    Object? jsonBody;
    try {
      jsonBody = jsonDecode(body);
    } on Object {
      /* Other supported feed formats. */
    }
    final info = jsonBody is Map && jsonBody['info'] is Map
        ? catalogMap(jsonBody['info'])
        : <String, Object?>{};
    for (final entry in {'enabled': 'enabled', 'online': 'isOnline'}.entries) {
      if (info[entry.value] is bool) metadata[entry.key] = info[entry.value];
    }
    metadata['announcement'] ??= display(info['announce']);
    if (info['hide_url'] == true) metadata['hideURL'] = true;
    for (final key in ['upload', 'download', 'total']) {
      final number = info['${key}Byte'];
      if (metadata[key] == null && number is int && number >= 0)
        metadata[key] = number;
    }
    for (final entry in {
      'raw': 'subUrl',
      'json': 'subJsonUrl',
      'clash': 'subClashUrl',
      'support': 'subSupportUrl',
    }.entries) {
      final link = safeURL(info[entry.value]);
      if (link != null) newLinks[entry.key] = link;
    }
    // Only the default format's response names the other formats; a refresh
    // in one of them keeps the names it has.
    if (targetFormat != 'source') {
      for (final format in ['raw', 'json', 'clash']) {
        newLinks[format] ??= links[format];
      }
      newLinks.removeWhere((_, link) => link == null);
    }
    final hours = refreshHours({...current, 'metadata': metadata});
    final interval =
        (hours.clamp(1, 168) *
                3600 *
                (0.9 + Random.secure().nextDouble() * 0.2))
            .clamp(900, 604800);
    if (migratedURL != null) {
      for (final format in ['raw', 'json', 'clash']) {
        newLinks.remove(format);
      }
    }
    final providerName =
        display(headers['profile-title']) ??
        current['importedName'] ??
        current['providerName'] ??
        Uri.parse(feed['url']! as String).host;
    putSource({
      ...current,
      if (migratedURL != null) ...{
        'url': migratedURL,
        'shareLink': migratedURL,
      },
      if (targetFormat == 'source' && imported['fallbackURL'] is String)
        'fallbackURL': imported['fallbackURL'],
      'nodes': nodes,
      'hiddenNodes': [
        for (final node in merged)
          if (hidden.contains(node['id'])) node,
      ],
      'metadata': metadata,
      'links': newLinks,
      'providerName': providerName,
      'name': current['manualName'] ?? providerName,
      'status': 'ready',
      'riskCodes': <Object?>[],
      'refreshError': null,
      'failures': 0,
      'format': migratedURL == null ? targetFormat : 'source',
      'approvedChain': migratedURL == null ? feed['approvedChain'] : <String>[],
      'lastSuccessfulFetch': now,
      'refreshInterval': hours * 3600,
      'nextRefreshAt': now + interval,
    });
    if (metadata['routingEnabled'] != false) {
      final directives = addressedRouting([
        if (headers['routing'] is String &&
            (headers['routing']! as String).isNotEmpty)
          headers['routing']! as String,
        ...(imported['directives'] as List? ?? []).cast<String>().where(
          isRoutingLink,
        ),
      ]);
      for (final directive in directives) {
        importRouting(directive, provider: id);
      }
    }
    reconcileSelection();
    // As on Android, a running tunnel moves to this provider's first server,
    // or to the next one automation checks so that it stays valid.
    data['selectedNodeId'] ??=
        switch (data['automation']) {
          {'enabled': true, 'nodeIDs': [final next, ...]} => next,
          _ => null,
        } ??
        nodes
            .where((node) => node['format'] == 'xrayProfile')
            .firstOrNull?['id'];
    return null;
  }

  num? nextSubscriptionRefresh(CatalogMap source) {
    if (source['url'] == null || source['status'] == 'needsApproval')
      return null;
    final scheduled = source['nextRefreshAt'] as num?;
    // Failed refreshes retain their backoff or authorization pause.
    if (source['refreshError'] != null ||
        (source['failures'] as int? ?? 0) > 0) {
      return scheduled;
    }
    final last = source['lastSuccessfulFetch'] as num?;
    final interval = refreshHours(source) * 3600;
    if (last != null && source['refreshInterval'] != interval)
      return last + interval;
    return scheduled;
  }

  // The user's override, else the provider's Profile-Update-Interval, else the
  // app setting.
  int refreshHours(CatalogMap source) =>
      int.tryParse(
        catalogMap(source['fetchOptions'] ?? {})['refreshHours'] as String? ??
            '',
      ) ??
      catalogMap(source['metadata'] ?? {})['updateIntervalHours'] as int? ??
      settings.subscriptionAutoUpdateHours;

  // Every failed refresh, scheduled or not, retries after this many seconds.
  static int retryDelay(int failures) =>
      const [60, 300, 1800][(failures - 1).clamp(0, 2)];

  void refreshFailed(String id, String code) {
    final current = source(id);
    final failures = (current['failures'] as int? ?? 0) + 1;
    putSource({
      ...current,
      'status': 'failed',
      'refreshError': code,
      'failures': failures,
      'nextRefreshAt': {'hwid_required', 'hwid_limit'}.contains(code)
          ? null
          : now + retryDelay(failures),
    });
  }

  void geofilesFailed(String id, String? message) {
    final current = route(id);
    final failures = (current['geoFailures'] as int? ?? 0) + 1;
    putRoute({
      ...current,
      'geofileStatus': 'failed',
      'geofileError': message,
      'geoFailures': failures,
      'nextGeoRefreshAt': now + retryDelay(failures),
    });
  }

  void setNodeIPPreference(String nodeID, Object? preference) {
    if (preference != null &&
        !{'automatic', 'ipv4', 'ipv6'}.contains(preference)) {
      throw desktopError('invalid_settings');
    }
    for (final source in sources) {
      final nodes = catalogList(source['nodes']);
      final index = nodes.indexWhere((item) => item['id'] == nodeID);
      if (index < 0) continue;
      if (nodes[index]['format'] != 'xrayProfile')
        throw desktopError('unsupported_profile');
      nodes[index]['ipPreference'] = preference;
      putSource({...source, 'nodes': nodes});
      return;
    }
    throw desktopError('invalid_profile');
  }

  void selectGroup(String nodeID, String groupName, String choice) {
    for (final source in sources) {
      final nodes = catalogList(source['nodes']);
      final index = nodes.indexWhere((item) => item['id'] == nodeID);
      if (index < 0) continue;
      final node = nodes[index], config = catalogMap(nodes[index]['config']);
      final groups = catalogList(config['elarniGroups']);
      final group = groups.firstWhere(
        (item) => item['name'] == groupName,
        orElse: () => throw desktopError('invalid_group'),
      );
      if (!(group['options'] as List).contains(choice))
        throw desktopError('invalid_group');
      group['selected'] = choice;
      config['elarniGroups'] = groups;
      nodes[index] = {
        ...node,
        'config': config,
        'groupOverrides': {
          ...catalogMap(node['groupOverrides'] ?? {}),
          groupName: choice,
        },
      };
      putSource({...source, 'nodes': nodes});
      return;
    }
    throw desktopError('invalid_profile');
  }

  // Once the user assigns a subscription's routing, the provider's directives
  // no longer change it; refreshes still update the provider's own profile.
  void assignRouting(String sourceID, String? routeID, {bool byUser = true}) {
    final current = source(sourceID);
    if (!byUser && current['manualRouting'] == true) return;
    data['assignments'] = routeID == null
        ? (assignments..remove(sourceID))
        : (assignments..[sourceID] = routeID);
    if (byUser) putSource({...current, 'manualRouting': true});
  }

  String? importRouting(String content, {String? provider, String? update}) {
    final parsed = catalogMap(
      domain('decodeRouting', {'content': content})['import'],
    );
    final target =
        provider ??
        sources
                .where(
                  (source) => catalogList(
                    source['nodes'],
                  ).any((node) => node['id'] == selected),
                )
                .firstOrNull?['id']
            as String?;
    if (parsed['action'] == 'off') {
      if (target == null) throw desktopError('no_selected_subscription');
      assignRouting(target, null, byUser: provider == null);
      return null;
    }
    final profile = catalogMap(parsed['profile']);
    final previous = update != null
        ? route(update)
        : provider == null
        ? routes
              .where(
                (item) =>
                    item['providerSubscriptionId'] == null &&
                    item['name'] ==
                        (display(profile['Name']) ?? 'Routing profile'),
              )
              .firstOrNull
        : routes
              .where((item) => item['providerSubscriptionId'] == provider)
              .firstOrNull;
    final id = previous?['id'] as String? ?? desktopID();
    if (parsed['activate'] == true) {
      if (target == null) throw desktopError('no_selected_subscription');
      assignRouting(target, id, byUser: provider == null);
    }
    if (provider != null && previous?['edited'] == true) {
      putRoute({...previous!, 'original': profile});
      return id;
    }
    final managed = catalogList(profile['ManagedSources']);
    final oldSources = catalogList(
      catalogMap(previous?['profile'] ?? {})['ManagedSources'],
    );
    final oldLists = catalogMap(previous?['lists'] ?? {});
    final retained = <String, Object?>{};
    for (final item in managed) {
      if (oldSources.any(
            (old) => [
              'id',
              'destination',
              'matchMode',
            ].every((key) => old[key] == item[key]),
          ) &&
          oldLists.containsKey(item['id']))
        retained[item['id']! as String] = oldLists[item['id']];
    }
    final hasGeo = ['Geoipurl', 'Geositeurl'].any(
      (key) => profile[key] is String && (profile[key] as String).isNotEmpty,
    );
    putRoute({
      if (previous != null) ...previous,
      'id': id,
      'name': display(profile['Name']) ?? 'Routing profile',
      'source': provider == null
          ? (previous?['source'] ?? 'local')
          : 'provider',
      'providerSubscriptionId': provider ?? previous?['providerSubscriptionId'],
      'edited': update != null,
      'enabled': previous?['enabled'] ?? true,
      'profile': profile,
      'original': provider != null ? profile : previous?['original'] ?? profile,
      'lists': retained,
      'routeModel': domain('mergeManagedRouting', {
        'profile': profile,
        'lists': retained,
      })['routeModel'],
      'geofileStatus':
          previous?['geofileStatus'] ?? (hasGeo ? 'pending' : 'ready'),
      'geofiles': previous?['geofiles'] ?? [],
      'reductionStatus':
          previous?['reductionStatus'] ??
          (profile['UseChunkFiles'] == 'true' ? 'pending' : 'disabled'),
      'nextManagedRefreshAt': managed.isEmpty
          ? null
          : jsonEncode(managed) == jsonEncode(oldSources)
          ? (previous?['nextManagedRefreshAt'] ?? now)
          : now,
    });
    return id;
  }

  // Each list refreshes on its own: a failed one keeps its last download, and
  // the route records the first error and retries on the shared schedule.
  Future<void> refreshManaged(String id) async {
    final item = route(id), profile = catalogMap(item['profile']);
    final sources = catalogList(profile['ManagedSources']);
    final previous = catalogMap(item['lists'] ?? {});
    final lists = <String, Object?>{
      for (final source in sources)
        if (previous.containsKey(source['id']))
          source['id']! as String: previous[source['id']],
    };
    String? error;
    for (final source in sources) {
      try {
        final feed = await native('fetchSubscription', {'url': source['url']});
        if (feed['warning'] != null) throw desktopError('approval_required');
        lists[source['id']! as String] = domain('parseManagedDomains', {
          'text': feed['body'],
          'matchMode': source['matchMode'],
        })['domains'];
      } on PlatformException catch (failure) {
        if (failure.code == 'cancelled') rethrow;
        error ??= failure.code;
      }
    }
    Object? routeModel;
    try {
      routeModel = domain('mergeManagedRouting', {
        'profile': profile,
        'lists': lists,
      })['routeModel'];
    } on PlatformException catch (failure) {
      // The merged lists are unusable, for example over the routing limits,
      // so the route keeps its previous lists.
      error = failure.code;
    }
    final failures = error == null
        ? 0
        : (item['managedFailures'] as int? ?? 0) + 1;
    putRoute({
      ...item,
      if (routeModel != null) ...{'lists': lists, 'routeModel': routeModel},
      'nextManagedRefreshAt':
          now + (error == null ? 86400 : retryDelay(failures)),
      'managedError': error,
      'managedFailures': failures,
    });
  }
}
