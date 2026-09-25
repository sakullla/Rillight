import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_motion.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/app/widgets/skeleton.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/home/phone_shelf_page.dart';
import 'package:rillight/library/episode_detail_sections.dart';
import 'package:rillight/library/mobile_detail_page.dart';
import 'package:rillight/library/mobile_library_page.dart';
import 'package:rillight/library/mobile_series_page.dart';
import 'package:rillight/media_image/media_image.dart';

import '../emby/fake_emby_server.dart';
import '../helpers/image_cache_fixture.dart';

const _device = EmbyDeviceInfo(
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

  for (final width in [360.0, 412.0]) {
    testWidgets('cast rows settle on whole cards at ${width.toInt()}dp', (
      tester,
    ) async {
      await _pumpPeople(tester, width: width, height: 900);
      expect(tester.takeException(), isNull);

      final actor0 = find.byKey(const ValueKey('episode-person-Actor-0'));
      final actor1 = find.byKey(const ValueKey('episode-person-Actor-1'));
      final actor2 = find.byKey(const ValueKey('episode-person-Actor-2'));
      expect(actor0, findsOneWidget);
      expect(actor1, findsOneWidget);
      expect(actor2, findsNothing);

      final first = tester.getRect(actor0);
      final second = tester.getRect(actor1);
      _expectOnScreen(first, width, 900);
      _expectOnScreen(second, width, 900);
      expect(first.left, closeTo(24, 1));
      expect(second.left, greaterThanOrEqualTo(first.right - 0.5));

      final avatar = tester.getRect(
        find.descendant(of: actor1, matching: find.byType(CircleAvatar)),
      );
      _expectOnScreen(avatar, width, 900);
      expect(avatar.width, closeTo(80, 1));
      expect(avatar.height, closeTo(80, 1));
      final role = tester.getRect(
        find.descendant(of: actor1, matching: find.text('Friend')),
      );
      _expectInside(role, tester.getRect(actor1));

      final longName = tester.getRect(
        find.descendant(of: actor0, matching: find.byType(Text)).first,
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
      _expectOnScreen(other, width, 900);
      expect(other.left, closeTo(24, 1));
      expect(width - other.right, greaterThanOrEqualTo(23));

      final strip = find.byType(PageView).first;
      for (var i = 0; i < 4; i++) {
        if (find
            .byKey(const ValueKey('episode-person-Actor-4'))
            .evaluate()
            .isNotEmpty) {
          break;
        }
        await tester.fling(strip, Offset(-width, 0), 2000);
        await tester.pumpAndSettle();
      }
      final last = tester.getRect(
        find.byKey(const ValueKey('episode-person-Actor-4')),
      );
      _expectOnScreen(last, width, 900);
      expect(last.right, closeTo(width - first.left, 1));
      expect(
        find.byKey(const ValueKey('episode-person-Actor-3')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('wide cast still wraps instead of paging', (tester) async {
    await _pumpPeople(tester, width: 900, height: 700);
    expect(find.byType(PageView), findsNothing);
    for (var i = 0; i < 5; i++) {
      final rect = tester.getRect(
        find.byKey(ValueKey('episode-person-Actor-$i')),
      );
      _expectOnScreen(rect, 900, 700);
    }
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
                startPositionTicks: i * 60 * 10000000,
              ),
          ];
          movie.people = const [
            FakePerson(name: 'Only Actor', type: 'Actor', role: 'Lead'),
          ];
        },
      );
      unawaited(harness.router.push('/item/movie-inception'));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byKey(const Key('phone-chapter-strip')));
      await tester.pumpAndSettle();
      expect(find.byKey(CatalogKeys.chapter(0)), findsOneWidget);
      expect(find.byKey(CatalogKeys.chapter(1)), findsOneWidget);
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
        await tester.pumpAndSettle();
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
        var episodeQueries = 0;
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) async {
              final uri = options.uri.toString();
              if (uri.contains('IncludeItemTypes=Episode')) {
                episodeQueries++;
                if (episodeQueries > 1 && !gate.isCompleted) {
                  await gate.future;
                }
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
    final card = tester.getRect(find.byType(SkeletonBlock).first);
    _expectOnScreen(card, 360, 900);
    expect(tester.takeException(), isNull);
    gate.complete();
    await tester.pumpAndSettle();
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
      await tester.pumpAndSettle();

      final poster = find.byKey(const ValueKey('movie-inception'));
      await tester.ensureVisible(poster);
      await tester.pumpAndSettle();
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

      await tester.tap(poster);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(_pendingHeader), findsOneWidget);
      final headerImages = tester.widgetList<MediaImage>(
        find.descendant(
          of: find.byKey(_pendingHeader),
          matching: find.byType(MediaImage),
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
      await tester.pumpAndSettle();
      expect(find.textContaining('dream-sharing'), findsOneWidget);
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
    await tester.pumpAndSettle();

    final poster = find.byKey(const ValueKey('movie-transcode'));
    await tester.scrollUntilVisible(
      poster,
      300,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
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
    await tester.pumpAndSettle();
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
      await tester.pumpAndSettle();
      final poster = find.byKey(
        const ValueKey('phone-library-poster-movie-inception'),
      );
      await tester.ensureVisible(poster);
      await tester.pumpAndSettle();
      final posterImage = tester.widget<MediaImage>(
        find.descendant(of: poster, matching: find.byType(MediaImage)),
      );

      await tester.tap(poster);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(_pendingHeader), findsOneWidget);
      final headerImages = tester.widgetList<MediaImage>(
        find.descendant(
          of: find.byKey(_pendingHeader),
          matching: find.byType(MediaImage),
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
      final body = tester.getRect(find.byKey(_pendingBody));
      expect(tester.widget<Text>(find.byKey(_pendingTitle)).data, 'Inception');
      expect(title.top, greaterThanOrEqualTo(header.bottom - 1));
      expect(action.top, greaterThanOrEqualTo(header.bottom - 1));
      expect(action.width, greaterThanOrEqualTo(48));
      expect(action.height, greaterThanOrEqualTo(48));
      expect(body.top, greaterThanOrEqualTo(action.bottom - 1));
      expect(body.height, greaterThan(40));
      expect(find.textContaining('dream-sharing'), findsNothing);
      expect(tester.takeException(), isNull);

      gate.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(_pendingBody), findsNothing);
      expect(find.textContaining('dream-sharing'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('mobile-detail-play')))
            .onPressed,
        isNotNull,
      );
      expect(tester.getTopLeft(find.byKey(PhoneItemBanner.bannerKey)).dy, 0);
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

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
    await tester.pumpAndSettle();
    final poster = find.byKey(
      const ValueKey('phone-library-poster-movie-inception'),
    );
    await tester.ensureVisible(poster);
    await tester.pumpAndSettle();
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
    expect(
      tester.getRect(find.byKey(_pendingTitle)).top,
      greaterThanOrEqualTo(
        tester.getRect(find.byKey(_pendingHeader)).bottom - 1,
      ),
    );
    expect(find.byKey(_pendingAction), findsOneWidget);
    expect(find.byKey(_pendingBody), findsOneWidget);
    expect(tester.takeException(), isNull);
    gate.complete();
    await tester.pumpAndSettle();
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
      await tester.pumpAndSettle();
      expect(find.text('重试'), findsOneWidget);
      expect(find.byKey(_pendingBody), findsNothing);
      expect(find.text('需转码片'), findsNothing);

      failDetail = false;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.text('需转码片'), findsWidgets);
      expect(find.text('重试'), findsNothing);
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );
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

Future<void> _pumpPeople(
  WidgetTester tester, {
  required double width,
  required double height,
}) async {
  _useSurface(tester, width, height);
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('zh'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      theme: AppTheme.dark(),
      home: Scaffold(
        body: EpisodePeopleSection(
          people: const [
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
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pumpSeasonPlaceholder(WidgetTester tester, double width) async {
  _useSurface(tester, width, 800);
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      const FakeAccessibilityFeatures(disableAnimations: true);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('zh'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      theme: AppTheme.dark(),
      home: Scaffold(
        body: ListView(
          children: [
            MobileSeriesPage(
              item: const EmbyItem(
                id: 'series',
                name: '剧',
                type: 'Series',
                overview: '概览',
              ),
              seasons: const [
                EmbyItem(id: 'season-1', name: '第 1 季', type: 'Season'),
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
  void Function(FakeEmbyServer server)? prepare,
  void Function(Dio dio)? intercept,
}) async {
  return _start(
    tester,
    width: width,
    reduceMotion: reduceMotion,
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
    EmbyItem(
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
        builder: (context, state) => const Scaffold(body: SizedBox()),
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
        child: MaterialApp.router(
          locale: const Locale('zh'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          theme: AppTheme.dark(),
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
