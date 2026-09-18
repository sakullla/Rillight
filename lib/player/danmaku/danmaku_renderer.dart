import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:rillight/player/danmaku/danmaku_controller.dart';
import 'package:rillight/player/danmaku/danmaku_layout.dart';
import 'package:rillight/player/danmaku/dandanplay_models.dart';

/// 弹幕渲染层:CustomPainter 自绘滚动/固定弹幕。
///
/// 按播放位置驱动 [DanmakuLayout](时间轴进入/退出/seek 重定位由布局引擎
/// 完成);播放中用 ticker + 位置插值获得逐帧平滑滚动,暂停时冻结在
/// 最后位置。上层在开关关闭或无弹幕时不挂载本 widget,实现零渲染开销;
/// 挂载但无弹幕时 ticker 停止、每帧只遍历空列表。
class DanmakuView extends StatefulWidget {
  const DanmakuView({super.key, required this.controller});

  final DanmakuController controller;

  @override
  DanmakuViewState createState() => DanmakuViewState();
}

class DanmakuViewState extends State<DanmakuView>
    with SingleTickerProviderStateMixin {
  final ValueNotifier<List<DanmakuFrame>> _frames = ValueNotifier(const []);

  /// 文本绘制缓存(换集/参数变化时整体失效),键含字号/颜色/不透明度。
  final Map<String, TextPainter> _strokePainters = {};
  final Map<String, TextPainter> _fillPainters = {};
  List<DanmakuComment>? _cachedComments;
  DanmakuDisplaySettings? _cachedDisplay;

  Ticker? _ticker;

  /// 当前 ticker 是否在转;暂停后再播必须重新 start。
  @visibleForTesting
  bool get debugTickerActive => _ticker?.isActive ?? false;

  /// 最近一次绘制帧,供测试观察暂停冻结与恢复后位移。
  @visibleForTesting
  List<DanmakuFrame> get debugFrames => _frames.value;

  /// 描边 painter 缓存条数;参数变化后不得残留旧键。
  @visibleForTesting
  int get debugStrokePainterCount => _strokePainters.length;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    _syncTicker();
  }

  @override
  void didUpdateWidget(DanmakuView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
      _cachedComments = null;
      _cachedDisplay = null;
      _strokePainters.clear();
      _fillPainters.clear();
      _frames.value = const [];
    }
    _syncTicker();
  }

  @override
  void dispose() {
    _ticker?.dispose();
    widget.controller.removeListener(_onControllerChanged);
    _frames.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) {
      return;
    }
    _invalidateStaleCache();
    _syncTicker();
    // 状态/seek/暂停切换时立即重绘一帧(ticker 之外的更新路径)。
    _paintFrame();
  }

  /// 换集或显示参数变化后清掉旧文本缓存,防止无限增长。
  void _invalidateStaleCache() {
    final comments = widget.controller.comments;
    final display = widget.controller.display;
    if (identical(_cachedComments, comments) &&
        identical(_cachedDisplay, display)) {
      return;
    }
    _cachedComments = comments;
    _cachedDisplay = display;
    _strokePainters.clear();
    _fillPainters.clear();
  }

  /// 仅在「有弹幕且播放中」运转 ticker;暂停/无弹幕时停止。
  /// 已创建但被 stop 的 ticker 在恢复播放时必须再次 start。
  void _syncTicker() {
    final controller = widget.controller;
    final shouldTick = controller.hasComments && controller.playing;
    if (shouldTick) {
      _ticker ??= createTicker((_) => _paintFrame());
      if (!_ticker!.isActive) {
        _ticker!.start();
      }
    } else {
      _ticker?.stop();
    }
  }

  void _paintFrame() {
    final size = context.size;
    if (size == null) {
      return;
    }
    _frames.value = widget.controller.layout.update(
      widget.controller.estimatePosition(),
      size,
    );
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.infinite,
      painter: _DanmakuPainter(
        frames: _frames,
        strokePainters: _strokePainters,
        fillPainters: _fillPainters,
      ),
    );
  }
}

/// 弹幕画笔:每条弹幕以深色描边 + 彩色填充两次绘制保证任意背景可读。
class _DanmakuPainter extends CustomPainter {
  _DanmakuPainter({
    required this.frames,
    required this.strokePainters,
    required this.fillPainters,
  }) : super(repaint: frames);

  final ValueListenable<List<DanmakuFrame>> frames;
  final Map<String, TextPainter> strokePainters;
  final Map<String, TextPainter> fillPainters;

  @override
  void paint(Canvas canvas, Size size) {
    for (final frame in frames.value) {
      final key =
          '${frame.id}|${frame.fontSize}|${frame.color}|${frame.opacity}';
      var stroke = strokePainters[key];
      var fill = fillPainters[key];
      if (stroke == null || fill == null) {
        stroke = _buildPainter(
          frame,
          foreground: Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3
            ..strokeJoin = StrokeJoin.round
            ..color = const Color(0xB0000000),
        );
        fill = _buildPainter(frame, color: _fillColor(frame));
        strokePainters[key] = stroke;
        fillPainters[key] = fill;
      }
      canvas.save();
      canvas.translate(frame.left, frame.top);
      stroke.paint(canvas, Offset.zero);
      fill.paint(canvas, Offset.zero);
      canvas.restore();
    }
  }

  TextPainter _buildPainter(
    DanmakuFrame frame, {
    Paint? foreground,
    Color? color,
  }) {
    return TextPainter(
      text: TextSpan(
        text: frame.text,
        style: TextStyle(
          fontSize: frame.fontSize,
          fontWeight: FontWeight.w500,
          color: color,
          foreground: foreground,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
  }

  static Color _fillColor(DanmakuFrame frame) {
    final rgb = frame.color & 0xFFFFFF;
    final alpha = (frame.opacity * 0xFF).round().clamp(0, 255);
    return Color((alpha << 24) | rgb);
  }

  @override
  bool shouldRepaint(_DanmakuPainter oldDelegate) {
    // 逐帧更新经 repaint listenable(_frames)驱动。
    return true;
  }
}
