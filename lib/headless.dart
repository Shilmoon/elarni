import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'desktop_catalog.dart';
import 'desktop_proxy.dart';
import 'headless_transport.dart';
import 'tunnel_channel.dart' show recordingBuild;

export 'headless_transport.dart';

// Dialog-free operations shared by the native macOS and Dart controllers.
const headlessMethods = {
  'state',
  'subscriptions',
  'routingProfiles',
  'tunnelSettings',
  'connect',
  'disconnect',
  'repairTunnel',
  'runtimeMetrics',
  'systemInfo',
  'routeTable',
  'setLaunchAtLogin',
  'configureAutomation',
  'automationStatus',
  'importClientProfiles',
  'addSubscription',
  'refreshSubscription',
  'selectNode',
  'setNodeFavorite',
  'setNodeIPPreference',
  'selectProfileGroup',
  'renameSubscription',
  'deleteSubscription',
  'updateSubscriptionFetchOptions',
  'updateTunnelSettings',
  'updateInboundCredentials',
  'importRouting',
  'updateRoutingProfile',
  'duplicateRoutingProfile',
  'deleteRoutingProfile',
  'resetRoutingProfile',
  'setRoutingProfileEnabled',
  'assignRoutingProfile',
  'refreshRoutingGeofiles',
  'pingNode',
  'shareClient',
  'exportCatalogBackup',
  'restoreCatalogBackup',
  'exportEvidence',
  if (recordingBuild) ...{'markRecording', 'exportRecording'},
};

// Only these operations are reachable through the private local control socket.
final class HeadlessControl {
  HeadlessControl(
    this.invoke, {
    this.unattended = false,
    this.desktopIntegration = true,
  });
  final DesktopRequest invoke;
  final bool unattended;
  final bool desktopIntegration;

  Set<String> get methods =>
      {...headlessMethods}
        ..removeAll(desktopIntegration ? const [] : const ['setLaunchAtLogin']);

  Future<CatalogMap> call(
    String method, [
    CatalogMap arguments = const {},
  ]) async {
    if (!methods.contains(method)) throw desktopError('unsupported_method');
    final args = {...arguments};
    if (method == 'importClientProfiles') args['source'] = 'text';
    if (method == 'restoreCatalogBackup' && args['content'] is! String)
      throw desktopError('backup_content_required');
    // The ZIP is written on the controller's host, as the controller's user.
    // The sandboxed macOS app keeps it in its temporary folder and returns that path.
    if (method == 'exportRecording' &&
        !Platform.isMacOS &&
        !(args['destination'] is String &&
            File(args['destination'] as String).isAbsolute))
      throw desktopError('recording_destination_required');
    if ({
      'exportCatalogBackup',
      'restoreCatalogBackup',
      'exportEvidence',
      'exportRecording',
    }.contains(method))
      args['headless'] = true;
    final result = await invoke(method, args);
    return {...result, ...approval(result)};
  }

  Future<CatalogMap> profiles() async {
    final snapshot = await invoke('subscriptions', {});
    return {
      'selectedNodeId': snapshot['selectedNodeId'],
      'subscriptions': [
        for (final source in catalogList(snapshot['subscriptions']))
          {
            'id': source['id'],
            'name': source['name'],
            'status': source['status'],
            'nodes': [
              for (final node in catalogList(source['nodes']))
                {
                  for (final key in [
                    'id',
                    'name',
                    'protocol',
                    'transport',
                    'selected',
                    'favorite',
                    'ipPreference',
                    'groups',
                  ])
                    key: node[key],
                },
            ],
          },
      ],
    };
  }

  Future<({String id, String source})> node(String reference) async {
    final matches = <({String id, String source})>[];
    final snapshot = await profiles();
    for (final source in catalogList(snapshot['subscriptions'])) {
      for (final item in catalogList(source['nodes'])) {
        if (item['id'] == reference || item['name'] == reference) {
          matches.add((
            id: item['id']! as String,
            source: source['id']! as String,
          ));
        }
      }
    }
    if (matches.length != 1)
      throw desktopError(
        matches.isEmpty ? 'profile_not_found' : 'ambiguous_profile',
      );
    return matches.single;
  }

  Future<CatalogMap> request(CatalogMap input) async {
    String text(String key) {
      final value = input[key];
      if (value is! String || value.isEmpty)
        throw desktopError('invalid_request');
      return value;
    }

    switch (input['command']) {
      case 'commands':
        return {
          'methods': methods.toList()..sort(),
          'desktopIntegration': desktopIntegration,
        };
      case 'call':
        return call(
          text('method'),
          input['arguments'] == null ? {} : headlessObject(input['arguments']),
        );
      case 'status':
        final snapshot = await profiles();
        return {
          ...await invoke('state', {}),
          'selectedNodeId': snapshot['selectedNodeId'],
          'automation': await invoke('automationStatus', {}),
          'runtime': await invoke('runtimeMetrics', {}),
        };
      case 'profiles':
        return profiles();
      case 'import':
        final result = await call('importClientProfiles', {
          'source': 'text',
          'content': text('content'),
        });
        return {...await profiles(), ...approval(result)};
      case 'refresh':
        final result = await call('refreshSubscription', {
          'id': text('id'),
          if (input['challenge'] != null) 'challenge': text('challenge'),
        });
        return {...await profiles(), ...approval(result)};
      case 'select':
        await call('selectNode', {'id': (await node(text('node'))).id});
        return profiles();
      case 'connect':
      case 'disconnect':
        return call(input['command']! as String);
      case 'probe':
        return call('pingNode', {
          'nodeId': (await node(text('node'))).id,
          'protocol': 'proxy',
          'method': 'GET',
          'mode': 'default',
          'timeout': 10,
          'url': input['url'] ?? 'https://www.gstatic.com/generate_204',
          'expectedStatus': 204,
          'expectedBody': '',
        });
      case 'settings':
        if (input['settings'] == null) return call('tunnelSettings');
        if (input['settings'] is! Map) throw desktopError('invalid_request');
        final settings = {
          ...await call('tunnelSettings'),
          ...catalogMap(input['settings']),
        };
        final result = await call('updateTunnelSettings', settings);
        return {...result, ...approval(result)};
      case 'failover':
        final primary = await node(text('primary'));
        final fallback = await node(text('fallback'));
        if (primary.id == fallback.id) throw desktopError('invalid_automation');
        final targets =
            input['targets'] ??
            [
              {
                'id': 'gstatic',
                'url': 'https://www.gstatic.com/generate_204',
                'expectedStatus': 204,
                'expectedBody': '',
              },
              {
                'id': 'cloudflare',
                'url': 'https://cp.cloudflare.com/generate_204',
                'expectedStatus': 204,
                'expectedBody': '',
              },
            ];
        if (!unattended) {
          if (primary.source != fallback.source)
            throw desktopError('fallback_requires_same_subscription');
          if ((await profiles())['selectedNodeId'] != primary.id)
            throw desktopError('select_primary_first');
        }
        return call('configureAutomation', {
          if (unattended) 'selectedNodeId': primary.id,
          'schemaVersion': 1,
          'enabled': true,
          'policy': 'orderedFallback',
          'subscriptionID': primary.source,
          'nodeIDs': [primary.id, fallback.id],
          'targets': targets,
        });
      default:
        throw desktopError('unsupported_command');
    }
  }

  // A source fetch that needs approval returns its challenge.
  CatalogMap approval(CatalogMap result) {
    final warning = catalogMap(result['warning'] ?? {});
    return {
      for (final key in ['subscriptionId', 'challenge', 'riskCodes'])
        if (warning[key] != null) key: warning[key],
    };
  }
}

/// Follows logind's PrepareForSleep through gdbus, as the Linux desktop host
/// does natively. Without gdbus or a system bus, sleep goes unnoticed.
Future<Process?> watchLinuxSleep(
  void Function(bool sleeping) changed, {
  String gdbus = 'gdbus',
}) async {
  final Process monitor;
  try {
    monitor = await Process.start(gdbus, [
      'monitor',
      '--system',
      '--dest',
      'org.freedesktop.login1',
      '--object-path',
      '/org/freedesktop/login1',
    ]);
  } on ProcessException {
    return null;
  }
  unawaited(monitor.stderr.drain<void>());
  monitor.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(
    (line) {
      for (final sleeping in [true, false]) {
        if (line.endsWith(
          'org.freedesktop.login1.Manager.PrepareForSleep ($sleeping,)',
        ))
          changed(sleeping);
      }
    },
  );
  return monitor;
}

Future<void> runHeadless({
  required String socketPath,
  required String corePath,
  required String domainPath,
  String? keyringPasswordFile,
}) async {
  if (!(Platform.isLinux || Platform.isWindows))
    throw UnsupportedError('Use the macOS app host for headless control.');
  if (keyringPasswordFile != null && !Platform.isLinux)
    throw ArgumentError('keyring_password_requires_linux');
  Process? keyring, sleep;
  DesktopProxy? proxy;
  HeadlessServer? server;
  final done = Completer<void>();
  void stop() {
    if (!done.isCompleted) done.complete();
  }

  final signals = <StreamSubscription<ProcessSignal>>[];
  try {
    if (keyringPasswordFile != null) {
      final password = File(keyringPasswordFile);
      if ((password.statSync().mode & 0x3f) != 0)
        throw StateError('keyring_password_must_be_private');
      keyring = await Process.start('gnome-keyring-daemon', [
        '--foreground',
        '--components=secrets',
        '--unlock',
      ]);
      // Secret bytes are written only to the daemon's stdin, never argv/logs.
      keyring.stdout.drain<void>();
      keyring.stderr.drain<void>();
      keyring.stdin.add(await password.readAsBytes());
      await keyring.stdin.close();
      var ready = false;
      for (var attempt = 0; attempt < 100; attempt++) {
        final response = await Process.run('gdbus', [
          'call',
          '--session',
          '--dest',
          'org.freedesktop.DBus',
          '--object-path',
          '/org/freedesktop/DBus',
          '--method',
          'org.freedesktop.DBus.NameHasOwner',
          'org.freedesktop.secrets',
        ]);
        if (response.exitCode == 0 &&
            response.stdout.toString().contains('true')) {
          ready = true;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      if (!ready) throw StateError('keyring_unavailable');
    }
    proxy = DesktopProxy(
      corePath: corePath,
      domainPath: domainPath,
      unattended: true,
      platformIO: (method, args) async {
        if (method == 'systemInfo')
          return {
            'os': Platform.operatingSystemVersion,
            'processorCount': Platform.numberOfProcessors,
            'activeProcessorCount': Platform.numberOfProcessors,
            'launchAtLoginStatus': 'managedByService',
          };
        if (method == 'routeTable' && Platform.isLinux) {
          final table = StringBuffer();
          // Debian keeps ip in /usr/sbin, Arch in /usr/bin, NixOS elsewhere.
          final ip =
              [
                '/usr/sbin/ip',
                '/usr/bin/ip',
                '/sbin/ip',
                '/run/current-system/sw/bin/ip',
              ].firstWhere(
                (path) => File(path).existsSync(),
                orElse: () => '/usr/sbin/ip',
              );
          for (final family in ['-4', '-6']) {
            final result = await Process.run(ip, [
              family,
              'route',
              'show',
              'table',
              'all',
            ]);
            if (result.exitCode != 0) throw desktopError('diagnostics_failed');
            table.write(result.stdout);
          }
          return {'table': table.toString()};
        }
        throw desktopError('desktop_operation_unavailable');
      },
    );
    server = await HeadlessServer.bind(
      socketPath,
      HeadlessControl(
        proxy.request,
        unattended: true,
        desktopIntegration: false,
      ).request,
      onShutdown: stop,
    );
    await proxy.request('state'); // Acquire the same catalog lease as the GUI.
    // The Windows daemon is the hidden app, whose window hears sleep itself.
    if (Platform.isLinux)
      sleep = await watchLinuxSleep((sleeping) {
        unawaited(proxy?.handleSleep(sleeping));
      });
    for (final signal in [
      ProcessSignal.sigint,
      if (!Platform.isWindows) ProcessSignal.sigterm,
    ]) {
      signals.add(signal.watch().listen((_) => stop()));
    }
    if (keyring != null)
      unawaited(
        keyring.exitCode.then((_) {
          if (!done.isCompleted)
            done.completeError(StateError('keyring_exited'));
        }),
      );
    stderr.writeln('Elarni headless control ready.');
    await done.future;
  } finally {
    for (final signal in signals) {
      await signal.cancel();
    }
    sleep?.kill();
    try {
      await server?.close();
    } finally {
      try {
        await proxy?.dispose();
      } finally {
        keyring?.kill();
        if (keyring != null) await keyring.exitCode;
      }
    }
  }
}
