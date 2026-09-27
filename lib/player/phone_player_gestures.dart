import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/player/player_controller.dart';
import 'package:rillight/player/phone/phone_player_interaction.dart';

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
/// MethodChannel backed by the owned core plugin. A missing platform method
/// reports a failure to the gesture layer instead of inventing a percentage.
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
  @override
  Future<double> brightness() async {
    final value = await _channel.invokeMethod<double>('getSystemBrightness');
    if (value == null || value < 0 || value > 1) {
      throw StateError('Brightness unavailable');
    }
    return value;
  }

  @override
  Future<void> setBrightness(double value) async {
    await _channel.invokeMethod<void>('setSystemBrightness', {'value': value});
  }

  @override
  Future<double> volume() async {
    final value = await _channel.invokeMethod<double>('getSystemVolume');
    if (value == null || value < 0 || value > 1) {
      throw StateError('Volume unavailable');
    }
    return value;
  }

  @override
  Future<void> setVolume(double value) async {
    await _channel.invokeMethod<void>('setSystemVolume', {'value': value});
  }
}

enum _GestureOverlayKind {
  tapBack,
  tapForward,
  brightness,
  volume,
  seek,
  unavailable,
}

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
/// - single tap: toggle controls, or reveal the explicit unlock button;
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
    required this.interaction,
  });

  final PlayerController controller;
  final PhoneDisplayControl display;

  final PhonePlayerInteraction interaction;

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
  bool _dragAllowed = false;
  bool _verticalLeft = false;
  int _inputGeneration = 0;
  bool _brightnessAvailable = false;
  bool _volumeAvailable = false;
  Object? _playbackIdentity;
  TapDownDetails? _doubleTapDown;

  bool get _canSeek => widget.interaction.canSeek(_controller);

  bool _inSystemEdge(Offset local) {
    final width = context.size?.width ?? 0;
    final insets = MediaQuery.of(context).systemGestureInsets;
    return local.dx < insets.left + 24 || local.dx > width - insets.right - 24;
  }

  void _onVerticalDragStart(DragStartDetails details) {
    _dragAllowed =
        !widget.interaction.locked &&
        !_controller.loading &&
        _controller.error == null &&
        !_controller.disconnected &&
        !_controller.sessionExpired &&
        !_inSystemEdge(details.localPosition);
    _verticalLeft = details.localPosition.dx < (context.size?.width ?? 0) / 2;
  }

  Future<void> _applyDisplay(double value, {required bool brightness}) async {
    final generation = _inputGeneration;
    try {
      if (brightness) {
        await widget.display.setBrightness(value);
      } else {
        await widget.display.setVolume(value);
      }
      if (!mounted || generation != _inputGeneration) return;
      if (brightness) {
        _brightness = value;
      } else {
        _systemVolume = value;
      }
      _showOverlay(
        _GestureOverlay(
          brightness
              ? _GestureOverlayKind.brightness
              : _GestureOverlayKind.volume,
          value,
        ),
      );
    } catch (_) {
      if (!mounted || generation != _inputGeneration) return;
      if (brightness) {
        _brightnessAvailable = false;
      } else {
        _volumeAvailable = false;
      }
      _showOverlay(
        const _GestureOverlay(_GestureOverlayKind.unavailable, null),
      );
    }
  }

  PlayerController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onPlayback);
    widget.interaction.addListener(_onInteraction);
    _playbackIdentity = _identity();
    unawaited(_readDisplay());
  }

  Object _identity() => (
    _controller.itemId,
    _controller.loading,
    _controller.error,
    _controller.disconnected,
    _controller.sessionExpired,
    _controller.playbackEnded,
  );

  void _onPlayback() {
    final next = _identity();
    if (next == _playbackIdentity) return;
    _playbackIdentity = next;
    _cancelInput();
  }

  void _onInteraction() => _cancelInput();

  void _cancelInput() {
    _inputGeneration++;
    _dragAllowed = false;
    _clearOverlay();
  }

  Future<void> _readDisplay() async {
    await Future.wait([_readBrightness(), _readVolume()]);
  }

  Future<void> _readBrightness() async {
    try {
      final brightness = await widget.display.brightness();
      if (!mounted || brightness < 0 || brightness > 1) return;
      _brightness = brightness;
      _brightnessAvailable = true;
    } catch (_) {
      _brightnessAvailable = false;
    }
  }

  Future<void> _readVolume() async {
    try {
      final volume = await widget.display.volume();
      if (!mounted || volume < 0 || volume > 1) return;
      _systemVolume = volume;
      _volumeAvailable = true;
    } catch (_) {
      _volumeAvailable = false;
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onPlayback);
    widget.interaction.removeListener(_onInteraction);
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
    if (widget.interaction.locked) {
      widget.interaction.revealUnlock();
      return;
    }
    _controller.toggleControls();
  }

  void _onDoubleTap(TapDownDetails details) {
    if (!_canSeek || widget.interaction.locked) return;
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

  void _commitDoubleTap() {
    final details = _doubleTapDown;
    _doubleTapDown = null;
    if (details != null) _onDoubleTap(details);
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    if (!_dragAllowed || widget.interaction.locked) return;
    final size = context.size;
    if (size == null || size.height <= 0) return;
    if (_verticalLeft ? !_brightnessAvailable : !_volumeAvailable) {
      _showOverlay(
        const _GestureOverlay(_GestureOverlayKind.unavailable, null),
      );
      return;
    }
    if (_verticalLeft) {
      final base = _brightness!;
      final value = (base - details.delta.dy / size.height).clamp(0.0, 1.0);
      unawaited(_applyDisplay(value, brightness: true));
    } else {
      final base = _systemVolume!;
      final value = (base - details.delta.dy / size.height).clamp(0.0, 1.0);
      unawaited(_applyDisplay(value, brightness: false));
    }
  }

  void _onHorizontalDragStart(DragStartDetails details) {
    _dragAllowed = _canSeek && !_inSystemEdge(details.localPosition);
    if (!_dragAllowed) return;
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
    if (!_dragAllowed || !_canSeek || widget.interaction.locked) return;
    _seekDeltaMs += details.delta.dx * _seekSecondsPerPixel * 1000;
    _showOverlay(_GestureOverlay(_GestureOverlayKind.seek, _seekTargetMs));
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    if (!_dragAllowed || !_canSeek || widget.interaction.locked) {
      _cancelInput();
      return;
    }
    _dragAllowed = false;
    final target = _seekTargetMs;
    _clearOverlay();
    _controller.seekTo(Duration(milliseconds: target.round()));
  }

  @override
  Widget build(BuildContext context) {
    final locked = widget.interaction.locked;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _onTap,
      onDoubleTapDown: locked ? null : (details) => _doubleTapDown = details,
      onDoubleTap: locked ? null : _commitDoubleTap,
      onDoubleTapCancel: () => _doubleTapDown = null,
      onVerticalDragStart: locked ? null : _onVerticalDragStart,
      onVerticalDragUpdate: locked ? null : _onVerticalDragUpdate,
      onVerticalDragEnd: locked ? null : (_) => _cancelInput(),
      onVerticalDragCancel: _cancelInput,
      onHorizontalDragStart: locked ? null : _onHorizontalDragStart,
      onHorizontalDragUpdate: locked ? null : _onHorizontalDragUpdate,
      onHorizontalDragEnd: locked ? null : _onHorizontalDragEnd,
      onHorizontalDragCancel: _cancelInput,
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
      _GestureOverlayKind.unavailable => Icons.info_outline,
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
      _GestureOverlayKind.unavailable => Text(
        AppLocalizations.of(context).mobileGestureUnavailable,
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
