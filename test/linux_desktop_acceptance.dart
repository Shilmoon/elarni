// Built explicitly for native desktop acceptance; not a widget test.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../lib/desktop_proxy.dart';

const desktop = MethodChannel('com.elarni/desktop');
const platform = MethodChannel('com.elarni/linux');
late Directory fixture;
final passed = <String>[];
final events = <String>[];

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

File file(String name) => File('${fixture.path}/$name');
void stage(String name) => file('stage').writeAsStringSync(name);
Future<void> until(bool Function() ready) async {
  for (var i = 0; i < 200; i++) {
    if (ready()) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  throw StateError('Desktop event timed out');
}

Future<Object?> native(String method, [Map<String, Object?> args = const {}]) =>
    platform.invokeMethod<Object?>(method, args);

Future<Map<String, Object?>> core(
  String method,
  Map<String, Object?> payload,
) async {
  final binary = '${File(Platform.resolvedExecutable).parent.path}/elarni-core';
  final process = await Process.start(binary, const []);
  final errorDrain = process.stderr.drain<void>();
  process.stdin.writeln(
    jsonEncode({'apiVersion': 1, 'method': method, 'payload': payload}),
  );
  final line = await process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .first
      .timeout(const Duration(seconds: 20));
  await process.stdin.close();
  await process.exitCode.timeout(const Duration(seconds: 5));
  await errorDrain;
  final reply = jsonDecode(line) as Map;
  check(reply['success'] == true, '$method failed: ${reply['error']}');
  return Map<String, Object?>.from(reply['data'] as Map);
}

Future<void> exercise() async {
  desktop.setMethodCallHandler((call) async {
    events.add('${call.method}:${call.arguments}');
  });
  platform.setMethodCallHandler((call) async {
    events.add('${call.method}:${call.arguments}');
  });
  check(
    await desktop.invokeMethod<String>('getPreferences') == '{}',
    'Preferences were not isolated',
  );
  await desktop.invokeMethod<void>('setPreferences', {
    'json': '{"theme":"dark","fixture":true}',
  });
  check(
    jsonDecode(
          (await desktop.invokeMethod<String>('getPreferences'))!,
        )['fixture'] ==
        true,
    'Preference round trip',
  );
  try {
    await desktop.invokeMethod<void>('setPreferences', {'json': 'x' * 32769});
    throw StateError('Oversized preferences accepted');
  } on PlatformException catch (error) {
    check(error.code == 'preferences_failed', 'Preference error contract');
  }
  passed.add('preferences');
  final apps = await desktop.invokeMethod<List<Object?>>('routingApplications');
  check(
    apps != null &&
        apps.isNotEmpty &&
        apps.every(
          (entry) => (entry! as Map)['process'].toString().startsWith('/'),
        ),
    'Linux executable inventory',
  );
  passed.add('applications');
  final info = (await native('systemInfo'))! as Map;
  check(
    info['os'] == 'Linux' &&
        info['architecture'] == 'x86_64' &&
        (info['physicalMemoryBytes'] as int) > 0,
    'System information',
  );
  check(
    ((await native('setLaunchAtLogin', {'enabled': true}))!
            as Map)['launchAtLoginStatus'] ==
        'enabled',
    'Autostart registration',
  );
  final autostart = File(
    '${Platform.environment['XDG_CONFIG_HOME']}/autostart/com.elarni.Elarni.desktop',
  );
  check(
    autostart.readAsStringSync().contains('Exec='),
    'Autostart file missing',
  );
  stage('validate-autostart');
  await until(() => file('autostart-validated').existsSync());
  check(
    ((await native('setLaunchAtLogin', {'enabled': false}))!
                as Map)['launchAtLoginStatus'] ==
            'notRegistered' &&
        !autostart.existsSync(),
    'Autostart removal',
  );
  passed.add('system-info-autostart');
  final routes = (await native('routeTable'))! as Map;
  check(
    (routes['table'] as String).isNotEmpty && (routes['timestamp'] as num) > 0,
    'Route diagnostics',
  );
  passed.add('routes');
  final initial = ((await native('takeLinks'))! as Map)['links']! as List;
  check(initial.contains('elarni://fixture-first'), 'Initial client link');
  events.clear();
  stage('second-link');
  await until(() => events.any((event) => event.startsWith('linksAvailable:')));
  check(
    (((await native('takeLinks'))! as Map)['links']! as List).contains(
      'elarni://fixture-second',
    ),
    'Single-instance client link',
  );
  check(
    (((await native('takeLinks'))! as Map)['links']! as List).isEmpty,
    'Links were not drained',
  );
  passed.add('single-instance-links');
  stage('pick-file');
  check(
    ((await native('pickFile'))! as Map)['path'] == file('import.json').path,
    'Native file picker',
  );
  stage('pick-app');
  final picked = (await desktop.invokeMethod<List<Object?>>(
    'pickRoutingApplications',
  ))!;
  check(
    picked.length == 1 &&
        (picked.single! as Map)['process'] == file('Fixture App').path,
    'Native executable picker',
  );
  stage('cancel-picker');
  check(
    ((await native('pickFile'))! as Map).isEmpty,
    'File picker cancellation',
  );
  stage('save-backup');
  await native('saveBackup', {'content': '{"fixture":"backup"}'});
  check(
    file('saved-backup.json').readAsStringSync() == '{"fixture":"backup"}',
    'Backup publication',
  );
  stage('save-evidence');
  await native('saveEvidence', {'content': '{"fixture":"diagnostics"}'});
  check(
    file('saved-diagnostics.json').readAsStringSync() ==
        '{"fixture":"diagnostics"}',
    'Diagnostic publication',
  );
  passed.add('native-pickers-backup-diagnostics');
  for (final url in [
    'https://fixture.elarni.test/\nopen',
    'https://fixture.elarni.test/${'x' * 16384}',
    'file:///tmp/elarni-test',
  ]) {
    try {
      await native('openURL', {'url': url});
      throw StateError('Invalid URL reached the desktop');
    } on PlatformException catch (error) {
      check(error.code == 'invalid_url', 'URL validation error contract');
    }
  }
  await native('openURL', {'url': 'https://fixture.elarni.test/open'});
  await until(() => file('opened-url').existsSync());
  check(
    file('opened-url').readAsStringSync().trim() ==
        'https://fixture.elarni.test/open',
    'URL handoff',
  );
  passed.add('url-handoff');
  check(
    await desktop.invokeMethod<bool>('requestNotifications') == true,
    'Notification request',
  );
  await desktop.invokeMethod<void>('showExpiryReminder', {'count': 2});
  await until(() => file('notification').existsSync());
  check(
    file(
      'notification',
    ).readAsStringSync().contains('2 subscriptions expire soon'),
    'Native notification',
  );
  await desktop.invokeMethod<void>('setStatus', {
    'state': 'disconnected',
    'canConnect': true,
    'canDisconnect': false,
  });
  stage('tray-connect');
  await until(() => events.contains('action:connect'));
  passed.add('notifications-tray');
  stage('camera-start');
  Uint8List? frame;
  for (var i = 0; i < 100 && frame == null; i++) {
    frame = await platform.invokeMethod<Uint8List>('cameraFrame', const {});
    if (frame == null)
      await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  check(frame != null, 'Camera frame unavailable');
  file('camera-frame.jpg').writeAsBytesSync(frame!);
  final decoded = await core('decodeQRImage', {'image': base64Encode(frame)});
  check(
    decoded['text'] == 'elarni://camera-fixture',
    'Camera QR frame did not decode',
  );
  await native('cameraStop');
  stage('camera-removed');
  await until(() => file('camera-removed').existsSync());
  try {
    await native('cameraFrame');
    throw StateError('Missing camera produced a synthetic frame');
  } on PlatformException catch (error) {
    check(error.code == 'camera_unavailable', 'Missing camera error contract');
  }
  stage('sleep-events');
  await until(
    () =>
        events.contains('sleepChanged:true') &&
        events.contains('sleepChanged:false'),
  );
  passed.add('camera-and-sleep');
  // Exercise the same bundled FFI and encrypted helper storage as the app.
  final bundle = File(Platform.resolvedExecutable).parent;
  final storage = Directory('${fixture.path}/controller-data')..createSync();
  DesktopProxy controller() => DesktopProxy(
    corePath: '${bundle.path}/elarni-core',
    domainPath: '${bundle.path}/lib/libelarni_domain.so',
    startProcess: (path) => Process.start(
      path,
      const [],
      environment: {'XDG_DATA_HOME': storage.path},
    ),
    platformIO: (method, payload) async => <String, Object?>{},
  );
  var proxy = controller();
  try {
    final imported = await proxy.control.importClientProfiles(
      content: 'socks://127.0.0.1:18090#Linux%20fixture',
    );
    check(
      imported.snapshot.subscriptions.single.nodes.single.name ==
          'Linux fixture',
      'Controller import',
    );
    await proxy.dispose();
    proxy = controller();
    final restored = await proxy.control.subscriptions();
    check(
      restored.subscriptions.single.nodes.single.name == 'Linux fixture',
      'Controller encrypted relaunch',
    );
  } finally {
    await proxy.dispose();
  }
  passed.add('controller-import-persistence');
  stage('done');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final path = Platform.environment['ELARNI_DESKTOP_FIXTURE'];
  if (!Platform.isLinux || path == null) exit(2);
  fixture = Directory(path);
  runApp(
    const MaterialApp(
      home: Scaffold(body: Center(child: Text('Elarni desktop acceptance'))),
    ),
  );
  await WidgetsBinding.instance.endOfFrame;
  try {
    await exercise();
    file('result.json').writeAsStringSync(
      jsonEncode({'passed': passed, 'failed': 0, 'skipped': 0}),
    );
    exit(0);
  } on Object catch (error, stack) {
    file('result.json').writeAsStringSync(
      jsonEncode({
        'passed': passed,
        'failed': 1,
        'error': error.toString(),
        'stack': stack.toString(),
      }),
    );
    exit(1);
  }
}
