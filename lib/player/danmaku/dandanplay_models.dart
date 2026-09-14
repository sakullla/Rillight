/// dandanplay 开放 API 的数据模型(弹弹play API 规范)。
///
/// 同时被 API 客户端、匹配记忆持久化(player_settings.dart)与渲染层使用。
library;

/// 一条弹幕评论。
///
/// [mode] 为 dandanplay 规范的模式:1 滚动、4 底部固定、5 顶部固定,
/// 其余未知模式按滚动处理;[time] 为该条弹幕出现的播放时刻(秒)。
class DanmakuComment {
  const DanmakuComment({
    required this.cid,
    required this.time,
    required this.mode,
    required this.color,
    required this.text,
  });

  final int cid;
  final double time;
  final int mode;
  final int color;
  final String text;

  DanmakuMode get renderMode {
    switch (mode) {
      case 4:
        return DanmakuMode.bottom;
      case 5:
        return DanmakuMode.top;
      default:
        return DanmakuMode.scroll;
    }
  }

  /// 按时间升序排序用的比较器。
  static int compareByTime(DanmakuComment a, DanmakuComment b) {
    return a.time.compareTo(b.time);
  }
}

/// 弹幕渲染模式。
enum DanmakuMode { scroll, top, bottom }

/// dandanplay 动画(番剧)下的一个剧集条目。
class DanmakuEpisode {
  const DanmakuEpisode({required this.episodeId, required this.episodeTitle});

  final int episodeId;
  final String episodeTitle;
}

/// dandanplay 搜索/匹配结果中的动画条目。
///
/// [type] 为动画类型字符串(tvseries/movie/ova 等),降级标题搜索时
/// 客户端按条目类型(电影/剧集)过滤结果。
class DanmakuAnime {
  const DanmakuAnime({
    required this.animeId,
    required this.animeTitle,
    this.type,
    this.episodes = const [],
  });

  final int animeId;
  final String animeTitle;
  final String? type;
  final List<DanmakuEpisode> episodes;

  bool get isMovie => type == 'movie';

  bool get isSeries => type == 'tvseries';
}

/// POST /api/v2/match 的单个候选匹配。
class DanmakuMatchCandidate {
  const DanmakuMatchCandidate({
    required this.animeId,
    required this.animeTitle,
    required this.episodeId,
    required this.episodeTitle,
  });

  final int animeId;
  final String animeTitle;
  final int episodeId;
  final String episodeTitle;
}

/// POST /api/v2/match 的响应。
class DanmakuMatchResponse {
  const DanmakuMatchResponse({required this.isMatched, required this.matches});

  final bool isMatched;
  final List<DanmakuMatchCandidate> matches;
}

/// 按剧(seriesId)记忆的 dandanplay 匹配结果:
/// 记住动画与集,同剧后续集自动沿用该动画并按集号对位。
class DanmakuSeriesMemory {
  const DanmakuSeriesMemory({
    required this.animeId,
    required this.animeTitle,
    this.episodeId,
    this.episodeNumber,
  });

  final int animeId;
  final String animeTitle;
  final int? episodeId;
  final int? episodeNumber;

  Map<String, dynamic> toJson() => {
    'animeId': animeId,
    'animeTitle': animeTitle,
    if (episodeId != null) 'episodeId': episodeId,
    if (episodeNumber != null) 'episodeNumber': episodeNumber,
  };

  factory DanmakuSeriesMemory.fromJson(Map<String, dynamic> json) {
    return DanmakuSeriesMemory(
      animeId: _asInt(json['animeId']) ?? 0,
      animeTitle: json['animeTitle']?.toString() ?? '',
      episodeId: _asInt(json['episodeId']),
      episodeNumber: _asInt(json['episodeNumber']),
    );
  }
}

int? _asInt(dynamic raw) {
  if (raw is int) {
    return raw;
  }
  if (raw is num) {
    return raw.toInt();
  }
  if (raw is String) {
    return int.tryParse(raw);
  }
  return null;
}
