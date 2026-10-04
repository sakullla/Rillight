import 'package:flutter/material.dart';
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

  double? _wheelTarget;
  int _wheelGeneration = 0;

  void _cancelWheelTarget() {
    _wheelTarget = null;
    _wheelGeneration++;
  }

  @override
  void pointerScroll(double delta) {
    final platform = ScrollConfiguration.of(
      context.storageContext,
    ).getPlatform(context.storageContext);
    if ((platform != TargetPlatform.windows &&
            platform != TargetPlatform.linux) ||
        delta.abs() <= 8) {
      _cancelWheelTarget();
      super.pointerScroll(delta);
      return;
    }
    // Discrete Windows/Linux ticks need enough travel to navigate a poster
    // page. Precision input keeps the OS-provided distance above.
    final wheelDelta = delta * 1.6;
    if (DesktopPerformanceHost.systemReducedMotionOf(context.storageContext)) {
      _cancelWheelTarget();
      super.pointerScroll(wheelDelta);
      return;
    }
    final pending = activity is DrivenScrollActivity ? _wheelTarget : null;
    // Reverse immediately instead of first consuming the previous direction's
    // remaining distance. Same-direction ticks accumulate without being lost.
    final base = pending != null && (pending - pixels) * delta > 0
        ? pending
        : pixels;
    final target = (base + wheelDelta).clamp(minScrollExtent, maxScrollExtent);
    if (target == pixels) {
      _cancelWheelTarget();
      super.pointerScroll(0);
      return;
    }
    _wheelTarget = target;
    final generation = ++_wheelGeneration;
    updateUserScrollDirection(
      delta < 0 ? ScrollDirection.forward : ScrollDirection.reverse,
    );
    super
        .animateTo(
          target,
          duration: const Duration(milliseconds: 60),
          curve: Curves.easeOutCubic,
        )
        .whenComplete(() {
          if (generation == _wheelGeneration) _wheelTarget = null;
        });
  }

  @override
  void jumpTo(double value) {
    _cancelWheelTarget();
    super.jumpTo(value);
  }

  @override
  Future<void> animateTo(
    double to, {
    required Duration duration,
    required Curve curve,
  }) {
    _cancelWheelTarget();
    return super.animateTo(to, duration: duration, curve: curve);
  }

  @override
  void dispose() {
    _cancelWheelTarget();
    super.dispose();
  }
}
