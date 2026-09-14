import 'dart:async';
import 'dart:io';

import 'package:rillight/player/spawn_player_process.dart';

/// 宿主对独立播放进程的生命周期控制。
///
/// 生产环境为 [WindowsPlayerProcessControl];测试注入记录调用序列的
/// 假实现,让 `DesktopPlayerWindowHost` 的关闭顺序与代发逻辑可断言。
abstract class PlayerProcessControl {
  /// 以 [arguments](JSON 启动载荷)拉起播放进程,返回其 pid。
  Future<int> spawn({required String executable, required String arguments});

  bool isAlive(int pid);

  /// 请求播放进程自行关窗(先发 Stopped 再退出),最多等待 [wait]。
  ///
  /// 进程已退出或在期限内退出时返回 true;超时或无法投递时返回 false,
  /// 由调用方决定是否 [kill]。
  Future<bool> requestClose(int pid, Duration wait);

  void kill(int pid);
}

/// Windows 实现:CreateProcess 拉起、WM_CLOSE 优雅关闭、进程句柄探活。
class WindowsPlayerProcessControl implements PlayerProcessControl {
  const WindowsPlayerProcessControl({
    this.pollInterval = const Duration(milliseconds: 100),
  });

  static const launchFileName = 'rillight-player-launch.json';

  final Duration pollInterval;

  @override
  Future<int> spawn({
    required String executable,
    required String arguments,
  }) async {
    final file = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}$launchFileName',
    );
    await file.writeAsString(arguments);
    return spawnStandalonePlayer(
      executable: executable,
      payloadPath: file.path,
    );
  }

  @override
  bool isAlive(int pid) => isPidAlive(pid);

  @override
  Future<bool> requestClose(int pid, Duration wait) async {
    if (!isAlive(pid)) {
      return true;
    }
    if (postCloseToPid(pid) == 0) {
      // 窗口尚未显示(仍在启动)或已不可见:没有可走的优雅路径。
      return false;
    }
    final deadline = DateTime.now().add(wait);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(pollInterval);
      if (!isAlive(pid)) {
        return true;
      }
    }
    return !isAlive(pid);
  }

  @override
  void kill(int pid) => killPid(pid);
}
