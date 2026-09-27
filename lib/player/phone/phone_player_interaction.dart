import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:rillight/player/player_controller.dart';

/// The page owns phone chrome state. Playback facts remain in PlayerController.
class PhonePlayerInteraction extends ChangeNotifier {
  bool _locked = false;
  bool _unlockVisible = false;
  Timer? _unlockTimer;
  int _occupancy = 0;
  String? _panel;

  bool get locked => _locked;
  bool get unlockVisible => _unlockVisible;
  bool get occupied => _occupancy > 0;
  String? get panel => _panel;

  bool controlsVisibleFor(PlayerController controller) {
    if (_locked) return _unlockVisible;
    return _occupancy > 0 ||
        controller.controlsVisible ||
        controller.loading ||
        controller.error != null ||
        controller.disconnected ||
        controller.sessionExpired ||
        controller.progressSyncFailed ||
        controller.trackFailure != null;
  }

  void lock() {
    if (_locked) return;
    _locked = true;
    _occupancy = 0;
    _panel = null;
    revealUnlock();
  }

  /// A tap on the video only reveals the button; it never unlocks.
  void revealUnlock() {
    if (!_locked) return;
    _unlockTimer?.cancel();
    _unlockVisible = true;
    notifyListeners();
    _unlockTimer = Timer(const Duration(seconds: 4), () {
      _unlockVisible = false;
      notifyListeners();
    });
  }

  void unlock() {
    if (!_locked || !_unlockVisible) return;
    _unlockTimer?.cancel();
    _locked = false;
    _unlockVisible = false;
    notifyListeners();
  }

  VoidCallback occupy() {
    _occupancy++;
    notifyListeners();
    var released = false;
    return () {
      if (released) return;
      released = true;
      if (_occupancy > 0) _occupancy--;
      notifyListeners();
    };
  }

  void setPanel(String? value) {
    if (_panel == value) return;
    _panel = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _unlockTimer?.cancel();
    super.dispose();
  }
}
