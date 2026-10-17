import '../helpers/cupertino_test_app.dart';
import '../helpers/widget_harness.dart';
import '../helpers/settle.dart';

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:rillight/app/ui/app_icons.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;
import 'package:go_router/go_router.dart';
import 'package:rillight/aggregation/identity/media_identity.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_chrome.dart';
import 'package:rillight/app/mobile_motion.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/app/widgets/poster_placeholder.dart';
import 'package:rillight/app/widgets/skeleton.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/media_server/media_server_client.dart';
import 'package:rillight/emby/catalog_cache.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/media_server/device.dart';
import 'package:rillight/media_server/models.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/home/media_shelf.dart';
import 'package:rillight/home/phone_shelf_page.dart';
import 'package:rillight/library/detail_source_scope.dart';
import 'package:rillight/library/episode_detail_sections.dart';
import 'package:rillight/library/mobile_detail_page.dart';
import 'package:rillight/library/mobile_library_page.dart';
import 'package:rillight/library/mobile_series_page.dart';
import 'package:rillight/media_image/media_image.dart';
import 'package:rillight/player/playback_runtime.dart';
import 'package:rillight/player/player_host_command.dart';

import '../emby/fake_emby_server.dart';
import '../helpers/image_cache_fixture.dart';
import '../helpers/synthetic_source_fixture.dart';

const _device = ClientDeviceInfo(
  clientName: 'test',
  deviceName: 'phone',
  deviceId: 'phone-detail-rows',
  version: '1',
);

const _pendingHeader = Key('phone-detail-pending-header');
const _pendingTitle = Key('phone-detail-pending-title');
const _pendingAction = Key('phone-detail-pending-action');
const _pendingBody = Key('phone-detail-pending-body');
const _episodePlaceholder = Key('phone-season-episode-placeholder');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(isolateImageCache);

  testWidgets('long episode list builds only rows near the viewport', (
    tester,
  ) async {
    final episodes = [
      for (var index = 0; index < 80; index++)
        MediaItem(
          id: 'episode-$index',
          name: '第 $index 集',
          type: 'Episode',
          overview: index < 40
              ? '前半季有较长的剧情介绍，用于模拟各集卡片高度变化。'
                    '角色在不同场景中继续行动，并留下足够的文字让简介折成两行。'
              : null,
        ),
    ];
    await tester.pumpWidget(
      CupertinoTestApp(
        locale: const Locale('zh'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: [
          AppLocalizations.delegate,
          ...GlobalCupertinoLocalizations.delegates,
        ],
        theme: AppUiTheme.dark(),
        home: CupertinoPageScaffold(
          child: Builder(
            builder: (context) => CustomScrollView(
              slivers: MobileSeriesPage(
                item: const MediaItem(id: 'series', name: '剧', type: 'Series'),
                seasons: const [],
                seasonId: null,
                episodes: episodes,
                episodesLoading: false,
                episodeError: null,
                hasMore: false,
                playTargetId: null,
                similar: const [],
                onSelectSeason: _ignore,
                onOpenEpisode: _ignore,
                onRetryEpisodes: _noop,
                onLoadMore: _noop,
                onOpenItem: _ignore,
                onOpenSimilar: _noop,
              ).buildSlivers(context),
            ),
          ),
        ),
      ),
    );
    expect(find.byKey(CatalogKeys.episode('episode-0')), findsOneWidget);
    expect(find.byKey(CatalogKeys.episode('episode-79')), findsNothing);
    expect(find.byType(MediaImage).evaluate().length, lessThan(20));
    await tester.scrollUntilVisible(
      find.byKey(CatalogKeys.episode('episode-79')),
      500,
      maxScrolls: 80,
    );
    expect(find.byKey(CatalogKeys.episode('episode-79')), findsOneWidget);
    expect(find.byKey(CatalogKeys.episode('episode-0')), findsNothing);
  });

  testWidgets('distant initial episode is located without eager rows', (
    tester,
  ) async {
    final episodes = [
      for (var index = 0; index < 80; index++)
        MediaItem(
          id: 'episode-$index',
          name: '第 $index 集',
          type: 'Episode',
          overview: index < 40
              ? '前半季有较长的剧情介绍，用于模拟各集卡片高度变化。'
                    '角色在不同场景中继续行动，并留下足够的文字让简介折成两行。'
              : null,
        ),
    ];
    final scroll = ScrollController();
    final coordinator = EpisodeScrollCoordinator(scroll);
    addTearDown(() {
      coordinator.dispose();
      scroll.dispose();
    });
    await tester.pumpWidget(
      CupertinoTestApp(
        locale: const Locale('zh'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: [
          AppLocalizations.delegate,
          ...GlobalCupertinoLocalizations.delegates,
        ],
        theme: AppUiTheme.dark(),
        home: CupertinoPageScaffold(
          child: Builder(
            builder: (context) => CustomScrollView(
              controller: scroll,
              slivers: MobileSeriesPage(
                item: const MediaItem(id: 'series', name: '剧', type: 'Series'),
                seasons: const [],
                seasonId: null,
                episodes: episodes,
                episodesLoading: false,
                episodeError: null,
                hasMore: false,
                playTargetId: null,
                focusEpisodeId: 'episode-75',
                scrollCoordinator: coordinator,
                similar: const [],
                onSelectSeason: _ignore,
                onOpenEpisode: _ignore,
                onRetryEpisodes: _noop,
                onLoadMore: _noop,
                onOpenItem: _ignore,
                onOpenSimilar: _noop,
              ).buildSlivers(context),
            ),
          ),
        ),
      ),
    );
    await settle(tester);
    final focused = find.byKey(CatalogKeys.episode('episode-75'));
    expect(focused, findsOneWidget);
    final rect = tester.getRect(focused);
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.top, lessThan(tester.view.physicalSize.height));
    expect(find.byKey(CatalogKeys.episode('episode-0')), findsNothing);
    expect(find.byType(MediaImage).evaluate().length, lessThan(20));
  });

  for (final width in [360.0, 412.0]) {
    testWidgets('cast rows settle on whole cards at ${width.toInt()}dp', (
      tester,
    ) async {
      const height = 1800.0;
      await _pumpPeople(
        tester,
        width: width,
        height: height,
        environment: PresentationEnvironment.phone,
      );
      expect(tester.takeException(), isNull);

      final actor0 = find.byKey(const ValueKey('episode-person-Actor-0'));
      final actor1 = find.byKey(const ValueKey('episode-person-Actor-1'));
      final actor2 = find.byKey(const ValueKey('episode-person-Actor-2'));
      expect(actor0, findsOneWidget);
      expect(actor1, findsOneWidget);
      expect(actor2, findsNothing);

      final first = tester.getRect(actor0);
      final second = tester.getRect(actor1);
      _expectOnScreen(first, width, height);
      _expectOnScreen(second, width, height);
      expect(first.left, closeTo(16, 1));
      expect(second.left, greaterThanOrEqualTo(first.right - 0.5));
      expect(second.left - first.right, closeTo(AppSpacing.xs, 1));

      final image = find.descendant(
        of: actor1,
        matching: find.byKey(EpisodePeopleSection.imageKey),
      );
      final poster = tester.getRect(image);
      final cardWidth = phoneHomePosterCardWidth(width);
      _expectOnScreen(poster, width, height);
      expect(poster.width, closeTo(cardWidth, 0.5));
      expect(poster.height, closeTo(cardWidth * 1.5, 0.5));
      final decoration =
          tester
                  .widget<DecoratedBox>(
                    find.descendant(
                      of: image,
                      matching: find.byType(DecoratedBox),
                    ),
                  )
                  .decoration
              as BoxDecoration;
      expect(decoration.borderRadius, BorderRadius.circular(AppRadii.md));
      expect(
        decoration.color,
        AppUiTheme.of(tester.element(image)).colorScheme.surfaceContainerLow,
      );
      expect(
        find.descendant(of: image, matching: find.text('B')),
        findsOneWidget,
      );
      expect(
        find.byWidgetPredicate(
          (widget) => widget.runtimeType.toString() == 'CircleAvatar',
        ),
        findsNothing,
      );
      final role = tester.getRect(
        find.descendant(of: actor1, matching: find.text('Friend')),
      );
      _expectInside(role, tester.getRect(actor1));

      final longName = tester.getRect(
        find.descendant(
          of: actor0,
          matching: find.textContaining('Alexandria'),
        ),
      );
      expect(longName.left, greaterThanOrEqualTo(first.left - 0.5));
      expect(longName.right, lessThanOrEqualTo(first.right + 0.5));

      expect(
        tester.getTopLeft(find.text('演员')).dy,
        lessThan(tester.getTopLeft(find.text('导演')).dy),
      );
      expect(
        tester.getTopLeft(find.text('导演')).dy,
        lessThan(tester.getTopLeft(find.text('编剧')).dy),
      );
      expect(
        tester.getTopLeft(find.text('编剧')).dy,
        lessThan(tester.getTopLeft(find.text('其他')).dy),
      );

      final other = tester.getRect(
        find.byKey(const ValueKey('episode-person--0')),
      );
      _expectOnScreen(other, width, height);
      expect(other.left, closeTo(16, 1));
      expect(width - other.right, greaterThanOrEqualTo(15));
      expect(
        find.descendant(
          of: find.descendant(
            of: find.byKey(const ValueKey('episode-person--1')),
            matching: find.byKey(EpisodePeopleSection.imageKey),
          ),
          matching: find.text('?'),
        ),
        findsOneWidget,
      );

      final strip = find.byType(PageView).first;
      for (var i = 0; i < 4; i++) {
        if (find
            .byKey(const ValueKey('episode-person-Actor-4'))
            .evaluate()
            .isNotEmpty) {
          break;
        }
        await tester.fling(strip, Offset(-width, 0), 2000);
        await settle(tester);
      }
      final last = tester.getRect(
        find.byKey(const ValueKey('episode-person-Actor-4')),
      );
      _expectOnScreen(last, width, height);
      expect(last.right, closeTo(width - first.left, 1));
      expect(
        find.byKey(const ValueKey('episode-person-Actor-3')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('wide cast scrolls one row instead of wrapping', (tester) async {
    const width = 1440.0;
    const height = 1800.0;
    await _pumpPeople(
      tester,
      width: width,
      height: height,
      environment: PresentationEnvironment.desktop,
    );
    final section = find.byKey(EpisodePeopleSection.sectionKey);
    expect(
      find.descendant(of: section, matching: find.byType(PageView)),
      findsNothing,
    );
    expect(
      find.descendant(of: section, matching: find.byType(Wrap)),
      findsNothing,
    );
    final tops = <double>[];
    for (var i = 0; i < 5; i++) {
      final rect = tester.getRect(
        find.byKey(ValueKey('episode-person-Actor-$i')),
      );
      _expectOnScreen(rect, width, height);
      tops.add(rect.top);
    }
    for (final top in tops) {
      expect(top, closeTo(tops.first, 1));
    }
    final image = find.descendant(
      of: find.byKey(const ValueKey('episode-person-Actor-0')),
      matching: find.byKey(EpisodePeopleSection.imageKey),
    );
    final poster = tester.getRect(image);
    // 宽桌面是圆形头像:宽高相等,圆角为半径。
    final cardWidth = EpisodePeopleSection.desktopAvatarWidth(width);
    expect(poster.width, closeTo(cardWidth, 0.5));
    expect(poster.height, closeTo(cardWidth, 0.5));
    final decoration =
        tester
                .widget<DecoratedBox>(
                  find
                      .descendant(
                        of: image,
                        matching: find.byType(DecoratedBox),
                      )
                      .first,
                )
                .decoration
            as BoxDecoration;
    expect(decoration.borderRadius, BorderRadius.circular(cardWidth / 2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('wide cast keeps one role on a single horizontal row', (
    tester,
  ) async {
    const width = 1024.0;
    const height = 900.0;
    await _pumpPeople(
      tester,
      width: width,
      height: height,
      people: [
        for (var i = 0; i < 12; i++)
          ItemPerson(name: '演员$i', type: 'Actor', role: '角色$i'),
      ],
    );
    final section = find.byKey(EpisodePeopleSection.sectionKey);
    expect(
      find.descendant(of: section, matching: find.byType(Wrap)),
      findsNothing,
    );
    expect(
      find.descendant(of: section, matching: find.byType(PageView)),
      findsNothing,
    );
    final first = tester.getRect(
      find.byKey(const ValueKey('episode-person-Actor-0')),
    );
    final last = tester.getRect(
      find.byKey(const ValueKey('episode-person-Actor-11')),
    );
    expect(last.top, closeTo(first.top, 1));
    expect(last.left, greaterThan(width));
    final poster = tester.getRect(
      find.descendant(
        of: find.byKey(const ValueKey('episode-person-Actor-0')),
        matching: find.byKey(EpisodePeopleSection.imageKey),
      ),
    );
    expect(
      poster.width,
      closeTo(EpisodePeopleSection.desktopAvatarWidth(width), 0.5),
    );
    expect(poster.height / poster.width, closeTo(1, 0.02));
    expect(tester.takeException(), isNull);
  });

  testWidgets('wide cast drags with the left mouse button and the arrow', (
    tester,
  ) async {
    await _pumpPeople(
      tester,
      width: 1024,
      height: 900,
      people: [
        for (var i = 0; i < 12; i++)
          ItemPerson(name: '演员$i', type: 'Actor', role: '角色$i'),
      ],
    );
    final section = find.byKey(EpisodePeopleSection.sectionKey);
    final scrollable = find.descendant(
      of: section,
      matching: find.byType(Scrollable),
    );
    ScrollPosition position() {
      return tester.state<ScrollableState>(scrollable).position;
    }

    expect(position().maxScrollExtent, greaterThan(0));
    expect(position().pixels, 0);
    expect(
      find.byKey(CatalogKeys.shelfScrollRight('people-Actor')),
      findsOneWidget,
    );
    final before = tester.getTopLeft(
      find.byKey(const ValueKey('episode-person-Actor-0')),
    );
    await tester.drag(
      find.byKey(const ValueKey('episode-person-Actor-0')),
      const Offset(-120, 0),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    expect(position().pixels, greaterThan(40));
    expect(
      tester
          .getTopLeft(find.byKey(const ValueKey('episode-person-Actor-0')))
          .dx,
      lessThan(before.dx - 40),
    );
    final dragged = position().pixels;
    await tester.tap(find.byKey(CatalogKeys.shelfScrollRight('people-Actor')));
    await settle(tester);
    expect(position().pixels, greaterThan(dragged + 40));
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow desktop pages whole poster cards', (tester) async {
    const width = 360.0;
    const height = 1800.0;
    await _pumpPeople(tester, width: width, height: height);
    expect(find.byType(PageView), findsWidgets);
    expect(find.byKey(const ValueKey('episode-person-Actor-2')), findsNothing);
    final first = tester.getRect(
      find.byKey(const ValueKey('episode-person-Actor-0')),
    );
    expect(first.left, closeTo(24, 1));
    final poster = tester.getRect(
      find.descendant(
        of: find.byKey(const ValueKey('episode-person-Actor-0')),
        matching: find.byKey(EpisodePeopleSection.imageKey),
      ),
    );
    expect(poster.width, closeTo(MediaShelf.posterWidthFor(width), 0.5));
    expect(poster.height, closeTo(poster.width * 1.5, 0.5));
    expect(
      find.byWidgetPredicate(
        (widget) => widget.runtimeType.toString() == 'CircleAvatar',
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('tv cast is a focusable horizontal poster row', (tester) async {
    const width = 960.0;
    const height = 1600.0;
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await _pumpPeople(
      tester,
      width: width,
      height: height,
      environment: PresentationEnvironment.tv,
      people: [
        for (var i = 0; i < 10; i++)
          ItemPerson(id: 'actor-$i', name: '演员$i', type: 'Actor', role: '角色$i'),
        const ItemPerson(name: '无编号', type: 'Actor'),
        const ItemPerson(id: 'director-1', name: '导演甲', type: 'Director'),
        const ItemPerson(id: 'writer-1', name: '编剧甲', type: 'Writer'),
        const ItemPerson(name: '制片', type: 'Producer'),
      ],
    );
    final section = find.byKey(EpisodePeopleSection.sectionKey);
    expect(
      find.descendant(of: section, matching: find.byType(PageView)),
      findsNothing,
    );
    expect(
      find.descendant(of: section, matching: find.byType(Wrap)),
      findsNothing,
    );
    expect(
      tester.getTopLeft(find.text('演员')).dy,
      lessThan(tester.getTopLeft(find.text('导演')).dy),
    );
    expect(
      tester.getTopLeft(find.text('导演')).dy,
      lessThan(tester.getTopLeft(find.text('编剧')).dy),
    );
    expect(
      tester.getTopLeft(find.text('编剧')).dy,
      lessThan(tester.getTopLeft(find.text('其他')).dy),
    );
    final first = tester.getRect(
      find.byKey(const ValueKey('episode-person-Actor-0')),
    );
    final offscreen = tester.getRect(
      find.byKey(const ValueKey('episode-person-Actor-9')),
    );
    expect(offscreen.top, closeTo(first.top, 1));
    expect(offscreen.left, greaterThan(width));
    final unnamed = find.byKey(const ValueKey('episode-person-Actor-10'));
    expect(unnamed, findsOneWidget);
    expect(tester.getRect(unnamed).top, closeTo(first.top, 1));
    expect(
      find.descendant(
        of: unnamed,
        matching: find.byType(FocusableActionDetector),
      ),
      findsOneWidget,
    );
    final image = find.descendant(
      of: find.byKey(const ValueKey('episode-person-Actor-0')),
      matching: find.byKey(EpisodePeopleSection.imageKey),
    );
    final poster = tester.getRect(image);
    final cardWidth =
        TvDesign.posterWidth * TvDesign.scaleOf(tester.element(image));
    expect(poster.width, closeTo(cardWidth, 0.5));
    expect(poster.height, closeTo(cardWidth * 1.5, 0.5));
    final decoration =
        tester
                .widget<DecoratedBox>(
                  find.descendant(
                    of: image,
                    matching: find.byType(DecoratedBox),
                  ),
                )
                .decoration
            as BoxDecoration;
    expect(
      decoration.borderRadius,
      BorderRadius.circular(
        TvDesign.cardRadius * TvDesign.scaleOf(tester.element(image)),
      ),
    );

    final detector = find.descendant(
      of: find.byKey(const ValueKey('episode-person-Actor-0')),
      matching: find.byType(FocusableActionDetector),
    );
    tester.widget<FocusableActionDetector>(detector).focusNode!.requestFocus();
    await tester.pump();
    for (var i = 0; i < 9; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
    }
    final revealed = tester.getRect(
      find.byKey(const ValueKey('episode-person-Actor-9')),
    );
    _expectOnScreen(revealed, width, height);
    expect(
      tester
          .widget<FocusableActionDetector>(
            find.descendant(
              of: find.byKey(const ValueKey('episode-person-Actor-9')),
              matching: find.byType(FocusableActionDetector),
            ),
          )
          .focusNode!
          .hasFocus,
      isTrue,
    );
    expect(
      tester.getRect(unnamed).right,
      greaterThan(width),
      reason: 'the nameless card is still past the viewport',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    final unnamedRect = tester.getRect(unnamed);
    _expectOnScreen(unnamedRect, width, height);
    expect(_personFocused(tester, unnamed), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(
      _personFocused(tester, unnamed),
      isTrue,
      reason: 'the last card in the row keeps the key',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(_personFocused(tester, unnamed), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(
      _personFocused(
        tester,
        find.byKey(const ValueKey('episode-person-Actor-9')),
      ),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('tv cast without ids still reveals later cards', (tester) async {
    const width = 960.0;
    const height = 1600.0;
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final people = [
      for (var i = 0; i < 10; i++) ItemPerson(name: '路人$i', type: 'Actor'),
      const ItemPerson(id: 'person-ada', name: '艾达', type: 'Actor'),
    ];
    final router = GoRouter(
      initialLocation: '/detail',
      routes: [
        GoRoute(
          path: '/detail',
          builder: (context, state) => PresentationScope(
            environment: PresentationEnvironment.tv,
            child: CupertinoPageScaffold(
              child: EpisodePeopleSection(people: people),
            ),
          ),
        ),
        GoRoute(
          path: '/person/:personId',
          builder: (context, state) => CupertinoPageScaffold(
            child: Text('person ${state.pathParameters['personId']}'),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    _useSurface(tester, width, height);
    await tester.pumpWidget(
      CupertinoTestApp.router(
        locale: const Locale('zh'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: [
          AppLocalizations.delegate,
          ...GlobalCupertinoLocalizations.delegates,
        ],
        theme: AppUiTheme.dark(),
        routerConfig: router,
      ),
    );
    await settle(tester);
    final first = find.byKey(const ValueKey('episode-person-Actor-0'));
    final last = find.byKey(const ValueKey('episode-person-Actor-9'));
    expect(tester.getRect(last).left, greaterThan(width));
    tester
        .widget<FocusableActionDetector>(
          find.descendant(
            of: first,
            matching: find.byType(FocusableActionDetector),
          ),
        )
        .focusNode!
        .requestFocus();
    await tester.pump();
    for (var i = 0; i < 9; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
    }
    _expectOnScreen(tester.getRect(last), width, height);
    expect(_personFocused(tester, last), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await settle(tester);
    expect(router.state.uri.path, '/detail');
    expect(find.text('路人9'), findsWidgets);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    final identified = find.byKey(const ValueKey('episode-person-Actor-10'));
    _expectOnScreen(tester.getRect(identified), width, height);
    expect(_personFocused(tester, identified), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await settle(tester);
    expect(router.state.uri.path, '/person/person-ada');
    expect(router.state.uri.queryParameters['name'], '艾达');
    expect(tester.takeException(), isNull);
  });

  for (final environment in [
    PresentationEnvironment.desktop,
    PresentationEnvironment.phone,
    PresentationEnvironment.tv,
  ]) {
    testWidgets(
      '${environment.presentation.name} person cards open one path and stay without an id',
      (tester) async {
        final router = await _pumpCastRoute(tester, environment: environment);
        addTearDown(router.dispose);
        final actor = find.byKey(const ValueKey('episode-person-Actor-0'));
        final unnamed = find.byKey(const ValueKey('episode-person-Actor-1'));
        final director = find.byKey(
          const ValueKey('episode-person-Director-0'),
        );
        expect(unnamed, findsOneWidget);
        if (environment.isTv) {
          expect(
            find.descendant(of: unnamed, matching: find.byType(TvAction)),
            findsOneWidget,
          );
        } else {
          expect(
            find.descendant(
              of: unnamed,
              matching: find.byWidgetPredicate(
                (widget) => widget is AppSurfaceAction || widget is TvAction,
              ),
            ),
            findsNothing,
          );
        }

        await _activatePerson(tester, actor, environment);
        final actorLocation = router.state.uri.toString();
        expect(router.state.uri.path, '/person/person-ada');
        expect(router.state.uri.queryParameters['name'], '艾达');
        expect(router.state.extra, isNull);
        router.pop();
        await settle(tester);
        expect(router.state.uri.path, '/detail');
        await _revealDetailOrigin(tester);
        expect(find.text('原详情').hitTestable(), findsOneWidget);

        await tester.ensureVisible(unnamed);
        if (environment.isTv) {
          tester
              .widget<FocusableActionDetector>(
                find.descendant(
                  of: unnamed,
                  matching: find.byType(FocusableActionDetector),
                ),
              )
              .focusNode!
              .requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.select);
        } else {
          await tester.tap(unnamed);
        }
        await settle(tester);
        expect(router.state.uri.path, '/detail');
        expect(find.text('路人'), findsWidgets);

        await _activatePerson(tester, director, environment);
        expect(router.state.uri.toString(), actorLocation);
        expect(router.state.extra, isNull);
        router.pop();
        await settle(tester);
        await _revealDetailOrigin(tester);
        expect(find.text('原详情').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '${environment.presentation.name} person cards carry the detail source',
      (tester) async {
        final server = FakeEmbyServer();
        final auth = SyntheticSourceAuth(
          adapter: FakeEmbyAdapter([server]),
          device: _device,
          libraryIds: const {'view-movies'},
        );
        addTearDown(auth.dispose);
        final session = await tester.runAsync(() async {
          await auth.sources.load();
          final connected = await auth.connect(
            address: server.baseUrl.toString(),
            username: 'alice',
            password: 'correct-horse',
          );
          if (!connected) throw StateError('signed-in fixture failed');
          return auth.sources.authenticate(auth.session!.server.id);
        });
        final account = session!.account;
        final permit = auth.sources.permit(account, libraryId: 'view-movies');
        final origin = PlaybackOrigin(
          source: SourceReference(account: account, itemId: 'movie-inception'),
          work: SourceReference(account: account, itemId: 'movie-inception'),
          libraryId: 'view-movies',
          permit: permit,
          client: session.client,
        );
        final policy = MediaImageSourcePolicy(origin);
        addTearDown(policy.dispose);
        final router = await _pumpCastRoute(
          tester,
          environment: environment,
          origin: origin,
          policy: policy,
          cache: CatalogCache()..debugSetDiskStore(null),
        );
        addTearDown(router.dispose);

        Future<void> expectSource(Finder card) async {
          await _activatePerson(tester, card, environment);
          expect(router.state.uri.path, '/person/person-ada');
          expect(router.state.uri.queryParameters['name'], '艾达');
          final extra = router.state.extra;
          expect(extra, isA<PlayerHostOpenItemCommand>());
          final command = extra! as PlayerHostOpenItemCommand;
          expect(command.itemId, 'person-ada');
          expect(command.libraryId, 'view-movies');
          expect(
            command.source?.account.configuredServerId,
            account.configuredServerId,
          );
          router.pop();
          await settle(tester);
          expect(router.state.uri.path, '/detail');
          await _revealDetailOrigin(tester);
          expect(find.text('原详情').hitTestable(), findsOneWidget);
        }

        await expectSource(
          find.byKey(const ValueKey('episode-person-Actor-0')),
        );
        await expectSource(
          find.byKey(const ValueKey('episode-person-Director-0')),
        );
        final unnamed = find.byKey(const ValueKey('episode-person-Actor-1'));
        await tester.ensureVisible(unnamed);
        if (environment.isTv) {
          tester
              .widget<FocusableActionDetector>(
                find.descendant(
                  of: unnamed,
                  matching: find.byType(FocusableActionDetector),
                ),
              )
              .focusNode!
              .requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.select);
        } else {
          await tester.tap(unnamed);
        }
        await settle(tester);
        expect(router.state.uri.path, '/detail');
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('missing and failed portraits stay inside the poster', (
    tester,
  ) async {
    final server = FakeEmbyServer();
    server.items.add(
      FakeEmbyItem(
        id: 'person-face',
        name: '有图',
        type: 'Person',
        primaryImageTag: 'face',
      ),
    );
    final dio = dioForFakeEmby(FakeEmbyAdapter([server]));
    final auth = AuthController.memory(
      client: EmbyClient(device: _device, dio: dio),
    );
    addTearDown(auth.dispose);
    await tester.runAsync(
      () => auth.connect(
        address: server.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      ),
    );
    await _pumpPeople(
      tester,
      width: 800,
      height: 700,
      auth: auth,
      people: const [
        ItemPerson(
          id: 'person-face',
          name: '有图',
          type: 'Actor',
          primaryImageTag: 'face',
        ),
        ItemPerson(
          id: 'person-missing',
          name: '无图',
          type: 'Actor',
          primaryImageTag: 'gone',
        ),
      ],
    );
    final face = find.byKey(const ValueKey('episode-person-Actor-0'));
    final missing = find.byKey(const ValueKey('episode-person-Actor-1'));
    expect(
      find.descendant(of: face, matching: find.byType(RawImage)),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.descendant(
          of: face,
          matching: find.byKey(EpisodePeopleSection.imageKey),
        ),
        matching: find.text('有'),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.descendant(
          of: missing,
          matching: find.byKey(EpisodePeopleSection.imageKey),
        ),
        matching: find.text('无'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  for (final width in [360.0, 412.0]) {
    testWidgets('chapter rows settle on whole cards at ${width.toInt()}dp', (
      tester,
    ) async {
      final harness = await _startDetail(
        tester,
        width: width,
        prepare: (server) {
          final movie = server.items.firstWhere(
            (item) => item.id == 'movie-inception',
          );
          movie.chapters = [
            for (var i = 0; i < 5; i++)
              FakeChapter(
                name: i == 0
                    ? 'A chapter title that is much too long to fit beside the card'
                    : 'Chapter $i',
                startPosition: Duration(
                  microseconds: (i * 60 * 10000000) ~/ 10,
                ),
              ),
          ];
          movie.people = const [
            FakePerson(name: 'Only Actor', type: 'Actor', role: 'Lead'),
          ];
        },
      );
      unawaited(harness.router.push('/item/movie-inception'));
      await settle(tester);

      await tester.ensureVisible(find.byKey(const Key('phone-chapter-strip')));
      await settle(tester);
      expect(find.byKey(CatalogKeys.chapter(0)), findsOneWidget);
      expect(find.byKey(CatalogKeys.chapter(1)), findsOneWidget);
      final fallbackPlay = tester.widgetList<Icon>(
        find.descendant(
          of: find.byType(ChapterFallbackArt),
          matching: find.byIcon(AppIcons.play),
        ),
      );
      expect(fallbackPlay, isNotEmpty);
      for (final icon in fallbackPlay) {
        expect(icon.icon, AppIcons.play);
        expect(icon.fill, AppIcons.filled);
      }
      expect(find.byKey(CatalogKeys.chapter(2)), findsNothing);

      final first = tester.getRect(find.byKey(CatalogKeys.chapter(0)));
      final second = tester.getRect(find.byKey(CatalogKeys.chapter(1)));
      _expectOnScreen(first, width, 900);
      _expectOnScreen(second, width, 900);
      expect(first.left, closeTo(16, 1));
      expect(second.left, greaterThanOrEqualTo(first.right - 0.5));
      final title = tester.getRect(find.textContaining('much too long'));
      final clock = tester.getRect(find.text('00:00'));
      _expectInside(title, first);
      _expectInside(clock, first);
      expect(title.right, lessThanOrEqualTo(first.right + 0.5));

      final strip = find.byKey(const Key('phone-chapter-strip'));
      for (var i = 0; i < 4; i++) {
        if (find.byKey(CatalogKeys.chapter(4)).evaluate().isNotEmpty) {
          break;
        }
        await tester.fling(strip, Offset(-width, 0), 2000);
        await settle(tester);
      }
      final last = tester.getRect(find.byKey(CatalogKeys.chapter(4)));
      _expectOnScreen(last, width, 900);
      expect(last.right, closeTo(width - first.left, 1));
      _expectInside(tester.getRect(find.text('Chapter 4')), last);
      _expectInside(tester.getRect(find.text('04:00')), last);
      expect(find.byKey(CatalogKeys.chapter(3)), findsNothing);
      expect(tester.takeException(), isNull);
    }, tags: ['integration']);

    testWidgets(
      'season episode placeholders fit ${width.toInt()}dp without overflow',
      (tester) async {
        await _pumpSeasonPlaceholder(tester, width);
        expect(find.byKey(_episodePlaceholder), findsOneWidget);
        final blocks = tester
            .widgetList<SkeletonBlock>(find.byType(SkeletonBlock))
            .toList();
        expect(blocks, hasLength(3));
        for (final block in blocks) {
          expect(block.width, lessThanOrEqualTo(width - 32));
          expect(block.width! / block.height!, closeTo(16 / 9, 0.02));
        }
        final first = tester.getRect(find.byType(SkeletonBlock).first);
        _expectOnScreen(first, width, 800);
        expect(first.left, closeTo(16, 1));
        await tester.fling(
          find.byKey(_episodePlaceholder),
          Offset(-width, 0),
          1500,
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('opening a season detail does not overflow while episodes load', (
    tester,
  ) async {
    final gate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) {
        gate.complete();
      }
    });
    final harness = await _startDetail(
      tester,
      width: 360,
      reduceMotion: true,
      intercept: (dio) {
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) async {
              final uri = options.uri.toString();
              if (uri.contains('IncludeItemTypes=Episode') &&
                  !gate.isCompleted) {
                await gate.future;
              }
              handler.next(options);
            },
          ),
        );
      },
      prepare: (server) {
        server.setSeasons('series-friends', const [
          FakeSeason(id: 'season-friends-1', name: '第 1 季', indexNumber: 1),
        ]);
        server.setEpisodes('series-friends', const [
          FakeEpisode(
            id: 'episode-friends-s1e1',
            name: 'The Pilot',
            seasonId: 'season-friends-1',
            indexNumber: 1,
            parentIndexNumber: 1,
          ),
        ]);
      },
    );
    unawaited(harness.router.push('/item/series-friends'));
    var found = false;
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (find.byKey(_episodePlaceholder).evaluate().isNotEmpty) {
        found = true;
        break;
      }
    }
    expect(found, isTrue);
    final placeholder = tester.getRect(find.byKey(_episodePlaceholder));
    expect(placeholder.left, greaterThanOrEqualTo(-0.5));
    expect(placeholder.right, lessThanOrEqualTo(360.5));
    final card = tester.getRect(
      find
          .descendant(
            of: find.byKey(_episodePlaceholder),
            matching: find.byType(SkeletonBlock),
          )
          .first,
    );
    _expectOnScreen(card, 360, 900);
    expect(tester.takeException(), isNull);
    gate.complete();
    await settle(tester);
    expect(find.text('The Pilot'), findsWidgets);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  testWidgets(
    'shelf poster handoff keeps the tapped image on the first detail frame',
    (tester) async {
      final gate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) {
          gate.complete();
        }
      });
      final harness = await _startDetail(
        tester,
        width: 360,
        reduceMotion: true,
        intercept: (dio) => _holdItemDetail(dio, gate),
      );
      unawaited(harness.router.push(AppRoutes.shelfLatestMovies));
      await settle(tester);

      final poster = find.byKey(PhoneShelfPage.imageKey('movie-inception'));
      await tester.ensureVisible(poster);
      await settle(tester);
      final posterImage = tester.widget<MediaImage>(
        find.descendant(of: poster, matching: find.byType(MediaImage)),
      );
      expect(posterImage.preferBackdrop, isFalse);
      expect(
        find.descendant(
          of: poster,
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Hero &&
                widget.tag ==
                    PhoneMotion.imageTag(
                      'movie-inception',
                      preferBackdrop: false,
                    ),
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: poster, matching: find.byType(Image)),
        findsWidgets,
      );
      await _waitForDecoded(tester, poster);

      await tester.tap(poster);
      await tester.pump();
      expect(find.byKey(_pendingHeader), findsOneWidget);
      _expectHandoffFrame(tester);
      final headerImages = tester.widgetList<MediaImage>(
        find.descendant(
          of: find.byKey(_pendingHeader),
          matching: find.byKey(PhoneItemBanner.handoffImageKey),
          skipOffstage: false,
        ),
      );
      expect(headerImages, isNotEmpty);
      final headerImage = headerImages.single;
      expect(headerImage.item.id, posterImage.item.id);
      expect(headerImage.preferBackdrop, posterImage.preferBackdrop);
      expect(headerImage.maxWidth, posterImage.maxWidth);
      expect(
        headerImage.item.primaryImageTag,
        posterImage.item.primaryImageTag,
      );
      final extra = GoRouterState.of(
        tester.element(find.byType(MobileDetailPage)),
      ).extra;
      expect(extra, isA<PhoneImageHandoff>());
      final handoff = extra! as PhoneImageHandoff;
      expect(handoff.item.id, 'movie-inception');
      expect(handoff.preferBackdrop, isFalse);
      expect(handoff.maxWidth, posterImage.maxWidth);
      expect(tester.takeException(), isNull);

      gate.complete();
      await settle(tester);
      expect(find.textContaining('dream-sharing'), findsOneWidget);
      final settled = tester.widget<MediaImage>(
        find.descendant(
          of: find.byKey(PhoneItemBanner.bannerKey),
          matching: find.byKey(PhoneItemBanner.handoffImageKey),
        ),
      );
      expect(settled.preferBackdrop, posterImage.preferBackdrop);
      expect(settled.maxWidth, posterImage.maxWidth);
      expect(settled.item.primaryImageTag, posterImage.item.primaryImageTag);
      expect(settled.preferBackdrop, isFalse);
      _expectHandoffFrame(tester);
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  testWidgets('shelf poster without an image still opens by a direct push', (
    tester,
  ) async {
    final gate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) {
        gate.complete();
      }
    });
    final harness = await _startDetail(
      tester,
      width: 360,
      reduceMotion: true,
      intercept: (dio) => _holdItemDetail(dio, gate),
    );
    unawaited(harness.router.push(AppRoutes.shelfLatestMovies));
    await settle(tester);

    final poster = find.byKey(PhoneShelfPage.imageKey('movie-transcode'));
    await tester.scrollUntilVisible(
      poster,
      300,
      scrollable: find.byType(Scrollable).last,
    );
    await settle(tester);
    expect(
      find.descendant(of: poster, matching: find.byType(Hero)),
      findsNothing,
    );

    await tester.tap(poster);
    await tester.pump();
    await tester.pump();
    expect(
      find.descendant(
        of: find.byKey(_pendingHeader),
        matching: find.byType(MediaImage),
      ),
      findsNothing,
    );
    expect(find.byKey(_pendingTitle), findsOneWidget);
    expect(find.byKey(_pendingAction), findsOneWidget);
    expect(find.byKey(_pendingBody), findsOneWidget);
    final extra = GoRouterState.of(
      tester.element(find.byType(MobileDetailPage)),
    ).extra;
    expect(extra, isNot(isA<PhoneImageHandoff>()));
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Hero &&
            widget.tag ==
                PhoneMotion.imageTag('movie-transcode', preferBackdrop: false),
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
    gate.complete();
    await settle(tester);
    expect(find.text('需转码片'), findsWidgets);
  }, tags: ['integration']);

  testWidgets(
    'library poster handoff keeps the image and placeholders below it',
    (tester) async {
      final gate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) {
          gate.complete();
        }
      });
      await _startLibrary(tester, width: 360, holdDetail: gate);
      await settle(tester);
      final poster = find.byKey(
        const ValueKey('phone-library-poster-movie-inception'),
      );
      await tester.ensureVisible(poster);
      await settle(tester);
      final posterImage = tester.widget<MediaImage>(
        find.descendant(of: poster, matching: find.byType(MediaImage)),
      );
      expect(
        find.descendant(of: poster, matching: find.byType(Image)),
        findsWidgets,
      );
      await _waitForDecoded(tester, poster);

      await tester.tap(poster);
      for (var i = 0; i < 4; i++) {
        await tester.pump();
        if (find.byKey(_pendingHeader).evaluate().isNotEmpty) break;
      }
      expect(find.byKey(_pendingHeader), findsOneWidget);
      _expectHandoffFrame(tester);
      final headerImages = tester.widgetList<MediaImage>(
        find.descendant(
          of: find.byKey(_pendingHeader),
          matching: find.byKey(PhoneItemBanner.handoffImageKey),
          skipOffstage: false,
        ),
      );
      final headerImage = headerImages.isEmpty
          ? tester
                .widgetList<MediaImage>(
                  find.byType(MediaImage, skipOffstage: false),
                )
                .firstWhere((image) => image.item.id == posterImage.item.id)
          : headerImages.single;
      expect(headerImage.item.id, posterImage.item.id);
      expect(headerImage.preferBackdrop, posterImage.preferBackdrop);
      expect(headerImage.maxWidth, posterImage.maxWidth);
      expect(
        headerImage.item.primaryImageTag,
        posterImage.item.primaryImageTag,
      );
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Hero &&
              widget.tag ==
                  PhoneMotion.imageTag(
                    'movie-inception',
                    preferBackdrop: false,
                  ),
        ),
        findsWidgets,
      );

      await tester.pump(PhoneMotion.pageTransition);
      final header = tester.getRect(find.byKey(_pendingHeader));
      final title = tester.getRect(find.byKey(_pendingTitle));
      final action = tester.getRect(find.byKey(_pendingAction));
      final playDuringLoad = tester.getRect(
        find.byKey(const Key('mobile-detail-play')),
      );
      final body = tester.getRect(find.byKey(_pendingBody));
      expect(tester.widget<Text>(find.byKey(_pendingTitle)).data, 'Inception');
      // 有交接图时标题与主操作就画在同一个头部里，载入前后版式不跳。
      expect(title.top, greaterThanOrEqualTo(header.top));
      expect(action.top, greaterThanOrEqualTo(title.bottom - 1));
      expect(action.bottom, lessThanOrEqualTo(header.bottom + 1));
      expect(action.width, greaterThanOrEqualTo(48));
      expect(action.height, greaterThanOrEqualTo(48));
      expect(body.top, greaterThanOrEqualTo(action.bottom - 1));
      expect(body.height, greaterThan(40));
      expect(find.textContaining('dream-sharing'), findsNothing);
      expect(tester.takeException(), isNull);

      gate.complete();
      await settle(tester);
      expect(find.byKey(_pendingBody), findsNothing);
      expect(find.textContaining('dream-sharing'), findsOneWidget);
      final play = find.byKey(const Key('mobile-detail-play'));
      expect(tester.widget<AppButton>(play).onPressed, isNotNull);
      expect(tester.getTopLeft(play).dy, closeTo(playDuringLoad.top, 1));
      expect(find.text('剩余 89 分钟'), findsOneWidget);
      expect(tester.getTopLeft(find.byKey(PhoneItemBanner.bannerKey)).dy, 0);
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  testWidgets('movie and series banners cover the status bar', (tester) async {
    final harness = await _startDetail(tester, width: 390, reduceMotion: true);
    tester.view.viewPadding = const FakeViewPadding(top: 47, bottom: 34);
    tester.view.padding = const FakeViewPadding(top: 47, bottom: 34);
    addTearDown(tester.view.resetViewPadding);
    addTearDown(tester.view.resetPadding);

    Future<void> expectCovered(String id) async {
      unawaited(harness.router.push('/item/$id'));
      await settle(tester);
      final banner = tester.getRect(find.byKey(PhoneItemBanner.bannerKey));
      final image = tester.getRect(find.byKey(PhoneItemBanner.handoffImageKey));
      final bar = find.byType(PhoneTopBar);
      final backButton = find.byKey(PhoneTopBar.backKey);
      expect(bar, findsOneWidget, reason: id);
      expect(
        find.descendant(of: bar, matching: backButton),
        findsOneWidget,
        reason: id,
      );
      expect(find.byType(CupertinoNavigationBarBackButton), findsNothing);
      final back = tester.getRect(backButton);
      expect(banner.top, 0, reason: id);
      expect(image.top, 0, reason: id);
      expect(back.top, greaterThanOrEqualTo(47), reason: id);
      expect(back.bottom, lessThan(image.bottom), reason: id);
      final poster = tester.getRect(find.byKey(PhoneItemBanner.posterKey));
      final posterImage = tester.getRect(
        find.descendant(
          of: find.byKey(PhoneItemBanner.posterKey),
          matching: find.byType(MediaImage),
        ),
      );
      expect(poster.height / poster.width, closeTo(1.5, 0.02), reason: id);
      expect(poster.top, greaterThanOrEqualTo(0), reason: id);
      expect(poster.bottom, lessThanOrEqualTo(900), reason: id);
      expect(posterImage.width, closeTo(poster.width, 1), reason: id);
      expect(posterImage.height, closeTo(poster.height, 1), reason: id);
      expect(
        tester.widget<ColoredBox>(find.byKey(PhoneTopBar.backgroundKey)).color,
        const Color(0x00000000),
        reason: id,
      );
      await tester.tap(backButton);
      await settle(tester);
      expect(find.byType(MobileDetailPage), findsNothing, reason: id);
    }

    await expectCovered('movie-inception');
    await expectCovered('series-friends');
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  testWidgets('scrolled detail bar uses the phone top bar colors', (
    tester,
  ) async {
    for (final theme in [AppUiTheme.phoneLight(), AppUiTheme.phoneDark()]) {
      final harness = await _startDetail(
        tester,
        width: 390,
        reduceMotion: true,
        theme: theme,
      );
      unawaited(harness.router.push('/item/movie-inception'));
      await settle(tester);
      expect(
        tester.widget<ColoredBox>(find.byKey(PhoneTopBar.backgroundKey)).color,
        const Color(0x00000000),
      );
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -180));
      await tester.pump();
      expect(
        find.descendant(
          of: find.byType(PhoneTopBar),
          matching: find.text('Inception'),
        ),
        findsOneWidget,
      );
      final phone = phoneChromeTheme(tester.element(find.byType(PhoneTopBar)));
      expect(phone.phone, isTrue);
      expect(phone.brightness, theme.brightness);
      expect(
        tester.widget<ColoredBox>(find.byKey(PhoneTopBar.backgroundKey)).color,
        phone.scaffoldBackgroundColor,
      );
      final iconFinder = find.descendant(
        of: find.byKey(PhoneTopBar.backKey),
        matching: find.byIcon(AppIcons.back),
      );
      final icon = tester.widget<Icon>(iconFinder);
      expect(
        icon.color ?? IconTheme.of(tester.element(iconFinder)).color,
        phone.colorScheme.onSurface,
      );
      expect(tester.takeException(), isNull);
    }
  }, tags: ['integration']);

  testWidgets(
    'one season hides the selector and a watched episode is marked once',
    (tester) async {
      final harness = await _startDetail(
        tester,
        width: 390,
        reduceMotion: true,
        theme: AppUiTheme.phoneDark(),
      );
      unawaited(harness.router.push('/item/series-friends'));
      await settle(tester);
      expect(find.byType(PhoneTopBar), findsOneWidget);
      expect(find.byKey(const Key('phone-season-list')), findsNothing);
      expect(find.byType(PhoneSeasonTab), findsNothing);
      final poster = tester.getRect(find.byKey(PhoneItemBanner.posterKey));
      expect(poster.height / poster.width, closeTo(1.5, 0.02));
      expect(
        poster.bottom,
        lessThanOrEqualTo(poster.top + poster.width * 1.5 + 1),
      );
      await tester.ensureVisible(
        find.byKey(const Key('phone-episode-watched')),
      );
      await settle(tester);
      expect(find.byKey(const Key('phone-episode-watched')), findsOneWidget);
      expect(find.text('已看'), findsNothing);
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  testWidgets('two seasons can switch to the second season', (tester) async {
    final harness = await _startDetail(
      tester,
      width: 390,
      reduceMotion: true,
      theme: AppUiTheme.phoneLight(),
      prepare: (server) {
        server.setSeasons('series-friends', const [
          FakeSeason(id: 'season-friends-1', name: '第 1 季', indexNumber: 1),
          FakeSeason(id: 'season-friends-2', name: '第 2 季', indexNumber: 2),
        ]);
        server.setEpisodes('series-friends', const [
          FakeEpisode(
            id: 'episode-s1',
            name: '第一季试点',
            seasonId: 'season-friends-1',
            indexNumber: 1,
            parentIndexNumber: 1,
            played: true,
          ),
          FakeEpisode(
            id: 'episode-s2',
            name: '第二季试点',
            seasonId: 'season-friends-2',
            indexNumber: 1,
            parentIndexNumber: 2,
          ),
        ]);
      },
    );
    unawaited(harness.router.push('/item/series-friends'));
    await settle(tester);
    expect(find.byKey(const Key('phone-season-list')), findsOneWidget);
    final second = find.byKey(CatalogKeys.season('season-friends-2'));
    await tester.ensureVisible(second);
    await tester.tap(second);
    await settle(tester);
    expect(
      tester
          .widget<PhoneSeasonTab>(find.widgetWithText(PhoneSeasonTab, '第 2 季'))
          .selected,
      isTrue,
    );
    expect(find.text('第二季试点'), findsOneWidget);
    expect(find.text('第一季试点'), findsNothing);
    expect(find.byKey(const Key('phone-episode-watched')), findsNothing);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  testWidgets('reduced motion opens detail in place with placeholders', (
    tester,
  ) async {
    final gate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) {
        gate.complete();
      }
    });
    await _startLibrary(
      tester,
      width: 360,
      reduceMotion: true,
      holdDetail: gate,
    );
    await settle(tester);
    final poster = find.byKey(
      const ValueKey('phone-library-poster-movie-inception'),
    );
    await tester.ensureVisible(poster);
    await settle(tester);
    await tester.tap(poster);
    await tester.pump();
    await tester.pump();
    final route = ModalRoute.of(tester.element(find.byType(MobileDetailPage)));
    expect(route!.transitionDuration, Duration.zero);
    expect(find.byType(SlideTransition), findsNothing);
    final before = tester.getTopLeft(find.byKey(_pendingHeader));
    expect(before.dy, lessThan(40));
    await tester.pump(const Duration(milliseconds: 250));
    expect(route.animation!.value, 1);
    expect(tester.getTopLeft(find.byKey(_pendingHeader)), before);
    final pendingHeader = tester.getRect(find.byKey(_pendingHeader));
    final pendingTitle = tester.getRect(find.byKey(_pendingTitle));
    expect(pendingTitle.top, greaterThanOrEqualTo(pendingHeader.top));
    expect(pendingTitle.bottom, lessThanOrEqualTo(pendingHeader.bottom + 1));
    expect(find.byKey(_pendingAction), findsOneWidget);
    expect(find.byKey(_pendingBody), findsOneWidget);
    expect(tester.takeException(), isNull);
    gate.complete();
    await settle(tester);
    expect(find.textContaining('dream-sharing'), findsOneWidget);
  }, tags: ['integration']);

  testWidgets(
    'a detail opened without an image still placeholders, then can fail and retry',
    (tester) async {
      final gate = Completer<void>();
      var failDetail = true;
      addTearDown(() {
        if (!gate.isCompleted) {
          gate.complete();
        }
      });
      final harness = await _startDetail(
        tester,
        width: 360,
        reduceMotion: true,
        intercept: (dio) {
          dio.interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) async {
                final path = options.uri.path;
                final detail =
                    options.method == 'GET' &&
                    RegExp(r'/Items/[^/]+$').hasMatch(path);
                if (!detail) {
                  handler.next(options);
                  return;
                }
                if (!gate.isCompleted) {
                  await gate.future;
                }
                if (failDetail) {
                  handler.reject(
                    DioException(
                      requestOptions: options,
                      type: DioExceptionType.badResponse,
                      response: Response(
                        requestOptions: options,
                        statusCode: 500,
                      ),
                    ),
                  );
                  return;
                }
                handler.next(options);
              },
            ),
          );
        },
      );
      unawaited(harness.router.push('/item/movie-transcode'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        find.descendant(
          of: find.byKey(_pendingHeader),
          matching: find.byType(MediaImage),
        ),
        findsNothing,
      );
      final header = tester.getRect(find.byKey(_pendingHeader));
      final title = tester.getRect(find.byKey(_pendingTitle));
      final body = tester.getRect(find.byKey(_pendingBody));
      expect(header.height, greaterThan(40));
      expect(title.top, greaterThanOrEqualTo(header.bottom - 1));
      expect(find.byKey(_pendingAction), findsOneWidget);
      expect(body.top, greaterThan(title.bottom));
      expect(tester.takeException(), isNull);

      gate.complete();
      await settle(tester);
      expect(find.text('重试'), findsOneWidget);
      expect(find.byKey(_pendingBody), findsNothing);
      expect(find.text('需转码片'), findsNothing);

      failDetail = false;
      await tester.tap(find.text('重试'));
      await settle(tester);
      expect(find.text('需转码片'), findsWidgets);
      expect(find.text('重试'), findsNothing);
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  testWidgets(
    'many subtitle tracks share equal columns on phone and desktop widths',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final source = ItemMediaSource(
        id: 'source',
        streams: [
          const ItemMediaStream(index: 0, type: 'Video', label: '4K'),
          for (var index = 1; index <= 8; index++)
            ItemMediaStream(
              index: index,
              type: 'Subtitle',
              label: index == 1
                  ? 'Chinese Simplified (默认 SUBRIP)'
                  : index == 4 || index == 7
                  ? 'Spanish (SUBRIP)'
                  : 'Arabic (SUBRIP) $index',
            ),
        ],
      );

      Future<void> pump(Size size) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        await tester.pumpWidget(
          CupertinoTestApp(
            locale: const Locale('zh'),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: [
              AppLocalizations.delegate,
              ...GlobalCupertinoLocalizations.delegates,
            ],
            theme: AppUiTheme.dark(),
            home: CupertinoPageScaffold(
              child: EpisodeMediaStreamsSection(source: source),
            ),
          ),
        );
      }

      Size chip(int index) =>
          tester.getSize(find.byKey(ValueKey('media-stream-$index')));

      await pump(const Size(360, 900));
      expect(find.text('Spanish (SUBRIP) #4'), findsOneWidget);
      expect(find.text('Spanish (SUBRIP) #7'), findsOneWidget);
      expect(find.text('Chinese Simplified (默认 SUBRIP)'), findsOneWidget);
      expect(chip(1).width, chip(2).width);
      expect(chip(1).width, chip(4).width);
      expect(chip(0).width, lessThan(chip(1).width));
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('media-stream-1'))).dy,
        tester.getTopLeft(find.byKey(const ValueKey('media-stream-2'))).dy,
      );
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('media-stream-3'))).dy,
        greaterThan(
          tester.getTopLeft(find.byKey(const ValueKey('media-stream-1'))).dy,
        ),
      );
      expect(tester.takeException(), isNull);

      // 桌面最窄窗口：分类名在左列，字幕仍是四等列。
      await pump(const Size(1024, 800));
      expect(chip(1).width, chip(5).width);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('media-stream-1'))).dy,
        tester.getTopLeft(find.byKey(const ValueKey('media-stream-4'))).dy,
      );
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('media-stream-5'))).dy,
        greaterThan(
          tester.getTopLeft(find.byKey(const ValueKey('media-stream-1'))).dy,
        ),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'vertical detail scroll keeps season, cast, and similar rows at the left',
    (tester) async {
      _useSurface(tester, 400, 700);
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        CupertinoTestApp(
          locale: const Locale('zh'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: [
            AppLocalizations.delegate,
            ...GlobalCupertinoLocalizations.delegates,
          ],
          theme: AppUiTheme.dark(),
          home: CupertinoPageScaffold(
            child: Builder(
              builder: (context) {
                final page = MobileSeriesPage(
                  item: MediaItem(
                    id: 'series',
                    name: '剧',
                    type: 'Series',
                    people: [
                      for (var index = 0; index < 8; index++)
                        ItemPerson(
                          name: '演员$index',
                          type: 'Actor',
                          role: '角色$index',
                        ),
                    ],
                  ),
                  seasons: [
                    for (var index = 1; index <= 12; index++)
                      MediaItem(
                        id: 'season-$index',
                        name: '第$index季',
                        type: 'Season',
                      ),
                  ],
                  seasonId: 'season-1',
                  episodes: [
                    for (var index = 0; index < 30; index++)
                      MediaItem(
                        id: 'episode-$index',
                        name: '第 $index 集',
                        type: 'Episode',
                      ),
                  ],
                  episodesLoading: false,
                  episodeError: null,
                  hasMore: false,
                  playTargetId: null,
                  similar: [
                    for (var index = 0; index < 8; index++)
                      MediaItem(
                        id: 'similar-$index',
                        name: '类似$index',
                        type: 'Series',
                      ),
                  ],
                  onSelectSeason: _ignore,
                  onOpenEpisode: _ignore,
                  onRetryEpisodes: _noop,
                  onLoadMore: _noop,
                  onOpenItem: _ignore,
                  onOpenSimilar: _noop,
                );
                return CustomScrollView(
                  key: const PageStorageKey('detail-series'),
                  controller: scroll,
                  scrollCacheExtent: const ScrollCacheExtent.viewport(0.5),
                  slivers: [
                    ...page.buildSlivers(context),
                    const SliverToBoxAdapter(child: SizedBox(height: 2400)),
                  ],
                );
              },
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('第1季'), findsOneWidget);
      await tester.fling(
        find.byType(CustomScrollView),
        const Offset(0, -400),
        8000,
      );
      await settle(tester);
      expect(find.text('第1季'), findsNothing);

      await tester.fling(
        find.byType(CustomScrollView),
        const Offset(0, 400),
        8000,
      );
      await settle(tester);
      expect(find.text('第1季'), findsOneWidget);
      final season = tester.getTopLeft(find.text('第1季'));
      expect(season.dx, inInclusiveRange(0, 80));

      final max = scroll.position.maxScrollExtent;
      scroll.jumpTo(max);
      await tester.pump();
      final similar = find.byKey(CatalogKeys.item('similar-0'));
      final person = find.byKey(const ValueKey('episode-person-Actor-0'));
      expect(similar, findsNothing);

      var guard = 0;
      while (similar.evaluate().isEmpty && scroll.offset > 0 && guard < 40) {
        scroll.jumpTo((scroll.offset - 280).clamp(0, max));
        await tester.pump();
        guard++;
      }
      expect(similar, findsOneWidget);
      expect(
        tester.getTopLeft(similar).dx,
        inInclusiveRange(0, 80),
        reason: '更多类似 stayed on the left',
      );

      guard = 0;
      while (person.evaluate().isEmpty && scroll.offset > 0 && guard < 40) {
        scroll.jumpTo((scroll.offset - 280).clamp(0, max));
        await tester.pump();
        guard++;
      }
      expect(person, findsOneWidget);
      expect(
        tester.getTopLeft(person).dx,
        inInclusiveRange(0, 80),
        reason: '演员 stayed on the left',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('episode picker does not tint the loaded episode page', (
    tester,
  ) async {
    final harness = await _startDetail(
      tester,
      width: 360,
      reduceMotion: true,
      prepare: (server) {
        server.setSeasons('series-friends', const [
          FakeSeason(id: 'season-friends-1', name: '第 1 季', indexNumber: 1),
        ]);
        server.setEpisodes('series-friends', [
          for (var index = 1; index <= 60; index++)
            FakeEpisode(
              id: 'episode-$index',
              name: '第 $index 集',
              seasonId: 'season-friends-1',
              indexNumber: index,
              parentIndexNumber: 1,
              playbackPosition: Duration(
                microseconds: (index == 29 ? 6000000000 : 0) ~/ 10,
              ),
              runtime: Duration(microseconds: (36000000000) ~/ 10),
            ),
        ]);
      },
    );
    unawaited(harness.router.push('/item/series-friends'));
    await settle(tester);
    final picker = find.byKey(CatalogKeys.locateEpisode);
    expect(
      tester
          .widget<Icon>(
            find.descendant(
              of: picker,
              matching: find.byIcon(AppIcons.episodes),
            ),
          )
          .icon,
      AppIcons.episodes,
    );
    await Scrollable.ensureVisible(tester.element(picker), alignment: 0.5);
    await settle(tester);
    await tester.tap(picker);
    await settle(tester);

    final grid = find.byType(GridView);
    expect(grid, findsOneWidget);
    expect(tester.getSize(grid).height, lessThan(500));
    expect(tester.getTopLeft(grid).dy, greaterThan(300));
    expect(find.widgetWithText(AppButton, '29'), findsOneWidget);
    final tinted = tester
        .widgetList<AppButton>(
          find.descendant(of: grid, matching: find.byType(AppButton)),
        )
        .where((button) => button.style?.backgroundColor != null);
    expect(tinted, isEmpty);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  testWidgets(
    'phone detail surfaces EpisodeMediaStreamsSection directly below overview and genres before chapters and cast',
    (tester) async {
      final harness = await _startDetail(
        tester,
        width: 412,
        reduceMotion: true,
        prepare: (server) {
          final movie = server.items.firstWhere(
            (item) => item.id == 'movie-inception',
          );
          movie.genres = const ['科幻', '动作'];
          movie.people = const [
            FakePerson(name: 'Cobb Actor', type: 'Actor', role: 'Cobb'),
          ];
        },
      );
      unawaited(harness.router.push('/item/movie-inception'));
      await settle(tester);

      final overview = find.byType(EpisodeOverviewSection);
      final genres = find.byKey(PhoneGenreChips.rowKey);
      final streams = find.byKey(EpisodeMediaStreamsSection.sectionKey);
      final chapters = find.byKey(const Key('phone-chapter-strip'));
      final cast = find.byKey(EpisodePeopleSection.sectionKey);

      expect(overview, findsOneWidget);
      expect(genres, findsOneWidget);
      expect(streams, findsOneWidget);
      expect(chapters, findsOneWidget);
      expect(cast, findsOneWidget);

      final genresBottom = tester.getRect(genres).bottom;
      final streamsRect = tester.getRect(streams);
      final chaptersTop = tester.getRect(chapters).top;
      final castTop = tester.getRect(cast).top;

      expect(streamsRect.top, greaterThanOrEqualTo(genresBottom));
      expect(streamsRect.bottom, lessThanOrEqualTo(chaptersTop));
      expect(chaptersTop, lessThanOrEqualTo(castTop));
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  testWidgets('phone detail play button uses the phone accent', (tester) async {
    final harness = await _startDetail(
      tester,
      width: 360,
      reduceMotion: true,
      theme: AppUiTheme.phoneLight(),
    );
    unawaited(harness.router.push('/item/movie-inception'));
    await settle(tester);
    final play = find.byKey(const Key('mobile-detail-play'));
    expect(play, findsOneWidget);
    final box = tester.widget<AnimatedContainer>(
      find.descendant(of: play, matching: find.byType(AnimatedContainer)).first,
    );
    final color = (box.decoration! as ShapeDecoration).color;
    final phone = AppUiTheme.phoneLight().colorScheme;
    expect(color, phone.primary);
    expect(color, isNot(phone.inverseSurface));
    expect(
      tester
          .widget<Icon>(
            find.descendant(of: play, matching: find.byIcon(AppIcons.play)),
          )
          .icon,
      AppIcons.play,
    );
    final favorite = find.byKey(const Key('phone-detail-favorite'));
    expect(favorite, findsOneWidget);
    final favoriteIcon = tester.widget<Icon>(
      find.descendant(of: favorite, matching: find.byType(Icon)),
    );
    expect(favoriteIcon.icon, AppIcons.favorite);
    expect(favoriteIcon.fill, AppIcons.outline);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  testWidgets(
    'release filenames show resolution and codec on the phone source row',
    (tester) async {
      const release = ItemMediaSource(
        id: 'src-release',
        name: 'NF.WD.264.AAC-SonyHD',
        height: 1080,
        streams: [
          ItemMediaStream(index: 0, type: 'Video', codec: 'h264', height: 1080),
        ],
      );
      const edition = ItemMediaSource(
        id: 'src-edition',
        name: '导演剪辑版',
        height: 2160,
        streams: [
          ItemMediaStream(index: 0, type: 'Video', codec: 'hevc', height: 2160),
        ],
      );
      const twin = ItemMediaSource(
        id: 'src-twin',
        name: 'Other.WD.264.AAC-Group',
        height: 1080,
        streams: [
          ItemMediaStream(index: 0, type: 'Video', codec: 'h264', height: 1080),
        ],
      );
      await tester.pumpWidget(
        PresentationScope(
          environment: PresentationEnvironment.phone,
          child: CupertinoTestApp(
            locale: const Locale('zh'),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: [
              AppLocalizations.delegate,
              ...GlobalCupertinoLocalizations.delegates,
            ],
            theme: AppUiTheme.phoneLight(),
            home: CupertinoPageScaffold(
              child: EpisodeMediaStreamsSection(
                source: release,
                sources: const [release, edition, twin],
                selectedSourceId: 'src-release',
                onSelectSource: _ignore,
              ),
            ),
          ),
        ),
      );
      final row = find.byKey(EpisodeMediaStreamsSection.phoneVersionRowKey);
      expect(row, findsOneWidget);
      expect(
        find.descendant(of: row, matching: find.text('1080p · H.264 · 1')),
        findsOneWidget,
      );
      expect(find.text('NF.WD.264.AAC-SonyHD'), findsNothing);
      expect(find.byIcon(AppIcons.video), findsOneWidget);
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(find.text('导演剪辑版'), findsOneWidget);
      expect(find.text('1080p · H.264 · 3'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('changing season keeps the old hero until the new frame', (
    tester,
  ) async {
    final gate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    final harness = await _startDetail(
      tester,
      width: 360,
      reduceMotion: true,
      prepare: (server) {
        server.setSeasons('series-friends', const [
          FakeSeason(
            id: 'season-friends-1',
            name: '第 1 季',
            indexNumber: 1,
            primaryImageTag: 'tag-s1',
          ),
          FakeSeason(
            id: 'season-friends-2',
            name: '第 2 季',
            indexNumber: 2,
            primaryImageTag: 'tag-s2',
          ),
        ]);
      },
      intercept: (dio) {
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) async {
              if (options.uri.toString().contains(
                    '/Items/season-friends-2/Images/',
                  ) &&
                  !gate.isCompleted) {
                await gate.future;
              }
              handler.next(options);
            },
          ),
        );
      },
    );
    const series = MediaItem(
      id: 'series-friends',
      name: '老友记',
      type: 'Series',
      primaryImageTag: 'tag-friends',
    );
    unawaited(
      harness.router.push(
        AppRoutes.item(series.id),
        extra: const PhoneImageHandoff(
          item: series,
          preferBackdrop: false,
          maxWidth: 400,
        ),
      ),
    );
    await settle(tester);
    final backdrop = find.byKey(PhoneItemBanner.backdropKey);
    expect(backdrop, findsOneWidget);
    await _waitForDecoded(tester, backdrop);
    await tester.ensureVisible(
      find.byKey(CatalogKeys.season('season-friends-2')),
    );
    await tester.tap(find.byKey(CatalogKeys.season('season-friends-2')));
    await tester.pump();
    expect(
      find.descendant(of: backdrop, matching: find.byType(SkeletonBlock)),
      findsNothing,
    );
    expect(
      find.descendant(of: backdrop, matching: find.byType(PosterPlaceholder)),
      findsNothing,
    );
    expect(
      find.descendant(of: backdrop, matching: find.byType(Image)),
      findsWidgets,
    );
    expect(
      tester
          .widgetList<RawImage>(
            find.descendant(of: backdrop, matching: find.byType(RawImage)),
          )
          .any((raw) => raw.image != null),
      isTrue,
    );
    expect(tester.widget<MediaImage>(backdrop).item.id, 'season-friends-2');
    gate.complete();
    await settle(tester);
    expect(tester.widget<MediaImage>(backdrop).item.id, 'season-friends-2');
    expect(
      find.descendant(of: backdrop, matching: find.byType(Image)),
      findsWidgets,
    );
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);
}

void _expectOnScreen(Rect rect, double width, double height) {
  expect(rect.left, greaterThanOrEqualTo(-0.5), reason: '$rect');
  expect(rect.top, greaterThanOrEqualTo(-0.5), reason: '$rect');
  expect(rect.right, lessThanOrEqualTo(width + 0.5), reason: '$rect');
  expect(rect.bottom, lessThanOrEqualTo(height + 0.5), reason: '$rect');
  expect(rect.width, greaterThan(1));
  expect(rect.height, greaterThan(1));
}

void _expectInside(Rect inner, Rect outer) {
  expect(inner.left, greaterThanOrEqualTo(outer.left - 0.5));
  expect(inner.top, greaterThanOrEqualTo(outer.top - 0.5));
  expect(inner.right, lessThanOrEqualTo(outer.right + 0.5));
  expect(inner.bottom, lessThanOrEqualTo(outer.bottom + 0.5));
}

const _samplePeople = [
  ItemPerson(
    name: 'Alexandria Montgomery-Washington the Third',
    type: 'Actor',
    role: 'Lead',
  ),
  ItemPerson(name: 'Bea', type: 'Actor', role: 'Friend'),
  ItemPerson(name: 'Cid', type: 'Actor', role: 'Rival'),
  ItemPerson(name: 'Dee', type: 'Actor', role: 'Neighbor'),
  ItemPerson(name: 'Eve', type: 'Actor', role: 'Guest'),
  ItemPerson(name: 'Director One', type: 'Director'),
  ItemPerson(name: 'Writer One', type: 'Writer'),
  ItemPerson(
    name: 'Other Person With A Very Long Name That Must Ellipsize',
    type: 'Producer',
    role: 'A role name that is also far too long for one card',
  ),
  ItemPerson(name: '   ', type: 'Guest'),
];

const _routePeople = [
  ItemPerson(id: 'person-ada', name: '艾达', type: 'Actor', role: '主角'),
  ItemPerson(name: '路人', type: 'Actor', role: '客串'),
  ItemPerson(id: 'person-ada', name: '艾达', type: 'Director'),
  ItemPerson(id: 'person-bob', name: '鲍勃', type: 'Writer', role: '剧本'),
];

Future<void> _pumpPeople(
  WidgetTester tester, {
  required double width,
  required double height,
  PresentationEnvironment? environment,
  List<ItemPerson>? people,
  AuthController? auth,
}) async {
  _useSurface(tester, width, height);
  final section = EpisodePeopleSection(people: people ?? _samplePeople);
  Widget home = CupertinoPageScaffold(child: section);
  if (environment != null) {
    home = PresentationScope(environment: environment, child: home);
  }
  if (auth != null) {
    home = AuthScope(controller: auth, child: home);
  }
  await tester.pumpWidget(
    CupertinoTestApp(
      locale: const Locale('zh'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: [
        AppLocalizations.delegate,
        ...GlobalCupertinoLocalizations.delegates,
      ],
      theme: AppUiTheme.dark(),
      home: home,
    ),
  );
  await settle(tester);
}

Future<GoRouter> _pumpCastRoute(
  WidgetTester tester, {
  required PresentationEnvironment environment,
  PlaybackOrigin? origin,
  MediaImageSourcePolicy? policy,
  CatalogCache? cache,
}) async {
  final size = switch (environment.presentation) {
    AppPresentation.androidPhone => const Size(412, 900),
    AppPresentation.androidTv => const Size(960, 540),
    AppPresentation.desktop => const Size(1440, 900),
  };
  _useSurface(tester, size.width, size.height);
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      const FakeAccessibilityFeatures(disableAnimations: true);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  final anchor = FocusNode(debugLabel: 'origin-detail');
  addTearDown(anchor.dispose);
  final router = GoRouter(
    initialLocation: '/detail',
    routes: [
      GoRoute(
        path: '/detail',
        builder: (context, state) {
          final page = CupertinoPageScaffold(
            child: ListView(
              children: [
                Focus(focusNode: anchor, child: const Text('原详情')),
                const EpisodePeopleSection(people: _routePeople),
              ],
            ),
          );
          final scoped = origin == null
              ? page
              : DetailSourceScope(
                  origin: origin,
                  cache: cache!,
                  imagePolicy: policy!,
                  child: page,
                );
          return PresentationScope(environment: environment, child: scoped);
        },
      ),
      GoRoute(
        path: '/person/:personId',
        builder: (context, state) => CupertinoPageScaffold(
          child: Text('person ${state.pathParameters['personId']}'),
        ),
      ),
    ],
  );
  await tester.pumpWidget(
    CupertinoTestApp.router(
      locale: const Locale('zh'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: [
        AppLocalizations.delegate,
        ...GlobalCupertinoLocalizations.delegates,
      ],
      theme: AppUiTheme.dark(),
      routerConfig: router,
    ),
  );
  await settle(tester);
  return router;
}

/// `ensureVisible` aligns a card to the top of the detail list. Bring the
/// original header back before asserting that pop returned to that detail.
Future<void> _revealDetailOrigin(WidgetTester tester) async {
  for (final state in tester.stateList<ScrollableState>(
    find.byType(Scrollable),
  )) {
    final position = state.position;
    if (position.axis == Axis.vertical && position.pixels != 0) {
      position.jumpTo(0);
    }
  }
  await settle(tester);
}

bool _personFocused(WidgetTester tester, Finder card) {
  return tester
      .widget<FocusableActionDetector>(
        find.descendant(
          of: card,
          matching: find.byType(FocusableActionDetector),
        ),
      )
      .focusNode!
      .hasFocus;
}

Future<void> _activatePerson(
  WidgetTester tester,
  Finder card,
  PresentationEnvironment environment,
) async {
  await tester.ensureVisible(card);
  await settle(tester);
  if (environment.isTv) {
    final detector = find.descendant(
      of: card,
      matching: find.byType(FocusableActionDetector),
    );
    expect(detector, findsOneWidget);
    tester.widget<FocusableActionDetector>(detector).focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
  } else if (environment.presentation == AppPresentation.androidPhone) {
    await tester.tap(card);
  } else {
    final center = tester.getCenter(card);
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: center);
    await tester.pump();
    await gesture.down(center);
    await gesture.up();
    await gesture.removePointer();
  }
  await settle(tester);
}

Future<void> _pumpSeasonPlaceholder(WidgetTester tester, double width) async {
  _useSurface(tester, width, 800);
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      const FakeAccessibilityFeatures(disableAnimations: true);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  await tester.pumpWidget(
    CupertinoTestApp(
      locale: const Locale('zh'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: [
        AppLocalizations.delegate,
        ...GlobalCupertinoLocalizations.delegates,
      ],
      theme: AppUiTheme.dark(),
      home: CupertinoPageScaffold(
        child: ListView(
          children: [
            MobileSeriesPage(
              item: const MediaItem(
                id: 'series',
                name: '剧',
                type: 'Series',
                overview: '概览',
              ),
              seasons: const [
                MediaItem(id: 'season-1', name: '第 1 季', type: 'Season'),
              ],
              seasonId: 'season-1',
              episodes: const [],
              episodesLoading: true,
              episodeError: null,
              hasMore: false,
              playTargetId: null,
              similar: const [],
              onSelectSeason: _ignore,
              onOpenEpisode: _ignore,
              onRetryEpisodes: _noop,
              onLoadMore: _noop,
              onOpenItem: _ignore,
              onOpenSimilar: _noop,
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _waitForDecoded(WidgetTester tester, Finder scope) async {
  for (var i = 0; i < 30; i++) {
    final ready = tester
        .widgetList<RawImage>(
          find.descendant(
            of: scope,
            matching: find.byType(RawImage),
            skipOffstage: false,
          ),
        )
        .any((raw) => raw.image != null);
    if (ready) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await tester.pump();
  }
  fail('artwork frame was not decoded');
}

void _expectHandoffFrame(WidgetTester tester) {
  final handoff = find.byKey(PhoneItemBanner.handoffImageKey);
  expect(handoff, findsWidgets);
  expect(
    find.descendant(of: handoff, matching: find.byType(SkeletonBlock)),
    findsNothing,
  );
  expect(
    find.descendant(of: handoff, matching: find.byType(PosterPlaceholder)),
    findsNothing,
  );
  expect(
    find.descendant(of: handoff, matching: find.byType(Image)),
    findsWidgets,
  );
  expect(
    tester
        .widgetList<RawImage>(
          find.descendant(of: handoff, matching: find.byType(RawImage)),
        )
        .any((raw) => raw.image != null),
    isTrue,
  );
  final surface = AppUiTheme.dark().colorScheme.surfaceContainerHigh;
  expect(
    find.descendant(
      of: find.byKey(PhoneItemBanner.bannerKey),
      matching: find.byWidgetPredicate(
        (widget) => widget is ColoredBox && widget.color == surface,
      ),
    ),
    findsNothing,
  );
}

void _ignore(String _) {}

void _noop() {}

class _Started {
  const _Started({
    required this.router,
    required this.auth,
    required this.catalog,
  });

  final GoRouter router;
  final AuthController auth;
  final CatalogController catalog;
}

Future<_Started> _startDetail(
  WidgetTester tester, {
  required double width,
  bool reduceMotion = false,
  AppUiThemeData? theme,
  void Function(FakeEmbyServer server)? prepare,
  void Function(Dio dio)? intercept,
}) async {
  return _start(
    tester,
    width: width,
    reduceMotion: reduceMotion,
    theme: theme,
    prepare: prepare,
    intercept: intercept,
    initialLocation: '/library/view-movies',
    showLibrary: false,
  );
}

void _holdItemDetail(Dio dio, Completer<void> gate) {
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) async {
        final uri = options.uri.toString();
        final detail =
            options.method == 'GET' &&
            RegExp(r'/Items/[^/?]+($|\?)').hasMatch(uri) &&
            !uri.contains('/Images/');
        if (detail && !gate.isCompleted) {
          await gate.future;
        }
        handler.next(options);
      },
    ),
  );
}

Future<_Started> _startLibrary(
  WidgetTester tester, {
  required double width,
  bool reduceMotion = false,
  Completer<void>? holdDetail,
}) {
  return _start(
    tester,
    width: width,
    reduceMotion: reduceMotion,
    initialLocation: '/library/view-movies',
    showLibrary: true,
    intercept: holdDetail == null
        ? null
        : (dio) {
            dio.interceptors.add(
              InterceptorsWrapper(
                onRequest: (options, handler) async {
                  final uri = options.uri.toString();
                  final detail =
                      options.method == 'GET' &&
                      RegExp(r'/Items/[^/?]+($|\?)').hasMatch(uri) &&
                      !uri.contains('/Images/');
                  if (detail && !holdDetail.isCompleted) {
                    await holdDetail.future;
                  }
                  handler.next(options);
                },
              ),
            );
          },
  );
}

Future<_Started> _start(
  WidgetTester tester, {
  required double width,
  required String initialLocation,
  required bool showLibrary,
  bool reduceMotion = false,
  AppUiThemeData? theme,
  void Function(FakeEmbyServer server)? prepare,
  void Function(Dio dio)? intercept,
}) async {
  _useSurface(tester, width, 900);
  if (reduceMotion) {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  }
  final server = FakeEmbyServer();
  prepare?.call(server);
  final dio = dioForFakeEmby(FakeEmbyAdapter([server]));
  intercept?.call(dio);
  final auth = AuthController.memory(
    client: EmbyClient(device: _device, dio: dio),
  );
  await tester.runAsync(
    () => auth.connect(
      address: server.baseUrl.toString(),
      username: 'alice',
      password: 'correct-horse',
    ),
  );
  final catalog = CatalogController(auth: auth);
  catalog.libraries = const [
    MediaItem(
      id: 'view-movies',
      name: '电影',
      type: 'CollectionFolder',
      collectionType: 'movies',
    ),
  ];
  catalog.librariesLoading = false;
  final router = GoRouter(
    initialLocation: showLibrary ? initialLocation : '/empty',
    routes: [
      GoRoute(
        path: '/empty',
        builder: (context, state) =>
            const CupertinoPageScaffold(child: SizedBox()),
      ),
      GoRoute(
        path: '/library/:viewId',
        builder: (context, state) =>
            MobileLibraryPage(viewId: state.pathParameters['viewId']!),
      ),
      GoRoute(
        path: '/shelf/:source',
        builder: (context, state) => PhoneShelfPage.fromState(state),
      ),
      GoRoute(
        path: '/item/:itemId',
        pageBuilder: (context, state) => PhoneMotion.detailPage(
          context: context,
          state: state,
          child: MobileDetailPage(itemId: state.pathParameters['itemId']!),
        ),
      ),
    ],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 50));
    router.dispose();
    catalog.dispose();
    auth.dispose();
  });
  MediaImageCache.instance.fetchTimeout = const Duration(milliseconds: 1);
  await tester.pumpWidget(
    AuthScope(
      controller: auth,
      child: CatalogScope(
        controller: catalog,
        child: CupertinoTestApp.router(
          locale: const Locale('zh'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: [
            AppLocalizations.delegate,
            ...GlobalCupertinoLocalizations.delegates,
          ],
          theme: theme ?? AppUiTheme.dark(),
          routerConfig: router,
        ),
      ),
    ),
  );
  await tester.pump();
  return _Started(router: router, auth: auth, catalog: catalog);
}

void _useSurface(WidgetTester tester, double width, double height) {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  tester.view.padding = FakeViewPadding();
  tester.view.viewPadding = FakeViewPadding();
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPadding);
  addTearDown(tester.view.resetViewPadding);
}
