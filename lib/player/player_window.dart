import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';

class PlayerWindow extends ChangeNotifier {
  bool _fullScreen = false;

  bool get isFullScreen => _fullScreen;

  Future<void> setFullScreen(bool value) async {
    if (_fullScreen == value) {
      return;
    }
    _fullScreen = value;
    notifyListeners();
  }
}

class WindowManagerPlayerWindow extends PlayerWindow {
  @override
  Future<void> setFullScreen(bool value) async {
    await super.setFullScreen(value);
    try {
      await windowManager.setFullScreen(value);
    } catch (_) {}
  }
}
