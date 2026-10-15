import 'dart:convert';

import 'backup_import_models.dart';
import 'hills_backup.dart';
import 'rodel_backup_package.dart';
import 'rodel_common_config.dart';

/// Parses a foreign backup file into media-server import drafts. The parser is
/// read-only: it never touches the server list, credentials or any other
/// store; committing drafts stays with the existing import registry.
///
/// Format detection is container-based — a ZIP local-file header routes to the
/// `.rpb` parser, otherwise the document must be JSON recognized as a Hills
/// backup (version 2 + `data`) or a common-config export (`from` +
/// `configs`). Unrecognized, damaged, oversized or undecryptable input yields
/// a non-ready status with zero drafts, and a valid container still reports
/// each bad record individually.
Future<BackupImportParseResult> parseBackupForImport(
  List<int> bytes, {
  BackupImportKeys keys = const BackupImportKeys(),
  BackupImportLimits limits = const BackupImportLimits(),
}) async {
  if (bytes.length > limits.maxInputBytes) {
    return const BackupImportParseResult(
      format: null,
      status: BackupImportContainerStatus.sizeLimitExceeded,
    );
  }
  if (bytes.length >= 2 && bytes[0] == 0x50 && bytes[1] == 0x4B) {
    return parseRodelBackupPackage(bytes, keys, limits);
  }
  final document = _tryDecodeJsonObject(bytes);
  if (document != null) {
    // A `data` payload or a version marker routes to the Hills parser, which
    // owns the version check so unknown versions are reported as such rather
    // than as an unrecognized file.
    if (document.containsKey('data') || document['version'] == 2) {
      return parseHillsBackupJson(document, keys);
    }
    if (document['from'] is String && document['configs'] is List) {
      return parseRodelCommonConfig(document, keys);
    }
  }
  return const BackupImportParseResult(
    format: null,
    status: BackupImportContainerStatus.unrecognizedFormat,
  );
}

Map<String, dynamic>? _tryDecodeJsonObject(List<int> bytes) {
  try {
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
  } on FormatException {
    // Not UTF-8 JSON; the caller reports an unrecognized format.
  }
  return null;
}
