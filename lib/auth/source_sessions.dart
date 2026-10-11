import 'package:rillight/media_server/capabilities.dart';
import 'package:rillight/media_server/media_server_client.dart';
import 'dart:async';
import 'dart:convert';

import 'credential_store.dart';
import '../media_server/authentication.dart';
import 'cloud_credentials.dart';
import 'region_access.dart';
import 'server_list_store.dart';
import '../media_server/errors.dart';
import '../media_server/playback.dart';

/// Account identity only. Media item/version identity belongs to aggregation.
class SourceAccount {
  const SourceAccount({
    required this.region,
    required this.configuredServerId,
    required this.verifiedServerId,
    required this.userId,
    this.serviceType = MediaServerType.emby,
    this.cloudAccountId,
    this.homeUserId,
  });
  final MediaServerType serviceType;
  final String? cloudAccountId;
  final String? homeUserId;
  final AccessRegion region;
  final String configuredServerId;
  final String verifiedServerId;
  final String userId;
  @override
  bool operator ==(Object other) =>
      other is SourceAccount &&
      serviceType == other.serviceType &&
      cloudAccountId == other.cloudAccountId &&
      homeUserId == other.homeUserId &&
      region == other.region &&
      configuredServerId == other.configuredServerId &&
      verifiedServerId == other.verifiedServerId &&
      userId == other.userId;
  @override
  int get hashCode => Object.hash(
    serviceType,
    region,
    configuredServerId,
    verifiedServerId,
    userId,
    cloudAccountId,
    homeUserId,
  );
}

/// Captured before any asynchronous login/logout/restore work.
class CredentialCommit {
  CredentialCommit._(this.owner, this.id, this.scope);
  final SourceSessionRegistry owner;
  final String id;
  final int scope;
}

/// An authorization transaction is captured before password/Quick Connect/PIN
/// or Home switching starts. Polling can continue only while this is current.
class SourceAuthorization {
  SourceAuthorization._(
    this._owner,
    this.id,
    this.serviceType,
    this.region,
    this._scope,
    this._generation,
    this._attempt,
    this._cloudRevision,
  );
  final SourceSessionRegistry _owner;
  final String id;
  final MediaServerType serviceType;
  final AccessRegion region;
  final int _scope;
  final int _generation;
  final int _attempt;
  final int _cloudRevision;
  bool _finished = false;
  bool get isValid => _owner._acceptsAuthorization(this);
  void requireValid() {
    if (!isValid) throw StateError('Authorization revoked');
  }

  Future<AuthorizationStatus> poll(AuthorizationAttempt attempt) async {
    requireValid();
    final result = await attempt.poll();
    requireValid();
    return result;
  }

  Future<AuthorizationGrant> exchange(AuthorizationAttempt attempt) async {
    requireValid();
    final result = await attempt.exchange();
    requireValid();
    return result;
  }

  void cancel() {
    _finished = true;
    if (identical(_owner._pendingAuthorizations[id], this)) {
      _owner._pendingAuthorizations.remove(id);
    }
  }
}

class SourceSession {
  SourceSession._(this.account, this.client, this.revision);
  final SourceAccount account;
  final MediaServerClient client;
  final int revision;
}

class OperationPermit {
  OperationPermit._(
    this._owner,
    this.account,
    this.sessionRevision,
    this.scopeRevision,
    this.regionGeneration,
    this.libraryId, {
    this.sessionOnly = false,
  });
  final SourceSessionRegistry _owner;
  final SourceAccount account;
  final int sessionRevision;
  final int scopeRevision;
  final int regionGeneration;
  final String? libraryId;

  /// 聚合视界打开条目时只要求该服务器会话有效，不要求库范围已勾选。
  final bool sessionOnly;
  bool get isValid => _owner.accepts(this);
  void requireValid() {
    if (!isValid) throw StateError('Source permission revoked');
  }

  /// Both dispatch and receipt use the same frozen permit.
  Future<T> dispatch<T>(
    Future<T> Function(MediaServerClient client) request,
  ) async {
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
  final MediaServerClient _client;
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
      await _client.stopPlayback(_report);
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

typedef SourceClientFactory = MediaServerClient Function();
typedef SessionIdentityVerifier =
    Future<void> Function(
      SavedServer server,
      StoredCredentials credentials,
      MediaServerClient client,
    );
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
    this.createProviderClient,
    this.sessionIdentityVerifier,
  }) {
    access.addRevocationHook(_revokePrivate);
    access.addCleanupHook(_clearPrivate);
    access.addTerminationHook(_terminateStops);
  }
  final RegionAccessController access;
  final ServerListStore store;
  final CredentialStore credentials;
  final SourceClientFactory createClient;
  final SessionIdentityVerifier? sessionIdentityVerifier;
  final MediaServerClient Function(MediaServerType)? createProviderClient;
  MediaServerClient _clientFor(MediaServerType type) {
    final client = createProviderClient?.call(type) ?? createClient();
    if (client.serviceType != type) {
      throw StateError('Client factory does not support the requested service');
    }
    return client;
  }

  bool _credentialsMatch(SavedServer server, StoredCredentials value) =>
      value.serviceType == server.serviceType &&
      value.cloudAccountId == server.cloudAccountId &&
      value.homeUserId == server.homeUserId &&
      value.cloudCredentialRef == server.cloudCredentialRef &&
      value.resourceCredentialRef == server.resourceCredentialRef;

  List<SavedServer> _servers = [];
  String? _lastServerId;
  final Map<String, SourceSession> _sessions = {};
  final Map<String, int> _scopes = {};
  final Set<String> _transitioning = {};
  final Set<String> _credentialChanges = {};
  final Set<String> _cloudDisconnects = {};
  int _cloudRevision = 0;
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
    MediaServerClient? actualClient,
  }) {
    permit.requireValid();
    if (!identical(permit._owner, this) ||
        permit.account.region != AccessRegion.private) {
      throw StateError('Private source permit required');
    }
    final registered = _sessions[permit.account.configuredServerId]!.client;
    final source = actualClient ?? registered;
    if (source.serviceType != permit.account.serviceType ||
        source.userId != permit.account.userId ||
        source.accessToken != registered.accessToken ||
        source.baseUrl == null) {
      throw StateError('Stop credentials do not belong to permitted source');
    }
    final client = _clientFor(permit.account.serviceType);
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
  final Map<String, SourceAuthorization> _pendingAuthorizations = {};
  final Map<String, Future<SourceSession>> _sessionAcquisitions = {};
  final Map<String, int> _checkAttempts = {};

  void _requireCurrent(SavedServer server, int scope, int generation) {
    if (_cloudDisconnects.contains(server.cloudCredentialRef) ||
        _pendingAuthorizations.containsKey(server.id) ||
        _credentialChanges.contains(server.id) ||
        (_scopes[server.id] ?? 0) != scope ||
        _allowed(server.id).region != server.region ||
        _allowed(server.id).serviceType != server.serviceType ||
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

  Future<void> requireOrdinaryIdentity(
    MediaServerType type,
    String remoteId,
  ) async {
    if (!_loaded) await load();
    if (_servers.any(
      (s) =>
          s.serviceType == type &&
          (s.verifiedServerId ?? s.id) == remoteId &&
          (s.region != AccessRegion.ordinary || _transitioning.contains(s.id)),
    )) {
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

  Future<SourceAuthorization> beginAuthorization({
    required MediaServerType serviceType,
    required AccessRegion region,
    String? configuredServerId,
  }) async {
    if (!_loaded) await load();
    if (!access.allows(region)) throw StateError('Region locked');
    final id = configuredServerId ?? 'source-${generateDeviceId()}';
    final existing = _servers.where((s) => s.id == id).firstOrNull;
    if (configuredServerId != null &&
        (existing == null ||
            existing.region != region ||
            existing.serviceType != serviceType)) {
      throw StateError('Source identity mismatch');
    }
    if (_cloudDisconnects.contains(existing?.cloudCredentialRef) ||
        _transitioning.contains(id) ||
        _credentialChanges.contains(id)) {
      throw StateError('Source changing');
    }
    // A Home switch/relogin revokes the old user immediately, before PIN IO.
    _sessions.remove(id)?.client.clearSession();
    _invalidate(id);
    final attempt = (_authAttempts[id] ?? 0) + 1;
    _authAttempts[id] = attempt;
    final authorization = SourceAuthorization._(
      this,
      id,
      serviceType,
      region,
      _scopes[id]!,
      access.generation,
      attempt,
      _cloudRevision,
    );
    _pendingAuthorizations[id] = authorization;
    return authorization;
  }

  bool _acceptsAuthorization(SourceAuthorization authorization) =>
      identical(authorization._owner, this) &&
      !authorization._finished &&
      (authorization.serviceType != MediaServerType.plex ||
          authorization._cloudRevision == _cloudRevision) &&
      access.allows(authorization.region) &&
      (authorization.region != AccessRegion.private ||
          authorization._generation == access.generation) &&
      _scopes[authorization.id] == authorization._scope &&
      _authAttempts[authorization.id] == authorization._attempt &&
      !_transitioning.contains(authorization.id);

  /// Verify resource/server/effective-user correspondence before committing.
  /// Discovery alone never imports or selects a library.
  Future<SourceSession> commitAuthorization(
    SourceAuthorization authorization, {
    required SavedServer server,
    required StoredCredentials value,
  }) async {
    void guard() {
      authorization.requireValid();
      if (_cloudDisconnects.contains(server.cloudCredentialRef)) {
        throw StateError('Cloud authorization revoked');
      }
    }

    guard();
    if (server.id != authorization.id ||
        server.region != authorization.region ||
        server.serviceType != authorization.serviceType ||
        !_credentialsMatch(server, value) ||
        value.accessToken.isEmpty ||
        value.userId.isEmpty ||
        server.verifiedServerId == null) {
      throw StateError('Authorization identity mismatch');
    }
    final client = _clientFor(server.serviceType);
    try {
      client.setUserAgent(server.userAgent);
      final info = await client.getPublicInfo(Uri.parse(server.baseUrl));
      guard();
      if (info.id != server.verifiedServerId) {
        throw StateError('Server identity mismatch');
      }
      client.attachSession(
        baseUrl: Uri.parse(server.baseUrl),
        accessToken: value.accessToken,
        userId: value.userId,
        userAgent: server.userAgent,
      );
      await sessionIdentityVerifier?.call(server, value, client);
      guard();
      final user = await client.getUser();
      guard();
      if (user.id != value.userId) {
        throw StateError('Account identity mismatch');
      }
      await _enqueue(() async {
        guard();
        final previous = await credentials.read(server.id);
        guard();
        final previousServers = List<SavedServer>.of(_servers);
        final old = _servers.where((s) => s.id == server.id).firstOrNull;
        if (old != null &&
            (old.serviceType != server.serviceType ||
                (old.verifiedServerId ?? old.id) != server.verifiedServerId ||
                old.region != server.region)) {
          throw StateError('Source identity changed');
        }
        final preserveScope =
            old != null &&
            previous != null &&
            previous.userId == value.userId &&
            previous.homeUserId == value.homeUserId &&
            previous.cloudAccountId == value.cloudAccountId;
        final saved = server.copyWith(
          libraryIds: preserveScope ? old.libraryIds : const [],
          scopeKnown: preserveScope ? old.scopeKnown : false,
          participates: old?.participates ?? server.participates,
        );
        var savedConfig = false;
        _credentialChanges.add(server.id);
        try {
          await credentials.write(server.id, value);
          guard();
          final next = [
            for (final s in _servers)
              if (s.id != server.id) s,
            saved,
          ];
          await store.save(
            ServerListSnapshot(servers: next, lastServerId: _lastServerId),
          );
          savedConfig = true;
          guard();
          _servers = next;
        } catch (_) {
          if (savedConfig) {
            await store.save(
              ServerListSnapshot(
                servers: previousServers,
                lastServerId: _lastServerId,
              ),
            );
          }
          if (previous == null) {
            await credentials.delete(server.id);
          } else {
            await credentials.write(server.id, previous);
          }
          rethrow;
        } finally {
          _credentialChanges.remove(server.id);
        }
      });
      guard();
      authorization.cancel();
      final session = SourceSession._(
        SourceAccount(
          serviceType: server.serviceType,
          region: server.region,
          configuredServerId: server.id,
          verifiedServerId: server.verifiedServerId!,
          userId: value.userId,
          cloudAccountId: value.cloudAccountId,
          homeUserId: value.homeUserId,
        ),
        client,
        ++_revision,
      );
      _sessions.remove(server.id)?.client.clearSession();
      _sessions[server.id] = session;
      client.onSessionExpired = () {
        if (identical(_sessions[server.id], session)) {
          _sessions.remove(server.id);
          _invalidate(server.id);
        }
        client.clearSession();
      };
      _notifySourceChange(server.id);
      return session;
    } catch (_) {
      authorization.cancel();
      client.clearSession();
      rethrow;
    }
  }

  /// Source logout never deletes a cloud grant shared with another source.
  Future<void> logoutSource(String id, {bool remove = false}) async {
    final server = _allowed(id);
    _pendingAuthorizations.remove(id)?.cancel();
    _invalidate(id);
    _authAttempts[id] = (_authAttempts[id] ?? 0) + 1;
    final session = _sessions.remove(id);
    _transitioning.add(id);
    try {
      await Future.wait(
        _migrationHooks.map((hook) => hook(session?.account, id)),
      );
      await _enqueue(() async {
        await credentials.delete(id);
        if (remove) {
          final next = _servers.where((s) => s.id != id).toList();
          await store.save(
            ServerListSnapshot(
              servers: next,
              lastServerId: _lastServerId == id ? null : _lastServerId,
            ),
          );
          _servers = next;
          if (_lastServerId == id) _lastServerId = null;
        }
      });
      // Deliberately retain cloud/device material. Explicit account disconnect
      // is the only operation that may remove it.
      if (server.serviceType != MediaServerType.plex) {
        await session?.client.logout();
      }
    } finally {
      session?.client.clearSession();
      _transitioning.remove(id);
      _notifySourceChange(id);
    }
  }

  /// Caller presents these visible references before requesting a whole-account
  /// disconnect. Hidden/private bindings must first be unlocked.
  List<String> cloudBindings(String credentialRef) {
    final bindings = _servers
        .where((s) => s.cloudCredentialRef == credentialRef)
        .toList();
    if (bindings.any((s) => !access.allows(s.region))) {
      throw StateError('Region locked');
    }
    return List.unmodifiable(bindings.map((s) => s.id));
  }

  Future<void> disconnectCloudAccount(
    String credentialRef,
    CloudCredentialStore cloud,
  ) async {
    final ids = cloudBindings(credentialRef);
    if (!_cloudDisconnects.add(credentialRef)) {
      throw StateError('Account disconnect pending');
    }
    _cloudRevision++;
    try {
      // Block reacquisition for every binding before the first asynchronous IO.
      for (final id in ids) {
        _invalidate(id);
        _authAttempts[id] = (_authAttempts[id] ?? 0) + 1;
      }
      for (final id in ids) {
        await logoutSource(id);
      }
      await cloud.deleteCredential(credentialRef);
    } finally {
      _cloudDisconnects.remove(credentialRef);
    }
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
          (s) =>
              s.id == commit.id &&
              (s.region != AccessRegion.ordinary ||
                  _cloudDisconnects.contains(s.cloudCredentialRef)),
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
    final configured = _servers.where((s) => s.id == commit.id).firstOrNull;
    if (value != null &&
        configured != null &&
        !_credentialsMatch(configured, value)) {
      throw StateError('Source credential identity mismatch');
    }
    final previousServers = List<SavedServer>.of(_servers);
    var savedConfig = false;
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
      if (value != null &&
          configured != null &&
          previous?.userId != value.userId) {
        final next = _servers
            .map(
              (s) => s.id == commit.id
                  ? s.copyWith(libraryIds: const [], scopeKnown: false)
                  : s,
            )
            .toList();
        await store.save(
          ServerListSnapshot(servers: next, lastServerId: _lastServerId),
        );
        savedConfig = true;
        _guardCredentials(writing);
        _servers = next;
      }
    } catch (error) {
      if (savedConfig) {
        await store.save(
          ServerListSnapshot(
            servers: previousServers,
            lastServerId: _lastServerId,
          ),
        );
      }
      // Failed cleanup after logout must never write the former credential
      // back and clear its durable revocation marker.
      if (value != null || error is! CredentialRevocationException) {
        if (previous == null) {
          await credentials.delete(commit.id);
        } else {
          await credentials.write(commit.id, previous);
        }
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
    _notifySourceChange(id);
  }

  void _notifySourceChange(String id) {
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
      // Consumers must also see the committed scope, not only its revocation.
      _notifySourceChange(id);
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
      _notifySourceChange(id);
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

  /// Deliberate management login; never changes the legacy active account.
  Future<void> login(String id, String username, String password) async {
    final server = _allowed(id);
    final client = _clientFor(server.serviceType);
    final authorization = await beginAuthorization(
      serviceType: server.serviceType,
      region: server.region,
      configuredServerId: id,
    );
    try {
      client.setUserAgent(server.userAgent);
      final info = await client.getPublicInfo(Uri.parse(server.baseUrl));
      authorization.requireValid();
      if (info.id != (server.verifiedServerId ?? id)) {
        throw StateError('Server identity mismatch');
      }
      final result = await client.authenticateByName(
        baseUrl: Uri.parse(server.baseUrl),
        username: username,
        password: password,
        serverId: info.id,
      );
      authorization.requireValid();
      await commitAuthorization(
        authorization,
        server: server.copyWith(
          username: username,
          verifiedServerId: info.id,
          authorizationMethod: AuthorizationMethod.password,
        ),
        value: StoredCredentials(
          serviceType: server.serviceType,
          accessToken: result.accessToken,
          userId: result.user.id,
          username: username,
          password: password.isEmpty ? null : password,
          cloudCredentialRef: server.cloudCredentialRef,
          cloudAccountId: server.cloudAccountId,
          homeUserId: server.homeUserId,
          resourceCredentialRef: server.resourceCredentialRef,
        ),
      );
    } finally {
      authorization.cancel();
      client.clearSession();
    }
  }

  /// Management discovery is not a media permit and never selects libraries.
  Future<Map<String, String>> discoverLibraries(String id) async {
    final session = await authenticate(id);
    final server = _allowed(id);
    final scope = _scopes[id] ?? 0;
    final generation = access.generation;
    final views = await session.client.getViews();
    _requireCurrent(server, scope, generation);
    if (!identical(_sessions[id], session)) {
      throw StateError('Discovery revoked');
    }
    return {for (final view in views) view.id: view.name};
  }

  /// 已保存的访问令牌直接挂上，并带上该服务器的 User-Agent。
  /// 内存里已有同一令牌的会话则复用，不再请求公开信息或重新登录。
  Future<SourceSession> ensureSession(String id) async {
    final server = _allowed(id);
    final scope = _scopes[id] ?? 0;
    final generation = access.generation;
    _requireCurrent(server, scope, generation);
    final reused = await _reuse(server, scope, generation);
    if (reused != null) return reused;
    final pending = _sessionAcquisitions[id];
    if (pending != null) return pending;
    final created = _attachStoredSession(server, scope, generation);
    _sessionAcquisitions[id] = created;
    try {
      return await created;
    } finally {
      if (identical(_sessionAcquisitions[id], created)) {
        _sessionAcquisitions.remove(id);
      }
    }
  }

  Future<SourceSession?> _reuse(
    SavedServer server,
    int scope,
    int generation,
  ) async {
    final session = _sessions[server.id];
    if (session == null ||
        session.account.region != server.region ||
        session.account.serviceType != server.serviceType ||
        !session.client.hasSession) {
      return null;
    }
    final stored = await credentials.read(server.id);
    _requireCurrent(server, scope, generation);
    if (stored == null ||
        !_credentialsMatch(server, stored) ||
        session.client.accessToken != stored.accessToken ||
        session.client.userId != stored.userId ||
        session.account.userId != stored.userId) {
      return null;
    }
    if (session.client.customUserAgent != server.normalizedUserAgent) {
      session.client.setUserAgent(server.userAgent);
    }
    return identical(_sessions[server.id], session) ? session : null;
  }

  Future<SourceSession> _attachStoredSession(
    SavedServer server,
    int scope,
    int generation,
  ) async {
    final client = _clientFor(server.serviceType);
    client.setUserAgent(server.userAgent);
    if (_sessions.values.any((s) => identical(s.client, client))) {
      throw StateError('Client factory must be independent');
    }
    try {
      final stored = await credentials.read(server.id);
      _requireCurrent(server, scope, generation);
      final reused = await _reuse(server, scope, generation);
      if (reused != null) {
        client.clearSession();
        return reused;
      }
      if (stored == null || !_credentialsMatch(server, stored)) {
        throw StateError('Login required');
      }
      client.attachSession(
        baseUrl: Uri.parse(server.baseUrl),
        accessToken: stored.accessToken,
        userId: stored.userId,
        userAgent: server.userAgent,
      );
      await sessionIdentityVerifier?.call(server, stored, client);
      _requireCurrent(server, scope, generation);
      if (server.serviceType == MediaServerType.plex) {
        final user = await client.getUser();
        _requireCurrent(server, scope, generation);
        if (user.id != stored.userId) {
          throw StateError('Account identity mismatch');
        }
      }
      if ((_scopes[server.id] ?? 0) != scope ||
          _allowed(server.id).region != server.region ||
          (server.region == AccessRegion.private &&
              generation != access.generation)) {
        throw StateError('Access revoked');
      }
      final session = SourceSession._(
        SourceAccount(
          region: server.region,
          serviceType: server.serviceType,
          cloudAccountId: stored.cloudAccountId,
          homeUserId: stored.homeUserId,
          configuredServerId: server.id,
          verifiedServerId: server.verifiedServerId ?? server.id,
          userId: stored.userId,
        ),
        client,
        ++_revision,
      );
      _sessions.remove(server.id)?.client.clearSession();
      _sessions[server.id] = session;
      client.onSessionExpired = () {
        if (identical(_sessions[server.id], session)) {
          _sessions.remove(server.id);
          _invalidate(server.id);
        }
        client.clearSession();
      };
      _requireCurrent(server, scope, generation);
      return session;
    } catch (_) {
      client.clearSession();
      rethrow;
    }
  }

  /// Verify a selected-source client without registering a second authority.
  /// Call before publishing its AuthSession; registry revisions still own it.
  Future<void> verifyAttachedSession(
    String id,
    StoredCredentials value,
    MediaServerClient client,
  ) async {
    final server = _allowed(id);
    final scope = _scopes[id] ?? 0;
    final generation = access.generation;
    _requireCurrent(server, scope, generation);
    final stored = await credentials.read(id);
    _requireCurrent(server, scope, generation);
    if (stored == null ||
        !_credentialsMatch(server, value) ||
        stored.accessToken != value.accessToken ||
        stored.userId != value.userId ||
        client.serviceType != server.serviceType ||
        client.accessToken != value.accessToken ||
        client.userId != value.userId) {
      throw StateError('Source credential identity mismatch');
    }
    await sessionIdentityVerifier?.call(server, value, client);
    _requireCurrent(server, scope, generation);
    final user = await client.getUser();
    _requireCurrent(server, scope, generation);
    if (user.id != value.userId) throw StateError('Account identity mismatch');
  }

  Future<SourceSession> authenticate(String id) async {
    final server = _allowed(id);
    final scope = _scopes[id] ?? 0;
    final generation = access.generation;
    _requireCurrent(server, scope, generation);
    final attempt = (_authAttempts[id] ?? 0) + 1;
    _authAttempts[id] = attempt;
    final client = _clientFor(server.serviceType);
    client.setUserAgent(server.userAgent);
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
      if (stored == null || !_credentialsMatch(server, stored)) {
        throw StateError('Login required');
      }
      client.attachSession(
        baseUrl: Uri.parse(server.baseUrl),
        accessToken: stored.accessToken,
        userId: stored.userId,
        userAgent: server.userAgent,
      );
      await sessionIdentityVerifier?.call(server, stored, client);
      _requireCurrent(server, scope, generation);
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
          serviceType: server.serviceType,
          cloudAccountId: stored.cloudAccountId,
          homeUserId: stored.homeUserId,
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

  OperationPermit permit(
    SourceAccount account, {
    String? libraryId,
    bool sessionOnly = false,
  }) {
    final server = _allowed(account.configuredServerId);
    final session = _sessions[server.id];
    final blockedByScope =
        !sessionOnly &&
        (!server.participates ||
            !server.scopeKnown ||
            server.libraryIds.isEmpty ||
            (libraryId != null && !server.libraryIds.contains(libraryId)));
    if (_cloudDisconnects.contains(server.cloudCredentialRef) ||
        _credentialChanges.contains(server.id) ||
        session?.account != account ||
        blockedByScope) {
      throw StateError('Source outside allowed scope');
    }
    return OperationPermit._(
      this,
      account,
      session!.revision,
      _scopes[server.id] ?? 0,
      access.generation,
      libraryId,
      sessionOnly: sessionOnly,
    );
  }

  bool accepts(OperationPermit permit) {
    if (!identical(permit._owner, this)) return false;
    try {
      final server = _allowed(permit.account.configuredServerId);
      final session = _sessions[server.id];
      final libraryOk =
          permit.sessionOnly ||
          (server.participates &&
              server.scopeKnown &&
              server.libraryIds.isNotEmpty &&
              (permit.libraryId == null ||
                  server.libraryIds.contains(permit.libraryId)));
      return !_cloudDisconnects.contains(server.cloudCredentialRef) &&
          !_credentialChanges.contains(server.id) &&
          server.region == permit.account.region &&
          server.serviceType == permit.account.serviceType &&
          libraryOk &&
          session?.account == permit.account &&
          session?.client.hasSession == true &&
          session?.client.userId == permit.account.userId &&
          session?.revision == permit.sessionRevision &&
          (_scopes[server.id] ?? 0) == permit.scopeRevision &&
          (server.region != AccessRegion.private ||
              access.generation == permit.regionGeneration);
    } on StateError {
      return false;
    }
  }

  Future<ManualCheckResult> check(
    String id, {
    String? lineId,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final server = _allowed(id);
    final line = lineId == null
        ? server.activeLine
        : server.lines.where((line) => line.id == lineId).firstOrNull;
    if (line == null) throw StateError('Unknown check line');
    final checkKey = jsonEncode([id, line.id]);
    final scope = _scopes[id] ?? 0;
    final generation = access.generation;
    _requireCurrent(server, scope, generation);
    final client = _clientFor(server.serviceType);
    client.setUserAgent(server.userAgent);
    if (_sessions.values.any((s) => identical(s.client, client))) {
      throw StateError('Check client must be independent');
    }
    final attempt = (_checkAttempts[checkKey] ?? 0) + 1;
    _checkAttempts[checkKey] = attempt;
    var finished = false;
    void guard() {
      _requireCurrent(server, scope, generation);
      if (finished || _checkAttempts[checkKey] != attempt) {
        throw StateError('Check superseded');
      }
    }

    var status = ManualCheckStatus.unknown;
    try {
      status = await (() async {
        final info = await client.getPublicInfo(Uri.parse(line.address));
        guard();
        if (info.id != (server.verifiedServerId ?? id)) {
          return ManualCheckStatus.identityMismatch;
        }
        final stored = await credentials.read(id);
        guard();
        if (stored == null || !_credentialsMatch(server, stored)) {
          return ManualCheckStatus.needsLogin;
        }
        client.attachSession(
          baseUrl: Uri.parse(line.address),
          accessToken: stored.accessToken,
          userId: stored.userId,
          userAgent: server.userAgent,
        );
        await sessionIdentityVerifier?.call(server, stored, client);
        guard();
        final user = await client.getUser();
        guard();
        return user.id == stored.userId
            ? ManualCheckStatus.available
            : ManualCheckStatus.needsLogin;
      })().timeout(timeout);
    } on TimeoutException {
      status = ManualCheckStatus.timeout;
    } on MediaServerException catch (error) {
      status = switch (error.kind) {
        MediaServerFailureKind.timeout => ManualCheckStatus.timeout,
        MediaServerFailureKind.sessionExpired ||
        MediaServerFailureKind.invalidCredentials =>
          ManualCheckStatus.needsLogin,
        _ => ManualCheckStatus.offline,
      };
    } catch (_) {
      status = ManualCheckStatus.offline;
    } finally {
      finished = true;
      client.clearSession();
    }
    if (_checkAttempts[checkKey] != attempt) {
      throw StateError('Check superseded');
    }
    if ((_scopes[id] ?? 0) != scope ||
        _allowed(id).region != server.region ||
        (server.region == AccessRegion.private &&
            generation != access.generation)) {
      throw StateError('Check revoked');
    }
    final result = ManualCheckResult(status, DateTime.now());
    await _update(id, (current) {
      _requireCurrent(server, scope, generation);
      if (_checkAttempts[checkKey] != attempt) {
        throw StateError('Check superseded');
      }
      final target = current.lines.where((l) => l.id == line.id).firstOrNull;
      if (target == null || target.address != line.address) {
        throw StateError('Check target changed');
      }
      return current.copyWith(
        lines: current.lines
            .map(
              (l) => l.id == line.id
                  ? l.copyWith(
                      checkStatus: status.name,
                      checkedAt: result.checkedAt,
                    )
                  : l,
            )
            .toList(),
        checkStatus: lineId == null ? status.name : current.checkStatus,
        checkedAt: lineId == null ? result.checkedAt : current.checkedAt,
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
              'serviceType',
              'authorizationMethod',
              'cloudCredentialRef',
              'cloudAccountId',
              'homeUserId',
              'resourceCredentialRef',
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
        final merged = _mergeDelta(
          line.toJson(),
          old[line.id]?.toJson() ?? {},
          edit.toJson(),
        );
        final sameTarget = merged['address'] == line.address;
        // Ordinary editors may rename/reorder, not overwrite check facts.
        merged['checkStatus'] = sameTarget ? line.checkStatus : 'unknown';
        merged['checkedAt'] = sameTarget
            ? line.checkedAt?.toIso8601String()
            : null;
        result[line.id] = merged;
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
    for (final authorization in _pendingAuthorizations.values.toList()) {
      authorization.cancel();
    }
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
