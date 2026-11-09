import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'src/generated/elarni_ffi.g.dart';

final class ElarniDomainFfi {
  ElarniDomainFfi._(this._bindings, this._handle);

  static const int supportedAbi = 1;
  static const int supportedSchema = 1;

  final ElarniNativeBindings _bindings;
  final Pointer<ElarniHandle> _handle;

  static ElarniDomainFfi openLibrary(String path) =>
      _open(DynamicLibrary.open(path));

  static ElarniDomainFfi _open(DynamicLibrary library) {
    final bindings = ElarniNativeBindings(library);
    if (bindings.elarni_abi_version() != supportedAbi ||
        bindings.elarni_schema_min() > supportedSchema ||
        bindings.elarni_schema_max() < supportedSchema) {
      throw StateError('Elarni native ABI/schema mismatch.');
    }
    final handle = bindings.elarni_handle_new();
    if (handle == nullptr) {
      throw StateError('Elarni native handle allocation failed.');
    }
    return ElarniDomainFfi._(bindings, handle);
  }

  Map<String, Object?> request(Map<String, Object?> envelope) {
    final request = JsonUtf8Encoder().convert(envelope);
    // Matches MAX_REQUEST_BYTES in native/elarni-domain/src/ffi.rs.
    if (request.length > 64 * 1024 * 1024) {
      throw const FormatException('Native request exceeds 64 MiB.');
    }
    final requestPointer = calloc<Uint8>(request.length);
    final outputPointer = calloc<ElarniBuffer>();
    try {
      requestPointer.asTypedList(request.length).setAll(0, request);
      final status = _bindings.elarni_request(
        _handle,
        requestPointer,
        request.length,
        outputPointer,
      );
      final output = outputPointer.ref;
      final response = output.data == nullptr
          ? const <String, Object?>{}
          : jsonDecode(
                  utf8.decode(
                    output.data.asTypedList(output.len),
                    allowMalformed: false,
                  ),
                )
                as Map<String, Object?>;
      if (status != 0) {
        throw FormatException(
          response['error']?.toString() ?? 'Native request failed.',
        );
      }
      return response;
    } finally {
      if (outputPointer.ref.data != nullptr) {
        _bindings.elarni_buffer_free(outputPointer.ref);
      }
      calloc.free(outputPointer);
      calloc.free(requestPointer);
    }
  }

  void dispose() => _bindings.elarni_handle_free(_handle);
}
