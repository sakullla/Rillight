import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/media_server/errors.dart';

String embyFailureMessage(AppLocalizations l10n, MediaServerException error) {
  final detail = error.detail?.trim();
  if (error.statusCode == 403 &&
      (detail == null || detail.isEmpty || detail == 'HTTP 403')) {
    return 'HTTP 403: ${l10n.errorForbidden}';
  }
  if (detail != null && detail.isNotEmpty) {
    return detail;
  }
  switch (error.kind) {
    case MediaServerFailureKind.invalidAddress:
      return l10n.errorInvalidAddress;
    case MediaServerFailureKind.unreachable:
      return l10n.errorUnreachable;
    case MediaServerFailureKind.timeout:
      return l10n.errorTimeout;
    case MediaServerFailureKind.certificate:
      return l10n.errorCertificate;
    case MediaServerFailureKind.incompatibleServer:
      return l10n.errorNotEmby;
    case MediaServerFailureKind.invalidCredentials:
      return l10n.errorInvalidCredentials;
    case MediaServerFailureKind.sessionExpired:
      return l10n.errorSessionExpired;
    case MediaServerFailureKind.forbidden:
      return l10n.errorForbidden;
    case MediaServerFailureKind.rateLimited:
    case MediaServerFailureKind.cancelled:
    case MediaServerFailureKind.unsupported:
    case MediaServerFailureKind.invalidResponse:
    case MediaServerFailureKind.authorizationExpired:
    case MediaServerFailureKind.signatureRejected:
    case MediaServerFailureKind.clockSkew:
    case MediaServerFailureKind.unknown:
      return l10n.errorUnknown;
  }
}
