import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/app_shell.dart';
import 'package:rillight/app/phone_mine_page.dart';
import 'package:rillight/app/settings/settings_page.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/change_password_dialog.dart';
import 'package:rillight/auth/connect_page.dart';
import 'package:rillight/auth/phone_server_manager.dart';
import 'package:rillight/auth/server_switcher_dialog.dart';
import 'package:rillight/auth/session_actions.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/library/detail_extras.dart';
import 'package:rillight/search/search_overlay.dart';
import 'package:rillight/player/player_host_command.dart';
import 'package:rillight/aggregation/identity/media_identity.dart';

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
        await activate(find.byType(NavigationDestination).at(1));
      } else {
        await tap(const ValueKey('tv-nav-1'));
      }
      await advance(1200);
      await save('aggregation-ready');
      // TV 聚合页是分段 + 卡片行的新版本,没有来源管理与私密区入口。
      if (platform != 'tv') {
        await tap(const Key('aggregation-source-management'));
        await save('aggregation-management');
        await activate(find.widgetWithText(ListTile, '私密区域'));
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
        await activate(find.widgetWithText(FilterChip, '全部普通来源'));
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
        await activate(find.widgetWithText(FilterChip, '全部普通来源'));
        await advance(900);
        await activate(find.widgetWithText(TextButton, '查找同源 · 2').first);
        await advance(900);
        await save('aggregation-comparison');
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await advance(350);
        adapter.failAggregationMirror = true;
        await activate(find.widgetWithText(FilterChip, '全部普通来源'));
        await advance(1000);
        await save('aggregation-partial-failure');
        adapter.failAggregationMirror = false;
        if (platform == 'phone') {
          // /aggregation 只有桌面路由;先回首页再经底部导航进聚合页。
          app.router.go('/');
          await advance(900);
          await activate(find.byType(NavigationDestination).at(1));
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
        await activate(find.byType(NavigationDestination).at(2));
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
        await activate(find.byType(NavigationDestination).at(0));
      }
      if (platform == 'tv') await tap(const ValueKey('tv-nav-0'));
    }
    if (wants('home') || wants('library')) {
      await route(app, '/', 'home-return');
      if (platform == 'desktop') {
        await tap(AppShell.overflowNavKey);
        await save('home-display');
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
        await activate(find.byType(NavigationDestination).at(1));
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
        'phone' => find.byKey(const Key('phone-season-list')),
        _ => find.byKey(const Key('tv-detail-episodes')),
      };
      if (episodeArea.evaluate().isNotEmpty) {
        await tester.ensureVisible(episodeArea.first);
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
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        await advance(350);
        await save('movie-detail-text-200');
        tester.platformDispatcher.clearTextScaleFactorTestValue();
        await advance(350);
      }
      if (platform == 'desktop') {
        await modal(CatalogKeys.detailAudio, 'detail-audio');
        await modal(CatalogKeys.detailSubtitle, 'detail-subtitles');
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
            matching: find.byType(InkWell),
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
          final scheme = Theme.of(tester.element(genres)).colorScheme;
          final base = scheme.brightness == Brightness.dark
              ? AppTheme.dark().colorScheme
              : AppTheme.light().colorScheme;
          expect(
            scheme.primary,
            isNot(base.primary),
            reason: 'The $tone genre capture must show resolved artwork colors',
          );
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
            final first = Theme.of(
              tester.element(find.byKey(const Key('phone-detail-banner'))),
            ).colorScheme;
            app.router.go('/item/movie-up');
            await advance(500);
            app.router.go('/item/$id');
            await advance(900);
            await advance(500);
            await save('detail-palette-fallback-reentry');
            final revisited = Theme.of(
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
      await activate(find.byTooltip('搜索'));
    } else if (platform == 'phone') {
      await activate(find.byType(NavigationDestination).at(2));
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
        matching: find.byType(Card),
      );
      await activate(
        find.descendant(
          of: selectedServerCard,
          matching: find.byTooltip('修改显示名称'),
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
  }

  Future<void> settingsPages(RillightApp app) async {
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
      await tester.ensureVisible(find.byKey(entry.$1));
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
