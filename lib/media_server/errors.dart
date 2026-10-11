import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

enum MediaServerFailureKind {
  invalidAddress,
  unreachable,
  timeout,
  certificate,
  incompatibleServer,
  forbidden,
  rateLimited,
  cancelled,
  unsupported,
  invalidResponse,
  authorizationExpired,
  signatureRejected,
  clockSkew,
  invalidCredentials,
  sessionExpired,
  unknown,
}

class MediaServerException implements Exception {
  const MediaServerException(
    this.kind, {
    this.statusCode,
    this.detail,
    this.cause,
  });

  final MediaServerFailureKind kind;
  final int? statusCode;
  final String? detail;
  final Object? cause;

  factory MediaServerException.fromDio(
    DioException error, {
    bool authenticating = false,
  }) {
    final detail = _detailFromDio(error);
    if (_isCertificateFailure(error)) {
      return MediaServerException(
        MediaServerFailureKind.certificate,
        detail: detail,
        cause: error,
      );
    }

    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.transformTimeout:
        return MediaServerException(
          MediaServerFailureKind.timeout,
          detail: detail,
          cause: error,
        );
      case DioExceptionType.badCertificate:
        return MediaServerException(
          MediaServerFailureKind.certificate,
          detail: detail,
          cause: error,
        );
      case DioExceptionType.connectionError:
        return MediaServerException(
          MediaServerFailureKind.unreachable,
          detail: detail,
          cause: error,
        );
      case DioExceptionType.badResponse:
        final code = error.response?.statusCode;
        if (code == 403 || code == 429) {
          return MediaServerException(
            code == 403
                ? MediaServerFailureKind.forbidden
                : MediaServerFailureKind.rateLimited,
            statusCode: code,
            detail: detail,
            cause: error,
          );
        }
        if (authenticating && (code == 401 || code == 400)) {
          return MediaServerException(
            MediaServerFailureKind.invalidCredentials,
            statusCode: code,
            detail: detail,
            cause: error,
          );
        }
        if (!authenticating && code == 401) {
          return MediaServerException(
            MediaServerFailureKind.sessionExpired,
            statusCode: code,
            detail: detail,
            cause: error,
          );
        }
        return MediaServerException(
          MediaServerFailureKind.unknown,
          statusCode: code,
          detail: detail,
          cause: error,
        );
      case DioExceptionType.unknown:
        if (error.error is SocketException) {
          return MediaServerException(
            MediaServerFailureKind.unreachable,
            detail: detail,
            cause: error,
          );
        }
        return MediaServerException(
          MediaServerFailureKind.unknown,
          detail: detail,
          cause: error,
        );
      case DioExceptionType.cancel:
        return MediaServerException(
          MediaServerFailureKind.cancelled,
          detail: detail,
          cause: error,
        );
    }
  }

  @override
  String toString() =>
      'MediaServerException($kind, statusCode: $statusCode, detail: $detail)';
}

bool _isCertificateFailure(DioException error) {
  if (error.type == DioExceptionType.badCertificate) {
    return true;
  }
  Object? current = error.error;
  for (var i = 0; i < 6 && current != null; i++) {
    if (current is CertificateException ||
        current is HandshakeException ||
        current is TlsException) {
      return true;
    }
    if (current is DioException) {
      current = current.error;
      continue;
    }
    if (current is SocketException) {
      current = current.osError;
      continue;
    }
    break;
  }
  final text = '${error.message ?? ''} ${error.error ?? ''}'.toLowerCase();
  return text.contains('certificate') ||
      text.contains('handshake') ||
      text.contains('certificate_verify_failed');
}

String? _detailFromDio(DioException error) {
  final contentType = error.response?.headers
      .value(Headers.contentTypeHeader)
      ?.toLowerCase();
  final html =
      contentType?.contains('text/html') == true ||
      contentType?.contains('application/xhtml+xml') == true;
  final body = html ? null : _safeDetail(_bodyText(error.response?.data));
  final code = error.response?.statusCode;
  if (body != null && body.isNotEmpty) {
    return code == null ? body : 'HTTP $code: $body';
  }
  if (code != null) {
    return 'HTTP $code';
  }
  final inner = error.error;
  if (inner is SocketException) {
    final osError = inner.osError;
    if (osError != null) {
      final os = osError.message.trim();
      if (os.isNotEmpty) {
        return _safeDetail(os);
      }
    }
    final message = inner.message.trim();
    return _safeDetail(message.isEmpty ? inner.toString() : message);
  }
  if (inner is HandshakeException ||
      inner is TlsException ||
      inner is CertificateException) {
    return _safeDetail(inner.toString());
  }
  final message = error.message?.trim();
  if (message != null && message.isNotEmpty) {
    return _safeDetail(message);
  }
  if (inner != null) {
    return _safeDetail(inner.toString());
  }
  return null;
}

String? _safeDetail(String? text) {
  if (text == null) return null;
  // Proxy error pages are not useful form feedback, even with a wrong MIME type.
  if (RegExp(
    r'<\s*(?:!doctype\s+html|/?[a-z][\w:-]*(?:\s[^<>]*)?/?>)',
    caseSensitive: false,
  ).hasMatch(text)) {
    return null;
  }
  final clean = text
      .replaceAll(
        RegExp(r'[\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]'),
        ' ',
      )
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (clean.isEmpty) return null;
  const limit = 240;
  final runes = clean.runes.take(limit + 1).toList();
  return runes.length > limit
      ? '${String.fromCharCodes(runes.take(limit))}…'
      : clean;
}

String? _bodyText(Object? data) {
  if (data == null) {
    return null;
  }
  if (data is String) {
    final trimmed = data.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
  if (data is Uint8List || data is List<int>) {
    final decoded = utf8.decode(data as List<int>, allowMalformed: true).trim();
    return decoded.isEmpty ? null : decoded;
  }
  if (data is Map) {
    for (final key in const ['Message', 'message', 'error', 'Error', 'title']) {
      final value = data[key];
      if (value != null) {
        final text = value.toString().trim();
        if (text.isNotEmpty) {
          return text;
        }
      }
    }
  }
  return null;
}
