import 'package:flutter/widgets.dart';
import 'package:rillight/player/danmaku/dandanplay_models.dart';
import 'package:rillight/player/danmaku/danmaku_display_settings.dart';

// 显示参数已迁至独立文件;此处转出口以兼容仍从本文件导入的调用方。
export 'package:rillight/player/danmaku/danmaku_display_settings.dart';

/// 基础字号(逻辑像素),最终字号 = 基础字号 × fontScale。
const double kDanmakuBaseFontSize = 24;

/// 滚动弹幕基础穿越时长(秒),实际 = 基础 / speed。
const double kDanmakuScrollSeconds = 12;

/// 顶部/底部固定弹幕的停留时长(秒)。
const double kDanmakuFixedSeconds = 5;

/// 播放位置回跳或前跳超过该阈值视为 seek:清屏并按新位置重建。
/// 小于该幅度的回退视为进度抖动,不得重排车道,否则弹幕会上下左右跳。
const Duration kDanmakuSeekThreshold = Duration(seconds: 2);

/// 同车道弹幕之间的最小像素间隙,避免描边重叠。
const double kDanmakuCollisionGap = 8;

/// 一帧待绘制弹幕:文本、颜色、字号与画布内位置。
class DanmakuFrame {
  const DanmakuFrame({
    required this.id,
    required this.text,
    required this.color,
    required this.fontSize,
    required this.left,
    required this.top,
    required this.opacity,
  });

  /// 弹幕条目标识(dandanplay cid),渲染层文本缓存键使用。
  final int id;
  final String text;
  final int color;
  final double fontSize;
  final double left;
  final double top;
  final double opacity;
}

/// 文本宽度测量器:渲染层用 TextPainter,单测用确定性假实现注入。
typedef DanmakuTextMeasurer = double Function(String text, double fontSize);

/// 活动弹幕条目(spawn 后的运行时状态)。
class _ActiveEntry {
  _ActiveEntry({
    required this.comment,
    required this.lane,
    required this.width,
    required this.spawn,
    required this.lifespan,
  });

  final DanmakuComment comment;
  final int lane;
  final double width;
  final Duration spawn;
  final Duration lifespan;
}

/// 弹幕时间轴布局引擎:纯逻辑,按播放位置驱动弹幕进入/退出,
/// seek 后清屏并按新位置重建可见集(仍处于显示窗口内的弹幕按比例复位)。
class DanmakuLayout {
  DanmakuLayout({required DanmakuTextMeasurer measurer}) : _measure = measurer;

  final DanmakuTextMeasurer _measure;

  List<DanmakuComment> comments = const [];
  DanmakuDisplaySettings settings = const DanmakuDisplaySettings();

  final List<_ActiveEntry> _active = [];
  // 各模式每条轨道最近一条弹幕,用于防追尾的车道分配。
  final Map<DanmakuMode, List<_ActiveEntry?>> _laneLast = {};
  Duration? _lastPosition;
  int _cursor = 0;
  double _width = 0;
  double _height = 0;

  /// 当前同屏弹幕数(密度上限的判定依据)。
  int get activeCount => _active.length;

  /// 重置运行时状态(切换集/更换显示参数后调用)。
  void reset() {
    _active.clear();
    _laneLast.clear();
    _lastPosition = null;
    _cursor = 0;
  }

  /// 按播放位置推进一帧,返回当前可见弹幕的绘制帧。
  List<DanmakuFrame> update(Duration position, Size size) {
    if (comments.isEmpty) {
      return const [];
    }
    _width = size.width;
    _height = size.height;
    final last = _lastPosition;
    final seek = _isSeek(position, last);
    // 未达 seek 阈值的回退当成时钟抖动:保持单调时钟,已上场弹幕车道不动。
    final clock = (!seek && last != null && position < last) ? last : position;
    if (seek) {
      _handleSeek(clock);
    } else {
      _spawnDue(clock);
    }
    _lastPosition = clock;
    _expire(clock);

    final frames = <DanmakuFrame>[];
    final fontSize = kDanmakuBaseFontSize * settings.fontScale;
    final lineHeight = fontSize * 1.35;
    final areaHeight = _height * settings.areaFraction;
    for (final entry in _active) {
      final span = entry.lifespan.inMicroseconds;
      final raw = span <= 0 ? 1.0 : (clock - entry.spawn).inMicroseconds / span;
      final progress = raw.clamp(0.0, 1.0);
      final left = switch (entry.comment.renderMode) {
        DanmakuMode.scroll => _width - progress * (_width + entry.width),
        _ => (_width - entry.width) / 2,
      };
      final top = switch (entry.comment.renderMode) {
        DanmakuMode.scroll => entry.lane * lineHeight,
        DanmakuMode.top => entry.lane * lineHeight,
        // 底部固定:贴显示区域下沿向上排。
        DanmakuMode.bottom => areaHeight - (entry.lane + 1) * lineHeight,
      };
      frames.add(
        DanmakuFrame(
          id: entry.comment.cid,
          text: entry.comment.text,
          color: entry.comment.color,
          fontSize: fontSize,
          left: left,
          top: top,
          opacity: settings.opacity,
        ),
      );
    }
    return frames;
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

  /// seek:清屏重建。显示窗口覆盖新位置的弹幕按其真实出现时刻复位
  /// (滚动进度按时间比例恢复,位置跟随新播放位置)。
  void _handleSeek(Duration position) {
    _active.clear();
    _laneLast.clear();
    final maxLifespan = _maxLifespan();
    var index = comments.indexWhere(
      (comment) => comment.time > position.inMilliseconds / 1000,
    );
    if (index < 0) {
      index = comments.length;
    }
    _cursor = index;
    // 按时间正序播种,车道分配与正向播放一致,避免 seek 后上下乱跳。
    var start = index;
    while (start > 0) {
      final at = comments[start - 1].time * 1000;
      if (position.inMilliseconds - at > maxLifespan) {
        break;
      }
      start--;
    }
    for (var i = start; i < index; i++) {
      final at = comments[i].time * 1000;
      _spawn(comments[i], Duration(milliseconds: at.round()));
    }
  }

  double _maxLifespan() {
    var seconds = kDanmakuScrollSeconds / settings.speed;
    if (kDanmakuFixedSeconds / settings.speed > seconds) {
      seconds = kDanmakuFixedSeconds / settings.speed;
    }
    return seconds * 1000;
  }

  /// 播放推进:产出时间落在 (上一位置, 当前位置] 的弹幕,
  /// 以弹幕自身时刻为出生点(滚动进度与时间轴精确对齐)。
  void _spawnDue(Duration position) {
    final positionSeconds = position.inMilliseconds / 1000;
    while (_cursor < comments.length &&
        comments[_cursor].time <= positionSeconds) {
      final comment = comments[_cursor];
      _cursor++;
      _spawn(comment, Duration(milliseconds: (comment.time * 1000).round()));
    }
  }

  void _expire(Duration position) {
    if (_active.isEmpty) {
      return;
    }
    _active.removeWhere((entry) {
      final dead = position - entry.spawn >= entry.lifespan;
      if (dead) {
        _clearLaneIfCurrent(entry);
      }
      return dead;
    });
  }

  void _clearLaneIfCurrent(_ActiveEntry entry) {
    final lanes = _laneLast[entry.comment.renderMode];
    if (lanes == null || entry.lane >= lanes.length) {
      return;
    }
    if (identical(lanes[entry.lane], entry)) {
      lanes[entry.lane] = null;
    }
  }

  void _spawn(DanmakuComment comment, Duration spawn) {
    if (_isBlocked(comment)) {
      return;
    }
    final fontSize = kDanmakuBaseFontSize * settings.fontScale;
    final laneCount = _laneCount(fontSize);
    if (laneCount <= 0) {
      return;
    }
    // 密度上限 = 档位倍数 × 车道数,作用于同屏总数;unlimited 不设上限。
    final multiplier = settings.density.laneMultiplier;
    if (multiplier != null && _active.length >= multiplier * laneCount) {
      return;
    }
    final width = _measure(comment.text, fontSize);
    final mode = comment.renderMode;
    final lifespan = Duration(
      milliseconds:
          ((mode == DanmakuMode.scroll
                      ? kDanmakuScrollSeconds
                      : kDanmakuFixedSeconds) /
                  settings.speed *
                  1000)
              .round(),
    );
    final lanes = _laneLast.putIfAbsent(mode, () => <_ActiveEntry?>[]);
    while (lanes.length < laneCount) {
      lanes.add(null);
    }
    for (var lane = 0; lane < laneCount; lane++) {
      if (_laneFree(lanes, lane, mode, width, lifespan, spawn)) {
        final entry = _ActiveEntry(
          comment: comment,
          lane: lane,
          width: width,
          spawn: spawn,
          lifespan: lifespan,
        );
        _active.add(entry);
        lanes[lane] = entry;
        return;
      }
    }
    // 全部车道拥挤:丢弃本条(标准防重叠策略)。
  }

  bool _isBlocked(DanmakuComment comment) {
    final keywords = settings.blockedKeywords;
    if (keywords.isEmpty) {
      return false;
    }
    final text = comment.text.toLowerCase();
    for (final keyword in keywords) {
      final needle = keyword.trim().toLowerCase();
      if (needle.isNotEmpty && text.contains(needle)) {
        return true;
      }
    }
    return false;
  }

  int _laneCount(double fontSize) {
    final lineHeight = fontSize * 1.35;
    if (lineHeight <= 0) {
      return 0;
    }
    return (_height * settings.areaFraction / lineHeight).floor();
  }

  /// 车道空闲判定(当前几何,不重排已上场弹幕):
  /// - 固定弹幕:前一条仍在该车道则占用。
  /// - 滚动弹幕:前一条须整段进入画面,且新条在旧条离开前追不上。
  bool _laneFree(
    List<_ActiveEntry?> lanes,
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
    _ActiveEntry last,
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
