import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:win32/win32.dart';

import 'update_download.dart';
import 'update_platform_contract.dart';
import 'update_service.dart';

/// The injectable boundary is OS operations only; candidate and file validation
/// always run in the production adapter, including when the OS is faked.
class SystemUpdatePlatform implements UpdatePlatform {
  SystemUpdatePlatform({
    UpdateOperatingSystem? system,
    String? runningAbi,
    this.channel = const MethodChannel('com.rillight/updates'),
    Future<bool> Function(Uri)? openWeb,
    Future<ProcessResult> Function(String, List<String>)? runProcess,
    Future<UpdateActionResult> Function(String)? openWindows,
  }) : _system = system ?? _hostSystem(),
       _runningAbi = runningAbi ?? Abi.current().toString(),
       _openWeb = openWeb ?? _launchWeb,
       _runProcess = runProcess ?? _run,
       _openWindows = openWindows ?? _launchWindows;

  final UpdateOperatingSystem _system;
  final String _runningAbi;
  final MethodChannel channel;
  final Future<bool> Function(Uri) _openWeb;
  final Future<ProcessResult> Function(String, List<String>) _runProcess;
  final Future<UpdateActionResult> Function(String) _openWindows;

  static UpdateOperatingSystem _hostSystem() =>
      switch (Platform.operatingSystem) {
        'windows' => UpdateOperatingSystem.windows,
        'macos' => UpdateOperatingSystem.macos,
        'linux' => UpdateOperatingSystem.linux,
        'android' => UpdateOperatingSystem.android,
        _ => UpdateOperatingSystem.unsupported,
      };

  static Future<bool> _launchWeb(Uri uri) =>
      launchUrl(uri, mode: LaunchMode.externalApplication);
  static Future<ProcessResult> _run(String executable, List<String> args) =>
      Process.run(executable, args, runInShell: false);

  @override
  Future<UpdateCapabilities> capabilities() async {
    // Abi.current reports the process ABI, including Rosetta/WOW emulation.
    final prefix = '${_system.name}_';
    final arch = _runningAbi.startsWith(prefix)
        ? normalizeUpdateArchitecture(_runningAbi.substring(prefix.length))
        : null;
    var abis = <String>[];
    var deb = false;
    try {
      if (_system == UpdateOperatingSystem.android) {
        final response = await channel.invokeMapMethod<String, dynamic>(
          'capabilities',
        );
        abis = (response?['abis'] as List? ?? []).whereType<String>().toList();
        // Never advertise an ABI this running app cannot execute.
        abis = abis
            .where((abi) => normalizeUpdateArchitecture(abi) == arch)
            .toList();
      } else if (_system == UpdateOperatingSystem.linux) {
        final response = await _runProcess('/usr/bin/dpkg', [
          '--print-architecture',
        ]);
        deb =
            response.exitCode == 0 &&
            normalizeUpdateArchitecture(response.stdout.toString().trim()) ==
                arch &&
            arch != null;
      }
    } catch (_) {
      // Unknown capabilities must not produce an inferred download choice.
    }
    return UpdateCapabilities(
      system: _system,
      architecture: arch,
      androidAbis: abis,
      supportsDeb: deb,
    );
  }

  @override
  Future<UpdateActionResult> openRelease(AppRelease release) async {
    if (!release.isOfficial) return _failed(UpdateActionFailure.unavailable);
    try {
      return await _openWeb(release.url)
          ? const UpdateActionResult(UpdateActionStatus.handedOff)
          : _failed(UpdateActionFailure.unavailable);
    } catch (_) {
      return _failed(UpdateActionFailure.systemFailure);
    }
  }

  @override
  Future<UpdateActionResult> install(VerifiedUpdate update) async {
    final selected = selectUpdateAsset(update.release, await capabilities());
    if (selected.asset != update.asset) {
      return _failed(UpdateActionFailure.incompatiblePackage);
    }
    final verifier = UpdateDownloader();
    try {
      if (!await verifier.verify(update) ||
          update.file.uri.pathSegments.last != update.asset.name) {
        return _failed(UpdateActionFailure.invalidFile);
      }
      final path = update.file.absolute.path;
      switch (_system) {
        case UpdateOperatingSystem.windows:
          return await _openWindows(path);
        case UpdateOperatingSystem.android:
        case UpdateOperatingSystem.macos:
          return await _nativeAction('install', {
            'path': path,
            'name': update.asset.name,
            'sha256': update.sha256,
            'length': update.length,
          });
        case UpdateOperatingSystem.linux:
          try {
            final result = await _runProcess('/usr/bin/xdg-open', [path]);
            return UpdateActionResult(
              result.exitCode == 0
                  ? UpdateActionStatus.handedOff
                  : UpdateActionStatus.failed,
              failure: result.exitCode == 0
                  ? null
                  : UpdateActionFailure.unavailable,
              localPath: path,
            );
          } catch (_) {
            return UpdateActionResult(
              UpdateActionStatus.failed,
              failure: UpdateActionFailure.unavailable,
              localPath: path,
            );
          }
        case UpdateOperatingSystem.unsupported:
          return _failed(UpdateActionFailure.unavailable);
      }
    } catch (_) {
      return _failed(UpdateActionFailure.systemFailure);
    } finally {
      verifier.dispose();
    }
  }

  @override
  Future<UpdateActionResult> requestInstallPermission() async =>
      _system == UpdateOperatingSystem.android
      ? _nativeAction('requestInstallPermission')
      : _failed(UpdateActionFailure.unavailable);

  Future<UpdateActionResult> _nativeAction(
    String method, [
    Map<String, Object>? arguments,
  ]) async {
    try {
      final value = await channel.invokeMapMethod<String, dynamic>(
        method,
        arguments,
      );
      final status = switch (value?['status']) {
        'handedOff' => UpdateActionStatus.handedOff,
        'permissionRequired' => UpdateActionStatus.permissionRequired,
        'cancelled' => UpdateActionStatus.cancelled,
        _ => UpdateActionStatus.failed,
      };
      final failure = switch (value?['failure']) {
        'unavailable' => UpdateActionFailure.unavailable,
        'permissionDenied' => UpdateActionFailure.permissionDenied,
        'incompatiblePackage' => UpdateActionFailure.incompatiblePackage,
        'invalidFile' => UpdateActionFailure.invalidFile,
        _ =>
          status == UpdateActionStatus.failed
              ? UpdateActionFailure.systemFailure
              : null,
      };
      return UpdateActionResult(
        status,
        failure: failure,
        localPath: value?['localPath'] as String?,
      );
    } on MissingPluginException {
      return _failed(UpdateActionFailure.unavailable);
    } on PlatformException {
      return _failed(UpdateActionFailure.systemFailure);
    }
  }

  static UpdateActionResult _failed(UpdateActionFailure failure) =>
      UpdateActionResult(UpdateActionStatus.failed, failure: failure);

  static Future<UpdateActionResult> _launchWindows(String path) =>
      Isolate.run(() {
        final com = CoInitializeEx(COINIT_APARTMENTTHREADED);
        try {
          return using((arena) {
            final info = arena<SHELLEXECUTEINFO>();
            info.ref
              ..cbSize = sizeOf<SHELLEXECUTEINFO>()
              // NOASYNC: the worker has no message loop. FLAG_NO_UI suppresses shell
              // error dialogs only; the executable manifest still controls UAC.
              ..fMask = 0x100 | 0x400
              ..lpVerb = 'open'.toPwstr(allocator: arena)
              ..lpFile = path.toPwstr(allocator: arena)
              ..nShow = 1;
            final result = ShellExecuteEx(info);
            if (result.value) {
              return const UpdateActionResult(UpdateActionStatus.handedOff);
            }
            if (result.error == ERROR_CANCELLED) {
              return const UpdateActionResult(UpdateActionStatus.cancelled);
            }
            return _failed(
              result.error == ERROR_ACCESS_DENIED
                  ? UpdateActionFailure.permissionDenied
                  : UpdateActionFailure.systemFailure,
            );
          });
        } finally {
          if (com.isOk) CoUninitialize();
        }
      });
}
