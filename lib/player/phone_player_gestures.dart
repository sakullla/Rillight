import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:rillight/player/player_controller.dart';

/// `mm:ss` / `h:mm:ss` clock used by gesture and control overlays.
String phonePlayerClock(Duration value) {
  final hours = value.inHours;
  final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = (value.inSeconds % 60).toString().padLeft(2, '0');
  if (hours > 0) return '$hours:$minutes:$seconds';
  return '$minutes:$seconds';
}

/// System brightness / volume access for the gesture layer (ADR-6).
///
/// The default implementation talks to the `rillight/android_core`
/// MethodChannel backed by the owned core plugin. Where the
/// platform side is missing (widget tests, desktop embedders) it degrades
/// to an in-memory value so the gesture feedback chain keeps working.
abstract class PhoneDisplayControl {
  Future<double> brightness();
  Future<void> setBrightness(double value);
  Future<double> volume();
  Future<void> setVolume(double value);
}

class MethodChannelPhoneDisplayControl implements PhoneDisplayControl {
  MethodChannelPhoneDisplayControl({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('rillight/android_core');

  final MethodChannel _channel;
  double _brightness = 0.5;
  double _volume = 0.5;

  @override
  Future<double> brightness() async {
    try {
      final value = await _channel.invokeMethod<double>('getSystemBrightness');
      if (value != null && value >= 0) _brightness = value;
    } catch (_) {
      // No platform side: keep the last known / default value.
    }
    return _brightness;
  }

  @override
  Future<void> setBrightness(double value) async {
    _brightness = value;
    try {
      await _channel.invokeMethod<void>('setSystemBrightness', {
        'value': value,
      });
    } catch (_) {
      // A device that ignores window brightness must not break gestures.
    }
  }

  @override
  Future<double> volume() async {
    try {
      final value = await _channel.invokeMethod<double>('getSystemVolume');
      if (value != null) _volume = value;
    } catch (_) {
      // No platform side: keep the last known / default value.
    }
    return _volume;
  }

  @override
  Future<void> setVolume(double value) async {
    _volume = value;
    try {
      await _channel.invokeMethod<void>('setSystemVolume', {'value': value});
    } catch (_) {
      // Channel failures must not break gestures.
    }
  }
}

enum _GestureOverlayKind { tapBack, tapForward, brightness, volume, seek }

class _GestureOverlay {
  const _GestureOverlay(this.kind, this.value);

  final _GestureOverlayKind kind;

  /// 0..1 for brightness / volume, target milliseconds for seek, null for
  /// the double-tap indicators.
  final double? value;
}

/// Gesture layer of the phone player. Sits above the video view and below
/// the control layer; the danmaku layer above stays `IgnorePointer`.
///
/// - single tap: toggle the control layer (unlock when [locked]);
/// - double tap on the left / right half: seek ∓10 seconds;
/// - vertical drag on the left half: system brightness, right half: system
///   volume (live overlay feedback);
/// - horizontal drag: relative seek, committed on release with a live
///   target-time preview.
///
/// Arena arbitration relies on `GestureDetector`: the double-tap recognizer
/// claims the arena before the tap timer fires, so a double tap never also
/// triggers the single-tap toggle.
class PhonePlayerGestures extends StatefulWidget {
  const PhonePlayerGestures({
    super.key,
    required this.controller,
    required this.display,
    this.locked = false,
    this.onUnlock,
  });

  final PlayerController controller;
  final PhoneDisplayControl display;

  /// Locked screens keep only the single-tap unlock gesture.
  final bool locked;
  final VoidCallback? onUnlock;

  @override
  State<PhonePlayerGestures> createState() => _PhonePlayerGesturesState();
}

class _PhonePlayerGesturesState extends State<PhonePlayerGestures> {
  static const double _seekSecondsPerPixel = 0.2;

  _GestureOverlay? _overlay;
  Timer? _overlayTimer;
  double? _brightness;
  double? _systemVolume;
  double _seekBaseMs = 0;
  double _seekDeltaMs = 0;

  PlayerController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    unawaited(_readDisplay());
  }

  Future<void> _readDisplay() async {
    final brightness = await widget.display.brightness();
    final volume = await widget.display.volume();
    if (!mounted) return;
    _brightness = brightness;
    _systemVolume = volume;
  }

  @override
  void dispose() {
    _overlayTimer?.cancel();
    super.dispose();
  }

  void _showOverlay(
    _GestureOverlay overlay, {
    Duration hideAfter = Duration.zero,
  }) {
    _overlayTimer?.cancel();
    setState(() => _overlay = overlay);
    if (hideAfter > Duration.zero) {
      _overlayTimer = Timer(hideAfter, () {
        if (mounted) setState(() => _overlay = null);
      });
    }
  }

  void _clearOverlay() {
    _overlayTimer?.cancel();
    if (_overlay != null && mounted) setState(() => _overlay = null);
  }

  void _onTap() {
    if (widget.locked) {
      widget.onUnlock?.call();
      return;
    }
    _controller.toggleControls();
  }

  void _onDoubleTap(TapDownDetails details) {
    final width = context.size?.width ?? 0;
    final left = details.localPosition.dx < width / 2;
    if (left) {
      _controller.seekRelative(const Duration(seconds: -10));
      _showOverlay(
        const _GestureOverlay(_GestureOverlayKind.tapBack, null),
        hideAfter: const Duration(milliseconds: 500),
      );
    } else {
      _controller.seekRelative(const Duration(seconds: 10));
      _showOverlay(
        const _GestureOverlay(_GestureOverlayKind.tapForward, null),
        hideAfter: const Duration(milliseconds: 500),
      );
    }
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    final size = context.size;
    if (size == null || size.height <= 0) return;
    final left = details.localPosition.dx < size.width / 2;
    if (left) {
      final base = _brightness ?? 0.5;
      final value = (base - details.delta.dy / size.height).clamp(0.0, 1.0);
      _brightness = value;
      unawaited(widget.display.setBrightness(value));
      _showOverlay(_GestureOverlay(_GestureOverlayKind.brightness, value));
    } else {
      final base = _systemVolume ?? 0.5;
      final value = (base - details.delta.dy / size.height).clamp(0.0, 1.0);
      _systemVolume = value;
      unawaited(widget.display.setVolume(value));
      _showOverlay(_GestureOverlay(_GestureOverlayKind.volume, value));
    }
  }

  void _onHorizontalDragStart(DragStartDetails details) {
    _seekBaseMs = _controller.position.inMilliseconds.toDouble();
    _seekDeltaMs = 0;
  }

  double get _seekTargetMs {
    final durationMs = _controller.duration.inMilliseconds.toDouble().clamp(
      0,
      double.infinity,
    );
    return (_seekBaseMs + _seekDeltaMs).clamp(0, durationMs).toDouble();
  }

  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    _seekDeltaMs += details.delta.dx * _seekSecondsPerPixel * 1000;
    _showOverlay(_GestureOverlay(_GestureOverlayKind.seek, _seekTargetMs));
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    final target = _seekTargetMs;
    _clearOverlay();
    _controller.seekTo(Duration(milliseconds: target.round()));
  }

  @override
  Widget build(BuildContext context) {
    final locked = widget.locked;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _onTap,
      onDoubleTapDown: locked ? null : _onDoubleTap,
      onVerticalDragStart: locked ? null : (_) {},
      onVerticalDragUpdate: locked ? null : _onVerticalDragUpdate,
      onVerticalDragEnd: locked ? null : (_) => _clearOverlay(),
      onHorizontalDragStart: locked ? null : _onHorizontalDragStart,
      onHorizontalDragUpdate: locked ? null : _onHorizontalDragUpdate,
      onHorizontalDragEnd: locked ? null : _onHorizontalDragEnd,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_overlay != null) Center(child: _OverlayView(overlay: _overlay!)),
        ],
      ),
    );
  }
}

class _OverlayView extends StatelessWidget {
  const _OverlayView({required this.overlay});

  final _GestureOverlay overlay;

  @override
  Widget build(BuildContext context) {
    final icon = switch (overlay.kind) {
      _GestureOverlayKind.tapBack => Icons.replay_10,
      _GestureOverlayKind.tapForward => Icons.forward_10,
      _GestureOverlayKind.brightness => Icons.brightness_6,
      _GestureOverlayKind.volume => Icons.volume_up,
      _GestureOverlayKind.seek => Icons.schedule,
    };
    final Widget? label = switch (overlay.kind) {
      _GestureOverlayKind.brightness || _GestureOverlayKind.volume => Text(
        key: const Key('mobile-player-gesture-value'),
        '${((overlay.value ?? 0) * 100).round()}%',
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
      ),
      _GestureOverlayKind.seek => Text(
        key: const Key('mobile-player-gesture-seek'),
        phonePlayerClock(Duration(milliseconds: (overlay.value ?? 0).round())),
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
      ),
      _ => null,
    };
    return Container(
      key: const Key('mobile-player-gesture-overlay'),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 32),
          if (label != null) ...[const SizedBox(height: 8), label],
        ],
      ),
    );
  }
}
