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
///
/// Exit leaves [restoreTo] in place. Android treats all four orientations as
/// sensor follow, so requesting them in the same step replaces the entry
/// direction before the activity has turned back. A later rotation is released
/// only after the viewport is observed on that entry direction.
class PhoneOrientation with WidgetsBindingObserver {
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
  /// Not requested until the viewport is already back on [restoreTo].
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
  bool _awaitingReturn = false;
  bool _observing = false;
  Future<void> _queue = Future<void>.value();

  Future<void> get settled => _queue;

  Future<void> enterPlayback() {
    if (_entered) return _queue;
    _entered = true;
    _awaitingReturn = false;
    _stopObserving();
    return _enqueue(() => _send(landscape));
  }

  Future<void> leavePlayback() {
    if (!_entered) return _queue;
    _entered = false;
    return _enqueue(() async {
      final releaseLater = !_same(restoreTo, unlocked);
      if (releaseLater) {
        _awaitingReturn = true;
        _startObserving();
      }
      await _send(restoreTo);
      if (lastError != null || !releaseLater) {
        _awaitingReturn = false;
        _stopObserving();
        return;
      }
      // A metrics callback during [restoreTo] may already have released.
      if (!_awaitingReturn) return;
      final current = _viewportOrientation();
      if (current != null && _isEntry(current)) {
        // Already on the entry direction, so nothing still has to turn back.
        // Wait until after this callback so the four-direction request cannot
        // share the restore step.
        _releaseOnNextFrame();
      }
    });
  }

  @override
  void didChangeMetrics() {
    if (!_awaitingReturn) return;
    final current = _viewportOrientation();
    if (current == null || !_isEntry(current)) return;
    _release();
  }

  void _releaseOnNextFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_awaitingReturn) return;
      final current = _viewportOrientation();
      if (current == null || !_isEntry(current)) return;
      _release();
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  void _release() {
    if (!_awaitingReturn) return;
    _awaitingReturn = false;
    _stopObserving();
    _enqueue(() => _send(unlocked));
  }

  void _startObserving() {
    if (_observing) return;
    _observing = true;
    WidgetsBinding.instance.addObserver(this);
  }

  void _stopObserving() {
    if (!_observing) return;
    _observing = false;
    WidgetsBinding.instance.removeObserver(this);
  }

  /// Viewport axis, or null when the window has no size yet.
  Orientation? _viewportOrientation() {
    final view = WidgetsBinding.instance.platformDispatcher.implicitView;
    if (view == null) return null;
    final size = view.physicalSize;
    if (size.isEmpty) return null;
    return size.width > size.height
        ? Orientation.landscape
        : Orientation.portrait;
  }

  bool _isEntry(Orientation orientation) {
    if (restoreTo.isEmpty) return false;
    final portrait = orientation == Orientation.portrait;
    for (final direction in restoreTo) {
      final directionIsPortrait =
          direction == DeviceOrientation.portraitUp ||
          direction == DeviceOrientation.portraitDown;
      if (directionIsPortrait != portrait) return false;
    }
    return true;
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
