import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/app_shell.dart';
import 'package:rillight/app/phone_mine_page.dart';
import 'package:rillight/app/settings/settings_page.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/change_password_dialog.dart';
import 'package:rillight/auth/connect_page.dart';
import 'package:rillight/auth/phone_server_manager.dart';
import 'package:rillight/auth/server_switcher_dialog.dart';
import 'package:rillight/auth/session_actions.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/library/catalog_filter_button.dart';
import 'package:rillight/library/detail_extras.dart';
import 'package:rillight/library/shelf_grid_page.dart';
import 'package:rillight/search/search_overlay.dart';

import '../../test/emby/fake_emby_server.dart';
import 'capture.dart';

extension PageCaptures on CaptureSession {
  Future<void> activate(Finder finder) async {
    expect(finder, findsOneWidget);
    await Scrollable.ensureVisible(tester.element(finder), alignment: .5);
    await advance(100);
    await tester.tap(finder);
    await advance(400);
  }

  Future<void> dismiss() async {
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await advance(350);
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
  ) async {
    if (wants('home') || wants('library')) {
      await route(app, '/', 'home-return');
      if (platform == 'desktop') {
        await tap(AppShell.overflowNavKey);
        await save('library-navigation-menu');
        await tap(AppShell.moreLibrariesKey);
        await save('library-list');
        await dismiss();
        await tap(AppShell.overflowNavKey);
        await tap(AppShell.customizeNavKey);
        await save('library-navigation-customize');
        await dismiss();
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
      if (platform == 'desktop') {
        await modal(CatalogKeys.sortBy, 'library-sort');
        await filterStates(gridFilterMenuKey, 'catalog-grid-filter');
      } else if (platform == 'phone') {
        await filterStates(const Key('phone-library-filter'), 'phone-library');
      } else {
        await filterStates(const Key('tv-library-filter'), 'tv-library');
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
      if (platform == 'phone') {
        for (final tone in ['red', 'blue', 'green', 'mono', 'bright', 'dark']) {
          final id = 'palette-$tone';
          server.items.add(
            FakeEmbyItem(
              id: id,
              name: '海报配色 · $tone',
              type: 'Movie',
              primaryImageTag: id,
              backdropImageTag: id,
              overview: '动态背景来自当前显示的图片。文字和操作保持清晰。',
            ),
          );
          await route(app, '/item/$id', 'detail-palette-$tone');
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

  Future<void> searchPages(RillightApp app) async {
    await route(app, '/', 'search-entry');
    Finder field;
    if (platform == 'desktop') {
      await activate(find.byTooltip('搜索'));
      field = find.byKey(CatalogKeys.searchField);
    } else if (platform == 'phone') {
      await activate(find.byType(NavigationDestination).at(2));
      field = find.byKey(const Key('mobile-search-field'));
    } else {
      await tap(const ValueKey('tv-nav-2'));
      await activate(find.byType(TvInput));
      await save('search-input-dialog');
      field = find.byKey(const Key('tv-input-editor'));
    }
    await save('search-idle');
    await tester.enterText(field, '飞屋');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await advance(900);
    await save('search-results');
    if (platform == 'tv') {
      await activate(find.byType(TvInput));
      field = find.byKey(const Key('tv-input-editor'));
    }
    await tester.enterText(field, '不存在的影片');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await advance(700);
    await save('search-empty');
    if (platform == 'desktop') {
      await modal(CatalogFilterButton.defaultKey, 'search-filter');
      await tap(SearchOverlay.closeKey);
    } else if (platform == 'phone') {
      await modal(CatalogFilterButton.defaultKey, 'search-filter');
    }
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
      await activate(find.byTooltip('修改显示名称'));
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
    await tester.enterText(
      find.byKey(ChangePasswordDialog.newPasswordField),
      'capture-only',
    );
    await tester.enterText(
      find.byKey(ChangePasswordDialog.confirmField),
      'mismatch',
    );
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
    await modal(SettingsPage.appearanceKey, 'settings-appearance');
    await tap(const ValueKey('settings-section-外观'));
    await tap(const ValueKey('settings-section-播放'));
    await save('settings-playback-expanded');
    for (final entry in [
      (const Key('settings-playback-rate'), 'speed'),
      (SettingsPage.diskCacheLimitKey, 'cache'),
      (SettingsPage.hardwareDecodingKey, 'decoding'),
      (SettingsPage.decoderBackendKey, 'decoder'),
    ]) {
      await modal(entry.$1, 'settings-${entry.$2}');
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
      await tester.tap(find.byKey(address));
      await advance(350);
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
