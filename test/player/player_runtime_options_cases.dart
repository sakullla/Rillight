import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/player/cache/session_byte_cache.dart';
import 'package:rillight/player/player_runtime_options.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight_player/rillight_player.dart';

void main() {
  group('trusted temporary base and cache ownership', () {
    late Directory sandbox;
    setUp(() async {
      sandbox = await Directory.systemTemp.createTemp(
        'rillight-temp-base-test-',
      );
    });
    tearDown(() async {
      await sandbox.delete(recursive: true);
    });

    Directory cacheUnder(Directory temporary) => IOOverrides.runZoned(
      PlayerDiskCache.defaultDirectory,
      getSystemTempDirectory: () => temporary,
    );

    test(
      'resolves linked OS temporary ancestor and retains disk cleanup',
      () async {
        final actual = await Directory(
          '${sandbox.path}/actual/os-temp',
        ).create(recursive: true);
        final alias = Link('${sandbox.path}/os-alias');
        await _directoryLink(alias, actual.parent);
        final cacheRoot = cacheUnder(Directory('${alias.path}/os-temp'));
        final canonical = actual.resolveSymbolicLinksSync();
        expect(
          cacheRoot.absolute.uri,
          Directory('$canonical/rillight-player-cache/session-v1').absolute.uri,
        );
        final sentinel = File('${actual.path}/unrelated.txt')
          ..writeAsStringSync('preserve');
        final cache = await SessionByteCache.open(
          root: cacheRoot,
          memoryLimitBytes: 0,
          diskLimitBytes: 4096,
        );
        try {
          expect(cache.diagnostics['degradation'], isNull);
          await cache.put(
            resource: 'fixture',
            generation: 1,
            offset: 0,
            bytes: Uint8List.fromList([1, 2, 3, 4]),
          );
          final hit = await cache.read(
            resource: 'fixture',
            generation: 1,
            offset: 0,
          );
          expect(hit?.source, CacheReadSource.disk);
          expect(hit?.bytes, [1, 2, 3, 4]);
        } finally {
          await cache.close();
        }
        expect(cache.diagnostics['cleanup'], 'complete');
        expect(cacheRoot.listSync().whereType<Directory>(), isEmpty);
        expect(sentinel.readAsStringSync(), 'preserve');
      },
    );

    for (final child in [
      'rillight-player-cache',
      'rillight-player-cache/session-v1',
    ]) {
      test('rejects a link inside owned namespace: $child', () async {
        final actual = await Directory('${sandbox.path}/actual').create();
        final foreign = await Directory('${sandbox.path}/foreign').create();
        final sentinel = File('${foreign.path}/unrelated.txt')
          ..writeAsStringSync('preserve');
        final alias = Link('${sandbox.path}/os-alias');
        await _directoryLink(alias, actual);
        final internal = Link('${actual.path}/$child');
        await internal.parent.create(recursive: true);
        await _directoryLink(internal, foreign);
        final cache = await SessionByteCache.open(
          root: cacheUnder(Directory(alias.path)),
          memoryLimitBytes: 4,
          diskLimitBytes: 4096,
        );
        try {
          expect(cache.diagnostics['degradation'], 'disk-unavailable');
          await cache.put(
            resource: 'fixture',
            generation: 1,
            offset: 0,
            bytes: Uint8List.fromList([7]),
          );
          expect(
            (await cache.read(
              resource: 'fixture',
              generation: 1,
              offset: 0,
            ))?.source,
            CacheReadSource.memory,
          );
        } finally {
          await cache.close();
        }
        expect(sentinel.readAsStringSync(), 'preserve');
        expect(foreign.listSync(), hasLength(1));
      });
    }
  });

  test('cache limit stays bounded independently of decode preference', () {
    expect(
      PlayerRuntimeOptions.effectiveDiskCacheLimitMiB(
        const PlayerSettings(diskCacheLimitMiB: 8),
      ),
      PlayerRuntimeDefaults.minDiskCacheLimitMiB,
    );
    expect(
      PlayerRuntimeOptions.effectiveDiskCacheLimitMiB(
        const PlayerSettings(diskCacheLimitMiB: 999999),
      ),
      PlayerRuntimeDefaults.maxDiskCacheLimitMiB,
    );
  });

  test('owned core selects platform hardware and honors explicit off', () {
    const settings = PlayerSettings();
    expect(
      PlayerRuntimeOptions.coreHardware(settings, TargetPlatform.windows),
      CoreHardware.d3d11,
    );
    expect(
      PlayerRuntimeOptions.coreHardware(settings, TargetPlatform.macOS),
      CoreHardware.videotoolbox,
    );
    expect(
      PlayerRuntimeOptions.coreHardware(settings, TargetPlatform.linux),
      CoreHardware.vaapi,
    );
    expect(
      PlayerRuntimeOptions.coreHardware(settings, TargetPlatform.android),
      CoreHardware.mediacodec,
    );
    for (final platform in TargetPlatform.values) {
      expect(
        PlayerRuntimeOptions.coreHardware(
          const PlayerSettings(hardwareDecoding: HardwareDecodingMode.off),
          platform,
        ),
        CoreHardware.software,
      );
    }
  });

  test('retired NVDEC setting is not offered by the owned core', () {
    expect(PlayerRuntimeOptions.availableBackends(TargetPlatform.windows), [
      HardwareDecoderBackend.auto,
      HardwareDecoderBackend.d3d11va,
    ]);
    expect(
      PlayerRuntimeOptions.isBackendApplicable(
        HardwareDecoderBackend.nvdec,
        TargetPlatform.windows,
      ),
      isFalse,
    );
    final restored = PlayerRuntimeOptions.defaultSettings(volume: 42);
    expect(restored.volume, 42);
    expect(restored.hardwareDecoder, HardwareDecoderBackend.auto);
  });
}

Future<void> _directoryLink(Link link, Directory target) async {
  try {
    await link.create(target.path);
  } on FileSystemException catch (error) {
    if (!Platform.isWindows || error.osError?.errorCode != 1314) rethrow;
    String quoted(String value) => "'${value.replaceAll("'", "''")}'";
    final result = await Process.run('powershell', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      'New-Item -ItemType Junction -Path ${quoted(link.path)} -Target ${quoted(target.path)} | Out-Null',
    ]);
    if (result.exitCode != 0) {
      throw StateError('Could not create test junction: ${result.stderr}');
    }
  }
}
