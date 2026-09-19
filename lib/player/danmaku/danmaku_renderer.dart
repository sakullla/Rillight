import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:rillight/player/danmaku/danmaku_controller.dart';
import 'package:rillight/player/danmaku/danmaku_glyph_cache.dart';
import 'package:rillight/player/danmaku/danmaku_layout.dart';
import 'package:rillight/player/danmaku/danmaku_timeline.dart';
import 'package:rillight/player/danmaku/dandanplay_models.dart';

/// 窗口拖拽期间推迟样式代际切换,避免字形缓存抖动重建。
const Duration kDanmakuResizeDebounce = Duration(milliseconds: 200);

/// 弹幕渲染层:滚动层每帧重绘,固定层仅在集合变化时重绘。
///
/// 按播放位置驱动 [DanmakuLayout];播放中用 ticker 推进滚动位置,
/// 暂停时冻结。上层在开关关闭或无弹幕时不挂载本 widget。
class DanmakuView extends StatefulWidget {
  const DanmakuView({super.key, required this.controller});

  final DanmakuController controller;

  @override
  DanmakuViewState createState() => DanmakuViewState();
}

class DanmakuViewState extends State<DanmakuView>
    with SingleTickerProviderStateMixin {
  final ValueNotifier<int> _scrollTick = ValueNotifier(0);
  final ValueNotifier<int> _fixedTick = ValueNotifier(0);
  late final _ScrollLayerPainter _scrollPainter;
  late final _FixedLayerPainter _fixedPainter;

  Ticker? _ticker;
  Timer? _resizeDebounce;
  Size? _lastSize;
  DanmakuGlyphStyle? _appliedStyle;
  List<DanmakuEntry>? _preparedEntries;
  int _fixedIdentity = Object.hash(0, 0);

  /// 当前 ticker 是否在转;暂停后再播必须重新 start。
  @visibleForTesting
  bool get debugTickerActive => _ticker?.isActive ?? false;

  /// 当前同屏活动条数。
  @visibleForTesting
  int get debugActiveCount => widget.controller.layout.activeCount;

  /// 字形缓存键数量。
  @visibleForTesting
  int get debugGlyphCacheSize => widget.controller.glyphCache.size;

  /// ticker 回调内触发的同步文本 layout 次数。预热完成后应保持 0。
  @visibleForTesting
  int debugLayoutCallsDuringTick = 0;

  /// 固定层 [CustomPainter.paint] 调用次数。
  @visibleForTesting
  int debugFixedLayerPaintCount = 0;

  /// 最近一帧 [Canvas.drawParagraph] 次数。
  @visibleForTesting
  int debugLastDrawParagraphCount = 0;

  int _drawsThisFrame = 0;

  DanmakuGlyphCache get _cache => widget.controller.glyphCache;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    _scrollPainter = _ScrollLayerPainter(view: this, repaint: _scrollTick);
    _fixedPainter = _FixedLayerPainter(view: this, repaint: _fixedTick);
    _syncTicker();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _advanceFrame();
      }
    });
  }

  @override
  void didUpdateWidget(DanmakuView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
      _appliedStyle = null;
      _preparedEntries = null;
      _fixedIdentity = 0;
    }
    _syncTicker();
  }

  @override
  void dispose() {
    _resizeDebounce?.cancel();
    _ticker?.dispose();
    widget.controller.removeListener(_onControllerChanged);
    _scrollTick.dispose();
    _fixedTick.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) {
      return;
    }
    _syncTicker();
    _advanceFrame();
  }

  /// 仅在「有弹幕且播放中」运转 ticker;暂停/无弹幕时停止。
  void _syncTicker() {
    final controller = widget.controller;
    final shouldTick = controller.hasComments && controller.playing;
    if (shouldTick) {
      _ticker ??= createTicker(_onTick);
      if (!_ticker!.isActive) {
        _ticker!.start();
      }
    } else {
      _ticker?.stop();
    }
  }

  void _onTick(Duration _) {
    final before = _cache.debugSyncLayoutCount;
    _advanceFrame();
    debugLayoutCallsDuringTick += _cache.debugSyncLayoutCount - before;
  }

  void _advanceFrame() {
    final size = context.size;
    if (size == null || size.isEmpty) {
      return;
    }
    final sizeChanged = _lastSize != null && _lastSize != size;
    _lastSize = size;
    _syncGlyphCache(size, sizeChanged: sizeChanged);
    widget.controller.layout.update(widget.controller.estimatePosition(), size);
    _drawsThisFrame = 0;
    _scrollTick.value++;
    _syncFixedIdentity();
  }

  void _syncGlyphCache(Size size, {required bool sizeChanged}) {
    final display = widget.controller.display;
    final next = DanmakuGlyphStyle(
      fontPx: _fontPxFor(size, display.fontScale),
      opacity: display.opacity,
      outline: display.outline,
      colorful: display.colorful,
    );
    final source = widget.controller.layout.entries;
    final styleChanged = _appliedStyle != next;
    final sourceChanged = !identical(_preparedEntries, source);

    void apply({required bool clearForSource}) {
      _resizeDebounce?.cancel();
      if (styleChanged) {
        _cache.applyStyle(next);
      } else if (clearForSource) {
        _cache.clear();
      }
      _appliedStyle = next;
      _preparedEntries = source;
      _cache.prepare(source, fromTime: _prepareFromTime());
    }

    if (!styleChanged && !sourceChanged) {
      return;
    }
    if (styleChanged && sizeChanged && _appliedStyle != null) {
      _resizeDebounce?.cancel();
      _resizeDebounce = Timer(kDanmakuResizeDebounce, () {
        if (!mounted) {
          return;
        }
        apply(clearForSource: sourceChanged);
      });
      return;
    }
    apply(clearForSource: sourceChanged);
  }

  double _prepareFromTime() {
    return widget.controller.estimatePosition().inMilliseconds / 1000;
  }

  static int _fontPxFor(Size size, double fontScale) {
    final viewScale = (size.height / kDanmakuViewportReferenceHeight).clamp(
      kDanmakuViewportScaleMin,
      kDanmakuViewportScaleMax,
    );
    return (kDanmakuBaseFontSize * fontScale * viewScale).round();
  }

  void _syncFixedIdentity() {
    var hash = 0;
    var count = 0;
    for (final item in widget.controller.layout.activeEntries) {
      if (item.mode == DanmakuMode.scroll) {
        continue;
      }
      hash ^= item.id;
      count++;
    }
    final identity = Object.hash(hash, count);
    if (identity != _fixedIdentity) {
      _fixedIdentity = identity;
      _fixedTick.value++;
    }
  }

  void _noteDraws(int count) {
    _drawsThisFrame += count;
    debugLastDrawParagraphCount = _drawsThisFrame;
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          CustomPaint(size: Size.infinite, painter: _scrollPainter),
          RepaintBoundary(
            child: CustomPaint(size: Size.infinite, painter: _fixedPainter),
          ),
        ],
      ),
    );
  }
}

void _paintLayer({
  required Canvas canvas,
  required DanmakuViewState view,
  required bool scroll,
}) {
  final cache = view.widget.controller.glyphCache;
  final outline = cache.outline;
  var draws = 0;
  for (final item in view.widget.controller.layout.activeEntries) {
    final isScroll = item.mode == DanmakuMode.scroll;
    if (scroll != isScroll) {
      continue;
    }
    final glyph = cache.get(cache.keyOf(item.entry));
    final offset = Offset(item.left, item.top);
    if (outline && glyph.stroke != null) {
      canvas.drawParagraph(glyph.stroke!, offset);
      draws++;
    }
    canvas.drawParagraph(glyph.fill, offset);
    draws++;
  }
  view._noteDraws(draws);
}

class _ScrollLayerPainter extends CustomPainter {
  _ScrollLayerPainter({required this.view, required Listenable repaint})
    : super(repaint: repaint);

  final DanmakuViewState view;

  @override
  void paint(Canvas canvas, Size size) {
    _paintLayer(canvas: canvas, view: view, scroll: true);
  }

  @override
  bool? hitTest(Offset position) => false;

  @override
  bool shouldRepaint(covariant _ScrollLayerPainter oldDelegate) => false;
}

class _FixedLayerPainter extends CustomPainter {
  _FixedLayerPainter({required this.view, required Listenable repaint})
    : super(repaint: repaint);

  final DanmakuViewState view;

  @override
  void paint(Canvas canvas, Size size) {
    view.debugFixedLayerPaintCount++;
    _paintLayer(canvas: canvas, view: view, scroll: false);
  }

  @override
  bool? hitTest(Offset position) => false;

  @override
  bool shouldRepaint(covariant _FixedLayerPainter oldDelegate) => false;
}
