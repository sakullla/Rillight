import 'package:flutter/foundation.dart';
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

class AuthController extends ChangeNotifier {
  AuthController({
    required this.client,
    required this.credentials,
    required this.servers,
  }) {
    client.onSessionExpired = _onSessionExpired;
  }

  factory AuthController.memory({EmbyClient? client}) {
    return AuthController(
      client:
          client ??
          EmbyClient(
            device: const EmbyDeviceInfo(
              clientName: '灯川 Rillight',
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

  AuthSession? _session;
  List<SavedServer> _savedServers = const [];
  SavedServer? _prefill;
  EmbyException? _failure;
  bool _busy = false;
  bool _handlingExpiry = false;

  AuthSession? get session => _session;
  List<SavedServer> get savedServers => _savedServers;
  SavedServer? get prefill => _prefill;
  EmbyException? get failure => _failure;
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
    SavedServer? last;
    for (final server in snapshot.servers) {
      if (server.id == lastId) {
        last = server;
        break;
      }
    }
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
  }) async {
    if (_busy) {
      return;
    }
    _busy = true;
    _failure = null;
    notifyListeners();
    try {
      final baseUrl = normalizeEmbyBaseUrl(address);
      final publicInfo = await client.getPublicInfo(baseUrl);
      final auth = await client.authenticateByName(
        baseUrl: baseUrl,
        username: username,
        password: password,
        serverId: publicInfo.id,
      );
      final server = SavedServer(
        id: publicInfo.id,
        name: publicInfo.serverName,
        baseUrl: baseUrl.toString(),
        username: username,
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
    } on EmbyException catch (error) {
      _failure = error;
      _session = null;
      client.clearSession();
    } catch (error) {
      _failure = EmbyException(EmbyFailureKind.unknown, cause: error);
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
      if (current != null) {
        await credentials.delete(current.server.id);
      }
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> switchTo(String serverId) async {
    SavedServer? server;
    for (final item in _savedServers) {
      if (item.id == serverId) {
        server = item;
        break;
      }
    }
    if (server == null) {
      return;
    }
    final stored = await credentials.read(serverId);
    if (stored != null && stored.accessToken.isNotEmpty) {
      _failure = null;
      await _upsertServer(server);
      _activate(server, stored);
      notifyListeners();
      return;
    }
    _session = null;
    client.clearSession();
    _prefill = server;
    _failure = null;
    notifyListeners();
  }

  Future<void> selectSavedServer(String serverId) async {
    SavedServer? server;
    for (final item in _savedServers) {
      if (item.id == serverId) {
        server = item;
        break;
      }
    }
    if (server == null) {
      return;
    }
    _prefill = server;
    _failure = null;
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
    );
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

  void _onSessionExpired() {
    if (_handlingExpiry || _session == null) {
      return;
    }
    _handlingExpiry = true;
    final serverId = _session!.server.id;
    _session = null;
    client.clearSession();
    _failure = const EmbyException(EmbyFailureKind.sessionExpired);
    notifyListeners();
    credentials.delete(serverId).whenComplete(() {
      _handlingExpiry = false;
    });
  }
}
