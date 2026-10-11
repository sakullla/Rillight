import 'package:rillight/emby/emby_url.dart';
import 'package:rillight/emby/media_source_format.dart';
import 'package:rillight/player/playback_models.dart';

class ResolvedPlayback {
  const ResolvedPlayback({
    required this.playMethod,
    required this.streamUrl,
    required this.playSessionId,
    required this.mediaSource,
    required this.itemId,
    this.requiresStrmExpansion = false,
  });

  final PlayMethod playMethod;
  final Uri streamUrl;
  final String playSessionId;
  final PlaybackMediaSource mediaSource;
  final String itemId;

  /// [streamUrl] is the strm pointer, not a media file. The caller reads it
  /// and opens the first http(s) target inside.
  final bool requiresStrmExpansion;

  bool get isTranscode => playMethod == PlayMethod.transcode;
}

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

/// 解析起播流。
///
/// 远端媒体地址(含 strm 已解析出的 http(s) 路径)优先于
/// DirectStreamUrl:后者对 strm 经常是 `stream.strm` 文本。容器或路径仍是
/// strm、且没有可直接打开的媒体地址时,返回指针并标记
/// [ResolvedPlayback.requiresStrmExpansion],由调用方读取正文里的第一行
/// http(s)。其余直连仍用 DirectStreamUrl,否则静态流;不可直连且有
/// TranscodingUrl 时转码。
///
/// [mediaSourceId] 指定选择的媒体源(播放中换源);缺省取第一个。
ResolvedPlayback? resolvePlayback({
  required PlaybackInfo info,
  required Uri baseUrl,
  required String accessToken,
  required String itemId,
  String? mediaSourceId,
  bool forceTranscode = false,
}) {
  PlaybackMediaSource? source = info.primarySource;
  if (mediaSourceId != null && mediaSourceId.isNotEmpty) {
    final requested = info.sourceById(mediaSourceId);
    if (requested != null) {
      source = requested;
    }
  }
  if (source == null || source.id.isEmpty) {
    return null;
  }

  final canDirect = source.supportsDirectPlay || source.supportsDirectStream;
  if (!forceTranscode) {
    final remoteMedia = _remoteMediaUrl(source);
    // The owned core can open the URL inside a strm even when the device
    // profile has no strm container and the server therefore clears
    // SupportsDirectPlay.
    if (remoteMedia != null &&
        (source.supportsDirectPlay || _isStrmSource(source))) {
      return _direct(
        source,
        info.playSessionId,
        itemId,
        Uri.parse(remoteMedia),
      );
    }
  }
  if (canDirect && !forceTranscode) {
    final directStreamUrl = source.directStreamUrl?.trim();
    if (directStreamUrl != null &&
        directStreamUrl.isNotEmpty &&
        !_isStrmResource(directStreamUrl)) {
      return _direct(
        source,
        info.playSessionId,
        itemId,
        embyResourceUri(baseUrl, directStreamUrl, accessToken),
      );
    }
    if (source.isRemoteHttpPath && !_isStrmResource(source.path)) {
      // strm 等场景:服务端已把条目解析为远端地址,直连打开原始 URL,
      // 不附带 api_key(避免向第三方地址泄漏令牌)。
      return _direct(
        source,
        info.playSessionId,
        itemId,
        Uri.parse(source.path!.trim()),
      );
    }
    if (_isStrmSource(source)) {
      return _direct(
        source,
        info.playSessionId,
        itemId,
        _strmPointerUri(
          source,
          baseUrl,
          accessToken,
          itemId,
          info.playSessionId,
        ),
        expandStrm: true,
      );
    }
    return _direct(
      source,
      info.playSessionId,
      itemId,
      embyResourceUri(
        baseUrl,
        _staticStreamPath(itemId, source, info.playSessionId),
        accessToken,
      ),
    );
  }

  final transcoding = source.transcodingUrl;
  if (transcoding != null && transcoding.isNotEmpty) {
    // AC-3, E-AC-3 and TrueHD must stay on the original track. An AAC
    // transcode of that source is not a successful Dolby playback.
    if (source.audioStreams.any(
      (stream) => isOriginalDolbyAudioCodec(stream.codec),
    )) {
      return null;
    }
    return ResolvedPlayback(
      playMethod: PlayMethod.transcode,
      streamUrl: embyResourceUri(baseUrl, transcoding, accessToken),
      playSessionId: info.playSessionId,
      mediaSource: source,
      itemId: itemId,
    );
  }
  return null;
}

ResolvedPlayback _direct(
  PlaybackMediaSource source,
  String playSessionId,
  String itemId,
  Uri streamUrl, {
  bool expandStrm = false,
}) {
  final method = source.supportsDirectStream || !source.supportsDirectPlay
      ? PlayMethod.directStream
      : PlayMethod.directPlay;
  return ResolvedPlayback(
    playMethod: expandStrm ? PlayMethod.directPlay : method,
    streamUrl: streamUrl,
    playSessionId: playSessionId,
    mediaSource: source,
    itemId: itemId,
    requiresStrmExpansion: expandStrm,
  );
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

bool _isHttpUrl(String value) {
  final lower = value.trim().toLowerCase();
  return lower.startsWith('http://') || lower.startsWith('https://');
}

bool _isStrmResource(String? value) {
  final text = value?.trim();
  if (text == null || text.isEmpty) return false;
  final path = (Uri.tryParse(text)?.path ?? text).toLowerCase();
  return path.endsWith('.strm');
}

bool _isStrmSource(PlaybackMediaSource source) {
  return source.container?.trim().toLowerCase() == 'strm' ||
      _isStrmResource(source.path) ||
      _isStrmResource(source.directStreamUrl);
}

/// Remote URL that is the media itself. A `.strm` URL still has to be read.
String? _remoteMediaUrl(PlaybackMediaSource source) {
  final path = source.path?.trim();
  if (path == null || !_isHttpUrl(path) || _isStrmResource(path)) return null;
  return path;
}

Uri _strmPointerUri(
  PlaybackMediaSource source,
  Uri baseUrl,
  String accessToken,
  String itemId,
  String playSessionId,
) {
  final path = source.path?.trim();
  if (path != null && _isHttpUrl(path) && _isStrmResource(path)) {
    return Uri.parse(path);
  }
  final direct = source.directStreamUrl?.trim();
  if (direct != null && direct.isNotEmpty) {
    return embyResourceUri(baseUrl, direct, accessToken);
  }
  return embyResourceUri(
    baseUrl,
    '/Videos/$itemId/stream.strm?static=true'
    '&MediaSourceId=${source.id}&PlaySessionId=$playSessionId',
    accessToken,
  );
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

String _staticStreamPath(
  String itemId,
  PlaybackMediaSource source,
  String playSessionId,
) {
  final container = (source.container == null || source.container!.isEmpty)
      ? 'mkv'
      : source.container!;
  return '/Videos/$itemId/stream.$container?static=true'
      '&MediaSourceId=${source.id}&PlaySessionId=$playSessionId';
}

Uri embyResourceUri(Uri baseUrl, String pathOrUrl, String accessToken) {
  final parsed = Uri.parse(pathOrUrl);
  final Uri resolved;
  if (parsed.hasScheme) {
    resolved = parsed;
  } else if (parsed.hasAuthority) {
    resolved = baseUrl.resolveUri(parsed);
  } else {
    resolved = joinEmbyApiPath(
      baseUrl,
      parsed.path,
    ).replace(query: parsed.hasQuery ? parsed.query : null);
  }
  if (resolved.origin != baseUrl.origin) {
    return withoutEmbyTokenValues(resolved, {
      if (accessToken.isNotEmpty) accessToken,
    });
  }
  final params = resolved.queryParameters;
  if (!params.containsKey('api_key') && !params.containsKey('ApiKey')) {
    final query = resolved.query;
    return resolved.replace(
      query:
          '${query.isEmpty ? '' : '$query&'}api_key=${Uri.encodeQueryComponent(accessToken)}',
    );
  }
  return resolved;
}

/// 自定义 UA 对所有媒体地址生效；会话凭据只发往 Emby 同源地址。
Map<String, String> playbackStreamHeaders({
  required Uri streamUrl,
  required Uri baseUrl,
  required Map<String, String> sessionHeaders,
}) {
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
