import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';

class _PreviewAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];
  bool empty = false;
  bool oversized = false;
  int chunksRead = 0;
  bool cancelled = false;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (options.path.contains('ThumbnailSet')) {
      return ResponseBody.fromString(
        empty
            ? '{"Thumbnails":[]}'
            : '{"Thumbnails":[{"PositionTicks":0,"ImageTag":"test"}]}',
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
    }
    if (!oversized) return ResponseBody.fromBytes([1, 2, 3], 200);
    cancelFuture?.then((_) => cancelled = true);
    Stream<Uint8List> chunks() async* {
      final chunk = Uint8List(1024 * 1024);
      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(Duration.zero);
        if (cancelled) break;
        chunksRead++;
        yield chunk;
      }
    }

    return ResponseBody(chunks(), 200);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late _PreviewAdapter adapter;
  late EmbyClient client;
  setUp(() {
    adapter = _PreviewAdapter();
    client = EmbyClient(
      device: const EmbyDeviceInfo(
        clientName: 'test',
        deviceName: 'test',
        deviceId: 'preview',
        version: '1',
      ),
      dio: Dio()..httpClientAdapter = adapter,
    );
    client.attachSession(
      baseUrl: Uri.parse('http://test.invalid/emby'),
      accessToken: 'synthetic',
      userId: 'test',
      userAgent: 'ConfiguredTestUA',
    );
  });
  test(
    'preview metadata and BIF preserve API prefix and saved session headers',
    () async {
      expect(await client.hasVideoPreviewThumbnails('video'), isTrue);
      expect(await client.getVideoPreviewBif('video'), [1, 2, 3]);
      expect(adapter.requests.map((r) => r.uri.path), [
        '/emby/Items/video/ThumbnailSet',
        '/emby/Videos/video/index.bif',
      ]);
      for (final request in adapter.requests) {
        expect(request.headers['User-Agent'], 'ConfiguredTestUA');
        expect(request.headers['X-Emby-Token'], 'synthetic');
        expect(request.uri.queryParameters['Width'], '160');
      }
    },
  );
  test('empty preview metadata remains optional', () async {
    adapter.empty = true;
    expect(await client.hasVideoPreviewThumbnails('video'), isFalse);
  });
  test('BIF stream stops at its 32 MiB budget', () async {
    adapter.oversized = true;
    await expectLater(
      client.getVideoPreviewBif('video'),
      throwsFormatException,
    );
    expect(adapter.chunksRead, lessThanOrEqualTo(34));
  });
}
