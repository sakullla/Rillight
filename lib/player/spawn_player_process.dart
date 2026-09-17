import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// Owns the process object returned by CreateProcess, not a reusable PID.
abstract interface class WindowsPlayerProcess {
  int get pid;
  bool get isAlive;
  void terminate();
  void close();
}

class _WindowsPlayerProcess implements WindowsPlayerProcess {
  _WindowsPlayerProcess(this.pid, this._handle);

  @override
  final int pid;
  int _handle;

  @override
  bool get isAlive {
    if (_handle == 0) return false;
    // A signalled process has exited, including one with exit code 259.
    return switch (WaitForSingleObject(_handle, 0)) {
      WAIT_OBJECT_0 => false,
      WAIT_TIMEOUT => true,
      _ => throw WindowsException(HRESULT_FROM_WIN32(GetLastError())),
    };
  }

  @override
  void terminate() {
    if (!isAlive) return;
    if (TerminateProcess(_handle, 1) == FALSE) {
      final error = GetLastError();
      // The child may have exited between the poll and TerminateProcess.
      if (isAlive) throw WindowsException(HRESULT_FROM_WIN32(error));
    }
  }

  @override
  void close() {
    if (_handle == 0) return;
    if (isAlive) throw StateError('Cannot release a running player process');
    if (CloseHandle(_handle) == FALSE) {
      throw WindowsException(HRESULT_FROM_WIN32(GetLastError()));
    }
    _handle = 0;
  }
}

Map<String, String> playerProcessEnvironment() {
  final env = Map<String, String>.from(Platform.environment);
  env.removeWhere(
    (key, value) =>
        key.startsWith('FLUTTER') ||
        key.startsWith('DART_') ||
        key == 'FLUTTER_ENGINE_SWITCHES',
  );
  return env;
}

WindowsPlayerProcess spawnStandalonePlayer({
  required String executable,
  required String payloadPath,
}) {
  if (!Platform.isWindows) {
    throw UnsupportedError('standalone player spawn is Windows-only');
  }
  final command = '"$executable" player "$payloadPath"';
  final startup = calloc<STARTUPINFO>();
  final processInfo = calloc<PROCESS_INFORMATION>();
  final commandPtr = command.toNativeUtf16();
  final entries = playerProcessEnvironment().entries.toList()
    ..sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase()));
  final environment =
      ('${entries.map((e) => '${e.key}=${e.value}').join('\u0000')}\u0000')
          .toNativeUtf16();
  startup.ref.cb = sizeOf<STARTUPINFO>();
  var flags =
      CREATE_UNICODE_ENVIRONMENT |
      CREATE_NEW_PROCESS_GROUP |
      CREATE_BREAKAWAY_FROM_JOB;
  var ok = CreateProcess(
    nullptr,
    commandPtr,
    nullptr,
    nullptr,
    FALSE,
    flags,
    environment.cast(),
    nullptr,
    startup,
    processInfo,
  );
  if (ok == FALSE) {
    flags = CREATE_UNICODE_ENVIRONMENT | CREATE_NEW_PROCESS_GROUP;
    ok = CreateProcess(
      nullptr,
      commandPtr,
      nullptr,
      nullptr,
      FALSE,
      flags,
      environment.cast(),
      nullptr,
      startup,
      processInfo,
    );
  }
  final error = ok == FALSE ? GetLastError() : 0;
  final pid = processInfo.ref.dwProcessId;
  final handle = processInfo.ref.hProcess;
  if (processInfo.ref.hThread != 0) {
    CloseHandle(processInfo.ref.hThread);
  }
  calloc.free(environment);
  calloc.free(commandPtr);
  calloc.free(startup);
  calloc.free(processInfo);
  if (ok == FALSE || pid == 0) {
    if (handle != 0) CloseHandle(handle);
    throw WindowsException(HRESULT_FROM_WIN32(error));
  }
  return _WindowsPlayerProcess(pid, handle);
}
