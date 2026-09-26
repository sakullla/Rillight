import 'dart:async';
import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'core_bindings.dart';
import 'surface_retirement.dart';

class CorePlayerEvent {
  const CorePlayerEvent(this.session, this.kind, this.value);
  final String session;
  final String kind;
  final Object value;
}

class CorePlayerTrack {
  const CorePlayerTrack({
    required this.index,
    required this.type,
    required this.language,
    required this.isExternal,
  });
  final int index;
  final String type;
  final String? language;
  final bool isExternal;

  Map<String, Object?> toChannel() => {
    'index': index,
    'type': type,
    'language': language,
    'external': isExternal,
  };
}

class CorePlayerOpen {
  const CorePlayerOpen({
    required this.url,
    required this.session,
    this.start = Duration.zero,
    this.paused = false,
    this.streams = const [],
  });
  final Uri url;
  final String session;
  final Duration start;
  final bool paused;
  final List<CorePlayerTrack> streams;
}

class _CoreSnapshot {
  const _CoreSnapshot(
    this.state,
    this.ffmpegError,
    this.videoStreamIndex,
    this.audioStreamIndex,
    this.subtitleStreamIndex,
    this.durationUs,
    this.positionUs,
    this.firstVideoFrameReady,
    this.firstAudioFrameReady,
    this.playbackSpeed,
    this.externalSubtitlePending,
    this.timelineVersion,
  );
  final int state;
  final int ffmpegError;
  final int videoStreamIndex;
  final int audioStreamIndex;
  final int subtitleStreamIndex;
  final int durationUs;
  final int positionUs;
  final int firstVideoFrameReady;
  final int firstAudioFrameReady;
  final double playbackSpeed;
  final int externalSubtitlePending;
  final int timelineVersion;
}

abstract class CorePlayer {
  Stream<CorePlayerEvent> get events;
  Future<Map<String, dynamic>> open(CorePlayerOpen request);
  Future<Map<String, dynamic>> command(
    String method, [
    Map<String, Object?> args = const {},
  ]);
  Future<void> stop();
  Future<void> dispose();
  Widget buildView({Key? key});

  static Future<CorePlayer> create({String? libraryPath}) async {
    if (Platform.isAndroid) return AndroidCorePlayer();
    return DesktopCorePlayer.create(libraryPath: libraryPath);
  }
}

/// One Android owner has one mounted TextureView even while media is opening.
class AndroidCorePlayer implements CorePlayer {
  AndroidCorePlayer()
    : owner = 'core-${++_nextOwner}-${DateTime.now().microsecondsSinceEpoch}' {
    _subscription = _nativeEvents.listen((dynamic raw) {
      if (raw is! Map ||
          raw['owner'] != owner ||
          raw['sessionId'] != _session) {
        return;
      }
      final kind = raw['kind'];
      final value = raw['value'];
      if (kind is String && value is Object) {
        _events.add(CorePlayerEvent(_session, kind, value));
      }
    });
  }

  static int _nextOwner = 0;
  static const _channel = MethodChannel('rillight/android_core');
  static const _eventChannel = EventChannel('rillight/android_core/events');
  static final Stream<dynamic> _nativeEvents = _eventChannel
      .receiveBroadcastStream()
      .asBroadcastStream();
  final String owner;
  String _session = '';
  bool _disposed = false;
  final _events = StreamController<CorePlayerEvent>.broadcast();
  late final StreamSubscription<dynamic> _subscription;

  @override
  Stream<CorePlayerEvent> get events => _events.stream;

  @override
  Future<Map<String, dynamic>> open(CorePlayerOpen request) async {
    _session = request.session;
    final result = await _channel.invokeMapMethod<String, dynamic>('open', {
      'owner': owner,
      'sessionId': _session,
      'url': request.url.toString(),
      'start': request.start.inMilliseconds,
      'paused': request.paused,
      'streams': [for (final track in request.streams) track.toChannel()],
    });
    if (_session != request.session) throw StateError('Superseded core open');
    return result ?? const {};
  }

  @override
  Future<Map<String, dynamic>> command(
    String method, [
    Map<String, Object?> args = const {},
  ]) async {
    final session = _session;
    final result = await _channel.invokeMapMethod<String, dynamic>(method, {
      'owner': owner,
      'sessionId': session,
      ...args,
    });
    if (_session != session) throw StateError('Superseded core command');
    return result ?? const {};
  }

  Future<Map<String, dynamic>> capabilities() async =>
      await _channel.invokeMapMethod<String, dynamic>('capabilities') ??
      const {};

  @override
  Future<void> stop() async {
    if (_disposed) return;
    await command('stop');
  }

  @override
  Widget buildView({Key? key}) => AndroidView(
    key: key,
    viewType: 'rillight/android_core/view',
    creationParams: {'owner': owner},
    creationParamsCodec: const StandardMessageCodec(),
  );

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await _channel.invokeMethod<void>('dispose', {
        'owner': owner,
        'sessionId': _session,
      });
    } finally {
      await _subscription.cancel();
      await _events.close();
    }
  }
}

class DesktopCorePlayer implements CorePlayer {
  DesktopCorePlayer._(this._bindings, this._handle, this._textureId);

  static const _channel = MethodChannel('rillight_player');
  final CoreBindings _bindings;
  final Pointer<Void> _handle;
  final int _textureId;
  final _events = StreamController<CorePlayerEvent>.broadcast();
  String _session = '';
  int _operation = 0;
  bool _disposed = false;
  Timer? _poll;
  int _previousPosition = -1;
  int _previousDuration = -1;
  int _previousState = -1;
  int _previousTimeline = -1;

  static Future<DesktopCorePlayer> create({String? libraryPath}) async {
    final bindings = CoreBindings(libraryPath: libraryPath);
    final handle = bindings.createLoopback();
    if (handle == nullptr) throw StateError('Could not create Rillight core');
    try {
      final texture = await _channel.invokeMethod<int>('create', {
        'handle': handle.address,
      });
      if (texture == null) throw StateError('Core texture was not created');
      return DesktopCorePlayer._(bindings, handle, texture);
    } catch (_) {
      // A renderer may have been registered before create reported failure.
      // Keep its core alive if retirement cannot be acknowledged.
      await retireSurface(
        channel: _channel,
        handle: handle.address,
        needsRasterBarrier: Platform.isLinux,
      );
      await _destroyCore((handle.address, bindings.libraryPath));
      rethrow;
    }
  }

  @override
  Stream<CorePlayerEvent> get events => _events.stream;

  @override
  Future<Map<String, dynamic>> open(CorePlayerOpen request) async {
    if (_disposed) throw StateError('Core is disposed');
    _session = request.session;
    _serverStreams = request.streams;
    _poll?.cancel();
    _previousPosition = _previousDuration = _previousState = _previousTimeline =
        -1;
    final url = request.url.toString().toNativeUtf8();
    try {
      _check(_bindings.open(_handle, url, ++_operation), 'open');
    } finally {
      calloc.free(url);
    }
    if (request.paused) {
      _check(_bindings.setPlaying(_handle, 0, ++_operation), 'pause');
    }
    _poll = Timer.periodic(const Duration(milliseconds: 100), (_) => _tick());
    final deadline = DateTime.now().add(const Duration(seconds: 45));
    var seekApplied = request.start <= Duration.zero;
    while (DateTime.now().isBefore(deadline)) {
      if (_disposed || _session != request.session) {
        throw StateError('Superseded core open');
      }
      final snapshot = _readSnapshot();
      if (snapshot.state == 8) {
        throw StateError('Core media open failed (${snapshot.ffmpegError})');
      }
      final videoReady =
          snapshot.videoStreamIndex >= 0 && snapshot.firstVideoFrameReady != 0;
      final audioReady =
          snapshot.videoStreamIndex < 0 &&
          snapshot.audioStreamIndex >= 0 &&
          snapshot.firstAudioFrameReady != 0;
      if (snapshot.state >= 2 &&
          snapshot.state <= 6 &&
          (videoReady || audioReady)) {
        if (!seekApplied) {
          seekApplied = true;
          _check(
            _bindings.seek(_handle, request.start.inMicroseconds, ++_operation),
            'seek',
          );
          await Future<void>.delayed(const Duration(milliseconds: 50));
          continue;
        }
        if (videoReady) {
          final status = await _channel.invokeMapMethod<String, dynamic>(
            'status',
            {'handle': _handle.address},
          );
          final frames = status?['frames'];
          final renderedTimeline = status?['timeline'];
          if (frames is! num ||
              frames.toInt() <= 0 ||
              (renderedTimeline is num &&
                  renderedTimeline.toInt() != snapshot.timelineVersion)) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
            continue;
          }
        }
        return _trackResult(snapshot, request.streams);
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    throw TimeoutException('Core did not render the first frame');
  }

  void _tick() {
    if (_disposed || _session.isEmpty) return;
    final snapshot = _readSnapshot();
    if (snapshot.timelineVersion != _previousTimeline) {
      _previousTimeline = snapshot.timelineVersion;
      _previousPosition = -1;
    }
    final position = snapshot.positionUs ~/ 1000;
    final duration = snapshot.durationUs ~/ 1000;
    if (position != _previousPosition) {
      _previousPosition = position;
      _events.add(CorePlayerEvent(_session, 'position', position));
    }
    if (duration != _previousDuration) {
      _previousDuration = duration;
      _events.add(CorePlayerEvent(_session, 'duration', duration));
    }
    if (snapshot.state != _previousState) {
      _previousState = snapshot.state;
      _events.add(
        CorePlayerEvent(
          _session,
          'buffering',
          snapshot.state == 5 || snapshot.state == 6,
        ),
      );
      _events.add(CorePlayerEvent(_session, 'playing', snapshot.state == 3));
      if (snapshot.state == 7) {
        _events.add(CorePlayerEvent(_session, 'completed', true));
      }
      if (snapshot.state == 8) {
        _events.add(
          CorePlayerEvent(
            _session,
            'error',
            'Core playback failed (${snapshot.ffmpegError})',
          ),
        );
      }
    }
  }

  _CoreSnapshot _readSnapshot() {
    final pointer = calloc<NativeCoreSnapshot>();
    pointer.ref.structSize = sizeOf<NativeCoreSnapshot>();
    try {
      _check(_bindings.snapshot(_handle, pointer), 'snapshot');
      final value = pointer.ref;
      return _CoreSnapshot(
        value.state,
        value.ffmpegError,
        value.videoStreamIndex,
        value.audioStreamIndex,
        value.subtitleStreamIndex,
        value.durationUs,
        value.positionUs,
        value.firstVideoFrameReady,
        value.firstAudioFrameReady,
        value.playbackSpeed,
        value.externalSubtitlePending,
        value.timelineVersion,
      );
    } finally {
      calloc.free(pointer);
    }
  }

  List<CorePlayerTrack> _serverStreams = const [];
  Map<String, dynamic> _trackResult(
    _CoreSnapshot snapshot,
    List<CorePlayerTrack> server,
  ) {
    final native = <int, (int, String?)>{};
    final track = calloc<NativeCoreTrack>();
    try {
      for (
        var ordinal = 0;
        ordinal < _bindings.trackCount(_handle);
        ordinal++
      ) {
        track.ref.structSize = sizeOf<NativeCoreTrack>();
        if (_bindings.getTrack(_handle, ordinal, track) != 0) continue;
        native[track.ref.streamIndex] = (
          track.ref.type,
          _cstring(track.ref.language),
        );
      }
    } finally {
      calloc.free(track);
    }
    final mapped = <int, int>{};
    final used = <int>{};
    for (final item in server.where((item) => !item.isExternal)) {
      final type = switch (item.type) {
        'Video' => 1,
        'Audio' => 2,
        'Subtitle' => 3,
        _ => 0,
      };
      final candidates = native.entries.where(
        (entry) => entry.value.$1 == type && !used.contains(entry.key),
      );
      final exact = candidates
          .where((entry) => entry.key == item.index)
          .firstOrNull;
      final byLanguage = candidates
          .where(
            (entry) => item.language != null && entry.value.$2 == item.language,
          )
          .toList();
      final chosen =
          exact ??
          (byLanguage.length == 1
              ? byLanguage.single
              : candidates.length == 1
              ? candidates.first
              : null);
      if (chosen != null) {
        mapped[item.index] = chosen.key;
        used.add(chosen.key);
      }
    }
    _trackMap = mapped;
    return {
      'audioIndex': mapped.entries
          .where((entry) => entry.value == snapshot.audioStreamIndex)
          .firstOrNull
          ?.key,
      'subtitleIndex': mapped.entries
          .where((entry) => entry.value == snapshot.subtitleStreamIndex)
          .firstOrNull
          ?.key,
      'playableAudio': [
        for (final item in server.where((item) => item.type == 'Audio'))
          if (mapped.containsKey(item.index)) item.index,
      ],
      'rejectedAudio': [
        for (final item in server.where((item) => item.type == 'Audio'))
          if (!mapped.containsKey(item.index)) item.index,
      ],
      'playableSubtitle': [
        for (final item in server.where((item) => item.type == 'Subtitle'))
          if (mapped.containsKey(item.index)) item.index,
      ],
      'rejectedSubtitle': [
        for (final item in server.where(
          (item) => item.type == 'Subtitle' && !item.isExternal,
        ))
          if (!mapped.containsKey(item.index)) item.index,
      ],
    };
  }

  Map<int, int> _trackMap = const {};
  static String? _cstring(Array<Uint8> bytes) {
    final values = <int>[];
    for (var index = 0; index < 32; index++) {
      if (bytes[index] == 0) break;
      values.add(bytes[index]);
    }
    return values.isEmpty ? null : String.fromCharCodes(values).toLowerCase();
  }

  @override
  Future<Map<String, dynamic>> command(
    String method, [
    Map<String, Object?> args = const {},
  ]) async {
    if (_disposed) throw StateError('Core is disposed');
    var result = 0;
    final selectedStream = method == 'audio' || method == 'subtitle'
        ? _mapped(args['index'])
        : method == 'subtitleOff'
        ? -1
        : null;
    switch (method) {
      case 'play':
        result = _bindings.setPlaying(_handle, 1, ++_operation);
      case 'pause':
        result = _bindings.setPlaying(_handle, 0, ++_operation);
      case 'seek':
        result = _bindings.seek(
          _handle,
          ((args['position'] as num).toInt() * 1000),
          ++_operation,
        );
      case 'rate':
        result = _bindings.setSpeed(
          _handle,
          (args['value'] as num).toDouble(),
          ++_operation,
        );
      case 'audio':
        result = _bindings.selectAudio(_handle, selectedStream!, ++_operation);
      case 'subtitle':
        result = _bindings.selectSubtitle(
          _handle,
          selectedStream!,
          ++_operation,
        );
      case 'subtitleOff':
        result = _bindings.selectSubtitle(_handle, -1, ++_operation);
      case 'subtitleUri':
        final url = (args['url'] as String).toNativeUtf8();
        try {
          result = _bindings.addExternalSubtitle(_handle, url, ++_operation);
        } finally {
          calloc.free(url);
        }
      case 'volume':
        result = _bindings.setVolume(
          _handle,
          (args['value'] as num).toDouble().clamp(0.0, 1.5),
          ++_operation,
        );
      default:
        throw UnsupportedError('Unknown core command $method');
    }
    _check(result, method);
    _CoreSnapshot snapshot;
    if (method == 'audio') {
      snapshot = await _waitSnapshot(
        (value) => value.audioStreamIndex == selectedStream && value.state != 6,
      );
    } else if (method == 'subtitle' || method == 'subtitleOff') {
      snapshot = await _waitSnapshot(
        (value) =>
            value.subtitleStreamIndex == selectedStream && value.state != 6,
      );
    } else if (method == 'subtitleUri') {
      await _waitSnapshot((value) => value.externalSubtitlePending == 0);
      final external = _latestExternalSubtitle();
      if (external == null) {
        throw StateError('External subtitle failed to load');
      }
      _check(
        _bindings.selectSubtitle(_handle, external, ++_operation),
        'external subtitle selection',
      );
      snapshot = await _waitSnapshot(
        (value) => value.subtitleStreamIndex == external && value.state != 6,
      );
    } else if (method == 'rate') {
      final speed = (args['value'] as num).toDouble();
      snapshot = await _waitSnapshot(
        (value) =>
            (value.playbackSpeed - speed).abs() < 0.001 && value.state != 6,
      );
    } else {
      snapshot = _readSnapshot();
    }
    return _trackResult(snapshot, _serverStreams);
  }

  Future<_CoreSnapshot> _waitSnapshot(
    bool Function(_CoreSnapshot) accept,
  ) async {
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (DateTime.now().isBefore(deadline)) {
      if (_disposed) throw StateError('Core was disposed during command');
      final value = _readSnapshot();
      if (value.state == 8) {
        throw StateError('Core command failed (${value.ffmpegError})');
      }
      if (accept(value)) return value;
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    throw TimeoutException('Core did not confirm command');
  }

  int? _latestExternalSubtitle() {
    final track = calloc<NativeCoreTrack>();
    int? selected;
    try {
      for (
        var ordinal = 0;
        ordinal < _bindings.trackCount(_handle);
        ordinal++
      ) {
        track.ref.structSize = sizeOf<NativeCoreTrack>();
        if (_bindings.getTrack(_handle, ordinal, track) == 0 &&
            track.ref.type == 3 &&
            track.ref.isExternal != 0) {
          selected = track.ref.streamIndex;
        }
      }
    } finally {
      calloc.free(track);
    }
    return selected;
  }

  int _mapped(Object? index) {
    final stream = _trackMap[(index as num).toInt()];
    if (stream == null) throw StateError('Container track cannot be mapped');
    return stream;
  }

  void _check(int result, String action) {
    if (result != 0) throw StateError('Core rejected $action ($result)');
  }

  @override
  Future<void> stop() async {
    _poll?.cancel();
    _session = '';
    if (!_disposed) {
      try {
        await command('pause');
      } catch (_) {
        // A failed or not-yet-open core has no active audio to pause.
      }
    }
  }

  @override
  Widget buildView({Key? key}) => _DesktopCoreView(key: key, player: this);

  Future<void> resize(int width, int height) => _channel.invokeMethod<void>(
    'resize',
    {'handle': _handle.address, 'width': width, 'height': height},
  );

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _poll?.cancel();
    _session = '';
    await retireSurface(
      channel: _channel,
      handle: _handle.address,
      needsRasterBarrier: Platform.isLinux,
    );
    await _destroyCore((_handle.address, _bindings.libraryPath));
    await _events.close();
  }
}

Future<void> _destroyCore((int, String) identity) => Isolate.run(() {
  final bindings = CoreBindings(libraryPath: identity.$2);
  bindings.destroyLoopback(Pointer<Void>.fromAddress(identity.$1));
});

class _DesktopCoreView extends StatefulWidget {
  const _DesktopCoreView({super.key, required this.player});
  final DesktopCorePlayer player;
  @override
  State<_DesktopCoreView> createState() => _DesktopCoreViewState();
}

class _DesktopCoreViewState extends State<_DesktopCoreView> {
  Size? _lastSize;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final ratio = MediaQuery.devicePixelRatioOf(context);
      final size = Size(
        constraints.maxWidth * ratio,
        constraints.maxHeight * ratio,
      );
      if (size.width.isFinite && size.height.isFinite && size != _lastSize) {
        _lastSize = size;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            unawaited(
              widget.player.resize(size.width.round(), size.height.round()),
            );
          }
        });
      }
      return Texture(
        textureId: widget.player._textureId,
        filterQuality: FilterQuality.medium,
      );
    },
  );
}
