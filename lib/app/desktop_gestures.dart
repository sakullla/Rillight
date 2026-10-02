import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A navigation drag joins the arena, so a horizontal shelf gets first refusal.
class DesktopNavigationGestures extends StatefulWidget {
  const DesktopNavigationGestures({
    super.key,
    required this.child,
    this.onBack,
    this.onForward,
  });
  final Widget child;
  final VoidCallback? onBack, onForward;
  @override
  State<DesktopNavigationGestures> createState() =>
      _DesktopNavigationGesturesState();
}

class _DesktopNavigationGesturesState extends State<DesktopNavigationGestures> {
  double _distance = 0;
  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.macOS) return widget.child;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.bracketLeft, meta: true): () =>
            widget.onBack?.call(),
        const SingleActivator(
          LogicalKeyboardKey.bracketRight,
          meta: true,
        ): () =>
            widget.onForward?.call(),
      },
      child: Listener(
        onPointerDown: (event) {
          if (event.buttons == kBackMouseButton) widget.onBack?.call();
          if (event.buttons == kForwardMouseButton) widget.onForward?.call();
        },
        child: GestureDetector(
          supportedDevices: const {PointerDeviceKind.trackpad},
          behavior: HitTestBehavior.translucent,
          onHorizontalDragStart: (_) => _distance = 0,
          onHorizontalDragUpdate: (event) => _distance += event.delta.dx,
          onHorizontalDragCancel: () => _distance = 0,
          onHorizontalDragEnd: (_) {
            if (_distance > 80) widget.onBack?.call();
            if (_distance < -80) widget.onForward?.call();
            _distance = 0;
          },
          child: widget.child,
        ),
      ),
    );
  }
}

enum _PlaybackGesture { seek, volume, zoom }

/// Trackpad movement previews locally; a seek is issued once on release.
class DesktopPlaybackGestures extends StatefulWidget {
  const DesktopPlaybackGestures({
    super.key,
    required this.child,
    required this.position,
    required this.duration,
    required this.volume,
    required this.onSeek,
    required this.onVolume,
    required this.onFullScreen,
    this.enabled = true,
  });
  final Widget child;
  final Duration position, duration;
  final int volume;
  final bool enabled;
  final Future<void> Function(Duration) onSeek;
  final Future<void> Function(int) onVolume;
  final Future<void> Function(bool) onFullScreen;
  @override
  State<DesktopPlaybackGestures> createState() =>
      _DesktopPlaybackGesturesState();
}

class _DesktopPlaybackGesturesState extends State<DesktopPlaybackGestures> {
  Offset _pan = Offset.zero;
  Duration _start = Duration.zero;
  int _startVolume = 0;
  double _scale = 1;
  _PlaybackGesture? _gesture;
  Timer? _wheelEnd;

  Duration get _target => Duration(
    milliseconds: (_start.inMilliseconds + _pan.dx * 100).round().clamp(
      0,
      widget.duration.inMilliseconds,
    ),
  );
  int get _volume => (_startVolume - _pan.dy / 8).round().clamp(0, 150);

  @override
  void dispose() {
    _wheelEnd?.cancel();
    super.dispose();
  }

  void _startGesture() {
    _wheelEnd?.cancel();
    _start = widget.position;
    _startVolume = widget.volume;
    _pan = Offset.zero;
    _scale = 1;
    _gesture = null;
  }

  void _finish() {
    final mode = _gesture;
    final target = _target, volume = _volume, scale = _scale;
    final distance = _pan.dx.abs();
    setState(() => _gesture = null);
    if (!widget.enabled) return;
    if (mode == _PlaybackGesture.seek &&
        distance >= 24 &&
        widget.duration > Duration.zero) {
      unawaited(widget.onSeek(target));
    } else if (mode == _PlaybackGesture.volume) {
      unawaited(widget.onVolume(volume));
    } else if (mode == _PlaybackGesture.zoom && (scale > 1.18 || scale < .82)) {
      unawaited(widget.onFullScreen(scale > 1));
    }
  }

  void _scroll(PointerSignalEvent event) {
    if (!widget.enabled || event is! PointerScrollEvent) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      if (event.scrollDelta.dx.abs() > event.scrollDelta.dy.abs() * 1.5) {
        if (_wheelEnd == null || !_wheelEnd!.isActive) _startGesture();
        setState(() {
          _gesture = _PlaybackGesture.seek;
          _pan += Offset(-event.scrollDelta.dx, 0);
        });
        _wheelEnd?.cancel();
        _wheelEnd = Timer(const Duration(milliseconds: 180), _finish);
      } else if (event.scrollDelta.dy != 0) {
        unawaited(
          widget.onVolume(
            (widget.volume + (event.scrollDelta.dy < 0 ? 5 : -5)).clamp(0, 150),
          ),
        );
      }
    });
  }

  String _clock(Duration value) {
    final s = value.inSeconds;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.macOS) return widget.child;
    return Listener(
      onPointerSignal: _scroll,
      child: GestureDetector(
        supportedDevices: const {PointerDeviceKind.trackpad},
        behavior: HitTestBehavior.translucent,
        onScaleStart: widget.enabled ? (_) => _startGesture() : null,
        onScaleUpdate: widget.enabled
            ? (event) {
                setState(() {
                  _pan += event.focalPointDelta;
                  _scale = event.scale;
                  if ((_scale - 1).abs() > .08) {
                    _gesture = _PlaybackGesture.zoom;
                  } else if (_gesture != _PlaybackGesture.zoom &&
                      _pan.distance > 8) {
                    _gesture ??= _pan.dx.abs() > _pan.dy.abs() * 1.5
                        ? _PlaybackGesture.seek
                        : _PlaybackGesture.volume;
                  }
                });
              }
            : null,
        onScaleEnd: widget.enabled ? (_) => _finish() : null,
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            widget.child,
            if (_gesture != null)
              Positioned.fill(
                child: IgnorePointer(
                  child: Center(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.black87,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 16,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _gesture == _PlaybackGesture.seek
                                  ? Icons.fast_forward
                                  : _gesture == _PlaybackGesture.volume
                                  ? Icons.volume_up
                                  : Icons.fullscreen,
                              color: Colors.white,
                            ),
                            const SizedBox(width: 12),
                            Text(
                              _gesture == _PlaybackGesture.seek
                                  ? _clock(_target)
                                  : _gesture == _PlaybackGesture.volume
                                  ? '$_volume%'
                                  : '${(_scale * 100).round()}%',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 22,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
