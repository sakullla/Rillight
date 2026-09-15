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

  static const int bytesPerMiB = 1024 * 1024;
}

/// 播放器运行时选项:集中构造 open 前经 NativePlayer.setProperty 注入的
/// mpv 属性集。
///
/// 属性来源三类(ADR-3):网络缓冲(cache-on-disk + 磁盘缓存目录)、
/// 解码/渲染平台默认(hwdec)、音质链路(audio-exclusive)。
/// 注意不设置 `vo`:media_kit 的 VideoController 以 vo=libmpv 走渲染 API,
/// 外部覆盖 vo 会使内嵌视频输出失效;等比缩放由 mpv 默认 keepaspect 保证。
/// 硬解必须用 *-copy:libmpv 纹理吃不到 D3D11/NVDEC/VT 零拷贝表面,
/// 直出会在关键帧或画面尺寸变化时裂屏闪一帧。
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
    required String cacheDir,
    TargetPlatform platform = TargetPlatform.windows,
    bool liveOrHlsStream = false,
  }) {
    final properties = <String, String>{
      'cache': 'yes',
      'cache-on-disk': 'yes',
      'demuxer-cache-dir': cacheDir,
      // 音质:维持共享模式;scaletempo 用 mpv 默认,不加劣化链路。
      'audio-exclusive': 'no',
    };
    if (liveOrHlsStream) {
      properties['demuxer-max-bytes'] =
          '${PlayerRuntimeDefaults.hlsDemuxerMaxBytes}';
      properties['demuxer-back-playback-bytes'] =
          '${PlayerRuntimeDefaults.hlsDemuxerBackBytes}';
    } else {
      final limit = effectiveDiskCacheLimitBytes(settings);
      properties['demuxer-max-bytes'] = '$limit';
      properties['demuxer-back-playback-bytes'] = '${limit ~/ 2}';
    }
    final hwdec = _hardwareDecodingValue(settings, platform);
    if (hwdec != null) {
      properties['hwdec'] = embedHwdec(hwdec);
    }
    return properties;
  }

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

/// mpv 磁盘缓冲目录管理:定位、建目录、按容量上限从最旧文件开始回收。
class PlayerDiskCache {
  const PlayerDiskCache._();

  /// 系统临时目录下的专用缓存目录。
  static Directory defaultDirectory() {
    return Directory(
      '${Directory.systemTemp.path}'
      '${Platform.pathSeparator}rillight-player-cache',
    );
  }

  static Future<void> ensure(Directory dir) async {
    try {
      await dir.create(recursive: true);
    } catch (_) {}
  }

  /// 按容量上限回收:总占用超限时从最旧文件开始删除,尽力而为、不抛错。
  static Future<void> reclaim(Directory dir, int limitBytes) async {
    try {
      final files = <(File, int, DateTime)>[];
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) {
          continue;
        }
        try {
          final stat = await entity.stat();
          files.add((entity, stat.size, stat.modified));
        } catch (_) {}
      }
      var total = files.fold<int>(0, (sum, entry) => sum + entry.$2);
      if (total <= limitBytes) {
        return;
      }
      files.sort((a, b) => a.$3.compareTo(b.$3));
      for (final entry in files) {
        if (total <= limitBytes) {
          break;
        }
        try {
          await entry.$1.delete();
          total -= entry.$2;
        } catch (_) {}
      }
    } catch (_) {}
  }
}
