import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight_player/rillight_player.dart';

/// Session cache limits and defaults shared by the settings page and backend.
abstract final class PlayerRuntimeDefaults {
  static const int diskCacheLimitMiB = 2048;
  static const int minDiskCacheLimitMiB = 128;
  static const int maxDiskCacheLimitMiB = 8192;
  static const int bytesPerMiB = 1024 * 1024;
}

class PlayerRuntimeOptions {
  const PlayerRuntimeOptions._();

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

  /// Hardware decode is a preference. The core may fall back to software;
  /// actual hardware use comes only from the current session's native status.
  static CoreHardware coreHardware(
    PlayerSettings settings,
    TargetPlatform platform,
  ) {
    if (settings.hardwareDecoding == HardwareDecodingMode.off) {
      return CoreHardware.software;
    }
    return switch (platform) {
      TargetPlatform.windows => CoreHardware.d3d11,
      TargetPlatform.macOS => CoreHardware.videotoolbox,
      TargetPlatform.linux => CoreHardware.vaapi,
      TargetPlatform.android => CoreHardware.mediacodec,
      _ => CoreHardware.software,
    };
  }

  /// Only backends implemented by the owned core are selectable. The persisted
  /// old NVDEC value is still readable, but resolves to the supported default.
  static List<HardwareDecoderBackend> availableBackends(
    TargetPlatform platform,
  ) {
    return switch (platform) {
      TargetPlatform.windows => const [
        HardwareDecoderBackend.auto,
        HardwareDecoderBackend.d3d11va,
      ],
      TargetPlatform.macOS => const [
        HardwareDecoderBackend.auto,
        HardwareDecoderBackend.videotoolbox,
      ],
      _ => const [HardwareDecoderBackend.auto],
    };
  }

  static bool isBackendApplicable(
    HardwareDecoderBackend backend,
    TargetPlatform platform,
  ) => availableBackends(platform).contains(backend);

  /// Storage merges null fields, so restoring defaults writes explicit values.
  static PlayerSettings defaultSettings({int volume = 100}) {
    return PlayerSettings(
      volume: volume,
      diskCacheLimitMiB: PlayerRuntimeDefaults.diskCacheLimitMiB,
      hardwareDecoding: HardwareDecodingMode.auto,
      hardwareDecoder: HardwareDecoderBackend.auto,
    );
  }
}

/// Session cache root. Legacy files without an ownership record are untouched.
class PlayerDiskCache {
  const PlayerDiskCache._();

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
      // Resolve only the trusted OS temporary ancestor. Links inserted inside
      // the owned cache namespace are rejected by the disk coordinator.
      base = temporary.resolveSymbolicLinksSync();
    } on FileSystemException {
      // Disk failure must not prevent a bounded memory-only playback session.
    }
    return Directory(
      '$base'
      '${Platform.pathSeparator}rillight-player-cache/session-v1',
    );
  }
}
