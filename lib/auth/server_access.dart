import 'dart:math';

import 'package:flutter/foundation.dart';

import 'server_access_store.dart';
import 'server_list_store.dart';

export 'server_access_store.dart';

class ServerAccessPermit {
  ServerAccessPermit._(this._owner, this.serverId, this.generation);
  final ServerAccessController _owner;
  final String serverId;
  final int generation;
  bool get isValid =>
      _owner.allows(serverId) && generation == _owner.generation(serverId);
  bool belongsTo(ServerAccessController owner) => identical(_owner, owner);
}

/// A correct password is only a candidate until the entry intent is committed.
class ServerUnlockCandidate {
  ServerUnlockCandidate._(this._owner, this.serverId, this.generation);
  final ServerAccessController _owner;
  final String serverId;
  final int generation;
  bool _consumed = false;
  bool get isValid => !_consumed && _owner.generation(serverId) == generation;
  void cancel() {
    _consumed = true;
  }
}

class _Access {
  _Access(this.reference, this.record);
  String? reference;
  ServerAccessRecord record;
  int generation = 0;
  bool unlocked = false;
  bool busy = false;
  int failures = 0;
  DateTime? retryAt;
}

/// Local entry authority only; it never owns or deletes remote credentials.
class ServerAccessController extends ChangeNotifier {
  ServerAccessController({
    required this.store,
    DateTime Function()? clock,
    Future<ServerPasswordVerifier> Function(String)? createVerifier,
  }) : _clock = clock ?? DateTime.now,
       _createVerifier = createVerifier ?? ServerPasswordVerifier.create;
  final ServerAccessStore store;
  final DateTime Function() _clock;
  final Future<ServerPasswordVerifier> Function(String) _createVerifier;
  final Map<String, _Access> _entries = {};
  int _epoch = 0;
  bool _disposed = false;

  /// Call before publishing content. Missing/corrupt records remain protected.
  Future<void> register(SavedServer server) async {
    if (_entries.containsKey(server.id)) return;
    final entry = _Access(
      server.protectionRef,
      server.protectionRef == null
          ? const ServerAccessRecord.disabled()
          : const ServerAccessRecord.unavailable(),
    );
    _entries[server.id] = entry;
    entry.generation = ++_epoch;
    if (server.protectionRef != null) {
      try {
        entry.record =
            await store.read(server.protectionRef!) ??
            const ServerAccessRecord.unavailable();
      } catch (_) {
        entry.record = const ServerAccessRecord.unavailable();
      }
    }
    _notify();
  }

  bool allows(String serverId) {
    final entry = _entries[serverId];
    return !_disposed &&
        entry != null &&
        (!entry.record.enabled || entry.unlocked);
  }

  bool isProtected(String serverId) =>
      _entries[serverId]?.record.enabled ?? true;
  bool isUnavailable(String serverId) =>
      _entries[serverId]?.record.unavailable ?? true;
  int generation(String serverId) => _entries[serverId]?.generation ?? -1;
  DateTime? retryAt(String serverId) => _entries[serverId]?.retryAt;
  String? protectionRef(String serverId) => _entries[serverId]?.reference;
  ServerAccessPermit? permit(String serverId) => allows(serverId)
      ? ServerAccessPermit._(this, serverId, generation(serverId))
      : null;

  bool _mayCheck(_Access entry) =>
      !entry.busy &&
      !_disposed &&
      (entry.retryAt == null || !_clock().isBefore(entry.retryAt!));
  Future<bool> _verify(_Access entry, String password) async {
    final valid = await entry.record.verifier?.matches(password) ?? false;
    if (!valid) {
      entry.failures++;
      entry.retryAt = _clock().add(
        Duration(seconds: min(60, 1 << min(entry.failures, 6))),
      );
      _notify();
    } else {
      entry.failures = 0;
      entry.retryAt = null;
    }
    return valid;
  }

  Future<ServerUnlockCandidate?> prepareUnlock(
    String serverId,
    String password,
  ) async {
    final entry = _entries[serverId];
    if (entry == null || !_mayCheck(entry) || entry.record.unavailable) {
      return null;
    }
    final captured = entry.generation;
    entry.busy = true;
    try {
      final valid = !entry.record.enabled || await _verify(entry, password);
      if (!valid || captured != entry.generation || _disposed) return null;
      return ServerUnlockCandidate._(this, serverId, captured);
    } finally {
      entry.busy = false;
    }
  }

  bool commitUnlock(ServerUnlockCandidate candidate) {
    if (!identical(candidate._owner, this) || !candidate.isValid || _disposed) {
      return false;
    }
    candidate._consumed = true;
    final entry = _entries[candidate.serverId]!;
    entry.unlocked = true;
    entry.generation = ++_epoch;
    _notify();
    return true;
  }

  Future<bool> unlock(String serverId, String password) async {
    final candidate = await prepareUnlock(serverId, password);
    return candidate != null && commitUnlock(candidate);
  }

  void lock(String serverId) {
    final entry = _entries[serverId];
    if (entry == null) return;
    entry.unlocked = false;
    entry.generation = ++_epoch;
    _notify();
  }

  /// Invoke only after another server entry transaction has succeeded.
  void didEnter(String serverId) {
    if (!allows(serverId)) throw StateError('Server entry not authorized');
    for (final id in _entries.keys.toList()) {
      if (id != serverId && isProtected(id)) lock(id);
    }
  }

  /// Returns the reference the configuration transaction must retain. UI/registry
  /// callers pass persistReference to atomically publish it in SavedServer;
  /// failure leaves the previous protection and runtime permit unchanged.
  Future<String> setPassword(
    String serverId,
    String password,
    String confirmation, {
    String? oldPassword,
    Future<void> Function(String reference)? persistReference,
  }) async {
    ServerPasswordVerifier.validatePassword(password);
    if (password != confirmation) {
      throw ArgumentError('Password confirmation differs');
    }
    return _change(
      serverId,
      oldPassword,
      () async => ServerAccessRecord.protected(await _createVerifier(password)),
      persistReference,
    );
  }

  Future<String> disablePassword(
    String serverId,
    String oldPassword, {
    Future<void> Function(String reference)? persistReference,
  }) => _change(
    serverId,
    oldPassword,
    () async => const ServerAccessRecord.disabled(),
    persistReference,
  );

  Future<String> _change(
    String serverId,
    String? oldPassword,
    Future<ServerAccessRecord> Function() prepare,
    Future<void> Function(String reference)? persistReference,
  ) async {
    final entry = _entries[serverId];
    if (entry == null || !_mayCheck(entry)) {
      throw StateError('Server access busy');
    }
    final captured = entry.generation;
    entry.busy = true;
    try {
      if (entry.record.enabled &&
          (oldPassword == null || !await _verify(entry, oldPassword))) {
        throw StateError('Current password required');
      }
      final record = await prepare();
      if (_disposed ||
          !identical(_entries[serverId], entry) ||
          entry.generation != captured) {
        throw StateError('Server access changed');
      }
      // Stage at a fresh key. A failed configuration commit cannot replace the
      // previous verifier, even if secure storage completed before throwing.
      final reference = 'server:$serverId:${generateDeviceId()}';
      await store.write(reference, record);
      try {
        if (_disposed ||
            !identical(_entries[serverId], entry) ||
            entry.generation != captured) {
          throw StateError('Server access changed');
        }
        await persistReference?.call(reference);
      } catch (_) {
        try {
          await store.delete(reference);
        } catch (_) {
          /* Unreferenced key. */
        }
        rethrow;
      }
      final previousReference = entry.reference;
      entry.reference = reference;
      entry.record = record;
      entry.unlocked = false;
      entry.generation = ++_epoch;
      _notify();
      if (previousReference != null) {
        try {
          await store.delete(previousReference);
        } catch (_) {
          // The new configuration is authoritative. Cleanup cannot undo commit.
        }
      }
      return reference;
    } finally {
      entry.busy = false;
    }
  }

  /// Called after the local configuration removal commits. Secure cleanup is
  /// separately retryable and must not make the removed entry readable.
  void unregister(String serverId) {
    lock(serverId);
    _entries.remove(serverId);
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final entry in _entries.values) {
      entry.generation = ++_epoch;
    }
    super.dispose();
  }
}
