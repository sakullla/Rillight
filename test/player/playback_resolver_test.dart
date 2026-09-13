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

  test('selects the requested media source when switching', () {
    final info = PlaybackInfo.fromJson({
      'PlaySessionId': 'play-multi',
      'MediaSources': [
        {
          'Id': 'src-1080',
          'Name': '1080p 版本',
          'Container': 'mkv',
          'SupportsDirectPlay': true,
          'SupportsDirectStream': true,
          'DirectStreamUrl':
              '/Videos/movie/stream.mkv?static=true&MediaSourceId=src-1080',
        },
        {
          'Id': 'src-4k',
          'Name': '4K 版本',
          'Container': 'mkv',
          'SupportsDirectPlay': true,
          'SupportsDirectStream': true,
          'DirectStreamUrl':
              '/Videos/movie/stream.mkv?static=true&MediaSourceId=src-4k',
        },
      ],
    });
    final resolved = resolvePlayback(
      info: info,
      baseUrl: Uri.parse(base),
      accessToken: token,
      itemId: 'movie',
      mediaSourceId: 'src-4k',
    );
    expect(resolved, isNotNull);
    expect(resolved!.mediaSource.id, 'src-4k');
    expect(resolved.mediaSource.label, '4K 版本');
    expect(resolved.streamUrl.queryParameters['MediaSourceId'], 'src-4k');
    // 缺省仍取第一个源。
    final fallback = resolvePlayback(
      info: info,
      baseUrl: Uri.parse(base),
      accessToken: token,
      itemId: 'movie',
    );
    expect(fallback!.mediaSource.id, 'src-1080');
    // 未知 id 回退第一个源。
    final unknown = resolvePlayback(
      info: info,
      baseUrl: Uri.parse(base),
      accessToken: token,
      itemId: 'movie',
      mediaSourceId: 'src-missing',
    );
    expect(unknown!.mediaSource.id, 'src-1080');
  });

  test('PlaybackInfo looks up sources by id', () {
    final info = PlaybackInfo.fromJson({
      'PlaySessionId': 'play-multi',
      'MediaSources': [
        {'Id': 'src-a'},
        {'Id': 'src-b'},
      ],
    });
    expect(info.sourceById('src-b')?.id, 'src-b');
    expect(info.sourceById('src-missing'), isNull);
  });

  test('strm remote path direct plays the original URL without token', () {
    final resolved = resolvePlayback(
      info: PlaybackInfo.fromJson({
        'PlaySessionId': 'play-strm',
        'MediaSources': [
          {
            'Id': 'src-strm',
            'Protocol': 'Http',
            'Path': 'https://cdn.example.com/episode-01.mkv',
            'Container': 'mkv',
            'SupportsDirectPlay': true,
            'SupportsDirectStream': true,
          },
        ],
      }),
      baseUrl: Uri.parse(base),
      accessToken: token,
      itemId: 'episode-strm',
    );
    expect(resolved, isNotNull);
    expect(resolved!.isTranscode, isFalse);
    expect(
      resolved.streamUrl.toString(),
      'https://cdn.example.com/episode-01.mkv',
    );
    expect(resolved.streamUrl.queryParameters.containsKey('api_key'), isFalse);
  });

  test('strm source without remote path falls back to the static stream', () {
    final resolved = resolvePlayback(
      info: PlaybackInfo.fromJson({
        'PlaySessionId': 'play-strm2',
        'MediaSources': [
          {
            'Id': 'src-strm2',
            'Protocol': 'File',
            'Path': '/media/movies/file.mkv',
            'Container': 'mkv',
            'SupportsDirectPlay': false,
            'SupportsDirectStream': true,
          },
        ],
      }),
      baseUrl: Uri.parse(base),
      accessToken: token,
      itemId: 'episode-strm2',
    );
    expect(resolved, isNotNull);
    expect(resolved!.streamUrl.path, '/Videos/episode-strm2/stream.mkv');
    expect(resolved.streamUrl.queryParameters['api_key'], token);
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
