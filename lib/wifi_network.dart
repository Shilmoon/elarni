import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// The Wi-Fi network this computer has joined: its name, or null off Wi-Fi.
/// [denied] means the system keeps the name from Elarni: Windows 11 24H2 and
/// later ask for Location access first.
typedef WiFiReading = ({String? name, bool denied});

Future<WiFiReading> readWiFiNetwork() async {
  if (Platform.isWindows) return _windowsWiFi();
  if (Platform.isLinux) return (name: await _linuxWiFi(), denied: false);
  return (name: null, denied: false);
}

const _offWiFi = (name: null, denied: false);

final class _Wlan {
  _Wlan(DynamicLibrary library)
    : open = library
          .lookupFunction<
            Uint32 Function(Uint32, Pointer, Pointer<Uint32>, Pointer<IntPtr>),
            int Function(int, Pointer, Pointer<Uint32>, Pointer<IntPtr>)
          >('WlanOpenHandle'),
      close = library
          .lookupFunction<
            Uint32 Function(IntPtr, Pointer),
            int Function(int, Pointer)
          >('WlanCloseHandle'),
      interfaces = library
          .lookupFunction<
            Uint32 Function(IntPtr, Pointer, Pointer<Pointer<Uint8>>),
            int Function(int, Pointer, Pointer<Pointer<Uint8>>)
          >('WlanEnumInterfaces'),
      query = library
          .lookupFunction<
            Uint32 Function(
              IntPtr,
              Pointer<Uint8>,
              Int32,
              Pointer,
              Pointer<Uint32>,
              Pointer<Pointer<Uint8>>,
              Pointer<Int32>,
            ),
            int Function(
              int,
              Pointer<Uint8>,
              int,
              Pointer,
              Pointer<Uint32>,
              Pointer<Pointer<Uint8>>,
              Pointer<Int32>,
            )
          >('WlanQueryInterface'),
      free = library
          .lookupFunction<Void Function(Pointer), void Function(Pointer)>(
            'WlanFreeMemory',
          );
  final int Function(int, Pointer, Pointer<Uint32>, Pointer<IntPtr>) open;
  final int Function(int, Pointer) close;
  final int Function(int, Pointer, Pointer<Pointer<Uint8>>) interfaces;
  final int Function(
    int,
    Pointer<Uint8>,
    int,
    Pointer,
    Pointer<Uint32>,
    Pointer<Pointer<Uint8>>,
    Pointer<Int32>,
  )
  query;
  final void Function(Pointer) free;
}

// wlanapi.dll is no KnownDLL, so it loads from System32 by full path, never
// from beside the app. Windows Server without wireless support has none.
final _Wlan? _wlan = () {
  try {
    final system = using((arena) {
      final buffer = arena<Uint16>(260);
      final length = DynamicLibrary.open('kernel32.dll')
          .lookupFunction<
            Uint32 Function(Pointer<Uint16>, Uint32),
            int Function(Pointer<Uint16>, int)
          >('GetSystemDirectoryW')(buffer, 260);
      if (length == 0 || length >= 260) throw StateError('system directory');
      return buffer.cast<Utf16>().toDartString(length: length);
    });
    return _Wlan(DynamicLibrary.open('$system\\wlanapi.dll'));
  } on Object {
    return null;
  }
}();

WiFiReading _windowsWiFi() {
  final api = _wlan;
  if (api == null) return _offWiFi;
  return using((arena) {
    final handle = arena<IntPtr>();
    // Without the WLAN AutoConfig service there is no Wi-Fi to read.
    if (api.open(2, nullptr, arena<Uint32>(), handle) != 0) return _offWiFi;
    final list = arena<Pointer<Uint8>>();
    try {
      if (api.interfaces(handle.value, nullptr, list) != 0) return _offWiFi;
      var denied = false;
      final count = list.value.cast<Uint32>().value;
      for (var index = 0; index < count; index++) {
        // WLAN_INTERFACE_INFO_LIST holds two DWORDs, then interfaces of a GUID,
        // a 256-WCHAR description and their state; 1 is connected.
        final item = list.value + 8 + index * 532;
        if ((item + 528).cast<Uint32>().value != 1) continue;
        final data = arena<Pointer<Uint8>>();
        // 7 is wlan_intf_opcode_current_connection.
        final status = api.query(
          handle.value,
          item,
          7,
          nullptr,
          arena<Uint32>(),
          data,
          arena<Int32>(),
        );
        // ERROR_ACCESS_DENIED: the user has not allowed location access.
        if (status == 5) denied = true;
        if (status != 0) continue;
        try {
          // WLAN_CONNECTION_ATTRIBUTES: state, mode and a 256-WCHAR profile
          // name, then the SSID's length and its up to 32 bytes.
          final length = (data.value + 520).cast<Uint32>().value;
          if (length >= 1 && length <= 32)
            return (
              name: utf8.decode(
                (data.value + 524).asTypedList(length),
                allowMalformed: true,
              ),
              denied: false,
            );
        } finally {
          api.free(data.value);
        }
      }
      return (name: null, denied: denied);
    } finally {
      if (list.value != nullptr) api.free(list.value);
      api.close(handle.value, nullptr);
    }
  });
}

// NetworkManager runs most desktops; iw reads the kernel's view otherwise.
Future<String?> _linuxWiFi() async {
  const english = {'LC_ALL': 'C'};
  try {
    final result = await Process.run('nmcli', [
      '-t',
      '-f',
      'ACTIVE,SSID',
      'device',
      'wifi',
      'list',
      '--rescan',
      'no',
    ], environment: english);
    if (result.exitCode == 0) return nmcliWiFi(result.stdout as String);
  } on ProcessException {
    // Not installed.
  }
  try {
    final devices = await Process.run('iw', ['dev'], environment: english);
    if (devices.exitCode != 0) return null;
    for (final match in RegExp(
      r'^\s*Interface\s+(\S+)',
      multiLine: true,
    ).allMatches(devices.stdout as String)) {
      final link = await Process.run('iw', [
        'dev',
        match[1]!,
        'link',
      ], environment: english);
      final name = link.exitCode == 0 ? iwWiFi(link.stdout as String) : null;
      if (name != null) return name;
    }
  } on ProcessException {
    // Not installed.
  }
  return null;
}

/// The active network in `nmcli -t -f ACTIVE,SSID device wifi list` output,
/// which escapes colons and backslashes with a backslash.
String? nmcliWiFi(String output) {
  for (final line in const LineSplitter().convert(output)) {
    if (!line.startsWith('yes:')) continue;
    final name = line
        .substring(4)
        .replaceAllMapped(RegExp(r'\\(.)'), (match) => match[1]!);
    if (name.isNotEmpty) return name;
  }
  return null;
}

/// The network in `iw dev <interface> link` output, which writes bytes
/// outside printable ASCII as \xNN.
String? iwWiFi(String output) {
  final line = RegExp(r'^\s*SSID: (.*)$', multiLine: true).firstMatch(output);
  if (line == null || line[1]!.isEmpty) return null;
  final bytes = <int>[];
  final text = line[1]!;
  for (var index = 0; index < text.length; index++) {
    final escape = RegExp(r'\\x([0-9a-fA-F]{2})').matchAsPrefix(text, index);
    if (escape != null) {
      bytes.add(int.parse(escape[1]!, radix: 16));
      index += 3;
    } else {
      bytes.addAll(utf8.encode(text[index]));
    }
  }
  return utf8.decode(bytes, allowMalformed: true);
}
