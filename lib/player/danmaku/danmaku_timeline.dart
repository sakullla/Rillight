import 'package:flutter/foundation.dart' show immutable, listEquals;
import 'package:rillight/player/danmaku/dandanplay_models.dart';
import 'package:rillight/player/danmaku/danmaku_display_settings.dart';

/// 时间轴上的一条可渲染弹幕:过滤/合并/偏移后的结果视图。
@immutable
class DanmakuEntry {
  const DanmakuEntry({
    required this.comment,
    required this.time,
    required this.mergedCount,
    required this.renderMode,
    required this.displayText,
  });

  /// 合并组的首条原始评论(cid/颜色/原文由此取)。
  final DanmakuComment comment;

  /// 上屏时刻(秒)= `comment.time + timeOffset`,可为负。
  final double time;

  /// 折叠进本条的重复条数(含自身),≥ 1。
  final int mergedCount;

  final DanmakuMode renderMode;

  /// 渲染文本:原文去首尾空白;[mergedCount] > 1 时为 `"$text ×N"`。
  final String displayText;

  int get cid => comment.cid;

  int get color => comment.color;

  @override
  String toString() =>
      'DanmakuEntry(cid: $cid, time: $time, ×$mergedCount, "$displayText")';
}

/// 合并组构建期的可变状态,完成后固化为 [DanmakuEntry]。
class _MergeGroup {
  _MergeGroup(this.head);

  final DanmakuComment head;
  int count = 1;
}

/// 弹幕时间轴:把原始评论按显示设置一次性算成不可变、按时间排序的
/// [DanmakuEntry] 列表。在评论落地或影响时间轴的设置变化时重建;
/// 布局/渲染层只消费结果,不再逐条判断类型、关键词与合并。
abstract final class DanmakuTimeline {
  /// 过滤(mode 7/8、类型开关、关键词)→ 合并重复 → 时间偏移。
  static List<DanmakuEntry> build(
    List<DanmakuComment> raw,
    DanmakuDisplaySettings settings,
  ) {
    if (raw.isEmpty) {
      return const [];
    }
    final sorted = _sortedByTime(raw);
    final needles = _needles(settings.blockedKeywords);
    final windowSeconds =
        kDanmakuMergeWindow.inMicroseconds / Duration.microsecondsPerSecond;
    final groups = <_MergeGroup>[];
    // 每个文本当前仍开着窗的合并组;窗以首条(被保留的)时刻为锚点。
    final open = <String, _MergeGroup>{};
    for (final comment in sorted) {
      if (comment.isSpecial || !_modeVisible(comment.renderMode, settings)) {
        continue;
      }
      if (needles.isNotEmpty && _matchesAny(comment.text, needles)) {
        continue;
      }
      if (!settings.mergeDuplicates) {
        groups.add(_MergeGroup(comment));
        continue;
      }
      final key = comment.text.trim();
      final current = open[key];
      if (current != null &&
          comment.time - current.head.time <= windowSeconds) {
        current.count++;
        continue;
      }
      final group = _MergeGroup(comment);
      open[key] = group;
      groups.add(group);
    }
    final offsetSeconds =
        settings.timeOffset.inMicroseconds / Duration.microsecondsPerSecond;
    return List.unmodifiable([
      for (final group in groups)
        DanmakuEntry(
          comment: group.head,
          time: group.head.time + offsetSeconds,
          mergedCount: group.count,
          renderMode: group.head.renderMode,
          displayText: _displayText(group.head.text.trim(), group.count),
        ),
    ]);
  }

  /// 渲染文本统一按去空白后的文本生成(与合并键一致),合并组追加 `×N`。
  static String _displayText(String text, int count) {
    return count > 1 ? '$text ×$count' : text;
  }

  /// 两组设置之间的差异是否需要重建时间轴。
  /// 仅类型开关、合并重复、时间偏移与关键词参与判定;
  /// 不透明度/字号/速度/区域/防重叠/密度/描边/彩色/倍速只影响布局与渲染。
  static bool affectsTimeline(
    DanmakuDisplaySettings previous,
    DanmakuDisplaySettings next,
  ) {
    return previous.showScroll != next.showScroll ||
        previous.showTop != next.showTop ||
        previous.showBottom != next.showBottom ||
        previous.mergeDuplicates != next.mergeDuplicates ||
        previous.timeOffset != next.timeOffset ||
        !listEquals(previous.blockedKeywords, next.blockedKeywords);
  }

  /// 文本是否包含任一关键词(去空白、不区分大小写)。
  static bool isBlocked(String text, List<String> keywords) {
    final needles = _needles(keywords);
    return needles.isNotEmpty && _matchesAny(text, needles);
  }

  static List<String> _needles(List<String> keywords) {
    if (keywords.isEmpty) {
      return const [];
    }
    return [
      for (final keyword in keywords)
        if (keyword.trim().isNotEmpty) keyword.trim().toLowerCase(),
    ];
  }

  static bool _matchesAny(String text, List<String> needles) {
    final haystack = text.toLowerCase();
    for (final needle in needles) {
      if (haystack.contains(needle)) {
        return true;
      }
    }
    return false;
  }

  static bool _modeVisible(DanmakuMode mode, DanmakuDisplaySettings settings) {
    return switch (mode) {
      DanmakuMode.scroll => settings.showScroll,
      DanmakuMode.top => settings.showTop,
      DanmakuMode.bottom => settings.showBottom,
    };
  }

  /// 客户端已按时间排序;仅在乱序时复制排序,避免万条级无谓拷贝。
  static List<DanmakuComment> _sortedByTime(List<DanmakuComment> raw) {
    for (var i = 1; i < raw.length; i++) {
      if (raw[i].time < raw[i - 1].time) {
        return List.of(raw)..sort(DanmakuComment.compareByTime);
      }
    }
    return raw;
  }
}
