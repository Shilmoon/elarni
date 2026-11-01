import 'dart:convert';
import 'dart:io';

import '../lib/headless.dart';

const usage = '''Elarni headless controls (Linux, macOS, Windows)
  elarni-cli [--socket PATH] daemon [--core PATH] [--domain PATH]
      [--keyring-password-file PATH]            # Linux private keyring
  elarni-cli [--socket PATH] daemon --app PATH # macOS/Windows app executable
  elarni-cli [--socket PATH] status | profiles | connect | disconnect
  elarni-cli [--socket PATH] import FILE|-     # profile or subscription URL
  elarni-cli [--socket PATH] select ID|NAME
  elarni-cli [--socket PATH] probe ID|NAME [CHECK_URL]
  elarni-cli [--socket PATH] refresh SUBSCRIPTION_ID [CHALLENGE_TOKEN]
  elarni-cli [--socket PATH] failover PRIMARY BACKUP [TARGETS_JSON_FILE]
  elarni-cli [--socket PATH] settings [JSON_FILE|-]
  elarni-cli [--socket PATH] commands
  elarni-cli [--socket PATH] call METHOD [JSON_FILE|-]
  elarni-cli [--socket PATH] shutdown       # standalone daemon only

Inputs containing credentials should use a private file or stdin, not arguments.
Commands control the running GUI or a standalone daemon using the same catalog.
Use "commands" for all methods; see docs/HEADLESS.md for arguments and examples.
''';

Future<String> content(String path) async {
  final bytes = <int>[];
  await for (final chunk in path == '-' ? stdin : File(path).openRead()) {
    if (bytes.length + chunk.length > 12 * 1024 * 1024)
      throw const FormatException('input_too_large');
    bytes.addAll(chunk);
  }
  return utf8.decode(bytes);
}

Future<void> main(List<String> arguments) async {
  var daemon = false;
  try {
    final args = [...arguments];
    String option(String name, String fallback) {
      final index = args.indexOf(name);
      if (index < 0) return fallback;
      if (index + 1 == args.length)
        throw const FormatException('missing_option_value');
      final value = args[index + 1];
      args.removeRange(index, index + 2);
      return value;
    }

    if (args.isEmpty || args.contains('--help') || args.contains('-h')) {
      stdout.write(usage);
      return;
    }
    // The default path can throw without HOME/LOCALAPPDATA; --socket must not need it.
    final socket = args.contains('--socket')
        ? option('--socket', '')
        : headlessSocketPath;
    if (args.isEmpty) throw const FormatException('expected_command');
    final command = args.removeAt(0);
    if (command == 'daemon') {
      var bundle = File(Platform.resolvedExecutable).parent.path;
      if (Platform.isMacOS &&
          bundle.endsWith('/ElarniCLI.app/Contents/MacOS')) {
        bundle = Directory('$bundle/../../../../MacOS').absolute.path;
      }
      if (Platform.isMacOS || Platform.isWindows) {
        final app = option(
          '--app',
          Platform.isMacOS ? '$bundle/Elarni' : '$bundle/elarni.exe',
        );
        if (args.isNotEmpty) throw const FormatException('unexpected_argument');
        final process = await Process.start(
          File(app).absolute.path,
          [],
          mode: ProcessStartMode.inheritStdio,
          // Not the caller's directory: Windows searches it for DLLs and programs.
          workingDirectory: bundle,
          environment: {
            'ELARNI_HEADLESS': '1',
            'ELARNI_CONTROL_SOCKET': File(socket).absolute.path,
          },
        );
        final signals = [
          for (final signal in [
            ProcessSignal.sigint,
            if (!Platform.isWindows) ProcessSignal.sigterm,
          ])
            signal.watch().listen((_) async {
              // Windows Process.kill is TerminateProcess; ask the owner to clean up.
              try {
                await headlessClient(socket, {
                  'command': 'shutdown',
                  'ownerPid': process.pid,
                });
              } catch (_) {
                if (!Platform.isWindows) process.kill(signal);
              }
            }),
        ];
        try {
          exitCode = await process.exitCode;
        } finally {
          for (final signal in signals) {
            await signal.cancel();
          }
        }
        return;
      }
      final core = option(
        '--core',
        '$bundle/elarni-core${Platform.isWindows ? '.exe' : ''}',
      );
      final domain = option(
        '--domain',
        Platform.isWindows
            ? '$bundle/elarni_domain.dll'
            : '$bundle/lib/libelarni_domain.so',
      );
      final password = option('--keyring-password-file', '');
      if (args.isNotEmpty) throw const FormatException('unexpected_argument');
      daemon = true;
      await runHeadless(
        socketPath: socket,
        corePath: core,
        domainPath: domain,
        keyringPasswordFile: password.isEmpty ? null : password,
      );
      return;
    }
    final request = <String, Object?>{'command': command};
    switch (command) {
      case 'status':
      case 'profiles':
      case 'connect':
      case 'disconnect':
      case 'commands':
      case 'shutdown':
        if (args.isNotEmpty) throw const FormatException('unexpected_argument');
      case 'call':
        if (args.isEmpty || args.length > 2)
          throw const FormatException('expected_method_and_optional_json_file');
        request['method'] = args.first;
        if (args.length == 2)
          request['arguments'] = headlessObject(
            jsonDecode(await content(args[1])),
          );
      case 'import':
        if (args.length != 1)
          throw const FormatException('expected_input_file');
        request['content'] = await content(args.single);
      case 'select':
        if (args.length != 1)
          throw const FormatException('expected_identifier');
        request['node'] = args.single;
      case 'refresh':
        if (args.isEmpty || args.length > 2)
          throw const FormatException(
            'expected_subscription_and_optional_challenge',
          );
        request['id'] = args.first;
        if (args.length == 2) request['challenge'] = args[1];
      case 'probe':
        if (args.isEmpty || args.length > 2)
          throw const FormatException('expected_profile');
        request['node'] = args.first;
        if (args.length == 2) request['url'] = args[1];
      case 'settings':
        if (args.length > 1) throw const FormatException('unexpected_argument');
        if (args.isNotEmpty)
          request['settings'] = headlessObject(
            jsonDecode(await content(args.single)),
          );
      case 'failover':
        if (args.length < 2 || args.length > 3)
          throw const FormatException('expected_primary_and_backup');
        request['primary'] = args[0];
        request['fallback'] = args[1];
        if (args.length == 3)
          request['targets'] = jsonDecode(await content(args[2]));
      default:
        throw const FormatException('unknown_command');
    }
    final response = await headlessClient(socket, request);
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(response));
    if (response['success'] != true) exitCode = 1;
  } catch (error) {
    stderr.writeln(
      jsonEncode({
        'success': false,
        'error': error is FormatException
            ? error.message
            : error is SocketException
            ? 'daemon_unavailable'
            : 'operation_failed',
      }),
    );
    exitCode = 1;
  } finally {
    // The core, catalog lease and keyring are gone, after a stop or a failure;
    // a reply timer left by an interrupted request must not hold the service for minutes.
    if (daemon) {
      await stderr.flush();
      exit(exitCode);
    }
  }
}
