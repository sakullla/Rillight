import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/player/danmaku/danmaku_hash.dart';

/// 哈希器测试用适配器:返回固定字节流并记录请求。
class _StreamAdapter implements HttpClientAdapter {
  _StreamAdapter(this._handler);

  final Future<ResponseBody> Function(RequestOptions options) _handler;
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
    return _handler(options);
  }
}

DanmakuStreamHasher hasherFor(
  Future<ResponseBody> Function(RequestOptions options) handler,
) {
  final dio = Dio();
  dio.httpClientAdapter = _StreamAdapter(handler);
  return DanmakuStreamHasher(dio: dio);
}

void main() {
  test('md5 known vectors', () async {
    expect(
      await md5OfBytes(Stream.value(utf8.encode(''))),
      'd41d8cd98f00b204e9800998ecf8427e',
    );
    expect(
      await md5OfBytes(Stream.value(utf8.encode('abc'))),
      '900150983cd24fb0d6963f7d28e17f72',
    );
  });

  test(
    'md5 chunked feeding equals single feeding across block boundaries',
    () async {
      for (final length in [55, 56, 57, 63, 64, 65, 128, 200, 1000]) {
        final data = List<int>.generate(length, (i) => (i * 31 + 7) & 0xff);
        final whole = Md5Sink()..add(data);
        final chunked = Md5Sink();
        for (var i = 0; i < data.length; i += 7) {
          chunked.add(data.sublist(i, (i + 7).clamp(0, data.length)));
        }
        expect(chunked.close(), whole.close(), reason: 'length $length');
      }
    },
  );

  test('hasher sends 16MB range request and hashes the payload', () async {
    final bytes = List<int>.generate(1024, (i) => i & 0xff);
    late RequestOptions captured;
    final hasher = hasherFor((options) async {
      captured = options;
      return ResponseBody(
        Stream.fromIterable([Uint8List.fromList(bytes)]),
        206,
      );
    });
    final hash = await hasher.hashOf(Uri.parse('https://emby.example/v/1'));
    expect(captured.headers['Range'], 'bytes=0-${16 * 1024 * 1024 - 1}');
    final expected = Md5Sink()..add(bytes);
    expect(hash, expected.close());
    expect(captured.uri.toString(), 'https://emby.example/v/1');
  });

  test('hasher truncates streams larger than 16MB', () async {
    final total = 16 * 1024 * 1024 + 4096;
    final bytes = Uint8List(total);
    for (var i = 0; i < total; i++) {
      bytes[i] = i & 0xff;
    }
    final hasher = hasherFor((options) async {
      return ResponseBody(Stream.fromIterable([bytes]), 200);
    });
    final hash = await hasher.hashOf(Uri.parse('https://emby.example/v/1'));
    final expected = Md5Sink()..add(bytes.sublist(0, 16 * 1024 * 1024));
    expect(hash, expected.close());
  });

  test('hasher swallows failures as null (filename fallback)', () async {
    final hasher = hasherFor((options) async {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
      );
    });
    expect(await hasher.hashOf(Uri.parse('https://emby.example/v/1')), isNull);
  });
}
