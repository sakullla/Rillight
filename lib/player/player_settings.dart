import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class PlayerSettings {
  const PlayerSettings({this.volume = 100});

  final int volume;

  int get clampedVolume => volume.clamp(0, 100);

  Map<String, dynamic> toJson() => {'volume': clampedVolume};

  factory PlayerSettings.fromJson(Map<String, dynamic> json) {
    final raw = json['volume'];
    final value = raw is int
        ? raw
        : raw is num
        ? raw.round()
        : int.tryParse(raw?.toString() ?? '') ?? 100;
    return PlayerSettings(volume: value.clamp(0, 100));
  }
}

abstract class PlayerSettingsStore {
  Future<PlayerSettings> read();

  Future<void> write(PlayerSettings settings);
}

class MemoryPlayerSettingsStore implements PlayerSettingsStore {
  MemoryPlayerSettingsStore([this._value = const PlayerSettings()]);

  PlayerSettings _value;

  @override
  Future<PlayerSettings> read() async => _value;

  @override
  Future<void> write(PlayerSettings settings) async {
    _value = settings;
  }
}

class FilePlayerSettingsStore implements PlayerSettingsStore {
  FilePlayerSettingsStore(this.file);

  final File file;

  @override
  Future<PlayerSettings> read() async {
    try {
      if (!await file.exists()) {
        return const PlayerSettings();
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map) {
        return PlayerSettings.fromJson(Map<String, dynamic>.from(decoded));
      }
    } catch (_) {}
    return const PlayerSettings();
  }

  @override
  Future<void> write(PlayerSettings settings) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(settings.toJson()),
    );
  }
}

Future<PlayerSettingsStore> openPlayerSettingsStore() async {
  try {
    final support = await getApplicationSupportDirectory();
    return FilePlayerSettingsStore(
      File('${support.path}/rillight/player_settings.json'),
    );
  } catch (_) {
    return MemoryPlayerSettingsStore();
  }
}
