import 'server_entry_coordinator.dart';
import '../media_server/server_address.dart';

import 'package:rillight/media_server/capabilities.dart';
import 'package:rillight/media_server/media_server_client.dart';

import 'dart:async';
import 'dart:convert';

import 'credential_store.dart';
import '../media_server/authentication.dart';
import 'cloud_credentials.dart';
import 'server_access.dart';
import 'server_list_store.dart';
import '../media_server/errors.dart';
import '../media_server/playback.dart';
import 'server_import_models.dart';

/// Account identity only. Media item/version identity belongs to aggregation.
class SourceAccount {
  const SourceAccount({
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
  final String configuredServerId;
  final String verifiedServerId;
  final String userId;
  @override
  bool operator ==(Object other) =>
      other is SourceAccount &&
      serviceType == other.serviceType &&
      cloudAccountId == other.cloudAccountId &&
      homeUserId == other.homeUserId &&
      configuredServerId == other.configuredServerId &&
      verifiedServerId == other.verifiedServerId &&
      userId == other.userId;
  @override
  int get hashCode => Object.hash(
    serviceType,
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
  void Function()? _settledSelectionGuard;
}

/// An authorization transaction is captured before password/Quick Connect/PIN
/// or Home switching starts. Polling can continue only while this is current.
class SourceAuthorization {
  SourceAuthorization._(
    this._owner,
    this.id,
    this.serviceType,
    this._scope,
    this._generation,
    this._attempt,
    this._cloudRevision,
    this._configuration,
  );
  final SourceSessionRegistry _owner;
  final String id;
  final MediaServerType serviceType;
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
    this.authorizationRevision,
    this.accessGeneration,
    this.libraryId,
    this.entry,
  );
  final SourceSessionRegistry _owner;
  final SourceAccount account;
  final int sessionRevision;
  final int authorizationRevision;
  final int accessGeneration;
  final String? libraryId;
  final ServerEntryTicket? entry;

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
        permit.accessGeneration != _generation ||
        report.itemId != _report.itemId ||
        report.mediaSourceId != _report.mediaSourceId ||
        report.playSessionId != _report.playSessionId) {
      throw StateError('Frozen stop owner changed');
    }
    _report = report;
  }

  bool _used = false;
  Future<void> reportStopped(ServerStopPermit permit) async {
    if (_used ||
        !permit.isValid ||
        !permit.belongsTo(_owner.access) ||
        permit.previousGeneration != _generation ||
        permit.serverId != account.configuredServerId) {
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
  const ManualCheckResult(
    this.status,
    this.checkedAt, {
    this.failureKind,
    this.latencyMs,
  });
  final MediaServerFailureKind? failureKind;
  final ManualCheckStatus status;
  final DateTime checkedAt;

  /// Milliseconds to receive public server info. Null when that probe failed.
  final int? latencyMs;
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
  final ServerAccessController access;
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

  bool _sessionOwns(MediaServerClient candidate) =>
      _sessions.values.any((session) => identical(session.client, candidate));

  /// A line check must not reuse the browsing session's client. When the
  /// factory hands that instance back, detach a second one instead of failing
  /// the whole page.
  MediaServerClient _independentCheckClient(MediaServerType type) {
    final created = _clientFor(type);
    if (!_sessionOwns(created)) return created;
    final detached = created.createDetached()
      ..onSessionExpired = null
      ..onRefreshSession = null
      ..clearSession();
    if (identical(detached, created) || _sessionOwns(detached)) {
      throw StateError('Check client must be independent');
    }
    return detached;
  }

  String _checkKey(String id, String lineId) => jsonEncode([id, lineId]);

  /// Forget in-flight manual checks for [id] before their results are saved.
  void cancelChecks(String id) {
    final server = _servers.where((server) => server.id == id).firstOrNull;
    if (server == null) return;
    for (final line in server.lines) {
      final key = _checkKey(id, line.id);
      _checkAttempts[key] = (_checkAttempts[key] ?? 0) + 1;
    }
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
  final Map<String, int> _authorizations = {};
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
        !access.isProtected(permit.account.configuredServerId)) {
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
      access.generation(permit.account.configuredServerId),
    );
    _frozenStops.add(stop);
    return stop;
  }

  void _terminateStops() {
    for (final stop in _frozenStops.toList()) {
      if (!_disposed &&
          access.generation(stop.account.configuredServerId) ==
              stop._generation) {
        continue;
      }
      stop._clear();
      _frozenStops.remove(stop);
    }
  }

  /// Compensate one persisted playback without reacquiring cloud authority or
  /// negotiating media. This never publishes a session or grants catalog access.
  Future<bool> recoverPlayback({
    required SourceAccount account,
    required PlaybackReport report,
    required Uri baseUrl,
    required String libraryId,
    int? accessGeneration,
    bool cleanupOnly = false,
  }) async {
    requireContentAccess(account.configuredServerId);
    final server = _allowed(account.configuredServerId);
    final scope = _authorizations[server.id] ?? 0;
    final generation = access.generation(server.id);
    void requireOwner() {
      try {
        _requireCurrent(server, scope, generation);
        final current = _allowed(server.id);
        if (current.serviceType != account.serviceType ||
            current.verifiedServerId != account.verifiedServerId ||
            current.cloudAccountId != account.cloudAccountId ||
            current.homeUserId != account.homeUserId ||
            !current.lines.any((line) => Uri.parse(line.address) == baseUrl) ||
            (access.isProtected(account.configuredServerId) &&
                (accessGeneration != generation ||
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
        (_authorizations[server.id] ?? 0) != scope ||
        _allowed(server.id).serviceType != server.serviceType ||
        generation != access.generation(server.id)) {
      throw StateError('Access revoked');
    }
  }

  Future<void>? _writes;
  int _writeTicket = 0;
  bool _loaded = false;
  late final ServerListStore configurationStore = _RegistryServerStore(this);
  Future<void> load() async {
    final snapshot = await store.load();
    _servers = snapshot.servers
        .map((s) => SavedServer.fromJson(s.toJson()))
        .toList();
    for (final server in _servers) {
      await access.register(server);
    }
    _lastServerId = snapshot.lastServerId;
    _loaded = true;
  }

  /// Offline, additive import. Each record shares the configuration/credential
  /// writer and is published only after both stores have committed.
  Future<ServerImportResult> importServers(
    Iterable<ServerImportDraft> drafts,
  ) async {
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
      if (draft.isPrivate) {
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
      final scope = _authorizations[id] ?? 0;
      void guard() {
        if ((_authorizations[id] ?? 0) != scope ||
            _transitioning.contains(id)) {
          throw const _ImportRevoked();
        }
      }

      await _enqueue(() async {
        try {
          guard();
          final addresses = lines.map((line) => line.address).toSet();
          for (final existing in _servers.where(
            (s) => s.serviceType == draft.serviceType,
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
            for (final server in next) {
              await access.register(server);
            }
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

  List<SavedServer> project() =>
      List.unmodifiable(_servers.where((s) => !_transitioning.contains(s.id)));

  void requireContentAccess(String id) {
    _allowed(id);
    if (!access.allows(id)) throw StateError('Server entry required');
  }

  Future<void> requireConfiguredServer(String id) async {
    if (!_loaded) await load();
    if (_transitioning.contains(id)) throw StateError('Source changing');
  }

  Future<void> requireConfiguredIdentity(
    MediaServerType type,
    String remoteId,
  ) async {
    if (!_loaded) await load();
    if (_servers.any(
      (s) =>
          s.serviceType == type &&
          s.expectedServerId == remoteId &&
          _transitioning.contains(s.id),
    )) {
      throw StateError('Source changing');
    }
  }

  SavedServer _allowed(String id) {
    final server = _servers.where((s) => s.id == id).firstOrNull;
    if (_disposed || server == null || _transitioning.contains(id)) {
      throw StateError('Source unavailable');
    }
    return server;
  }

  Future<SourceAuthorization> beginAuthorization({
    required MediaServerType serviceType,
    String? configuredServerId,
  }) async {
    if (!_loaded) await load();
    final id = configuredServerId ?? 'source-${generateDeviceId()}';
    final existing = _servers.where((s) => s.id == id).firstOrNull;
    if (configuredServerId != null &&
        (existing == null || existing.serviceType != serviceType)) {
      throw StateError('Source identity mismatch');
    }
    if (_cloudDisconnects.contains(existing?.cloudCredentialRef) ||
        _transitioning.contains(id) ||
        (_credentialChanges.contains(id) || _candidateCommits.contains(id))) {
      throw StateError('Source changing');
    }
    // Preparing another account must not revoke the still usable session.
    _authorizations.putIfAbsent(id, () => 0);
    final attempt = (_authAttempts[id] ?? 0) + 1;
    _authAttempts[id] = attempt;
    final authorization = SourceAuthorization._(
      this,
      id,
      serviceType,
      _authorizations[id]!,
      access.generation(id),
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
      (authorization._configuration == null ||
          authorization._generation == access.generation(authorization.id)) &&
      _authorizations[authorization.id] == authorization._scope &&
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
                    old.expectedServerId != server.verifiedServerId))) {
          throw StateError('Source identity changed');
        }
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
          for (final server in next) {
            await access.register(server);
          }
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
          for (final server in next) {
            await access.register(server);
          }
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

  Future<CredentialCommit> beginCredentials(String id) async {
    await requireConfiguredServer(id);
    // A management login publishes its new authorization after its durable
    // write completes. Capture authority after that publication, so a logout
    // queued behind the write can delete the newly saved credential.
    final pendingWrite = _writes;
    if (pendingWrite != null) {
      try {
        await pendingWrite;
      } catch (_) {
        // A failed write does not prevent explicit credential cleanup.
      }
      await requireConfiguredServer(id);
    }
    return CredentialCommit._(this, id, _authorizations[id] ?? 0);
  }

  void _guardCredentials(CredentialCommit commit) {
    if (!identical(commit.owner, this) ||
        (_authorizations[commit.id] ?? 0) != commit.scope ||
        _transitioning.contains(commit.id) ||
        _servers.any(
          (s) =>
              s.id == commit.id &&
              _cloudDisconnects.contains(s.cloudCredentialRef),
        )) {
      throw StateError('Credential operation revoked');
    }
  }

  /// Only a completed write or completed rollback can replace the selected
  /// lease retired by that write. Later authorization or entry changes still
  /// revoke this proof; callers cannot renew it by taking a fresh snapshot.
  void Function() settledCredentialsGuard(CredentialCommit commit) {
    final guard = commit._settledSelectionGuard;
    if (!identical(commit.owner, this) || guard == null) {
      throw StateError('Credential write did not settle');
    }
    guard();
    return guard;
  }

  /// Shares the configuration writer. Migration revokes synchronously; if it
  /// starts during secure-store IO, restore the old value before it can commit.
  Future<void> commitCredentials(
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
    final writing = CredentialCommit._(
      this,
      commit.id,
      _authorizations[commit.id]!,
    );
    final generation = access.generation(commit.id);
    void settledGuard() {
      _guardCredentials(writing);
      requireContentAccess(commit.id);
      if (access.generation(commit.id) != generation) {
        throw StateError('Credential entry revoked');
      }
    }

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
        for (final server in next) {
          await access.register(server);
        }
      }
      if (value != null) commit._settledSelectionGuard = settledGuard;
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
      if (value != null && previous != null) {
        commit._settledSelectionGuard = settledGuard;
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
    for (final server in next) {
      await access.register(server);
    }
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
    final next = change(current);
    return _servers.map((s) => s.id == id ? next : s).toList();
  });

  final Map<String, int> _selectedRevisions = {};

  /// A selected single-source session is independent of aggregation library
  /// scope, but is revoked by authentication, logout, membership and locking.
  void Function() selectedSessionGuard(String id) {
    final server = _allowed(id);
    final revision = _selectedRevisions[id] ?? 0;
    return () {
      final current = _allowed(id);
      if ((_selectedRevisions[id] ?? 0) != revision ||
          current.serviceType != server.serviceType ||
          _cloudDisconnects.contains(current.cloudCredentialRef)) {
        throw StateError('Selected source revoked');
      }
    };
  }

  void _invalidate(String id, {bool revokeSelected = true}) {
    if (revokeSelected) {
      _selectedRevisions[id] = (_selectedRevisions[id] ?? 0) + 1;
    }
    _authorizations[id] = (_authorizations[id] ?? 0) + 1;
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
    final scope = _authorizations[id] ?? 0;
    final generation = access.generation(id);
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
    // Changing the server-level User-Agent is metadata. It must not trigger a
    // second anonymous identity probe: some Emby reverse proxies route or
    // filter that request based on the custom header and can return a response
    // which looks like a different server. Only an address change changes the
    // endpoint identity and therefore requires a probe.
    final connectionChanged = candidate.baseUrl != original.baseUrl;
    final userAgentChanged =
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
        for (final server in next) {
          await access.register(server);
        }
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
      if (userAgentChanged && !connectionChanged) {
        _sessions[id]?.client.setUserAgent(candidate.userAgent);
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

  Future<void> setLineAddress(
    String id,
    String address, {
    String? lineId,
    String? nickname,
  }) => _editLines(id, (server) {
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
        if (lineId == null)
          ServerLine(id: generateLineId(), address: uri, nickname: nickname),
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

  /// Publishes an already verified playback connection without revoking the
  /// account lease. The caller owns native open and compensates a failed save.
  Future<void> commitPlaybackLine({
    required OperationPermit permit,
    required MediaServerClient client,
    required String lineId,
    required LineSelection selection,
    required void Function() guard,
  }) async {
    final id = permit.account.configuredServerId;
    final original = _allowed(id);
    void current() {
      guard();
      permit.requireValid();
      final server = _allowed(id);
      if (server.lines.length != original.lines.length ||
          jsonEncode(server.lines.map((l) => l.toJson()).toList()) !=
              jsonEncode(original.lines.map((l) => l.toJson()).toList()) ||
          server.lineSelection != original.lineSelection ||
          server.activeLineId != original.activeLineId ||
          client.userId != permit.account.userId ||
          client.serviceType != permit.account.serviceType ||
          !server.lines.any(
            (l) => l.id == lineId && Uri.parse(l.address) == client.baseUrl,
          ) ||
          (selection.fixedLineId != null && selection.fixedLineId != lineId)) {
        throw StateError('Playback line transaction expired');
      }
    }

    current();
    await _enqueue(() async {
      current();
      final previous = ServerListSnapshot(
        servers: _servers,
        lastServerId: _lastServerId,
      );
      final next = _servers
          .map(
            (s) => s.id == id
                ? s.copyWith(
                    activeLineId: lineId,
                    lineSelection: selection,
                    lastSuccessfulLineId: lineId,
                  )
                : s,
          )
          .toList();
      try {
        await store.save(
          ServerListSnapshot(servers: next, lastServerId: _lastServerId),
        );
        current();
      } catch (_) {
        await store.save(previous);
        rethrow;
      }
      // The commit point has no further asynchronous work. Access protection
      // did not change, so there is no need to re-register or revoke its lease.
      _servers = next;
      _configurationRevision++;
      final session = _sessions[id]!;
      session.client.attachSession(
        baseUrl: client.baseUrl!,
        accessToken: client.accessToken!,
        userId: client.userId!,
        userAgent: client.customUserAgent,
      );
      _notifySourceChange(id);
    });
  }

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
  SourceAccount? sessionAccount(String id, {required String libraryId}) {
    if (!access.allows(id)) return null;
    final account = _sessions[id]?.account;
    if (account == null) return null;
    try {
      permit(account, libraryId: libraryId).requireValid();
      return account;
    } on StateError {
      return null;
    }
  }

  Future<SourceAccount> acquireAccount(
    String id, {
    required String libraryId,
  }) async {
    final session = await ensureSession(id);
    permit(session.account, libraryId: libraryId).requireValid();
    return session.account;
  }

  /// Deliberate management login; never changes the legacy active account.
  Future<void> login(String id, String username, String password) async {
    final server = _allowed(id);
    final client = _clientFor(server.serviceType);
    final authorization = await beginAuthorization(
      serviceType: server.serviceType,
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
    final session = await ensureSession(id);
    final server = _allowed(id);
    final scope = _authorizations[id] ?? 0;
    final generation = access.generation(server.id);
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
    requireContentAccess(id);
    final generation = access.generation(id);
    final session = await prepareEntrySession(id);
    requireContentAccess(id);
    if (generation != access.generation(id)) throw StateError('Access revoked');
    return _contentSession(session);
  }

  SourceSession _contentSession(SourceSession session) {
    final accessPermit = permit(session.account);
    return SourceSession._(
      session.account,
      session.client.withRequestGuard(accessPermit.requireValid),
      session.revision,
      verified: session.verified,
    );
  }

  /// Identity/account preflight only. No content requests or media permit are
  /// granted by this method; entry publishes access after successful commit.
  Future<SourceSession> prepareEntrySession(String id) async {
    final server = _allowed(id);
    if (_candidateCommits.contains(id)) {
      final existing = _sessions[id];
      if (existing != null) return existing;
      throw StateError('Source authorization is committing');
    }
    final scope = _authorizations[id] ?? 0;
    final generation = access.generation(server.id);
    _requireCurrent(server, scope, generation);
    final reused = await _reuse(server, scope, generation);
    if (reused != null) return reused;
    final pending = _sessionAcquisitions[id];
    if (pending != null) return pending;
    final created = server.identityPending
        ? prepareAuthentication(id)
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
      if ((_authorizations[server.id] ?? 0) != scope ||
          generation != access.generation(server.id)) {
        throw StateError('Access revoked');
      }
      final session = SourceSession._(
        SourceAccount(
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
    final scope = _authorizations[id] ?? 0;
    final generation = access.generation(server.id);
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
    requireContentAccess(id);
    final generation = access.generation(id);
    final result = await prepareAuthentication(id, lineId: lineId);
    requireContentAccess(id);
    if (generation != access.generation(id)) throw StateError('Access revoked');
    return _contentSession(result);
  }

  Future<SourceSession> prepareAuthentication(
    String id, {
    String? lineId,
  }) async {
    final server = _allowed(id);
    final line = lineId == null
        ? server.activeLine
        : server.lines.where((line) => line.id == lineId).firstOrNull;
    if (line == null) throw StateError('Unknown authentication line');
    final baseUrl = Uri.parse(line.address);
    final scope = _authorizations[id] ?? 0;
    final generation = access.generation(server.id);
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
      if ((_authorizations[id] ?? 0) != scope ||
          generation != access.generation(server.id)) {
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
          for (final server in next) {
            await access.register(server);
          }
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
    ServerEntryTicket? entry,
  }) {
    final server = _allowed(account.configuredServerId);
    final session = _sessions[server.id];
    if (entry == null) {
      requireContentAccess(server.id);
    } else if (!entry.authorizes(access, server.id)) {
      throw StateError('Entry preparation revoked');
    }
    if (_cloudDisconnects.contains(server.cloudCredentialRef) ||
        _credentialChanges.contains(server.id) ||
        session?.account != account) {
      throw StateError('Source authorization revoked');
    }
    return OperationPermit._(
      this,
      account,
      session!.revision,
      _authorizations[server.id] ?? 0,
      entry?.generation ?? access.generation(server.id),
      libraryId,
      entry,
    );
  }

  bool accepts(OperationPermit permit) {
    if (!identical(permit._owner, this)) return false;
    try {
      final server = _allowed(permit.account.configuredServerId);
      final session = _sessions[server.id];
      return !_cloudDisconnects.contains(server.cloudCredentialRef) &&
          !_credentialChanges.contains(server.id) &&
          server.serviceType == permit.account.serviceType &&
          (permit.entry?.authorizes(access, server.id) ??
              access.allows(server.id)) &&
          session?.account == permit.account &&
          session?.client.hasSession == true &&
          session?.client.userId == permit.account.userId &&
          session?.revision == permit.sessionRevision &&
          (_authorizations[server.id] ?? 0) == permit.authorizationRevision &&
          (permit.entry?.generation ?? access.generation(server.id)) ==
              permit.accessGeneration;
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
    final checkKey = _checkKey(id, line.id);
    final scope = _authorizations[id] ?? 0;
    final generation = access.generation(server.id);
    _requireCurrent(server, scope, generation);
    final client = _independentCheckClient(server.serviceType);
    client.setUserAgent(server.userAgent);
    if (_sessionOwns(client)) {
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
    int? latencyMs;
    try {
      status = await (() async {
        final watch = Stopwatch()..start();
        final info = await client.getPublicInfo(Uri.parse(line.address));
        latencyMs = watch.elapsedMilliseconds;
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
    if ((_authorizations[id] ?? 0) != scope ||
        generation != access.generation(server.id)) {
      throw StateError('Check revoked');
    }
    final result = ManualCheckResult(
      status,
      DateTime.now(),
      failureKind: failureKind,
      latencyMs: latencyMs,
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
                      latencyMs: latencyMs,
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
    final id = access.revokingServerId;
    if (id != null) _invalidate(id);
  }

  Future<void> _clearPrivate(ServerStopPermit permit) async {
    _sessions.remove(permit.serverId)?.client.clearSession();
  }

  Future<void> _saveConfigurationSnapshot(
    ServerListSnapshot snapshot,
    Map<String, SavedServer> baseline,
  ) async {
    if (!_loaded) await load();
    final incoming = {for (final s in snapshot.servers) s.id: s};
    if (incoming.length != snapshot.servers.length) {
      throw StateError('Duplicate server');
    }
    await _commit(
      () {
        final next = <SavedServer>[];
        for (final current in _servers) {
          final update = incoming.remove(current.id);
          if (update == null) {
            if (!baseline.containsKey(current.id)) next.add(current);
            continue;
          }
          final old = baseline[current.id];
          if (old == null) throw StateError('Server appeared after snapshot');
          final merged = _mergeDelta(
            current.toConfigurationJson(),
            old.toConfigurationJson(),
            update.toConfigurationJson(),
          );
          for (final key in [
            'serviceType',
            'authorizationMethod',
            'cloudCredentialRef',
            'cloudAccountId',
            'homeUserId',
            'resourceCredentialRef',
            'protectionRef',
            'verifiedServerId',
            'identityPending',
            'checkedAt',
            'checkStatus',
          ]) {
            merged[key] = current.toConfigurationJson()[key];
          }
          merged['lines'] = _mergeLines(current.lines, old.lines, update.lines);
          next.add(SavedServer.fromJson(merged));
        }
        next.addAll(incoming.values);
        return next;
      },
      replaceLast: true,
      lastServerId: snapshot.lastServerId,
    );
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
class _RegistryServerStore implements ServerListStore {
  _RegistryServerStore(this.registry);
  final SourceSessionRegistry registry;
  Map<String, SavedServer> _baseline = {};
  @override
  Future<ServerListSnapshot> load() async {
    if (!registry._loaded) await registry.load();
    final ordinary = registry.project();
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
    await registry._saveConfigurationSnapshot(snapshot, _baseline);
    // Track what this consumer actually observed, not newer registry values.
    _baseline = {for (final s in snapshot.servers) s.id: s};
  }
}
