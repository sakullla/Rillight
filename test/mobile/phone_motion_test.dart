import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_motion.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/home/phone_hero.dart';
import 'package:rillight/home/phone_home.dart';
import 'package:rillight/library/mobile_detail_page.dart';
import 'package:rillight/library/mobile_series_page.dart';
import 'package:rillight/media_image/media_image.dart';
import 'package:rillight/player/mobile_player_page.dart';
import 'package:rillight/player/phone_orientation.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_controller.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/video_backend.dart';

import '../emby/fake_emby_server.dart';
import '../helpers/image_cache_fixture.dart';

const _device = EmbyDeviceInfo(
  clientName: 'test',
  deviceName: 'phone',
  deviceId: 'phone-motion',
  version: '1',
);

void main() {
  setUp(isolateImageCache);

  testWidgets('poster flies to the top as the same image', (tester) async {
    await _pumpHome(tester);
    await _until(tester, find.byKey(CatalogKeys.item('movie-inception')));
    final poster = find.byKey(CatalogKeys.item('movie-inception'));
    final posterImage = tester.widget<MediaImage>(
      find.descendant(of: poster, matching: find.byType(MediaImage)),
    );

    await tester.tap(poster);
    await _until(tester, find.byKey(PhoneItemBanner.bannerKey));
    _expectSameImage(tester, posterImage, onstage: true);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Hero &&
            widget.tag ==
                PhoneMotion.imageTag('movie-inception', preferBackdrop: false),
      ),
      findsWidgets,
    );

    await _settle(tester);
    expect(tester.getTopLeft(find.byKey(PhoneItemBanner.bannerKey)).dy, 0);
    final landed = _bannerImage(tester);
    expect(landed.item.id, posterImage.item.id);
    expect(landed.preferBackdrop, isFalse);
    expect(landed.maxWidth, posterImage.maxWidth);
    expect(landed.item.primaryImageTag, posterImage.item.primaryImageTag);
    final play = find.byKey(const Key('mobile-detail-play'));
    expect(tester.widget<FilledButton>(play).onPressed, isNotNull);
    expect(find.text('Inception'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('series poster lands on the series page without a blank top', (
    tester,
  ) async {
    await _pumpHome(tester);
    final poster = find.byKey(CatalogKeys.item('series-friends'));
    await _until(tester, poster);
    final posterImage = tester.widget<MediaImage>(
      find.descendant(of: poster, matching: find.byType(MediaImage)),
    );
    await tester.tap(poster);
    await _until(tester, find.byKey(PhoneItemBanner.bannerKey));
    _expectSameImage(tester, posterImage, onstage: true);

    await _settle(tester);
    expect(tester.getTopLeft(find.byKey(PhoneItemBanner.bannerKey)).dy, 0);
    expect(_bannerImage(tester).item.id, 'series-friends');
    expect(_bannerImage(tester).preferBackdrop, isFalse);
    expect(_bannerImage(tester).maxWidth, PhoneMotion.posterRequestWidth);
    expect(find.byKey(const Key('phone-season-list')), findsOneWidget);
    expect(find.byType(ChoiceChip), findsWidgets);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('mobile-detail-play')))
          .onPressed,
      isNotNull,
    );
    expect(find.text('老友记'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the same poster id is only one hero', (tester) async {
    await _pumpHome(tester);
    await _until(tester, find.byKey(CatalogKeys.item('movie-inception')));
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Hero &&
            widget.tag ==
                PhoneMotion.imageTag('movie-inception', preferBackdrop: false),
      ),
      findsOneWidget,
    );
    await _settle(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion keeps the banner and the primary action', (
    tester,
  ) async {
    PhoneHero.autoAdvanceEnabled = true;
    addTearDown(() => PhoneHero.autoAdvanceEnabled = false);
    await _pumpHome(tester, reduceMotion: true);
    await _until(tester, find.byKey(PhoneHero.itemKey('movie-inception')));
    expect(
      tester.widget<IconButton>(find.byKey(PhoneHero.pauseKey)).onPressed,
      isNull,
    );
    expect(
      tester.widget<FilledButton>(find.byKey(PhoneHero.openKey)).onPressed,
      isNotNull,
    );
    expect(find.text('已看 40%'), findsWidgets);

    await tester.pump(const Duration(seconds: 7));
    expect(find.byKey(PhoneHero.itemKey('movie-inception')), findsOneWidget);
    expect(find.text('已看 40%'), findsWidgets);
    expect(find.text('继续播放'), findsWidgets);

    await tester.tap(find.byKey(PhoneHero.openKey));
    await _settle(tester);
    expect(tester.getTopLeft(find.byKey(PhoneItemBanner.bannerKey)).dy, 0);
    expect(_bannerImage(tester).preferBackdrop, isTrue);
    expect(_bannerImage(tester).maxWidth, PhoneMotion.heroRequestWidth);
    expect(find.textContaining('dream-sharing'), findsOneWidget);
    expect(find.textContaining('2010'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('mobile-detail-play')))
          .onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('track sheet enters from the bottom', (tester) async {
    final harness = await _pumpHome(tester);
    unawaited(harness.router.push('/item/movie-inception'));
    await _settle(tester);
    await tester.ensureVisible(find.byKey(CatalogKeys.mediaSource));
    await tester.tap(find.byKey(CatalogKeys.mediaSource));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final audio = find.text('音轨');
    expect(audio, findsOneWidget);
    final route = ModalRoute.of(tester.element(audio));
    expect(route, isA<ModalBottomSheetRoute<void>>());
    expect(route!.transitionDuration, AppMotion.normal);
    final moving = tester.getTopLeft(audio).dy;
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.getTopLeft(audio).dy, lessThan(moving));
    expect(find.text('English'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion shows the track sheet without a slide', (
    tester,
  ) async {
    final harness = await _pumpHome(tester, reduceMotion: true);
    unawaited(harness.router.push('/item/movie-inception'));
    await _settle(tester);
    await tester.ensureVisible(find.byKey(CatalogKeys.mediaSource));
    await tester.tap(find.byKey(CatalogKeys.mediaSource));
    await tester.pump();
    final audio = find.text('音轨');
    expect(audio, findsOneWidget);
    final route = ModalRoute.of(tester.element(audio));
    expect(route!.transitionDuration, Duration.zero);
    expect(find.text('English'), findsOneWidget);
    expect(find.text('中文'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('player controls fade instead of popping', (tester) async {
    final current = await _showPlayer(tester);
    expect(
      tester
          .widget<AnimatedOpacity>(find.byKey(PhoneMotion.playerControlsKey))
          .duration,
      AppMotion.normal,
    );
    expect(_controlsOpacity(tester), 1);

    current.toggleControls();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    final fading = _controlsOpacity(tester);
    expect(fading, greaterThan(0));
    expect(fading, lessThan(1));
    await tester.pump(const Duration(milliseconds: 300));
    expect(_controlsOpacity(tester), 0);

    current.toggleControls();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    final showing = _controlsOpacity(tester);
    expect(showing, greaterThan(0));
    expect(showing, lessThan(1));
    await tester.pump(const Duration(milliseconds: 300));
    expect(_controlsOpacity(tester), 1);
    await tester.tap(find.byKey(const Key('mobile-player-toggle')));
    await tester.pump();
    expect(current.isPlaying, isFalse);
    await _closePlayer(tester);
    expect(tester.takeException(), isNull);
  });
}

MediaImage _bannerImage(WidgetTester tester) {
  return tester.widget<MediaImage>(
    find.descendant(
      of: find.byKey(PhoneItemBanner.bannerKey),
      matching: find.byType(MediaImage),
      skipOffstage: false,
    ),
  );
}

void _expectSameImage(
  WidgetTester tester,
  MediaImage poster, {
  required bool onstage,
}) {
  final images = tester.widgetList<MediaImage>(
    find.byType(MediaImage, skipOffstage: onstage),
  );
  expect(
    images.where(
      (image) =>
          image.item.id == poster.item.id &&
          image.preferBackdrop == poster.preferBackdrop &&
          image.maxWidth == poster.maxWidth &&
          image.item.primaryImageTag == poster.item.primaryImageTag,
    ),
    isNotEmpty,
  );
}

double _controlsOpacity(WidgetTester tester) {
  final fade = tester.widget<FadeTransition>(
    find.descendant(
      of: find.byKey(PhoneMotion.playerControlsKey),
      matching: find.byType(FadeTransition),
    ),
  );
  return fade.opacity.value;
}

class _Harness {
  _Harness(this.router);

  final GoRouter router;
}

Future<_Harness> _pumpHome(
  WidgetTester tester, {
  bool reduceMotion = false,
}) async {
  tester.view.physicalSize = const Size(360, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  if (reduceMotion) {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  }
  final server = FakeEmbyServer();
  final auth = AuthController.memory(
    client: EmbyClient(
      device: _device,
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
  final catalog = CatalogController(auth: auth);
  catalog.resume = CatalogRowState(
    items: [
      _movie('movie-inception', 'Inception', percent: 40),
      _movie('movie-up', '飞屋环游记'),
    ],
  );
  catalog.nextUp = const CatalogRowState(hidden: true);
  catalog.latestMovies = CatalogRowState(
    items: [
      _movie('movie-inception', 'Inception', percent: 40),
      _movie('movie-up', '飞屋环游记'),
    ],
  );
  catalog.latestSeries = CatalogRowState(
    items: [
      const EmbyItem(
        id: 'series-friends',
        name: '老友记',
        type: 'Series',
        overview: 'Six friends living in New York.',
        primaryImageTag: 'tag-friends',
      ),
    ],
  );
  catalog.librariesLoading = false;
  final router = GoRouter(
    initialLocation: AppRoutes.home,
    routes: [
      GoRoute(
        path: AppRoutes.home,
        builder: (context, state) => const PhoneHome(),
      ),
      GoRoute(
        path: '/item/:itemId',
        builder: (context, state) =>
            MobileDetailPage(itemId: state.pathParameters['itemId']!),
      ),
    ],
  );
  addTearDown(router.dispose);
  addTearDown(catalog.dispose);
  addTearDown(auth.dispose);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 200));
  });
  MediaImageCache.instance.fetchTimeout = const Duration(milliseconds: 1);
  await tester.pumpWidget(
    AuthScope(
      controller: auth,
      child: CatalogScope(
        controller: catalog,
        child: MaterialApp.router(
          theme: AppTheme.dark(),
          locale: const Locale('zh'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          routerConfig: router,
        ),
      ),
    ),
  );
  await tester.pump();
  return _Harness(router);
}

EmbyItem _movie(String id, String name, {double? percent}) {
  return EmbyItem(
    id: id,
    name: name,
    type: 'Movie',
    overview: id == 'movie-inception'
        ? 'A thief who steals corporate secrets through dream-sharing.'
        : null,
    productionYear: id == 'movie-inception' ? 2010 : 2009,
    primaryImageTag: 'tag-$id',
    userData: percent == null
        ? const EmbyUserData()
        : EmbyUserData(playbackPositionTicks: 1, playedPercentage: percent),
  );
}

Future<void> _until(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 20; i++) {
    if (finder.evaluate().isNotEmpty) {
      return;
    }
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(finder, findsWidgets);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<PlayerController> _showPlayer(WidgetTester tester) async {
  final server = FakeEmbyServer();
  final auth = AuthController.memory(
    client: EmbyClient(
      device: _device,
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
  addTearDown(auth.dispose);
  final backend = FakeVideoBackend();
  tester.view.physicalSize = const Size(800, 360);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final orientation = PhoneOrientation(
    restoreTo: const [DeviceOrientation.portraitUp],
    request: (_) async {},
  );
  await tester.pumpWidget(
    AuthScope(
      controller: auth,
      child: PlayerScope(
        bindings: PlayerBindings(
          createBackend: () => backend,
          settingsStore: MemoryPlayerSettingsStore(),
          snapshotStore: MemoryPlaybackSessionSnapshotStore(),
        ),
        child: MaterialApp(
          theme: AppTheme.dark(),
          locale: const Locale('zh'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: MobilePlayerPage(
            itemId: 'movie-inception',
            orientation: orientation,
            wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
          ),
        ),
      ),
    ),
  );
  PlayerController? ready;
  for (var i = 0; i < 40; i++) {
    final page = find.byType(MobilePlayerPage);
    if (page.evaluate().isNotEmpty) {
      final current = tester.state<MobilePlayerPageState>(page).controller;
      if (current != null && !current.loading) {
        ready = current;
        break;
      }
    }
    await tester.pump(const Duration(milliseconds: 20));
  }
  await tester.pump(const Duration(milliseconds: 400));
  if (ready == null || ready.loading) {
    fail('player did not become ready');
  }
  return ready;
}

Future<void> _closePlayer(WidgetTester tester) async {
  final button = find.byTooltip('关闭');
  await tester.ensureVisible(button);
  await tester.tap(button);
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 200));
    if (find.byType(MobilePlayerPage).evaluate().isEmpty) {
      return;
    }
  }
  expect(find.byType(MobilePlayerPage), findsNothing);
}
