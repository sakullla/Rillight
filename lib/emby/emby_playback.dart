import 'package:rillight/media_server/server_address.dart';
import 'package:rillight/player/playback_resolver.dart';
import 'package:rillight/emby/emby_url.dart';
import 'package:rillight/media_server/playback.dart';

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
ResolvedPlayback? resolveEmbyPlayback({
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
      outputBitrate: source.transcodingOutputBitrate,
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
    outputBitrate: source.bitrate,
    streamUrl: streamUrl,
    playSessionId: playSessionId,
    mediaSource: source,
    itemId: itemId,
    requiresStrmExpansion: expandStrm,
  );
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
    return withoutCredentialValues(resolved, {
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
