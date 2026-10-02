import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:rillight/player/player_controller.dart';
import 'package:rillight/player/video_backend.dart';

/// Shared phone/TV lifecycle adapter. Inactive (IME/system overlays) and layout
/// changes do not release the session; a paused Activity does.
class AndroidPlaybackLifecycle with WidgetsBindingObserver {
  AndroidPlaybackLifecycle(this.controller, {this.phonePresentation}) {
    phonePresentation?.phonePresentation.addListener(_nativeChanged);
    WidgetsBinding.instance.addObserver(this);
  }
  final PlayerController controller;
  final VideoBackendPhonePresentation? phonePresentation;
  bool _nativeSuspendRequested = false;
  void _nativeChanged() {
    final suspend =
        phonePresentation?.phonePresentation.value['shouldSuspend'] == true;
    if (suspend && !_nativeSuspendRequested) {
      _enqueue(AppLifecycleState.paused, nativeOnly: true);
    }
    _nativeSuspendRequested = suspend;
  }

  bool _disposed = false;
  Future<void> _pending = Future.value();
  Future<void> get settled => _pending;
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.paused &&
        state != AppLifecycleState.resumed) {
      return;
    }
    _enqueue(state);
  }

  Future<Map<String, dynamic>> _facts() async {
    try {
      return await phonePresentation?.refreshPhonePresentation().timeout(
            const Duration(milliseconds: 700),
          ) ??
          const {};
    } catch (_) {
      // A failed bridge cannot grant an unlimited background audio exception.
      return const {};
    }
  }

  void _enqueue(AppLifecycleState state, {bool nativeOnly = false}) {
    final session = phonePresentation?.phonePresentation.value['session'];
    _pending = _pending
        .then((_) async {
          if (_disposed) return;
          if (state == AppLifecycleState.paused) {
            final facts = await _facts();
            if (_disposed || facts['retainPlayback'] == true) return;
            if (session != null &&
                facts['session'] != null &&
                session != facts['session']) {
              return;
            }
            if (nativeOnly &&
                facts.isNotEmpty &&
                facts['shouldSuspend'] != true) {
              return;
            }
            if (facts['foreground'] == true && facts['shouldSuspend'] != true) {
              return;
            }
            await controller.suspendPlayback();
          } else {
            final facts = await _facts();
            if (_disposed || facts['retainPlayback'] == true) return;
            await controller.restorePlayback();
          }
        })
        .catchError((Object _) {
          /* Controller retains the observable failure. */
        });
  }

  void dispose() {
    _disposed = true;
    phonePresentation?.phonePresentation.removeListener(_nativeChanged);
    WidgetsBinding.instance.removeObserver(this);
  }
}
