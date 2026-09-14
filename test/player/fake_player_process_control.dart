import 'package:rillight/player/player_process_control.dart';

/// 记录 spawn/requestClose/kill 调用序列的进程控制假实现。
///
/// [calls] 可与其他被测对象共享,以断言跨对象的调用顺序
/// (例如 `requestClose` 必须先于 `logout`)。
class FakePlayerProcessControl implements PlayerProcessControl {
  FakePlayerProcessControl({
    List<String>? calls,
    this.requestCloseResult = false,
    int firstPid = 1001,
  }) : calls = calls ?? <String>[],
       _nextPid = firstPid;

  /// 按顺序记录的调用:`spawn:<pid>`、`requestClose:<pid>`、`kill:<pid>`。
  final List<String> calls;

  /// `requestClose` 的返回值;为 true 时同时把进程标记为已退出。
  bool requestCloseResult;

  /// 每次 spawn 收到的 JSON 启动载荷。
  final List<String> spawnedArguments = [];

  /// 当前视为存活的 pid。
  final Set<int> alive = {};

  int _nextPid;

  int get lastPid => _nextPid - 1;

  @override
  Future<int> spawn({
    required String executable,
    required String arguments,
  }) async {
    final pid = _nextPid++;
    alive.add(pid);
    spawnedArguments.add(arguments);
    calls.add('spawn:$pid');
    return pid;
  }

  @override
  bool isAlive(int pid) => alive.contains(pid);

  @override
  Future<bool> requestClose(int pid, Duration wait) async {
    calls.add('requestClose:$pid');
    if (requestCloseResult) {
      alive.remove(pid);
    }
    return requestCloseResult;
  }

  @override
  void kill(int pid) {
    calls.add('kill:$pid');
    alive.remove(pid);
  }

  /// 模拟播放进程意外退出(崩溃或被外部结束)。
  void exit(int pid) {
    alive.remove(pid);
  }
}
