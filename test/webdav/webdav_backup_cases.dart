import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/webdav/webdav_backup.dart';

const _serversDoc = <String, Object?>{
  'version': 3,
  'servers': [
    {
      'id': 'srv-a',
      'name': 'media-a',
      'lines': [
        {'id': 'line-a', 'url': 'http://192.0.2.21:8096'},
      ],
    },
    {
      'id': 'srv-b',
      'name': 'media-b',
      'lines': [
        {'id': 'line-b', 'url': 'http://192.0.2.22:8096'},
      ],
    },
  ],
  'lastServerId': 'srv-a',
};

const _pinDoc = <String, Object?>{
  'version': 1,
  'salt': 'synthetic-salt',
  'verifier': 'synthetic-verifier',
};

const _webdavDoc = <String, Object?>{
  'address': 'http://192.0.2.10:5005/dav',
  'username': 'user',
  'password': 'pass',
  'directory': 'rillight',
};

const _playerSettingsDoc = <String, Object?>{
  'volume': 0.7,
  'audioTrack': 'chn',
};

const _phoneNavDoc = <String, Object?>{
  'order': ['home', 'library'],
};

const _recentSearchesDoc = <String, Object?>{
  'queries': ['cats', 'dogs'],
};

const _credA = StoredCredentials(
  accessToken: 'synthetic-token-a',
  userId: 'user-a',
  username: 'alice',
);

const _credB = StoredCredentials(
  accessToken: 'synthetic-token-b',
  userId: 'user-b',
  username: 'bob',
  password: 'secret-b',
);

const _credGhost = StoredCredentials(
  accessToken: 'synthetic-token-ghost',
  userId: 'user-ghost',
  username: 'ghost',
);

Future<Directory> _stage(String prefix) async {
  final dir = await Directory.systemTemp.createTemp(prefix);
  addTearDown(() => dir.delete(recursive: true));
  return dir;
}

Future<void> _writeDoc(Directory dir, String name, Map<String, Object?> doc) =>
    File('${dir.path}/$name').writeAsString(jsonEncode(doc));

/// Builds the on-disk source state: servers, credentials (including one for a
/// server no longer listed), three of six prefs, pin, webdav config, plus the
/// excluded device_id and catalog_cache content.
Future<(Directory, MemoryCredentialStore)> _stageSource() async {
  final dir = await _stage('rillight_webdav_src');
  await _writeDoc(dir, 'servers.json', _serversDoc);
  await _writeDoc(dir, 'player_settings.json', _playerSettingsDoc);
  await _writeDoc(dir, 'phone_nav.json', _phoneNavDoc);
  await _writeDoc(dir, 'recent_searches.json', _recentSearchesDoc);
  await _writeDoc(dir, 'private_pin.json', _pinDoc);
  await _writeDoc(dir, 'webdav.json', _webdavDoc);
  await File('${dir.path}/device_id').writeAsString('device-secret');
  final cache = Directory('${dir.path}/catalog_cache');
  await cache.create(recursive: true);
  await File('${cache.path}/item-1.json').writeAsString('{"stale":true}');
  final store = MemoryCredentialStore(<String, StoredCredentials>{
    'srv-a': _credA,
    'srv-b': _credB,
    'srv-ghost': _credGhost,
  });
  return (dir, store);
}

Future<Map<String, dynamic>> _readDoc(Directory dir, String name) async {
  final decoded = jsonDecode(await File('${dir.path}/$name').readAsString());
  return Map<String, dynamic>.from(decoded as Map);
}

void main() {
  group('collect', () {
    test(
      'captures servers, listed credentials, prefs, pin and webdav config',
      () async {
        final (dir, store) = await _stageSource();
        final bundle = await collectBackupBundle(dir, store);
        expect(bundle['format'], 'rillight-backup');
        expect(bundle['version'], 1);
        expect(bundle['created_at'], isA<int>());
        expect(bundle['created_at'] as int, greaterThan(0));
        expect(bundle['servers'], _serversDoc);
        expect(bundle['credentials'].keys, {'srv-a', 'srv-b'});
        expect(bundle['credentials']['srv-a'], _credA.toJson());
        expect(bundle['credentials']['srv-b'], _credB.toJson());
        expect(bundle['pin'], _pinDoc);
        expect(bundle['webdav'], _webdavDoc);
        expect(bundle['prefs'].keys, {
          'player_settings',
          'phone_nav',
          'recent_searches',
        });
        expect(bundle['prefs']['player_settings'], _playerSettingsDoc);
        expect(bundle['prefs']['phone_nav'], _phoneNavDoc);
        expect(bundle['prefs']['recent_searches'], _recentSearchesDoc);
      },
    );

    test(
      'never contains device_id, catalog_cache or unlisted credentials',
      () async {
        final (dir, store) = await _stageSource();
        final encoded = jsonEncode(await collectBackupBundle(dir, store));
        expect(encoded.contains('device-secret'), isFalse);
        expect(encoded.contains('catalog_cache'), isFalse);
        expect(encoded.contains('stale'), isFalse);
        expect(encoded.contains('srv-ghost'), isFalse);
        expect(encoded.contains('synthetic-token-ghost'), isFalse);
      },
    );

    test('missing prefs files are simply absent, not errors', () async {
      final dir = await _stage('rillight_webdav_src');
      await _writeDoc(dir, 'servers.json', _serversDoc);
      final bundle = await collectBackupBundle(dir, MemoryCredentialStore());
      expect(bundle['prefs'], isEmpty);
      expect(bundle.containsKey('pin'), isFalse);
      expect(bundle.containsKey('webdav'), isFalse);
    });
  });

  group('validate', () {
    test('accepts a collected bundle', () async {
      final (dir, store) = await _stageSource();
      final bytes = utf8.encode(
        jsonEncode(await collectBackupBundle(dir, store)),
      );
      final result = validateBackupBundle(bytes);
      expect(result, isA<WebDavBundleValid>());
      expect((result as WebDavBundleValid).bundle['format'], 'rillight-backup');
    });

    test('rejects an unknown format', () {
      final bytes = utf8.encode(jsonEncode({'format': 'other', 'version': 1}));
      expect(
        validateBackupBundle(bytes),
        isA<WebDavBundleInvalid>().having(
          (v) => v.error,
          'error',
          WebDavBackupError.unknownFormat,
        ),
      );
    });

    test('rejects an unsupported version', () async {
      final (dir, store) = await _stageSource();
      final bundle = await collectBackupBundle(dir, store);
      bundle['version'] = 2;
      final result = validateBackupBundle(utf8.encode(jsonEncode(bundle)));
      expect(result, isA<WebDavBundleInvalid>());
      expect(
        (result as WebDavBundleInvalid).error,
        WebDavBackupError.unsupportedVersion,
      );
    });

    test('rejects truncated JSON as malformed', () async {
      final (dir, store) = await _stageSource();
      final text = jsonEncode(await collectBackupBundle(dir, store))
          .substring(0, 40);
      final result = validateBackupBundle(utf8.encode(text));
      expect(result, isA<WebDavBundleInvalid>());
      expect(
        (result as WebDavBundleInvalid).error,
        WebDavBackupError.malformed,
      );
    });
  });

  group('apply', () {
    test('roundtrips a collected bundle into a fresh directory', () async {
      final (source, store) = await _stageSource();
      final bundle = await collectBackupBundle(source, store);
      final target = await _stage('rillight_webdav_dst');
      final junkCache = Directory('${target.path}/catalog_cache');
      await junkCache.create(recursive: true);
      await File('${junkCache.path}/stale.json').writeAsString('{"old":1}');
      final restored = MemoryCredentialStore();

      final result = await applyBackupBundle(bundle, target, restored);

      expect(result, isA<WebDavApplySuccess>());
      expect((result as WebDavApplySuccess).needsReload, isTrue);
      expect(await _readDoc(target, 'servers.json'), _serversDoc);
      expect(
        await _readDoc(target, 'player_settings.json'),
        _playerSettingsDoc,
      );
      expect(await _readDoc(target, 'phone_nav.json'), _phoneNavDoc);
      expect(
        await _readDoc(target, 'recent_searches.json'),
        _recentSearchesDoc,
      );
      expect(await _readDoc(target, 'private_pin.json'), _pinDoc);
      expect(await _readDoc(target, 'webdav.json'), _webdavDoc);
      expect(
        File('${target.path}/tv_home_sections.json').existsSync(),
        isFalse,
      );
      expect((await restored.read('srv-a'))!.toJson(), _credA.toJson());
      expect((await restored.read('srv-b'))!.toJson(), _credB.toJson());
      expect(junkCache.listSync(), isEmpty);
    });

    test('rejected version leaves the target untouched', () async {
      final (source, store) = await _stageSource();
      final bundle = await collectBackupBundle(source, store);
      bundle['version'] = 99;
      final target = await _stage('rillight_webdav_dst');
      await _writeDoc(target, 'servers.json', {'keep': true});

      final result = await applyBackupBundle(bundle, target, store);

      expect(result, isA<WebDavApplyRejected>());
      expect(
        (result as WebDavApplyRejected).error,
        WebDavBackupError.unsupportedVersion,
      );
      expect(await _readDoc(target, 'servers.json'), {'keep': true});
      expect(File('${target.path}/webdav.json').existsSync(), isFalse);
      expect(File('${target.path}/private_pin.json').existsSync(), isFalse);
      expect(target.listSync(), hasLength(1));
    });

    test('malformed credential entries reject with zero writes', () async {
      final target = await _stage('rillight_webdav_dst');
      await _writeDoc(target, 'servers.json', {'keep': true});
      final bundle = <String, dynamic>{
        'format': 'rillight-backup',
        'version': 1,
        'created_at': 1700000000,
        'servers': _serversDoc,
        'credentials': {
          'srv-a': {'version': 2, 'userId': 'user-a', 'username': 'alice'},
        },
        'prefs': <String, dynamic>{},
      };

      final result = await applyBackupBundle(
        bundle,
        target,
        MemoryCredentialStore(),
      );

      expect(result, isA<WebDavApplyRejected>());
      expect(
        (result as WebDavApplyRejected).error,
        WebDavBackupError.malformed,
      );
      expect(await _readDoc(target, 'servers.json'), {'keep': true});
      expect(target.listSync(), hasLength(1));
    });

    test('bytes entrypoint validates before applying', () async {
      final (source, store) = await _stageSource();
      final bytes = utf8.encode(
        jsonEncode(await collectBackupBundle(source, store)),
      );
      final target = await _stage('rillight_webdav_dst');
      final result = await applyBackupBundleBytes(
        bytes,
        target,
        MemoryCredentialStore(),
      );
      expect(result, isA<WebDavApplySuccess>());
      expect(await _readDoc(target, 'servers.json'), _serversDoc);

      final rejected = await applyBackupBundleBytes(
        utf8.encode('{"format":'),
        target,
        MemoryCredentialStore(),
      );
      expect(rejected, isA<WebDavApplyRejected>());
    });
  });
}
