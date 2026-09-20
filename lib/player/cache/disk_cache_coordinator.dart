import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

/// One coordinator isolate per root in this process. Its queue is the local
/// mutex; the nonblocking OS lock coordinates other player processes. Media
/// bytes and filesystem calls never run on the playback isolate.
class DiskCacheSession {
  DiskCacheSession._(this._coordinator, this._id, this._timeout);

  static Future<DiskCacheSession> open({
    required Directory root,
    required int limitBytes,
    required int sessionLimitBytes,
    required Duration timeout,
  }) async {
    final coordinator = await _Coordinator.acquire(root);
    final id = _nonce();
    final session = DiskCacheSession._(coordinator, id, timeout);
    final result = await session._call('open', {
      'limit': limitBytes,
      'sessionLimit': sessionLimitBytes,
    });
    if (result?['ok'] != true) {
      await session.close();
      throw const FileSystemException('Cache session unavailable');
    }
    return session;
  }

  final _Coordinator _coordinator;
  final String _id;
  final Duration _timeout;
  String? degradation;
  bool _closed = false;
  Future<void>? _closing;
  final Map<String, Object?> _stats = {};
  final _operations = <Future<Map<String, Object?>>>{};
  Map<String, Object?> get diagnostics => Map.unmodifiable(_stats);

  /// Finishes only when timed-out work has actually released its buffers.
  Future<void> get settled async {
    await Future.wait(_operations);
  }

  Future<String?> put(Uint8List bytes) async {
    final result = await _call('put', {'bytes': bytes});
    return result?['token'] as String?;
  }

  Future<Uint8List?> read(String token) async {
    final result = await _call('read', {'token': token});
    return result?['bytes'] as Uint8List?;
  }

  Future<void> setSessionLimit(int bytes) async {
    await _call('resize', {'sessionLimit': bytes});
  }

  Future<bool> hasAny(List<String> tokens) async {
    final result = await _call('available', {'tokens': tokens});
    return result?['available'] == true;
  }

  /// Verifies and protects a complete immutable range without retaining its
  /// media bytes in RAM. Pin metadata is charged to the ordinary disk quota.
  Future<String?> protect(List<String> tokens) async {
    final protection = _nonce();
    final result = await _call('protect', {
      'tokens': tokens,
      'protection': protection,
    });
    if (result?['ok'] == true) return protection;
    // Also queued after a timed-out operation: a late successful pin must not
    // survive an abandoned acquisition, even after the session degraded.
    await releaseProtection(protection);
    return null;
  }

  Future<void> releaseProtection(String protection) async {
    if (_closed) return;
    final operation = _coordinator.request({
      'op': 'unprotect',
      'id': _id,
      'protection': protection,
    });
    _operations.add(operation);
    unawaited(
      operation.then(
        (_) {
          _operations.remove(operation);
        },
        onError: (Object _) {
          _operations.remove(operation);
        },
      ),
    );
    try {
      final result = await operation.timeout(_timeout);
      final stats = result['stats'];
      if (stats is Map) _stats.addAll(Map<String, Object?>.from(stats));
    } catch (_) {}
  }

  Future<Map<String, Object?>?> _call(
    String operation,
    Map<String, Object?> args,
  ) async {
    if (_closed || degradation != null) return null;
    try {
      final operationFuture = _coordinator.request({
        'op': operation,
        'id': _id,
        ...args,
      });
      _operations.add(operationFuture);
      unawaited(
        operationFuture.then((_) {
          _operations.remove(operationFuture);
        }),
      );
      final result = await operationFuture.timeout(_timeout);
      final stats = result['stats'];
      if (stats is Map) _stats.addAll(Map<String, Object?>.from(stats));
      if (result['error'] != null) degradation = result['error'] as String;
      return result;
    } on TimeoutException {
      // Do not kill a filesystem operation or refund its reservation. The
      // coordinator retains the global lock until it stops, and close is queued
      // behind it. The media path immediately continues with bounded memory.
      degradation = 'disk-timeout';
      return null;
    } catch (_) {
      degradation = 'disk-unavailable';
      return null;
    }
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    final cleanup = _coordinator.request({'op': 'close', 'id': _id});
    // Always keep an owner for late cleanup, even when the UI wait expires.
    final released = cleanup.then((result) {
      final stats = result['stats'];
      if (stats is Map) _stats.addAll(Map<String, Object?>.from(stats));
      _stats['cleanup'] = result['ok'] == true ? 'complete' : 'pending';
      return _coordinator.release();
    }, onError: (Object _, StackTrace _) => _coordinator.release());
    try {
      await released.timeout(_timeout);
    } on TimeoutException {
      _stats['cleanup'] = 'pending';
    }
  }
}

class _Coordinator {
  _Coordinator(this.root);
  static final _roots = <String, Future<_Coordinator>>{};
  final String root;
  final _responses = ReceivePort();
  final _pending = <int, Completer<Map<String, Object?>>>{};
  late SendPort _requests;
  late Isolate _isolate;
  int _serial = 0;
  int _clients = 0;

  static Future<_Coordinator> acquire(Directory directory) async {
    final path = directory.absolute.uri.normalizePath().toFilePath();
    final key = Platform.isWindows ? path.toLowerCase() : path;
    final coordinator = await _roots.putIfAbsent(key, () async {
      final value = _Coordinator(key);
      await value._start();
      return value;
    });
    coordinator._clients++;
    return coordinator;
  }

  Future<void> _start() async {
    final ready = Completer<void>();
    _responses.listen((dynamic message) {
      if (message is SendPort) {
        _requests = message;
        ready.complete();
      } else if (message is List) {
        final completion = _pending.remove(message[0]);
        completion?.complete(Map<String, Object?>.from(message[1] as Map));
      }
    });
    _isolate = await Isolate.spawn(_diskMain, [root, _responses.sendPort]);
    await ready.future;
  }

  Future<Map<String, Object?>> request(Map<String, Object?> message) {
    final sequence = _serial++;
    final result = Completer<Map<String, Object?>>();
    _pending[sequence] = result;
    _requests.send([sequence, message]);
    return result.future;
  }

  Future<void> release() async {
    if (--_clients != 0) return;
    _roots.remove(root);
    await request({'op': 'shutdown'});
    _responses.close();
    _isolate.kill();
  }
}

void _diskMain(List<Object> startup) async {
  final responses = startup[1] as SendPort;
  final requests = ReceivePort();
  final store = _DiskStore(startup[0] as String);
  responses.send(requests.sendPort);
  await for (final envelope in requests) {
    final message = Map<String, Object?>.from(envelope[1] as Map);
    Map<String, Object?> result;
    try {
      result = await store.handle(message);
    } catch (_) {
      result = {'error': 'disk-io'};
    }
    if (message['op'] == 'close') {
      // Even when the quota lock is unavailable, surrender the lifecycle lock.
      // All earlier operations have finished in this serialized worker. Bytes
      // stay charged on disk until the next lock holder actually reclaims them.
      try {
        store.abandon(message['id'] as String);
      } catch (_) {
        result = {'error': 'disk-close'};
      }
    }
    responses.send([envelope[0], result]);
  }
}

const _marker = 'rillight-session-byte-cache-v1';
const _maxCacheFiles = 8192;
final _sessionPattern = RegExp(r'^[a-f0-9]{32}$');
final _blockPattern = RegExp(r'^[a-f0-9]{32}-[0-9]+-[a-f0-9]{8}\.block$');
final _tempPattern = RegExp(r'^[a-f0-9]{32}\.partial$');
final _pinPattern = RegExp(r'^[a-f0-9]{32}\.pin$');
String _nonce() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

String _join(String parent, String child) =>
    '$parent${Platform.pathSeparator}$child';
String _name(FileSystemEntity entity) =>
    entity.uri.pathSegments.where((s) => s.isNotEmpty).last;

class _Lease {
  _Lease(this.directory, this.lock, this.limit, this.sessionLimit);
  final Directory directory;
  final RandomAccessFile lock;
  final int limit;
  int sessionLimit;
}

class _DiskStore {
  _DiskStore(String path) : root = Directory(path);
  final Directory root;
  final _leases = <String, _Lease>{};
  final _releasedProtections = <String, Set<String>>{};
  int _peak = 0;
  int _reservedPeak = 0;
  int _evictions = 0;
  // Reused only while the global lock is held. Other processes can change the
  // directory between operations, so no inventory survives a lock release.
  final _entryInventory = <String, List<FileSystemEntity>>{};
  final _statInventory = <String, FileStat>{};

  Future<Map<String, Object?>> handle(Map<String, Object?> message) async {
    if (message['op'] == 'shutdown') return {'ok': true};
    if (message['op'] == 'unprotect') {
      final id = message['id'] as String;
      final protection = message['protection'] as String;
      if (_leases.containsKey(id) && _sessionPattern.hasMatch(protection)) {
        (_releasedProtections[id] ??= {}).add(protection);
      }
    }
    _prepareRoot();
    final lockPath = _join(root.path, 'quota.lock');
    _assertRegularOrAbsent(lockPath);
    final lock = File(lockPath).openSync(mode: FileMode.append);
    var locked = false;
    try {
      final deadline = DateTime.now().add(const Duration(milliseconds: 150));
      while (!locked) {
        try {
          lock.lockSync(FileLock.exclusive);
          locked = true;
        } on FileSystemException {
          if (DateTime.now().isAfter(deadline)) {
            return {'error': 'disk-lock-timeout'};
          }
          sleep(const Duration(milliseconds: 5));
        }
      }
      _entryInventory.clear();
      _statInventory.clear();
      await _reap();
      // An earlier release may have encountered a foreign quota lock. Keep its
      // intent in the coordinator and remove the charged pin under this lock.
      for (final entry in _releasedProtections.entries.toList()) {
        for (final protection in entry.value) {
          _unprotect(entry.key, protection);
        }
        _releasedProtections.remove(entry.key);
      }
      final id = message['id'] as String;
      switch (message['op']) {
        case 'open':
          return _open(
            id,
            message['limit'] as int,
            message['sessionLimit'] as int,
          );
        case 'put':
          return _put(id, message['bytes'] as Uint8List);
        case 'resize':
          final lease = _leases[id];
          if (lease == null) return {};
          lease.sessionLimit = min(lease.limit, message['sessionLimit'] as int);
          return _resize(lease);
        case 'read':
          return _read(id, message['token'] as String);
        case 'available':
          final lease = _leases[id];
          final tokens = List<String>.from(message['tokens'] as List);
          if (lease == null || tokens.length > 8192) return {};
          for (final token in tokens) {
            if (!_blockPattern.hasMatch(token)) continue;
            final file = File(_join(lease.directory.path, token));
            if (FileSystemEntity.typeSync(file.path, followLinks: false) ==
                    FileSystemEntityType.file &&
                file.lengthSync() == int.parse(token.split('-')[1])) {
              return {'available': true};
            }
          }
          return {'available': false};
        case 'protect':
          return _protect(
            id,
            List<String>.from(message['tokens'] as List),
            message['protection'] as String,
          );
        case 'unprotect':
          return _unprotect(id, message['protection'] as String);
        case 'close':
          return await _close(id);
        default:
          return {'error': 'unknown-operation'};
      }
    } finally {
      if (locked) lock.unlockSync();
      lock.closeSync();
    }
  }

  void _prepareRoot() {
    // Never follow a symlink in the configured root or its ancestors.
    var current = root.absolute;
    while (true) {
      if (FileSystemEntity.typeSync(current.path, followLinks: false) ==
          FileSystemEntityType.link) {
        throw const FileSystemException('Linked cache root');
      }
      final parent = current.parent;
      if (parent.path == current.path) break;
      current = parent;
    }
    root.createSync(recursive: true);
  }

  List<Directory> _candidateDirectories() {
    final result = <Directory>[];
    var scanned = 0;
    for (final entity in root.listSync(followLinks: false)) {
      if (++scanned > 256) {
        throw const FileSystemException('Cache root entry limit');
      }
      if (entity is! Directory || !_sessionPattern.hasMatch(_name(entity))) {
        continue;
      }
      result.add(entity);
    }
    return result;
  }

  Map<String, Object?>? _metadata(Directory directory) {
    try {
      final owner = File(_join(directory.path, 'owner.json'));
      if (FileSystemEntity.typeSync(owner.path, followLinks: false) !=
          FileSystemEntityType.file) {
        return null;
      }
      if (owner.lengthSync() > 256) return null;
      final data = jsonDecode(owner.readAsStringSync());
      if (data is Map &&
          data['format'] == _marker &&
          data['limit'] is int &&
          (data['limit'] as int) >= 0) {
        return Map<String, Object?>.from(data);
      }
    } on FormatException {
      // A partially published or damaged ownership record is not authority to
      // delete its directory, nor a reason to reject unrelated valid sessions.
      return null;
    } on FileSystemException {
      return null;
    }
    return null;
  }

  List<Directory> _sessions() =>
      _candidateDirectories().where((dir) => _metadata(dir) != null).toList();

  List<FileSystemEntity> _entries(Directory directory) {
    final cached = _entryInventory[directory.path];
    if (cached != null) return cached;
    final entries = directory.listSync(followLinks: false);
    if (entries.length > _maxCacheFiles) {
      throw const FileSystemException('Cache file count limit');
    }
    return _entryInventory[directory.path] = entries;
  }

  FileStat _stat(File file) =>
      _statInventory.putIfAbsent(file.path, file.statSync);

  void _changed(File file) {
    // Directory.path and File.parent differ in trailing separator spelling.
    // Drop listings after mutation while retaining unchanged file statistics.
    _entryInventory.clear();
    _statInventory.remove(file.path);
  }

  List<File> _files(Directory directory) =>
      _entries(directory).whereType<File>().toList();

  // Unknown ownership prevents deletion, but does not make occupied bytes free.
  int _usage() => _candidateDirectories().fold(
    0,
    (sum, dir) => sum + _files(dir).fold(0, (n, file) => n + _stat(file).size),
  );

  int _limit() => _sessions().fold(1 << 62, (limit, dir) {
    final metadata = _metadata(dir);
    return metadata == null ? limit : min(limit, metadata['limit'] as int);
  });

  Future<void> _reap() async {
    for (final directory in _sessions()) {
      final id = _name(directory);
      if (_leases.containsKey(id)) continue;
      final path = _join(directory.path, 'lease.lock');
      _assertRegularOrAbsent(path);
      final lease = File(path).openSync(mode: FileMode.append);
      var acquired = false;
      try {
        try {
          lease.lockSync(FileLock.exclusive);
          acquired = true;
        } on FileSystemException {
          continue;
        }
        await _removeData(directory);
      } finally {
        if (acquired) lease.unlockSync();
        lease.closeSync();
      }
      if (acquired) await _removeShell(directory);
    }
  }

  Map<String, Object?> _open(String id, int limit, int sessionLimit) {
    if (!_sessionPattern.hasMatch(id)) {
      throw const FileSystemException('Invalid session');
    }
    final metadata = utf8.encode(
      jsonEncode({'format': _marker, 'limit': limit}),
    );
    final effectiveLimit = min(limit, _limit());
    // lease.lock and owner.pending (renamed to owner.json) both need slots.
    if (!_makeRoom(metadata.length, effectiveLimit, requiredFiles: 2)) {
      return {'error': 'disk-quota'};
    }
    final directory = Directory(_join(root.path, id))..createSync();
    final lock = File(
      _join(directory.path, 'lease.lock'),
    ).openSync(mode: FileMode.append);
    try {
      lock.lockSync(FileLock.exclusive);
      final pendingOwner = File(_join(directory.path, 'owner.pending'));
      pendingOwner.writeAsBytesSync(metadata, flush: true);
      pendingOwner.renameSync(_join(directory.path, 'owner.json'));
      _leases[id] = _Lease(directory, lock, limit, sessionLimit);
    } catch (_) {
      lock.closeSync();
      rethrow;
    }
    return {'ok': true, 'stats': _stats()};
  }

  Set<String> _protectedBlocks() {
    final blocks = <String>{};
    for (final session in _sessions()) {
      for (final pin in _files(
        session,
      ).where((file) => _pinPattern.hasMatch(_name(file)))) {
        if (pin.lengthSync() > 512 * 1024) {
          throw const FileSystemException('Invalid read protection');
        }
        final tokens = pin.readAsLinesSync();
        if (tokens.length > 8192 ||
            tokens.any((token) => !_blockPattern.hasMatch(token))) {
          throw const FileSystemException('Invalid read protection');
        }
        blocks.addAll(tokens.map((token) => '${_name(session)}/$token'));
      }
    }
    return blocks;
  }

  bool _makeRoom(
    int required,
    int limit, {
    required int requiredFiles,
    Directory? only,
    Set<String> protecting = const {},
  }) {
    // Protection uses the owned session/block identity, not filesystem spelling
    // (Windows permits equivalent paths with different separators/casing).
    final protected = _protectedBlocks()..addAll(protecting);
    final sessions = only == null ? _candidateDirectories() : [only];
    final candidates = <({File file, int length, DateTime modified})>[];
    // Include every entry, not just evictable blocks. Protected blocks, pin
    // records, partial writes, ownership files and unknown entries all consume
    // slots. The global inventory also includes the root's quota.lock.
    var occupiedFiles = only == null ? 1 : 0;
    var occupied = 0;
    for (final directory in sessions) {
      final entries = _entries(directory);
      occupiedFiles += entries.length;
      final owned = _metadata(directory) != null;
      for (final file in entries.whereType<File>()) {
        final stat = _stat(file);
        occupied += stat.size;
        if (owned &&
            _blockPattern.hasMatch(_name(file)) &&
            !protected.contains('${_name(directory)}/${_name(file)}') &&
            candidates.length < _maxCacheFiles) {
          candidates.add((
            file: file,
            length: stat.size,
            modified: stat.modified,
          ));
        }
      }
    }
    // Sorting must not turn a bounded directory scan into O(n log n) filesystem
    // calls while holding the global quota lock.
    candidates.sort((a, b) => a.modified.compareTo(b.modified));
    for (final candidate in candidates) {
      if (occupied + required <= limit &&
          occupiedFiles + requiredFiles <= _maxCacheFiles) {
        break;
      }
      candidate.file.deleteSync();
      _changed(candidate.file);
      occupied -= candidate.length;
      occupiedFiles--;
      _evictions++;
    }
    return occupied + required <= limit &&
        occupiedFiles + requiredFiles <= _maxCacheFiles;
  }

  Map<String, Object?> _resize(_Lease lease) {
    final converged = _makeRoom(
      0,
      lease.sessionLimit,
      only: lease.directory,
      requiredFiles: 0,
    );
    return {
      'ok': true,
      'stats': {
        ..._stats(),
        'diskSessionTargetBytes': lease.sessionLimit,
        'diskResizePending': !converged,
      },
    };
  }

  Map<String, Object?> _put(String id, Uint8List bytes) {
    final lease = _leases[id];
    if (lease == null || bytes.isEmpty || bytes.length > 1024 * 1024) {
      return {'error': 'invalid-write'};
    }
    // A partial file becomes its immutable block through rename, so exactly one
    // slot is reserved for the entire write, including failure leftovers.
    if (!_makeRoom(
          bytes.length,
          lease.sessionLimit,
          only: lease.directory,
          requiredFiles: 1,
        ) ||
        !_makeRoom(bytes.length, _limit(), requiredFiles: 1)) {
      return {'stats': _stats()};
    }
    // The reservation is protected by the global lock for the entire operation.
    // Partial files remain charged after a failure and are reclaimed only after
    // actual deletion. No other process can reserve these bytes in the meantime.
    final reserved = _usage() + bytes.length;
    _peak = max(_peak, reserved);
    _reservedPeak = max(_reservedPeak, bytes.length);
    final nonce = _nonce();
    final checksum = _crc32(bytes).toRadixString(16).padLeft(8, '0');
    final token = '$nonce-${bytes.length}-$checksum.block';
    final temporary = File(_join(lease.directory.path, '$nonce.partial'));
    try {
      temporary.writeAsBytesSync(bytes, flush: true);
      temporary.renameSync(_join(lease.directory.path, token));
      _changed(temporary);
    } catch (_) {
      if (temporary.existsSync()) {
        try {
          temporary.deleteSync();
        } catch (_) {
          /* Remains charged. */
        }
      }
      rethrow;
    }
    return {'token': token, 'stats': _stats()};
  }

  Map<String, Object?> _read(String id, String token) {
    final lease = _leases[id];
    if (lease == null || !_blockPattern.hasMatch(token)) return {};
    final file = File(_join(lease.directory.path, token));
    if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      return {};
    }
    final parts = token.split('-');
    final length = int.parse(parts[1]);
    if (length > 1024 * 1024 || length <= 0 || file.lengthSync() != length) {
      file.deleteSync();
      _changed(file);
      return {'stats': _stats()};
    }
    final bytes = file.readAsBytesSync();
    final checksum = int.parse(parts[2].split('.').first, radix: 16);
    if (_crc32(bytes) != checksum) {
      file.deleteSync();
      _changed(file);
      return {'stats': _stats()};
    }
    file.setLastModifiedSync(DateTime.now());
    // Immutable owned bytes are sent before another command can evict the file.
    // Reads do not change quota. Avoid a full disk inventory on every 64 KiB
    // consumer slice; allocation/deletion operations refresh usage diagnostics.
    return {'bytes': bytes};
  }

  Map<String, Object?> _protect(
    String id,
    List<String> tokens,
    String protection,
  ) {
    final lease = _leases[id];
    if (lease == null ||
        !_sessionPattern.hasMatch(protection) ||
        tokens.isEmpty ||
        tokens.length > 8192 ||
        tokens.any((token) => !_blockPattern.hasMatch(token))) {
      return {};
    }
    if (_files(
          lease.directory,
        ).where((file) => _pinPattern.hasMatch(_name(file))).length >=
        2) {
      return {};
    }
    final protecting = tokens.map((token) => '$id/$token').toSet();
    // Pin identities and lengths under the eviction lock. CRC remains mandatory
    // on each actual read; scanning all media bytes here would read the complete
    // range twice and could time out before a single byte reached the consumer.
    for (final token in tokens) {
      final path = _join(lease.directory.path, token);
      if (FileSystemEntity.typeSync(path, followLinks: false) !=
          FileSystemEntityType.file) {
        return {};
      }
      final file = File(path);
      final parts = token.split('-');
      final length = int.parse(parts[1]);
      if (length <= 0 || length > 1024 * 1024 || file.lengthSync() != length) {
        return {};
      }
    }
    final metadata = utf8.encode(tokens.join('\n'));
    if (!_makeRoom(
          metadata.length,
          lease.sessionLimit,
          only: lease.directory,
          protecting: protecting,
          requiredFiles: 1,
        ) ||
        !_makeRoom(
          metadata.length,
          _limit(),
          protecting: protecting,
          requiredFiles: 1,
        )) {
      return {};
    }
    _peak = max(_peak, _usage() + metadata.length);
    final file = File(_join(lease.directory.path, '$protection.pin'));
    _assertRegularOrAbsent(file.path);
    file.writeAsBytesSync(metadata, flush: true);
    _changed(file);
    return {'ok': true, 'stats': _stats()};
  }

  Map<String, Object?> _unprotect(String id, String protection) {
    final lease = _leases[id];
    if (lease == null || !_sessionPattern.hasMatch(protection)) return {};
    final file = File(_join(lease.directory.path, '$protection.pin'));
    _assertRegularOrAbsent(file.path);
    if (file.existsSync()) file.deleteSync();
    _changed(file);
    return _resize(lease);
  }

  Future<Map<String, Object?>> _close(String id) async {
    final lease = _leases.remove(id);
    if (lease == null) return {'ok': true};
    try {
      await _removeData(lease.directory);
    } finally {
      lease.lock.unlockSync();
      lease.lock.closeSync();
    }
    await _removeShell(lease.directory);
    return {'ok': !lease.directory.existsSync(), 'stats': _stats()};
  }

  void abandon(String id) {
    _releasedProtections.remove(id);
    final lease = _leases.remove(id);
    if (lease == null) return;
    try {
      lease.lock.unlockSync();
    } finally {
      lease.lock.closeSync();
    }
  }

  Future<void> _removeData(Directory directory) async {
    // This path runs only for an owned session with its lifecycle lock held.
    // Recovery must not use the normal operational scan ceiling: an older
    // process may have crashed with more than that many entries. Stream the
    // directory so cleanup remains bounded and never follows child links.
    await for (final file in directory.list(followLinks: false)) {
      if (file is! File) continue;
      final name = _name(file);
      if (_blockPattern.hasMatch(name) ||
          _tempPattern.hasMatch(name) ||
          _pinPattern.hasMatch(name)) {
        await file.delete();
      }
    }
  }

  Future<void> _removeShell(Directory directory) async {
    // Unknown files or links preserve the ownership record for later inspection.
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is! File ||
          !{'lease.lock', 'owner.json'}.contains(_name(entry))) {
        return;
      }
    }
    for (final name in ['lease.lock', 'owner.json']) {
      final file = File(_join(directory.path, name));
      _assertRegularOrAbsent(file.path);
      if (await file.exists()) await file.delete();
    }
    await directory.delete();
  }

  Map<String, Object?> _stats() {
    final usage = _usage();
    _peak = max(_peak, usage);
    return {
      'diskBytes': usage,
      'diskPeakBytes': _peak,
      'diskReservedPeakBytes': _reservedPeak,
      'diskEvictions': _evictions,
      'diskLimitBytes': _limit(),
    };
  }
}

void _assertRegularOrAbsent(String path) {
  final type = FileSystemEntity.typeSync(path, followLinks: false);
  if (type != FileSystemEntityType.notFound &&
      type != FileSystemEntityType.file) {
    throw const FileSystemException('Unsafe cache file');
  }
}

final _crcTable = Uint32List.fromList(
  List.generate(256, (value) {
    var crc = value;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc >> 1) ^ ((crc & 1) == 0 ? 0 : 0xedb88320);
    }
    return crc;
  }),
);

int _crc32(Uint8List bytes) {
  var crc = 0xffffffff;
  for (final byte in bytes) {
    crc = (crc >> 8) ^ _crcTable[(crc ^ byte) & 0xff];
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}
