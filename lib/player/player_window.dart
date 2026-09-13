import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';

class PlayerWindow extends ChangeNotifier {
  bool _fullScreen = false;
  bool _alwaysOnTop = false;

  bool get isFullScreen => _fullScreen;
  bool get isAlwaysOnTop => _alwaysOnTop;

  Future<void> setFullScreen(bool value) async {
    if (_fullScreen == value) {
      return;
    }
    _fullScreen = value;
    notifyListeners();
  }

  Future<void> setAlwaysOnTop(bool value) async {
    if (_alwaysOnTop == value) {
      return;
    }
    _alwaysOnTop = value;
    notifyListeners();
  }
}

class WindowManagerPlayerWindow extends PlayerWindow {
  WindowManagerPlayerWindow() {
    // 会话内记忆:播放进程内换集会重建 PlayerPage/PlayerWindow,
    // 以进程级标志恢复置顶状态,与 OS 窗口的实际置顶保持一致;
    // 进程重启后自然回到未置顶。
    _alwaysOnTop = _sessionAlwaysOnTop;
  }

  static bool _sessionAlwaysOnTop = false;

  @override
  Future<void> setFullScreen(bool value) async {
    await super.setFullScreen(value);
    try {
      await windowManager.setFullScreen(value);
    } catch (_) {}
  }

  @override
  Future<void> setAlwaysOnTop(bool value) async {
    _sessionAlwaysOnTop = value;
    await super.setAlwaysOnTop(value);
    try {
      await windowManager.setAlwaysOnTop(value);
    } catch (_) {}
  }
}
