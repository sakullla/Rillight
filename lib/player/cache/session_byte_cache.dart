import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'disk_cache_coordinator.dart';

enum CacheReadSource { memory, disk }

class CacheRead {
  const CacheRead(this.offset, this.bytes, this.source);

  final int offset;
  final Uint8List bytes;
  final CacheReadSource source;
}

/// Session-only media byte storage. HTTP freshness and representation validation
/// belong to the caller; [generation] must change when the representation does.
/// Reads return owned copies so eviction cannot alter an in-flight response.
class SessionByteCache {
  SessionByteCache._({
    required this.memoryLimitBytes,
    required this.pendingLimitBytes,
    required this.maxEntries,
    required this.diskSessionLimitBytes,
  });

  static const maxBlockBytes = 1024 * 1024;

  static Future<SessionByteCache> open({
    Directory? root,
    int memoryLimitBytes = 32 * 1024 * 1024,
    int diskLimitBytes = 2048 * 1024 * 1024,
    int? diskSessionLimitBytes,
    int pendingLimitBytes = 8 * 1024 * 1024,
    int maxEntries = 4096,
    Duration diskTimeout = const Duration(milliseconds: 750),
  }) async {
    if (memoryLimitBytes < 0 ||
        diskLimitBytes < 0 ||
        pendingLimitBytes < 0 ||
        maxEntries < 1 ||
        (diskSessionLimitBytes != null && diskSessionLimitBytes < 0)) {
      throw ArgumentError('Cache budgets must be nonnegative');
    }
    final cache = SessionByteCache._(
      memoryLimitBytes: memoryLimitBytes,
      pendingLimitBytes: pendingLimitBytes,
      maxEntries: maxEntries,
      diskSessionLimitBytes: diskSessionLimitBytes ?? diskLimitBytes,
    );
    if (root != null && diskLimitBytes > 0) {
      try {
        cache._disk = await DiskCacheSession.open(
          root: root,
          limitBytes: diskLimitBytes,
          sessionLimitBytes: cache.diskSessionLimitBytes,
          timeout: diskTimeout,
        );
      } catch (_) {
        cache._degradation = 'disk-unavailable';
      }
    }
    return cache;
  }

  final int memoryLimitBytes;
  final int pendingLimitBytes;
  final int maxEntries;
  final int diskSessionLimitBytes;
  final _entries = <_BlockKey, _Entry>{};
  final _memory = <_BlockKey, Uint8List>{};
  DiskCacheSession? _disk;
  String? _degradation;
  bool _closed = false;
  int _memoryBytes = 0;
  int _indexBytes = 0;
  int _memoryPeak = 0;
  int _pendingBytes = 0;
  int _pendingPeak = 0;
  int _memoryHits = 0;
  int _diskHits = 0;
  int _evictions = 0;
  int _invalidations = 0;
  Future<void>? _closing;

  Map<String, Object?> get diagnostics => {
    'memoryBytes': _memoryBytes,
    'memoryPeakBytes': _memoryPeak,
    'pendingBytes': _pendingBytes,
    'pendingPeakBytes': _pendingPeak,
    'indexEntries': _entries.length,
    'indexBudgetBytes': _indexBytes,
    'memoryHitBytes': _memoryHits,
    'diskHitBytes': _diskHits,
    'evictions': _evictions,
    'invalidations': _invalidations,
    'degradation': _degradation ?? _disk?.degradation,
    'closed': _closed,
    ...?_disk?.diagnostics,
  };

  /// Publishes only caller-validated, complete bytes. A producer must await this
  /// call or respect [pendingLimitBytes]; excess writes are skipped, never queued.
  /// Resource identifiers are bounded and only held in memory, never on disk.
  Future<bool> put({
    required String resource,
    required int generation,
    required int offset,
    required Uint8List bytes,
  }) async {
    if (_closed ||
        offset < 0 ||
        resource.length > 1024 ||
        bytes.isEmpty ||
        bytes.length > maxBlockBytes ||
        _pendingBytes + bytes.length > pendingLimitBytes) {
      return false;
    }
    final key = _BlockKey(resource, generation, offset);
    // An exact range can be replaced after validation, but a late write must not
    // resurrect invalidated or replaced entries.
    final entry = _Entry(bytes.length);
    _forget(key);
    _entries[key] = entry;
    _indexBytes += _indexCost(key);
    _retain(key, bytes);
    while (_entries.length > maxEntries || _indexBytes > 4 * 1024 * 1024) {
      final oldest = _entries.keys.first;
      _forget(oldest);
      _removeMemory(oldest);
      _evictions++;
    }
    final disk = _disk;
    if (disk == null || disk.degradation != null) return true;
    // Include both the message copy and the disk isolate's working buffer.
    final pendingCost = bytes.length * 2;
    if (_pendingBytes + pendingCost > pendingLimitBytes) return true;
    _pendingBytes += pendingCost;
    if (_pendingBytes > _pendingPeak) _pendingPeak = _pendingBytes;
    try {
      final token = await disk.put(bytes);
      if (!_closed && identical(_entries[key], entry)) entry.diskToken = token;
    } finally {
      _releasePending(pendingCost);
    }
    return true;
  }

  /// Returns the cached part starting exactly at [offset], at most [maxLength].
  /// A null result is a miss (including eviction, corruption, or disk failure).
  Future<CacheRead?> read({
    required String resource,
    required int generation,
    required int offset,
    int maxLength = maxBlockBytes,
  }) async {
    if (_closed || maxLength <= 0) return null;
    _BlockKey? key;
    _Entry? entry;
    // Bounded index; favor the latest overlapping block.
    for (final candidate in _entries.keys.toList().reversed) {
      final value = _entries[candidate]!;
      if (candidate.resource == resource &&
          candidate.generation == generation &&
          candidate.offset <= offset &&
          offset < candidate.offset + value.length) {
        key = candidate;
        entry = value;
        break;
      }
    }
    if (key == null || entry == null) return null;
    var bytes = _memory.remove(key);
    var source = CacheReadSource.memory;
    if (bytes != null) {
      _memory[key] = bytes;
    } else if (entry.diskToken != null) {
      final pendingCost = entry.length * 2;
      if (_pendingBytes + pendingCost > pendingLimitBytes) return null;
      _pendingBytes += pendingCost;
      if (_pendingBytes > _pendingPeak) _pendingPeak = _pendingBytes;
      try {
        bytes = await _disk?.read(entry.diskToken!);
      } finally {
        _releasePending(pendingCost);
      }
      source = CacheReadSource.disk;
      if (_closed || !identical(_entries[key], entry)) return null;
      if (bytes != null) _retain(key, bytes);
    }
    if (bytes == null) {
      _forget(key);
      return null;
    }
    _entries.remove(key);
    _entries[key] = entry;
    final start = offset - key.offset;
    final end = (start + maxLength).clamp(start, bytes.length);
    final result = Uint8List.fromList(Uint8List.sublistView(bytes, start, end));
    if (source == CacheReadSource.memory) {
      _memoryHits += result.length;
    } else {
      _diskHits += result.length;
    }
    return CacheRead(offset, result, source);
  }

  /// The next possible hit lets the proxy limit an upstream gap request.
  /// Disk eviction can turn this hint into a miss; callers must handle that.
  int? nextOffset({
    required String resource,
    required int generation,
    required int after,
  }) {
    int? next;
    for (final key in _entries.keys) {
      if (key.resource == resource &&
          key.generation == generation &&
          key.offset > after &&
          (next == null || key.offset < next)) {
        next = key.offset;
      }
    }
    return next;
  }

  void invalidate(String resource, {int? generation}) {
    final keys = _entries.keys.where(
      (key) =>
          key.resource == resource &&
          (generation == null || key.generation == generation),
    );
    for (final key in keys.toList()) {
      _forget(key);
      _removeMemory(key);
      _invalidations++;
    }
    // Inaccessible immutable disk blocks remain charged and are LRU candidates.
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    _entries.clear();
    _indexBytes = 0;
    _memory.clear();
    _memoryBytes = 0;
    await _disk?.close();
  }

  void _retain(_BlockKey key, Uint8List bytes) {
    _removeMemory(key);
    if (bytes.length > memoryLimitBytes) return;
    while (_memoryBytes + bytes.length > memoryLimitBytes) {
      _removeMemory(_memory.keys.first);
      _evictions++;
    }
    _memory[key] = Uint8List.fromList(bytes);
    _memoryBytes += bytes.length;
    if (_memoryBytes > _memoryPeak) _memoryPeak = _memoryBytes;
  }

  void _removeMemory(_BlockKey key) {
    final bytes = _memory.remove(key);
    if (bytes != null) _memoryBytes -= bytes.length;
  }

  int _indexCost(_BlockKey key) => key.resource.length * 2 + 256;

  void _releasePending(int bytes) {
    final disk = _disk;
    if (disk?.degradation == 'disk-timeout') {
      unawaited(
        disk!.settled.then((_) {
          _pendingBytes -= bytes;
        }),
      );
    } else {
      _pendingBytes -= bytes;
    }
  }

  void _forget(_BlockKey key) {
    if (_entries.remove(key) != null) _indexBytes -= _indexCost(key);
  }
}

class _Entry {
  _Entry(this.length);
  final int length;
  String? diskToken;
}

class _BlockKey {
  const _BlockKey(this.resource, this.generation, this.offset);
  final String resource;
  final int generation;
  final int offset;

  @override
  bool operator ==(Object other) =>
      other is _BlockKey &&
      resource == other.resource &&
      generation == other.generation &&
      offset == other.offset;

  @override
  int get hashCode => Object.hash(resource, generation, offset);
}
