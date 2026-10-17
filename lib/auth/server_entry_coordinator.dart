import 'server_access.dart';
import 'server_list_store.dart';

/// One user intent from a server entry to its original destination. Preparation
/// must not navigate; only a successful, still-current connection publishes the
/// unlock. Route adapters share this coordinator rather than unlocking eagerly.
class ServerEntryCoordinator {
  ServerEntryCoordinator(this.access);
  final ServerAccessController access;
  int _revision = 0;
  void cancel() => _revision++;

  Future<bool> enter<T>({
    required SavedServer server,
    required T destination,
    required Future<String?> Function() requestPassword,
    required Future<bool> Function(void Function() guard) connect,
    required Future<void> Function(T destination) navigate,
    void Function()? onPasswordRejected,
  }) async {
    final revision = ++_revision;
    void guard() {
      if (revision != _revision) throw StateError('Entry superseded');
    }

    ServerUnlockCandidate? candidate;
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
      if (candidate != null && !access.commitUnlock(candidate)) return false;
      access.didEnter(server.id);
      await navigate(destination);
      return true;
    } finally {
      candidate?.cancel();
    }
  }
}
