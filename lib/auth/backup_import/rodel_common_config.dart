import 'dart:convert';

import 'backup_crypto.dart';
import 'backup_import_models.dart';
import 'rodel_config_entry.dart';

/// Parser for the common-config interchange export
/// (`from`/`version`/`configs`/`_key`, observed with `from: RodelPlayer`).
///
/// Verified contract: each `configs[i]` entry holds
/// `base64(AES-256-CBC(key, IV = key[0..16], PKCS7)(entryJson))`. A self
/// carried 32-character `_key` takes precedence over the embedder's key table
/// keyed by `from`, which is how third-party producers that publish their own
/// key interoperate without any private constant. Only `configs` entries are
/// consumed; icon packages, settings and additional data never reach a draft.
Future<BackupImportParseResult> parseRodelCommonConfig(
  Map<String, dynamic> document,
  BackupImportKeys keys,
) async {
  const format = BackupImportFormat.rodelCommonConfig;
  final from = document['from'];
  final configs = document['configs'];
  if (from is! String || configs is! List) {
    return const BackupImportParseResult(
      format: format,
      status: BackupImportContainerStatus.corruptContainer,
    );
  }
  if (document['version'] != '1.0') {
    return const BackupImportParseResult(
      format: format,
      status: BackupImportContainerStatus.unsupportedVersion,
    );
  }
  var key = _selfCarriedKey(document['_key']);
  key ??= keys.rodelCommonKeysBySource[from];
  if (key == null || key.length != 32) {
    return const BackupImportParseResult(
      format: format,
      status: BackupImportContainerStatus.decryptionKeyUnavailable,
    );
  }
  final records = <BackupRecordOutcome>[];
  for (var i = 0; i < configs.length; i++) {
    final entry = configs[i];
    Object? decoded;
    if (entry is String) {
      final ciphertext = tryDecodeBase64(entry);
      final clear = ciphertext == null
          ? null
          : await tryDecryptAes256CbcFixedIv(
              key,
              ciphertext,
              key.sublist(0, 16),
            );
      if (clear != null) {
        try {
          decoded = jsonDecode(utf8.decode(clear));
        } on FormatException {
          decoded = null;
        }
      }
    }
    if (decoded == null) {
      records.add(
        BackupRecordOutcome(
          index: i,
          status: BackupRecordStatus.invalid,
          reason: BackupRecordReason.undecryptableRecord,
        ),
      );
      continue;
    }
    records.add(mapRodelConfigEntry(i, decoded));
  }
  return BackupImportParseResult(
    format: format,
    status: BackupImportContainerStatus.ready,
    records: records,
  );
}

List<int>? _selfCarriedKey(Object? value) {
  if (value is! String) return null;
  final bytes = utf8.encode(value);
  return bytes.length == 32 ? bytes : null;
}
