import 'dart:async';
import 'dart:convert';

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

/// Captured before any asynchronous login/logout/restore work.
class CredentialCommit {
  CredentialCommit._(this.owner, this.id, this.scope);
  final SourceSessionRegistry owner;
  final String id;
  final int scope;
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
  PlaybackReport _report;
  final int _generation;

  /// Refresh only the position/intent of the already frozen session while its
  /// normal permit is valid. Lock cleanup never takes a new playback snapshot.
  void updateReport(OperationPermit permit, PlaybackReport report) {
    permit.requireValid();
    if (_used ||
        permit.account != account ||
        permit.regionGeneration != _generation ||
        report.itemId != _report.itemId ||
        report.mediaSourceId != _report.mediaSourceId ||
        report.playSessionId != _report.playSessionId) {
      throw StateError('Frozen stop owner changed');
    }
    _report = report;
  }

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
  final Set<String> _credentialChanges = {};
  final Set<MembershipCleanup> _migrationHooks = {};
  final Set<void Function(String)> _sourceRevocations = {};
  void addSourceRevocation(void Function(String) hook) =>
      _sourceRevocations.add(hook);
  void removeSourceRevocation(void Function(String) hook) =>
      _sourceRevocations.remove(hook);
  final Set<FrozenSourceStop> _frozenStops = {};

  void releaseStop(FrozenSourceStop stop) {
    if (_frozenStops.remove(stop)) stop._clear();
  }

  FrozenSourceStop freezeStop(
    OperationPermit permit,
    PlaybackReport report, {
    EmbyClient? actualClient,
  }) {
    permit.requireValid();
    if (!identical(permit._owner, this) ||
        permit.account.region != AccessRegion.private) {
      throw StateError('Private source permit required');
    }
    final registered = _sessions[permit.account.configuredServerId]!.client;
    final source = actualClient ?? registered;
    if (source.userId != permit.account.userId ||
        source.accessToken != registered.accessToken ||
        source.baseUrl == null) {
      throw StateError('Stop credentials do not belong to permitted source');
    }
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
  final Map<String, Future<SourceSession>> _sessionAcquisitions = {};
  final Map<String, int> _checkAttempts = {};

  void _requireCurrent(SavedServer server, int scope, int generation) {
    if (_credentialChanges.contains(server.id) ||
        (_scopes[server.id] ?? 0) != scope ||
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

  Future<CredentialCommit> beginOrdinaryCredentials(String id) async {
    await requireOrdinaryServer(id);
    return CredentialCommit._(this, id, _scopes[id] ?? 0);
  }

  void _guardCredentials(CredentialCommit commit) {
    if (!identical(commit.owner, this) ||
        (_scopes[commit.id] ?? 0) != commit.scope ||
        _transitioning.contains(commit.id) ||
        _servers.any(
          (s) => s.id == commit.id && s.region != AccessRegion.ordinary,
        )) {
      throw StateError('Credential operation revoked');
    }
  }

  /// Shares the configuration writer. Migration revokes synchronously; if it
  /// starts during secure-store IO, restore the old value before it can commit.
  Future<void> commitOrdinaryCredentials(
    CredentialCommit commit,
    StoredCredentials? value,
  ) => _enqueue(() async {
    _guardCredentials(commit);
    final previous = await credentials.read(commit.id);
    _guardCredentials(commit);
    _sessions.remove(commit.id)?.client.clearSession();
    _invalidate(commit.id);
    _credentialChanges.add(commit.id);
    final writing = CredentialCommit._(this, commit.id, _scopes[commit.id]!);
    try {
      if (value == null) {
        await credentials.delete(commit.id);
      } else {
        await credentials.write(commit.id, value);
      }
      _guardCredentials(writing);
    } catch (_) {
      if (previous == null) {
        await credentials.delete(commit.id);
      } else {
        await credentials.write(commit.id, previous);
      }
      rethrow;
    } finally {
      _credentialChanges.remove(commit.id);
    }
  });

  Future<void> _enqueue(Future<void> Function() action) {
    final previous = _writes;
    final ticket = ++_writeTicket;
    final write = () async {
      try {
        try {
          if (previous != null) await previous;
        } catch (_) {
          /* a failed write does not poison the queue */
        }
        await action();
      } finally {
        if (_writeTicket == ticket) _writes = null;
      }
    }();
    _writes = write;
    return write;
  }

  Future<void> _commit(
    List<SavedServer> Function() change, {
    String? lastServerId,
    bool replaceLast = false,
  }) => _enqueue(() async {
    final next = change();
    await store.save(
      ServerListSnapshot(
        servers: next,
        lastServerId: replaceLast ? lastServerId : _lastServerId,
      ),
    );
    _servers = next;
    if (replaceLast) _lastServerId = lastServerId;
  });

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
    for (final hook in List.of(_sourceRevocations)) {
      try {
        hook(id);
      } catch (_) {
        /* one consumer cannot delay revocation */
      }
    }
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

  bool _participatingLibrary(
    String id,
    AccessRegion region,
    String libraryId,
  ) =>
      libraryId.isNotEmpty &&
      project(region).any(
        (server) =>
            server.id == id &&
            server.participates &&
            server.scopeKnown &&
            server.libraryIds.contains(libraryId),
      );

  /// Read-only resolution through the same region/library authority as permit.
  /// Unknown, hidden, nonparticipating and unauthenticated sources all return
  /// null; this never probes a server or reveals a private membership.
  SourceAccount? sessionAccount(
    String id, {
    required AccessRegion region,
    required String libraryId,
  }) {
    if (!_participatingLibrary(id, region, libraryId)) return null;
    final account = _sessions[id]?.account;
    if (account == null || account.region != region) return null;
    try {
      permit(account, libraryId: libraryId).requireValid();
      return account;
    } on StateError {
      return null;
    }
  }

  /// Query consumers reuse valid sessions. Concurrent first acquisitions share
  /// authentication rather than replacing one another's session revision.
  /// Explicit authenticate remains available for deliberate credential refresh.
  Future<SourceAccount> acquireAccount(
    String id, {
    required AccessRegion region,
    required String libraryId,
  }) async {
    if (!_participatingLibrary(id, region, libraryId)) {
      throw StateError('Source outside allowed scope');
    }
    final existing = sessionAccount(id, region: region, libraryId: libraryId);
    if (existing != null) return existing;
    final acquisition = _sessionAcquisitions[id] ??= authenticate(id);
    try {
      final session = await acquisition;
      if (session.account.region != region ||
          !_participatingLibrary(id, region, libraryId)) {
        throw StateError('Source outside allowed scope');
      }
      permit(session.account, libraryId: libraryId).requireValid();
      return session.account;
    } finally {
      if (identical(_sessionAcquisitions[id], acquisition)) {
        _sessionAcquisitions.remove(id);
      }
    }
  }

  Future<SourceSession> authenticate(String id) async {
    final server = _allowed(id);
    final scope = _scopes[id] ?? 0;
    final generation = access.generation;
    _requireCurrent(server, scope, generation);
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
    if (_credentialChanges.contains(server.id) ||
        session?.account != account ||
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
      return !_credentialChanges.contains(server.id) &&
          server.region == permit.account.region &&
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
    _requireCurrent(server, scope, generation);
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
    final removed = project(AccessRegion.ordinary)
        .where((s) => baseline.containsKey(s.id) && !incoming.containsKey(s.id))
        .toList();
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
          if (_servers.any(
                (s) =>
                    s.region == AccessRegion.private &&
                    incoming.containsKey(s.id),
              ) ||
              incoming.keys.any(_transitioning.contains)) {
            throw StateError('Ordinary snapshot revoked by membership change');
          }
          final next = <SavedServer>[];
          for (final current in _servers) {
            if (current.region == AccessRegion.private) {
              next.add(current);
              continue;
            }
            final updated = incoming.remove(current.id);
            if (updated == null) {
              if (!baseline.containsKey(current.id)) next.add(current);
              continue;
            }
            final previous = baseline[current.id];
            if (previous == null) {
              throw StateError('Member appeared after ordinary snapshot');
            }
            final merged = _mergeDelta(
              current.toJson(),
              previous.toJson(),
              updated.toJson(),
            );
            // Region, participation, verification and checks remain registry-owned.
            for (final key in [
              'region',
              'participates',
              'libraryIds',
              'scopeKnown',
              'verifiedServerId',
              'checkedAt',
              'checkStatus',
            ]) {
              merged[key] = current.toJson()[key];
            }
            merged['lines'] = _mergeLines(
              current.lines,
              previous.lines,
              updated.lines,
            );
            next.add(SavedServer.fromJson(merged));
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

  static Map<String, dynamic> _mergeDelta(
    Map<String, dynamic> current,
    Map<String, dynamic> baseline,
    Map<String, dynamic> incoming,
  ) {
    final result = Map<String, dynamic>.of(current);
    for (final key in {...baseline.keys, ...incoming.keys}) {
      if (jsonEncode(baseline[key]) != jsonEncode(incoming[key])) {
        if (incoming.containsKey(key)) {
          result[key] = incoming[key];
        } else {
          result.remove(key);
        }
      }
    }
    return result;
  }

  static List<Map<String, dynamic>> _mergeLines(
    List<ServerLine> current,
    List<ServerLine> baseline,
    List<ServerLine> incoming,
  ) {
    final old = {for (final l in baseline) l.id: l};
    final edits = {for (final l in incoming) l.id: l};
    final result = <String, Map<String, dynamic>>{};
    for (final line in current) {
      final edit = edits.remove(line.id);
      if (edit == null) {
        if (!old.containsKey(line.id)) result[line.id] = line.toJson();
      } else {
        result[line.id] = _mergeDelta(
          line.toJson(),
          old[line.id]?.toJson() ?? {},
          edit.toJson(),
        );
      }
    }
    for (final line in edits.values) {
      if (old.containsKey(line.id)) {
        throw StateError('Line removed since snapshot');
      }
      result[line.id] = line.toJson();
    }
    final oldOrder = baseline.map((l) => l.id).toList();
    final newOrder = incoming.map((l) => l.id).toList();
    if (jsonEncode(oldOrder) != jsonEncode(newOrder)) {
      return [
        for (final id in newOrder)
          if (result.containsKey(id)) result.remove(id)!,
        ...result.values,
      ];
    }
    return result.values.toList();
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
    _sourceRevocations.clear();
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
    // Track what this consumer actually observed, not newer registry values.
    _baseline = {for (final s in snapshot.servers) s.id: s};
  }
}
