import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/emby/emby_errors.dart';

String embyFailureMessage(AppLocalizations l10n, EmbyFailureKind kind) {
  switch (kind) {
    case EmbyFailureKind.invalidAddress:
      return l10n.errorInvalidAddress;
    case EmbyFailureKind.unreachable:
      return l10n.errorUnreachable;
    case EmbyFailureKind.timeout:
      return l10n.errorTimeout;
    case EmbyFailureKind.certificate:
      return l10n.errorCertificate;
    case EmbyFailureKind.notEmby:
      return l10n.errorNotEmby;
    case EmbyFailureKind.invalidCredentials:
      return l10n.errorInvalidCredentials;
    case EmbyFailureKind.sessionExpired:
      return l10n.errorSessionExpired;
    case EmbyFailureKind.unknown:
      return l10n.errorUnknown;
  }
}
