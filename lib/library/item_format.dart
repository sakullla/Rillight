import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/emby/emby_models.dart';

String itemTitle(EmbyItem item) {
  final year = item.productionYear;
  if (year != null && year > 0) {
    return '${item.name} ($year)';
  }
  return item.name;
}

String? runtimeLabel(AppLocalizations l10n, EmbyItem item) {
  final ticks = item.runTimeTicks;
  if (ticks == null || ticks <= 0) {
    return null;
  }
  final minutes = (ticks / 10000000 / 60).round();
  if (minutes < 60) {
    return l10n.runtimeMinutes(minutes);
  }
  return l10n.runtimeHoursMinutes(minutes ~/ 60, minutes % 60);
}

String chapterClock(int startPositionTicks) {
  final seconds = startPositionTicks <= 0 ? 0 : startPositionTicks ~/ 10000000;
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

String? seasonEpisodeCode(EmbyItem item) {
  final season = item.parentIndexNumber;
  final episode = item.indexNumber;
  if (season == null || episode == null) {
    return null;
  }
  return 'S${season}E$episode';
}

String episodeLabel(EmbyItem item) {
  final code = seasonEpisodeCode(item);
  if (code == null) {
    return item.name;
  }
  final name = item.name.trim();
  return name.isEmpty ? code : '$code $name';
}

/// 继续观看副标题:有正常集名时为 S1E2 · 集名。
/// 集名经常是发行文件名(分辨率、音轨、来源),那种只保留季集编号。
String continueWatchingSubtitle(EmbyItem item) {
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
