import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:rillight/player/player_settings.dart';

/// 播放器运行时默认值与上下限。
abstract final class PlayerRuntimeDefaults {
  /// 磁盘缓冲容量上限默认 2 GiB。
  static const int diskCacheLimitMiB = 2048;
  static const int minDiskCacheLimitMiB = 128;
  static const int maxDiskCacheLimitMiB = 8192;

  /// 直播/纯转码 HLS 流收敛为 mpv 默认量级的小缓冲。
  static const int hlsDemuxerMaxBytes = 32 * 1024 * 1024;
  static const int hlsDemuxerBackBytes = 10 * 1024 * 1024;
  static const int demuxerMaxBytes = 64 * 1024 * 1024;
  static const int demuxerBackBytes = 16 * 1024 * 1024;

  static const int bytesPerMiB = 1024 * 1024;
}

/// 播放器运行时选项:集中构造独立 libmpv 实例创建前注入的
/// mpv 属性集。
///
/// 属性来源三类:有界内存缓冲、
/// 解码/渲染平台默认(hwdec)、音质链路(audio-exclusive)。
/// 注意不设置 `vo`:自有视频插件以 vo=libmpv 走渲染 API,
/// 外部覆盖 vo 会使内嵌视频输出失效;等比缩放由 mpv 默认 keepaspect 保证。
/// 当前 ANGLE/GL 接入使用 *-copy 兼容路径；后续直接表面互操作需独立验证。
class PlayerRuntimeOptions {
  const PlayerRuntimeOptions._();

  /// 解析生效的磁盘缓冲上限(MiB):未配置用默认值,并夹到上下限。
  static int effectiveDiskCacheLimitMiB(PlayerSettings settings) {
    final raw =
        settings.diskCacheLimitMiB ?? PlayerRuntimeDefaults.diskCacheLimitMiB;
    return raw.clamp(
      PlayerRuntimeDefaults.minDiskCacheLimitMiB,
      PlayerRuntimeDefaults.maxDiskCacheLimitMiB,
    );
  }

  static int effectiveDiskCacheLimitBytes(PlayerSettings settings) =>
      effectiveDiskCacheLimitMiB(settings) * PlayerRuntimeDefaults.bytesPerMiB;

  /// 构造 open 前注入的 mpv 属性集。
  static Map<String, String> build({
    PlayerSettings settings = const PlayerSettings(),
    String? cacheDir,
    TargetPlatform platform = TargetPlatform.windows,
    bool liveOrHlsStream = false,
  }) {
    final properties = <String, String>{
      'cache': 'yes',
      'cache-on-disk': 'no',
      ...bufferProperties(conservative: liveOrHlsStream),
      'cache-pause-initial': 'no',
      'cache-pause-wait': '1',
      // 音质:维持共享模式;scaletempo 用 mpv 默认,不加劣化链路。
      'audio-exclusive': 'no',
      // 100 为原片 0 dB;volume-max 允许滑条超过 100 做增益(与 IINA 默认一致)。
      'volume-max': '${PlayerSettings.volumeMax}',
      // 有 ReplayGain 标签的片子按音轨对齐;无标签则保持原片电平。
      'replaygain': 'track',
      'replaygain-clip': 'no',
    };
    final hwdec = _hardwareDecodingValue(settings, platform);
    if (hwdec != null) {
      properties['hwdec'] = embedHwdec(hwdec);
    }
    return properties;
  }

  static Map<String, String> bufferProperties({required bool conservative}) => {
    'demuxer-max-bytes':
        '${conservative ? PlayerRuntimeDefaults.hlsDemuxerMaxBytes : PlayerRuntimeDefaults.demuxerMaxBytes}',
    'demuxer-max-back-bytes':
        '${conservative ? PlayerRuntimeDefaults.hlsDemuxerBackBytes : PlayerRuntimeDefaults.demuxerBackBytes}',
    'demuxer-readahead-secs': conservative ? '10' : '120',
    'cache-secs': conservative ? '10' : '120',
  };

  /// libmpv 嵌入渲染要把硬解表面 copy 回系统内存再上传纹理。
  static String embedHwdec(String hwdec) {
    if (hwdec == 'no' ||
        hwdec == 'yes' ||
        hwdec.endsWith('-copy') ||
        hwdec.endsWith('-safe')) {
      return hwdec;
    }
    if (hwdec == 'auto') {
      return 'auto-copy';
    }
    return '$hwdec-copy';
  }

  /// 平台默认硬件解码后端:Windows d3d11va、macOS videotoolbox;
  /// Linux 无既定默认,不显式指定以维持 mpv 默认行为。
  /// 写入 mpv 前再经 [embedHwdec] 加上 -copy。
  static String? platformDefaultHwdec(TargetPlatform platform) {
    switch (platform) {
      case TargetPlatform.windows:
        return 'd3d11va';
      case TargetPlatform.macOS:
        return 'videotoolbox';
      default:
        return null;
    }
  }

  /// 当前平台可选的解码后端(含 auto)。
  static List<HardwareDecoderBackend> availableBackends(
    TargetPlatform platform,
  ) {
    switch (platform) {
      case TargetPlatform.windows:
        return const [
          HardwareDecoderBackend.auto,
          HardwareDecoderBackend.d3d11va,
          HardwareDecoderBackend.nvdec,
        ];
      case TargetPlatform.macOS:
        return const [
          HardwareDecoderBackend.auto,
          HardwareDecoderBackend.videotoolbox,
        ];
      default:
        return const [HardwareDecoderBackend.auto];
    }
  }

  static bool isBackendApplicable(
    HardwareDecoderBackend backend,
    TargetPlatform platform,
  ) {
    return availableBackends(platform).contains(backend);
  }

  static String? _hardwareDecodingValue(
    PlayerSettings settings,
    TargetPlatform platform,
  ) {
    final mode = settings.hardwareDecoding ?? HardwareDecodingMode.auto;
    if (mode == HardwareDecodingMode.off) {
      return 'no';
    }
    final backend = settings.hardwareDecoder ?? HardwareDecoderBackend.auto;
    if (backend != HardwareDecoderBackend.auto) {
      return isBackendApplicable(backend, platform)
          ? backend.name
          : platformDefaultHwdec(platform);
    }
    final fallback = platformDefaultHwdec(platform);
    if (fallback != null) {
      return fallback;
    }
    // 平台无既定默认(如 Linux):auto 维持 mpv 默认,显式开启交给 mpv 自选。
    return mode == HardwareDecodingMode.on ? 'auto' : null;
  }

  /// 直播/纯转码 HLS 流:Emby 转码地址路径含 .m3u8。
  static bool isLiveOrHlsStream(Uri url) {
    return url.path.toLowerCase().contains('.m3u8');
  }

  /// 「恢复默认」写入的显式默认设置。
  ///
  /// 设置存储为合并写(null 不覆盖旧值),因此恢复默认必须写显式默认值。
  static PlayerSettings defaultSettings({int volume = 100}) {
    return PlayerSettings(
      volume: volume,
      diskCacheLimitMiB: PlayerRuntimeDefaults.diskCacheLimitMiB,
      hardwareDecoding: HardwareDecodingMode.auto,
      hardwareDecoder: HardwareDecoderBackend.auto,
    );
  }
}

/// 会话缓存根目录。旧 mpv 文件没有归属记录，不能自动删除。
class PlayerDiskCache {
  const PlayerDiskCache._();

  /// 系统临时目录下的专用缓存目录。
  static Directory defaultDirectory() {
    final validation = Platform.environment['RILLIGHT_VALIDATION_DIRECTORY'];
    if (validation != null && validation.isNotEmpty) {
      if (!Directory(validation).isAbsolute) {
        throw ArgumentError('Validation directory must be absolute');
      }
      return Directory('$validation/cache/session-v1');
    }
    final temporary = Directory.systemTemp;
    var base = temporary.path;
    try {
      // The OS temporary base is trusted (for example /var -> /private/var on
      // macOS). Resolve only that base, before appending our owned namespace.
      // Links inserted in rillight-player-cache/session-v1 must still be rejected
      // by the disk coordinator, rather than silently followed here.
      base = temporary.resolveSymbolicLinksSync();
    } on FileSystemException {
      // Preserve the ordinary bounded disk-unavailable fallback when the system
      // directory cannot be resolved. Do not make cache failure an open failure.
    }
    return Directory(
      '$base'
      '${Platform.pathSeparator}rillight-player-cache/session-v1',
    );
  }
}
