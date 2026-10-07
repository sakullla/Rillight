import 'package:flutter/services.dart';

typedef PhoneOrientationRequest =
    Future<void> Function(List<DeviceOrientation> orientations);

/// Whether the picture itself is landscape.
///
/// WeChat and YouTube choose fullscreen direction from the video aspect ratio:
/// wider than tall rotates to landscape, and a square or vertical picture stays
/// portrait. Missing or empty dimensions return null so playback does not guess.
bool? videoPictureIsLandscape(int? width, int? height) {
  if (width == null || height == null || width <= 0 || height <= 0) {
    return null;
  }
  return width > height;
}

/// Phone playback orientation taken from the video picture, not the device.
///
/// A landscape picture requests both landscape sides. A portrait or square
/// picture requests both portrait sides. Leaving playback releases every
/// orientation instead of requesting portrait, which would rotate the player
/// that is still on screen.
///
/// [request] is replaceable so tests can observe the calls without rotating a
/// device. A failed request is recorded and swallowed; playback continues.
/// This never writes an activity-wide manifest lock.
class PhoneOrientation {
  PhoneOrientation({PhoneOrientationRequest? request})
    : _request = request ?? systemRequest;

  static const portrait = <DeviceOrientation>[
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ];

  static const landscape = <DeviceOrientation>[
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ];

  /// Browsing default after playback. Not a portrait lock.
  static const unlocked = <DeviceOrientation>[
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ];

  // Orientation is activity-wide. A departing route must not overwrite a newer
  // player's picture.
  static PhoneOrientation? _owner;
  static int _generation = 0;

  static Future<void> systemRequest(List<DeviceOrientation> orientations) {
    return SystemChrome.setPreferredOrientations(orientations);
  }

  final PhoneOrientationRequest _request;

  final List<List<DeviceOrientation>> calls = [];
  Object? lastError;
  bool _entered = false;
  bool? _landscape;
  int? _lease;
  Future<void> _queue = Future<void>.value();

  bool get _ownsLease => identical(_owner, this) && _lease == _generation;

  Future<void> get settled => _queue;

  Future<void> enterPlayback() {
    if (_entered) return _queue;
    _owner = this;
    _lease = ++_generation;
    _entered = true;
    return _queue;
  }

  /// Lock to the picture once its display size is known.
  Future<void> applyPicture({required bool landscape}) {
    if (!_entered || _landscape == landscape) return _queue;
    _landscape = landscape;
    return _enqueueCurrent(
      () => _send(landscape ? PhoneOrientation.landscape : portrait),
    );
  }

  /// Android may recreate its activity while the player is in the background.
  /// Reapply the picture orientation when playback becomes visible again.
  Future<void> reassert() {
    final landscape = _landscape;
    if (!_entered || landscape == null) return _queue;
    return _enqueueCurrent(
      () => _send(landscape ? PhoneOrientation.landscape : portrait),
    );
  }

  Future<void> leavePlayback() {
    if (!_entered) return _queue;
    _entered = false;
    _landscape = null;
    return _enqueueCurrent(() async {
      await _send(unlocked);
      _dropLease();
    });
  }

  void _dropLease() {
    if (_ownsLease && !_entered) _owner = null;
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
}
