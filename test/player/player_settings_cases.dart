import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/player/player_settings.dart';

void main() {
  test('concurrent stores merge and readers only see complete JSON', () async {
    final directory = await Directory.systemTemp.createTemp(
      'rillight-settings-atomic-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/settings.json');
    await file.writeAsString('{"futureField":true,"volume":0}');
    final writes = [
      for (var i = 0; i < 20; i++)
        FilePlayerSettingsStore(file).write(
          i.isEven
              ? PlayerSettings(volume: i)
              : PlayerSettings(diskCacheLimitMiB: 128 + i),
        ),
    ];
    final writing = Future.wait(writes);
    for (var i = 0; i < 20; i++) {
      final current = await FilePlayerSettingsStore(file).read();
      expect(current.volume, inInclusiveRange(0, 18));
    }
    await writing;
    final result = jsonDecode(await file.readAsString()) as Map;
    expect(result['volume'], 18);
    expect(result['diskCacheLimitMiB'], 147);
    expect(result['futureField'], isTrue);
  });
  test('memory store keeps the last written volume', () async {
    final store = MemoryPlayerSettingsStore();
    await store.write(const PlayerSettings(volume: 42));
    expect((await store.read()).volume, 42);
  });

  test('file store round-trips volume', () async {
    final file = File(
      '${Directory.systemTemp.path}/rillight-player-settings-test.json',
    );
    addTearDown(() {
      if (file.existsSync()) {
        file.deleteSync();
      }
    });
    final store = FilePlayerSettingsStore(file);
    await store.write(const PlayerSettings(volume: 7));
    expect((await FilePlayerSettingsStore(file).read()).volume, 7);
  });

  test('series preference keeps missing subtitle as unspecified, not off', () {
    final preference = PlayerSeriesPreference.fromJson(const {
      'maxStreamingBitrate': 4000000,
      'audioStreamIndex': 1,
    });
    expect(preference.subtitleOff, isFalse);
    expect(preference.subtitleStreamIndex, isNull);
    expect(preference.toJson().containsKey('subtitleOff'), isFalse);
  });

  test('series preference round-trips subtitleOff and language', () {
    const preference = PlayerSeriesPreference(
      subtitleOff: true,
      subtitleLanguage: 'chi',
      subtitleTitle: '中文',
      maxStreamingBitrate: 8000000,
    );
    final decoded = PlayerSeriesPreference.fromJson(preference.toJson());
    expect(decoded.subtitleOff, isTrue);
    expect(decoded.subtitleLanguage, 'chi');
    expect(decoded.subtitleTitle, '中文');
    expect(decoded.maxStreamingBitrate, 8000000);
  });

  test('series preference round-trips mediaSourceName', () {
    final preference = PlayerSeriesPreference.fromJson(const {
      'mediaSourceName': '4K 版本',
      'audioStreamIndex': 2,
    });
    expect(preference.mediaSourceName, '4K 版本');
    expect(preference.audioStreamIndex, 2);
    expect(preference.toJson()['mediaSourceName'], '4K 版本');
  });

  test('fromJson clamps out of range values', () {
    expect(PlayerSettings.fromJson({'volume': 140}).volume, 140);
    expect(
      PlayerSettings.fromJson({'volume': 200}).volume,
      PlayerSettings.volumeMax,
    );
    expect(PlayerSettings.fromJson({'volume': -3}).volume, 0);
  });

  test('legacy volume-only file keeps new fields unset', () {
    final settings = PlayerSettings.fromJson({'volume': 42});
    expect(settings.volume, 42);
    expect(settings.diskCacheLimitMiB, isNull);
    expect(settings.hardwareDecoding, isNull);
    expect(settings.hardwareDecoder, isNull);
  });

  test('file store round-trips playback settings', () async {
    final file = File(
      '${Directory.systemTemp.path}/rillight-player-settings-new.json',
    );
    addTearDown(() {
      if (file.existsSync()) {
        file.deleteSync();
      }
    });
    await FilePlayerSettingsStore(file).write(
      const PlayerSettings(
        volume: 55,
        diskCacheLimitMiB: 4096,
        hardwareDecoding: HardwareDecodingMode.on,
        hardwareDecoder: HardwareDecoderBackend.nvdec,
      ),
    );
    final settings = await FilePlayerSettingsStore(file).read();
    expect(settings.volume, 55);
    expect(settings.diskCacheLimitMiB, 4096);
    expect(settings.hardwareDecoding, HardwareDecodingMode.on);
    expect(settings.hardwareDecoder, HardwareDecoderBackend.nvdec);
  });

  test('fromJson tolerates invalid playback fields', () {
    final settings = PlayerSettings.fromJson({
      'volume': 30,
      'diskCacheLimitMiB': 'not-a-number',
      'hardwareDecoding': 'unknown-mode',
      'hardwareDecoder': 7,
    });
    expect(settings.volume, 30);
    expect(settings.diskCacheLimitMiB, isNull);
    expect(settings.hardwareDecoding, isNull);
    expect(settings.hardwareDecoder, isNull);
  });

  test('file store read tolerates garbage content', () async {
    final file = File(
      '${Directory.systemTemp.path}/rillight-player-settings-garbage.json',
    );
    addTearDown(() {
      if (file.existsSync()) {
        file.deleteSync();
      }
    });
    await file.writeAsString('not json');
    final settings = await FilePlayerSettingsStore(file).read();
    // 未设置音量:读取回落默认 100,且字段保持未设置。
    expect(settings.volume, isNull);
    expect(settings.clampedVolume, 100);
    expect(settings.diskCacheLimitMiB, isNull);
  });

  test('unset volume is omitted from toJson and defaults to 100 on read', () {
    const settings = PlayerSettings(danmakuEnabled: true);
    expect(settings.volume, isNull);
    expect(settings.clampedVolume, 100);
    expect(settings.toJson().containsKey('volume'), isFalse);
    expect(PlayerSettings.fromJson(const <String, dynamic>{}).volume, isNull);
  });

  test('danmaku partial write does not clear stored volume', () async {
    final file = File(
      '${Directory.systemTemp.path}/rillight-player-settings-danmaku.json',
    );
    addTearDown(() {
      if (file.existsSync()) {
        file.deleteSync();
      }
    });
    final store = FilePlayerSettingsStore(file);
    await store.write(const PlayerSettings(volume: 42));
    // 弹幕控制器的部分写:只携带弹幕字段,音量不清。
    await store.write(
      const PlayerSettings(danmakuEnabled: false, danmakuToken: 'secret'),
    );
    final settings = await store.read();
    expect(settings.volume, 42);
    expect(settings.danmakuEnabled, isFalse);
    expect(settings.danmakuToken, 'secret');
  });

  test('volume write does not clear stored danmaku config', () async {
    final file = File(
      '${Directory.systemTemp.path}/rillight-player-settings-volume.json',
    );
    addTearDown(() {
      if (file.existsSync()) {
        file.deleteSync();
      }
    });
    final store = FilePlayerSettingsStore(file);
    await store.write(
      const PlayerSettings(
        danmakuEnabled: true,
        danmakuServer: 'https://dan.example.com',
        danmakuToken: 'secret',
      ),
    );
    // 播放器控制器只写音量/倍速:弹幕配置不清。
    await store.write(const PlayerSettings(volume: 61, playbackRate: 1.5));
    final settings = await store.read();
    expect(settings.volume, 61);
    expect(settings.playbackRate, 1.5);
    expect(settings.danmakuEnabled, isTrue);
    expect(settings.danmakuServer, 'https://dan.example.com');
    expect(settings.danmakuToken, 'secret');
  });

  test('volume-only write keeps other stored fields (merged write)', () async {
    final file = File(
      '${Directory.systemTemp.path}/rillight-player-settings-merge.json',
    );
    addTearDown(() {
      if (file.existsSync()) {
        file.deleteSync();
      }
    });
    final store = FilePlayerSettingsStore(file);
    await store.write(
      const PlayerSettings(
        volume: 60,
        diskCacheLimitMiB: 8192,
        hardwareDecoding: HardwareDecodingMode.off,
        hardwareDecoder: HardwareDecoderBackend.d3d11va,
      ),
    );
    // 播放进程只持久化音量:不得清掉其他字段与未知字段。
    await store.write(const PlayerSettings(volume: 61));

    final settings = await store.read();
    expect(settings.volume, 61);
    expect(settings.diskCacheLimitMiB, 8192);
    expect(settings.hardwareDecoding, HardwareDecodingMode.off);
    expect(settings.hardwareDecoder, HardwareDecoderBackend.d3d11va);

    final raw = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    expect(raw['volume'], 61);
    expect(raw['diskCacheLimitMiB'], 8192);
  });

  test('merged write keeps unknown fields for future readers', () async {
    final file = File(
      '${Directory.systemTemp.path}/rillight-player-settings-unknown.json',
    );
    addTearDown(() {
      if (file.existsSync()) {
        file.deleteSync();
      }
    });
    await file.writeAsString(
      const JsonEncoder.withIndent(
        '  ',
      ).convert({'volume': 10, 'danmakuServer': 'https://api.example.com'}),
    );
    await FilePlayerSettingsStore(file).write(const PlayerSettings(volume: 11));
    final raw = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    expect(raw['volume'], 11);
    expect(raw['danmakuServer'], 'https://api.example.com');
  });
}
