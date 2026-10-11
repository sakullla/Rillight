import 'package:rillight/media_server/media_source_format.dart';
import 'package:rillight/media_server/playback.dart';
import 'package:rillight/media_server/resources.dart';

/// 从 PlaybackInfo 的多个媒体源里选出要播的那一个。
///
/// 先按 [requestedId] 精确匹配(当前条目换源/详情页手选)。下一集的源 id
/// 和整段文件名都会变,再按 [requestedName] 的发行组标签对齐;都对不上
/// 才回落第一个源。
String? preferredPlaybackSourceId({
  required List<PlaybackMediaSource> sources,
  String? requestedId,
  String? requestedName,
}) {
  if (sources.isEmpty) {
    return null;
  }
  if (requestedId != null && requestedId.isNotEmpty) {
    for (final source in sources) {
      if (source.id == requestedId) {
        return source.id;
      }
    }
  }
  final name = requestedName?.trim();
  if (name != null && name.isNotEmpty) {
    for (final source in sources) {
      if (source.label.trim().toLowerCase() == name.toLowerCase()) {
        return source.id;
      }
    }
    final matched = _matchSourceByFingerprint(sources, name);
    if (matched != null) {
      return matched;
    }
  }
  return sources.first.id;
}

String? _matchSourceByFingerprint(
  List<PlaybackMediaSource> sources,
  String requestedName,
) {
  final requested = mediaSourceMatchTokens(requestedName);
  final parsed = [
    for (final source in sources)
      (source, mediaSourceMatchTokens(source.name ?? source.label)),
  ];
  final common = _commonTokenSet([for (final entry in parsed) entry.$2.tokens]);
  var bestId = '';
  var bestScore = 0;
  for (final entry in parsed) {
    final score = _sourceFingerprintScore(
      requested: requested,
      candidate: entry.$2,
      common: common,
    );
    if (score > bestScore) {
      bestScore = score;
      bestId = entry.$1.id;
    }
  }
  if (bestScore <= 0 || bestId.isEmpty) {
    return null;
  }
  return bestId;
}

Set<String> _commonTokenSet(Iterable<List<String>> groups) {
  final iterator = groups.iterator;
  if (!iterator.moveNext()) {
    return const {};
  }
  final common = <String>{
    for (final token in iterator.current) token.toUpperCase(),
  };
  while (iterator.moveNext()) {
    common.retainAll({
      for (final token in iterator.current) token.toUpperCase(),
    });
    if (common.isEmpty) {
      break;
    }
  }
  return common;
}

int _sourceFingerprintScore({
  required MediaSourceMatchTokens requested,
  required MediaSourceMatchTokens candidate,
  required Set<String> common,
}) {
  Set<String> folded(Iterable<String> tokens) => {
    for (final token in tokens) token.toUpperCase(),
  };
  final requestedDistinct = folded(requested.tokens).difference(common);
  final candidateDistinct = folded(candidate.tokens).difference(common);
  if (requestedDistinct.isEmpty) {
    final requestedAll = folded(requested.tokens);
    final candidateAll = folded(candidate.tokens);
    if (requestedAll.isEmpty ||
        requestedAll.length != candidateAll.length ||
        !candidateAll.containsAll(requestedAll)) {
      return 0;
    }
    return 1;
  }
  final overlap = requestedDistinct.intersection(candidateDistinct);
  if (overlap.isEmpty) {
    return 0;
  }
  var score = overlap.length * 10;
  if (overlap.length == requestedDistinct.length) {
    score += 5;
  }
  if (candidateDistinct.difference(requestedDistinct).isEmpty) {
    score += 2;
  }
  return score;
}

/// Provider resource authorization takes precedence over the legacy session.
/// Custom UA is public; session credentials stay on their authorized origins.
Map<String, String> playbackStreamHeaders({
  required Uri streamUrl,
  required Uri baseUrl,
  required Map<String, String> sessionHeaders,
  ResourceAuthorization? authorization,
}) {
  if (authorization != null) return authorization.headersFor(streamUrl);
  final sameOrigin =
      streamUrl.scheme == baseUrl.scheme &&
      streamUrl.host == baseUrl.host &&
      streamUrl.port == baseUrl.port;
  return {
    for (final entry in sessionHeaders.entries)
      if (sameOrigin || entry.key.toLowerCase() == 'user-agent')
        entry.key: entry.value,
  };
}

/// 跨集对齐音轨/字幕:语言+标题优先,序号只作兜底(每集 Index 常变)。
int? matchPreferredStreamIndex({
  required List<MediaStreamInfo> streams,
  int? preferredIndex,
  bool exactIndex = false,
  String? language,
  String? title,
}) {
  if (streams.isEmpty) {
    return null;
  }
  // Only an identical source can treat a persisted index as authoritative.
  // Language/title alone cannot distinguish two tracks with identical labels.
  if (exactIndex && preferredIndex != null) {
    for (final stream in streams) {
      if (stream.index == preferredIndex) return stream.index;
    }
  }
  final lang = language?.trim() ?? '';
  final name = title?.trim() ?? '';
  if (lang.isNotEmpty && name.isNotEmpty) {
    for (final stream in streams) {
      if (_sameIgnoreCase(stream.language, language) &&
          _sameIgnoreCase(stream.displayTitle ?? stream.label, title)) {
        return stream.index;
      }
    }
  }
  if (lang.isNotEmpty) {
    for (final stream in streams) {
      if (_sameIgnoreCase(stream.language, language)) {
        return stream.index;
      }
    }
  }
  if (name.isNotEmpty) {
    for (final stream in streams) {
      if (_sameIgnoreCase(stream.displayTitle ?? stream.label, title)) {
        return stream.index;
      }
    }
  }
  if (preferredIndex != null) {
    for (final stream in streams) {
      if (stream.index == preferredIndex) {
        return stream.index;
      }
    }
  }
  return null;
}

/// 默认字幕:服务端默认轨(含位图),否则第一条文本轨,再否则第一条字幕。
int? fallbackSubtitleStreamIndex(PlaybackMediaSource source) {
  final index = source.defaultSubtitleStreamIndex;
  if (index != null) {
    final stream = source.streamByIndex(index);
    if (stream != null && stream.isSubtitle) {
      return index;
    }
  }
  for (final stream in source.subtitleStreams) {
    if (stream.isTextSubtitle) {
      return stream.index;
    }
  }
  return source.subtitleStreams.isEmpty
      ? null
      : source.subtitleStreams.first.index;
}

bool _sameIgnoreCase(String? left, String? right) {
  final a = left?.trim().toLowerCase() ?? '';
  final b = right?.trim().toLowerCase() ?? '';
  return a.isNotEmpty && a == b;
}

/// First playable http(s) target in a strm body. Blank lines and `#` comments,
/// including `#EXTM3U` / `#EXTINF`, are skipped.
Uri? parseStrmTarget(String text) {
  final body = text.length > 256 * 1024 ? text.substring(0, 256 * 1024) : text;
  for (final raw in body.split(RegExp(r'\r?\n'))) {
    var line = raw.trim();
    if (line.startsWith('\uFEFF')) {
      line = line.substring(1).trim();
    }
    if (line.isEmpty || line.startsWith('#')) continue;
    if ((line.startsWith('"') && line.endsWith('"') && line.length >= 2) ||
        (line.startsWith("'") && line.endsWith("'") && line.length >= 2)) {
      line = line.substring(1, line.length - 1).trim();
    }
    final lower = line.toLowerCase();
    if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
      continue;
    }
    return Uri.tryParse(line);
  }
  return null;
}

/// True for AC-3, E-AC-3, TrueHD and the short names servers use for them.
bool isOriginalDolbyAudioCodec(String? codec) {
  final value = codec?.trim().toLowerCase() ?? '';
  return value == 'ac3' ||
      value == 'ac-3' ||
      value == 'dd' ||
      value == 'eac3' ||
      value == 'ec-3' ||
      value == 'ec3' ||
      value == 'ddp' ||
      value == 'dd+' ||
      value == 'truehd' ||
      value == 'true-hd' ||
      value.contains('atmos');
}
