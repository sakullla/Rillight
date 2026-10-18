import '../../test/helpers/cupertino_test_app.dart';

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/app_shell.dart';
import 'package:rillight/app/file_import.dart';
import 'package:rillight/app/phone_mine_page.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/settings/settings_page.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/backup_import/backup_import_flow.dart';
import 'package:rillight/auth/backup_import/backup_import_models.dart';
import 'package:rillight/auth/change_password_dialog.dart';
import 'package:rillight/auth/connect_page.dart';
import 'package:rillight/auth/phone_server_manager.dart';
import 'package:rillight/auth/server_switcher_dialog.dart';
import 'package:rillight/auth/session_actions.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/library/detail_extras.dart';
import 'package:rillight/library/episode_detail_sections.dart';
import 'package:rillight/library/item_detail_page.dart';
import 'package:rillight/library/mobile_detail_page.dart';
import 'package:rillight/search/search_overlay.dart';
import 'package:rillight/player/player_host_command.dart';
import 'package:rillight/aggregation/identity/media_identity.dart';

import '../../test/auth/backup_import/backup_import_cases.dart';
import '../../test/emby/fake_emby_server.dart';
import 'capture.dart';
import 'fixtures.dart';

extension PageCaptures on CaptureSession {
  Future<void> activate(Finder finder) async {
    expect(finder, findsOneWidget);
    await Scrollable.ensureVisible(tester.element(finder), alignment: .5);
    await advance(100);
    await tester.tap(finder);
    await advance(400);
  }

  /// 点开 [TvInput]，写入编辑框，再按完成回到原对话框。
  Future<void> _editTvField(Key field, String text) async {
    await activate(find.byKey(field));
    final editor = find.byKey(const Key('tv-input-editor'));
    expect(editor, findsOneWidget);
    await tester.enterText(editor, text);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await advance(350);
  }

  Future<void> dismiss() async {
    final barriers = find.byWidgetPredicate(
      (widget) => widget is ModalBarrier && widget.dismissible,
    );
    if (barriers.evaluate().isNotEmpty) {
      // AppShell 会先吃掉 Escape;屏障四角又可能被窗口 chrome 或
      // 弹出层本体盖住。让承载屏障的 Navigator 弹出顶层路由,
      // 与真实关闭路径等价且不受遮挡影响。
      final barrier = barriers.last;
      final dismissedElement = tester.element(barrier);
      final navigator = Navigator.maybeOf(dismissedElement);
      expect(navigator, isNotNull);
      await navigator!.maybePop();
      await advance(350);
      expect(
        dismissedElement.mounted,
        isFalse,
        reason: 'Capture must close the top modal (a parent may remain)',
      );
    } else {
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await advance(350);
    }
  }

  Future<void> route(RillightApp app, String path, String name) async {
    app.router.go(path);
    await advance(900);
    await save(name);
  }

  Future<void> modal(Key key, String name) async {
    await tap(key);
    await save(name);
    await dismiss();
  }

  Future<void> pages(
    RillightApp app,
    AuthController auth,
    FakeEmbyServer server,
    CaptureAdapter adapter,
  ) async {
    if (wants('aggregation')) {
      app.router.go('/');
      await advance(700);
      if (platform == 'desktop') {
        await tap(const Key('app-shell-aggregation'));
      } else if (platform == 'phone') {
        await activate(
          find.descendant(
            of: find.byType(CupertinoTabBar),
            matching: find.text('聚合'),
          ),
        );
      } else {
        await tap(const ValueKey('tv-nav-1'));
      }
      await advance(1200);
      await save('aggregation-ready');
      // TV 聚合页是分段 + 卡片行的新版本,没有来源管理与私密区入口。
      if (platform != 'tv') {
        await tap(const Key('aggregation-source-management'));
        await save('aggregation-management');
        await activate(find.widgetWithText(AppListTile, '私密区域'));
        await save('aggregation-pin-setup');
        await tester.enterText(find.byKey(const Key('private-pin')), '1234');
        await tester.enterText(
          find.byKey(const Key('private-pin-confirm')),
          '5678',
        );
        await tap(const Key('private-unlock'));
        await save('aggregation-pin-error');
        await tap(const Key('private-pin-cancel'));
        await tap(const Key('source-management-close'));
        await tap(const Key('aggregation-segment-favorites'));
        await save('aggregation-segment-favorites');
        await tap(const Key('aggregation-segment-libraries'));
        await save('aggregation-segment-libraries');
        // 来源裁剪/同源比较只在旧版跨服务器聚合页上,从命令路由进入。
        final sources = auth.sources.project(AccessRegion.ordinary);
        final account = (await tester.runAsync(
          () async =>
              (await auth.sources.authenticate(sources.first.id)).account,
        ))!;
        app.router.go(
          '/shelf/items',
          extra: PlayerHostOpenItemCommand(
            itemId: 'movie-up',
            source: SourceReference(account: account, itemId: 'movie-up'),
            libraryId: 'view-movies',
            regionGeneration: auth.regionAccess.generation,
          ),
        );
        await advance(1200);
        await activate(find.widgetWithText(AppChoiceChip, '全部普通来源'));
        await advance(600);
        await activate(
          find.byKey(ValueKey('aggregation-source-${sources.last.id}')),
        );
        await advance(600);
        await save('aggregation-single-source');
        await activate(
          find.byKey(ValueKey('aggregation-source-${sources.first.id}')),
        );
        await save('aggregation-empty-scope');
        await activate(find.widgetWithText(AppChoiceChip, '全部普通来源'));
        await advance(900);
        await activate(find.widgetWithText(AppButton, '查找同源 · 2').first);
        await advance(900);
        await save('aggregation-comparison');
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await advance(350);
        adapter.failAggregationMirror = true;
        await activate(find.widgetWithText(AppChoiceChip, '全部普通来源'));
        await advance(1000);
        await save('aggregation-partial-failure');
        adapter.failAggregationMirror = false;
        if (platform == 'phone') {
          // /aggregation 只有桌面路由;先回首页再经底部导航进聚合页。
          app.router.go('/');
          await advance(900);
          await activate(
            find.descendant(
              of: find.byType(CupertinoTabBar),
              matching: find.text('聚合'),
            ),
          );
        } else {
          app.router.go('/aggregation');
          await advance(900);
        }
        await tap(const Key('aggregation-segment-continue'));
      }
      if (platform == 'desktop') {
        app.router.go('/search');
        await advance(700);
      } else if (platform == 'phone') {
        await activate(
          find.descendant(
            of: find.byType(CupertinoTabBar),
            matching: find.text('搜索'),
          ),
        );
      } else {
        await tap(const ValueKey('tv-nav-2'));
      }
      if (platform == 'tv') {
        await activate(find.byKey(const Key('aggregation-keyword')));
        await tester.enterText(find.byKey(const Key('tv-input-editor')), '飞屋');
        await tester.testTextInput.receiveAction(TextInputAction.done);
      } else {
        await tester.enterText(
          find.byKey(const Key('aggregation-keyword')),
          '飞屋',
        );
      }
      await advance(900);
      await save('aggregation-search-single');
      app.router.go('/');
      await advance(400);
      if (platform == 'phone') {
        await activate(
          find.descendant(
            of: find.byType(CupertinoTabBar),
            matching: find.text('首页'),
          ),
        );
      }
      if (platform == 'tv') await tap(const ValueKey('tv-nav-0'));
    }
    if (wants('home') || wants('library')) {
      await route(app, '/', 'home-return');
      if (platform == 'desktop') {
        await tap(AppShell.overflowNavKey);
        await save('home-display');
        await dismiss();
        await tap(AppShell.librariesNavKey);
        await save('home-libraries-menu');
        await dismiss();
        final homeScroll = find
            .descendant(
              of: find.byKey(const PageStorageKey('home-scroll')),
              matching: find.byType(Scrollable),
            )
            .first;
        tester.state<ScrollableState>(homeScroll).position.jumpTo(0);
        await advance(100);
        await tester.scrollUntilVisible(
          find.byKey(CatalogKeys.librariesMenu),
          320,
          scrollable: homeScroll,
        );
        await advance(300);
        await save('library-list');
      } else if (platform == 'phone') {
        await tap(const Key('phone-home-edit'));
        await save('home-customize');
        app.router.pop();
        await advance(400);
        // 手机「媒体库」标签页:快速入口与全部媒体库磁贴。
        await activate(
          find.descendant(
            of: find.byType(CupertinoTabBar),
            matching: find.text('媒体库'),
          ),
        );
        await save('library-list');
      } else {
        await tap(const ValueKey('tv-nav-1'));
        await save('library-list');
      }
    }
    if (wants('library')) {
      await route(app, '/library/view-movies', 'library-movies');
      if (platform == 'tv') {
        await filterStates(const Key('tv-library-filter'), 'tv-library');
      } else {
        await aggregationFilterStates();
      }
      await route(app, '/library/view-tv', 'library-series');
      await route(app, '/shelf/resume', 'shelf-continue-watching');
      await route(app, '/shelf/nextup', 'shelf-next-up');
      await route(app, '/shelf/latest-movies', 'shelf-latest-movies');
      await route(app, '/shelf/latest-series', 'shelf-latest-series');
    }
    if (wants('detail')) {
      await route(app, '/item/series-friends', 'series-detail');
      if (platform == 'phone') {
        await tap(CatalogKeys.season('season-friends-2'));
        await save('series-second-season-artwork');
        await tap(CatalogKeys.season('season-friends-1'));
        await save('series-first-season-artwork');
      }

      if (platform == 'desktop') {
        await modal(CatalogKeys.seasonPicker, 'series-season-picker');
      }
      await route(
        app,
        '/item/series-friends?season=season-friends-1',
        'season-detail',
      );
      final episodeArea = switch (platform) {
        'desktop' => find.byKey(CatalogKeys.episodesRow),
        // 手机的分区标题行（剧集 + 选集）在季标签和本季概况上方。
        'phone' => find.byKey(CatalogKeys.locateEpisode),
        _ => find.byKey(const Key('tv-detail-episodes')),
      };
      if (episodeArea.evaluate().isNotEmpty) {
        if (platform == 'phone') {
          // 顶栏会盖住贴顶的标题行，留出顶栏高度再对齐。
          await Scrollable.ensureVisible(
            tester.element(episodeArea.first),
            alignment: 0.15,
          );
        } else {
          await tester.ensureVisible(episodeArea.first);
        }
        await advance(300);
        await save('season-episodes');
      }
      if (platform != 'tv') {
        await modal(CatalogKeys.locateEpisode, 'season-episode-picker');
      }
      if (platform == 'desktop') {
        final row = find.byKey(CatalogKeys.episode('episode-friends-s1e2'));
        await tester.ensureVisible(row);
        await advance(100);
        await tester.tap(row, buttons: kSecondaryMouseButton);
        await advance(200);
        await save('episode-context-menu');
        await dismiss();
      }
      await route(app, '/item/episode-friends-s1e2', 'episode-detail');
      await route(app, '/item/movie-up', 'movie-detail');
      if (platform == 'phone') {
        // 首屏以下：章节、演职员、媒体信息与详细信息。
        final page = find
            .descendant(
              of: find.byType(MobileDetailPage),
              matching: find.byType(Scrollable),
            )
            .first;
        for (final (key, name) in const [
          (Key('phone-chapter-strip'), 'movie-detail-chapters'),
          (EpisodePeopleSection.sectionKey, 'movie-detail-cast'),
          (EpisodeMediaStreamsSection.sectionKey, 'movie-detail-media'),
        ]) {
          await tester.scrollUntilVisible(
            find.byKey(key),
            300,
            scrollable: page,
          );
          await Scrollable.ensureVisible(
            tester.element(find.byKey(key)),
            alignment: 0.15,
          );
          await advance(300);
          await save(name);
        }
        tester.state<ScrollableState>(page).position.jumpTo(0);
        await advance(300);
      }
      if (platform == 'phone') {
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        await advance(350);
        await save('movie-detail-text-200');
        tester.platformDispatcher.clearTextScaleFactorTestValue();
        await advance(350);
      }
      if (platform == 'desktop') {
        await modal(CatalogKeys.detailAudio, 'detail-audio');
        await modal(CatalogKeys.detailSubtitle, 'detail-subtitles');
        final page = find
            .descendant(
              of: find.byType(ItemDetailPage),
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is Scrollable && widget.axis == Axis.vertical,
              ),
            )
            .first;
        for (final (finder, name) in [
          (find.byKey(CatalogKeys.chapter(0)), 'movie-detail-chapters'),
          (find.byKey(EpisodePeopleSection.sectionKey), 'movie-detail-cast'),
        ]) {
          await tester.scrollUntilVisible(finder, 400, scrollable: page);
          await Scrollable.ensureVisible(
            tester.element(finder),
            alignment: 0.12,
          );
          await advance(300);
          await save(name);
        }
      }
      if (platform == 'tv') {
        // TV detail mounts later ListView sections only as they approach the
        // viewport. Scroll the actual page before reading or opening its album.
        final page = find.descendant(
          of: find.byKey(const PageStorageKey('tv-detail-movie-up')),
          matching: find.byWidgetPredicate(
            (widget) => widget is Scrollable && widget.axis == Axis.vertical,
          ),
        );
        expect(page, findsOneWidget);
        await tester.scrollUntilVisible(
          find.byType(DetailAlbumStrip),
          200,
          scrollable: page,
        );
        await advance(300);
      }
      expect(
        tester
            .widget<DetailAlbumStrip>(find.byType(DetailAlbumStrip))
            .item
            .backdropImageTags,
        hasLength(2),
      );
      await tester.ensureVisible(find.byType(DetailAlbumStrip));
      await advance(300);
      final album = find
          .descendant(
            of: find.byType(DetailAlbumStrip),
            matching: find.byType(AppSurfaceAction),
          )
          .first;
      await activate(album);
      await save('detail-gallery');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await advance(350);
      expect(find.text('2 / 2'), findsOneWidget);
      await save('detail-gallery-next');
      await dismiss();
      if (platform != 'tv') {
        for (final tone in ['red', 'blue', 'green']) {
          final id = 'palette-$tone';
          server.items.removeWhere((item) => item.id == id);
          server.items.add(
            FakeEmbyItem(
              id: id,
              name: '流派配色 · $tone',
              type: 'Movie',
              parentId: 'view-movies',
              primaryImageTag: id,
              backdropImageTag: id,
              genres: ['动画', '动作冒险', 'Sci-Fi & Fantasy'],
              overview: '流派标签随海报配色变化，支持点击筛选和键盘聚焦。',
            ),
          );
          app.router.go('/item/$id');
          await advance(900);
          final genres = platform == 'phone'
              ? find.text('动作冒险')
              : find.byType(DetailGenreRow);
          expect(genres, findsOneWidget);
          await Scrollable.ensureVisible(tester.element(genres), alignment: .5);
          await advance(400);
          final scheme = AppUiTheme.of(tester.element(genres)).colorScheme;
          final dark = scheme.brightness == Brightness.dark;
          final base =
              (platform == 'phone'
                      ? (dark
                            ? AppUiTheme.phoneDark()
                            : AppUiTheme.phoneLight())
                      : (dark ? AppUiTheme.dark() : AppUiTheme.light()))
                  .colorScheme;
          // 海报取色只染表面与色调容器,主操作保持品牌色。
          expect(
            scheme.primaryContainer,
            isNot(base.primaryContainer),
            reason: 'The $tone genre capture must show resolved artwork colors',
          );
          expect(scheme.primary, base.primary);
          await save('detail-genres-$tone');
          server.items.removeWhere((item) => item.id == id);
        }
      }
      if (platform == 'phone') {
        for (final tone in [
          'red',
          'blue',
          'green',
          'mono',
          'bright',
          'dark',
          'fallback',
        ]) {
          final id = 'palette-$tone';
          server.items.add(
            FakeEmbyItem(
              id: id,
              name: '海报配色 · $tone',
              type: 'Movie',
              parentId: 'view-movies',
              primaryImageTag: id,
              backdropImageTag: id,
              overview: '动态背景来自当前显示的图片。文字和操作保持清晰。',
            ),
          );
          app.router.go('/item/$id');
          await advance(900);
          if (tone == 'fallback') await advance(500);
          await save('detail-palette-$tone');
          if (tone == 'fallback') {
            final first = AppUiTheme.of(
              tester.element(find.byKey(const Key('phone-detail-banner'))),
            ).colorScheme;
            app.router.go('/item/movie-up');
            await advance(500);
            app.router.go('/item/$id');
            await advance(900);
            await advance(500);
            await save('detail-palette-fallback-reentry');
            final revisited = AppUiTheme.of(
              tester.element(find.byKey(const Key('phone-detail-banner'))),
            ).colorScheme;
            expect(revisited.surface, first.surface);
          }
        }
      }
    }
    if (wants('search')) await searchPages(app);
    if (wants('servers')) await serverPages(app, auth);
    if (platform != 'tv' && wants('settings')) await settingsPages(app);
    if (wants('person')) await personPages(app, server, adapter);
  }

  /// 人物作品：加载骨架、按人物 Id 的电影和剧集、空货架、失败重试。
  Future<void> personPages(
    RillightApp app,
    FakeEmbyServer server,
    CaptureAdapter adapter,
  ) async {
    final gate = Completer<void>();
    adapter.catalogGate = gate;
    try {
      app.router.go(AppRoutes.person('person-carl', name: '卡尔'));
      await advance(700);
      await save('person-loading');
      adapter.catalogGate = null;
      gate.complete();
      await advance(900);
      await save('person-works');
      app.router.go(AppRoutes.person('person-none', name: '无名'));
      await advance(900);
      await save('person-empty');
      server.itemsStatus = 500;
      app.router.go(AppRoutes.person('person-carl', name: '卡尔'));
      await advance(900);
      await save('person-error');
    } finally {
      adapter.catalogGate = null;
      if (!gate.isCompleted) gate.complete();
      server.itemsStatus = null;
    }
  }

  Future<void> filterStates(Key openKey, String prefix) async {
    await tap(openKey);
    await save('library-filters');
    if (platform == 'phone') {
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      await advance(350);
      await save('library-filters-text-200');
      tester.platformDispatcher.clearTextScaleFactorTestValue();
      await advance(350);
    }
    for (final section in ['watch', 'genre', 'year']) {
      await tap(Key('$prefix-section-$section'));
      await save('library-filters-$section');
    }
    if (platform != 'desktop') {
      await tap(Key('$prefix-section-sort'));
      await save('library-filters-sorting');
    }
    await tap(Key('$prefix-section-watch'));
    await tap(Key('$prefix-watch-IsUnplayed'));
    await save('library-filters-selected');
    await tap(Key('$prefix-cancel'));
  }

  /// 片库筛选面板:桌面对话框、手机底表共用 [LibraryFilterPanel] 的分区键。
  Future<void> aggregationFilterStates() async {
    final phone = platform == 'phone';
    final prefix = phone ? 'phone-library' : 'catalog-grid-filter';
    await tap(Key(phone ? 'phone-library-filter' : 'catalog-grid-filter-menu'));
    await save('library-filters');
    if (phone) {
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      await advance(350);
      await save('library-filters-text-200');
      tester.platformDispatcher.clearTextScaleFactorTestValue();
      await advance(350);
    }
    for (final section in ['watch', 'genre', 'year']) {
      await tap(Key('$prefix-section-$section'));
      await save('library-filters-$section');
    }
    if (phone) {
      // 排序只在手机筛选面板里;桌面仍是页头的排序下拉。
      await tap(const Key('phone-library-section-sort'));
      await save('library-filters-sorting');
    }
    await tap(Key('$prefix-section-watch'));
    await tap(Key('$prefix-watch-IsUnplayed'));
    await save('library-filters-selected');
    await tap(Key('$prefix-cancel'));
    if (platform == 'desktop') {
      await tap(CatalogKeys.sortBy);
      await save('library-sort');
      // 点已选排序项:无重查,菜单确定关闭(左上角屏障点会命中窗口 chrome)。
      await tap(CatalogKeys.sortOption('DateLastContentAdded'));
    }
  }

  Future<void> searchPages(RillightApp app) async {
    await route(app, '/', 'search-entry');
    if (platform == 'desktop') {
      await activate(findAppTooltip('搜索'));
    } else if (platform == 'phone') {
      await activate(
        find.descendant(
          of: find.byType(CupertinoTabBar),
          matching: find.text('搜索'),
        ),
      );
    } else {
      await tap(const ValueKey('tv-nav-2'));
      await activate(find.byKey(const Key('aggregation-keyword')));
      await save('search-input-dialog');
    }
    final field = find.byKey(
      Key(platform == 'tv' ? 'tv-input-editor' : 'aggregation-keyword'),
    );
    await save('search-idle');
    await tester.enterText(field, '飞屋');
    await tester.testTextInput.receiveAction(
      platform == 'tv' ? TextInputAction.done : TextInputAction.search,
    );
    await advance(900);
    await save('search-results');
    if (platform == 'tv') {
      await activate(find.byKey(const Key('aggregation-keyword')));
    }
    await tester.enterText(field, '不存在的影片');
    await tester.testTextInput.receiveAction(
      platform == 'tv' ? TextInputAction.done : TextInputAction.search,
    );
    await advance(700);
    await save('search-empty');
    if (platform != 'tv') {
      // 桌面/手机搜索都是 _AggregationSearch,筛选是来源开关而非弹层。
      await tap(const Key('aggregation-search-filters'));
      await save('search-filter');
      await tap(const Key('aggregation-search-filters'));
    }
    if (platform == 'desktop') await tap(SearchOverlay.closeKey);
  }

  Future<void> serverPages(RillightApp app, AuthController auth) async {
    await route(app, '/', 'server-entry');
    final server = auth.session!.server;
    final id = server.id;
    final lineId = server.activeLineId!;
    if (platform == 'desktop') {
      await tap(SessionActions.serverMenuKey);
      await save('server-manager');
      await tap(ServerSwitcherDialog.addLineKey(id));
      await save('server-add-line');
      await dismiss();
      await tap(SessionActions.serverMenuKey);
      await tap(ServerSwitcherDialog.editLineKey(id, lineId));
      await save('server-edit-line');
      await dismiss();
      await tap(SessionActions.serverMenuKey);
      await tap(ServerSwitcherDialog.deleteKey(id));
      await save('server-delete-confirm');
      await tap(ServerSwitcherDialog.deleteCancelKey);
      await dismiss();
      await tap(SessionActions.serverMenuKey);
      await tap(ServerSwitcherDialog.changePasswordKey);
    } else if (platform == 'phone') {
      await tap(const Key('mobile-shell-mine-entry'));
      await save('account');
      await tap(PhoneMinePage.lineKey);
      await save('server-manager');
      await modal(PhoneMinePage.lineAddKey(id), 'server-add-line');
      await modal(PhoneMinePage.lineEditKey(id, lineId), 'server-edit-line');
      final selectedServerCard = find.ancestor(
        of: find.byKey(PhoneMinePage.serverDeleteKey(id)),
        matching: find.byType(Column),
      );
      await activate(
        find.descendant(
          of: selectedServerCard.first,
          matching: findAppTooltip('修改显示名称'),
        ),
      );
      await save('server-rename');
      await dismiss();
      await tap(PhoneMinePage.serverDeleteKey(id));
      await save('server-delete-confirm');
      await tap(PhoneMinePage.serverDeleteCancelKey);
      await tester.enterText(find.byKey(PhoneServerManager.searchKey), '不存在');
      await advance(200);
      await save('server-search-empty');
      await dismiss();
      await tap(PhoneMinePage.changePasswordKey);
    } else {
      await tap(const ValueKey('tv-nav-3'));
      await save('server-manager');
      await modal(ValueKey('tv-line-add-$id'), 'server-add-line');
      await modal(ValueKey('tv-line-edit-$id-$lineId'), 'server-edit-line');
      await tap(ValueKey('tv-server-delete-$id'));
      await save('server-delete-confirm');
      await tap(const Key('tv-server-delete-cancel'));
      await tap(const Key('tv-change-password'));
    }
    await save('account-change-password');
    if (platform == 'tv') {
      // 电视密码行是 TvInput，文本框在点开后的编辑框里。
      await _editTvField(ChangePasswordDialog.newPasswordField, 'capture-only');
      await _editTvField(ChangePasswordDialog.confirmField, 'mismatch');
    } else {
      await tester.enterText(
        find.byKey(ChangePasswordDialog.newPasswordField),
        'capture-only',
      );
      await tester.enterText(
        find.byKey(ChangePasswordDialog.confirmField),
        'mismatch',
      );
    }
    await advance(150);
    await save('account-password-mismatch');
    await tap(ChangePasswordDialog.cancelKey);
    await route(app, '/connect?add=1', 'server-add');
    if (platform != 'tv') {
      await tap(
        platform == 'desktop'
            ? ConnectFormKeys.more
            : const Key('android-connect-more'),
      );
      await save('server-add-advanced');
    }
    await _backupImportStates(app, auth);
  }

  /// 备份导入:合成凭据样本走真实的解析与提交。入口、加载、部分成功、
  /// 整体失败与私密锁定跳过都是显式注册的原型状态。
  Future<void> _backupImportStates(RillightApp app, AuthController auth) async {
    const ids = [
      'server-import-entry',
      'server-import-loading',
      'server-import-partial',
      'server-import-failed',
      'server-import-private',
    ];
    if (!ids.any(shouldCapture)) return;
    final existing = auth.savedServers.first;
    // 自携带密钥的 common-config:不需要任何客户端密钥常量。
    final partialBytes = (await tester.runAsync(
      () => buildCommonConfig([
        commonEntry(
          type: 'emby',
          name: '导入的新服务器',
          url: 'http://192.0.2.60:8096',
          authorization: authorization(userName: 'carol'),
        ),
        commonEntry(
          type: 'emby',
          name: '已存在服务器',
          url: existing.baseUrl,
          // 缺少可对照的远端 userId 时,判重回落到账号名比对。
          authorization: authorization(userName: existing.username, userId: ''),
        ),
        commonEntry(
          type: 'jellyfin',
          name: '非目标服务',
          url: 'http://192.0.2.61:8920',
        ),
        commonEntry(type: 'emby', name: '缺线路', url: ''),
      ], selfKey: selfCarriedTestKey),
    ))!;
    final privateBytes = (await tester.runAsync(
      () => buildHillsBackup([
        hillsServer(
          displayName: '私密库',
          serverUrl: 'http://192.0.2.62:8096',
          isPrivate: true,
        ),
      ]),
    ))!;
    final brokenBytes = utf8.encode('not a backup');

    Future<Key> openEntry() async {
      switch (platform) {
        case 'desktop':
          app.router.go('/');
          await advance(700);
          await tap(SessionActions.serverMenuKey);
          await advance(400);
          return ServerSwitcherDialog.importBackupKey;
        case 'phone':
          app.router.go('/mine');
          await advance(700);
          await tap(PhoneMinePage.lineKey);
          await advance(600);
          return PhoneServerManager.importKey;
        default:
          app.router.go('/connect?add=1');
          await advance(700);
          return const ValueKey('tv-connect-import');
      }
    }

    PickedAppFile fileOf(String name, List<int> bytes) => PickedAppFile(
      fileName: name,
      length: bytes.length,
      read: (limit) async => Uint8List.fromList(bytes),
    );

    Future<void> runImport(Key entry, List<int> bytes) async {
      auth.backupImportPicker = _InlinePicker(
        () async => fileOf('backup', bytes),
      );
      await tap(entry);
    }

    final entry = await openEntry();
    await save('server-import-entry');

    // 加载态:读取被门闩挂起,面板出现后放行。
    final gate = Completer<void>();
    auth.backupImportPicker = _InlinePicker(
      () async => PickedAppFile(
        fileName: 'backup.json',
        length: partialBytes.length,
        read: (limit) async {
          await gate.future;
          return Uint8List.fromList(partialBytes);
        },
      ),
    );
    await tap(entry);
    for (
      var i = 0;
      i < 40 && find.byKey(BackupImportFlowKeys.loading).evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
    }
    expect(find.byKey(BackupImportFlowKeys.loading), findsOneWidget);
    await save('server-import-loading');
    gate.complete();
    for (
      var i = 0;
      i < 60 && find.byKey(BackupImportFlowKeys.result).evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
    }
    expect(find.byKey(BackupImportFlowKeys.result), findsOneWidget);
    await save('server-import-partial');
    await tap(BackupImportFlowKeys.close);

    // 整体失败:未知格式零写入,失败面板给出安全分类原因。
    Key next = entry;
    if (platform == 'desktop') {
      // 切换面板在导入前已自行关闭;重新打开。手机底表与电视连接页仍在。
      next = await openEntry();
    }
    await runImport(next, brokenBytes);
    await advance(600);
    expect(find.byKey(BackupImportFlowKeys.failure), findsOneWidget);
    await save('server-import-failed');
    await tap(BackupImportFlowKeys.close);

    // 私密锁定:备份中的私密记录按条跳过并说明原因。
    if (platform == 'desktop') {
      next = await openEntry();
    }
    auth.backupImportKeys = hillsKeys();
    await runImport(next, privateBytes);
    await advance(600);
    expect(find.byKey(BackupImportFlowKeys.result), findsOneWidget);
    await save('server-import-private');
    await tap(BackupImportFlowKeys.close);
    if (platform == 'phone') {
      // 返回键关闭仍在的手机服务底表,避免遮挡后续页面捕获。
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      await tester.binding.handlePopRoute();
      await advance(500);
    }
    auth.backupImportKeys = const BackupImportKeys();
    auth.backupImportPicker = null;
  }

  Future<void> settingsPages(RillightApp app) async {
    // Widget tests default to Android, which has a single decoder backend.
    // Desktop capture should show the Windows choice the settings page hides
    // until more than one backend exists.
    final restorePlatform = debugDefaultTargetPlatformOverride;
    if (platform == 'desktop') {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    }
    try {
      await _settingsPages(app);
    } finally {
      debugDefaultTargetPlatformOverride = restorePlatform;
    }
  }

  Future<void> _settingsPages(RillightApp app) async {
    if (platform == 'desktop') {
      await route(app, '/settings', 'settings');
    } else {
      await route(app, '/mine', 'account-settings-entry');
      await tap(PhoneMinePage.settingsKey);
      await save('settings');
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      await advance(350);
      await save('settings-text-200');
      tester.platformDispatcher.clearTextScaleFactorTestValue();
      await advance(350);
    }
    await tap(const ValueKey('settings-section-外观'));
    await save('settings-appearance-expanded');
    await tester.ensureVisible(find.byKey(SettingsPage.appearanceKey));
    await advance(200);
    await save('settings-appearance');
    await tap(const ValueKey('settings-section-外观'));
    await tap(const ValueKey('settings-section-播放'));
    await save('settings-playback-expanded');
    await tester.ensureVisible(find.byKey(const Key('settings-playback-rate')));
    await advance(200);
    await save('settings-speed');
    for (final entry in [
      (SettingsPage.diskCacheLimitKey, 'cache'),
      (SettingsPage.hardwareDecodingKey, 'decoding'),
      (SettingsPage.decoderBackendKey, 'decoder'),
    ]) {
      final target = find.byKey(entry.$1);
      if (target.evaluate().isEmpty) continue;
      await tester.ensureVisible(target);
      await advance(200);
      await save('settings-${entry.$2}');
    }
    await tap(const ValueKey('settings-section-播放'));
    await tap(const ValueKey('settings-section-弹幕配置'));
    await tester.ensureVisible(find.byKey(SettingsPage.danmakuServerFieldKey));
    await advance(200);
    await save('settings-danmaku');
    await tap(const ValueKey('danmaku-advanced-settings'));
    await save('settings-danmaku-advanced');
    if (platform == 'phone') {
      Navigator.of(tester.element(find.byType(SettingsPage))).pop();
      await advance(400);
    }
  }

  Future<void> loginPages(RillightApp app, AuthController auth) async {
    await tester.runAsync(auth.logout);
    await route(app, '/connect', 'login-saved-servers');
    for (final provider in ['jellyfin', 'plex']) {
      await tap(Key('login-provider-$provider'));
      await save('login-$provider');
    }
    await tap(const Key('login-provider-emby'));
    final address = Key(switch (platform) {
      'desktop' => 'connect-address',
      'phone' => 'android-connect-address',
      _ => 'tv-connect-address',
    });
    final submit = Key(switch (platform) {
      'desktop' => 'connect-submit',
      'phone' => 'android-connect-submit',
      _ => 'tv-connect-submit',
    });
    if (platform == 'phone') {
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      await advance(350);
      await save('login-text-200');
      tester.platformDispatcher.clearTextScaleFactorTestValue();
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await advance(350);
      await activate(find.byKey(address));
      await save('login-keyboard');
      tester.view.resetViewInsets();
      tester.testTextInput.hide();
      FocusManager.instance.primaryFocus?.unfocus();
      await advance(350);
    }
    if (platform == 'tv') {
      await tap(address);
      await save('login-address-editor');
      await dismiss();
    } else {
      await tester.enterText(find.byKey(address), 'not a server');
      await tap(submit);
      await save('login-validation');
      await tap(
        platform == 'desktop'
            ? ConnectFormKeys.more
            : const Key('android-connect-more'),
      );
      await save('login-advanced');
      await modal(
        platform == 'desktop'
            ? ConnectFormKeys.connectAppearanceKey
            : const Key('android-connect-appearance'),
        'login-appearance',
      );
    }
  }
}

/// 注入式文件选择边界:原型捕获直接交付合成备份字节。
class _InlinePicker implements AppFilePicker {
  const _InlinePicker(this._pick);
  final Future<PickedAppFile?> Function() _pick;

  @override
  Future<PickedAppFile?> pickFile({
    required String dialogTitle,
    required List<String> allowedExtensions,
  }) => _pick();
}
