import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/auth/failure_message.dart';
import 'package:rillight/emby/emby_errors.dart';

String catalogFailureMessage(AppLocalizations l10n, EmbyException error) {
  final detail = error.detail?.trim();
  if (detail != null && detail.isNotEmpty) {
    return detail;
  }
  if (error.kind == EmbyFailureKind.unknown) {
    return l10n.errorLoadFailed;
  }
  return embyFailureMessage(l10n, error);
}

String searchFailureMessage(AppLocalizations l10n, EmbyException error) {
  final detail = error.detail?.trim();
  if (detail != null && detail.isNotEmpty) {
    return detail;
  }
  if (error.kind == EmbyFailureKind.unknown) {
    return l10n.errorSearchFailed;
  }
  return embyFailureMessage(l10n, error);
}
