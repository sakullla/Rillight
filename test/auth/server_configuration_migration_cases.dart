import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_access.dart';
import 'package:rillight/auth/region_access.dart' show PinVerifier;
import 'package:rillight/auth/server_configuration_migration.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/media_server/capabilities.dart';
import 'package:rillight/media_server/authentication.dart';

Map<String, dynamic> _legacy({int? version, bool missingActive = false}) => {
  'version': ?version,
  'lastServerId': 'plex',
  'servers': [
    for (final provider in ['plex', 'emby', 'jellyfin'])
      {
        'id': provider,
        'name': 'Name $provider',
        'nickname': 'Alias $provider',
        'username': 'user-$provider',
        'serviceType': provider,
        'authorizationMethod': provider == 'plex' ? 'browserPin' : 'password',
        'verifiedServerId': 'remote-$provider',
        'region': provider == 'emby' ? 'ordinary' : 'private',
        'cloudCredentialRef': provider == 'plex' ? 'cloud-ref' : null,
        'resourceCredentialRef': provider == 'plex' ? 'resource-ref' : null,
        'cloudAccountId': provider == 'plex' ? 'cloud-user' : null,
        'homeUserId': provider == 'plex' ? 'home-user' : null,
        'libraryIds': ['library'],
        'scopeKnown': true,
        if (!missingActive) 'activeLineId': 'wan',
        'lines': [
          {
            'id': 'lan',
            'address': 'http://$provider.test:8096/prefix',
            'nickname': 'LAN',
          },
          {
            'id': 'wan',
            'address': 'https://$provider.example/path',
            'nickname': 'WAN',
            'userAgent': 'custom/$provider',
          },
        ],
      },
  ],
};

class _FailingAccessStore extends MemoryServerAccessStore {
  bool fail = true;
  @override
  Future<void> write(String reference, ServerAccessRecord record) async {
    if (fail && records.isNotEmpty) {
      throw StateError('secure storage unavailable');
    }
    await super.write(reference, record);
  }
}

void main() {
  late Directory directory;
  late File file;
  late MemoryCredentialStore credentials;
  late Map<String, dynamic> verifier;
  setUpAll(() async {
    verifier = (await PinVerifier.create('1234')).toJson();
  });
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('rillight-migration-');
    file = File('${directory.path}/servers.json');
    credentials = MemoryCredentialStore({
      for (final provider in MediaServerType.values)
        provider.name: StoredCredentials(
          accessToken: 'secret-${provider.name}',
          userId: 'user-${provider.name}',
          username: 'name',
          serviceType: provider,
          authorizationMethod: provider == MediaServerType.plex
              ? AuthorizationMethod.browserPin
              : AuthorizationMethod.password,
        ),
    });
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test(
    'unversioned single-address source migrates to fixed default line',
    () async {
      await file.writeAsString(
        jsonEncode({
          'servers': [
            {
              'id': 'emby',
              'name': 'legacy',
              'username': 'user',
              'baseUrl': 'https://emby.test:8920/subpath',
            },
          ],
        }),
      );
      final result = await ServerConfigurationMigration(
        configuration: file,
        credentials: credentials,
        accessStore: MemoryServerAccessStore(),
        readLegacyVerifier: () async => null,
      ).migrate();
      expect(
        result.snapshot.servers.single.lineSelection,
        const LineSelection.fixed('default'),
      );
      expect(
        result.snapshot.servers.single.baseUrl,
        'https://emby.test:8920/subpath',
      );
    },
  );

  test(
    'completion marker cannot turn a missing configuration into an empty list',
    () async {
      await file.writeAsString(jsonEncode(_legacy(version: 3)));
      final migration = ServerConfigurationMigration(
        configuration: file,
        credentials: credentials,
        accessStore: MemoryServerAccessStore(),
        readLegacyVerifier: () async => verifier,
      );
      await migration.migrate();
      final original = await migration.backup.readAsString();
      await file.delete();
      await expectLater(migration.migrate(), throwsFormatException);
      await expectLater(
        FileServerListStore(file).load(),
        throwsFormatException,
      );
      await expectLater(
        FileServerListStore(file).save(const ServerListSnapshot(servers: [])),
        throwsFormatException,
      );
      expect(await migration.backup.readAsString(), original);
      expect(await file.exists(), isFalse);
    },
  );

  test('all legacy versions retain three provider identities, lines, credentials and order', () async {
    for (final version in [null, 1, 2, 3]) {
      final source = File('${directory.path}/servers-$version.json');
      final original = jsonEncode(_legacy(version: version));
      await source.writeAsString(original);
      final accessStore = MemoryServerAccessStore();
      final migration = ServerConfigurationMigration(
        configuration: source,
        credentials: credentials,
        accessStore: accessStore,
        readLegacyVerifier: () async => verifier,
      );
      final result = await migration.migrate();
      expect(result.snapshot.servers.map((s) => s.id), [
        'emby',
        'plex',
        'jellyfin',
      ]);
      expect(result.snapshot.lastServerId, 'plex');
      expect(await migration.backup.readAsString(), original);
      expect(result.unavailableProtectionIds, isEmpty);
      final controller = ServerAccessController(store: accessStore);
      for (final server in result.snapshot.servers) {
        expect(server.lineSelection, const LineSelection.fixed('wan'));
        expect(server.activeLineId, 'wan');
        expect(server.lines.map((line) => line.id), ['lan', 'wan']);
        expect(
          server.lines.first.address,
          'http://${server.id}.test:8096/prefix',
        );
        expect(server.normalizedUserAgent, 'custom/${server.id}');
        expect(server.expectedServerId, 'remote-${server.id}');
        expect(server.displayName, 'Alias ${server.id}');
        final credential = await credentials.read(
          server.effectiveCredentialRef,
        );
        expect(credential!.accessToken, 'secret-${server.id}');
        await controller.register(server);
        if (server.id != 'emby') {
          expect(controller.allows(server.id), isFalse);
          expect(await controller.unlock(server.id, '1234'), isTrue);
        }
      }
      controller.dispose();
      final plex = result.snapshot.servers[1];
      expect(plex.cloudCredentialRef, 'cloud-ref');
      expect(plex.resourceCredentialRef, 'resource-ref');
      expect(plex.homeUserId, 'home-user');
      expect(plex.cloudAccountId, 'cloud-user');
      await FileServerListStore(source).save(result.snapshot);
      final persisted = jsonDecode(await source.readAsString()) as Map;
      expect(persisted['version'], 4);
      expect(
        (persisted['servers'] as List)[1]['protectionRef'],
        plex.protectionRef,
      );
      expect((persisted['servers'] as List)[1].containsKey('region'), isFalse);
      expect(
        (await migration.migrate()).snapshot.servers[1].protectionRef,
        plex.protectionRef,
      );
    }
  });

  test(
    'interrupted protection writes retain original and resume idempotently',
    () async {
      final original = jsonEncode(_legacy(version: 3));
      await file.writeAsString(original);
      final store = _FailingAccessStore();
      final migration = ServerConfigurationMigration(
        configuration: file,
        credentials: credentials,
        accessStore: store,
        readLegacyVerifier: () async => verifier,
      );
      await expectLater(migration.migrate(), throwsStateError);
      expect(await file.readAsString(), original);
      expect(await migration.backup.readAsString(), original);
      final first = store.records.values.single;
      store.fail = false;
      final result = await migration.migrate();
      expect(result.snapshot.servers, hasLength(3));
      expect(store.records.values.first, same(first));
      expect(store.records, hasLength(2));
      expect(
        jsonDecode(await migration.journal.readAsString())['stage'],
        'complete',
      );
    },
  );

  test('crashes before and after publication are retryable without empty overwrite', () async {
    for (final stop in [
      'prepared',
      'protection-ready',
      'configuration-published',
    ]) {
      final source = File('${directory.path}/$stop.json');
      final original = jsonEncode(_legacy(version: 2));
      await source.writeAsString(original);
      final store = MemoryServerAccessStore();
      final interrupted = ServerConfigurationMigration(
        configuration: source,
        credentials: credentials,
        accessStore: store,
        readLegacyVerifier: () async => verifier,
        checkpoint: (step) async {
          if (step == stop) throw StateError('interrupted');
        },
      );
      await expectLater(interrupted.migrate(), throwsStateError);
      expect(await interrupted.backup.readAsString(), original);
      final resumed = ServerConfigurationMigration(
        configuration: source,
        credentials: credentials,
        accessStore: store,
        readLegacyVerifier: () async => verifier,
      );
      expect((await resumed.migrate()).snapshot.servers, hasLength(3));
    }
  });

  test(
    'missing or damaged legacy PIN keeps former private entries inaccessible',
    () async {
      for (final damaged in [false, true]) {
        final source = File('${directory.path}/missing-$damaged.json');
        await source.writeAsString(jsonEncode(_legacy(version: 3)));
        final store = MemoryServerAccessStore();
        final result = await ServerConfigurationMigration(
          configuration: source,
          credentials: credentials,
          accessStore: store,
          readLegacyVerifier: () async => damaged ? {'version': 1} : null,
        ).migrate();
        expect(result.unavailableProtectionIds, ['plex', 'jellyfin']);
        final controller = ServerAccessController(store: store);
        for (final server in result.snapshot.servers) {
          await controller.register(server);
          expect(controller.allows(server.id), server.id == 'emby');
        }
        controller.dispose();
      }
    },
  );

  test(
    'missing active line and malformed config fail without replacing original',
    () async {
      for (final original in [
        jsonEncode(_legacy(missingActive: true)),
        '{broken',
      ]) {
        await file.writeAsString(original);
        final migration = ServerConfigurationMigration(
          configuration: file,
          credentials: credentials,
          accessStore: MemoryServerAccessStore(),
          readLegacyVerifier: () async => verifier,
        );
        await expectLater(migration.migrate(), throwsFormatException);
        expect(await file.readAsString(), original);
      }
    },
  );

  test(
    'journal damage and independent config edits are detected before resume',
    () async {
      await file.writeAsString(jsonEncode(_legacy(version: 3)));
      final migration = ServerConfigurationMigration(
        configuration: file,
        credentials: credentials,
        accessStore: MemoryServerAccessStore(),
        readLegacyVerifier: () async => verifier,
        checkpoint: (_) async => throw StateError('interrupted'),
      );
      await expectLater(migration.migrate(), throwsStateError);
      final changed = jsonEncode({'version': 3, 'servers': []});
      await file.writeAsString(changed);
      await expectLater(migration.migrate(), throwsFormatException);
      expect(await file.readAsString(), changed);
      await migration.journal.writeAsString('{}');
      await expectLater(migration.migrate(), throwsFormatException);
      expect(await file.readAsString(), changed);
    },
  );
}
