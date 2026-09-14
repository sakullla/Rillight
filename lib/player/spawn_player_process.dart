import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

const _stillActive = 259;

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

int spawnStandalonePlayer({
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
    nullptr,
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
      nullptr,
      nullptr,
      startup,
      processInfo,
    );
  }
  final pid = processInfo.ref.dwProcessId;
  if (processInfo.ref.hThread != 0) {
    CloseHandle(processInfo.ref.hThread);
  }
  if (processInfo.ref.hProcess != 0) {
    CloseHandle(processInfo.ref.hProcess);
  }
  calloc.free(commandPtr);
  calloc.free(startup);
  calloc.free(processInfo);
  if (ok == FALSE || pid == 0) {
    throw WindowsException(HRESULT_FROM_WIN32(GetLastError()));
  }
  return pid;
}

bool isPidAlive(int pid) {
  if (pid <= 0) {
    return false;
  }
  final handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (handle == 0) {
    return false;
  }
  final code = calloc<Uint32>();
  final ok = GetExitCodeProcess(handle, code);
  final alive = ok != 0 && code.value == _stillActive;
  calloc.free(code);
  CloseHandle(handle);
  return alive;
}

void killPid(int pid) {
  if (pid <= 0) {
    return;
  }
  Process.killPid(pid);
}

int _closeTargetPid = 0;
int _closePosted = 0;

int _postCloseProc(int hwnd, int lParam) {
  // 只投递可见、无属主的顶层窗口:Flutter 任务队列等隐藏辅助窗口收到
  // WM_CLOSE 会被 DefWindowProc 销毁,拖垮播放进程的事件循环。
  if (IsWindowVisible(hwnd) == FALSE || GetWindow(hwnd, GW_OWNER) != 0) {
    return TRUE;
  }
  final owner = calloc<Uint32>();
  GetWindowThreadProcessId(hwnd, owner);
  final matches = owner.value == _closeTargetPid;
  calloc.free(owner);
  if (matches) {
    PostMessage(hwnd, WM_CLOSE, 0, 0);
    _closePosted += 1;
  }
  return TRUE;
}

/// 向 [pid] 的可见顶层窗口投递 WM_CLOSE,返回投递的窗口数。
///
/// 播放进程以 `setPreventClose(true)` 接管 WM_CLOSE 并走
/// `onWindowClose` → Stopped → `exit(0)` 的正常关窗路径。
int postCloseToPid(int pid) {
  if (pid <= 0 || !Platform.isWindows) {
    return 0;
  }
  _closeTargetPid = pid;
  _closePosted = 0;
  final callback = Pointer.fromFunction<WNDENUMPROC>(_postCloseProc, 0);
  EnumWindows(callback, 0);
  _closeTargetPid = 0;
  return _closePosted;
}
