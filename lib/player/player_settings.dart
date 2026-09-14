import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:rillight/player/danmaku/danmaku_layout.dart'
    show DanmakuDisplaySettings;
import 'package:rillight/player/danmaku/dandanplay_models.dart'
    show DanmakuSeriesMemory;

/// 硬件解码开关:自动沿用平台默认,开启/关闭为显式指定。
enum HardwareDecodingMode { auto, on, off }

/// 硬件解码后端:auto 走平台默认,其余为 mpv hwdec 值。
enum HardwareDecoderBackend { auto, d3d11va, nvdec, videotoolbox }

/// 按剧(seriesId)记忆的播放偏好:音轨/字幕(含关闭)/码率/片源名/手动片头片尾。
///
/// [subtitleStreamIndex] 为 null 表示该剧字幕处于关闭状态;
/// [mediaSourceName] 按 MediaSource.Name 跨集对齐(源 id 每集不同);
/// [introSkipSeconds]/[outroSkipSeconds] 为无服务器章节标记时的
/// 手动跳过时长(秒),null 表示未设置。
/// 记录存在即视为有效快照,不存在记录时运行时沿用默认逻辑。
class PlayerSeriesPreference {
  const PlayerSeriesPreference({
    this.audioStreamIndex,
    this.subtitleStreamIndex,
    this.maxStreamingBitrate,
    this.mediaSourceName,
    this.introSkipSeconds,
    this.outroSkipSeconds,
  });

  final int? audioStreamIndex;
  final int? subtitleStreamIndex;
  final int? maxStreamingBitrate;
  final String? mediaSourceName;
  final int? introSkipSeconds;
  final int? outroSkipSeconds;

  Map<String, dynamic> toJson() => {
    if (audioStreamIndex != null) 'audioStreamIndex': audioStreamIndex,
    if (subtitleStreamIndex != null) 'subtitleStreamIndex': subtitleStreamIndex,
    if (maxStreamingBitrate != null) 'maxStreamingBitrate': maxStreamingBitrate,
    if (mediaSourceName != null && mediaSourceName!.isNotEmpty)
      'mediaSourceName': mediaSourceName,
    if (introSkipSeconds != null) 'introSkipSeconds': introSkipSeconds,
    if (outroSkipSeconds != null) 'outroSkipSeconds': outroSkipSeconds,
  };

  factory PlayerSeriesPreference.fromJson(Map<String, dynamic> json) {
    return PlayerSeriesPreference(
      audioStreamIndex: _readInt(json['audioStreamIndex']),
      subtitleStreamIndex: _readInt(json['subtitleStreamIndex']),
      maxStreamingBitrate: _readInt(json['maxStreamingBitrate']),
      mediaSourceName: _readString(json['mediaSourceName']),
      introSkipSeconds: _readInt(json['introSkipSeconds']),
      outroSkipSeconds: _readInt(json['outroSkipSeconds']),
    );
  }
}

/// 统一播放器设置(主进程与播放进程共享同一 JSON 文件)。
///
/// 全部字段(含 volume)为可空:null 表示「未配置」,读取时按默认值
/// 解析(volume 100、playbackRate 1.0 等);[toJson] 对未配置字段不输出,
/// [FilePlayerSettingsStore.write] 采用合并写,因此部分写者构造的
/// [PlayerSettings] 只携带自己设置的字段,不会覆盖文件中已有值。
class PlayerSettings {
  const PlayerSettings({
    this.volume,
    this.diskCacheLimitMiB,
    this.hardwareDecoding,
    this.hardwareDecoder,
    this.playbackRate,
    this.seriesPreferences = const {},
    this.danmakuEnabled,
    this.danmakuDisplay,
    this.danmakuServer,
    this.danmakuToken,
    this.danmakuSeriesMemories = const {},
  });

  /// 音量(0–100);null 表示「未配置」,读取回落默认 100。
  final int? volume;

  /// 磁盘缓冲容量上限(MiB)。
  final int? diskCacheLimitMiB;
  final HardwareDecodingMode? hardwareDecoding;
  final HardwareDecoderBackend? hardwareDecoder;

  /// 倍速(0.5–3.0 阶梯内取值);null 表示未配置,恢复默认 1.0。
  final double? playbackRate;

  /// 按剧记忆的音轨/字幕/码率，key 为 seriesId。
  final Map<String, PlayerSeriesPreference> seriesPreferences;

  /// 弹幕开关；null 表示未配置，默认开启。
  final bool? danmakuEnabled;

  bool get isDanmakuEnabled => danmakuEnabled ?? true;

  /// 弹幕显示参数（不透明度/字号/速度/区域/密度/屏蔽词）。
  final DanmakuDisplaySettings? danmakuDisplay;

  /// 自定义 dandanplay 兼容服务基地址（空表示官方直连）。
  final String? danmakuServer;

  /// 自定义服务的访问令牌。
  final String? danmakuToken;

  /// 弹幕按剧匹配记忆，key 为 seriesId。
  final Map<String, DanmakuSeriesMemory> danmakuSeriesMemories;

  int get clampedVolume => (volume ?? 100).clamp(0, 100);

  double get effectivePlaybackRate {
    final value = playbackRate;
    if (value == null) {
      return 1.0;
    }
    if (value < 0.25) {
      return 0.25;
    }
    if (value > 4.0) {
      return 4.0;
    }
    return value;
  }

  Map<String, dynamic> toJson() => {
    if (volume != null) 'volume': clampedVolume,
    if (diskCacheLimitMiB != null) 'diskCacheLimitMiB': diskCacheLimitMiB,
    if (hardwareDecoding != null) 'hardwareDecoding': hardwareDecoding!.name,
    if (hardwareDecoder != null) 'hardwareDecoder': hardwareDecoder!.name,
    if (playbackRate != null) 'playbackRate': playbackRate,
    if (seriesPreferences.isNotEmpty)
      'seriesPreferences': {
        for (final entry in seriesPreferences.entries)
          entry.key: entry.value.toJson(),
      },
    if (danmakuEnabled != null) 'danmakuEnabled': danmakuEnabled,
    if (danmakuDisplay != null) 'danmakuDisplay': danmakuDisplay!.toJson(),
    if (danmakuServer != null) 'danmakuServer': danmakuServer,
    if (danmakuToken != null) 'danmakuToken': danmakuToken,
    if (danmakuSeriesMemories.isNotEmpty)
      'danmakuSeriesMemories': {
        for (final entry in danmakuSeriesMemories.entries)
          entry.key: entry.value.toJson(),
      },
  };

  factory PlayerSettings.fromJson(Map<String, dynamic> json) {
    // 磁盘上已有 volume 值读取后视为已设置(保留);键缺失/不可解析
    // 视为未设置,回落默认且不参与合并写覆盖。
    final raw = json['volume'];
    final value = raw is int
        ? raw
        : raw is num
        ? raw.round()
        : int.tryParse(raw?.toString() ?? '');
    return PlayerSettings(
      volume: value?.clamp(0, 100),
      diskCacheLimitMiB: _readInt(json['diskCacheLimitMiB']),
      hardwareDecoding: _readEnum(
        HardwareDecodingMode.values,
        json['hardwareDecoding'],
      ),
      hardwareDecoder: _readEnum(
        HardwareDecoderBackend.values,
        json['hardwareDecoder'],
      ),
      playbackRate: _readDouble(json['playbackRate']),
      seriesPreferences: _readSeriesPreferences(json['seriesPreferences']),
      danmakuEnabled: json['danmakuEnabled'] is bool
          ? json['danmakuEnabled'] as bool
          : null,
      danmakuDisplay: json['danmakuDisplay'] is Map
          ? DanmakuDisplaySettings.fromJson(
              Map<String, dynamic>.from(json['danmakuDisplay'] as Map),
            )
          : null,
      danmakuServer: json['danmakuServer'] is String
          ? json['danmakuServer'] as String
          : null,
      danmakuToken: json['danmakuToken'] is String
          ? json['danmakuToken'] as String
          : null,
      danmakuSeriesMemories: _readDanmakuMemories(
        json['danmakuSeriesMemories'],
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

String? _readString(dynamic raw) {
  if (raw is String && raw.trim().isNotEmpty) {
    return raw.trim();
  }
  return null;
}

double? _readDouble(dynamic raw) {
  if (raw is num) {
    return raw.toDouble();
  }
  return double.tryParse(raw?.toString() ?? '');
}

Map<String, PlayerSeriesPreference> _readSeriesPreferences(dynamic raw) {
  if (raw is! Map) {
    return const {};
  }
  final result = <String, PlayerSeriesPreference>{};
  for (final entry in raw.entries) {
    if (entry.value is! Map) {
      continue;
    }
    result[entry.key.toString()] = PlayerSeriesPreference.fromJson(
      Map<String, dynamic>.from(entry.value as Map),
    );
  }
  return result;
}

Map<String, DanmakuSeriesMemory> _readDanmakuMemories(dynamic raw) {
  if (raw is! Map) {
    return const {};
  }
  final result = <String, DanmakuSeriesMemory>{};
  for (final entry in raw.entries) {
    if (entry.value is! Map) {
      continue;
    }
    result[entry.key.toString()] = DanmakuSeriesMemory.fromJson(
      Map<String, dynamic>.from(entry.value as Map),
    );
  }
  return result;
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
