import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'session_byte_cache.dart';
import 'session_read_ahead.dart';

/// Buffers exactly one HTTP response in a private cache namespace. No validator
/// is needed because bytes from another response can never enter this stream.
/// Cached downstream seeks share this response and keep its producer alive.
/// A new upstream response always gets an independent instance.
class ResponseReadAhead {
  ResponseReadAhead({
    required SessionByteCache cache,
    required String resource,
    required int length,
    required int aheadBytes,
    required Stream<List<int>> source,
    required void Function() cancelSource,
    void Function()? releaseWorkspace,
  }) : _cache = cache,
       _resource = resource,
       _length = length,
       _source = StreamIterator(source),
       _cancelSource = cancelSource,
       _releaseWorkspace = releaseWorkspace {
    _ahead = SessionReadAhead(
      cache: cache,
      resource: resource,
      generation: 0,
      total: length,
      aheadBytes: aheadBytes,
      fetch: _slice,
    );
  }

  final SessionByteCache _cache;
  final String _resource;
  final int _length;
  final StreamIterator<List<int>> _source;
  final void Function() _cancelSource;
  final void Function()? _releaseWorkspace;
  late final SessionReadAhead _ahead;
  List<int> _chunk = const [];
  int _chunkStart = 0;
  bool _closed = false;
  Future<void>? _closing;
  Future<void>? _finishing;

  String get resource => _resource;
  bool get stopped => _closed;
  bool get canContinue => !_closed && !_ahead.failed;

  Map<String, Object?> get diagnostics => _ahead.diagnostics;

  void setPlaybackActive(bool active) => _ahead.setPrefetchAllowed(active);
  void cancelReaders() => _ahead.cancelReadersKeepingProducer();

  Future<ReadAheadTransfer> _slice(int start, int end) async {
    Stream<List<int>> bytes() async* {
      var position = start;
      while (position <= end) {
        if (_closed) throw const ReadAheadSuperseded();
        if (position < _chunkStart) {
          // Unread spool bytes must never be replaced with a fresh, unvalidated
          // HTTP range if storage has lost them.
          throw const HttpException('Response buffer coverage lost');
        }
        if (position >= _chunkStart + _chunk.length) {
          _chunkStart += _chunk.length;
          _chunk = const [];
          if (!await _source.moveNext()) {
            throw const HttpException('Truncated buffered response');
          }
          _chunk = _source.current;
          continue;
        }
        final startInChunk = position - _chunkStart;
        final count = min(_chunk.length - startInChunk, end - position + 1);
        final chunk = _chunk;
        yield chunk is Uint8List
            ? Uint8List.sublistView(chunk, startInChunk, startInChunk + count)
            : Uint8List.fromList(
                chunk.sublist(startInChunk, startInChunk + count),
              );
        position += count;
      }
      if (end == _length - 1 && await _source.moveNext()) {
        throw const HttpException('Buffered response exceeded its length');
      }
    }

    // A scheduler window boundary/pause does not close the original response.
    // Keep its last chunk so a cancelled publication can resume at the exact
    // byte still missing from this response's private cache.
    return ReadAheadTransfer(bytes(), () {});
  }

  Stream<List<int>> read() => _ahead.read(0, _length - 1);
  Stream<List<int>> readRange(int start, int end) => _ahead.read(start, end);

  Future<void> close() => _closing ??= _close();

  void cancel() {
    if (_closed) return;
    _closed = true;
    _cancelSource();
    _ahead.stop();
  }

  /// Release the upstream socket, retaining immutable published blocks for
  /// bounded local range responses in this playback session.
  Future<void> finish() => _finishing ??= _finish();

  Future<void> _finish() async {
    cancel();
    try {
      await _ahead.close();
      await _source.cancel();
      _chunk = const [];
    } finally {
      _releaseWorkspace?.call();
    }
  }

  Future<void> _close() async {
    await finish();
    await _cache.discardResource(_resource);
  }
}
