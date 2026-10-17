import '../helpers/server_access_fixture.dart';

import 'package:dio/dio.dart';

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/aggregation/history/history_writer.dart';
import 'package:rillight/aggregation/identity/media_identity.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_access.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/auth/source_sessions.dart';
import 'package:rillight/media_server/media_server_client.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/media_server/device.dart';
import 'package:rillight/media_server/models.dart';
import 'package:rillight/player/player_settings.dart';

class _Client extends EmbyClient {
  _Client()
    : super(
        device: const ClientDeviceInfo(
          clientName: 'test',
          deviceName: 'test',
          deviceId: 'history',
          version: '1',
        ),
      );
  @override
  Future<void> logout() async => clearSession();
  @override
  Future<PublicServerInfo> getPublicInfo(Uri baseUrl) async =>
      PublicServerInfo(id: baseUrl.host, serverName: baseUrl.host);
  @override
  Future<MediaUser> getUser({CancelToken? cancelToken}) async =>
      MediaUser(id: userId!, name: 'user');
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

SavedServer _server(String id, {bool protected = false}) => SavedServer(
  id: id,
  name: id,
  username: 'user',
  protectionRef: protected ? 'test:$id' : null,
  lines: [ServerLine(id: 'line', address: 'https://$id')],
);

class _Fixture {
  _Fixture(this.access, this.registry, this.writer, this.a, this.b);
  final ServerAccessController access;
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
  final access = TestServerAccessController(
    passwords: {if (privateB) 'b': '1234'},
  );
  final registry = SourceSessionRegistry(
    access: access,
    store: MemoryServerListStore(
      ServerListSnapshot(
        servers: [
          _server('a'),
          _server('b', protected: privateB),
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
  if (privateB) expect(await access.unlock('b', '1234'), isTrue);
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
  test('a locked private playback permit cannot save preference', () async {
    final f = await _fixture(privateB: true);
    final permit = f.registry.permit(f.b, libraryId: 'library');
    await f.writer.savePreference(f.pref(f.b), playbackPermit: permit);
    await f.access.lock('b');
    await expectLater(
      f.writer.savePreference(f.pref(f.b), playbackPermit: permit),
      throwsStateError,
    );
  });

  test(
    'preferences from every authorized library need no participation setup',
    () async {
      final f = await _fixture();
      final preference = f.pref(f.a);
      final permit = f.registry.permit(f.a, libraryId: 'library');
      await f.writer.savePreference(preference);
      await f.writer.savePreference(preference, playbackPermit: permit);
      expect(
        f.writer
            .resolvePreference(
              owner: preference.owner,
              candidates: [f.candidate(f.a)],
            )
            .selected!
            .source,
        preference.target,
      );
      for (final wrong in [
        f.registry.permit(f.b, libraryId: 'library'),
        f.registry.permit(f.a, libraryId: 'other-library'),
        f.registry.permit(f.a),
      ]) {
        await expectLater(
          f.writer.savePreference(preference, playbackPermit: wrong),
          throwsStateError,
        );
      }
      await f.registry.logoutSource('a');
      await expectLater(
        f.writer.savePreference(preference, playbackPermit: permit),
        throwsStateError,
      );
    },
  );

  test('actual local observation commits before failed report; reports only actual source', () async {
    final f = await _fixture();
    final s = await f.begin(f.a);
    expect(await _observe(f, s, 0, 20, playing: false), isNull);
    expect(f.writer.records(), isEmpty);
    final record = (await _observe(f, s, 1, 30))!;
    var requests = 0;
    await f.writer.synchronize(record, (client, actual) async {
      requests++;
      expect(client.userId, f.a.userId);
      expect(actual.source.account, f.a);
      expect(f.writer.records().single.positionTicks, 30);
      throw StateError('remote failed');
    });
    expect(requests, 1);
    final saved = f.writer.records().single;
    expect(saved.remoteStatus, RemoteSyncStatus.failed);
    expect(saved.positionTicks, 30);
    expect(saved.timeline.edition, 'cut');
  });

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
      final records = f.writer.records();
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
    expect(f.writer.records().single.remoteStatus, RemoteSyncStatus.pending);
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
        f.writer.records().single.remoteStatus,
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
            .resolveResume(index: index, anchor: anchor)
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
            .resolveResume(index: index, anchor: anchor)
            .local!
            .source
            .account,
        f.a,
      );
      expect(f.writer.records(), hasLength(2));
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
        f.writer.resolveResume(index: index, anchor: c).kind,
        ResumeKind.empty,
      );
    },
  );

  test('remote unknown/equal timestamps conflict, not max position or response order', () async {
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
        remote(f.b, 10, at: at.add(const Duration(seconds: 1)), trusted: true),
      ]).remote!.source.account,
      f.b,
    );
  });

  test('restart retains sequence, sync status, exact source and timeline, not active sessions', () async {
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
    final saved = f.writer.records().single;
    expect(saved.source, record.source);
    expect(saved.remoteStatus, RemoteSyncStatus.failed);
    expect(saved.timeline.durationTicks, 1000);
    final next = await f.begin(f.a);
    expect(next.id, isNot(session.id));
    expect(
      (await _observe(f, next, 0, 3))!.localOrder,
      greaterThan(record.localOrder),
    );
  });

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
      expect(f.writer.records().single, same(first));
      store.fail = false;
      final next = (await _observe(f, s, 2, 20))!;
      expect(next.localOrder, first.localOrder + 1);
    },
  );

  test(
    'a locked preferred server never silently selects an allowed alternative',
    () async {
      final f = await _fixture(privateB: true);
      final owner = f.source(f.a, version: null);
      await f.writer.savePreference(
        SourcePreference(
          owner: owner,
          target: f.source(f.b),
          libraryId: 'library',
        ),
      );
      PreferenceResolution resolve() => f.writer.resolvePreference(
        owner: owner,
        candidates: [f.candidate(f.a), f.candidate(f.b)],
      );
      expect(resolve().selected!.source.account, f.b);
      await f.access.lock('b');
      expect(resolve().failure, PreferenceFailure.serverLocked);
      expect(resolve().selected, isNull);
      expect(resolve().allowedCandidates.single.source.account, f.a);
      await f.access.unlock('b', '1234');
      await f.registry.authenticate('b');
      expect(resolve().selected!.source.account, f.b);
    },
  );

  test('removed line and unavailable account are explicit, with allowed alternatives', () async {
    final f = await _fixture();
    final owner = f.source(f.a, version: null);
    await f.writer.savePreference(f.pref(f.a));
    final snapshot = await f.registry.configurationStore.load();
    await f.registry.configurationStore.save(
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
      candidates: [f.candidate(f.a), f.candidate(f.b)],
    );
    expect(resolve().failure, PreferenceFailure.lineRemoved);
    expect(resolve().selected, isNull);
    await f.writer.savePreference(f.pref(f.a, line: 'replacement'));
    final commit = await f.registry.beginCredentials('a');
    await f.registry.commitCredentials(commit, null);
    expect(resolve().failure, PreferenceFailure.accountUnavailable);
    expect(resolve().allowedCandidates.single.source.account, f.b);
  });

  test('preference persistence survives restart and preserves explicitly chosen source', () async {
    final f = await _fixture(privateB: true);
    await f.writer.savePreference(f.pref(f.a));
    final store = f.writer.store;
    await f.writer.close();
    f.writer = await HistoryWriter.open(registry: f.registry, store: store);
    final resolved = f.writer.resolvePreference(
      owner: f.source(f.a, version: null),
      candidates: [f.candidate(f.a)],
    );
    expect(resolved.failure, isNull);
    expect(resolved.preference!.settings.audioLanguage, 'zh');
    await f.writer.savePreference(
      SourcePreference(
        owner: f.source(f.a, version: null),
        target: f.source(f.b),
        libraryId: 'library',
      ),
    );
    expect(
      f.writer
          .resolvePreference(
            owner: f.source(f.a, version: null),
            candidates: [f.candidate(f.a), f.candidate(f.b)],
          )
          .selected!
          .source
          .account,
      f.b,
    );
  });

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

  test('next episode resolves fresh concrete version; missing label stays uncertain', () async {
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
            candidates: [next],
            nextEpisode: true,
          )
          .selected,
      isNull,
    );
    final result = f.writer.resolvePreference(
      owner: owner,
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
            candidates: [PreferenceCandidate(next.source, 'library')],
            nextEpisode: true,
            episodeLookups: lookups,
          )
          .failure,
      PreferenceFailure.versionUncertain,
    );
    expect(
      f.writer.resolvePreference(owner: owner, candidates: [next]).failure,
      PreferenceFailure.targetMissing,
    );
  });

  test(
    'unlocked server records and preferences join the single aggregation',
    () async {
      final f = await _fixture(privateB: true);
      final session = await f.begin(f.b);
      await _observe(f, session, 0, 10);
      await f.writer.savePreference(f.pref(f.b));
      expect(f.writer.records().single.source.account, f.b);
      final result = f.writer.resolvePreference(
        owner: f.source(f.b, version: null),
        candidates: [f.candidate(f.b)],
      );
      expect(result.failure, isNull);
      expect(result.selected!.source.account, f.b);
    },
  );

  test(
    'lock hides records and preferences but unlock restores persisted history',
    () async {
      final f = await _fixture(privateB: true);
      final session = await f.begin(f.b);
      await _observe(f, session, 0, 10);
      await f.writer.savePreference(f.pref(f.b));
      final before = await f.writer.store.read();
      await f.access.lock('b');
      expect(await _observe(f, session, 1, 50), isNull);
      expect(f.writer.records(), isEmpty);
      expect(
        f.writer
            .resolvePreference(
              owner: f.source(f.b, version: null),
              candidates: [f.candidate(f.b)],
            )
            .failure,
        PreferenceFailure.serverLocked,
      );
      expect(await f.writer.store.read(), before);
      expect(await f.access.unlock('b', '1234'), isTrue);
      await f.registry.authenticate('b');
      expect(
        f.writer
            .resolvePreference(
              owner: f.source(f.b, version: null),
              candidates: [f.candidate(f.b)],
            )
            .failure,
        isNull,
      );
      expect(f.writer.records().single.positionTicks, 10);
      expect(
        await _observe(f, session, 2, 60),
        isNull,
        reason: 'Unlock never revives an old playback permit',
      );
    },
  );

  test('enabling entry password retains records and preferences for the same account', () async {
    final f = await _fixture();
    final session = await f.begin(f.a);
    await _observe(f, session, 0, 20);
    await f.writer.savePreference(f.pref(f.a));
    await f.access.setPassword(
      'a',
      '1234',
      '1234',
      persistReference: (ref) =>
          f.registry.persistProtectionReference('a', ref),
    );
    expect(f.writer.records(), isEmpty);
    expect(await _observe(f, session, 1, 40), isNull);
    await f.access.unlock('a', '1234');
    await f.registry.authenticate('a');
    expect(f.writer.records().single.positionTicks, 20);
    expect(
      f.writer
          .resolvePreference(
            owner: f.source(f.a, version: null),
            candidates: [f.candidate(f.a)],
          )
          .failure,
      isNull,
    );
  });

  test(
    'legacy concrete version resolves normally before and after restart',
    () async {
      final f = await _fixture();
      final candidate = f.candidate(f.a);
      const settings = PlayerSeriesPreference(
        mediaSourceName: 'cut',
        audioLanguage: 'zh',
        audioStreamIndex: 3,
      );
      expect(
        await f.writer.migrateLegacy(
          seriesId: 'movie',
          settings: settings,
          candidates: [candidate],
          inventoryComplete: true,
        ),
        isNull,
      );
      void checkResolution() {
        final result = f.writer.resolvePreference(
          owner: candidate.source.item,
          candidates: [candidate],
        );
        expect(result.failure, isNull);
        expect(result.selected!.source, candidate.source);
        expect(result.preference!.owner, candidate.source.item);
        expect(result.preference!.target, candidate.source);
        expect(result.preference!.settings.audioLanguage, 'zh');
        expect(result.preference!.settings.audioStreamIndex, isNull);
        final missing = f.writer.resolvePreference(
          owner: candidate.source.item,
          candidates: [f.candidate(f.a, version: 'other')],
        );
        expect(missing.failure, PreferenceFailure.targetMissing);
        expect(missing.selected, isNull);
      }

      checkResolution();
      await f.writer.close();
      f.writer = await HistoryWriter.open(
        registry: f.registry,
        store: f.writer.store,
      );
      checkResolution();
    },
  );

  test(
    'legacy migration rejects ambiguous versions and missing version evidence',
    () async {
      final f = await _fixture();
      final candidate = f.candidate(f.a);
      for (final candidates in <List<PreferenceCandidate>>[
        [candidate, f.candidate(f.a, version: 'other')],
        [f.candidate(f.a, version: 'other'), candidate],
        [PreferenceCandidate(candidate.source.item, 'library')],
        [f.candidate(f.a, version: '')],
        [candidate, PreferenceCandidate(candidate.source.item, 'library')],
      ]) {
        expect(
          await f.writer.migrateLegacy(
            seriesId: 'movie',
            settings: const PlayerSeriesPreference(mediaSourceName: 'cut'),
            candidates: candidates,
            inventoryComplete: true,
          ),
          PreferenceFailure.ambiguousLegacy,
        );
        final result = f.writer.resolvePreference(
          owner: candidate.source.item,
          candidates: [candidate],
        );
        expect(result.failure, PreferenceFailure.notConfigured);
        expect(result.selected, isNull);
      }
      await f.writer.close();
      f.writer = await HistoryWriter.open(
        registry: f.registry,
        store: f.writer.store,
      );
      // Rejected attempts neither persist a preference nor consume the id.
      expect(
        await f.writer.migrateLegacy(
          seriesId: 'movie',
          settings: const PlayerSeriesPreference(),
          candidates: [candidate],
          inventoryComplete: true,
        ),
        isNull,
      );
    },
  );

  test(
    'legacy migration rejects missing or mismatched account identity evidence',
    () async {
      final f = await _fixture();
      final candidate = f.candidate(f.a);
      for (final account in [
        SourceAccount(
          configuredServerId: f.a.configuredServerId,
          verifiedServerId: '',
          userId: f.a.userId,
        ),
        SourceAccount(
          configuredServerId: f.a.configuredServerId,
          verifiedServerId: 'different-server',
          userId: f.a.userId,
        ),
        SourceAccount(
          configuredServerId: f.a.configuredServerId,
          verifiedServerId: f.a.verifiedServerId,
          userId: '',
        ),
      ]) {
        await expectLater(
          f.writer.migrateLegacy(
            seriesId: 'movie',
            settings: const PlayerSeriesPreference(),
            candidates: [f.candidate(account)],
            inventoryComplete: true,
          ),
          throwsStateError,
        );
        expect(
          f.writer
              .resolvePreference(
                owner: candidate.source.item,
                candidates: [candidate],
              )
              .failure,
          PreferenceFailure.notConfigured,
        );
      }
      await f.writer.close();
      f.writer = await HistoryWriter.open(
        registry: f.registry,
        store: f.writer.store,
      );
      expect(
        await f.writer.migrateLegacy(
          seriesId: 'movie',
          settings: const PlayerSeriesPreference(),
          candidates: [candidate],
          inventoryComplete: true,
        ),
        isNull,
      );
    },
  );

  test('legacy ids migrate only with complete unique attribution; consumed id cannot revive', () async {
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
    await f.access.setPassword(
      'a',
      '1234',
      '1234',
      persistReference: (ref) =>
          f.registry.persistProtectionReference('a', ref),
    );
    await f.access.unlock('a', '1234');
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
  });

  test('revocation during disk IO rejects result and remote dispatch; cleanup removes pending preferences', () async {
    final store = _FailingStore();
    final f = await _fixture(store: store, privateB: true);
    final s = await f.begin(f.b);
    store.started = Completer<void>();
    store.gate = Completer<void>();
    final started = store.started!.future;
    final observing = _observe(f, s, 1, 80);
    final rejected = expectLater(observing, throwsStateError);
    await started;
    final locking = f.access.lock('b');
    expect(f.writer.records(), isEmpty);
    store.gate!.complete();
    await rejected;
    await locking;
    expect(f.writer.sessionById(s.id), isNull);
  });

  test('lock keeps preferences even when history storage is temporarily unwritable', () async {
    final store = _FailingStore();
    final f = await _fixture(store: store, privateB: true);
    await f.writer.savePreference(f.pref(f.b));
    store.fail = true;
    await f.access.lock('b');
    expect(
      f.writer
          .resolvePreference(
            owner: f.source(f.b, version: null),
            candidates: [f.candidate(f.b)],
          )
          .preference,
      isNull,
    );
    expect(await f.access.unlock('b', '1234'), isTrue);
    await f.registry.authenticate('b');
    expect(
      f.writer
          .resolvePreference(
            owner: f.source(f.b, version: null),
            candidates: [f.candidate(f.b)],
          )
          .preference,
      isNotNull,
    );
    store.fail = false;
    await f.access.lock('b');
    await f.writer.close();
    f.writer = await HistoryWriter.open(registry: f.registry, store: store);
    expect(f.writer.records(), isEmpty);
  });

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
      expect(f.writer.records().single.positionTicks, 88);
      expect(await File('${file.path}.next').exists(), isFalse);
    },
  );
}
