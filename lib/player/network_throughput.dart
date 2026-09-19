import 'package:flutter/material.dart';

/// 把 mpv `cache-speed`(字节/秒,约 1 秒窗口)格式化成播放器网速文案。
///
/// 这是实际读入缓冲的吞吐,不是片源码率。缓冲写满后会落到 0,与 YouTube
/// Network Activity、mpv stats 的 Speed 一致。单位用 1024 进制,和 mpv /
/// 常见下载器相同。
String formatNetworkThroughput(num bytesPerSecond) {
  final raw = bytesPerSecond.isFinite ? bytesPerSecond.toDouble() : 0.0;
  final bytes = raw < 0 ? 0.0 : raw;
  const kibi = 1024.0;
  const mebi = 1024.0 * 1024.0;
  if (bytes < mebi) {
    return '${(bytes / kibi).round()} KB/s';
  }
  final mebibytes = bytes / mebi;
  if (mebibytes < 10) {
    return '${mebibytes.toStringAsFixed(1)} MB/s';
  }
  return '${mebibytes.round()} MB/s';
}

/// 顶栏实时网速:下行箭头 + 读数。
///
/// 火绒流量悬浮窗、TrafficMonitor、任务管理器用 ↓ 表示入站吞吐;
/// Material `download` 是「保存到磁盘」,会读成下载文件而不是网速。
class NetworkSpeedReadout extends StatelessWidget {
  const NetworkSpeedReadout({
    super.key,
    required this.bytesPerSecond,
    this.color,
  });

  final num bytesPerSecond;
  final Color? color;

  /// 与 bodySmall 字身齐高的细箭头,避免 24px 图标视口把字形挤小。
  static const markSize = Size(8, 11);

  @override
  Widget build(BuildContext context) {
    final textStyle = Theme.of(context).textTheme.bodySmall;
    final resolved =
        color ?? textStyle?.color ?? Theme.of(context).colorScheme.onSurface;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        CustomPaint(
          size: markSize,
          painter: InboundSpeedMarkPainter(color: resolved),
        ),
        const SizedBox(width: 5),
        Text(
          formatNetworkThroughput(bytesPerSecond),
          style: textStyle?.copyWith(
            color: resolved,
            height: 1,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

/// 入站箭头:竖杆 + 箭头,没有下载托盘。
class InboundSpeedMarkPainter extends CustomPainter {
  const InboundSpeedMarkPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final cx = size.width / 2;
    final tip = Offset(cx, size.height - 0.6);
    canvas.drawLine(Offset(cx, 0.6), tip, stroke);
    canvas.drawPath(
      Path()
        ..moveTo(1.0, size.height * 0.55)
        ..lineTo(tip.dx, tip.dy)
        ..lineTo(size.width - 1.0, size.height * 0.55),
      stroke,
    );
  }

  @override
  bool shouldRepaint(covariant InboundSpeedMarkPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}
