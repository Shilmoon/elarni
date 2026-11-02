import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'desktop_catalog.dart';
import 'platform_services.dart';
import 'windows_private_directory.dart';

const headlessMessageLimit = 16 * 1024 * 1024;

/// System PowerShell; a bare name also searches the app and current directories.
String get windowsPowerShell =>
    '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}'
    r'\System32\WindowsPowerShell\v1.0\powershell.exe';

// USER is caller-controlled and survives `su`; the effective UID decides.
bool get _linuxRoot {
  if (!Platform.isLinux) return false;
  try {
    final uid = File('/proc/self/status')
        .readAsLinesSync()
        .firstWhere((line) => line.startsWith('Uid:'))
        .split(RegExp(r'\s+'));
    return uid[2] == '0';
  } on Object {
    return false;
  }
}

String get headlessSocketPath =>
    headlessSocketPathFor(Platform.environment, linuxRoot: _linuxRoot);

/// The default endpoint for [env]; the GUI, the daemon and the CLI all use it.
String headlessSocketPathFor(
  Map<String, String> env, {
  required bool linuxRoot,
}) {
  if (env['ELARNI_CONTROL_SOCKET'] case final String value
      when value.isNotEmpty)
    return value;
  if (Platform.isWindows) {
    final base = env['LOCALAPPDATA'];
    if (base == null) throw StateError('local_app_data_unavailable');
    return '$base/Elarni/control/endpoint.json';
  }
  // System units without User= get no HOME; neither Linux default below needs it.
  if (!Platform.isMacOS) {
    if (linuxRoot) return '/run/elarni/control.sock';
    if (env['XDG_RUNTIME_DIR'] case final String runtime)
      return '$runtime/elarni/control.sock';
  }
  final home = env['HOME'];
  if (home == null) throw StateError('home_unavailable');
  if (Platform.isMacOS) {
    // The GUI is sandboxed; the standalone CLI must use its container too.
    final container = home.endsWith('/Library/Containers/com.elarni.mac/Data')
        ? home
        : '$home/Library/Containers/com.elarni.mac/Data';
    return '$container/.elarni/control.sock';
  }
  return '$home/.local/state/Elarni/control/control.sock';
}

Future<String> readHeadlessMessage(Stream<List<int>> stream) async {
  final lines = _HeadlessLines(stream);
  try {
    return await lines.next(headlessMessageLimit);
  } finally {
    unawaited(lines.cancel());
  }
}

// Reads newline-framed lines and keeps bytes that follow one for the next.
final class _HeadlessLines {
  _HeadlessLines(Stream<List<int>> stream) : _chunks = StreamIterator(stream);
  final StreamIterator<List<int>> _chunks;
  List<int> _rest = const [];

  Future<String> next(int limit) async {
    final bytes = BytesBuilder(copy: false);
    for (;;) {
      var chunk = _rest;
      _rest = const [];
      if (chunk.isEmpty) {
        if (!await _chunks.moveNext())
          throw const FormatException('incomplete_message');
        chunk = _chunks.current;
      }
      final end = chunk.indexOf(10);
      final part = end < 0 ? chunk : chunk.sublist(0, end);
      if (bytes.length + part.length > limit)
        throw const FormatException('message_too_large');
      bytes.add(part);
      if (end >= 0) {
        _rest = chunk.sublist(end + 1);
        return utf8.decode(bytes.takeBytes());
      }
    }
  }

  Future<void> cancel() => _chunks.cancel();
}

// Under the exclusive lock, unparsable content is an endpoint whose owner was
// interrupted while writing; valid JSON of another shape belongs to someone else.
bool _ownedEndpoint(String content) {
  final Object? value;
  try {
    value = jsonDecode(content);
  } on FormatException {
    return true;
  }
  return value is Map && value['elarniControl'] == 1;
}

CatalogMap headlessObject(Object? value) {
  if (value is! Map<String, dynamic>)
    throw const FormatException('expected_json_object');
  return value.cast<String, Object?>();
}

Future<CatalogMap> headlessClient(String path, CatalogMap request) async {
  String? token;
  InternetAddress address;
  var port = 0;
  final type = await FileSystemEntity.type(path, followLinks: false);
  if (type == FileSystemEntityType.notFound)
    throw const SocketException('daemon_unavailable');
  if (type == FileSystemEntityType.file) {
    await _privateDirectory(File(path).parent);
    final file = File(path);
    if (await file.length() > 1024)
      throw const FormatException('invalid_endpoint');
    final CatalogMap endpoint;
    try {
      endpoint = headlessObject(jsonDecode(await file.readAsString()));
    } on FormatException {
      throw const FormatException('invalid_endpoint');
    }
    if (endpoint['elarniControl'] != 1 ||
        endpoint['port'] is! int ||
        (endpoint['port']! as int) < 1 ||
        (endpoint['port']! as int) > 65535 ||
        endpoint['token'] is! String ||
        (endpoint['token']! as String).length != 64)
      throw const FormatException('invalid_endpoint');
    if (Platform.isWindows && !await _endpointOwnerAlive('$path.lock'))
      throw const SocketException('daemon_unavailable');
    token = endpoint['token']! as String;
    port = endpoint['port']! as int;
    address = InternetAddress.loopbackIPv4;
  } else {
    if (Platform.isWindows || type != FileSystemEntityType.unixDomainSock)
      throw const FormatException('invalid_endpoint');
    address = InternetAddress(path, type: InternetAddressType.unix);
  }
  // The token line comes first so the server authenticates before buffering.
  final encoded = utf8.encode(
    '${token != null ? '$token\n' : ''}${jsonEncode(request)}\n',
  );
  if (encoded.length > headlessMessageLimit)
    throw const FormatException('message_too_large');
  final socket = await Socket.connect(
    address,
    port,
    timeout: const Duration(seconds: 5),
  );
  try {
    socket.add(encoded);
    await socket.flush();
    return headlessObject(
      jsonDecode(
        // Above the core's longest operation (a 370 s VPN start).
        await readHeadlessMessage(socket).timeout(const Duration(minutes: 7)),
      ),
    );
  } finally {
    socket.destroy();
  }
}

// A crashed owner leaves its endpoint behind, and another local user may then
// bind its port. A live owner still holds the lock it took before publishing.
// Windows locks are per handle; POSIX ones are per process and would pass here.
Future<bool> _endpointOwnerAlive(String lockPath) async {
  if (await FileSystemEntity.type(lockPath, followLinks: false) !=
      FileSystemEntityType.file)
    return false;
  final lock = await File(lockPath).open(mode: FileMode.append);
  try {
    await lock.lock(FileLock.exclusive);
    return false;
  } on FileSystemException {
    return true;
  } finally {
    await lock.close();
  }
}

Future<void> _privateDirectory(Directory directory) async {
  final type = await FileSystemEntity.type(directory.path, followLinks: false);
  final created = type == FileSystemEntityType.notFound;
  if (!created && type != FileSystemEntityType.directory)
    throw StateError('socket_directory_must_be_private');
  if (created) await directory.create(recursive: true);
  if (Platform.isWindows) {
    // PowerShell takes up to seconds to start on slow hosts, once per CLI command;
    // it remains for the first-run repair and for the rejection of other ACLs.
    if (!created && windowsPrivateDirectory(directory.absolute.path)) return;
    // Pass the path as data, never interpolate it into a PowerShell program.
    final process = await Process.start(
      windowsPowerShell,
      [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        r'''
$ErrorActionPreference = 'Stop'
$path = $env:ELARNI_CONTROL_DIRECTORY
$sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
if ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'reparse_point' }
# An interrupted first run leaves this directory empty and still inheriting access.
if ($env:ELARNI_CONTROL_CREATED -eq '1' -or @(Get-ChildItem -LiteralPath $path -Force).Count -eq 0) {
  $acl = New-Object System.Security.AccessControl.DirectorySecurity
  $acl.SetOwner($sid)
  $acl.SetAccessRuleProtection($true, $false)
  $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
  $acl.AddAccessRule($rule)
  [IO.Directory]::SetAccessControl($path, $acl)
}
$acl = [IO.Directory]::GetAccessControl($path)
if ($acl.GetOwner([System.Security.Principal.SecurityIdentifier]) -ne $sid -or !$acl.AreAccessRulesProtected) { throw 'private_directory_required' }
foreach ($rule in $acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])) {
  if ($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference -ne $sid) { throw 'private_directory_required' }
}
''',
      ],
      environment: {
        'ELARNI_CONTROL_DIRECTORY': directory.absolute.path,
        'ELARNI_CONTROL_CREATED': created ? '1' : '0',
      },
    );
    unawaited(process.stdout.drain<void>());
    unawaited(process.stderr.drain<void>());
    final code = await process.exitCode.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        process.kill();
        return -1;
      },
    );
    if (code != 0) throw StateError('socket_directory_must_be_private');
  } else {
    // As on Windows, an interrupted first run leaves an empty directory to repair.
    if ((created || directory.listSync().isEmpty) &&
        (await Process.run('chmod', ['700', directory.path])).exitCode != 0)
      throw StateError('socket_permissions_failed');
    if ((directory.statSync().mode & 0x3f) != 0)
      throw StateError('socket_directory_must_be_private');
    // Root must not serve from a directory another user can swap entries in.
    if (_linuxRoot) {
      final owner = await Process.run('stat', ['-c', '%u', directory.path]);
      if (owner.exitCode != 0 || (owner.stdout as String).trim() != '0')
        throw StateError('socket_directory_must_be_private');
    }
  }
}

final class HeadlessServer {
  HeadlessServer._(this.path, this._lock, this._server, this._token);
  final String path;
  final RandomAccessFile _lock;
  final ServerSocket _server;
  final String? _token;
  final _clients = <Socket>{};
  static final _owned = <String>{};
  bool _closed = false;

  static Future<HeadlessServer> bind(
    String path,
    Future<CatalogMap> Function(CatalogMap) request, {
    void Function()? onShutdown,
    bool? tcp,
  }) async {
    final file = File(path).absolute;
    await _privateDirectory(file.parent);
    path =
        '${await file.parent.resolveSymbolicLinks()}${Platform.pathSeparator}${file.uri.pathSegments.last}';
    if (!_owned.add(path)) throw StateError('control_already_running');
    RandomAccessFile? lock;
    ServerSocket? server;
    var locked = false;
    var published = false;
    try {
      final lockType = await FileSystemEntity.type(
        '$path.lock',
        followLinks: false,
      );
      if (lockType != FileSystemEntityType.notFound &&
          lockType != FileSystemEntityType.file)
        throw StateError('socket_path_occupied');
      lock = await File('$path.lock').open(mode: FileMode.append);
      // A client checking whether an earlier owner is alive holds it briefly.
      for (var attempt = 1; ; attempt++) {
        try {
          await lock.lock(FileLock.exclusive);
          break;
        } on FileSystemException {
          if (attempt == 10) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
      locked = true;
      final useTcp = tcp ?? Platform.isWindows;
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type != FileSystemEntityType.notFound) {
        if (type !=
            (useTcp
                ? FileSystemEntityType.file
                : FileSystemEntityType.unixDomainSock))
          throw StateError('socket_path_occupied');
        if (useTcp) {
          final old = File(path);
          if (await old.length() > 1024 ||
              !_ownedEndpoint(await old.readAsString()))
            throw StateError('socket_path_occupied');
        }
        await File(path).delete();
      }
      server = await ServerSocket.bind(
        useTcp
            ? InternetAddress.loopbackIPv4
            : InternetAddress(path, type: InternetAddressType.unix),
        0,
      );
      final random = Random.secure();
      final token = useTcp
          ? List.generate(
              32,
              (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
            ).join()
          : null;
      if (useTcp) {
        // Replace atomically so no reader or later owner sees a partial file.
        final staged = File('$path.tmp');
        await staged.writeAsString(
          jsonEncode({'elarniControl': 1, 'port': server.port, 'token': token}),
          flush: true,
        );
        await staged.rename(path);
      }
      published = true;
      if (!Platform.isWindows &&
          (await Process.run('chmod', ['600', path])).exitCode != 0)
        throw StateError('socket_permissions_failed');
      final control = HeadlessServer._(path, lock, server, token);
      server.listen((socket) => control._serve(socket, request, onShutdown));
      return control;
    } catch (_) {
      await server?.close();
      if (locked && published) await File(path).delete();
      await lock?.close();
      _owned.remove(path);
      rethrow;
    }
  }

  Future<void> _serve(
    Socket socket,
    Future<CatalogMap> Function(CatalogMap) request,
    void Function()? onShutdown,
  ) async {
    if (_closed || _clients.length >= 16) {
      socket.destroy();
      return;
    }
    _clients.add(socket);
    final lines = _HeadlessLines(socket);
    try {
      // An unauthenticated peer gets a short line and a short wait, not 16 MiB.
      if (_token case final token?) {
        final line = await lines.next(128).timeout(const Duration(seconds: 5));
        // Compare every character so response timing does not reveal a prefix.
        var diff = line.length ^ token.length;
        for (var i = 0; i < token.length; i++) {
          diff |=
              token.codeUnitAt(i) ^ (i < line.length ? line.codeUnitAt(i) : 0);
        }
        if (diff != 0) throw PlatformException(code: 'unauthorized');
      }
      final input = headlessObject(
        jsonDecode(
          await lines
              .next(headlessMessageLimit)
              .timeout(const Duration(seconds: 10)),
        ),
      );
      final shutdown = input['command'] == 'shutdown';
      if (shutdown && input['ownerPid'] != null && input['ownerPid'] != pid)
        throw PlatformException(code: 'different_daemon_owner');
      if (shutdown && onShutdown == null)
        throw PlatformException(code: 'shutdown_requires_daemon');
      final result = shutdown
          ? <String, Object?>{'stopping': true}
          : await request(input);
      final response = utf8.encode(
        '${jsonEncode({'success': true, 'data': result})}\n',
      );
      if (response.length > headlessMessageLimit)
        throw const FormatException('message_too_large');
      socket.add(response);
      await socket.flush();
      if (shutdown) onShutdown!();
    } catch (error) {
      try {
        final details = error is PlatformException && error.details is Map
            ? catalogMap(error.details)
            : <String, Object?>{};
        final diagnostics = catalogMap(details['diagnostics'] ?? {});
        socket.writeln(
          jsonEncode({
            'success': false,
            'error': error is PlatformException
                ? error.code
                : error is FormatException
                ? error.message
                : 'request_failed',
            if (diagnostics.isNotEmpty)
              'diagnostics': {
                for (final key in [
                  'stage',
                  'code',
                  'httpStatus',
                  'cleanupState',
                ])
                  if (diagnostics.containsKey(key)) key: diagnostics[key],
              },
          }),
        );
        await socket.flush();
      } on Object {
        /* The caller may have disconnected. */
      }
    } finally {
      _clients.remove(socket);
      socket.destroy();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _server.close();
      for (final socket in _clients) {
        socket.destroy();
      }
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.notFound)
        await File(path).delete();
    } finally {
      await _lock.close();
      _owned.remove(path);
    }
  }
}
