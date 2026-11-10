import 'dart:convert';
import 'dart:io';

import 'package:elarni/system_proxy.dart';
import 'package:flutter_test/flutter_test.dart';

// An OS setting that is either the user's own or a port Elarni pointed it at.
final class _FakeOS implements SystemProxy {
  ProxySettings current = {'user': 'pac'};
  final writes = <ProxySettings>[];
  Object? pointFailure;
  Object? readFailure;

  @override
  Future<ProxySettings> read() async {
    if (readFailure case final failure?) throw failure;
    return {...current};
  }

  @override
  Future<void> point(int port) async {
    // A half-applied change, as when one gsettings call of several fails.
    current = {'port': port};
    if (pointFailure case final failure?) throw failure;
  }

  @override
  Future<void> write(ProxySettings settings) async {
    writes.add(settings);
    current = {...settings};
  }

  @override
  bool pointsAt(ProxySettings settings, int port) => settings['port'] == port;
}

void main() {
  late Directory temporary;
  late File backup;
  late _FakeOS os;
  late SystemProxySession session;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('elarni-system-proxy-');
    backup = File('${temporary.path}/state/Elarni/system-proxy.json');
    os = _FakeOS();
    session = SystemProxySession(os, backup);
  });

  tearDown(() => temporary.delete(recursive: true));

  test('the setting it replaces is saved before it changes', () async {
    expect(await session.sync(10891), isNull);
    expect(os.current, {'port': 10891});
    expect(jsonDecode(await backup.readAsString()), {
      'port': 10891,
      'previous': {'user': 'pac'},
    });
    expect(await session.sync(10891), isNull);
    expect(os.writes, isEmpty, reason: 'an unchanged port is left alone');

    expect(await session.sync(null), isNull);
    expect(os.current, {'user': 'pac'});
    expect(await backup.exists(), isFalse);
  });

  test('a new port replaces the old one and keeps the user setting', () async {
    await session.sync(10891);
    await session.sync(20891);
    expect(os.current, {'port': 20891});
    await session.sync(null);
    expect(os.current, {'user': 'pac'});
  });

  test('a setting the user changed meanwhile stays theirs', () async {
    await session.sync(10891);
    os.current = {'user': 'manual'};
    await session.sync(null);
    expect(os.current, {'user': 'manual'});
    expect(os.writes, isEmpty);
    expect(await backup.exists(), isFalse);
  });

  test('a run that crashed is undone at the next start', () async {
    await session.sync(10891);
    final next = SystemProxySession(os, backup);
    expect(await next.recover(), isNull);
    expect(os.current, {'user': 'pac'});
    expect(await backup.exists(), isFalse);
    expect(await next.recover(), isNull, reason: 'nothing left to restore');
    expect(os.writes, hasLength(1));
  });

  test('a failed apply is undone and not retried every second', () async {
    os.pointFailure = const OSError('gsettings failed');
    final message = await session.sync(10891);
    expect(message, contains('127.0.0.1:10891'));
    expect(os.current, {'user': 'pac'});
    expect(await backup.exists(), isFalse);

    os.pointFailure = null;
    expect(await session.sync(10891), isNull);
    expect(os.current, {'user': 'pac'}, reason: 'the failed port waits');
    expect(await session.sync(null), isNull);
    expect(await session.sync(10891), isNull);
    expect(os.current, {'port': 10891}, reason: 'a new session tries again');
  });

  test('an unreadable setting keeps its backup for the next restore', () async {
    await session.sync(10891);
    os.readFailure = const OSError('gsettings failed');
    expect(await session.sync(null), contains('could not be restored'));
    expect(await backup.exists(), isTrue);

    os.readFailure = null;
    expect(await SystemProxySession(os, backup).recover(), isNull);
    expect(os.current, {'user': 'pac'});
  });

  test('a restore that keeps failing is reported once', () async {
    await backup.parent.create(recursive: true);
    await backup.writeAsString('not a backup');
    expect(await session.sync(10891), contains('could not be restored'));
    expect(await session.sync(10891), isNull, reason: 'the failed port waits');
    expect(os.current, {'user': 'pac'});

    await backup.delete();
    expect(await session.sync(null), isNull);
    expect(await session.sync(10891), isNull);
    expect(os.current, {'port': 10891}, reason: 'a new session tries again');
  });

  test('a restore that fails at disconnect is reported once', () async {
    await session.sync(10891);
    os.readFailure = const OSError('gsettings failed');
    expect(await session.sync(null), contains('could not be restored'));
    expect(await session.sync(null), isNull, reason: 'the next tick is quiet');
    expect(os.current, {'port': 10891});

    os.readFailure = null;
    expect(await session.sync(10891), isNull);
    expect(await session.sync(null), isNull);
    expect(os.current, {'user': 'pac'}, reason: 'the next session restores');
    expect(await backup.exists(), isFalse);
  });

  test('overlapping calls run in order', () async {
    final results = await Future.wait([
      session.sync(10891),
      session.sync(null),
      session.sync(20891),
    ]);
    expect(results, [null, null, null]);
    expect(os.current, {'port': 20891});
    expect((jsonDecode(await backup.readAsString()) as Map)['previous'], {
      'user': 'pac',
    });
  });

  group('Linux', () {
    late List<String> calls;
    late Map<String, String> gsettings;

    Future<ProcessResult> run(String command, List<String> args) async {
      calls.add([command, ...args].join(' '));
      if (command == 'gsettings' && args.first == 'get')
        return ProcessResult(
          0,
          0,
          '${gsettings['${args[1]} ${args[2]}']}\n',
          '',
        );
      if (command == 'gsettings') gsettings['${args[1]} ${args[2]}'] = args[3];
      if (command.startsWith('kreadconfig'))
        return ProcessResult(0, 0, args.last == 'ProxyType' ? '0\n' : '\n', '');
      return ProcessResult(0, 0, '', '');
    }

    setUp(() {
      calls = [];
      gsettings = {
        'org.gnome.system.proxy mode': "'auto'",
        'org.gnome.system.proxy ignore-hosts': "['localhost']",
        for (final kind in ['http', 'https', 'socks']) ...{
          'org.gnome.system.proxy.$kind host': "''",
          'org.gnome.system.proxy.$kind port': '0',
        },
      };
    });

    test('GNOME is pointed at the listener and put back as it was', () async {
      final linux = LinuxSystemProxy({
        'XDG_CURRENT_DESKTOP': 'ubuntu:GNOME',
      }, run: run);
      final before = await linux.read();
      expect(linux.pointsAt(before, 10891), isFalse);
      await linux.point(10891);
      expect(gsettings['org.gnome.system.proxy.http host'], "'127.0.0.1'");
      expect(gsettings['org.gnome.system.proxy.https port'], '10891');
      expect(gsettings['org.gnome.system.proxy.socks host'], "''");
      expect(
        gsettings['org.gnome.system.proxy ignore-hosts'],
        contains("'192.168.0.0/16'"),
      );
      expect(
        calls.last,
        "gsettings set org.gnome.system.proxy mode 'manual'",
        reason: 'the mode switches once the addresses are in place',
      );
      expect(linux.pointsAt(await linux.read(), 10891), isTrue);
      expect(calls.where((call) => call.contains('kioslaverc')), isEmpty);

      await linux.write(before);
      expect(await linux.read(), before);
    });

    test('KDE Plasma also gets kioslaverc and the reload signal', () async {
      final linux = LinuxSystemProxy({
        'XDG_CURRENT_DESKTOP': 'KDE',
        'KDE_SESSION_VERSION': '5',
      }, run: run);
      final before = await linux.read();
      expect((before['kde'] as Map)['ProxyType'], '0');
      calls.clear();
      await linux.point(10891);
      expect(
        calls,
        containsAllInOrder([
          'kwriteconfig5 --file kioslaverc --group Proxy Settings --key httpProxy http://127.0.0.1:10891',
          'kwriteconfig5 --file kioslaverc --group Proxy Settings --key ProxyType 1',
          'dbus-send --type=signal /KIO/Scheduler org.kde.KIO.Scheduler.reparseSlaveConfiguration string:',
        ]),
      );
      calls.clear();
      await linux.write(before);
      expect(
        calls,
        contains(
          'kwriteconfig5 --file kioslaverc --group Proxy Settings --key ProxyType 0',
        ),
      );
    });

    test('a failing command is an error, not a silent success', () async {
      final linux = LinuxSystemProxy(
        const {},
        run: (command, args) async => ProcessResult(0, 1, '', 'no schema'),
      );
      await expectLater(linux.point(10891), throwsA(isA<OSError>()));
    });
  });
}
