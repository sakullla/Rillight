import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

typedef PhoneOrientationRequest =
    Future<void> Function(List<DeviceOrientation> orientations);

/// Asks for landscape while a phone player is open, then restores the
/// orientations captured at entry.
///
/// [request] is replaceable so tests can observe the calls without rotating
/// a device. A failed request is recorded and swallowed; playback continues.
/// This never writes an activity-wide manifest lock.
class PhoneOrientation {
  PhoneOrientation({
    PhoneOrientationRequest? request,
    List<DeviceOrientation>? restoreTo,
  }) : _request = request ?? systemRequest,
       restoreTo = List<DeviceOrientation>.unmodifiable(restoreTo ?? unlocked);

  /// Both landscape directions. Portrait stays out of this list only while
  /// playback holds it; exit puts [restoreTo] back.
  static const landscape = <DeviceOrientation>[
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ];

  /// Browsing default: every orientation, so a later rotation is not locked.
  static const unlocked = <DeviceOrientation>[
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ];

  static Future<void> systemRequest(List<DeviceOrientation> orientations) {
    return SystemChrome.setPreferredOrientations(orientations);
  }

  final PhoneOrientationRequest _request;

  /// Orientations that were current before playback requested landscape.
  final List<DeviceOrientation> restoreTo;

  final List<List<DeviceOrientation>> calls = [];
  Object? lastError;
  bool _entered = false;
  Future<void> _queue = Future<void>.value();

  Future<void> get settled => _queue;

  Future<void> enterPlayback() {
    if (_entered) return _queue;
    _entered = true;
    return _enqueue(() => _send(landscape));
  }

  Future<void> leavePlayback() {
    if (!_entered) return _queue;
    _entered = false;
    final restore = restoreTo;
    return _enqueue(() async {
      await _send(restore);
      // Landscape must not remain the activity preference after exit, or
      // portrait browsing stays locked. The entry direction is still requested
      // first so the platform can turn back.
      if (!_same(restore, unlocked)) {
        await _send(unlocked);
      }
    });
  }

  Future<void> _enqueue(Future<void> Function() action) {
    _queue = _queue.then((_) => action());
    return _queue;
  }

  Future<void> _send(List<DeviceOrientation> orientations) async {
    final copy = List<DeviceOrientation>.unmodifiable(orientations);
    calls.add(copy);
    try {
      // A platform implementation that never answers must not pin the player
      // route open. Playback and exit both continue after this deadline.
      await _request(copy).timeout(const Duration(milliseconds: 300));
      lastError = null;
    } catch (error) {
      lastError = error;
    }
  }

  static bool _same(List<DeviceOrientation> a, List<DeviceOrientation> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Device orientations that match the viewport direction at player entry.
List<DeviceOrientation> phoneOrientationsFor(Orientation orientation) {
  switch (orientation) {
    case Orientation.portrait:
      return const [
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ];
    case Orientation.landscape:
      return PhoneOrientation.landscape;
  }
}
