import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:elarni/desktop_catalog.dart';
import 'package:elarni/headless.dart';
import 'package:elarni/tunnel_channel.dart' show recordingBuild;
import 'package:elarni/windows_private_directory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'all catalog controls use the existing controller without dialogs',
    () async {
      final calls = <({String method, CatalogMap args})>[];
      final control = HeadlessControl((method, args) async {
        calls.add((method: method, args: args));
        return {'method': method};
      });
      for (final method in headlessMethods) {
        await control.request({
          'command': 'call',
          'method': method,
          'arguments': {
            'content': 'synthetic',
            'source': 'camera',
            'destination': '${Directory.systemTemp.path}/recording.zip',
          },
        });
      }
      expect(calls.map((c) => c.method).toSet(), headlessMethods);
      expect(
        calls
            .singleWhere((c) => c.method == 'importClientProfiles')
            .args['source'],
        'text',
      );
      for (final method in [
        'exportCatalogBackup',
        'restoreCatalogBackup',
        'exportEvidence',
        if (recordingBuild) 'exportRecording',
      ]) {
        expect(
          calls.singleWhere((c) => c.method == method).args['headless'],
          true,
        );
      }
      final count = calls.length;
      for (final method in [
        'debugFault',
        'saveLogs',
        'openProviderLink',
        'unknown',
      ]) {
        await expectLater(
          control.call(method),
          throwsA(isA<PlatformException>()),
        );
      }
      await expectLater(
        control.call('restoreCatalogBackup', {'password': 'synthetic'}),
        throwsA(isA<PlatformException>()),
      );
      await expectLater(
        control.request({
          'command': 'call',
          'method': 'connect',
          'arguments': [],
        }),
        throwsFormatException,
      );
      expect(calls.length, count);
    },
  );

  test('connection recording is headless only in recording builds', () async {
    var calls = 0;
    final control = HeadlessControl((method, args) async {
      calls++;
      return {};
    });
    if (!recordingBuild) {
      for (final method in ['markRecording', 'exportRecording']) {
        expect(headlessMethods, isNot(contains(method)));
        await expectLater(
          control.call(method, {
            'destination': '${Directory.systemTemp.path}/recording.zip',
          }),
          throwsA(
            isA<PlatformException>().having(
              (e) => e.code,
              'code',
              'unsupported_method',
            ),
          ),
        );
      }
      expect(calls, 0);
      return;
    }
    expect(headlessMethods, containsAll(['markRecording', 'exportRecording']));
    // A relative path would land wherever the controller happens to run.
    // The sandboxed macOS app ignores the path and returns its own.
    for (final destination in [
      if (!Platform.isMacOS) ...[null, 'recording.zip'],
    ]) {
      await expectLater(
        control.call('exportRecording', {'destination': destination}),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'recording_destination_required',
          ),
        ),
      );
    }
    expect(calls, 0);
  });

  test('the Linux daemon follows logind sleep and wake', () async {
    final directory = await Directory.systemTemp.createTemp('elarni-sleep-');
    addTearDown(() => directory.delete(recursive: true));
    final gdbus = File('${directory.path}/gdbus');
    // Lines as gdbus monitor prints them, around an unrelated signal.
    await gdbus.writeAsString('''#!/bin/sh
echo "Monitoring signals on object /org/freedesktop/login1 owned by org.freedesktop.login1"
echo "/org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForSleep (true,)"
echo "/org/freedesktop/login1: org.freedesktop.login1.Manager.SessionNew ('3', objectpath '/org/freedesktop/login1/session/_33')"
echo "/org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForSleep (false,)"
''');
    await Process.run('chmod', ['700', gdbus.path]);
    final changes = <bool>[];
    final monitor = await watchLinuxSleep(changes.add, gdbus: gdbus.path);
    expect(await monitor!.exitCode, 0);
    // The exit can arrive before the last stdout lines reach the listener.
    for (var i = 0; changes.length < 2 && i < 250; i++)
      await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(changes, [true, false]);
    expect(
      await watchLinuxSleep((_) {}, gdbus: '${directory.path}/missing'),
      isNull,
    );
  }, skip: Platform.isWindows);

  test(
    'the Linux endpoint needs no HOME for root or a runtime directory',
    () {
      String path(Map<String, String> env, {bool root = false}) =>
          headlessSocketPathFor(env, linuxRoot: root);
      // A system unit without User= has no HOME; the boot service listens here.
      expect(path({}, root: true), '/run/elarni/control.sock');
      expect(
        path({'XDG_RUNTIME_DIR': '/run/user/1000'}),
        '/run/user/1000/elarni/control.sock',
      );
      expect(
        path({'HOME': '/home/u', 'XDG_RUNTIME_DIR': '/run/user/1000'}),
        '/run/user/1000/elarni/control.sock',
      );
      expect(
        path({'HOME': '/home/u'}),
        '/home/u/.local/state/Elarni/control/control.sock',
      );
      expect(
        path({'ELARNI_CONTROL_SOCKET': '/x/control.sock'}, root: true),
        '/x/control.sock',
      );
      expect(
        () => path({}),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'home_unavailable',
          ),
        ),
      );
    },
    skip: !Platform.isLinux,
  );

  test('profiles redact secrets and retain source approvals', () async {
    final control = HeadlessControl(
      (method, args) async => switch (method) {
        'subscriptions' => {
          'selectedNodeId': 'one',
          'subscriptions': [
            {
              'id': 'source',
              'name': 'Fixture',
              'url': 'secret-url',
              'nodes': [
                {
                  'id': 'one',
                  'name': 'Same',
                  'config': {'password': 'secret'},
                },
                {'id': 'two', 'name': 'Same'},
              ],
            },
          ],
        },
        'refreshSubscription' => {
          'warning': {
            'subscriptionId': 'source',
            'challenge': 'approval-token',
            'riskCodes': ['loopback_target'],
            'url': 'secret-url',
          },
        },
        _ => {},
      },
    );
    final profiles = await control.profiles();
    expect(jsonEncode(profiles), isNot(contains('secret')));
    expect((await control.node('one')).id, 'one');
    await expectLater(
      control.node('Same'),
      throwsA(
        isA<PlatformException>().having(
          (e) => e.code,
          'code',
          'ambiguous_profile',
        ),
      ),
    );
    final refresh = await control.request({
      'command': 'refresh',
      'id': 'source',
    });
    expect(refresh['challenge'], 'approval-token');
    expect(jsonEncode(refresh), isNot(contains('secret')));
  });

  test('probe shorthand uses the native proxy protocol contract', () async {
    final calls = <CatalogMap>[];
    final control = HeadlessControl((method, args) async {
      if (method == 'subscriptions') {
        return {
          'subscriptions': [
            {
              'id': 'source',
              'nodes': [
                {'id': 'one', 'name': 'Fixture'},
              ],
            },
          ],
        };
      }
      calls.add({'method': method, 'arguments': args});
      return {'status': 'success'};
    });
    expect(
      await control.request({
        'command': 'probe',
        'node': 'Fixture',
        'url': 'https://example.com/check',
      }),
      {'status': 'success'},
    );
    expect(calls.single, {
      'method': 'pingNode',
      'arguments': {
        'nodeId': 'one',
        'protocol': 'proxy',
        'method': 'GET',
        'mode': 'default',
        'timeout': 10,
        'url': 'https://example.com/check',
        'expectedStatus': 204,
        'expectedBody': '',
      },
    });
  });

  test('partial settings preserve the controller contract', () async {
    final calls = <CatalogMap>[];
    final control = HeadlessControl((method, args) async {
      calls.add({'method': method, ...args});
      return method == 'tunnelSettings'
          ? {'socksPort': 1080, 'httpPort': 8080}
          : {};
    });
    await control.request({
      'command': 'settings',
      'settings': {'httpPort': 8081},
    });
    expect(calls.last, {
      'method': 'updateTunnelSettings',
      'socksPort': 1080,
      'httpPort': 8081,
    });
  });

  test(
    'interactive failover never selects a node before validating configuration',
    () async {
      final calls = <String>[];
      final control = HeadlessControl((method, args) async {
        calls.add(method);
        return {
          'selectedNodeId': 'backup',
          'subscriptions': [
            {
              'id': 'source',
              'nodes': [
                {'id': 'primary', 'name': 'Primary'},
                {'id': 'backup', 'name': 'Backup'},
              ],
            },
          ],
        };
      });
      await expectLater(
        control.request({
          'command': 'failover',
          'primary': 'primary',
          'fallback': 'backup',
        }),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'select_primary_first',
          ),
        ),
      );
      expect(calls.toSet(), {'subscriptions'});
    },
  );

  for (final tcp in [true, if (!Platform.isWindows) false]) {
    group(tcp ? 'authenticated loopback' : 'private Unix socket', () {
      late Directory temporary;
      late String path;
      HeadlessServer? server;
      setUp(() async {
        temporary = await Directory.systemTemp.createTemp('rv-control-');
        path = '${temporary.path}/private/control';
      });
      tearDown(() async {
        await server?.close();
        server = null;
        await temporary.delete(recursive: true);
      });

      test('an interrupted first run leaves a repairable directory', () async {
        // Created but never made private: it still inherits the temp ACL.
        await Directory('${temporary.path}/private').create();
        server = await HeadlessServer.bind(path, (_) async => {}, tcp: tcp);
        expect(
          (await headlessClient(path, {'command': 'status'}))['success'],
          true,
        );
      });

      test(
        'round trip, duplicate owner, shutdown and endpoint cleanup',
        () async {
          final done = Completer<void>();
          server = await HeadlessServer.bind(
            path,
            (input) async => input,
            tcp: tcp,
            onShutdown: () => done.complete(),
          );
          final reply = await headlessClient(path, {'command': 'status'});
          expect(reply['success'], true);
          expect(reply['data'], {'command': 'status'});
          expect(
            (await headlessClient(path, {
              'command': 'shutdown',
              'ownerPid': -1,
            }))['error'],
            'different_daemon_owner',
          );
          expect(done.isCompleted, false);
          await expectLater(
            HeadlessServer.bind(path, (_) async => {}, tcp: tcp),
            throwsStateError,
          );
          expect(
            (await headlessClient(path, {'command': 'status'}))['success'],
            true,
          );
          expect(
            (await headlessClient(path, {'command': 'shutdown'}))['success'],
            true,
          );
          await done.future;
          await server!.close();
          expect(
            await FileSystemEntity.type(path),
            FileSystemEntityType.notFound,
          );
          server = await HeadlessServer.bind(path, (_) async => {}, tcp: tcp);
          expect(
            (await headlessClient(path, {'command': 'shutdown'}))['error'],
            'shutdown_requires_daemon',
          );
        },
      );

      test(
        'disconnect can cancel a pending connect without an IPC queue',
        () async {
          final started = Completer<void>(), cancelled = Completer<void>();
          server = await HeadlessServer.bind(path, (input) async {
            if (input['command'] == 'connect') {
              started.complete();
              await cancelled.future;
            } else if (input['command'] == 'disconnect') {
              cancelled.complete();
            }
            return {'state': 'disconnected'};
          }, tcp: tcp);
          final connect = headlessClient(path, {'command': 'connect'});
          await started.future;
          expect(
            (await headlessClient(path, {'command': 'disconnect'}))['success'],
            true,
          );
          expect((await connect)['success'], true);
        },
      );

      test(
        'CLI reads JSON stdin and returns stable success and error codes',
        () async {
          server = await HeadlessServer.bind(path, (input) async {
            if (input['method'] == 'connect')
              throw PlatformException(code: 'busy', message: 'secret');
            return input;
          }, tcp: tcp);
          final packageFile = File('.dart_tool/package_config.json').absolute;
          final packages =
              jsonDecode(await packageFile.readAsString())['packages'] as List;
          final flutter = packages.singleWhere((p) => p['name'] == 'flutter');
          final dart =
              Directory.fromUri(
                    packageFile.uri.resolve(flutter['rootUri'] as String),
                  ).parent.parent.uri
                  .resolve(
                    'bin/cache/dart-sdk/bin/dart${Platform.isWindows ? '.exe' : ''}',
                  )
                  .toFilePath();
          final process = await Process.start(dart, [
            'bin/elarni.dart',
            '--socket',
            path,
            'call',
            'setNodeFavorite',
            '-',
          ]);
          final output = process.stdout.transform(utf8.decoder).join();
          final errors = process.stderr.transform(utf8.decoder).join();
          process.stdin.write('{"nodeId":"fixture","favorite":true}');
          await process.stdin.close();
          expect(await process.exitCode, 0, reason: await errors);
          expect(catalogMap(jsonDecode(await output)['data'])['arguments'], {
            'nodeId': 'fixture',
            'favorite': true,
          });
          final failure = await Process.run(dart, [
            'bin/elarni.dart',
            '--socket',
            path,
            'call',
            'connect',
          ]);
          expect(failure.exitCode, 1);
          expect(jsonDecode(failure.stdout as String), {
            'success': false,
            'error': 'busy',
          });
        },
      );
    });
  }

  test(
    'unauthenticated, malformed and oversized TCP requests cannot reach the controller',
    () async {
      final temporary = await Directory.systemTemp.createTemp('rv-auth-');
      final path = '${temporary.path}/private/control';
      var invoked = false;
      final server = await HeadlessServer.bind(path, (_) async {
        invoked = true;
        return {};
      }, tcp: true);
      try {
        final endpoint = headlessObject(
          jsonDecode(await File(path).readAsString()),
        );
        Future<CatalogMap> send(String value) async {
          final socket = await Socket.connect(
            InternetAddress.loopbackIPv4,
            endpoint['port']! as int,
          );
          try {
            socket.write(value);
            await socket.flush();
            return headlessObject(
              jsonDecode(await readHeadlessMessage(socket)),
            );
          } finally {
            socket.destroy();
          }
        }

        final token = endpoint['token']! as String;
        expect(
          (await send('{"command":"connect"}\n'))['error'],
          'unauthorized',
        );
        // The old in-body token no longer authenticates.
        expect(
          (await send(
            '${jsonEncode({'command': 'connect', 'authorization': token})}\n',
          ))['error'],
          'unauthorized',
        );
        // A peer without the token cannot make the server buffer a body.
        expect((await send('x' * 200))['error'], 'message_too_large');
        expect((await send('$token\n[]\n'))['error'], 'expected_json_object');
        expect((await send('$token\n{broken}\n'))['success'], false);
        expect(invoked, false);
        await expectLater(
          headlessClient(path, {'content': 'x' * headlessMessageLimit}),
          throwsFormatException,
        );
        await expectLater(
          readHeadlessMessage(
            Stream.value(List.filled(headlessMessageLimit + 1, 120)),
          ),
          throwsFormatException,
        );
        await expectLater(
          readHeadlessMessage(Stream.value(utf8.encode('{}'))),
          throwsFormatException,
        );
        expect(
          await readHeadlessMessage(
            Stream.fromIterable([
              [123],
              [125, 10],
            ]),
          ),
          '{}',
        );
      } finally {
        await server.close();
        await temporary.delete(recursive: true);
      }
    },
  );

  test(
    'a crashed owner\'s endpoint never receives the token',
    () async {
      final temporary = await Directory.systemTemp.createTemp('rv-path-');
      // Another local user can bind the port a crashed owner left behind.
      final impostor = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final received = <int>[];
      impostor.listen((socket) => socket.listen(received.addAll));
      try {
        final path = '${temporary.path}/private/control';
        final initial = await HeadlessServer.bind(
          path,
          (input) async => input,
          tcp: true,
        );
        await initial.close();
        await File(path).writeAsString(
          jsonEncode({
            'elarniControl': 1,
            'port': impostor.port,
            'token': 'a' * 64,
          }),
        );
        await expectLater(
          headlessClient(path, {'command': 'status'}),
          throwsA(isA<SocketException>()),
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(received, isEmpty);
      } finally {
        await impostor.close();
        await temporary.delete(recursive: true);
      }
    },
    // Only Windows publishes a TCP endpoint; its file locks are per handle.
    skip: !Platform.isWindows,
  );

  test(
    "a client checking a dead owner does not fail the next owner's start",
    () async {
      final temporary = await Directory.systemTemp.createTemp('rv-path-');
      try {
        final path = '${temporary.path}/private/control';
        final initial = await HeadlessServer.bind(
          path,
          (input) async => input,
          tcp: true,
        );
        await initial.close();
        // A client probing the stale endpoint holds the lock for a moment.
        final probe = await File('$path.lock').open(mode: FileMode.append);
        await probe.lock(FileLock.exclusive);
        final release = Future<void>.delayed(
          const Duration(milliseconds: 200),
          probe.close,
        );
        try {
          final server = await HeadlessServer.bind(
            path,
            (input) async => input,
            tcp: true,
          );
          await server.close();
        } finally {
          await release;
        }
      } finally {
        await temporary.delete(recursive: true);
      }
    },
    skip: !Platform.isWindows,
  );

  test(
    'a half-written endpoint does not lock out a new control server',
    () async {
      final temporary = await Directory.systemTemp.createTemp('rv-path-');
      try {
        final path = '${temporary.path}/private/control';
        final initial = await HeadlessServer.bind(
          path,
          (input) async => input,
          tcp: true,
        );
        await initial.close();
        // An owner killed while writing leaves a truncated endpoint behind.
        await File(path).writeAsString('{"elarniControl":1,"po');
        await expectLater(
          headlessClient(path, {'command': 'status'}),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              'invalid_endpoint',
            ),
          ),
        );
        final server = await HeadlessServer.bind(
          path,
          (input) async => input,
          tcp: true,
        );
        try {
          expect(
            (await headlessClient(path, {'command': 'status'}))['success'],
            true,
          );
        } finally {
          await server.close();
        }
      } finally {
        await temporary.delete(recursive: true);
      }
    },
  );

  test('occupied files and public control directories are preserved', () async {
    final temporary = await Directory.systemTemp.createTemp('rv-path-');
    try {
      final private = Directory('${temporary.path}/private');
      final path = '${private.path}/control';
      final initial = await HeadlessServer.bind(
        path,
        (_) async => {},
        tcp: true,
      );
      await initial.close();
      await File(path).writeAsString('{"unrelated":"preserve"}');
      await expectLater(
        HeadlessServer.bind(path, (_) async => {}, tcp: true),
        throwsStateError,
      );
      expect(await File(path).readAsString(), '{"unrelated":"preserve"}');
      if (!Platform.isWindows) {
        await Process.run('chmod', ['755', private.path]);
        await expectLater(
          HeadlessServer.bind(path, (_) async => {}, tcp: true),
          throwsStateError,
        );
        expect(await File(path).readAsString(), '{"unrelated":"preserve"}');
      } else {
        final expose = await Process.run(
          'powershell.exe',
          [
            '-NoProfile',
            '-NonInteractive',
            '-Command',
            r'''
$ErrorActionPreference = 'Stop'
$path = $env:ELARNI_TEST_DIRECTORY
$acl = [IO.Directory]::GetAccessControl($path)
$everyone = [System.Security.Principal.SecurityIdentifier]::new('S-1-1-0')
$rule = [System.Security.AccessControl.FileSystemAccessRule]::new($everyone, 'Read', 'Allow')
$acl.AddAccessRule($rule)
[IO.Directory]::SetAccessControl($path, $acl)
''',
          ],
          environment: {'ELARNI_TEST_DIRECTORY': private.path},
        );
        expect(expose.exitCode, 0, reason: expose.stderr.toString());
        final publicPath = '${private.path}/public-control';
        await expectLater(
          HeadlessServer.bind(publicPath, (_) async => {}, tcp: true),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'privacy error',
              'socket_directory_must_be_private',
            ),
          ),
        );
        expect(await File(publicPath).exists(), false);
        expect(await File(path).readAsString(), '{"unrelated":"preserve"}');
      }
    } finally {
      await temporary.delete(recursive: true);
    }
  });

  test(
    'the in-process Windows check accepts only a private control directory',
    () async {
      final temporary = await Directory.systemTemp.createTemp('rv-acl-');
      try {
        final private = '${temporary.path}/private';
        await (await HeadlessServer.bind(
          '$private/control',
          (_) async => {},
          tcp: true,
        )).close();
        expect(windowsPrivateDirectory(private), isTrue);
        // The temporary parent inherits access for administrators and SYSTEM.
        expect(windowsPrivateDirectory(temporary.path), isFalse);
        expect(windowsPrivateDirectory('${temporary.path}/missing'), isFalse);
        await File('$private/file').writeAsString('');
        expect(windowsPrivateDirectory('$private/file'), isFalse);
      } finally {
        await temporary.delete(recursive: true);
      }
    },
    skip: !Platform.isWindows,
  );

  // Another user who can write the directory could point a client at their port.
  for (final change in [
    'everyone',
    if (Platform.isWindows) 'inherited',
    if (Platform.isWindows) 'reparse',
  ]) {
    test(
      'a client refuses a control directory that is not private ($change)',
      () async {
        final temporary = await Directory.systemTemp.createTemp('rv-client-');
        final private = Directory('${temporary.path}/private');
        final path = '${private.path}/control';
        final server = await HeadlessServer.bind(
          path,
          (_) async => {},
          tcp: true,
        );
        var client = path;
        try {
          if (!Platform.isWindows) {
            await Process.run('chmod', ['755', private.path]);
          } else if (change == 'reparse') {
            // The client must not follow a junction to the real directory.
            final junction = await Link(
              '${temporary.path}/junction',
            ).create(private.path);
            client = '${junction.path}/control';
          } else {
            final expose = await Process.run(
              'powershell.exe',
              [
                '-NoProfile',
                '-NonInteractive',
                '-Command',
                r'''
$ErrorActionPreference = 'Stop'
$path = $env:ELARNI_TEST_DIRECTORY
$acl = [IO.Directory]::GetAccessControl($path)
if ($env:ELARNI_TEST_CHANGE -eq 'inherited') {
  $acl.SetAccessRuleProtection($false, $true)
} else {
  $everyone = [System.Security.Principal.SecurityIdentifier]::new('S-1-1-0')
  $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($everyone, 'Read', 'Allow'))
}
[IO.Directory]::SetAccessControl($path, $acl)
''',
              ],
              environment: {
                'ELARNI_TEST_DIRECTORY': private.path,
                'ELARNI_TEST_CHANGE': change,
              },
            );
            expect(expose.exitCode, 0, reason: expose.stderr.toString());
          }
          await expectLater(
            headlessClient(client, {'command': 'status'}),
            throwsA(
              isA<StateError>().having(
                (e) => e.message,
                'privacy error',
                'socket_directory_must_be_private',
              ),
            ),
          );
        } finally {
          await server.close();
          await temporary.delete(recursive: true);
        }
      },
    );
  }
}
