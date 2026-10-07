import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Must match native/core/rillight_core.h. The core owns decoded frames;
/// Dart only reads control snapshots and never transfers video pixels.
final class NativeCoreSnapshot extends Struct {
  @Uint32()
  external int structSize;
  @Uint32()
  external int abiVersion;
  @Uint64()
  external int sessionId;
  @Uint64()
  external int operationId;
  @Uint64()
  external int timelineVersion;
  @Int32()
  external int state;
  @Int32()
  external int ffmpegError;
  @Int32()
  external int videoStreamIndex;
  @Int32()
  external int audioStreamIndex;
  @Int32()
  external int subtitleStreamIndex;
  @Int64()
  external int durationUs;
  @Int64()
  external int positionUs;
  @Int32()
  external int firstVideoFrameReady;
  @Int32()
  external int firstAudioFrameReady;
  @Int32()
  external int sourceEof;
  @Int32()
  external int queuedVideoFrames;
  @Int32()
  external int queuedAudioFrames;
  @Double()
  external double playbackSpeed;
  @Uint32()
  external int preferredHardware;
  @Int32()
  external int allowSoftwareFallback;
  @Int32()
  external int externalSubtitlePending;
  @Int32()
  external int dolbyVisionProfile;
  @Int32()
  external int videoOutputKind;
  @Int32()
  external int audioDelivery;
  @Int32()
  external int audioChannels;
  @Int32()
  external int audioLayout;
  @Int32()
  external int audioAtmos;
  @Int32()
  external int audioCodecId;
  @Int32()
  external int requestedInterpolation;
  @Int32()
  external int effectiveInterpolation;
  @Int32()
  external int requestedAnime4k;
  @Int32()
  external int effectiveAnime4k;
  @Int32()
  external int requestedSuperResolution;
  @Int32()
  external int effectiveSuperResolution;
  @Int32()
  external int requestedDenoise;
  @Int32()
  external int effectiveDenoise;
  @Int32()
  external int requestedSharpen;
  @Int32()
  external int effectiveSharpen;
  @Int32()
  external int doviReconstruction;
  @Int32()
  external int dolbyVisionCompatibility;
}

final class NativeCoreTrack extends Struct {
  @Uint32()
  external int structSize;
  @Int32()
  external int streamIndex;
  @Int32()
  external int type;
  @Int32()
  external int codecId;
  @Array(32)
  external Array<Uint8> codecName;
  @Array(32)
  external Array<Uint8> language;
  @Array(128)
  external Array<Uint8> title;
  @Int32()
  external int isDefault;
  @Int32()
  external int width;
  @Int32()
  external int height;
  @Int32()
  external int sampleRate;
  @Int32()
  external int channels;
  @Uint32()
  external int decoderHardwareCapabilities;
  @Uint32()
  external int actualHardware;
  @Int32()
  external int isExternal;
}

final class NativeSubtitlePresentation extends Struct {
  @Uint32()
  external int structSize;
  @Uint32()
  external int version;
  @Int32()
  external int enabled;
  @Int32()
  external int originalAss;
  @Double()
  external double displayWidth;
  @Double()
  external double displayHeight;
  @Double()
  external double fontSize;
  @Double()
  external double userScale;
  @Double()
  external double safeHorizontal;
  @Double()
  external double safeVertical;
}

final class NativeEnhancementRequest extends Struct {
  @Uint32()
  external int structSize;
  @Int32()
  external int interpolation;
  @Int32()
  external int anime4k;
  @Int32()
  external int superResolution;
  @Int32()
  external int denoise;
  @Int32()
  external int sharpen;
  @Int32()
  external int acceptLeaveNativeDolby;
  @Int32()
  external int displayRefreshHz;
}

final class NativeEnhancementStatus extends Struct {
  @Uint32()
  external int structSize;
  @Int32()
  external int requestedInterpolation;
  @Int32()
  external int effectiveInterpolation;
  @Int32()
  external int requestedAnime4k;
  @Int32()
  external int effectiveAnime4k;
  @Int32()
  external int requestedSuperResolution;
  @Int32()
  external int effectiveSuperResolution;
  @Int32()
  external int requestedDenoise;
  @Int32()
  external int effectiveDenoise;
  @Int32()
  external int requestedSharpen;
  @Int32()
  external int effectiveSharpen;
  @Int32()
  external int reasonInterpolation;
  @Int32()
  external int reasonAnime4k;
  @Int32()
  external int reasonSuperResolution;
  @Int32()
  external int reasonDenoise;
  @Int32()
  external int reasonSharpen;
  @Int32()
  external int interpolationBackend;
  @Int32()
  external int anime4kBackend;
  @Int32()
  external int superResolutionBackend;
  @Int32()
  external int leftNativeDolby;
  @Double()
  external double sourceFrameRate;
  @Double()
  external double outputFrameRate;
}

class CoreBindings {
  CoreBindings({String? libraryPath})
    : libraryPath = libraryPath ?? defaultLibraryPath,
      _library = DynamicLibrary.open(libraryPath ?? defaultLibraryPath) {
    if (abiVersion() != 10) {
      throw StateError('Unsupported Rillight core ABI ${abiVersion()}');
    }
    // ABI 10 is incomplete without its required presentation entry point.
    setSubtitlePresentation;
  }

  static String get defaultLibraryPath {
    final executable = File(Platform.resolvedExecutable);
    if (Platform.isWindows) {
      return '${executable.parent.path}/librillight_core.dll';
    }
    if (Platform.isMacOS) {
      return '${executable.parent.parent.path}/Frameworks/librillight_core.dylib';
    }
    if (Platform.isLinux) {
      final bundled = File('${executable.parent.path}/lib/librillight_core.so');
      return bundled.existsSync() ? bundled.path : 'librillight_core.so';
    }
    throw UnsupportedError('Desktop core bindings require a desktop OS');
  }

  final String libraryPath;
  final DynamicLibrary _library;

  late final abiVersion = _library
      .lookupFunction<Uint32 Function(), int Function()>(
        'rillight_core_abi_version',
      );
  late final createLoopback = _library
      .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
        'rillight_core_create_loopback',
      );
  late final destroyLoopback = _library
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('rillight_core_destroy_loopback');
  late final open = _library
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Utf8>, Uint64),
        int Function(Pointer<Void>, Pointer<Utf8>, int)
      >('rillight_core_open');
  late final openAt = _library
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Utf8>, Int64, Uint64),
        int Function(Pointer<Void>, Pointer<Utf8>, int, int)
      >('rillight_core_open_at');
  late final configureHardware = _library
      .lookupFunction<
        Int32 Function(Pointer<Void>, Int32, Int32),
        int Function(Pointer<Void>, int, int)
      >('rillight_core_configure_hardware');
  late final setPlaying = _library
      .lookupFunction<
        Int32 Function(Pointer<Void>, Int32, Uint64),
        int Function(Pointer<Void>, int, int)
      >('rillight_core_set_playing');
  late final seek = _library
      .lookupFunction<
        Int32 Function(Pointer<Void>, Int64, Uint64),
        int Function(Pointer<Void>, int, int)
      >('rillight_core_seek');
  late final selectAudio = _library
      .lookupFunction<
        Int32 Function(Pointer<Void>, Int32, Uint64),
        int Function(Pointer<Void>, int, int)
      >('rillight_core_select_audio');
  late final setSubtitlePresentation = _library
      .lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Pointer<NativeSubtitlePresentation>,
          Uint64,
        ),
        int Function(Pointer<Void>, Pointer<NativeSubtitlePresentation>, int)
      >('rillight_core_set_subtitle_presentation');
  late final selectSubtitle = _library
      .lookupFunction<
        Int32 Function(Pointer<Void>, Int32, Uint64),
        int Function(Pointer<Void>, int, int)
      >('rillight_core_select_subtitle');
  late final addExternalSubtitle = _library
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Utf8>, Uint64),
        int Function(Pointer<Void>, Pointer<Utf8>, int)
      >('rillight_core_add_external_subtitle');
  late final setSpeed = _library
      .lookupFunction<
        Int32 Function(Pointer<Void>, Double, Uint64),
        int Function(Pointer<Void>, double, int)
      >('rillight_core_set_speed');
  late final setVolume = _library
      .lookupFunction<
        Int32 Function(Pointer<Void>, Double, Uint64),
        int Function(Pointer<Void>, double, int)
      >('rillight_core_set_volume');
  late final snapshot = _library
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<NativeCoreSnapshot>),
        int Function(Pointer<Void>, Pointer<NativeCoreSnapshot>)
      >('rillight_core_snapshot');
  late final int Function(Pointer<Void>, Pointer<Int32>, Pointer<Int32>)?
  containerTrackIds =
      _library.providesSymbol('rillight_core_container_track_ids')
      ? _library.lookupFunction<
          Int32 Function(Pointer<Void>, Pointer<Int32>, Pointer<Int32>),
          int Function(Pointer<Void>, Pointer<Int32>, Pointer<Int32>)
        >('rillight_core_container_track_ids')
      : null;
  late final int Function(Pointer<Utf8>)? hasDecoder =
      _library.providesSymbol('rillight_core_has_decoder')
      ? _library.lookupFunction<
          Int32 Function(Pointer<Utf8>),
          int Function(Pointer<Utf8>)
        >('rillight_core_has_decoder')
      : null;

  bool decoderAvailable(String name) {
    final probe = hasDecoder;
    if (probe == null || name.isEmpty) return false;
    final native = name.toNativeUtf8();
    try {
      return probe(native) == 1;
    } finally {
      malloc.free(native);
    }
  }

  late final trackCount = _library
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('rillight_core_track_count');
  late final getTrack = _library
      .lookupFunction<
        Int32 Function(Pointer<Void>, Int32, Pointer<NativeCoreTrack>),
        int Function(Pointer<Void>, int, Pointer<NativeCoreTrack>)
      >('rillight_core_get_track');
  // Resolved on first use so an older core fails the enhancement command
  // instead of failing library construction.
  late final configureEnhancement = _library
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<NativeEnhancementRequest>),
        int Function(Pointer<Void>, Pointer<NativeEnhancementRequest>)
      >('rillight_core_configure_enhancement');
  late final retryEnhancement = _library
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<NativeEnhancementRequest>),
        int Function(Pointer<Void>, Pointer<NativeEnhancementRequest>)
      >('rillight_core_retry_enhancement');
  late final noteFrameDeadline = _library
      .lookupFunction<
        Int32 Function(Pointer<Void>, Int32, Int64),
        int Function(Pointer<Void>, int, int)
      >('rillight_core_note_frame_deadline');
  late final enhancementStatus = _library
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<NativeEnhancementStatus>),
        int Function(Pointer<Void>, Pointer<NativeEnhancementStatus>)
      >('rillight_core_enhancement_status');
}
