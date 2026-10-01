import 'package:flutter/material.dart';

import 'buffer_snapshot.dart';

/// Installs a seek track inside the Slider's painting pass, before its thumb.
/// Slider still owns geometry, input, focus and accessibility.
class BufferedRangesTrack extends StatelessWidget {
  const BufferedRangesTrack({
    super.key,
    required this.snapshot,
    required this.duration,
    required this.child,
  });

  final BufferSnapshot snapshot;
  final Duration duration;
  final Widget child;

  @override
  Widget build(BuildContext context) => SliderTheme(
    data: SliderTheme.of(context).copyWith(
      trackHeight: 4,
      thumbColor: Colors.white,
      trackShape: _BufferedSliderTrack(snapshot: snapshot, duration: duration),
    ),
    child: child,
  );
}

class _BufferedSliderTrack extends RoundedRectSliderTrackShape {
  const _BufferedSliderTrack({required this.snapshot, required this.duration});

  final BufferSnapshot snapshot;
  final Duration duration;

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 2,
  }) {
    final rect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    if (rect.width <= 0 || rect.height <= 0) return;
    final physicalFraction = ((thumbCenter.dx - rect.left) / rect.width).clamp(
      0.0,
      1.0,
    );
    _paintTrack(
      context.canvas,
      rect,
      snapshot: snapshot,
      duration: duration,
      value: textDirection == TextDirection.rtl
          ? 1 - physicalFraction
          : physicalFraction,
      textDirection: textDirection,
    );
  }
}

/// TV supplies seek input through its surrounding focus action.
class BufferedRangesProgressIndicator extends StatelessWidget {
  const BufferedRangesProgressIndicator({
    super.key,
    required this.snapshot,
    required this.duration,
    required this.value,
  });

  final BufferSnapshot snapshot;
  final Duration duration;
  final double value;

  @override
  Widget build(BuildContext context) => Semantics(
    value: '${(value.clamp(0, 1) * 100).round()}%',
    child: SizedBox(
      height: 6,
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
  if (snapshot.isKnown && snapshot.ranges.isNotEmpty && total > 0) {
    for (final range in snapshot.ranges) {
      segment(
        (range.start.inMicroseconds / total).clamp(0.0, 1.0),
        (range.end.inMicroseconds / total).clamp(0.0, 1.0),
        const Color(0xff697783),
      );
    }
  } else if (snapshot.byteCoverage case final bytes?) {
    // A byte ratio is download progress, not a promise that the same media
    // time can be sought. Use a distinct color on the one existing track.
    for (final range in bytes.ranges) {
      segment(
        range.start / bytes.totalBytes,
        range.end / bytes.totalBytes,
        const Color(0xff75bed2),
      );
    }
  }
  // Played coverage takes precedence; cache never paints over the thumb.
  segment(0, value.clamp(0.0, 1.0), Colors.white);
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
