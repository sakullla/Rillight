import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/player/playback_models.dart';
import 'package:rillight/player/playback_resolver.dart';

void main() {
  const base = 'http://emby.test:8096';
  const token = 'token-1';

  test('media URL resolution preserves the signed query bytes', () {
    const query = 'path=a%20b&part=one&flag&part=two&signature=x%2By%3D';
    for (final address in [
      '/video.mp4?$query',
      '$base/video.mp4?$query',
      'https://cdn.test/video.mp4?$query',
    ]) {
      final uri = embyResourceUri(Uri.parse(base), address, token);
      expect(
        uri.query,
        uri.host == 'cdn.test' ? query : '$query&api_key=$token',
      );
    }
    final foreign = embyResourceUri(
      Uri.parse(base),
      'https://cdn.test/video.mp4?api_key=$token&$query',
      token,
    );
    expect(foreign.query, query);
  });

  test('server media URLs use the API prefix for root and mounted servers', () {
    for (final basePath in ['', '/emby', '/gateway', '/gateway/emby']) {
      final mount = basePath.startsWith('/gateway') ? '/gateway' : '';
      for (final resource in [
        '/videos/movie/original.mp4',
        '/emby/videos/movie/original.mp4',
        '$mount/emby/videos/movie/original.mp4',
      ]) {
        final uri = embyResourceUri(
          Uri.parse('$base$basePath'),
          '$resource?MediaSourceId=source&PlaySessionId=play',
          token,
        );
        expect(uri.path, '$mount/emby/videos/movie/original.mp4');
        expect(uri.queryParameters, {
          'MediaSourceId': 'source',
          'PlaySessionId': 'play',
          'api_key': token,
        });
      }
    }
  });

  test('absolute media and CDN URLs keep their server-selected paths', () {
    for (final url in [
      '$base/custom/stream.mp4?signature=signed',
      'https://cdn.example.com/custom/stream.mp4?signature=signed',
      '//cdn.example.com/custom/stream.mp4?signature=signed',
    ]) {
      final uri = embyResourceUri(Uri.parse(base), url, token);
      expect(uri.path, '/custom/stream.mp4');
      expect(uri.queryParameters['signature'], 'signed');
      expect(
        uri.queryParameters['api_key'],
        uri.host == 'emby.test' ? token : isNull,
      );
    }
  });

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

  test('original Dolby audio is not replaced by an AAC transcode', () {
    for (final codec in ['ac3', 'eac3', 'truehd', 'true-hd', 'atmos', 'ec-3']) {
      final resolved = resolvePlayback(
        info: PlaybackInfo.fromJson({
          'PlaySessionId': 'dolby-$codec',
          'MediaSources': [
            {
              'Id': 'src-dolby',
              'SupportsDirectPlay': false,
              'SupportsDirectStream': false,
              'SupportsTranscoding': true,
              'TranscodingUrl': '/videos/movie/master.m3u8',
              'MediaStreams': [
                {'Index': 0, 'Type': 'Video', 'Codec': 'hevc'},
                {'Index': 1, 'Type': 'Audio', 'Codec': codec},
              ],
            },
          ],
        }),
        baseUrl: Uri.parse(base),
        accessToken: token,
        itemId: 'movie',
      );
      expect(resolved, isNull, reason: codec);
    }
    final aac = resolvePlayback(
      info: PlaybackInfo.fromJson({
        'PlaySessionId': 'aac-transcode',
        'MediaSources': [
          {
            'Id': 'src-aac',
            'SupportsDirectPlay': false,
            'SupportsDirectStream': false,
            'SupportsTranscoding': true,
            'TranscodingUrl': '/videos/movie/master.m3u8',
            'MediaStreams': [
              {'Index': 1, 'Type': 'Audio', 'Codec': 'aac'},
            ],
          },
        ],
      }),
      baseUrl: Uri.parse(base),
      accessToken: token,
      itemId: 'movie',
    );
    expect(aac, isNotNull);
    expect(aac!.playMethod, PlayMethod.transcode);
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
    expect(resolved.streamUrl.path, '/emby/Videos/movie-2/stream.mp4');
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

  test('stream headers retain UA for every origin and scope credentials', () {
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
    // strm 等远端直连地址保留 UA，不带令牌头。
    expect(
      playbackStreamHeaders(
        streamUrl: Uri.parse('https://cdn.example.com/episode-01.mkv'),
        baseUrl: Uri.parse(base),
        sessionHeaders: sessionHeaders,
      ),
      {'User-Agent': 'test-agent'},
    );
    // 同主机但协议或端口不同时仍保留 UA。
    expect(
      playbackStreamHeaders(
        streamUrl: Uri.parse('https://emby.test:8096/Videos/movie/stream.mkv'),
        baseUrl: Uri.parse(base),
        sessionHeaders: sessionHeaders,
      ),
      {'User-Agent': 'test-agent'},
    );
    expect(
      playbackStreamHeaders(
        streamUrl: Uri.parse('http://emby.test/Videos/movie/stream.mkv'),
        baseUrl: Uri.parse(base),
        sessionHeaders: sessionHeaders,
      ),
      {'User-Agent': 'test-agent'},
    );
  });

  test('embyResourceUri scopes api_key to the base origin', () {
    final baseUri = Uri.parse(base);
    // 同源相对地址照常附加 api_key。
    final sameOrigin = embyResourceUri(
      baseUri,
      '/Videos/movie/stream.mkv?static=true',
      token,
    );
    expect(sameOrigin.origin, baseUri.origin);
    expect(sameOrigin.queryParameters['api_key'], token);
    // 同源绝对地址保留既有 api_key,不重复附加。
    final sameOriginAbsolute = embyResourceUri(
      baseUri,
      '$base/videos/movie/master.m3u8?MediaSourceId=src-1&api_key=$token',
      token,
    );
    expect(sameOriginAbsolute.queryParameters['api_key'], token);
    expect(sameOriginAbsolute.queryParameters['MediaSourceId'], 'src-1');
    // 跨域绝对地址:查询里等于令牌的 api_key 被剥掉,其余参数保留。
    final crossOrigin = embyResourceUri(
      baseUri,
      'https://cdn.example.com/video/master.m3u8?api_key=$token&MediaSourceId=src-1',
      token,
    );
    expect(crossOrigin.origin, isNot(baseUri.origin));
    expect(crossOrigin.queryParameters.containsKey('api_key'), isFalse);
    expect(crossOrigin.queryParameters['MediaSourceId'], 'src-1');
    // 跨域地址上与令牌无关的签名参数原样保留。
    final foreignSigned = embyResourceUri(
      baseUri,
      'https://cdn.example.com/video/master.m3u8?api_key=cdn-signature&x=1',
      token,
    );
    expect(foreignSigned.queryParameters['api_key'], 'cdn-signature');
    // 仅协议或端口不同的同源主机仍视为跨域,不附带令牌。
    final otherScheme = embyResourceUri(
      baseUri,
      'https://emby.test:8096/videos/movie/master.m3u8?api_key=$token',
      token,
    );
    expect(otherScheme.queryParameters.containsKey('api_key'), isFalse);
  });

  test(
    'transcoding URL on a foreign host drops the token while same origin keeps it',
    () {
      final foreign = resolvePlayback(
        info: PlaybackInfo.fromJson({
          'PlaySessionId': 'play-foreign',
          'MediaSources': [
            {
              'Id': 'src-foreign',
              'Container': 'ts',
              'SupportsDirectPlay': false,
              'SupportsDirectStream': false,
              'SupportsTranscoding': true,
              'TranscodingUrl':
                  'https://transcode.example.com/videos/movie/master.m3u8?MediaSourceId=src-foreign&api_key=$token',
            },
          ],
        }),
        baseUrl: Uri.parse(base),
        accessToken: token,
        itemId: 'movie',
      );
      expect(foreign, isNotNull);
      expect(foreign!.isTranscode, isTrue);
      expect(foreign.streamUrl.origin, 'https://transcode.example.com');
      expect(foreign.streamUrl.queryParameters.containsKey('api_key'), isFalse);
      expect(foreign.streamUrl.queryParameters['MediaSourceId'], 'src-foreign');
      final own = resolvePlayback(
        info: PlaybackInfo.fromJson({
          'PlaySessionId': 'play-own',
          'MediaSources': [
            {
              'Id': 'src-own',
              'Container': 'ts',
              'SupportsDirectPlay': false,
              'SupportsDirectStream': false,
              'SupportsTranscoding': true,
              'TranscodingUrl':
                  '/videos/movie/master.m3u8?MediaSourceId=src-own',
            },
          ],
        }),
        baseUrl: Uri.parse(base),
        accessToken: token,
        itemId: 'movie',
      );
      expect(own, isNotNull);
      expect(own!.streamUrl.origin, Uri.parse(base).origin);
      expect(own.streamUrl.queryParameters['api_key'], token);
    },
  );

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
    expect(resolved!.streamUrl.path, '/emby/Videos/episode-strm2/stream.mkv');
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

  // R8:同域直播(IsInfiniteStream)与普通节目共用现有选择规则,
  // 选中后地址必须留在同域并携带令牌,手机/桌面/TV 起播行为一致。
  test('same-origin live stream follows the existing selection rules', () {
    final baseUri = Uri.parse(base);
    // 直播可直连:DirectStreamUrl 拼上 baseUrl,api_key 保留。
    final directLive = resolvePlayback(
      info: PlaybackInfo.fromJson({
        'PlaySessionId': 'play-live-direct',
        'MediaSources': [
          {
            'Id': 'src-live-1',
            'Container': 'ts',
            'IsInfiniteStream': true,
            'SupportsDirectPlay': true,
            'SupportsDirectStream': true,
            'DirectStreamUrl':
                '/LiveStreams/channel.ts?MediaSourceId=src-live-1',
          },
        ],
      }),
      baseUrl: baseUri,
      accessToken: token,
      itemId: 'channel-1',
    );
    expect(directLive, isNotNull);
    expect(directLive!.playMethod, PlayMethod.directStream);
    expect(directLive.isTranscode, isFalse);
    expect(directLive.mediaSource.isInfiniteStream, isTrue);
    expect(directLive.streamUrl.origin, baseUri.origin);
    expect(directLive.streamUrl.queryParameters['api_key'], token);
    expect(directLive.streamUrl.queryParameters['MediaSourceId'], 'src-live-1');
    // 直播不可直连但有转码地址:按现有规则选转码,同域令牌保留。
    final transcodedLive = resolvePlayback(
      info: PlaybackInfo.fromJson({
        'PlaySessionId': 'play-live-transcode',
        'MediaSources': [
          {
            'Id': 'src-live-2',
            'Container': 'ts',
            'IsInfiniteStream': true,
            'SupportsDirectPlay': false,
            'SupportsDirectStream': false,
            'SupportsTranscoding': true,
            'TranscodingUrl':
                '/videos/channel-2/master.m3u8?MediaSourceId=src-live-2',
          },
        ],
      }),
      baseUrl: baseUri,
      accessToken: token,
      itemId: 'channel-2',
    );
    expect(transcodedLive, isNotNull);
    expect(transcodedLive!.isTranscode, isTrue);
    expect(transcodedLive.mediaSource.isInfiniteStream, isTrue);
    expect(transcodedLive.streamUrl.origin, baseUri.origin);
    expect(transcodedLive.streamUrl.queryParameters['api_key'], token);
    // 起播请求头照常:同域携带全部会话头(含令牌与 UA)。
    expect(
      playbackStreamHeaders(
        streamUrl: transcodedLive.streamUrl,
        baseUrl: baseUri,
        sessionHeaders: const {
          'X-Emby-Token': token,
          'User-Agent': 'rillight-test-ua',
        },
      ),
      const {'X-Emby-Token': token, 'User-Agent': 'rillight-test-ua'},
    );
  });
}
