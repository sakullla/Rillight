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
    final result = await _handler(options);
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
  FutureOr<Object?> Function(RequestOptions options) handler,
) {
  final dio = Dio();
  dio.httpClientAdapter = _ScriptedAdapter(handler);
  return DandanplayClient(dio: dio);
}

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
      fileSize: 0,
      videoDuration: 24,
    );
    expect(captured.uri.toString(), 'https://api.dandanplay.net/api/v2/match');
    expect(captured.method, 'POST');
    final body = captured.data as Map<String, dynamic>;
    expect(body['fileName'], '[Group] Foo - 01 [1080p].mkv');
    expect(body['fileHash'], '0123abcd');
    expect(body['fileSize'], 0);
    expect(body['videoDuration'], 24);
    expect(body['matchMode'], 'hashAndFileName');
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

  test('fetchComments parses p/m fields and sorts by time', () async {
    final client = clientFor((options) {
      expect(options.uri.path, contains('/api/v2/comment/100'));
      return {
        'success': true,
        'comments': [
          {'cid': 2, 'p': '61.2,1,16711680,0,25,0,7b7b7b,0', 'm': 'scroll'},
          {'cid': 1, 'p': '12.5,4,16777215,0,25,0,ffffff,0', 'm': 'bottom'},
          {'cid': 3, 'p': '5.0,5,65280,0,25,0,ffffff,0', 'm': 'top'},
          {'cid': 4, 'p': 'broken', 'm': 'skipped'},
          {'cid': 5, 'p': '1,1,2,0,25,0,fff,0', 'm': ''},
          'not-a-map',
        ],
      };
    });
    final comments = await client.fetchComments(DandanplaySource.official, 100);
    expect(comments.map((c) => c.cid), [3, 1, 2]);
    expect(comments[0].time, 5.0);
    expect(comments[0].renderMode, DanmakuMode.top);
    expect(comments[1].renderMode, DanmakuMode.bottom);
    expect(comments[2].renderMode, DanmakuMode.scroll);
    expect(comments[2].color, 16711680);
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

  test('non-dandanplay JSON maps to incompatible', () async {
    final client = clientFor((options) => {'unexpected': 'shape'});
    await expectLater(
      client.searchAnime(DandanplaySource.official, 'foo'),
      throwsA(
        isA<DanmakuApiException>().having(
          (e) => e.kind,
          'kind',
          DanmakuApiFailureKind.incompatible,
        ),
      ),
    );
  });

  test('plain text body maps to incompatible', () async {
    final client = clientFor((options) => '<html>not json</html>');
    await expectLater(
      client.searchAnime(DandanplaySource.official, 'foo'),
      throwsA(
        isA<DanmakuApiException>().having(
          (e) => e.kind,
          'kind',
          DanmakuApiFailureKind.incompatible,
        ),
      ),
    );
  });

  test('success=false maps to http with errorMessage detail', () async {
    final client = clientFor((options) {
      return {'errorCode': 1000, 'success': false, 'errorMessage': 'not found'};
    });
    await expectLater(
      client.fetchComments(DandanplaySource.official, 100),
      throwsA(
        isA<DanmakuApiException>()
            .having((e) => e.kind, 'kind', DanmakuApiFailureKind.http)
            .having((e) => e.detail, 'detail', 'not found'),
      ),
    );
  });

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
