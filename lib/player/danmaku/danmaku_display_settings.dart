import 'package:flutter/foundation.dart' show immutable, listEquals;

/// 同屏密度档:以「车道数 × 倍数」限制同屏弹幕总数。
enum DanmakuDensity {
  /// 2× 车道数。
  auto(2),

  /// 1× 车道数。
  sparse(1),

  /// 4× 车道数。
  dense(4),

  /// 不限。
  unlimited(null);

  const DanmakuDensity(this.laneMultiplier);

  /// 同屏上限 = laneMultiplier × 车道数;null 表示不限。
  final int? laneMultiplier;
}

/// 字号档位:小 / 中 / 大 / 特大。
const List<double> kDanmakuFontScaleSteps = [0.75, 1.0, 1.25, 1.5];

/// 速度档位:慢 / 标准 / 快 / 极快(穿越秒数 = 12 / speed)。
const List<double> kDanmakuSpeedSteps = [0.75, 1.0, 1.5, 2.0];

/// 显示区域档位:1/4 / 半屏 / 3/4 / 全屏。
const List<double> kDanmakuAreaFractionSteps = [0.25, 0.5, 0.75, 1.0];

/// 不透明度下限(上限 1.0)。
const double kDanmakuOpacityMin = 0.2;

/// 时间偏移绝对值上限。
const Duration kDanmakuTimeOffsetMax = Duration(seconds: 60);

/// 合并重复弹幕的时间窗:窗内相同文本折叠为一条并计数。
const Duration kDanmakuMergeWindow = Duration(seconds: 20);

/// 弹幕显示参数(持久化于 PlayerSettings.danmakuDisplay)。
///
/// 构造函数保留原值;[copyWith]/[fromJson] 将连续值收敛到合法区间、
/// 档位值吸附到最近档位、关键词去空白去重。[toJson] 总是输出全部字段
/// (含空数组、false、0),使 FilePlayerSettingsStore 的浅合并写可以
/// 覆盖或清空任意值;「恢复默认」即写入 `const DanmakuDisplaySettings()`。
@immutable
class DanmakuDisplaySettings {
  const DanmakuDisplaySettings({
    this.opacity = 0.85,
    this.fontScale = 1.0,
    this.speed = 1.0,
    this.areaFraction = 0.5,
    this.showScroll = true,
    this.showTop = true,
    this.showBottom = true,
    this.colorful = true,
    this.preventOverlap = true,
    this.density = DanmakuDensity.auto,
    this.mergeDuplicates = true,
    this.outline = true,
    this.followPlaybackRate = true,
    this.timeOffset = Duration.zero,
    this.blockedKeywords = const [],
  });

  /// 不透明度 0.2–1.0。
  final double opacity;

  /// 字号缩放,档位见 [kDanmakuFontScaleSteps]。
  final double fontScale;

  /// 速度倍率,档位见 [kDanmakuSpeedSteps](数值越大滚动越快)。
  final double speed;

  /// 显示区域:画面顶部起的高度占比,档位见 [kDanmakuAreaFractionSteps]。
  final double areaFraction;

  /// 是否显示滚动弹幕。
  final bool showScroll;

  /// 是否显示顶部固定弹幕。
  final bool showTop;

  /// 是否显示底部固定弹幕。
  final bool showBottom;

  /// 彩色弹幕;false 时全部以白色绘制。
  final bool colorful;

  /// 防重叠:true 时车道拥挤则丢弃,false 时允许同车道叠放。
  final bool preventOverlap;

  /// 同屏密度档。
  final DanmakuDensity density;

  /// 合并 [kDanmakuMergeWindow] 内的重复文本并显示 ×N。
  final bool mergeDuplicates;

  /// 文字描边。
  final bool outline;

  /// 弹幕寿命是否跟随播放倍速。
  final bool followPlaybackRate;

  /// 时间偏移(正值弹幕延后出现),绝对值不超过 [kDanmakuTimeOffsetMax]。
  final Duration timeOffset;

  /// 屏蔽关键词:弹幕文本包含任一关键词(不区分大小写)时整条不显示。
  final List<String> blockedKeywords;

  DanmakuDisplaySettings copyWith({
    double? opacity,
    double? fontScale,
    double? speed,
    double? areaFraction,
    bool? showScroll,
    bool? showTop,
    bool? showBottom,
    bool? colorful,
    bool? preventOverlap,
    DanmakuDensity? density,
    bool? mergeDuplicates,
    bool? outline,
    bool? followPlaybackRate,
    Duration? timeOffset,
    List<String>? blockedKeywords,
  }) {
    return DanmakuDisplaySettings(
      opacity: _clampOpacity(opacity ?? this.opacity),
      fontScale: _snap(fontScale ?? this.fontScale, kDanmakuFontScaleSteps),
      speed: _snap(speed ?? this.speed, kDanmakuSpeedSteps),
      areaFraction: _snap(
        areaFraction ?? this.areaFraction,
        kDanmakuAreaFractionSteps,
      ),
      showScroll: showScroll ?? this.showScroll,
      showTop: showTop ?? this.showTop,
      showBottom: showBottom ?? this.showBottom,
      colorful: colorful ?? this.colorful,
      preventOverlap: preventOverlap ?? this.preventOverlap,
      density: density ?? this.density,
      mergeDuplicates: mergeDuplicates ?? this.mergeDuplicates,
      outline: outline ?? this.outline,
      followPlaybackRate: followPlaybackRate ?? this.followPlaybackRate,
      timeOffset: _clampOffset(timeOffset ?? this.timeOffset),
      blockedKeywords: normalizeKeywords(
        blockedKeywords ?? this.blockedKeywords,
      ),
    );
  }

  /// 全字段输出,不省略默认值/空值。
  Map<String, dynamic> toJson() => {
    'opacity': opacity,
    'fontScale': fontScale,
    'speed': speed,
    'areaFraction': areaFraction,
    'showScroll': showScroll,
    'showTop': showTop,
    'showBottom': showBottom,
    'colorful': colorful,
    'preventOverlap': preventOverlap,
    'density': density.name,
    'mergeDuplicates': mergeDuplicates,
    'outline': outline,
    'followPlaybackRate': followPlaybackRate,
    'timeOffsetMs': timeOffset.inMilliseconds,
    'blockedKeywords': List<String>.of(blockedKeywords),
  };

  /// 缺失/非法字段取默认;旧版连续值吸附到最近档位;旧 `maxVisibleCount`
  /// 忽略(由 [density] 取代)。
  factory DanmakuDisplaySettings.fromJson(Map<String, dynamic> json) {
    const defaults = DanmakuDisplaySettings();
    return DanmakuDisplaySettings(
      opacity: _clampOpacity(_asDouble(json['opacity']) ?? defaults.opacity),
      fontScale: _snap(
        _asDouble(json['fontScale']) ?? defaults.fontScale,
        kDanmakuFontScaleSteps,
      ),
      speed: _snap(
        _asDouble(json['speed']) ?? defaults.speed,
        kDanmakuSpeedSteps,
      ),
      areaFraction: _snap(
        _asDouble(json['areaFraction']) ?? defaults.areaFraction,
        kDanmakuAreaFractionSteps,
      ),
      showScroll: _asBool(json['showScroll']) ?? defaults.showScroll,
      showTop: _asBool(json['showTop']) ?? defaults.showTop,
      showBottom: _asBool(json['showBottom']) ?? defaults.showBottom,
      colorful: _asBool(json['colorful']) ?? defaults.colorful,
      preventOverlap:
          _asBool(json['preventOverlap']) ?? defaults.preventOverlap,
      density: _asDensity(json['density']) ?? defaults.density,
      mergeDuplicates:
          _asBool(json['mergeDuplicates']) ?? defaults.mergeDuplicates,
      outline: _asBool(json['outline']) ?? defaults.outline,
      followPlaybackRate:
          _asBool(json['followPlaybackRate']) ?? defaults.followPlaybackRate,
      timeOffset: _clampOffset(
        Duration(milliseconds: _asInt(json['timeOffsetMs']) ?? 0),
      ),
      blockedKeywords: normalizeKeywords(
        json['blockedKeywords'] is List
            ? [
                for (final keyword in json['blockedKeywords'] as List)
                  keyword.toString(),
              ]
            : const [],
      ),
    );
  }

  /// 去首尾空白、去空项、不区分大小写去重(保留首次出现的写法与顺序)。
  static List<String> normalizeKeywords(Iterable<String> raw) {
    final seen = <String>{};
    final result = <String>[];
    for (final keyword in raw) {
      final trimmed = keyword.trim();
      if (trimmed.isEmpty || !seen.add(trimmed.toLowerCase())) {
        continue;
      }
      result.add(trimmed);
    }
    return List.unmodifiable(result);
  }

  /// 吸附到最近档位;并列时取较小档位。
  static double snapToStep(double value, List<double> steps) =>
      _snap(value, steps);

  static double _snap(double value, List<double> steps) {
    if (value.isNaN || value.isInfinite) {
      return steps.contains(1.0) ? 1.0 : steps.first;
    }
    var best = steps.first;
    var bestDistance = (value - best).abs();
    for (final step in steps.skip(1)) {
      final distance = (value - step).abs();
      if (distance < bestDistance) {
        best = step;
        bestDistance = distance;
      }
    }
    return best;
  }

  static double _clampOpacity(double value) {
    if (value.isNaN) {
      return 0.85;
    }
    return value.clamp(kDanmakuOpacityMin, 1.0);
  }

  static Duration _clampOffset(Duration value) {
    if (value > kDanmakuTimeOffsetMax) {
      return kDanmakuTimeOffsetMax;
    }
    if (value < -kDanmakuTimeOffsetMax) {
      return -kDanmakuTimeOffsetMax;
    }
    return value;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is DanmakuDisplaySettings &&
        other.opacity == opacity &&
        other.fontScale == fontScale &&
        other.speed == speed &&
        other.areaFraction == areaFraction &&
        other.showScroll == showScroll &&
        other.showTop == showTop &&
        other.showBottom == showBottom &&
        other.colorful == colorful &&
        other.preventOverlap == preventOverlap &&
        other.density == density &&
        other.mergeDuplicates == mergeDuplicates &&
        other.outline == outline &&
        other.followPlaybackRate == followPlaybackRate &&
        other.timeOffset == timeOffset &&
        listEquals(other.blockedKeywords, blockedKeywords);
  }

  @override
  int get hashCode => Object.hash(
    opacity,
    fontScale,
    speed,
    areaFraction,
    showScroll,
    showTop,
    showBottom,
    colorful,
    preventOverlap,
    density,
    mergeDuplicates,
    outline,
    followPlaybackRate,
    timeOffset,
    Object.hashAll(blockedKeywords),
  );

  @override
  String toString() => 'DanmakuDisplaySettings(${toJson()})';
}

double? _asDouble(dynamic raw) {
  final value = raw is num
      ? raw.toDouble()
      : double.tryParse(raw?.toString() ?? '');
  return value == null || value.isNaN || value.isInfinite ? null : value;
}

int? _asInt(dynamic raw) {
  if (raw is int) {
    return raw;
  }
  if (raw is num) {
    return raw.isFinite ? raw.round() : null;
  }
  return int.tryParse(raw?.toString() ?? '');
}

bool? _asBool(dynamic raw) => raw is bool ? raw : null;

DanmakuDensity? _asDensity(dynamic raw) {
  if (raw is! String) {
    return null;
  }
  for (final value in DanmakuDensity.values) {
    if (value.name == raw) {
      return value;
    }
  }
  return null;
}
