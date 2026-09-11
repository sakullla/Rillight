import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

class FakeEmbyUser {
  const FakeEmbyUser({
    required this.username,
    required this.password,
    required this.userId,
  });

  final String username;
  final String password;
  final String userId;
}

class FakeEmbyServer {
  FakeEmbyServer({
    this.serverId = 'server-id-1',
    this.serverName = '灯川测试',
    this.version = '4.8.0.0',
    Uri? baseUrl,
    List<FakeEmbyUser>? users,
  }) : baseUrl = baseUrl ?? Uri.parse('http://emby.test:8096'),
       users =
           users ??
           const [
             FakeEmbyUser(
               username: 'alice',
               password: 'correct-horse',
               userId: 'user-alice',
             ),
           ];

  final List<FakeEmbyUser> users;
  final Uri baseUrl;
  String serverId;
  String serverName;
  String version;

  bool hangPublicInfo = false;
  bool publicInfoHtml = false;
  int? publicInfoStatus;
  bool expireAuthenticatedRequests = false;

  final List<String> requests = [];
  final Set<String> issuedTokens = {};
  final Set<String> loggedOutTokens = {};
  int _tokenSeq = 0;

  Future<ResponseBody> handle(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
  ) async {
    final path = options.uri.path;
    requests.add('${options.method.toUpperCase()} $path');

    if (hangPublicInfo && path.endsWith('/System/Info/Public')) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }

    if (path.endsWith('/System/Info/Public') &&
        options.method.toUpperCase() == 'GET') {
      return _handlePublicInfo();
    }
    if (path.endsWith('/Users/AuthenticateByName') &&
        options.method.toUpperCase() == 'POST') {
      return _handleAuthenticate(await _readBody(options, requestStream));
    }

    final token = _tokenOf(options);
    if (expireAuthenticatedRequests ||
        token == null ||
        !issuedTokens.contains(token) ||
        loggedOutTokens.contains(token)) {
      return _json(401, {'error': 'unauthorized'});
    }

    if (path.endsWith('/Sessions/Logout') &&
        options.method.toUpperCase() == 'POST') {
      loggedOutTokens.add(token);
      issuedTokens.remove(token);
      return _json(200, {});
    }

    if (path.endsWith('/System/Info') &&
        options.method.toUpperCase() == 'GET') {
      return _json(200, {
        'Id': serverId,
        'ServerName': serverName,
        'Version': version,
      });
    }

    return _json(404, {'error': 'not found'});
  }

  ResponseBody _handlePublicInfo() {
    if (publicInfoStatus != null) {
      return _json(publicInfoStatus!, {'error': 'failed'});
    }
    if (publicInfoHtml) {
      return ResponseBody.fromString(
        '<html>not emby</html>',
        200,
        headers: {
          Headers.contentTypeHeader: [ContentType.html.mimeType],
        },
      );
    }
    return _json(200, {
      'Id': serverId,
      'ServerName': serverName,
      'Version': version,
    });
  }

  ResponseBody _handleAuthenticate(String raw) {
    Map<String, dynamic> body = const {};
    if (raw.isNotEmpty) {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        body = Map<String, dynamic>.from(decoded);
      }
    }
    final username = body['Username']?.toString() ?? '';
    final password = body['Pw']?.toString() ?? '';
    FakeEmbyUser? user;
    for (final item in users) {
      if (item.username == username && item.password == password) {
        user = item;
        break;
      }
    }
    if (user == null) {
      return _json(401, {'error': 'invalid credentials'});
    }
    final token = 'token-$serverId-${user.username}-${++_tokenSeq}';
    issuedTokens.add(token);
    return _json(200, {
      'AccessToken': token,
      'ServerId': serverId,
      'User': {'Id': user.userId, 'Name': user.username, 'ServerId': serverId},
    });
  }

  String? _tokenOf(RequestOptions options) {
    final headers = options.headers;
    final header =
        headers['X-Emby-Token']?.toString() ??
        headers['x-emby-token']?.toString();
    if (header != null && header.isNotEmpty) {
      return header;
    }
    final authorization =
        headers['X-Emby-Authorization']?.toString() ??
        headers['Authorization']?.toString() ??
        headers['authorization']?.toString() ??
        '';
    return RegExp(r'Token="([^"]+)"').firstMatch(authorization)?.group(1);
  }

  Future<String> _readBody(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
  ) async {
    if (options.data is String) {
      return options.data as String;
    }
    if (options.data is Map) {
      return jsonEncode(options.data);
    }
    if (requestStream == null) {
      return '';
    }
    final chunks = await requestStream.toList();
    return utf8.decode(chunks.expand((chunk) => chunk).toList());
  }

  ResponseBody _json(int status, Object body) {
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

class FakeEmbyAdapter implements HttpClientAdapter {
  FakeEmbyAdapter([List<FakeEmbyServer>? servers]) {
    for (final server in servers ?? const <FakeEmbyServer>[]) {
      add(server);
    }
  }

  bool certificateError = false;
  final Map<String, FakeEmbyServer> _servers = {};

  void add(FakeEmbyServer server) {
    _servers[server.baseUrl.authority] = server;
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    if (certificateError) {
      return Future.error(
        DioException(
          requestOptions: options,
          type: DioExceptionType.badCertificate,
          error: const HandshakeException('CERTIFICATE_VERIFY_FAILED'),
        ),
      );
    }
    final server = _servers[options.uri.authority];
    if (server == null) {
      return Future.error(
        DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
          error: const SocketException('Connection refused'),
        ),
      );
    }
    final future = server.handle(options, requestStream);
    final timeout = options.receiveTimeout ?? options.connectTimeout;
    if (timeout != null && timeout > Duration.zero) {
      return future.timeout(
        timeout,
        onTimeout: () => throw DioException(
          requestOptions: options,
          type: DioExceptionType.receiveTimeout,
        ),
      );
    }
    return future;
  }

  @override
  void close({bool force = false}) {}
}

Dio dioForFakeEmby(
  FakeEmbyAdapter adapter, {
  Duration timeout = const Duration(seconds: 5),
}) {
  return Dio(
    BaseOptions(
      connectTimeout: timeout,
      receiveTimeout: timeout,
      sendTimeout: timeout,
      headers: const {'Accept': 'application/json'},
    ),
  )..httpClientAdapter = adapter;
}
