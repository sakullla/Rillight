import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/updates/update_service.dart';
import 'package:rillight/app/updates/update_check.dart';
import 'package:rillight/app/ui/ui.dart';

import '../helpers/cupertino_test_app.dart';

Map<String, Object?> releaseJson(String tag) => {
  'tag_name': tag,
  'draft': false,
  'prerelease': false,
  'body': '改进字幕导入',
  'html_url': 'https://unrelated.test/download',
};

class _ReleaseAdapter implements HttpClientAdapter {
  RequestOptions? request;
  int status = 200;
  Object? data = releaseJson('v0.1.100');
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async {
    request = options;
    return ResponseBody.fromString(
      jsonEncode(data),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('compares numeric versions and ignores build metadata', () {
    expect(
      AppRelease.fromJson(releaseJson('v0.1.100')).isNewerThan('0.1.99'),
      isTrue,
    );
    expect(
      AppRelease.fromJson(releaseJson('v0.1.9')).isNewerThan('0.1.67'),
      isFalse,
    );
    expect(
      AppRelease.fromJson(releaseJson('v0.1.67')).isNewerThan('0.1.67+68'),
      isFalse,
    );
    expect(
      AppRelease.fromJson(releaseJson('v1.0.0')).isNewerThan('1.0.0-rc.1'),
      isTrue,
    );
  });
  test('rejects prereleases, drafts and invalid tags', () {
    for (final data in [
      null,
      {},
      releaseJson('latest'),
      releaseJson('v1.0.0-beta'),
      {...releaseJson('v1.0.0'), 'draft': true},
      {...releaseJson('v1.0.0'), 'prerelease': true},
    ]) {
      expect(() => AppRelease.fromJson(data), throwsFormatException);
    }
  });
  test(
    'uses the official release endpoint without server credentials',
    () async {
      final adapter = _ReleaseAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      addTearDown(() => dio.close(force: true));
      final release = await UpdateService(dio: dio).check();
      expect(
        adapter.request!.uri.toString(),
        'https://api.github.com/repos/sakullla/Rillight/releases/latest',
      );
      expect(adapter.request!.headers.containsKey('Authorization'), isFalse);
      expect(
        release.url.toString(),
        'https://github.com/sakullla/Rillight/releases/tag/v0.1.100',
      );
      adapter.status = 403;
      await expectLater(
        UpdateService(dio: dio).check(),
        throwsA(isA<DioException>()),
      );
    },
  );
  testWidgets('shows progress, release notes and a download action', (
    tester,
  ) async {
    final pending = Completer<AppRelease>();
    Uri? opened;
    await tester.pumpWidget(
      CupertinoTestApp(
        home: CupertinoPageScaffold(
          child: UpdateCheck(
            check: () => pending.future,
            openRelease: (uri) async {
              opened = uri;
              return true;
            },
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('app-update-check-button')));
    await tester.pump();
    expect(find.text('正在检查更新…'), findsOneWidget);
    pending.complete(AppRelease.fromJson(releaseJson('v99.0.0')));
    await tester.pumpAndSettle();
    expect(find.text('发现新版本 99.0.0'), findsOneWidget);
    await tester.tap(find.byKey(const Key('app-update-open')));
    await tester.pumpAndSettle();
    expect(opened?.host, 'github.com');
  });
  testWidgets('failure can be retried and does not claim latest', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      CupertinoTestApp(
        home: CupertinoPageScaffold(
          child: UpdateCheck(
            check: () async {
              if (calls++ == 0) throw StateError('network');
              return AppRelease.fromJson(releaseJson('v0.0.1'));
            },
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('app-update-check-button')));
    await tester.pumpAndSettle();
    expect(find.text('暂时无法检查更新，请检查网络后重试。'), findsOneWidget);
    expect(find.text('当前已是最新版本'), findsNothing);
    await tester.tap(find.byKey(const Key('app-update-check-button')));
    await tester.pumpAndSettle();
    expect(find.text('当前已是最新版本'), findsOneWidget);
    expect(find.byKey(const Key('app-update-open')), findsNothing);
  });
}
