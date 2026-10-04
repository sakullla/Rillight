import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:rillight/auth/connect_draft.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/auth/source_sessions.dart';
import 'package:rillight/auth/region_access.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/emby/emby_url.dart';

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
    required this.client,
    required this.credentials,
    required ServerListStore servers,
    SourceSessionRegistry? sources,
    this.persistPin,
  }) {
    this.sources =
        sources ??
        SourceSessionRegistry(
          access: RegionAccessController(),
          store: servers,
          credentials: credentials,
          createClient: () => EmbyClient(device: client.device),
        );
    this.servers = this.sources.ordinaryStore;
    this.sources.addMembershipCleanup(_clearSourceContribution);
    client.onSessionExpired = _onSessionExpired;
    client.onRefreshSession = _refreshSession;
  }

  factory AuthController.memory({EmbyClient? client}) {
    return AuthController(
      client:
          client ??
          EmbyClient(
            device: const EmbyDeviceInfo(
              clientName: 'Rillight',
              deviceName: 'test',
              deviceId: 'rillight-memory-device',
              version: '0.1.0',
            ),
          ),
      credentials: MemoryCredentialStore(),
      servers: MemoryServerListStore(),
    );
  }

  final EmbyClient client;
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

  AuthSession? _session;
  List<SavedServer> _savedServers = const [];
  SavedServer? _prefill;
  String? _rememberedServerId;
  EmbyException? _failure;
  LineSwitchFailure? _lineSwitchFailure;
  bool _busy = false;
  bool _handlingExpiry = false;
  LibraryCounts? _libraryCounts;
  EmbyException? _libraryCountsFailure;
  String? _libraryCountsServerId;
  bool _libraryCountsLoading = false;
  int _libraryCountsSeq = 0;
  bool _disposed = false;

  AuthSession? get session => _session;
  List<SavedServer> get savedServers => _savedServers;
  SavedServer? get prefill => _prefill;
  EmbyException? get failure => _failure;
  LineSwitchFailure? get lineSwitchFailure => _lineSwitchFailure;
  bool get isBusy => _busy;
  bool get isLoggedIn => _session != null;

  /// 当前服务器的库规模;加载中为 null,界面不得把加载态显示成 0。
  LibraryCounts? get libraryCounts => _libraryCounts;

  /// 最近一次库规模拉取失败的原因;成功或开始新一次拉取时清空。
  EmbyException? get libraryCountsFailure => _libraryCountsFailure;

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
    } on EmbyException catch (error) {
      if (_disposed || !_countsStillCurrent(seq, session)) {
        return;
      }
      _libraryCountsFailure = error;
    } catch (error) {
      if (_disposed || !_countsStillCurrent(seq, session)) {
        return;
      }
      _libraryCountsFailure = EmbyException(
        EmbyFailureKind.unknown,
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
    final snapshot = await servers.load();
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
    if (stored == null || stored.accessToken.isEmpty) {
      _prefill = last;
      notifyListeners();
      return;
    }
    _activate(last, stored);
    notifyListeners();
  }

  Future<bool> connect({
    required String address,
    required String username,
    required String password,
    String? userAgent,
    String? lineId,
    bool preserveSessionOnFailure = false,
  }) async {
    if (_busy) {
      return false;
    }
    // 只有电视辅助确认会要求失败后留在原会话。手机和桌面的失败结果保持原样。
    final previous = preserveSessionOnFailure ? _session : null;
    _busy = true;
    _failure = null;
    notifyListeners();
    try {
      client.setUserAgent(userAgent);
      final baseUrl = normalizeEmbyBaseUrl(address);
      final publicInfo = await client.getPublicInfo(baseUrl);
      // Ordinary legacy login cannot replace credentials of a private member.
      final credentialCommit = await sources.beginOrdinaryCredentials(
        publicInfo.id,
      );
      final auth = await client.authenticateByName(
        baseUrl: baseUrl,
        username: username,
        password: password,
        serverId: publicInfo.id,
      );
      final server = _serverWithLine(
        existing: _serverById(publicInfo.id),
        serverId: publicInfo.id,
        name: publicInfo.serverName,
        username: username,
        address: baseUrl.toString(),
        userAgent: userAgent,
        lineId: lineId,
      );
      final stored = StoredCredentials(
        accessToken: auth.accessToken,
        userId: auth.user.id,
        username: username,
        password: password.isEmpty ? null : password,
      );
      await sources.commitOrdinaryCredentials(credentialCommit, stored);
      await _upsertServer(server);
      await sources.requireOrdinaryServer(server.id);
      _activate(server, stored);
      _prefill = null;
      connectDraft = null;
      return true;
    } on EmbyException catch (error) {
      _failure = error;
      await _dropOrRestore(previous);
      return false;
    } catch (error) {
      _failure = EmbyException(
        EmbyFailureKind.unknown,
        detail: error.toString(),
        cause: error,
      );
      await _dropOrRestore(previous);
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// 登录失败时清掉尝试。若调用方留下了原会话，则重新挂上原来的令牌。
  Future<void> _dropOrRestore(AuthSession? previous) async {
    if (previous != null) {
      if (!_isSameSession(previous)) {
        previous = null;
      } else {
        try {
          await sources.requireOrdinaryServer(previous.server.id);
        } on StateError {
          previous = null;
        }
      }
    }
    if (previous == null) {
      _session = null;
      client.clearSession();
      _resetLibraryCounts();
      return;
    }
    _session = previous;
    client.attachSession(
      baseUrl: Uri.parse(previous.server.baseUrl),
      accessToken: previous.accessToken,
      userId: previous.userId,
      userAgent: previous.server.normalizedUserAgent,
    );
  }

  Future<void> logout() async {
    if (_busy) {
      return;
    }
    _busy = true;
    notifyListeners();
    final current = _session;
    CredentialCommit? credentialCommit;
    try {
      if (current != null) {
        credentialCommit = await sources.beginOrdinaryCredentials(
          current.server.id,
        );
      }
      await client.logout();
    } on EmbyException {
      // Local credentials are still cleared so the user can sign in again.
    } on StateError {
      // The member may have moved before logout could capture authority.
    } finally {
      client.clearSession();
      _session = null;
      _failure = null;
      connectDraft = null;
      _resetLibraryCounts();
      if (credentialCommit != null) {
        try {
          await sources.commitOrdinaryCredentials(credentialCommit, null);
        } on StateError {
          // Membership/account changed while remote logout was pending.
        }
      }
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> switchTo(String serverId, {String? lineId}) async {
    final found = _serverById(serverId);
    if (found == null) {
      return;
    }
    final currentLineId = found.activeLine?.id;
    final requestedLineId = (lineId == null || lineId.isEmpty)
        ? currentLineId
        : lineId;
    if (requestedLineId != null && requestedLineId != found.activeLineId) {
      var hasLine = false;
      for (final line in found.lines) {
        if (line.id == requestedLineId) {
          hasLine = true;
          break;
        }
      }
      if (!hasLine) {
        return;
      }
    }
    final server =
        (requestedLineId != null && requestedLineId != found.activeLineId)
        ? found.copyWith(activeLineId: requestedLineId)
        : found;
    final stored = await credentials.read(serverId);
    final sameServer = _session?.server.id == serverId;
    final changingLine = sameServer && requestedLineId != currentLineId;
    if (stored != null && stored.accessToken.isNotEmpty) {
      if (changingLine) {
        // User-Agent is server-level: switching lines keeps the server's UA.
        // The current line and session stay active unless the target line is
        // reachable and proves it belongs to the same server.
        _lineSwitchFailure = null;
        String detail;
        try {
          final info = await client.getPublicInfo(Uri.parse(server.baseUrl));
          if (info.id != server.id) {
            detail = '线路返回的服务器身份与当前服务器不一致';
          } else {
            detail = '';
          }
        } on EmbyException catch (error) {
          detail = error.detail ?? error.toString();
        } catch (error) {
          detail = error.toString();
        }
        if (detail.isNotEmpty) {
          _lineSwitchFailure = LineSwitchFailure(
            address: server.baseUrl,
            detail: detail,
          );
          notifyListeners();
          return;
        }
      }
      _lineSwitchFailure = null;
      _failure = null;
      await _upsertServer(server);
      _activate(server, stored);
      connectDraft = null;
      notifyListeners();
      return;
    }
    _session = null;
    client.clearSession();
    _prefill = server;
    _failure = null;
    _lineSwitchFailure = null;
    _resetLibraryCounts();
    notifyListeners();
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

  /// 给当前已登录服务器追加备用线路,不切换正在使用的地址。
  Future<void> appendLines(Iterable<String> addresses) async {
    final current = _session?.server;
    if (current == null) {
      return;
    }
    var server = current;
    var changed = false;
    for (final raw in addresses) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty) {
        continue;
      }
      try {
        final url = normalizeEmbyBaseUrl(trimmed).toString();
        if (server.lines.any((line) => line.address == url)) {
          continue;
        }
        server = _serverWithLine(
          existing: server,
          serverId: server.id,
          name: server.name,
          username: server.username,
          address: url,
        ).copyWith(activeLineId: current.activeLineId);
        changed = true;
      } on EmbyException {
        continue;
      }
    }
    if (!changed) {
      return;
    }
    await _upsertServer(server);
    final session = _session;
    if (session != null && session.server.id == server.id) {
      _session = AuthSession(
        server: server,
        userId: session.userId,
        username: session.username,
        accessToken: session.accessToken,
      );
    }
    notifyListeners();
  }

  /// 给已保存服务器添加一条线路:只录入地址,不改变当前线路、用户名与
  /// 服务器 User-Agent,浏览与播放继续走原地址。返回是否实际写入。
  Future<bool> addLine(String serverId, String address) async {
    final server = _serverById(serverId);
    if (server == null) {
      return false;
    }
    final url = _normalizeLineAddress(address);
    if (url == null || server.lines.any((line) => line.address == url)) {
      return false;
    }
    final next = server.copyWith(
      lines: [
        ...server.lines,
        ServerLine(id: generateLineId(), address: url),
      ],
    );
    await _persistLineEdit(next, remountSession: false);
    return true;
  }

  /// 修改一条线路的地址:线路 id、当前线路选择、用户名与服务器
  /// User-Agent 都不变;改的是当前会话的活跃线路时,客户端改挂新地址,
  /// 之后浏览与播放走新地址。返回是否实际写入。
  Future<bool> updateLineAddress(
    String serverId,
    String lineId,
    String address,
  ) async {
    final server = _serverById(serverId);
    if (server == null) {
      return false;
    }
    final url = _normalizeLineAddress(address);
    if (url == null) {
      return false;
    }
    final lines = <ServerLine>[...server.lines];
    var found = false;
    var active = false;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].id != lineId) {
        continue;
      }
      if (lines[i].address == url) {
        return false;
      }
      lines[i] = lines[i].copyWith(address: url);
      found = true;
      active = server.activeLineId == lineId;
      break;
    }
    if (!found) {
      return false;
    }
    final next = server.copyWith(lines: lines);
    await _persistLineEdit(
      next,
      remountSession: active && _session?.server.id == serverId,
    );
    return true;
  }

  /// 管理界面录入的线路地址:空白或非法地址返回 null,不写入。
  String? _normalizeLineAddress(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    try {
      return normalizeEmbyBaseUrl(trimmed).toString();
    } on EmbyException {
      return null;
    }
  }

  /// 线路增删改后的共同落盘路径:走与登录一致的 server_list_store 保存,
  /// 并同步 prefill 与当前会话引用;[remountSession] 为真时按已存凭据把
  /// 客户端挂到(可能已变化的)新地址,用户名与服务器 UA 保持不变。
  Future<void> _persistLineEdit(
    SavedServer next, {
    required bool remountSession,
  }) async {
    await _upsertServer(next, remember: false);
    if (_prefill?.id == next.id) {
      _prefill = next;
    }
    final session = _session;
    if (session != null && session.server.id == next.id) {
      if (remountSession) {
        final stored = await credentials.read(next.id);
        if (stored != null && stored.accessToken.isNotEmpty) {
          _activate(next, stored);
          notifyListeners();
          return;
        }
      }
      _session = AuthSession(
        server: next,
        userId: session.userId,
        username: session.username,
        accessToken: session.accessToken,
      );
    }
    notifyListeners();
  }

  Future<void> deleteLine(String serverId, String lineId) async {
    final server = _serverById(serverId);
    if (server == null || server.lines.length <= 1) {
      return;
    }
    final nextLines = [
      for (final line in server.lines)
        if (line.id != lineId) line,
    ];
    if (nextLines.length == server.lines.length) {
      return;
    }
    final activeChanged = server.activeLineId == lineId;
    final nextActive = activeChanged ? nextLines.first.id : server.activeLineId;
    final next = server.copyWith(lines: nextLines, activeLineId: nextActive);
    await _upsertServer(next, remember: false);
    if (_prefill?.id == serverId) {
      _prefill = next;
    }
    final session = _session;
    if (session != null && session.server.id == serverId) {
      if (activeChanged) {
        final stored = await credentials.read(serverId);
        if (stored != null && stored.accessToken.isNotEmpty) {
          _activate(next, stored);
        } else {
          _session = AuthSession(
            server: next,
            userId: session.userId,
            username: session.username,
            accessToken: session.accessToken,
          );
        }
      } else {
        _session = AuthSession(
          server: next,
          userId: session.userId,
          username: session.username,
          accessToken: session.accessToken,
        );
      }
    }
    notifyListeners();
  }

  /// 删除已保存的服务器与本机凭据。删除当前登录的服务器时结束本地会话,
  /// 路由会随之回到登录页;删除其它服务器不影响当前会话与播放。
  /// 服务器端账号不会被删除,之后可重新登录。
  Future<void> deleteServer(String serverId) async {
    final target = _serverById(serverId);
    if (target == null) {
      return;
    }
    final current = _session?.server.id;
    final next = <SavedServer>[
      for (final item in _savedServers)
        if (item.id != serverId) item,
    ];
    final credentialCommit = await sources.beginOrdinaryCredentials(serverId);
    await sources.commitOrdinaryCredentials(credentialCommit, null);
    _savedServers = next;
    // 删除的是当前服务器时不再保留 lastServerId,避免下次启动凭空预选。
    final lastId = (current != null && current != serverId) ? current : null;
    await servers.save(ServerListSnapshot(servers: next, lastServerId: lastId));
    _rememberedServerId = lastId;
    if (_prefill?.id == serverId) {
      _prefill = null;
    }
    if (current == serverId) {
      _session = null;
      client.clearSession();
      _failure = null;
      _lineSwitchFailure = null;
      connectDraft = null;
      _resetLibraryCounts();
    }
    notifyListeners();
  }

  Future<String?> savedPassword(String serverId) async {
    return (await credentials.read(serverId))?.password;
  }

  Future<void> renameServer(String serverId, String nickname) async {
    final server = _serverById(serverId);
    if (server == null) return;
    await _persistLineEdit(
      server.copyWith(nickname: nickname.trim()),
      remountSession: false,
    );
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

  EmbyException? _passwordChangeFailure;

  /// 最近一次改密被服务器拒绝的原因;开始新的改密或改密成功时清空。
  EmbyException? get passwordChangeFailure => _passwordChangeFailure;

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
        ),
      );
      await _verifySessionAfterPasswordChange();
      return true;
    } on EmbyException catch (error) {
      _passwordChangeFailure = error;
      return false;
    } catch (error) {
      _passwordChangeFailure = EmbyException(
        EmbyFailureKind.unknown,
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
    } on EmbyException {
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
    required String name,
    required String username,
    required String address,
    String? userAgent,
    String? lineId,
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
      name: name,
      nickname: existing?.nickname,
      username: username,
      lines: lines,
      activeLineId: line.id,
      userAgent: normalizedUa,
      region: existing?.region ?? AccessRegion.ordinary,
      participates: existing?.participates ?? true,
      libraryIds: existing?.libraryIds ?? const [],
      scopeKnown: existing?.scopeKnown ?? false,
      verifiedServerId: existing?.verifiedServerId ?? serverId,
      checkedAt: existing?.checkedAt,
      checkStatus: existing?.checkStatus ?? 'unknown',
    );
  }

  void _activate(SavedServer server, StoredCredentials stored) {
    _session = AuthSession(
      server: server,
      userId: stored.userId,
      username: stored.username,
      accessToken: stored.accessToken,
    );
    client.attachSession(
      baseUrl: Uri.parse(server.baseUrl),
      accessToken: stored.accessToken,
      userId: stored.userId,
      userAgent: server.normalizedUserAgent,
    );
    // 会话指向(或换到)一台服务器后刷新库规模;后台进行,不阻塞登录/切换。
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
    _savedServers = next;
    await servers.save(ServerListSnapshot(servers: next, lastServerId: lastId));
    _rememberedServerId = lastId;
  }

  Future<bool> _refreshSession() async {
    final session = _session;
    if (session == null) {
      return false;
    }
    try {
      final credentialCommit = await sources.beginOrdinaryCredentials(
        session.server.id,
      );
      final stored = await credentials.read(session.server.id);
      final password = stored?.password;
      if (stored == null || password == null || password.isEmpty) {
        return false;
      }
      client.setUserAgent(session.server.normalizedUserAgent);
      final auth = await client.authenticateByName(
        baseUrl: Uri.parse(session.server.baseUrl),
        username: stored.username,
        password: password,
        serverId: session.server.id,
      );
      final next = StoredCredentials(
        accessToken: auth.accessToken,
        userId: auth.user.id,
        username: stored.username,
        password: password,
      );
      if (!_isSameSession(session)) {
        return false;
      }
      await sources.commitOrdinaryCredentials(credentialCommit, next);
      if (!_isSameSession(session)) return false;
      _activate(session.server, next);
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
    client.clearSession();
    _prefill = current.server;
    _failure = const EmbyException(EmbyFailureKind.sessionExpired);
    _resetLibraryCounts();
    notifyListeners();
    _handlingExpiry = false;
  }

  @override
  void dispose() {
    _disposed = true;
    _resetLibraryCounts();
    connectDraft = null;
    sources.removeMembershipCleanup(_clearSourceContribution);
    sources.dispose();
    super.dispose();
  }
}
