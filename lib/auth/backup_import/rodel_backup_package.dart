import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'backup_crypto.dart';
import 'backup_import_models.dart';
import 'rodel_config_entry.dart';

/// Parser for the Rodel native `.rpb` backup package (v2/v3).
///
/// Verified container contract: a ZIP archive with `__v2__`/`__v3__` marker
/// entries; `config.json` holds base64 AES-256-CBC connection records while
/// history, settings, search history and other members are plaintext JSON.
/// Only `config.json` is decoded; user history and preferences never reach a
/// draft and nothing is extracted to the file system.
///
/// Open gap, reported honestly: the native key for `config.json` is not yet
/// available through an authorized channel. Without a candidate key the parse
/// returns [BackupImportContainerStatus.decryptionKeyUnavailable] with zero
/// drafts rather than an empty success, and with a wrong key it returns
/// [BackupImportContainerStatus.undecryptablePayload]. The IV layout of the
/// real payload is likewise unverified, so both observed layouts — IV
/// prefixed to the ciphertext and IV derived from the key — are attempted.
Future<BackupImportParseResult> parseRodelBackupPackage(
  List<int> bytes,
  BackupImportKeys keys,
  BackupImportLimits limits,
) async {
  const format = BackupImportFormat.rodelBackupPackage;
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes);
  } catch (_) {
    return const BackupImportParseResult(
      format: format,
      status: BackupImportContainerStatus.corruptContainer,
    );
  }
  final files = archive.files;
  // The decoder never throws on damaged input; it returns an empty archive.
  // A real `.rpb` always carries its marker entries, and any other ZIP keeps
  // its central directory, so an empty result means the container is damaged
  // while a markerless non-empty ZIP is simply not a `.rpb` backup.
  if (files.isEmpty) {
    return const BackupImportParseResult(
      format: format,
      status: BackupImportContainerStatus.corruptContainer,
    );
  }
  if (!files.any((file) => file.name == '__v2__' || file.name == '__v3__')) {
    return const BackupImportParseResult(
      format: format,
      status: BackupImportContainerStatus.unrecognizedFormat,
    );
  }
  if (files.length > limits.maxArchiveEntries) {
    return const BackupImportParseResult(
      format: format,
      status: BackupImportContainerStatus.sizeLimitExceeded,
    );
  }
  final configFile = files.where((file) => file.name == 'config.json').toList();
  if (configFile.isEmpty) {
    return const BackupImportParseResult(
      format: format,
      status: BackupImportContainerStatus.corruptContainer,
    );
  }
  final Uint8List content;
  try {
    content = configFile.first.content;
  } catch (_) {
    return const BackupImportParseResult(
      format: format,
      status: BackupImportContainerStatus.corruptContainer,
    );
  }
  if (content.length > limits.maxArchiveEntryBytes) {
    return const BackupImportParseResult(
      format: format,
      status: BackupImportContainerStatus.sizeLimitExceeded,
    );
  }
  List<int>? ciphertext;
  try {
    ciphertext = tryDecodeBase64(utf8.decode(content));
  } on FormatException {
    ciphertext = null;
  }
  if (ciphertext == null) {
    return const BackupImportParseResult(
      format: format,
      status: BackupImportContainerStatus.corruptContainer,
    );
  }
  final candidateKeys = keys.rodelBackupConfigKeys
      .where((key) => key.length == 32)
      .toList(growable: false);
  if (candidateKeys.isEmpty) {
    return const BackupImportParseResult(
      format: format,
      status: BackupImportContainerStatus.decryptionKeyUnavailable,
    );
  }
  for (final key in candidateKeys) {
    final records = await _tryConfigRecords(key, ciphertext);
    if (records != null) {
      return BackupImportParseResult(
        format: format,
        status: BackupImportContainerStatus.ready,
        records: records,
      );
    }
  }
  return const BackupImportParseResult(
    format: format,
    status: BackupImportContainerStatus.undecryptablePayload,
  );
}

Future<List<BackupRecordOutcome>?> _tryConfigRecords(
  List<int> key,
  List<int> ciphertext,
) async {
  final layouts = <Uint8List?>[];
  layouts.add(await tryDecryptAes256CbcPrefixedIv(key, ciphertext));
  layouts.add(
    await tryDecryptAes256CbcFixedIv(key, ciphertext, key.sublist(0, 16)),
  );
  for (final clear in layouts) {
    if (clear == null) continue;
    List<dynamic>? entries;
    try {
      final decoded = jsonDecode(utf8.decode(clear));
      if (decoded is List) {
        entries = decoded;
      } else if (decoded is Map && decoded['configs'] is List) {
        entries = decoded['configs']! as List;
      }
    } on FormatException {
      entries = null;
    }
    if (entries == null) continue;
    return [
      for (var i = 0; i < entries.length; i++)
        mapRodelConfigEntry(i, entries[i]),
    ];
  }
  return null;
}
