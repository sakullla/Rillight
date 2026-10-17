import 'server_access.dart';
import 'server_list_store.dart';

/// A password-verified navigation intent, kept private to its caller until
/// playback or navigation can commit. It never changes global content access.
class ServerEntryTicket {
  ServerEntryTicket._(
    this._owner,
    this.serverId,
    this._revision,
    this._candidate,
  ) : generation =
          _candidate?.authorizedGeneration ??
          _owner.access.generation(serverId);
  final ServerEntryCoordinator _owner;
  final String serverId;
  final int _revision;
  final ServerUnlockCandidate? _candidate;
  final int generation;
  bool _cancelled = false, _committed = false, _prepared = false;
  bool get isCommitted => _committed;
  bool get isValid =>
      !_cancelled &&
      (_committed || _owner._revision == _revision) &&
      ((_owner.access.allows(serverId) &&
              _owner.access.generation(serverId) == generation) ||
          (!_committed && _candidate?.isValid == true));
  bool authorizes(ServerAccessController access, String id) =>
      identical(access, _owner.access) && id == serverId && isValid;
  void requireValid() {
    if (!isValid) throw StateError('Entry preparation revoked');
  }

  Future<void> prepareCommit() async {
    requireValid();
    await _owner.preparePublication?.call(serverId, requireValid);
    requireValid();
    _prepared = true;
  }

  bool commit() {
    requireValid();
    if (!_prepared) throw StateError('Entry publication not prepared');
    final result = _owner.access.commitEntry(
      serverId,
      _candidate,
      publishConnection: () => _owner.publishConnection?.call(serverId),
    );
    _committed = result;
    return result;
  }

  void cancel() {
    if (_committed || _cancelled) return;
    _cancelled = true;
    _candidate?.cancel();
    if (_owner._revision == _revision) _owner.cancel();
  }
}

/// One user intent from a server entry to its original destination. Preparation
/// must not navigate; only a successful, still-current connection publishes the
/// unlock. Route adapters share this coordinator rather than unlocking eagerly.
class ServerEntryCoordinator {
  ServerEntryCoordinator(
    this.access, {
    this.publishConnection,
    this.cancelConnection,
    this.preparePublication,
  });
  final ServerAccessController access;
  final void Function(String serverId)? publishConnection;
  final void Function()? cancelConnection;
  final Future<void> Function(String serverId, void Function() guard)?
  preparePublication;
  int _revision = 0;
  void cancel() {
    _revision++;
    cancelConnection?.call();
  }

  Future<ServerEntryTicket?> prepareEntry({
    required SavedServer server,
    required Future<String?> Function() requestPassword,
    required Future<bool> Function(void Function() guard) connect,
    void Function()? onPasswordRejected,
  }) async {
    final revision = ++_revision;
    void guard() {
      if (_revision != revision) throw StateError('Entry superseded');
    }

    ServerUnlockCandidate? candidate;
    var prepared = false;
    try {
      await access.register(server);
      guard();
      if (!access.allows(server.id)) {
        final password = await requestPassword();
        guard();
        if (password == null) return null;
        candidate = await access.prepareUnlock(server.id, password);
        guard();
        if (candidate == null) {
          onPasswordRejected?.call();
          return null;
        }
      }
      if (!await connect(guard)) return null;
      guard();
      if (candidate != null && !candidate.isValid) return null;
      prepared = true;
      return ServerEntryTicket._(this, server.id, revision, candidate);
    } finally {
      if (!prepared) {
        candidate?.cancel();
        if (_revision == revision) cancelConnection?.call();
      }
    }
  }

  Future<bool> enter<T>({
    required SavedServer server,
    required T destination,
    required Future<String?> Function() requestPassword,
    required Future<bool> Function(void Function() guard) connect,
    required Future<void> Function(T destination) navigate,
    void Function()? onPasswordRejected,
    Future<bool> Function(ServerEntryTicket ticket)? validate,
  }) => _authorize(
    server: server,
    destination: destination,
    requestPassword: requestPassword,
    connect: connect,
    navigate: navigate,
    onPasswordRejected: onPasswordRejected,
    publishContentAccess: true,
    validate: validate,
  );

  /// Authorize only this management destination, including offline repair.
  /// Never publishes a content permit or locks the currently used server.
  Future<bool> authorizeManagement<T>({
    required SavedServer server,
    required T destination,
    required Future<String?> Function() requestPassword,
    required Future<void> Function(T destination) navigate,
    void Function()? onPasswordRejected,
  }) => _authorize(
    server: server,
    destination: destination,
    requestPassword: requestPassword,
    connect: (_) async => true,
    navigate: navigate,
    onPasswordRejected: onPasswordRejected,
    publishContentAccess: false,
  );

  Future<bool> _authorize<T>({
    required SavedServer server,
    required T destination,
    required Future<String?> Function() requestPassword,
    required Future<bool> Function(void Function() guard) connect,
    required Future<void> Function(T destination) navigate,
    required bool publishContentAccess,
    Future<bool> Function(ServerEntryTicket ticket)? validate,
    void Function()? onPasswordRejected,
  }) async {
    final revision = ++_revision;
    void guard() {
      if (revision != _revision) throw StateError('Entry superseded');
    }

    ServerUnlockCandidate? candidate;
    var committed = false;
    try {
      await access.register(server);
      guard();
      if (!access.allows(server.id)) {
        final password = await requestPassword();
        guard();
        if (password == null) return false;
        candidate = await access.prepareUnlock(server.id, password);
        guard();
        if (candidate == null) {
          onPasswordRejected?.call();
          return false;
        }
      }
      if (!await connect(guard)) return false;
      guard();
      if (candidate != null && !candidate.isValid) return false;
      if (publishContentAccess) {
        if (validate != null &&
            !await validate(
              ServerEntryTicket._(this, server.id, revision, candidate),
            )) {
          return false;
        }
        guard();
        void publicationGuard() {
          guard();
          if (candidate != null && !candidate.isValid) {
            throw StateError('Entry authorization revoked');
          }
        }

        await preparePublication?.call(server.id, publicationGuard);
        guard();
        if (candidate != null && !candidate.isValid) return false;
        if (!access.commitEntry(
          server.id,
          candidate,
          publishConnection: () => publishConnection?.call(server.id),
        )) {
          return false;
        }
        committed = true;
      }
      await navigate(destination);
      return true;
    } finally {
      candidate?.cancel();
      if (publishContentAccess && !committed && revision == _revision) {
        cancelConnection?.call();
      }
    }
  }
}
