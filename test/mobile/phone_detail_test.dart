import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/library/mobile_detail_page.dart';
import 'package:rillight/library/mobile_library_page.dart';
import 'package:rillight/library/mobile_series_page.dart';
import 'package:rillight/player/mobile_player_page.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/player_window_host.dart';
import 'package:rillight/player/video_backend.dart';

import '../emby/fake_emby_server.dart';
import '../helpers/image_cache_fixture.dart';

void main() {
  setUp(isolateImageCache);

  Future<(GoRouter, FakeVideoBackend)> start(
    WidgetTester tester,
    FakeEmbyServer server, {
    double width = 360,
    double height = 800,
    double bottomInset = 0,
  }) async {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = FakeViewPadding(bottom: bottomInset, top: 24);
    tester.view.viewPadding = FakeViewPadding(bottom: bottomInset, top: 24);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    final auth = AuthController.memory(
      client: EmbyClient(
        device: const EmbyDeviceInfo(
          clientName: 'test',
          deviceName: 'phone',
          deviceId: 'phone-detail',
          version: '1',
        ),
        dio: dioForFakeEmby(FakeEmbyAdapter([server])),
      ),
    );
    await tester.runAsync(
      () => auth.connect(
        address: server.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      ),
    );
    final backend = FakeVideoBackend(duration: const Duration(hours: 3));
    final catalog = CatalogController(auth: auth);
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const Scaffold(body: SizedBox()),
        ),
        GoRoute(
          path: '/item/:itemId',
          builder: (context, state) =>
              MobileDetailPage(itemId: state.pathParameters['itemId']!),
        ),
        GoRoute(
          path: '/play/:itemId',
          builder: (context, state) {
            final request = state.extra as PlayerOpenRequest?;
            return MobilePlayerPage(
              itemId: state.pathParameters['itemId']!,
              mediaSourceId: request?.mediaSourceId,
              autoResume: request?.autoResume ?? true,
              audioStreamIndex: request?.audioStreamIndex,
              subtitleStreamIndex: request?.subtitleStreamIndex,
            );
          },
        ),
        GoRoute(
          path: '/library/:viewId',
          builder: (context, state) =>
              MobileLibraryPage(viewId: state.pathParameters['viewId']!),
        ),
      ],
    );
    await tester.pumpWidget(
      AuthScope(
        controller: auth,
        child: CatalogScope(
          controller: catalog,
          child: PlayerScope(
            bindings: PlayerBindings(
              createBackend: () => backend,
              snapshotStore: MemoryPlaybackSessionSnapshotStore(),
              settingsStore: MemoryPlayerSettingsStore(),
            ),
            child: MaterialApp.router(
              locale: const Locale('zh', 'CN'),
              supportedLocales: AppLocalizations.supportedLocales,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              theme: AppTheme.dark(),
              routerConfig: router,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      router.dispose();
      catalog.dispose();
      auth.dispose();
    });
    return (router, backend);
  }

  Future<void> openItem(WidgetTester tester, GoRouter router, String id) async {
    unawaited(router.push('/item/$id'));
    await tester.pumpAndSettle();
  }

  Future<void> closePlayer(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  }

  testWidgets('series page names the episode and returns from episode detail', (
    tester,
  ) async {
    const minute = 10000000 * 60;
    final server = FakeEmbyServer();
    server.setSeasons('series-friends', const [
      FakeSeason(id: 'season-friends-1', name: '第 1 季', indexNumber: 1),
      FakeSeason(id: 'season-friends-2', name: '第 2 季', indexNumber: 2),
    ]);
    server.setEpisodes('series-friends', [
      const FakeEpisode(
        id: 'episode-friends-s1e1',
        name: 'The Pilot',
        seasonId: 'season-friends-1',
        indexNumber: 1,
        parentIndexNumber: 1,
        played: true,
        overview: 'Monica gets a new apartment.',
        runTimeTicks: minute * 22,
      ),
      FakeEpisode(
        id: 'episode-friends-s2e1',
        name: 'The One with the Resume',
        seasonId: 'season-friends-2',
        indexNumber: 1,
        parentIndexNumber: 2,
        playbackPositionTicks: minute * 5,
        playedPercentage: 20,
        overview: 'Halfway through season two.',
        runTimeTicks: minute * 22,
        primaryImageTag: 'tag-s2e1',
      ),
      const FakeEpisode(
        id: 'episode-friends-s2e2',
        name: 'Season Two Follow Up',
        seasonId: 'season-friends-2',
        indexNumber: 2,
        parentIndexNumber: 2,
        overview: 'The next night.',
        runTimeTicks: minute * 22,
      ),
    ]);
    final (router, backend) = await start(tester, server, bottomInset: 48);
    await openItem(tester, router, 'series-friends');

    expect(find.byType(MobileDetailPage), findsOneWidget);
    expect(find.byKey(PhoneItemBanner.bannerKey), findsOneWidget);
    expect(tester.getTopLeft(find.byKey(PhoneItemBanner.bannerKey)).dy, 0);
    expect(find.byType(ChoiceChip), findsNWidgets(2));
    expect(
      tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '第 2 季'))
          .selected,
      isTrue,
    );
    expect(find.byKey(const Key('phone-season-list')), findsOneWidget);
    expect(
      find.byWidgetPredicate((widget) => widget is DropdownButton),
      findsNothing,
    );
    final play = find.byKey(const Key('mobile-detail-play'));
    expect(
      tester
          .widget<Text>(find.descendant(of: play, matching: find.byType(Text)))
          .data,
      contains('The One with the Resume'),
    );
    expect(find.text('从头播放'), findsNothing);
    expect(find.byKey(const Key('phone-episode-current')), findsOneWidget);
    expect(tester.getRect(play).bottom, lessThanOrEqualTo(800 - 48));

    await tester.tap(play);
    await tester.pumpAndSettle();
    expect(find.byType(MobilePlayerPage), findsOneWidget);
    expect(backend.position, const Duration(minutes: 5));
    await closePlayer(tester);
    expect(find.byType(MobilePlayerPage), findsNothing);
    expect(find.widgetWithText(ChoiceChip, '第 2 季'), findsOneWidget);

    await tester.tap(find.text('第 1 季'));
    await tester.pumpAndSettle();
    expect(find.text('The Pilot'), findsWidgets);
    expect(find.text('The One with the Resume'), findsNothing);
    await tester.tap(find.text('第 2 季'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('The One with the Resume').first);
    await tester.tap(find.text('The One with the Resume').first);
    await tester.pumpAndSettle();
    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.text('Halfway through season two.'), findsOneWidget);
    expect(find.byKey(CatalogKeys.seriesLink), findsOneWidget);
    expect(find.text('Season Two Follow Up'), findsOneWidget);
    await tester.tap(find.byKey(CatalogKeys.nextEpisode));
    await tester.pumpAndSettle();
    expect(find.text('The next night.'), findsOneWidget);
    await tester.tap(find.byKey(CatalogKeys.seriesLink));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ChoiceChip, '第 2 季'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  testWidgets('movie detail resumes, restarts, and starts at a chapter', (
    tester,
  ) async {
    const minute = 10000000 * 60;
    final server = FakeEmbyServer();
    final movie = server.items.firstWhere(
      (item) => item.id == 'movie-inception',
    );
    movie.people = const [
      FakePerson(name: 'Cobb Actor', type: 'Actor', role: 'Cobb'),
      FakePerson(name: 'Nolan Director', type: 'Director'),
      FakePerson(name: 'Emma Writer', type: 'Writer'),
    ];
    server.items.firstWhere((item) => item.id == 'movie-up').people = const [
      FakePerson(name: 'Carl Actor', type: 'Actor', role: 'Carl'),
    ];
    final (router, backend) = await start(tester, server, width: 412);
    await openItem(tester, router, 'movie-inception');

    expect(find.byType(ChoiceChip), findsNothing);
    expect(
      find.byWidgetPredicate((widget) => widget is DropdownButton),
      findsNothing,
    );
    expect(find.text('继续播放'), findsOneWidget);
    expect(find.text('从头播放'), findsOneWidget);
    expect(tester.getTopLeft(find.byKey(PhoneItemBanner.bannerKey)).dy, 0);

    await tester.tap(find.byKey(const Key('mobile-detail-play')));
    await tester.pumpAndSettle();
    expect(backend.position, const Duration(minutes: 59));
    await closePlayer(tester);

    await tester.tap(find.byKey(const Key('phone-detail-play-start')));
    await tester.pumpAndSettle();
    expect(backend.position, Duration.zero);
    await closePlayer(tester);

    await tester.ensureVisible(find.byKey(CatalogKeys.chapter(1)));
    await tester.tap(find.byKey(CatalogKeys.chapter(1)));
    await tester.pumpAndSettle();
    expect(backend.position, const Duration(minutes: 7));
    final extra =
        GoRouterState.of(tester.element(find.byType(MobilePlayerPage))).extra
            as PlayerOpenRequest;
    expect(extra.startTimeTicks, 7 * minute);
    await closePlayer(tester);

    await tester.ensureVisible(find.text('演员'));
    expect(find.text('导演'), findsOneWidget);
    expect(find.text('编剧'), findsOneWidget);
    expect(find.text('其他'), findsNothing);
    expect(find.text('Cobb Actor'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await openItem(tester, router, 'movie-up');
    await tester.ensureVisible(find.text('演员'));
    expect(find.text('导演'), findsNothing);
    expect(find.text('编剧'), findsNothing);
    expect(find.text('演职员'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await openItem(tester, router, 'movie-transcode');
    expect(find.text('演职员'), findsNothing);
    expect(find.text('章节'), findsNothing);
    expect(find.text('演员'), findsNothing);
    expect(find.byType(ChoiceChip), findsNothing);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  testWidgets('marking played removes the movie from the unwatched filter', (
    tester,
  ) async {
    final server = _FilteringEmbyServer();
    final (router, _) = await start(tester, server, height: 1600);
    await openItem(tester, router, 'movie-inception');
    await tester.ensureVisible(find.byKey(CatalogKeys.playedToggle));
    await tester.tap(find.byKey(CatalogKeys.playedToggle));
    await tester.pumpAndSettle();
    expect(find.text('标记未看'), findsOneWidget);
    expect(
      server.items.firstWhere((item) => item.id == 'movie-inception').played,
      isTrue,
    );

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    unawaited(router.push('/library/view-movies'));
    await tester.pumpAndSettle();
    expect(find.text('Inception'), findsOneWidget);
    await _filterUnwatched(tester);
    expect(find.text('Inception'), findsNothing);
    expect(find.text('飞屋环游记'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await openItem(tester, router, 'movie-inception');
    await tester.ensureVisible(find.byKey(CatalogKeys.playedToggle));
    await tester.tap(find.byKey(CatalogKeys.playedToggle));
    await tester.pumpAndSettle();
    expect(find.text('标记已看'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    unawaited(router.push('/library/view-movies'));
    await tester.pumpAndSettle();
    await _filterUnwatched(tester);
    expect(find.text('Inception'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  testWidgets('chosen audio and subtitle are used when phone playback starts', (
    tester,
  ) async {
    final server = FakeEmbyServer();
    final movie = server.items.firstWhere(
      (item) => item.id == 'movie-inception',
    );
    movie.mediaStreams = [
      ...movie.mediaStreams,
      const FakeMediaStream(
        index: 3,
        type: 'Audio',
        codec: 'aac',
        language: 'jpn',
        displayTitle: '日语音轨',
      ),
      const FakeMediaStream(
        index: 4,
        type: 'Subtitle',
        codec: 'subrip',
        language: 'eng',
        displayTitle: '英文字幕',
        isTextSubtitleStream: true,
      ),
    ];
    final (router, backend) = await start(
      tester,
      server,
      width: 412,
      height: 2000,
    );
    await openItem(tester, router, 'movie-inception');

    await tester.ensureVisible(find.byKey(CatalogKeys.mediaSource));
    await tester.tap(find.byKey(CatalogKeys.mediaSource));
    await tester.pumpAndSettle();
    await tester.tap(find.text('日语音轨'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(CatalogKeys.mediaSource));
    await tester.tap(find.byKey(CatalogKeys.mediaSource));
    await tester.pumpAndSettle();
    await tester.tap(find.text('英文字幕'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('mobile-detail-play')));
    await tester.pumpAndSettle();
    final page = tester.widget<MobilePlayerPage>(find.byType(MobilePlayerPage));
    final player = tester.state<MobilePlayerPageState>(
      find.byType(MobilePlayerPage),
    );
    expect(page.audioStreamIndex, 3);
    expect(page.subtitleStreamIndex, 4);
    expect(player.controller?.audioStreamIndex, 3);
    expect(player.controller?.subtitleStreamIndex, 4);
    expect(backend.audioIndex, 3);
    expect(backend.subtitleIndex, 4);
    expect(server.lastPlaybackInfoBody?['AudioStreamIndex'], 3);
    expect(server.lastPlaybackInfoBody?['SubtitleStreamIndex'], 4);
    await closePlayer(tester);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  testWidgets('resume past the loaded season page stays the play action', (
    tester,
  ) async {
    const minute = 10000000 * 60;
    final server = FakeEmbyServer();
    server.setEpisodes('series-friends', [
      for (var i = 0; i < 51; i++)
        FakeEpisode(
          id: 'episode-$i',
          name: i == 50 ? 'Far Resume' : 'Episode ${i + 1}',
          seasonId: 'season-friends-1',
          indexNumber: i + 1,
          parentIndexNumber: 1,
          played: i < 50,
          playbackPositionTicks: i == 50 ? minute * 3 : 0,
          runTimeTicks: minute * 22,
        ),
    ]);
    final (router, backend) = await start(tester, server);
    await openItem(tester, router, 'series-friends');

    final play = find.byKey(const Key('mobile-detail-play'));
    expect(
      tester
          .widget<Text>(find.descendant(of: play, matching: find.byType(Text)))
          .data,
      contains('Far Resume'),
    );
    expect(find.text('Episode 1'), findsOneWidget);
    expect(find.text('Far Resume'), findsNothing);

    await tester.tap(play);
    await tester.pumpAndSettle();
    expect(
      tester.widget<MobilePlayerPage>(find.byType(MobilePlayerPage)).itemId,
      'episode-50',
    );
    expect(backend.position, const Duration(minutes: 3));
    await closePlayer(tester);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);
}

Future<void> _filterUnwatched(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('phone-library-filter')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('phone-library-watch-IsUnplayed')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('phone-library-apply')));
  await tester.pumpAndSettle();
}

/// Applies IsPlayed / IsUnplayed on library item queries. The shared fake
/// records Filters but does not remove played rows.
class _FilteringEmbyServer extends FakeEmbyServer {
  @override
  Future<ResponseBody> handle(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
  ) async {
    final query = options.uri.queryParameters;
    if (options.method.toUpperCase() == 'GET' &&
        options.uri.path == '/Users/user-alice/Items' &&
        query.containsKey('Filters')) {
      return _filteredItems(options);
    }
    return super.handle(options, requestStream);
  }

  ResponseBody _filteredItems(RequestOptions options) {
    final query = options.uri.queryParameters;
    final parentId = query['ParentId'];
    final recursive = (query['Recursive'] ?? 'false').toLowerCase() == 'true';
    final types = _split(query['IncludeItemTypes']);
    final filters = _split(query['Filters']);
    final matched = items.where((item) {
      if (types.isNotEmpty && !types.contains(item.type)) return false;
      if (parentId != null &&
          parentId.isNotEmpty &&
          !_belongs(item, parentId, recursive: recursive)) {
        return false;
      }
      if (filters.contains('IsPlayed') && !item.played) return false;
      if (filters.contains('IsUnplayed') && item.played) return false;
      return true;
    }).toList();
    return ResponseBody.fromString(
      jsonEncode({
        'Items': [for (final item in matched) item.toJson()],
        'TotalRecordCount': matched.length,
      }),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  bool _belongs(FakeEmbyItem item, String parentId, {required bool recursive}) {
    if (item.parentId == parentId) return true;
    if (!recursive) return false;
    final byId = {
      for (final candidate in [...items, ...views]) candidate.id: candidate,
    };
    var current = item.parentId;
    final seen = <String>{};
    while (current != null && seen.add(current)) {
      if (current == parentId) return true;
      current = byId[current]?.parentId;
    }
    return false;
  }

  Set<String> _split(String? raw) {
    return (raw ?? '')
        .split(',')
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toSet();
  }
}
