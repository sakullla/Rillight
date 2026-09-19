import 'package:flutter/widgets.dart';
import 'package:rillight/player/danmaku/dandanplay_models.dart';
import 'package:rillight/player/danmaku/danmaku_display_settings.dart';
import 'package:rillight/player/danmaku/danmaku_timeline.dart';

// 显示参数已迁至独立文件;此处转出口以兼容仍从本文件导入的调用方。
export 'package:rillight/player/danmaku/danmaku_display_settings.dart';

/// 基础字号(逻辑像素,1080p「中」档)。最终字号 =
/// `基础 × fontScale × clamp(viewportHeight / 1080, 0.6, 1.5)`,取整。
/// 未调过的默认档是「大」(`kDanmakuFontScaleDefault`)。
const double kDanmakuBaseFontSize = 26;

/// 字号随视口缩放的参考高度。
const double kDanmakuViewportReferenceHeight = 1080;

/// 视口高度缩放下限 / 上限。
const double kDanmakuViewportScaleMin = 0.6;
const double kDanmakuViewportScaleMax = 1.5;

/// 行高相对字号的倍数。
const double kDanmakuLineHeightFactor = 1.35;

/// 滚动弹幕基础穿越时长(秒),实际 = 基础 / speed。
const double kDanmakuScrollSeconds = 12;

/// 顶部/底部固定弹幕的停留时长(秒)。
const double kDanmakuFixedSeconds = 5;

/// 播放位置回跳或前跳超过该阈值视为 seek:清屏并按新位置重建。
/// 小于该幅度的回退视为进度抖动,不得重排车道,否则弹幕会上下左右跳。
const Duration kDanmakuSeekThreshold = Duration(seconds: 2);

/// 同车道弹幕之间的最小像素间隙,避免描边重叠。
const double kDanmakuCollisionGap = 8;

/// 活动弹幕条目(spawn 后的运行时状态),由 [DanmakuLayout.update] 原地更新。
class DanmakuActive {
  DanmakuActive({
    required this.entry,
    required this.lane,
    required this.width,
    required this.spawn,
    required this.lifespan,
    required this.fontPx,
    this.left = 0,
    this.top = 0,
    this.opacity = 1,
  });

  final DanmakuEntry entry;
  final int lane;
  double width;
  final Duration spawn;
  final Duration lifespan;
  int fontPx;
  double left;
  double top;
  double opacity;

  int get id => entry.cid;
  String get text => entry.displayText;
  int get color => entry.color;
  double get fontSize => fontPx.toDouble();
  DanmakuMode get mode => entry.renderMode;
}

/// T4 删除前的兼容别名:渲染层仍按 [DanmakuFrame] 读取绘制字段。
typedef DanmakuFrame = DanmakuActive;

/// 文本宽度测量器:渲染层用 TextPainter,单测用确定性假实现注入。
typedef DanmakuTextMeasurer = double Function(String text, double fontSize);

/// 弹幕时间轴布局引擎:纯逻辑,按播放位置驱动弹幕进入/退出,
/// seek 后清屏并按新位置重建可见集(仍处于显示窗口内的弹幕按比例复位)。
class DanmakuLayout {
  DanmakuLayout({required DanmakuTextMeasurer measurer}) : _measure = measurer;

  final DanmakuTextMeasurer _measure;

  List<DanmakuComment> _comments = const [];
  List<DanmakuEntry> _wrappedEntries = const [];
  List<DanmakuEntry>? _explicitEntries;

  /// 兼容 T2 控制器:把 [DanmakuComment] 包成 [DanmakuEntry]。
  /// 若同时设置了 [entries],以 [entries] 为准。
  set comments(List<DanmakuComment> value) {
    _comments = value;
    _wrappedEntries = [
      for (final comment in value)
        DanmakuEntry(
          comment: comment,
          time: comment.time,
          mergedCount: 1,
          renderMode: comment.renderMode,
          displayText: comment.text,
        ),
    ];
  }

  List<DanmakuComment> get comments => _comments;

  /// 布局输入。与 [comments] 同时存在时本字段优先。
  set entries(List<DanmakuEntry> value) {
    _explicitEntries = value;
  }

  List<DanmakuEntry> get entries => _explicitEntries ?? _wrappedEntries;

  DanmakuDisplaySettings settings = const DanmakuDisplaySettings();

  /// 媒体倍速,仅在 [DanmakuDisplaySettings.followPlaybackRate] 为 false
  /// 时于 spawn 瞬间拉伸寿命;已上场条目不改写。T4 负责写入。
  double playbackRate = 1.0;

  final List<DanmakuActive> _active = [];
  // 各模式每条轨道最近一条弹幕,用于防追尾的车道分配。
  final Map<DanmakuMode, List<DanmakuActive?>> _laneLast = {};
  final Map<DanmakuMode, int> _lastAssigned = {};
  Duration? _lastPosition;
  int _cursor = 0;
  double _width = 0;
  double _height = 0;
  int _fontPx = 0;
  int _styleGeneration = 0;

  /// 当前同屏弹幕数(密度上限的判定依据)。
  int get activeCount => _active.length;

  /// 当前活动列表(与 [update] 返回值为同一实例,逐帧原地更新)。
  List<DanmakuActive> get activeEntries => _active;

  /// 当前取整后的字号。
  int get fontPx => _fontPx;

  /// 当前车道数。
  int get laneCount => _laneCount();

  /// 字号取整变化时递增,供渲染层丢弃字形缓存。
  int get styleGeneration => _styleGeneration;

  /// 重置运行时状态(切换集/更换显示参数后调用)。
  void reset() {
    _active.clear();
    _laneLast.clear();
    _lastAssigned.clear();
    _lastPosition = null;
    _cursor = 0;
  }

  /// 按播放位置推进一帧,原地更新并返回 [activeEntries] 自身。
  List<DanmakuFrame> update(Duration position, Size size) {
    _syncMetrics(size);
    final last = _lastPosition;
    final seek = _isSeek(position, last);
    // 未达 seek 阈值的回退当成时钟抖动:保持单调时钟,已上场弹幕车道不动。
    final clock = (!seek && last != null && position < last) ? last : position;
    if (entries.isEmpty) {
      _active.clear();
      _laneLast.clear();
      _lastAssigned.clear();
      _cursor = 0;
      _lastPosition = clock;
      return _active;
    }
    if (seek) {
      _handleSeek(clock);
    } else {
      _expire(clock);
      _spawnDue(clock);
    }
    _lastPosition = clock;
    _layoutPositions(clock);
    return _active;
  }

  bool _isSeek(Duration position, Duration? last) {
    if (last == null) {
      return true;
    }
    if (position < last) {
      return last - position > kDanmakuSeekThreshold;
    }
    return position - last > kDanmakuSeekThreshold;
  }

  void _syncMetrics(Size size) {
    _width = size.width;
    _height = size.height;
    final nextFont = _computeFontPx();
    if (nextFont != _fontPx) {
      _fontPx = nextFont;
      _styleGeneration++;
      for (final item in _active) {
        item.fontPx = nextFont;
        item.width = _measure(item.entry.displayText, nextFont.toDouble());
      }
    }
    _trimLanes(_laneCount());
  }

  int _computeFontPx() {
    final viewScale = (_height / kDanmakuViewportReferenceHeight).clamp(
      kDanmakuViewportScaleMin,
      kDanmakuViewportScaleMax,
    );
    return (kDanmakuBaseFontSize * settings.fontScale * viewScale).round();
  }

  void _trimLanes(int laneCount) {
    if (_active.isEmpty) {
      return;
    }
    _active.removeWhere((item) {
      if (item.lane >= laneCount) {
        _clearLaneIfCurrent(item);
        return true;
      }
      return false;
    });
    for (final lanes in _laneLast.values) {
      if (lanes.length > laneCount) {
        lanes.removeRange(laneCount, lanes.length);
      }
    }
    for (final mode in _lastAssigned.keys) {
      final last = _lastAssigned[mode]!;
      if (laneCount <= 0) {
        _lastAssigned[mode] = -1;
      } else if (last >= laneCount) {
        _lastAssigned[mode] = laneCount - 1;
      }
    }
  }

  void _layoutPositions(Duration clock) {
    final lineHeight = _fontPx * kDanmakuLineHeightFactor;
    final areaHeight = _height * settings.areaFraction;
    for (final item in _active) {
      final span = item.lifespan.inMicroseconds;
      final raw = span <= 0 ? 1.0 : (clock - item.spawn).inMicroseconds / span;
      final progress = raw.clamp(0.0, 1.0);
      item.left = switch (item.mode) {
        DanmakuMode.scroll => _width - progress * (_width + item.width),
        _ => (_width - item.width) / 2,
      };
      item.top = switch (item.mode) {
        DanmakuMode.scroll => item.lane * lineHeight,
        DanmakuMode.top => item.lane * lineHeight,
        DanmakuMode.bottom => areaHeight - (item.lane + 1) * lineHeight,
      };
      item.fontPx = _fontPx;
      item.opacity = settings.opacity;
    }
  }

  /// seek:清屏重建。显示窗口覆盖新位置的弹幕按其真实出现时刻复位
  /// (滚动进度按时间比例恢复,位置跟随新播放位置)。
  /// 寿命已在目标时刻结束的条目不播种,避免占用密度名额。
  void _handleSeek(Duration position) {
    _active.clear();
    _laneLast.clear();
    _lastAssigned.clear();
    final source = entries;
    final maxLifespan = _maxLookback();
    var index = source.indexWhere(
      (entry) => entry.time > position.inMilliseconds / 1000,
    );
    if (index < 0) {
      index = source.length;
    }
    _cursor = index;
    // 按时间正序播种,车道分配与正向播放一致,避免 seek 后上下乱跳。
    var start = index;
    while (start > 0) {
      final at = _spawnTime(source[start - 1]);
      if (position - at > maxLifespan) {
        break;
      }
      start--;
    }
    for (var i = start; i < index; i++) {
      final entry = source[i];
      final spawn = _spawnTime(entry);
      if (position - spawn >= _lifespanFor(entry.renderMode)) {
        continue;
      }
      _spawn(entry, spawn);
    }
  }

  Duration _maxLookback() {
    var seconds = kDanmakuScrollSeconds / settings.speed;
    if (kDanmakuFixedSeconds > seconds) {
      seconds = kDanmakuFixedSeconds;
    }
    if (!settings.followPlaybackRate) {
      seconds *= _rateFactor;
    }
    return Duration(milliseconds: (seconds * 1000).ceil());
  }

  Duration _lifespanFor(DanmakuMode mode) {
    final baseSeconds = mode == DanmakuMode.scroll
        ? kDanmakuScrollSeconds / settings.speed
        : kDanmakuFixedSeconds;
    final seconds = settings.followPlaybackRate
        ? baseSeconds
        : baseSeconds * _rateFactor;
    return Duration(milliseconds: (seconds * 1000).round());
  }

  double get _rateFactor {
    final rate = playbackRate;
    if (rate <= 0 || rate.isNaN || rate.isInfinite) {
      return 1.0;
    }
    return rate;
  }

  Duration _spawnTime(DanmakuEntry entry) {
    return Duration(milliseconds: (entry.time * 1000).round());
  }

  /// 播放推进:产出时间落在 (上一位置, 当前位置] 的弹幕,
  /// 以弹幕自身时刻为出生点(滚动进度与时间轴精确对齐)。
  void _spawnDue(Duration position) {
    final source = entries;
    final positionSeconds = position.inMilliseconds / 1000;
    while (_cursor < source.length && source[_cursor].time <= positionSeconds) {
      final entry = source[_cursor];
      _cursor++;
      _spawn(entry, _spawnTime(entry));
    }
  }

  void _expire(Duration position) {
    if (_active.isEmpty) {
      return;
    }
    _active.removeWhere((item) {
      final dead = position - item.spawn >= item.lifespan;
      if (dead) {
        _clearLaneIfCurrent(item);
      }
      return dead;
    });
  }

  void _clearLaneIfCurrent(DanmakuActive item) {
    final lanes = _laneLast[item.mode];
    if (lanes == null || item.lane >= lanes.length) {
      return;
    }
    if (identical(lanes[item.lane], item)) {
      lanes[item.lane] = null;
    }
  }

  void _spawn(DanmakuEntry entry, Duration spawn) {
    if (_explicitEntries == null && _isBlocked(entry.displayText)) {
      return;
    }
    final laneCount = _laneCount();
    if (laneCount <= 0) {
      return;
    }
    // 密度上限 = 档位倍数 × 车道数,作用于同屏总数;unlimited 不设上限。
    final multiplier = settings.density.laneMultiplier;
    if (multiplier != null && _active.length >= multiplier * laneCount) {
      return;
    }
    final width = _measure(entry.displayText, _fontPx.toDouble());
    final mode = entry.renderMode;
    final lifespan = _lifespanFor(mode);
    final lanes = _laneLast.putIfAbsent(mode, () => <DanmakuActive?>[]);
    while (lanes.length < laneCount) {
      lanes.add(null);
    }
    for (var lane = 0; lane < laneCount; lane++) {
      if (_laneFree(lanes, lane, mode, width, lifespan, spawn)) {
        _commit(entry, lane, width, spawn, lifespan, lanes);
        return;
      }
    }
    if (settings.preventOverlap) {
      return;
    }
    final start = ((_lastAssigned[mode] ?? -1) + 1) % laneCount;
    var bestLane = start;
    var bestFree = _freeAt(lanes[start], spawn);
    for (var i = 1; i < laneCount; i++) {
      final lane = (start + i) % laneCount;
      final at = _freeAt(lanes[lane], spawn);
      if (at < bestFree) {
        bestFree = at;
        bestLane = lane;
      }
    }
    _commit(entry, bestLane, width, spawn, lifespan, lanes);
  }

  void _commit(
    DanmakuEntry entry,
    int lane,
    double width,
    Duration spawn,
    Duration lifespan,
    List<DanmakuActive?> lanes,
  ) {
    final item = DanmakuActive(
      entry: entry,
      lane: lane,
      width: width,
      spawn: spawn,
      lifespan: lifespan,
      fontPx: _fontPx,
    );
    _active.add(item);
    lanes[lane] = item;
    _lastAssigned[entry.renderMode] = lane;
  }

  Duration _freeAt(DanmakuActive? last, Duration spawn) {
    if (last == null) {
      return spawn;
    }
    return last.spawn + last.lifespan;
  }

  bool _isBlocked(String text) {
    final keywords = settings.blockedKeywords;
    if (keywords.isEmpty) {
      return false;
    }
    final haystack = text.toLowerCase();
    for (final keyword in keywords) {
      final needle = keyword.trim().toLowerCase();
      if (needle.isNotEmpty && haystack.contains(needle)) {
        return true;
      }
    }
    return false;
  }

  int _laneCount() {
    final lineHeight = _fontPx * kDanmakuLineHeightFactor;
    if (lineHeight <= 0) {
      return 0;
    }
    return (_height * settings.areaFraction / lineHeight).floor();
  }

  /// 车道空闲判定(当前几何,不重排已上场弹幕):
  /// - 固定弹幕:前一条仍在该车道则占用。
  /// - 滚动弹幕:前一条须整段进入画面,且新条在旧条离开前追不上。
  bool _laneFree(
    List<DanmakuActive?> lanes,
    int lane,
    DanmakuMode mode,
    double width,
    Duration lifespan,
    Duration spawn,
  ) {
    final last = lanes[lane];
    if (last == null) {
      return true;
    }
    if (spawn - last.spawn >= last.lifespan) {
      lanes[lane] = null;
      return true;
    }
    if (mode != DanmakuMode.scroll) {
      return false;
    }
    return _scrollLaneClear(last, width, lifespan, spawn);
  }

  bool _scrollLaneClear(
    DanmakuActive last,
    double width,
    Duration lifespan,
    Duration spawn,
  ) {
    final lastSpan = last.lifespan.inMicroseconds;
    final nextSpan = lifespan.inMicroseconds;
    if (lastSpan <= 0 || nextSpan <= 0 || _width <= 0) {
      return false;
    }
    final lastProgress = ((spawn - last.spawn).inMicroseconds / lastSpan).clamp(
      0.0,
      1.0,
    );
    final lastLeft = _width - lastProgress * (_width + last.width);
    final lastRight = lastLeft + last.width;
    // 前一条还挂在右沿外,新条会叠在同一入口。
    if (lastRight > _width - kDanmakuCollisionGap) {
      return false;
    }
    final v1 = (_width + last.width) / lastSpan;
    final v2 = (_width + width) / nextSpan;
    if (v2 <= v1) {
      return true;
    }
    // 旧条右缘离开左边界时,新条左缘仍须留出间隙。
    final timeToLastExit = lastRight / v1;
    final newLeftThen = _width - v2 * timeToLastExit;
    return newLeftThen >= kDanmakuCollisionGap;
  }
}
