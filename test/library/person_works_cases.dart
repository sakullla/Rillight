import '../helpers/widget_harness.dart';
import 'package:rillight/media_server/device.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;
import 'package:rillight/app/app.dart';
import 'package:rillight/app/l10n/app_localizations_zh.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/emby/catalog_cache.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/media_server/models.dart';
import 'package:rillight/library/person_works_controller.dart';
import 'package:rillight/library/person_works_page.dart';
import 'package:rillight/aggregation/identity/media_identity.dart';
import 'package:rillight/player/player_host_command.dart';

import '../emby/fake_emby_server.dart';
import '../helpers/image_cache_fixture.dart';
import '../helpers/synthetic_source_fixture.dart';

const _device = ClientDeviceInfo(
  clientName: '灯川 Rillight',
  deviceName: 'test',
  deviceId: 'person-works',
  version: '0.1.0',
);

void main() {
  setUp(isolateImageCache);

  test('arrange re-sorts each merged page and drops non-works', () {
    MediaItem movie(String id, String name, DateTime? date) =>
        MediaItem(id: id, name: name, type: 'Movie', premiereDate: date);
    final page = [
      movie('b', 'B 未定档', null),
      movie('a', 'A 未定档', null),
      movie('new', '新片', DateTime.utc(2024, 6, 1)),
      const MediaItem(
        id: 'ep',
        name: '不应出现的集',
        type: 'Episode',
        premiereDate: null,
      ),
    ];
    final older = movie('old', '旧片', DateTime.utc(2010, 1, 2));
    expect(PersonWorksController.arrange(page).map((item) => item.id), [
      'new',
      'a',
      'b',
    ]);
    expect(
      PersonWorksController.arrange([
        ...PersonWorksController.arrange(page),
        older,
      ]).map((item) => item.id),
      ['new', 'old', 'a', 'b'],
    );
  });

  test(
    'controller queries PersonIds and keeps works when the next page fails',
    () async {
      final server = FakeEmbyServer();
      server.ignoreItemTypeFilter = true;
      server.items.addAll([
        for (var i = 0; i < 61; i++)
          FakeEmbyItem(
            id: 'page-$i',
            name: '片${i.toString().padLeft(2, '0')}',
            type: 'Movie',
            premiereDate: DateTime.utc(2020, 1, 1).add(Duration(days: i)),
            personIds: const ['person-ada'],
          ),
        FakeEmbyItem(
          id: 'actor-movie',
          name: '演员电影',
          type: 'Movie',
          premiereDate: DateTime.utc(2024, 8, 1),
          personIds: const ['person-ada'],
        ),
        FakeEmbyItem(
          id: 'director-series',
          name: '导演剧集',
          type: 'Series',
          premiereDate: DateTime.utc(2023, 3, 1),
          personIds: const ['person-ada'],
        ),
        FakeEmbyItem(
          id: 'undated-b',
          name: 'B 未定档',
          type: 'Movie',
          personIds: const ['person-ada'],
        ),
        FakeEmbyItem(
          id: 'undated-a',
          name: 'A 未定档',
          type: 'Series',
          personIds: const ['person-ada'],
        ),
        FakeEmbyItem(
          id: 'episode-noise',
          name: '不应出现的集',
          type: 'Episode',
          personIds: const ['person-ada'],
        ),
        FakeEmbyItem(
          id: 'other-person',
          name: '别人的片',
          type: 'Movie',
          premiereDate: DateTime.utc(2025, 1, 1),
          personIds: const ['person-other'],
        ),
      ]);
      final client = await _signedIn(server);
      final cache = CatalogCache()
        ..debugSetDiskStore(null)
        ..attachSession(serverId: server.serverId, userId: client.userId!);
      final works = PersonWorksController(
        client: client,
        cache: cache,
        personId: 'person-ada',
      );
      addTearDown(works.dispose);
      await works.load();
      final request = server.requests.lastWhere(
        (line) => line.contains('PersonIds=person-ada'),
      );
      expect(request, contains('IncludeItemTypes=Movie%2CSeries'));
      expect(request, contains('SortBy=PremiereDate'));
      expect(request, contains('SortOrder=Descending'));
      expect(request, contains('Recursive=true'));
      expect(request, contains('Limit=60'));
      expect(request, isNot(contains('ParentId=')));
      expect(request, isNot(contains('PersonTypes')));
      expect(request, isNot(contains('People')));
      expect(works.error, isNull);
      expect(works.items.where((item) => item.type == 'Episode'), isEmpty);
      expect(
        works.items.map((item) => item.id),
        isNot(contains('other-person')),
      );
      expect(
        works.items.map((item) => item.id),
        isNot(contains('episode-noise')),
      );
      expect(works.items.first.id, 'actor-movie');
      expect(
        works.items.map((item) => item.id),
        containsAll(['actor-movie', 'director-series']),
      );
      expect(works.items.any((item) => item.premiereDate == null), isFalse);
      expect(works.hasMore, isTrue);

      server.itemsStatus = 500;
      await works.loadMore();
      expect(works.pageError, isNotNull);
      expect(works.error, isNull);
      expect(works.items.first.id, 'actor-movie');
      expect(works.items.map((item) => item.id), isNot(contains('undated-a')));
      server.itemsStatus = null;
      await works.loadMore();
      expect(works.pageError, isNull);
      final ids = works.items.map((item) => item.id).toList();
      expect(ids.first, 'actor-movie');
      expect(ids[1], 'director-series');
      expect(ids.last, 'undated-b');
      expect(ids[ids.length - 2], 'undated-a');
    },
  );

  final l10n = AppLocalizationsZh();
  for (final environment in [
    PresentationEnvironment.desktop,
    PresentationEnvironment.phone,
    PresentationEnvironment.tv,
  ]) {
    final emptyCopy = environment.isDesktop
        ? l10n.browseEmpty
        : l10n.mobileEmpty;
    testWidgets(
      '${environment.presentation.name} person page orders works and keeps the name',
      (tester) async {
        final server = FakeEmbyServer()..ignoreItemTypeFilter = true;
        _addAdaWorks(server);
        final app = await _start(tester, [server], environment);
        final hold = Completer<void>();
        server.holdItems = hold;
        app.router.go(AppRoutes.person('person-ada', name: '艾达'));
        await _until(tester, find.byKey(PersonWorksPage.loadingKey));
        expect(find.text(emptyCopy), findsNothing);
        expect(find.text('艾达'), findsWidgets);

        hold.complete();
        server.holdItems = null;
        await _until(tester, find.text('新片'));
        expect(
          _readingOrder(tester, const ['新片', '旧片', 'A 未定档', 'B 未定档']),
          isTrue,
        );
        expect(find.text('不应出现的集'), findsNothing);
        expect(find.text('别人的片'), findsNothing);
        final personRequest = server.requests.lastWhere(
          (line) => line.contains('PersonIds=person-ada'),
        );
        expect(personRequest, isNot(contains('ParentId=')));

        await tester.ensureVisible(
          find.byKey(PersonWorksPage.posterKey('work-new')),
        );
        await tester.tap(find.byKey(PersonWorksPage.posterKey('work-new')));
        await _untilPath(tester, app, '/item/work-new');
        expect(app.router.state.uri.path, '/item/work-new');

        app.router.go(AppRoutes.person('person-none', name: '无名'));
        await _until(tester, find.text(emptyCopy));
        await _routeSettled(tester);
        expect(find.text('无名'), findsWidgets);
        expect(find.byKey(PersonWorksPage.loadingKey), findsNothing);

        app.router.go(AppRoutes.item('movie-inception'));
        await _until(tester, find.text('Inception'));
        await _routeSettled(tester);
        server.itemsStatus = 500;
        app.router.push(AppRoutes.person('person-ada', name: '艾达'));
        await _until(tester, find.text('重试'));
        await _routeSettled(tester);
        expect(app.router.state.uri.path, startsWith('/person/'));
        expect(find.text(emptyCopy), findsNothing);
        expect(find.text('艾达'), findsWidgets);
        await tester.tap(find.text('重试').hitTestable().last);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(app.router.state.uri.path, startsWith('/person/'));
        server.itemsStatus = null;
        app.router.pop();
        await _until(tester, find.text('Inception'));
        expect(app.router.state.uri.path, '/item/movie-inception');
      },
      tags: const ['integration'],
    );
  }

  testWidgets(
    'a server source queries only that server and retry leaves its detail',
    (tester) async {
      final serverA = FakeEmbyServer(
        serverId: 'server-a',
        baseUrl: Uri.parse('http://a.test:8096'),
      );
      final serverB = FakeEmbyServer(
        serverId: 'server-b',
        baseUrl: Uri.parse('http://b.test:8096'),
      );
      serverA.items.add(
        FakeEmbyItem(
          id: 'only-a',
          name: '只在甲服',
          type: 'Movie',
          parentId: 'view-movies',
          premiereDate: DateTime.utc(2024, 1, 1),
          personIds: const ['person-ada'],
        ),
      );
      serverB.items.add(
        FakeEmbyItem(
          id: 'only-b',
          name: '只在乙服',
          type: 'Movie',
          parentId: 'view-movies',
          premiereDate: DateTime.utc(2022, 5, 1),
          personIds: const ['person-ada'],
        ),
      );
      final app = await _start(tester, [
        serverA,
        serverB,
      ], PresentationEnvironment.desktop);
      final auth = app.auth;
      final account = (await tester.runAsync(
        () => auth.sources.authenticate(
          auth.savedServers
              .firstWhere((s) => s.verifiedServerId == serverB.serverId)
              .id,
        ),
      ))!.account;
      final permit = auth.sources.permit(account, libraryId: 'view-movies');
      PlayerHostOpenItemCommand command(String itemId) =>
          PlayerHostOpenItemCommand(
            itemId: itemId,
            source: SourceReference(account: account, itemId: itemId),
            libraryId: 'view-movies',
            regionGeneration: permit.regionGeneration,
          );
      app.router.go(AppRoutes.item('only-b'), extra: command('only-b'));
      await _until(tester, find.text('只在乙服'));
      expect(auth.session!.server.verifiedServerId, serverA.serverId);
      final aBefore = serverA.requests.length;
      serverB.itemsStatus = 500;
      app.router.push(
        AppRoutes.person('person-ada', name: '艾达'),
        extra: command('person-ada'),
      );
      await _until(tester, find.text('重试'));
      expect(find.text('只在甲服'), findsNothing);
      expect(find.text('只在乙服'), findsNothing);
      expect(
        serverA.requests
            .skip(aBefore)
            .any((line) => line.contains('PersonIds=')),
        isFalse,
      );
      expect(
        serverB.requests.any((line) => line.contains('PersonIds=person-ada')),
        isTrue,
      );
      expect(app.router.state.uri.path, '/person/person-ada');
      await tester.tap(find.text('重试').hitTestable().last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(app.router.state.uri.path, '/person/person-ada');
      serverB.itemsStatus = null;
      await tester.tap(find.text('重试').hitTestable().last);
      await _until(tester, find.text('只在乙服'));
      expect(find.text('只在甲服'), findsNothing);
      expect(
        serverA.requests
            .skip(aBefore)
            .any((line) => line.contains('PersonIds=')),
        isFalse,
      );
      app.router.pop();
      await _until(tester, find.text('只在乙服'));
      expect(app.router.state.uri.path, '/item/only-b');
      expect(auth.session!.server.verifiedServerId, serverA.serverId);
    },
    tags: const ['integration'],
  );
}

void _addAdaWorks(FakeEmbyServer server) {
  server.items.addAll([
    FakeEmbyItem(
      id: 'work-new',
      name: '新片',
      type: 'Movie',
      parentId: 'view-movies',
      premiereDate: DateTime.utc(2024, 6, 1),
      personIds: const ['person-ada'],
    ),
    FakeEmbyItem(
      id: 'work-old',
      name: '旧片',
      type: 'Series',
      parentId: 'view-tv',
      premiereDate: DateTime.utc(2010, 1, 2),
      personIds: const ['person-ada'],
    ),
    FakeEmbyItem(
      id: 'work-b',
      name: 'B 未定档',
      type: 'Movie',
      parentId: 'view-movies',
      personIds: const ['person-ada'],
    ),
    FakeEmbyItem(
      id: 'work-a',
      name: 'A 未定档',
      type: 'Series',
      parentId: 'view-tv',
      personIds: const ['person-ada'],
    ),
    FakeEmbyItem(
      id: 'work-episode',
      name: '不应出现的集',
      type: 'Episode',
      parentId: 'season-friends-1',
      seriesId: 'series-friends',
      personIds: const ['person-ada'],
    ),
    FakeEmbyItem(
      id: 'work-other',
      name: '别人的片',
      type: 'Movie',
      parentId: 'view-movies',
      premiereDate: DateTime.utc(2025, 1, 1),
      personIds: const ['person-other'],
    ),
  ]);
}

bool _readingOrder(WidgetTester tester, List<String> names) {
  final offsets = [
    for (final name in names) tester.getTopLeft(find.text(name).first),
  ];
  for (var i = 1; i < offsets.length; i++) {
    final previous = offsets[i - 1];
    final current = offsets[i];
    final below = current.dy > previous.dy + 1;
    final sameRow =
        (current.dy - previous.dy).abs() <= 1 && current.dx > previous.dx;
    if (!below && !sameRow) return false;
  }
  return true;
}

Future<void> _routeSettled(WidgetTester tester) async {
  // 手机 shared-axis 会在约 250ms 内把上一页留在舞台上。
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _until(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 50; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isNotEmpty) {
      await tester.pump(const Duration(milliseconds: 50));
      return;
    }
  }
  expect(finder, findsWidgets);
}

Future<void> _untilPath(
  WidgetTester tester,
  RillightApp app,
  String path,
) async {
  for (var i = 0; i < 50; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (app.router.state.uri.path == path) return;
  }
  expect(app.router.state.uri.path, path);
}

Future<EmbyClient> _signedIn(FakeEmbyServer server) async {
  final client = EmbyClient(
    device: _device,
    dio: dioForFakeEmby(FakeEmbyAdapter([server])),
  );
  final auth = await client.authenticateByName(
    baseUrl: server.baseUrl,
    username: 'alice',
    password: 'correct-horse',
    serverId: server.serverId,
  );
  client.attachSession(
    baseUrl: server.baseUrl,
    accessToken: auth.accessToken,
    userId: auth.user.id,
  );
  return client;
}

Future<RillightApp> _start(
  WidgetTester tester,
  List<FakeEmbyServer> servers,
  PresentationEnvironment environment,
) async {
  final size = switch (environment.presentation) {
    AppPresentation.androidPhone => const Size(412, 900),
    AppPresentation.androidTv => const Size(960, 540),
    AppPresentation.desktop => const Size(1440, 1000),
  };
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final auth = SyntheticSourceAuth(
    adapter: FakeEmbyAdapter(servers),
    device: _device,
    libraryIds: const {'view-movies', 'view-tv', 'view-photos', 'view-untyped'},
  );
  await tester.runAsync(() async {
    await auth.sources.load();
    for (final server in servers) {
      final connected = await auth.connect(
        address: server.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      );
      if (!connected) {
        throw StateError('signed-in fixture failed for ${server.baseUrl}');
      }
    }
    if (servers.length > 1) {
      await auth.switchTo(
        auth.savedServers
            .firstWhere((s) => s.verifiedServerId == servers.first.serverId)
            .id,
      );
    }
  });
  final app = RillightApp(auth: auth, environment: environment);
  await tester.pumpWidget(app);
  await tester.pump();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 20));
    app.router.dispose();
    auth.dispose();
  });
  return app;
}
