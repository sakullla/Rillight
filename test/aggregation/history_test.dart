import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/aggregation/history/history_writer.dart';
import 'package:rillight/aggregation/identity/media_identity.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/region_access.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/auth/source_sessions.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/player/player_settings.dart';

class _Client extends EmbyClient {
  _Client()
    : super(
        device: const EmbyDeviceInfo(
          clientName: 'test',
          deviceName: 'test',
          deviceId: 'history',
          version: '1',
        ),
      );
  @override
  Future<PublicServerInfo> getPublicInfo(Uri baseUrl) async =>
      PublicServerInfo(id: baseUrl.host, serverName: baseUrl.host);
  @override
  Future<EmbyUser> getUser() async => EmbyUser(id: userId!, name: 'user');
}

class _FailingStore extends MemoryHistoryStore {
  bool fail = false;
  Completer<void>? started;
  Completer<void>? gate;
  @override
  Future<void> replace(Map<String, dynamic> snapshot) async {
    started?.complete();
    started = null;
    await gate?.future;
    if (fail) throw const FileSystemException('synthetic disk failure');
    await super.replace(snapshot);
  }
}

SavedServer _server(String id, {AccessRegion region = AccessRegion.ordinary}) =>
    SavedServer(
      id: id,
      name: id,
      username: 'user',
      region: region,
      lines: [ServerLine(id: 'line', address: 'https://$id')],
      libraryIds: const ['library'],
      scopeKnown: true,
    );

class _Fixture {
  _Fixture(this.access, this.registry, this.writer, this.a, this.b);
  final RegionAccessController access;
  final SourceSessionRegistry registry;
  HistoryWriter writer;
  final SourceAccount a;
  final SourceAccount b;
  SourceReference source(
    SourceAccount account, {
    String item = 'movie',
    String? version = 'v',
  }) => SourceReference(account: account, itemId: item, mediaSourceId: version);
  Future<WatchSession> begin(
    SourceAccount account, {
    String item = 'movie',
    String work = 'movie',
  }) => writer.beginSession(
    source: source(account, item: item),
    work: source(account, item: work, version: null),
    libraryId: 'library',
  );
  WorkIndex index({bool merged = true}) => WorkIndex()
    ..upsert([
      WorkSource(
        reference: source(a, version: null),
        type: 'Movie',
        title: 'one',
        providerIds: const {'tmdb': '1'},
      ),
      WorkSource(
        reference: source(b, version: null),
        type: 'Movie',
        title: 'one',
        providerIds: {'tmdb': merged ? '1' : '2'},
      ),
    ]);
  SourcePreference pref(SourceAccount account, {String? line = 'line'}) =>
      SourcePreference(
        owner: source(account, version: null),
        target: source(account),
        libraryId: 'library',
        lineId: line,
        settings: const PlayerSeriesPreference(
          mediaSourceName: 'cut',
          audioLanguage: 'zh',
        ),
      );
  PreferenceCandidate candidate(
    SourceAccount account, {
    String item = 'movie',
    String version = 'v',
  }) => PreferenceCandidate(
    source(account, item: item, version: version),
    'library',
    versionName: 'cut',
  );
}

Future<_Fixture> _fixture({HistoryStore? store, bool privateB = false}) async {
  final access = RegionAccessController();
  if (privateB) {
    await access.setPin('1234', '1234', (_) async {});
    expect(await access.unlock('1234'), isTrue);
  }
  final registry = SourceSessionRegistry(
    access: access,
    store: MemoryServerListStore(
      ServerListSnapshot(
        servers: [
          _server('a'),
          _server(
            'b',
            region: privateB ? AccessRegion.private : AccessRegion.ordinary,
          ),
        ],
      ),
    ),
    credentials: MemoryCredentialStore({
      for (final id in ['a', 'b'])
        id: StoredCredentials(
          accessToken: 'token-$id',
          userId: 'user-$id',
          username: 'user',
        ),
    }),
    createClient: _Client.new,
  );
  await registry.load();
  final a = (await registry.authenticate('a')).account;
  final b = (await registry.authenticate('b')).account;
  final writer = await HistoryWriter.open(
    registry: registry,
    store: store ?? MemoryHistoryStore(),
  );
  final fixture = _Fixture(access, registry, writer, a, b);
  addTearDown(() async {
    await fixture.writer.close();
    registry.dispose();
    access.dispose();
  });
  return fixture;
}

Future<WatchRecord?> _observe(
  _Fixture f,
  WatchSession session,
  int event,
  int position, {
  bool playing = true,
  DateTime? at,
}) => f.writer.observe(
  session: session,
  eventSequence: event,
  positionTicks: position,
  actuallyPlaying: playing,
  timeline: const WatchTimeline(durationTicks: 1000, edition: 'cut'),
  observedAt: at,
);

void main() {
  test(
    'actual local observation commits before failed report; reports only actual source',
    () async {
      final f = await _fixture();
      final s = await f.begin(f.a);
      expect(await _observe(f, s, 0, 20, playing: false), isNull);
      expect(f.writer.records(AccessRegion.ordinary), isEmpty);
      final record = (await _observe(f, s, 1, 30))!;
      var requests = 0;
      await f.writer.synchronize(record, (client, actual) async {
        requests++;
        expect(client.userId, f.a.userId);
        expect(actual.source.account, f.a);
        expect(
          f.writer.records(AccessRegion.ordinary).single.positionTicks,
          30,
        );
        throw StateError('remote failed');
      });
      expect(requests, 1);
      final saved = f.writer.records(AccessRegion.ordinary).single;
      expect(saved.remoteStatus, RemoteSyncStatus.failed);
      expect(saved.positionTicks, 30);
      expect(saved.timeline.edition, 'cut');
    },
  );

  test(
    'reject out of order, ended and superseded sessions, including IPC ids',
    () async {
      final f = await _fixture();
      final old = await f.begin(f.a);
      await _observe(f, old, 4, 100);
      expect(await _observe(f, old, 3, 900), isNull);
      expect(await _observe(f, old, 4, 500), isNull);
      final current = await f.begin(f.b);
      expect(f.writer.sessionById(old.id), isNull);
      expect(f.writer.sessionById(current.id), same(current));
      expect(await _observe(f, old, 5, 800), isNull);
      await _observe(f, current, 0, 10);
      f.writer.endSession(current);
      expect(await _observe(f, current, 1, 20), isNull);
      final records = f.writer.records(AccessRegion.ordinary);
      expect(records.first.source.account, f.b);
      expect(records.last.positionTicks, 100);
    },
  );

  test('late remote completion does not update newer observation', () async {
    final f = await _fixture();
    final s = await f.begin(f.a);
    final old = (await _observe(f, s, 1, 10))!;
    final gate = Completer<void>();
    final started = Completer<void>();
    final syncing = f.writer.synchronize(old, (_, _) async {
      started.complete();
      await gate.future;
    });
    await started.future;
    await _observe(f, s, 2, 20);
    gate.complete();
    await syncing;
    expect(
      f.writer.records(AccessRegion.ordinary).single.remoteStatus,
      RemoteSyncStatus.pending,
    );
  });

  test(
    'older failed report attempt cannot overwrite a newer successful attempt',
    () async {
      final f = await _fixture();
      final s = await f.begin(f.a);
      final record = (await _observe(f, s, 1, 10))!;
      final gate = Completer<void>();
      final started = Completer<void>();
      final old = f.writer.synchronize(record, (_, _) async {
        started.complete();
        await gate.future;
        throw StateError('old attempt');
      });
      await started.future;
      await f.writer.synchronize(record, (_, _) async {});
      gate.complete();
      await old;
      expect(
        f.writer.records(AccessRegion.ordinary).single.remoteStatus,
        RemoteSyncStatus.succeeded,
      );
    },
  );

  test(
    'local order beats wall clock and position; split never copies progress',
    () async {
      final f = await _fixture();
      final a = await f.begin(f.a);
      await _observe(f, a, 1, 900, at: DateTime.utc(2030));
      final b = await f.begin(f.b);
      await _observe(f, b, 1, 10, at: DateTime.utc(2020));
      final index = f.index();
      final anchor = f.source(f.a, version: null);
      expect(
        f.writer
            .resolveResume(
              region: AccessRegion.ordinary,
              index: index,
              anchor: anchor,
            )
            .local!
            .source
            .account,
        f.b,
      );
      index.upsert([
        WorkSource(
          reference: f.source(f.b, version: null),
          type: 'Movie',
          title: 'one',
          providerIds: const {'tmdb': '2'},
        ),
      ]);
      expect(
        f.writer
            .resolveResume(
              region: AccessRegion.ordinary,
              index: index,
              anchor: anchor,
            )
            .local!
            .source
            .account,
        f.a,
      );
      expect(f.writer.records(AccessRegion.ordinary), hasLength(2));
      // No record for a newly split source that has never been observed.
      final c = f.source(f.a, item: 'new', version: null);
      index.upsert([
        WorkSource(
          reference: c,
          type: 'Movie',
          title: 'one',
          providerIds: const {'tmdb': '3'},
        ),
      ]);
      expect(
        f.writer
            .resolveResume(
              region: AccessRegion.ordinary,
              index: index,
              anchor: c,
            )
            .kind,
        ResumeKind.empty,
      );
    },
  );

  test(
    'remote unknown/equal timestamps conflict, not max position or response order',
    () async {
      final f = await _fixture();
      RemoteWatch remote(
        SourceAccount a,
        int pos, {
        DateTime? at,
        bool trusted = false,
      }) => RemoteWatch(
        source: f.source(a),
        work: f.source(a, version: null),
        libraryId: 'library',
        positionTicks: pos,
        playedAt: at,
        timeTrusted: trusted,
      );
      ResumeChoice resolve(List<RemoteWatch> candidates) =>
          f.writer.resolveResume(
            region: AccessRegion.ordinary,
            index: f.index(),
            anchor: f.source(f.a, version: null),
            remote: candidates,
          );
      final unknown = [remote(f.a, 900), remote(f.b, 10)];
      expect(resolve(unknown).kind, ResumeKind.conflict);
      expect(resolve(unknown.reversed.toList()).conflicts, hasLength(2));
      final at = DateTime.utc(2026);
      expect(
        resolve([
          remote(f.a, 900, at: at, trusted: true),
          remote(f.b, 10, at: at, trusted: true),
        ]).kind,
        ResumeKind.conflict,
      );
      expect(
        resolve([
          remote(f.a, 900, at: at, trusted: true),
          remote(
            f.b,
            10,
            at: at.add(const Duration(seconds: 1)),
            trusted: true,
          ),
        ]).remote!.source.account,
        f.b,
      );
    },
  );

  test(
    'restart retains sequence, sync status, exact source and timeline, not active sessions',
    () async {
      final store = MemoryHistoryStore();
      final f = await _fixture(store: store);
      final session = await f.begin(f.a);
      final record = (await _observe(f, session, 8, 99))!;
      await f.writer.synchronize(record, (_, _) async {
        throw StateError('offline');
      });
      await f.writer.close();
      f.writer = await HistoryWriter.open(registry: f.registry, store: store);
      expect(f.writer.sessionById(session.id), isNull);
      final saved = f.writer.records(AccessRegion.ordinary).single;
      expect(saved.source, record.source);
      expect(saved.remoteStatus, RemoteSyncStatus.failed);
      expect(saved.timeline.durationTicks, 1000);
      final next = await f.begin(f.a);
      expect(next.id, isNot(session.id));
      expect(
        (await _observe(f, next, 0, 3))!.localOrder,
        greaterThan(record.localOrder),
      );
    },
  );

  test(
    'disk failure leaves prior snapshot and allows same event retry',
    () async {
      final store = _FailingStore();
      final f = await _fixture(store: store);
      final s = await f.begin(f.a);
      final first = (await _observe(f, s, 1, 10))!;
      store.fail = true;
      await expectLater(
        _observe(f, s, 2, 20),
        throwsA(isA<FileSystemException>()),
      );
      expect(f.writer.records(AccessRegion.ordinary).single, same(first));
      store.fail = false;
      final next = (await _observe(f, s, 2, 20))!;
      expect(next.localOrder, first.localOrder + 1);
    },
  );

  test(
    'preference validates registry scope and never silently picks first source',
    () async {
      final f = await _fixture();
      final owner = f.source(f.a, version: null);
      await f.writer.savePreference(f.pref(f.a));
      PreferenceResolution resolve() => f.writer.resolvePreference(
        owner: owner,
        region: AccessRegion.ordinary,
        candidates: [f.candidate(f.a), f.candidate(f.b)],
      );
      expect(resolve().selected!.source.account, f.a);
      await f.registry.configureScope(
        'a',
        participates: false,
        libraryIds: {'library'},
      );
      final invalid = resolve();
      expect(invalid.failure, PreferenceFailure.notParticipating);
      expect(invalid.selected, isNull);
      expect(invalid.allowedCandidates.single.source.account, f.b);
      await f.registry.configureScope(
        'a',
        participates: true,
        libraryIds: {'other'},
      );
      expect(resolve().failure, PreferenceFailure.libraryExcluded);
    },
  );

  test(
    'removed line and unavailable account are explicit, with allowed alternatives',
    () async {
      final f = await _fixture();
      final owner = f.source(f.a, version: null);
      await f.writer.savePreference(f.pref(f.a));
      final snapshot = await f.registry.ordinaryStore.load();
      await f.registry.ordinaryStore.save(
        ServerListSnapshot(
          servers: [
            for (final server in snapshot.servers)
              if (server.id == 'a')
                server.copyWith(
                  lines: [
                    const ServerLine(id: 'replacement', address: 'https://a'),
                  ],
                  activeLineId: 'replacement',
                )
              else
                server,
          ],
        ),
      );
      PreferenceResolution resolve() => f.writer.resolvePreference(
        owner: owner,
        region: AccessRegion.ordinary,
        candidates: [f.candidate(f.a), f.candidate(f.b)],
      );
      expect(resolve().failure, PreferenceFailure.lineRemoved);
      expect(resolve().selected, isNull);
      await f.writer.savePreference(f.pref(f.a, line: 'replacement'));
      final commit = await f.registry.beginOrdinaryCredentials('a');
      await f.registry.commitOrdinaryCredentials(commit, null);
      expect(resolve().failure, PreferenceFailure.accountUnavailable);
      expect(resolve().allowedCandidates.single.source.account, f.b);
    },
  );

  test(
    'preference persistence survives restart and rejects cross-region writes',
    () async {
      final f = await _fixture(privateB: true);
      await f.writer.savePreference(f.pref(f.a));
      final store = f.writer.store;
      await f.writer.close();
      f.writer = await HistoryWriter.open(registry: f.registry, store: store);
      final resolved = f.writer.resolvePreference(
        owner: f.source(f.a, version: null),
        region: AccessRegion.ordinary,
        candidates: [f.candidate(f.a)],
      );
      expect(resolved.failure, isNull);
      expect(resolved.preference!.settings.audioLanguage, 'zh');
      await expectLater(
        f.writer.savePreference(
          SourcePreference(
            owner: f.source(f.a, version: null),
            target: f.source(f.b),
            libraryId: 'library',
          ),
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'unknown storage versions are rejected without overwriting the file',
    () async {
      final f = await _fixture();
      final store = MemoryHistoryStore();
      await store.replace({'version': 100, 'future': true});
      await expectLater(
        HistoryWriter.open(registry: f.registry, store: store),
        throwsFormatException,
      );
      expect(await store.read(), {'version': 100, 'future': true});
    },
  );

  test(
    'next episode resolves fresh concrete version; missing label stays uncertain',
    () async {
      final f = await _fixture();
      final owner = f.source(f.a, version: null);
      await f.writer.savePreference(f.pref(f.a));
      final next = f.candidate(
        f.a,
        item: 'episode-2',
        version: 'different-version-id',
      );
      final index = WorkIndex()
        ..upsert([
          WorkSource(
            reference: owner,
            type: 'Series',
            title: 'series',
            providerIds: const {'tmdb': '1'},
          ),
        ]);
      final intended = EpisodeSource(
        reference: next.source.item,
        series: owner,
        season: 1,
        episode: 2,
        isSpecial: false,
        numberingScheme: 'aired',
      );
      final lookup = locateEpisode(
        series: index.groupFor(owner)!,
        origin: intended,
        targetAccount: f.a,
        available: [intended],
      );
      final lookups = {f.a: lookup};
      expect(lookup.status, EpisodeLookupStatus.confirmed);
      expect(
        f.writer
            .resolvePreference(
              owner: owner,
              region: AccessRegion.ordinary,
              candidates: [next],
              nextEpisode: true,
            )
            .selected,
        isNull,
      );
      final result = f.writer.resolvePreference(
        owner: owner,
        region: AccessRegion.ordinary,
        candidates: [next],
        nextEpisode: true,
        episodeLookups: lookups,
      );
      expect(result.selected!.source.itemId, 'episode-2');
      expect(result.selected!.source.mediaSourceId, 'different-version-id');
      expect(
        f.writer
            .resolvePreference(
              owner: owner,
              region: AccessRegion.ordinary,
              candidates: [PreferenceCandidate(next.source, 'library')],
              nextEpisode: true,
              episodeLookups: lookups,
            )
            .failure,
        PreferenceFailure.versionUncertain,
      );
      expect(
        f.writer
            .resolvePreference(
              owner: owner,
              region: AccessRegion.ordinary,
              candidates: [next],
            )
            .failure,
        PreferenceFailure.targetMissing,
      );
    },
  );

  test(
    'ordinary projection never includes unlocked private records, preferences or remote',
    () async {
      final f = await _fixture(privateB: true);
      final s = await f.begin(f.b);
      await _observe(f, s, 0, 10);
      await f.writer.savePreference(f.pref(f.b));
      expect(f.writer.records(AccessRegion.ordinary), isEmpty);
      expect(f.writer.records(AccessRegion.private), hasLength(1));
      final result = f.writer.resolvePreference(
        owner: f.source(f.b, version: null),
        region: AccessRegion.ordinary,
        candidates: [f.candidate(f.b)],
      );
      expect(result.failure, PreferenceFailure.wrongRegion);
      expect(result.preference, isNull);
      expect(result.allowedCandidates, isEmpty);
    },
  );

  test(
    'lock revokes sessions and clears preferences; unlocking does not resurrect them',
    () async {
      final f = await _fixture(privateB: true);
      final s = await f.begin(f.b);
      await _observe(f, s, 0, 10);
      await f.writer.savePreference(f.pref(f.b));
      await f.access.lock();
      expect(await _observe(f, s, 1, 50), isNull);
      expect(f.writer.records(AccessRegion.private), isEmpty);
      final locked = f.writer.resolvePreference(
        owner: f.source(f.b, version: null),
        region: AccessRegion.private,
        candidates: [f.candidate(f.b)],
      );
      expect(locked.failure, PreferenceFailure.regionLocked);
      expect(locked.preference, isNull);
      expect(await f.access.unlock('1234'), isTrue);
      await f.registry.authenticate('b');
      expect(
        f.writer
            .resolvePreference(
              owner: f.source(f.b, version: null),
              region: AccessRegion.private,
              candidates: [f.candidate(f.b)],
            )
            .failure,
        PreferenceFailure.notConfigured,
      );
      expect(f.writer.records(AccessRegion.ordinary), isEmpty);
    },
  );

  test(
    'service migration purges actual records and preferences before membership change',
    () async {
      final f = await _fixture();
      await f.access.setPin('1234', '1234', (_) async {});
      await f.access.unlock('1234');
      final s = await f.begin(f.a);
      await _observe(f, s, 0, 20);
      await f.writer.savePreference(f.pref(f.a));
      await f.registry.move('a', AccessRegion.private);
      expect(f.writer.records(AccessRegion.ordinary), isEmpty);
      expect(await _observe(f, s, 1, 40), isNull);
      await f.registry.move('a', AccessRegion.ordinary);
      await f.registry.authenticate('a');
      expect(f.writer.records(AccessRegion.ordinary), isEmpty);
      expect(
        f.writer
            .resolvePreference(
              owner: f.source(f.a, version: null),
              region: AccessRegion.ordinary,
              candidates: [f.candidate(f.a)],
            )
            .failure,
        PreferenceFailure.notConfigured,
      );
    },
  );

  test(
    'legacy ids migrate only with complete unique attribution; consumed id cannot revive',
    () async {
      final f = await _fixture();
      const settings = PlayerSeriesPreference(
        audioLanguage: 'zh',
        mediaSourceName: 'cut',
      );
      expect(
        await f.writer.migrateLegacy(
          seriesId: 'movie',
          settings: settings,
          candidates: [f.candidate(f.a)],
          inventoryComplete: false,
        ),
        PreferenceFailure.ambiguousLegacy,
      );
      expect(
        await f.writer.migrateLegacy(
          seriesId: 'movie',
          settings: settings,
          candidates: [f.candidate(f.a), f.candidate(f.b)],
          inventoryComplete: true,
        ),
        PreferenceFailure.ambiguousLegacy,
      );
      expect(
        await f.writer.migrateLegacy(
          seriesId: 'movie',
          settings: settings,
          candidates: [f.candidate(f.a)],
          inventoryComplete: true,
        ),
        isNull,
      );
      await f.access.setPin('1234', '1234', (_) async {});
      await f.access.unlock('1234');
      await f.registry.move('a', AccessRegion.private);
      await f.registry.move('a', AccessRegion.ordinary);
      await f.registry.authenticate('a');
      await f.writer.close();
      f.writer = await HistoryWriter.open(
        registry: f.registry,
        store: f.writer.store,
      );
      expect(
        await f.writer.migrateLegacy(
          seriesId: 'movie',
          settings: settings,
          candidates: [f.candidate(f.a)],
          inventoryComplete: true,
        ),
        PreferenceFailure.notConfigured,
      );
    },
  );

  test(
    'revocation during disk IO rejects result and remote dispatch; cleanup removes pending preferences',
    () async {
      final store = _FailingStore();
      final f = await _fixture(store: store, privateB: true);
      final s = await f.begin(f.b);
      store.started = Completer<void>();
      store.gate = Completer<void>();
      final started = store.started!.future;
      final observing = _observe(f, s, 1, 80);
      final rejected = expectLater(observing, throwsStateError);
      await started;
      final locking = f.access.lock();
      expect(f.writer.records(AccessRegion.private), isEmpty);
      store.gate!.complete();
      await rejected;
      await locking;
      expect(f.writer.sessionById(s.id), isNull);
    },
  );

  test(
    'failed lock cleanup still evicts preference in memory and on next locked restart',
    () async {
      final store = _FailingStore();
      final f = await _fixture(store: store, privateB: true);
      await f.writer.savePreference(f.pref(f.b));
      store.fail = true;
      await f.access.lock();
      expect(await f.access.unlock('1234'), isTrue);
      await f.registry.authenticate('b');
      expect(
        f.writer
            .resolvePreference(
              owner: f.source(f.b, version: null),
              region: AccessRegion.private,
              candidates: [f.candidate(f.b)],
            )
            .preference,
        isNull,
      );
      store.fail = false;
      await f.access.lock();
      await f.writer.close();
      f.writer = await HistoryWriter.open(registry: f.registry, store: store);
      expect(f.writer.records(AccessRegion.ordinary), isEmpty);
    },
  );

  test(
    'file atomic replacement, restart and exclusive main-process ownership',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'rillight-history-test-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/history.json');
      final store = await FileHistoryStore.open(file);
      final f = await _fixture(store: store);
      await expectLater(FileHistoryStore.open(file), throwsStateError);
      await expectLater(
        HistoryWriter.open(registry: f.registry, store: store),
        throwsStateError,
      );
      final s = await f.begin(f.a);
      await _observe(f, s, 0, 88);
      await f.writer.close();
      f.writer = await HistoryWriter.open(
        registry: f.registry,
        store: await FileHistoryStore.open(file),
      );
      expect(f.writer.records(AccessRegion.ordinary).single.positionTicks, 88);
      expect(await File('${file.path}.next').exists(), isFalse);
    },
  );
}
