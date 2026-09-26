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

class CoreBindings {
  CoreBindings({String? libraryPath})
    : libraryPath = libraryPath ?? defaultLibraryPath,
      _library = DynamicLibrary.open(libraryPath ?? defaultLibraryPath) {
    if (abiVersion() != 8) {
      throw StateError('Unsupported Rillight core ABI ${abiVersion()}');
    }
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
}
