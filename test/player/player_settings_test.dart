import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/player/player_settings.dart';

void main() {
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

  test('fromJson clamps out of range values', () {
    expect(PlayerSettings.fromJson({'volume': 140}).volume, 100);
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
    expect(settings.volume, 100);
    expect(settings.diskCacheLimitMiB, isNull);
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
