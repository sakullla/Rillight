import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/auth/backup_import/backup_crypto.dart';
import 'package:rillight/auth/backup_import/backup_import.dart';
import 'package:rillight/auth/backup_import/backup_import_models.dart';

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
  32,
  (i) => (0x1d * i + 3) & 0xff,
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

Future<List<int>> buildRpbBackup(
  List<Map<String, Object?>> entries, {
  List<int> key = const [],
  bool fixedIvScheme = false,
  bool includeMarkers = true,
  bool includeConfig = true,
  int extraEntries = 0,
}) async {
  final effectiveKey = key.isEmpty ? rpbTestKey : key;
  final iv = fixedIvScheme
      ? effectiveKey.sublist(0, 16)
      : List<int>.generate(16, (i) => 0x30 + i);
  final ciphertext = await encryptAes256Cbc(
    utf8.encode(jsonEncode(entries)),
    effectiveKey,
    iv,
  );
  final body = utf8.encode(
    base64.encode(
      fixedIvScheme ? ciphertext : Uint8List.fromList([...iv, ...ciphertext]),
    ),
  );
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
    test('decrypts config records and ignores plaintext members', () async {
      final bytes = await buildRpbBackup([
        commonEntry(
          type: 'emby',
          name: 'rpb-a',
          url: 'http://192.0.2.30:8096',
          lines: [
            {
              'url': 'https://rpb-line.test.example',
              'name': 'l1',
              'additional_data': null,
            },
          ],
          authorization: authorization(),
        ),
        commonEntry(
          type: 'emby',
          name: 'rpb-b',
          url: 'https://rpb-b.test.example',
        ),
        commonEntry(
          type: 'plex',
          name: 'rpb-c',
          url: 'http://192.0.2.31:32400',
        ),
      ]);
      final result = await parseBackupForImport(bytes, keys: rpbKeys());
      expect(result.format, BackupImportFormat.rodelBackupPackage);
      expect(result.status, BackupImportContainerStatus.ready);
      expect(result.count(BackupRecordStatus.ready), 2);
      expect(result.count(BackupRecordStatus.skippedNonTarget), 1);
      final drafts = result.drafts.toList();
      expect(drafts[0].name, 'rpb-a');
      expect(drafts[0].credentials?.accessToken, 'synthetic-token');
      expect(drafts[0].lines.map((line) => line.address), [
        'http://192.0.2.30:8096',
        'https://rpb-line.test.example',
      ]);
      // history/settings/searchHistory members exist in the fixture but no
      // draft field can carry them.
      expect(drafts.every((draft) => draft.lines.length <= 2), isTrue);
    });

    test('supports the key-derived IV layout', () async {
      final bytes = await buildRpbBackup([
        commonEntry(
          type: 'emby',
          name: 'fixed-iv',
          url: 'http://192.0.2.32:8096',
        ),
      ], fixedIvScheme: true);
      final result = await parseBackupForImport(bytes, keys: rpbKeys());
      expect(result.status, BackupImportContainerStatus.ready);
      expect(result.drafts.single.name, 'fixed-iv');
    });

    test('accepts a configs object wrapper around the record list', () async {
      final iv = rpbTestKey.sublist(0, 16);
      final ciphertext = await encryptAes256Cbc(
        utf8.encode(
          jsonEncode(<String, Object?>{
            'configs': [
              commonEntry(
                type: 'emby',
                name: 'wrapped',
                url: 'http://192.0.2.33:8096',
              ),
            ],
          }),
        ),
        rpbTestKey,
        iv,
      );
      final body = utf8.encode(base64.encode(ciphertext));
      final archive = Archive()
        ..addFile(ArchiveFile('__v2__', 0, Uint8List(0)))
        ..addFile(ArchiveFile('config.json', body.length, body));
      final bytes = Uint8List.fromList(ZipEncoder().encode(archive));
      final result = await parseBackupForImport(bytes, keys: rpbKeys());
      expect(result.status, BackupImportContainerStatus.ready);
      expect(result.drafts.single.name, 'wrapped');
    });

    test(
      'reports the missing native key as an honest gap, not empty success',
      () async {
        final bytes = await buildRpbBackup([
          commonEntry(
            type: 'emby',
            name: 'rpb-a',
            url: 'http://192.0.2.30:8096',
          ),
        ]);
        final result = await parseBackupForImport(bytes);
        expect(result.format, BackupImportFormat.rodelBackupPackage);
        expect(
          result.status,
          BackupImportContainerStatus.decryptionKeyUnavailable,
        );
        expect(result.records, isEmpty);
        expect(result.hasDrafts, isFalse);
      },
    );

    test('treats a wrong key as an undecryptable payload', () async {
      final bytes = await buildRpbBackup([
        commonEntry(type: 'emby', name: 'rpb-a', url: 'http://192.0.2.30:8096'),
      ]);
      final result = await parseBackupForImport(
        bytes,
        keys: rpbKeys(key: hillsWrongKey),
      );
      expect(result.status, BackupImportContainerStatus.undecryptablePayload);
      expect(result.hasDrafts, isFalse);
    });

    test('rejects markerless zips, corrupt zips and missing config', () async {
      final markerless = await buildRpbBackup([
        commonEntry(type: 'emby', name: 'x', url: 'http://192.0.2.34:8096'),
      ], includeMarkers: false);
      expect(
        (await parseBackupForImport(markerless, keys: rpbKeys())).status,
        BackupImportContainerStatus.unrecognizedFormat,
      );
      final noConfig = await buildRpbBackup([
        commonEntry(type: 'emby', name: 'x', url: 'http://192.0.2.34:8096'),
      ], includeConfig: false);
      expect(
        (await parseBackupForImport(noConfig, keys: rpbKeys())).status,
        BackupImportContainerStatus.corruptContainer,
      );
      final truncatedEocd = (await buildRpbBackup([
        commonEntry(type: 'emby', name: 'x', url: 'http://192.0.2.34:8096'),
      ])).sublist(0, 30);
      expect(
        (await parseBackupForImport(truncatedEocd, keys: rpbKeys())).status,
        BackupImportContainerStatus.corruptContainer,
      );
    });

    test('enforces archive entry bounds', () async {
      final bytes = await buildRpbBackup([
        commonEntry(type: 'emby', name: 'rpb-a', url: 'http://192.0.2.30:8096'),
      ], extraEntries: 8);
      final result = await parseBackupForImport(
        bytes,
        keys: rpbKeys(),
        limits: const BackupImportLimits(maxArchiveEntries: 6),
      );
      expect(result.status, BackupImportContainerStatus.sizeLimitExceeded);
      expect(result.hasDrafts, isFalse);
    });
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
