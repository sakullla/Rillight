import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/auth/backup_import/backup_crypto.dart';
import 'package:rillight/auth/backup_import/backup_import.dart';
import 'package:rillight/auth/backup_import/backup_import_models.dart';

bool _probeMaterialsPresent() {
  final base =
      'docs/sakullla-workflow/2026-10-11-字幕完善与Emby配置导入'
      '/evidence/import-materials';
  return File('$base/rpb-probe-sample.rpb').existsSync() &&
      File('$base/KEYS.md').existsSync();
}

// Fixtures are rebuilt synthetically from the verified source-format
// contracts (docs evidence directory, not committed) with test keys and
// TEST-NET addresses only; no real backup, credential or client key appears
// in this repository.
final List<int> hillsTestKey = List<int>.generate(
  32,
  (i) => (0x11 * i + 7) & 0xff,
);
final List<int> hillsWrongKey = List<int>.generate(
  32,
  (i) => (0x07 * i + 11) & 0xff,
);
final List<int> commonTestKey = List<int>.generate(
  32,
  (i) => (0x0b * i + 5) & 0xff,
);
final List<int> rpbTestKey = List<int>.generate(
  16,
  (i) => (0x1d * i + 3) & 0xff,
);
final List<int> rpbWrongKey = List<int>.generate(
  16,
  (i) => (0x05 * i + 17) & 0xff,
);
const selfCarriedTestKey = 'rillight-self-carried-test-key!!';

Map<String, Object?> hillsServer({
  required String displayName,
  required String serverUrl,
  String serverName = '',
  String username = '',
  String password = '',
  String authenticateJson = '',
  List<Map<String, Object?>> routing = const [],
  bool isJellyfin = false,
  bool isPrivate = false,
}) => <String, Object?>{
  // Field order matters: the export drops the first 16 characters
  // `[{"id":<digit>,"displa` of the serialized array, so `id` must stay a
  // single digit directly before `displayName`.
  'id': 0,
  'displayName': displayName,
  'serverName': serverName,
  'serverUrl': serverUrl,
  'username': username,
  'password': password,
  'authenticateJson': authenticateJson,
  'orderIndex': 0,
  'hideUsername': false,
  'iconUrl': null,
  'hideLibraryList': <Object?>[],
  'libraryOrderIndexList': <Object?>[],
  'avatarTag': null,
  'viewSortList': <Object?>[],
  'viewFilterList': <Object?>[],
  'selectedServerRoutingId': '',
  'serverRoutingList': routing,
  'hideFederated': false,
  'isJellyfin': isJellyfin,
  'lastWatchedDate': '',
  'mainRoutingName': '',
  'isActive': true,
  'isPrivate': isPrivate,
  'remark': '',
  'viewCoverTypeList': <Object?>[],
  'strmDirectLinkPlay': false,
  'enableFailover': false,
};

Future<List<int>> buildHillsBackup(
  List<Map<String, Object?>> servers, {
  List<int> key = const [],
}) async {
  final effectiveKey = key.isEmpty ? hillsTestKey : key;
  final full = jsonEncode(servers);
  final truncated = full.substring(16); // the app drops the leading 16 chars
  final iv = List<int>.generate(16, (i) => 0x40 + i);
  final payload = await encryptAes256CbcPrefixedIv(
    utf8.encode(truncated),
    effectiveKey,
    iv,
  );
  return utf8.encode(
    jsonEncode(<String, Object?>{
      'version': 2,
      'data': base64.encode(payload),
      'settings': <String, Object?>{'theme': 'dark'},
      'mpvConf': 'vo=gpu',
      'iconPacks': <Object?>[],
      'customIcons': <Object?>[],
    }),
  );
}

Map<String, Object?> commonEntry({
  required String type,
  required String name,
  required String url,
  List<Map<String, Object?>> lines = const [],
  Map<String, Object?>? authorization,
}) => <String, Object?>{
  'type': type,
  'id': 'synthetic-id-${name.hashCode & 0xffffff}',
  'name': name,
  'url': url,
  'lines': lines,
  'authorization': authorization,
  'create_time': 1766063765,
  'last_update_time': 1791213740,
  'last_play_time': 1791561834,
  'last_open_time': 1779595366,
  'icon': null,
  'sort_order': null,
  'options': null,
};

Future<List<int>> buildCommonConfig(
  List<Map<String, Object?>> entries, {
  String from = 'RodelPlayer',
  String? selfKey,
  List<int> key = const [],
}) async {
  final effectiveKey = selfKey != null
      ? utf8.encode(selfKey)
      : (key.isEmpty ? commonTestKey : key);
  final iv = effectiveKey.sublist(0, 16);
  final configs = <String>[];
  for (final entry in entries) {
    final ciphertext = await encryptAes256Cbc(
      utf8.encode(jsonEncode(entry)),
      effectiveKey,
      iv,
    );
    configs.add(base64.encode(ciphertext));
  }
  return utf8.encode(
    jsonEncode(<String, Object?>{
      'from': from,
      'version': '1.0',
      'export_time': 1791687392,
      'configs': configs,
      'icon_packages': <Object?>[],
      'settings': <String, Object?>{},
      'additional_data': null,
      '_key': selfKey,
    }),
  );
}

Map<String, Object?> authorization({
  String userName = 'synthetic-user',
  String password = 'synthetic-pass',
  String userId = 'synthetic-user-id',
  String accessToken = 'synthetic-token',
}) => <String, Object?>{
  'user_name': userName,
  'password': password,
  'user_id': userId,
  'access_token': accessToken,
  'data': null,
};

/// One sqlite `Config` table row as serialized inside the `.rpb`
/// `config.json` payload; `DetailJson` is a nested JSON string.
Map<String, Object?> rpbRow({
  required String name,
  required String host,
  int port = 8096,
  String path = '',
  String userName = '',
  String userId = '',
  String password = '',
  String accessToken = '',
  List<Map<String, Object?>> backupLines = const [],
  int type = 3,
  String rowId = '0123456789abcdef0123456789abcdef',
}) => <String, Object?>{
  'Id': rowId,
  'Type': type,
  'LastOpenTime': null,
  'CreatedTime': '2026-10-11T00:00:00Z',
  'LastUpdateTime': '2026-10-11T00:00:00Z',
  'LastPlayTime': null,
  'Order': 0,
  'Icon': null,
  'DetailJson': jsonEncode(<String, Object?>{
    'Name': name,
    'UserName': userName,
    'UserId': userId,
    'Host': host,
    'Port': port,
    'Path': path.isEmpty ? null : path,
    'Password': password.isEmpty ? null : password,
    'AccessToken': accessToken.isEmpty ? null : accessToken,
    'BackupLinesJson': backupLines.isEmpty ? null : jsonEncode(backupLines),
    'AutomaticLineSwitching': null,
    'TsTranscode': null,
    'StrmDirectlyPlay': null,
    'StrmUseM3U8': null,
    'ServerDanmaku': null,
    'StripReverseProxyPrefix': null,
    'AppendAuthQueryParameters': null,
    'AutoAppendEmbyPath': null,
    'IncludePlatformInUserAgent': null,
    'TokenRecordTime': null,
    'AuthWithoutPassword': false,
    'CollectionOrder': null,
    'HiddenCollections': null,
    'HappyEyeballsMode': null,
  }),
  'ExcludeAggregateSearch': false,
  'WatchCycle': null,
  'ExtensionData': null,
};

/// Builds a `.rpb` fixture with the verified payload contract:
/// `base64(IV || AES-128-CBC(key, PKCS7))` over the row array JSON with the
/// first 16 serialized characters dropped.
Future<List<int>> buildRpbBackup(
  List<Map<String, Object?>> entries, {
  List<int> key = const [],
  bool includeMarkers = true,
  bool includeConfig = true,
  bool dropHeader = true,
  int extraEntries = 0,
}) async {
  final effectiveKey = key.isEmpty ? rpbTestKey : key;
  final iv = List<int>.generate(16, (i) => 0x30 + i);
  final serialized = jsonEncode(entries);
  final plaintext = utf8.encode(
    dropHeader ? serialized.substring(16) : serialized,
  );
  final blob = await encryptAes128CbcPrefixedIv(plaintext, effectiveKey, iv);
  final body = utf8.encode(base64.encode(blob));
  final archive = Archive();
  if (includeMarkers) {
    archive.addFile(ArchiveFile('__v2__', 0, Uint8List(0)));
    archive.addFile(ArchiveFile('__v3__', 0, Uint8List(0)));
  }
  if (includeConfig) {
    archive.addFile(ArchiveFile('config.json', body.length, body));
  }
  archive.addFile(ArchiveFile('history.json', 2, utf8.encode('[]')));
  archive.addFile(ArchiveFile('searchHistory.json', 2, utf8.encode('[]')));
  archive.addFile(
    ArchiveFile('settings.json', 20, utf8.encode('[{"Key":"K","Value":"V"}]')),
  );
  for (var i = 0; i < extraEntries; i++) {
    archive.addFile(ArchiveFile('pad$i.json', 2, utf8.encode('[]')));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

BackupImportKeys hillsKeys({List<int> key = const []}) =>
    BackupImportKeys(hillsDataKey: key.isEmpty ? hillsTestKey : key);
BackupImportKeys commonKeys() => const BackupImportKeys();
BackupImportKeys tableKeys() =>
    BackupImportKeys(rodelCommonKeysBySource: {'RodelPlayer': commonTestKey});
BackupImportKeys rpbKeys({List<int> key = const []}) =>
    BackupImportKeys(rodelBackupConfigKeys: [key.isEmpty ? rpbTestKey : key]);

void main() {
  group('hills backup json', () {
    test('parses names, accounts, lines and credentials', () async {
      final bytes = await buildHillsBackup([
        hillsServer(
          displayName: 'Synthetic A',
          serverName: 'Server A',
          serverUrl: 'http://192.0.2.10:8096',
          username: 'alice',
          password: 'pw-a',
          authenticateJson: jsonEncode(<String, Object?>{
            'AccessToken': 'token-a',
            'User': {'Id': 'user-a', 'Name': 'alice'},
          }),
          routing: [
            {
              'id': 'r1',
              'url': 'https://a-backup.test.example',
              'name': 'line-a',
              'source': 'manual',
            },
            {
              'id': 'r2',
              'url': 'https://a-backup2.test.example',
              'name': '',
              'source': 'manual',
            },
          ],
        ),
        hillsServer(
          displayName: '',
          serverName: 'Server B',
          serverUrl: 'https://b.test.example/emby',
          username: 'bob',
        ),
        hillsServer(
          displayName: 'Jellyfin C',
          serverUrl: 'http://192.0.2.11:8920',
          isJellyfin: true,
        ),
      ]);
      final result = await parseBackupForImport(bytes, keys: hillsKeys());
      expect(result.format, BackupImportFormat.hillsBackupJson);
      expect(result.status, BackupImportContainerStatus.ready);
      expect(result.count(BackupRecordStatus.ready), 2);
      expect(result.count(BackupRecordStatus.skippedNonTarget), 1);
      expect(result.count(BackupRecordStatus.invalid), 0);

      final drafts = result.drafts.toList();
      expect(drafts[0].name, 'Synthetic A');
      expect(drafts[0].username, 'alice');
      expect(drafts[0].lines.map((line) => line.address), [
        'http://192.0.2.10:8096',
        'https://a-backup.test.example',
        'https://a-backup2.test.example',
      ]);
      expect(drafts[0].lines[1].name, 'line-a');
      expect(drafts[0].lines[2].name, isNull);
      expect(drafts[0].credentials?.accessToken, 'token-a');
      expect(drafts[0].credentials?.userId, 'user-a');
      expect(drafts[0].credentials?.password, 'pw-a');
      expect(drafts[0].isPrivate, isFalse);

      // displayName empty falls back to serverName; no auth material keeps
      // the record as a pending-login draft.
      expect(drafts[1].name, 'Server B');
      expect(drafts[1].lines.single.address, 'https://b.test.example/emby');
      expect(drafts[1].credentials, isNull);

      final skipped = result.records[2];
      expect(skipped.status, BackupRecordStatus.skippedNonTarget);
      expect(skipped.reason, BackupRecordReason.nonTargetServerType);
      expect(skipped.draft, isNull);
    });

    test(
      'keeps same-address accounts and duplicate records independent',
      () async {
        final bytes = await buildHillsBackup([
          hillsServer(
            displayName: 'Acc 1',
            serverUrl: 'http://192.0.2.10:8096',
            username: 'alice',
          ),
          hillsServer(
            displayName: 'Acc 2',
            serverUrl: 'http://192.0.2.10:8096',
            username: 'bob',
          ),
          hillsServer(
            displayName: 'Acc 1',
            serverUrl: 'http://192.0.2.10:8096',
            username: 'alice',
          ),
        ]);
        final result = await parseBackupForImport(bytes, keys: hillsKeys());
        // Deduplication is the commit registry's job; the parser reports every
        // record so the result can present duplicates explicitly.
        expect(result.count(BackupRecordStatus.ready), 3);
        expect(result.drafts.elementAt(0).username, 'alice');
        expect(result.drafts.elementAt(1).username, 'bob');
        expect(result.drafts.elementAt(2).username, 'alice');
      },
    );

    test('propagates the private marker', () async {
      final bytes = await buildHillsBackup([
        hillsServer(
          displayName: 'Private A',
          serverUrl: 'http://192.0.2.12:8096',
          isPrivate: true,
        ),
      ]);
      final result = await parseBackupForImport(bytes, keys: hillsKeys());
      expect(result.drafts.single.isPrivate, isTrue);
    });

    test(
      'reports records without a name or usable line individually',
      () async {
        final bytes = await buildHillsBackup([
          hillsServer(
            displayName: '',
            serverName: '',
            serverUrl: 'http://192.0.2.13:8096',
          ),
          hillsServer(displayName: 'No Url', serverUrl: ''),
          hillsServer(displayName: 'Ok', serverUrl: 'http://192.0.2.14:8096'),
        ]);
        final result = await parseBackupForImport(bytes, keys: hillsKeys());
        expect(result.status, BackupImportContainerStatus.ready);
        expect(result.count(BackupRecordStatus.ready), 1);
        expect(result.count(BackupRecordStatus.invalid), 2);
        expect(
          result.records
              .where((r) => r.status == BackupRecordStatus.invalid)
              .map((r) => r.reason),
          everyElement(BackupRecordReason.missingRequiredFields),
        );
        expect(result.drafts.single.name, 'Ok');
      },
    );

    test(
      'treats a wrong key as an undecryptable payload with zero drafts',
      () async {
        final bytes = await buildHillsBackup([
          hillsServer(displayName: 'A', serverUrl: 'http://192.0.2.10:8096'),
        ]);
        final result = await parseBackupForImport(
          bytes,
          keys: hillsKeys(key: hillsWrongKey),
        );
        expect(result.format, BackupImportFormat.hillsBackupJson);
        expect(result.status, BackupImportContainerStatus.undecryptablePayload);
        expect(result.hasDrafts, isFalse);
        expect(result.records, isEmpty);
      },
    );

    test('reports a missing key instead of an empty success', () async {
      final bytes = await buildHillsBackup([
        hillsServer(displayName: 'A', serverUrl: 'http://192.0.2.10:8096'),
      ]);
      final result = await parseBackupForImport(
        bytes,
        keys: const BackupImportKeys(),
      );
      expect(
        result.status,
        BackupImportContainerStatus.decryptionKeyUnavailable,
      );
      expect(result.hasDrafts, isFalse);
    });

    test('rejects unsupported versions and damaged containers', () async {
      final unsupported = utf8.encode(
        jsonEncode(<String, Object?>{'version': 3, 'data': 'AAAA'}),
      );
      expect(
        (await parseBackupForImport(unsupported, keys: hillsKeys())).status,
        BackupImportContainerStatus.unsupportedVersion,
      );
      final missingData = utf8.encode(
        jsonEncode(<String, Object?>{'version': 2}),
      );
      expect(
        (await parseBackupForImport(missingData, keys: hillsKeys())).status,
        BackupImportContainerStatus.corruptContainer,
      );
      final badBase64 = utf8.encode(
        jsonEncode(<String, Object?>{'version': 2, 'data': '!!!not-base64!!!'}),
      );
      expect(
        (await parseBackupForImport(badBase64, keys: hillsKeys())).status,
        BackupImportContainerStatus.corruptContainer,
      );
      // Well-formed base64 that does not decrypt is an undecryptable
      // payload, distinct from a structurally damaged container.
      final undecryptable = utf8.encode(
        jsonEncode(<String, Object?>{
          'version': 2,
          'data': base64.encode(List<int>.filled(48, 0x41)),
        }),
      );
      expect(
        (await parseBackupForImport(undecryptable, keys: hillsKeys())).status,
        BackupImportContainerStatus.undecryptablePayload,
      );
    });

    test(
      'supports wider id digit widths in the reconstructed header',
      () async {
        // A backup whose first record id has two digits drops a prefix ending
        // mid "displ"; the parser probes that continuation as well.
        final full = jsonEncode([
          hillsServer(displayName: 'Wide', serverUrl: 'http://192.0.2.15:8096'),
        ]).replaceFirst('"id":0,', '"id":42,');
        final iv = List<int>.generate(16, (i) => 0x50 + i);
        final payload = await encryptAes256CbcPrefixedIv(
          utf8.encode(full.substring(16)),
          hillsTestKey,
          iv,
        );
        final bytes = utf8.encode(
          jsonEncode(<String, Object?>{
            'version': 2,
            'data': base64.encode(payload),
          }),
        );
        final result = await parseBackupForImport(bytes, keys: hillsKeys());
        expect(result.status, BackupImportContainerStatus.ready);
        expect(result.drafts.single.name, 'Wide');
      },
    );
  });

  group('rodel common config', () {
    test('parses emby entries with lines and authorization', () async {
      final bytes = await buildCommonConfig([
        commonEntry(
          type: 'emby',
          name: 'synthetic-a',
          url: 'http://192.0.2.20:8096',
          lines: [
            {
              'url': 'https://a-line1.test.example',
              'name': 'l1',
              'additional_data': null,
            },
            {
              'url': 'https://a-line2.test.example',
              'name': 'l2',
              'additional_data': null,
            },
          ],
          authorization: authorization(),
        ),
        commonEntry(
          type: 'jellyfin',
          name: 'not-target',
          url: 'http://192.0.2.21:8920',
        ),
        commonEntry(
          type: 'emby',
          name: 'no-auth',
          url: 'https://b.test.example',
        ),
      ], selfKey: selfCarriedTestKey);
      final result = await parseBackupForImport(bytes);
      expect(result.format, BackupImportFormat.rodelCommonConfig);
      expect(result.status, BackupImportContainerStatus.ready);
      expect(result.count(BackupRecordStatus.ready), 2);
      expect(result.count(BackupRecordStatus.skippedNonTarget), 1);

      final drafts = result.drafts.toList();
      expect(drafts[0].name, 'synthetic-a');
      expect(drafts[0].username, 'synthetic-user');
      expect(drafts[0].lines.map((line) => line.address), [
        'http://192.0.2.20:8096',
        'https://a-line1.test.example',
        'https://a-line2.test.example',
      ]);
      expect(drafts[0].credentials?.accessToken, 'synthetic-token');
      expect(drafts[0].credentials?.userId, 'synthetic-user-id');
      expect(drafts[0].credentials?.password, 'synthetic-pass');
      expect(drafts[1].credentials, isNull);
    });

    test('uses the embedder key table when no key is self-carried', () async {
      final bytes = await buildCommonConfig([
        commonEntry(
          type: 'emby',
          name: 'table-key',
          url: 'http://192.0.2.22:8096',
        ),
      ]);
      final withoutKey = await parseBackupForImport(bytes);
      expect(
        withoutKey.status,
        BackupImportContainerStatus.decryptionKeyUnavailable,
      );
      expect(withoutKey.hasDrafts, isFalse);
      final withKey = await parseBackupForImport(bytes, keys: tableKeys());
      expect(withKey.status, BackupImportContainerStatus.ready);
      expect(withKey.drafts.single.name, 'table-key');
    });

    test('reports undecryptable and invalid entries per record', () async {
      final good = await encryptAes256Cbc(
        utf8.encode(
          jsonEncode(
            commonEntry(
              type: 'emby',
              name: 'ok',
              url: 'http://192.0.2.23:8096',
            ),
          ),
        ),
        commonTestKey,
        commonTestKey.sublist(0, 16),
      );
      final wrongKey = await encryptAes256Cbc(
        utf8.encode(
          jsonEncode(
            commonEntry(
              type: 'emby',
              name: 'no',
              url: 'http://192.0.2.24:8096',
            ),
          ),
        ),
        hillsTestKey,
        hillsTestKey.sublist(0, 16),
      );
      final notAnObject = await encryptAes256Cbc(
        utf8.encode('[1,2]'),
        commonTestKey,
        commonTestKey.sublist(0, 16),
      );
      final bytes = utf8.encode(
        jsonEncode(<String, Object?>{
          'from': 'RodelPlayer',
          'version': '1.0',
          'configs': [
            base64.encode(good),
            base64.encode(wrongKey),
            'not base64!!',
            base64.encode(notAnObject),
          ],
        }),
      );
      final result = await parseBackupForImport(bytes, keys: tableKeys());
      expect(result.status, BackupImportContainerStatus.ready);
      expect(result.count(BackupRecordStatus.ready), 1);
      final invalid = result.records
          .where((record) => record.status == BackupRecordStatus.invalid)
          .toList();
      expect(invalid.length, 3);
      expect(
        invalid.map((record) => record.reason),
        containsAll([
          BackupRecordReason.undecryptableRecord,
          BackupRecordReason.malformedRecord,
        ]),
      );
    });

    test('rejects unsupported versions', () async {
      final bytes = utf8.encode(
        jsonEncode(<String, Object?>{
          'from': 'RodelPlayer',
          'version': '2.0',
          'configs': <Object?>[],
        }),
      );
      expect(
        (await parseBackupForImport(bytes, keys: tableKeys())).status,
        BackupImportContainerStatus.unsupportedVersion,
      );
    });
  });

  group('rodel backup package', () {
    test('decrypts config rows and ignores plaintext members', () async {
      final bytes = await buildRpbBackup([
        rpbRow(
          name: 'rpb-a',
          host: 'http://192.0.2.30',
          port: 8096,
          userName: 'synthetic-user',
          userId: 'synthetic-user-id',
          password: 'synthetic-pass',
          accessToken: 'synthetic-token',
          backupLines: [
            {
              'Id': 'line-1',
              'Name': 'l1',
              'Host': 'https://rpb-line.test.example',
              'Port': 443,
              'Path': '',
            },
          ],
        ),
        rpbRow(name: 'rpb-b', host: 'https://rpb-b.test.example', port: 443),
        rpbRow(name: 'rpb-c', host: 'http://192.0.2.31', port: 32400, type: 4),
      ]);
      final result = await parseBackupForImport(bytes, keys: rpbKeys());
      expect(result.format, BackupImportFormat.rodelBackupPackage);
      expect(result.status, BackupImportContainerStatus.ready);
      expect(result.count(BackupRecordStatus.ready), 2);
      expect(result.count(BackupRecordStatus.skippedNonTarget), 1);
      final drafts = result.drafts.toList();
      expect(drafts[0].name, 'rpb-a');
      expect(drafts[0].username, 'synthetic-user');
      expect(drafts[0].credentials?.accessToken, 'synthetic-token');
      expect(drafts[0].credentials?.userId, 'synthetic-user-id');
      expect(drafts[0].credentials?.password, 'synthetic-pass');
      expect(drafts[0].lines.map((line) => line.address), [
        'http://192.0.2.30:8096',
        'https://rpb-line.test.example',
      ]);
      expect(drafts[0].lines[1].name, 'l1');
      // history/settings/searchHistory members exist in the fixture but no
      // draft field can carry them.
      expect(drafts[1].credentials, isNull);
      final skipped = result.records[2];
      expect(skipped.status, BackupRecordStatus.skippedNonTarget);
      expect(skipped.reason, BackupRecordReason.nonTargetServerType);
    });

    test('composes host, port and path into normalized addresses', () async {
      final bytes = await buildRpbBackup([
        rpbRow(name: 'custom-port', host: 'http://192.0.2.31', port: 27367),
        rpbRow(
          name: 'default-port',
          host: 'https://rpb-default.test.example',
          port: 443,
          path: '/',
        ),
        rpbRow(name: 'no-scheme', host: '192.0.2.32', port: 8096),
        rpbRow(
          name: 'sub-path',
          host: 'https://rpb-path.test.example',
          port: 443,
          path: '/emby',
        ),
      ]);
      final result = await parseBackupForImport(bytes, keys: rpbKeys());
      expect(result.status, BackupImportContainerStatus.ready);
      expect(result.drafts.map((draft) => draft.lines.first.address).toList(), [
        'http://192.0.2.31:27367',
        'https://rpb-default.test.example',
        'http://192.0.2.32:8096',
        'https://rpb-path.test.example/emby',
      ]);
    });

    test(
      'reports the missing native key as an honest gap, not empty success',
      () async {
        final bytes = await buildRpbBackup([
          rpbRow(name: 'rpb-a', host: 'http://192.0.2.30', port: 8096),
        ]);
        final result = await parseBackupForImport(bytes);
        expect(result.format, BackupImportFormat.rodelBackupPackage);
        expect(
          result.status,
          BackupImportContainerStatus.decryptionKeyUnavailable,
        );
        expect(result.records, isEmpty);
        expect(result.hasDrafts, isFalse);
        // The verified contract is AES-128; a 32-byte candidate is not a
        // usable key and must not silently downgrade the report.
        final wideKey = await parseBackupForImport(
          bytes,
          keys: BackupImportKeys(rodelBackupConfigKeys: [hillsTestKey]),
        );
        expect(
          wideKey.status,
          BackupImportContainerStatus.decryptionKeyUnavailable,
        );
      },
    );

    test('treats a wrong key as an undecryptable payload', () async {
      final bytes = await buildRpbBackup([
        rpbRow(name: 'rpb-a', host: 'http://192.0.2.30', port: 8096),
      ]);
      final result = await parseBackupForImport(
        bytes,
        keys: rpbKeys(key: rpbWrongKey),
      );
      expect(result.status, BackupImportContainerStatus.undecryptablePayload);
      expect(result.hasDrafts, isFalse);
    });

    test('rejects markerless zips, corrupt zips and missing config', () async {
      final markerless = await buildRpbBackup([
        rpbRow(name: 'x', host: 'http://192.0.2.34', port: 8096),
      ], includeMarkers: false);
      expect(
        (await parseBackupForImport(markerless, keys: rpbKeys())).status,
        BackupImportContainerStatus.unrecognizedFormat,
      );
      final noConfig = await buildRpbBackup([
        rpbRow(name: 'x', host: 'http://192.0.2.34', port: 8096),
      ], includeConfig: false);
      expect(
        (await parseBackupForImport(noConfig, keys: rpbKeys())).status,
        BackupImportContainerStatus.corruptContainer,
      );
      final truncatedEocd = (await buildRpbBackup([
        rpbRow(name: 'x', host: 'http://192.0.2.34', port: 8096),
      ])).sublist(0, 30);
      expect(
        (await parseBackupForImport(truncatedEocd, keys: rpbKeys())).status,
        BackupImportContainerStatus.corruptContainer,
      );
    });

    test('enforces archive entry bounds', () async {
      final bytes = await buildRpbBackup([
        rpbRow(name: 'rpb-a', host: 'http://192.0.2.30', port: 8096),
      ], extraEntries: 8);
      final result = await parseBackupForImport(
        bytes,
        keys: rpbKeys(),
        limits: const BackupImportLimits(maxArchiveEntries: 6),
      );
      expect(result.status, BackupImportContainerStatus.sizeLimitExceeded);
      expect(result.hasDrafts, isFalse);
    });

    test(
      'parses the authorized probe sample end to end',
      () async {
        // The probe sample and the real key live only in the local,
        // git-ignored evidence directory (they must not be committed); the
        // synthetic fixture tests above cover committed coverage.
        final sample = File(
          'docs/sakullla-workflow/2026-10-11-字幕完善与Emby配置导入'
          '/evidence/import-materials/rpb-probe-sample.rpb',
        );
        final keysDoc = File(
          'docs/sakullla-workflow/2026-10-11-字幕完善与Emby配置导入'
          '/evidence/import-materials/KEYS.md',
        );
        final keyHex = RegExp(
          r'\.rpb `config\.json`[^`]*`([0-9a-f]{32})`',
        ).firstMatch(keysDoc.readAsStringSync())!.group(1)!;
        final key = [
          for (var i = 0; i < 32; i += 2)
            int.parse(keyHex.substring(i, i + 2), radix: 16),
        ];
        final result = await parseBackupForImport(
          sample.readAsBytesSync(),
          keys: BackupImportKeys(rodelBackupConfigKeys: [key]),
        );
        expect(result.status, BackupImportContainerStatus.ready);
        final draft = result.drafts.single;
        expect(draft.name, 'KEYTEST-AAAA');
        expect(draft.username, 'probe');
        expect(draft.lines.single.address, 'http://198.51.100.1:8096');
        expect(draft.credentials, isNull);
      },
      skip: _probeMaterialsPresent()
          ? false
          : '探针样本与密钥文档仅存在于本机 evidence 目录(不入仓)',
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });

  group('container detection', () {
    test('reports unknown input and oversized input without drafts', () async {
      expect(
        (await parseBackupForImport(utf8.encode('not a backup'))).status,
        BackupImportContainerStatus.unrecognizedFormat,
      );
      expect(
        (await parseBackupForImport(utf8.encode('{"unrelated": true}'))).status,
        BackupImportContainerStatus.unrecognizedFormat,
      );
      final big = List<int>.filled(16, 0x00);
      expect(
        (await parseBackupForImport(
          big,
          limits: const BackupImportLimits(maxInputBytes: 4),
        )).status,
        BackupImportContainerStatus.sizeLimitExceeded,
      );
    });
  });
}
