import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/theme/tokens.dart';
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
          productionYear: 2024,
          communityRating: 8.5,
        ),
        EmbyItem(
          id: 'movie-b',
          name: 'Movie B',
          type: 'Movie',
          primaryImageTag: 'poster-b',
          productionYear: 2025,
          communityRating: 8.6,
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

  group('desktop stage layout', () {
    for (final size in const [
      Size(1024, 768),
      Size(1440, 900),
      Size(1920, 1080),
    ]) {
      testWidgets('full-bleed stage keeps cinematic proportions at $size', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        catalog.latestMovies = CatalogRowState(
          items: [
            for (final id in ['a', 'b', 'c'])
              EmbyItem(
                id: 'movie-$id',
                name: 'Movie $id',
                type: 'Movie',
                backdropImageTag: 'art-$id',
                overview: '\u4e00\u6bb5\u5f88\u957f\u7684\u7b80\u4ecb' * 40,
              ),
          ],
        );
        await tester.pumpWidget(
          wrap(
            SingleChildScrollView(
              child: HomeHero(catalog: catalog, topOverlap: 56),
            ),
          ),
        );
        await tester.pump();
        final card = tester.getRect(find.byKey(const Key('home-hero-card')));
        // Edge to edge, no side gutters or a box shape under the top bar.
        expect(card.left, 0);
        expect(card.width, size.width);
        // Neither a thin letterbox strip nor the whole first screen.
        expect(card.width / card.height, inInclusiveRange(1.6, 2.8));
        expect(card.height, lessThan(size.height * .8));

        final title = tester.getRect(find.text('Movie a'));
        final textBlock = tester.getRect(
          find.byKey(const ValueKey('home-hero-text-movie-a')),
        );
        // Overview wraps inside the text column instead of spanning the stage.
        expect(
          textBlock.width,
          lessThanOrEqualTo(HomeHero.textBlockWidthFor(size.width) + .5),
        );
        // Copy is aligned with the shelf gutter and clear of the top bar.
        expect(textBlock.left, AppSpacing.page);
        expect(textBlock.top, greaterThan(56));
        // Switch controls never sit on top of the title or copy.
        for (final key in [CatalogKeys.heroPrev, CatalogKeys.heroNext]) {
          final control = tester.getRect(find.byKey(key));
          expect(control.overlaps(title), isFalse);
          expect(control.overlaps(textBlock), isFalse);
        }
        expect(tester.takeException(), isNull);
        await unmount(tester);
      });
    }

    testWidgets('switching keeps one caption once the transition ends', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        wrap(
          SingleChildScrollView(
            child: HomeHero(catalog: catalog, topOverlap: 56),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(CatalogKeys.heroNext));
      await tester.pump();
      // Mid-transition the old caption has already faded out before the new
      // one is fully in, so the two never print over each other at full ink.
      await tester.pump(heroSlideDuration * .5);
      final opacities = tester
          .widgetList<FadeTransition>(
            find.ancestor(
              of: find.text('Movie A'),
              matching: find.byType(FadeTransition),
            ),
          )
          .map((fade) => fade.opacity.value);
      expect(opacities.first, 0);
      await tester.pump(heroBackdropDuration);
      expect(find.text('Movie A'), findsNothing);
      expect(find.text('Movie B'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await unmount(tester);
    });
  });

  group('desktop auto rotate', () {
    testWidgets(
      'loaded idle desktop hero does not continuously schedule frames',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(wrap(HomeHero(catalog: catalog)));
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump(const Duration(milliseconds: 500));
        expect(tester.hasRunningAnimations, isFalse);
        expect(tester.binding.hasScheduledFrame, isFalse);
        expect(find.text('Movie A'), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.binding.hasScheduledFrame, isFalse);
        await unmount(tester);
      },
    );

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

    testWidgets(
      'desktop active dot stays static while hover reveals controls',
      (tester) async {
        await pumpDesktop(tester);
        await tester.pump();
        Finder countdown() => find.byType(TweenAnimationBuilder<double>);
        expect(countdown(), findsNothing);

        final gesture = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
        );
        addTearDown(gesture.removePointer);
        await gesture.addPointer(
          location: tester.getCenter(find.byKey(const Key('home-hero-card'))),
        );
        await tester.pump();
        await tester.pump();
        expect(countdown(), findsNothing);
        // 悬停时左右箭头浮现。
        final next = find.ancestor(
          of: find.byKey(CatalogKeys.heroNext),
          matching: find.byType(AnimatedOpacity),
        );
        expect(tester.widget<AnimatedOpacity>(next.first).opacity, 1);

        await gesture.moveTo(const Offset(20, 780));
        await tester.pump();
        await tester.pump();
        expect(countdown(), findsNothing);
        expect(tester.widget<AnimatedOpacity>(next.first).opacity, 0);
        await unmount(tester);
      },
    );

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
      // Allow scrolling to stop before the rotation timer is rearmed.
      await tester.pump(const Duration(seconds: 1));

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

  group('phone swipe area', () {
    testWidgets('play and details taps still open the selected item', (
      tester,
    ) async {
      HeroAutoRotate.debugForceAutoRotate = false;
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => Scaffold(body: PhoneHero(catalog: catalog)),
          ),
          for (final action in ['item', 'play'])
            GoRoute(
              path: '/$action/:id',
              builder: (_, state) =>
                  Scaffold(body: Text('$action ${state.pathParameters['id']}')),
            ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        MaterialApp.router(
          routerConfig: router,
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      );
      await tester.pumpAndSettle();
      await tester.drag(find.text('Movie A'), const Offset(-180, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('hero-resume-movie-b')));
      await tester.pumpAndSettle();
      expect(find.text('play movie-b'), findsOneWidget);
      router.pop();
      await tester.pumpAndSettle();
      await tester.tap(find.text('详情'));
      await tester.pumpAndSettle();
      expect(find.text('item movie-b'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await unmount(tester);
    });

    for (final area in ['title', 'metadata', 'play', 'details', 'poster']) {
      testWidgets('swiping $area changes pages in both directions', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(360, 800);
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
                  PhoneHero(catalog: catalog),
                  const SizedBox(height: 1200),
                ],
              ),
            ),
          ),
        );
        await tester.pump();
        Finder target(bool second) => switch (area) {
          'title' => find.text(second ? 'Movie B' : 'Movie A'),
          'metadata' => find.text(second ? '2025' : '2024'),
          'play' => find.byKey(
            ValueKey('hero-resume-movie-${second ? 'b' : 'a'}'),
          ),
          'details' => find.text('详情'),
          _ => find.byKey(PhoneHero.openKey),
        };
        // Start on the actual text/button, not the poster PageView.
        await tester.drag(target(false), const Offset(-180, 0));
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(find.text('Movie B'), findsOneWidget);
        expect(find.text('Movie A'), findsNothing);
        expect(scroll.offset, 0);
        await tester.drag(target(true), const Offset(180, 0));
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(find.text('Movie A'), findsOneWidget);
        expect(find.text('Movie B'), findsNothing);
        // The same area must still let the containing home page scroll.
        await tester.drag(target(false), const Offset(0, -150));
        await tester.pump();
        expect(scroll.offset, greaterThan(50));
        expect(find.text('Movie A'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await unmount(tester);
      });
    }
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
