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
  });

  final PlayMethod playMethod;
  final Uri streamUrl;
  final String playSessionId;
  final PlaybackMediaSource mediaSource;
  final String itemId;

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

/// 解析起播流:直连优先(服务端 DirectStreamUrl,否则 strm 远端 Path,
/// 否则静态流地址),不可直连且有 TranscodingUrl 时转码。
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
  if (canDirect && !forceTranscode) {
    final directStreamUrl = source.directStreamUrl;
    if (directStreamUrl != null && directStreamUrl.isNotEmpty) {
      return _direct(
        source,
        info.playSessionId,
        itemId,
        embyResourceUri(baseUrl, directStreamUrl, accessToken),
      );
    }
    if (source.isRemoteHttpPath) {
      // strm 等场景:服务端已把条目解析为远端地址,直连打开原始 URL,
      // 不附带 api_key(避免向第三方地址泄漏令牌)。
      return _direct(
        source,
        info.playSessionId,
        itemId,
        Uri.parse(source.path!),
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
  Uri streamUrl,
) {
  final method = source.supportsDirectStream || !source.supportsDirectPlay
      ? PlayMethod.directStream
      : PlayMethod.directPlay;
  return ResolvedPlayback(
    playMethod: method,
    streamUrl: streamUrl,
    playSessionId: playSessionId,
    mediaSource: source,
    itemId: itemId,
  );
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
  } else {
    resolved = joinEmbyPath(
      baseUrl,
      parsed.path,
    ).replace(queryParameters: parsed.queryParameters);
  }
  final params = Map<String, String>.from(resolved.queryParameters);
  if (resolved.origin != baseUrl.origin) {
    params.removeWhere((key, value) => value == accessToken);
    return resolved.replace(queryParameters: params);
  }
  if (!params.containsKey('api_key') && !params.containsKey('ApiKey')) {
    params['api_key'] = accessToken;
  }
  return resolved.replace(queryParameters: params);
}

/// 播放流请求头:仅当流地址与 Emby 服务器同源(协议/主机/端口一致)时
/// 附加会话头(X-Emby-Token/Authorization 等);strm 等远端直连地址
/// 返回空 headers,避免服务器访问令牌被送达第三方主机。
Map<String, String> playbackStreamHeaders({
  required Uri streamUrl,
  required Uri baseUrl,
  required Map<String, String> sessionHeaders,
}) {
  final sameOrigin =
      streamUrl.scheme == baseUrl.scheme &&
      streamUrl.host == baseUrl.host &&
      streamUrl.port == baseUrl.port;
  return sameOrigin ? sessionHeaders : const {};
}

/// 跨集对齐音轨/字幕:语言+标题优先,序号只作兜底(每集 Index 常变)。
int? matchPreferredStreamIndex({
  required List<MediaStreamInfo> streams,
  int? preferredIndex,
  String? language,
  String? title,
}) {
  if (streams.isEmpty) {
    return null;
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
