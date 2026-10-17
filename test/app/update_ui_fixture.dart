import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:rillight/app/updates/update_controller.dart';
import 'package:rillight/app/updates/update_download.dart';
import 'package:rillight/app/updates/update_platform_contract.dart';
import 'package:rillight/app/updates/update_service.dart';

/// Offline UI/capture fixture. Never opens a transport, file or system installer.
class UpdateUiFixture {
  UpdateUiFixture({
    UpdateOperatingSystem system = UpdateOperatingSystem.windows,
  }) {
    platform = UiUpdatePlatform(system);
    service = UiUpdateService(system);
    downloader = UiUpdateDownloader();
    controller = UpdateController(
      platform: platform,
      service: service,
      downloader: downloader,
    );
  }
  late final UiUpdatePlatform platform;
  late final UiUpdateService service;
  late final UiUpdateDownloader downloader;
  late final UpdateController controller;
  void dispose() => controller.dispose();
}

class UiUpdateService extends UpdateService {
  UiUpdateService(UpdateOperatingSystem system) {
    final name = switch (system) {
      UpdateOperatingSystem.android => 'Rillight-android-arm64-v8a-v99.0.0.apk',
      UpdateOperatingSystem.macos => 'Rillight-macos-v99.0.0-arm64-signed.dmg',
      UpdateOperatingSystem.linux => 'Rillight-linux-x64-v99.0.0.deb',
      _ => 'Rillight-windows-x64-v99.0.0-setup.exe',
    };
    release = AppRelease.fromJson({
      'tag_name': 'v99.0.0',
      'draft': false,
      'prerelease': false,
      'body': '优化播放体验与字幕显示。\n修复已知问题。',
      'assets': [
        for (final name in [name, 'SHA256SUMS'])
          {
            'name': name,
            'browser_download_url':
                'https://github.com/sakullla/Rillight/releases/download/v99.0.0/$name',
          },
      ],
    });
  }
  late AppRelease release;
  Completer<void>? gate;
  Object? failure;
  int calls = 0;
  @override
  Future<AppRelease> check() async {
    calls++;
    await gate?.future;
    if (failure != null) throw failure!;
    return release;
  }
}

class UiUpdatePlatform implements UpdatePlatform {
  UiUpdatePlatform(this.system);
  final UpdateOperatingSystem system;
  bool noPackage = false;
  int opened = 0, installed = 0, authorized = 0;
  UpdateActionResult openResult = const UpdateActionResult(
    UpdateActionStatus.handedOff,
  );
  UpdateActionResult installResult = const UpdateActionResult(
    UpdateActionStatus.handedOff,
  );
  UpdateActionResult permissionResult = const UpdateActionResult(
    UpdateActionStatus.handedOff,
  );
  @override
  Future<UpdateCapabilities> capabilities() async => UpdateCapabilities(
    system: system,
    architecture: noPackage
        ? null
        : (system == UpdateOperatingSystem.android ||
                  system == UpdateOperatingSystem.macos
              ? 'arm64'
              : 'x64'),
    androidAbis: const ['arm64-v8a'],
    supportsDeb: true,
  );
  @override
  Future<UpdateActionResult> openRelease(AppRelease release) async {
    opened++;
    return openResult;
  }

  @override
  Future<UpdateActionResult> install(VerifiedUpdate update) async {
    installed++;
    return installResult;
  }

  @override
  Future<UpdateActionResult> requestInstallPermission() async {
    authorized++;
    return permissionResult;
  }
}

class UiUpdateDownloader extends UpdateDownloader {
  Completer<VerifiedUpdate>? _pending;
  AppRelease? _release;
  ReleaseAsset? _asset;
  UpdateByteProgress? _progress;
  void Function()? _verifying;
  bool intact = true;
  int calls = 0;
  @override
  Future<VerifiedUpdate> download({
    required AppRelease release,
    required ReleaseAsset asset,
    required CancelToken cancelToken,
    required UpdateByteProgress onProgress,
    required void Function() onVerifying,
  }) {
    calls++;
    _release = release;
    _asset = asset;
    _progress = onProgress;
    _verifying = onVerifying;
    final pending = _pending = Completer<VerifiedUpdate>();
    unawaited(
      cancelToken.whenCancel.then((_) {
        if (!pending.isCompleted) {
          pending.completeError(
            const UpdateDownloadException(UpdateDownloadFailure.cancelled),
          );
        }
      }),
    );
    onProgress(0, null);
    return pending.future;
  }

  void progress({int? total = 1024 * 1024 * 100}) =>
      _progress!(1024 * 1024 * 42, total);
  void verifying() => _verifying!();
  void fail(UpdateDownloadFailure failure) =>
      _pending!.completeError(UpdateDownloadException(failure));
  void finish() => _pending!.complete(
    VerifiedUpdate(
      release: _release!,
      asset: _asset!,
      file: File('build/synthetic-updates/${_asset!.name}'),
      sha256: '0' * 64,
      length: 1024 * 1024 * 100,
    ),
  );
  @override
  Future<bool> verify(VerifiedUpdate update) async => intact;
}
