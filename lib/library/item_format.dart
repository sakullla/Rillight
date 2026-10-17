import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/media_server/models.dart';

String? runtimeLabel(AppLocalizations l10n, MediaItem item) {
  final ticks = item.runtime;
  if (ticks == null || ticks <= Duration.zero) {
    return null;
  }
  final minutes = (ticks.inSeconds / 60).round();
  if (minutes < 60) {
    return l10n.runtimeMinutes(minutes);
  }
  return l10n.runtimeHoursMinutes(minutes ~/ 60, minutes % 60);
}

/// 未看完的剩余时长;不可续播或片长未知时为 null。
String? remainingLabel(AppLocalizations l10n, MediaItem item) {
  final runtime = item.runtime;
  if (!item.canResume || runtime == null || runtime <= Duration.zero) {
    return null;
  }
  final left = runtime - item.resumePosition;
  if (left <= Duration.zero) {
    return null;
  }
  return l10n.remainingMinutes((left.inSeconds / 60).ceil());
}

String chapterClock(Duration startPosition) {
  final seconds = startPosition <= Duration.zero ? 0 : startPosition.inSeconds;
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  final remain = seconds % 60;
  if (hours > 0) {
    final mm = minutes.toString().padLeft(2, '0');
    final ss = remain.toString().padLeft(2, '0');
    return '$hours:$mm:$ss';
  }
  return '${minutes.toString().padLeft(2, '0')}:${remain.toString().padLeft(2, '0')}';
}

/// 分集列表标题「N. 集名」。集名本身已以同一集数开头（「第 3 集」「EP03」
/// 「03 …」）时直接用集名，不再显示成「3. 第 3 集」。
String numberedEpisodeTitle(MediaItem item) {
  final number = item.indexNumber;
  if (number == null) {
    return item.name;
  }
  final match = _leadingEpisodeNumber.firstMatch(item.name.trim());
  final leading = match == null
      ? null
      : int.tryParse(match.group(1) ?? match.group(2) ?? match.group(3)!);
  return leading == number ? item.name : '$number. ${item.name}';
}

final _leadingEpisodeNumber = RegExp(
  r'^(?:第\s*(\d+)\s*[集话話期]|(?:episode|ep|e)\s*\.?\s*(\d+)|(\d+)(?!\d))',
  caseSensitive: false,
);

String? seasonEpisodeCode(MediaItem item) {
  final season = item.parentIndexNumber;
  final episode = item.indexNumber;
  if (season == null || episode == null) {
    return null;
  }
  return 'S${season}E$episode';
}

String episodeLabel(MediaItem item) {
  final code = seasonEpisodeCode(item);
  if (code == null) {
    return item.name;
  }
  final name = item.name.trim();
  return name.isEmpty ? code : '$code $name';
}

/// 继续观看副标题:有正常集名时为 S1E2 · 集名。
/// 集名经常是发行文件名(分辨率、音轨、来源),那种只保留季集编号。
String continueWatchingSubtitle(MediaItem item) {
  if (!item.isEpisode) {
    return '';
  }
  final code = seasonEpisodeCode(item);
  final name = item.name.trim();
  if (name.isNotEmpty && !_looksLikeReleaseName(name)) {
    if (code == null || name.toLowerCase().startsWith(code.toLowerCase())) {
      return name;
    }
    return '$code · $name';
  }
  return code ?? '';
}

bool _looksLikeReleaseName(String name) {
  return RegExp(
    r'1080p|720p|2160p|480p|\b4k\b|x26[45]|h\.?26[45]|hevc|flac|aac|bdrip|bluray|web-?dl|webrip|10bit',
    caseSensitive: false,
  ).hasMatch(name);
}

/// 点分或连写的发布串，例如 `NF.WD.264.AAC-SonyHD`。
/// 「导演剪辑版」「1080p SDR」这种短标签不是发布串。
bool isReleaseSourceName(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return false;
  if (trimmed.contains('.') || trimmed.contains('_')) return true;
  final tokens = trimmed
      .split(RegExp(r'[\s\-]+'))
      .where((token) => token.isNotEmpty)
      .toList();
  if (tokens.length < 3) return false;
  var technical = 0;
  for (final token in tokens) {
    if (_releaseSourceToken.hasMatch(token)) technical++;
  }
  return technical >= 2;
}

/// 发布串片源的主文字：分辨率和视频编码。人读版本名不走这里。
String releaseSourcePrimaryText(ItemMediaSource source) {
  final parts = <String>[
    ?_sourceResolution(source),
    ?_sourceVideoCodec(source),
  ];
  if (parts.isNotEmpty) return parts.join(' · ');
  final raw = (source.name ?? '').trim();
  final compact = source.presentation.compact.trim();
  if (compact.isNotEmpty && compact != raw) return compact;
  final headline = source.presentation.headline.trim();
  return headline.isNotEmpty ? headline : source.label;
}

/// 详情片源行主文字。发布串改用分辨率和编码；人读版本名保持原样。
/// 规格相同时用发行组区分，组名也相同才退回片源序号。
String phoneSourceVersionLabel(
  ItemMediaSource source,
  List<ItemMediaSource> sources,
) {
  final raw = (source.name ?? '').trim();
  if (raw.isEmpty || !isReleaseSourceName(raw)) {
    if (raw.isNotEmpty && raw.length <= 24) return raw;
    final compact = source.presentation.compact.trim();
    if (compact.isNotEmpty) return compact;
    return raw.isNotEmpty ? raw : source.label;
  }
  final tech = releaseSourcePrimaryText(source);
  final same = sources.where((other) {
    final name = (other.name ?? '').trim();
    return isReleaseSourceName(name) && releaseSourcePrimaryText(other) == tech;
  });
  if (same.length <= 1) return tech;
  final marker = sourceVersionMarker(source);
  final index = sources.indexWhere((other) => other.id == source.id);
  final number = index < 0 ? 1 : index + 1;
  if (marker == null) return '$tech · $number';
  final twins = same.where((other) => sourceVersionMarker(other) == marker);
  if (twins.length == 1) return '$tech · $marker';
  return '$tech · $marker · $number';
}

/// 发布串里用来区分同规格片源的组名。体积和码率不算。
String? sourceVersionMarker(ItemMediaSource source) {
  final detail = source.presentation.detail?.trim();
  if (detail == null || detail.isEmpty) return null;
  final parts = [
    for (final part in detail.split(' · '))
      if (part.isNotEmpty && !_sourceStat.hasMatch(part)) part,
  ];
  if (parts.isEmpty) return null;
  return parts.last;
}

final _sourceStat = RegExp(
  r'^\d+(?:\.\d+)?\s*(?:GB|MB|Mbps|kbps)$',
  caseSensitive: false,
);

final _releaseSourceToken = RegExp(
  r'^(?:480p|720p|1080p|1440p|2160p|4k|uhd|x26[45]|h\.?26[45]|hevc|avc|av1|vp9|'
  r'aac|flac|ac3|eac3|dts|truehd|atmos|bdrip|bluray|blu-ray|web-?dl|webrip|'
  r'10bit|hdr|sdr)$',
  caseSensitive: false,
);

String? _sourceResolution(ItemMediaSource source) {
  final video = source.streams.where((stream) => stream.isVideo).firstOrNull;
  final fromStream = _pixelResolution(
    video?.height ?? source.height,
    video?.width ?? source.width,
  );
  if (fromStream != null) return fromStream;
  return _tokenFromName(source.name, _filenameResolution);
}

String? _sourceVideoCodec(ItemMediaSource source) {
  final video = source.streams.where((stream) => stream.isVideo).firstOrNull;
  final fromStream = _codecLabel(video?.codec);
  if (fromStream != null) return fromStream;
  return _tokenFromName(source.name, _filenameCodec);
}

String? _pixelResolution(int? height, int? width) {
  final h = height ?? 0;
  final w = width ?? 0;
  if (h <= 0 && w <= 0) return null;
  if (h >= 2000 || w >= 3800) return '4K';
  if (h >= 1400 || w >= 2500) return '1440p';
  if (h >= 1000 || w >= 1900) return '1080p';
  if (h >= 700 || w >= 1200) return '720p';
  return 'SD';
}

String? _codecLabel(String? codec) {
  final value = codec?.trim().toLowerCase() ?? '';
  if (value.isEmpty) return null;
  if (value.contains('265') || value.contains('hevc')) return 'H.265';
  if (value.contains('264') || value.contains('avc')) return 'H.264';
  if (value.contains('av1')) return 'AV1';
  if (value.contains('vp9')) return 'VP9';
  return codec!.trim().toUpperCase();
}

String? _filenameResolution(String token) {
  switch (token.toLowerCase()) {
    case '2160p':
    case '4k':
    case 'uhd':
      return '4K';
    case '1440p':
      return '1440p';
    case '1080p':
      return '1080p';
    case '720p':
      return '720p';
    case '480p':
      return 'SD';
    default:
      return null;
  }
}

String? _filenameCodec(String token) {
  switch (token.toLowerCase()) {
    case '265':
    case 'h265':
    case 'h.265':
    case 'x265':
    case 'hevc':
      return 'H.265';
    case '264':
    case 'h264':
    case 'h.264':
    case 'x264':
    case 'avc':
      return 'H.264';
    case 'av1':
      return 'AV1';
    case 'vp9':
      return 'VP9';
    default:
      return null;
  }
}

String? _tokenFromName(String? name, String? Function(String token) map) {
  final raw = name?.trim() ?? '';
  if (raw.isEmpty) return null;
  for (final token in raw.split(RegExp(r'[.\s_\-]+'))) {
    if (token.isEmpty) continue;
    final mapped = map(token);
    if (mapped != null) return mapped;
  }
  return null;
}

/// 去掉简介里的 HTML/实体,供海报叠字与列表展示共用。
String? plainOverview(String? raw) {
  final text = raw?.trim();
  if (text == null || text.isEmpty) {
    return null;
  }
  final stripped = text
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'</p>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
  return stripped.isEmpty ? null : stripped;
}

/// 详情头部的画质/声道/字幕标签：4K、HDR/杜比视界、5.1/7.1、全景声、字幕。
/// 三端头部共用，只描述当前片源，不代表最终输出。
List<String> mediaTechBadges(ItemMediaSource? source) {
  if (source == null) return const [];
  final video = source.streams.where((s) => s.isVideo).firstOrNull;
  final audios = source.streams.where((s) => s.isAudio).toList();
  final audio =
      audios.where((s) => s.isDefault == true).firstOrNull ??
      audios.firstOrNull;
  final badges = <String>[];
  final height = video?.height ?? source.height;
  if (height != null && height > 0) {
    badges.add(
      height >= 2000
          ? '4K'
          : height >= 1000
          ? '1080P'
          : height >= 700
          ? '720P'
          : 'SD',
    );
  }
  final rangeType = (video?.videoRangeType ?? '').toUpperCase();
  final range = (video?.videoRange ?? '').toUpperCase();
  if (rangeType.contains('DOVI') || rangeType.contains('DOLBY')) {
    badges.add('DOLBY VISION');
  } else if (rangeType.contains('HDR10+') || rangeType.contains('HDR10PLUS')) {
    badges.add('HDR10+');
  } else if (range == 'HDR' ||
      rangeType.contains('HDR') ||
      rangeType == 'HLG') {
    badges.add(rangeType == 'HLG' ? 'HLG' : 'HDR');
  }
  final audioText = [
    audio?.profile,
    audio?.label,
    audio?.codec,
  ].whereType<String>().join(' ').toUpperCase();
  if (audioText.contains('ATMOS')) {
    badges.add('ATMOS');
  }
  final channels = audio?.channels;
  if (channels != null && channels >= 6) {
    badges.add(channels >= 8 ? '7.1' : '5.1');
  }
  if (source.streams.any((s) => s.isSubtitle)) {
    badges.add('CC');
  }
  return badges;
}
