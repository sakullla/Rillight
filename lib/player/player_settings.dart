import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 硬件解码开关:自动沿用平台默认,开启/关闭为显式指定。
enum HardwareDecodingMode { auto, on, off }

/// 硬件解码后端:auto 走平台默认,其余为 mpv hwdec 值。
enum HardwareDecoderBackend { auto, d3d11va, nvdec, videotoolbox }

/// 统一播放器设置(主进程与播放进程共享同一 JSON 文件)。
///
/// 除 volume 外的字段为可空:null 表示「未配置」,运行时按默认值解析;
/// [FilePlayerSettingsStore.write] 采用合并写,未配置字段不会覆盖文件中
/// 已有值,因此播放进程只持久化音量时不会清掉主进程写入的其他设置。
class PlayerSettings {
  const PlayerSettings({
    this.volume = 100,
    this.diskCacheLimitMiB,
    this.hardwareDecoding,
    this.hardwareDecoder,
  });

  final int volume;

  /// 磁盘缓冲容量上限(MiB)。
  final int? diskCacheLimitMiB;
  final HardwareDecodingMode? hardwareDecoding;
  final HardwareDecoderBackend? hardwareDecoder;

  int get clampedVolume => volume.clamp(0, 100);

  Map<String, dynamic> toJson() => {
    'volume': clampedVolume,
    if (diskCacheLimitMiB != null) 'diskCacheLimitMiB': diskCacheLimitMiB,
    if (hardwareDecoding != null) 'hardwareDecoding': hardwareDecoding!.name,
    if (hardwareDecoder != null) 'hardwareDecoder': hardwareDecoder!.name,
  };

  factory PlayerSettings.fromJson(Map<String, dynamic> json) {
    final raw = json['volume'];
    final value = raw is int
        ? raw
        : raw is num
        ? raw.round()
        : int.tryParse(raw?.toString() ?? '') ?? 100;
    return PlayerSettings(
      volume: value.clamp(0, 100),
      diskCacheLimitMiB: _readInt(json['diskCacheLimitMiB']),
      hardwareDecoding: _readEnum(
        HardwareDecodingMode.values,
        json['hardwareDecoding'],
      ),
      hardwareDecoder: _readEnum(
        HardwareDecoderBackend.values,
        json['hardwareDecoder'],
      ),
    );
  }
}

int? _readInt(dynamic raw) {
  if (raw is int) {
    return raw;
  }
  if (raw is num) {
    return raw.round();
  }
  return int.tryParse(raw?.toString() ?? '');
}

T? _readEnum<T extends Enum>(List<T> values, dynamic raw) {
  if (raw is! String) {
    return null;
  }
  for (final value in values) {
    if (value.name == raw) {
      return value;
    }
  }
  return null;
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

  /// 合并写:先读文件中已有字段再覆盖本次显式写入的字段。
  ///
  /// 未配置字段(及未来扩展的未知字段)得以保留,双进程以文件为唯一权威,
  /// 避免播放进程只写音量时清掉其他设置;「恢复默认」写入显式默认值即可覆盖。
  @override
  Future<void> write(PlayerSettings settings) async {
    await file.parent.create(recursive: true);
    final merged = <String, dynamic>{};
    try {
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map) {
          merged.addAll(Map<String, dynamic>.from(decoded));
        }
      }
    } catch (_) {}
    merged.addAll(settings.toJson());
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(merged),
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
