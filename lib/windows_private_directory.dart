import 'dart:ffi';

import 'package:ffi/ffi.dart';

// Both are KnownDLLs, so a bare name always loads the System32 copy.
final _kernel = DynamicLibrary.open('kernel32.dll');
final _advapi = DynamicLibrary.open('advapi32.dll');

final _attributes = _kernel
    .lookupFunction<
      Uint32 Function(Pointer<Utf16>),
      int Function(Pointer<Utf16>)
    >('GetFileAttributesW');
final _currentProcess = _kernel
    .lookupFunction<IntPtr Function(), int Function()>('GetCurrentProcess');
final _closeHandle = _kernel
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');
final _localFree = _kernel
    .lookupFunction<Pointer Function(Pointer), Pointer Function(Pointer)>(
      'LocalFree',
    );
final _openToken = _advapi
    .lookupFunction<
      Int32 Function(IntPtr, Uint32, Pointer<IntPtr>),
      int Function(int, int, Pointer<IntPtr>)
    >('OpenProcessToken');
final _tokenInformation = _advapi
    .lookupFunction<
      Int32 Function(IntPtr, Int32, Pointer, Uint32, Pointer<Uint32>),
      int Function(int, int, Pointer, int, Pointer<Uint32>)
    >('GetTokenInformation');
final _securityInfo = _advapi
    .lookupFunction<
      Uint32 Function(
        Pointer<Utf16>,
        Int32,
        Uint32,
        Pointer<Pointer>,
        Pointer<Pointer>,
        Pointer<Pointer>,
        Pointer<Pointer>,
        Pointer<Pointer>,
      ),
      int Function(
        Pointer<Utf16>,
        int,
        int,
        Pointer<Pointer>,
        Pointer<Pointer>,
        Pointer<Pointer>,
        Pointer<Pointer>,
        Pointer<Pointer>,
      )
    >('GetNamedSecurityInfoW');
final _descriptorControl = _advapi
    .lookupFunction<
      Int32 Function(Pointer, Pointer<Uint16>, Pointer<Uint32>),
      int Function(Pointer, Pointer<Uint16>, Pointer<Uint32>)
    >('GetSecurityDescriptorControl');
final _getAce = _advapi
    .lookupFunction<
      Int32 Function(Pointer, Uint32, Pointer<Pointer>),
      int Function(Pointer, int, Pointer<Pointer>)
    >('GetAce');
final _equalSid = _advapi
    .lookupFunction<
      Int32 Function(Pointer, Pointer),
      int Function(Pointer, Pointer)
    >('EqualSid');

/// The control directory check without a PowerShell launch: a plain directory
/// owned by this user whose protected DACL allows nobody else. False when unsure.
bool windowsPrivateDirectory(String path) => using((arena) {
  final name = path.toNativeUtf16(allocator: arena);
  final attributes = _attributes(name);
  // Invalid, not a directory, or a reparse point such as a junction.
  if (attributes == 0xFFFFFFFF ||
      attributes & 0x10 == 0 ||
      attributes & 0x400 != 0)
    return false;
  final token = arena<IntPtr>();
  if (_openToken(_currentProcess(), 0x8 /* TOKEN_QUERY */, token) == 0)
    return false;
  // TOKEN_USER and its SID (at most 68 bytes) fit in 256 bytes.
  final user = arena<Uint8>(256);
  final length = arena<Uint32>();
  final queried = _tokenInformation(
    token.value,
    1 /* TokenUser */,
    user,
    256,
    length,
  );
  _closeHandle(token.value);
  if (queried == 0) return false;
  final sid = user.cast<Pointer>().value;
  final owner = arena<Pointer>(),
      dacl = arena<Pointer>(),
      descriptor = arena<Pointer>();
  // SE_FILE_OBJECT, OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION.
  if (_securityInfo(
        name,
        1,
        0x1 | 0x4,
        owner,
        nullptr,
        dacl,
        nullptr,
        descriptor,
      ) !=
      0)
    return false;
  try {
    final control = arena<Uint16>(), revision = arena<Uint32>();
    // A null DACL grants everyone access; SE_DACL_PROTECTED blocks inheritance.
    if (dacl.value == nullptr ||
        _descriptorControl(descriptor.value, control, revision) == 0 ||
        control.value & 0x1000 == 0 ||
        _equalSid(owner.value, sid) == 0)
      return false;
    final count = dacl.value.cast<Uint16>()[2]; // ACL.AceCount
    final ace = arena<Pointer>();
    for (var index = 0; index < count; index++) {
      if (_getAce(dacl.value, index, ace) == 0) return false;
      final type = ace.value.cast<Uint8>().value;
      if (type == 1) continue; // ACCESS_DENIED_ACE_TYPE only narrows access.
      // This app writes no other entry kinds; PowerShell decides about those.
      if (type != 0 ||
          _equalSid(Pointer.fromAddress(ace.value.address + 8), sid) == 0)
        return false;
    }
    return true;
  } finally {
    _localFree(descriptor.value);
  }
});
