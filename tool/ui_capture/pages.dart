import 'package:rillight/library/source_selection.dart';
import 'package:rillight/app/startup_failure.dart';
import 'package:rillight/app/android_bootstrap.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/auth/startup_recovery.dart';

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
import 'package:rillight/auth/session_actions.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/library/detail_extras.dart';
import 'package:rillight/library/episode_detail_sections.dart';
import 'package:rillight/library/item_detail_page.dart';
import 'package:rillight/library/mobile_detail_page.dart';
import 'package:rillight/search/search_overlay.dart';

import '../../test/auth/backup_import/backup_import_cases.dart';
import '../../test/emby/fake_emby_server.dart';
import 'capture.dart';
import 'fixtures.dart';

extension PageCaptures on CaptureSession {
  /// Startup failure owns a fresh root; do not replace an active detail app.
  Future<void> entryRecovery() async {
    const recovery = ConfigurationUpgradeFailure(
      '/synthetic/rillight',
      originalPath: '/synthetic/rillight/watch-history.json',
      backupPath: '/synthetic/rillight/watch-history.json.pre-source-v2',
      history: true,
    );
    tester.platformDispatcher.platformBrightnessTestValue = theme == 'dark'
        ? Brightness.dark
        : Brightness.light;
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: platform == 'desktop'
            ? StartupFailureApp(upgrade: recovery, retry: () async {})
            : AndroidBootstrap(
                resolveEnvironment: () async => platform == 'tv'
                    ? PresentationEnvironment.tv
                    : PresentationEnvironment.phone,
                createAuth: () async => AuthController.memory(),
                createRuntime: (_) async => throw recovery,
              ),
      ),
    );
    for (var i = 0; i < 40 && find.text('播放记录暂时无法读取').evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await advance(100);
    }
    expect(find.text('播放记录暂时无法读取'), findsOneWidget);
    await save(
      'entry-history-recovery',
      renderedTheme: platform == 'desktop' ? theme : 'dark',
    );
    tester.platformDispatcher.clearPlatformBrightnessTestValue();
    await tester.pumpWidget(const SizedBox.shrink());
    await advance(100);
  }

  Future<void> _driveEntryCapture(Future<void> Function() action) async {
    var done = false;
    Object? failure;
    await tester.runAsync(() async {
      unawaited(
        action().then(
          (_) {
            done = true;
          },
          onError: (Object error) {
            failure = error;
            done = true;
          },
        ),
      );
    });
    for (var step = 0; step < 100 && !done; step++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await advance(100);
    }
    if (!done) {
      throw TimeoutException('Entry capture fixture operation did not finish');
    }
    if (failure != null) throw failure!;
  }

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
    if (wants('entry')) {
      if ([
        'entry-source-selection-locked',
        'entry-source-selection-password',
        'entry-source-selection-candidate',
      ].any(shouldCapture)) {
        final source = auth.savedServers.first;
        final target = auth.savedServers.last;
        await _driveEntryCapture(() async {
          await auth.serverAccess.setPassword(
            target.id,
            'capture-entry',
            'capture-entry',
            persistReference: (ref) =>
                auth.sources.persistProtectionReference(target.id, ref),
          );
          await auth.refreshServers();
        });
        // Use the same ordinary detail route as a home-page poster.
        app.router.go('/item/movie-up');
        await advance(1200);
        await activate(
          find
              .descendant(
                of: find.byType(SourceSelectionAction),
                matching: find.byType(AppButton),
              )
              .first,
        );
        await advance(800);
        expect(
          find.byKey(ValueKey('source-selection-verify-${target.id}')),
          findsOneWidget,
        );
        await save('entry-source-selection-locked');
        await activate(
          find.byKey(ValueKey('source-selection-verify-${target.id}')),
        );
        await save('entry-source-selection-password');
        if (platform == 'tv') {
          await _editTvField(
            const Key('server-unlock-password'),
            'capture-entry',
          );
        } else {
          await tester.enterText(
            find.byKey(const Key('server-unlock-password')),
            'capture-entry',
          );
        }
        await activate(find.byKey(const Key('server-unlock-submit')));
        for (
          var i = 0;
          i < 60 &&
              find
                  .byKey(
                    ValueKey('source-selection-item-${target.id}-movie-up'),
                  )
                  .evaluate()
                  .isEmpty;
          i++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          await advance(100);
        }
        expect(
          find.byKey(ValueKey('source-selection-item-${target.id}-movie-up')),
          findsOneWidget,
        );
        expect(auth.session?.server.id, source.id);
        expect(auth.serverAccess.allows(target.id), isFalse);
        await Scrollable.ensureVisible(
          tester.element(
            find.byKey(ValueKey('source-selection-item-${target.id}-movie-up')),
          ),
          alignment: .2,
        );
        await advance(250);
        await save('entry-source-selection-candidate');
        await activate(find.byKey(const Key('source-selection-close')));
        await _driveEntryCapture(() async {
          await auth.serverAccess.disablePassword(
            target.id,
            'capture-entry',
            persistReference: (ref) =>
                auth.sources.persistProtectionReference(target.id, ref),
          );
          await auth.refreshServers();
        });
      }
      app.router.go('/');
      await advance(500);
    }
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
      if (['aggregation-locked', 'aggregation-unlock'].any(shouldCapture)) {
        final protected = auth.savedServers.last;
        await tester.runAsync(() async {
          await auth.serverAccess.setPassword(
            protected.id,
            'capture-entry',
            'capture-entry',
            persistReference: (ref) =>
                auth.sources.persistProtectionReference(protected.id, ref),
          );
          await auth.refreshServers();
        });
        await advance(600);
        await save('aggregation-locked');
        await activate(
          find.descendant(
            of: find.byKey(ValueKey('aggregation-server-${protected.id}')),
            matching: find.text('进入服务器'),
          ),
        );
        await advance(400);
        await save('aggregation-unlock');
        Navigator.of(
          tester.element(find.byKey(const Key('server-unlock-password'))),
        ).pop();
        await advance(350);
        await tester.runAsync(() async {
          await auth.serverAccess.disablePassword(
            protected.id,
            'capture-entry',
            persistReference: (ref) =>
                auth.sources.persistProtectionReference(protected.id, ref),
          );
          await auth.refreshServers();
        });
        await advance(900);
      }
      await tap(const Key('aggregation-segment-favorites'));
      await save('aggregation-segment-favorites');
      await tap(const Key('aggregation-segment-libraries'));
      await save('aggregation-segment-libraries');
      adapter.failAggregationMirror = true;
      // Re-enter the content shell so the real row loader performs a fresh
      // request; changing a segment alone only changes the visible slice.
      app.router.go('/connect?add=1');
      await advance(400);
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
      await tap(const Key('aggregation-segment-favorites'));
      await advance(1000);
      expect(find.text('重试'), findsWidgets);
      await tester.ensureVisible(find.text('重试').first);
      await advance(200);
      await save('aggregation-partial-failure');
      adapter.failAggregationMirror = false;
      adapter.emptyAggregationMirror = true;
      await activate(find.text('重试').first);
      await advance(700);
      expect(find.text('重试'), findsNothing);
      expect(find.text('暂无内容'), findsWidgets);
      await tester.ensureVisible(find.text('暂无内容').last);
      await advance(200);
      await save('aggregation-empty');
      adapter.emptyAggregationMirror = false;
      await tap(const Key('aggregation-segment-continue'));
      await advance(800);
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
        // 单库入口保留在首页的媒体库横排。
        await tester.scrollUntilVisible(
          find.byKey(const Key('phone-home-library-view-movies')),
          320,
          scrollable: find.byType(Scrollable).first,
        );
        await Scrollable.ensureVisible(
          tester.element(
            find.byKey(const Key('phone-home-library-view-movies')),
          ),
          alignment: .25,
        );
        await advance(300);
        await save('library-list');
      } else {
        await tap(const ValueKey('tv-nav-1'));
        await tap(const Key('aggregation-segment-libraries'));
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
          // 海报取色只染 7 个表面字段;主容器、选中态与主操作保持品牌色。
          expect(
            scheme.surfaceContainerHighest,
            isNot(base.surfaceContainerHighest),
            reason:
                'The $tone genre capture must show resolved artwork surface colors',
          );
          expect(scheme.primaryContainer, base.primaryContainer);
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
    if (wants('servers')) await serverPages(app, auth, adapter);
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

  Future<void> serverPages(
    RillightApp app,
    AuthController auth,
    CaptureAdapter adapter,
  ) async {
    await route(app, '/', 'server-entry');
    final server = auth.session!.server;
    final id = server.id;
    final lineId = server.activeLineId!;
    await _modernServerPages(app, auth, id, lineId, adapter);
    await _backupImportStates(app, auth);
  }

  Future<void> _modernServerPages(
    RillightApp app,
    AuthController auth,
    String id,
    String lineId,
    CaptureAdapter adapter,
  ) async {
    Future<void> open() async {
      if (platform == 'desktop') {
        await tap(SessionActions.serverMenuKey);
      } else if (platform == 'tv') {
        await tap(const Key('tv-nav-user'));
      } else {
        app.router.go('/mine');
        await advance(600);
        await save('account');
        await tap(PhoneMinePage.lineKey);
      }
    }

    Future<void> back() =>
        tap(Key(platform == 'tv' ? 'tv-server-back' : 'server-flow-back'));
    Future<void> edit() async {
      await tap(Key('server-more-$id'));
      await tap(
        Key(platform == 'tv' ? 'server-more-edit' : 'server-action-edit-$id'),
      );
    }

    await open();
    await save('server-manager');
    await tap(Key('server-lines-$id'));
    await save('server-line-selector');
    const checkStates = [
      'server-check-certificate',
      'server-check-permission',
      'server-check-login',
      'server-check-offline',
    ];
    if (checkStates.any(shouldCapture)) {
      final remote = adapter.servers.firstWhere(
        (s) => s.baseUrl.toString() == auth.session!.server.baseUrl,
      );
      for (final state in checkStates) {
        if (!shouldCapture(state)) continue;
        adapter.certificateError = state == 'server-check-certificate';
        adapter.failLineCheck = state == 'server-check-offline';
        remote.publicInfoStatus = state == 'server-check-permission'
            ? 403
            : state == 'server-check-login'
            ? 401
            : null;
        await tap(Key('server-line-check-$lineId'));
        await save(state);
      }
      adapter.certificateError = false;
      adapter.failLineCheck = false;
      remote.publicInfoStatus = null;
      await tap(Key('server-line-check-$lineId'));
    }
    await back();
    await edit();
    await save('server-editor');
    if (platform == 'tv') await save('account');
    await save('server-rename');
    await tap(const Key('server-editor-add-line'));
    await save('server-add-line');
    await back();
    await tap(Key('server-editor-line-$lineId'));
    await save('server-edit-line');
    await back();
    await tap(const Key('server-editor-password'));
    await save('server-password-form');
    await back();
    await tap(const Key('server-editor-remote-password'));
    await save('account-change-password');
    if (platform == 'tv') {
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
    await back();
    await tap(Key('server-more-$id'));
    await tap(
      Key(platform == 'tv' ? 'server-more-remove' : 'server-action-remove-$id'),
    );
    await save('server-delete-confirm');
    await tap(const Key('server-remove-cancel'));
    if (platform == 'tv') {
      await _editTvField(const Key('server-search'), '不存在');
    } else {
      await tester.enterText(find.byKey(const Key('server-search')), '不存在');
    }
    await advance(200);
    await save('server-search-empty');
    if (platform == 'tv') {
      await _editTvField(const Key('server-search'), '');
    } else {
      await tester.enterText(find.byKey(const Key('server-search')), '');
    }
    await tap(const Key('server-add'));
    await save('server-add');
    if (platform != 'tv') {
      await tap(const Key('provider-advanced'));
      await save('server-add-advanced');
    }
    await tap(const Key('server-add-paste'));
    const pasteSample =
        '名称：家庭影院\n地址：https://home.example.com\n用户：alice\n密码：synthetic\n名称：朋友的影院\n线路1：https://friend.example.com\n线路2：https://backup.example.com/emby\n用户：bob';
    if (platform == 'tv') {
      await _editTvField(const Key('server-paste-text'), pasteSample);
    } else {
      await tester.enterText(
        find.byKey(const Key('server-paste-text')),
        pasteSample,
      );
    }
    if (platform == 'tv') await save('server-paste-input');
    await tap(const Key('server-paste-parse'));
    await save('server-paste-groups');
    await tap(const Key('server-paste-group-1'));
    await save('server-paste-preview');
    if (platform == 'tv') {
      final lines = find.byKey(const Key('provider-extra-lines'));
      tester
          .widget<FocusableActionDetector>(
            find.descendant(
              of: lines,
              matching: find.byType(FocusableActionDetector),
            ),
          )
          .focusNode!
          .requestFocus();
      await advance(500);
      await save('server-paste-lines');
      await tap(const Key('provider-extra-lines'));
      await save('server-paste-keyboard');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await advance(350);
    }
    await back();
    await back();
    if (shouldCapture('server-needs-login') ||
        shouldCapture('server-account-needs-login')) {
      final other = auth.savedServers.last;
      await tap(Key('server-more-${other.id}'));
      await tap(
        Key(
          platform == 'tv'
              ? 'server-more-edit'
              : 'server-action-edit-${other.id}',
        ),
      );
      await tap(const Key('server-editor-logout'));
      await tap(const Key('server-logout-confirm'));
      await open();
      await save('server-needs-login');
      await tap(Key('server-more-${other.id}'));
      await tap(
        Key(
          platform == 'tv'
              ? 'server-more-edit'
              : 'server-action-edit-${other.id}',
        ),
      );
      await save('server-account-needs-login');
      await back();
    }
    if ([
      'server-locked-list',
      'server-unlock',
      'server-unlock-error',
    ].any(shouldCapture)) {
      final protected = auth.savedServers.last;
      await tester.runAsync(() async {
        await auth.serverAccess.register(protected);
        await auth.serverAccess.setPassword(
          protected.id,
          'capture-entry',
          'capture-entry',
          persistReference: (ref) =>
              auth.sources.persistProtectionReference(protected.id, ref),
        );
        await auth.refreshServers();
      });
      await advance(150);
      await save('server-locked-list');
      await tap(Key('server-enter-${protected.id}'));
      await save('server-unlock');
      if (platform == 'tv') {
        await _editTvField(const Key('server-unlock-password'), 'wrong');
      } else {
        await tester.enterText(
          find.byKey(const Key('server-unlock-password')),
          'wrong',
        );
      }
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('server-unlock-submit')));
        for (
          var i = 0;
          i < 500 && auth.serverAccess.retryAt(protected.id) == null;
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await advance(150);
      expect(find.text('密码不正确。'), findsOneWidget);
      await save('server-unlock-error');
      await back();
    }
    await back();
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
          await tap(const Key('server-add'));
          return const Key('server-add-import');
        case 'phone':
          app.router.go('/mine');
          await advance(700);
          await tap(PhoneMinePage.lineKey);
          await advance(600);
          await tap(const Key('server-add'));
          return const Key('server-add-import');
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
    if (platform != 'tv') {
      // 桌面与手机都先关闭服务器流程再导入；返回后重新打开。
      next = await openEntry();
    }
    await runImport(next, brokenBytes);
    await advance(600);
    expect(find.byKey(BackupImportFlowKeys.failure), findsOneWidget);
    await save('server-import-failed');
    await tap(BackupImportFlowKeys.close);

    // 私密锁定:备份中的私密记录按条跳过并说明原因。
    if (platform != 'tv') {
      next = await openEntry();
    }
    auth.backupImportKeys = hillsKeys();
    await runImport(next, privateBytes);
    await advance(600);
    expect(find.byKey(BackupImportFlowKeys.result), findsOneWidget);
    await save('server-import-private');
    await tap(BackupImportFlowKeys.close);
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

/// 首页三种整页状态:空库、设备离线、服务器离线。
///
/// 目录控制器在失败后先按 2s/6s/20s 静默重试,耗尽才落为整页错误态;
/// 这里用跨越重试节拍的整帧推进,避免逐 20ms 空转。
extension HomeFailureCaptures on CaptureSession {
  static const _failureStates = <CaptureCatalogFailure, String>{
    CaptureCatalogFailure.empty: 'home-empty-library',
    CaptureCatalogFailure.deviceOffline: 'home-device-offline',
    CaptureCatalogFailure.serverOffline: 'home-server-offline',
  };

  static const _titles = <CaptureCatalogFailure, String>{
    CaptureCatalogFailure.empty: '这个服务器还没有内容',
    CaptureCatalogFailure.deviceOffline: '设备未联网',
    CaptureCatalogFailure.serverOffline: '无法连接服务器',
  };

  static const _primaryLabels = <CaptureCatalogFailure, String>{
    CaptureCatalogFailure.empty: '去媒体库',
    CaptureCatalogFailure.deviceOffline: '重试',
    CaptureCatalogFailure.serverOffline: '重试',
  };

  static const _secondaryLabels = <CaptureCatalogFailure, String>{
    CaptureCatalogFailure.empty: '刷新',
    CaptureCatalogFailure.deviceOffline: '切换服务器',
    CaptureCatalogFailure.serverOffline: '更换线路',
  };

  /// 每台状态使用一台从未载入过目录的合成服务器。
  ///
  /// 目录缓存按服务器身份隔离,并且会磁盘持久化;复用当前服务器会先显示
  /// 上一状态缓存的真实条目,截不到整页空态/失败态。新身份等效于刚添加
  /// 的服务器首次打开首页。
  Future<void> _connectFreshServer(
    RillightApp app,
    AuthController auth,
    CaptureAdapter adapter,
    FakeEmbyServer template,
    String suffix,
  ) async {
    final fresh = FakeEmbyServer(
      serverId: 'capture-failure-$suffix',
      serverName: '合成服务器 · $suffix',
      baseUrl: Uri.parse('http://capture-failure-$suffix.test:8096'),
      views: template.views,
      items: template.items,
    );
    adapter.add(fresh);
    // CaptureAdapter 用构造时列表同步各线路签发的令牌;后加的服务器也要登记。
    adapter.servers.add(fresh);
    final backup = FakeEmbyServer(
      serverId: 'capture-failure-$suffix',
      serverName: '合成服务器 · $suffix',
      baseUrl: Uri.parse('http://capture-failure-$suffix-backup.test:8096'),
      views: template.views,
      items: template.items,
    );
    adapter.add(backup);
    adapter.servers.add(backup);
    await tester.runAsync(() async {
      await auth.connect(
        address: fresh.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      );
      // 两条线路才会在服务器离线时给出「更换线路」而不是「切换服务器」。
      await auth.addLine(auth.session!.server.id, backup.baseUrl.toString());
    });
    // 换服务器的同时重建内容壳层:沿用旧控制器会先显示上一台的条目。
    await tester.pumpWidget(const SizedBox.shrink());
    await advance(150);
    await tester.pumpWidget(RepaintBoundary(key: boundary, child: app));
    await advance(900);
    // PageStorage 会记住上次停留的标签页/面板;失败态必须落在首页本身。
    if (platform == 'phone') {
      final homeTab = find.descendant(
        of: find.byType(CupertinoTabBar),
        matching: find.text('首页'),
      );
      if (homeTab.evaluate().isNotEmpty) {
        await tester.tap(homeTab);
        await advance(700);
      }
    } else if (platform == 'tv') {
      if (find.byKey(const ValueKey('tv-nav-0')).evaluate().isNotEmpty) {
        await tap(const ValueKey('tv-nav-0'));
        await advance(700);
      }
    }
  }

  Future<void> homeFailureStates(
    RillightApp app,
    AuthController auth,
    CaptureAdapter adapter,
    FakeEmbyServer template,
  ) async {
    if (!_failureStates.values.any(shouldCapture)) return;
    var index = 0;
    for (final entry in _failureStates.entries) {
      if (!shouldCapture(entry.value)) continue;
      final failure = entry.key;
      adapter.catalogFailure = failure;
      await _connectFreshServer(app, auth, adapter, template, '${++index}');
      final title = _titles[failure]!;
      for (var attempt = 0; attempt < 6; attempt++) {
        if (find.text(title).evaluate().isNotEmpty) break;
        // 2s / 6s / 20s 三次静默重试后才会显示错误态。
        await tester.pump(const Duration(seconds: 21));
        await advance(300);
      }
      expect(
        find.text(title),
        findsWidgets,
        reason: '${entry.value} 必须显示独立标题而不是通用空态',
      );
      expect(
        find.text(_primaryLabels[failure]!),
        findsWidgets,
        reason: '${entry.value} 缺少主操作',
      );
      expect(
        find.text(_secondaryLabels[failure]!),
        findsWidgets,
        reason: '${entry.value} 缺少次操作',
      );
      await save(entry.value);
    }
    adapter.catalogFailure = null;
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
