import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/aggregation/query/aggregation_query.dart';
import 'package:rillight/aggregation/query/same_source_query.dart';
import 'package:rillight/aggregation/history/history_writer.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/region_access.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/auth/source_sessions.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';

Map<String, dynamic> _movie(
  String id, {
  String title = 'Film',
  String? provider = '1',
  int year = 2025,
  String type = 'Movie',
}) => {
  'Id': id,
  'Name': title,
  'Type': type,
  'ProductionYear': year,
  if (provider != null) 'ProviderIds': {'Tmdb': provider},
  'Genres': ['Drama'],
};
Map<String, dynamic> _page(List<Map<String, dynamic>> items, {int? total}) => {
  'Items': items,
  'TotalRecordCount': ?total,
};

class _HttpSource {
  _HttpSource(this.id);
  final String id;
  late HttpServer server;
  final List<Uri> requests = [];
  Future<Object> Function(HttpRequest request) items = (_) async =>
      _page([], total: 0);
  int status = 200;
  Future<void> Function()? authenticationGate;
  Future<void> open() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requests.add(request.uri);
      Object data;
      var code = 200;
      if (request.uri.path.endsWith('/System/Info/Public')) {
        await authenticationGate?.call();
        data = {'Id': id, 'ServerName': id};
      } else if (request.uri.path.endsWith('/Items') ||
          request.uri.path.endsWith('/Shows/NextUp')) {
        data = await items(request);
        code = status;
      } else {
        data = {'Id': 'user-$id', 'Name': 'user'};
      }
      try {
        request.response.statusCode = code;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(data));
        await request.response.close();
      } catch (_) {
        /* timed-out client */
      }
    });
  }

  String get address => 'http://127.0.0.1:${server.port}';
  List<Uri> get itemRequests =>
      requests.where((r) => r.path.endsWith('/Items')).toList();
}

class _Fixture {
  final a = _HttpSource('a');
  final b = _HttpSource('b');
  late RegionAccessController access;
  late SourceSessionRegistry registry;
  late HistoryWriter history;
  late AggregationQueryController query;
  Future<void> open({
    bool privateB = false,
    Duration timeout = const Duration(seconds: 2),
  }) async {
    await a.open();
    await b.open();
    access = RegionAccessController();
    if (privateB) {
      await access.setPin('1234', '1234', (_) async {});
      await access.unlock('1234');
    }
    registry = SourceSessionRegistry(
      access: access,
      store: MemoryServerListStore(
        ServerListSnapshot(
          servers: [
            for (final source in [a, b])
              SavedServer(
                id: source.id,
                name: source.id,
                username: 'user',
                region: privateB && source == b
                    ? AccessRegion.private
                    : AccessRegion.ordinary,
                lines: [ServerLine(id: 'line', address: source.address)],
                libraryIds: const ['library'],
                scopeKnown: true,
              ),
          ],
        ),
      ),
      credentials: MemoryCredentialStore({
        for (final source in [a, b])
          source.id: StoredCredentials(
            accessToken: 'token-${source.id}',
            userId: 'user-${source.id}',
            username: 'user',
          ),
      }),
      createClient: () => EmbyClient(
        device: const EmbyDeviceInfo(
          clientName: 'query-test',
          deviceName: 'test',
          deviceId: 'test',
          version: '1',
        ),
      ),
    );
    await registry.load();
    history = await HistoryWriter.open(
      registry: registry,
      store: MemoryHistoryStore(),
    );
    query = AggregationQueryController(
      registry: registry,
      history: history,
      timeout: timeout,
    );
  }

  Future<void> close() async {
    query.dispose();
    await history.close();
    await a.server.close(force: true);
    await b.server.close(force: true);
  }
}

Future<void> _until(bool Function() predicate) async {
  for (var i = 0; i < 200; i++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('Expected state not reached');
}

void main() {
  late _Fixture f;
  test(
    'nextup uses allowed-library endpoint, keeps zero progress, pages and rejects late revoked response',
    () async {
      await f.open();
      f.a.items = (request) async {
        final p = request.uri.queryParameters;
        expect(request.uri.path, endsWith('/Shows/NextUp'));
        expect(p['ParentId'], 'library');
        expect(p['Filters'], isNull);
        final start = int.parse(p['StartIndex']!);
        return _page([
          _movie('episode-$start', type: 'Episode', provider: null),
        ], total: 3);
      };
      await f.query.start(
        QueryScope(
          region: AccessRegion.ordinary,
          serverIds: {'a'},
          mode: QueryMode.nextUp,
          pageSize: 1,
        ),
      );
      expect(f.query.items.map((i) => i.item.id), ['episode-0']);
      await f.query.loadMoreServer('a');
      expect(
        f.query.items.map((i) => i.item.id),
        containsAll(['episode-0', 'episode-1']),
      );
      final arrived = Completer<void>();
      final gate = Completer<void>();
      f.a.items = (_) async {
        arrived.complete();
        await gate.future;
        return _page([
          _movie('late', type: 'Episode', provider: null),
        ], total: 3);
      };
      final pending = f.query.loadMoreServer('a');
      await arrived.future;
      await f.access.setPin('1234', '1234', (_) async {});
      await f.access.unlock('1234');
      await f.registry.move('a', AccessRegion.private);
      gate.complete();
      await pending;
      expect(f.query.items, isEmpty);
    },
  );
  setUp(() {
    f = _Fixture();
  });
  tearDown(() async {
    await f.close();
  });

  test(
    'two independent controllers reuse existing playback permit without authentication or session replacement',
    () async {
      await f.open();
      f.a.items = (_) async => _page([_movie('one')], total: 1);
      final account = (await f.registry.authenticate('a')).account;
      final playing = f.registry.permit(account, libraryId: 'library');
      final infoCount = f.a.requests
          .where((r) => r.path.endsWith('/System/Info/Public'))
          .length;
      final second = AggregationQueryController(
        registry: f.registry,
        history: f.history,
      );
      addTearDown(second.dispose);
      await Future.wait([
        f.query.start(
          QueryScope(region: AccessRegion.ordinary, serverIds: {'a'}),
        ),
        second.start(
          QueryScope(region: AccessRegion.ordinary, serverIds: {'a'}),
        ),
      ]);
      expect(playing.isValid, isTrue);
      expect(f.query.items.single.reference.account, account);
      expect(second.items.single.reference.account, account);
      expect(
        f.a.requests
            .where((r) => r.path.endsWith('/System/Info/Public'))
            .length,
        infoCount,
      );
      expect(
        f.registry.sessionAccount(
          'a',
          region: AccessRegion.ordinary,
          libraryId: 'unknown',
        ),
        isNull,
      );
      await expectLater(
        f.registry.acquireAccount(
          'a',
          region: AccessRegion.ordinary,
          libraryId: 'unknown',
        ),
        throwsStateError,
      );
      expect(playing.isValid, isTrue);
    },
  );

  test(
    'concurrent initial query authentication is shared across independent controllers',
    () async {
      await f.open();
      final gate = Completer<void>();
      f.a.authenticationGate = () => gate.future;
      f.a.items = (_) async => _page([_movie('one')], total: 1);
      final second = AggregationQueryController(
        registry: f.registry,
        history: f.history,
      );
      addTearDown(second.dispose);
      final firstRun = f.query.start(
        QueryScope(region: AccessRegion.ordinary, serverIds: {'a'}),
      );
      final secondRun = second.start(
        QueryScope(region: AccessRegion.ordinary, serverIds: {'a'}),
      );
      await _until(() => f.a.requests.isNotEmpty);
      expect(
        f.a.requests.where((r) => r.path.endsWith('/System/Info/Public')),
        hasLength(1),
      );
      gate.complete();
      await Future.wait([firstRun, secondRun]);
      expect(f.query.items, hasLength(1));
      expect(second.items, hasLength(1));
      final account = f.query.items.single.reference.account;
      expect(f.registry.permit(account, libraryId: 'library').isValid, isTrue);
      expect(
        f.a.requests.where((r) => r.path.endsWith('/System/Info/Public')),
        hasLength(1),
      );
    },
  );

  test(
    'reentrant scope replacement from a listener cannot dispatch the unselected service',
    () async {
      await f.open();
      var replaced = false;
      Future<void>? replacement;
      f.query.addListener(() {
        if (!replaced && f.query.scope?.serverIds?.contains('b') == true) {
          replaced = true;
          replacement = f.query.start(
            QueryScope(region: AccessRegion.ordinary, serverIds: {'a'}),
          );
        }
      });
      await f.query.start(
        QueryScope(region: AccessRegion.ordinary, serverIds: {'b'}),
      );
      await replacement;
      expect(f.b.requests, isEmpty);
      expect(f.query.sources.single.key.serverId, 'a');
    },
  );

  test(
    'HTTP first successful service is usable before slower source; independent paging grows editions without duplicate cards',
    () async {
      await f.open();
      final gate = Completer<void>();
      f.a.items = (r) async =>
          int.parse(r.uri.queryParameters['StartIndex']!) == 0
          ? _page([_movie('one')], total: 1)
          : _page([], total: 1);
      f.b.items = (r) async {
        await gate.future;
        final cursor = int.parse(r.uri.queryParameters['StartIndex']!);
        return cursor == 0
            ? _page([_movie('two', provider: '2')], total: 2)
            : _page([_movie('edition')], total: 2);
      };
      final run = f.query.start(
        QueryScope(region: AccessRegion.ordinary, pageSize: 1),
      );
      await _until(() => f.query.items.length == 1);
      expect(f.query.summary, QuerySummary.available);
      expect(f.query.totalWorks, isNull);
      final anchor = f.query.items.single.reference;
      f.query.anchor = anchor;
      gate.complete();
      await run;
      expect(f.query.works, hasLength(2));
      await f.query.loadMore(const QuerySourceKey('b', 'library'));
      expect(f.query.works, hasLength(2));
      expect(f.query.resolveAnchor(anchor)!.sources, hasLength(2));
      expect(f.query.complete, isTrue);
      expect(f.query.totalWorks, 2);
      expect(f.query.anchor, anchor);
      expect(f.b.itemRequests.last.queryParameters['StartIndex'], '1');
    },
  );

  test(
    'HTTP local 401 does not expire sibling; single-source retry reauthenticates only failed service',
    () async {
      await f.open();
      f.a.items = (_) async => _page([_movie('one')], total: 1);
      f.b.status = 401;
      await f.query.start(QueryScope(region: AccessRegion.ordinary));
      expect(f.query.items, hasLength(1));
      expect(f.query.summary, QuerySummary.partialFailure);
      expect(f.query.sources.last.status, SourceQueryStatus.needsLogin);
      final aRequests = f.a.requests.length;
      f.b.status = 200;
      f.b.items = (_) async => _page([_movie('two')], total: 1);
      await f.query.retry(const QuerySourceKey('b', 'library'));
      expect(f.a.requests.length, aRequests);
      expect(f.query.works.single.sources, hasLength(2));
      expect(f.query.complete, isTrue);
    },
  );

  test(
    'HTTP timeout preserves success and retry rejects original late page',
    () async {
      await f.open(timeout: const Duration(milliseconds: 100));
      final gate = Completer<void>();
      f.a.items = (_) async => _page([_movie('one')], total: 1);
      f.b.items = (_) async {
        await gate.future;
        return _page([_movie('late', provider: '5')], total: 1);
      };
      await f.query.start(QueryScope(region: AccessRegion.ordinary));
      expect(f.query.sources.last.status, SourceQueryStatus.timeout);
      expect(f.query.items, hasLength(1));
      f.b.items = (_) async => _page([_movie('retry')], total: 1);
      await f.query.retry(const QuerySourceKey('b', 'library'));
      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        f.query.items.map((i) => i.reference.itemId),
        unorderedEquals(['one', 'retry']),
      );
    },
  );

  test(
    'keyword/scope changes synchronously remove errors counts and rows; unselected service has no HTTP',
    () async {
      await f.open();
      f.a.items = (_) async => _page([_movie('old')], total: 1);
      f.b.status = 403;
      await f.query.start(QueryScope(region: AccessRegion.ordinary));
      final old = Completer<void>();
      f.a.items = (_) async {
        await old.future;
        return _page([_movie('stale')], total: 100);
      };
      final pending = f.query.start(
        QueryScope(
          region: AccessRegion.ordinary,
          mode: QueryMode.search,
          keyword: 'old',
          serverIds: {'a'},
        ),
      );
      await _until(() => f.a.itemRequests.length == 2);
      final bCount = f.b.requests.length;
      f.a.items = (_) async => _page([_movie('fresh')]);
      final fresh = f.query.start(
        QueryScope(
          region: AccessRegion.ordinary,
          mode: QueryMode.search,
          keyword: 'new',
          serverIds: {'a'},
        ),
      );
      expect(f.query.items, isEmpty);
      expect(f.query.totalWorks, isNull);
      expect(
        f.query.sources.every((s) => s.total == null && !s.failed),
        isTrue,
      );
      await fresh;
      old.complete();
      await pending;
      expect(f.query.items.single.reference.itemId, 'fresh');
      expect(f.b.requests.length, bCount);
      expect(f.a.itemRequests.last.queryParameters['SearchTerm'], 'new');
      // Unknown server total stays unknown even when a short page exhausts it.
      expect(f.query.sources.single.total, isNull);
      expect(f.query.complete, isTrue);
      await f.query.start(
        QueryScope(region: AccessRegion.ordinary, serverIds: {}),
      );
      expect(f.query.summary, QuerySummary.emptyScope);
    },
  );

  test(
    'source filters precede reliable merge, server library scope never widens',
    () async {
      await f.open();
      f.a.items = (_) async => _page([
        _movie('allowed'),
        _movie('wrong-year', year: 2024),
      ], total: 2);
      f.b.items = (_) async => _page([_movie('edition', year: 2024)], total: 1);
      await f.query.start(
        QueryScope(
          region: AccessRegion.ordinary,
          years: {2025},
          genres: {'Drama'},
          libraries: {
            'a': {'library', 'unknown'},
            'b': {'unknown'},
          },
        ),
      );
      expect(f.query.items.single.reference.itemId, 'allowed');
      expect(f.query.works.single.sources, hasLength(1));
      expect(f.b.requests, isEmpty);
      expect(f.a.itemRequests.single.queryParameters['ParentId'], 'library');
      expect(f.a.itemRequests.single.queryParameters['Years'], '2025');
      await f.registry.configureScope('a', participates: true, libraryIds: {});
      expect(f.query.items, isEmpty);
      expect(f.query.sources, isEmpty);
    },
  );

  test(
    'empty and all-failed differ; failure retry does not clear siblings',
    () async {
      await f.open();
      await f.query.start(QueryScope(region: AccessRegion.ordinary));
      expect(f.query.summary, QuerySummary.empty);
      f.a.status = 403;
      f.b.status = 403;
      await f.query.start(QueryScope(region: AccessRegion.ordinary));
      expect(f.query.summary, QuerySummary.allFailed);
      expect(f.query.totalWorks, isNull);
    },
  );

  test(
    'private lock rejects HTTP late data and ordinary projection excludes unlocked private membership',
    () async {
      await f.open(privateB: true);
      await f.query.start(QueryScope(region: AccessRegion.ordinary));
      expect(f.b.requests, isEmpty);
      final gate = Completer<void>();
      f.b.items = (_) async {
        await gate.future;
        return _page([_movie('secret')], total: 7);
      };
      final run = f.query.start(QueryScope(region: AccessRegion.private));
      await _until(() => f.b.itemRequests.isNotEmpty);
      await f.access.lock();
      final requestCount = f.b.requests.length;
      expect(
        f.registry.sessionAccount(
          'b',
          region: AccessRegion.private,
          libraryId: 'library',
        ),
        isNull,
      );
      expect(
        f.registry.sessionAccount(
          'b',
          region: AccessRegion.ordinary,
          libraryId: 'library',
        ),
        isNull,
      );
      await expectLater(
        f.registry.acquireAccount(
          'b',
          region: AccessRegion.private,
          libraryId: 'library',
        ),
        throwsStateError,
      );
      expect(f.b.requests.length, requestCount);
      expect(f.query.items, isEmpty);
      expect(f.query.sources, isEmpty);
      gate.complete();
      await run;
      expect(f.query.items, isEmpty);
      expect(f.query.totalWorks, isNull);
    },
  );

  test(
    'membership migration evicts contributions before commit and rejects in-flight result',
    () async {
      await f.open(privateB: true);
      final gate = Completer<void>();
      f.a.items = (_) async {
        await gate.future;
        return _page([_movie('moved')], total: 1);
      };
      final run = f.query.start(QueryScope(region: AccessRegion.ordinary));
      await _until(() => f.a.itemRequests.isNotEmpty);
      await f.registry.move('a', AccessRegion.private);
      gate.complete();
      await run;
      expect(f.query.sources, isEmpty);
      expect(f.query.items, isEmpty);
    },
  );

  test(
    'T3 records projected by actual source/selected scope; lock prevents stale history access',
    () async {
      await f.open(privateB: true);
      final account = (await f.registry.authenticate('b')).account;
      final version = SourceReference(
        account: account,
        itemId: 'one',
        mediaSourceId: 'v',
      );
      final session = await f.history.beginSession(
        source: version,
        work: version.item,
        libraryId: 'library',
      );
      await f.history.observe(
        session: session,
        eventSequence: 1,
        positionTicks: 100,
        actuallyPlaying: true,
        timeline: const WatchTimeline(durationTicks: 1000),
      );
      await f.query.start(QueryScope(region: AccessRegion.ordinary));
      expect(f.query.localContinueWatching, isEmpty);
      await f.query.start(
        QueryScope(
          region: AccessRegion.private,
          mode: QueryMode.continueWatching,
        ),
      );
      expect(f.query.localContinueWatching.single.source, version);
      await f.access.lock();
      expect(f.query.localContinueWatching, isEmpty);
    },
  );

  for (final inFlight in [false, true]) {
    test(
      'paged conflict revokes ${inFlight ? 'in-flight' : 'cached'} episode confirmation',
      () async {
        await f.open();
        final originRow = _movie('z-origin', type: 'Series')
          ..['ProviderIds'] = {'Tmdb': '1', 'Tvdb': '2'};
        final conflictRow = _movie('a-conflict', type: 'Series')
          ..['ProviderIds'] = {'Tmdb': '1', 'Tvdb': '3'};
        f.a.items = (_) async => _page([originRow], total: 1);
        await f.query.start(
          QueryScope(
            region: AccessRegion.ordinary,
            serverIds: {'a'},
            types: {'Series'},
          ),
        );
        final seed = f.query.items.single;
        f.a.items = (r) async => _page([
          r.uri.queryParameters['StartIndex'] == '0' ? originRow : conflictRow,
        ], total: 2);
        final entered = Completer<void>();
        final release = Completer<void>();
        f.b.items = (r) async {
          if (r.uri.queryParameters['ParentId'] != 'target') {
            return _page([_movie('target', type: 'Series')], total: 1);
          }
          if (!entered.isCompleted) entered.complete();
          if (inFlight) await release.future;
          return _page([
            {
              'Id': 'target-e1',
              'Name': 'E1',
              'Type': 'Episode',
              'SeriesId': 'target',
              'ParentIndexNumber': 1,
              'IndexNumber': 1,
            },
          ], total: 1);
        };
        final detail = SameSourceQueryController(
          registry: f.registry,
          history: f.history,
        );
        addTearDown(detail.dispose);
        await detail.start(
          origin: seed,
          scope: QueryScope(region: AccessRegion.ordinary, pageSize: 1),
        );
        final target = detail.comparisons.single.source;
        expect(detail.comparisons.single.decision.confirmed, isTrue);
        final episode = EpisodeSource(
          reference: SourceReference(
            account: seed.reference.account,
            itemId: 'origin-e1',
          ),
          series: seed.reference,
          season: 1,
          episode: 1,
          isSpecial: false,
          numberingScheme: 'aired',
        );
        final lookup = detail.lookupEpisode(
          target: target,
          episode: episode,
          verifiedNumberingScheme: 'aired',
        );
        await entered.future;
        if (!inFlight) {
          await lookup;
          expect(
            detail.episodes.single.lookup.status,
            EpisodeLookupStatus.confirmed,
          );
        }
        await detail.loadMore(const QuerySourceKey('a', 'library'));
        expect(
          detail.comparisons
              .firstWhere((c) => c.source.reference == target.reference)
              .decision
              .confirmed,
          isFalse,
        );
        expect(detail.episodes, isEmpty);
        await expectLater(
          detail.lookupEpisode(target: target, episode: episode),
          throwsStateError,
        );
        if (inFlight) {
          // A relation restored while the retired request is still pending
          // cannot resurrect its result (or reuse its attempt token).
          f.a.items = (_) async => _page([
            Map<String, dynamic>.from(conflictRow)
              ..['ProviderIds'] = {'Tmdb': '1', 'Tvdb': '2'},
          ], total: 3);
          await detail.retry(const QuerySourceKey('a', 'library'));
          expect(
            detail.comparisons
                .firstWhere((c) => c.source.reference == target.reference)
                .decision
                .confirmed,
            isTrue,
          );
          release.complete();
        }
        await lookup;
        expect(detail.episodes, isEmpty);
        // Once conflicts disappear, only a new lookup may restore confirmation.
        f.a.items = (_) async => _page([originRow], total: 1);
        await detail.start(
          origin: seed,
          scope: QueryScope(region: AccessRegion.ordinary, pageSize: 1),
        );
        expect(detail.episodes, isEmpty);
        await detail.lookupEpisode(
          target: target,
          episode: episode,
          verifiedNumberingScheme: 'aired',
        );
        expect(
          detail.episodes.single.lookup.status,
          EpisodeLookupStatus.confirmed,
        );
      },
    );
  }

  test(
    'malformed provider aliases fail only their source and corrected retry is atomic',
    () async {
      await f.open();
      f.a.items = (_) async => _page([_movie('good')], total: 1);
      f.b.items = (_) async => _page([
        _movie('valid-before-malformed'),
        _movie('bad')..['ProviderIds'] = {'Tmdb': '1', 'tmdb': '2'},
      ], total: 2);
      await f.query.start(QueryScope(region: AccessRegion.ordinary));
      expect(f.query.summary, QuerySummary.partialFailure);
      expect(
        f.query.sources.firstWhere((s) => s.key.serverId == 'b').status,
        SourceQueryStatus.failed,
      );
      expect(
        f.query.sources.firstWhere((s) => s.key.serverId == 'b').cursor,
        0,
      );
      expect(f.query.items.single.reference.itemId, 'good');
      expect(f.query.works.single.sources.single.reference.itemId, 'good');
      f.b.items = (_) async => _page([_movie('repaired')], total: 1);
      await f.query.retry(const QuerySourceKey('b', 'library'));
      expect(f.query.summary, QuerySummary.available);
      expect(f.query.items, hasLength(2));
      expect(f.query.works.single.sources, hasLength(2));
      expect(f.b.itemRequests.last.queryParameters['StartIndex'], '0');
    },
  );

  test(
    'malformed discovery page retains cached editions and retries at unchanged cursor',
    () async {
      await f.open();
      f.a.items = (_) async =>
          _page([_movie('origin', type: 'Series')], total: 1);
      await f.query.start(
        QueryScope(
          region: AccessRegion.ordinary,
          serverIds: {'a'},
          types: {'Series'},
        ),
      );
      final detail = SameSourceQueryController(
        registry: f.registry,
        history: f.history,
      );
      addTearDown(detail.dispose);
      f.b.items = (_) async =>
          _page([_movie('cached', type: 'Series')], total: 2);
      await detail.start(
        origin: f.query.items.single,
        scope: QueryScope(region: AccessRegion.ordinary, pageSize: 1),
      );
      f.b.items = (_) async => _page([
        _movie('cached', type: 'Series', provider: '2'),
        _movie('bad', type: 'Series')
          ..['ProviderIds'] = {'Tmdb': '1', 'tmdb': '2'},
      ], total: 3);
      await detail.loadMore(const QuerySourceKey('b', 'library'));
      expect(
        detail.sources.firstWhere((s) => s.key.serverId == 'b').status,
        SourceQueryStatus.failed,
      );
      expect(detail.sources.firstWhere((s) => s.key.serverId == 'b').cursor, 1);
      expect(detail.comparisons.single.decision.confirmed, isTrue);
      expect(detail.query.works.single.sources, hasLength(2));
      expect(detail.episodes, isEmpty);
      f.b.items = (_) async =>
          _page([_movie('repaired', type: 'Series')], total: 2);
      await detail.retry(const QuerySourceKey('b', 'library'));
      expect(f.b.itemRequests.last.queryParameters['StartIndex'], '1');
      expect(detail.comparisons, hasLength(2));
      expect(detail.comparisons.every((c) => c.decision.confirmed), isTrue);
      expect(detail.complete, isTrue);
    },
  );

  test(
    'independent detail lookup separates title candidates, preserves unknown version data and missing/uncertain episodes',
    () async {
      await f.open();
      f.a.items = (_) async =>
          _page([_movie('series-a', type: 'Series')], total: 1);
      f.b.items = (_) async => _page([
        _movie('series-b', title: 'Localized', type: 'Series'),
        _movie('candidate', type: 'Series', provider: null),
      ], total: 2);
      await f.query.start(
        QueryScope(
          region: AccessRegion.ordinary,
          types: {'Series'},
          serverIds: {'a'},
        ),
      );
      final seed = f.query.items.single;
      final detail = SameSourceQueryController(
        registry: f.registry,
        history: f.history,
      );
      addTearDown(detail.dispose);
      await detail.start(
        origin: seed,
        scope: QueryScope(region: AccessRegion.ordinary, serverIds: {'a', 'b'}),
      );
      expect(
        detail.comparisons.where((c) => c.decision.confirmed),
        hasLength(1),
      );
      expect(
        detail.comparisons.where((c) => c.decision.kind == MatchKind.candidate),
        hasLength(1),
      );
      expect(detail.comparisons.first.source.item.mediaSources, isEmpty);
      expect(f.query.items.single.reference, seed.reference);
      final target = detail.comparisons
          .firstWhere((c) => c.decision.confirmed)
          .source;
      final episode = EpisodeSource(
        reference: SourceReference(
          account: seed.reference.account,
          itemId: 'e1',
        ),
        series: seed.reference,
        season: 1,
        episode: 1,
        isSpecial: false,
        numberingScheme: 'aired',
      );
      f.b.items = (_) async => _page([], total: 0);
      await detail.lookupEpisode(
        target: target,
        episode: episode,
        verifiedNumberingScheme: 'aired',
      );
      expect(detail.episodes.single.lookup.status, EpisodeLookupStatus.missing);
      expect(detail.episodes.single.lookup.source, isNull);
      f.b.items = (_) async => _page([
        {'Id': 'unknown', 'Name': 'Unknown'},
      ], total: 1);
      await detail.lookupEpisode(
        target: target,
        episode: episode,
        verifiedNumberingScheme: 'aired',
      );
      expect(
        detail.episodes.single.lookup.status,
        EpisodeLookupStatus.uncertain,
      );
      expect(detail.episodes.single.lookup.source, isNull);
      final failed = Completer<void>();
      f.b.items = (_) async {
        await failed.future;
        return _page([], total: 0);
      };
      // Timeout is separate from discovery's successful comparison rows.
      // A second detail controller gives this probe a short bounded timeout.
      final short = SameSourceQueryController(
        registry: f.registry,
        history: f.history,
        timeout: const Duration(milliseconds: 100),
      );
      addTearDown(short.dispose);
      short.query.useAccount(
        target.reference.account,
        libraryId: target.libraryId,
      );
      f.b.items = (_) async => _page([
        _movie('series-b', title: 'Localized', type: 'Series'),
      ], total: 1);
      await short.start(
        origin: seed,
        scope: QueryScope(region: AccessRegion.ordinary, serverIds: {'b'}),
      );
      f.b.items = (_) async {
        await failed.future;
        return _page([], total: 0);
      };
      await short.lookupEpisode(
        target: target,
        episode: episode,
        verifiedNumberingScheme: 'aired',
      );
      expect(short.episodes.single.status, SourceQueryStatus.timeout);
      expect(short.comparisons.single.decision.confirmed, isTrue);
      f.b.items = (_) async => _page([], total: 0);
      await short.lookupEpisode(
        target: target,
        episode: episode,
        verifiedNumberingScheme: 'aired',
      );
      expect(short.episodes.single.lookup.status, EpisodeLookupStatus.missing);
      failed.complete();
      f.b.items = (_) async => _page([
        {
          'Id': 'e1-b',
          'Name': 'E',
          'Type': 'Episode',
          'SeriesId': 'series-b',
          'ParentIndexNumber': 1,
          'IndexNumber': 1,
        },
      ], total: 1);
      await detail.lookupEpisode(target: target, episode: episode);
      expect(
        detail.episodes.single.lookup.status,
        EpisodeLookupStatus.uncertain,
      );
      await detail.lookupEpisode(
        target: target,
        episode: episode,
        verifiedNumberingScheme: 'aired',
      );
      expect(
        detail.episodes.single.lookup.status,
        EpisodeLookupStatus.confirmed,
      );
      expect(
        detail.episodes.single.lookup.source!.reference.account,
        target.reference.account,
      );
      await expectLater(
        detail.lookupEpisode(
          target: detail.comparisons
              .firstWhere((c) => c.decision.kind == MatchKind.candidate)
              .source,
          episode: episode,
        ),
        throwsStateError,
      );
      expect(
        () => detail.start(
          origin: seed,
          scope: QueryScope(region: AccessRegion.private),
        ),
        throwsArgumentError,
      );
    },
  );
}
