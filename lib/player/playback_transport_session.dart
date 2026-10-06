import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:io';
import 'dart:typed_data';

import 'cache/cache_limits.dart';
import 'cache/session_byte_cache.dart';
import 'playback_http_proxy.dart';

/// Owns one playback transport on a dedicated isolate. Only sealed loopback
/// URLs cross this boundary; credentials and cache state stay in the worker.
class PlaybackTransportSession {
  PlaybackTransportSession._(this._isolate, this._inbox, this._worker) {
    _inbox.listen((message) {
      if (message is! List || message.length != 3) {
        if (message is List && message.length == 2) {
          _workerFailure = TransportWorkerFailure.fromMessage(message);
        } else if (message == null) {
          _workerExited = true;
        }
        final tracePath = Platform.environment['RILLIGHT_TRANSPORT_TRACE'];
        if (tracePath != null && tracePath.isNotEmpty) {
          try {
            File('$tracePath.host.jsonl').writeAsStringSync(
              '${jsonEncode({'time': DateTime.now().toUtc().toIso8601String(), ...localDiagnostics})}\n',
              mode: FileMode.append,
            );
          } catch (_) {
            // Optional local diagnostics must not affect failure handling.
          }
        }
        if (!_closed && !_closing) {
          _closed = true;
          for (final pending in _pending.values) {
            pending.completeError(StateError('Transport isolate stopped'));
          }
          _pending.clear();
        }
        return;
      }
      final pending = _pending.remove(message[0]);
      if (pending == null) return;
      if (message[1] == true) {
        pending.complete(message[2]);
      } else {
        pending.completeError(StateError(message[2].toString()));
      }
    });
  }

  final Isolate _isolate;
  final ReceivePort _inbox;
  final SendPort _worker;
  final _pending = <int, Completer<Object?>>{};
  final _pendingOperations = <int, (String, DateTime)>{};
  int _nextId = 0;
  bool _closed = false;
  bool _closing = false;
  bool _workerExited = false;
  TransportWorkerFailure? _workerFailure;

  /// Host-side facts survive a worker failure without querying the dead port.
  Map<String, Object?> get localDiagnostics => {
    'transportWorkerExited': _workerExited,
    'transportWorkerFailureKind': _workerFailure?.kind,
    'transportWorkerFailureFrames': _workerFailure?.frames ?? const <String>[],
    'transportPendingCommands': [
      for (final entry in _pendingOperations.entries)
        {
          'operation': entry.value.$1,
          'ageMs': DateTime.now().difference(entry.value.$2).inMilliseconds,
        },
    ],
  };

  static Future<PlaybackTransportSession> start({
    Uri? origin,
    Map<String, String> headers = const {},
    Directory? cacheRoot,
    int memoryLimitBytes = 32 * 1024 * 1024,
    int diskLimitBytes = 2048 * 1024 * 1024,
    int pendingLimitBytes = defaultCachePendingBytes,
    int readAheadBytes = 512 * 1024 * 1024,
    bool dynamicSource = false,
    bool sessionBuffering = false,
  }) async {
    final inbox = ReceivePort();
    final ready = ReceivePort();
    try {
      final isolate = await Isolate.spawn(
        _serveTransport,
        [
          ready.sendPort,
          inbox.sendPort,
          origin?.toString(),
          headers,
          cacheRoot?.path,
          memoryLimitBytes,
          cacheRoot == null ? 0 : diskLimitBytes,
          pendingLimitBytes,
          readAheadBytes,
          dynamicSource,
          sessionBuffering,
        ],
        onError: inbox.sendPort,
        onExit: inbox.sendPort,
      );
      final first = await ready.first;
      if (first is! SendPort) {
        isolate.kill(priority: Isolate.immediate);
        throw StateError(first.toString());
      }
      return PlaybackTransportSession._(isolate, inbox, first);
    } catch (_) {
      inbox.close();
      rethrow;
    } finally {
      ready.close();
    }
  }

  Future<Object?> _request(
    String operation, [
    Object? value,
    Duration? deadline,
  ]) {
    if (_closed) throw StateError('Transport session closed');
    final id = ++_nextId;
    final pending = Completer<Object?>();
    _pending[id] = pending;
    _pendingOperations[id] = (operation, DateTime.now());
    _worker.send([id, operation, value]);
    final future = deadline == null
        ? pending.future
        : pending.future.timeout(deadline);
    return future.whenComplete(() {
      _pending.remove(id);
      _pendingOperations.remove(id);
    });
  }

  Future<Uri> register(
    Uri url, {
    PlaybackResourceRole role = PlaybackResourceRole.media,
    String context = '',
  }) async => Uri.parse(
    (await _request('register', [url.toString(), role.index, context]))!
        as String,
  );

  Future<Map<String, Object?>> get diagnostics async =>
      Map<String, Object?>.from(
        (await _request('diagnostics', null, const Duration(seconds: 2)))!
            as Map,
      );

  Future<void> seek() async {
    await _request('seek');
  }

  Future<void> cancelSubtitles() async {
    await _request('subtitles');
  }

  Future<void> retryReadAhead() async {
    await _request('retry');
  }

  Future<void> refreshSourceUrl(Uri route, Uri url) async {
    await _request('refreshSource', [route.toString(), url.toString()]);
  }

  Future<void> refreshTimeline(Duration duration) async {
    await _request(
      'timeline',
      duration.inMicroseconds,
      const Duration(seconds: 5),
    );
  }

  Future<void> selectContainerTracks({
    int? videoTrackId,
    int? audioTrackId,
  }) async {
    await _request('tracks', [videoTrackId, audioTrackId]);
  }

  Future<void> setPlaybackActive(bool active) async {
    await _request('playbackActive', active);
  }

  Future<void> installWarmPrefix(Uri url, Uint8List bytes) async {
    await _request('warmPrefix', [url.toString(), bytes]);
  }

  Future<void> resizeCache({
    required int memoryBytes,
    required int pendingBytes,
    required int diskBytes,
  }) async {
    await _request('resize', [memoryBytes, pendingBytes, diskBytes]);
  }

  Future<void> close() async {
    if (_closed) {
      _inbox.close();
      _isolate.kill(priority: Isolate.immediate);
      return;
    }
    _closing = true;
    try {
      await _request('close').timeout(const Duration(seconds: 10));
    } on TimeoutException {
      // The finally block forcefully retires the unresponsive worker. Close is
      // best effort and must not replace the original playback failure.
    } finally {
      _closed = true;
      for (final pending in _pending.values) {
        pending.completeError(StateError('Transport session closed'));
      }
      _pending.clear();
      _inbox.close();
      _isolate.kill(priority: Isolate.immediate);
    }
  }
}

/// An isolate error message can embed signed URLs. Retain only its error class
/// and Dart source locations, never the message or arbitrary stack text.
class TransportWorkerFailure {
  TransportWorkerFailure._(this.kind, this.frames);

  factory TransportWorkerFailure.fromMessage(List<Object?> message) {
    final raw = message.firstOrNull?.toString() ?? '';
    final named = RegExp(
      r'^([A-Za-z_][A-Za-z_0-9]*(?:Exception|Error))\b',
    ).firstMatch(raw)?.group(1);
    final kind =
        named ?? (raw.startsWith('Bad state:') ? 'StateError' : 'unknown');
    final stack = message.length > 1 ? message[1]?.toString() ?? '' : '';
    final frames = RegExp(
      r'(?:package:[A-Za-z_0-9]+/[A-Za-z_0-9./-]+\.dart|dart:[A-Za-z_0-9./-]+)(?::\d+){1,2}',
    ).allMatches(stack).take(16).map((match) => match.group(0)!).toList();
    return TransportWorkerFailure._(kind, List.unmodifiable(frames));
  }

  final String kind;
  final List<String> frames;
}

Future<void> _serveTransport(List<Object?> arguments) async {
  final ready = arguments[0]! as SendPort;
  final inbox = arguments[1]! as SendPort;
  final commands = ReceivePort();

  SessionByteCache? cache;
  PlaybackHttpProxy? proxy;
  IOSink? trace;
  try {
    final tracePath = Platform.environment['RILLIGHT_TRANSPORT_TRACE'];
    if (tracePath != null && tracePath.isNotEmpty) {
      trace = File(tracePath).openWrite(mode: FileMode.append);
      unawaited(trace.done.catchError((Object _) {}));
    }
    cache = await SessionByteCache.open(
      root: arguments[4] == null ? null : Directory(arguments[4]! as String),
      memoryLimitBytes: arguments[5]! as int,
      diskLimitBytes: arguments[6]! as int,
      pendingLimitBytes: arguments[7]! as int,
    );
    proxy = await PlaybackHttpProxy.create(
      origin: arguments[2] == null ? null : Uri.parse(arguments[2]! as String),
      headers: Map<String, String>.from(arguments[3]! as Map),
      cache: cache,
      readAheadBytes: arguments[8]! as int,
      dynamicSource: arguments[9]! as bool,
      sessionBuffering: arguments[10]! as bool,
    );
    ready.send(commands.sendPort);
    await for (final message in commands) {
      if (message is! List || message.length != 3) continue;
      final id = message[0] as int;
      final operation = message[1] as String;
      if (operation == 'timeline') {
        // The optional cache snapshot may wait on disk. Keep playback controls
        // and diagnostics serviceable while it is calculated.
        unawaited(() async {
          try {
            await proxy!.refreshTimeline(
              Duration(microseconds: message[2] as int),
              verifyChecksum: true,
            );
            inbox.send([id, true, null]);
          } catch (error) {
            inbox.send([id, false, error.toString()]);
          }
        }());
        continue;
      }
      try {
        Object? result;
        switch (operation) {
          case 'register':
            final value = message[2] as List;
            result = proxy
                .register(
                  Uri.parse(value[0] as String),
                  role: PlaybackResourceRole.values[value[1] as int],
                  context: value[2] as String,
                )
                .toString();
            break;
          case 'diagnostics':
            result = proxy.diagnostics;
            // Opt-in local investigation only. Never record resource IDs,
            // headers, URLs, credentials or exception messages.
            trace?.writeln(
              jsonEncode({
                'time': DateTime.now().toUtc().toIso8601String(),
                for (final entry in (result as Map<String, Object?>).entries)
                  if (entry.value is num ||
                      entry.value is bool ||
                      const {
                        'degradation',
                        'streamPolicy',
                        'readAheadBypassReason',
                        'readAheadConcurrencyFallback',
                        'lastUpstreamPhase',
                        'lastUpstreamFailureKind',
                        'lastRequestedResourceRole',
                        'lastUpstreamResourceRole',
                      }.contains(entry.key))
                    entry.key: entry.value,
              }),
            );
            break;
          case 'seek':
            proxy.cancelPendingReads(preserveSubtitles: true);
            break;
          case 'subtitles':
            proxy.cancelSubtitleReads();
            break;
          case 'retry':
            await proxy.retryReadAhead();
            break;
          case 'refreshSource':
            final value = message[2] as List;
            proxy.refreshSourceUrl(
              Uri.parse(value[0] as String),
              Uri.parse(value[1] as String),
            );
            break;
          case 'tracks':
            final value = message[2] as List;
            proxy.selectContainerTracks(
              videoTrackId: value[0] as int?,
              audioTrackId: value[1] as int?,
            );
            break;
          case 'playbackActive':
            proxy.setPlaybackActive(message[2] as bool);
            break;
          case 'warmPrefix':
            final value = message[2] as List;
            proxy.installWarmPrefix(
              Uri.parse(value[0] as String),
              value[1] as Uint8List,
            );
            break;
          case 'resize':
            final value = message[2] as List;
            await cache.resize(
              memoryBytes: value[0] as int,
              pendingBytes: value[1] as int,
              diskBytes: value[2] as int,
            );
            break;
          case 'close':
            await proxy.close();
            break;
          default:
            throw ArgumentError('Unknown transport operation');
        }
        inbox.send([id, true, result]);
        if (operation == 'close') break;
      } catch (error) {
        inbox.send([id, false, error.toString()]);
      }
    }
  } catch (error) {
    ready.send(error.toString());
    await proxy?.close();
    await cache?.close();
  } finally {
    try {
      await trace?.close();
    } catch (_) {
      // Optional tracing must not affect playback shutdown.
    }
    commands.close();
  }
}
