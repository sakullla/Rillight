import '../media_server/server_address.dart';

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
import 'server_import_models.dart';

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
    this._configuration,
  );
  final SourceSessionRegistry _owner;
  final String id;
  final MediaServerType serviceType;
  final AccessRegion region;
  final int _scope;
  final int _generation;
  final int _attempt;
  final int _cloudRevision;
  final SavedServer? _configuration;
  bool _finished = false;
  bool get isValid => _owner._acceptsAuthorization(this);
  void requireValid() {
    if (!isValid) throw StateError('Authorization revoked');
  }

  void requireServerIdentity(String identity) {
    requireValid();
    final expected = _configuration?.expectedServerId;
    if (expected != null && expected != identity) {
      throw const MediaServerException(
        MediaServerFailureKind.incompatibleServer,
      );
    }
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
  SourceSession._(
    this.account,
    this.client,
    this.revision, {
    this.verified = false,
    this._activationAvailable = false,
  });
  bool _activationAvailable;
  final bool verified;
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
  const ManualCheckResult(this.status, this.checkedAt, {this.failureKind});
  final MediaServerFailureKind? failureKind;
  final ManualCheckStatus status;
  final DateTime checkedAt;
}

typedef SourceClientFactory = MediaServerClient Function();
typedef SessionIdentityVerifier = Future<void> Function(
  SavedServer server,
  StoredCredentials credentials,
  MediaServerClient client,
);
typedef MembershipCleanup = Future<void> Function(
  SourceAccount? account,
  String serverId,
);

/// The captured compensation authority was retired. Unlike transport failures,
/// retrying this old operation must not reacquire authorization.
class PlaybackCleanupRevoked extends StateError {
  PlaybackCleanupRevoked() : super('Playback cleanup ownership revoked');
}

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

  /// Local authorization projection, independent of the selected browsing
  /// session. This does not contact the server or grant content access.
  Future<bool> hasStoredAuthorization(String id) async {
    final server = _servers.where((s) => s.id == id).firstOrNull;
    if (server == null) return false;
    final value = await credentials.read(id);
    return value != null &&
        value.accessToken.isNotEmpty &&
        value.userId.isNotEmpty &&
        _credentialsMatch(server, value);
  }

  List<SavedServer> _servers = [];
  String? _lastServerId;
  final Map<String, SourceSession> _sessions = {};
  final Map<String, int> _scopes = {};
  final Set<String> _transitioning = {};
  final Set<String> _credentialChanges = {};
  final Set<String> _candidateCommits = {};
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

  /// Compensate one persisted playback without reacquiring cloud authority or
  /// negotiating media. This never publishes a session or grants catalog access.
  Future<bool> recoverPlayback({
    required SourceAccount account,
    required PlaybackReport report,
    required Uri baseUrl,
    required String libraryId,
    int? regionGeneration,
    bool cleanupOnly = false,
  }) async {
    final server = _allowed(account.configuredServerId);
    final scope = _scopes[server.id] ?? 0;
    final generation = access.generation;
    void requireOwner() {
      try {
        _requireCurrent(server, scope, generation);
        final current = _allowed(server.id);
        if (current.region != account.region ||
            current.serviceType != account.serviceType ||
            current.verifiedServerId != account.verifiedServerId ||
            current.cloudAccountId != account.cloudAccountId ||
            current.homeUserId != account.homeUserId ||
            !current.participates ||
            !current.scopeKnown ||
            !current.libraryIds.contains(libraryId) ||
            !current.lines.any((line) => Uri.parse(line.address) == baseUrl) ||
            (account.region == AccessRegion.private &&
                (regionGeneration != generation ||
                    _sessions[server.id]?.account != account))) {
          throw PlaybackCleanupRevoked();
        }
      } on StateError {
        throw PlaybackCleanupRevoked();
      }
    }

    requireOwner();
    final stored = await credentials.read(server.id);
    requireOwner();
    if (stored == null ||
        !_credentialsMatch(server, stored) ||
        stored.userId != account.userId ||
        stored.accessToken.isEmpty) {
      return false;
    }
    final client = _clientFor(account.serviceType);
    if (_sessions.values.any((session) => identical(session.client, client))) {
      throw StateError('Cleanup client must be independent');
    }
    client.attachSession(
      baseUrl: baseUrl,
      accessToken: stored.accessToken,
      userId: stored.userId,
      userAgent: server.userAgent,
    );
    try {
      requireOwner();
      await (cleanupOnly
              ? client.releasePlayback(report)
              : client.stopPlayback(report))
          .timeout(const Duration(seconds: 3));
      requireOwner();
      return true;
    } finally {
      client.clearSession();
    }
  }

  int _revision = 0;
  int _configurationRevision = 0;
  int get configurationRevision => _configurationRevision;
  SavedServer server(String id) => _allowed(id);
  MediaServerClient createCandidate(MediaServerType type) => _clientFor(type);
  String? connectedLineId(String id) {
    final current = _sessions[id]?.client.baseUrl?.toString();
    return _servers
        .where((s) => s.id == id)
        .firstOrNull
        ?.lines
        .where((l) => l.address == current)
        .firstOrNull
        ?.id;
  }

  final Map<String, int> _authAttempts = {};
  final Map<String, SourceAuthorization> _pendingAuthorizations = {};
  final Map<String, Future<SourceSession>> _sessionAcquisitions = {};
  final Map<String, int> _checkAttempts = {};

  void _requireCurrent(SavedServer server, int scope, int generation) {
    if (_cloudDisconnects.contains(server.cloudCredentialRef) ||
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

  /// Offline, additive import. Each record shares the configuration/credential
  /// writer and is published only after both stores have committed.
  Future<ServerImportResult> importServers(
    Iterable<ServerImportDraft> drafts, {
    AccessRegion region = AccessRegion.ordinary,
  }) async {
    final generation = access.generation;
    // Snapshot caller-owned lists before the first asynchronous operation.
    final input = [
      for (final draft in drafts)
        ServerImportDraft(
          name: draft.name,
          serviceType: draft.serviceType,
          username: draft.username,
          lines: List.unmodifiable(draft.lines),
          credentials: draft.credentials,
          userAgent: draft.userAgent,
          isPrivate: draft.isPrivate,
        ),
    ];
    if (!_loaded) await load();
    final results = <ServerImportItemResult>[];
    var storageUncertain = false;
    for (var index = 0; index < input.length; index++) {
      final draft = input[index];
      ServerImportItemResult result(
        ServerImportStatus status, {
        String? id,
        ServerImportReason? reason,
      }) => ServerImportItemResult(
        index: index,
        status: status,
        serverId: id,
        reason: reason,
      );
      if (storageUncertain) {
        results.add(
          result(
            ServerImportStatus.failed,
            reason: ServerImportReason.rollbackFailed,
          ),
        );
        continue;
      }
      if ((draft.isPrivate && region != AccessRegion.private) ||
          !access.allows(region)) {
        results.add(
          result(
            ServerImportStatus.skipped,
            reason: ServerImportReason.privateAccessRequired,
          ),
        );
        continue;
      }
      final lines = <ServerLine>[];
      try {
        if (draft.lines.isEmpty ||
            draft.userAgent?.contains(RegExp(r'[\r\n]')) == true ||
            (draft.credentials != null &&
                (draft.credentials!.username != draft.username ||
                    draft.credentials!.serviceType != draft.serviceType))) {
          throw const FormatException();
        }
        for (final line in draft.lines) {
          final raw = Uri.parse(
            line.address.contains('://')
                ? line.address.trim()
                : 'http://${line.address.trim()}',
          );
          if (raw.userInfo.isNotEmpty || raw.hasQuery || raw.hasFragment) {
            throw const _UnsupportedImportOptions();
          }
          final address = normalizeServerAddress(line.address).toString();
          if (lines.any((line) => line.address == address)) continue;
          lines.add(
            ServerLine(
              id: generateLineId(),
              address: address,
              nickname: line.name,
            ),
          );
        }
      } catch (error) {
        results.add(
          result(
            ServerImportStatus.failed,
            reason: error is _UnsupportedImportOptions
                ? ServerImportReason.unsupportedConnectionOptions
                : ServerImportReason.invalidConfiguration,
          ),
        );
        continue;
      }
      final id = 'config-${generateDeviceId()}';
      final scope = _scopes[id] ?? 0;
      void guard() {
        if (!access.allows(region) ||
            (region == AccessRegion.private &&
                access.generation != generation) ||
            (_scopes[id] ?? 0) != scope ||
            _transitioning.contains(id)) {
          throw const _ImportRevoked();
        }
      }

      await _enqueue(() async {
        try {
          guard();
          final addresses = lines.map((line) => line.address).toSet();
          for (final existing in _servers.where(
            (s) => s.region == region && s.serviceType == draft.serviceType,
          )) {
            if (!existing.lines.any((line) {
              try {
                return addresses.contains(
                  normalizeServerAddress(line.address).toString(),
                );
              } catch (_) {
                return false;
              }
            })) {
              continue;
            }
            final stored = await credentials.read(existing.id);
            guard();
            final incomingUser = draft.credentials?.userId ?? '';
            final existingUser = stored?.userId ?? '';
            final sameAccount =
                incomingUser.isNotEmpty && existingUser.isNotEmpty
                ? incomingUser == existingUser
                : draft.username.isNotEmpty &&
                      draft.username == existing.username;
            if (sameAccount) {
              results.add(result(ServerImportStatus.duplicate));
              return;
            }
          }
          final server = SavedServer(
            id: id,
            name: draft.name,
            serviceType: draft.serviceType,
            username: draft.username,
            lines: List.unmodifiable(lines),
            activeLineId: lines.first.id,
            userAgent: draft.userAgent,
            region: region,
            identityPending: true,
          );
          final previous = ServerListSnapshot(
            servers: List.of(_servers),
            lastServerId: _lastServerId,
          );
          var configurationAttempted = false;
          try {
            if (draft.credentials != null) {
              await credentials.write(id, draft.credentials!);
            }
            guard();
            final next = [..._servers, server];
            configurationAttempted = true;
            await store.save(
              ServerListSnapshot(servers: next, lastServerId: _lastServerId),
            );
            guard();
            _servers = next;
            _configurationRevision++;
            _notifySourceChange(id);
            results.add(result(ServerImportStatus.added, id: id));
          } catch (error) {
            var rollbackFailed = false;
            try {
              await credentials.delete(id);
            } catch (_) {
              rollbackFailed = true;
            }
            if (configurationAttempted) {
              try {
                await store.save(previous);
              } catch (_) {
                rollbackFailed = true;
              }
            }
            if (rollbackFailed) {
              storageUncertain = true;
              results.add(
                result(
                  ServerImportStatus.failed,
                  reason: ServerImportReason.rollbackFailed,
                ),
              );
            } else {
              results.add(
                result(
                  ServerImportStatus.failed,
                  reason: error is _ImportRevoked
                      ? ServerImportReason.accessRevoked
                      : ServerImportReason.persistenceFailed,
                ),
              );
            }
          }
        } catch (error) {
          results.add(
            result(
              ServerImportStatus.failed,
              reason: error is _ImportRevoked
                  ? ServerImportReason.accessRevoked
                  : ServerImportReason.persistenceFailed,
            ),
          );
        }
      });
    }
    return ServerImportResult(results);
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
    if (_disposed ||
        server == null ||
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
        (_credentialChanges.contains(id) || _candidateCommits.contains(id))) {
      throw StateError('Source changing');
    }
    // Preparing another account must not revoke the still usable session.
    _scopes.putIfAbsent(id, () => 0);
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
      existing,
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

  String _connectionConfiguration(SavedServer server) => jsonEncode({
    'lines': [
      for (final line in server.lines) [line.id, line.address],
    ],
    'active': server.activeLineId,
    'selection': server.lineSelection.toJson(),
    'userAgent': server.normalizedUserAgent,
  });

  /// Verify resource/server/effective-user correspondence before committing.
  /// Discovery alone never imports or selects a library.
  Future<SourceSession> commitAuthorization(
    SourceAuthorization authorization, {
    required SavedServer server,
    required StoredCredentials value,
    SessionIdentityVerifier? candidateVerifier,
    Future<void> Function()? persistCandidate,
    Future<void> Function()? rollbackCandidate,
    bool remember = false,
  }) async {
    SavedServer? committedConfiguration;
    void guard() {
      authorization.requireValid();
      final baseline = committedConfiguration ?? authorization._configuration;
      final current = _servers.where((s) => s.id == server.id).firstOrNull;
      if (baseline != null &&
          (current == null ||
              _connectionConfiguration(current) !=
                  _connectionConfiguration(baseline))) {
        throw StateError('Source configuration changed; retry authorization');
      }
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
    authorization.requireServerIdentity(server.verifiedServerId!);
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
      await (candidateVerifier ?? sessionIdentityVerifier)?.call(
        server,
        value,
        client,
      );
      guard();
      final user = await client.getUser();
      guard();
      if (user.id != value.userId) {
        throw StateError('Account identity mismatch');
      }
      final addresses = <String>{};
      for (final line in server.lines) {
        final uri = normalizeServerAddress(line.address);
        if (!addresses.add(uri.toString())) throw StateError('Duplicate line');
        if (line.id == server.activeLine?.id) continue;
        final probe = _clientFor(server.serviceType);
        try {
          probe.setUserAgent(server.userAgent);
          final info = await probe.getPublicInfo(uri);
          guard();
          if (info.id != server.verifiedServerId) {
            throw const MediaServerException(
              MediaServerFailureKind.incompatibleServer,
            );
          }
          probe.attachSession(
            baseUrl: uri,
            accessToken: value.accessToken,
            userId: value.userId,
            userAgent: server.userAgent,
          );
          await (candidateVerifier ?? sessionIdentityVerifier)?.call(
            server,
            value,
            probe,
          );
          guard();
          if ((await probe.getUser()).id != value.userId) {
            throw const MediaServerException(
              MediaServerFailureKind.invalidCredentials,
            );
          }
          guard();
        } finally {
          probe.clearSession();
        }
      }
      await _enqueue(() async {
        guard();
        final previous = await credentials.read(server.id);
        guard();
        final previousServers = List<SavedServer>.of(_servers);
        final old = _servers.where((s) => s.id == server.id).firstOrNull;
        if (old != null &&
            (old.serviceType != server.serviceType ||
                (old.expectedServerId != null &&
                    old.expectedServerId != server.verifiedServerId) ||
                old.region != server.region)) {
          throw StateError('Source identity changed');
        }
        final preserveScope =
            old != null &&
            previous != null &&
            previous.userId == value.userId &&
            previous.homeUserId == value.homeUserId &&
            previous.cloudAccountId == value.cloudAccountId;
        final baseline = authorization._configuration;
        final saved = server.copyWith(
          nickname: old != null && old.nickname != baseline?.nickname
              ? old.nickname ?? ''
              : server.nickname,
          iconId: old != null && old.iconId != baseline?.iconId
              ? old.iconId
              : server.iconId,
          protectionRef: old?.protectionRef,
          clearProtection: old != null && old.protectionRef == null,
          lines: [
            for (final line in server.lines)
              line.copyWith(
                nickname:
                    old?.lines
                        .where((l) => l.id == line.id)
                        .firstOrNull
                        ?.nickname ??
                    line.nickname,
              ),
          ],
          libraryIds: preserveScope ? old.libraryIds : const [],
          scopeKnown: preserveScope ? old.scopeKnown : false,
          participates: old?.participates ?? server.participates,
        );
        var savedConfig = false;
        _candidateCommits.add(server.id);
        try {
          await persistCandidate?.call();
          guard();
          await credentials.write(server.id, value);
          guard();
          final next = [
            for (final s in _servers) s.id == server.id ? saved : s,
            if (old == null) saved,
          ];
          savedConfig = true;
          await store.save(
            ServerListSnapshot(
              servers: next,
              lastServerId: remember ? server.id : _lastServerId,
            ),
          );
          guard();
          _servers = next;
          committedConfiguration = saved;
          if (remember) _lastServerId = server.id;
          _configurationRevision++;
        } catch (_) {
          // Attempt every compensation even when one backing store fails.
          await Future.wait<void>([
            if (savedConfig)
              store.save(
                ServerListSnapshot(
                  servers: previousServers,
                  lastServerId: _lastServerId,
                ),
              ),
            if (rollbackCandidate != null) rollbackCandidate(),
            previous == null
                ? credentials.delete(server.id)
                : credentials.write(server.id, previous),
          ]);
          rethrow;
        } finally {
          _candidateCommits.remove(server.id);
        }
      });
      guard();
      authorization.cancel();
      _invalidate(server.id);
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
        verified: true,
        activationAvailable: true,
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
    if (remove && !_servers.any((s) => s.id == id)) return;
    final server = remove
        ? _servers.firstWhere((s) => s.id == id)
        : _allowed(id);
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
          _configurationRevision++;
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
    StoredCredentials? value, {
    String? verifiedServerId,
  }) => _enqueue(() async {
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
          (previous?.userId != value.userId || verifiedServerId != null)) {
        final next = _servers
            .map(
              (s) => s.id == commit.id
                  ? s.copyWith(
                      libraryIds: previous?.userId != value.userId
                          ? const []
                          : s.libraryIds,
                      scopeKnown: previous?.userId != value.userId
                          ? false
                          : s.scopeKnown,
                      verifiedServerId: verifiedServerId,
                      identityPending: verifiedServerId == null
                          ? s.identityPending
                          : false,
                      username: value.username,
                    )
                  : s,
            )
            .toList();
        savedConfig = true;
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
    void Function()? guard,
  }) => _enqueue(() async {
    guard?.call();
    final next = change();
    final previous = ServerListSnapshot(
      servers: _servers,
      lastServerId: _lastServerId,
    );
    try {
      await store.save(
        ServerListSnapshot(
          servers: next,
          lastServerId: replaceLast ? lastServerId : _lastServerId,
        ),
      );
      guard?.call();
    } catch (_) {
      await store.save(previous);
      rethrow;
    }
    _servers = next;
    _configurationRevision++;
    for (final server in next) {
      if (!_transitioning.contains(server.id)) _notifySourceChange(server.id);
    }
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

  final Map<String, int> _selectedRevisions = {};

  /// A selected single-source session is independent of aggregation library
  /// scope, but is revoked by authentication, logout, membership and locking.
  void Function() selectedSessionGuard(String id) {
    final server = _allowed(id);
    final revision = _selectedRevisions[id] ?? 0;
    final generation = access.generation;
    return () {
      final current = _allowed(id);
      if ((_selectedRevisions[id] ?? 0) != revision ||
          current.serviceType != server.serviceType ||
          current.region != server.region ||
          _cloudDisconnects.contains(current.cloudCredentialRef) ||
          (server.region == AccessRegion.private &&
              generation != access.generation)) {
        throw StateError('Selected source revoked');
      }
    };
  }

  void _invalidate(String id, {bool revokeSelected = true}) {
    if (revokeSelected) {
      _selectedRevisions[id] = (_selectedRevisions[id] ?? 0) + 1;
    }
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
    _invalidate(id, revokeSelected: false);
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

  /// Anonymous identity first, account material only after identity matches.
  Future<MediaServerClient> _prepareLine(
    SavedServer server,
    ServerLine line,
    void Function() guard,
  ) async {
    final probe = _clientFor(server.serviceType);
    try {
      probe.setUserAgent(server.userAgent);
      final info = await probe.getPublicInfo(
        normalizeServerAddress(line.address),
      );
      guard();
      if (server.expectedServerId == null ||
          info.id != server.expectedServerId) {
        throw const MediaServerException(
          MediaServerFailureKind.incompatibleServer,
          detail: '线路返回的服务器身份与当前服务器不一致',
        );
      }
      final value = await credentials.read(server.id);
      guard();
      if (value != null) {
        if (!_credentialsMatch(server, value)) {
          throw const MediaServerException(
            MediaServerFailureKind.sessionExpired,
          );
        }
        probe.attachSession(
          baseUrl: normalizeServerAddress(line.address),
          accessToken: value.accessToken,
          userId: value.userId,
          userAgent: server.userAgent,
        );
        await sessionIdentityVerifier?.call(server, value, probe);
        guard();
        final user = await probe.getUser();
        guard();
        if (user.id != value.userId) {
          throw const MediaServerException(
            MediaServerFailureKind.invalidCredentials,
          );
        }
      } else if (server.serviceType == MediaServerType.plex) {
        throw const MediaServerException(MediaServerFailureKind.sessionExpired);
      }
      return probe;
    } catch (_) {
      probe.clearSession();
      rethrow;
    }
  }

  /// Shared transaction. Failed prepare/save preserves the original client.
  Future<void> _editLines(
    String id,
    SavedServer Function(SavedServer) edit, {
    void Function()? guard,
  }) async {
    final original = _allowed(id);
    final scope = _scopes[id] ?? 0;
    final generation = access.generation;
    void current() {
      guard?.call();
      _requireCurrent(original, scope, generation);
      final latest = _allowed(id);
      if (jsonEncode(latest.lines.map((l) => l.toJson()).toList()) !=
              jsonEncode(original.lines.map((l) => l.toJson()).toList()) ||
          latest.activeLineId != original.activeLineId ||
          latest.lineSelection != original.lineSelection ||
          latest.userAgent != original.userAgent) {
        throw StateError('Lines changed; retry the edit');
      }
    }

    final candidate = edit(original);
    if (candidate.lines.isEmpty) throw StateError('Cannot remove last line');
    final addresses = candidate.lines.map(
      (l) => normalizeServerAddress(l.address).toString(),
    );
    if (addresses.toSet().length != candidate.lines.length) {
      throw StateError('Duplicate line');
    }
    final active = candidate.activeLine;
    if (active == null ||
        !candidate.lines.any((l) => l.id == candidate.activeLineId) ||
        (candidate.lineSelection.fixedLineId != null &&
            !candidate.lines.any(
              (l) => l.id == candidate.lineSelection.fixedLineId,
            ))) {
      throw StateError('Unknown selected line');
    }
    final connectionChanged =
        candidate.baseUrl != original.baseUrl ||
        candidate.normalizedUserAgent != original.normalizedUserAgent;
    final prepared = <MediaServerClient>[];
    MediaServerClient? replacement;
    try {
      for (final line in candidate.lines) {
        if (original.lines.any(
              (old) => old.id == line.id && old.address == line.address,
            ) &&
            !(connectionChanged && line.id == active.id)) {
          continue;
        }
        final probe = await _prepareLine(candidate, line, current);
        prepared.add(probe);
        if (line.id == active.id) replacement = probe;
      }
      current();
      await _enqueue(() async {
        current();
        final previous = ServerListSnapshot(
          servers: _servers,
          lastServerId: _lastServerId,
        );
        final latest = _allowed(id).copyWith(
          lines: candidate.lines,
          activeLineId: candidate.activeLineId,
          lineSelection: candidate.lineSelection,
          lastSuccessfulLineId: candidate.lastSuccessfulLineId,
          nickname: candidate.nickname != original.nickname
              ? candidate.nickname
              : _allowed(id).nickname,
          iconId: candidate.iconId != original.iconId
              ? candidate.iconId
              : _allowed(id).iconId,
          userAgent: candidate.userAgent,
          protectionRef: candidate.protectionRef != original.protectionRef
              ? candidate.protectionRef
              : _allowed(id).protectionRef,
        );
        final next = _servers.map((s) => s.id == id ? latest : s).toList();
        try {
          await store.save(
            ServerListSnapshot(servers: next, lastServerId: _lastServerId),
          );
          current();
        } catch (_) {
          await store.save(previous);
          rethrow;
        }
        _servers = next;
        _configurationRevision++;
      });
      if (connectionChanged) {
        _sessions.remove(id)?.client.clearSession();
        _invalidate(id);
        final value = replacement;
        if (value != null && value.hasSession) {
          _sessions[id] = SourceSession._(
            SourceAccount(
              configuredServerId: id,
              verifiedServerId: candidate.expectedServerId!,
              userId: value.userId!,
              serviceType: candidate.serviceType,
              region: candidate.region,
              cloudAccountId: candidate.cloudAccountId,
              homeUserId: candidate.homeUserId,
            ),
            value,
            ++_revision,
            verified: true,
            activationAvailable: true,
          );
          prepared.remove(value);
          value.onSessionExpired = () {
            if (identical(_sessions[id]?.client, value)) {
              _sessions.remove(id);
              _invalidate(id);
            }
            value.clearSession();
          };
        }
      }
      _notifySourceChange(id);
    } finally {
      for (final probe in prepared) {
        probe.clearSession();
      }
    }
  }

  /// One concentrated editor save, including verified line edits. The caller's
  /// draft is untouched on failure; only this operation publishes changes.
  Future<void> saveConfiguration(
    String id, {
    required String nickname,
    String? iconId,
    required String userAgent,
    required List<ServerLine> lines,
    LineSelection? lineSelection,
    String? protectionRef,
  }) => _editLines(id, (server) {
    if (userAgent.contains(RegExp(r'[\r\n]'))) {
      throw ArgumentError('Invalid user agent');
    }
    final normalized = [
      for (final line in lines)
        line.copyWith(address: normalizeServerAddress(line.address).toString()),
    ];
    if (normalized.map((l) => l.id).toSet().length != normalized.length) {
      throw StateError('Duplicate line');
    }
    final activeId = normalized.any((l) => l.id == server.activeLineId)
        ? server.activeLineId
        : normalized.firstOrNull?.id;
    final selection =
        lineSelection ??
        (server.lineSelection.isAutomatic
            ? const LineSelection.auto()
            : LineSelection.fixed(activeId ?? ''));
    return server.copyWith(
      nickname: nickname.trim(),
      iconId: iconId,
      userAgent: userAgent.trim(),
      lines: normalized,
      activeLineId: selection.fixedLineId ?? activeId,
      lineSelection: selection,
      lastSuccessfulLineId:
          normalized.any((l) => l.id == server.lastSuccessfulLineId)
          ? server.lastSuccessfulLineId
          : activeId,
      protectionRef: protectionRef,
    );
  });

  Future<void> persistProtectionReference(String id, String? reference) =>
      _update(
        id,
        (server) => server.copyWith(
          protectionRef: reference,
          clearProtection: reference == null,
        ),
      );

  Future<void> setLineAddress(String id, String address, {String? lineId}) =>
      _editLines(id, (server) {
        final uri = normalizeServerAddress(address).toString();
        if (lineId != null && !server.lines.any((l) => l.id == lineId)) {
          throw StateError('Unknown line');
        }
        return server.copyWith(
          lines: [
            for (final line in server.lines)
              line.id == lineId
                  ? line.copyWith(
                      address: uri,
                      checkStatus: 'unknown',
                      checkedAt: null,
                    )
                  : line,
            if (lineId == null) ServerLine(id: generateLineId(), address: uri),
          ],
        );
      });

  Future<void> removeLine(String id, String lineId) => _editLines(id, (server) {
    if (!server.lines.any((l) => l.id == lineId)) {
      throw StateError('Unknown line');
    }
    final remaining = server.lines.where((l) => l.id != lineId).toList();
    if (remaining.isEmpty) throw StateError('Cannot remove last line');
    final activeId = server.activeLineId == lineId
        ? remaining.first.id
        : server.activeLineId;
    return server.copyWith(
      lines: remaining,
      activeLineId: activeId,
      lineSelection: server.lineSelection.fixedLineId == lineId
          ? LineSelection.fixed(activeId!)
          : server.lineSelection,
      lastSuccessfulLineId: server.lastSuccessfulLineId == lineId
          ? activeId
          : server.lastSuccessfulLineId,
    );
  });

  Future<void> selectLine(
    String id,
    LineSelection selection, {
    void Function()? guard,
  }) => _editLines(
    id,
    (server) => server.copyWith(
      activeLineId: selection.fixedLineId ?? server.activeLineId,
      lineSelection: selection,
      lastSuccessfulLineId: selection.fixedLineId ?? server.activeLineId,
    ),
    guard: guard,
  );

  Future<void> rememberSelection(String id, {void Function()? guard}) async {
    guard?.call();
    if (_lastServerId == id) return;
    await _commit(
      () {
        _allowed(id);
        return List.of(_servers);
      },
      replaceLast: true,
      lastServerId: id,
      guard: guard,
    );
  }

  Future<void> reorderServers(List<String> ids) => _commit(() {
    final byId = {for (final s in _servers) s.id: s};
    if (ids.length != byId.length ||
        ids.toSet().length != byId.length ||
        !ids.every(byId.containsKey)) {
      throw ArgumentError('Invalid server order');
    }
    return ids.map((id) => byId[id]!).toList();
  });

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
      if (server.expectedServerId != null &&
          info.id != server.expectedServerId) {
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
          identityPending: false,
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

  /// Reuse a verified in-memory session; a cold acquisition checks anonymous
  /// server identity before attaching the saved token and verifying its user.
  Future<SourceSession> ensureSession(String id) async {
    final server = _allowed(id);
    if (_candidateCommits.contains(id)) {
      final existing = _sessions[id];
      if (existing != null) return existing;
      throw StateError('Source authorization is committing');
    }
    final scope = _scopes[id] ?? 0;
    final generation = access.generation;
    _requireCurrent(server, scope, generation);
    final reused = await _reuse(server, scope, generation);
    if (reused != null) return reused;
    final pending = _sessionAcquisitions[id];
    if (pending != null) return pending;
    final created = server.identityPending
        ? authenticate(id)
        : _attachStoredSession(server, scope, generation);
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
      final info = await client.getPublicInfo(Uri.parse(server.baseUrl));
      _requireCurrent(server, scope, generation);
      if (info.id != server.expectedServerId) {
        throw const MediaServerException(
          MediaServerFailureKind.incompatibleServer,
        );
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
      _requireCurrent(server, scope, generation);
      if (user.id != stored.userId) {
        throw StateError('Account identity mismatch');
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
        verified: true,
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

  /// Reuse a just-committed proof without a second network phase after durable
  /// selection. The proof is consumed once; ordinary restore/switch always
  /// verifies afresh. The clone keeps provider proof and transport isolated.
  MediaServerClient? verifiedClient(String id, StoredCredentials value) {
    final server = _allowed(id);
    final session = _sessions[id];
    if (session == null ||
        !session.verified ||
        !session._activationAvailable ||
        session.account.verifiedServerId != server.expectedServerId ||
        session.client.customUserAgent != server.normalizedUserAgent ||
        session.client.baseUrl?.toString() != server.baseUrl ||
        session.client.accessToken != value.accessToken ||
        session.account.userId != value.userId ||
        !_credentialsMatch(server, value)) {
      return null;
    }
    session._activationAvailable = false;
    return session.client.withRequestGuard(selectedSessionGuard(id));
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

  Future<SourceSession> authenticate(String id, {String? lineId}) async {
    final server = _allowed(id);
    final line = lineId == null
        ? server.activeLine
        : server.lines.where((line) => line.id == lineId).firstOrNull;
    if (line == null) throw StateError('Unknown authentication line');
    final baseUrl = Uri.parse(line.address);
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
      final info = await client.getPublicInfo(baseUrl);
      _requireCurrent(server, scope, generation);
      final expected = server.expectedServerId;
      if (expected != null && info.id != expected) {
        throw StateError('Server identity mismatch');
      }
      final stored = await credentials.read(id);
      _requireCurrent(server, scope, generation);
      if (stored == null || !_credentialsMatch(server, stored)) {
        throw StateError('Login required');
      }
      var verified = stored;
      var tokenAccepted = false;
      if (stored.accessToken.isNotEmpty && stored.userId.isNotEmpty) {
        client.attachSession(
          baseUrl: baseUrl,
          accessToken: stored.accessToken,
          userId: stored.userId,
          userAgent: server.userAgent,
        );
        try {
          await sessionIdentityVerifier?.call(server, stored, client);
          _requireCurrent(server, scope, generation);
          final user = await client.getUser();
          if (user.id != stored.userId) {
            throw StateError('Account identity mismatch');
          }
          tokenAccepted = true;
        } on MediaServerException catch (error) {
          if (!server.identityPending ||
              server.serviceType == MediaServerType.plex ||
              (error.kind != MediaServerFailureKind.sessionExpired &&
                  error.kind != MediaServerFailureKind.invalidCredentials)) {
            rethrow;
          }
        }
      }
      _requireCurrent(server, scope, generation);
      if (!tokenAccepted) {
        if (!server.identityPending ||
            server.serviceType == MediaServerType.plex ||
            stored.password == null ||
            stored.username.isEmpty) {
          throw StateError('Login required');
        }
        final auth = await client.authenticateByName(
          baseUrl: baseUrl,
          username: stored.username,
          password: stored.password!,
          serverId: info.id,
        );
        if (stored.userId.isNotEmpty && stored.userId != auth.user.id) {
          throw StateError('Account identity mismatch');
        }
        verified = StoredCredentials(
          serviceType: stored.serviceType,
          authorizationMethod: stored.authorizationMethod,
          accessToken: auth.accessToken,
          userId: auth.user.id,
          username: stored.username,
          password: stored.password,
        );
        client.attachSession(
          baseUrl: baseUrl,
          accessToken: verified.accessToken,
          userId: verified.userId,
          userAgent: server.userAgent,
        );
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
      await _enqueue(() async {
        void guard() {
          _requireCurrent(server, scope, generation);
          if (_authAttempts[id] != attempt) {
            throw StateError('Authentication superseded');
          }
        }

        guard();
        final previous = ServerListSnapshot(
          servers: List.of(_servers),
          lastServerId: _lastServerId,
        );
        var configurationAttempted = false;
        try {
          if (!identical(verified, stored)) {
            await credentials.write(id, verified);
          }
          guard();
          final next = _servers
              .map(
                (current) => current.id == id
                    ? current.copyWith(
                        verifiedServerId: info.id,
                        identityPending: false,
                      )
                    : current,
              )
              .toList();
          configurationAttempted = true;
          await store.save(
            ServerListSnapshot(servers: next, lastServerId: _lastServerId),
          );
          guard();
          _servers = next;
        } catch (_) {
          if (!identical(verified, stored)) await credentials.write(id, stored);
          if (configurationAttempted) await store.save(previous);
          rethrow;
        }
      });
      _requireCurrent(server, scope, generation);
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
          userId: verified.userId,
        ),
        client,
        ++_revision,
        verified: true,
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
    MediaServerFailureKind? failureKind;
    try {
      status = await (() async {
        final info = await client.getPublicInfo(Uri.parse(line.address));
        guard();
        if (server.expectedServerId != null &&
            info.id != server.expectedServerId) {
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
      failureKind = MediaServerFailureKind.timeout;
      status = ManualCheckStatus.timeout;
    } on MediaServerException catch (error) {
      failureKind = error.kind;
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
    final result = ManualCheckResult(
      status,
      DateTime.now(),
      failureKind: failureKind,
    );
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
                      checkFailureKind: failureKind?.name,
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
              'identityPending',
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

  bool _disposed = false;

  void dispose() {
    _disposed = true;
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

class _UnsupportedImportOptions implements Exception {
  const _UnsupportedImportOptions();
}

class _ImportRevoked implements Exception {
  const _ImportRevoked();
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
