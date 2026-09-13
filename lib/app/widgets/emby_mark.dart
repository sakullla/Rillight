import 'package:flutter/material.dart';

/// Emby 风格标记:圆角方块 + 播放三角,给服务器列表当图标用。
class EmbyMark extends StatelessWidget {
  const EmbyMark({super.key, this.size = 28});

  final double size;

  static const Color fill = Color(0xFF52B54B);

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Emby',
      child: CustomPaint(
        size: Size.square(size),
        painter: const _EmbyMarkPainter(),
      ),
    );
  }
}

class _EmbyMarkPainter extends CustomPainter {
  const _EmbyMarkPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final radius = size.shortestSide * 0.22;
    final rect = Offset.zero & size;
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(radius)),
      Paint()..color = EmbyMark.fill,
    );
    final play = Path()
      ..moveTo(size.width * 0.36, size.height * 0.28)
      ..lineTo(size.width * 0.72, size.height * 0.50)
      ..lineTo(size.width * 0.36, size.height * 0.72)
      ..close();
    canvas.drawPath(play, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
