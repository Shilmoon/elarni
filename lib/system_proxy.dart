import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef ProxySettings = Map<String, Object?>;

/// The desktop's own proxy setting, which System proxy mode points at the
/// core's loopback HTTP listener.
abstract interface class SystemProxy {
  Future<ProxySettings> read();
  Future<void> point(int port);
  Future<void> write(ProxySettings settings);
  bool pointsAt(ProxySettings settings, int port);
}

// Local names and private ranges stay direct, as they would without a proxy.
const _bypass = [
  'localhost',
  '127.0.0.0/8',
  '::1',
  '10.0.0.0/8',
  '172.16.0.0/12',
  '192.168.0.0/16',
];

/// Points the OS proxy at the listener while Elarni is connected and puts the
/// user's own setting back afterwards, also after a crash: the setting it
/// replaced is saved before it is changed.
final class SystemProxySession {
  SystemProxySession(this._os, this._backup);
  final SystemProxy _os;
  final File _backup;
  // No port is negative, and null is a target too: the user's own setting.
  static const _none = -1;
  int? _port, _failed = _none;
  Future<String?> _queue = Future.value();

  /// Moves the OS setting to [port], or back to the user's when null. Returns
  /// an error message when it could not; a target that failed is tried again
  /// only after the target changed.
  Future<String?> sync(int? port) => _queue = _queue.then((_) => _sync(port));

  /// Restores a setting that a crashed run left pointing at its listener.
  Future<String?> recover() => _queue = _queue.then((_) async {
    try {
      await _restore();
      return null;
    } on Object {
      return _restoreFailed;
    }
  });

  static const _restoreFailed =
      'The system proxy setting could not be restored. Check it in your system network settings.';

  Future<String?> _sync(int? port) async {
    // Only the session that failed waits; the next one tries again.
    if (port != _failed) _failed = _none;
    if (port == _port || port == _failed) return null;
    try {
      await _restore();
    } on Object {
      // The sync runs every second and would report this each time.
      _failed = port;
      return _restoreFailed;
    }
    _port = null;
    if (port == null) return null;
    ProxySettings? previous;
    try {
      previous = await _os.read();
      await _backup.parent.create(recursive: true);
      final pending = File('${_backup.path}.tmp');
      await pending.writeAsString(
        jsonEncode({'port': port, 'previous': previous}),
        flush: true,
      );
      await pending.rename(_backup.path);
      await _os.point(port);
      _port = port;
      return null;
    } on Object {
      _failed = port;
      // A half-applied setting is undone whether or not it points here yet.
      try {
        if (previous != null) await _os.write(previous);
        if (await _backup.exists()) await _backup.delete();
      } on Object {
        /* The backup stays for the next restore. */
      }
      return 'The system proxy could not be set. Apps can still use the HTTP proxy at 127.0.0.1:$port.';
    }
  }

  Future<void> _restore() async {
    if (!await _backup.exists()) return;
    final saved = jsonDecode(await _backup.readAsString()) as Map;
    // A setting the user changed since stays theirs.
    if (_os.pointsAt(await _os.read(), saved['port'] as int))
      await _os.write((saved['previous'] as Map).cast());
    await _backup.delete();
  }

  static SystemProxySession? forPlatform(Map<String, String> env) {
    if (Platform.isWindows) {
      final base = env['LOCALAPPDATA'];
      return base == null
          ? null
          : SystemProxySession(
              WindowsSystemProxy(),
              File('$base/Elarni/system-proxy.json'),
            );
    }
    if (!Platform.isLinux) return null;
    final state =
        env['XDG_STATE_HOME'] ??
        (env['HOME'] == null ? null : '${env['HOME']}/.local/state');
    return state == null
        ? null
        : SystemProxySession(
            LinuxSystemProxy(env),
            File('$state/Elarni/system-proxy.json'),
          );
  }
}

// WinINet's per-connection options (WinInet.h).
const _perConnectionOption = 75,
    _settingsChanged = 39,
    _refresh = 37,
    _flags = 1,
    _server = 2,
    _bypassList = 3,
    _autoConfigURL = 4,
    _flagsUI = 10,
    _direct = 1,
    _proxy = 2;

final class _OptionValue extends Union {
  @Uint32()
  external int number;
  external Pointer<Utf16> text;
}

final class _Option extends Struct {
  @Uint32()
  external int option;
  external _OptionValue value;
}

final class _OptionList extends Struct {
  @Uint32()
  external int size;
  external Pointer<Utf16> connection;
  @Uint32()
  external int count;
  @Uint32()
  external int error;
  external Pointer<_Option> options;
}

/// The current user's WinINet setting, which browsers and most apps follow.
/// shortcut: the LAN setting only; dial-up and PPPoE entries keep their own,
/// add RasEnumEntries if users on those report it.
final class WindowsSystemProxy implements SystemProxy {
  // Not a KnownDLL, so name the System32 copy rather than search the app directory.
  late final _wininet = DynamicLibrary.open(
    '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}\\System32\\wininet.dll',
  );
  late final _query = _wininet
      .lookupFunction<
        Int32 Function(Pointer, Uint32, Pointer, Pointer<Uint32>),
        int Function(Pointer, int, Pointer, Pointer<Uint32>)
      >('InternetQueryOptionW');
  late final _set = _wininet
      .lookupFunction<
        Int32 Function(Pointer, Uint32, Pointer, Uint32),
        int Function(Pointer, int, Pointer, int)
      >('InternetSetOptionW');
  late final _globalFree = DynamicLibrary.open('kernel32.dll')
      .lookupFunction<Pointer Function(Pointer), Pointer Function(Pointer)>(
        'GlobalFree',
      );

  bool _call(
    Arena arena,
    List<(int, Object?)> values,
    bool Function(Pointer<_OptionList>) call,
  ) {
    final options = arena<_Option>(values.length);
    for (final (index, (option, value)) in values.indexed) {
      options[index].option = option;
      switch (value) {
        case int number:
          options[index].value.number = number;
        case String text:
          options[index].value.text = text.toNativeUtf16(allocator: arena);
        default:
          options[index].value.text = nullptr;
      }
    }
    final list = arena<_OptionList>();
    list.ref
      ..size = sizeOf<_OptionList>()
      ..connection = nullptr
      ..count = values.length
      ..error = 0
      ..options = options;
    return call(list);
  }

  ProxySettings? _readWith(int flags) => using((arena) {
    final options = <(int, Object?)>[
      (flags, 0),
      (_server, null),
      (_bypassList, null),
      (_autoConfigURL, null),
    ];
    ProxySettings? result;
    _call(arena, options, (list) {
      final size = arena<Uint32>()..value = sizeOf<_OptionList>();
      if (_query(nullptr, _perConnectionOption, list, size) == 0) return false;
      String? text(int index) {
        final value = list.ref.options[index].value.text;
        if (value == nullptr) return null;
        final string = value.toDartString();
        _globalFree(value);
        return string;
      }

      result = {
        'flags': list.ref.options[0].value.number,
        'server': text(1),
        'bypass': text(2),
        'autoConfigURL': text(3),
      };
      return true;
    });
    return result;
  });

  // Windows 7 and later report automatic detection only through FLAGS_UI.
  @override
  Future<ProxySettings> read() async =>
      _readWith(_flagsUI) ??
      _readWith(_flags) ??
      (throw const OSError('InternetQueryOptionW failed'));

  void _apply(List<(int, Object?)> values) {
    final applied = using(
      (arena) => _call(
        arena,
        values,
        (list) =>
            _set(nullptr, _perConnectionOption, list, sizeOf<_OptionList>()) !=
            0,
      ),
    );
    if (!applied) throw const OSError('InternetSetOptionW failed');
    // Running apps reread the setting only when told.
    _set(nullptr, _settingsChanged, nullptr, 0);
    _set(nullptr, _refresh, nullptr, 0);
  }

  @override
  Future<void> point(int port) async => _apply([
    (_flags, _direct | _proxy),
    (_server, '127.0.0.1:$port'),
    (
      _bypassList,
      'localhost;127.*;10.*;${[for (var i = 16; i < 32; i++) '172.$i.*'].join(';')};192.168.*;<local>',
    ),
  ]);

  // Windows restores the connection type through FLAGS, whichever flag read it.
  @override
  Future<void> write(ProxySettings settings) async => _apply([
    (_flags, settings['flags'] as int),
    (_server, settings['server']),
    (_bypassList, settings['bypass']),
    (_autoConfigURL, settings['autoConfigURL']),
  ]);

  @override
  bool pointsAt(ProxySettings settings, int port) =>
      (settings['flags'] as int) & _proxy != 0 &&
      settings['server'] == '127.0.0.1:$port';
}

/// GNOME's setting (also read by GTK apps, Chromium and Firefox elsewhere), and
/// on KDE Plasma also kioslaverc. shortcut: other desktops (XFCE, LXQt) have no
/// shared setting; their apps keep using 127.0.0.1:<port> by hand.
final class LinuxSystemProxy implements SystemProxy {
  LinuxSystemProxy(
    this._env, {
    Future<ProcessResult> Function(String, List<String>)? run,
  }) : _run = run ?? Process.run;
  final Map<String, String> _env;
  final Future<ProcessResult> Function(String, List<String>) _run;

  static final _gnome = [
    ('org.gnome.system.proxy', 'mode'),
    ('org.gnome.system.proxy', 'ignore-hosts'),
    for (final kind in ['http', 'https', 'socks']) ...[
      ('org.gnome.system.proxy.$kind', 'host'),
      ('org.gnome.system.proxy.$kind', 'port'),
    ],
  ];
  static const _kde = [
    'ProxyType',
    'httpProxy',
    'httpsProxy',
    'socksProxy',
    'NoProxyFor',
  ];

  bool get _plasma =>
      (_env['XDG_CURRENT_DESKTOP'] ?? '').toUpperCase().contains('KDE');
  String get _kdeVersion => _env['KDE_SESSION_VERSION'] == '5' ? '5' : '6';

  Future<String> _out(String command, List<String> args) async {
    final result = await _run(command, args);
    if (result.exitCode != 0) throw OSError('$command failed');
    return (result.stdout as String).trim();
  }

  // gsettings prints and accepts GVariant text, so values go back unparsed.
  @override
  Future<ProxySettings> read() async => {
    'gnome': {
      for (final (schema, key) in _gnome)
        '$schema $key': await _out('gsettings', ['get', schema, key]),
    },
    if (_plasma)
      'kde': {
        for (final key in _kde)
          key: await _out('kreadconfig$_kdeVersion', [
            '--file',
            'kioslaverc',
            '--group',
            'Proxy Settings',
            '--key',
            key,
          ]),
      },
  };

  Future<void> _gnomeWrite(Map<String, String> values) async {
    for (final MapEntry(:key, :value) in values.entries) {
      final [schema, name] = key.split(' ');
      await _out('gsettings', ['set', schema, name, value]);
    }
  }

  Future<void> _kdeWrite(Map<String, String> values) async {
    for (final MapEntry(:key, :value) in values.entries)
      await _out('kwriteconfig$_kdeVersion', [
        '--file',
        'kioslaverc',
        '--group',
        'Proxy Settings',
        '--key',
        key,
        value,
      ]);
    // KIO apps reread kioslaverc only when told.
    await _out('dbus-send', [
      '--type=signal',
      '/KIO/Scheduler',
      'org.kde.KIO.Scheduler.reparseSlaveConfiguration',
      'string:',
    ]);
  }

  @override
  Future<void> point(int port) async {
    await _gnomeWrite({
      'org.gnome.system.proxy.http host': "'127.0.0.1'",
      'org.gnome.system.proxy.http port': '$port',
      'org.gnome.system.proxy.https host': "'127.0.0.1'",
      'org.gnome.system.proxy.https port': '$port',
      // A SOCKS entry would take every other protocol.
      'org.gnome.system.proxy.socks host': "''",
      'org.gnome.system.proxy.socks port': '0',
      'org.gnome.system.proxy ignore-hosts':
          '[${_bypass.map((host) => "'$host'").join(', ')}]',
      'org.gnome.system.proxy mode': "'manual'",
    });
    if (_plasma)
      await _kdeWrite({
        'httpProxy': 'http://127.0.0.1:$port',
        'httpsProxy': 'http://127.0.0.1:$port',
        'socksProxy': '',
        'NoProxyFor': _bypass.join(','),
        'ProxyType': '1',
      });
  }

  @override
  Future<void> write(ProxySettings settings) async {
    await _gnomeWrite((settings['gnome'] as Map).cast());
    if (settings['kde'] case final Map kde when _plasma)
      await _kdeWrite(kde.cast());
  }

  @override
  bool pointsAt(ProxySettings settings, int port) {
    final gnome = (settings['gnome'] as Map).cast<String, String>();
    return gnome['org.gnome.system.proxy mode'] == "'manual'" &&
        gnome['org.gnome.system.proxy.http host'] == "'127.0.0.1'" &&
        gnome['org.gnome.system.proxy.http port'] == '$port';
  }
}
