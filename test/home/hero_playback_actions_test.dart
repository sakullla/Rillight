import 'package:go_router/go_router.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/catalog_cache.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/home/phone_hero.dart';
import '../emby/fake_emby_server.dart';
import '../helpers/image_cache_fixture.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/hero_playback_actions.dart';
import 'package:rillight/player/player_window_host.dart';

/// 连上假服务器并把 series-friends 放进最近剧集;[mode] 决定该剧的分集状态。
Future<(AuthController, CatalogController)> _seriesFixture(
  WidgetTester tester,
  String mode,
) async {
  final server = FakeEmbyServer();
  server.setEpisodes('series-friends', [
    if (mode != 'empty') ...[
      FakeEpisode(
        id: 'episode-first',
        name: '第一集',
        seasonId: 'season-friends-1',
        indexNumber: 1,
        parentIndexNumber: 1,
        played: mode == 'unwatched',
      ),
      FakeEpisode(
        id: 'episode-target',
        name: '第二集',
        seasonId: 'season-friends-1',
        indexNumber: 2,
        parentIndexNumber: 1,
        playbackPositionTicks: mode == 'resume' ? 120000000 : 0,
      ),
    ],
  ]);
  final auth = AuthController.memory(
    client: EmbyClient(
      device: const EmbyDeviceInfo(
        clientName: 'test',
        deviceName: 'test',
        deviceId: 'series-hero',
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
  final catalog = CatalogController(
    auth: auth,
    cache: CatalogCache()..debugSetDiskStore(null),
  );
  catalog.latestSeries = CatalogRowState(
    items: [
      EmbyItem.fromJson(
        server.items.firstWhere((item) => item.id == 'series-friends').toJson(),
      ),
    ],
  );
  return (auth, catalog);
}

Future<void> _pumpResolution(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
}

void main() {
  for (final mode in ['resume', 'unwatched', 'empty']) {
    testWidgets('phone Series hero resolves $mode before opening playback', (
      tester,
    ) async {
      isolateImageCache();
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 800);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final (auth, catalog) = await _seriesFixture(tester, mode);
      PlayerOpenRequest? opened;
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => Scaffold(
              body: SingleChildScrollView(child: PhoneHero(catalog: catalog)),
            ),
          ),
          GoRoute(
            path: '/play/:id',
            builder: (_, state) {
              opened = state.extra! as PlayerOpenRequest;
              return Scaffold(
                body: Text('playing ${state.pathParameters['id']}'),
              );
            },
          ),
        ],
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        router.dispose();
        catalog.dispose();
        auth.dispose();
      });
      await tester.pumpWidget(
        MaterialApp.router(
          theme: AppTheme.phoneDark(),
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
          builder: (context, child) => AuthScope(
            controller: auth,
            child: CatalogScope(controller: catalog, child: child!),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final play = find.byKey(const ValueKey('hero-resume-series-friends'));
      // 剧集条目的主操作恒为「播放」,不暴露续播进度。
      expect(find.descendant(of: play, matching: find.text('播放')), findsOne);
      expect(find.text('最新剧集'), findsOneWidget);
      await tester.tap(play);
      await _pumpResolution(tester);
      if (mode == 'empty') {
        expect(opened, isNull);
        expect(find.text('没有可播放的流'), findsOneWidget);
        expect(find.byType(PhoneHero), findsOneWidget);
      } else {
        expect(opened?.itemId, 'episode-target');
        expect(opened?.autoResume, isTrue);
        expect(find.text('playing episode-target'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    }, tags: ['integration']);

    testWidgets('desktop Series hero resolves $mode through the player host', (
      tester,
    ) async {
      isolateImageCache();
      final (auth, catalog) = await _seriesFixture(tester, mode);
      final host = OverlayPlayerWindowHost();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        host.dispose();
        catalog.dispose();
        auth.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: AuthScope(
            controller: auth,
            child: CatalogScope(
              controller: catalog,
              child: PlayerWindowScope(
                host: host,
                child: Scaffold(
                  body: Center(
                    child: HeroPlaybackActions(
                      item: catalog.latestSeries.items.single,
                      catalog: catalog,
                      onDetails: () {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('hero-resume-series-friends')),
      );
      await _pumpResolution(tester);
      if (mode == 'empty') {
        expect(host.current, isNull);
        expect(find.text('没有可播放的流'), findsOneWidget);
      } else {
        expect(host.current?.itemId, 'episode-target');
        expect(host.current?.autoResume, isTrue);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('resume and details share a row and resume opens the real host', (
    tester,
  ) async {
    final host = OverlayPlayerWindowHost();
    addTearDown(host.dispose);
    var details = false;
    final item = EmbyItem.fromJson({
      'Id': 'episode',
      'Name': 'Episode',
      'Type': 'Episode',
      'UserData': {'PlaybackPositionTicks': 120000000, 'PlayedPercentage': 20},
    });
    expect(item.canResume, isTrue);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: PlayerWindowScope(
          host: host,
          child: Scaffold(
            body: Center(
              child: HeroPlaybackActions(
                item: item,
                onDetails: () => details = true,
              ),
            ),
          ),
        ),
      ),
    );
    final resume = find.byKey(const ValueKey('hero-resume-episode'));
    final info = find.widgetWithText(OutlinedButton, '详情');
    expect(tester.getTopLeft(resume).dy, tester.getTopLeft(info).dy);
    // 可续播条目也只写「播放」:轮播不展示用户使用记录。
    expect(find.descendant(of: resume, matching: find.text('播放')), findsOne);
    expect(find.text('继续播放'), findsNothing);
    await tester.tap(resume);
    await tester.pump();
    expect(host.current?.itemId, 'episode');
    expect(host.current?.autoResume, isTrue);
    expect(details, isFalse);
    await tester.tap(info);
    expect(details, isTrue);
    expect(tester.takeException(), isNull);
  });
}
