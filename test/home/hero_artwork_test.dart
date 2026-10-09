import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/featured_items.dart';
import 'package:rillight/home/hero_artwork.dart';
import 'package:rillight/home/hero_carousel.dart';
import 'package:rillight/home/home_hero.dart';
import 'package:rillight/home/phone_hero.dart';
import 'package:rillight/player/player_window_host.dart';
import 'package:rillight/media_image/media_image.dart';

import '../helpers/image_cache_fixture.dart';

void main() {
  for (final posterOnly in [false, true]) {
    testWidgets('hero poster uses a bounded request, posterOnly=$posterOnly', (
      tester,
    ) async {
      isolateImageCache();
      addTearDown(MediaImage.debugClearCache);
      addTearDown(MediaImage.debugResetCacheConfiguration);
      final poster = (await tester.runAsync(() => _imageBytes(320, 480)))!;
      final client = _HeroImageClient(poster);
      final imageAuth = AuthController.memory(client: client);
      addTearDown(imageAuth.dispose);
      HeroArtworkData? resolved;
      final sources = HeroArtworkSources(
        [
          if (!posterOnly)
            const ItemImageRef(itemId: 'title', type: 'Backdrop', tag: 'bad'),
        ],
        [const ItemImageRef(itemId: 'title', type: 'Primary', tag: 'poster')],
      );
      Widget subject() => MaterialApp(
        home: AuthScope(
          controller: imageAuth,
          child: SizedBox(
            width: 1000,
            height: 400,
            child: HeroArtwork(
              sources: sources,
              requestWidth: 1920,
              onResolved: (data) => resolved = data,
            ),
          ),
        ),
      );
      await tester.pumpWidget(subject());
      await _pumpUntil(tester, () => resolved != null);
      expect(resolved!.poster, isTrue);
      expect(client.requests, [
        if (!posterOnly) ('Backdrop', 1920),
        ('Primary', 480),
      ]);
      await tester.pumpWidget(const SizedBox());
      resolved = null;
      await tester.pumpWidget(subject());
      await _pumpUntil(tester, () => resolved != null);
      expect(resolved!.poster, isTrue);
      expect(client.requests.length, posterOnly ? 1 : 2);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('a backdrop requested below 960px remains usable', (
    tester,
  ) async {
    isolateImageCache();
    addTearDown(MediaImage.debugClearCache);
    addTearDown(MediaImage.debugResetCacheConfiguration);
    final bytes = (await tester.runAsync(() => _imageBytes(800, 450)))!;
    final client = _HeroImageClient(bytes, backdrop: bytes);
    final imageAuth = AuthController.memory(client: client);
    addTearDown(imageAuth.dispose);
    HeroArtworkData? resolved;
    Widget subject({bool prefetch = false}) => MaterialApp(
      home: AuthScope(
        controller: imageAuth,
        child: HeroArtwork(
          sources: const HeroArtworkSources(
            [ItemImageRef(itemId: 'title', type: 'Backdrop', tag: 'small')],
            [ItemImageRef(itemId: 'title', type: 'Primary', tag: 'poster')],
          ),
          requestWidth: 800,
          prefetch: prefetch,
          onResolved: (data) => resolved = data,
        ),
      ),
    );
    await tester.pumpWidget(subject());
    await _pumpUntil(tester, () => resolved != null);
    expect(resolved!.poster, isFalse);
    expect(client.requests, [('Backdrop', 800)]);

    // A carousel slide that comes back shows its cached art on the very first
    // frame instead of flashing the placeholder while an async load resolves.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(subject());
    expect(find.byType(Image), findsOneWidget);
    expect(client.requests, [('Backdrop', 800)]);

    // Prefetch paints nothing and never reports a layout to the parent.
    resolved = null;
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(subject(prefetch: true));
    await tester.pump();
    expect(find.byType(Image), findsNothing);
    expect(resolved, isNull);
    await tester.pumpWidget(const SizedBox());
  });
  test(
    'season posters fall back to the series endpoint without a missing-image request',
    () {
      const series = EmbyItem(
        id: 'series',
        name: '',
        type: 'Series',
        primaryImageTag: 'series-poster',
      );
      for (final tag in <String?>[null, 'season-poster', 'series-poster']) {
        final season = seasonArtworkItem(
          EmbyItem(
            id: 'season',
            name: '',
            type: 'Season',
            primaryImageTag: tag,
          ),
          series,
        );
        final refs = season.imageCandidates();
        expect(refs.last.itemId, 'series');
        expect(refs.last.tag, 'series-poster');
        expect(refs.last.type, 'Primary');
        if (tag == 'season-poster') {
          expect(refs.map((r) => r.itemId), ['season', 'series']);
        } else {
          expect(refs.length, 1);
        }
      }
    },
  );

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
    // 续播条目不进轮播:首帧是最新电影,没有观看进度与「继续播放」。
    expect(find.byKey(const ValueKey('hero-resume-episode')), findsNothing);
    expect(find.textContaining('已看'), findsNothing);
    expect(find.text('继续播放'), findsNothing);
    expect(find.text('最新电影'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('hero-resume-movie')));
    await tester.pumpAndSettle();
    expect(host.current?.itemId, 'movie');
    expect(router.canPop(), isFalse);
    final target = find.byKey(const Key('home-hero-details-target'));
    await tester.tapAt(tester.getTopRight(target) + const Offset(-40, 80));
    await tester.pumpAndSettle();
    expect(find.text('Details movie'), findsOneWidget);
    router.pop();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Movie').first);
    await tester.pumpAndSettle();
    expect(find.text('Details movie'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  test(
    'latest movies and series alternate; resume rows never feed the hero',
    () {
      expect(featuredHomeItems(catalog).map((item) => item.id), [
        'movie',
        'series',
      ]);
      catalog.nextUp = const CatalogRowState(items: [episode]);
      expect(featuredHomeItems(catalog).map((item) => item.id), [
        'movie',
        'series',
      ]);
      catalog.latestMovies = const CatalogRowState();
      expect(featuredHomeItems(catalog).map((item) => item.id), ['series']);
    },
  );

  test('poster-only titles stay featured; artless titles are excluded', () {
    catalog.resume = const CatalogRowState();
    catalog.latestSeries = const CatalogRowState();
    catalog.latestMovies = const CatalogRowState(
      items: [
        EmbyItem(
          id: 'poster-only',
          name: 'Poster only',
          type: 'Movie',
          primaryImageTag: 'poster',
        ),
        EmbyItem(id: 'artless', name: 'Artless', type: 'Movie'),
      ],
    );
    expect(featuredHomeItems(catalog).map((item) => item.id), ['poster-only']);
  });

  testWidgets('rating badge hides without a score and shows one decimal', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              HeroRatingBadge(rating: null),
              HeroRatingBadge(rating: 8.84),
            ],
          ),
        ),
      ),
    );
    expect(find.byIcon(Icons.star_rounded), findsOneWidget);
    expect(find.text('8.8'), findsOneWidget);
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
          find.descendant(of: caption, matching: find.text('Movie')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: caption, matching: find.text('最新电影')),
          findsOneWidget,
        );
        expect(find.byKey(CatalogKeys.heroDot(1)), findsOneWidget);
        if (phone) {
          // 手机轮播高度与骨架屏使用的估算一致,顶栏延伸 56 以内。
          final expected =
              56 + PhoneHero.contentHeightFor(width, viewportHeight: 900);
          expect(
            tester.getSize(find.byKey(PhoneHero.bannerKey)).height,
            inInclusiveRange(expected, expected + 24),
          );
          expect(
            find.descendant(of: caption, matching: find.byType(HeroArtwork)),
            findsWidgets,
          );
        }
        await tester.tap(find.byKey(CatalogKeys.heroDot(1)));
        await tester.pumpAndSettle();
        expect(
          find.descendant(of: caption, matching: find.text('Series')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: caption, matching: find.text('最新剧集')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      });
    }
  }
}

Future<Uint8List> _imageBytes(int width, int height) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawColor(Colors.green, BlendMode.src);
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return bytes!.buffer.asUint8List();
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() ready) async {
  for (var attempt = 0; attempt < 50 && !ready(); attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expect(ready(), isTrue);
}

class _HeroImageClient extends EmbyClient {
  _HeroImageClient(this.poster, {Uint8List? backdrop})
    : backdrop = backdrop ?? Uint8List.fromList([1, 2, 3]),
      super(
        device: const EmbyDeviceInfo(
          clientName: 'test',
          deviceName: 'test',
          deviceId: 'hero-images',
          version: '1',
        ),
      ) {
    attachSession(
      baseUrl: Uri.parse('https://hero.example/emby'),
      accessToken: 'synthetic',
      userId: 'test',
    );
  }

  final Uint8List poster;
  final Uint8List backdrop;
  final requests = <(String, int)>[];

  @override
  Future<List<int>> getItemImage(
    String itemId, {
    String type = 'Primary',
    int? index,
    String? tag,
    int maxWidth = 280,
    CancelToken? cancelToken,
  }) async {
    requests.add((type, maxWidth));
    return type == 'Backdrop' ? backdrop : poster;
  }
}
