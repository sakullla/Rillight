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

/// A snapshot of one cached representation. Pins refer to existing storage;
/// they never grow the memory budget or hold the global lock during playback.
class CacheRangeLease {
  CacheRangeLease._(this._cache, this._blocks, this._protection);
  final SessionByteCache _cache;
  final List<_ProtectedBlock> _blocks;
  final String? _protection;
  bool _closed = false;

  Future<CacheRead?> read(int offset, {int maxLength = 64 * 1024}) async {
    if (_closed || _cache._closed) return null;
    final block = _blocks
        .where(
          (b) => b.key.offset <= offset && offset < b.key.offset + b.length,
        )
        .firstOrNull;
    if (block == null) return null;
    var bytes = block.memory;
    var source = CacheReadSource.memory;
    if (bytes == null) {
      final cost = block.length * 2;
      if (_cache._pendingBytes + cost > _cache.pendingLimitBytes) return null;
      _cache._pendingBytes += cost;
      if (_cache._pendingBytes > _cache._pendingPeak) {
        _cache._pendingPeak = _cache._pendingBytes;
      }
      try {
        bytes = await _cache._disk?.read(block.token!);
      } finally {
        _cache._releasePending(cost);
      }
      source = CacheReadSource.disk;
    }
    if (_closed || bytes == null) return null;
    final start = offset - block.key.offset;
    final end = (start + maxLength).clamp(start, bytes.length);
    final result = Uint8List.fromList(Uint8List.sublistView(bytes, start, end));
    if (source == CacheReadSource.memory) {
      _cache._memoryHits += result.length;
    } else {
      _cache._diskHits += result.length;
    }
    return CacheRead(offset, result, source);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _cache._rangeLeases.remove(this);
    for (final block in _blocks.where((b) => b.memory != null)) {
      final count = _cache._memoryPins[block.key]! - 1;
      if (count == 0) {
        _cache._memoryPins.remove(block.key);
        if (!_cache._entries.containsKey(block.key)) {
          _cache._removeMemory(block.key);
        }
      } else {
        _cache._memoryPins[block.key] = count;
      }
    }
    if (_protection != null) await _cache._disk?.releaseProtection(_protection);
    _cache._trimMemory();
  }
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
    int maxEntries = 8192,
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

  int memoryLimitBytes;
  int pendingLimitBytes;
  final int maxEntries;
  int diskSessionLimitBytes;
  final _entries = <_BlockKey, _Entry>{};
  final _memory = <_BlockKey, Uint8List>{};
  final _memoryPins = <_BlockKey, int>{};
  final _rangeLeases = <CacheRangeLease>{};
  int _acquiringLeases = 0;
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
    'memoryLimitBytes': memoryLimitBytes,
    'pendingLimitBytes': pendingLimitBytes,
    'diskSessionLimitBytes': diskSessionLimitBytes,
    'memoryResizePending': _memoryBytes > memoryLimitBytes,
    'pendingResizePending': _pendingBytes > pendingLimitBytes,
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
    'protectedRanges': _rangeLeases.length,
    'degradation': _degradation ?? _disk?.degradation,
    'closed': _closed,
    ...?_disk?.diagnostics,
  };

  /// Existing protected reads remain valid. New writes honor the new target;
  /// protected excess is released as consumers finish, never copied elsewhere.
  Future<void> resize({
    required int memoryBytes,
    required int pendingBytes,
    required int diskBytes,
  }) async {
    if (_closed) return;
    if (memoryBytes < 0 || pendingBytes < 0 || diskBytes < 0) {
      throw ArgumentError('Cache budgets must be nonnegative');
    }
    memoryLimitBytes = memoryBytes;
    pendingLimitBytes = pendingBytes;
    diskSessionLimitBytes = diskBytes;
    _trimMemory();
    await _disk?.setSessionLimit(diskBytes);
  }

  void _trimMemory() {
    for (final key in _memory.keys.toList()) {
      if (_memoryBytes <= memoryLimitBytes) break;
      if (_memoryPins.containsKey(key)) continue;
      _removeMemory(key);
      _evictions++;
    }
  }

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
        bytes.length > maxBlockBytes) {
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

  /// A planning hint only: another process may evict a disk block after this
  /// check. Consumers still validate each read and must handle a miss.
  int? firstMissingOffset({
    required String resource,
    required int generation,
    required int offset,
    required int length,
  }) {
    var position = offset;
    final end = offset + length;
    while (position < end) {
      var coveredUntil = position;
      for (final entry in _entries.entries) {
        if (entry.key.resource == resource &&
            entry.key.generation == generation &&
            entry.key.offset <= position &&
            entry.key.offset + entry.value.length > coveredUntil &&
            (_memory.containsKey(entry.key) || entry.value.diskToken != null)) {
          coveredUntil = entry.key.offset + entry.value.length;
        }
      }
      if (coveredUntil == position) return position;
      position = coveredUntil;
    }
    return null;
  }

  /// Used only after a miss, before committing a cached prefix. Fully evicted
  /// ranges can use one ordinary streaming request instead of many tiny gaps.
  /// Presence is a hint; every actual disk read still validates length and CRC.
  Future<bool> hasAny({
    required String resource,
    required int generation,
    required int offset,
    required int length,
  }) async {
    if (_closed) return false;
    final tokens = <String>[];
    for (final item in _entries.entries) {
      if (item.key.resource != resource ||
          item.key.generation != generation ||
          item.key.offset >= offset + length ||
          item.key.offset + item.value.length <= offset) {
        continue;
      }
      if (_memory.containsKey(item.key)) return true;
      final token = item.value.diskToken;
      if (token != null) tokens.add(token);
    }
    if (tokens.isEmpty) return false;
    final cost = tokens.length * 128;
    // Retain the conservative gap path if another operation owns this budget.
    if (_pendingBytes + cost > pendingLimitBytes) return true;
    _pendingBytes += cost;
    if (_pendingBytes > _pendingPeak) _pendingPeak = _pendingBytes;
    try {
      return await _disk?.hasAny(tokens) ?? false;
    } finally {
      _releasePending(cost);
    }
  }

  Future<CacheRangeLease?> protectRange({
    required String resource,
    required int generation,
    required int offset,
    required int length,
  }) async {
    if (_closed || length <= 0 || _rangeLeases.length + _acquiringLeases >= 2) {
      return null;
    }
    final blocks = <_ProtectedBlock>[];
    var position = offset;
    while (position < offset + length) {
      _ProtectedBlock? selected;
      for (final item in _entries.entries) {
        if (item.key.resource != resource ||
            item.key.generation != generation ||
            item.key.offset > position ||
            item.key.offset + item.value.length <= position) {
          continue;
        }
        final memory = _memory[item.key];
        if (memory == null && item.value.diskToken == null) continue;
        if (selected == null ||
            item.key.offset + item.value.length >
                selected.key.offset + selected.length) {
          selected = _ProtectedBlock(
            item.key,
            item.value.length,
            memory,
            item.value.diskToken,
          );
        }
      }
      if (selected == null) return null;
      blocks.add(selected);
      position = selected.key.offset + selected.length;
    }
    // Pin before the first await. Concurrent writers may skip retention rather
    // than displace these existing bytes or exceed memoryLimitBytes.
    for (final block in blocks.where((b) => b.memory != null)) {
      _memoryPins[block.key] = (_memoryPins[block.key] ?? 0) + 1;
    }
    _acquiringLeases++;
    String? protection;
    CacheRangeLease? lease;
    try {
      final tokens = blocks
          .where((b) => b.memory == null)
          .map((b) => b.token!)
          .toSet()
          .toList();
      if (tokens.isNotEmpty) {
        // Protection checks lengths and pins identities; media CRC is checked
        // on actual reads. Charge the bounded token message, not a media copy.
        final cost = tokens.length * 128;
        if (_pendingBytes + cost <= pendingLimitBytes) {
          _pendingBytes += cost;
          if (_pendingBytes > _pendingPeak) _pendingPeak = _pendingBytes;
          try {
            protection = await _disk?.protect(tokens);
          } finally {
            _releasePending(cost);
          }
        }
      }
      lease = CacheRangeLease._(this, blocks, protection);
      if (_closed || tokens.isNotEmpty && protection == null) {
        await lease.close();
        return null;
      }
      _rangeLeases.add(lease);
      return lease;
    } finally {
      _acquiringLeases--;
      if (lease == null) {
        await CacheRangeLease._(this, blocks, protection).close();
      }
    }
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
    await Future.wait(_rangeLeases.toList().map((lease) => lease.close()));
    _entries.clear();
    _indexBytes = 0;
    _memory.clear();
    _memoryBytes = 0;
    await _disk?.close();
  }

  void _retain(_BlockKey key, Uint8List bytes) {
    if (_memoryPins.containsKey(key)) return;
    _removeMemory(key);
    if (bytes.length > memoryLimitBytes) return;
    while (_memoryBytes + bytes.length > memoryLimitBytes) {
      final oldest = _memory.keys
          .where((candidate) => !_memoryPins.containsKey(candidate))
          .firstOrNull;
      if (oldest == null) return;
      _removeMemory(oldest);
      _evictions++;
    }
    _memory[key] = Uint8List.fromList(bytes);
    _memoryBytes += bytes.length;
    if (_memoryBytes > _memoryPeak) _memoryPeak = _memoryBytes;
  }

  void _removeMemory(_BlockKey key) {
    if (_memoryPins.containsKey(key)) return;
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

class _ProtectedBlock {
  _ProtectedBlock(this.key, this.length, this.memory, this.token);
  final _BlockKey key;
  final int length;
  final Uint8List? memory;
  final String? token;
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
