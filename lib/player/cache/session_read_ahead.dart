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
  static const maxRequestBytes = 32 * 1024 * 1024;
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
  bool _prefetchAllowed = true;
  bool _readerWaiting = false;
  int _requestBytes = requestBytes;
  int _stableRequests = 0;
  int _publicationActive = 0;
  int _publicationPeak = 0;
  int _publicationBackpressure = 0;
  Future<void>? _worker;
  ReadAheadTransfer? _transfer;
  Completer<void> _changed = Completer<void>();

  bool get failed => _failed;
  Map<String, Object?> get diagnostics => {
    'readAheadActive': _active,
    'readAheadWorkerActive': _worker != null,
    'readAheadLimitBytes': aheadBytes,
    'readAheadPublishedBytes': _published,
    'readAheadPositionBytes': _position,
    'readAheadReaderWaiting': _readerWaiting,
    'readAheadFailed': _failed,
    'readAheadWaitingForDisk': _waitingForDisk,
    'readAheadPrefetchAllowed': _prefetchAllowed,
    'readAheadRequestBytes': _requestBytes,
    'readAheadPublicationActive': _publicationActive,
    'readAheadPublicationPeak': _publicationPeak,
    'readAheadPublicationBackpressure': _publicationBackpressure,
  };

  void _notify() {
    final changed = _changed;
    _changed = Completer<void>();
    changed.complete();
  }

  void stop() {
    _active = false;
    _resetRequestSize();
    _reader++;
    _transfer?.cancel();
    _readerWaiting = false;
    _notify();
  }

  Future<void> close() async {
    _closed = true;
    stop();
    await _worker;
  }

  void _schedule() {
    if (_worker != null ||
        !_active ||
        _closed ||
        _failed ||
        (!_prefetchAllowed && !_readerWaiting)) {
      return;
    }
    _worker = _fill().whenComplete(() {
      _worker = null;
      _notify();
      // A seek may have cancelled the old producer while a new reader arrived.
      if (_active &&
          !_closed &&
          !_failed &&
          (_prefetchAllowed || _readerWaiting) &&
          _missing() != null) {
        _schedule();
      }
    });
  }

  void resumeAfterDiskRecovery() {
    if (_waitingForDisk && cache.diagnostics['degradation'] == null) {
      _waitingForDisk = false;
      _schedule();
    }
  }

  void setPrefetchAllowed(bool allowed) {
    if (_prefetchAllowed == allowed) return;
    _prefetchAllowed = allowed;
    if (allowed) _schedule();
  }

  int get _windowEnd {
    // Disk failure must not turn a disk-sized read-ahead into RAM usage.
    final usable = cache.diagnostics['degradation'] == null;
    final length = usable
        ? min(aheadBytes, cache.diskSessionLimitBytes ~/ 2)
        : min(blockBytes, cache.memoryLimitBytes);
    return min(total, _position + length);
  }

  int? _missing() => cache.firstMissingOffset(
    resource: resource,
    generation: generation,
    offset: _position,
    length: max(0, _windowEnd - _position),
  );

  void _resetRequestSize() {
    _stableRequests = 0;
    _requestBytes = requestBytes;
  }

  Future<void> _waitForPublicationCapacity(int cost) async {
    while (!_closed &&
        cost <= cache.pendingLimitBytes &&
        cache.diagnostics['degradation'] == null &&
        (cache.diagnostics['pendingBytes'] as int) + cost >
            cache.pendingLimitBytes) {
      _publicationBackpressure++;
      _resetRequestSize();
      final changed = cache.pendingChanged;
      await changed;
    }
  }

  Future<void> _fill() async {
    final reader = _reader;
    final reserved = reserveWorkspace?.call() ?? true;
    try {
      if (!reserved) {
        throw const HttpException('Read-ahead workspace unavailable');
      }
      while (_active &&
          !_closed &&
          reader == _reader &&
          (_prefetchAllowed || _readerWaiting)) {
        if (cache.diagnostics['degradation'] == 'disk-timeout') {
          _waitingForDisk = true;
          _resetRequestSize();
        }
        if (_position < total && _windowEnd <= _position) {
          throw const HttpException('Read-ahead budget unavailable');
        }
        final missing = _missing();
        if (missing == null) return;
        final start = missing;
        final requestLength = min(_requestBytes, _windowEnd - start);
        final end = start + requestLength - 1;
        final transfer = await fetch(start, end);
        _transfer = transfer;
        if (!_active ||
            _closed ||
            reader != _reader ||
            (!_prefetchAllowed && !_readerWaiting)) {
          transfer.cancel();
          return;
        }
        var offset = start;
        var buffer = Uint8List(min(blockBytes, end - offset + 1));
        var length = 0;
        var pressured = false;
        final publications = <Future<bool>>[];
        final pendingPublications = <Future<bool>>{};
        final publicationLimit = max(
          1,
          min(4, cache.pendingLimitBytes ~/ (2 * blockBytes)),
        );
        Future<void> publish(Uint8List bytes, int position) async {
          while (pendingPublications.length >= publicationLimit) {
            final pending = cache.diagnostics['pendingBytes'] as int;
            if (pending >= cache.pendingLimitBytes) {
              pressured = true;
              _resetRequestSize();
            }
            _publicationBackpressure++;
            await pendingPublications.first;
          }
          final cost = bytes.length * 2;
          if ((cache.diagnostics['pendingBytes'] as int) + cost >
              cache.pendingLimitBytes) {
            pressured = true;
          }
          await _waitForPublicationCapacity(cost);
          if (!_active || _closed || reader != _reader) return;
          late final Future<bool> publication;
          publication = cache
              .put(
                resource: resource,
                generation: generation,
                offset: position,
                bytes: bytes,
              )
              .whenComplete(() {
                pendingPublications.remove(publication);
                _publicationActive--;
                _notify();
              });
          publications.add(publication);
          pendingPublications.add(publication);
          _publicationActive++;
          _publicationPeak = max(_publicationPeak, _publicationActive);
          // put publishes RAM synchronously. Let playback and the network
          // continue while bounded disk work is still in flight.
          _notify();
        }

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
                await publish(buffer, offset);
                if (cache.diagnostics['degradation'] == 'disk-timeout') {
                  _waitingForDisk = true;
                }
                if (!_active || _closed || reader != _reader) return;
                offset += length;
                _published += length;
                length = 0;
                _notify();
                // A confirmed pause may abandon the rest of this optional
                // range; foreground demand can reopen from the next missing
                // block without treating that cancellation as a failure.
                if (!_prefetchAllowed && !_readerWaiting) return;
                buffer = Uint8List(min(blockBytes, max(0, end - offset + 1)));
              }
            }
          }
          if (offset != end + 1 || length != 0) {
            throw const HttpException('Truncated prefetch range');
          }
          if (pressured || cache.diagnostics['degradation'] != null) {
            _resetRequestSize();
          } else if (++_stableRequests >= 2) {
            _stableRequests = 0;
            _requestBytes = min(maxRequestBytes, _requestBytes * 2);
          }
        } finally {
          transfer.cancel();
          if (identical(_transfer, transfer)) _transfer = null;
          final results = await Future.wait(publications);
          if (results.any((accepted) => !accepted) &&
              _active &&
              !_closed &&
              reader == _reader) {
            throw const HttpException('Read-ahead cache rejected a block');
          }
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
      var progressDeadline = DateTime.now().add(const Duration(seconds: 25));
      while (offset <= end) {
        if (_closed || !_active || reader != _reader) {
          throw const HttpException('Media read cancelled');
        }
        final changed = _changed.future;
        final pendingChanged = cache.pendingChanged;
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
          _readerWaiting = true;
          _resetRequestSize();
          _position = offset;
          // A cache index hit blocked by disk capacity is not a producer
          // miss. Starting an empty producer would repeatedly wake this read
          // and starve the transport isolate's control messages.
          if (_missing() != null) _schedule();
          // An indexed disk block can be temporarily unreadable when the
          // bounded pending budget is occupied by an optional checksum query.
          // No producer will publish that block again, so also wake when disk
          // capacity is released. Both futures were captured before read().
          final remaining = progressDeadline.difference(DateTime.now());
          if (remaining <= Duration.zero) {
            throw const HttpException('Cached media read made no progress');
          }
          await Future.any([changed, pendingChanged]).timeout(remaining);
          continue;
        }
        _readerWaiting = false;
        if (hit.bytes.isEmpty) {
          throw const HttpException('Cached media read made no progress');
        }
        yield hit.bytes;
        offset += hit.bytes.length;
        _position = offset;
        progressDeadline = DateTime.now().add(const Duration(seconds: 25));
        _schedule();
      }
    } finally {
      if (reader == _reader) stop();
    }
  }
}
