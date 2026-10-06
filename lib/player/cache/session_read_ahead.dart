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

/// A session seek/stop cancelled this reader; the resource remains usable.
class ReadAheadSuperseded extends HttpException {
  const ReadAheadSuperseded() : super('Media read superseded');
}

/// Retry this representation serially before treating a parallel-only refusal
/// as authentication failure or permanent range incompatibility.
class ReadAheadConcurrencyRejected implements Exception {
  const ReadAheadConcurrencyRejected(this.reason);
  final String reason;
}

/// A bounded network attempt ended; cached playback can continue while the
/// producer waits before trying again. This does not invalidate a resource.
class ReadAheadRetryLater implements Exception {
  const ReadAheadRetryLater();
}

/// A session-owned sliding read-ahead window, independent of socket backpressure.
/// Bounded producers publish disjoint ranges directly into the shared cache.
/// Readers consume the earliest available bytes without waiting for a complete
/// range or for later ranges to finish. Small demuxer probes stay in transport.
class SessionReadAhead {
  SessionReadAhead({
    required this.cache,
    required this.resource,
    required this.generation,
    required this.total,
    required this.aheadBytes,
    required this.fetch,
    this.maxConcurrentTransfers = 1,
    this.reserveWorkspace,
    this.releaseWorkspace,
  }) : _concurrency = maxConcurrentTransfers.clamp(1, 4);

  // Match the store's bounded immutable block size. Tiny disk files multiply
  // quota/index filesystem work and can throttle playback on Windows.
  static const blockBytes = SessionByteCache.maxBlockBytes;
  // Refill in substantial windows, retaining one connection per window.
  static const requestBytes = 8 * 1024 * 1024; // HLS segment prefetch cap.
  static const maxRequestBytes = 32 * 1024 * 1024;
  static const parallelRequestBytes = 8 * 1024 * 1024;
  final SessionByteCache cache;
  final String resource;
  final int generation;
  final int total;
  final int aheadBytes;
  final int maxConcurrentTransfers;
  int _concurrency;
  String? _concurrencyFallback;
  DateTime? _serialRestartAfter;
  final Future<ReadAheadTransfer> Function(int start, int end) fetch;
  final bool Function()? reserveWorkspace;
  final void Function()? releaseWorkspace;
  int _reader = 0;
  final _readers = <int, ({int position, bool waiting})>{};
  int _cancelGeneration = 0;
  int _producerEpoch = 0;
  final _jobs = <_ReadAheadJob>{};
  int _transferPeak = 0;
  int _temporaryFailures = 0;
  final _recentPositions = <int, (int, DateTime)>{};
  int _discardedBefore = 0;
  int _position = 0;
  int _published = 0;
  bool _active = false;
  bool _closed = false;
  bool _failed = false;
  Object? _failure;
  bool _waitingForDisk = false;
  bool _prefetchAllowed = true;
  bool _readerWaiting = false;
  int _requestBytes = 0;
  int _publicationActive = 0;
  int _publicationPeak = 0;
  int _publicationBackpressure = 0;
  bool _publicationAdmission = false;
  int _foregroundAcquisitions = 0;
  Future<void>? _worker;
  Completer<void> _changed = Completer<void>();

  bool get failed => _failed;
  int get workspaceBytes =>
      maxConcurrentTransfers > 1 ? blockBytes ~/ 2 : blockBytes;
  bool get hasParallelTransfers => _concurrency > 1 && _jobs.length > 1;

  /// Let an uncached index/subtitle request use a single-stream server. Keep
  /// playback readers alive; the pool queues the restarted producer behind it.
  Future<void Function()> yieldToForeground({String? refusal}) async {
    _foregroundAcquisitions++;
    final waiting = _readerWaiting;
    final active = _active;
    if (refusal != null) {
      _concurrency = 1;
      _concurrencyFallback = refusal;
    }
    stop(cancelReaders: false);
    _active = active;
    _readerWaiting = waiting;
    await _worker;
    // Apply stream-lease grace only after an actual concurrency refusal.
    // Ordinary MKV index probes should not each pay an extra 250 ms after
    // cancellation. A refusing origin still teaches the existing serial retry.
    if (_concurrencyFallback != null) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return () {
      _foregroundAcquisitions--;
      _schedule();
    };
  }

  Map<String, Object?> get diagnostics => {
    'readAheadActive': _active,
    'readAheadWorkerActive': _worker != null,
    'readAheadLimitBytes': aheadBytes,
    'readAheadPublishedBytes': _published,
    'readAheadPositionBytes': _position,
    'readAheadReaderWaiting': _readerWaiting,
    'readAheadReaders': _readers.length,
    'readAheadNoProgressMs': _jobs.isEmpty
        ? 0
        : _jobs.map((job) => job.progress.elapsedMilliseconds).reduce(min),
    'readAheadFailed': _failed,
    'readAheadWaitingForDisk': _waitingForDisk,
    'readAheadPrefetchAllowed': _prefetchAllowed,
    'readAheadRequestBytes': _requestBytes,
    'readAheadConcurrentTransfers': _jobs.length,
    'readAheadTransferPeak': _transferPeak,
    'readAheadConcurrencyLimit': _concurrency,
    'readAheadConcurrencyFallback': _concurrencyFallback,
    'readAheadTemporaryFailures': _temporaryFailures,
    'readAheadPublicationActive': _publicationActive,
    'readAheadPublicationPeak': _publicationPeak,
    'readAheadPublicationBackpressure': _publicationBackpressure,
  };

  void _notify() {
    final changed = _changed;
    _changed = Completer<void>();
    changed.complete();
  }

  void stop({bool cancelReaders = true}) {
    if (cancelReaders) {
      _cancelGeneration++;
      _readers.clear();
      _recentPositions.clear();
      _discardedBefore = 0;
    }
    _active = false;
    _reader++;
    _producerEpoch++;
    for (final job in _jobs) {
      job.transfer?.cancel();
    }
    _readerWaiting = false;
    _notify();
  }

  /// A response-owned producer can survive a downstream seek. Wake only its
  /// obsolete readers while retaining the current bounded download window.
  void cancelReadersKeepingProducer() {
    _cancelGeneration++;
    _readers.clear();
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
        _foregroundAcquisitions > 0 ||
        !_active ||
        _closed ||
        _failed ||
        (!_prefetchAllowed && !_readerWaiting)) {
      return;
    }
    _worker =
        Future.wait([
          for (var lane = 0; lane < _concurrency; lane++) _fill(lane),
        ]).then<void>((_) {}).whenComplete(() {
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

  void retryAfterSourceRenewal() {
    if (_closed) return;
    final waiting = _readerWaiting;
    // Retire an in-flight request/backoff against the old signed address.
    // Merely scheduling does nothing while that producer is still alive.
    stop(cancelReaders: false);
    _failed = false;
    _failure = null;
    _active = true;
    _readerWaiting = waiting;
    _serialRestartAfter = DateTime.now().add(const Duration(milliseconds: 250));
    _notify();
    _schedule();
  }

  void setPrefetchAllowed(bool allowed) {
    if (_prefetchAllowed == allowed) return;
    _prefetchAllowed = allowed;
    if (allowed) _schedule();
  }

  int get _publicationBlockBytes => min(
    workspaceBytes,
    max(64 * 1024, min(cache.memoryLimitBytes, cache.pendingLimitBytes ~/ 6)),
  );

  int get _windowEnd {
    // Disk failure must not turn a disk-sized read-ahead into RAM usage.
    final usable = cache.diagnostics['degradation'] == null;
    // Reserve a few blocks for initialization/index data and the active write;
    // the configured disk quota otherwise bounds the forward window directly.
    final reserve = min(8 * blockBytes, cache.diskSessionLimitBytes ~/ 8);
    final length = usable
        ? min(aheadBytes, cache.diskSessionLimitBytes - reserve)
        : min(blockBytes, cache.memoryLimitBytes);
    return min(total, _position + length);
  }

  int? _missing() {
    var position = _position;
    int? missing;
    while (position < _windowEnd) {
      missing = cache.firstMissingOffset(
        resource: resource,
        generation: generation,
        offset: position,
        length: _windowEnd - position,
      );
      if (missing == null) return null;
      final owner = _jobs
          .where(
            (job) =>
                job.epoch == _producerEpoch &&
                job.start <= missing! &&
                job.end >= missing,
          )
          .firstOrNull;
      if (owner == null) break;
      position = owner.end + 1;
      missing = null;
    }
    if (missing == null || _readerWaiting) return missing;
    final refill = min(maxRequestBytes, max(blockBytes, aheadBytes ~/ 4));
    // A full sliding window must not reopen HTTP for each 64 KiB consumed.
    if (_windowEnd < total && _windowEnd - missing < refill) return null;
    return missing;
  }

  void _noteReaderPosition(int position) {
    final now = DateTime.now();
    _recentPositions.removeWhere(
      (_, value) => now.difference(value.$2) > const Duration(seconds: 15),
    );
    // Keep distinct nearby audio/video cursors; a far audio chunk must not
    // advance the eviction boundary beyond video that is still being read.
    final bucket = position ~/ (32 * 1024 * 1024);
    final previous = _recentPositions[bucket];
    _recentPositions[bucket] = (
      previous == null ? position : min(previous.$1, position),
      now,
    );
    while (_recentPositions.length > 32) {
      _recentPositions.remove(_recentPositions.keys.first);
    }
  }

  Future<void> _reclaimConsumed() async {
    if (_recentPositions.isEmpty) return;
    final used = cache.diagnostics['diskBytes'] as int? ?? 0;
    if (used < cache.diskSessionLimitBytes * .75) return;
    final floor = _recentPositions.values.map((value) => value.$1).reduce(min);
    final reserve = min(64 * 1024 * 1024, cache.diskSessionLimitBytes ~/ 8);
    final before = max(0, floor - reserve);
    if (before < _discardedBefore + blockBytes) return;
    await cache.discardBefore(
      resource: resource,
      generation: generation,
      offset: before,
      keepPrefixBytes: min(32 * 1024 * 1024, cache.diskSessionLimitBytes ~/ 16),
    );
    _discardedBefore = before;
  }

  Future<bool> _waitForPublicationCapacity(int cost, int reader) async {
    // Leave one disk-read reservation available while ahead writes are queued.
    // Otherwise publications can fill the pending budget and
    // starve the foreground reader and cache-integrity observations.
    final limit = max(
      cost,
      cache.pendingLimitBytes - 2 * _publicationBlockBytes,
    );
    while (!_closed &&
        _active &&
        reader == _producerEpoch &&
        (_publicationAdmission ||
            cost <= cache.pendingLimitBytes &&
                (cache.diagnostics['degradation'] == 'disk-timeout' ||
                    cache.diagnostics['degradation'] == null &&
                        (cache.diagnostics['pendingBytes'] as int) + cost >
                            limit))) {
      _publicationBackpressure++;
      await Future.any([cache.pendingChanged, _changed.future]);
    }
    if (_closed || !_active || reader != _producerEpoch) return false;
    // Capacity checking and cache.put's synchronous reservation must be one
    // admission. Otherwise several lanes can all observe the same free space
    // across this async boundary and silently skip persistence under pressure.
    _publicationAdmission = true;
    return true;
  }

  Future<void> _fill(int lane) async {
    final reader = _producerEpoch;
    final reserved = reserveWorkspace?.call() ?? true;
    _ReadAheadJob? currentJob;
    try {
      if (!reserved) {
        // Foreground/cache pressure reduces concurrency, never disables an
        // otherwise healthy first producer.
        if (lane > 0) return;
        throw const HttpException('Read-ahead workspace unavailable');
      }
      // Socket abort is local; give the origin a short grace period to release
      // its single-stream lease before the serial retry. Seeks/close still wake
      // this wait immediately through the generation/notification checks.
      while (_active && !_closed && reader == _producerEpoch) {
        final remaining = _serialRestartAfter?.difference(DateTime.now());
        if (remaining == null || remaining <= Duration.zero) break;
        await Future.any([Future<void>.delayed(remaining), _changed.future]);
      }
      while (_active &&
          !_closed &&
          !_failed &&
          reader == _producerEpoch &&
          (_prefetchAllowed || _readerWaiting)) {
        await _reclaimConsumed();
        if (cache.diagnostics['degradation'] == 'disk-timeout') {
          _waitingForDisk = true;
        }
        if (_position < total && _windowEnd <= _position) {
          throw const HttpException('Read-ahead budget unavailable');
        }
        final missing = _missing();
        if (missing == null) return;
        final start = missing;
        // The disk quota is a sliding window, not one enormous HTTP request.
        // Large ranges amplify demuxer probes/seeks and can be rejected by CDNs.
        var requestLength = min(
          _concurrency > 1
              ? min(
                  parallelRequestBytes,
                  max(workspaceBytes, min(aheadBytes, total) ~/ _concurrency),
                )
              : maxRequestBytes,
          _windowEnd - start,
        );
        // A completed/cancelled out-of-order range may already follow this
        // hole. Never overwrite it or overlap a live producer's reservation.
        final nextCached = cache.nextOffset(
          resource: resource,
          generation: generation,
          after: start,
        );
        if (nextCached != null) {
          requestLength = min(requestLength, nextCached - start);
        }
        for (final job in _jobs) {
          if (job.epoch == reader && job.start > start) {
            requestLength = min(requestLength, job.start - start);
          }
        }
        _requestBytes = requestLength;
        final end = start + requestLength - 1;
        final job = _ReadAheadJob(start, end, reader);
        currentJob = job;
        _jobs.add(job);
        _transferPeak = max(_transferPeak, _jobs.length);
        final transfer = await fetch(start, end);
        job.transfer = transfer;
        if (!_active ||
            _closed ||
            reader != _producerEpoch ||
            (!_prefetchAllowed && !_readerWaiting)) {
          transfer.cancel();
          return;
        }
        var offset = start;
        // Persist a first MiB, then larger disk blocks. The foreground can
        // consume the validated live prefix before a whole block is persisted.
        var buffer = Uint8List(
          min(min(_publicationBlockBytes, 1024 * 1024), end - offset + 1),
        );
        job.buffer = buffer;
        job.offset = offset;
        job.length = 0;
        var length = 0;
        final publications = <Future<bool>>[];
        final pendingPublications = <Future<bool>>{};
        final publicationLimit = max(
          1,
          min(
            4,
            (cache.pendingLimitBytes - 2 * _publicationBlockBytes) ~/
                (2 * _publicationBlockBytes),
          ),
        );
        Future<void> publish(Uint8List bytes, int position) async {
          while (pendingPublications.length >= publicationLimit) {
            _publicationBackpressure++;
            await pendingPublications.first;
          }
          final cost = bytes.length * 2;
          if (!await _waitForPublicationCapacity(cost, reader)) return;
          try {
            if (!_active || _closed || reader != _producerEpoch) return;
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
          } finally {
            _publicationAdmission = false;
            _notify();
          }
          // put publishes RAM synchronously. Let playback and the network
          // continue while bounded disk work is still in flight.
          _notify();
        }

        try {
          await for (final bytes in transfer.bytes) {
            if (!_active || _closed || reader != _producerEpoch) return;
            if (bytes.isNotEmpty) job.progress.reset();
            // React at network-chunk granularity even when assembling a large
            // disk block. A pause must not download the remaining 4 MiB first.
            if (!_prefetchAllowed && !_readerWaiting) return;
            var cursor = 0;
            while (cursor < bytes.length) {
              final count = min(buffer.length - length, bytes.length - cursor);
              if (count <= 0) {
                throw const HttpException('Invalid prefetch length');
              }
              buffer.setRange(length, length + count, bytes, cursor);
              length += count;
              cursor += count;
              job.length = length;
              _notify();
              if (length == buffer.length) {
                await publish(buffer, offset);
                if (cache.diagnostics['degradation'] == 'disk-timeout') {
                  _waitingForDisk = true;
                }
                if (!_active || _closed || reader != _producerEpoch) return;
                offset += length;
                _published += length;
                length = 0;
                _notify();
                // A confirmed pause may abandon the rest of this optional
                // range; foreground demand can reopen from the next missing
                // block without treating that cancellation as a failure.
                if (!_prefetchAllowed && !_readerWaiting) return;
                buffer = Uint8List(
                  min(_publicationBlockBytes, max(0, end - offset + 1)),
                );
                job.buffer = buffer;
                job.offset = offset;
                job.length = 0;
              }
            }
          }
          if (offset != end + 1 || length != 0) {
            throw const HttpException('Truncated prefetch range');
          }
        } finally {
          transfer.cancel();
          // Keep validated partial bytes on seek, pause, transport failure and
          // parallel refusal. A serial restart must not redownload this prefix.
          // Representation invalidation closes this scheduler before publication.
          if (!_closed && length > 0) {
            final retained = await cache.put(
              resource: resource,
              generation: generation,
              offset: offset,
              bytes: Uint8List.sublistView(buffer, 0, length),
            );
            if (retained) _published += length;
          }
          final results = await Future.wait(publications);
          _jobs.remove(job);
          currentJob = null;
          _notify();
          if (results.any((accepted) => !accepted) &&
              _active &&
              !_closed &&
              reader == _producerEpoch) {
            throw const HttpException('Read-ahead cache rejected a block');
          }
        }
      }
    } on ReadAheadRetryLater {
      if (_active && !_closed && reader == _producerEpoch) {
        _temporaryFailures++;
        _serialRestartAfter = DateTime.now().add(const Duration(seconds: 2));
        final waiting = _readerWaiting;
        stop(cancelReaders: false);
        _active = true;
        _readerWaiting = waiting;
      }
    } on ReadAheadConcurrencyRejected catch (error) {
      if (_active && !_closed && reader == _producerEpoch) {
        _concurrency = 1;
        _concurrencyFallback = error.reason;
        _serialRestartAfter = DateTime.now().add(
          const Duration(milliseconds: 250),
        );
        // Retire all parallel sockets before restarting at the demanded gap.
        // Reader generation and validated partial publications remain usable.
        final waiting = _readerWaiting;
        stop(cancelReaders: false);
        _active = true;
        _readerWaiting = waiting;
      }
    } catch (error) {
      if (_active && !_closed && reader == _producerEpoch) {
        _failed = true;
        _failure = error;
        for (final job in _jobs) {
          job.transfer?.cancel();
        }
      }
      _notify();
    } finally {
      if (currentJob != null) {
        currentJob.transfer?.cancel();
        _jobs.remove(currentJob);
      }
      if (reserved) releaseWorkspace?.call();
    }
  }

  bool _producerNear(int start, int end) {
    final cachedStart =
        cache.firstMissingOffset(
          resource: resource,
          generation: generation,
          offset: start,
          length: min(64 * 1024, end - start + 1),
        ) ==
        null;
    return _worker != null &&
        (cachedStart ||
            _jobs.any(
              (job) =>
                  job.epoch == _producerEpoch &&
                  start >= job.start &&
                  start <= min(job.end, job.offset + job.length + blockBytes),
            ));
  }

  void _updateReader(int reader, int position, {required bool waiting}) {
    if (!_readers.containsKey(reader)) return;
    _readers[reader] = (position: position, waiting: waiting);
    // An older HTTP response may remain alive across native seek. It can read
    // cached bytes, but must not move the producer away from the newest demand
    // whenever a cache publication or cancellation wakes both readers.
    if (reader == _readers.keys.last) {
      _position = position;
      _readerWaiting = waiting;
    }
  }

  Stream<List<int>> read(int start, int end) async* {
    if (_closed || _failed) throw const HttpException('Read-ahead unavailable');
    // MP4 can place audio and video chunks tens of MiB apart. Replacing the
    // HTTP consumer must not cancel the continuous download each time the
    // demuxer alternates tracks. Far seeks still interrupt obsolete work.
    if (!_producerNear(start, end)) stop(cancelReaders: false);
    final reader = ++_reader;
    _readers[reader] = (position: start, waiting: false);
    final cancellation = _cancelGeneration;
    _noteReaderPosition(start);
    _active = true;
    _position = start;
    _readerWaiting = false;
    try {
      var offset = start;
      var progressDeadline = DateTime.now().add(const Duration(seconds: 25));
      while (offset <= end) {
        if (_closed || !_active || cancellation != _cancelGeneration) {
          throw const ReadAheadSuperseded();
        }
        final changed = _changed.future;
        final pendingChanged = cache.pendingChanged;
        var hit = await cache.read(
          resource: resource,
          generation: generation,
          offset: offset,
          maxLength: min(64 * 1024, end - offset + 1),
        );
        // Already validated network bytes belong to this reader/generation.
        // Copy only the requested slice so a 64 KiB read never retains a
        // whole producer block, and don't publish incomplete disk coverage.
        final job = _jobs
            .where(
              (job) =>
                  job.epoch == _producerEpoch &&
                  offset >= job.offset &&
                  offset < job.offset + job.length,
            )
            .firstOrNull;
        final live = job?.buffer;
        if (hit == null && live != null && job != null) {
          final start = offset - job.offset;
          final length = min(
            min(64 * 1024, end - offset + 1),
            job.length - start,
          );
          hit = CacheRead(
            offset,
            Uint8List.fromList(
              Uint8List.sublistView(live, start, start + length),
            ),
            CacheReadSource.memory,
          );
        }
        if (_closed || !_active || cancellation != _cancelGeneration) {
          throw const ReadAheadSuperseded();
        }
        if (hit == null) {
          if (_failed) {
            throw _failure ?? const HttpException('Read-ahead failed');
          }
          _updateReader(reader, offset, waiting: true);
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
            throw TimeoutException('Cached media read made no progress');
          }
          await Future.any([changed, pendingChanged]).timeout(remaining);
          continue;
        }
        _updateReader(reader, offset, waiting: false);
        if (hit.bytes.isEmpty) {
          throw const HttpException('Cached media read made no progress');
        }
        yield hit.bytes;
        offset += hit.bytes.length;
        _noteReaderPosition(offset);
        _updateReader(reader, offset, waiting: false);
        progressDeadline = DateTime.now().add(const Duration(seconds: 25));
        _schedule();
      }
    } finally {
      final wasLatest = _readers.isNotEmpty && reader == _readers.keys.last;
      _readers.remove(reader);
      if (wasLatest) {
        if (_readers.isNotEmpty) {
          final next = _readers.values.last;
          if (_active && !_producerNear(next.position, total - 1)) {
            stop(cancelReaders: false);
            _active = true;
          }
          _position = next.position;
          _readerWaiting = next.waiting;
          _notify();
          _schedule();
        } else {
          _readerWaiting = false;
        }
        // Keep the session's bounded forward window warm between demux reads.
        // Playback pause, explicit seek and session close stop it separately.
        if (!_prefetchAllowed && _readers.isEmpty) stop();
      }
    }
  }
}

class _ReadAheadJob {
  _ReadAheadJob(this.start, this.end, this.epoch) : offset = start;
  final int start;
  final int end;
  final int epoch;
  final progress = Stopwatch()..start();
  ReadAheadTransfer? transfer;
  Uint8List? buffer;
  int offset;
  int length = 0;
}
