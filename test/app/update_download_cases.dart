import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/updates/update_download.dart';
import 'package:rillight/app/updates/update_service.dart';

const _digest =
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';
const _name = 'Rillight-windows-x64-v2.0.0-setup.exe';

AppRelease _release({
  int? size,
  String? url,
  bool sums = true,
}) => AppRelease.fromJson({
  'tag_name': 'v2.0.0',
  'draft': false,
  'prerelease': false,
  'assets': [
    {
      'name': _name,
      'size': size,
      'browser_download_url':
          url ??
          'https://github.com/sakullla/Rillight/releases/download/v2.0.0/$_name',
    },
    if (sums)
      {
        'name': 'SHA256SUMS',
        'browser_download_url': 'https://github.com/sakullla/Rillight/releases/download/v2.0.0/SHA256SUMS',
      },
  ],
});

class _Adapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];
  Future<ResponseBody> Function(RequestOptions)? handler;
  String manifest = '$_digest  dist/$_name\n';
  String package = 'abc';
  int? contentLength;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (handler != null) return handler!(options);
    return ResponseBody.fromString(
      options.uri.path.endsWith('SHA256SUMS') ? manifest : package,
      200,
      headers: {
        if (contentLength != null && !options.uri.path.endsWith('SHA256SUMS'))
          'content-length': ['$contentLength'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late Directory root;
  late _Adapter adapter;
  late Dio dio;
  late UpdateDownloader downloader;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('rillight-update-test-');
    adapter = _Adapter();
    dio = Dio()..httpClientAdapter = adapter;
    downloader = UpdateDownloader(dio: dio, cacheDirectory: () async => root);
  });
  tearDown(() async {
    downloader.dispose();
    dio.close(force: true);
    await root.delete(recursive: true);
  });
  Future<VerifiedUpdate> run({
    AppRelease? release,
    CancelToken? token,
    UpdateByteProgress? progress,
    void Function()? verifying,
  }) {
    final candidate = release ?? _release();
    return downloader.download(
      release: candidate,
      asset: candidate.assets.first,
      cancelToken: token ?? CancelToken(),
      onProgress: progress ?? (_, _) {},
      onVerifying: verifying ?? () {},
    );
  }

  test(
    'streams into a real file, verifies dist checksums and known progress',
    () async {
      adapter.contentLength = 3;
      final progress = <(int, int?)>[];
      var verifying = false;
      final update = await run(
        progress: (bytes, total) => progress.add((bytes, total)),
        verifying: () => verifying = true,
      );
      expect(await update.file.readAsString(), 'abc');
      expect(update.file.path.endsWith('.part'), isFalse);
      expect(verifying, isTrue);
      expect(progress.first, (0, 3));
      expect(progress.last, (3, 3));
      expect(await downloader.verify(update), isTrue);
      expect(adapter.requests, hasLength(2));
      expect(
        adapter.requests.every(
          (r) => !r.headers.containsKey('Authorization') && !r.followRedirects,
        ),
        isTrue,
      );
    },
  );
  test(
    'unknown size stays indeterminate; metadata size is a fallback',
    () async {
      final totals = <int?>[];
      await run(progress: (_, total) => totals.add(total));
      expect(totals, everyElement(isNull));
      await run(
        release: _release(size: 3),
        progress: (_, total) => totals.add(total),
      );
      expect(totals.last, 3);
    },
  );
  test(
    'same length file tampering and missing file revoke integrity',
    () async {
      final update = await run();
      await update.file.writeAsString('abd');
      expect(await downloader.verify(update), isFalse);
      await update.file.delete();
      expect(await downloader.verify(update), isFalse);
    },
  );
  for (final manifest in [
    '',
    'not a checksum',
    '${'0' * 64}  $_name',
    '$_digest  other.exe',
    '$_digest  ../$_name',
    '$_digest  /$_name',
    '$_digest  dist/../$_name',
    '$_digest  $_name\n$_digest *dist/$_name',
    '$_digest  $_name\ninvalid extra line',
  ]) {
    test('invalid or ambiguous checksum prevents ready: $manifest', () async {
      adapter.manifest = manifest;
      await expectLater(
        run(),
        throwsA(
          isA<UpdateDownloadException>().having(
            (e) => e.failure,
            'failure',
            UpdateDownloadFailure.checksum,
          ),
        ),
      );
      expect(await root.list().toList(), isEmpty);
    });
  }
  test('checksum parser accepts uppercase and binary marker', () {
    expect(
      updateChecksumFor('${_digest.toUpperCase()} *dist/$_name\r\n', _name),
      _digest,
    );
  });
  test(
    'checksum HTTP failure and duplicate manifest assets cannot become ready',
    () async {
      adapter.handler = (options) async => ResponseBody.fromString(
        options.uri.path.endsWith('SHA256SUMS') ? '' : 'abc',
        options.uri.path.endsWith('SHA256SUMS') ? 404 : 200,
      );
      await expectLater(run(), throwsA(isA<UpdateDownloadException>()));
      expect(await root.list().toList(), isEmpty);
      final release = _release();
      final duplicate = AppRelease(
        version: release.version,
        url: release.url,
        assets: [...release.assets, release.assets.last],
      );
      adapter.requests.clear();
      await expectLater(
        run(release: duplicate),
        throwsA(
          isA<UpdateDownloadException>().having(
            (e) => e.failure,
            'failure',
            UpdateDownloadFailure.checksum,
          ),
        ),
      );
      expect(adapter.requests, isEmpty);
    },
  );
  test('download timeout is an explicit retryable failure', () async {
    adapter.handler = (options) async => throw DioException(
      requestOptions: options,
      type: DioExceptionType.receiveTimeout,
    );
    await expectLater(
      run(),
      throwsA(
        isA<UpdateDownloadException>().having(
          (e) => e.failure,
          'failure',
          UpdateDownloadFailure.timeout,
        ),
      ),
    );
    expect(await root.list().toList(), isEmpty);
  });
  test('missing checksum asset fails before network', () async {
    await expectLater(
      run(release: _release(sums: false)),
      throwsA(isA<UpdateDownloadException>()),
    );
    expect(adapter.requests, isEmpty);
  });
  test('unsafe source is rejected before network', () async {
    for (final uri in [
      'http://github.com/sakullla/Rillight/releases/download/v2.0.0/$_name',
      'https://github.com/other/Rillight/releases/download/v2.0.0/$_name',
      'https://github.com/sakullla/Rillight/releases/download/v1.0.0/$_name',
      'https://example.com/$_name',
    ]) {
      await expectLater(
        run(release: _release(url: uri)),
        throwsA(
          isA<UpdateDownloadException>().having(
            (e) => e.failure,
            'failure',
            UpdateDownloadFailure.unsafeAsset,
          ),
        ),
      );
    }
    expect(adapter.requests, isEmpty);
  });
  test('redirects only connect to approved HTTPS asset hosts', () async {
    adapter.handler = (options) async => ResponseBody.fromString(
      '',
      302,
      headers: {
        'location': ['https://unrelated.test/file'],
      },
    );
    await expectLater(
      run(),
      throwsA(
        isA<UpdateDownloadException>().having(
          (e) => e.failure,
          'failure',
          UpdateDownloadFailure.unsafeAsset,
        ),
      ),
    );
    expect(adapter.requests, hasLength(1));
    adapter.requests.clear();
    adapter.handler = (options) async {
      if (options.uri.path.endsWith('SHA256SUMS')) {
        return ResponseBody.fromString(adapter.manifest, 200);
      }
      if (options.uri.host == 'github.com') {
        return ResponseBody.fromString(
          '',
          302,
          headers: {
            'location': [
              'https://release-assets.githubusercontent.com/github-production-release-asset/123/file?signature=synthetic',
            ],
          },
        );
      }
      return ResponseBody.fromString('abc', 200);
    };
    expect(await downloader.verify(await run()), isTrue);
    expect(adapter.requests, hasLength(3));
  });
  test(
    'truncated response and wrong metadata length cannot become ready',
    () async {
      adapter.contentLength = 5;
      await expectLater(run(), throwsA(isA<UpdateDownloadException>()));
      adapter.contentLength = null;
      await expectLater(
        run(release: _release(size: 1)),
        throwsA(isA<UpdateDownloadException>()),
      );
      expect(await root.list().toList(), isEmpty);
    },
  );
  test('network failure cleans partial and retry starts from zero', () async {
    adapter.handler = (_) async => ResponseBody(
      Stream<Uint8List>.fromIterable([Uint8List.fromList(utf8.encode('ab'))])
          .asyncExpand((bytes) async* {
            yield bytes;
            throw const SocketException('synthetic disconnect');
          }),
      200,
    );
    await expectLater(run(), throwsA(isA<UpdateDownloadException>()));
    expect(await root.list().toList(), isEmpty);
    adapter.handler = null;
    final update = await run();
    expect(await update.file.readAsString(), 'abc');
  });
  test(
    'unwritable cache failure is classified as disk, without a package',
    () async {
      final blocker = File('${root.path}/blocker');
      await blocker.writeAsString('not a directory');
      final broken = UpdateDownloader(
        dio: dio,
        cacheDirectory: () async => Directory('${blocker.path}/updates'),
      );
      final candidate = _release();
      await expectLater(
        broken.download(
          release: candidate,
          asset: candidate.assets.first,
          cancelToken: CancelToken(),
          onProgress: (_, _) {},
          onVerifying: () {},
        ),
        throwsA(
          isA<UpdateDownloadException>().having(
            (e) => e.failure,
            'failure',
            UpdateDownloadFailure.disk,
          ),
        ),
      );
      expect(adapter.requests, isEmpty);
    },
  );
  test(
    'cancel before request and during verification never returns a file',
    () async {
      final early = CancelToken()..cancel();
      await expectLater(
        run(token: early),
        throwsA(
          isA<UpdateDownloadException>().having(
            (e) => e.failure,
            'failure',
            UpdateDownloadFailure.cancelled,
          ),
        ),
      );
      expect(adapter.requests, isEmpty);
      final token = CancelToken();
      await expectLater(
        run(token: token, verifying: () => token.cancel()),
        throwsA(
          isA<UpdateDownloadException>().having(
            (e) => e.failure,
            'failure',
            UpdateDownloadFailure.cancelled,
          ),
        ),
      );
      expect(await root.list().toList(), isEmpty);
    },
  );
  test(
    'cancellation stops a pending request even if adapter responds late',
    () async {
      final response = Completer<ResponseBody>();
      final started = Completer<void>();
      adapter.handler = (_) {
        started.complete();
        return response.future;
      };
      final token = CancelToken();
      final pending = run(token: token);
      final assertion = expectLater(
        pending,
        throwsA(
          isA<UpdateDownloadException>().having(
            (e) => e.failure,
            'failure',
            UpdateDownloadFailure.cancelled,
          ),
        ),
      );
      await started.future;
      token.cancel();
      response.complete(ResponseBody.fromString('abc', 200));
      await assertion;
      expect(await root.list().toList(), isEmpty);
    },
  );
}
