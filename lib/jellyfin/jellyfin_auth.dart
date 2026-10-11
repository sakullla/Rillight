part of 'jellyfin_client.dart';

extension _JellyfinLogin on JellyfinClient {
  AuthenticationResult _loginResult(dynamic data, String expectedServer) {
    final result = decodeJellyfinAuthenticationResult(
      _map(data),
      fallbackServerId: expectedServer,
    );
    if (result.serverId != expectedServer) {
      throw const MediaServerException(
        MediaServerFailureKind.incompatibleServer,
      );
    }
    return result;
  }
}

class _QuickConnectAttempt implements AuthorizationAttempt {
  _QuickConnectAttempt(
    this.client,
    this.server,
    this.serverId,
    this.secret,
    this.code,
    this.expiresAt,
  ) : generation = client._generation;
  final JellyfinClient client;
  final Uri server;
  final String serverId, secret;
  final int generation;
  @override
  final String code;
  @override
  final DateTime expiresAt;
  @override
  Uri? get verificationUri => null;
  @override
  Duration get pollInterval => const Duration(seconds: 5);
  AuthorizationStatus _status = AuthorizationStatus.pending;
  SessionAuthorizationGrant? _grant;
  Future<AuthorizationGrant>? _exchange;
  void _check() {
    client._check(generation);
    if (_status == AuthorizationStatus.cancelled) {
      throw const MediaServerException(MediaServerFailureKind.cancelled);
    }
    if (!client._clock().isBefore(expiresAt)) {
      _status = AuthorizationStatus.expired;
      throw const MediaServerException(
        MediaServerFailureKind.authorizationExpired,
      );
    }
  }

  @override
  Future<AuthorizationStatus> poll() async {
    if (_status == AuthorizationStatus.cancelled ||
        _status == AuthorizationStatus.expired ||
        _status == AuthorizationStatus.denied) {
      return _status;
    }
    try {
      _check();
      final raw = client._map(
        await client._request(
          'QuickConnect/Connect',
          server: server,
          authenticated: false,
          query: {'secret': secret},
        ),
      );
      _check();
      if (raw['Authenticated'] == true) {
        _status = AuthorizationStatus.authorized;
      }
      return _status;
    } on MediaServerException catch (e) {
      if (e.kind == MediaServerFailureKind.authorizationExpired ||
          e.statusCode == 404) {
        return _status = AuthorizationStatus.expired;
      }
      if (e.kind == MediaServerFailureKind.forbidden) {
        return _status = AuthorizationStatus.denied;
      }
      rethrow;
    }
  }

  @override
  Future<AuthorizationGrant> exchange() {
    _check();
    if (_grant != null) return Future.value(_grant);
    return _exchange ??= _performExchange().whenComplete(
      () => _exchange = null,
    );
  }

  Future<AuthorizationGrant> _performExchange() async {
    if (_status != AuthorizationStatus.authorized) {
      throw const MediaServerException(MediaServerFailureKind.forbidden);
    }
    final result = client._loginResult(
      await client._request(
        'Users/AuthenticateWithQuickConnect',
        method: 'POST',
        body: {'Secret': secret},
        server: server,
        authenticated: false,
      ),
      serverId,
    );
    _check();
    return _grant = SessionAuthorizationGrant(result);
  }

  @override
  Future<void> cancel() async {
    _status = AuthorizationStatus.cancelled;
    _grant = null;
  }
}
