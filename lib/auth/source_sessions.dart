import 'dart:async';

import 'credential_store.dart';
import 'region_access.dart';
import 'server_list_store.dart';
import '../emby/emby_client.dart';
import '../emby/emby_errors.dart';
import '../player/playback_models.dart';

/// Account identity only. Media item/version identity belongs to aggregation.
class SourceAccount {
  const SourceAccount({
    required this.region,
    required this.configuredServerId,
    required this.verifiedServerId,
    required this.userId,
  });
  final AccessRegion region;
  final String configuredServerId;
  final String verifiedServerId;
  final String userId;
  @override
  bool operator ==(Object other) =>
      other is SourceAccount &&
      region == other.region &&
      configuredServerId == other.configuredServerId &&
      verifiedServerId == other.verifiedServerId &&
      userId == other.userId;
  @override
  int get hashCode =>
      Object.hash(region, configuredServerId, verifiedServerId, userId);
}

class SourceSession {
  SourceSession._(this.account, this.client, this.revision);
  final SourceAccount account;
  final EmbyClient client;
  final int revision;
}

class OperationPermit {
  OperationPermit._(
    this._owner,
    this.account,
    this.sessionRevision,
    this.scopeRevision,
    this.regionGeneration,
    this.libraryId,
  );
  final SourceSessionRegistry _owner;
  final SourceAccount account;
  final int sessionRevision;
  final int scopeRevision;
  final int regionGeneration;
  final String? libraryId;
  bool get isValid => _owner.accepts(this);
  void requireValid() {
    if (!isValid) throw StateError('Source permission revoked');
  }

  /// Both dispatch and receipt use the same frozen permit.
  Future<T> dispatch<T>(Future<T> Function(EmbyClient client) request) async {
    requireValid();
    final client = _owner._sessions[account.configuredServerId]!.client;
    try {
      final result = await request(client);
      requireValid();
      return result;
    } catch (_) {
      requireValid();
      rethrow;
    }
  }
}

/// Frozen before locking; exposes only a single Stopped request, never a client.
class FrozenSourceStop {
  FrozenSourceStop._(
    this._owner,
    this.account,
    this._client,
    this._report,
    this._generation,
  );
  final SourceSessionRegistry _owner;
  final SourceAccount account;
  final EmbyClient _client;
  final PlaybackReport _report;
  final int _generation;
  bool _used = false;
  Future<void> reportStopped(RestrictedStopPermit permit) async {
    if (_used ||
        !permit.isValid ||
        !permit.belongsTo(_owner.access) ||
        permit.generation != _generation + 1) {
      throw StateError('Stop transaction revoked');
    }
    _used = true;
    try {
      await _client.reportStopped(_report);
    } finally {
      _client.clearSession();
    }
  }

  void _clear() {
    _used = true;
    _client.clearSession();
  }
}

enum ManualCheckStatus {
  unknown,
  available,
  timeout,
  needsLogin,
  identityMismatch,
  offline,
}

class ManualCheckResult {
  const ManualCheckResult(this.status, this.checkedAt);
  final ManualCheckStatus status;
  final DateTime checkedAt;
}

typedef SourceClientFactory = EmbyClient Function();
typedef MembershipCleanup =
    Future<void> Function(SourceAccount? account, String serverId);

/// Sole configuration/session/permission authority for multi-source consumers.
/// Factory MUST return a new client, never AuthController's active client.
class SourceSessionRegistry {
  SourceSessionRegistry({
    required this.access,
    required this.store,
    required this.credentials,
    required this.createClient,
  }) {
    access.addRevocationHook(_revokePrivate);
    access.addCleanupHook(_clearPrivate);
    access.addTerminationHook(_terminateStops);
  }
  final RegionAccessController access;
  final ServerListStore store;
  final CredentialStore credentials;
  final SourceClientFactory createClient;
  List<SavedServer> _servers = [];
  String? _lastServerId;
  final Map<String, SourceSession> _sessions = {};
  final Map<String, int> _scopes = {};
  final Set<String> _transitioning = {};
  final Set<MembershipCleanup> _migrationHooks = {};
  final Set<FrozenSourceStop> _frozenStops = {};

  FrozenSourceStop freezeStop(OperationPermit permit, PlaybackReport report) {
    permit.requireValid();
    if (!identical(permit._owner, this) ||
        permit.account.region != AccessRegion.private) {
      throw StateError('Private source permit required');
    }
    final source = _sessions[permit.account.configuredServerId]!.client;
    final client = createClient();
    if (_sessions.values.any((s) => identical(s.client, client))) {
      throw StateError('Stop client must be independent');
    }
    client.attachSession(
      baseUrl: source.baseUrl!,
      accessToken: source.accessToken!,
      userId: source.userId!,
      userAgent: source.customUserAgent,
    );
    final stop = FrozenSourceStop._(
      this,
      permit.account,
      client,
      report,
      access.generation,
    );
    _frozenStops.add(stop);
    return stop;
  }

  void _terminateStops() {
    for (final stop in _frozenStops) {
      stop._clear();
    }
    _frozenStops.clear();
  }

  int _revision = 0;
  final Map<String, int> _authAttempts = {};
  final Map<String, int> _checkAttempts = {};

  void _requireCurrent(SavedServer server, int scope, int generation) {
    if ((_scopes[server.id] ?? 0) != scope ||
        _allowed(server.id).region != server.region ||
        (server.region == AccessRegion.private &&
            generation != access.generation)) {
      throw StateError('Access revoked');
    }
  }

  Future<void>? _writes;
  int _writeTicket = 0;
  bool _loaded = false;
  late final ServerListStore ordinaryStore = _OrdinaryServerStore(this);
  Future<void> load() async {
    final snapshot = await store.load();
    _servers = snapshot.servers
        .map((s) => SavedServer.fromJson(s.toJson()))
        .toList();
    _lastServerId = snapshot.lastServerId;
    _loaded = true;
  }

  List<SavedServer> project(AccessRegion region) {
    if (!access.allows(region)) return const [];
    return List.unmodifiable(
      _servers.where(
        (s) => s.region == region && !_transitioning.contains(s.id),
      ),
    );
  }

  /// Legacy single-service login must not overwrite a hidden private identity.
  Future<void> requireOrdinaryServer(String id) async {
    if (!_loaded) await load();
    final current = _servers.where((s) => s.id == id).firstOrNull;
    if (current?.region == AccessRegion.private ||
        _transitioning.contains(id)) {
      throw StateError('Source unavailable in ordinary context');
    }
  }

  SavedServer _allowed(String id) {
    final server = _servers.where((s) => s.id == id).firstOrNull;
    if (server == null ||
        !access.allows(server.region) ||
        _transitioning.contains(id)) {
      throw StateError('Source unavailable');
    }
    return server;
  }

  Future<void> _commit(
    List<SavedServer> Function() change, {
    String? lastServerId,
    bool replaceLast = false,
  }) {
    final previous = _writes;
    final ticket = ++_writeTicket;
    final write = () async {
      try {
        try {
          if (previous != null) await previous;
        } catch (_) {
          /* a failed write does not poison the queue */
        }
        final next = change();
        await store.save(
          ServerListSnapshot(
            servers: next,
            lastServerId: replaceLast ? lastServerId : _lastServerId,
          ),
        );
        _servers = next;
        if (replaceLast) _lastServerId = lastServerId;
      } finally {
        if (_writeTicket == ticket) _writes = null;
      }
    }();
    _writes = write;
    return write;
  }

  Future<void> _update(
    String id,
    SavedServer Function(SavedServer) change, {
    bool duringTransition = false,
  }) => _commit(() {
    final current = duringTransition
        ? _servers.firstWhere((s) => s.id == id)
        : _allowed(id);
    if (!access.allows(current.region)) throw StateError('Source revoked');
    final next = change(current);
    return _servers.map((s) => s.id == id ? next : s).toList();
  });

  void _invalidate(String id) {
    _scopes[id] = (_scopes[id] ?? 0) + 1;
  }

  Future<void> configureScope(
    String id, {
    required bool participates,
    required Set<String> libraryIds,
  }) async {
    _allowed(id);
    final selected = libraryIds.toList()..sort();
    _invalidate(id);
    _transitioning.add(id);
    try {
      await _update(
        id,
        (server) => server.copyWith(
          participates: participates,
          libraryIds: selected,
          scopeKnown: true,
        ),
        duringTransition: true,
      );
    } finally {
      _transitioning.remove(id);
    }
  }

  /// Reconcile discovery by intersection: never select new/unknown libraries.
  Future<void> reconcileLibraries(String id, Set<String> available) async {
    final server = _allowed(id);
    await configureScope(
      id,
      participates: server.participates,
      libraryIds: server.libraryIds.where(available.contains).toSet(),
    );
  }

  Future<void> rename(String id, String nickname) {
    _allowed(id);
    return _update(id, (server) => server.copyWith(nickname: nickname));
  }

  Future<void> renameLine(String id, String lineId, String nickname) async {
    _allowed(id);
    await _update(
      id,
      (server) => server.copyWith(
        lines: server.lines
            .map((l) => l.id == lineId ? l.copyWith(nickname: nickname) : l)
            .toList(),
      ),
    );
  }

  Future<void> reorder(AccessRegion region, List<String> ids) async {
    final current = project(region);
    if (ids.toSet().length != current.length ||
        !current.every((s) => ids.contains(s.id))) {
      throw ArgumentError('Order must contain exactly the visible region');
    }
    final order = List<String>.of(ids);
    await _commit(() {
      final ordered = {for (final s in project(region)) s.id: s};
      if (ordered.length != order.length || !order.every(ordered.containsKey)) {
        throw StateError('Region changed');
      }
      var index = 0;
      return _servers
          .map((s) => s.region == region ? ordered[order[index++]]! : s)
          .toList();
    });
  }

  Future<void> reorderLines(String id, List<String> ids) async {
    final server = _allowed(id);
    final lines = {for (final line in server.lines) line.id: line};
    if (ids.length != lines.length ||
        ids.toSet().length != lines.length ||
        !ids.every(lines.containsKey)) {
      throw ArgumentError('Invalid line order');
    }
    final order = List<String>.of(ids);
    await _update(id, (current) {
      final latest = {for (final line in current.lines) line.id: line};
      if (latest.length != order.length || !order.every(latest.containsKey)) {
        throw StateError('Lines changed');
      }
      return current.copyWith(lines: order.map((id) => latest[id]!).toList());
    });
  }

  void addMembershipCleanup(MembershipCleanup hook) =>
      _migrationHooks.add(hook);
  void removeMembershipCleanup(MembershipCleanup hook) =>
      _migrationHooks.remove(hook);
  Future<void> move(
    String id,
    AccessRegion target, {
    Duration budget = const Duration(seconds: 3),
  }) async {
    final server = _allowed(id);
    if (target == server.region) return;
    if (!access.hasPin || !access.allows(AccessRegion.private)) {
      throw StateError('Private unlock required');
    }
    _transitioning.add(id);
    _invalidate(id);
    for (final stop
        in _frozenStops
            .where((s) => s.account.configuredServerId == id)
            .toList()) {
      stop._clear();
      _frozenStops.remove(stop);
    }
    final session = _sessions.remove(id);
    try {
      await Future.wait(
        _migrationHooks.map((hook) => hook(session?.account, id)),
      ).timeout(budget);
      if (!access.allows(AccessRegion.private)) {
        throw StateError('Access revoked during migration');
      }
      session?.client.clearSession();
      await _update(id, (current) {
        if (!access.allows(AccessRegion.private)) {
          throw StateError('Migration revoked');
        }
        return current.copyWith(region: target);
      }, duringTransition: true);
    } finally {
      session?.client.clearSession();
      _transitioning.remove(id);
    }
  }

  Future<SourceSession> authenticate(String id) async {
    final server = _allowed(id);
    final scope = _scopes[id] ?? 0;
    final generation = access.generation;
    final attempt = (_authAttempts[id] ?? 0) + 1;
    _authAttempts[id] = attempt;
    final client = createClient();
    if (_sessions.values.any((s) => identical(s.client, client))) {
      throw StateError('Client factory must be independent');
    }
    try {
      final info = await client.getPublicInfo(Uri.parse(server.baseUrl));
      _requireCurrent(server, scope, generation);
      final expected = server.verifiedServerId ?? server.id;
      if (info.id != expected) throw StateError('Server identity mismatch');
      final stored = await credentials.read(id);
      _requireCurrent(server, scope, generation);
      if (stored == null) throw StateError('Login required');
      client.attachSession(
        baseUrl: Uri.parse(server.baseUrl),
        accessToken: stored.accessToken,
        userId: stored.userId,
        userAgent: server.userAgent,
      );
      final user = await client.getUser();
      if (user.id != stored.userId) {
        throw StateError('Account identity mismatch');
      }
      if ((_scopes[id] ?? 0) != scope ||
          _allowed(id).region != server.region ||
          (server.region == AccessRegion.private &&
              generation != access.generation)) {
        throw StateError('Access revoked');
      }
      if (_authAttempts[id] != attempt) {
        throw StateError('Authentication superseded');
      }
      final session = SourceSession._(
        SourceAccount(
          region: server.region,
          configuredServerId: id,
          verifiedServerId: info.id,
          userId: user.id,
        ),
        client,
        ++_revision,
      );
      _sessions.remove(id)?.client.clearSession();
      _sessions[id] = session;
      client.onSessionExpired = () {
        if (identical(_sessions[id], session)) {
          _sessions.remove(id);
          _invalidate(id);
        }
        client.clearSession();
      };
      await _update(
        id,
        (current) => current.copyWith(verifiedServerId: info.id),
      );
      _requireCurrent(server, scope, generation);
      if (_authAttempts[id] != attempt) {
        throw StateError('Authentication superseded');
      }
      return session;
    } catch (_) {
      client.clearSession();
      rethrow;
    }
  }

  OperationPermit permit(SourceAccount account, {String? libraryId}) {
    final server = _allowed(account.configuredServerId);
    final session = _sessions[server.id];
    if (session?.account != account ||
        !server.participates ||
        !server.scopeKnown ||
        server.libraryIds.isEmpty ||
        (libraryId != null && !server.libraryIds.contains(libraryId))) {
      throw StateError('Source outside allowed scope');
    }
    return OperationPermit._(
      this,
      account,
      session!.revision,
      _scopes[server.id] ?? 0,
      access.generation,
      libraryId,
    );
  }

  bool accepts(OperationPermit permit) {
    if (!identical(permit._owner, this)) return false;
    try {
      final server = _allowed(permit.account.configuredServerId);
      final session = _sessions[server.id];
      return server.region == permit.account.region &&
          server.participates &&
          server.scopeKnown &&
          server.libraryIds.isNotEmpty &&
          session?.account == permit.account &&
          session?.client.hasSession == true &&
          session?.client.userId == permit.account.userId &&
          session?.revision == permit.sessionRevision &&
          (_scopes[server.id] ?? 0) == permit.scopeRevision &&
          (server.region != AccessRegion.private ||
              access.generation == permit.regionGeneration) &&
          (permit.libraryId == null ||
              server.libraryIds.contains(permit.libraryId));
    } on StateError {
      return false;
    }
  }

  Future<ManualCheckResult> check(
    String id, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final server = _allowed(id);
    final scope = _scopes[id] ?? 0;
    final generation = access.generation;
    final client = createClient();
    if (_sessions.values.any((s) => identical(s.client, client))) {
      throw StateError('Check client must be independent');
    }
    final attempt = (_checkAttempts[id] ?? 0) + 1;
    _checkAttempts[id] = attempt;
    var finished = false;
    void guard() {
      _requireCurrent(server, scope, generation);
      if (finished || _checkAttempts[id] != attempt) {
        throw StateError('Check superseded');
      }
    }

    var status = ManualCheckStatus.unknown;
    try {
      status = await (() async {
        final info = await client.getPublicInfo(Uri.parse(server.baseUrl));
        guard();
        if (info.id != (server.verifiedServerId ?? id)) {
          return ManualCheckStatus.identityMismatch;
        }
        final stored = await credentials.read(id);
        guard();
        if (stored == null) return ManualCheckStatus.needsLogin;
        client.attachSession(
          baseUrl: Uri.parse(server.baseUrl),
          accessToken: stored.accessToken,
          userId: stored.userId,
          userAgent: server.userAgent,
        );
        final user = await client.getUser();
        return user.id == stored.userId
            ? ManualCheckStatus.available
            : ManualCheckStatus.needsLogin;
      })().timeout(timeout);
    } on TimeoutException {
      status = ManualCheckStatus.timeout;
    } on EmbyException catch (error) {
      status = switch (error.kind) {
        EmbyFailureKind.timeout => ManualCheckStatus.timeout,
        EmbyFailureKind.sessionExpired ||
        EmbyFailureKind.invalidCredentials => ManualCheckStatus.needsLogin,
        _ => ManualCheckStatus.offline,
      };
    } catch (_) {
      status = ManualCheckStatus.offline;
    } finally {
      finished = true;
      client.clearSession();
    }
    if (_checkAttempts[id] != attempt) throw StateError('Check superseded');
    if ((_scopes[id] ?? 0) != scope ||
        _allowed(id).region != server.region ||
        (server.region == AccessRegion.private &&
            generation != access.generation)) {
      throw StateError('Check revoked');
    }
    final result = ManualCheckResult(status, DateTime.now());
    await _update(id, (current) {
      _requireCurrent(server, scope, generation);
      if (_checkAttempts[id] != attempt) throw StateError('Check superseded');
      return current.copyWith(
        checkStatus: status.name,
        checkedAt: result.checkedAt,
      );
    });
    return result;
  }

  void _revokePrivate() {
    for (final server in _servers.where(
      (s) => s.region == AccessRegion.private,
    )) {
      _invalidate(server.id);
    }
  }

  Future<void> _clearPrivate(RestrictedStopPermit permit) async {
    // Consumers freeze their own stop-only credentials before revocation.
    for (final id in _sessions.keys.toList()) {
      if (_sessions[id]!.account.region == AccessRegion.private) {
        _sessions.remove(id)!.client.clearSession();
      }
    }
  }

  Future<void> _saveOrdinary(
    ServerListSnapshot snapshot,
    Map<String, SavedServer> baseline,
  ) async {
    if (!_loaded) await load();
    final incoming = {for (final s in snapshot.servers) s.id: s};
    if (incoming.length != snapshot.servers.length ||
        snapshot.servers.any((s) => s.region != AccessRegion.ordinary)) {
      throw StateError('Ordinary store cannot write private members');
    }
    for (final s in _servers.where((s) => s.region == AccessRegion.private)) {
      if (incoming.containsKey(s.id)) {
        throw StateError(
          'Private identity is not writable from ordinary context',
        );
      }
    }
    final removed = project(
      AccessRegion.ordinary,
    ).where((s) => !incoming.containsKey(s.id)).toList();
    for (final server in removed) {
      _transitioning.add(server.id);
      _invalidate(server.id);
      final session = _sessions.remove(server.id);
      try {
        await Future.wait(
          _migrationHooks.map((hook) => hook(session?.account, server.id)),
        ).timeout(const Duration(seconds: 3));
      } catch (_) {
        _transitioning.remove(server.id);
        session?.client.clearSession();
        rethrow;
      }
      session?.client.clearSession();
    }
    try {
      await _commit(
        () {
          final next = <SavedServer>[];
          for (final current in _servers) {
            if (current.region == AccessRegion.private) {
              next.add(current);
              continue;
            }
            final updated = incoming.remove(current.id);
            if (updated == null) continue;
            final previous = baseline[current.id];
            next.add(
              current.copyWith(
                name: updated.name,
                username: updated.username,
                nickname: previous?.nickname == updated.nickname
                    ? current.nickname
                    : updated.nickname,
                lines: updated.lines,
                activeLineId: updated.activeLineId,
                userAgent: updated.userAgent,
              ),
            );
          }
          next.addAll(
            incoming.values.map(
              (s) => SavedServer.fromJson(
                s
                    .copyWith(
                      region: AccessRegion.ordinary,
                      libraryIds: const [],
                      scopeKnown: false,
                    )
                    .toJson(),
              ),
            ),
          );
          return next;
        },
        replaceLast: true,
        lastServerId: snapshot.lastServerId,
      );
    } finally {
      for (final server in removed) {
        _transitioning.remove(server.id);
      }
    }
  }

  void dispose() {
    access.removeRevocationHook(_revokePrivate);
    access.removeCleanupHook(_clearPrivate);
    access.removeTerminationHook(_terminateStops);
    _terminateStops();
    for (final session in _sessions.values) {
      session.client.clearSession();
    }
    _sessions.clear();
  }
}

/// Compatibility projection for the existing single-service AuthController.
/// Its writes are reconciled by the registry, never sent straight to disk.
class _OrdinaryServerStore implements ServerListStore {
  _OrdinaryServerStore(this.registry);
  final SourceSessionRegistry registry;
  Map<String, SavedServer> _baseline = {};
  @override
  Future<ServerListSnapshot> load() async {
    if (!registry._loaded) await registry.load();
    final ordinary = registry.project(AccessRegion.ordinary);
    _baseline = {for (final s in ordinary) s.id: s};
    return ServerListSnapshot(
      servers: ordinary,
      lastServerId: _baseline.containsKey(registry._lastServerId)
          ? registry._lastServerId
          : null,
    );
  }

  @override
  Future<void> save(ServerListSnapshot snapshot) async {
    await registry._saveOrdinary(snapshot, _baseline);
    _baseline = {
      for (final s in registry.project(AccessRegion.ordinary)) s.id: s,
    };
  }
}
