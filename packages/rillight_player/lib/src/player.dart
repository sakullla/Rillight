import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'control.dart';
import 'surface_health.dart';
import 'surface_retirement.dart';

class MpvEvent {
  const MpvEvent(this.type, {this.property, this.value, this.error});
  final String type;
  final String? property;
  final Object? value;
  final String? error;
}

/// One core and one native surface. Use a new instance for a new media session.
class MpvPlayer {
  MpvPlayer._();
  static const _channel = MethodChannel('rillight_player');
  final _events = StreamController<MpvEvent>.broadcast(sync: true);
  final _textureId = ValueNotifier<int?>(null);
  final _pending = <int, Completer<Object?>>{};
  final _ready = Completer<void>();
  final _receive = ReceivePort();
  SendPort? _commands;
  Isolate? _isolate;
  int _handle = 0;
  int _nextId = 0;
  bool _closing = false;
  bool _closed = false;
  bool _controlFailed = false;
  bool _firstFrame = false;
  bool _mediaLoaded = false;
  bool _surfaceRequested = false;
  late final _surfaceHealth = SurfaceHealth(
    readStatus: () => _channel.invokeMapMethod<String, dynamic>('status', {
      'handle': _handle,
    }),
    readTracks: () => getProperty('track-list'),
    onStatus: _surfaceStatus,
    onError: _surfaceError,
  );
  Timer? _poll;
  Future<void>? _disposeFuture;
  late final String nativeVersion;

  Stream<MpvEvent> get events => _events.stream;
  ValueListenable<int?> get textureId => _textureId;

  static Future<MpvPlayer> create({
    Map<String, String> options = const {},
    String? libraryPath,
    bool video = true,
  }) async {
    final player = MpvPlayer._();
    player._receive.listen(player._message);
    player._isolate = await Isolate.spawn(
      controlMain,
      (player._receive.sendPort, options, libraryPath),
      onError: player._receive.sendPort,
      onExit: player._receive.sendPort,
    );
    try {
      await player._ready.future.timeout(const Duration(seconds: 15));
      player.nativeVersion = (await player.getProperty(
        'mpv-version',
      )).toString();
      final version = RegExp(
        r'v?(\d+)\.(\d+)\.(\d+)',
      ).firstMatch(player.nativeVersion);
      if (version == null ||
          (int.parse(version[1]!) == 0 && int.parse(version[2]!) < 41)) {
        throw StateError(
          'libmpv 0.41.0 or newer is required; loaded ${player.nativeVersion}',
        );
      }
      if (video) {
        player._surfaceRequested = true;
        try {
          player._textureId.value = await _channel
              .invokeMethod<int>('create', {'handle': player._handle})
              .timeout(const Duration(seconds: 15));
        } on MissingPluginException {
          player._surfaceRequested = false;
          rethrow;
        }
        player._poll = Timer.periodic(
          const Duration(milliseconds: 100),
          (_) => player._pollSurface(),
        );
      }
      return player;
    } catch (_) {
      if (player._commands != null && !player._controlFailed) {
        await player.dispose();
      } else {
        player._isolate?.kill(priority: Isolate.beforeNextEvent);
        await player._finishDispose();
      }
      rethrow;
    }
  }

  void _message(dynamic raw) {
    if (_closed) return;
    if (raw == null || raw is List) {
      if (_closing && raw == null) return;
      final error = StateError('libmpv control isolate exited: $raw');
      _controlFailed = true;
      if (!_ready.isCompleted) _ready.completeError(error);
      _failPending(error);
      _events.add(MpvEvent('error', error: error.toString()));
      return;
    }
    final message = raw as Map;
    if (message.containsKey('bootstrap')) {
      _commands = message['bootstrap'] as SendPort;
      return;
    }
    if (message.containsKey('ready')) {
      _commands = message['ready'] as SendPort;
      _handle = message['handle'] as int;
      _ready.complete();
      return;
    }
    if (message.containsKey('fatal')) {
      _controlFailed = true;
      final error = StateError(message['fatal'] as String);
      if (!_ready.isCompleted) _ready.completeError(error);
      _failPending(error);
      if (_closing) unawaited(_finishDispose());
      return;
    }
    final event = message['event'];
    if (message['disposed'] == true ||
        event == 3 ||
        event == 4 ||
        event == 5 ||
        event == null) {
      final pending = _pending.remove(message['reply']);
      if (message['error'] != null) {
        pending?.completeError(StateError(message['error'] as String));
      } else {
        pending?.complete(message['value']);
      }
      if (message['disposed'] == true) unawaited(_finishDispose());
      return;
    }
    if (_closing) return;
    if (event == 6) {
      _mediaLoaded = false;
      _firstFrame = false;
    }
    if (event == 8) _mediaLoaded = true;
    final type = switch (event) {
      6 => 'start-file',
      7 => 'end-file',
      8 => 'file-loaded',
      20 => 'seek',
      21 => 'playback-restart',
      22 => 'property',
      24 => 'queue-overflow',
      _ => null,
    };
    if (type != null) {
      if (_surfaceRequested) {
        _surfaceHealth.event(
          type,
          property: message['property'] as String?,
          value: message['value'],
        );
      }
      _events.add(
        MpvEvent(
          type,
          property: message['property'] as String?,
          value: message['value'],
          error: message['error'] as String?,
        ),
      );
    }
  }

  Future<void> _pollSurface() => _surfaceHealth.poll();

  void _surfaceStatus(Map<String, dynamic> status) {
    if (_closing) return;
    if (!_firstFrame && _mediaLoaded && (status['frames'] as int) > 0) {
      _firstFrame = true;
      _events.add(const MpvEvent('first-frame'));
    }
  }

  void _surfaceError(String message) {
    if (_closing) return;
    _poll?.cancel();
    _events.add(MpvEvent('error', error: 'Video surface: $message'));
  }

  Future<Object?> _request(
    String op, [
    Map<String, Object?> arguments = const {},
  ]) {
    if (_closing && op != 'dispose') {
      return Future.error(StateError('Player is closing'));
    }
    final id = ++_nextId;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _commands!.send({'id': id, 'op': op, ...arguments});
    return completer.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        _pending.remove(id);
        throw TimeoutException('libmpv $op reply timed out');
      },
    );
  }

  Future<void> command(List<String> arguments) async {
    if (arguments.isEmpty) throw ArgumentError.value(arguments, 'arguments');
    await _request('command', {'args': arguments});
  }

  Future<void> setProperty(String name, String value) async {
    await _request('set', {'name': name, 'value': value});
  }

  Future<Object?> getProperty(String name) => _request('get', {'name': name});
  Future<void> stop() => command(['stop']);

  Future<void> resize(int width, int height) async {
    if (_closing || _textureId.value == null) return;
    try {
      await _channel.invokeMethod<void>('resize', {
        'handle': _handle,
        'width': width.clamp(1, 7680),
        'height': height.clamp(1, 4320),
      });
    } catch (error) {
      if (!_closing) {
        _events.add(MpvEvent('error', error: 'Video resize: $error'));
      }
    }
  }

  void _failPending(Object error) {
    for (final pending in _pending.values) {
      pending.completeError(error);
    }
    _pending.clear();
  }

  Future<void> dispose() => _disposeFuture ??= _dispose();
  Future<void> _dispose() async {
    _closing = true;
    _surfaceHealth.close();
    _poll?.cancel();
    _failPending(StateError('Player disposed'));
    // Native method only completes after texture unregister and render free.
    // Never destroy the core while an outstanding renderer might reference it.
    if (_surfaceRequested) {
      _textureId.value = null;
      await retireSurface(
        channel: _channel,
        handle: _handle,
        needsRasterBarrier: defaultTargetPlatform == TargetPlatform.linux,
      );
      _surfaceRequested = false;
    }
    await _request('dispose');
    await _finishDispose();
  }

  Future<void> _finishDispose() async {
    if (_closed) return;
    _closed = true;
    _surfaceHealth.close();
    _receive.close();
    await _events.close();
    _textureId.dispose();
  }
}

class MpvVideoView extends StatefulWidget {
  const MpvVideoView({super.key, required this.player});
  final MpvPlayer player;
  @override
  State<MpvVideoView> createState() => _MpvVideoViewState();
}

class _MpvVideoViewState extends State<MpvVideoView> {
  Size? _lastSize;
  @override
  void didUpdateWidget(covariant MpvVideoView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.player, widget.player)) _lastSize = null;
  }

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
      return ValueListenableBuilder<int?>(
        valueListenable: widget.player.textureId,
        builder: (context, id, _) =>
            id == null ? const SizedBox.expand() : Texture(textureId: id),
      );
    },
  );
}
