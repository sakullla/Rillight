import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:rillight/player/player_controller.dart';

/// Shared phone/TV lifecycle adapter. Inactive (IME/system overlays) and layout
/// changes do not release the session; a paused Activity does.
class AndroidPlaybackLifecycle with WidgetsBindingObserver {
  AndroidPlaybackLifecycle(this.controller) {
    WidgetsBinding.instance.addObserver(this);
  }
  final PlayerController controller;
  bool _disposed = false;
  Future<void> _pending = Future.value();
  Future<void> get settled => _pending;
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.paused &&
        state != AppLifecycleState.resumed) {
      return;
    }
    _pending = _pending
        .then((_) async {
          if (_disposed) return;
          if (state == AppLifecycleState.paused) {
            await controller.suspendPlayback();
          } else {
            await controller.restorePlayback();
          }
        })
        .catchError((Object _) {
          /* Controller retains the observable failure. */
        });
  }

  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
  }
}
