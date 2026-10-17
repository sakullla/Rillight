import 'dart:io';

import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_access.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/auth/source_sessions.dart';
import 'package:rillight/aggregation/history/history_writer.dart';
import 'package:rillight/aggregation/identity/media_identity.dart';
import 'package:rillight/media_server/capabilities.dart';
import 'package:rillight/player/player_settings.dart';

import '../auth/provider_identity_cases.dart' show IdentityClient;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/auth/server_configuration_migration.dart';

Map<String, dynamic> _source(
  String server,
  String user, {
  String region = 'private',
}) => {
  'serviceType': 'plex',
  'cloudAccountId': 'cloud',
  'homeUserId': user,
  'region': region,
  'server': server,
  'verifiedServer': 'remote',
  'user': user,
  'item': 'episode',
  'version': 'cut',
};

void main() {
  test(
    'old Emby keys and new keys migrate idempotently without account rebinding',
    () {
      const mapping = ServerSourceMapping([]);
      final legacy = jsonEncode([
        'private',
        'local',
        'remote',
        'alice',
        'item',
        null,
      ]);
      final expected = jsonEncode([
        'emby',
        null,
        null,
        'local',
        'remote',
        'alice',
        'item',
        null,
      ]);
      expect(mapping.migrateSourceKey(legacy), expected);
      expect(mapping.migrateSourceKey(expected), expected);
      final otherUser = jsonEncode([
        'private',
        'local',
        'remote',
        'bob',
        'item',
        null,
      ]);
      expect(mapping.migrateSourceKey(otherUser), isNot(expected));
    },
  );
  test('source migration retains separate server/user history and preferences without mutation', () async {
    final original = {
      'version': 1,
      'revision': 20,
      'order': 80,
      'records': [
        for (final pair in [('a', 'alice'), ('a', 'bob'), ('b', 'alice')])
          {
            'source': _source(pair.$1, pair.$2),
            'work': _source(pair.$1, pair.$2),
            'position': 5678,
            'session': 'watched-${pair.$1}-${pair.$2}',
          },
      ],
      'preferences': [
        for (final user in ['alice', 'bob'])
          {
            'owner': _source('a', user),
            'target': _source('b', user),
            'settings': {'subtitle': 'zh', 'speed': 1.5},
          },
      ],
      'legacyConsumed': ['untouched'],
    };
    final store = MemoryHistoryStore();
    await store.replace(original);
    const mapping = ServerSourceMapping([]);
    final migrated = mapping.migrateHistory((await store.read())!);
    expect(migrated['records'], hasLength(3));
    expect(migrated['preferences'], hasLength(2));
    expect(migrated['sourceIdentityVersion'], 2);
    expect(migrated['revision'], 20);
    expect(migrated['legacyConsumed'], ['untouched']);
    final records = migrated['records'] as List;
    expect(records[0]['source']['user'], 'alice');
    expect(records[1]['source']['user'], 'bob');
    expect(records[2]['source']['server'], 'b');
    expect(records[0]['source'].containsKey('region'), isFalse);
    expect(records[0]['position'], 5678);
    expect(await store.read(), original);
    expect(mapping.migrateHistory(migrated), migrated);
    expect(
      mapping.migrateSourceKey(
        jsonEncode([
          'plex',
          'cloud',
          'alice',
          'private',
          'a',
          'remote',
          'alice',
          'episode',
          'cut',
        ]),
      ),
      jsonEncode([
        'plex',
        'cloud',
        'alice',
        'a',
        'remote',
        'alice',
        'episode',
        'cut',
      ]),
    );
  });

  test(
    'region collapse never silently overwrites matching history identities',
    () {
      const mapping = ServerSourceMapping([]);
      final history = {
        'version': 1,
        'records': [
          for (final region in ['ordinary', 'private'])
            {
              'source': _source('a', 'user', region: region),
              'work': _source('a', 'user'),
            },
        ],
        'preferences': [],
      };
      expect(() => mapping.migrateHistory(history), throwsFormatException);
      expect(
        () => mapping.migrateSource({'server': 'a'}),
        throwsFormatException,
      );
    },
  );

  test('startup opens migrated history with all three providers and distinct users intact', () async {
    final dir = await Directory.systemTemp.createTemp(
      'startup-source-migration-',
    );
    addTearDown(() => dir.delete(recursive: true));
    final config = File('${dir.path}/servers.json');
    final historyFile = File('${dir.path}/history.json');
    final saved = [
      for (final provider in MediaServerType.values)
        for (final user in ['alice', 'bob'])
          SavedServer(
            id: '${provider.name}-$user',
            name: 'Same name',
            username: user,
            serviceType: provider,
            verifiedServerId: 'same-remote',
            lines: const [ServerLine(id: 'line', address: 'https://same.test')],
          ),
    ];
    final credentials = MemoryCredentialStore({
      for (final server in saved)
        server.id: StoredCredentials(
          accessToken: 'token-${server.id}',
          userId: server.username,
          username: server.username,
          serviceType: server.serviceType,
        ),
    });
    final references = [
      for (final server in saved)
        SourceReference(
          account: SourceAccount(
            serviceType: server.serviceType,
            configuredServerId: server.id,
            verifiedServerId: 'same-remote',
            userId: server.username,
          ),
          itemId: 'same-item',
          mediaSourceId: 'same-cut',
        ),
    ];
    final original = <String, dynamic>{
      'version': 1,
      'revision': 6,
      'order': 6,
      'sessions': 6,
      'records': [
        for (var i = 0; i < references.length; i++)
          WatchRecord(
            source: references[i],
            work: references[i].item,
            libraryId: 'library',
            sessionId: 'observed-$i',
            eventSequence: 1,
            localOrder: i + 1,
            observedAt: DateTime.utc(2026, 10, 17),
            positionTicks: (i + 1) * 100,
            played: false,
            timeline: const WatchTimeline(durationTicks: 10000),
          ).toJson(),
      ],
      'preferences': [
        for (final ref in references)
          SourcePreference(
            owner: ref.item,
            target: ref,
            libraryId: 'library',
            lineId: 'line',
            settings: const PlayerSeriesPreference(audioLanguage: 'zh'),
          ).toJson(),
      ],
      'legacyConsumed': <String>[],
    };
    for (final record in original['records'] as List) {
      final region = record['source']['server'] == 'plex-bob'
          ? 'private'
          : 'ordinary';
      record['source']['region'] = region;
      record['work']['region'] = region;
    }
    for (final pref in original['preferences'] as List) {
      final region = pref['owner']['server'] == 'plex-bob'
          ? 'private'
          : 'ordinary';
      pref['owner']['region'] = region;
      pref['target']['region'] = region;
    }
    final rawHistory = jsonEncode(original);
    await historyFile.writeAsString(rawHistory);
    await config.writeAsString(
      jsonEncode({
        'version': 3,
        'servers': [
          for (final server in saved)
            {
              ...server.toJson(),
              'region': server.id == 'plex-bob' ? 'private' : 'ordinary',
              'participates': false,
              'scopeKnown': false,
              'libraryIds': [],
            },
        ],
      }),
    );
    final accessStore = MemoryServerAccessStore();
    final legacyVerifier = (await ServerPasswordVerifier.create('1234'))
        .toJson();
    await ServerConfigurationMigration(
      configuration: config,
      credentials: credentials,
      accessStore: accessStore,
      readLegacyVerifier: () async => legacyVerifier,
    ).migrate();
    final registry = SourceSessionRegistry(
      access: ServerAccessController(store: accessStore),
      store: FileServerListStore(config),
      credentials: credentials,
      createClient: () => IdentityClient(MediaServerType.emby),
      createProviderClient: IdentityClient.new,
    );
    addTearDown(registry.dispose);
    await registry.load();
    for (final server in saved) {
      if (registry.access.allows(server.id)) {
        await registry.authenticate(server.id);
      }
    }
    final store = await FileHistoryStore.open(historyFile);
    final writer = await HistoryWriter.open(registry: registry, store: store);
    try {
      expect(registry.access.allows('plex-bob'), isFalse);
      expect(writer.records(), hasLength(5));
      expect(
        writer.records().any(
          (r) => r.source.account.configuredServerId == 'plex-bob',
        ),
        isFalse,
      );
      expect(
        (await credentials.read('plex-bob'))!.accessToken,
        'token-plex-bob',
      );
      expect(await registry.access.unlock('plex-bob', '1234'), isTrue);
      await registry.authenticate('plex-bob');
      expect(writer.records(), hasLength(6));
      expect(writer.records().map((r) => r.source.key).toSet(), hasLength(6));
      for (var i = 0; i < references.length; i++) {
        final ref = references[i];
        expect(
          writer.records().singleWhere((r) => r.source == ref).positionTicks,
          (i + 1) * 100,
        );
        final preference = writer.resolvePreference(
          owner: ref.item,
          candidates: [PreferenceCandidate(ref, 'library')],
        );
        expect(preference.failure, isNull);
        expect(preference.preference!.settings.audioLanguage, 'zh');
        expect(preference.selected!.source.account, ref.account);
        expect(
          (await credentials.read(ref.account.configuredServerId))!.userId,
          ref.account.userId,
        );
      }
      expect((await store.read())!['sourceIdentityVersion'], 2);
      expect(
        await File('${historyFile.path}.pre-source-v2').readAsString(),
        rawHistory,
      );
    } finally {
      await writer.close();
    }
    final reopened = await FileHistoryStore.open(historyFile);
    expect((await reopened.read())!['records'], hasLength(6));
    await reopened.close();
  });
}
