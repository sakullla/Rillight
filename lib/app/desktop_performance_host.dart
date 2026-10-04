import 'dart:collection';
import 'dart:ui' show FramePhase, FrameTiming;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Use measured raster pressure rather than guessing GPU speed from its name.
/// Once effects are reduced, keep that choice until this window is closed to
/// avoid switching effects back on as soon as the cheaper frames recover.
class DesktopPerformanceHost extends StatefulWidget {
  const DesktopPerformanceHost({
    super.key,
    required this.child,
    this.monitorTimings = !kDebugMode,
  });

  final Widget child;
  final bool monitorTimings;

  /// Raster adaptation reduces optional effects; wheel motion still follows
  /// the user's original accessibility preference.
  static bool systemReducedMotionOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_SystemMotionPreference>()
          ?.disabled ??
      MediaQuery.disableAnimationsOf(context);

  @override
  State<DesktopPerformanceHost> createState() => _DesktopPerformanceHostState();
}

class _DesktopPerformanceHostState extends State<DesktopPerformanceHost> {
  final _slowFrames = Queue<bool>();
  bool _reduceEffects = false;
  bool _listening = false;
  double _rasterBudgetUs = 1000000 / 60;
  int? _lastRasterStart;

  @override
  void initState() {
    super.initState();
    _syncListener();
  }

  void _syncListener() {
    final listen = widget.monitorTimings && !_reduceEffects;
    if (listen == _listening) return;
    _listening = listen;
    if (listen) {
      WidgetsBinding.instance.addTimingsCallback(_onTimings);
    } else {
      WidgetsBinding.instance.removeTimingsCallback(_onTimings);
      _slowFrames.clear();
      _lastRasterStart = null;
    }
  }

  @override
  void didUpdateWidget(DesktopPerformanceHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncListener();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final refreshRate = View.of(context).display.refreshRate;
    final budget = 1000000 / (refreshRate > 0 ? refreshRate : 60);
    if (_rasterBudgetUs != budget) _slowFrames.clear();
    _rasterBudgetUs = budget;
  }

  void _onTimings(List<FrameTiming> timings) {
    if (!mounted || !_listening) return;
    for (final timing in timings) {
      final rasterStart = timing.timestampInMicroseconds(
        FramePhase.rasterStart,
      );
      final previousStart = _lastRasterStart;
      if (previousStart != null && rasterStart - previousStart > 500000) {
        _slowFrames.clear();
      }
      _lastRasterStart = rasterStart;
      // UI/build delays cannot establish GPU pressure. A single slow upload or
      // route's first frame must not permanently change the window's effects.
      _slowFrames.add(timing.rasterDuration.inMicroseconds > _rasterBudgetUs);
      if (_slowFrames.length > 12) _slowFrames.removeFirst();
      if (_slowFrames.length == 12 &&
          _slowFrames.where((slow) => slow).length >= 8) {
        setState(() => _reduceEffects = true);
        _syncListener();
        return;
      }
    }
  }

  @override
  void dispose() {
    if (_listening) {
      WidgetsBinding.instance.removeTimingsCallback(_onTimings);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    // Keep the wrapper present before and after adaptation so navigation,
    // scroll positions, focus and loaded artwork remain mounted.
    return _SystemMotionPreference(
      disabled: media.disableAnimations,
      child: MediaQuery(
        data: _reduceEffects ? media.copyWith(disableAnimations: true) : media,
        child: widget.child,
      ),
    );
  }
}

class _SystemMotionPreference extends InheritedWidget {
  const _SystemMotionPreference({required this.disabled, required super.child});

  final bool disabled;

  @override
  bool updateShouldNotify(_SystemMotionPreference oldWidget) =>
      disabled != oldWidget.disabled;
}
