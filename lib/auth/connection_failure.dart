import '../media_server/errors.dart';

/// Form feedback contains a category and HTTP status, never a server response
/// body, URL query, password, resource token or arbitrary exception diagnostic.
MediaServerException connectionFailure(Object error) {
  if (error is MediaServerException) {
    return MediaServerException(
      error.kind,
      statusCode: error.statusCode,
      detail: error.statusCode == null ? null : 'HTTP ${error.statusCode}',
    );
  }
  final message = error is StateError ? error.message.toLowerCase() : '';
  final kind = message.contains('account identity')
      ? MediaServerFailureKind.invalidCredentials
      : message.contains('identity mismatch') ||
            message.contains('identity changed')
      ? MediaServerFailureKind.incompatibleServer
      : message.contains('login required')
      ? MediaServerFailureKind.sessionExpired
      : message.contains('revoked') || message.contains('superseded')
      ? MediaServerFailureKind.cancelled
      : MediaServerFailureKind.unknown;
  return MediaServerException(kind);
}
