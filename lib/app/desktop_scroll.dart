import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show precisionErrorTolerance;
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:rillight/app/desktop_performance_host.dart';

/// Each desktop route owns its primary position, including offstage routes.
class DesktopScrollScope extends StatefulWidget {
  const DesktopScrollScope({super.key, required this.child});

  final Widget child;

  @override
  State<DesktopScrollScope> createState() => _DesktopScrollScopeState();
}

class _DesktopScrollScopeState extends State<DesktopScrollScope> {
  final _controller = DesktopScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PrimaryScrollController(
    controller: _controller,
    automaticallyInheritForPlatforms: const {
      TargetPlatform.windows,
      TargetPlatform.linux,
    },
    child: widget.child,
  );
}

/// Smooth discrete wheel ticks while keeping drag and precision input native.
class DesktopScrollController extends ScrollController {
  DesktopScrollController({super.initialScrollOffset, super.debugLabel});

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => _DesktopScrollPosition(
    physics: physics,
    context: context,
    initialPixels: initialScrollOffset,
    keepScrollOffset: keepScrollOffset,
    oldPosition: oldPosition,
    debugLabel: debugLabel,
  );
}

class _DesktopScrollPosition extends ScrollPositionWithSingleContext {
  _DesktopScrollPosition({
    required super.physics,
    required super.context,
    super.initialPixels,
    super.keepScrollOffset,
    super.oldPosition,
    super.debugLabel,
  });

  @override
  void pointerScroll(double delta) {
    final platform = ScrollConfiguration.of(
      context.storageContext,
    ).getPlatform(context.storageContext);
    if ((platform != TargetPlatform.windows &&
            platform != TargetPlatform.linux) ||
        delta.abs() <= 8) {
      super.pointerScroll(delta);
      return;
    }
    // Discrete Windows/Linux ticks need enough travel to navigate a poster
    // page. Precision input keeps the OS-provided distance above.
    final wheelDelta = delta * 1.6;
    if (DesktopPerformanceHost.systemReducedMotionOf(context.storageContext)) {
      super.pointerScroll(wheelDelta);
      return;
    }
    final wheel = activity is _WheelScrollActivity
        ? activity as _WheelScrollActivity
        : null;
    final pending = wheel?.target;
    // Reverse immediately instead of first consuming the previous direction's
    // remaining distance. Same-direction ticks accumulate without being lost.
    final base = pending != null && (pending - pixels) * delta > 0
        ? pending
        : pixels;
    final target = (base + wheelDelta).clamp(minScrollExtent, maxScrollExtent);
    if (target == pixels) {
      super.pointerScroll(0);
      return;
    }
    updateUserScrollDirection(
      delta < 0 ? ScrollDirection.forward : ScrollDirection.reverse,
    );
    if (wheel != null) {
      wheel.retarget(from: pixels, to: target);
    } else {
      beginActivity(
        _WheelScrollActivity(
          this,
          from: pixels,
          to: target,
          vsync: context.vsync,
        ),
      );
    }
  }
}

/// Keep one ticker alive for a burst. Replacing DrivenScrollActivity on every
/// wheel event resets its first frame to t=0, so input arriving before every
/// vsync can prevent *any* movement until the burst ends.
class _WheelScrollActivity extends ScrollActivity {
  _WheelScrollActivity(
    super.delegate, {
    required double from,
    required double to,
    required TickerProvider vsync,
  }) : _from = from,
       target = to {
    _ticker = vsync.createTicker(_tick)..start();
  }

  late final Ticker _ticker;
  double _from;
  double target;
  Duration _elapsed = Duration.zero;
  Duration _segmentStart = Duration.zero;
  double _velocity = 0;
  static const _durationUs = 60000;

  void retarget({required double from, required double to}) {
    _from = from;
    target = to;
    _segmentStart = _elapsed;
  }

  void _tick(Duration elapsed) {
    _elapsed = elapsed;
    final t = ((elapsed - _segmentStart).inMicroseconds / _durationUs).clamp(
      0.0,
      1.0,
    );
    final value = _from + (target - _from) * Curves.easeOutCubic.transform(t);
    _velocity = (target - _from) * 3 * (1 - t) * (1 - t) / .06;
    if (delegate.setPixels(value).abs() > precisionErrorTolerance) {
      delegate.goIdle();
    } else if (t >= 1) {
      delegate.goBallistic(0);
    }
  }

  @override
  bool get shouldIgnorePointer => true;
  @override
  bool get isScrolling => true;
  @override
  double get velocity => _velocity;
  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }
}
