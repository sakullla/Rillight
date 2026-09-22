import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/player/playback_models.dart';
import 'package:rillight/player/playback_resolver.dart';

void main() {
  const base = 'http://emby.test:8096';
  const token = 'token-1';

  test(
    'explicit compatibility fallback cannot silently choose direct again',
    () {
      final info = PlaybackInfo.fromJson({
        'PlaySessionId': 'fallback',
        'MediaSources': [
          {
            'Id': 's',
            'SupportsDirectPlay': true,
            'TranscodingUrl': '/hls/master.m3u8',
          },
        ],
      });
      final result = resolvePlayback(
        info: info,
        baseUrl: Uri.parse(base),
        accessToken: token,
        itemId: 'movie',
        forceTranscode: true,
      );
      expect(result!.playMethod, PlayMethod.transcode);
      final unavailable = PlaybackInfo.fromJson({
        'MediaSources': [
          {'Id': 's', 'SupportsDirectPlay': true},
        ],
      });
      expect(
        resolvePlayback(
          info: unavailable,
          baseUrl: Uri.parse(base),
          accessToken: token,
          itemId: 'movie',
          forceTranscode: true,
        ),
        isNull,
      );
    },
  );

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

  test('preferredPlaybackSourceId matches id then name then first', () {
    const sources = [
      PlaybackMediaSource(id: 'e1-1080', name: '1080p'),
      PlaybackMediaSource(id: 'e1-4k', name: '4K 版本'),
    ];
    expect(
      preferredPlaybackSourceId(sources: sources, requestedId: 'e1-4k'),
      'e1-4k',
    );
    expect(
      preferredPlaybackSourceId(
        sources: sources,
        requestedId: 'stale-id',
        requestedName: '4K 版本',
      ),
      'e1-4k',
    );
    expect(preferredPlaybackSourceId(sources: sources), 'e1-1080');
  });

  test('preferredPlaybackSourceId aligns episodes by release group', () {
    const nextEpisode = [
      PlaybackMediaSource(
        id: 'e2-cr',
        name: 'Show.S01E02.CR.WEB-DL.1080p.H264.AAC-SonyHD',
      ),
      PlaybackMediaSource(
        id: 'e2-cp',
        name: 'Show.S01E02.CP+.WEB-DL.1080p.H264.AAC-SonyHD',
      ),
      PlaybackMediaSource(
        id: 'e2-line',
        name: 'Show.S01E02.LINETV.WEB-DL.1080p.H264.AAC-SonyHD',
      ),
      PlaybackMediaSource(
        id: 'e2-loli',
        name: '[LoliHouse] Show - 02 [WebRip 1080p HEVC AAC]',
      ),
      PlaybackMediaSource(
        id: 'e2-orion-ja',
        name: 'Show.S01E02.简日双语.1080p.H265.AAC-猎户发布组',
      ),
      PlaybackMediaSource(
        id: 'e2-orion',
        name: 'Show.S01E02.1080p.H265.AAC-猎户发布组',
      ),
    ];
    expect(
      preferredPlaybackSourceId(
        sources: nextEpisode,
        requestedId: 'e1-line-stale',
        requestedName: 'Show.S01E01.LINETV.WEB-DL.1080p.H264.AAC-SonyHD',
      ),
      'e2-line',
    );
    expect(
      preferredPlaybackSourceId(
        sources: nextEpisode,
        requestedName: 'LINETV · WEB-DL · SonyHD',
      ),
      'e2-line',
    );
    expect(
      preferredPlaybackSourceId(
        sources: nextEpisode,
        requestedName: '简日双语 · 猎户发布组',
      ),
      'e2-orion-ja',
    );
    expect(
      preferredPlaybackSourceId(sources: nextEpisode, requestedName: '猎户发布组'),
      'e2-orion',
    );
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

  test('stream headers attach the session only for same-origin URLs', () {
    const sessionHeaders = {
      'X-Emby-Token': 'token-1',
      'Authorization': 'MediaBrowser Token="token-1"',
      'User-Agent': 'test-agent',
    };
    // Emby 自有流(与 baseUrl 同源)仍携带会话头。
    expect(
      playbackStreamHeaders(
        streamUrl: Uri.parse('$base/Videos/movie/stream.mkv?api_key=$token'),
        baseUrl: Uri.parse(base),
        sessionHeaders: sessionHeaders,
      ),
      sessionHeaders,
    );
    // strm 等远端直连地址不带令牌头(空 headers)。
    expect(
      playbackStreamHeaders(
        streamUrl: Uri.parse('https://cdn.example.com/episode-01.mkv'),
        baseUrl: Uri.parse(base),
        sessionHeaders: sessionHeaders,
      ),
      isEmpty,
    );
    // 同主机但协议或端口不同也视为不同源,保守不附加。
    expect(
      playbackStreamHeaders(
        streamUrl: Uri.parse('https://emby.test:8096/Videos/movie/stream.mkv'),
        baseUrl: Uri.parse(base),
        sessionHeaders: sessionHeaders,
      ),
      isEmpty,
    );
    expect(
      playbackStreamHeaders(
        streamUrl: Uri.parse('http://emby.test/Videos/movie/stream.mkv'),
        baseUrl: Uri.parse(base),
        sessionHeaders: sessionHeaders,
      ),
      isEmpty,
    );
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

  test('matches subtitle by language when indexes differ', () {
    const streams = [
      MediaStreamInfo(
        index: 4,
        type: 'Subtitle',
        language: 'eng',
        displayTitle: 'English',
        isTextSubtitleStream: true,
      ),
      MediaStreamInfo(
        index: 5,
        type: 'Subtitle',
        language: 'chi',
        displayTitle: '中文',
        isTextSubtitleStream: true,
      ),
    ];
    expect(
      matchPreferredStreamIndex(
        streams: streams,
        preferredIndex: 2,
        language: 'chi',
        title: '中文',
      ),
      5,
    );
  });

  test('falls back to default then first text subtitle', () {
    final source = PlaybackMediaSource.fromJson({
      'Id': 'src',
      'DefaultSubtitleStreamIndex': 3,
      'MediaStreams': [
        {'Index': 0, 'Type': 'Video'},
        {
          'Index': 2,
          'Type': 'Subtitle',
          'Codec': 'ass',
          'IsTextSubtitleStream': true,
        },
        {
          'Index': 3,
          'Type': 'Subtitle',
          'Codec': 'pgssub',
          'IsTextSubtitleStream': false,
        },
      ],
    });
    expect(fallbackSubtitleStreamIndex(source), 3);
    expect(source.streamByIndex(2)!.isExternal, isFalse);
    expect(
      MediaStreamInfo.fromJson({
        'Index': 4,
        'Type': 'Subtitle',
        'IsExternal': true,
      }).isExternal,
      isTrue,
    );
    expect(
      fallbackSubtitleStreamIndex(
        PlaybackMediaSource.fromJson({
          'Id': 'src-2',
          'MediaStreams': [
            {
              'Index': 2,
              'Type': 'Subtitle',
              'Codec': 'ass',
              'IsTextSubtitleStream': true,
            },
          ],
        }),
      ),
      2,
    );
  });
}
