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
