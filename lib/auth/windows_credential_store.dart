import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:win32/win32.dart';

CredentialStore windowsKeychainOrFallback(CredentialStore fallback) {
  if (!Platform.isWindows) {
    return fallback;
  }
  return SecureCredentialStore(
    writeSecure: _write,
    readSecure: _read,
    deleteSecure: _delete,
    fallback: fallback,
  );
}

const _targetPrefix = 'Rillight/Emby/';

String _target(String key) => '$_targetPrefix$key';

Future<void> _write(String key, String value) async {
  final target = _target(key).toPwstr(allocator: calloc);
  final user = 'Rillight'.toPwstr(allocator: calloc);
  final bytes = Uint8List.fromList(utf8.encode(value));
  final blob = calloc<Uint8>(bytes.length);
  blob.asTypedList(bytes.length).setAll(0, bytes);
  final cred = calloc<CREDENTIAL>();
  cred.ref
    ..Type = CRED_TYPE_GENERIC
    ..TargetName = target
    ..UserName = user
    ..Persist = CRED_PERSIST_LOCAL_MACHINE
    ..CredentialBlob = blob
    ..CredentialBlobSize = bytes.length;
  try {
    final result = CredWrite(cred, 0);
    if (!result.value) {
      throw WindowsException(result.error.toHRESULT());
    }
  } finally {
    calloc.free(target);
    calloc.free(user);
    calloc.free(blob);
    calloc.free(cred);
  }
}

Future<String?> _read(String key) async {
  final target = _target(key).toPcwstr(allocator: calloc);
  final cred = calloc<Pointer<CREDENTIAL>>();
  try {
    final result = CredRead(target, CRED_TYPE_GENERIC, cred);
    if (!result.value) {
      final error = result.error;
      if (error == ERROR_NOT_FOUND || error == 0) {
        return null;
      }
      throw WindowsException(error.toHRESULT());
    }
    final ref = cred.value.ref;
    final blob = ref.CredentialBlob.asTypedList(ref.CredentialBlobSize);
    return utf8.decode(blob);
  } finally {
    if (cred.value != nullptr) {
      CredFree(cred.value);
    }
    calloc.free(target);
    calloc.free(cred);
  }
}

Future<void> _delete(String key) async {
  final target = _target(key).toPcwstr(allocator: calloc);
  try {
    final result = CredDelete(target, CRED_TYPE_GENERIC);
    if (!result.value && result.error != ERROR_NOT_FOUND) {
      throw WindowsException(result.error.toHRESULT());
    }
  } finally {
    calloc.free(target);
  }
}
