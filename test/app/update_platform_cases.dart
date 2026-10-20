import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:rillight/app/updates/update_download.dart';
import 'package:rillight/app/updates/update_platform.dart';
import 'package:rillight/app/updates/update_platform_contract.dart';
import 'package:rillight/app/updates/update_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.rillight/updates');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory temporary;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('update-platform-');
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    await temporary.delete(recursive: true);
  });

  Future<VerifiedUpdate> package(String name) async {
    final asset = ReleaseAsset(
      name: name,
      url: Uri.parse(
        'https://github.com/sakullla/Rillight/releases/download/v2.0.0/$name',
      ),
    );
    final release = AppRelease(
      version: Version.parse('2.0.0'),
      url: Uri.parse(
        'https://github.com/sakullla/Rillight/releases/tag/v2.0.0',
      ),
      assets: [asset],
    );
    final bytes = List.generate(128, (index) => index);
    final file = await File('${temporary.path}${Platform.pathSeparator}$name')
        .writeAsBytes(bytes);
    final hash = (await Sha256().hash(bytes)).bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return VerifiedUpdate(
      release: release,
      asset: asset,
      file: file,
      sha256: hash,
      length: bytes.length,
    );
  }

  test(
    'process ABI is authoritative and unknown values stay unknown',
    () async {
      for (final entry in {
        'windows_x64': 'x64',
        'windows_arm64': 'arm64',
        'windows_ia32': null,
        'linux_x64': null,
        'unknown': null,
      }.entries) {
        final platform = SystemUpdatePlatform(
          system: UpdateOperatingSystem.windows,
          runningAbi: entry.key,
        );
        expect((await platform.capabilities()).architecture, entry.value);
      }
    },
  );

  test(
    'Android only advertises supported ABIs compatible with running app',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'capabilities');
        return {
          'abis': ['arm64-v8a', 'armeabi-v7a', 'x86_64'],
        };
      });
      final platform = SystemUpdatePlatform(
        system: UpdateOperatingSystem.android,
        runningAbi: 'android_arm64',
      );
      expect((await platform.capabilities()).androidAbis, ['arm64-v8a']);
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => throw PlatformException(code: 'unavailable'),
      );
      expect((await platform.capabilities()).androidAbis, isEmpty);
    },
  );

  test(
    'DEB support requires successful dpkg and matching architecture',
    () async {
      for (final output in ['amd64', 'arm64', '']) {
        final platform = SystemUpdatePlatform(
          system: UpdateOperatingSystem.linux,
          runningAbi: 'linux_x64',
          runProcess: (command, args) async {
            expect(command, '/usr/bin/dpkg');
            expect(args, ['--print-architecture']);
            return ProcessResult(1, output.isEmpty ? 1 : 0, output, '');
          },
        );
        expect((await platform.capabilities()).supportsDeb, output == 'amd64');
      }
    },
  );

  test(
    'Release opens exact official candidate and reports rejection/retry',
    () async {
      final update = await package('Rillight-windows-x64-v2.0.0-setup.exe');
      var calls = 0;
      final platform = SystemUpdatePlatform(
        openWeb: (uri) async {
          expect(uri, update.release.url);
          calls++;
          return calls > 1;
        },
      );
      expect(
        (await platform.openRelease(update.release)).failure,
        UpdateActionFailure.unavailable,
      );
      expect(
        (await platform.openRelease(update.release)).status,
        UpdateActionStatus.handedOff,
      );
      final unsafe = AppRelease(
        version: Version.parse('2.0.0'),
        tag: 'v2.0.0',
        url: Uri.parse('https://example.com/v2.0.0'),
      );
      expect(
        (await platform.openRelease(unsafe)).status,
        UpdateActionStatus.failed,
      );
      expect(calls, 2);
    },
  );

  test(
    'Windows dispatch is explicit and file tampering blocks every retry',
    () async {
      final update = await package('Rillight-windows-x64-v2.0.0-setup.exe');
      var calls = 0;
      final platform = SystemUpdatePlatform(
        system: UpdateOperatingSystem.windows,
        runningAbi: 'windows_x64',
        openWindows: (path) async {
          calls++;
          expect(path, update.file.absolute.path);
          return const UpdateActionResult(UpdateActionStatus.cancelled);
        },
      );
      expect(
        (await platform.install(update)).status,
        UpdateActionStatus.cancelled,
      );
      await update.file.writeAsBytes(List.filled(update.length, 0));
      expect(
        (await platform.install(update)).failure,
        UpdateActionFailure.invalidFile,
      );
      expect(calls, 1);
    },
  );

  test('wrong platform package cannot reach installer', () async {
    final update = await package('Rillight-android-arm64-v8a-v2.0.0.apk');
    final platform = SystemUpdatePlatform(
      system: UpdateOperatingSystem.windows,
      runningAbi: 'windows_x64',
      openWindows: (_) async => throw StateError('must not dispatch'),
    );
    expect(
      (await platform.install(update)).failure,
      UpdateActionFailure.incompatiblePackage,
    );
  });

  test('Android permission is a separate gesture and install rechecks native permission', () async {
    final update = await package('Rillight-android-arm64-v8a-v2.0.0.apk');
    final calls = <String>[];
    var permitted = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'capabilities':
          return {
            'abis': ['arm64-v8a'],
          };
        case 'requestInstallPermission':
          permitted = true;
          return {'status': 'handedOff'};
        case 'install':
          expect(call.arguments, {
            'path': update.file.absolute.path,
            'name': update.asset.name,
            'sha256': update.sha256,
            'length': update.length,
          });
          return {'status': permitted ? 'handedOff' : 'permissionRequired'};
      }
      return null;
    });
    final platform = SystemUpdatePlatform(
      system: UpdateOperatingSystem.android,
      runningAbi: 'android_arm64',
    );
    expect(
      (await platform.install(update)).status,
      UpdateActionStatus.permissionRequired,
    );
    expect(calls, ['capabilities', 'install']);
    expect(
      (await platform.requestInstallPermission()).status,
      UpdateActionStatus.handedOff,
    );
    expect(
      (await platform.install(update)).status,
      UpdateActionStatus.handedOff,
    );
    expect(calls, [
      'capabilities',
      'install',
      'requestInstallPermission',
      'capabilities',
      'install',
    ]);
  });

  test('native cancellation, incompatible package, missing handler stay observable', () async {
    final update = await package('Rillight-android-arm64-v8a-v2.0.0.apk');
    final platform = SystemUpdatePlatform(
      system: UpdateOperatingSystem.android,
      runningAbi: 'android_arm64',
    );
    for (final failure in UpdateActionFailure.values) {
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => call.method == 'capabilities'
            ? {
                'abis': ['arm64-v8a'],
              }
            : {'status': 'failed', 'failure': failure.name},
      );
      expect((await platform.install(update)).failure, failure);
    }
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => call.method == 'capabilities'
          ? {
              'abis': ['arm64-v8a'],
            }
          : {'status': 'cancelled'},
    );
    expect(
      (await platform.install(update)).status,
      UpdateActionStatus.cancelled,
    );
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => throw MissingPluginException(),
    );
    expect(
      (await platform.requestInstallPermission()).failure,
      UpdateActionFailure.unavailable,
    );
  });

  test(
    'macOS export receives verified DMG and preserves save cancellation',
    () async {
      final update = await package('Rillight-macos-v2.0.0-arm64-signed.dmg');
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'install');
        expect((call.arguments as Map)['sha256'], update.sha256);
        return {'status': 'cancelled'};
      });
      final platform = SystemUpdatePlatform(
        system: UpdateOperatingSystem.macos,
        runningAbi: 'macos_arm64',
      );
      expect(
        (await platform.install(update)).status,
        UpdateActionStatus.cancelled,
      );
    },
  );

  test(
    'Linux uses argument array and keeps local instructions on open failure',
    () async {
      final update = await package('Rillight-linux-x64-v2.0.0.deb');
      var openCalls = 0;
      final platform = SystemUpdatePlatform(
        system: UpdateOperatingSystem.linux,
        runningAbi: 'linux_x64',
        runProcess: (command, args) async {
          if (command == '/usr/bin/dpkg') {
            return ProcessResult(1, 0, 'amd64\n', '');
          }
          expect(command, '/usr/bin/xdg-open');
          expect(args, [update.file.absolute.path]);
          openCalls++;
          return ProcessResult(2, 4, '', 'no handler');
        },
      );
      final result = await platform.install(update);
      expect(result.status, UpdateActionStatus.failed);
      expect(result.failure, UpdateActionFailure.unavailable);
      expect(result.localPath, update.file.absolute.path);
      expect(openCalls, 1);
    },
  );
}
