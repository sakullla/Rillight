import 'package:dio/dio.dart';
import 'package:rillight/media_server/errors.dart';

Map<String, dynamic> plexMap(Object? value) {
  if (value is Map) return Map<String, dynamic>.from(value);
  throw const MediaServerException(MediaServerFailureKind.invalidResponse);
}

List<Map<String, dynamic>> plexList(Object? value) =>
    value is List ? value.map(plexMap).toList() : const [];
int? plexInt(Object? value) =>
    value is num ? value.toInt() : int.tryParse('$value');
String plexString(Object? value) => value?.toString() ?? '';

/// Never include upstream bodies, URLs, PINs or token-bearing Dio errors in
/// user-visible failures. Redirects are handled explicitly by resource readers.
Future<Response<dynamic>> plexRequest(
  Dio dio,
  Uri uri, {
  String method = 'GET',
  Map<String, String> headers = const {},
  Object? data,
  ResponseType responseType = ResponseType.json,
  CancelToken? cancelToken,
}) async {
  try {
    final response = await dio.requestUri<dynamic>(
      uri,
      data: data,
      cancelToken: cancelToken,
      options: Options(
        method: method,
        headers: {'Accept': 'application/json', ...headers},
        responseType: responseType,
        followRedirects: false,
        validateStatus: (_) => true,
      ),
    );
    final status = response.statusCode ?? 0;
    if (status >= 200 && status < 400) return response;
    final kind = switch (status) {
      401 => MediaServerFailureKind.sessionExpired,
      403 => MediaServerFailureKind.forbidden,
      429 => MediaServerFailureKind.rateLimited,
      498 => MediaServerFailureKind.authorizationExpired,
      422 =>
        _clockError(response.data)
            ? MediaServerFailureKind.clockSkew
            : MediaServerFailureKind.signatureRejected,
      _ => MediaServerFailureKind.invalidResponse,
    };
    throw MediaServerException(kind, statusCode: status);
  } on DioException catch (error) {
    final mapped = MediaServerException.fromDio(error);
    throw MediaServerException(mapped.kind, statusCode: mapped.statusCode);
  }
}

bool _clockError(Object? body) {
  final text = body.toString().toLowerCase();
  return text.contains('clock') ||
      text.contains('timestamp') ||
      text.contains('issued at');
}

Uri plexEndpoint(
  Uri base,
  String path, [
  Map<String, Object?> query = const {},
]) {
  final target = Uri.parse(path);
  if (target.hasScheme || target.hasAuthority) return target;
  final prefix = base.path.replaceFirst(RegExp(r'/+$'), '');
  final uri = base.replace(
    path: '$prefix/${target.path.replaceFirst(RegExp(r'^/+'), '')}',
    query: null,
    fragment: null,
  );
  return uri.replace(
    queryParameters: {
      ...target.queryParameters,
      for (final entry in query.entries)
        if (entry.value != null) entry.key: entry.value.toString(),
    },
  );
}
