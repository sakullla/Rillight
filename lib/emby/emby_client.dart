import 'package:dio/dio.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/emby/emby_url.dart';

class EmbyClient {
  EmbyClient({
    required this.device,
    Dio? dio,
    Duration connectTimeout = const Duration(seconds: 15),
    Duration receiveTimeout = const Duration(seconds: 15),
    this.onSessionExpired,
  }) : _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: connectTimeout,
               receiveTimeout: receiveTimeout,
               sendTimeout: connectTimeout,
               headers: const {'Accept': 'application/json'},
             ),
           );

  final EmbyDeviceInfo device;
  final Dio _dio;
  void Function()? onSessionExpired;

  Uri? _baseUrl;
  String? _accessToken;
  String? _userId;

  Uri? get baseUrl => _baseUrl;
  String? get accessToken => _accessToken;
  String? get userId => _userId;
  bool get hasSession =>
      _baseUrl != null && _accessToken != null && _accessToken!.isNotEmpty;

  void attachSession({
    required Uri baseUrl,
    required String accessToken,
    required String userId,
  }) {
    _baseUrl = baseUrl;
    _accessToken = accessToken;
    _userId = userId;
  }

  void clearSession() {
    _baseUrl = null;
    _accessToken = null;
    _userId = null;
  }

  Future<PublicServerInfo> getPublicInfo(Uri baseUrl) async {
    final uri = joinEmbyPath(baseUrl, '/System/Info/Public');
    try {
      final response = await _dio.getUri<dynamic>(
        uri,
        options: Options(headers: _headers()),
      );
      return PublicServerInfo.fromJson(
        _asJsonMap(response.data, notEmby: true),
        fallbackName: baseUrl.host,
      );
    } on EmbyException {
      rethrow;
    } on DioException catch (error) {
      throw _mapPublicInfoFailure(error);
    }
  }

  Future<AuthenticationResult> authenticateByName({
    required Uri baseUrl,
    required String username,
    required String password,
    required String serverId,
  }) async {
    final uri = joinEmbyPath(baseUrl, '/Users/AuthenticateByName');
    try {
      final response = await _dio.postUri<dynamic>(
        uri,
        data: {'Username': username, 'Pw': password},
        options: Options(
          headers: {..._headers(), 'Content-Type': 'application/json'},
        ),
      );
      return AuthenticationResult.fromJson(
        _asJsonMap(response.data, notEmby: false),
        fallbackServerId: serverId,
      );
    } on EmbyException {
      rethrow;
    } on DioException catch (error) {
      throw EmbyException.fromDio(error, authenticating: true);
    }
  }

  Future<void> logout() async {
    if (!hasSession) {
      return;
    }
    try {
      await postJson('/Sessions/Logout');
    } on EmbyException catch (error) {
      if (error.kind == EmbyFailureKind.sessionExpired) {
        return;
      }
      rethrow;
    }
  }

  Future<Map<String, dynamic>> getJson(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) {
    return _requestJson('GET', path, queryParameters: queryParameters);
  }

  Future<Map<String, dynamic>> postJson(String path, {Object? body}) {
    return _requestJson('POST', path, body: body);
  }

  Future<Map<String, dynamic>> _requestJson(
    String method,
    String path, {
    Object? body,
    Map<String, dynamic>? queryParameters,
  }) async {
    if (!hasSession) {
      throw const EmbyException(EmbyFailureKind.sessionExpired);
    }
    final uri = joinEmbyPath(
      _baseUrl!,
      path,
    ).replace(queryParameters: queryParameters);
    try {
      final response = await _dio.requestUri<dynamic>(
        uri,
        data: body,
        options: Options(
          method: method,
          headers: _headers(token: _accessToken, userId: _userId),
        ),
      );
      if (response.data == null ||
          (response.data is String && (response.data as String).isEmpty)) {
        return <String, dynamic>{};
      }
      if (response.data is Map) {
        return _asJsonMap(response.data, notEmby: false);
      }
      return <String, dynamic>{'value': response.data};
    } on EmbyException {
      rethrow;
    } on DioException catch (error) {
      final mapped = EmbyException.fromDio(error);
      if (mapped.kind == EmbyFailureKind.sessionExpired) {
        onSessionExpired?.call();
      }
      throw mapped;
    }
  }

  Map<String, String> _headers({String? token, String? userId}) {
    final authorization = device.authorizationHeader(
      userId: userId,
      token: token,
    );
    return {
      'Authorization': authorization,
      'X-Emby-Authorization': authorization,
      if (token != null && token.isNotEmpty) 'X-Emby-Token': token,
    };
  }

  Map<String, dynamic> _asJsonMap(dynamic data, {required bool notEmby}) {
    if (data is Map<String, dynamic>) {
      return data;
    }
    if (data is Map) {
      return Map<String, dynamic>.from(data);
    }
    throw EmbyException(
      notEmby ? EmbyFailureKind.notEmby : EmbyFailureKind.unknown,
    );
  }

  EmbyException _mapPublicInfoFailure(DioException error) {
    final mapped = EmbyException.fromDio(error);
    if (mapped.kind == EmbyFailureKind.timeout ||
        mapped.kind == EmbyFailureKind.certificate ||
        mapped.kind == EmbyFailureKind.unreachable) {
      return mapped;
    }
    if (error.response != null) {
      return EmbyException(
        EmbyFailureKind.notEmby,
        statusCode: error.response?.statusCode,
        cause: error,
      );
    }
    return mapped;
  }
}
