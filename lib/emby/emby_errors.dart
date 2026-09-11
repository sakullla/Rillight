import 'dart:io';

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
  const EmbyException(this.kind, {this.statusCode, this.cause});

  final EmbyFailureKind kind;
  final int? statusCode;
  final Object? cause;

  factory EmbyException.fromDio(
    DioException error, {
    bool authenticating = false,
  }) {
    if (_isCertificateFailure(error)) {
      return EmbyException(EmbyFailureKind.certificate, cause: error);
    }

    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.transformTimeout:
        return EmbyException(EmbyFailureKind.timeout, cause: error);
      case DioExceptionType.badCertificate:
        return EmbyException(EmbyFailureKind.certificate, cause: error);
      case DioExceptionType.connectionError:
        return EmbyException(EmbyFailureKind.unreachable, cause: error);
      case DioExceptionType.badResponse:
        final code = error.response?.statusCode;
        if (authenticating && (code == 401 || code == 400 || code == 403)) {
          return EmbyException(
            EmbyFailureKind.invalidCredentials,
            statusCode: code,
            cause: error,
          );
        }
        if (!authenticating && code == 401) {
          return EmbyException(
            EmbyFailureKind.sessionExpired,
            statusCode: code,
            cause: error,
          );
        }
        return EmbyException(
          EmbyFailureKind.unknown,
          statusCode: code,
          cause: error,
        );
      case DioExceptionType.unknown:
        if (error.error is SocketException) {
          return EmbyException(EmbyFailureKind.unreachable, cause: error);
        }
        return EmbyException(EmbyFailureKind.unknown, cause: error);
      case DioExceptionType.cancel:
        return EmbyException(EmbyFailureKind.unknown, cause: error);
    }
  }

  @override
  String toString() => 'EmbyException($kind, statusCode: $statusCode)';
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
