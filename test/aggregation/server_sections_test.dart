import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/aggregation/view/server_sections.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/region_access.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/auth/source_sessions.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/library/shelf_sort.dart';

Map<String, dynamic> _item(
  String id,
  String type, {
  String? name,
  int? year,
  String? seriesId,
  int? season,
  int? episode,
  String? collectionType,
}) => {
  'Id': id,
  'Name': name ?? id,
  'Type': type,
  'ProductionYear': ?year,
  'SeriesId': ?seriesId,
  'ParentIndexNumber': ?season,
  'IndexNumber': ?episode,
  'CollectionType': ?collectionType,
};

Map<String, dynamic> _page(List<Map<String, dynamic>> items, {int? total}) => {
  'Items': items,
  'TotalRecordCount': total ?? items.length,
};

class _Source {
  _Source(this.id, this.name);

  final String id;
  final String name;
  late HttpServer server;
  final List<Uri> requests = [];
  bool failCatalog = false;
  bool failResume = false;
  bool failFavorites = false;
  bool forbidPublicInfo = false;
  int nextUpStatus = 200;
  bool rich = true;
  Completer<void>? favoritesGate;
  final List<({Uri uri, String? userAgent, String? token})> seen = [];

  Future<void> open() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requests.add(request.uri);
      seen.add((
        uri: request.uri,
        userAgent: request.headers.value(HttpHeaders.userAgentHeader),
        token: request.headers.value('x-emby-token'),
      ));
      final path = request.uri.path;
      if (request.uri.queryParameters['Filters'] == 'IsFavorite') {
        await favoritesGate?.future;
      }
      Object data = {'Id': 'user-$id', 'Name': 'user'};
      var code = 200;
      if (path.endsWith('/System/Info/Public')) {
        data = {'Id': id, 'ServerName': name};
        if (forbidPublicInfo) code = 403;
      } else if (path.endsWith('/Items/Resume')) {
        code = failCatalog || failResume ? 500 : 200;
        data = _page(
          rich
              ? [
                  _item(
                    'ep-1',
                    'Episode',
                    seriesId: 'series-1',
                    season: 1,
                    episode: 2,
                    year: 2020,
                  ),
                  _item('movie-1', 'Movie', year: 2019),
                  _item('song', 'Audio'),
                ]
              : [_item('movie-$id', 'Movie', year: 2024)],
          total: 100,
        );
      } else if (path.endsWith('/Shows/NextUp')) {
        code = failCatalog ? 500 : nextUpStatus;
        data = _page(
          rich
              ? [
                  _item(
                    'ep-9',
                    'Episode',
                    seriesId: 'series-1',
                    season: 1,
                    episode: 3,
                  ),
                  _item(
                    'ep-3',
                    'Episode',
                    seriesId: 'series-2',
                    season: 2,
                    episode: 1,
                  ),
                ]
              : const [],
        );
      } else if (path.endsWith('/Views')) {
        code = failCatalog ? 500 : 200;
        data = _page(
          rich
              ? [
                  _item(
                    'lib-movies',
                    'CollectionFolder',
                    collectionType: 'movies',
                  ),
                  _item(
                    'lib-tv',
                    'CollectionFolder',
                    collectionType: 'tvshows',
                  ),
                  _item(
                    'lib-music',
                    'CollectionFolder',
                    collectionType: 'music',
                  ),
                  _item(
                    'lib-photos',
                    'CollectionFolder',
                    collectionType: 'photos',
                  ),
                  _item('lib-mixed', 'CollectionFolder'),
                ]
              : [
                  _item(
                    'lib-$id',
                    'CollectionFolder',
                    collectionType: 'movies',
                  ),
                ],
        );
      } else if (path.endsWith('/Items')) {
        final parent = request.uri.queryParameters['ParentId'];
        if (parent != null) {
          data = _page([_item('child-movie', 'Movie', year: 2018)]);
        } else {
          code = failCatalog || failFavorites ? 500 : 200;
          data = _page(
            rich
                ? [
                    _item('fav-movie', 'Movie', year: 2017),
                    _item('fav-series', 'Series', year: 2021),
                    _item('fav-episode', 'Episode', season: 1, episode: 4),
                    _item('fav-audio', 'Audio'),
                    _item('fav-photo', 'Photo'),
                  ]
                : [_item('fav-$id', 'Series', year: 2022)],
            total: 80,
          );
        }
      }
      try {
        request.response.statusCode = code;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(data));
        await request.response.close();
      } catch (_) {
        /* client timed out or closed */
      }
    });
  }

  String get address => 'http://127.0.0.1:${server.port}';

  List<Uri> wherePath(String suffix) =>
      requests.where((uri) => uri.path.endsWith(suffix)).toList();

  List<Uri> get favoriteQueries => requests
      .where(
        (uri) =>
            uri.path.endsWith('/Items') &&
            !uri.path.endsWith('/Items/Resume') &&
            uri.queryParameters['ParentId'] == null,
      )
      .toList();
}

class _Harness {
  final sources = <_Source>[];
  late RegionAccessController access;
  late SourceSessionRegistry registry;
  late ServerSectionsLoader loader;

  Future<_Source> add(String id, String name) async {
    final source = _Source(id, name);
    await source.open();
    sources.add(source);
    return source;
  }

  Future<void> start({
    bool includeLoggedOut = false,
    bool includePrivate = false,
    String? userAgent,
  }) async {
    final alpha = await add('alpha', 'Alpha');
    final beta = await add('beta', 'Beta');
    _Source? loggedOut;
    _Source? private;
    if (includeLoggedOut) {
      loggedOut = await add('gamma', 'Gamma');
    }
    if (includePrivate) {
      private = await add('private', 'Private');
    }
    final listed = [alpha, beta, ?loggedOut, ?private];
    access = RegionAccessController();
    registry = SourceSessionRegistry(
      access: access,
      store: MemoryServerListStore(
        ServerListSnapshot(
          servers: [
            for (final source in listed)
              SavedServer(
                id: source.id,
                name: source.name,
                username: 'user',
                region: source.id == 'private'
                    ? AccessRegion.private
                    : AccessRegion.ordinary,
                participates: false,
                scopeKnown: false,
                libraryIds: const [],
                userAgent: userAgent,
                lines: [ServerLine(id: 'line', address: source.address)],
              ),
          ],
        ),
      ),
      credentials: MemoryCredentialStore({
        for (final source in listed)
          if (source.id != 'gamma')
            source.id: StoredCredentials(
              accessToken: 'token-${source.id}',
              userId: 'user-${source.id}',
              username: 'user',
            ),
      }),
      createClient: () => EmbyClient(
        device: const EmbyDeviceInfo(
          clientName: 'section-test',
          deviceName: 'test',
          deviceId: 'test',
          version: '1',
        ),
      ),
    );
    await registry.load();
    loader = ServerSectionsLoader(registry: registry);
  }

  _Source source(String id) => sources.singleWhere((item) => item.id == id);

  Future<void> close() async {
    loader.dispose();
    for (final source in sources) {
      await source.server.close(force: true);
    }
  }
}

void main() {
  test('each module publishes without waiting for a slow sibling', () async {
    final harness = _Harness();
    await harness.start();
    addTearDown(harness.close);
    final gate = Completer<void>();
    harness.source('alpha').favoritesGate = gate;
    final ready = Completer<void>();
    harness.loader.addListener(() {
      final alpha = harness.loader.servers
          .where((section) => section.serverId == 'alpha')
          .firstOrNull;
      if (alpha != null &&
          !alpha.continueWatching.loading &&
          alpha.continueWatching.items.isNotEmpty &&
          !alpha.libraries.loading &&
          alpha.libraries.items.isNotEmpty &&
          alpha.favorites.loading &&
          !ready.isCompleted) {
        ready.complete();
      }
    });
    final loading = harness.loader.load();
    try {
      await ready.future.timeout(const Duration(seconds: 2));
    } finally {
      gate.complete();
      await loading;
    }
    expect(harness.loader.servers.first.favorites.items, isNotEmpty);
  });

  test(
    'logged-in ordinary servers load rows without a scope selection',
    () async {
      final harness = _Harness();
      await harness.start(includeLoggedOut: true, includePrivate: true);
      addTearDown(harness.close);
      final alpha = harness.source('alpha');
      final beta = harness.source('beta');
      beta.rich = false;

      await harness.loader.load();

      expect(harness.loader.loading, isFalse);
      expect(harness.loader.servers.map((item) => item.serverId), [
        'alpha',
        'beta',
      ]);
      expect(harness.loader.servers.map((item) => item.serverName), [
        'Alpha',
        'Beta',
      ]);
      final first = harness.loader.servers.first;
      expect(first.account?.configuredServerId, 'alpha');
      expect(first.account?.userId, 'user-alpha');
      expect(first.account?.region, AccessRegion.ordinary);
      expect(first.continueWatching.error, isNull);
      expect(first.continueWatching.items.map((item) => item.id), [
        'ep-1',
        'movie-1',
        'ep-3',
      ]);
      expect(
        aggregationContinueCaption(first.continueWatching.items[0]),
        'S1E2',
      );
      expect(
        aggregationContinueCaption(first.continueWatching.items[1]),
        '2019',
      );
      expect(
        aggregationContinueCaption(first.continueWatching.items[2]),
        'S2E1',
      );
      expect(first.favorites.error, isNull);
      expect(first.favorites.items.map((item) => item.id), [
        'fav-movie',
        'fav-series',
      ]);
      expect(aggregationContinueCaption(first.favorites.items[1]), '2021');
      expect(first.libraries.error, isNull);
      expect(first.libraries.items.map((item) => item.id), [
        'lib-movies',
        'lib-tv',
        'lib-mixed',
      ]);

      final resume = alpha.wherePath('/Items/Resume').single;
      expect(resume.queryParameters['ParentId'], isNull);
      expect(resume.queryParameters['Limit'], '$aggregationRowLimit');
      expect(resume.queryParameters.containsKey('StartIndex'), isFalse);
      final nextUp = alpha.wherePath('/Shows/NextUp').single;
      expect(nextUp.queryParameters['ParentId'], isNull);
      expect(nextUp.queryParameters['UserId'], 'user-alpha');
      final favorite = alpha.favoriteQueries.single;
      expect(favorite.queryParameters['Filters'], 'IsFavorite');
      expect(
        favorite.queryParameters['Filters'],
        CatalogWatchFilter.favorite.param,
      );
      expect(favorite.queryParameters['IncludeItemTypes'], 'Movie,Series');
      expect(favorite.queryParameters['Recursive'], 'true');
      expect(favorite.queryParameters['Limit'], '$aggregationRowLimit');
      expect(favorite.queryParameters['ParentId'], isNull);
      expect(favorite.queryParameters.containsKey('StartIndex'), isFalse);
      expect(
        alpha.requests
            .where((uri) => uri.queryParameters['ParentId'] != null)
            .map((uri) => uri.queryParameters['ParentId']),
        ['lib-mixed'],
      );
      expect(harness.source('gamma').wherePath('/Items/Resume'), isEmpty);
      expect(harness.source('private').requests, isEmpty);
      expect(beta.favoriteQueries, hasLength(1));
      expect(
        harness.loader.servers[1].continueWatching.items.single.id,
        'movie-beta',
      );
      expect(harness.loader.servers[1].favorites.items.single.id, 'fav-beta');
      expect(harness.loader.servers[1].libraries.items.single.id, 'lib-beta');
      expect(harness.loader.servers[1].failed, isFalse);
    },
  );

  test('one server failure keeps the other and retries only itself', () async {
    final harness = _Harness();
    await harness.start();
    addTearDown(harness.close);
    final alpha = harness.source('alpha');
    final beta = harness.source('beta');
    beta.rich = false;
    beta.failCatalog = true;

    await harness.loader.load();

    final loadedAlpha = harness.loader.servers.singleWhere(
      (item) => item.serverId == 'alpha',
    );
    final failedBeta = harness.loader.servers.singleWhere(
      (item) => item.serverId == 'beta',
    );
    expect(loadedAlpha.continueWatching.items.map((item) => item.id), [
      'ep-1',
      'movie-1',
      'ep-3',
    ]);
    expect(loadedAlpha.failed, isFalse);
    expect(failedBeta.continueWatching.error, isNotNull);
    expect(failedBeta.favorites.error, isNotNull);
    expect(failedBeta.libraries.error, isNotNull);
    expect(failedBeta.continueWatching.items, isEmpty);

    beta.failCatalog = false;
    final resumeCount = alpha.wherePath('/Items/Resume').length;
    final alphaIds = loadedAlpha.continueWatching.items
        .map((item) => item.id)
        .toList();
    final seenAlpha = <List<String>>[];
    harness.loader.addListener(() {
      final current = harness.loader.servers
          .where((item) => item.serverId == 'alpha')
          .firstOrNull;
      final ids = harness.loader.servers.map((item) => item.serverId).toList();
      expect(ids, contains('alpha'));
      expect(ids, contains('beta'));
      if (current != null) {
        seenAlpha.add(
          current.continueWatching.items.map((item) => item.id).toList(),
        );
      }
    });

    await harness.loader.retry('beta');

    expect(seenAlpha, isNotEmpty);
    expect(seenAlpha, everyElement(alphaIds));
    expect(alpha.wherePath('/Items/Resume'), hasLength(resumeCount));
    final retried = harness.loader.servers.singleWhere(
      (item) => item.serverId == 'beta',
    );
    expect(retried.failed, isFalse);
    expect(retried.continueWatching.items.single.id, 'movie-beta');
    expect(retried.favorites.items.single.id, 'fav-beta');
    expect(retried.libraries.items.single.id, 'lib-beta');
    expect(
      harness.loader.servers.first.continueWatching.items.map(
        (item) => item.id,
      ),
      alphaIds,
    );
  });

  test(
    'a failed favorites row keeps that server resume and libraries',
    () async {
      final harness = _Harness();
      await harness.start();
      addTearDown(harness.close);
      harness.source('alpha').failFavorites = true;
      harness.source('beta').rich = false;

      await harness.loader.load();

      final alpha = harness.loader.servers.first;
      expect(alpha.continueWatching.items, isNotEmpty);
      expect(alpha.continueWatching.error, isNull);
      expect(
        alpha.libraries.items.map((item) => item.id),
        contains('lib-movies'),
      );
      expect(alpha.libraries.error, isNull);
      expect(alpha.favorites.error, isNotNull);
      expect(alpha.favorites.items, isEmpty);
      expect(harness.loader.servers[1].favorites.items.single.id, 'fav-beta');

      harness.source('alpha').failFavorites = false;
      await harness.loader.retry('alpha');

      final retried = harness.loader.servers.singleWhere(
        (item) => item.serverId == 'alpha',
      );
      expect(retried.favorites.items.map((item) => item.id), [
        'fav-movie',
        'fav-series',
      ]);
      expect(retried.continueWatching.items.map((item) => item.id), [
        'ep-1',
        'movie-1',
        'ep-3',
      ]);
      expect(harness.loader.servers[1].favorites.items.single.id, 'fav-beta');
    },
  );

  test('unsupported NextUp still keeps the resume row', () async {
    final harness = _Harness();
    await harness.start();
    addTearDown(harness.close);
    harness.source('alpha').nextUpStatus = 404;
    harness.source('beta').rich = false;

    await harness.loader.load();

    final alpha = harness.loader.servers.first;
    expect(alpha.continueWatching.error, isNull);
    expect(alpha.continueWatching.items.map((item) => item.id), [
      'ep-1',
      'movie-1',
    ]);
  });

  test('NextUp 500 still keeps resume items', () async {
    final harness = _Harness();
    await harness.start();
    addTearDown(harness.close);
    harness.source('alpha').nextUpStatus = 500;
    harness.source('beta').rich = false;

    await harness.loader.load();

    final alpha = harness.loader.servers.first;
    expect(alpha.continueWatching.error, isNull);
    expect(alpha.continueWatching.items.map((item) => item.id), [
      'ep-1',
      'movie-1',
    ]);
  });

  test('resume failure still keeps next up items', () async {
    final harness = _Harness();
    await harness.start();
    addTearDown(harness.close);
    harness.source('alpha').failResume = true;
    harness.source('beta').rich = false;

    await harness.loader.load();

    final alpha = harness.loader.servers.first;
    expect(alpha.continueWatching.error, isNull);
    expect(alpha.continueWatching.items.map((item) => item.id), [
      'ep-9',
      'ep-3',
    ]);
  });

  test('stored token is reused with the configured user agent', () async {
    final harness = _Harness();
    await harness.start(userAgent: 'Youno/1.0');
    addTearDown(harness.close);
    final alpha = harness.source('alpha');
    final beta = harness.source('beta');
    alpha.forbidPublicInfo = true;
    beta.forbidPublicInfo = true;
    beta.rich = false;

    await harness.loader.load();

    expect(harness.loader.servers.map((item) => item.serverId), [
      'alpha',
      'beta',
    ]);
    expect(harness.loader.servers.first.continueWatching.error, isNull);
    expect(harness.loader.servers.first.continueWatching.items, isNotEmpty);
    final first = await harness.registry.ensureSession('alpha');
    final second = await harness.registry.ensureSession('alpha');
    expect(identical(first.client, second.client), isTrue);
    await harness.loader.load();

    for (final source in [alpha, beta]) {
      expect(
        source.seen.where(
          (item) => item.uri.path.endsWith('/System/Info/Public'),
        ),
        isEmpty,
      );
      expect(
        source.seen.where(
          (item) => item.uri.path.endsWith('/Users/user-${source.id}'),
        ),
        isEmpty,
      );
      final resumes = source.seen.where(
        (item) => item.uri.path.endsWith('/Items/Resume'),
      );
      expect(resumes, isNotEmpty);
      for (final item in resumes) {
        expect(item.userAgent, 'Youno/1.0');
        expect(item.token, 'token-${source.id}');
      }
    }
  });
}
