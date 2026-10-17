import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../auth/server_configuration_migration.dart';
import '../../auth/startup_recovery.dart';

/// Only the application main process opens this store. Playback processes send
/// events to its HistoryWriter; they must never open the history file.
abstract interface class HistoryStore {
  Future<Map<String, dynamic>?> read();
  Future<void> replace(Map<String, dynamic> snapshot);
  Future<void> close();
}

class MemoryHistoryStore implements HistoryStore {
  Map<String, dynamic>? _value;
  @override
  Future<Map<String, dynamic>?> read() async => _value == null
      ? null
      : jsonDecode(jsonEncode(_value)) as Map<String, dynamic>;
  @override
  Future<void> replace(Map<String, dynamic> snapshot) async {
    _value = jsonDecode(jsonEncode(snapshot)) as Map<String, dynamic>;
  }

  @override
  Future<void> close() async {}
}

/// An OS-held exclusive lease prevents another process from becoming a writer.
/// A separate lock inode survives atomic replacement of the data inode.
class FileHistoryStore implements HistoryStore {
  FileHistoryStore._(this.file, this._lease);
  final File file;
  final RandomAccessFile _lease;
  static final Set<String> _openPaths = {};
  bool _closed = false;

  static Future<FileHistoryStore> open(File file) async {
    final absolute = file.absolute;
    await absolute.parent.create(recursive: true);
    if (await FileSystemEntity.type(absolute.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw StateError('History data must not be a symlink');
    }
    final path =
        '${await absolute.parent.resolveSymbolicLinks()}'
        '${Platform.pathSeparator}${absolute.uri.pathSegments.last}';
    if (!_openPaths.add(path)) throw StateError('History already has a writer');
    RandomAccessFile? lease;
    try {
      lease = await File('$path.lock').open(mode: FileMode.append);
      await lease.lock(FileLock.exclusive);
      final store = FileHistoryStore._(File(path), lease);
      try {
        final value = await store.read();
        if (value != null && value['sourceIdentityVersion'] != 2) {
          final migrated = const ServerSourceMapping([]).migrateHistory(value);
          final backup = File('$path.pre-source-v2');
          if (!await backup.exists()) {
            await backup.writeAsString(
              await store.file.readAsString(),
              flush: true,
            );
          }
          await store.replace(migrated);
        }
      } catch (_) {
        throw await recoveryFailure(store.file);
      }
      return store;
    } catch (_) {
      await lease?.close();
      _openPaths.remove(path);
      rethrow;
    }
  }

  static Future<ConfigurationUpgradeFailure> recoveryFailure(File file) async {
    final original = file.absolute;
    final backup = File('${original.path}.pre-source-v2');
    var backupExists = false;
    try {
      backupExists =
          await FileSystemEntity.type(backup.path, followLinks: false) ==
          FileSystemEntityType.file;
    } catch (_) {
      /* The original path still provides a recovery target. */
    }
    return ConfigurationUpgradeFailure(
      original.parent.path,
      originalPath: original.path,
      backupPath: backupExists ? backup.path : null,
      history: true,
    );
  }

  void _requireOpen() {
    if (_closed) throw StateError('History store closed');
  }

  @override
  Future<Map<String, dynamic>?> read() async {
    _requireOpen();
    if (!await file.exists()) return null;
    return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  }

  @override
  Future<void> replace(Map<String, dynamic> snapshot) async {
    _requireOpen();
    final temporary = File('${file.path}.next');
    try {
      await temporary.writeAsString(jsonEncode(snapshot), flush: true);
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _lease.unlock();
    } finally {
      await _lease.close();
      _openPaths.remove(file.path);
    }
  }
}
