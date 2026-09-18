import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/player/player_runtime_options.dart';
import 'package:rillight/player/player_settings.dart';

void main() {
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
    test('enables cache-on-disk with the dedicated cache directory', () {
      final properties = build();
      expect(properties['cache'], 'yes');
      expect(properties['cache-on-disk'], 'yes');
      expect(properties['demuxer-cache-dir'], cacheDir);
    });

    test('allows volume above 100 percent without clipping replaygain', () {
      final properties = build();
      expect(properties['volume-max'], '${PlayerSettings.volumeMax}');
      expect(properties['replaygain'], 'track');
      expect(properties['replaygain-clip'], 'no');
    });

    test('converts the configured disk limit to demuxer byte budgets', () {
      final properties = build(
        settings: const PlayerSettings(diskCacheLimitMiB: 1024),
      );
      expect(properties['demuxer-max-bytes'], '${1024 * 1024 * 1024}');
      expect(
        properties['demuxer-max-back-bytes'],
        '${(1024 * 1024 * 1024) ~/ 2}',
      );
    });

    test('uses the default limit when unset', () {
      final properties = build();
      expect(
        properties['demuxer-max-bytes'],
        '${PlayerRuntimeDefaults.diskCacheLimitMiB * PlayerRuntimeDefaults.bytesPerMiB}',
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
      // 缓冲目录与磁盘缓存仍开启。
      expect(properties['cache-on-disk'], 'yes');
      expect(properties['demuxer-cache-dir'], cacheDir);
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

  group('disk cache reclaiming', () {
    late Directory dir;

    setUp(() async {
      dir = Directory(
        '${Directory.systemTemp.path}/rillight-disk-cache-test-'
        '${DateTime.now().microsecondsSinceEpoch}',
      );
      await dir.create(recursive: true);
    });

    tearDown(() async {
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    });

    Future<File> seed(String name, int bytes, DateTime modified) async {
      final file = File('${dir.path}${Platform.pathSeparator}$name');
      await file.writeAsBytes(List.filled(bytes, 1));
      await file.setLastModifiedSyncSafe(modified);
      return file;
    }

    test('deletes oldest files until the limit is met', () async {
      final oldest = await seed('a.bin', 600, DateTime(2026, 1, 1));
      final middle = await seed('b.bin', 300, DateTime(2026, 1, 2));
      final newest = await seed('c.bin', 300, DateTime(2026, 1, 3));

      // 总占用 1200,上限 800:只删最旧的 a(600) 即回到 600 ≤ 800。
      await PlayerDiskCache.reclaim(dir, 800);

      expect(oldest.existsSync(), isFalse);
      expect(middle.existsSync(), isTrue);
      expect(newest.existsSync(), isTrue);
    });

    test('keeps deleting while still over the limit', () async {
      final oldest = await seed('a.bin', 600, DateTime(2026, 1, 1));
      final middle = await seed('b.bin', 300, DateTime(2026, 1, 2));
      final newest = await seed('c.bin', 300, DateTime(2026, 1, 3));

      // 上限 500:删 a 后仍 600 > 500,需继续删 b。
      await PlayerDiskCache.reclaim(dir, 500);

      expect(oldest.existsSync(), isFalse);
      expect(middle.existsSync(), isFalse);
      expect(newest.existsSync(), isTrue);
    });

    test('keeps everything when under the limit', () async {
      final a = await seed('a.bin', 100, DateTime(2026, 1, 1));
      await seed('b.bin', 100, DateTime(2026, 1, 2));
      await PlayerDiskCache.reclaim(dir, 500);
      expect(a.existsSync(), isTrue);
    });

    test('missing directory does not throw', () async {
      final missing = Directory('${dir.path}/missing');
      await PlayerDiskCache.reclaim(missing, 100);
    });
  });
}

extension on File {
  /// setLastModified 在部分平台对过去时间有限制,失败时忽略(顺序仍由文件名稳定性保证测试)。
  Future<void> setLastModifiedSyncSafe(DateTime value) async {
    try {
      await setLastModified(value);
    } catch (_) {}
  }
}
