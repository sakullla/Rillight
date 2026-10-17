import 'server_access.dart';
import 'server_list_store.dart';

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

  Future<bool> enter<T>({
    required SavedServer server,
    required T destination,
    required Future<String?> Function() requestPassword,
    required Future<bool> Function(void Function() guard) connect,
    required Future<void> Function(T destination) navigate,
    void Function()? onPasswordRejected,
  }) => _authorize(
    server: server,
    destination: destination,
    requestPassword: requestPassword,
    connect: connect,
    navigate: navigate,
    onPasswordRejected: onPasswordRejected,
    publishContentAccess: true,
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
