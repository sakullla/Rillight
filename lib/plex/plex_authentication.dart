import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart';
import 'package:rillight/media_server/authentication.dart';
import 'package:rillight/media_server/capabilities.dart';
import 'package:rillight/media_server/device.dart';
import 'package:rillight/media_server/errors.dart';
import 'package:rillight/media_server/models.dart';
import 'plex_http.dart';

typedef PlexCredentialReader =
    Future<Map<String, dynamic>?> Function(String ref);
typedef PlexCredentialWriter =
    Future<void> Function(String ref, Map<String, dynamic> value);
typedef PlexCredentialDeleter = Future<void> Function(String ref);

/// Only live verification below can construct this proof. PMS '/' identifies
/// the machine, not the effective account; a caller-supplied userId is no proof.
class PlexVerifiedResourceIdentity {
  const PlexVerifiedResourceIdentity._(
    this.user,
    this.serverId,
    this.cloudAccountId,
    this.homeUserId,
    this.connection,
    this._token,
  );
  final MediaUser user;
  final String serverId, cloudAccountId;
  final String? homeUserId;
  final Uri connection;
  final String _token;
  bool matches(Uri? url, String? token, String? userId) =>
      url != null &&
      _sameConnection(url, connection) &&
      token == _token &&
      userId == user.id;
}

bool _sameConnection(Uri a, Uri b) =>
    a.scheme == b.scheme &&
    a.host == b.host &&
    a.port == b.port &&
    a.path.replaceFirst(RegExp(r'/+$'), '') ==
        b.path.replaceFirst(RegExp(r'/+$'), '') &&
    a.query == b.query &&
    a.userInfo.isEmpty &&
    b.userInfo.isEmpty;

/// Controller-owned authentication. Storage is injected by the source authority;
/// neither this object nor a server client is a global logged-in account.
class PlexAuthentication
    implements InteractiveAuthentication, AccountResourceAuthentication {
  PlexAuthentication({
    required this.device,
    required this.readCredential,
    required this.writeCredential,
    required this.deleteCredential,
    Dio? dio,
    Uri? accountUrl,
    Uri? homeUrl,
    this.guard,
    DateTime Function()? now,
    this.strongPin = true,
  }) : dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 10),
               receiveTimeout: const Duration(seconds: 30),
               sendTimeout: const Duration(seconds: 30),
             ),
           ),
       accountUrl = accountUrl ?? Uri.parse('https://clients.plex.tv'),
       homeUrl = homeUrl ?? Uri.parse('https://plex.tv'),
       now = now ?? DateTime.now;
  final ClientDeviceInfo device;
  final PlexCredentialReader readCredential;
  final PlexCredentialWriter writeCredential;
  final PlexCredentialDeleter deleteCredential;
  final Dio dio;
  final Uri accountUrl, homeUrl;
  final void Function()? guard;
  final DateTime Function() now;
  final bool strongPin;
  final Map<String, Future<void>> _refreshes = {};
  final Map<String, int> _generations = {};
  Map<String, String> get headers => {
    'X-Plex-Client-Identifier': device.deviceId,
    'X-Plex-Product': device.clientName,
    'X-Plex-Version': device.version,
  };
  String get _deviceRef => 'plex:device:${device.deviceId}';
  void _check() => guard?.call();
  Future<dynamic> _request(
    String path, {
    String? token,
    String method = 'GET',
    Object? data,
    Map<String, Object?> query = const {},
    bool home = false,
  }) async {
    _check();
    final response = await plexRequest(
      dio,
      plexEndpoint(home ? homeUrl : accountUrl, path, query),
      method: method,
      data: data,
      headers: {...headers, 'X-Plex-Token': ?token},
    );
    _check();
    if ((response.statusCode ?? 0) >= 300) {
      throw const MediaServerException(MediaServerFailureKind.invalidResponse);
    }
    return response.data;
  }

  Future<Map<String, dynamic>> _read(String ref) async {
    _check();
    final value = await readCredential(ref);
    _check();
    if (value == null) {
      throw const MediaServerException(MediaServerFailureKind.sessionExpired);
    }
    return value;
  }

  Future<Map<String, dynamic>> _key() async {
    _check();
    final existing = await readCredential(_deviceRef);
    _check();
    if (existing != null) return existing;
    final pair = await Ed25519().newKeyPair();
    final seed = await pair.extractPrivateKeyBytes();
    final public = await pair.extractPublicKey();
    final value = <String, dynamic>{
      'kind': 'device',
      'deviceId': device.deviceId,
      'signingKey': jsonEncode({
        'seed': _b64(seed),
        'x': _b64(public.bytes),
        'kid': _b64(public.bytes),
      }),
    };
    _check();
    await writeCredential(_deviceRef, value);
    _check();
    return value;
  }

  Future<String> _sign(Map<String, dynamic> key, {String? nonce}) async {
    final material = plexMap(jsonDecode(key['signingKey'] as String));
    final pair = await Ed25519().newKeyPairFromSeed(
      base64Url.decode(base64Url.normalize(material['seed'] as String)),
    );
    final stamp = now().toUtc().millisecondsSinceEpoch ~/ 1000;
    final head = _b64(
      utf8.encode(
        jsonEncode({'kid': material['kid'], 'alg': 'EdDSA', 'typ': 'JWT'}),
      ),
    );
    final body = _b64(
      utf8.encode(
        jsonEncode({
          'aud': 'plex.tv',
          'iss': device.deviceId,
          'iat': stamp,
          'exp': stamp + 300,
          'scope': 'username,friendly_name,restricted',
          'nonce': ?nonce,
        }),
      ),
    );
    final signature = await Ed25519().sign(
      utf8.encode('$head.$body'),
      keyPair: pair,
    );
    return '$head.$body.${_b64(signature.bytes)}';
  }

  @override
  Future<CapabilityStatus> availability(
    AuthorizationMethod method, {
    Uri? server,
  }) async => CapabilityStatus(
    method == AuthorizationMethod.browserPin
        ? CapabilityAvailability.available
        : CapabilityAvailability.unsupported,
    reason: method == AuthorizationMethod.browserPin
        ? 'Plex 官方浏览器/PIN 授权'
        : 'Plex 账号通过官方授权入口登录',
  );
  @override
  Future<AuthorizationAttempt> begin(
    AuthorizationMethod method, {
    Uri? server,
  }) async {
    if (method != AuthorizationMethod.browserPin) {
      throw const MediaServerException(MediaServerFailureKind.unsupported);
    }
    final key = await _key();
    final material = plexMap(jsonDecode(key['signingKey'] as String));
    final pin = plexMap(
      await _request(
        '/api/v2/pins',
        method: 'POST',
        data: {
          'strong': strongPin,
          'jwk': {
            'kty': 'OKP',
            'crv': 'Ed25519',
            'alg': 'EdDSA',
            'x': material['x'],
            'kid': material['kid'],
          },
        },
      ),
    );
    final expiry =
        DateTime.tryParse(plexString(pin['expiresAt'])) ??
        now().add(Duration(seconds: plexInt(pin['expiresIn']) ?? 300));
    if (plexString(pin['id']).isEmpty || plexString(pin['code']).isEmpty) {
      throw const MediaServerException(MediaServerFailureKind.invalidResponse);
    }
    return _PlexPin(
      this,
      key,
      plexString(pin['id']),
      plexString(pin['code']),
      expiry,
    );
  }

  Future<CloudAccount> _accept(
    String token,
    Map<String, dynamic> key,
    void Function() check,
  ) async {
    // PIN-with-JWK must yield JWT; never silently accept the legacy flow.
    if (token.split('.').length != 3) {
      throw const MediaServerException(MediaServerFailureKind.invalidResponse);
    }
    final user = plexMap(await _request('/api/v2/user', token: token));
    check();
    final id = plexString(user['id']);
    if (id.isEmpty) {
      throw const MediaServerException(MediaServerFailureKind.invalidResponse);
    }
    final ref =
        'plex:cloud:${device.deviceId}:$id:${now().microsecondsSinceEpoch}';
    final account = CloudAccount(
      id: id,
      name: plexString(user['title'] ?? user['username']),
      credentialRef: ref,
    );
    check();
    await writeCredential(ref, {
      ...key,
      'kind': 'cloud',
      'accountId': id,
      'name': account.name,
      'accessToken': token,
      'expiresAt': _tokenExpiry(token),
    });
    try {
      check();
    } catch (_) {
      await deleteCredential(ref);
      rethrow;
    }
    return account;
  }

  @override
  Future<CloudAccount> restoreAccount(String credentialRef) async {
    var value = await _read(credentialRef);
    final account = CloudAccount(
      id: plexString(value['accountId']),
      name: plexString(value['name']),
      credentialRef: credentialRef,
    );
    try {
      await _request('/api/v2/user', token: value['accessToken'] as String);
    } on MediaServerException catch (error) {
      if (error.kind != MediaServerFailureKind.authorizationExpired) rethrow;
      await refreshAccount(account);
      value = await _read(credentialRef);
    }
    final user = plexMap(
      await _request('/api/v2/user', token: value['accessToken'] as String),
    );
    if (plexString(user['id']) != account.id) {
      throw const MediaServerException(MediaServerFailureKind.forbidden);
    }
    return account;
  }

  @override
  Future<void> refreshAccount(CloudAccount account) =>
      _refreshes[account.credentialRef] ??= _refresh(account).whenComplete(() {
        _refreshes.remove(account.credentialRef);
      });
  Future<void> _refresh(CloudAccount account) async {
    final generation = _generations[account.credentialRef] ?? 0;
    final old = await _read(account.credentialRef);
    final nonce =
        plexMap(await _request('/api/v2/auth/nonce'))['nonce'] as String;
    final token =
        plexMap(
              await _request(
                '/api/v2/auth/token',
                method: 'POST',
                data: {'jwt': await _sign(old, nonce: nonce)},
              ),
            )['auth_token']
            as String;
    if (token.split('.').length != 3) {
      throw const MediaServerException(MediaServerFailureKind.invalidResponse);
    }
    final user = plexMap(await _request('/api/v2/user', token: token));
    if (plexString(user['id']) != account.id ||
        generation != (_generations[account.credentialRef] ?? 0)) {
      throw const MediaServerException(MediaServerFailureKind.cancelled);
    }
    _check();
    await writeCredential(account.credentialRef, {
      ...old,
      'accessToken': token,
      'expiresAt': _tokenExpiry(token),
    });
    _check();
    if (generation != (_generations[account.credentialRef] ?? 0)) {
      await deleteCredential(account.credentialRef);
      throw const MediaServerException(MediaServerFailureKind.cancelled);
    }
  }

  @override
  Future<List<AuthorizedServerResource>> discoverResources(
    CloudAccount account,
  ) async {
    return _withAccount(
      account,
      (token) => _resources(
        account,
        token,
        MediaUser(id: account.id, name: account.name),
      ),
    );
  }

  Future<T> _withAccount<T>(
    CloudAccount account,
    Future<T> Function(String token) action,
  ) async {
    var stored = await _read(account.credentialRef);
    if (stored['kind'] != 'cloud' ||
        plexString(stored['accountId']) != account.id) {
      throw const MediaServerException(MediaServerFailureKind.forbidden);
    }
    final expiry = DateTime.tryParse(plexString(stored['expiresAt']));
    if (expiry != null &&
        !now().isBefore(expiry.subtract(const Duration(minutes: 1)))) {
      await refreshAccount(account);
      stored = await _read(account.credentialRef);
    }
    try {
      return await action(stored['accessToken'] as String);
    } on MediaServerException catch (error) {
      if (error.kind != MediaServerFailureKind.authorizationExpired) rethrow;
      await refreshAccount(account);
      stored = await _read(account.credentialRef);
      return action(stored['accessToken'] as String);
    }
  }

  Future<List<AuthorizedServerResource>> _resources(
    CloudAccount account,
    String token,
    MediaUser user, {
    String? homeUserId,
    String? homeCredentialRef,
  }) async {
    final rows = plexList(
      await _request(
        '/api/v2/resources',
        token: token,
        query: {'includeHttps': 1, 'includeRelay': 1, 'includeIPv6': 1},
      ),
    );
    final result = <AuthorizedServerResource>[];
    for (final row in rows) {
      if (!plexString(row['provides']).split(',').contains('server')) continue;
      final id = plexString(row['clientIdentifier']);
      final resourceToken = plexString(row['accessToken']);
      if (id.isEmpty || resourceToken.isEmpty) continue;
      final connections = <ServerConnection>[];
      for (final connection in plexList(row['connections'])) {
        final uri = Uri.tryParse(plexString(connection['uri']));
        if (uri == null ||
            !['http', 'https'].contains(uri.scheme) ||
            uri.userInfo.isNotEmpty) {
          continue;
        }
        final relay = connection['relay'] == true || connection['relay'] == 1;
        final local = connection['local'] == true || connection['local'] == 1;
        connections.add(
          ServerConnection(
            uri,
            relay
                ? ServerConnectionKind.relay
                : local
                ? ServerConnectionKind.local
                : ServerConnectionKind.remote,
            limitedBandwidth: relay,
          ),
        );
      }
      connections.sort(
        (a, b) => (a.kind.index * 2 + (a.uri.scheme == 'https' ? 0 : 1))
            .compareTo(b.kind.index * 2 + (b.uri.scheme == 'https' ? 0 : 1)),
      );
      final ref = '${account.credentialRef}:user:${user.id}:server:$id';
      _check();
      await writeCredential(ref, {
        'kind': 'resource',
        'cloudCredentialRef': account.credentialRef,
        'accountId': account.id,
        'homeUserId': homeUserId,
        'homeCredentialRef': homeCredentialRef,
        'serverId': id,
        'userId': user.id,
        'accessToken': resourceToken,
      });
      _check();
      result.add(
        AuthorizedServerResource(
          serviceType: MediaServerType.plex,
          server: PublicServerInfo(
            id: id,
            serverName: plexString(row['name']),
            version: row['productVersion'] as String?,
          ),
          user: user,
          resourceCredentialRef: ref,
          connections: connections,
          cloudAccountId: account.id,
          homeUserId: homeUserId,
        ),
      );
    }
    return result;
  }

  @override
  Future<List<HomeUser>> homeUsers(CloudAccount account) async {
    final body = plexMap(
      await _withAccount(
        account,
        (token) => _request('/api/home/users', home: true, token: token),
      ),
    );
    final root = body['MediaContainer'] is Map
        ? plexMap(body['MediaContainer'])
        : body;
    return plexList(root['User'] ?? root['users'])
        .map(
          (u) => HomeUser(
            id: plexString(u['id']),
            name: plexString(u['title'] ?? u['username']),
            requiresPin: u['protected'] == true || u['protected'] == 1,
          ),
        )
        .toList();
  }

  @override
  Future<List<AuthorizedServerResource>> switchHomeUser(
    CloudAccount account,
    HomeUser user, {
    String? pin,
  }) async {
    if (user.requiresPin && (pin == null || pin.isEmpty)) {
      throw const MediaServerException(
        MediaServerFailureKind.invalidCredentials,
      );
    }
    final body = plexMap(
      await _withAccount(
        account,
        (token) => _request(
          '/api/home/users/${Uri.encodeComponent(user.id)}/switch',
          home: true,
          method: 'POST',
          token: token,
          query: {'pin': ?pin},
        ),
      ),
    );
    final switched = body['user'] is Map ? plexMap(body['user']) : body;
    if (plexString(switched['id']) != user.id) {
      throw const MediaServerException(MediaServerFailureKind.forbidden);
    }
    final token = plexString(
      switched['authenticationToken'] ?? switched['authToken'],
    );
    if (token.isEmpty) {
      throw const MediaServerException(MediaServerFailureKind.invalidResponse);
    }
    // The account endpoint can identify the Home-scoped token; PMS cannot.
    final verifiedUser = plexMap(await _request('/api/v2/user', token: token));
    if (plexString(verifiedUser['id']) != user.id) {
      throw const MediaServerException(MediaServerFailureKind.forbidden);
    }
    final homeRef = '${account.credentialRef}:home:${user.id}';
    _check();
    await writeCredential(homeRef, {
      'kind': 'home',
      'cloudCredentialRef': account.credentialRef,
      'accountId': account.id,
      'userId': user.id,
      'accessToken': token,
    });
    _check();
    // Home's explicit returned token is a scoped exchange, never a retry of the
    // legacy PIN flow. Always rediscover resources under the selected identity.
    return _resources(
      account,
      token,
      MediaUser(id: user.id, name: user.name),
      homeUserId: user.id,
      homeCredentialRef: homeRef,
    );
  }

  /// Used by SourceSessionRegistry.sessionIdentityVerifier on both commit and
  /// restore. The resource record is an index, never accepted as identity proof:
  /// account /user and /resources are fetched live and all claims are compared.
  Future<PlexVerifiedResourceIdentity> verifyResourceIdentity({
    required String cloudCredentialRef,
    required String resourceCredentialRef,
    required String cloudAccountId,
    required String serverId,
    required String userId,
    required String resourceToken,
    required Uri connection,
    String? homeUserId,
  }) async {
    final account = await restoreAccount(cloudCredentialRef);
    if (account.id != cloudAccountId ||
        (homeUserId != null ? homeUserId != userId : userId != account.id)) {
      throw const MediaServerException(MediaServerFailureKind.forbidden);
    }
    final stored = await _read(resourceCredentialRef);
    if (stored['kind'] != 'resource' ||
        stored['cloudCredentialRef'] != cloudCredentialRef ||
        stored['accountId'] != account.id ||
        stored['serverId'] != serverId ||
        stored['userId'] != userId ||
        stored['homeUserId'] != homeUserId ||
        stored['accessToken'] != resourceToken) {
      throw const MediaServerException(MediaServerFailureKind.forbidden);
    }
    Future<PlexVerifiedResourceIdentity> verify(String token) async {
      final response = plexMap(await _request('/api/v2/user', token: token));
      if (plexString(response['id']) != userId) {
        throw const MediaServerException(MediaServerFailureKind.forbidden);
      }
      final rows = plexList(
        await _request(
          '/api/v2/resources',
          token: token,
          query: {'includeHttps': 1, 'includeRelay': 1, 'includeIPv6': 1},
        ),
      );
      final resources = rows
          .where(
            (row) =>
                plexString(row['clientIdentifier']) == serverId &&
                plexString(row['provides']).split(',').contains('server'),
          )
          .toList();
      if (resources.length != 1 ||
          plexString(resources.single['accessToken']) != resourceToken ||
          !plexList(resources.single['connections']).any((row) {
            final uri = Uri.tryParse(plexString(row['uri']));
            return uri != null && _sameConnection(uri, connection);
          })) {
        throw const MediaServerException(MediaServerFailureKind.forbidden);
      }
      _check();
      return PlexVerifiedResourceIdentity._(
        MediaUser(
          id: userId,
          name: plexString(response['title'] ?? response['username']),
        ),
        serverId,
        account.id,
        homeUserId,
        connection,
        resourceToken,
      );
    }

    if (homeUserId == null) return _withAccount(account, verify);
    final homeRef = stored['homeCredentialRef'];
    if (homeRef is! String) {
      throw const MediaServerException(
        MediaServerFailureKind.authorizationExpired,
      );
    }
    final home = await _read(homeRef);
    if (home['kind'] != 'home' ||
        home['cloudCredentialRef'] != cloudCredentialRef ||
        home['accountId'] != account.id ||
        home['userId'] != homeUserId) {
      throw const MediaServerException(MediaServerFailureKind.forbidden);
    }
    // Never refresh an expired Home token using the owner's device grant.
    // Re-enter Home/PIN authorization instead of silently escalating to owner.
    return verify(home['accessToken'] as String);
  }

  @override
  Future<void> revokeAccount(CloudAccount account) async {
    _generations[account.credentialRef] =
        (_generations[account.credentialRef] ?? 0) + 1;
    final stored = await _read(account.credentialRef);
    await _request(
      '/api/v2/users/signout',
      method: 'DELETE',
      home: true,
      token: stored['accessToken'] as String,
    );
    await deleteCredential(account.credentialRef);
  }
}

String _b64(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

String? _tokenExpiry(String token) {
  try {
    final payload = plexMap(
      jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(token.split('.')[1]))),
      ),
    );
    final exp = plexInt(payload['exp']);
    return exp == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            exp * 1000,
            isUtc: true,
          ).toIso8601String();
  } catch (_) {
    return null;
  }
}

class _PlexPin implements AuthorizationAttempt {
  _PlexPin(this.owner, this.key, this.id, this.code, this.expiresAt);
  final PlexAuthentication owner;
  final Map<String, dynamic> key;
  final String id;
  @override
  final String code;
  @override
  final DateTime expiresAt;
  bool _cancelled = false;
  String? _token;
  AuthorizationGrant? _grant;
  @override
  Duration get pollInterval => const Duration(seconds: 1);
  @override
  Uri get verificationUri => owner.strongPin
      ? Uri.parse('https://app.plex.tv/auth').replace(
          fragment:
              '?${Uri(queryParameters: {'clientID': owner.device.deviceId, 'code': code, 'context[device][product]': owner.device.clientName}).query}',
        )
      : Uri.https('plex.tv', '/link/', {'pin': code});
  void _check() {
    owner._check();
    if (_cancelled || !owner.now().isBefore(expiresAt)) {
      throw MediaServerException(
        _cancelled
            ? MediaServerFailureKind.cancelled
            : MediaServerFailureKind.authorizationExpired,
      );
    }
  }

  @override
  Future<AuthorizationStatus> poll() async {
    if (_cancelled) return AuthorizationStatus.cancelled;
    if (!owner.now().isBefore(expiresAt)) return AuthorizationStatus.expired;
    final row = plexMap(
      await owner._request(
        '/api/v2/pins/${Uri.encodeComponent(id)}',
        query: {'deviceJWT': await owner._sign(key)},
      ),
    );
    if (_cancelled) return AuthorizationStatus.cancelled;
    if (!owner.now().isBefore(expiresAt)) return AuthorizationStatus.expired;
    if (row['authToken'] is String) _token = row['authToken'] as String;
    return _token == null
        ? AuthorizationStatus.pending
        : AuthorizationStatus.authorized;
  }

  @override
  Future<AuthorizationGrant> exchange() async {
    _check();
    if (_grant != null) return _grant!;
    if (_token == null) {
      throw const MediaServerException(
        MediaServerFailureKind.invalidCredentials,
      );
    }
    final account = await owner._accept(_token!, key, _check);
    _check();
    return _grant = CloudAuthorizationGrant(account);
  }

  @override
  Future<void> cancel() async {
    _cancelled = true;
    _token = null;
  }
}
