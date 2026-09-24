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
  HANDLE _handle;

  @override
  bool get isAlive {
    if (_handle == nullptr) return false;
    final wait = WaitForSingleObject(_handle, 0);
    // A signalled process has exited, including one with exit code 259.
    return switch (wait.value) {
      WAIT_OBJECT_0 => false,
      WAIT_TIMEOUT => true,
      _ => throw WindowsException(wait.error.toHRESULT()),
    };
  }

  @override
  void terminate() {
    if (!isAlive) return;
    final result = TerminateProcess(_handle, 1);
    // The child may have exited between the poll and TerminateProcess.
    if (!result.value && isAlive) {
      throw WindowsException(result.error.toHRESULT());
    }
  }

  @override
  void close() {
    if (_handle == nullptr) return;
    if (isAlive) throw StateError('Cannot release a running player process');
    final result = CloseHandle(_handle);
    if (!result.value) {
      throw WindowsException(result.error.toHRESULT());
    }
    _handle = HANDLE(nullptr);
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
  final commandPtr = command.toPwstr(allocator: calloc);
  final entries = playerProcessEnvironment().entries.toList()
    ..sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase()));
  final environment =
      ('${entries.map((e) => '${e.key}=${e.value}').join('\u0000')}\u0000')
          .toPwstr(allocator: calloc);
  startup.ref.cb = sizeOf<STARTUPINFO>();
  var flags =
      CREATE_UNICODE_ENVIRONMENT |
      CREATE_NEW_PROCESS_GROUP |
      CREATE_BREAKAWAY_FROM_JOB;
  var result = CreateProcess(
    null,
    commandPtr,
    null,
    null,
    false,
    flags,
    environment,
    null,
    startup,
    processInfo,
  );
  if (!result.value) {
    flags = CREATE_UNICODE_ENVIRONMENT | CREATE_NEW_PROCESS_GROUP;
    result = CreateProcess(
      null,
      commandPtr,
      null,
      null,
      false,
      flags,
      environment,
      null,
      startup,
      processInfo,
    );
  }
  final error = !result.value ? result.error : ERROR_SUCCESS;
  final pid = processInfo.ref.dwProcessId;
  final handle = processInfo.ref.hProcess;
  if (processInfo.ref.hThread != nullptr) {
    CloseHandle(processInfo.ref.hThread);
  }
  calloc.free(environment);
  calloc.free(commandPtr);
  calloc.free(startup);
  calloc.free(processInfo);
  if (!result.value || pid == 0) {
    if (handle != nullptr) CloseHandle(handle);
    throw WindowsException(error.toHRESULT());
  }
  return _WindowsPlayerProcess(pid, handle);
}
