import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

typedef PhoneOrientationRequest =
    Future<void> Function(List<DeviceOrientation> orientations);

/// Requests landscape for phone playback and portrait on exit.
///
/// [request] is replaceable so tests can observe the calls without rotating
/// a device. A failed request is recorded and swallowed; playback continues.
/// This never writes an activity-wide manifest lock.
///
/// Exit leaves [restoreTo] in place until the viewport is portrait. Releasing
/// all orientations in the same step could keep the player in landscape when
/// the system's automatic rotation is disabled.
class PhoneOrientation with WidgetsBindingObserver {
  PhoneOrientation({
    PhoneOrientationRequest? request,
    List<DeviceOrientation>? restoreTo,
  }) : _request = request ?? systemRequest,
       restoreTo = List<DeviceOrientation>.unmodifiable(restoreTo ?? portrait);

  static const portrait = <DeviceOrientation>[DeviceOrientation.portraitUp];

  /// Android's userLandscape requests a landscape axis even when automatic
  /// rotation is disabled, while allowing either side when it is enabled.
  static const landscape = <DeviceOrientation>[
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ];

  /// Browsing default: every orientation, released after portrait is visible.
  static const unlocked = <DeviceOrientation>[
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ];

  // Orientation is activity-wide. A departing route must not release a newer
  // player's landscape request after its own delayed metrics callback.
  static PhoneOrientation? _owner;
  static int _generation = 0;

  static Future<void> systemRequest(List<DeviceOrientation> orientations) {
    return SystemChrome.setPreferredOrientations(orientations);
  }

  final PhoneOrientationRequest _request;

  /// Direction to restore when playback exits (portrait on phones by default).
  final List<DeviceOrientation> restoreTo;

  final List<List<DeviceOrientation>> calls = [];
  Object? lastError;
  bool _entered = false;
  bool _awaitingReturn = false;
  bool _observing = false;
  int? _lease;
  Future<void> _queue = Future<void>.value();

  bool get _ownsLease => identical(_owner, this) && _lease == _generation;

  Future<void> get settled => _queue;

  Future<void> enterPlayback() {
    if (_entered) return _queue;
    _owner?._cancelReturn();
    _owner = this;
    _lease = ++_generation;
    _entered = true;
    _cancelReturn();
    return _enqueueCurrent(() => _send(landscape));
  }

  /// Android may recreate its activity while the player is in the background.
  /// Reapply the landscape request when playback becomes visible again.
  Future<void> reassert() {
    if (!_entered) return _queue;
    return _enqueueCurrent(() => _send(landscape));
  }

  Future<void> leavePlayback() {
    if (!_entered) return _queue;
    _entered = false;
    final leaveLease = _lease;
    return _enqueueCurrent(() async {
      final releaseLater = !_same(restoreTo, unlocked);
      if (releaseLater) {
        _awaitingReturn = true;
        _startObserving();
      }
      await _send(restoreTo);
      if (!_ownsLease || _lease != leaveLease) return;
      if (lastError != null || !releaseLater) {
        _cancelReturn();
        _dropLease();
        return;
      }
      // A metrics callback during [restoreTo] may already have released.
      if (!_awaitingReturn) return;
      final current = _viewportOrientation();
      if (current != null && _isEntry(current)) {
        // Already in portrait, so nothing still has to turn back.
        // Wait until after this callback so the four-direction request cannot
        // share the restore step.
        _releaseOnNextFrame();
      }
    });
  }

  @override
  void didChangeMetrics() {
    if (!_awaitingReturn || !_ownsLease) return;
    final current = _viewportOrientation();
    if (current == null || !_isEntry(current)) return;
    _release();
  }

  void _releaseOnNextFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_awaitingReturn || !_ownsLease) return;
      final current = _viewportOrientation();
      if (current == null || !_isEntry(current)) return;
      _release();
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  void _release() {
    if (!_awaitingReturn || !_ownsLease) return;
    _cancelReturn();
    _enqueueCurrent(() async {
      await _send(unlocked);
      _dropLease();
    });
  }

  void _cancelReturn() {
    _awaitingReturn = false;
    _stopObserving();
  }

  void _dropLease() {
    if (_ownsLease && !_entered) _owner = null;
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

  Future<void> _enqueueCurrent(Future<void> Function() action) {
    final lease = _lease;
    return _enqueue(() {
      if (lease == null || !_ownsLease || _lease != lease) {
        return Future<void>.value();
      }
      return action();
    });
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
