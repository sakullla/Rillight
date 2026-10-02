import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/featured_items.dart';
import 'package:rillight/home/hero_artwork.dart';
import 'package:rillight/home/home_hero.dart';
import 'package:rillight/home/phone_hero.dart';
import 'package:rillight/player/player_window_host.dart';

void main() {
  const episode = EmbyItem(
    id: 'episode',
    name: 'Generated frame',
    type: 'Episode',
    seriesId: 'series',
    seriesName: 'Series',
    primaryImageTag: 'generated',
    thumbImageTag: 'frame',
    backdropImageTag: 'small-frame',
    parentBackdropItemId: 'series',
    parentBackdropImageTag: 'formal',
    seriesPrimaryImageTag: 'poster',
  );
  test('episode promotional artwork excludes every local frame', () {
    final sources = heroArtworkSources(episode);
    expect(sources.backdrops.single.itemId, 'series');
    expect(sources.backdrops.single.tag, 'formal');
    expect(sources.posters.single.itemId, 'series');
    expect(sources.posters.single.tag, 'poster');
    final handoff = sources.handoffItem(episode);
    expect(handoff.id, episode.id);
    expect(
      handoff
          .imageCandidates(preferBackdrop: true)
          .any((ref) => ref.itemId == episode.id),
      isFalse,
    );
  });
  test('series metadata fills missing episode promotional artwork', () {
    final sources = heroArtworkSources(
      const EmbyItem(
        id: 'ep',
        name: 'Ep',
        type: 'Episode',
        seriesId: 'series',
        primaryImageTag: 'generated',
      ),
      series: const [
        EmbyItem(
          id: 'series',
          name: 'Series',
          type: 'Series',
          backdropImageTag: 'formal',
          primaryImageTag: 'poster',
        ),
      ],
    );
    expect(sources.backdrops.single.tag, 'formal');
    expect(sources.posters.single.tag, 'poster');
    expect(
      heroArtworkSources(
        const EmbyItem(
          id: 'ep',
          name: 'Ep',
          type: 'Episode',
          primaryImageTag: 'generated',
        ),
      ).isEmpty,
      isTrue,
    );
  });
  test('small backgrounds and portrait crops cannot fill the desktop hero', () {
    expect(HeroArtwork.suitableBackdrop(640, 360, minimumWidth: 960), isFalse);
    expect(
      HeroArtwork.suitableBackdrop(1280, 1920, minimumWidth: 960),
      isFalse,
    );
    expect(HeroArtwork.suitableBackdrop(1280, 720, minimumWidth: 960), isTrue);
    expect(HeroArtwork.suitableBackdrop(800, 450, minimumWidth: 640), isTrue);
  });

  late AuthController auth;
  late CatalogController catalog;
  setUp(() {
    auth = AuthController.memory();
    catalog = CatalogController(auth: auth);
    catalog.resume = const CatalogRowState(items: [episode]);
    catalog.latestSeries = const CatalogRowState(
      items: [
        EmbyItem(
          id: 'series',
          name: 'Series',
          type: 'Series',
          primaryImageTag: 'poster',
        ),
      ],
    );
    catalog.latestMovies = const CatalogRowState(
      items: [
        EmbyItem(
          id: 'movie',
          name: 'Movie',
          type: 'Movie',
          backdropImageTag: 'art',
        ),
      ],
    );
  });
  tearDown(() {
    catalog.dispose();
    auth.dispose();
  });
  testWidgets('desktop hero artwork and copy open details but resume plays', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    catalog.resume = CatalogRowState(
      items: [
        EmbyItem.fromJson({
          'Id': 'episode',
          'Name': 'Resume episode',
          'Type': 'Episode',
          'SeriesId': 'series',
          'UserData': {
            'PlaybackPositionTicks': 120000000,
            'PlayedPercentage': 20,
          },
        }),
      ],
    );
    final host = OverlayPlayerWindowHost();
    addTearDown(host.dispose);
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => Scaffold(body: HomeHero(catalog: catalog)),
        ),
        GoRoute(
          path: '/item/:id',
          builder: (_, state) =>
              Scaffold(body: Text('Details ${state.pathParameters['id']}')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      PlayerWindowScope(
        host: host,
        child: MaterialApp.router(
          routerConfig: router,
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('hero-resume-episode')));
    await tester.pumpAndSettle();
    expect(host.current?.itemId, 'episode');
    expect(router.canPop(), isFalse);
    final target = find.byKey(const Key('home-hero-details-target'));
    await tester.tapAt(tester.getTopRight(target) + const Offset(-40, 80));
    await tester.pumpAndSettle();
    expect(find.text('Details episode'), findsOneWidget);
    router.pop();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Resume episode').first);
    await tester.pumpAndSettle();
    expect(find.text('Details episode'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  test('resume episodes and series appear only once per title', () {
    expect(featuredHomeItems(catalog).map((item) => item.id), [
      'episode',
      'movie',
    ]);
  });

  testWidgets(
    'five phone targets remain usable with large text and a long title',
    (tester) async {
      tester.view.physicalSize = const Size(320, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      catalog.resume = const CatalogRowState();
      catalog.latestSeries = const CatalogRowState();
      catalog.latestMovies = CatalogRowState(
        items: List.generate(
          6,
          (i) => EmbyItem(
            id: '$i',
            name: '一个很长的影片名称用于检查手机两行标题与大号字体',
            type: 'Movie',
            primaryImageTag: 'poster-$i',
          ),
        ),
      );
      expect(featuredHomeItems(catalog).length, 5);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 1100),
              textScaler: TextScaler.linear(2),
            ),
            child: Scaffold(
              body: SingleChildScrollView(child: PhoneHero(catalog: catalog)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (var i = 0; i < 5; i++) {
        expect(
          tester.getSize(find.byKey(CatalogKeys.heroDot(i))),
          const Size(44, 44),
        );
      }
      expect(tester.takeException(), isNull);
    },
  );

  for (final brightness in Brightness.values) {
    for (final width in [320.0, 412.0, 1280.0]) {
      testWidgets('hero retains readable controls at $width in $brightness', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final phone = width < 600;
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: ThemeData(
              colorScheme: ColorScheme.fromSeed(
                seedColor: Colors.teal,
                brightness: brightness,
              ),
            ),
            home: Scaffold(
              body: SingleChildScrollView(
                child: phone
                    ? PhoneHero(catalog: catalog)
                    : HomeHero(catalog: catalog),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final caption = phone
            ? find.byKey(PhoneHero.bannerKey)
            : find.byKey(const Key('home-hero-card'));
        expect(
          find.descendant(of: caption, matching: find.text('Series')),
          findsOneWidget,
        );
        expect(find.byKey(CatalogKeys.heroDot(1)), findsOneWidget);
        if (phone) {
          expect(
            tester.getSize(find.byKey(PhoneHero.bannerKey)).height,
            lessThan(width * 5 / 4 + 56),
          );
          expect(
            tester
                .widget<AspectRatio>(find.byType(AspectRatio).first)
                .aspectRatio,
            16 / 9,
          );
        }
        await tester.tap(find.byKey(CatalogKeys.heroDot(1)));
        await tester.pumpAndSettle();
        expect(
          find.descendant(of: caption, matching: find.text('Movie')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      });
    }
  }
}
