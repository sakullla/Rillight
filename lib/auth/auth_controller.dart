import 'package:flutter/foundation.dart';
import 'package:rillight/auth/connect_draft.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';
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
    required this.servers,
  }) {
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
  final ServerListStore servers;

  ConnectDraft? connectDraft;

  AuthSession? _session;
  List<SavedServer> _savedServers = const [];
  SavedServer? _prefill;
  EmbyException? _failure;
  LineSwitchFailure? _lineSwitchFailure;
  bool _busy = false;
  bool _handlingExpiry = false;

  AuthSession? get session => _session;
  List<SavedServer> get savedServers => _savedServers;
  SavedServer? get prefill => _prefill;
  EmbyException? get failure => _failure;
  LineSwitchFailure? get lineSwitchFailure => _lineSwitchFailure;
  bool get isBusy => _busy;
  bool get isLoggedIn => _session != null;

  Future<void> restore() async {
    final snapshot = await servers.load();
    _savedServers = snapshot.servers;
    final lastId = snapshot.lastServerId;
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

  Future<void> connect({
    required String address,
    required String username,
    required String password,
    String? userAgent,
    String? lineId,
  }) async {
    if (_busy) {
      return;
    }
    _busy = true;
    _failure = null;
    notifyListeners();
    try {
      client.setUserAgent(userAgent);
      final baseUrl = normalizeEmbyBaseUrl(address);
      final publicInfo = await client.getPublicInfo(baseUrl);
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
      await credentials.write(server.id, stored);
      await _upsertServer(server);
      _activate(server, stored);
      _prefill = null;
      connectDraft = null;
    } on EmbyException catch (error) {
      _failure = error;
      _session = null;
      client.clearSession();
    } catch (error) {
      _failure = EmbyException(
        EmbyFailureKind.unknown,
        detail: error.toString(),
        cause: error,
      );
      _session = null;
      client.clearSession();
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> logout() async {
    if (_busy) {
      return;
    }
    _busy = true;
    notifyListeners();
    final current = _session;
    try {
      await client.logout();
    } on EmbyException {
      // Local credentials are still cleared so the user can sign in again.
    } finally {
      client.clearSession();
      _session = null;
      _failure = null;
      connectDraft = null;
      if (current != null) {
        await credentials.delete(current.server.id);
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
    await _upsertServer(next);
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
    _savedServers = next;
    // 删除的是当前服务器时不再保留 lastServerId,避免下次启动凭空预选。
    await servers.save(
      ServerListSnapshot(
        servers: next,
        lastServerId: (current != null && current != serverId) ? current : null,
      ),
    );
    await credentials.delete(serverId);
    if (_prefill?.id == serverId) {
      _prefill = null;
    }
    if (current == serverId) {
      _session = null;
      client.clearSession();
      _failure = null;
      _lineSwitchFailure = null;
      connectDraft = null;
    }
    notifyListeners();
  }

  Future<String?> savedPassword(String serverId) async {
    return (await credentials.read(serverId))?.password;
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
      line = ServerLine(id: lines[index].id, address: address);
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
      username: username,
      lines: lines,
      activeLineId: line.id,
      userAgent: normalizedUa,
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
  }

  SavedServer? _serverById(String id) {
    for (final server in _savedServers) {
      if (server.id == id) {
        return server;
      }
    }
    return null;
  }

  Future<void> _upsertServer(SavedServer server) async {
    final next = <SavedServer>[
      for (final item in _savedServers)
        if (item.id != server.id) item,
      server,
    ];
    _savedServers = next;
    await servers.save(
      ServerListSnapshot(servers: next, lastServerId: server.id),
    );
  }

  Future<bool> _refreshSession() async {
    final session = _session;
    if (session == null) {
      return false;
    }
    final stored = await credentials.read(session.server.id);
    final password = stored?.password;
    if (stored == null || password == null || password.isEmpty) {
      return false;
    }
    try {
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
      await credentials.write(session.server.id, next);
      if (!_isSameSession(session)) {
        await credentials.delete(session.server.id);
        return false;
      }
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
    notifyListeners();
    _handlingExpiry = false;
  }

  @override
  void dispose() {
    connectDraft = null;
    super.dispose();
  }
}
