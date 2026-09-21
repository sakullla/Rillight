import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'session_byte_cache.dart';

/// One validated, cancellable byte-range transfer. Validation belongs to the
/// HTTP transport; the scheduler never combines unvalidated representations.
class ReadAheadTransfer {
  const ReadAheadTransfer(this.bytes, this.cancel);
  final Stream<List<int>> bytes;
  final void Function() cancel;
}

/// A session-owned sliding read-ahead window, independent of socket backpressure.
/// Only one producer runs. The newest large media read owns its position; small
/// demuxer probes are handled by the HTTP transport outside this scheduler.
class SessionReadAhead {
  SessionReadAhead({
    required this.cache,
    required this.resource,
    required this.generation,
    required this.total,
    required this.aheadBytes,
    required this.fetch,
    this.reserveWorkspace,
    this.releaseWorkspace,
  });

  // Match the store's bounded immutable block size. Tiny disk files multiply
  // quota/index filesystem work and can throttle playback on Windows.
  static const blockBytes = SessionByteCache.maxBlockBytes;
  // Keep one bounded range request large enough to amortize WAN round trips,
  // while still yielding at each 1 MiB cache block for playback reads.
  static const requestBytes = 8 * 1024 * 1024;
  final SessionByteCache cache;
  final String resource;
  final int generation;
  final int total;
  final int aheadBytes;
  final Future<ReadAheadTransfer> Function(int start, int end) fetch;
  final bool Function()? reserveWorkspace;
  final void Function()? releaseWorkspace;
  int _reader = 0;
  int _position = 0;
  int _published = 0;
  bool _active = false;
  bool _closed = false;
  bool _failed = false;
  bool _waitingForDisk = false;
  Future<void>? _worker;
  ReadAheadTransfer? _transfer;
  Completer<void> _changed = Completer<void>();

  bool get failed => _failed;
  Map<String, Object?> get diagnostics => {
    'readAheadActive': _active,
    'readAheadWorkerActive': _worker != null,
    'readAheadLimitBytes': aheadBytes,
    'readAheadPublishedBytes': _published,
    'readAheadFailed': _failed,
    'readAheadWaitingForDisk': _waitingForDisk,
  };

  void _notify() {
    final changed = _changed;
    _changed = Completer<void>();
    changed.complete();
  }

  void stop() {
    _active = false;
    _reader++;
    _transfer?.cancel();
    _notify();
  }

  Future<void> close() async {
    _closed = true;
    stop();
    await _worker;
  }

  void _schedule() {
    if (_worker != null || !_active || _closed || _failed) return;
    _worker = _fill().whenComplete(() {
      _worker = null;
      _notify();
      // A seek may have cancelled the old producer while a new reader arrived.
      if (_active && !_closed && !_failed && _missing() != null) _schedule();
    });
  }

  void resumeAfterDiskRecovery() {
    if (_waitingForDisk && cache.diagnostics['degradation'] == null) {
      _waitingForDisk = false;
      _schedule();
    }
  }

  int get _windowEnd {
    // Disk failure must not turn a disk-sized read-ahead into RAM usage.
    final usable = cache.diagnostics['degradation'] == null;
    final length = usable ? aheadBytes : blockBytes;
    return min(total, _position + length);
  }

  int? _missing() => cache.firstMissingOffset(
    resource: resource,
    generation: generation,
    offset: _position,
    length: max(0, _windowEnd - _position),
  );

  Future<void> _fill() async {
    final reader = _reader;
    final reserved = reserveWorkspace?.call() ?? true;
    try {
      if (!reserved) {
        throw const HttpException('Read-ahead workspace unavailable');
      }
      while (_active && !_closed && reader == _reader) {
        if (cache.diagnostics['degradation'] == 'disk-timeout') {
          _waitingForDisk = true;
        }
        final missing = _missing();
        if (missing == null) return;
        final start = missing;
        final end = min(start + requestBytes, _windowEnd) - 1;
        final transfer = await fetch(start, end);
        _transfer = transfer;
        if (!_active || _closed || reader != _reader) {
          transfer.cancel();
          return;
        }
        var offset = start;
        var buffer = Uint8List(min(blockBytes, end - offset + 1));
        var length = 0;
        try {
          await for (final bytes in transfer.bytes) {
            if (!_active || _closed || reader != _reader) return;
            var cursor = 0;
            while (cursor < bytes.length) {
              final count = min(buffer.length - length, bytes.length - cursor);
              if (count <= 0) {
                throw const HttpException('Invalid prefetch length');
              }
              buffer.setRange(length, length + count, bytes, cursor);
              length += count;
              cursor += count;
              if (length == buffer.length) {
                final publication = cache.put(
                  resource: resource,
                  generation: generation,
                  offset: offset,
                  bytes: buffer,
                );
                // put publishes RAM synchronously. Let playback consume it
                // while the independent disk operation is still in flight.
                _notify();
                await publication;
                if (cache.diagnostics['degradation'] == 'disk-timeout') {
                  _waitingForDisk = true;
                }
                if (!_active || _closed || reader != _reader) return;
                offset += length;
                _published += length;
                length = 0;
                _notify();
                buffer = Uint8List(min(blockBytes, max(0, end - offset + 1)));
              }
            }
          }
          if (offset != end + 1 || length != 0) {
            throw const HttpException('Truncated prefetch range');
          }
        } finally {
          transfer.cancel();
          if (identical(_transfer, transfer)) _transfer = null;
        }
      }
    } catch (_) {
      if (_active && !_closed && reader == _reader) _failed = true;
      _notify();
    } finally {
      if (reserved) releaseWorkspace?.call();
    }
  }

  Stream<List<int>> read(int start, int end) async* {
    if (_closed || _failed) throw const HttpException('Read-ahead unavailable');
    stop();
    final reader = _reader;
    _active = true;
    _position = start;
    try {
      var offset = start;
      while (offset <= end) {
        if (_closed || !_active || reader != _reader) {
          throw const HttpException('Media read cancelled');
        }
        final changed = _changed.future;
        final hit = await cache.read(
          resource: resource,
          generation: generation,
          offset: offset,
          maxLength: min(64 * 1024, end - offset + 1),
        );
        if (_closed || !_active || reader != _reader) {
          throw const HttpException('Media read cancelled');
        }
        if (hit == null) {
          if (_failed) throw const HttpException('Read-ahead failed');
          _position = offset;
          _schedule();
          await changed.timeout(const Duration(seconds: 25));
          continue;
        }
        yield hit.bytes;
        offset += hit.bytes.length;
        _position = offset;
        _schedule();
      }
    } finally {
      if (reader == _reader) stop();
    }
  }
}
