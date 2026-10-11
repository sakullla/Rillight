import '../../emby/emby_errors.dart';
import '../../emby/emby_url.dart';
import '../credential_store.dart';
import '../server_import_models.dart';
import 'backup_import_models.dart';

/// Maps one decrypted common-config record onto the shared import draft.
/// The schema is verified for common-config entries
/// (`type`/`name`/`url`/`lines`/`authorization`); the native `.rpb`
/// `config.json` payload uses its own sqlite `Config` row schema and is
/// mapped by `mapRodelPackageRow` instead. Records are only reported after
/// a working key materializes them, so an unverifiable assumption can never
/// silently produce drafts on its own.
BackupRecordOutcome mapRodelConfigEntry(int index, Object? entry) {
  if (entry is! Map) {
    return BackupRecordOutcome(
      index: index,
      status: BackupRecordStatus.invalid,
      reason: BackupRecordReason.malformedRecord,
    );
  }
  final type = _text(entry['type']);
  if (type != 'emby') {
    return BackupRecordOutcome(
      index: index,
      status: BackupRecordStatus.skippedNonTarget,
      reason: BackupRecordReason.nonTargetServerType,
    );
  }
  final name = _text(entry['name']);
  final lines = <ServerImportLine>[];
  final primary = _normalizeLine(_text(entry['url']));
  if (primary != null) {
    lines.add(primary);
  }
  final extraLines = entry['lines'];
  if (extraLines is List) {
    for (final extra in extraLines) {
      if (extra is! Map) continue;
      final line = _normalizeLine(_text(extra['url']), _text(extra['name']));
      if (line != null && lines.every((e) => e.address != line.address)) {
        lines.add(line);
      }
    }
  }
  if (name.isEmpty || lines.isEmpty) {
    return BackupRecordOutcome(
      index: index,
      status: BackupRecordStatus.invalid,
      reason: BackupRecordReason.missingRequiredFields,
    );
  }
  return BackupRecordOutcome(
    index: index,
    status: BackupRecordStatus.ready,
    draft: ServerImportDraft(
      name: name,
      username: _authorizationName(entry['authorization']),
      lines: List.unmodifiable(lines),
      credentials: _rodelCredentials(entry['authorization']),
    ),
  );
}

StoredCredentials? _rodelCredentials(Object? authorization) {
  if (authorization is! Map) return null;
  final accessToken = _text(authorization['access_token']);
  final password = _text(authorization['password']);
  if (accessToken.isEmpty && password.isEmpty) {
    return null;
  }
  return StoredCredentials(
    accessToken: accessToken,
    userId: _text(authorization['user_id']),
    username: _authorizationName(authorization),
    password: password.isEmpty ? null : password,
  );
}

String _authorizationName(Object? authorization) =>
    authorization is Map ? _text(authorization['user_name']) : '';

ServerImportLine? _normalizeLine(String raw, [String name = '']) {
  if (raw.isEmpty) return null;
  try {
    return ServerImportLine(
      address: normalizeEmbyBaseUrl(raw).toString(),
      name: name.isEmpty ? null : name,
    );
  } on EmbyException {
    return null;
  }
}

String _text(Object? value) => value is String ? value : '';
