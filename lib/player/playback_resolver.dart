import 'package:rillight/emby/emby_url.dart';
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

ResolvedPlayback? resolvePlayback({
  required PlaybackInfo info,
  required Uri baseUrl,
  required String accessToken,
  required String itemId,
}) {
  final source = info.primarySource;
  if (source == null || source.id.isEmpty) {
    return null;
  }

  final canDirect = source.supportsDirectPlay || source.supportsDirectStream;
  if (canDirect) {
    final path =
        (source.directStreamUrl != null && source.directStreamUrl!.isNotEmpty)
        ? source.directStreamUrl!
        : _staticStreamPath(itemId, source, info.playSessionId);
    final method = source.supportsDirectStream || !source.supportsDirectPlay
        ? PlayMethod.directStream
        : PlayMethod.directPlay;
    return ResolvedPlayback(
      playMethod: method,
      streamUrl: embyResourceUri(baseUrl, path, accessToken),
      playSessionId: info.playSessionId,
      mediaSource: source,
      itemId: itemId,
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
  if (!params.containsKey('api_key') && !params.containsKey('ApiKey')) {
    params['api_key'] = accessToken;
  }
  return resolved.replace(queryParameters: params);
}
