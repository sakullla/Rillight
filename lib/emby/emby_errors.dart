import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

enum EmbyFailureKind {
  invalidAddress,
  unreachable,
  timeout,
  certificate,
  notEmby,
  invalidCredentials,
  sessionExpired,
  unknown,
}

class EmbyException implements Exception {
  const EmbyException(this.kind, {this.statusCode, this.detail, this.cause});

  final EmbyFailureKind kind;
  final int? statusCode;
  final String? detail;
  final Object? cause;

  factory EmbyException.fromDio(
    DioException error, {
    bool authenticating = false,
  }) {
    final detail = _detailFromDio(error);
    if (_isCertificateFailure(error)) {
      return EmbyException(
        EmbyFailureKind.certificate,
        detail: detail,
        cause: error,
      );
    }

    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.transformTimeout:
        return EmbyException(
          EmbyFailureKind.timeout,
          detail: detail,
          cause: error,
        );
      case DioExceptionType.badCertificate:
        return EmbyException(
          EmbyFailureKind.certificate,
          detail: detail,
          cause: error,
        );
      case DioExceptionType.connectionError:
        return EmbyException(
          EmbyFailureKind.unreachable,
          detail: detail,
          cause: error,
        );
      case DioExceptionType.badResponse:
        final code = error.response?.statusCode;
        if (authenticating && (code == 401 || code == 400 || code == 403)) {
          return EmbyException(
            EmbyFailureKind.invalidCredentials,
            statusCode: code,
            detail: detail,
            cause: error,
          );
        }
        if (!authenticating && code == 401) {
          return EmbyException(
            EmbyFailureKind.sessionExpired,
            statusCode: code,
            detail: detail,
            cause: error,
          );
        }
        return EmbyException(
          EmbyFailureKind.unknown,
          statusCode: code,
          detail: detail,
          cause: error,
        );
      case DioExceptionType.unknown:
        if (error.error is SocketException) {
          return EmbyException(
            EmbyFailureKind.unreachable,
            detail: detail,
            cause: error,
          );
        }
        return EmbyException(
          EmbyFailureKind.unknown,
          detail: detail,
          cause: error,
        );
      case DioExceptionType.cancel:
        return EmbyException(
          EmbyFailureKind.unknown,
          detail: detail,
          cause: error,
        );
    }
  }

  @override
  String toString() =>
      'EmbyException($kind, statusCode: $statusCode, detail: $detail)';
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
  final body = _bodyText(error.response?.data);
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
        return os;
      }
    }
    final message = inner.message.trim();
    return message.isEmpty ? inner.toString() : message;
  }
  if (inner is HandshakeException ||
      inner is TlsException ||
      inner is CertificateException) {
    return inner.toString();
  }
  final message = error.message?.trim();
  if (message != null && message.isNotEmpty) {
    return message;
  }
  if (inner != null) {
    return inner.toString();
  }
  return null;
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
