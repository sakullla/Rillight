import 'dart:async';

/// Detects loss of renderer progress, not changes in image content. An ordinary
/// video with identical pictures still publishes frames and remains healthy.
/// Unknown/very low frame rates and images are deliberately not diagnosed as
/// frozen from a frame counter alone.
class SurfaceHealth {
  SurfaceHealth({
    required this.readStatus,
    required this.readTracks,
    required this.onStatus,
    required this.onError,
    this.statusTimeout = const Duration(seconds: 5),
    this.stallTimeout = const Duration(seconds: 8),
    Duration Function()? now,
  }) : _now = now ?? _monotonicClock();

  final Future<Map<String, dynamic>?> Function() readStatus;
  final Future<Object?> Function() readTracks;
  final void Function(Map<String, dynamic>) onStatus;
  final void Function(String) onError;
  final Duration statusTimeout;
  final Duration stallTimeout;
  final Duration Function() _now;
  static const _positionFreshness = Duration(seconds: 2);
  bool _closed = false;
  bool _failed = false;
  bool _polling = false;
  bool _loaded = false;
  bool _movingVideo = false;
  bool _seeking = false;
  bool _ended = false;
  bool? _paused;
  bool? _buffering;
  bool? _idle;
  double? _position;
  Duration? _lastAdvance;
  Duration? _watchSince;
  double? _watchPosition;
  int? _frames;
  int _mediaGeneration = 0;
  int _tracksRevision = 0;
  int? _inspectedGeneration;
  Timer? _deadline;
  Completer<Map<String, dynamic>?>? _pendingStatus;

  static Duration Function() _monotonicClock() {
    final clock = Stopwatch()..start();
    return () => clock.elapsed;
  }

  void event(String type, {String? property, Object? value}) {
    if (_closed || _failed) return;
    switch (type) {
      case 'start-file':
        ++_mediaGeneration;
        ++_tracksRevision;
        _loaded = _movingVideo = _seeking = _ended = false;
        _position = null;
        _lastAdvance = null;
        _frames = null;
        _resetGrace();
      case 'file-loaded':
        _loaded = true;
        _ended = _seeking = false;
        _resetGrace();
        if (_inspectedGeneration != _mediaGeneration) {
          _inspectedGeneration = _mediaGeneration;
          unawaited(_inspectTracks());
        }
      case 'seek':
        _seeking = true;
        _ended = false;
        _lastAdvance = null;
        _resetGrace();
      case 'playback-restart':
        _seeking = false;
        _lastAdvance = null;
        _resetGrace();
      case 'end-file':
        _loaded = false;
        _ended = true;
        _resetGrace();
      case 'property':
        _property(property, value);
    }
  }

  Future<void> _inspectTracks() async {
    final generation = _mediaGeneration;
    final revision = _tracksRevision;
    try {
      final tracks = await readTracks();
      if (_closed ||
          _failed ||
          generation != _mediaGeneration ||
          revision != _tracksRevision) {
        return;
      }
      _setTracks(tracks);
    } catch (_) {
      // The observed track-list may still provide metadata later. Missing
      // metadata cannot justify a stall diagnosis.
    }
  }

  void _setTracks(Object? tracks) {
    final moving =
        tracks is List &&
        tracks.any((track) {
          if (track is! Map ||
              track['type'] != 'video' ||
              track['selected'] != true ||
              track['image'] == true ||
              track['albumart'] == true) {
            return false;
          }
          final fps = track['demux-fps'];
          return fps is num && fps.isFinite && fps >= 2;
        });
    if (_movingVideo != moving) {
      _movingVideo = moving;
      _resetGrace();
    }
  }

  void _property(String? property, Object? value) {
    switch (property) {
      case 'track-list':
        ++_tracksRevision;
        _setTracks(value);
      case 'pause':
        final paused = value is bool ? value : null;
        if (paused != _paused) {
          _paused = paused;
          _lastAdvance = null;
          _resetGrace();
        }
      case 'paused-for-cache':
        final buffering = value is bool ? value : null;
        if (buffering != _buffering) {
          _buffering = buffering;
          _lastAdvance = null;
          _resetGrace();
        }
      case 'core-idle':
        final idle = value is bool ? value : null;
        if (idle != _idle) {
          _idle = idle;
          _lastAdvance = null;
          _resetGrace();
        }
      case 'eof-reached':
        if (value is bool && value != _ended) {
          _ended = value;
          _lastAdvance = null;
          _resetGrace();
        }
      case 'time-pos':
        if (value is! num || !value.isFinite || value < 0) {
          _position = null;
          _lastAdvance = null;
          _resetGrace();
          return;
        }
        final previous = _position;
        _position = value.toDouble();
        if (previous == null || value < previous) {
          _lastAdvance = null;
          _resetGrace();
        } else if (value > previous) {
          final now = _now();
          if (_lastAdvance == null ||
              now - _lastAdvance! > _positionFreshness) {
            _resetGrace();
          }
          _lastAdvance = now;
        }
    }
  }

  void _resetGrace() {
    _watchSince = _now();
    _watchPosition = _position;
  }

  bool _stalled(int frames) {
    final now = _now();
    final advancing =
        _lastAdvance != null && now - _lastAdvance! <= _positionFreshness;
    if (frames != _frames ||
        !_loaded ||
        !_movingVideo ||
        _seeking ||
        _ended ||
        _paused != false ||
        _buffering != false ||
        _idle != false ||
        !advancing) {
      _frames = frames;
      _resetGrace();
      return false;
    }
    return _watchSince != null &&
        _position != null &&
        _watchPosition != null &&
        // Count only time up to an observed clock advance. Polling after a
        // clock has stopped must not turn its freshness allowance into motion.
        _lastAdvance! - _watchSince! >= stallTimeout &&
        _position! - _watchPosition! >= .5;
  }

  /// At most one status request is outstanding. Timeout/error is terminal;
  /// native replies which arrive after timeout, close or another load cannot
  /// revive status/first-frame notifications.
  Future<void> poll() async {
    if (_closed || _failed || _polling) return;
    _polling = true;
    final generation = _mediaGeneration;
    final pending = Completer<Map<String, dynamic>?>();
    _pendingStatus = pending;
    _deadline = Timer(statusTimeout, () {
      if (!pending.isCompleted) {
        pending.completeError(
          TimeoutException('Native video status timed out', statusTimeout),
        );
      }
    });
    Future<Map<String, dynamic>?>.sync(readStatus).then(
      (status) {
        if (!pending.isCompleted) pending.complete(status);
      },
      onError: (Object error, StackTrace stack) {
        if (!pending.isCompleted) pending.completeError(error, stack);
      },
    );
    Map<String, dynamic>? status;
    try {
      status = await pending.future;
    } catch (error) {
      if (!_closed && generation == _mediaGeneration) _fail(error.toString());
      return;
    } finally {
      _deadline?.cancel();
      _deadline = null;
      _pendingStatus = null;
      _polling = false;
    }
    if (_closed || _failed || generation != _mediaGeneration) return;
    final frames = status?['frames'];
    if (status == null || frames is! int || frames < 0) {
      _fail('Invalid native video status');
      return;
    }
    if (status['error'] case final String error when error.isNotEmpty) {
      _fail(error);
      return;
    }
    if (_stalled(frames)) {
      _fail('Video frames stopped while playback continued');
      return;
    }
    onStatus(status);
  }

  void _fail(String message) {
    if (_closed || _failed) return;
    _failed = true;
    onError(message);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    ++_mediaGeneration;
    _deadline?.cancel();
    final pending = _pendingStatus;
    if (pending != null && !pending.isCompleted) pending.complete(null);
  }
}
