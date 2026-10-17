import 'dart:async';

import 'package:flutter/foundation.dart';

import '../media_server/authentication.dart';
import '../media_server/capabilities.dart';
import '../media_server/device.dart';
import '../media_server/errors.dart';
import '../media_server/media_server_client.dart';
import '../media_server/server_address.dart';
import '../plex/plex_authentication.dart';
import 'auth_controller.dart';
import 'provider_identity.dart';
import 'server_paste_draft.dart';
import 'cloud_credentials.dart';
import 'connection_failure.dart';
import 'credential_store.dart';
import 'server_list_store.dart';
import 'source_sessions.dart';

enum ProviderConnectStage {
  credentials,
  authorization,
  resources,
  libraries,
  done,
}

/// Shared candidate authorization for desktop, phone and remote controls.
/// Successful authorization enters content directly, without a scope step.
class ProviderConnectController extends ChangeNotifier {
  ProviderConnectController({
    required this.auth,
    this.existing,
    this.region = AccessRegion.ordinary,
    String? userAgent,
    this.pollInterval,
  }) : type = existing?.serviceType ?? MediaServerType.emby,
       userAgent = userAgent ?? existing?.userAgent ?? '';

  final AuthController auth;
  final SavedServer? existing;
  final AccessRegion region;
  final Duration? pollInterval;
  MediaServerType type;
  String userAgent;

  /// Editable paste preview fields; no writes occur until authorization commits.
  String? displayName;
  final List<String> extraLines = [];
  PendingCloudCredentials? _pendingCloud;
  String? _submittedPassword;
  ProviderConnectStage stage = ProviderConnectStage.credentials;
  bool busy = false;
  MediaServerFailureKind? failure;
  AuthorizationStatus? authorizationStatus;
  AuthorizationAttempt? attempt;
  CloudAccount? account;
  List<HomeUser> users = [];
  List<AuthorizedServerResource> resources = [];
  Map<String, String> libraries = {};
  final Set<String> selectedLibraries = {};
  String? sourceId;
  SourceAuthorization? _authorization;
  PlexAuthentication? _plex;
  MediaServerClient? _client;
  Timer? _timer;
  int _epoch = 0;
  bool _disposed = false;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void _guard(int epoch) {
    if (_disposed || epoch != _epoch || !auth.regionAccess.allows(region)) {
      throw StateError('Authorization revoked');
    }
  }

  Future<void> _run(Future<void> Function(int epoch) operation) async {
    if (busy || _disposed) return;
    final epoch = _epoch;
    busy = true;
    failure = null;
    _changed();
    try {
      await operation(epoch);
    } catch (error) {
      if (!_disposed && epoch == _epoch) {
        failure = connectionFailure(error).kind;
      }
    } finally {
      if (!_disposed && epoch == _epoch) {
        busy = false;
        _changed();
      }
    }
  }

  Future<void> _begin(int epoch) async {
    _authorization?.cancel();
    final authorization = await auth.sources.beginAuthorization(
      serviceType: type,
      region: region,
      configuredServerId: existing?.id,
    );
    if (_disposed || epoch != _epoch) {
      authorization.cancel();
      return;
    }
    _authorization = authorization;
    _guard(epoch);
    authorization.requireValid();
    _client = auth
        .createProviderClient(type)
        .withRequestGuard(authorization.requireValid);
    _client!.setUserAgent(userAgent);
    if (type == MediaServerType.plex) {
      final base = auth.plexAuthentication;
      _plex = PlexAuthentication(
        device: base.device,
        readCredential: (_pendingCloud = PendingCloudCredentials(
          CloudCredentialStore(auth.credentials),
        )).read,
        writeCredential: _pendingCloud!.write,
        deleteCredential: _pendingCloud!.delete,
        dio: base.dio,
        accountUrl: base.accountUrl,
        homeUrl: base.homeUrl,
        now: base.now,
        strongPin: base.strongPin,
        guard: authorization.requireValid,
        userAgent: userAgent,
      );
    }
  }

  /// The caller selects exactly one parsed group and may edit it first.
  Future<void> submitDraft(
    ServerPasteDraft draft, {
    bool acceptUnrecognized = false,
  }) {
    if (draft.unrecognized.isNotEmpty && !acceptUnrecognized) {
      failure = MediaServerFailureKind.invalidResponse;
      _changed();
      return Future.value();
    }
    if (draft.lines.isEmpty) {
      failure = MediaServerFailureKind.invalidAddress;
      _changed();
      return Future.value();
    }
    type = draft.serviceType;
    displayName = draft.name.isEmpty ? null : draft.name;
    extraLines
      ..clear()
      ..addAll(draft.lines.skip(1));
    return password(draft.lines.first, draft.username, draft.password);
  }

  Future<void> password(String address, String username, String password) =>
      _run((epoch) async {
        await _begin(epoch);
        _guard(epoch);
        _submittedPassword = password;
        final uri = normalizeServerAddress(address);
        final info = await _client!.getPublicInfo(uri);
        _guard(epoch);
        _authorization!.requireValid();
        final session = await _client!.authenticateByName(
          baseUrl: uri,
          username: username.trim(),
          password: password,
          serverId: info.id,
        );
        _guard(epoch);
        _authorization!.requireValid();
        if (session.serverId != info.id) {
          throw StateError('Server identity mismatch');
        }
        await _commitSession(
          epoch,
          uri,
          info,
          session,
          AuthorizationMethod.password,
        );
      });

  Future<void> authorize(String address) => _run((epoch) async {
    await _begin(epoch);
    _guard(epoch);
    _submittedPassword = null;
    final method = type == MediaServerType.plex
        ? AuthorizationMethod.browserPin
        : AuthorizationMethod.quickConnect;
    final interactive = type == MediaServerType.plex
        ? _plex!
        : _client!.interactiveAuthentication!;
    final uri = type == MediaServerType.plex
        ? null
        : normalizeServerAddress(address);
    final availability = await interactive.availability(method, server: uri);
    _authorization!.requireValid();
    if (!availability.isAvailable) {
      throw const MediaServerException(MediaServerFailureKind.unsupported);
    }
    final pending = await interactive.begin(method, server: uri);
    if (_disposed || epoch != _epoch || !_authorization!.isValid) {
      await pending.cancel();
      return;
    }
    attempt = pending;
    stage = ProviderConnectStage.authorization;
    authorizationStatus = AuthorizationStatus.pending;
    _schedulePoll(epoch, uri);
  });

  void _schedulePoll(int epoch, Uri? uri) {
    _timer?.cancel();
    _timer = Timer(pollInterval ?? attempt!.pollInterval, () {
      if (!_disposed && epoch == _epoch) unawaited(_poll(epoch, uri));
    });
  }

  Future<void> _poll(int epoch, Uri? uri) => _run((_) async {
    _guard(epoch);
    final pending = attempt!;
    final status = DateTime.now().isAfter(pending.expiresAt)
        ? AuthorizationStatus.expired
        : await _authorization!.poll(pending);
    _guard(epoch);
    authorizationStatus = status;
    if (status == AuthorizationStatus.pending) {
      _schedulePoll(epoch, uri);
      return;
    }
    if (status != AuthorizationStatus.authorized) {
      _authorization!.cancel();
      await pending.cancel();
      return;
    }
    final grant = await _authorization!.exchange(pending);
    _guard(epoch);
    if (grant is CloudAuthorizationGrant) {
      account = grant.account;
      await _discover(epoch);
    } else if (grant is SessionAuthorizationGrant) {
      final info = await _client!.getPublicInfo(uri!);
      _authorization!.requireValid();
      await _commitSession(
        epoch,
        uri,
        info,
        grant.session,
        AuthorizationMethod.quickConnect,
      );
    }
  });

  Future<void> restoreHome() => _run((epoch) async {
    await _begin(epoch);
    _guard(epoch);
    account = await _plex!.restoreAccount(existing!.cloudCredentialRef!);
    _authorization!.requireValid();
    // Do not expose owner resources while a Home user is selected.
    users = await _plex!.homeUsers(account!);
    _authorization!.requireValid();
    resources = [];
    stage = ProviderConnectStage.resources;
  });

  Future<void> _discover(int epoch) async {
    resources = await _plex!.discoverResources(account!);
    _authorization!.requireValid();
    _guard(epoch);
    users = await _plex!.homeUsers(account!);
    _authorization!.requireValid();
    stage = ProviderConnectStage.resources;
  }

  Future<void> selectHome(HomeUser user, String? pin) => _run((epoch) async {
    resources = [];
    _authorization!.requireValid();
    final next = await _plex!.switchHomeUser(account!, user, pin: pin);
    _authorization!.requireValid();
    _guard(epoch);
    resources = next;
  });

  Future<void> selectResource(
    AuthorizedServerResource resource,
    ServerConnection connection,
  ) => _run((epoch) async {
    _authorization!.requireValid();
    if (existing != null && resource.server.id != existing!.verifiedServerId) {
      throw StateError('Server identity mismatch');
    }
    final secret = await _pendingCloud!.read(resource.resourceCredentialRef);
    _authorization!.requireValid();
    _guard(epoch);
    final id = _authorization!.id;
    // Discovery may include unreachable relays. Only the deliberately selected
    // connection is admitted; extra addresses belong to the editable preview.
    final oldLine = existing?.lines
        .where((l) => normalizeServerAddress(l.address) == connection.uri)
        .firstOrNull;
    final lines = [
      ServerLine(
        id: oldLine?.id ?? '$id-line',
        address: normalizeServerAddress(connection.uri.toString()).toString(),
      ),
    ];
    const selected = 0;
    final server = SavedServer(
      id: id,
      name: resource.server.serverName,
      nickname: displayName ?? existing?.nickname,
      userAgent: normalizeUserAgent(userAgent),
      username: resource.user.name,
      region: region,
      serviceType: type,
      lines: lines,
      activeLineId: lines[selected].id,
      lineSelection: existing?.lineSelection.isAutomatic == false
          ? LineSelection.fixed(lines[selected].id)
          : const LineSelection.auto(),
      iconId: existing?.iconId,
      protectionRef: existing?.protectionRef,
      credentialRef: existing?.credentialRef,
      verifiedServerId: resource.server.id,
      authorizationMethod: AuthorizationMethod.browserPin,
      cloudAccountId: account!.id,
      cloudCredentialRef: account!.credentialRef,
      homeUserId: resource.homeUserId,
      resourceCredentialRef: resource.resourceCredentialRef,
    );
    await _commit(
      epoch,
      server,
      StoredCredentials(
        accessToken: secret?['accessToken'] as String? ?? '',
        userId: resource.user.id,
        username: resource.user.name,
        serviceType: type,
        authorizationMethod: AuthorizationMethod.browserPin,
        cloudAccountId: account!.id,
        cloudCredentialRef: account!.credentialRef,
        homeUserId: resource.homeUserId,
        resourceCredentialRef: resource.resourceCredentialRef,
      ),
    );
  });

  Future<void> _commitSession(
    int epoch,
    Uri uri,
    PublicServerInfo info,
    AuthenticationResult session,
    AuthorizationMethod method,
  ) async {
    _guard(epoch);
    if (session.serverId != info.id) {
      throw StateError('Server identity mismatch');
    }
    final id = _authorization!.id;
    await _commit(
      epoch,
      SavedServer(
        id: id,
        name: info.serverName,
        username: session.user.name,
        serviceType: type,
        region: region,
        authorizationMethod: method,
        verifiedServerId: info.id,
        nickname: displayName ?? existing?.nickname,
        userAgent: normalizeUserAgent(userAgent),
        lines: existing == null
            ? [ServerLine(id: '$id-line', address: uri.toString())]
            : [
                for (final line in existing!.lines)
                  line.id == existing!.activeLine?.id
                      ? line.copyWith(address: uri.toString())
                      : line,
              ],
        activeLineId: existing?.activeLine?.id ?? '$id-line',
        lineSelection: existing?.lineSelection ?? const LineSelection.auto(),
        lastSuccessfulLineId: existing?.lastSuccessfulLineId,
        iconId: existing?.iconId,
        protectionRef: existing?.protectionRef,
        credentialRef: existing?.credentialRef,
      ),
      StoredCredentials(
        password: _submittedPassword,
        accessToken: session.accessToken,
        userId: session.user.id,
        username: session.user.name,
        serviceType: type,
        authorizationMethod: method,
      ),
    );
  }

  Future<void> _commit(
    int epoch,
    SavedServer server,
    StoredCredentials credentials,
  ) async {
    _guard(epoch);
    final addresses = server.lines
        .map((l) => normalizeServerAddress(l.address).toString())
        .toSet();
    final lines = [...server.lines];
    for (final raw in extraLines) {
      final address = normalizeServerAddress(raw).toString();
      if (addresses.add(address)) {
        lines.add(ServerLine(id: generateLineId(), address: address));
      }
    }
    server = server.copyWith(lines: lines);
    await auth.sources.commitAuthorization(
      _authorization!,
      server: server,
      value: credentials,
      candidateVerifier: type == MediaServerType.plex
          ? (s, c, client) => verifyProviderIdentity(_plex!, s, c, client)
          : null,
      persistCandidate: _pendingCloud?.commit,
      rollbackCandidate: _pendingCloud?.rollback,
      remember: region == AccessRegion.ordinary,
    );
    _guard(epoch);
    sourceId = server.id;
    await _finish(epoch);
  }

  Future<void> _finish(int epoch) async {
    _guard(epoch);
    await auth.refreshServers();
    _guard(epoch);
    if (region == AccessRegion.ordinary) {
      await auth.activateCommittedSource(sourceId!, guard: () => _guard(epoch));
      _guard(epoch);
      if (auth.session?.server.id != sourceId) {
        throw StateError('Source activation failed');
      }
    }
    stage = ProviderConnectStage.done;
  }

  // Kept for old presentation consumers until the new form replaces them.
  Future<void> retryLibraries() => Future.value();
  Future<void> finish() =>
      stage == ProviderConnectStage.done || sourceId == null
      ? Future.value()
      : _run(_finish);

  void reset([MediaServerType? service]) {
    _epoch++;
    _timer?.cancel();
    _authorization?.cancel();
    final pending = attempt;
    if (pending != null) unawaited(pending.cancel().catchError((Object _) {}));
    _client?.clearSession();
    _submittedPassword = null;
    _pendingCloud = null;
    attempt = null;
    account = null;
    resources = [];
    users = [];
    libraries = {};
    selectedLibraries.clear();
    sourceId = null;
    failure = null;
    authorizationStatus = null;
    busy = false;
    if (service != null) type = service;
    stage = ProviderConnectStage.credentials;
    _changed();
  }

  @override
  void dispose() {
    _disposed = true;
    reset();
    super.dispose();
  }
}
