import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:rillight/player/danmaku/dandanplay_models.dart';

/// 弹幕显示参数(持久化于 PlayerSettings.danmakuDisplay)。
///
/// [copyWith]/[fromJson] 将字段收敛到合法区间;[blockedKeywords] 为基础
/// 屏蔽项,弹幕文本包含任一关键词(不区分大小写)时整条不显示。
class DanmakuDisplaySettings {
  const DanmakuDisplaySettings({
    this.opacity = 1,
    this.fontScale = 1,
    this.speed = 1,
    this.areaFraction = 0.5,
    this.maxVisibleCount,
    this.blockedKeywords = const [],
  });

  /// 不透明度 0.1–1。
  final double opacity;

  /// 字号缩放 0.5–2。
  final double fontScale;

  /// 速度倍率 0.5–2(数值越大滚动越快)。
  final double speed;

  /// 显示区域:画面顶部起的高度占比 0.1–1。
  final double areaFraction;

  /// 密度:同屏弹幕上限;null 表示不限。
  final int? maxVisibleCount;

  /// 基础屏蔽关键词。
  final List<String> blockedKeywords;

  DanmakuDisplaySettings copyWith({
    double? opacity,
    double? fontScale,
    double? speed,
    double? areaFraction,
    int? maxVisibleCount,
    bool unlimitedDensity = false,
    List<String>? blockedKeywords,
  }) {
    return DanmakuDisplaySettings(
      opacity: _clamp(opacity ?? this.opacity, 0.1, 1),
      fontScale: _clamp(fontScale ?? this.fontScale, 0.5, 2),
      speed: _clamp(speed ?? this.speed, 0.5, 2),
      areaFraction: _clamp(areaFraction ?? this.areaFraction, 0.1, 1),
      maxVisibleCount: unlimitedDensity
          ? null
          : (maxVisibleCount ?? this.maxVisibleCount),
      blockedKeywords: blockedKeywords ?? this.blockedKeywords,
    );
  }

  Map<String, dynamic> toJson() => {
    'opacity': opacity,
    'fontScale': fontScale,
    'speed': speed,
    'areaFraction': areaFraction,
    if (maxVisibleCount != null) 'maxVisibleCount': maxVisibleCount,
    if (blockedKeywords.isNotEmpty) 'blockedKeywords': blockedKeywords,
  };

  factory DanmakuDisplaySettings.fromJson(Map<String, dynamic> json) {
    return DanmakuDisplaySettings(
      opacity: _clamp(_asDouble(json['opacity']) ?? 1, 0.1, 1),
      fontScale: _clamp(_asDouble(json['fontScale']) ?? 1, 0.5, 2),
      speed: _clamp(_asDouble(json['speed']) ?? 1, 0.5, 2),
      areaFraction: _clamp(_asDouble(json['areaFraction']) ?? 0.5, 0.1, 1),
      maxVisibleCount: _asInt(json['maxVisibleCount']),
      blockedKeywords: [
        for (final keyword in (json['blockedKeywords'] as List? ?? const []))
          keyword.toString(),
      ],
    );
  }

  static double _clamp(double value, double min, double max) {
    return math.min(math.max(value, min), max);
  }
}

double? _asDouble(dynamic raw) =>
    raw is num ? raw.toDouble() : double.tryParse(raw?.toString() ?? '');

int? _asInt(dynamic raw) {
  if (raw is int) {
    return raw;
  }
  if (raw is num) {
    return raw.toInt();
  }
  return int.tryParse(raw?.toString() ?? '');
}

/// 基础字号(逻辑像素),最终字号 = 基础字号 × fontScale。
const double kDanmakuBaseFontSize = 24;

/// 滚动弹幕基础穿越时长(秒),实际 = 基础 / speed。
const double kDanmakuScrollSeconds = 12;

/// 顶部/底部固定弹幕的停留时长(秒)。
const double kDanmakuFixedSeconds = 5;

/// 播放位置回跳任意幅度或前跳超过该阈值视为 seek:清屏并按新位置重建。
const Duration kDanmakuSeekThreshold = Duration(seconds: 2);

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
    final isSeek =
        last == null ||
        position < last ||
        position - last > kDanmakuSeekThreshold;
    if (isSeek) {
      _handleSeek(position);
    } else {
      _spawnDue(position);
    }
    _lastPosition = position;
    _expire(position);

    final frames = <DanmakuFrame>[];
    final fontSize = kDanmakuBaseFontSize * settings.fontScale;
    final lineHeight = fontSize * 1.35;
    final areaHeight = _height * settings.areaFraction;
    for (final entry in _active) {
      final progress =
          (position - entry.spawn).inMicroseconds /
          entry.lifespan.inMicroseconds;
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
    // 回看窗口内已出现但尚未退出的弹幕按真实时刻重新播种。
    for (var i = index - 1; i >= 0; i--) {
      final at = comments[i].time * 1000;
      if (position.inMilliseconds - at > maxLifespan) {
        break;
      }
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
    _active.removeWhere((entry) => position - entry.spawn >= entry.lifespan);
  }

  void _spawn(DanmakuComment comment, Duration spawn) {
    if (_isBlocked(comment)) {
      return;
    }
    final cap = settings.maxVisibleCount;
    if (cap != null && cap > 0 && _active.length >= cap) {
      return;
    }
    final fontSize = kDanmakuBaseFontSize * settings.fontScale;
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
    final laneCount = _laneCount(fontSize);
    if (laneCount <= 0) {
      return;
    }
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

  /// 车道空闲判定:
  /// - 固定弹幕:前一条已退出该车道即可。
  /// - 滚动弹幕:推导防追尾条件——同速时前一条须完全进入画面;
  ///   新条更快(更宽)时要求足够的前距,保证新条在旧条退出前不追上。
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
      return true;
    }
    if (mode != DanmakuMode.scroll) {
      return false;
    }
    final v1 = (_width + last.width) / last.lifespan.inMicroseconds;
    final v2 = (_width + width) / lifespan.inMicroseconds;
    final head = (spawn - last.spawn).inMicroseconds;
    // head 是时间余量,速度单位为 像素/微秒,换算统一。
    if (v2 <= v1) {
      return head * v1 >= last.width;
    }
    final required = (last.width + (v2 - v1) * (_width + last.width) / v1) / v2;
    return head >= required;
  }
}
