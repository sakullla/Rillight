import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/player/danmaku/danmaku_layout.dart';
import 'package:rillight/player/danmaku/dandanplay_models.dart';
import 'package:rillight/player/player_settings.dart';

void main() {
  File tempFile(String name) {
    final file = File(
      '${Directory.systemTemp.path}/rillight-danmaku-$name.json',
    );
    addTearDown(() {
      if (file.existsSync()) {
        file.deleteSync();
      }
    });
    return file;
  }

  test('danmaku settings round-trip through the file store', () async {
    final file = tempFile('roundtrip');
    const settings = PlayerSettings(
      danmakuEnabled: false,
      danmakuDisplay: DanmakuDisplaySettings(
        opacity: 0.5,
        fontScale: 1.25,
        speed: 2,
        areaFraction: 0.75,
        maxVisibleCount: 20,
        blockedKeywords: ['广告', 'spam'],
      ),
      danmakuServer: 'https://dan.example.com/ddplay',
      danmakuToken: 'secret',
      danmakuAppId: 'app-id',
      danmakuSeriesMemories: {
        'series-1': DanmakuSeriesMemory(
          animeId: 7,
          animeTitle: 'Show',
          episodeId: 100,
          episodeNumber: 1,
        ),
      },
    );
    await FilePlayerSettingsStore(file).write(settings);
    final loaded = await FilePlayerSettingsStore(file).read();
    expect(loaded.danmakuEnabled, isFalse);
    expect(loaded.isDanmakuEnabled, isFalse);
    expect(loaded.danmakuDisplay!.opacity, 0.5);
    expect(loaded.danmakuDisplay!.fontScale, 1.25);
    expect(loaded.danmakuDisplay!.speed, 2);
    expect(loaded.danmakuDisplay!.areaFraction, 0.75);
    expect(loaded.danmakuDisplay!.maxVisibleCount, 20);
    expect(loaded.danmakuDisplay!.blockedKeywords, ['广告', 'spam']);
    expect(loaded.danmakuServer, 'https://dan.example.com/ddplay');
    expect(loaded.danmakuToken, 'secret');
    expect(loaded.danmakuAppId, 'app-id');
    final memory = loaded.danmakuSeriesMemories['series-1'];
    expect(memory!.animeId, 7);
    expect(memory.episodeId, 100);
    expect(memory.episodeNumber, 1);
  });

  test(
    'missing danmaku fields default to enabled with no custom server',
    () async {
      final loaded = PlayerSettings.fromJson({'volume': 30});
      expect(loaded.isDanmakuEnabled, isTrue);
      expect(loaded.danmakuEnabled, isNull);
      expect(loaded.danmakuDisplay, isNull);
      expect(loaded.danmakuServer, isNull);
      expect(loaded.danmakuAppId, isNull);
      expect(loaded.danmakuSeriesMemories, isEmpty);
    },
  );

  test('garbage danmaku fields fall back to defaults', () {
    final loaded = PlayerSettings.fromJson({
      'danmakuEnabled': 'yes',
      'danmakuDisplay': 'broken',
      'danmakuServer': 42,
      'danmakuSeriesMemories': 'nope',
    });
    expect(loaded.isDanmakuEnabled, isTrue);
    expect(loaded.danmakuDisplay, isNull);
    expect(loaded.danmakuServer, isNull);
    expect(loaded.danmakuSeriesMemories, isEmpty);
  });

  test(
    'merged write keeps danmaku fields when another writer saves volume',
    () async {
      final file = tempFile('merge');
      final store = FilePlayerSettingsStore(file);
      await store.write(
        const PlayerSettings(
          danmakuEnabled: true,
          danmakuServer: 'https://dan.example.com',
          danmakuToken: 'secret',
          danmakuAppId: 'app-id',
          danmakuSeriesMemories: {
            'series-1': DanmakuSeriesMemory(
              animeId: 7,
              animeTitle: 'Show',
              episodeId: 100,
            ),
          },
        ),
      );
      // 播放器控制器只写音量/倍速/按剧轨道记忆。
      await store.write(const PlayerSettings(volume: 61, playbackRate: 1.5));
      final loaded = await store.read();
      expect(loaded.volume, 61);
      expect(loaded.danmakuServer, 'https://dan.example.com');
      expect(loaded.danmakuToken, 'secret');
      expect(loaded.danmakuAppId, 'app-id');
      expect(loaded.danmakuSeriesMemories['series-1']!.episodeId, 100);
    },
  );

  test('danmaku writer keeps unrelated stored fields', () async {
    final file = tempFile('merge-danmaku');
    final store = FilePlayerSettingsStore(file);
    await store.write(
      const PlayerSettings(volume: 42, diskCacheLimitMiB: 4096),
    );
    await store.write(const PlayerSettings(danmakuEnabled: false));
    final loaded = await store.read();
    // 弹幕部分写未携带音量:既有 volume 不被默认值覆盖;
    // 未写入的可选字段(如磁盘缓冲)同样保留。
    expect(loaded.volume, 42);
    expect(loaded.diskCacheLimitMiB, 4096);
    expect(loaded.danmakuEnabled, isFalse);
  });

  test('danmaku-only write keeps a previously stored volume of 42', () async {
    final file = tempFile('merge-danmaku-volume');
    final store = FilePlayerSettingsStore(file);
    // 播放器控制器先写音量 42。
    await store.write(const PlayerSettings(volume: 42));
    // 弹幕控制器的纯弹幕字段写(开关/显示参数/记忆/来源)不携带音量。
    await store.write(
      const PlayerSettings(
        danmakuEnabled: true,
        danmakuDisplay: DanmakuDisplaySettings(opacity: 0.6),
        danmakuSeriesMemories: {
          'series-1': DanmakuSeriesMemory(
            animeId: 7,
            animeTitle: 'Show',
            episodeId: 100,
          ),
        },
      ),
    );
    final loaded = await store.read();
    expect(loaded.volume, 42);
    expect(loaded.danmakuDisplay!.opacity, 0.6);
    expect(loaded.danmakuSeriesMemories['series-1']!.episodeId, 100);
  });
}
