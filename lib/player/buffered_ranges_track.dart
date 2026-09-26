import 'package:flutter/material.dart';

import 'buffer_snapshot.dart';

/// Paints discontinuous verified cache coverage over an existing seek control.
/// The child continues to own pointer and TV focus handling.
class BufferedRangesTrack extends StatelessWidget {
  const BufferedRangesTrack({
    super.key,
    required this.snapshot,
    required this.duration,
    required this.child,
    this.color,
    this.horizontalInset = 12,
    this.height = 3,
  });

  final BufferSnapshot snapshot;
  final Duration duration;
  final Widget child;
  final Color? color;
  final double horizontalInset;
  final double height;

  @override
  Widget build(BuildContext context) => Stack(
    alignment: Alignment.center,
    children: [
      child,
      Positioned.fill(
        child: IgnorePointer(
          child: CustomPaint(
            painter: _BufferedRangesPainter(
              ranges: snapshot.ranges,
              duration: duration,
              color:
                  color ??
                  Theme.of(context).colorScheme.primary.withValues(alpha: 0.55),
              horizontalInset: horizontalInset,
              height: height,
            ),
          ),
        ),
      ),
    ],
  );
}

class _BufferedRangesPainter extends CustomPainter {
  const _BufferedRangesPainter({
    required this.ranges,
    required this.duration,
    required this.color,
    required this.horizontalInset,
    required this.height,
  });

  final List<BufferedRange> ranges;
  final Duration duration;
  final Color color;
  final double horizontalInset;
  final double height;

  @override
  void paint(Canvas canvas, Size size) {
    final total = duration.inMicroseconds;
    final left = horizontalInset.clamp(0.0, size.width / 2);
    final width = size.width - 2 * left;
    if (total <= 0 || width <= 0 || height <= 0) return;
    final top = (size.height - height) / 2;
    final paint = Paint()..color = color;
    for (final range in ranges) {
      final start = (range.start.inMicroseconds / total).clamp(0.0, 1.0);
      final end = (range.end.inMicroseconds / total).clamp(0.0, 1.0);
      if (end <= start) continue;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            left + width * start,
            top,
            width * (end - start),
            height,
          ),
          Radius.circular(height / 2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_BufferedRangesPainter oldDelegate) =>
      oldDelegate.ranges != ranges ||
      oldDelegate.duration != duration ||
      oldDelegate.color != color ||
      oldDelegate.horizontalInset != horizontalInset ||
      oldDelegate.height != height;
}
