import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:animations/animations.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_chrome.dart';
import 'package:rillight/app/mobile_motion.dart';
import 'package:rillight/app/mobile_widgets.dart';
import 'package:rillight/app/phone_libraries_tab.dart';
import 'package:rillight/app/phone_mine_page.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/app/router.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/auth/android_connect_page.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/catalog_cache.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/home/home_hero.dart';
import 'package:rillight/home/phone_hero.dart';
import 'package:rillight/home/phone_home.dart';
import 'package:rillight/home/phone_shelf_page.dart';
import 'package:rillight/library/browse_controller.dart';
import 'package:rillight/library/mobile_detail_page.dart';
import 'package:rillight/library/mobile_library_page.dart';
import 'package:rillight/library/mobile_series_page.dart';
import 'package:rillight/library/shelf_grid_page.dart';
import 'package:rillight/library/shelf_sort.dart';
import 'package:rillight/media_image/media_image.dart';
import 'package:rillight/player/danmaku/dandanplay_client.dart';
import 'package:rillight/player/danmaku/dandanplay_models.dart';
import 'package:rillight/player/danmaku/danmaku_controller.dart';
import 'package:rillight/player/mobile_player_page.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_controller.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/player_window.dart';
import 'package:rillight/player/player_window_host.dart';
import 'package:rillight/player/video_backend.dart';

import '../emby/fake_emby_server.dart';
import '../helpers/image_cache_fixture.dart';

const _connectDevice = EmbyDeviceInfo(
  clientName: 'test',
  deviceName: 'phone',
  deviceId: 'phone-connect',
  version: '1',
);

const _address = Key('android-connect-address');
const _username = Key('android-connect-username');
const _password = Key('android-connect-password');
const _submit = Key('android-connect-submit');
const _more = Key('android-connect-more');
const _path = Key('android-connect-path');
const _userAgent = Key('android-connect-user-agent');
const _addLine = Key('android-connect-add-line');

const _homeDevice = EmbyDeviceInfo(
  clientName: 'test',
  deviceName: 'phone',
  deviceId: 'phone-home',
  version: '1',
);

const _libraryDevice = EmbyDeviceInfo(
  clientName: 'test',
  deviceName: 'phone',
  deviceId: 'phone-library',
  version: '1',
);

const _mineDevice = EmbyDeviceInfo(
  clientName: 'test',
  deviceName: 'phone',
  deviceId: 'phone-mine',
  version: '1',
);

void main() {
  group('phone_connect_test.dart', () {
    late FakeEmbyServer server;

    setUp(() {
      server = FakeEmbyServer();
    });

    Future<AuthController> pumpConnect(
      WidgetTester tester, {
      int generation = 0,
      AuthController? auth,
    }) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller =
          auth ??
          AuthController.memory(
            client: EmbyClient(
              device: _connectDevice,
              dio: dioForFakeEmby(FakeEmbyAdapter([server])),
            ),
          );
      if (auth == null) {
        addTearDown(controller.dispose);
      }
      await tester.pumpWidget(_harness(controller, generation: generation));
      await tester.pumpAndSettle();
      return controller;
    }

    String textOf(WidgetTester tester, Key key) {
      return tester.widget<TextField>(find.byKey(key)).controller!.text;
    }

    Future<void> enterCredentials(
      WidgetTester tester, {
      required String address,
      required String username,
      required String password,
    }) async {
      await tester.enterText(find.byKey(_address), address);
      await tester.enterText(find.byKey(_username), username);
      await tester.enterText(find.byKey(_password), password);
    }

    Future<void> tap(WidgetTester tester, Finder finder) async {
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    testWidgets(
      'path, extra line and User-Agent stay under 更多 until expanded',
      (tester) async {
        final auth = await pumpConnect(tester);
        expect(find.byKey(_path), findsNothing);
        await tap(tester, find.byKey(_more));
        expect(find.byKey(_path), findsOneWidget);
        expect(find.byKey(_userAgent), findsOneWidget);
        expect(find.byKey(_addLine), findsOneWidget);

        await enterCredentials(
          tester,
          address: server.baseUrl.toString(),
          username: 'alice',
          password: 'correct-horse',
        );
        await tester.enterText(find.byKey(_path), '/emby');
        await tester.enterText(find.byKey(_userAgent), 'CustomUA/1.0');
        await tap(tester, find.byKey(_addLine));
        await tester.enterText(
          find.byKey(const Key('android-connect-extra-line-0')),
          'http://backup.test:8096',
        );
        await tap(tester, find.byKey(_submit));

        expect(auth.isLoggedIn, isTrue);
        expect(auth.savedServers.single.baseUrl, 'http://emby.test:8096/emby');
        expect(
          auth.savedServers.single.lines.map((line) => line.address),
          contains('http://backup.test:8096'),
        );
        expect(
          auth.savedServers.single.activeLine?.normalizedUserAgent,
          'CustomUA/1.0',
        );
        expect(server.lastUserAgent, 'CustomUA/1.0');
        expect(tester.takeException(), isNull);
      },
      tags: ['integration'],
    );

    testWidgets('connection failure stays on the page and can be retried', (
      tester,
    ) async {
      final auth = await pumpConnect(tester);
      await enterCredentials(
        tester,
        address: 'ftp://files.test',
        username: 'alice',
        password: 'correct-horse',
      );
      await tap(tester, find.byKey(_submit));

      expect(auth.isLoggedIn, isFalse);
      expect(find.byType(AndroidConnectPage), findsOneWidget);
      expect(find.text('请输入有效的服务器地址'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      expect(find.textContaining('EmbyException'), findsNothing);

      await tester.enterText(find.byKey(_address), server.baseUrl.toString());
      await tester.enterText(find.byKey(_password), 'wrong');
      await tap(tester, find.byKey(_submit));

      expect(auth.isLoggedIn, isFalse);
      expect(find.byType(AndroidConnectPage), findsOneWidget);
      expect(find.text('HTTP 401: invalid credentials'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      expect(find.text('请输入有效的服务器地址'), findsNothing);
      expect(textOf(tester, _password), 'wrong');

      await tester.enterText(find.byKey(_password), 'correct-horse');
      await tap(tester, find.byKey(_submit));

      expect(auth.isLoggedIn, isTrue);
      expect(find.text('重试'), findsNothing);
      expect(tester.takeException(), isNull);
    }, tags: ['integration']);

    testWidgets('unsubmitted password is empty after the page is recreated', (
      tester,
    ) async {
      final auth = await pumpConnect(tester);
      await enterCredentials(
        tester,
        address: server.baseUrl.toString(),
        username: 'alice',
        password: 'not-submitted',
      );
      await tester.pumpWidget(_harness(auth));
      await tester.pump();

      expect(auth.connectDraft?.password, 'not-submitted');
      expect(textOf(tester, _password), 'not-submitted');
      expect(textOf(tester, _address), server.baseUrl.toString());

      await tester.pumpWidget(_harness(auth, generation: 1));
      await tester.pumpAndSettle();

      expect(find.byType(AndroidConnectPage), findsOneWidget);
      expect(textOf(tester, _password), isEmpty);
      expect(auth.connectDraft?.password, isEmpty);
      expect(textOf(tester, _address), server.baseUrl.toString());
      expect(textOf(tester, _username), 'alice');
      expect(await auth.credentials.read(server.serverId), isNull);
      expect(tester.takeException(), isNull);
    }, tags: ['integration']);
  });

  group('phone_home_test.dart', () {
    setUp(isolateImageCache);

    test('dark theme exposes the mobile navigation bar theme from tokens', () {
      final theme = AppTheme.dark();
      final nav = theme.navigationBarTheme;
      expect(nav.elevation, 0);
      expect(nav.surfaceTintColor, Colors.transparent);
      expect(
        nav.backgroundColor!.a,
        closeTo(AppMobileNav.backgroundAlpha, 1e-6),
      );
      expect(nav.indicatorShape, isA<StadiumBorder>());
      expect(nav.indicatorColor, isNotNull);
      // 选中 pill 动效档位对齐 AppMotion。
      expect(AppMobileNav.pillDuration, AppMotion.normal);
      expect(AppMobileCard.pressDuration, AppMotion.fast);
      // 控制层渐变 token 与 AppScrim 对齐(R8:不再散落 black54/black87)。
      expect(AppMobileControls.bottomAlpha, AppScrim.playerBar);
      expect(AppMobileControls.bottomSoftAlpha, AppScrim.playerBarSoft);
      // 桌面 NavigationRail 主题保持原样,不受手机 token 影响。
      expect(theme.navigationRailTheme, isNotNull);
    });

    testWidgets('banner prefers continue watching and switches only by swipe', (
      tester,
    ) async {
      _usePhoneSurface(tester);
      final catalog = _catalog(
        resume: [
          _item('episode-a', '试播集', 'Episode', percent: 40, seriesName: '示例剧'),
          _item('movie-b', '乙电影', 'Movie', percent: 10),
        ],
        movies: [
          _item('movie-b', '乙电影', 'Movie', percent: 10),
          _item('movie-c', '示例电影', 'Movie'),
          _item('movie-d', '丁电影', 'Movie'),
          _item('movie-e', '戊电影', 'Movie'),
          _item('movie-f', '落选电影', 'Movie'),
        ],
        series: [_item('series-h', '示例剧全集', 'Series')],
      );
      addTearDown(catalog.auth.dispose);
      addTearDown(catalog.dispose);
      final router = _router(catalog);
      addTearDown(router.dispose);
      await tester.pumpWidget(_scriptedApp(catalog, router: router));
      await tester.pump();

      expect(find.byType(HomeHero), findsNothing);
      // 继续观看优先、按 id 去重、上限 5:movie-f 与 series-h 落选。
      expect(find.byKey(PhoneHero.itemKey('episode-a')), findsOneWidget);
      expect(find.byKey(PhoneHero.itemKey('movie-f')), findsNothing);
      expect(find.byKey(PhoneHero.itemKey('series-h')), findsNothing);
      expect(find.byKey(CatalogKeys.heroDot(4)), findsOneWidget);
      expect(find.byKey(CatalogKeys.heroDot(5)), findsNothing);
      expect(find.text('继续播放'), findsNothing);
      expect(find.text('已看 40%'), findsWidgets);
      expect(find.byTooltip('暂停轮播'), findsNothing);

      const featured = [
        'episode-a',
        'movie-b',
        'movie-c',
        'movie-d',
        'movie-e',
      ];
      String? alignedHero() {
        final banner = tester.getRect(find.byKey(PhoneHero.bannerKey));
        for (final id in featured) {
          final finder = find.byKey(PhoneHero.itemKey(id));
          if (finder.evaluate().isEmpty) {
            continue;
          }
          if ((tester.getRect(finder).left - banner.left).abs() < 2) {
            return id;
          }
        }
        return null;
      }

      // 无自动轮换:停留再久也停在当前条。
      expect(alignedHero(), 'episode-a');
      await tester.pump(const Duration(seconds: 7));
      expect(alignedHero(), 'episode-a');

      // 手动滑动切换到下一条。
      await tester.drag(find.byKey(PhoneHero.bannerKey), const Offset(-260, 0));
      await tester.pump();
      // PageView 弹簧归位动画跑完再判定。
      await tester.pump(const Duration(seconds: 1));
      expect(alignedHero(), 'movie-b');

      // 滑动后也不会恢复自动轮换。
      await tester.pump(const Duration(seconds: 7));
      expect(alignedHero(), 'movie-b');
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'home row editing opens from the home tab, not the account page',
      (tester) async {
        final (router, _) = await _openPhone(tester);
        expect(find.byKey(const Key('phone-home-edit')), findsOneWidget);
        expect(find.text('横幅'), findsNothing);

        await tester.tap(find.byKey(const Key('phone-home-edit')));
        await _homeSettle(tester);
        expect(find.byKey(const Key('phone-home-edit-page')), findsOneWidget);
        expect(find.text('横幅'), findsOneWidget);
        expect(
          find.text('按住左侧手柄拖动排序。关闭的行会归到「未显示」。片库页仍会列出全部片库。'),
          findsOneWidget,
        );

        router.pop();
        await _homeSettle(tester);
        await tester.tap(find.byKey(const Key('mobile-shell-mine-entry')));
        await _homeSettle(tester);
        expect(find.byType(PhoneMinePage), findsOneWidget);
        expect(find.text('横幅'), findsNothing);
        expect(find.byKey(const Key('phone-home-edit-page')), findsNothing);
        expect(tester.takeException(), isNull);
      },
      tags: ['integration'],
    );

    testWidgets('MobilePressable scales and brightens while pressed', (
      tester,
    ) async {
      Future<void> pumpPressable() {
        return tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.dark(),
            home: Scaffold(
              body: Center(
                child: MobilePressable(
                  onTap: () {},
                  child: const SizedBox(width: 100, height: 100),
                ),
              ),
            ),
          ),
        );
      }

      await pumpPressable();
      final pressable = find.byType(MobilePressable);
      expect(pressable, findsOneWidget);
      final gesture = find.descendant(
        of: pressable,
        matching: find.byType(GestureDetector),
      );
      expect(gesture, findsOneWidget);

      // 未按压:缩放 1、无提亮遮罩。
      AnimatedScale scaleOf() => tester.widget(
        find.descendant(of: pressable, matching: find.byType(AnimatedScale)),
      );
      expect(scaleOf().scale, 1);
      expect(
        tester
            .widget<ColorFiltered>(
              find.descendant(
                of: pressable,
                matching: find.byType(ColorFiltered),
              ),
            )
            .colorFilter,
        const ColorFilter.mode(Colors.transparent, BlendMode.plus),
      );

      final pointer = await tester.startGesture(tester.getCenter(gesture));
      await tester.pump();
      expect(scaleOf().scale, AppMobileCard.pressScale);
      expect(scaleOf().duration, AppMotion.fast);
      await pointer.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(scaleOf().scale, 1);

      // 减弱动效下按压仍可用,但动画时长归零。
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await pumpPressable();
      final reduced = find.byType(MobilePressable);
      final reducedGesture = find.descendant(
        of: reduced,
        matching: find.byType(GestureDetector),
      );
      await tester.startGesture(tester.getCenter(reducedGesture));
      await tester.pump();
      final scale = tester.widget<AnimatedScale>(
        find.descendant(of: reduced, matching: find.byType(AnimatedScale)),
      );
      expect(scale.duration, Duration.zero);
      expect(scale.scale, AppMobileCard.pressScale);
    });

    testWidgets(
      'poster flies to the top as the same image and is the only hero',
      (tester) async {
        await _pumpMotionHome(tester);
        await _homeUntil(
          tester,
          find.byKey(CatalogKeys.item('movie-inception')),
        );
        // 同一海报 id 只允许一个 Hero,否则 flight 会歧义。
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
          findsOneWidget,
        );
        final poster = find.byKey(CatalogKeys.item('movie-inception'));
        final posterImage = tester.widget<MediaImage>(
          find.descendant(of: poster, matching: find.byType(MediaImage)),
        );

        await tester.tap(poster);
        await _homeUntil(tester, find.byKey(PhoneItemBanner.bannerKey));
        _expectSameImage(tester, posterImage, onstage: true);
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

        await _homeSettle(tester);
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
      },
    );

    testWidgets('reduced motion keeps the banner and the primary action', (
      tester,
    ) async {
      await _pumpMotionHome(tester, reduceMotion: true);
      await _homeUntil(
        tester,
        find.byKey(PhoneHero.itemKey('movie-inception')),
      );
      expect(
        tester.widget<GestureDetector>(find.byKey(PhoneHero.openKey)).onTap,
        isNotNull,
      );
      expect(find.text('已看 40%'), findsWidgets);

      await tester.pump(const Duration(seconds: 7));
      expect(find.byKey(PhoneHero.itemKey('movie-inception')), findsOneWidget);
      expect(find.text('已看 40%'), findsWidgets);

      await tester.tap(find.byKey(PhoneHero.openKey));
      await _homeSettle(tester);
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

    test('route and tab transition tokens stay in the 200-300ms range', () {
      const lower = Duration(milliseconds: 200);
      const upper = Duration(milliseconds: 300);
      expect(
        PhoneMotion.pageTransition >= lower &&
            PhoneMotion.pageTransition <= upper,
        isTrue,
      );
      expect(
        PhoneMotion.tabTransition >= lower &&
            PhoneMotion.tabTransition <= upper,
        isTrue,
      );
    });

    testWidgets(
      'detail, shelf and mine pushes run material motion page transitions',
      (tester) async {
        final (router, _) = await _openPhone(
          tester,
          prepare: _addShelfMovies,
          reduceMotion: false,
        );

        // 详情:container transform 语义(fade-scale),时长走 AppMotion 中枢。
        await tester.ensureVisible(find.byKey(PhoneHero.openKey));
        await tester.tap(find.byKey(PhoneHero.openKey));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 80));
        expect(find.byType(FadeScaleTransition), findsOneWidget);
        expect(
          ModalRoute.of(
            tester.element(find.byType(MobileDetailPage)),
          )!.transitionDuration,
          PhoneMotion.pageTransition,
        );
        await _homeSettle(tester);
        expect(find.byKey(PhoneItemBanner.bannerKey), findsOneWidget);
        router.pop();
        await _homeSettle(tester);

        // 我的:shared axis Y。
        await tester.tap(find.byKey(const Key('mobile-shell-mine-entry')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 80));
        expect(
          tester
              .widget<SharedAxisTransition>(
                find.byType(SharedAxisTransition).last,
              )
              .transitionType,
          SharedAxisTransitionType.vertical,
        );
        expect(
          ModalRoute.of(
            tester.element(find.byType(PhoneMinePage)),
          )!.transitionDuration,
          PhoneMotion.pageTransition,
        );
        await _homeSettle(tester);
        router.pop();
        await _homeSettle(tester);

        // 货架:shared axis Y。
        final more = find.byKey(
          CatalogKeys.shelfMore(CatalogKeys.shelfLatestMovies),
        );
        await _showOnHome(tester, more);
        await tester.tap(more);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 80));
        expect(
          tester
              .widget<SharedAxisTransition>(
                find.byType(SharedAxisTransition).last,
              )
              .transitionType,
          SharedAxisTransitionType.vertical,
        );
        expect(find.byType(PhoneShelfPage), findsOneWidget);
        await _homeSettle(tester);
        expect(find.byType(PhoneShelfPage), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
      tags: ['integration'],
    );

    testWidgets('reduced motion finishes route transitions immediately', (
      tester,
    ) async {
      final (router, _) = await _openPhone(tester);
      await tester.ensureVisible(find.byKey(PhoneHero.openKey));
      await tester.tap(find.byKey(PhoneHero.openKey));
      await tester.pump();
      expect(
        ModalRoute.of(
          tester.element(find.byType(MobileDetailPage)),
        )!.transitionDuration,
        Duration.zero,
      );
      await _homeSettle(tester);
      expect(find.byKey(PhoneItemBanner.bannerKey), findsOneWidget);

      router.pop();
      await _homeSettle(tester);
      await tester.tap(find.byKey(const Key('mobile-shell-mine-entry')));
      await tester.pump();
      expect(
        ModalRoute.of(
          tester.element(find.byType(PhoneMinePage)),
        )!.transitionDuration,
        Duration.zero,
      );
      await _homeSettle(tester);
      expect(find.byType(PhoneMinePage), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, tags: ['integration']);

    testWidgets(
      'resume card carries progress and remove, and removal survives refresh',
      (tester) async {
        _usePhoneSurface(tester);
        final catalog = _catalog(
          resume: [_item('movie-b', '乙电影', 'Movie', percent: 10)],
          movies: [_item('movie-c', '示例电影', 'Movie')],
          series: const [],
        );
        addTearDown(catalog.auth.dispose);
        addTearDown(catalog.dispose);
        final router = _router(catalog);
        addTearDown(router.dispose);
        await tester.pumpWidget(_scriptedApp(catalog, router: router));
        await tester.pump();

        // 进度条与单条移除都保留,并落在继续观看卡内(Hero 也有一条进度条)。
        final card = tester.getRect(find.byKey(CatalogKeys.item('movie-b')));
        expect(
          _inside(
            tester.getRect(find.byKey(CatalogKeys.removeFromResume('movie-b'))),
            card,
          ),
          isTrue,
        );
        expect(find.byKey(CatalogKeys.resumeProgress), findsWidgets);
        expect(_inside(tester.getRect(find.text('已看 10%').last), card), isTrue);

        // 真实服务器上移除后刷新,继续观看行保持消失并落库。
        final (liveRouter, server) = await _openPhone(tester);
        expect(find.byType(HomeHero), findsNothing);
        expect(find.byType(PhoneHero), findsOneWidget);
        expect(find.text('已看 40%'), findsWidgets);
        expect(find.text('继续观看'), findsOneWidget);

        await tester.tap(find.byKey(CatalogKeys.item('movie-inception')));
        await _homeSettle(tester);
        expect(find.byType(MobilePlayerPage), findsNothing);
        expect(
          tester.widget<MobileDetailPage>(find.byType(MobileDetailPage)).itemId,
          'movie-inception',
        );
        liveRouter.pop();
        await _homeSettle(tester);

        final remove = find.byKey(
          CatalogKeys.removeFromResume('movie-inception'),
        );
        await _showOnHome(tester, remove);
        await tester.tap(remove);
        await _homeSettle(tester);
        expect(
          find.descendant(
            of: find.byKey(CatalogKeys.resumeRow),
            matching: find.byKey(CatalogKeys.item('movie-inception')),
          ),
          findsNothing,
        );
        expect(find.text('继续观看'), findsOneWidget);

        final homeScroll = tester.state<ScrollableState>(
          find.descendant(
            of: find.byKey(const PageStorageKey('mobile-home-scroll')),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Scrollable &&
                  widget.axisDirection == AxisDirection.down,
            ),
          ),
        );
        homeScroll.position.jumpTo(0);
        await tester.pump();
        await tester.fling(
          find.byKey(const PageStorageKey('mobile-home-scroll')),
          const Offset(0, 400),
          1500,
        );
        await _homeSettle(tester);
        expect(
          find.descendant(
            of: find.byKey(CatalogKeys.resumeRow),
            matching: find.byKey(CatalogKeys.item('movie-inception')),
          ),
          findsNothing,
        );
        expect(find.text('继续观看'), findsOneWidget);
        expect(
          server.items
              .firstWhere((item) => item.id == 'movie-inception')
              .hideFromResume,
          isTrue,
        );
        expect(tester.takeException(), isNull);
      },
      tags: ['integration'],
    );

    testWidgets('home rows carry episode, count, watched and progress badges', (
      tester,
    ) async {
      _usePhoneSurface(tester);
      final catalog = _catalog(
        resume: [
          const EmbyItem(
            id: 'episode-resume',
            name: '第二集',
            type: 'Episode',
            seriesName: '示例剧',
            seriesId: 'series-demo',
            parentIndexNumber: 1,
            indexNumber: 2,
            userData: EmbyUserData(
              playbackPositionTicks: 1,
              playedPercentage: 40,
            ),
          ),
        ],
        movies: [
          const EmbyItem(
            id: 'movie-progress',
            name: '进度电影',
            type: 'Movie',
            productionYear: 2024,
            userData: EmbyUserData(
              playbackPositionTicks: 1,
              playedPercentage: 10,
            ),
          ),
          const EmbyItem(
            id: 'movie-played',
            name: '已看电影',
            type: 'Movie',
            productionYear: 2023,
            userData: EmbyUserData(played: true),
          ),
        ],
        series: [
          const EmbyItem(
            id: 'series-long',
            name: '长剧集',
            type: 'Series',
            productionYear: 2022,
            childCount: 24,
          ),
        ],
      );
      addTearDown(catalog.auth.dispose);
      addTearDown(catalog.dispose);
      final router = _router(catalog);
      addTearDown(router.dispose);
      await tester.pumpWidget(_scriptedApp(catalog, router: router));
      await tester.pump();

      // 继续观看横卡:季集编号与进度角标都落在卡内,底部进度条保留。
      final wideBadges = find.byKey(phoneHomeBadgesKey('episode-resume'));
      expect(wideBadges, findsOneWidget);
      final wideCard = tester.getRect(
        find.byKey(CatalogKeys.item('episode-resume')),
      );
      expect(_inside(tester.getRect(wideBadges), wideCard), isTrue);
      expect(
        find.descendant(of: wideBadges, matching: find.text('S1E2')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: wideBadges, matching: find.text('已看 40%')),
        findsOneWidget,
      );
      expect(find.byKey(CatalogKeys.resumeProgress), findsWidgets);

      // 电影海报:可续播给进度角标,已看只给已看角标、不带百分比。
      expect(
        find.descendant(
          of: find.byKey(phoneHomeBadgesKey('movie-progress')),
          matching: find.text('已看 10%'),
        ),
        findsOneWidget,
      );
      final playedBadges = find.byKey(phoneHomeBadgesKey('movie-played'));
      expect(
        find.descendant(of: playedBadges, matching: find.text('已看')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: playedBadges, matching: find.textContaining('%')),
        findsNothing,
      );

      // 剧集海报:集数角标。
      expect(
        find.descendant(
          of: find.byKey(phoneHomeBadgesKey('series-long')),
          matching: find.text('24 集'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    }, tags: ['integration']);

    testWidgets('a failed home row retries inline while the other rows stay', (
      tester,
    ) async {
      _usePhoneSurface(tester);
      final catalog = _catalog(
        resume: [_item('movie-b', '乙电影', 'Movie', percent: 10)],
        movies: const [],
        series: const [],
      );
      catalog.latestMovies = const CatalogRowState(
        error: EmbyException(EmbyFailureKind.unknown, statusCode: 503),
      );
      addTearDown(catalog.auth.dispose);
      addTearDown(catalog.dispose);
      final router = _router(catalog);
      addTearDown(router.dispose);
      await tester.pumpWidget(_scriptedApp(catalog, router: router));
      await tester.pump();

      // 失败行内给重试,继续观看行不受影响,失败行不出现货架入口。
      expect(find.byKey(CatalogKeys.item('movie-b')), findsOneWidget);
      final failedRow = find.byKey(CatalogKeys.latestMoviesRow);
      expect(
        find.descendant(
          of: failedRow,
          matching: find.byType(MobileFailureState),
        ),
        findsOneWidget,
      );
      final retry = find.descendant(
        of: failedRow,
        matching: find.byKey(MobileFailureState.retryKey),
      );
      expect(retry, findsOneWidget);
      expect(
        find.byKey(CatalogKeys.shelfMore(CatalogKeys.shelfLatestMovies)),
        findsNothing,
      );

      await tester.tap(retry);
      await tester.pump();
      expect(find.byKey(CatalogKeys.item('movie-b')), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, tags: ['integration']);

    testWidgets(
      'an all-empty home shows the empty state with a refresh entry',
      (tester) async {
        _usePhoneSurface(tester);
        final catalog = _catalog(
          resume: const [],
          movies: const [],
          series: const [],
        );
        addTearDown(catalog.auth.dispose);
        addTearDown(catalog.dispose);
        final router = _router(catalog);
        addTearDown(router.dispose);
        await tester.pumpWidget(_scriptedApp(catalog, router: router));
        await tester.pump();

        expect(find.byType(MobileEmptyState), findsOneWidget);
        expect(find.text('暂无内容'), findsOneWidget);
        expect(find.text('刷新'), findsOneWidget);
        expect(find.byType(MobileFailureState), findsNothing);
        // 下拉刷新容器保留。
        expect(find.byType(RefreshIndicator), findsOneWidget);

        await tester.tap(find.byKey(MobileEmptyState.actionKey));
        await tester.pump();
        expect(find.byType(MobileEmptyState), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
      tags: ['integration'],
    );

    testWidgets(
      'shelf more appears only for full rows and opens the phone shelf',
      (tester) async {
        final (_, server) = await _openPhone(tester, prepare: _addShelfMovies);
        expect(find.text('冷门电影'), findsNothing);
        // 电影行满员出现"更多"。继续观看只要有条目就出现，剧集行不满员不出现。
        expect(
          find.byKey(CatalogKeys.shelfMore(CatalogKeys.shelfLatestMovies)),
          findsOneWidget,
        );
        expect(
          find.byKey(CatalogKeys.shelfMore(CatalogKeys.shelfLatestSeries)),
          findsNothing,
        );
        expect(
          find.byKey(CatalogKeys.shelfMore(CatalogKeys.shelfResume)),
          findsOneWidget,
        );
        expect(find.byType(ShelfGridPage), findsNothing);

        final more = find.byKey(
          CatalogKeys.shelfMore(CatalogKeys.shelfLatestMovies),
        );
        await _showOnHome(tester, more);
        await tester.tap(more);
        await _homeSettle(tester);

        expect(find.byType(PhoneShelfPage), findsOneWidget);
        expect(find.byType(ShelfGridPage), findsNothing);
        expect(find.byType(HomeHero), findsNothing);
        expect(
          find.descendant(
            of: find.byType(AppBar),
            matching: find.text('最近更新的电影'),
          ),
          findsOneWidget,
        );
        expect(find.text('加载更多'), findsNothing);
        expect(
          server.requests.where(
            (request) =>
                request.contains('IncludeItemTypes=Movie') &&
                request.contains('Limit=${PhoneShelfPage.pageSize}') &&
                request.contains('StartIndex=0') &&
                request.contains('SortBy=DateLastContentAdded') &&
                request.contains('SortOrder=Descending'),
          ),
          isNotEmpty,
        );
        await tester.scrollUntilVisible(find.text('冷门电影'), 400);
        expect(find.text('冷门电影'), findsOneWidget);
        await tester.tap(find.byKey(const Key('phone-shelf-filter')));
        await _homeSettle(tester);
        expect(
          find.byKey(const Key('catalog-filter-watch-unplayed')),
          findsOneWidget,
        );
        await tester.tap(
          find.byKey(const Key('catalog-filter-watch-unplayed')),
        );
        await _homeSettle(tester);
        expect(
          server.requests.where(
            (request) =>
                request.contains('IncludeItemTypes=Movie') &&
                request.contains('Filters=IsUnplayed'),
          ),
          isNotEmpty,
        );
        expect(tester.takeException(), isNull);
      },
      tags: ['integration'],
    );

    // '/shelf/:source' 的环境分派在全 test/ 仅此处守护:desktop 建 ShelfGridPage,
    // phone 建 PhoneShelfPage。只断言路由分派,不泵页面内容。
    testWidgets('desktop shelf route still uses the desktop grid', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      final server = FakeEmbyServer();
      final auth = AuthController.memory(
        client: EmbyClient(
          device: _homeDevice,
          dio: dioForFakeEmby(FakeEmbyAdapter([server])),
        ),
      );
      addTearDown(auth.dispose);
      await tester.runAsync(() async {
        await auth.connect(
          address: server.baseUrl.toString(),
          username: 'alice',
          password: 'correct-horse',
        );
      });
      final desktopRouter = createAppRouter(
        auth: auth,
        environment: PresentationEnvironment.desktop,
      );
      addTearDown(desktopRouter.dispose);
      desktopRouter.go(AppRoutes.shelfResume);
      await tester.pumpWidget(
        AuthScope(
          controller: auth,
          child: MaterialApp.router(
            theme: AppTheme.dark(),
            locale: const Locale('zh'),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            routerConfig: desktopRouter,
          ),
        ),
      );
      await _homeSettle(tester);
      expect(find.byType(ShelfGridPage), findsOneWidget);
      expect(find.byType(PhoneShelfPage), findsNothing);
      // 桌面路由不受手机 Material Motion 包装影响,仍是默认 Material 页面。
      final desktopShelfRoute = ModalRoute.of(
        tester.element(find.byType(ShelfGridPage)),
      )!;
      expect(desktopShelfRoute.settings, isA<MaterialPage<void>>());
      expect(
        desktopShelfRoute.settings,
        isNot(isA<CustomTransitionPage<void>>()),
      );

      final phoneRouter = createAppRouter(
        auth: auth,
        environment: PresentationEnvironment.phone,
      );
      addTearDown(phoneRouter.dispose);
      phoneRouter.go(AppRoutes.shelfLatestMovies);
      await tester.pumpWidget(
        AuthScope(
          controller: auth,
          child: MaterialApp.router(
            theme: AppTheme.dark(),
            locale: const Locale('zh'),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            routerConfig: phoneRouter,
          ),
        ),
      );
      await _homeSettle(tester);
      expect(find.byType(PhoneShelfPage), findsOneWidget);
      expect(find.byType(ShelfGridPage), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('phone_detail_test.dart', () {
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

    Future<void> openItem(
      WidgetTester tester,
      GoRouter router,
      String id,
    ) async {
      unawaited(router.push('/item/$id'));
      await tester.pumpAndSettle();
    }

    Future<void> closePlayer(WidgetTester tester) async {
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    }

    testWidgets(
      'series page names the episode and returns from episode detail',
      (tester) async {
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
              .widget<Tooltip>(
                find.ancestor(of: play, matching: find.byType(Tooltip)),
              )
              .message,
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
        expect(find.byTooltip('下一集'), findsOneWidget);
        await tester.tap(find.byKey(CatalogKeys.nextEpisode));
        await tester.pumpAndSettle();
        expect(find.text('The next night.'), findsOneWidget);
        await tester.tap(find.byKey(CatalogKeys.seriesLink));
        await tester.pumpAndSettle();
        expect(find.widgetWithText(ChoiceChip, '第 2 季'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
      tags: ['integration'],
    );

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
      expect(find.byTooltip('继续播放'), findsOneWidget);
      expect(find.byTooltip('从头播放'), findsOneWidget);
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
      expect(find.byTooltip('标记未看'), findsOneWidget);
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
      expect(find.byTooltip('标记已看'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      unawaited(router.push('/library/view-movies'));
      await tester.pumpAndSettle();
      await _filterUnwatched(tester);
      expect(find.text('Inception'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, tags: ['integration']);

    testWidgets(
      'chosen audio and subtitle are used when phone playback starts',
      (tester) async {
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

        await tester.ensureVisible(find.textContaining('日语音轨'));
        await tester.tap(find.textContaining('日语音轨'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.textContaining('英文字幕'));
        await tester.tap(find.textContaining('英文字幕'));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('mobile-detail-play')));
        await tester.pumpAndSettle();
        final page = tester.widget<MobilePlayerPage>(
          find.byType(MobilePlayerPage),
        );
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
      },
      tags: ['integration'],
    );

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
            .widget<Tooltip>(
              find.ancestor(of: play, matching: find.byType(Tooltip)),
            )
            .message,
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
  });

  group('phone_library_test.dart', () {
    setUp(isolateImageCache);

    test(
      'year, genre and premiere sort stay optional for television calls',
      () async {
        final server = FakeEmbyServer();
        final auth = AuthController.memory(
          client: EmbyClient(
            device: _libraryDevice,
            dio: dioForFakeEmby(FakeEmbyAdapter([server])),
          ),
        );
        addTearDown(auth.dispose);
        await auth.connect(
          address: server.baseUrl.toString(),
          username: 'alice',
          password: 'correct-horse',
        );
        final cache = CatalogCache()
          ..debugSetDiskStore(null)
          ..attachSession(
            serverId: server.serverId,
            userId: auth.client.userId!,
          );
        final browse = BrowseController(
          auth: auth,
          cache: cache,
          parentId: 'view-movies',
        );
        addTearDown(browse.dispose);
        await browse.load();
        await browse.filter(type: 'Movie', sortBy: 'SortName');
        final plain = _lastItemsQuery(server);
        expect(plain, contains('SortBy=SortName'));
        expect(plain, contains('SortOrder=Ascending'));
        expect(plain, isNot(contains('Years=')));
        expect(plain, isNot(contains('Genres=')));
        expect(plain, isNot(contains('Random')));

        await browse.filter(
          watch: 'IsUnplayed',
          sortBy: CatalogSort.dateCreated.sortBy,
          year: 2010,
          genre: 'SciFi',
        );
        final narrowed = _lastItemsQuery(server);
        expect(narrowed, contains('SortBy=DateCreated'));
        expect(narrowed, contains('SortOrder=Descending'));
        expect(narrowed, contains('Filters=IsUnplayed'));
        expect(narrowed, contains('Years=2010'));
        expect(narrowed, contains('Genres=SciFi'));
        expect(browse.year, 2010);
        expect(browse.genre, 'SciFi');

        await browse.filter(sortBy: CatalogSort.premiereDate.sortBy);
        final premiere = _lastItemsQuery(server);
        expect(premiere, contains('SortBy=PremiereDate'));
        expect(premiere, contains('SortOrder=Descending'));
        expect(browse.year, isNull);
        expect(browse.genre, isNull);
        expect(premiere, isNot(contains('Years=')));
        expect(premiere, isNot(contains('Genres=')));

        await browse.filter(sortBy: CatalogSort.communityRating.sortBy);
        expect(_lastItemsQuery(server), contains('SortBy=CommunityRating'));
        expect(_lastItemsQuery(server), contains('SortOrder=Descending'));

        server.items = [
          for (var i = 0; i < 65; i++)
            FakeEmbyItem(
              id: 'movie-$i',
              name: 'Film ${i.toString().padLeft(2, '0')}',
              type: 'Movie',
              parentId: 'view-movies',
            ),
        ];
        await browse.load();
        expect(browse.items, hasLength(BrowseController.pageSize));
        server.itemsStatus = 503;
        await browse.load(more: true);
        expect(browse.items, hasLength(BrowseController.pageSize));
        expect(browse.error, isNotNull);
        expect(browse.hasMore, isTrue);
      },
    );

    testWidgets(
      'library title, poster grid, filters and four sorts follow the library',
      (tester) async {
        final harness = await _start(tester);
        await _openMovies(tester);
        expect(
          tester
              .widget<Text>(find.byKey(const Key('phone-library-title')))
              .data,
          '电影',
        );
        final arts = tester
            .renderObjectList<RenderBox>(
              find.byWidgetPredicate((widget) {
                final key = widget.key;
                return key is ValueKey<String> &&
                    key.value.startsWith('phone-library-art-');
              }),
            )
            .toList();
        expect(arts.length, greaterThanOrEqualTo(3));
        final width = arts.first.size.width;
        expect(width, closeTo((360 - 32 - 2 * 16) / 3, 1));
        expect(
          arts.every((box) => (box.size.width - width).abs() < 0.5),
          isTrue,
        );
        expect(
          arts.every((box) => (box.size.height - width * 1.5).abs() < 0.5),
          isTrue,
        );
        final columns = arts
            .map((box) => box.localToGlobal(Offset.zero).dx.round())
            .toSet();
        expect(columns.length, 3);
        expect(find.byType(MobilePressable), findsWidgets);
        final poster = tester.widget<DecoratedBox>(
          find
              .descendant(
                of: find.byKey(
                  const ValueKey('phone-library-art-movie-inception'),
                ),
                matching: find.byType(DecoratedBox),
              )
              .first,
        );
        final shadow = poster.decoration as BoxDecoration;
        expect(shadow.boxShadow!.single.blurRadius, AppMobileCard.shadowBlur);
        expect(shadow.borderRadius, BorderRadius.circular(AppRadii.md));
        final progress = tester.widget<LinearProgressIndicator>(
          find.byKey(const ValueKey('phone-library-progress-movie-inception')),
        );
        expect(progress.value, closeTo(0.4, 0.001));
        expect(
          find.byKey(const ValueKey('phone-library-progress-movie-up')),
          findsNothing,
        );

        await _openFilters(tester);
        expect(find.text('更新日期'), findsWidgets);
        expect(find.text('加入日期'), findsOneWidget);
        expect(find.text('标题'), findsOneWidget);
        expect(find.text('出品年份'), findsOneWidget);
        expect(find.text('IMDb评分'), findsOneWidget);
        expect(find.text('随机'), findsOneWidget);
        expect(find.text('首映日期'), findsNothing);
        expect(
          find.byKey(const Key('phone-library-year-section')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('phone-library-genre-section')),
          findsNothing,
        );
        expect(find.text('流派'), findsNothing);

        await _libraryTap(tester, const Key('phone-library-watch-IsUnplayed'));
        await _libraryTap(tester, const Key('phone-library-sort-DateCreated'));
        await _libraryTap(tester, const Key('phone-library-year-2010'));
        await _libraryTap(tester, const Key('phone-library-apply'));
        expect(find.text('加入日期'), findsOneWidget);
        expect(find.text('未看'), findsOneWidget);
        expect(
          find.byKey(const Key('phone-library-active-year')),
          findsOneWidget,
        );
        final recent = _lastItemsQuery(harness.server);
        expect(recent, contains('SortBy=DateCreated'));
        expect(recent, contains('SortOrder=Descending'));
        expect(recent, contains('Filters=IsUnplayed'));
        expect(recent, contains('Years=2010'));
        expect(recent, isNot(contains('Random')));

        await _openFilters(tester);
        await _libraryTap(
          tester,
          const Key('phone-library-sort-ProductionYear'),
        );
        await _libraryTap(
          tester,
          const Key('phone-library-sort-CommunityRating'),
        );
        await _libraryTap(tester, const Key('phone-library-apply'));
        expect(find.text('IMDb评分'), findsOneWidget);
        expect(
          _lastItemsQuery(harness.server),
          contains('SortBy=CommunityRating'),
        );

        await _openFilters(tester);
        await _libraryTap(
          tester,
          const Key('phone-library-sort-ProductionYear'),
        );
        await _libraryTap(tester, const Key('phone-library-apply'));
        expect(find.text('出品年份'), findsOneWidget);
        final premiere = _lastItemsQuery(harness.server);
        expect(premiere, contains('SortBy=ProductionYear'));
        expect(premiere, contains('SortOrder=Descending'));
        expect(premiere, contains('Years=2010'));

        await _libraryTap(tester, const Key('phone-library-reset'));
        expect(find.text('出品年份'), findsNothing);
        expect(
          find.byKey(const Key('phone-library-active-watch')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('phone-library-active-year')),
          findsNothing,
        );
        final cleared = _lastItemsQuery(harness.server);
        expect(cleared, contains('SortBy=DateLastContentAdded'));
        expect(cleared, contains('SortOrder=Descending'));
        expect(cleared, contains('IncludeItemTypes=Movie,Series'));
        expect(cleared, isNot(contains('Years=')));
        expect(cleared, isNot(contains('Filters=')));
        expect(tester.takeException(), isNull);
      },
      tags: ['integration'],
    );

    testWidgets('library watch filter stays in the filter sheet', (
      tester,
    ) async {
      final harness = await _start(tester);
      await _openMovies(tester);
      expect(
        find.byKey(const Key('phone-library-watch-chip-all')),
        findsNothing,
      );
      await _openFilters(tester);
      await _libraryTap(tester, const Key('phone-library-watch-IsUnplayed'));
      await _libraryTap(tester, const Key('phone-library-apply'));
      expect(_lastItemsQuery(harness.server), contains('Filters=IsUnplayed'));
      expect(tester.takeException(), isNull);
    }, tags: ['integration']);

    testWidgets('genre filter appears only when the server has genres', (
      tester,
    ) async {
      final harness = await _start(tester);
      harness.dio.interceptors.add(
        InterceptorsWrapper(
          onResponse: (response, handler) {
            final data = response.data;
            if (data is Map) {
              final items = data['Items'];
              if (items is List) {
                for (final raw in items) {
                  if (raw is Map && raw['Type'] == 'Movie') {
                    raw['Genres'] = <String>['SciFi'];
                  }
                }
              }
            }
            handler.next(response);
          },
        ),
      );
      await _openMovies(tester);
      await _openFilters(tester);
      expect(
        find.byKey(const Key('phone-library-genre-section')),
        findsOneWidget,
      );
      expect(find.text('流派'), findsOneWidget);
      await _libraryTap(tester, const Key('phone-library-genre-SciFi'));
      await _libraryTap(tester, const Key('phone-library-apply'));
      expect(find.text('SciFi'), findsOneWidget);
      expect(_lastItemsQuery(harness.server), contains('Genres=SciFi'));
      expect(tester.takeException(), isNull);
    }, tags: ['integration']);

    testWidgets('an empty filter result is not a load failure', (tester) async {
      final harness = await _start(tester);
      await _openMovies(tester);
      await _openFilters(tester);
      await _libraryTap(tester, const Key('phone-library-type-Series'));
      await _libraryTap(tester, const Key('phone-library-apply'));
      expect(find.byType(MobileEmptyState), findsOneWidget);
      expect(find.text('暂无内容'), findsOneWidget);
      expect(find.text('清除筛选'), findsOneWidget);
      expect(find.byType(MobileFailureState), findsNothing);
      expect(find.text('重试'), findsNothing);
      expect(find.text('Inception'), findsNothing);
      expect(
        _lastItemsQuery(harness.server),
        contains('IncludeItemTypes=Series'),
      );

      await tester.tap(find.byKey(MobileEmptyState.actionKey));
      await tester.pumpAndSettle();
      expect(find.text('Inception'), findsOneWidget);
      expect(find.byType(MobileEmptyState), findsNothing);
      final cleared = _lastItemsQuery(harness.server);
      expect(cleared, contains('IncludeItemTypes=Movie,Series'));
      expect(cleared, contains('SortBy=DateLastContentAdded'));
      expect(tester.takeException(), isNull);
    }, tags: ['integration']);

    testWidgets('an empty library and a failed load are different screens', (
      tester,
    ) async {
      final harness = await _start(tester);
      harness.server.items = [];
      await _openMovies(tester);
      expect(find.byType(MobileEmptyState), findsOneWidget);
      expect(find.text('暂无内容'), findsOneWidget);
      expect(find.text('刷新'), findsOneWidget);
      expect(find.byType(MobileFailureState), findsNothing);
      expect(find.text('重试'), findsNothing);

      harness.server.itemsStatus = 503;
      await tester.tap(find.byKey(MobileEmptyState.actionKey));
      await tester.pumpAndSettle();
      expect(find.byType(MobileFailureState), findsOneWidget);
      expect(find.textContaining('503'), findsOneWidget);
      expect(find.byType(MobileEmptyState), findsNothing);
      expect(find.text('暂无内容'), findsNothing);
      expect(find.text('重试'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, tags: ['integration']);
  });

  group('phone_mine_test.dart', () {
    testWidgets(
      'current identity stays visible; a line switch reloads catalog or fails loudly',
      (tester) async {
        final lineA = FakeEmbyServer(
          serverName: '家庭影院',
          baseUrl: Uri.parse('http://line-a.test:8096'),
          items: [_mineMovie('movie-a', '甲线电影')],
        );
        final lineB = FakeEmbyServer(
          serverId: lineA.serverId,
          serverName: '家庭影院',
          baseUrl: Uri.parse('http://line-b.test:8096'),
          items: [_mineMovie('movie-b', '乙线电影')],
        );
        final auth = _auth([lineA, lineB]);
        addTearDown(auth.dispose);
        await _connect(tester, auth, lineA.baseUrl.toString());
        await _connect(tester, auth, lineB.baseUrl.toString());
        final catalog = CatalogController(auth: auth)
          ..cache.debugSetDiskStore(null);
        addTearDown(catalog.dispose);
        await tester.runAsync(catalog.reload);
        expect(catalog.latestMovies.items.map((item) => item.name), ['乙线电影']);

        await _pump(tester, auth: auth, catalog: catalog);
        expect(find.text('alice'), findsOneWidget);
        expect(find.text('家庭影院'), findsOneWidget);
        expect(find.text('line-b.test:8096'), findsOneWidget);
        expect(find.text('账户与服务器'), findsOneWidget);
        expect(find.text('播放设置'), findsOneWidget);
        expect(find.text('我的'), findsWidgets);
        expect(
          tester.getTopLeft(find.byKey(PhoneMinePage.userKey)).dy,
          lessThan(tester.getTopLeft(find.byKey(PhoneMinePage.serverKey)).dy),
        );
        expect(
          tester.getTopLeft(find.byKey(PhoneMinePage.currentLineKey)).dy,
          lessThan(tester.getTopLeft(find.text('退出登录')).dy),
        );
        expect(
          tester.getTopLeft(find.text('退出登录')).dy,
          lessThan(tester.getTopLeft(find.text('播放速度')).dy),
        );

        final target = auth.savedServers.single.lines.firstWhere(
          (line) => line.address == lineA.baseUrl.toString(),
        );
        final before = _itemRequests(lineA);
        await _mineTap(tester, find.byKey(PhoneMinePage.lineKey));
        final option = find.byKey(PhoneMinePage.lineOptionKey(target.id));
        expect(tester.widget<ListTile>(option).selected, isFalse);
        await _mineTap(tester, option);
        await _mineUntil(
          tester,
          () => catalog.latestMovies.items.any((item) => item.name == '甲线电影'),
        );

        expect(auth.client.baseUrl, lineA.baseUrl);
        expect(_itemRequests(lineA), greaterThan(before));
        expect(catalog.latestMovies.items.map((item) => item.name), ['甲线电影']);
        await _scrollToTop(tester);
        expect(find.text('line-a.test:8096'), findsOneWidget);
        expect(find.text('line-b.test:8096'), findsNothing);
        await _mineTap(tester, find.byKey(PhoneMinePage.lineKey));
        expect(
          tester
              .widget<ListTile>(
                find.byKey(PhoneMinePage.lineOptionKey(target.id)),
              )
              .selected,
          isTrue,
        );

        // 失败的线路切换保持当前线路与已加载目录,并解释原因。
        final lineBTarget = auth.savedServers.single.lines.firstWhere(
          (line) => line.address == lineB.baseUrl.toString(),
        );
        lineB.publicInfoStatus = 500;
        lineB.publicInfoRawBody = 'upstream timeout';
        final beforeFail = _itemRequests(lineB);
        await _mineTap(
          tester,
          find.byKey(PhoneMinePage.lineOptionKey(lineBTarget.id)),
        );

        // 失败提示在头部下方:先滚回列表顶部。
        await _scrollToTop(tester);
        expect(find.text('HTTP 500: upstream timeout'), findsOneWidget);
        expect(auth.session, isNull);
        expect(
          auth.savedServers.single.activeLine?.address,
          lineA.baseUrl.toString(),
        );
        expect(catalog.latestMovies.items.map((item) => item.name), ['甲线电影']);
        expect(_itemRequests(lineB), beforeFail);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('playback rate merges and the next playback uses it', (
      tester,
    ) async {
      final server = FakeEmbyServer();
      final auth = _auth([server]);
      addTearDown(auth.dispose);
      await _connect(tester, auth, server.baseUrl.toString());
      final store = MemoryPlayerSettingsStore(
        const PlayerSettings(
          volume: 40,
          playbackRate: 1,
          diskCacheLimitMiB: 2048,
          hardwareDecoding: HardwareDecodingMode.off,
          hardwareDecoder: HardwareDecoderBackend.nvdec,
          danmakuServer: 'https://keep.example',
          danmakuAppId: 'app-keep',
          danmakuToken: 'tok-keep',
        ),
      );
      await _pump(tester, auth: auth, store: store);

      expect(find.text('解码后端'), findsNothing);
      expect(find.text('硬件解码'), findsNothing);
      // 磁盘缓冲上限已收进"我的-缓存"分组,只读当前值、不暴露桌面解码项。
      await _scrollTo(tester, find.text('磁盘缓冲上限'));
      expect(find.text('磁盘缓冲上限'), findsOneWidget);
      await _mineTap(tester, find.byKey(PhoneMinePage.rateKey(1.5)));

      final saved = await store.read();
      expect(saved.playbackRate, 1.5);
      expect(saved.volume, 40);
      expect(saved.diskCacheLimitMiB, 2048);
      expect(saved.hardwareDecoding, HardwareDecodingMode.off);
      expect(saved.hardwareDecoder, HardwareDecoderBackend.nvdec);
      expect(saved.danmakuServer, 'https://keep.example');
      expect(saved.danmakuAppId, 'app-keep');
      expect(saved.danmakuToken, 'tok-keep');

      final backend = FakeVideoBackend();
      final window = PlayerWindow();
      final controller = PlayerController(
        client: auth.client,
        itemId: 'movie-inception',
        backend: backend,
        window: window,
        settingsStore: store,
        snapshotStore: MemoryPlaybackSessionSnapshotStore(),
        stoppedTimeout: const Duration(milliseconds: 20),
      );
      addTearDown(
        () => tester.runAsync(() async {
          await controller.disposeAsync();
          controller.dispose();
          window.dispose();
          await backend.dispose();
        }),
      );
      await tester.runAsync(controller.start);
      expect(controller.playbackRate, 1.5);
      expect(backend.rate, 1.5);
      expect(backend.volume, 40);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'custom danmaku address can be filled and cleared to official',
      (tester) async {
        final server = FakeEmbyServer();
        final auth = _auth([server]);
        addTearDown(auth.dispose);
        await _connect(tester, auth, server.baseUrl.toString());
        final store = MemoryPlayerSettingsStore(
          const PlayerSettings(
            volume: 40,
            playbackRate: 1.25,
            danmakuAppId: 'app-keep',
            danmakuToken: 'tok-keep',
          ),
        );
        await _pump(tester, auth: auth, store: store);

        expect(find.text('留空使用官方源'), findsOneWidget);
        expect(
          tester
              .widget<TextField>(find.byKey(PhoneMinePage.danmakuTokenKey))
              .obscureText,
          isTrue,
        );
        await _mineTap(tester, find.byKey(PhoneMinePage.tokenVisibilityKey));
        expect(
          tester
              .widget<TextField>(find.byKey(PhoneMinePage.danmakuTokenKey))
              .obscureText,
          isFalse,
        );
        expect(find.byTooltip('隐藏令牌'), findsOneWidget);

        await _enter(
          tester,
          PhoneMinePage.danmakuServerKey,
          'https://dan.example',
        );
        final custom = _CaptureDanmakuClient();
        final customDanmaku = DanmakuController(
          settingsStore: store,
          client: custom,
        );
        addTearDown(customDanmaku.dispose);
        await _mineUntil(
          tester,
          () => customDanmaku.customServerUrl == 'https://dan.example',
        );
        expect(customDanmaku.usesCustomSource, isTrue);
        await tester.runAsync(() => customDanmaku.search('示例'));
        expect(custom.source?.isCustom, isTrue);
        expect(custom.source?.baseUri.host, 'dan.example');

        await _enter(tester, PhoneMinePage.danmakuServerKey, '');
        final saved = await store.read();
        expect(saved.danmakuServer, '');
        expect(saved.danmakuAppId, 'app-keep');
        expect(saved.danmakuToken, 'tok-keep');
        expect(saved.volume, 40);
        expect(saved.playbackRate, 1.25);

        final official = _CaptureDanmakuClient();
        final officialDanmaku = DanmakuController(
          settingsStore: store,
          client: official,
        );
        addTearDown(officialDanmaku.dispose);
        await _mineUntil(
          tester,
          () =>
              officialDanmaku.hasOfficialCredentials &&
              !officialDanmaku.usesCustomSource,
        );
        await tester.runAsync(() => officialDanmaku.search('示例'));
        expect(official.source?.isCustom, isFalse);
        expect(official.source?.baseUri.host, 'api.dandanplay.net');
        expect(tester.takeException(), isNull);
      },
    );
  });
}

Widget _harness(AuthController auth, {int generation = 0}) {
  return AuthScope(
    controller: auth,
    child: MaterialApp(
      locale: const Locale('zh', 'CN'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: AndroidConnectPage(key: ValueKey(generation)),
    ),
  );
}

CatalogController _catalog({
  required List<EmbyItem> resume,
  required List<EmbyItem> movies,
  required List<EmbyItem> series,
}) {
  final catalog = CatalogController(auth: AuthController.memory());
  catalog.resume = CatalogRowState(items: resume);
  catalog.nextUp = const CatalogRowState(hidden: true);
  catalog.latestMovies = CatalogRowState(items: movies);
  catalog.latestSeries = CatalogRowState(items: series);
  catalog.librariesLoading = false;
  return catalog;
}

EmbyItem _item(
  String id,
  String name,
  String type, {
  double? percent,
  String? seriesName,
}) {
  return EmbyItem(
    id: id,
    name: name,
    type: type,
    seriesName: seriesName,
    userData: percent == null
        ? const EmbyUserData()
        : EmbyUserData(playbackPositionTicks: 1, playedPercentage: percent),
  );
}

EmbyItem _homeMovie(String id, String name, {double? percent}) {
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

Future<void> _homeSettle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _showOnHome(WidgetTester tester, Finder finder) async {
  final list = find.byKey(const PageStorageKey('mobile-home-scroll'));
  for (var i = 0; i < 8; i++) {
    final top = tester.getTopLeft(finder).dy;
    // 顶栏/AppBar 会压住滚动区上缘,留出余量再停。
    if (top >= 96 && top < 640) {
      return;
    }
    await tester.drag(list, Offset(0, top > 640 ? -350 : 350));
    await tester.pump();
  }
}

void _usePhoneSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget _scriptedApp(CatalogController catalog, {required GoRouter router}) {
  return MaterialApp.router(
    theme: AppTheme.dark(),
    locale: const Locale('zh'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    routerConfig: router,
  );
}

GoRouter _router(CatalogController catalog) {
  return GoRouter(
    initialLocation: AppRoutes.home,
    routes: [
      ShellRoute(
        builder: (context, state, child) {
          return CatalogScope(controller: catalog, child: child);
        },
        routes: [
          GoRoute(
            path: AppRoutes.home,
            builder: (context, state) => const PhoneHome(),
          ),
          GoRoute(
            path: '/item/:itemId',
            builder: (context, state) {
              final id = state.pathParameters['itemId']!;
              return Scaffold(body: Text('详情 $id'));
            },
          ),
          GoRoute(
            path: '/play/:itemId',
            builder: (context, state) {
              return Text('播放 ${state.pathParameters['itemId']}');
            },
          ),
        ],
      ),
    ],
  );
}

bool _inside(Rect inner, Rect outer) {
  return inner.left >= outer.left - 0.5 &&
      inner.top >= outer.top - 0.5 &&
      inner.right <= outer.right + 0.5 &&
      inner.bottom <= outer.bottom + 0.5;
}

void _addShelfMovies(FakeEmbyServer server) {
  for (var i = 0; i < phoneHomeRowLimit; i++) {
    final added = DateTime.utc(2030, 1, 1).add(Duration(days: i));
    server.items.add(
      FakeEmbyItem(
        id: 'movie-new-$i',
        name: '新片 $i',
        type: 'Movie',
        parentId: 'view-movies',
        dateCreated: added,
        dateLastContentAdded: added,
      ),
    );
  }
  server.items.add(
    FakeEmbyItem(
      id: 'movie-cold',
      name: '冷门电影',
      type: 'Movie',
      parentId: 'view-movies',
      dateCreated: DateTime.utc(2001, 1, 1),
      dateLastContentAdded: DateTime.utc(2001, 1, 1),
    ),
  );
}

Future<(GoRouter, FakeEmbyServer)> _openPhone(
  WidgetTester tester, {
  void Function(FakeEmbyServer server)? prepare,
  bool reduceMotion = true,
}) async {
  _usePhoneSurface(tester);
  if (reduceMotion) {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  }
  final server = FakeEmbyServer();
  prepare?.call(server);
  final auth = AuthController.memory(
    client: EmbyClient(
      device: _homeDevice,
      dio: dioForFakeEmby(FakeEmbyAdapter([server])),
    ),
  );
  addTearDown(auth.dispose);
  await tester.runAsync(() async {
    await auth.connect(
      address: server.baseUrl.toString(),
      username: 'alice',
      password: 'correct-horse',
    );
  });
  final router = createAppRouter(
    auth: auth,
    environment: PresentationEnvironment.phone,
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    AuthScope(
      controller: auth,
      child: MaterialApp.router(
        theme: AppTheme.dark(),
        locale: const Locale('zh'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        routerConfig: router,
      ),
    ),
  );
  await _homeSettle(tester);
  return (router, server);
}

// ---- Hero/动效专用 harness(自 phone_motion_test 并入) ----

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

Future<void> _pumpMotionHome(
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
      device: _homeDevice,
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
      _homeMovie('movie-inception', 'Inception', percent: 40),
      _homeMovie('movie-up', '飞屋环游记'),
    ],
  );
  catalog.nextUp = const CatalogRowState(hidden: true);
  catalog.latestMovies = CatalogRowState(
    items: [
      _homeMovie('movie-inception', 'Inception', percent: 40),
      _homeMovie('movie-up', '飞屋环游记'),
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
}

Future<void> _homeUntil(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 20; i++) {
    if (finder.evaluate().isNotEmpty) {
      return;
    }
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(finder, findsWidgets);
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

String _lastItemsQuery(FakeEmbyServer server) {
  return Uri.decodeQueryComponent(
    server.requests.lastWhere((line) => line.contains('/Items?')),
  );
}

Future<void> _openMovies(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('phone-library-block-view-movies')));
  await tester.pumpAndSettle();
}

Future<void> _openFilters(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('phone-library-filter')));
  await tester.pumpAndSettle();
}

Future<void> _libraryTap(WidgetTester tester, Key key) async {
  final finder = find.byKey(key);
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

class _Harness {
  const _Harness({required this.server, required this.dio});

  final FakeEmbyServer server;
  final Dio dio;
}

Future<_Harness> _start(
  WidgetTester tester, {
  void Function(FakeEmbyServer server)? prepare,
}) async {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final server = FakeEmbyServer();
  server.failingImageIds.clear();
  prepare?.call(server);
  final dio = dioForFakeEmby(FakeEmbyAdapter([server]));
  final auth = AuthController.memory(
    client: EmbyClient(device: _libraryDevice, dio: dio),
  );
  final catalog = CatalogController(
    auth: auth,
    cache: CatalogCache()..debugSetDiskStore(null),
  );
  // 假异步不会自己推进连接计时器，先在真实异步里完成登录和目录。
  await tester.runAsync(() async {
    await auth.connect(
      address: server.baseUrl.toString(),
      username: 'alice',
      password: 'correct-horse',
    );
    await catalog.reload();
  });
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const PhoneLibrariesTab(),
      ),
      GoRoute(
        path: '/library/:viewId',
        builder: (context, state) =>
            MobileLibraryPage(viewId: state.pathParameters['viewId']!),
      ),
    ],
  );
  addTearDown(auth.dispose);
  addTearDown(catalog.dispose);
  addTearDown(router.dispose);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
  });
  await tester.pumpWidget(
    MaterialApp.router(
      theme: AppTheme.dark(),
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      routerConfig: router,
      builder: (context, child) {
        return AuthScope(
          controller: auth,
          child: CatalogScope(
            controller: catalog,
            child: child ?? const SizedBox.shrink(),
          ),
        );
      },
    ),
  );
  await tester.pumpAndSettle();
  return _Harness(server: server, dio: dio);
}

FakeEmbyItem _mineMovie(String id, String name) {
  return FakeEmbyItem(
    id: id,
    name: name,
    type: 'Movie',
    parentId: 'view-movies',
  );
}

AuthController _auth(List<FakeEmbyServer> servers) {
  return AuthController.memory(
    client: EmbyClient(
      device: _mineDevice,
      dio: dioForFakeEmby(FakeEmbyAdapter(servers)),
    ),
  );
}

Future<void> _connect(
  WidgetTester tester,
  AuthController auth,
  String address,
) {
  return tester
      .runAsync(
        () => auth.connect(
          address: address,
          username: 'alice',
          password: 'correct-horse',
        ),
      )
      .then((_) {});
}

int _itemRequests(FakeEmbyServer server) {
  return server.requests.where((request) => request.contains('/Items')).length;
}

Future<void> _pump(
  WidgetTester tester, {
  required AuthController auth,
  PlayerSettingsStore? store,
  CatalogController? catalog,
}) async {
  tester.view.physicalSize = const Size(360, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final page = catalog == null
      ? const PhoneMinePage()
      : CatalogScope(controller: catalog, child: const PhoneMinePage());
  await tester.pumpWidget(
    AuthScope(
      controller: auth,
      child: PlayerScope(
        bindings: PlayerBindings(
          settingsStore: store ?? MemoryPlayerSettingsStore(),
        ),
        child: MaterialApp(
          theme: AppTheme.dark(),
          locale: const Locale('zh'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: Scaffold(body: page),
        ),
      ),
    ),
  );
  await _mineSettle(tester);
}

Future<void> _mineSettle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Finder _mineScrollable(WidgetTester tester) {
  // 首个为 ListView 自身纵向 Scrollable;其后是 TextField 横向滚动条。
  return find
      .descendant(
        of: find.byKey(const PageStorageKey('mobile-mine-scroll')),
        matching: find.byType(Scrollable),
      )
      .first;
}

/// 向下滚动"我的"列表,直到 [finder] 出现(懒加载 build)。
Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 25 && finder.evaluate().isEmpty; i++) {
    await tester.drag(_mineScrollable(tester), const Offset(0, -250));
    await _mineSettle(tester);
  }
  expect(finder, findsWidgets);
}

/// 滚回列表顶部(头部信息在首屏之上时懒加载不可见)。
Future<void> _scrollToTop(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.drag(_mineScrollable(tester), const Offset(0, 400));
    await _mineSettle(tester);
  }
}

Future<void> _mineTap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await _mineSettle(tester);
  await tester.tap(finder);
  await _mineSettle(tester);
}

Future<void> _enter(WidgetTester tester, Key key, String value) async {
  final finder = find.byKey(key);
  await tester.ensureVisible(finder);
  await _mineSettle(tester);
  await tester.enterText(finder, value);
  await tester.testTextInput.receiveAction(TextInputAction.done);
  FocusManager.instance.primaryFocus?.unfocus();
  await _mineSettle(tester);
}

Future<void> _mineUntil(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 40 && !ready(); i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(ready(), isTrue);
}

class _CaptureDanmakuClient extends DandanplayClient {
  DandanplaySource? source;

  @override
  Future<List<DanmakuAnime>> searchEpisodes(
    DandanplaySource source, {
    required String anime,
    int? episode,
    CancelToken? cancelToken,
  }) async {
    this.source = source;
    return [
      DanmakuAnime(
        animeId: 7,
        animeTitle: anime,
        episodes: const [DanmakuEpisode(episodeId: 8, episodeTitle: '1')],
      ),
    ];
  }
}
