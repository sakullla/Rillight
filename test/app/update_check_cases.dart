import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/updates/update_service.dart';
import 'package:rillight/app/updates/update_check.dart';
import 'package:rillight/app/updates/update_platform_contract.dart';
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
  int calls = 0;
  Future<void>? gate;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async {
    request = options;
    calls++;
    await gate;
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
      AppRelease.fromJson(releaseJson('v1.0.0+999')).isNewerThan('1.0.0+1'),
      isFalse,
    );
    expect(
      AppRelease.fromJson(releaseJson('v1.0.0+999')).isNewerThan('1.0.0'),
      isFalse,
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
      releaseJson('v1.0.0/../other'),
      releaseJson('v01.0.0'),
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
  test(
    'concurrent requests share one check and failed checks can retry',
    () async {
      final gate = Completer<void>();
      final adapter = _ReleaseAdapter()..gate = gate.future;
      final dio = Dio()..httpClientAdapter = adapter;
      final service = UpdateService(dio: dio);
      addTearDown(() {
        service.dispose();
        dio.close(force: true);
      });
      final first = service.check();
      final second = service.check();
      expect(identical(first, second), isTrue);
      gate.complete();
      await Future.wait([first, second]);
      expect(adapter.calls, 1);
      adapter.status = 404;
      await expectLater(service.check(), throwsA(isA<DioException>()));
      adapter.status = 200;
      expect(await service.check(), isA<AppRelease>());
      expect(adapter.calls, 3);
    },
  );
  test('official asset matching follows system architecture and package support', () {
    const tag = 'v2.0.0';
    const names = [
      'Rillight-windows-x64-v2.0.0-setup.exe',
      'Rillight-linux-x64-v2.0.0.deb',
      'Rillight-macos-v2.0.0-arm64-signed.dmg',
      'Rillight-macos-v2.0.0-x86_64-signed.dmg',
      'Rillight-android-arm64-v8a-v2.0.0.apk',
      'Rillight-android-armeabi-v7a-v2.0.0.apk',
      'Rillight-android-x86_64-v2.0.0.apk',
    ];
    final release = AppRelease.fromJson({
      ...releaseJson(tag),
      'assets': [
        for (final name in names)
          {
            'name': name,
            'size': 123,
            'browser_download_url':
                'https://github.com/sakullla/Rillight/releases/download/$tag/$name',
          },
      ],
    });
    final cases = [
      (
        UpdateCapabilities(
          system: UpdateOperatingSystem.windows,
          architecture: 'x86_64',
        ),
        names[0],
      ),
      (
        UpdateCapabilities(
          system: UpdateOperatingSystem.linux,
          architecture: 'x64',
          supportsDeb: true,
        ),
        names[1],
      ),
      (
        UpdateCapabilities(
          system: UpdateOperatingSystem.macos,
          architecture: 'aarch64',
        ),
        names[2],
      ),
      (
        UpdateCapabilities(
          system: UpdateOperatingSystem.macos,
          architecture: 'x64',
        ),
        names[3],
      ),
      (
        UpdateCapabilities(
          system: UpdateOperatingSystem.android,
          architecture: 'arm64',
          androidAbis: ['arm64-v8a', 'armeabi-v7a'],
        ),
        names[4],
      ),
      (
        UpdateCapabilities(
          system: UpdateOperatingSystem.android,
          architecture: 'arm',
          androidAbis: ['arm64-v8a', 'armeabi-v7a'],
        ),
        names[5],
      ),
      (
        UpdateCapabilities(
          system: UpdateOperatingSystem.android,
          architecture: 'x64',
          androidAbis: ['x86_64'],
        ),
        names[6],
      ),
    ];
    for (final (capabilities, name) in cases) {
      expect(selectUpdateAsset(release, capabilities).asset?.name, name);
    }
    expect(
      selectUpdateAsset(
        release,
        UpdateCapabilities(
          system: UpdateOperatingSystem.linux,
          architecture: 'x64',
        ),
      ).issue,
      UpdateAssetIssue.unsupportedPlatform,
    );
    expect(
      selectUpdateAsset(
        release,
        UpdateCapabilities(
          system: UpdateOperatingSystem.windows,
          architecture: 'arm64',
        ),
      ).asset,
      isNull,
    );
    expect(
      selectUpdateAsset(
        release,
        UpdateCapabilities(
          system: UpdateOperatingSystem.windows,
          architecture: null,
        ),
      ).issue,
      UpdateAssetIssue.unknownArchitecture,
    );
    expect(
      selectUpdateAsset(
        release,
        UpdateCapabilities(
          system: UpdateOperatingSystem.android,
          architecture: 'x64',
          androidAbis: ['arm64-v8a'],
        ),
      ).asset,
      isNull,
    );
    expect(() => release.assets.clear(), throwsUnsupportedError);
  });
  test('missing, ambiguous and unrelated asset links never produce a package', () {
    final capabilities = UpdateCapabilities(
      system: UpdateOperatingSystem.windows,
      architecture: 'x64',
    );
    const name = 'Rillight-windows-x64-v2.0.0-setup.exe';
    final asset = {
      'name': name,
      'browser_download_url':
          'https://github.com/sakullla/Rillight/releases/download/v2.0.0/$name',
    };
    AppRelease candidate(List<Object> assets) =>
        AppRelease.fromJson({...releaseJson('v2.0.0'), 'assets': assets});
    expect(
      selectUpdateAsset(candidate([]), capabilities).issue,
      UpdateAssetIssue.missing,
    );
    expect(
      selectUpdateAsset(candidate([asset, asset]), capabilities).issue,
      UpdateAssetIssue.ambiguous,
    );
    final unsafe = candidate([
      {...asset, 'browser_download_url': 'https://unrelated.test/$name'},
    ]);
    expect(
      selectUpdateAsset(unsafe, capabilities).issue,
      UpdateAssetIssue.unsafe,
    );
    expect(
      unsafe.url.toString(),
      'https://github.com/sakullla/Rillight/releases/tag/v2.0.0',
    );
  });
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
