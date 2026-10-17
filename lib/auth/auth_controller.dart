import '../media_server/provider_registry.dart';
import '../plex/plex_authentication.dart';
import 'cloud_credentials.dart';
import 'connection_failure.dart';
import 'provider_identity.dart';
import '../media_server/capabilities.dart';
import '../media_server/authentication.dart';

import 'package:rillight/media_server/server_address.dart';

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:rillight/app/file_import.dart';
import 'package:rillight/auth/backup_import/backup_import_models.dart';
import 'package:rillight/auth/connect_draft.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/auth/source_sessions.dart';
import 'package:rillight/auth/server_import_models.dart';
import 'package:rillight/auth/region_access.dart';
import 'package:rillight/media_server/media_server_client.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/media_server/device.dart';
import 'package:rillight/media_server/errors.dart';

class AuthSession {
  const AuthSession({
    required this.server,
    required this.userId,
    required this.username,
    required this.accessToken,
  });

  final SavedServer server;
  final String userId;
  final String username;
  final String accessToken;
}

class LineSwitchFailure {
  const LineSwitchFailure({required this.address, required this.detail});

  final String address;
  final String detail;
}

class AuthController extends ChangeNotifier {
  AuthController({
    required MediaServerClient client,
    required this.credentials,
    required ServerListStore servers,
    SourceSessionRegistry? sources,
    RegionAccessController? regionAccess,
    this.persistPin,
    MediaServerClient Function(MediaServerType)? providerClientFactory,
    PlexAuthentication? plexAuthentication,
  }) : _client = client {
    _providerClientFactory =
        providerClientFactory ??
        (type) => type == client.serviceType
            ? client.createDetached()
            : MediaServerProviders.create(type, client.device);
    _plexAuthentication = plexAuthentication;
    this.sources =
        sources ??
        SourceSessionRegistry(
          access: regionAccess ?? RegionAccessController(),
          store: servers,
          credentials: credentials,
          createClient: client.createDetached,
          createProviderClient: createProviderClient,
          sessionIdentityVerifier: (server, value, attached) async {
            if (server.serviceType == MediaServerType.plex) {
              await verifyProviderIdentity(
                this.plexAuthentication,
                server,
                value,
                attached,
              );
            }
          },
        );
    this.servers = this.sources.ordinaryStore;
    this.sources.addMembershipCleanup(_clearSourceContribution);
    this.sources.addSourceRevocation(_sourceChanged);
  }

  factory AuthController.memory({
    MediaServerClient? client,
    RegionAccessController? regionAccess,
  }) {
    return AuthController(
      client:
          client ??
          EmbyClient(
            device: const ClientDeviceInfo(
              clientName: 'Rillight',
              deviceName: 'test',
              deviceId: 'rillight-memory-device',
              version: '0.1.0',
            ),
          ),
      credentials: MemoryCredentialStore(),
      servers: MemoryServerListStore(),
      regionAccess: regionAccess,
    );
  }

  MediaServerClient _client;
  MediaServerClient? _guardedClient;
  MediaServerClient get client => _guardedClient ?? _client;
  late final MediaServerClient Function(MediaServerType) _providerClientFactory;
  PlexAuthentication? _plexAuthentication;
  PlexAuthentication get plexAuthentication {
    final cloud = CloudCredentialStore(credentials);
    return _plexAuthentication ??= PlexAuthentication(
      device: _client.device,
      readCredential: cloud.readCredential,
      writeCredential: cloud.writeCredential,
      deleteCredential: cloud.deleteCredential,
    );
  }

  MediaServerClient createProviderClient(MediaServerType type) =>
      _providerClientFactory(type);
  void Function()? _selectionGuard;
  int _activationGeneration = 0;
  Object? _sessionOwner;
  bool _ownsActivation(int generation) =>
      !_disposed && generation == _activationGeneration;
  void _requireActivation(int generation) {
    if (!_ownsActivation(generation)) throw StateError('Selection superseded');
  }

  String? _revokedSelectionId;
  bool _refreshingSelection = false;

  Future<void> refreshServers() async {
    final snapshot = await servers.load();
    if (_disposed) return;
    _savedServers = snapshot.servers;
    final selected = _session;
    if (selected != null) {
      final current = _serverById(selected.server.id);
      if (current != null) {
        _session = AuthSession(
          server: current,
          userId: selected.userId,
          username: selected.username,
          accessToken: selected.accessToken,
        );
      }
    }
    notifyListeners();
  }

  void _sourceChanged(String id) {
    if (_session?.server.id != id || _busy || _refreshingSelection) return;
    try {
      _selectionGuard?.call();
    } on StateError {
      _revokedSelectionId = id;
      _prefill = _session?.server;
      _session = null;
      _client.clearSession();
      _guardedClient?.clearSession();
      _guardedClient = null;
      _resetLibraryCounts();
      if (!_disposed) notifyListeners();
    }
  }

  final CredentialStore credentials;
  late final ServerListStore servers;
  late final SourceSessionRegistry sources;
  RegionAccessController get regionAccess => sources.access;
  final Future<void> Function(PinVerifier)? persistPin;
  Future<void> setPrivatePin(String pin, String confirmation) =>
      regionAccess.setPin(pin, confirmation, persistPin ?? (_) async {});

  Future<void> _clearSourceContribution(
    SourceAccount? account,
    String id,
  ) async {
    if (_revokedSelectionId == id) _revokedSelectionId = null;
    _savedServers = _savedServers.where((s) => s.id != id).toList();
    if (_session?.server.id == id) {
      _session = null;
      client.clearSession();
      _resetLibraryCounts();
    }
    if (_prefill?.id == id) _prefill = null;
    if (!_disposed) notifyListeners();
  }

  ConnectDraft? connectDraft;

  /// 备份导入的文件选择边界。生产使用系统选择器;测试与原型捕获注入
  /// 假实现,不把用户路径或 Android content URI 直接交给解析器。
  AppFilePicker? backupImportPicker;

  /// 备份解密材料注入点。仓库不携带第三方客户端密钥常量;授权渠道
  /// 注入前,加密容器按 decryptionKeyUnavailable 如实报告,不假装成功。
  BackupImportKeys backupImportKeys = const BackupImportKeys();

  AuthSession? _session;
  List<SavedServer> _savedServers = const [];
  SavedServer? _prefill;
  String? _rememberedServerId;
  MediaServerException? _failure;
  LineSwitchFailure? _lineSwitchFailure;
  bool _busy = false;
  bool _handlingExpiry = false;
  LibraryCounts? _libraryCounts;
  MediaServerException? _libraryCountsFailure;
  String? _libraryCountsServerId;
  bool _libraryCountsLoading = false;
  int _libraryCountsSeq = 0;
  bool _disposed = false;

  AuthSession? get session => _session;
  List<SavedServer> get savedServers => _savedServers;
  SavedServer? get prefill => _prefill;
  MediaServerException? get failure => _failure;
  LineSwitchFailure? get lineSwitchFailure => _lineSwitchFailure;
  bool get isBusy => _busy;
  bool get isLoggedIn => _session != null;

  int _authorizationPresentations = 0;
  bool get presentingAuthorization => _authorizationPresentations > 0;

  /// Keep the modal's hosting route alive while its old identity is revoked.
  /// This does not grant a session or retain any source permission.
  VoidCallback retainAuthorizationPresentation() {
    _authorizationPresentations++;
    var released = false;
    return () {
      if (released) return;
      released = true;
      _authorizationPresentations--;
      if (!_disposed) notifyListeners();
    };
  }

  /// 当前服务器的库规模;加载中为 null,界面不得把加载态显示成 0。
  LibraryCounts? get libraryCounts => _libraryCounts;

  /// 最近一次库规模拉取失败的原因;成功或开始新一次拉取时清空。
  MediaServerException? get libraryCountsFailure => _libraryCountsFailure;

  /// 库规模所属的服务器;切换服务器后随新一轮拉取更新。
  String? get libraryCountsServerId => _libraryCountsServerId;

  bool get libraryCountsLoading => _libraryCountsLoading;

  /// 拉取当前服务器的库规模,供服务器管理界面展示。
  ///
  /// 独立于登录/切换的 busy 状态:失败只记录原因,会话与登录态不变;
  /// 加载期间 [libraryCounts] 置空,避免把未知显示成 0。切换服务器使
  /// 序号失效后,旧响应直接丢弃。
  Future<void> loadLibraryCounts() async {
    final session = _session;
    if (_disposed || session == null) {
      return;
    }
    final seq = ++_libraryCountsSeq;
    _libraryCounts = null;
    _libraryCountsFailure = null;
    _libraryCountsLoading = true;
    notifyListeners();
    try {
      final counts = await client.getItemCounts();
      if (_disposed || !_countsStillCurrent(seq, session)) {
        return;
      }
      _libraryCounts = counts;
      _libraryCountsServerId = session.server.id;
    } on MediaServerException catch (error) {
      if (_disposed || !_countsStillCurrent(seq, session)) {
        return;
      }
      _libraryCountsFailure = error;
    } catch (error) {
      if (_disposed || !_countsStillCurrent(seq, session)) {
        return;
      }
      _libraryCountsFailure = MediaServerException(
        MediaServerFailureKind.unknown,
        detail: error.toString(),
        cause: error,
      );
    } finally {
      if (!_disposed && _countsStillCurrent(seq, session)) {
        _libraryCountsLoading = false;
        notifyListeners();
      }
    }
  }

  bool _countsStillCurrent(int seq, AuthSession captured) {
    if (seq != _libraryCountsSeq) {
      return false;
    }
    final current = _session;
    return current != null &&
        current.server.id == captured.server.id &&
        current.userId == captured.userId;
  }

  void _resetLibraryCounts() {
    _libraryCountsSeq++;
    _libraryCounts = null;
    _libraryCountsFailure = null;
    _libraryCountsServerId = null;
    _libraryCountsLoading = false;
  }

  Future<void> restore() async {
    final generation = ++_activationGeneration;
    final snapshot = await servers.load();
    if (!_ownsActivation(generation)) return;
    _savedServers = snapshot.servers;
    final lastId = snapshot.lastServerId;
    _rememberedServerId = lastId;
    if (lastId == null || lastId.isEmpty) {
      notifyListeners();
      return;
    }
    final last = _serverById(lastId);
    if (last == null) {
      notifyListeners();
      return;
    }
    final stored = await credentials.read(last.id);
    if (!_ownsActivation(generation)) return;
    if (stored == null || stored.accessToken.isEmpty) {
      _prefill = last;
      notifyListeners();
      return;
    }
    if (last.identityPending) {
      await switchTo(last.id);
      return;
    }
    try {
      await _activate(last, stored, generation: generation);
    } catch (error) {
      if (!_ownsActivation(generation)) return;
      _session = null;
      _prefill = last;
      _failure = error is MediaServerException
          ? error
          : const MediaServerException(MediaServerFailureKind.sessionExpired);
    }
    notifyListeners();
  }

  Future<bool> connect({
    required String address,
    required String username,
    required String password,
    String? userAgent,
    String? lineId,
    bool preserveSessionOnFailure = false,
    MediaServerType serviceType = MediaServerType.emby,
  }) async {
    if (_busy) {
      return false;
    }
    final generation = ++_activationGeneration;
    _busy = true;
    _failure = null;
    notifyListeners();
    final candidate = sources.createCandidate(serviceType);
    SourceAuthorization? authorization;
    try {
      candidate.setUserAgent(userAgent);
      final baseUrl = normalizeServerAddress(address);
      final info = await candidate.getPublicInfo(baseUrl);
      _requireActivation(generation);
      await sources.requireOrdinaryIdentity(serviceType, info.id);
      final existing = _savedServers
          .where(
            (s) =>
                s.serviceType == serviceType &&
                s.username == username &&
                (s.expectedServerId == info.id ||
                    s.lines.any(
                      (l) => normalizeServerAddress(l.address) == baseUrl,
                    )),
          )
          .firstOrNull;
      // An address already belonging to another saved identity must stay
      // anonymous, even when the user entered a different account name.
      for (final known in _savedServers.where(
        (s) =>
            s.serviceType == serviceType &&
            s.lines.any((l) => normalizeServerAddress(l.address) == baseUrl),
      )) {
        if (known.expectedServerId != null &&
            known.expectedServerId != info.id) {
          throw const MediaServerException(
            MediaServerFailureKind.incompatibleServer,
          );
        }
      }
      authorization = await sources.beginAuthorization(
        serviceType: serviceType,
        region: AccessRegion.ordinary,
        configuredServerId: existing?.id,
      );
      authorization.requireServerIdentity(info.id);
      final result = await candidate.authenticateByName(
        baseUrl: baseUrl,
        username: username,
        password: password,
        serverId: info.id,
      );
      _requireActivation(generation);
      authorization.requireValid();
      if (result.serverId != info.id) {
        throw const MediaServerException(
          MediaServerFailureKind.incompatibleServer,
        );
      }
      final server = _serverWithLine(
        existing: existing,
        serverId: authorization.id,
        verifiedServerId: info.id,
        name: info.serverName,
        username: username,
        address: baseUrl.toString(),
        userAgent: userAgent,
        lineId: lineId,
        serviceType: serviceType,
      );
      final stored = StoredCredentials(
        serviceType: serviceType,
        accessToken: result.accessToken,
        userId: result.user.id,
        username: username,
        password: password.isEmpty ? null : password,
      );
      await sources.commitAuthorization(
        authorization,
        server: server,
        value: stored,
        remember: true,
      );
      _requireActivation(generation);
      await refreshServers();
      await sources.rememberSelection(server.id);
      await _activate(
        sources.server(server.id),
        stored,
        generation: generation,
        usePrepared: true,
      );
      _prefill = null;
      connectDraft = null;
      return true;
    } catch (error) {
      if (!_ownsActivation(generation)) return false;
      _failure = connectionFailure(error);
      return false;
    } finally {
      authorization?.cancel();
      candidate.clearSession();
      _busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> logout() async {
    if (_busy) {
      return;
    }
    final generation = ++_activationGeneration;
    final selectedClient = client;
    _busy = true;
    notifyListeners();
    final currentId = _session?.server.id ?? _revokedSelectionId;
    CredentialCommit? credentialCommit;
    try {
      if (currentId != null) {
        credentialCommit = await sources.beginOrdinaryCredentials(currentId);
      }
      await selectedClient.logout();
    } on MediaServerException {
      // Local credentials are still cleared so the user can sign in again.
    } on StateError {
      // The member may have moved before logout could capture authority.
    } finally {
      if (_ownsActivation(generation)) {
        client.clearSession();
        _session = null;
        _sessionOwner = null;
        _failure = null;
        connectDraft = null;
        _resetLibraryCounts();
      }
      if (credentialCommit != null) {
        try {
          await sources.commitOrdinaryCredentials(credentialCommit, null);
        } on CredentialRevocationException catch (error) {
          if (_ownsActivation(generation)) {
            _failure = MediaServerException(
              MediaServerFailureKind.unknown,
              detail: error.toString(),
              cause: error,
            );
          }
        } on StateError {
          // Membership/account changed while remote logout was pending.
        }
      }
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> switchTo(
    String serverId, {
    String? lineId,
    void Function()? guard,
  }) => _switchTo(serverId, lineId: lineId, guard: guard);

  /// Used only immediately after registry authorization commits its proof.
  Future<void> activateCommittedSource(
    String serverId, {
    void Function()? guard,
  }) => _switchTo(serverId, guard: guard, prepared: true);

  Future<void> _switchTo(
    String serverId, {
    String? lineId,
    void Function()? guard,
    bool prepared = false,
  }) async {
    guard?.call();
    final found = _serverById(serverId);
    if (found == null) return;
    final generation = ++_activationGeneration;
    void current() {
      _requireActivation(generation);
      guard?.call();
    }

    _refreshingSelection = true;
    try {
      if (found.identityPending) {
        await sources.authenticate(serverId, lineId: lineId);
      }
      current();
      final stored = await credentials.read(serverId);
      current();
      if (stored == null || stored.accessToken.isEmpty) {
        _prefill = found;
        _failure = const MediaServerException(
          MediaServerFailureKind.sessionExpired,
        );
        return;
      }
      if (lineId != null && lineId.isNotEmpty) {
        await sources.selectLine(
          serverId,
          LineSelection.fixed(lineId),
          guard: current,
        );
      }
      current();
      final server = sources.server(serverId);
      await _activate(
        server,
        stored,
        generation: generation,
        guard: guard,
        usePrepared: prepared || lineId != null,
        remember: true,
      );
      await refreshServers();
      _lineSwitchFailure = null;
      _failure = null;
      connectDraft = null;
    } catch (error) {
      if (!_ownsActivation(generation)) return;
      _failure = connectionFailure(error);
      if (lineId != null) {
        _lineSwitchFailure = LineSwitchFailure(
          address:
              found.lines.where((l) => l.id == lineId).firstOrNull?.address ??
              '',
          detail: _failure?.kind == MediaServerFailureKind.incompatibleServer
              ? '线路返回的服务器身份与当前服务器不一致'
              : '无法连接该线路，请检查连接或重新登录',
        );
      }
    } finally {
      _refreshingSelection = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> selectSavedServer(String serverId) async {
    final server = _serverById(serverId);
    if (server == null) {
      return;
    }
    _prefill = server;
    _failure = null;
    notifyListeners();
  }

  /// Refresh the ordinary projection without restoring or selecting a session.
  Future<void> reloadSavedServers() async {
    final snapshot = await servers.load();
    _savedServers = snapshot.servers;
    _rememberedServerId = snapshot.lastServerId;
    if (!_disposed) notifyListeners();
  }

  Future<ServerImportResult> importServers(
    Iterable<ServerImportDraft> drafts, {
    AccessRegion region = AccessRegion.ordinary,
  }) async {
    final result = await sources.importServers(drafts, region: region);
    await reloadSavedServers();
    return result;
  }

  /// Every address uses the registry's anonymous identity/account preflight.
  /// A rejected address remains in the caller's draft rather than disappearing.
  Future<void> appendLines(Iterable<String> addresses) async {
    final id = _session?.server.id;
    if (id == null) return;
    for (final address in addresses) {
      await addLine(id, address);
    }
  }

  Future<void> _lineMutation(
    String id,
    Future<void> Function() mutation,
  ) async {
    final previous = _session;
    final generation = _activationGeneration;
    _refreshingSelection = true;
    try {
      await mutation();
      await refreshServers();
      final next = sources.server(id);
      if (_ownsActivation(generation) &&
          _session?.server.id == id &&
          previous?.server.id == id &&
          (previous!.server.baseUrl != next.baseUrl ||
              previous.server.normalizedUserAgent !=
                  next.normalizedUserAgent)) {
        final stored = await credentials.read(id);
        if (stored != null &&
            _ownsActivation(generation) &&
            _session?.server.id == id) {
          await _activate(
            next,
            stored,
            generation: generation,
            usePrepared: true,
          );
        }
      }
      if (_prefill?.id == id) _prefill = next;
      _lineSwitchFailure = null;
    } finally {
      _refreshingSelection = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> saveConfiguration(
    String id, {
    required String nickname,
    String? iconId,
    required String userAgent,
    required List<ServerLine> lines,
    LineSelection? lineSelection,
  }) => _lineMutation(
    id,
    () => sources.saveConfiguration(
      id,
      nickname: nickname,
      iconId: iconId,
      userAgent: userAgent,
      lines: lines,
      lineSelection: lineSelection,
    ),
  );

  Future<void> reorderServers(List<String> ids) async {
    await sources.reorderServers(ids);
    await refreshServers();
  }

  Future<void> reorderLines(String id, List<String> lineIds) async {
    await sources.reorderLines(id, lineIds);
    await refreshServers();
  }

  Future<bool> addLine(String serverId, String address) async {
    final server = _serverById(serverId);
    if (server == null) return false;
    final url = _normalizeLineAddress(address);
    if (url == null ||
        server.lines.any(
          (l) => normalizeServerAddress(l.address).toString() == url,
        )) {
      return false;
    }
    await _lineMutation(serverId, () => sources.setLineAddress(serverId, url));
    return true;
  }

  Future<bool> updateLineAddress(
    String serverId,
    String lineId,
    String address,
  ) async {
    final server = _serverById(serverId);
    final line = server?.lines.where((l) => l.id == lineId).firstOrNull;
    final url = _normalizeLineAddress(address);
    if (line == null || url == null || line.address == url) return false;
    await _lineMutation(
      serverId,
      () => sources.setLineAddress(serverId, url, lineId: lineId),
    );
    return true;
  }

  String? _normalizeLineAddress(String address) {
    try {
      return normalizeServerAddress(address).toString();
    } on MediaServerException {
      return null;
    }
  }

  Future<void> deleteLine(String serverId, String lineId) async {
    final server = _serverById(serverId);
    if (server == null ||
        server.lines.length <= 1 ||
        !server.lines.any((l) => l.id == lineId)) {
      return;
    }
    await _lineMutation(serverId, () => sources.removeLine(serverId, lineId));
  }

  Future<void> selectLine(String serverId, LineSelection selection) =>
      _lineMutation(serverId, () => sources.selectLine(serverId, selection));

  Future<void> deleteServer(String serverId) async {
    try {
      await sources.logoutSource(serverId, remove: true);
    } on CredentialRevocationException {
      _failure = const MediaServerException(MediaServerFailureKind.unknown);
      if (!_disposed) notifyListeners();
      rethrow;
    }
    await refreshServers();
    if (_prefill?.id == serverId) _prefill = null;
    if (_rememberedServerId == serverId) _rememberedServerId = null;
    if (!_disposed) notifyListeners();
  }

  Future<String?> savedPassword(String serverId) async {
    return (await credentials.read(serverId))?.password;
  }

  Future<void> renameServer(String serverId, String nickname) async {
    await sources.rename(serverId, nickname.trim());
    await refreshServers();
  }

  /// Undo a local removal without switching accounts or reviving a session.
  Future<void> restoreSavedServer(
    SavedServer server,
    StoredCredentials? stored,
  ) async {
    if (_serverById(server.id) != null) return;
    if (server.region != AccessRegion.ordinary) {
      throw StateError('Cannot restore a private member in ordinary context');
    }
    final credentialCommit = await sources.beginOrdinaryCredentials(server.id);
    if (stored != null) {
      await sources.commitOrdinaryCredentials(credentialCommit, stored);
    }
    await _upsertServer(server, remember: false);
    notifyListeners();
  }

  MediaServerException? _passwordChangeFailure;

  /// 最近一次改密被服务器拒绝的原因;开始新的改密或改密成功时清空。
  MediaServerException? get passwordChangeFailure => _passwordChangeFailure;

  /// 修改当前登录用户的密码;旧密码留空照常提交,客户端不做拦截。
  ///
  /// 成功:本机凭据换成新密码,会话保持可用。
  /// 失败:本机保留旧密码,用户仍处于登录态,原因经
  /// [passwordChangeFailure] 暴露。服务器改密后吊销当前会话时,
  /// 复用会话过期路径回到登录页,本机已存的新密码可直接重新进入。
  Future<bool> changePassword({
    String? currentPassword,
    required String newPassword,
  }) async {
    final session = _session;
    if (_busy || session == null || newPassword.isEmpty) {
      return false;
    }
    _busy = true;
    _passwordChangeFailure = null;
    notifyListeners();
    try {
      final credentialCommit = await sources.beginOrdinaryCredentials(
        session.server.id,
      );
      await client.changePassword(
        currentPassword: (currentPassword == null || currentPassword.isEmpty)
            ? null
            : currentPassword,
        newPassword: newPassword,
      );
      final stored = await credentials.read(session.server.id);
      await sources.commitOrdinaryCredentials(
        credentialCommit,
        StoredCredentials(
          accessToken: stored?.accessToken ?? session.accessToken,
          userId: stored?.userId ?? session.userId,
          username: stored?.username ?? session.username,
          password: newPassword,
          serviceType: session.server.serviceType,
          authorizationMethod: session.server.authorizationMethod,
          cloudCredentialRef: stored?.cloudCredentialRef,
          cloudAccountId: stored?.cloudAccountId,
          homeUserId: stored?.homeUserId,
          resourceCredentialRef: stored?.resourceCredentialRef,
          authMaterial: stored?.authMaterial ?? const {},
        ),
      );
      await _verifySessionAfterPasswordChange();
      return true;
    } on MediaServerException catch (error) {
      _passwordChangeFailure = error;
      return false;
    } catch (error) {
      _passwordChangeFailure = MediaServerException(
        MediaServerFailureKind.unknown,
        detail: error.toString(),
        cause: error,
      );
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// 部分服务器改密后会吊销当前 token。探测期间禁用静默重登:
  /// 会话已失效时走 [_onSessionExpired] 回到登录页;其它探测失败
  /// (如瞬时网络错误)不影响已完成的改密结果。
  Future<void> _verifySessionAfterPasswordChange() async {
    final refresh = client.onRefreshSession;
    client.onRefreshSession = null;
    try {
      await client.getUser();
    } on MediaServerException {
      // 会话过期时回调已把用户带回登录页,这里只需吞掉探测异常。
    } finally {
      client.onRefreshSession = refresh;
    }
  }

  void clearFailure() {
    if (_failure == null) {
      return;
    }
    _failure = null;
    notifyListeners();
  }

  SavedServer _serverWithLine({
    required SavedServer? existing,
    required String serverId,
    String? verifiedServerId,
    required String name,
    required String username,
    required String address,
    String? userAgent,
    String? lineId,
    MediaServerType? serviceType,
  }) {
    // The form's User-Agent belongs to the server, not to a single line.
    final normalizedUa = userAgent != null
        ? normalizeUserAgent(userAgent)
        : existing?.userAgent;
    final lines = existing == null
        ? <ServerLine>[]
        : [for (final line in existing.lines) line];
    var index = -1;
    if (lineId != null && lineId.isNotEmpty && existing != null) {
      index = lines.indexWhere((line) => line.id == lineId);
    }
    if (index < 0) {
      index = lines.indexWhere((line) => line.address == address);
    }
    late final ServerLine line;
    if (index >= 0) {
      line = lines[index].copyWith(address: address);
      lines[index] = line;
    } else {
      line = ServerLine(
        id: (lineId != null && lineId.isNotEmpty) ? lineId : generateLineId(),
        address: address,
      );
      lines.add(line);
    }
    return SavedServer(
      id: serverId,
      serviceType: existing?.serviceType ?? serviceType ?? client.serviceType,
      authorizationMethod:
          existing?.authorizationMethod ?? AuthorizationMethod.password,
      cloudCredentialRef: existing?.cloudCredentialRef,
      cloudAccountId: existing?.cloudAccountId,
      homeUserId: existing?.homeUserId,
      resourceCredentialRef: existing?.resourceCredentialRef,
      name: name,
      nickname: existing?.nickname,
      username: username,
      lines: lines,
      activeLineId: line.id,
      lineSelection: existing?.lineSelection.isAutomatic == false
          ? LineSelection.fixed(line.id)
          : const LineSelection.auto(),
      lastSuccessfulLineId: line.id,
      iconId: existing?.iconId,
      credentialRef: existing?.credentialRef,
      protectionRef: existing?.protectionRef,
      userAgent: normalizedUa,
      region: existing?.region ?? AccessRegion.ordinary,
      participates: existing?.participates ?? true,
      libraryIds: existing?.libraryIds ?? const [],
      scopeKnown: existing?.scopeKnown ?? false,
      verifiedServerId:
          verifiedServerId ?? existing?.verifiedServerId ?? serverId,
      checkedAt: existing?.checkedAt,
      checkStatus: existing?.checkStatus ?? 'unknown',
    );
  }

  Future<void> _activate(
    SavedServer server,
    StoredCredentials stored, {
    void Function()? guard,
    int? generation,
    bool usePrepared = false,
    bool remember = false,
  }) async {
    guard?.call();
    final operation = generation ?? ++_activationGeneration;
    _requireActivation(operation);
    if (stored.serviceType != server.serviceType ||
        server.homeUserId != stored.homeUserId ||
        server.cloudAccountId != stored.cloudAccountId) {
      throw StateError('Source credential identity mismatch');
    }
    // Never attach a token to an unverified endpoint or mutate the published
    // client while a candidate is awaiting anonymous identity verification.
    final prepared = usePrepared
        ? sources.verifiedClient(server.id, stored)
        : null;
    var attached = prepared ?? sources.createCandidate(server.serviceType);
    if (identical(attached, _client)) {
      throw StateError('Provider factory must return an independent client');
    }
    attached.onSessionExpired = null;
    attached.onRefreshSession = null;
    late final void Function() sourceGuard;
    MediaServerClient? guarded;
    try {
      sourceGuard = sources.selectedSessionGuard(server.id);
      void current() {
        _requireActivation(operation);
        sourceGuard();
        guard?.call();
      }

      if (prepared == null) {
        attached.setUserAgent(server.normalizedUserAgent);
        final info = await attached.getPublicInfo(Uri.parse(server.baseUrl));
        current();
        if (info.id != server.expectedServerId) {
          throw const MediaServerException(
            MediaServerFailureKind.incompatibleServer,
          );
        }
        attached.attachSession(
          baseUrl: Uri.parse(server.baseUrl),
          accessToken: stored.accessToken,
          userId: stored.userId,
          userAgent: server.normalizedUserAgent,
        );
        await sources.verifyAttachedSession(server.id, stored, attached);
        current();
      }
      if (server.serviceType != MediaServerType.emby) {
        guarded = attached.withRequestGuard(sourceGuard);
      }
      current();
      if (remember) await sources.rememberSelection(server.id, guard: current);
      current();
    } catch (_) {
      attached.clearSession();
      guarded?.clearSession();
      rethrow;
    }
    if (server.serviceType == MediaServerType.emby) {
      // Keep Emby's refresh/retry owner and injected behavior, but only attach
      // after the independent candidate and durable selection have succeeded.
      final candidate = attached;
      attached = _client.serviceType == MediaServerType.emby
          ? _client
          : sources.createCandidate(MediaServerType.emby);
      attached.attachSession(
        baseUrl: Uri.parse(server.baseUrl),
        accessToken: stored.accessToken,
        userId: stored.userId,
        userAgent: server.normalizedUserAgent,
      );
      candidate.clearSession();
    }
    final retired = _client;
    final retiredGuarded = _guardedClient;
    if (!identical(retired, attached)) {
      retired.onSessionExpired = null;
      retired.onRefreshSession = null;
      retired.clearSession();
    }
    retiredGuarded?.clearSession();
    _client = attached;
    _guardedClient = guarded;
    _selectionGuard = sourceGuard;
    _revokedSelectionId = null;
    final session = AuthSession(
      server: server,
      userId: stored.userId,
      username: stored.username,
      accessToken: stored.accessToken,
    );
    _session = session;
    final owner = Object();
    _sessionOwner = owner;
    bool ownsSession() =>
        !_disposed &&
        identical(_sessionOwner, owner) &&
        identical(_client, attached) &&
        _isSameSession(session);
    void expired() {
      if (ownsSession()) _onSessionExpired();
    }

    Future<bool> refresh() => ownsSession()
        ? _refreshSession(session, attached, ownsSession)
        : Future.value(false);
    attached.onSessionExpired = expired;
    attached.onRefreshSession = refresh;
    guarded?.onSessionExpired = expired;
    guarded?.onRefreshSession = refresh;
    unawaited(loadLibraryCounts());
  }

  SavedServer? _serverById(String id) {
    for (final server in _savedServers) {
      if (server.id == id) {
        return server;
      }
    }
    return null;
  }

  Future<void> _upsertServer(SavedServer server, {bool remember = true}) async {
    final lastId = remember
        ? server.id
        : _session?.server.id ?? _rememberedServerId;
    final exists = _savedServers.any((item) => item.id == server.id);
    final next = <SavedServer>[
      for (final item in _savedServers) item.id == server.id ? server : item,
      if (!exists) server,
    ];
    await servers.save(ServerListSnapshot(servers: next, lastServerId: lastId));
    _savedServers = next;
    _rememberedServerId = lastId;
  }

  Future<bool> _refreshSession(
    AuthSession session,
    MediaServerClient selectedClient,
    bool Function() ownsSession,
  ) async {
    final generation = _activationGeneration;
    bool current() => ownsSession() && _ownsActivation(generation);
    if (!current()) return false;
    try {
      final credentialCommit = await sources.beginOrdinaryCredentials(
        session.server.id,
      );
      final stored = await credentials.read(session.server.id);
      if (!current()) return false;
      final password = stored?.password;
      if (stored == null || password == null || password.isEmpty) {
        return false;
      }
      selectedClient.setUserAgent(session.server.normalizedUserAgent);
      final verifiedServerId = session.server.expectedServerId;
      if (verifiedServerId == null) return false;
      final info = await selectedClient.getPublicInfo(
        Uri.parse(session.server.baseUrl),
      );
      if (!current() || info.id != verifiedServerId) return false;
      final auth = await selectedClient.authenticateByName(
        baseUrl: Uri.parse(session.server.baseUrl),
        username: stored.username,
        password: password,
        serverId: verifiedServerId,
      );
      final next = StoredCredentials(
        serviceType: stored.serviceType,
        authorizationMethod: stored.authorizationMethod,
        cloudCredentialRef: stored.cloudCredentialRef,
        cloudAccountId: stored.cloudAccountId,
        homeUserId: stored.homeUserId,
        resourceCredentialRef: stored.resourceCredentialRef,
        authMaterial: stored.authMaterial,
        accessToken: auth.accessToken,
        userId: auth.user.id,
        username: stored.username,
        password: password,
      );
      if (!current()) {
        return false;
      }
      _refreshingSelection = true;
      try {
        await sources.commitOrdinaryCredentials(credentialCommit, next);
        if (!current()) return false;
        await _activate(
          session.server,
          next,
          generation: generation,
          guard: () {
            if (!current()) throw StateError('Refresh superseded');
          },
        );
      } finally {
        _refreshingSelection = false;
      }
      _failure = null;
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  bool _isSameSession(AuthSession captured) {
    final current = _session;
    return current != null &&
        current.server.id == captured.server.id &&
        current.userId == captured.userId &&
        current.accessToken == captured.accessToken;
  }

  void _onSessionExpired() {
    if (_handlingExpiry || _session == null) {
      return;
    }
    _handlingExpiry = true;
    final current = _session!;
    _session = null;
    _sessionOwner = null;
    client.clearSession();
    _prefill = current.server;
    _failure = const MediaServerException(
      MediaServerFailureKind.sessionExpired,
    );
    _resetLibraryCounts();
    notifyListeners();
    _handlingExpiry = false;
  }

  @override
  void dispose() {
    _disposed = true;
    _activationGeneration++;
    _client.clearSession();
    _guardedClient?.clearSession();
    _resetLibraryCounts();
    connectDraft = null;
    sources.removeMembershipCleanup(_clearSourceContribution);
    sources.removeSourceRevocation(_sourceChanged);
    sources.dispose();
    super.dispose();
  }
}
