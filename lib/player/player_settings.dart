import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:rillight/player/danmaku/danmaku_display_settings.dart'
    show DanmakuDisplaySettings;
import 'package:rillight/player/danmaku/dandanplay_models.dart'
    show DanmakuSeriesMemory;

/// 硬件解码开关:自动沿用平台默认,开启/关闭为显式指定。
enum HardwareDecodingMode { auto, on, off }

/// 硬件解码后端:auto 走平台默认,其余为 mpv hwdec 值。
enum HardwareDecoderBackend { auto, d3d11va, nvdec, videotoolbox }

/// 插帧。JSON 用 `double` 表示两倍,因为 `double` 不能做枚举名。
enum FrameInterpolation { off, doubleRate }

/// Anime4K 档位。light 是 v4.0.1 Mode A (Fast) 2 倍链，strong 是 Mode A (HQ) 2 倍链。
enum Anime4kLevel { off, light, strong }

/// 通用超分。x2 用 realesr-general-x4v3 再降到 2 倍；权重缺失时请求仍可保存，生效保持关闭。
enum SuperResolution { off, x2 }

/// 已保存的增强选择。生效档不在这里,过载或原生杜比可以低于选择。
class VideoEnhancementSelection {
  const VideoEnhancementSelection({
    required this.interpolation,
    required this.anime4k,
    required this.superResolution,
    required this.denoise,
    required this.sharpen,
    required this.acceptLeaveNativeDolby,
  });

  final FrameInterpolation interpolation;
  final Anime4kLevel anime4k;
  final SuperResolution superResolution;
  final int denoise;
  final int sharpen;
  final bool acceptLeaveNativeDolby;

  /// [displayRefreshHz] is the current display. Zero is unknown; the core
  /// then keeps double interpolation inactive. [clearOverload] is playback
  /// retry only. Ordinary repeats omit it so a downgrade can stay.
  Map<String, Object?> toCoreArgs({
    int displayRefreshHz = 0,
    bool clearOverload = false,
  }) => {
    'interpolation': interpolation == FrameInterpolation.doubleRate ? 2 : 0,
    'anime4k': switch (anime4k) {
      Anime4kLevel.off => 0,
      Anime4kLevel.light => 1,
      Anime4kLevel.strong => 2,
    },
    'superResolution': superResolution == SuperResolution.x2 ? 2 : 0,
    'denoise': denoise,
    'sharpen': sharpen,
    'acceptLeaveNativeDolby': acceptLeaveNativeDolby,
    'displayRefreshHz': displayRefreshHz,
    if (clearOverload) 'clearOverload': true,
  };
}

enum PhoneSubtitleSize {
  small(0.85),
  standard(1),
  large(1.25),
  extraLarge(1.5);

  const PhoneSubtitleSize(this.scale);
  final double scale;
}

/// Independent of subtitle track selection and danmaku. Explicit defaults
/// restore the default through the settings store's merge-write contract.
class PhoneSubtitleSettings {
  const PhoneSubtitleSettings({
    this.size = PhoneSubtitleSize.standard,
    this.originalAss = false,
  });
  final PhoneSubtitleSize size;
  final bool originalAss;
  Map<String, dynamic> toJson() => {
    'size': size.name,
    'originalAss': originalAss,
  };
  factory PhoneSubtitleSettings.fromJson(Map<String, dynamic> json) =>
      PhoneSubtitleSettings(
        size:
            _readEnum(PhoneSubtitleSize.values, json['size']) ??
            PhoneSubtitleSize.standard,
        originalAss: json['originalAss'] == true,
      );
}

/// 按剧(seriesId)记忆的播放偏好:音轨/字幕(含关闭)/码率/片源名。
///
/// [subtitleOff] 为 true 才表示用户关闭了字幕;缺省字段只表示未指定,
/// 换集时走默认字幕。轨道序号跨集会变,同时记下语言/标题以便对齐。
/// [mediaSourceName] 按发行组/版本标签跨集对齐(源 id 和文件名每集都不同)。
class PlayerSeriesPreference {
  const PlayerSeriesPreference({
    this.audioStreamIndex,
    this.audioLanguage,
    this.audioTitle,
    this.subtitleStreamIndex,
    this.subtitleLanguage,
    this.subtitleTitle,
    this.subtitleOff = false,
    this.maxStreamingBitrate,
    this.mediaSourceName,
    this.mediaSourceId,
  });

  final int? audioStreamIndex;
  final String? audioLanguage;
  final String? audioTitle;
  final int? subtitleStreamIndex;
  final String? subtitleLanguage;
  final String? subtitleTitle;
  final bool subtitleOff;
  final int? maxStreamingBitrate;
  final String? mediaSourceName;

  /// Exact source for an item preference; never carry this across episodes.
  final String? mediaSourceId;

  /// Only portable intent survives attribution to a different source/episode.
  /// Track numbers are source-specific, even when a legacy series id is unique.
  PlayerSeriesPreference get portableIntent => PlayerSeriesPreference(
    audioLanguage: audioLanguage,
    audioTitle: audioTitle,
    subtitleLanguage: subtitleLanguage,
    subtitleTitle: subtitleTitle,
    subtitleOff: subtitleOff,
    maxStreamingBitrate: maxStreamingBitrate,
    mediaSourceName: mediaSourceName,
  );

  Map<String, dynamic> toJson() => {
    if (audioStreamIndex != null) 'audioStreamIndex': audioStreamIndex,
    if (audioLanguage != null && audioLanguage!.isNotEmpty)
      'audioLanguage': audioLanguage,
    if (audioTitle != null && audioTitle!.isNotEmpty) 'audioTitle': audioTitle,
    if (subtitleStreamIndex != null) 'subtitleStreamIndex': subtitleStreamIndex,
    if (subtitleLanguage != null && subtitleLanguage!.isNotEmpty)
      'subtitleLanguage': subtitleLanguage,
    if (subtitleTitle != null && subtitleTitle!.isNotEmpty)
      'subtitleTitle': subtitleTitle,
    if (subtitleOff) 'subtitleOff': true,
    if (maxStreamingBitrate != null) 'maxStreamingBitrate': maxStreamingBitrate,
    if (mediaSourceName != null && mediaSourceName!.isNotEmpty)
      'mediaSourceName': mediaSourceName,
    if (mediaSourceId != null) 'mediaSourceId': mediaSourceId,
  };

  factory PlayerSeriesPreference.fromJson(Map<String, dynamic> json) {
    return PlayerSeriesPreference(
      audioStreamIndex: _readInt(json['audioStreamIndex']),
      audioLanguage: _readString(json['audioLanguage']),
      audioTitle: _readString(json['audioTitle']),
      subtitleStreamIndex: _readInt(json['subtitleStreamIndex']),
      subtitleLanguage: _readString(json['subtitleLanguage']),
      subtitleTitle: _readString(json['subtitleTitle']),
      subtitleOff: json['subtitleOff'] == true,
      maxStreamingBitrate: _readInt(json['maxStreamingBitrate']),
      mediaSourceName: _readString(json['mediaSourceName']),
      mediaSourceId: _readString(json['mediaSourceId']),
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
    this.phoneSubtitles,
    this.diskCacheLimitMiB,
    this.hardwareDecoding,
    this.hardwareDecoder,
    this.playbackRate,
    this.seriesPreferences = const {},
    this.itemPreferences = const {},
    this.danmakuEnabled,
    this.danmakuDisplay,
    this.danmakuServer,
    this.danmakuToken,
    this.danmakuAppId,
    this.danmakuSeriesMemories = const {},
    this.appearanceStyle,
    this.skipIntroEnabled,
    this.skipOutroEnabled,
    this.frameInterpolation,
    this.anime4k,
    this.superResolution,
    this.denoise,
    this.sharpen,
    this.acceptLeaveNativeDolby,
  });

  /// 音量百分比;100 为原片 0 dB,超过 100 为额外增益。
  /// null 表示「未配置」,读取回落默认 100。
  final PhoneSubtitleSettings? phoneSubtitles;
  PhoneSubtitleSettings get effectivePhoneSubtitles =>
      phoneSubtitles ?? const PhoneSubtitleSettings();

  static const int volumeMax = 150;
  final int? volume;

  /// 磁盘缓冲容量上限(MiB)。
  final int? diskCacheLimitMiB;
  final HardwareDecodingMode? hardwareDecoding;
  final HardwareDecoderBackend? hardwareDecoder;

  /// 倍速(0.5–3.0 阶梯内取值);null 表示未配置,恢复默认 1.0。
  final double? playbackRate;

  /// Legacy single-service compatibility data, keyed by bare seriesId.
  /// Multi-source consumers must not apply or update this map directly: pass
  /// complete uniquely attributed inventory to HistoryWriter.migrateLegacy,
  /// then use that authority's scoped preferences. Global settings stay here.
  final Map<String, PlayerSeriesPreference> seriesPreferences;

  /// Ordinary playback memory keyed by server, account and item identity.
  final Map<String, PlayerSeriesPreference> itemPreferences;

  /// 弹幕开关；null 表示未配置，默认开启。
  final bool? danmakuEnabled;

  bool get isDanmakuEnabled => danmakuEnabled ?? true;

  /// 弹幕显示参数（不透明度/字号/速度/区域/密度/屏蔽词）。
  final DanmakuDisplaySettings? danmakuDisplay;

  /// 自定义 dandanplay 兼容服务基地址（空表示官方直连）。
  final String? danmakuServer;

  /// 自定义服务的访问令牌;官方源时作为 AppSecret。
  final String? danmakuToken;

  /// 官方 dandanplay 开放平台 AppId;自定义源忽略。
  final String? danmakuAppId;

  /// 弹幕按剧匹配记忆，key 为 seriesId。
  final Map<String, DanmakuSeriesMemory> danmakuSeriesMemories;

  /// 外观偏好(浅色/深色/跟随系统的枚举名);null 表示未选择过,
  /// 由应用外壳按深色解析。仅存字符串,播放进程不消费。
  final String? appearanceStyle;

  final bool? skipIntroEnabled;
  final bool? skipOutroEnabled;
  bool get isSkipIntroEnabled => skipIntroEnabled ?? true;
  bool get isSkipOutroEnabled => skipOutroEnabled ?? true;

  /// null 表示未配置,读取为关闭,并且不参与合并写。
  final FrameInterpolation? frameInterpolation;
  final Anime4kLevel? anime4k;
  final SuperResolution? superResolution;
  final int? denoise;
  final int? sharpen;
  final bool? acceptLeaveNativeDolby;

  VideoEnhancementSelection get videoEnhancement {
    final scales = _exclusiveScales(anime4k, superResolution);
    return VideoEnhancementSelection(
      interpolation: frameInterpolation ?? FrameInterpolation.off,
      anime4k: scales.$1,
      superResolution: scales.$2,
      denoise: (denoise ?? 0).clamp(0, 100),
      sharpen: (sharpen ?? 0).clamp(0, 100),
      acceptLeaveNativeDolby: acceptLeaveNativeDolby ?? false,
    );
  }

  PlayerSettings selectingAnime4k(Anime4kLevel value) {
    return _withEnhancement(
      anime4k: value,
      superResolution: value == Anime4kLevel.off
          ? superResolution
          : SuperResolution.off,
    );
  }

  PlayerSettings selectingSuperResolution(SuperResolution value) {
    return _withEnhancement(
      anime4k: value == SuperResolution.off ? anime4k : Anime4kLevel.off,
      superResolution: value,
    );
  }

  PlayerSettings _withEnhancement({
    FrameInterpolation? frameInterpolation,
    Anime4kLevel? anime4k,
    SuperResolution? superResolution,
    int? denoise,
    int? sharpen,
    bool? acceptLeaveNativeDolby,
  }) {
    return PlayerSettings(
      volume: volume,
      phoneSubtitles: phoneSubtitles,
      diskCacheLimitMiB: diskCacheLimitMiB,
      hardwareDecoding: hardwareDecoding,
      hardwareDecoder: hardwareDecoder,
      playbackRate: playbackRate,
      seriesPreferences: seriesPreferences,
      itemPreferences: itemPreferences,
      danmakuEnabled: danmakuEnabled,
      danmakuDisplay: danmakuDisplay,
      danmakuServer: danmakuServer,
      danmakuToken: danmakuToken,
      danmakuAppId: danmakuAppId,
      danmakuSeriesMemories: danmakuSeriesMemories,
      appearanceStyle: appearanceStyle,
      skipIntroEnabled: skipIntroEnabled,
      skipOutroEnabled: skipOutroEnabled,
      frameInterpolation: frameInterpolation ?? this.frameInterpolation,
      anime4k: anime4k ?? this.anime4k,
      superResolution: superResolution ?? this.superResolution,
      denoise: denoise ?? this.denoise,
      sharpen: sharpen ?? this.sharpen,
      acceptLeaveNativeDolby:
          acceptLeaveNativeDolby ?? this.acceptLeaveNativeDolby,
    );
  }

  int get clampedVolume => (volume ?? 100).clamp(0, volumeMax);

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
    if (phoneSubtitles != null) 'phoneSubtitles': phoneSubtitles!.toJson(),
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
    if (itemPreferences.isNotEmpty)
      'itemPreferences': {
        for (final entry in itemPreferences.entries)
          entry.key: entry.value.toJson(),
      },
    if (danmakuEnabled != null) 'danmakuEnabled': danmakuEnabled,
    if (danmakuDisplay != null) 'danmakuDisplay': danmakuDisplay!.toJson(),
    if (danmakuServer != null) 'danmakuServer': danmakuServer,
    if (danmakuToken != null) 'danmakuToken': danmakuToken,
    if (danmakuAppId != null) 'danmakuAppId': danmakuAppId,
    if (danmakuSeriesMemories.isNotEmpty)
      'danmakuSeriesMemories': {
        for (final entry in danmakuSeriesMemories.entries)
          entry.key: entry.value.toJson(),
      },
    if (appearanceStyle != null) 'appearanceStyle': appearanceStyle,
    if (skipIntroEnabled != null) 'skipIntroEnabled': skipIntroEnabled,
    if (skipOutroEnabled != null) 'skipOutroEnabled': skipOutroEnabled,
    if (frameInterpolation != null)
      'frameInterpolation': frameInterpolation == FrameInterpolation.doubleRate
          ? 'double'
          : 'off',
    if (anime4k != null)
      'anime4k':
          anime4k != Anime4kLevel.off &&
              superResolution != null &&
              superResolution != SuperResolution.off
          ? Anime4kLevel.off.name
          : anime4k!.name,
    if (superResolution != null)
      'superResolution':
          superResolution != SuperResolution.off &&
              anime4k != null &&
              anime4k != Anime4kLevel.off
          ? SuperResolution.off.name
          : superResolution!.name,
    if (denoise != null) 'denoise': denoise!.clamp(0, 100),
    if (sharpen != null) 'sharpen': sharpen!.clamp(0, 100),
    if (acceptLeaveNativeDolby != null)
      'acceptLeaveNativeDolby': acceptLeaveNativeDolby,
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
      phoneSubtitles: json['phoneSubtitles'] is Map
          ? PhoneSubtitleSettings.fromJson(
              Map<String, dynamic>.from(json['phoneSubtitles'] as Map),
            )
          : null,
      volume: value?.clamp(0, volumeMax),
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
      skipIntroEnabled: json['skipIntroEnabled'] is bool
          ? json['skipIntroEnabled'] as bool
          : null,
      skipOutroEnabled: json['skipOutroEnabled'] is bool
          ? json['skipOutroEnabled'] as bool
          : null,
      seriesPreferences: _readSeriesPreferences(json['seriesPreferences']),
      itemPreferences: _readSeriesPreferences(json['itemPreferences']),
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
      danmakuAppId: json['danmakuAppId'] is String
          ? json['danmakuAppId'] as String
          : null,
      danmakuSeriesMemories: _readDanmakuMemories(
        json['danmakuSeriesMemories'],
      ),
      appearanceStyle: json['appearanceStyle'] is String
          ? json['appearanceStyle'] as String
          : null,
      frameInterpolation: _readInterpolation(json['frameInterpolation']),
      anime4k: _storedAnime(json),
      superResolution: _storedSuper(json),
      denoise: _readStrength(json['denoise']),
      sharpen: _readStrength(json['sharpen']),
      acceptLeaveNativeDolby: json['acceptLeaveNativeDolby'] is bool
          ? json['acceptLeaveNativeDolby'] as bool
          : null,
    );
  }
}

FrameInterpolation? _readInterpolation(dynamic raw) {
  if (raw == 'off') return FrameInterpolation.off;
  if (raw == 'double') return FrameInterpolation.doubleRate;
  return null;
}

int? _readStrength(dynamic raw) {
  final value = _readInt(raw);
  if (value == null) return null;
  return value.clamp(0, 100);
}

bool _scalesConflict(Anime4kLevel? anime, SuperResolution? superResolution) {
  return anime != null &&
      anime != Anime4kLevel.off &&
      superResolution != null &&
      superResolution != SuperResolution.off;
}

Anime4kLevel? _storedAnime(Map<String, dynamic> json) {
  final anime = _readEnum(Anime4kLevel.values, json['anime4k']);
  final superResolution = _readEnum(
    SuperResolution.values,
    json['superResolution'],
  );
  if (_scalesConflict(anime, superResolution)) return Anime4kLevel.off;
  return anime;
}

SuperResolution? _storedSuper(Map<String, dynamic> json) {
  final anime = _readEnum(Anime4kLevel.values, json['anime4k']);
  final superResolution = _readEnum(
    SuperResolution.values,
    json['superResolution'],
  );
  if (_scalesConflict(anime, superResolution)) return SuperResolution.off;
  return superResolution;
}

(Anime4kLevel, SuperResolution) _exclusiveScales(
  Anime4kLevel? anime,
  SuperResolution? superResolution,
) {
  final animeLevel = anime ?? Anime4kLevel.off;
  final superLevel = superResolution ?? SuperResolution.off;
  if (animeLevel != Anime4kLevel.off && superLevel != SuperResolution.off) {
    return (Anime4kLevel.off, SuperResolution.off);
  }
  return (animeLevel, superLevel);
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

  /// Preserve fields owned by other pages or the active playback process.
  Future<void> writePatch(PlayerSettings patch) async {
    final current = await read();
    await write(
      PlayerSettings.fromJson({...current.toJson(), ...patch.toJson()}),
    );
  }
}

class MemoryPlayerSettingsStore extends PlayerSettingsStore {
  MemoryPlayerSettingsStore([this._value = const PlayerSettings()]);

  PlayerSettings _value;

  @override
  Future<PlayerSettings> read() async => _value;

  @override
  Future<void> write(PlayerSettings settings) async {
    _value = settings;
  }
}

class FilePlayerSettingsStore extends PlayerSettingsStore {
  FilePlayerSettingsStore(this.file);

  final File file;
  static final _writes = <String, Future<void>>{};
  static int _temporaryId = 0;

  @override
  Future<PlayerSettings> read() => _serialize(_readLocked);

  Future<PlayerSettings> _readLocked() async {
    try {
      await file.parent.create(recursive: true);
      final lock = await File('${file.path}.lock').open(mode: FileMode.append);
      var locked = false;
      try {
        await lock.lock(FileLock.blockingShared);
        locked = true;
        if (!await file.exists()) return const PlayerSettings();
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map) {
          return PlayerSettings.fromJson(Map<String, dynamic>.from(decoded));
        }
      } finally {
        if (locked) await lock.unlock();
        await lock.close();
      }
    } catch (_) {}
    return const PlayerSettings();
  }

  /// 合并写:先读文件中已有字段再覆盖本次显式写入的字段。
  ///
  /// 未配置字段(及未来扩展的未知字段)得以保留,双进程以文件为唯一权威,
  /// 避免播放进程只写音量时清掉其他设置;「恢复默认」写入显式默认值即可覆盖。
  @override
  Future<void> write(PlayerSettings settings) =>
      _serialize(() => _writeLocked(settings));

  @override
  Future<void> writePatch(PlayerSettings patch) => write(patch);

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final key = file.absolute.path;
    final previous = _writes[key] ?? Future<void>.value();
    final next = previous.then((_) => operation());
    final settled = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _writes[key] = settled;
    unawaited(
      settled.then((_) {
        if (identical(_writes[key], settled)) _writes.remove(key);
      }),
    );
    return next;
  }

  Future<void> _writeLocked(PlayerSettings settings) async {
    await file.parent.create(recursive: true);
    final lock = await File('${file.path}.lock').open(mode: FileMode.append);
    await lock.lock(FileLock.blockingExclusive);
    final temporary = File('${file.path}.$pid.${++_temporaryId}.tmp');
    try {
      final merged = <String, dynamic>{};
      try {
        if (await file.exists()) {
          final decoded = jsonDecode(await file.readAsString());
          if (decoded is Map) {
            merged.addAll(Map<String, dynamic>.from(decoded));
          }
        }
      } on FormatException {
        // A corrupt JSON file can be repaired; an I/O failure must not turn an
        // unreadable existing configuration into a partial replacement.
      }
      for (final entry in settings.toJson().entries) {
        final existing = merged[entry.key];
        merged[entry.key] = existing is Map && entry.value is Map
            ? {...existing, ...entry.value as Map}
            : entry.value;
      }
      await temporary.writeAsString(
        const JsonEncoder.withIndent('  ').convert(merged),
        flush: true,
      );
      // Windows readers may briefly hold a handle without delete sharing.
      // Retry replacement while retaining the old complete file and lock.
      for (var attempt = 0; ; attempt++) {
        try {
          await temporary.rename(file.path);
          break;
        } on FileSystemException {
          if (!Platform.isWindows || attempt >= 49) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }
    } finally {
      if (await temporary.exists()) await temporary.delete();
      await lock.unlock();
      await lock.close();
    }
  }
}

Future<PlayerSettingsStore> openPlayerSettingsStore() async {
  final validation = Platform.environment['RILLIGHT_VALIDATION_DIRECTORY'];
  if (validation != null && validation.isNotEmpty) {
    if (!Directory(validation).isAbsolute) {
      throw ArgumentError('Validation directory must be absolute');
    }
    return FilePlayerSettingsStore(File('$validation/player_settings.json'));
  }
  try {
    final support = await getApplicationSupportDirectory();
    return FilePlayerSettingsStore(
      File('${support.path}/rillight/player_settings.json'),
    );
  } catch (_) {
    return MemoryPlayerSettingsStore();
  }
}
