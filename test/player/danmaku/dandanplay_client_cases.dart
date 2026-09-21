import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/player/danmaku/dandanplay_client.dart';
import 'package:rillight/player/danmaku/dandanplay_models.dart';

/// 脚本化 Dio 适配器:记录请求并按 handler 返回结果,不真实拨号。
class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(this._handler);

  final FutureOr<Object?> Function(RequestOptions options) _handler;
  final List<RequestOptions> requests = <RequestOptions>[];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final pending = Future<Object?>(() async => _handler(options));
    final Object? result;
    if (cancelFuture == null) {
      result = await pending;
    } else {
      result = await Future.any<Object?>([
        pending,
        cancelFuture.then<Object?>((_) {
          throw DioException(
            requestOptions: options,
            type: DioExceptionType.cancel,
          );
        }),
      ]);
    }
    if (result is ResponseBody) {
      return result;
    }
    if (result is Map) {
      return _json(result);
    }
    if (result is String) {
      return ResponseBody.fromBytes(
        utf8.encode(result),
        200,
        headers: _textHeaders,
      );
    }
    throw StateError('unexpected fake result: $result');
  }

  static ResponseBody _json(Map<Object?, Object?> body) {
    return ResponseBody.fromBytes(
      utf8.encode(jsonEncode(body)),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  static final Map<String, List<String>> _textHeaders = {
    Headers.contentTypeHeader: ['text/plain'],
  };
}

DandanplayClient clientFor(
  FutureOr<Object?> Function(RequestOptions options) handler, {
  int isolateParseThreshold = kDanmakuIsolateParseThreshold,
}) {
  final dio = Dio();
  dio.httpClientAdapter = _ScriptedAdapter(handler);
  return DandanplayClient(
    dio: dio,
    isolateParseThreshold: isolateParseThreshold,
  );
}

const _officialCommentBody = {
  'count': 3,
  'comments': [
    {'cid': 2, 'p': '61.2,1,16711680,0,25,0,7b7b7b,0', 'm': 'scroll'},
    {'cid': 1, 'p': '12.5,4,16777215,0,25,0,ffffff,0', 'm': 'bottom'},
    {'cid': 3, 'p': '5.0,5,65280,0,25,0,ffffff,0', 'm': 'top'},
    {'cid': 4, 'p': 'broken', 'm': 'skipped'},
    {'cid': 5, 'p': '1,1,2,0,25,0,fff,0', 'm': ''},
    'not-a-map',
  ],
};

TypeMatcher<DanmakuResponseFormatException> _formatFailure(
  DanmakuApiFailureKind kind,
) => isA<DanmakuResponseFormatException>().having((e) => e.kind, 'kind', kind);

void main() {
  test('match posts fileName/hash/duration to /api/v2/match', () async {
    late RequestOptions captured;
    final client = clientFor((options) {
      captured = options;
      return {
        'errorCode': 0,
        'success': true,
        'isMatched': true,
        'matches': [
          {
            'animeId': 1,
            'animeTitle': 'Test Anime',
            'episodeId': 100,
            'episodeTitle': '第01话',
          },
        ],
      };
    });
    final response = await client.match(
      DandanplaySource.official,
      fileName: '[Group] Foo - 01 [1080p].mkv',
      fileHash: '0123abcd',
      fileSize: 123456,
      videoDuration: 2739,
      matchMode: 'fileNameOnly',
    );
    expect(captured.uri.toString(), 'https://api.dandanplay.net/api/v2/match');
    expect(captured.method, 'POST');
    final body = captured.data as Map<String, dynamic>;
    expect(body['fileName'], '[Group] Foo - 01 [1080p].mkv');
    expect(body['fileHash'], '0123abcd');
    expect(body['fileSize'], 123456);
    expect(body['videoDuration'], 2739);
    expect(body['matchMode'], 'fileNameOnly');
    expect(response.isMatched, isTrue);
    expect(response.matches.single.animeId, 1);
    expect(response.matches.single.episodeId, 100);
    expect(response.matches.single.episodeTitle, '第01话');
  });

  test('custom source keeps base path prefix and sends bearer token', () async {
    late RequestOptions captured;
    final client = clientFor((options) {
      captured = options;
      return {'success': true, 'isMatched': false, 'matches': <Object?>[]};
    });
    final source = DandanplaySource.custom('dan.example.com/ddplay', 'secret');
    expect(source.isCustom, isTrue);
    await client.match(
      source,
      fileName: 'foo.mkv',
      fileHash: '',
      fileSize: 0,
      videoDuration: 24,
    );
    expect(
      captured.uri.toString(),
      'https://dan.example.com/ddplay/api/v2/match',
    );
    expect(captured.headers['Authorization'], 'Bearer secret');
  });

  test(
    'official source with app credentials sends X-AppId and X-AppSecret',
    () async {
      late RequestOptions captured;
      final client = clientFor((options) {
        captured = options;
        return {'success': true, 'isMatched': false, 'matches': <Object?>[]};
      });
      final source = DandanplaySource.officialWith(
        appId: 'app-id',
        appSecret: 'app-secret',
      );
      expect(source.isCustom, isFalse);
      expect(source.headers(), {
        'X-AppId': 'app-id',
        'X-AppSecret': 'app-secret',
      });
      await client.match(
        source,
        fileName: 'foo.mkv',
        fileHash: '',
        fileSize: 0,
        videoDuration: 24,
      );
      expect(captured.headers['X-AppId'], 'app-id');
      expect(captured.headers['X-AppSecret'], 'app-secret');
      expect(captured.headers['Authorization'], isNull);
    },
  );

  test('searchAnime parses animes and episodes', () async {
    late RequestOptions captured;
    final client = clientFor((options) {
      captured = options;
      return {
        'success': true,
        'animes': [
          {
            'animeId': 7,
            'animeTitle': 'Foo',
            'type': 'tvseries',
            'episodes': [
              {'episodeId': 11, 'episodeTitle': '第01话'},
              {'episodeId': 12, 'episodeTitle': '第02话'},
            ],
          },
          'not-a-map',
        ],
      };
    });
    final animes = await client.searchAnime(DandanplaySource.official, ' foo ');
    expect(captured.uri.path, contains('/api/v2/search/anime'));
    expect(captured.uri.queryParameters['keyword'], 'foo');
    expect(animes, hasLength(1));
    expect(animes.single.animeId, 7);
    expect(animes.single.type, 'tvseries');
    expect(animes.single.isSeries, isTrue);
    expect(animes.single.episodes.map((e) => e.episodeId), [11, 12]);
  });

  test('searchAnime with blank keyword makes no request', () async {
    var requests = 0;
    final client = clientFor((options) {
      requests++;
      return {'success': true};
    });
    expect(await client.searchAnime(DandanplaySource.official, '  '), isEmpty);
    expect(requests, 0);
  });

  test('searchEpisodes posts anime and episode query', () async {
    late RequestOptions captured;
    final client = clientFor((options) {
      captured = options;
      return {
        'success': true,
        'animes': [
          {
            'animeId': 8,
            'animeTitle': 'Bar',
            'type': 'tvseries',
            'episodes': [
              {'episodeId': 21, 'episodeTitle': '第01话'},
            ],
          },
        ],
      };
    });
    final animes = await client.searchEpisodes(
      DandanplaySource.official,
      anime: 'Bar',
      episode: 1,
    );
    expect(captured.uri.path, contains('/api/v2/search/episodes'));
    expect(captured.uri.queryParameters['anime'], 'Bar');
    expect(captured.uri.queryParameters['episode'], '1');
    expect(animes.single.episodes.single.episodeId, 21);
  });

  test('fetchBangumi reads wrapped bangumi.episodes', () async {
    final client = clientFor((options) {
      expect(options.uri.path, contains('/api/v2/bangumi/9'));
      return {
        'success': true,
        'bangumi': {
          'animeId': 9,
          'animeTitle': 'Baz',
          'type': 'tvseries',
          'episodes': [
            {'episodeId': 31, 'episodeTitle': '第01话'},
            {'episodeId': 32, 'episodeTitle': '第02话'},
          ],
        },
      };
    });
    final anime = await client.fetchBangumi(DandanplaySource.official, 9);
    expect(anime, isNotNull);
    expect(anime!.animeTitle, 'Baz');
    expect(anime.episodes.map((e) => e.episodeId), [31, 32]);
  });

  test(
    'fetchComments stays on /api/v2/comment/{id} without url query',
    () async {
      late RequestOptions captured;
      final client = clientFor((options) {
        captured = options;
        return {'success': true, 'comments': <Object>[]};
      });
      await client.fetchComments(DandanplaySource.official, 10001);
      expect(captured.method, 'GET');
      expect(captured.uri.path, '/api/v2/comment/10001');
      expect(captured.uri.queryParameters.containsKey('url'), isFalse);
    },
  );

  test(
    'parseDanmakuComments parses official success and count/comments envelopes',
    () {
      final official = parseDanmakuComments(
        jsonEncode({'errorCode': 0, 'success': true, ..._officialCommentBody}),
      );
      expect(official.map((c) => c.cid), [3, 1, 2]);
      expect(official[0].time, 5.0);
      expect(official[0].renderMode, DanmakuMode.top);
      expect(official[1].renderMode, DanmakuMode.bottom);
      expect(official[2].renderMode, DanmakuMode.scroll);
      expect(official[2].color, 16711680);
      expect(official[2].text, 'scroll');

      final counted = parseDanmakuComments(jsonEncode(_officialCommentBody));
      expect(counted.map((c) => c.cid), [3, 1, 2]);
      expect(counted.map((c) => c.time), [5.0, 12.5, 61.2]);
    },
  );

  test('parseDanmakuComments rejects non-object or malformed bodies', () {
    expect(
      () => parseDanmakuComments('[1,2,3]'),
      throwsA(_formatFailure(DanmakuApiFailureKind.incompatible)),
    );
    expect(
      () => parseDanmakuComments('<html>not json</html>'),
      throwsA(_formatFailure(DanmakuApiFailureKind.incompatible)),
    );
    expect(
      () => parseDanmakuComments('{"unexpected":"shape"}'),
      throwsA(_formatFailure(DanmakuApiFailureKind.incompatible)),
    );
    expect(
      () => parseDanmakuComments(
        '{"errorCode":1000,"success":false,"errorMessage":"not found"}',
      ),
      throwsA(
        _formatFailure(
          DanmakuApiFailureKind.http,
        ).having((e) => e.detail, 'detail', 'not found'),
      ),
    );
    expect(parseDanmakuComments('{"success":true}'), isEmpty);
  });

  test('fetchComments requests plain text and parses synchronously', () async {
    late RequestOptions captured;
    final client = clientFor((options) {
      captured = options;
      return _officialCommentBody;
    });
    final comments = await client.fetchComments(DandanplaySource.official, 100);
    expect(captured.responseType, ResponseType.plain);
    expect(comments.map((c) => c.cid), [3, 1, 2]);
  });

  test(
    'fetchComments at or above the isolate threshold returns identical results',
    () async {
      final sync = await clientFor(
        (options) => _officialCommentBody,
      ).fetchComments(DandanplaySource.official, 100);
      final viaIsolate = await clientFor(
        (options) => _officialCommentBody,
        isolateParseThreshold: 0,
      ).fetchComments(DandanplaySource.official, 100);
      expect(viaIsolate, hasLength(sync.length));
      for (var i = 0; i < sync.length; i++) {
        expect(viaIsolate[i].cid, sync[i].cid);
        expect(viaIsolate[i].time, sync[i].time);
        expect(viaIsolate[i].mode, sync[i].mode);
        expect(viaIsolate[i].color, sync[i].color);
        expect(viaIsolate[i].text, sync[i].text);
      }
      expect(kDanmakuIsolateParseThreshold, 256 * 1024);
    },
  );

  test(
    'fetchComments isolate branch keeps incompatible/http error semantics',
    () async {
      final incompatible = clientFor(
        (options) => '<html>not json</html>',
        isolateParseThreshold: 0,
      );
      await expectLater(
        incompatible.fetchComments(DandanplaySource.official, 100),
        throwsA(
          isA<DanmakuApiException>()
              .having((e) => e.kind, 'kind', DanmakuApiFailureKind.incompatible)
              .having((e) => e.statusCode, 'statusCode', isNull),
        ),
      );
      final business = clientFor(
        (options) => {
          'errorCode': 1000,
          'success': false,
          'errorMessage': 'not found',
        },
        isolateParseThreshold: 0,
      );
      await expectLater(
        business.fetchComments(DandanplaySource.official, 100),
        throwsA(
          isA<DanmakuApiException>()
              .having((e) => e.kind, 'kind', DanmakuApiFailureKind.http)
              .having((e) => e.statusCode, 'statusCode', 200)
              .having((e) => e.detail, 'detail', 'not found'),
        ),
      );
    },
  );

  test('cancelled request maps to cancelled not unreachable', () async {
    final client = clientFor((options) async {
      await Completer<void>().future;
      return {'success': true};
    });
    final token = CancelToken();
    final future = client.searchAnime(
      DandanplaySource.official,
      'foo',
      cancelToken: token,
    );
    await Future<void>.delayed(Duration.zero);
    token.cancel();
    await expectLater(
      future,
      throwsA(
        isA<DanmakuApiException>().having(
          (e) => e.kind,
          'kind',
          DanmakuApiFailureKind.cancelled,
        ),
      ),
    );
  });

  test('transport failure maps to unreachable', () async {
    final client = clientFor((options) {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
      );
    });
    await expectLater(
      client.match(
        DandanplaySource.official,
        fileName: 'f',
        fileHash: '',
        fileSize: 0,
        videoDuration: 24,
      ),
      throwsA(
        isA<DanmakuApiException>().having(
          (e) => e.isUnreachable,
          'isUnreachable',
          isTrue,
        ),
      ),
    );
  });

  test(
    'error bodies map to incompatible or http with errorMessage detail',
    () async {
      // 非 dandanplay JSON 映射为 incompatible。
      final nonDandanplay = clientFor((options) => {'unexpected': 'shape'});
      await expectLater(
        nonDandanplay.searchAnime(DandanplaySource.official, 'foo'),
        throwsA(
          isA<DanmakuApiException>().having(
            (e) => e.kind,
            'kind',
            DanmakuApiFailureKind.incompatible,
          ),
        ),
      );

      // 纯文本响应体同样映射为 incompatible。
      final plainText = clientFor((options) => '<html>not json</html>');
      await expectLater(
        plainText.searchAnime(DandanplaySource.official, 'foo'),
        throwsA(
          isA<DanmakuApiException>().having(
            (e) => e.kind,
            'kind',
            DanmakuApiFailureKind.incompatible,
          ),
        ),
      );

      // success=false 映射为 http,detail 取 errorMessage。
      final business = clientFor((options) {
        return {
          'errorCode': 1000,
          'success': false,
          'errorMessage': 'not found',
        };
      });
      await expectLater(
        business.fetchComments(DandanplaySource.official, 100),
        throwsA(
          isA<DanmakuApiException>()
              .having((e) => e.kind, 'kind', DanmakuApiFailureKind.http)
              .having((e) => e.detail, 'detail', 'not found'),
        ),
      );
    },
  );

  test('HTTP 500 maps to http kind', () async {
    final client = clientFor((options) {
      return ResponseBody.fromBytes(
        utf8.encode('boom'),
        500,
        headers: {
          Headers.contentTypeHeader: ['text/plain'],
        },
      );
    });
    await expectLater(
      client.fetchComments(DandanplaySource.official, 100),
      throwsA(
        isA<DanmakuApiException>().having(
          (e) => e.kind,
          'kind',
          DanmakuApiFailureKind.http,
        ),
      ),
    );
  });
}
