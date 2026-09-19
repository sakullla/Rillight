import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/player/danmaku/danmaku_display_settings.dart';
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
        showTop: false,
        colorful: false,
        preventOverlap: false,
        density: DanmakuDensity.dense,
        mergeDuplicates: false,
        outline: false,
        followPlaybackRate: false,
        timeOffset: Duration(milliseconds: 1500),
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
    expect(loaded.danmakuDisplay!.showScroll, isTrue);
    expect(loaded.danmakuDisplay!.showTop, isFalse);
    expect(loaded.danmakuDisplay!.showBottom, isTrue);
    expect(loaded.danmakuDisplay!.colorful, isFalse);
    expect(loaded.danmakuDisplay!.preventOverlap, isFalse);
    expect(loaded.danmakuDisplay!.density, DanmakuDensity.dense);
    expect(loaded.danmakuDisplay!.mergeDuplicates, isFalse);
    expect(loaded.danmakuDisplay!.outline, isFalse);
    expect(loaded.danmakuDisplay!.followPlaybackRate, isFalse);
    expect(
      loaded.danmakuDisplay!.timeOffset,
      const Duration(milliseconds: 1500),
    );
    expect(loaded.danmakuDisplay!.blockedKeywords, ['广告', 'spam']);
    expect(loaded.danmakuDisplay, settings.danmakuDisplay);
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

  group('DanmakuDisplaySettings', () {
    test('const default equals the R7 default set', () {
      const defaults = DanmakuDisplaySettings();
      expect(defaults.opacity, 0.85);
      expect(defaults.fontScale, 1.0);
      expect(defaults.speed, 1.0);
      expect(defaults.areaFraction, 0.5);
      expect(defaults.showScroll, isTrue);
      expect(defaults.showTop, isTrue);
      expect(defaults.showBottom, isTrue);
      expect(defaults.colorful, isTrue);
      expect(defaults.preventOverlap, isTrue);
      expect(defaults.density, DanmakuDensity.auto);
      expect(defaults.mergeDuplicates, isTrue);
      expect(defaults.outline, isTrue);
      expect(defaults.followPlaybackRate, isTrue);
      expect(defaults.timeOffset, Duration.zero);
      expect(defaults.blockedKeywords, isEmpty);
      expect(kDanmakuMergeWindow, const Duration(seconds: 20));
      // 值相等而非引用相等;copyWith() 与 fromJson(toJson()) 保持默认。
      expect(defaults, const DanmakuDisplaySettings());
      expect(defaults.hashCode, const DanmakuDisplaySettings().hashCode);
      expect(defaults.copyWith(), defaults);
      expect(DanmakuDisplaySettings.fromJson(defaults.toJson()), defaults);
      expect(DanmakuDisplaySettings.fromJson(const {}), defaults);
      expect(defaults, isNot(defaults.copyWith(outline: false)));
    });

    test('toJson always emits every field, including empty/false/zero', () {
      final json = const DanmakuDisplaySettings(
        showScroll: false,
        timeOffset: Duration.zero,
        blockedKeywords: [],
      ).toJson();
      expect(json.keys, {
        'opacity',
        'fontScale',
        'speed',
        'areaFraction',
        'showScroll',
        'showTop',
        'showBottom',
        'colorful',
        'preventOverlap',
        'density',
        'mergeDuplicates',
        'outline',
        'followPlaybackRate',
        'timeOffsetMs',
        'blockedKeywords',
      });
      expect(json['showScroll'], isFalse);
      expect(json['timeOffsetMs'], 0);
      expect(json['blockedKeywords'], isEmpty);
      expect(json['density'], 'auto');
    });

    test(
      'legacy json migrates with step snapping and ignores maxVisibleCount',
      () {
        final migrated = DanmakuDisplaySettings.fromJson({
          'opacity': 0.7,
          'fontScale': 1.1,
          'speed': 1.0,
          'areaFraction': 0.6,
          'maxVisibleCount': 30,
          'blockedKeywords': ['a'],
        });
        expect(migrated.opacity, 0.7);
        expect(migrated.fontScale, 1.0);
        expect(migrated.speed, 1.0);
        expect(migrated.areaFraction, 0.5);
        expect(migrated.blockedKeywords, ['a']);
        expect(migrated.toJson().containsKey('maxVisibleCount'), isFalse);
        // 新增项全部为默认。
        expect(
          migrated,
          const DanmakuDisplaySettings(opacity: 0.7, blockedKeywords: ['a']),
        );
      },
    );

    test('fromJson tolerates missing and invalid fields', () {
      final parsed = DanmakuDisplaySettings.fromJson({
        'opacity': 'oops',
        'fontScale': 9,
        'speed': -3,
        'areaFraction': 0,
        'showTop': 'no',
        'density': 'whatever',
        'timeOffsetMs': 120000,
        'blockedKeywords': 'not-a-list',
      });
      expect(parsed.opacity, 0.85);
      expect(parsed.fontScale, 1.5);
      expect(parsed.speed, 0.75);
      expect(parsed.areaFraction, 0.25);
      expect(parsed.showTop, isTrue);
      expect(parsed.density, DanmakuDensity.auto);
      expect(parsed.timeOffset, const Duration(seconds: 60));
      expect(parsed.blockedKeywords, isEmpty);
      expect(
        DanmakuDisplaySettings.fromJson({
          'density': 'unlimited',
          'timeOffsetMs': -90000,
        }),
        const DanmakuDisplaySettings(
          density: DanmakuDensity.unlimited,
          timeOffset: Duration(seconds: -60),
        ),
      );
    });

    test(
      'copyWith clamps opacity/offset, snaps steps, normalizes keywords',
      () {
        const raw = DanmakuDisplaySettings(
          opacity: 3,
          fontScale: 0.1,
          speed: 10,
          areaFraction: 0,
          timeOffset: Duration(minutes: 5),
        );
        final normalized = raw.copyWith(
          blockedKeywords: const [' 剧透 ', 'Spam', '', 'spam', '剧透', '  '],
        );
        expect(normalized.opacity, 1.0);
        expect(normalized.fontScale, 0.75);
        expect(normalized.speed, 2.0);
        expect(normalized.areaFraction, 0.25);
        expect(normalized.timeOffset, const Duration(seconds: 60));
        expect(normalized.blockedKeywords, ['剧透', 'Spam']);
        expect(
          const DanmakuDisplaySettings(opacity: 0).copyWith().opacity,
          0.2,
        );
        expect(raw.copyWith(fontScale: 1.2).fontScale, 1.25);
        expect(raw.copyWith(speed: 1.3).speed, 1.5);
        expect(raw.copyWith(areaFraction: 0.9).areaFraction, 1.0);
        expect(
          raw.copyWith(density: DanmakuDensity.sparse).density,
          DanmakuDensity.sparse,
        );
      },
    );

    test('density lane multipliers follow ADR-1', () {
      expect(DanmakuDensity.auto.laneMultiplier, 2);
      expect(DanmakuDensity.sparse.laneMultiplier, 1);
      expect(DanmakuDensity.dense.laneMultiplier, 4);
      expect(DanmakuDensity.unlimited.laneMultiplier, isNull);
    });
  });

  test('merged write can clear keywords and restore defaults', () async {
    final file = tempFile('merge-clear');
    final store = FilePlayerSettingsStore(file);
    await store.write(const PlayerSettings(volume: 42));
    await store.write(
      const PlayerSettings(
        danmakuDisplay: DanmakuDisplaySettings(
          opacity: 0.5,
          fontScale: 1.5,
          showBottom: false,
          density: DanmakuDensity.unlimited,
          timeOffset: Duration(seconds: 3),
          blockedKeywords: ['剧透', 'spam'],
        ),
      ),
    );
    var loaded = await store.read();
    expect(loaded.danmakuDisplay!.blockedKeywords, ['剧透', 'spam']);
    expect(loaded.danmakuDisplay!.density, DanmakuDensity.unlimited);

    // 先只清空关键词:浅合并下空数组必须落盘覆盖旧值。
    await store.write(
      PlayerSettings(
        danmakuDisplay: loaded.danmakuDisplay!.copyWith(
          blockedKeywords: const [],
        ),
      ),
    );
    loaded = await store.read();
    expect(loaded.danmakuDisplay!.blockedKeywords, isEmpty);
    expect(loaded.danmakuDisplay!.opacity, 0.5);
    expect(loaded.danmakuDisplay!.showBottom, isFalse);

    // 恢复默认:写入 const 默认值即可覆盖全部字段。
    await store.write(
      const PlayerSettings(danmakuDisplay: DanmakuDisplaySettings()),
    );
    loaded = await store.read();
    expect(loaded.danmakuDisplay, const DanmakuDisplaySettings());
    expect(loaded.volume, 42);
  });
}
