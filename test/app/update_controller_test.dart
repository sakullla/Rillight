import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/updates/update_controller.dart';
import 'package:rillight/app/updates/update_download.dart';
import 'package:rillight/app/updates/update_platform_contract.dart';
import 'package:rillight/app/updates/update_service.dart';

const _digest =
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';
Map<String, Object?> _json(String version) {
  final name = 'Rillight-windows-x64-v$version-setup.exe';
  return {
    'tag_name': 'v$version',
    'draft': false,
    'prerelease': false,
    'assets': [
      for (final name in [name, 'SHA256SUMS'])
        {
          'name': name,
          'browser_download_url':
              'https://github.com/sakullla/Rillight/releases/download/v$version/$name',
        },
    ],
  };
}

class _Adapter implements HttpClientAdapter {
  String version = '2.0.0';
  int checks = 0;
  int downloads = 0;
  int status = 200;
  Future<void>? checkGate;
  Future<void>? downloadGate;
  Completer<void>? downloadStarted;
  DioExceptionType? checkError;
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (options.uri.host == 'api.github.com') {
      checks++;
      await checkGate;
      if (checkError != null) {
        throw DioException(requestOptions: options, type: checkError!);
      }
      return ResponseBody.fromString(
        jsonEncode(_json(version)),
        status,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
    }
    if (options.uri.path.endsWith('SHA256SUMS')) {
      final tag = options.uri.pathSegments[4];
      return ResponseBody.fromString(
        '$_digest  dist/Rillight-windows-x64-$tag-setup.exe',
        200,
      );
    }
    downloads++;
    if (downloadStarted?.isCompleted == false) downloadStarted!.complete();
    await downloadGate;
    return ResponseBody.fromString('abc', 200);
  }

  @override
  void close({bool force = false}) {}
}

class _Platform implements UpdatePlatform {
  int installs = 0;
  int opens = 0;
  int permissions = 0;
  UpdateActionResult result = const UpdateActionResult(
    UpdateActionStatus.handedOff,
  );
  bool failCapabilities = false;
  @override
  Future<UpdateCapabilities> capabilities() async {
    if (failCapabilities) throw StateError('unavailable');
    return UpdateCapabilities(
      system: UpdateOperatingSystem.windows,
      architecture: 'x64',
    );
  }

  @override
  Future<UpdateActionResult> install(VerifiedUpdate update) async {
    installs++;
    return result;
  }

  @override
  Future<UpdateActionResult> openRelease(AppRelease release) async {
    opens++;
    return result;
  }

  @override
  Future<UpdateActionResult> requestInstallPermission() async {
    permissions++;
    return result;
  }
}

void main() {
  late Directory root;
  late _Adapter adapter;
  late _Platform platform;
  late Dio dio;
  late UpdateController controller;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('rillight-controller-test-');
    adapter = _Adapter();
    platform = _Platform();
    dio = Dio()..httpClientAdapter = adapter;
    controller = UpdateController(
      platform: platform,
      service: UpdateService(dio: dio),
      downloader: UpdateDownloader(dio: dio, cacheDirectory: () async => root),
      currentVersion: '1.0.0',
    );
  });
  tearDown(() async {
    controller.dispose();
    dio.close(force: true);
    await root.delete(recursive: true);
  });
  test(
    'manual joins startup check with feedback, one request, no auto download',
    () async {
      final gate = Completer<void>();
      adapter.checkGate = gate.future;
      final automatic = controller.checkAtStartup();
      expect(controller.checkPhase, UpdateCheckPhase.checking);
      expect(controller.manualCheck, isFalse);
      final manual = controller.check();
      expect(controller.manualCheck, isTrue);
      expect(identical(automatic, manual), isTrue);
      gate.complete();
      await Future.wait([automatic, manual]);
      expect(adapter.checks, 1);
      expect(controller.checkPhase, UpdateCheckPhase.available);
      expect(controller.pendingAutomaticRelease?.version.toString(), '2.0.0');
      expect(adapter.downloads, 0);
      expect(platform.installs, 0);
      await controller.checkAtStartup();
      expect(adapter.checks, 1);
    },
  );
  test(
    'automatic acknowledgement is per version and manual can still inspect',
    () async {
      await controller.checkAtStartup();
      controller.acknowledgeAutomaticRelease(
        controller.pendingAutomaticRelease!,
      );
      await controller.check(automatic: true);
      expect(controller.pendingAutomaticRelease, isNull);
      await controller.check();
      expect(controller.release?.version.toString(), '2.0.0');
      adapter.version = '3.0.0';
      await controller.check(automatic: true);
      expect(controller.pendingAutomaticRelease?.version.toString(), '3.0.0');
    },
  );
  test(
    'timeout and invalid release retain explicit failure instead of current',
    () async {
      adapter.checkError = DioExceptionType.receiveTimeout;
      await controller.check();
      expect(controller.checkPhase, UpdateCheckPhase.failed);
      expect(controller.checkFailure, UpdateCheckFailure.timeout);
      adapter.checkError = null;
      adapter.version = '2.0.0-beta';
      await controller.check();
      expect(controller.checkPhase, UpdateCheckPhase.failed);
      expect(controller.checkFailure, UpdateCheckFailure.invalidResponse);
      expect(controller.release, isNull);
    },
  );
  test('a reentrant listener cannot create duplicate checks', () async {
    var joined = false;
    controller.addListener(() {
      if (!joined && controller.checkPhase == UpdateCheckPhase.checking) {
        joined = true;
        unawaited(controller.check());
      }
    });
    await controller.checkAtStartup();
    expect(adapter.checks, 1);
    expect(controller.manualCheck, isTrue);
  });
  for (final (status, failure) in [
    (404, UpdateCheckFailure.noRelease),
    (403, UpdateCheckFailure.rateLimited),
    (429, UpdateCheckFailure.rateLimited),
    (500, UpdateCheckFailure.network),
  ]) {
    test(
      'check HTTP $status stays failure, silent auto intent and retry',
      () async {
        adapter.status = status;
        await controller.checkAtStartup();
        expect(controller.checkPhase, UpdateCheckPhase.failed);
        expect(controller.checkFailure, failure);
        expect(controller.manualCheck, isFalse);
        expect(controller.pendingAutomaticRelease, isNull);
        adapter.status = 200;
        adapter.version = '1.0.0+999';
        await controller.check();
        expect(controller.manualCheck, isTrue);
        expect(controller.checkPhase, UpdateCheckPhase.current);
        await controller.startDownload();
        expect(adapter.downloads, 0);
      },
    );
  }
  test(
    'platform detection failure keeps the Release action and cannot download',
    () async {
      platform.failCapabilities = true;
      await controller.check();
      expect(controller.selection?.issue, UpdateAssetIssue.unknownArchitecture);
      expect(controller.checkPhase, UpdateCheckPhase.available);
      await controller.startDownload();
      expect(adapter.downloads, 0);
      platform.result = const UpdateActionResult(
        UpdateActionStatus.failed,
        failure: UpdateActionFailure.unavailable,
      );
      await controller.openRelease();
      expect(controller.releaseAction?.status, UpdateActionStatus.failed);
      platform.result = const UpdateActionResult(UpdateActionStatus.handedOff);
      await controller.openRelease();
      expect(platform.opens, 2);
      expect(controller.releaseAction?.status, UpdateActionStatus.handedOff);
    },
  );
  test(
    'checking a newer candidate cannot mutate an in-flight download',
    () async {
      await controller.check();
      final original = controller.release;
      final gate = Completer<void>();
      adapter.downloadGate = gate.future;
      adapter.downloadStarted = Completer<void>();
      final download = controller.startDownload();
      await adapter.downloadStarted!.future;
      adapter.version = '3.0.0';
      await controller.check();
      await controller.startDownload();
      expect(adapter.downloads, 1);
      expect(controller.release?.version.toString(), '3.0.0');
      expect(controller.download.release, same(original));
      gate.complete();
      await download;
      expect(controller.download.phase, UpdateDownloadPhase.ready);
      expect(controller.download.verified?.release, same(original));
      expect(adapter.requests.last.uri.path, endsWith('/v2.0.0/SHA256SUMS'));
      expect(platform.installs, 0);
    },
  );
  test('cancelled generation cannot overwrite retry, retry retains original version', () async {
    await controller.check();
    final gate = Completer<void>();
    adapter.downloadGate = gate.future;
    adapter.downloadStarted = Completer<void>();
    final old = controller.startDownload();
    await adapter.downloadStarted!.future;
    controller.cancelDownload();
    expect(controller.download.phase, UpdateDownloadPhase.cancelled);
    adapter.version = '3.0.0';
    await controller.check();
    adapter.downloadGate = null;
    final retry = controller.retryDownload();
    gate.complete();
    await Future.wait([old, retry]);
    expect(controller.download.phase, UpdateDownloadPhase.ready);
    expect(controller.download.release?.version.toString(), '2.0.0');
    expect(adapter.downloads, 2);
    expect((await root.list().toList()), hasLength(1));
  });
  test(
    'install rehashes the actual ready file and rejects changed bytes',
    () async {
      await controller.check();
      await controller.startDownload();
      expect(controller.download.phase, UpdateDownloadPhase.ready);
      await controller.download.verified!.file.writeAsString('abd');
      await controller.install();
      expect(platform.installs, 0);
      expect(controller.download.phase, UpdateDownloadPhase.failed);
      expect(controller.download.failure, UpdateDownloadFailure.checksum);
      expect(
        controller.installAction?.failure,
        UpdateActionFailure.invalidFile,
      );
      await controller.retryDownload();
      await controller.install();
      expect(platform.installs, 1);
      expect(controller.installAction?.status, UpdateActionStatus.handedOff);
    },
  );
  test(
    'permission is a separate explicit action and install must be retried',
    () async {
      await controller.check();
      await controller.startDownload();
      platform.result = const UpdateActionResult(
        UpdateActionStatus.permissionRequired,
      );
      await controller.install();
      expect(platform.permissions, 0);
      await controller.requestInstallPermission();
      expect(platform.permissions, 1);
      expect(platform.installs, 1);
      platform.result = const UpdateActionResult(UpdateActionStatus.handedOff);
      await controller.install();
      expect(platform.installs, 2);
    },
  );
}
