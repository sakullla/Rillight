import 'package:rillight/app/ui/ui.dart';
import 'package:flutter/services.dart';

import 'buffer_snapshot.dart';

/// Buffer data is shared with the seek control's single painting pass.
class BufferedRangesTrack extends InheritedWidget {
  const BufferedRangesTrack({
    super.key,
    required this.snapshot,
    required this.duration,
    required super.child,
    this.trackHeight = 4,
  });
  final BufferSnapshot snapshot;
  final Duration duration;
  final double trackHeight;
  static BufferedRangesTrack? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<BufferedRangesTrack>();
  @override
  bool updateShouldNotify(BufferedRangesTrack oldWidget) =>
      snapshot != oldWidget.snapshot ||
      duration != oldWidget.duration ||
      trackHeight != oldWidget.trackHeight;
}

/// Neutral geometry shared by input, buffered painting and hover previews.
const playerSliderInset = 24.0;
const playerSliderHeight = 48.0;

class PlayerSlider extends StatefulWidget {
  const PlayerSlider({
    super.key,
    required this.value,
    this.min = 0,
    this.max = 1,
    this.onChanged,
    this.onChangeStart,
    this.onChangeEnd,
    this.divisions,
    this.label,
    this.padding = const EdgeInsets.symmetric(horizontal: playerSliderInset),
    this.unityFraction,
    this.activeColor,
    this.thumbColor,
  });
  final double value, min, max;
  final ValueChanged<double>? onChanged, onChangeStart, onChangeEnd;
  final int? divisions;
  final String? label;
  final EdgeInsets padding;
  final double? unityFraction;
  final Color? activeColor, thumbColor;
  @override
  State<PlayerSlider> createState() => _PlayerSliderState();
}

class _PlayerSliderState extends State<PlayerSlider> {
  final _focusNode = FocusNode();
  bool _focused = false;
  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  double? _dragValue;
  bool get _enabled => widget.onChanged != null && widget.max > widget.min;
  double get _fraction => widget.max <= widget.min
      ? 0
      : ((widget.value - widget.min) / (widget.max - widget.min)).clamp(0, 1);
  double _at(double dx, double width) {
    var fraction =
        ((dx - widget.padding.left) /
                (width - widget.padding.horizontal).clamp(1, double.infinity))
            .clamp(0.0, 1.0);
    if (Directionality.of(context) == TextDirection.rtl) {
      fraction = 1 - fraction;
    }
    if (widget.divisions case final steps? when steps > 0) {
      fraction = (fraction * steps).round() / steps;
    }
    return widget.min + fraction * (widget.max - widget.min);
  }

  void _step(bool increase) {
    if (!_enabled) return;
    final step = (widget.max - widget.min) / (widget.divisions ?? 100);
    final value = (widget.value + (increase ? step : -step)).clamp(
      widget.min,
      widget.max,
    );
    widget.onChangeStart?.call(widget.value);
    widget.onChanged?.call(value);
    widget.onChangeEnd?.call(value);
  }

  @override
  Widget build(BuildContext context) {
    final buffer = BufferedRangesTrack.of(context);
    return Focus(
      focusNode: _focusNode,
      canRequestFocus: _enabled,
      onFocusChange: (value) => setState(() => _focused = value),
      onKeyEvent: (_, event) {
        if (!_enabled || event is! KeyDownEvent && event is! KeyRepeatEvent) {
          return KeyEventResult.ignored;
        }
        final key = event.logicalKey;
        if (![
          LogicalKeyboardKey.arrowLeft,
          LogicalKeyboardKey.arrowRight,
          LogicalKeyboardKey.arrowUp,
          LogicalKeyboardKey.arrowDown,
        ].contains(key)) {
          return KeyEventResult.ignored;
        }
        final rtl = Directionality.of(context) == TextDirection.rtl;
        _step(
          key == LogicalKeyboardKey.arrowUp ||
              key ==
                  (rtl
                      ? LogicalKeyboardKey.arrowLeft
                      : LogicalKeyboardKey.arrowRight),
        );
        return KeyEventResult.handled;
      },
      child: Semantics(
        slider: true,
        enabled: _enabled,
        focusable: _enabled,
        focused: _focused,
        value: widget.label ?? '${(_fraction * 100).round()}%',
        increasedValue: '${((_fraction + .01).clamp(0, 1) * 100).round()}%',
        decreasedValue: '${((_fraction - .01).clamp(0, 1) * 100).round()}%',
        onIncrease: _enabled ? () => _step(true) : null,
        onDecrease: _enabled ? () => _step(false) : null,
        child: LayoutBuilder(
          builder: (context, constraints) => GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: !_enabled
                ? null
                : (event) {
                    _focusNode.requestFocus();
                    final value = _at(
                      event.localPosition.dx,
                      constraints.maxWidth,
                    );
                    widget.onChangeStart?.call(value);
                    widget.onChanged?.call(value);
                    widget.onChangeEnd?.call(value);
                  },
            onHorizontalDragStart: !_enabled
                ? null
                : (event) {
                    _focusNode.requestFocus();
                    _dragValue = _at(
                      event.localPosition.dx,
                      constraints.maxWidth,
                    );
                    widget.onChangeStart?.call(_dragValue!);
                    widget.onChanged?.call(_dragValue!);
                  },
            onHorizontalDragUpdate: !_enabled
                ? null
                : (event) {
                    _dragValue = _at(
                      event.localPosition.dx,
                      constraints.maxWidth,
                    );
                    widget.onChanged?.call(_dragValue!);
                  },
            onHorizontalDragEnd: !_enabled
                ? null
                : (_) {
                    if (_dragValue case final value?) {
                      widget.onChangeEnd?.call(value);
                    }
                    _dragValue = null;
                  },
            onHorizontalDragCancel: !_enabled
                ? null
                : () {
                    if (_dragValue case final value?) {
                      widget.onChangeEnd?.call(value);
                    }
                    _dragValue = null;
                  },
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                SizedBox(
                  height: playerSliderHeight,
                  child: CustomPaint(
                    painter: _SliderPainter(
                      fraction: _fraction,
                      buffer: buffer,
                      direction: Directionality.of(context),
                      padding: widget.padding,
                      focused: _focused,
                      enabled: _enabled,
                      unity: widget.unityFraction,
                      color: widget.activeColor ?? CupertinoColors.white,
                      thumbColor: widget.thumbColor ?? CupertinoColors.white,
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
                if (_dragValue != null && widget.label != null)
                  Positioned(
                    left:
                        ((constraints.maxWidth - 88).clamp(0, double.infinity) *
                        (Directionality.of(context) == TextDirection.rtl
                            ? 1 - _fraction
                            : _fraction)),
                    bottom: playerSliderHeight,
                    width: 88,
                    child: IgnorePointer(
                      child: ExcludeSemantics(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: CupertinoColors.white,
                            borderRadius: BorderRadius.circular(AppRadii.md),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 5,
                            ),
                            child: Text(
                              widget.label!,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: CupertinoColors.black,
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SliderPainter extends CustomPainter {
  const _SliderPainter({
    required this.fraction,
    required this.buffer,
    required this.direction,
    required this.padding,
    required this.focused,
    required this.enabled,
    required this.color,
    required this.thumbColor,
    this.unity,
  });
  final double fraction;
  final BufferedRangesTrack? buffer;
  final TextDirection direction;
  final EdgeInsets padding;
  final bool focused, enabled;
  final double? unity;
  final Color color, thumbColor;
  @override
  void paint(Canvas canvas, Size size) {
    final height = buffer?.trackHeight ?? 3;
    final rect = Rect.fromLTWH(
      padding.left,
      (size.height - height) / 2,
      (size.width - padding.horizontal).clamp(0, double.infinity),
      height,
    );
    final rtl = direction == TextDirection.rtl;
    double x(double f) => rect.left + rect.width * (rtl ? 1 - f : f);
    if (buffer case final data?) {
      _paintTrack(
        canvas,
        rect,
        snapshot: data.snapshot,
        duration: data.duration,
        value: fraction,
        textDirection: direction,
      );
    } else {
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(2)),
        Paint()..color = color.withValues(alpha: .25),
      );
      canvas.drawRect(
        Rect.fromLTRB(
          rtl ? x(fraction) : rect.left,
          rect.top,
          rtl ? rect.right : x(fraction),
          rect.bottom,
        ),
        Paint()..color = color,
      );
    }
    if (unity case final mark?) {
      canvas.drawLine(
        Offset(x(mark), rect.center.dy - 5),
        Offset(x(mark), rect.center.dy + 5),
        Paint()
          ..color = color
          ..strokeWidth = 1.5,
      );
    }
    final center = Offset(x(fraction), rect.center.dy);
    if (focused) {
      canvas.drawCircle(
        center,
        12,
        Paint()..color = color.withValues(alpha: .3),
      );
    }
    canvas.drawCircle(
      center,
      6,
      Paint()..color = enabled ? thumbColor : thumbColor.withValues(alpha: .45),
    );
  }

  @override
  bool shouldRepaint(_SliderPainter old) =>
      fraction != old.fraction ||
      buffer != old.buffer ||
      direction != old.direction ||
      focused != old.focused ||
      enabled != old.enabled ||
      color != old.color ||
      thumbColor != old.thumbColor ||
      padding != old.padding ||
      unity != old.unity;
}

/// TV supplies seek input through its surrounding focus action.
class BufferedRangesProgressIndicator extends StatelessWidget {
  const BufferedRangesProgressIndicator({
    super.key,
    required this.snapshot,
    required this.duration,
    required this.value,
    this.height = 6,
  });

  final BufferSnapshot snapshot;
  final Duration duration;
  final double value;

  /// 轨道粗细;TV 按画布缩放后传入。
  final double height;

  @override
  Widget build(BuildContext context) => Semantics(
    value: '${(value.clamp(0, 1) * 100).round()}%',
    child: SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _ProgressPainter(
          snapshot: snapshot,
          duration: duration,
          value: value,
          textDirection: Directionality.of(context),
        ),
      ),
    ),
  );
}

// Opaque colors keep the three states distinct over bright and dark video.
// The dark outline also keeps the white played track visible on bright frames.
void _paintTrack(
  Canvas canvas,
  Rect rect, {
  required BufferSnapshot snapshot,
  required Duration duration,
  required double value,
  required TextDirection textDirection,
}) {
  final shape = RRect.fromRectAndRadius(rect, Radius.circular(rect.height / 2));
  canvas.drawRRect(shape.inflate(1), Paint()..color = const Color(0xff111820));
  canvas.save();
  canvas.clipRRect(shape);
  canvas.drawRect(rect, Paint()..color = const Color(0xff363c44));

  void segment(double start, double end, Color color) {
    if (end <= start) return;
    final rtl = textDirection == TextDirection.rtl;
    canvas.drawRect(
      Rect.fromLTRB(
        rect.left + rect.width * (rtl ? 1 - end : start),
        rect.top,
        rect.left + rect.width * (rtl ? 1 - start : end),
        rect.bottom,
      ),
      Paint()..color = color,
    );
  }

  final total = duration.inMicroseconds;
  // Prefer exact media-time coverage. The byte fallback is a visual estimate
  // on this same track, not a claim of playable media time.
  if (snapshot.isKnown && snapshot.ranges.isNotEmpty && total > 0) {
    for (final range in snapshot.ranges) {
      segment(
        (range.start.inMicroseconds / total).clamp(0.0, 1.0),
        (range.end.inMicroseconds / total).clamp(0.0, 1.0),
        const Color(0xff697783),
      );
    }
  }
  if (snapshot.usesByteEstimate) {
    final coverage = snapshot.byteCoverage!;
    for (final range in coverage.ranges) {
      segment(
        (range.start / coverage.totalBytes).clamp(0.0, 1.0),
        (range.end / coverage.totalBytes).clamp(0.0, 1.0),
        const Color(0xff697783),
      );
    }
  }
  // Played coverage takes precedence; cache never paints over the thumb.
  segment(0, value.clamp(0.0, 1.0), CupertinoColors.white);
  canvas.restore();
}

class _ProgressPainter extends CustomPainter {
  const _ProgressPainter({
    required this.snapshot,
    required this.duration,
    required this.value,
    required this.textDirection,
  });

  final BufferSnapshot snapshot;
  final Duration duration;
  final double value;
  final TextDirection textDirection;

  @override
  void paint(Canvas canvas, Size size) => _paintTrack(
    canvas,
    Rect.fromLTWH(0, 1, size.width, size.height - 2),
    snapshot: snapshot,
    duration: duration,
    value: value,
    textDirection: textDirection,
  );

  @override
  bool shouldRepaint(_ProgressPainter oldDelegate) =>
      oldDelegate.snapshot != snapshot ||
      oldDelegate.duration != duration ||
      oldDelegate.value != value ||
      oldDelegate.textDirection != textDirection;
}
