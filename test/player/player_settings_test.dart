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
}
