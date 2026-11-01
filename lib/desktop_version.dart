import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// The pubspec version this desktop build carries, or null when its build
/// metadata is missing.
final String? desktopAppVersion = () {
  try {
    final executable = Platform.resolvedExecutable;
    if (Platform.isWindows) return windowsProductVersion(executable);
    if (Platform.isLinux) {
      return linuxBundleVersion(File(executable).parent.path);
    }
  } on Object {
    // Unreadable metadata only hides the version.
  }
  return null;
}();

/// Flutter writes version.json beside a Linux bundle's assets.
String? linuxBundleVersion(String bundle) {
  final file = File('$bundle/data/flutter_assets/version.json');
  if (!file.existsSync()) return null;
  final info = jsonDecode(file.readAsStringSync());
  if (info is! Map || info['version'] is! String) return null;
  final build = info['build_number'];
  return build is String && build.isNotEmpty
      ? '${info['version']}+$build'
      : info['version'] as String;
}

// An API set name never resolves to a DLL planted beside the app.
final _version = DynamicLibrary.open('api-ms-win-core-version-l1-1-0.dll');

final _infoSize = _version
    .lookupFunction<
      Uint32 Function(Pointer<Utf16>, Pointer<Uint32>),
      int Function(Pointer<Utf16>, Pointer<Uint32>)
    >('GetFileVersionInfoSizeW');
final _info = _version
    .lookupFunction<
      Int32 Function(Pointer<Utf16>, Uint32, Uint32, Pointer<Uint8>),
      int Function(Pointer<Utf16>, int, int, Pointer<Uint8>)
    >('GetFileVersionInfoW');
final _query = _version
    .lookupFunction<
      Int32 Function(
        Pointer<Uint8>,
        Pointer<Utf16>,
        Pointer<Pointer<Void>>,
        Pointer<Uint32>,
      ),
      int Function(
        Pointer<Uint8>,
        Pointer<Utf16>,
        Pointer<Pointer<Void>>,
        Pointer<Uint32>,
      )
    >('VerQueryValueW');

/// The ProductVersion of a file's version resource. The Windows runner fills
/// it from the pubspec version.
String? windowsProductVersion(String path) => using((arena) {
  final name = path.toNativeUtf16(allocator: arena);
  final size = _infoSize(name, nullptr);
  if (size == 0) return null;
  final data = arena<Uint8>(size);
  if (_info(name, 0, size, data) == 0) return null;
  final value = arena<Pointer<Void>>(), length = arena<Uint32>();
  bool found(String key) =>
      _query(data, key.toNativeUtf16(allocator: arena), value, length) != 0;
  // The first language and code page name the block that holds the strings.
  if (!found(r'\VarFileInfo\Translation') || length.value < 4) return null;
  final translation = value.value.cast<Uint16>();
  String hex(int word) => word.toRadixString(16).padLeft(4, '0');
  final block = '${hex(translation[0])}${hex(translation[1])}';
  if (!found('\\StringFileInfo\\$block\\ProductVersion')) return null;
  return value.value.cast<Utf16>().toDartString();
});
