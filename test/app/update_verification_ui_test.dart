import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/app/updates/update_check.dart';
import 'package:rillight/app/updates/update_controller.dart';
import 'package:rillight/app/updates/update_download.dart';
import 'package:rillight/app/updates/update_platform_contract.dart';

import '../helpers/cupertino_test_app.dart';
import 'update_ui_fixture.dart';

const _digest =
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.handler);
  final Future<ResponseBody> Function(RequestOptions) handler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) => handler(options);

  @override
  void close({bool force = false}) {}
}

Future<void> _downloadTap(
  WidgetTester tester,
  UpdateController controller,
  String key,
) async {
  await tester.ensureVisible(find.byKey(Key(key)));
  await tester.runAsync(() async {
    final finished = Completer<void>();
    void listener() {
      if (!controller.download.busy && !finished.isCompleted) {
        finished.complete();
      }
    }

    controller.addListener(listener);
    try {
      await tester.tap(find.byKey(Key(key)));
      await finished.future.timeout(const Duration(seconds: 10));
    } finally {
      controller.removeListener(listener);
    }
  });
  await tester.pumpAndSettle();
}

void main() {
  for (final checksumStage in [true, false]) {
    for (final error in ['HTTP 404', 'timeout', 'network']) {
      testWidgets(
        '${checksumStage ? 'checksum' : 'package'} $error preserves failure stage and retry',
        (tester) async {
          final root = (await tester.runAsync(
            () => Directory.systemTemp.createTemp('rillight-verification-ui-'),
          ))!;
          final platform = UiUpdatePlatform(UpdateOperatingSystem.windows);
          final service = UiUpdateService(UpdateOperatingSystem.windows);
          final packageName = service.release.assets.first.name;
          var shouldFail = true;
          var checksumRequests = 0;
          var packageRequests = 0;
          final packagesAtVerification = <String>[];
          final pathsAtVerification = <String>[];
          final dio = Dio()
            ..httpClientAdapter = _Adapter((options) async {
              final checksum = options.uri.path.endsWith('SHA256SUMS');
              if (checksum) {
                checksumRequests++;
                // The production downloader has flushed and closed a complete
                // package on disk before it requests the checksum manifest.
                final files = await root
                    .list(recursive: true)
                    .where((entry) => entry is File)
                    .cast<File>()
                    .toList();
                pathsAtVerification.add(files.single.path);
                packagesAtVerification.add(await files.single.readAsString());
              } else {
                packageRequests++;
              }
              if (shouldFail && checksum == checksumStage) {
                if (error == 'HTTP 404') {
                  return ResponseBody.fromString('', 404);
                }
                throw DioException(
                  requestOptions: options,
                  type: error == 'timeout'
                      ? DioExceptionType.receiveTimeout
                      : DioExceptionType.connectionError,
                );
              }
              return ResponseBody.fromString(
                checksum ? '$_digest  $packageName\n' : 'abc',
                200,
                headers: {
                  if (!checksum) 'content-length': ['3'],
                },
              );
            });
          final controller = UpdateController(
            platform: platform,
            service: service,
            downloader: UpdateDownloader(
              dio: dio,
              cacheDirectory: () async => root,
            ),
          );
          addTearDown(() async {
            controller.dispose();
            dio.close(force: true);
            await root.delete(recursive: true);
          });
          await controller.check();
          await tester.pumpWidget(
            CupertinoTestApp(
              home: CupertinoPageScaffold(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: UpdateCheck(controller: controller),
                ),
              ),
            ),
          );
          await _downloadTap(tester, controller, 'app-update-download');
          expect(controller.download.phase, UpdateDownloadPhase.failed);
          expect(
            controller.download.failedPhase,
            checksumStage
                ? UpdateDownloadPhase.verifying
                : UpdateDownloadPhase.downloading,
          );
          expect(
            controller.download.failure,
            error == 'timeout'
                ? UpdateDownloadFailure.timeout
                : UpdateDownloadFailure.network,
          );
          expect(controller.download.verified, isNull);
          expect(packageRequests, 1);
          expect(checksumRequests, checksumStage ? 1 : 0);
          expect(packagesAtVerification, checksumStage ? ['abc'] : isEmpty);
          expect(pathsAtVerification, everyElement(endsWith('.part')));
          if (checksumStage) {
            expect(find.textContaining('无法完成安装包完整性校验'), findsOneWidget);
            expect(find.textContaining('已禁止安装'), findsOneWidget);
            expect(find.textContaining('下载失败'), findsNothing);
            expect(find.textContaining('下载超时'), findsNothing);
          } else {
            expect(
              find.textContaining(error == 'timeout' ? '下载超时' : '下载失败'),
              findsOneWidget,
            );
            expect(find.textContaining('无法完成安装包完整性校验'), findsNothing);
          }
          expect(find.byKey(const Key('app-update-install')), findsNothing);
          expect(find.byKey(const Key('app-update-retry')), findsOneWidget);
          expect(find.byType(AppSelectableText), findsNothing);
          expect(find.textContaining('复制'), findsNothing);
          await controller.install();
          expect(platform.installed, 0);
          await tester.runAsync(() async {
            expect(await root.list().toList(), isEmpty);
          });
          await tester.ensureVisible(find.byKey(const Key('app-update-open')));
          await tester.tap(find.byKey(const Key('app-update-open')));
          await tester.pumpAndSettle();
          expect(platform.opened, 1);

          shouldFail = false;
          await _downloadTap(tester, controller, 'app-update-retry');
          expect(packageRequests, 2);
          expect(
            packagesAtVerification,
            checksumStage ? ['abc', 'abc'] : ['abc'],
          );
          expect(controller.download.phase, UpdateDownloadPhase.ready);
          expect(controller.download.failedPhase, isNull);
          expect(controller.download.failure, isNull);
          expect(find.byKey(const Key('app-update-install')), findsOneWidget);
          expect(find.textContaining('无法完成安装包完整性校验'), findsNothing);
          await tester.runAsync(() async {
            expect(
              await controller.download.verified!.file.readAsString(),
              'abc',
            );
          });
          expect(platform.installed, 0);
        },
      );
    }
  }
}
