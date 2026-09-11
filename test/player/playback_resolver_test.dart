import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/player/playback_models.dart';
import 'package:rillight/player/playback_resolver.dart';

void main() {
  const base = 'http://emby.test:8096';
  const token = 'token-1';

  test('prefers Direct Stream over transcode when the server allows it', () {
    final resolved = resolvePlayback(
      info: PlaybackInfo.fromJson({
        'PlaySessionId': 'play-1',
        'MediaSources': [
          {
            'Id': 'src-1',
            'Container': 'mkv',
            'SupportsDirectPlay': true,
            'SupportsDirectStream': true,
            'SupportsTranscoding': true,
            'DirectStreamUrl':
                '/Videos/movie/stream.mkv?static=true&MediaSourceId=src-1',
            'TranscodingUrl': '/videos/movie/master.m3u8',
          },
        ],
      }),
      baseUrl: Uri.parse(base),
      accessToken: token,
      itemId: 'movie',
    );
    expect(resolved, isNotNull);
    expect(resolved!.playMethod, PlayMethod.directStream);
    expect(resolved.streamUrl.queryParameters['static'], 'true');
    expect(resolved.streamUrl.queryParameters['api_key'], token);
    expect(resolved.streamUrl.path, contains('/Videos/movie/stream.mkv'));
  });

  test('uses transcoding URL when direct is not supported', () {
    final resolved = resolvePlayback(
      info: PlaybackInfo.fromJson({
        'PlaySessionId': 'play-2',
        'MediaSources': [
          {
            'Id': 'src-2',
            'Container': 'ts',
            'SupportsDirectPlay': false,
            'SupportsDirectStream': false,
            'SupportsTranscoding': true,
            'TranscodingUrl': '/videos/movie/master.m3u8?MediaSourceId=src-2',
          },
        ],
      }),
      baseUrl: Uri.parse(base),
      accessToken: token,
      itemId: 'movie',
    );
    expect(resolved!.playMethod, PlayMethod.transcode);
    expect(resolved.streamUrl.path, contains('master.m3u8'));
    expect(resolved.streamUrl.queryParameters['api_key'], token);
  });

  test('builds static stream URL when DirectStreamUrl is omitted', () {
    final resolved = resolvePlayback(
      info: PlaybackInfo.fromJson({
        'PlaySessionId': 'play-3',
        'MediaSources': [
          {
            'Id': 'src-3',
            'Container': 'mp4',
            'SupportsDirectPlay': false,
            'SupportsDirectStream': true,
          },
        ],
      }),
      baseUrl: Uri.parse(base),
      accessToken: token,
      itemId: 'movie-2',
    );
    expect(resolved!.playMethod, PlayMethod.directStream);
    expect(resolved.streamUrl.path, '/Videos/movie-2/stream.mp4');
    expect(resolved.streamUrl.queryParameters['static'], 'true');
  });

  test('returns null when there is no media source', () {
    expect(
      resolvePlayback(
        info: const PlaybackInfo(playSessionId: 'x', mediaSources: []),
        baseUrl: Uri.parse(base),
        accessToken: token,
        itemId: 'missing',
      ),
      isNull,
    );
  });

  test('classifies SRT as text and PGS as bitmap', () {
    const srt = MediaStreamInfo(
      index: 2,
      type: 'Subtitle',
      codec: 'subrip',
      isTextSubtitleStream: true,
    );
    const pgs = MediaStreamInfo(
      index: 3,
      type: 'Subtitle',
      codec: 'pgssub',
      isTextSubtitleStream: false,
    );
    expect(srt.isTextSubtitle, isTrue);
    expect(pgs.isBitmapSubtitle, isTrue);
  });
}
