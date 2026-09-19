/// 为 dandanplay 兼容 `/api/v2/match` 组装 fileName。
///
/// 弹弹把每一季算作不同番剧。有真实媒体文件名且季号一致时原样使用;
/// 文件名缺季或季号和片库冲突时,用剧名 + SxxExx(uosc_danmaku 同款)。
/// 电影在文件名没有年份时补上 [productionYear],避免同名翻拍被排到前面。
String danmakuMatchFileName({
  String? pathBaseName,
  String? seriesTitle,
  String? title,
  int? seasonIndex,
  int? episodeIndex,
  int? height,
  int? productionYear,
}) {
  final fromPath = pathBaseName?.trim() ?? '';
  final isEpisode = episodeIndex != null && episodeIndex > 0;
  final show = _firstNonEmpty([seriesTitle, title]);
  if (show.isNotEmpty && isEpisode) {
    final season =
        danmakuEffectiveSeason(seasonIndex: seasonIndex, seriesTitle: show) ??
        1;
    final pathSeason = parseSeasonNumber(fromPath);
    if (_looksLikeReleaseName(fromPath) && pathSeason == season) {
      return fromPath;
    }
    final tag =
        'S${season.toString().padLeft(2, '0')}E${episodeIndex.toString().padLeft(2, '0')}';
    final quality = _qualityTag(height);
    if (quality == null) {
      return '$show $tag';
    }
    return '$show.$tag.$quality';
  }
  if (_looksLikeReleaseName(fromPath)) {
    return isEpisode
        ? fromPath
        : danmakuTitleWithYear(fromPath, productionYear);
  }
  final fallback = _firstNonEmpty([title, fromPath]);
  if (fallback.isEmpty) {
    return danmakuTitleWithYear(fromPath, productionYear);
  }
  final quality = _qualityTag(height);
  final named = quality == null ? fallback : '$fallback.$quality';
  return danmakuTitleWithYear(named, productionYear);
}

String _firstNonEmpty(List<String?> values) {
  for (final value in values) {
    final trimmed = value?.trim() ?? '';
    if (trimmed.isNotEmpty) {
      return trimmed;
    }
  }
  return '';
}

/// 同剧不同季分开记:弹弹每个季度是独立番剧。第 1 季沿用旧的 seriesId 键。
/// 片库季号优先用 ParentIndex;剧名已带「第N季」时也认,避免把第四季当成 S01。
int? danmakuEffectiveSeason({int? seasonIndex, String? seriesTitle}) {
  final fromIndex = seasonIndex != null && seasonIndex > 0 ? seasonIndex : null;
  final fromName = parseSeasonNumber(seriesTitle ?? '');
  if (fromIndex != null && fromIndex > 1) {
    return fromIndex;
  }
  return fromName ?? fromIndex;
}

String danmakuMemoryKey(String seriesId, int? seasonIndex) {
  final season = seasonIndex != null && seasonIndex > 0 ? seasonIndex : 1;
  if (season == 1) {
    return seriesId;
  }
  return '$seriesId#s$season';
}

/// 搜索关键词:第 2 季起带「第N季」,避免命中第一季同名番剧。
String danmakuSearchKeyword({
  String? seriesTitle,
  String? title,
  String? fileName,
  int? seasonIndex,
  int? productionYear,
  bool isMovie = false,
}) {
  var keyword = _firstNonEmpty([seriesTitle, title, fileName]);
  if (isMovie) {
    return danmakuTitleWithYear(keyword, productionYear);
  }
  return danmakuTitleWithSeason(
    keyword,
    danmakuEffectiveSeason(seasonIndex: seasonIndex, seriesTitle: keyword),
  );
}

String danmakuTitleWithSeason(String name, int? seasonIndex) {
  final trimmed = name.trim();
  if (trimmed.isEmpty || seasonIndex == null || seasonIndex <= 1) {
    return trimmed;
  }
  if (parseSeasonNumber(trimmed) == seasonIndex) {
    return trimmed;
  }
  return '$trimmed 第$seasonIndex季';
}

/// 电影/关键词在尚未带年份时附上 `(2014)`。
String danmakuTitleWithYear(String name, int? year) {
  final trimmed = name.trim();
  if (trimmed.isEmpty || year == null || year < 1900 || year > 2100) {
    return trimmed;
  }
  final yearText = '$year';
  if (RegExp('(?:^|[^0-9])$yearText(?:[^0-9]|\$)').hasMatch(trimmed)) {
    return trimmed;
  }
  final ext = RegExp(
    r'\.(mkv|mp4|avi|ts|m2ts|wmv|flv|webm|mov|iso|rmvb)$',
    caseSensitive: false,
  ).firstMatch(trimmed);
  if (ext == null) {
    return '$trimmed($yearText)';
  }
  return '${trimmed.substring(0, ext.start)}($yearText)${ext.group(0)}';
}

/// 在弹弹返回的多个同名条目里挑最接近片库的一条。
///
/// 年份对得上加分;标题里的「美版」等翻拍标记、对不上的年份减分。
/// 季号对得上加分;看第 2 季及以后时,没标季的条目通常是第一季,减分。
T? pickBestDanmakuTitle<T>(
  List<T> items,
  String Function(T item) titleOf, {
  String? libraryTitle,
  int? year,
  int? seasonIndex,
}) {
  if (items.isEmpty) {
    return null;
  }
  T? best;
  var bestScore = -0x7fffffff;
  for (final item in items) {
    final score = danmakuMatchTitleScore(
      titleOf(item),
      libraryTitle: libraryTitle ?? '',
      year: year,
      seasonIndex: seasonIndex,
    );
    if (best == null || score > bestScore) {
      best = item;
      bestScore = score;
    }
  }
  return best;
}

int danmakuMatchTitleScore(
  String candidate, {
  required String libraryTitle,
  int? year,
  int? seasonIndex,
}) {
  final text = candidate.trim();
  if (text.isEmpty) {
    return -1000;
  }
  final needle = libraryTitle.trim();
  var score = 0;
  if (needle.isNotEmpty) {
    if (text == needle ||
        text.startsWith('$needle(') ||
        text.startsWith('$needle ')) {
      score += 8;
    } else if (text.contains(needle)) {
      score += 3;
    }
  }
  if (year != null && year >= 1900 && year <= 2100) {
    final yearText = '$year';
    if (RegExp('(?:^|[^0-9])$yearText(?:[^0-9]|\$)').hasMatch(text)) {
      score += 12;
    }
    for (final match in RegExp(r'(?:19|20)\d{2}').allMatches(text)) {
      if (match.group(0) != yearText) {
        score -= 10;
      }
    }
  }
  const remakes = ['美版', '日版', '韩版', '台版', '英版', '德版', '印版'];
  final libraryHasRemake = remakes.any(needle.contains);
  if (!libraryHasRemake) {
    for (final tag in remakes) {
      if (text.contains(tag)) {
        score -= 15;
      }
    }
  }
  score += danmakuMatchSeasonScore(text, seasonIndex);
  return score;
}

/// 自动收下匹配的门槛:错季直接否决;翻拍、年份对不上时总分也过不了。
bool danmakuAcceptsAutoMatch(
  String candidate, {
  required String libraryTitle,
  int? year,
  int? seasonIndex,
}) {
  if (danmakuMatchSeasonScore(candidate, seasonIndex) < 0) {
    return false;
  }
  return danmakuMatchTitleScore(
        candidate,
        libraryTitle: libraryTitle,
        year: year,
        seasonIndex: seasonIndex,
      ) >=
      0;
}

/// 从标题解析季号:S02E08 / 第2季 / 第四季 / Season 2。
int? parseSeasonNumber(String title) {
  var match = RegExp(
    r'(?:^|[^a-z0-9])s(\d{1,2})e\d{1,3}',
    caseSensitive: false,
  ).firstMatch(title);
  match ??= RegExp(r'第\s*(\d{1,2})\s*季').firstMatch(title);
  if (match != null) {
    return int.tryParse(match.group(1)!);
  }
  match ??= RegExp(
    r'season\s*(\d{1,2})',
    caseSensitive: false,
  ).firstMatch(title);
  if (match != null) {
    return int.tryParse(match.group(1)!);
  }
  final chinese = RegExp(r'第\s*([一二三四五六七八九十])\s*季').firstMatch(title);
  if (chinese == null) {
    return null;
  }
  const numerals = {
    '一': 1,
    '二': 2,
    '三': 3,
    '四': 4,
    '五': 5,
    '六': 6,
    '七': 7,
    '八': 8,
    '九': 9,
    '十': 10,
  };
  return numerals[chinese.group(1)!];
}

int danmakuMatchSeasonScore(String candidate, int? seasonIndex) {
  if (seasonIndex == null || seasonIndex <= 0) {
    return 0;
  }
  final parsed = parseSeasonNumber(candidate);
  if (parsed == seasonIndex) {
    return 16;
  }
  if (parsed != null) {
    return -20;
  }
  if (seasonIndex == 1) {
    return 2;
  }
  return -8;
}

bool _looksLikeReleaseName(String name) {
  if (name.isEmpty) {
    return false;
  }
  final lower = name.toLowerCase();
  if (RegExp(
    r'\.(mkv|mp4|avi|ts|m2ts|wmv|flv|webm|mov|iso|rmvb)$',
  ).hasMatch(lower)) {
    return true;
  }
  if (RegExp(r's\d{1,2}e\d{1,3}', caseSensitive: false).hasMatch(name)) {
    return true;
  }
  if (name.contains('第') && (name.contains('集') || name.contains('话'))) {
    return true;
  }
  return false;
}

String? _qualityTag(int? height) {
  if (height == null || height < 720) {
    return null;
  }
  if (height >= 2160) {
    return '2160p';
  }
  if (height >= 1440) {
    return '1440p';
  }
  if (height >= 1080) {
    return '1080p';
  }
  return '720p';
}
