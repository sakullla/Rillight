import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/auth/server_configuration_migration.dart';
import 'package:rillight/aggregation/history/history_store.dart';

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
}
