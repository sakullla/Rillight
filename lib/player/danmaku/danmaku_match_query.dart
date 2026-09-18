/// 为 dandanplay 兼容 `/api/v2/match` 组装 fileName。
///
/// 有真实媒体文件名时原样使用(含 SxxExx、分辨率、WEB-DL 等);
/// 否则用剧名 + SxxExx,必要时附上分辨率,便于只靠文件名匹配的兼容源。
String danmakuMatchFileName({
  String? pathBaseName,
  String? seriesTitle,
  String? title,
  int? seasonIndex,
  int? episodeIndex,
  int? height,
}) {
  final fromPath = pathBaseName?.trim() ?? '';
  if (_looksLikeReleaseName(fromPath)) {
    return fromPath;
  }
  final show = (seriesTitle ?? '').trim();
  if (show.isNotEmpty && episodeIndex != null && episodeIndex > 0) {
    final season = seasonIndex != null && seasonIndex > 0 ? seasonIndex : 1;
    final tag =
        'S${season.toString().padLeft(2, '0')}E${episodeIndex.toString().padLeft(2, '0')}';
    final quality = _qualityTag(height);
    if (quality == null) {
      return '$show $tag';
    }
    return '$show.$tag.$quality';
  }
  final fallback = (title ?? '').trim();
  if (fallback.isNotEmpty) {
    final quality = _qualityTag(height);
    return quality == null ? fallback : '$fallback.$quality';
  }
  return fromPath;
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
