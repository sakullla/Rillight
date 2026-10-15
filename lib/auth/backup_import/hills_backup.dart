import '../../media_server/capabilities.dart';

import 'dart:convert';

import '../../media_server/errors.dart';
import '../../media_server/server_address.dart';
import '../credential_store.dart';
import '../server_import_models.dart';
import 'backup_crypto.dart';
import 'backup_import_models.dart';

/// Parser for the Hills backup JSON (version 2). Hills Lite 1.5.4 and the
/// Rodel "Hills" export use the same container, so both enter here.
///
/// Verified contract: the top-level `data` field holds
/// `base64(IV(16) || AES-256-CBC(PKCS7))` whose plaintext is the server array
/// JSON minus its first 16 characters — both exporting apps drop the prefix
/// `[{"id":<digits>,"displa` of `displayName`. The removed id digits carry no
/// import meaning, so every observed digit width is probed during
/// reconstruction. Only `data` is consumed; settings, mpvConf, icon packs and
/// custom icons never reach a draft.
const List<String> _hillsHeaderCandidates = [
  '[{"id":0,"displa',
  '[{"id":10,"displ',
  '[{"id":100,"disp',
];

Future<BackupImportParseResult> parseHillsBackupJson(
  Map<String, dynamic> document,
  BackupImportKeys keys,
) async {
  if (document['version'] != 2) {
    return const BackupImportParseResult(
      format: BackupImportFormat.hillsBackupJson,
      status: BackupImportContainerStatus.unsupportedVersion,
    );
  }
  final data = document['data'];
  if (data is! String) {
    return const BackupImportParseResult(
      format: BackupImportFormat.hillsBackupJson,
      status: BackupImportContainerStatus.corruptContainer,
    );
  }
  final key = keys.hillsDataKey;
  if (key == null || key.length != 32) {
    return const BackupImportParseResult(
      format: BackupImportFormat.hillsBackupJson,
      status: BackupImportContainerStatus.decryptionKeyUnavailable,
    );
  }
  final ciphertext = tryDecodeBase64(data);
  if (ciphertext == null) {
    return const BackupImportParseResult(
      format: BackupImportFormat.hillsBackupJson,
      status: BackupImportContainerStatus.corruptContainer,
    );
  }
  final clear = await tryDecryptAes256CbcPrefixedIv(key, ciphertext);
  if (clear == null) {
    return const BackupImportParseResult(
      format: BackupImportFormat.hillsBackupJson,
      status: BackupImportContainerStatus.undecryptablePayload,
    );
  }
  String body;
  try {
    body = utf8.decode(clear);
  } on FormatException {
    return const BackupImportParseResult(
      format: BackupImportFormat.hillsBackupJson,
      status: BackupImportContainerStatus.undecryptablePayload,
    );
  }
  List<dynamic>? servers;
  for (final header in _hillsHeaderCandidates) {
    try {
      final decoded = jsonDecode(header + body);
      // A wrong digit width still parses as JSON but mangles the second field
      // name (e.g. `displaayName`), so acceptance additionally requires the
      // reconstructed first record to carry the schema's `displayName`.
      if (decoded is List &&
          (decoded.isEmpty ||
              (decoded.first is Map &&
                  (decoded.first as Map).containsKey('displayName')))) {
        servers = decoded;
        break;
      }
    } on FormatException {
      // Try the next id-digit width.
    }
  }
  if (servers == null) {
    return const BackupImportParseResult(
      format: BackupImportFormat.hillsBackupJson,
      status: BackupImportContainerStatus.undecryptablePayload,
    );
  }
  return BackupImportParseResult(
    format: BackupImportFormat.hillsBackupJson,
    status: BackupImportContainerStatus.ready,
    records: [
      for (var i = 0; i < servers.length; i++) _mapHillsServer(i, servers[i]),
    ],
  );
}

BackupRecordOutcome _mapHillsServer(int index, Object? entry) {
  if (entry is! Map) {
    return BackupRecordOutcome(
      index: index,
      status: BackupRecordStatus.invalid,
      reason: BackupRecordReason.malformedRecord,
    );
  }
  final displayName = _text(entry['displayName']);
  final name = displayName.isNotEmpty
      ? displayName
      : _text(entry['serverName']);
  final username = _text(entry['username']);

  final lines = <ServerImportLine>[];
  final primary = _normalizeLine(_text(entry['serverUrl']));
  if (primary != null) {
    lines.add(primary);
  }
  final routing = entry['serverRoutingList'];
  if (routing is List) {
    for (final route in routing) {
      if (route is! Map) continue;
      final line = _normalizeLine(_text(route['url']), _text(route['name']));
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
      serviceType: entry['isJellyfin'] == true
          ? MediaServerType.jellyfin
          : MediaServerType.emby,
      name: name,
      username: username,
      lines: List.unmodifiable(lines),
      credentials: _hillsCredentials(entry, username),
      isPrivate: entry['isPrivate'] == true,
    ),
  );
}

StoredCredentials? _hillsCredentials(Map entry, String username) {
  var accessToken = '';
  var userId = '';
  var accountName = username;
  final password = _text(entry['password']);
  final authJson = _text(entry['authenticateJson']);
  if (authJson.isNotEmpty) {
    try {
      final auth = jsonDecode(authJson);
      if (auth is Map) {
        accessToken = _text(auth['AccessToken']);
        final user = auth['User'];
        if (user is Map) {
          userId = _text(user['Id']);
          if (accountName.isEmpty) {
            accountName = _text(user['Name']);
          }
        }
      }
    } on FormatException {
      // Keep whatever password-only material the record carries.
    }
  }
  if (accessToken.isEmpty && password.isEmpty) {
    return null;
  }
  return StoredCredentials(
    serviceType: entry['isJellyfin'] == true
        ? MediaServerType.jellyfin
        : MediaServerType.emby,
    accessToken: accessToken,
    userId: userId,
    username: accountName,
    password: password.isEmpty ? null : password,
  );
}

ServerImportLine? _normalizeLine(String raw, [String name = '']) {
  if (raw.isEmpty) return null;
  try {
    return ServerImportLine(
      address: normalizeServerAddress(raw).toString(),
      name: name.isEmpty ? null : name,
    );
  } on MediaServerException {
    return null;
  }
}

String _text(Object? value) => value is String ? value : '';
