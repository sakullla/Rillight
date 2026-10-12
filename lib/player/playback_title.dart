import 'package:rillight/library/item_format.dart';
import 'package:rillight/media_server/models.dart';

/// 播放器标题拆成两行:剧集时上方是剧名(小字),下方是「S1E2 · 集名」;
/// 电影只有一行片名。桌面、手机与 TV 控制层共用,避免一行长串被截断。
({String? eyebrow, String title}) playbackTitleParts(
  MediaItem? item, {
  required String fallback,
}) {
  if (item == null) return (eyebrow: null, title: fallback);
  final name = item.name.trim().isEmpty ? fallback : item.name.trim();
  if (!item.isEpisode) return (eyebrow: null, title: name);
  final series = item.seriesName?.trim();
  final code = seasonEpisodeCode(item);
  final title =
      code == null || name.toLowerCase().startsWith(code.toLowerCase())
      ? name
      : '$code · $name';
  return (
    eyebrow: series == null || series.isEmpty || series == name ? null : series,
    title: title,
  );
}
