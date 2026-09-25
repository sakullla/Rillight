import 'dart:async';
import 'dart:isolate';
import 'dart:io';

import 'cache/session_byte_cache.dart';
import 'playback_http_proxy.dart';

/// Owns one playback transport on a dedicated isolate. Only sealed loopback
/// URLs cross this boundary; credentials and cache state stay in the worker.
class PlaybackTransportSession {
  PlaybackTransportSession._(this._isolate, this._inbox, this._worker) {
    _inbox.listen((message) {
      if (message is! List || message.length != 3) {
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
  int _nextId = 0;
  bool _closed = false;
  bool _closing = false;

  static Future<PlaybackTransportSession> start({
    Uri? origin,
    Map<String, String> headers = const {},
    Directory? cacheRoot,
    int memoryLimitBytes = 32 * 1024 * 1024,
    int diskLimitBytes = 2048 * 1024 * 1024,
    int pendingLimitBytes = 8 * 1024 * 1024,
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

  Future<Object?> _request(String operation, [Object? value]) {
    if (_closed) throw StateError('Transport session closed');
    final id = ++_nextId;
    final pending = Completer<Object?>();
    _pending[id] = pending;
    _worker.send([id, operation, value]);
    return pending.future;
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
      Map<String, Object?>.from((await _request('diagnostics'))! as Map);

  Future<void> seek() async {
    await _request('seek');
  }

  Future<void> cancelSubtitles() async {
    await _request('subtitles');
  }

  Future<void> retryReadAhead() async {
    await _request('retry');
  }

  Future<void> refreshTimeline(Duration duration) async {
    await _request('timeline', duration.inMicroseconds);
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

Future<void> _serveTransport(List<Object?> arguments) async {
  final ready = arguments[0]! as SendPort;
  final inbox = arguments[1]! as SendPort;
  final commands = ReceivePort();
  SessionByteCache? cache;
  PlaybackHttpProxy? proxy;
  try {
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
          case 'timeline':
            await proxy.refreshTimeline(
              Duration(microseconds: message[2] as int),
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
    commands.close();
  }
}
