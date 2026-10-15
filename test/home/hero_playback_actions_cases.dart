import '../helpers/cupertino_test_app.dart';

import 'package:rillight/app/ui/app_icons.dart';
import 'package:rillight/app/ui/ui.dart' as ui;

import '../helpers/widget_harness.dart';
import '../helpers/settle.dart';

import 'package:rillight/emby/emby_codec.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/catalog_cache.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/media_server/device.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/home/phone_hero.dart';

import '../emby/fake_emby_server.dart';
import '../helpers/image_cache_fixture.dart';

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
        playbackPosition: Duration(
          microseconds: (mode == 'resume' ? 120000000 : 0) ~/ 10,
        ),
      ),
    ],
  ]);
  final auth = AuthController.memory(
    client: EmbyClient(
      device: const ClientDeviceInfo(
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
      decodeEmbyMediaItem(
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
            builder: (_, _) => CupertinoPageScaffold(
              child: SingleChildScrollView(child: PhoneHero(catalog: catalog)),
            ),
          ),
          GoRoute(
            path: '/play/:id',
            builder: (_, state) {
              opened = state.extra! as PlayerOpenRequest;
              return CupertinoPageScaffold(
                child: Text('playing ${state.pathParameters['id']}'),
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
        CupertinoTestApp.router(
          theme: AppUiTheme.phoneDark(),
          locale: const Locale('zh'),
          localizationsDelegates: [
            ...[
              AppLocalizations.delegate,
              ...GlobalCupertinoLocalizations.delegates,
            ],
            ui.GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
          builder: (context, child) => ui.AppUiTheme(
            data: AppUiTheme.of(context).brightness == Brightness.dark
                ? ui.AppUiTheme.dark()
                : ui.AppUiTheme.light(),
            child: ((context, child) => AuthScope(
              controller: auth,
              child: CatalogScope(controller: catalog, child: child!),
            ))(context, child),
          ),
        ),
      );
      await settle(tester);
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
        CupertinoTestApp(
          locale: const Locale('zh'),
          localizationsDelegates: [
            ...[
              AppLocalizations.delegate,
              ...GlobalCupertinoLocalizations.delegates,
            ],
            ui.GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: AuthScope(
            controller: auth,
            child: CatalogScope(
              controller: catalog,
              child: PlayerWindowScope(
                host: host,
                child: CupertinoPageScaffold(
                  child: Center(
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
          builder: (context, child) => ui.AppUiTheme(
            data: AppUiTheme.of(context).brightness == Brightness.dark
                ? ui.AppUiTheme.dark()
                : ui.AppUiTheme.light(),
            child: child ?? const SizedBox.shrink(),
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
    final item = decodeEmbyMediaItem({
      'Id': 'episode',
      'Name': 'Episode',
      'Type': 'Episode',
      'UserData': {'PlaybackPositionTicks': 120000000, 'PlayedPercentage': 20},
    });
    expect(item.canResume, isTrue);
    await tester.pumpWidget(
      CupertinoTestApp(
        locale: const Locale('zh'),
        localizationsDelegates: [
          ...[
            AppLocalizations.delegate,
            ...GlobalCupertinoLocalizations.delegates,
          ],
          ui.GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: PlayerWindowScope(
          host: host,
          child: CupertinoPageScaffold(
            child: Center(
              child: HeroPlaybackActions(
                item: item,
                onDetails: () => details = true,
              ),
            ),
          ),
        ),
        builder: (context, child) => ui.AppUiTheme(
          data: AppUiTheme.of(context).brightness == Brightness.dark
              ? ui.AppUiTheme.dark()
              : ui.AppUiTheme.light(),
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    );
    final resume = find.byKey(const ValueKey('hero-resume-episode'));
    final info = find.widgetWithText(ui.AppButton, '详情');
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

  testWidgets('light desktop play uses the accent and details stay ink', (
    tester,
  ) async {
    final host = OverlayPlayerWindowHost();
    addTearDown(host.dispose);
    final item = decodeEmbyMediaItem({
      'Id': 'movie',
      'Name': 'Movie',
      'Type': 'Movie',
    });
    await tester.pumpWidget(
      CupertinoTestApp(
        theme: AppUiTheme.light(),
        locale: const Locale('zh'),
        localizationsDelegates: [
          ...[
            AppLocalizations.delegate,
            ...GlobalCupertinoLocalizations.delegates,
          ],
          ui.GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: PlayerWindowScope(
          host: host,
          child: CupertinoPageScaffold(
            child: Center(
              child: HeroPlaybackActions(item: item, onDetails: () {}),
            ),
          ),
        ),
        builder: (context, child) => ui.AppUiTheme(
          data: AppUiTheme.of(context).brightness == Brightness.dark
              ? ui.AppUiTheme.dark()
              : ui.AppUiTheme.light(),
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    );
    final playFinder = find.byKey(const ValueKey('hero-resume-movie'));
    final play = tester.widget<ui.AppButton>(playFinder);
    expect(play.style?.backgroundColor, AppUiTheme.light().colorScheme.primary);
    final icon = tester.widget<Icon>(
      find.descendant(of: playFinder, matching: find.byIcon(AppIcons.play)),
    );
    expect(icon.fill, AppIcons.filled);
    expect(
      find.descendant(of: playFinder, matching: find.text('播放')),
      findsOne,
    );
    final details = tester.widget<ui.AppButton>(
      find.widgetWithText(ui.AppButton, '详情'),
    );
    expect(
      details.style?.foregroundColor,
      AppUiTheme.light().colorScheme.onSurface,
    );
  });

  testWidgets('dark desktop play stays white on the scrim', (tester) async {
    final host = OverlayPlayerWindowHost();
    addTearDown(host.dispose);
    final item = decodeEmbyMediaItem({
      'Id': 'movie',
      'Name': 'Movie',
      'Type': 'Movie',
    });
    await tester.pumpWidget(
      CupertinoTestApp(
        theme: AppUiTheme.dark(),
        locale: const Locale('zh'),
        localizationsDelegates: [
          ...[
            AppLocalizations.delegate,
            ...GlobalCupertinoLocalizations.delegates,
          ],
          ui.GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: PlayerWindowScope(
          host: host,
          child: CupertinoPageScaffold(
            child: Center(
              child: HeroPlaybackActions(item: item, onDetails: () {}),
            ),
          ),
        ),
        builder: (context, child) => ui.AppUiTheme(
          data: AppUiTheme.of(context).brightness == Brightness.dark
              ? ui.AppUiTheme.dark()
              : ui.AppUiTheme.light(),
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    );
    final playFinder = find.byKey(const ValueKey('hero-resume-movie'));
    final play = tester.widget<ui.AppButton>(playFinder);
    expect(play.style?.backgroundColor, const Color(0xffffffff));
    final icon = tester.widget<Icon>(
      find.descendant(of: playFinder, matching: find.byIcon(AppIcons.play)),
    );
    expect(icon.fill, AppIcons.filled);
    expect(
      find.descendant(of: playFinder, matching: find.text('播放')),
      findsOne,
    );
  });

  testWidgets('phone carousel keeps one solid play button beside details', (
    tester,
  ) async {
    final item = decodeEmbyMediaItem({
      'Id': 'movie',
      'Name': 'Movie',
      'Type': 'Movie',
    });
    for (final theme in [AppUiTheme.phoneDark(), AppUiTheme.phoneLight()]) {
      await tester.pumpWidget(
        CupertinoTestApp(
          theme: theme,
          locale: const Locale('zh'),
          home: CupertinoPageScaffold(
            child: Center(
              child: HeroPlaybackActions(
                item: item,
                expand: true,
                onDetails: () {},
                onResume: () async {},
              ),
            ),
          ),
        ),
      );
      final playFinder = find.byKey(const ValueKey('hero-resume-movie'));
      final detailsFinder = find.widgetWithText(ui.AppButton, '详情');
      final play = tester.widget<ui.AppButton>(playFinder);
      final details = tester.widget<ui.AppButton>(detailsFinder);
      expect(play.variant, AppButtonVariant.filled);
      expect(details.variant, AppButtonVariant.outlined);
      expect(details.style?.backgroundColor, isNull);
      expect(play.style?.backgroundColor, theme.colorScheme.inverseSurface);
      expect(play.style!.backgroundColor!.a, greaterThan(0.9));
      expect(
        (play.style!.backgroundColor!.computeLuminance() - 0.5).abs(),
        greaterThan(0.35),
      );
      expect(
        tester.getTopLeft(playFinder).dy,
        tester.getTopLeft(detailsFinder).dy,
      );
      final icon = tester.widget<Icon>(
        find.descendant(of: playFinder, matching: find.byIcon(AppIcons.play)),
      );
      expect(icon.fill, AppIcons.filled);
      expect(find.text('播放'), findsOneWidget);
      expect(find.text('详情'), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping the phone hero still opens details', (tester) async {
    isolateImageCache();
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 800);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final auth = AuthController.memory();
    final catalog = CatalogController(auth: auth);
    addTearDown(catalog.dispose);
    addTearDown(auth.dispose);
    catalog.latestMovies = CatalogRowState(
      items: [
        decodeEmbyMediaItem({
          'Id': 'hero-movie',
          'Name': '新片',
          'Type': 'Movie',
          'ImageTags': {'Primary': 'poster'},
        }),
      ],
    );
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => AuthScope(
            controller: auth,
            child: CatalogScope(
              controller: catalog,
              child: PhoneHero(catalog: catalog),
            ),
          ),
        ),
        GoRoute(
          path: '/item/:id',
          builder: (_, state) => Text('detail ${state.pathParameters['id']}'),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      CupertinoTestApp.router(
        theme: AppUiTheme.phoneDark(),
        locale: const Locale('zh'),
        routerConfig: router,
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(PhoneHero.openKey));
    await settle(tester);
    expect(find.text('detail hero-movie'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);
}
