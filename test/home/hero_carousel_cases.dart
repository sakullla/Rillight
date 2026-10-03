import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/hero_carousel.dart';
import 'package:rillight/home/home_hero.dart';
import 'package:rillight/home/phone_hero.dart';

void main() {
  late AuthController auth;
  late CatalogController catalog;

  setUp(() {
    HeroAutoRotate.debugForceAutoRotate = true;
    auth = AuthController.memory();
    catalog = CatalogController(auth: auth);
    catalog.resume = const CatalogRowState();
    catalog.latestSeries = const CatalogRowState();
    catalog.latestMovies = const CatalogRowState(
      items: [
        EmbyItem(
          id: 'movie-a',
          name: 'Movie A',
          type: 'Movie',
          backdropImageTag: 'art-a',
        ),
        EmbyItem(
          id: 'movie-b',
          name: 'Movie B',
          type: 'Movie',
          primaryImageTag: 'poster-b',
        ),
      ],
    );
  });

  tearDown(() {
    HeroAutoRotate.debugForceAutoRotate = false;
    catalog.dispose();
    auth.dispose();
  });

  Widget wrap(Widget child) {
    return MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    );
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }

  group('desktop auto rotate', () {
    Future<void> pumpDesktop(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(wrap(HomeHero(catalog: catalog)));
      await tester.pump();
    }

    testWidgets('advances after the interval and wraps around', (tester) async {
      await pumpDesktop(tester);
      expect(find.text('Movie A'), findsOneWidget);
      await tester.pump(HeroAutoRotate.rotateInterval);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Movie B'), findsOneWidget);
      await tester.pump(HeroAutoRotate.rotateInterval);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Movie A'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('manual switch restarts the interval', (tester) async {
      await pumpDesktop(tester);
      await tester.pump(const Duration(seconds: 3));
      await tester.tap(find.byKey(CatalogKeys.heroNext));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Movie B'), findsOneWidget);
      // 手动切换后 3 秒仍在第二页(若未重置会在此刻翻页)。
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Movie B'), findsOneWidget);
      // 手动切换满 7 秒后翻回第一页。
      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Movie A'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('hovering pauses rotation until the pointer leaves', (
      tester,
    ) async {
      await pumpDesktop(tester);
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(gesture.removePointer);
      await gesture.addPointer(
        location: tester.getCenter(find.byKey(const Key('home-hero-card'))),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 14));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Movie A'), findsOneWidget);
      await gesture.moveTo(const Offset(20, 780));
      await tester.pump();
      await tester.pump(HeroAutoRotate.rotateInterval);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Movie B'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('a single candidate never arms the timer', (tester) async {
      catalog.latestMovies = const CatalogRowState(
        items: [
          EmbyItem(
            id: 'movie-a',
            name: 'Movie A',
            type: 'Movie',
            backdropImageTag: 'art-a',
          ),
        ],
      );
      await pumpDesktop(tester);
      await tester.pump(const Duration(seconds: 14));
      await tester.pump();
      expect(find.text('Movie A'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await unmount(tester);
    });

    testWidgets('scrolling and an offscreen banner pause rotation', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        wrap(
          SingleChildScrollView(
            controller: scroll,
            child: Column(
              children: [
                HomeHero(catalog: catalog),
                const SizedBox(height: 2000),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      final gesture = await tester.startGesture(const Offset(600, 300));
      await gesture.moveBy(const Offset(0, -80));
      await tester.pump();
      await tester.pump(const Duration(seconds: 14));
      expect(find.text('Movie A'), findsOneWidget);
      await gesture.up();
      await tester.pumpAndSettle();

      // An eager child stays mounted outside the viewport. Its timer must stop.
      scroll.jumpTo(700);
      await tester.pump();
      await tester.pump(const Duration(seconds: 14));
      expect(find.text('Movie A'), findsOneWidget);
      scroll.jumpTo(0);
      await tester.pump();
      await tester.pump(HeroAutoRotate.rotateInterval);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Movie B'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('disabling tickers cancels an already armed rotation', (
      tester,
    ) async {
      final enabled = ValueNotifier(true);
      addTearDown(enabled.dispose);
      await tester.pumpWidget(
        wrap(
          ValueListenableBuilder(
            valueListenable: enabled,
            builder: (_, value, child) =>
                TickerMode(enabled: value, child: child!),
            child: HomeHero(catalog: catalog),
          ),
        ),
      );
      await tester.pump();
      enabled.value = false;
      await tester.pump();
      await tester.pump(const Duration(seconds: 14));
      expect(find.text('Movie A'), findsOneWidget);
      enabled.value = true;
      await tester.pump();
      await tester.pump(HeroAutoRotate.rotateInterval);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Movie B'), findsOneWidget);
      await unmount(tester);
    });
  });

  group('phone auto rotate', () {
    testWidgets('advances after the interval and touch pauses it', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(wrap(PhoneHero(catalog: catalog)));
      await tester.pump();
      expect(find.text('Movie A'), findsOneWidget);
      await tester.pump(HeroAutoRotate.rotateInterval);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Movie B'), findsOneWidget);

      // 按住并小幅拖动:触摸期间不再翻页。
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(PhoneHero.bannerKey)),
      );
      await gesture.moveBy(const Offset(-40, 0));
      await tester.pump();
      await tester.pump(const Duration(seconds: 14));
      expect(find.text('Movie B'), findsOneWidget);
      await gesture.up();
      await tester.pump();
      await tester.pump(HeroAutoRotate.rotateInterval);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Movie A'), findsOneWidget);
      await unmount(tester);
    });
  });
}
