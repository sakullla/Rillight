import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/player/cache/session_byte_cache.dart';
import 'package:rillight/player/player_runtime_options.dart';
import 'package:rillight/player/player_settings.dart';

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
      'resolves a linked OS temporary ancestor and retains disk hits and cleanup',
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
        expect(await alias.target(), isNotEmpty);
      },
    );

    for (final child in [
      'rillight-player-cache',
      'rillight-player-cache/session-v1',
    ]) {
      test('still rejects a link inside the owned namespace: $child', () async {
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

  const cacheDir = '/tmp/rillight-player-cache';

  Map<String, String> build({
    PlayerSettings settings = const PlayerSettings(),
    TargetPlatform platform = TargetPlatform.windows,
    bool liveOrHlsStream = false,
  }) {
    return PlayerRuntimeOptions.build(
      settings: settings,
      cacheDir: cacheDir,
      platform: platform,
      liveOrHlsStream: liveOrHlsStream,
    );
  }

  group('network buffering', () {
    test(
      'keeps native packets in bounded memory and starts without filling',
      () {
        final properties = build();
        expect(properties['cache'], 'yes');
        expect(properties['cache-on-disk'], 'no');
        expect(properties.containsKey('demuxer-cache-dir'), isFalse);
        expect(properties['cache-pause-initial'], 'no');
        expect(properties['cache-pause-wait'], '1');
        expect(properties['demuxer-readahead-secs'], '120');
      },
    );

    test('allows volume above 100 percent without clipping replaygain', () {
      final properties = build();
      expect(properties['volume-max'], '${PlayerSettings.volumeMax}');
      expect(properties['replaygain'], 'track');
      expect(properties['replaygain-clip'], 'no');
    });

    test('disk settings never increase native memory budgets', () {
      final properties = build(
        settings: const PlayerSettings(diskCacheLimitMiB: 1024),
      );
      expect(properties['demuxer-max-bytes'], '${64 * 1024 * 1024}');
      expect(properties['demuxer-max-back-bytes'], '${16 * 1024 * 1024}');
    });

    test('uses the default limit when unset', () {
      final properties = build();
      expect(
        properties['demuxer-max-bytes'],
        '${PlayerRuntimeDefaults.demuxerMaxBytes}',
      );
    });

    test('clamps out-of-range limits into the supported range', () {
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

    test('converges live/transcoded HLS streams to small buffers', () {
      final properties = build(
        settings: const PlayerSettings(diskCacheLimitMiB: 8192),
        liveOrHlsStream: true,
      );
      expect(
        properties['demuxer-max-bytes'],
        '${PlayerRuntimeDefaults.hlsDemuxerMaxBytes}',
      );
      expect(
        properties['demuxer-max-back-bytes'],
        '${PlayerRuntimeDefaults.hlsDemuxerBackBytes}',
      );
      expect(properties['cache-on-disk'], 'no');
      expect(properties['demuxer-readahead-secs'], '10');
    });

    test('detects HLS manifest URLs', () {
      expect(
        PlayerRuntimeOptions.isLiveOrHlsStream(
          Uri.parse('http://emby.test/videos/1/main.m3u8?x=1'),
        ),
        isTrue,
      );
      expect(
        PlayerRuntimeOptions.isLiveOrHlsStream(
          Uri.parse('http://emby.test/videos/1/stream.mkv?static=true'),
        ),
        isFalse,
      );
    });
  });

  group('decoding and rendering platform defaults', () {
    test('windows defaults to d3d11va-copy and never overrides vo', () {
      final properties = build(platform: TargetPlatform.windows);
      expect(properties['hwdec'], 'd3d11va-copy');
      // 自有视频插件依赖 vo=libmpv 渲染,不得覆盖。
      expect(properties.containsKey('vo'), isFalse);
    });

    test('macOS defaults to videotoolbox-copy', () {
      final properties = build(platform: TargetPlatform.macOS);
      expect(properties['hwdec'], 'videotoolbox-copy');
    });

    test('linux auto leaves hwdec to mpv defaults', () {
      final properties = build(platform: TargetPlatform.linux);
      expect(properties.containsKey('hwdec'), isFalse);
    });

    test('explicit off forces hwdec=no on every platform', () {
      for (final platform in TargetPlatform.values) {
        final properties = build(
          settings: const PlayerSettings(
            hardwareDecoding: HardwareDecodingMode.off,
          ),
          platform: platform,
        );
        expect(properties['hwdec'], 'no', reason: '$platform');
      }
    });

    test('explicit backend selection overrides the platform default', () {
      final properties = build(
        settings: const PlayerSettings(
          hardwareDecoding: HardwareDecodingMode.on,
          hardwareDecoder: HardwareDecoderBackend.nvdec,
        ),
        platform: TargetPlatform.windows,
      );
      expect(properties['hwdec'], 'nvdec-copy');
    });

    test('backend not applicable on the platform falls back to default', () {
      // Windows 上选 videotoolbox 属坏数据:回退平台默认而不是注入无效值。
      final properties = build(
        settings: const PlayerSettings(
          hardwareDecoder: HardwareDecoderBackend.videotoolbox,
        ),
        platform: TargetPlatform.windows,
      );
      expect(properties['hwdec'], 'd3d11va-copy');
    });

    test('restore-defaults settings resolve to the platform defaults', () {
      final restored = PlayerRuntimeOptions.defaultSettings(volume: 42);
      expect(restored.volume, 42);
      final properties = build(settings: restored);
      expect(properties['hwdec'], 'd3d11va-copy');
      expect(properties['demuxer-max-bytes'], build()['demuxer-max-bytes']);
    });

    test('embedHwdec does not double-suffix copy or rewrite off', () {
      expect(PlayerRuntimeOptions.embedHwdec('d3d11va'), 'd3d11va-copy');
      expect(PlayerRuntimeOptions.embedHwdec('d3d11va-copy'), 'd3d11va-copy');
      expect(PlayerRuntimeOptions.embedHwdec('auto'), 'auto-copy');
      expect(PlayerRuntimeOptions.embedHwdec('auto-safe'), 'auto-safe');
      expect(PlayerRuntimeOptions.embedHwdec('no'), 'no');
    });
  });

  group('audio chain', () {
    test('keeps shared-mode audio output', () {
      final properties = build();
      expect(properties['audio-exclusive'], 'no');
    });
  });
}

Future<void> _directoryLink(Link link, Directory target) async {
  try {
    await link.create(target.path);
  } on FileSystemException catch (error) {
    if (!Platform.isWindows || error.osError?.errorCode != 1314) rethrow;
    // Windows directory junctions exercise the same link rejection boundary
    // without requiring the optional symbolic-link privilege on the test host.
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
