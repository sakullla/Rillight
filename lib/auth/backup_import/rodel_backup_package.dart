import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../../emby/emby_errors.dart';
import '../../emby/emby_url.dart';
import '../credential_store.dart';
import '../server_import_models.dart';
import 'backup_crypto.dart';
import 'backup_import_models.dart';

/// Parser for the Rodel native `.rpb` backup package (v2/v3).
///
/// Verified container contract: a ZIP archive with `__v2__`/`__v3__` marker
/// entries; `config.json` holds `base64(IV(16-byte prefix) ||
/// AES-128-CBC(key, PKCS7))` over the sqlite `Config` table row array, which
/// — like the Hills backup — is missing its first 16 serialized characters
/// and is reconstructed with the `[{"Id":"` header. History, icon sources,
/// search history, materials, subtitle links and settings members are
/// plaintext and never reach a draft; nothing is extracted to the file
/// system.
///
/// Only the `config.json` member is decoded. Each row carries `Type` and a
/// `DetailJson` string with the connector configuration (`Name/UserName/
/// UserId/Host/Port/Path/Password/AccessToken/BackupLinesJson`). `Type: 3`
/// is the verified Emby row; other row types are reported as non-target.
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
  // The verified `.rpb` contract uses 16-byte AES-128 keys.
  final candidateKeys = keys.rodelBackupConfigKeys
      .where((key) => key.length == 16)
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

/// The native export drops the first 16 characters of the serialized row
/// array; the rows are PascalCase `Config` table objects, so the shared
/// `[{"Id":"` header reconstructs a parseable document. Only the row `Id`
/// value loses characters, and row IDs never become local identities.
const _droppedHeader = '[{"Id":"';

Future<List<BackupRecordOutcome>?> _tryConfigRecords(
  List<int> key,
  List<int> ciphertext,
) async {
  final clear = await tryDecryptAes128CbcPrefixedIv(key, ciphertext);
  if (clear == null) return null;
  // The plaintext starts mid-first-row; the header must be prepended before
  // parsing. A wrong key or damaged payload fails the decode here as well.
  final String text;
  try {
    text = utf8.decode(clear);
  } on FormatException {
    return null;
  }
  List<dynamic>? entries;
  try {
    final decoded = jsonDecode('$_droppedHeader$text');
    if (decoded is List) entries = decoded;
  } on FormatException {
    entries = null;
  }
  if (entries == null) return null;
  return [
    for (var i = 0; i < entries.length; i++) mapRodelPackageRow(i, entries[i]),
  ];
}

/// Verified Emby row type in the sqlite `Config` table.
const _rodelEmbyRowType = 3;

/// Maps one decrypted `Config` row onto the shared import draft. The row's
/// `DetailJson` string carries the connector configuration; the many
/// playback/preference options inside it stay unexpressed rather than being
/// guessed onto the draft.
BackupRecordOutcome mapRodelPackageRow(int index, Object? entry) {
  if (entry is! Map) {
    return BackupRecordOutcome(
      index: index,
      status: BackupRecordStatus.invalid,
      reason: BackupRecordReason.malformedRecord,
    );
  }
  if (entry['Type'] != _rodelEmbyRowType) {
    return BackupRecordOutcome(
      index: index,
      status: BackupRecordStatus.skippedNonTarget,
      reason: BackupRecordReason.nonTargetServerType,
    );
  }
  final detailRaw = entry['DetailJson'];
  Object? detail;
  if (detailRaw is String && detailRaw.isNotEmpty) {
    try {
      detail = jsonDecode(detailRaw);
    } on FormatException {
      detail = null;
    }
  }
  if (detail is! Map) {
    return BackupRecordOutcome(
      index: index,
      status: BackupRecordStatus.invalid,
      reason: BackupRecordReason.malformedRecord,
    );
  }
  final name = _text(detail['Name']);
  final username = _text(detail['UserName']);
  final lines = <ServerImportLine>[];
  final primary = _composeLine(detail['Host'], detail['Port'], detail['Path']);
  if (primary != null) {
    lines.add(primary);
  }
  final backupRaw = detail['BackupLinesJson'];
  if (backupRaw is String && backupRaw.isNotEmpty) {
    Object? backup;
    try {
      backup = jsonDecode(backupRaw);
    } on FormatException {
      backup = null;
    }
    if (backup is List) {
      for (final line in backup) {
        if (line is! Map) continue;
        final mapped = _composeLine(
          line['Host'],
          line['Port'],
          line['Path'],
          name: _text(line['Name']),
        );
        if (mapped != null && lines.every((e) => e.address != mapped.address)) {
          lines.add(mapped);
        }
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
      username: username,
      lines: List.unmodifiable(lines),
      credentials: _rowCredentials(detail),
    ),
  );
}

StoredCredentials? _rowCredentials(Map<Object?, Object?> detail) {
  final accessToken = _text(detail['AccessToken']);
  final password = _text(detail['Password']);
  if (accessToken.isEmpty && password.isEmpty) {
    return null;
  }
  return StoredCredentials(
    accessToken: accessToken,
    userId: _text(detail['UserId']),
    username: _text(detail['UserName']),
    password: password.isEmpty ? null : password,
  );
}

/// Composes `Host` + `Port` + `Path` into one normalized Emby address. The
/// port is appended only when it differs from the scheme default and the
/// host does not already carry one.
ServerImportLine? _composeLine(
  Object? host,
  Object? port,
  Object? path, {
  String name = '',
}) {
  final raw = host is String ? host.trim() : '';
  if (raw.isEmpty) return null;
  final schemeIndex = raw.indexOf('://');
  final scheme = schemeIndex > 0 ? raw.substring(0, schemeIndex) : 'http';
  var address = schemeIndex > 0 ? raw : 'http://$raw';
  if (port is int && port > 0 && port != (scheme == 'https' ? 443 : 80)) {
    final uri = Uri.tryParse(address);
    if (uri != null && !uri.hasPort) {
      address = '$address:$port';
    }
  }
  if (path is String && path.isNotEmpty) {
    address = '$address${path.startsWith('/') ? path : '/$path'}';
  }
  try {
    return ServerImportLine(
      address: normalizeEmbyBaseUrl(address).toString(),
      name: name.isEmpty ? null : name,
    );
  } on EmbyException {
    return null;
  }
}

String _text(Object? value) => value is String ? value : '';
