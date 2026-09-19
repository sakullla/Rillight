import 'dart:collection';
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:rillight/player/danmaku/danmaku_layout.dart';
import 'package:rillight/player/danmaku/danmaku_timeline.dart';

/// 字形缓存容量上限;超出按 LRU 淘汰最久未使用项。
const int kDanmakuGlyphCacheLimit = 6000;

/// idle 预布局每块最多处理的唯一键数。
const int kDanmakuGlyphPrepareChunkSize = 200;

/// idle 预布局每块时间上限。
const Duration kDanmakuGlyphPrepareChunkLimit = Duration(milliseconds: 4);

/// 描边颜色(70% 黑)。
const Color kDanmakuGlyphStrokeColor = Color(0xB0000000);

/// 描边宽度。
const double kDanmakuGlyphStrokeWidth = 3;

/// 彩色关闭时缓存键与填充使用的 RGB。
const int kDanmakuGlyphWhiteRgb = 0xFFFFFF;

/// 字形缓存键:(展示文本, RGB)。字号/不透明度/描边/彩色属于样式代际,
/// 不进入键;代际变化时整表丢弃。
@immutable
class DanmakuGlyphKey {
  const DanmakuGlyphKey(this.displayText, this.colorARGB);

  final String displayText;

  /// 24-bit RGB;[DanmakuGlyphCache.colorful] 为 false 时固定为白。
  final int colorARGB;

  @override
  bool operator ==(Object other) {
    return other is DanmakuGlyphKey &&
        other.displayText == displayText &&
        other.colorARGB == colorARGB;
  }

  @override
  int get hashCode => Object.hash(displayText, colorARGB);
}

/// 样式代际:任一字段变化即丢弃并重建缓存。
@immutable
class DanmakuGlyphStyle {
  const DanmakuGlyphStyle({
    required this.fontPx,
    required this.opacity,
    required this.outline,
    required this.colorful,
  });

  static const unset = DanmakuGlyphStyle(
    fontPx: 0,
    opacity: 0.85,
    outline: true,
    colorful: true,
  );

  final int fontPx;
  final double opacity;
  final bool outline;
  final bool colorful;

  @override
  bool operator ==(Object other) {
    return other is DanmakuGlyphStyle &&
        other.fontPx == fontPx &&
        other.opacity == opacity &&
        other.outline == outline &&
        other.colorful == colorful;
  }

  @override
  int get hashCode => Object.hash(fontPx, opacity, outline, colorful);
}

/// 已 layout 的填充 Paragraph、可选描边 Paragraph 与测量宽度。
class DanmakuGlyph {
  DanmakuGlyph({
    required this.fill,
    required this.stroke,
    required this.width,
    required this.fillColor,
  });

  final ui.Paragraph fill;
  final ui.Paragraph? stroke;
  final double width;

  /// 填充色,供测试断言 colorful=false 时为白。
  @visibleForTesting
  final Color fillColor;
}

/// 弹幕字形缓存:按 (文本, 颜色) 去重,idle 分块预布局,未命中同步兜底。
///
/// [widthMeasurer] 保留为测试可替换的宽度布局器;未注入时宽度取 Paragraph。
class DanmakuGlyphCache {
  DanmakuGlyphCache({DanmakuTextMeasurer? widthMeasurer})
    : _widthMeasurer = widthMeasurer;

  final DanmakuTextMeasurer? _widthMeasurer;
  final LinkedHashMap<DanmakuGlyphKey, DanmakuGlyph> _entries =
      LinkedHashMap<DanmakuGlyphKey, DanmakuGlyph>();
  final Map<String, double> _widthByText = <String, double>{};

  DanmakuGlyphStyle _style = DanmakuGlyphStyle.unset;
  List<DanmakuGlyphKey> _pending = const [];
  int _prepareGeneration = 0;
  bool _preparing = false;

  /// 非 prepare 路径上的同步 layout 次数(ticker 验收用)。
  int debugSyncLayoutCount = 0;

  DanmakuGlyphStyle get style => _style;

  bool get colorful => _style.colorful;

  bool get outline => _style.outline;

  /// 当前缓存键数量。
  int get size => _entries.length;

  /// 供测试观察的缓存条数别名。
  @visibleForTesting
  int get debugCount => _entries.length;

  /// 布局引擎宽度适配器:命中缓存取 width,未命中同步 layout 并入缓存。
  double measure(String text, double fontSize) {
    final custom = _widthMeasurer;
    if (custom != null) {
      return custom(text, fontSize);
    }
    final cached = _widthByText[text];
    if (cached != null) {
      return cached;
    }
    return get(DanmakuGlyphKey(text, _keyColor(kDanmakuGlyphWhiteRgb))).width;
  }

  /// 由条目构造当前代际下的缓存键。
  DanmakuGlyphKey keyOf(DanmakuEntry entry) {
    return DanmakuGlyphKey(entry.displayText, _keyColor(entry.color));
  }

  int _keyColor(int rgb) {
    if (!_style.colorful) {
      return kDanmakuGlyphWhiteRgb;
    }
    return rgb & 0xFFFFFF;
  }

  /// 应用样式代际;有变化则丢弃全部键。返回是否发生了丢弃。
  bool applyStyle(DanmakuGlyphStyle style) {
    if (_style == style) {
      return false;
    }
    _style = style;
    clear();
    return true;
  }

  /// 丢弃全部键并取消在途预布局。
  void clear() {
    _prepareGeneration++;
    _pending = const [];
    _entries.clear();
    _widthByText.clear();
  }

  /// 时间轴/代际变化后从 [fromTime] 起向后优先,idle 分块预布局。
  void prepare(Iterable<DanmakuEntry> timeline, {double fromTime = 0}) {
    _prepareGeneration++;
    final generation = _prepareGeneration;
    if (_style.fontPx <= 0) {
      _pending = const [];
      return;
    }
    final keys = <DanmakuGlyphKey>{};
    final snapshot = List<DanmakuEntry>.of(timeline);
    for (final entry in snapshot) {
      if (entry.time >= fromTime) {
        keys.add(keyOf(entry));
      }
    }
    for (final entry in snapshot) {
      if (entry.time < fromTime) {
        keys.add(keyOf(entry));
      }
    }
    _pending = [
      for (final key in keys)
        if (!_entries.containsKey(key)) key,
    ];
    if (_pending.isEmpty) {
      return;
    }
    _preparing = true;
    try {
      _runChunk();
    } finally {
      _preparing = false;
    }
    if (_pending.isNotEmpty) {
      _scheduleChunk(generation);
    }
  }

  /// 取出字形;未命中则同步 layout。命中时刷新 LRU。
  DanmakuGlyph get(DanmakuGlyphKey key) {
    final existing = _entries.remove(key);
    if (existing != null) {
      _entries[key] = existing;
      return existing;
    }
    return _layoutAndStore(key, countMiss: !_preparing);
  }

  /// 测试用:同步完成剩余预布局,避免依赖 idle 调度时序。
  @visibleForTesting
  void debugFinishPrepareSync() {
    _prepareGeneration++;
    _preparing = true;
    try {
      while (_pending.isNotEmpty) {
        _layoutNextPending();
      }
    } finally {
      _preparing = false;
    }
  }

  void _scheduleChunk(int generation) {
    final binding = SchedulerBinding.instance;
    void run() {
      if (generation != _prepareGeneration) {
        return;
      }
      _preparing = true;
      try {
        _runChunk();
      } finally {
        _preparing = false;
      }
      if (generation == _prepareGeneration && _pending.isNotEmpty) {
        _scheduleChunk(generation);
      }
    }

    // 播放中 Ticker 会占着 transientCallback;此时 scheduleTask(Priority.idle)
    // 不会执行任务却仍返回 true,Timer.run 空转。改走帧后回调。
    if (binding.transientCallbackCount > 0 ||
        binding.schedulerPhase != SchedulerPhase.idle) {
      binding.addPostFrameCallback((_) => run());
      binding.ensureVisualUpdate();
    } else {
      binding.scheduleTask(run, Priority.idle);
    }
  }

  void _runChunk() {
    final limit = kDanmakuGlyphPrepareChunkLimit.inMicroseconds;
    final watch = Stopwatch()..start();
    var n = 0;
    while (_pending.isNotEmpty && n < kDanmakuGlyphPrepareChunkSize) {
      _layoutNextPending();
      n++;
      // FakeAsync 下 Stopwatch 可能一开始就超过 4ms;至少处理 1 个键以免空转死循环.
      if (watch.elapsedMicroseconds >= limit) {
        break;
      }
    }
  }

  void _layoutNextPending() {
    if (_pending.isEmpty) {
      return;
    }
    final key = _pending.removeAt(0);
    if (_entries.containsKey(key)) {
      return;
    }
    _layoutAndStore(key, countMiss: false);
  }

  DanmakuGlyph _layoutAndStore(DanmakuGlyphKey key, {required bool countMiss}) {
    if (countMiss) {
      debugSyncLayoutCount++;
    }
    final glyph = _build(key);
    _entries[key] = glyph;
    _widthByText[key.displayText] = glyph.width;
    _evict();
    return glyph;
  }

  void _evict() {
    while (_entries.length > kDanmakuGlyphCacheLimit) {
      final first = _entries.keys.first;
      final removed = _entries.remove(first);
      if (removed != null &&
          !_entries.keys.any((key) => key.displayText == first.displayText)) {
        _widthByText.remove(first.displayText);
      }
    }
  }

  DanmakuGlyph _build(DanmakuGlyphKey key) {
    final fontPx = _style.fontPx <= 0 ? 1.0 : _style.fontPx.toDouble();
    final alpha = (_style.opacity * 0xFF).round().clamp(0, 255);
    final fillColor = Color((alpha << 24) | (key.colorARGB & 0xFFFFFF));
    final fill = _paragraph(
      text: key.displayText,
      fontPx: fontPx,
      color: fillColor,
    );
    final stroke = _style.outline
        ? _paragraph(
            text: key.displayText,
            fontPx: fontPx,
            foreground: Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = kDanmakuGlyphStrokeWidth
              ..strokeJoin = StrokeJoin.round
              ..color = kDanmakuGlyphStrokeColor,
          )
        : null;
    return DanmakuGlyph(
      fill: fill,
      stroke: stroke,
      width: fill.maxIntrinsicWidth,
      fillColor: fillColor,
    );
  }

  ui.Paragraph _paragraph({
    required String text,
    required double fontPx,
    Color? color,
    Paint? foreground,
  }) {
    final builder = ui.ParagraphBuilder(
      ui.ParagraphStyle(
        textDirection: TextDirection.ltr,
        maxLines: 1,
        fontSize: fontPx,
        fontWeight: FontWeight.w500,
      ),
    );
    builder.pushStyle(
      ui.TextStyle(
        color: color,
        foreground: foreground,
        fontSize: fontPx,
        fontWeight: FontWeight.w500,
      ),
    );
    builder.addText(text);
    final paragraph = builder.build();
    paragraph.layout(const ui.ParagraphConstraints(width: double.infinity));
    return paragraph;
  }

  void dispose() {
    _prepareGeneration++;
    _pending = const [];
    _entries.clear();
    _widthByText.clear();
  }
}
