import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/phone_mine_page.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/app/tv_shell.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/auth/library_counts_panel.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/video_backend.dart';

import '../emby/fake_emby_server.dart';
import '../helpers/image_cache_fixture.dart';

const _device = EmbyDeviceInfo(
  clientName: '灯川 Rillight',
  deviceName: 'test',
  deviceId: 'device-library-counts',
  version: '0.1.0',
);

void main() {
  AuthController authController(List<FakeEmbyServer> servers) {
    final auth = AuthController.memory(
      client: EmbyClient(
        device: _device,
        dio: dioForFakeEmby(FakeEmbyAdapter(servers)),
      ),
    );
    addTearDown(auth.dispose);
    return auth;
  }

  Future<void> connect(AuthController auth, FakeEmbyServer target) {
    return auth.connect(
      address: target.baseUrl.toString(),
      username: 'alice',
      password: 'correct-horse',
    );
  }

  Future<void> until(bool Function() ready) async {
    for (var i = 0; i < 200 && !ready(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(ready(), isTrue);
  }

  test(
    'counts follow the current server, keeping zeros and other returned types',
    () async {
      // 空库 + 显式响应:统计按服务器返回如实展示,0 也保留。
      final server =
          FakeEmbyServer(
              baseUrl: Uri.parse('http://counts-one.test:8096'),
              items: const [],
            )
            ..itemCountsOverride = {
              'Movie': 7,
              'Series': 1,
              'Episode': 0,
              'Book': 0,
              'Photo': 3,
            };
      final auth = authController([server]);
      await connect(auth, server);
      await until(() => auth.libraryCounts != null);

      final counts = auth.libraryCounts!;
      expect(counts.movie, 7);
      expect(counts.series, 1);
      expect(counts.episode, 0);
      expect(
        counts.others.map((entry) => (entry.type, entry.count)),
        equals(const [('Book', 0), ('Photo', 3)]),
      );
      expect(auth.libraryCountsServerId, server.serverId);
      expect(auth.libraryCountsFailure, isNull);
      expect(auth.libraryCountsLoading, isFalse);
    },
  );

  test("switching servers replaces the counts with the new server's", () async {
    final one = FakeEmbyServer(
      baseUrl: Uri.parse('http://counts-one.test:8096'),
      items: const [],
    )..itemCountsOverride = {'Movie': 7, 'Series': 1, 'Episode': 2};
    final two = FakeEmbyServer(
      serverId: 'server-id-2',
      serverName: '第二台',
      baseUrl: Uri.parse('http://counts-two.test:8096'),
      items: const [],
    )..itemCountsOverride = {'Movie': 1, 'Series': 0, 'Episode': 0, 'Song': 9};
    final auth = authController([one, two]);

    await connect(auth, one);
    await until(() => auth.libraryCountsServerId == one.serverId);
    expect(auth.libraryCounts!.movie, 7);
    expect(auth.libraryCounts!.episode, 2);

    await connect(auth, two);
    await until(() => auth.libraryCountsServerId == two.serverId);
    expect(auth.libraryCounts!.movie, 1);
    expect(auth.libraryCounts!.series, 0);
    expect(auth.libraryCounts!.episode, 0);
    expect(
      auth.libraryCounts!.others.map((entry) => (entry.type, entry.count)),
      equals(const [('Song', 9)]),
    );

    // 切回第一台:数量随会话变回旧服务器。
    await auth.switchTo(one.serverId);
    await until(
      () =>
          auth.libraryCountsServerId == one.serverId &&
          auth.libraryCounts?.movie == 7,
    );
    expect(auth.libraryCounts!.episode, 2);
  });

  test(
    'a failed or forbidden fetch keeps the session and exposes the reason',
    () async {
      final server = FakeEmbyServer(
        baseUrl: Uri.parse('http://counts-hold.test:8096'),
        items: const [],
      )..itemCountsHold = Completer<void>();
      final auth = authController([server]);
      await connect(auth, server);

      // 加载中:未知不显示成 0,counts 保持为空。
      expect(auth.libraryCountsLoading, isTrue);
      expect(auth.libraryCounts, isNull);

      server.itemCountsStatus = 403;
      server.itemCountsHold!.complete();
      await until(() => auth.libraryCountsFailure != null);
      expect(auth.libraryCountsFailure!.statusCode, 403);
      expect(auth.libraryCountsFailure!.detail, 'HTTP 403: counts unavailable');
      expect(auth.libraryCounts, isNull);
      expect(auth.libraryCountsLoading, isFalse);

      // 页面保留:登录态、会话与线路都不因统计失败改变。
      final token = auth.session!.accessToken;
      expect(auth.isLoggedIn, isTrue);
      expect(auth.client.baseUrl, server.baseUrl);

      await auth.loadLibraryCounts();
      expect(auth.isLoggedIn, isTrue);
      expect(auth.session!.accessToken, token);
      expect(auth.libraryCountsFailure, isNotNull);
    },
  );

  testWidgets(
    'count panel shows per-type counts including zeros, loading and failure',
    (tester) async {
      Widget host({
        LibraryCounts? counts,
        bool loading = false,
        EmbyException? failure,
      }) {
        return MaterialApp(
          theme: AppTheme.dark(),
          locale: const Locale('zh'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: Scaffold(
            body: LibraryCountsPanel(
              counts: counts,
              loading: loading,
              failure: failure,
            ),
          ),
        );
      }

      await tester.pumpWidget(
        host(
          counts: const LibraryCounts(
            movie: 7,
            series: 1,
            episode: 0,
            others: [
              LibraryCountEntry(type: 'Photo', count: 3),
              LibraryCountEntry(type: 'Book', count: 0),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('电影 7'), findsOneWidget);
      expect(find.text('剧集 1'), findsOneWidget);
      expect(find.text('单集 0'), findsOneWidget);
      expect(find.text('照片 3'), findsOneWidget);
      expect(find.text('图书 0'), findsOneWidget);

      // 加载中:显示进度而不是 0。
      await tester.pumpWidget(host(counts: null, loading: true));
      await tester.pump();
      expect(find.byKey(LibraryCountsPanel.loadingKey), findsOneWidget);
      expect(find.text('单集 0'), findsNothing);

      // 失败:保留面板并显示原因。
      await tester.pumpWidget(
        host(
          failure: const EmbyException(
            EmbyFailureKind.unknown,
            statusCode: 403,
            detail: 'HTTP 403: counts unavailable',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(LibraryCountsPanel.failureKey), findsOneWidget);
      expect(find.text('HTTP 403: counts unavailable'), findsOneWidget);
      expect(find.text('电影 7'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'phone account prioritizes management without library statistics',
    (tester) async {
      tester.view.physicalSize = const Size(360, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final server =
          FakeEmbyServer(
              baseUrl: Uri.parse('http://counts-phone.test:8096'),
              items: const [],
            )
            ..itemCountsOverride = {
              'Movie': 12,
              'Series': 3,
              'Episode': 45,
              'Photo': 0,
            };
      final auth = authController([server]);
      await tester.runAsync(() async {
        await connect(auth, server);
        for (var i = 0; i < 100 && auth.libraryCounts == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      });
      expect(auth.libraryCounts, isNotNull);

      await tester.pumpWidget(
        AuthScope(
          controller: auth,
          child: PlayerScope(
            bindings: PlayerBindings(
              settingsStore: MemoryPlayerSettingsStore(),
            ),
            child: MaterialApp(
              theme: AppTheme.dark(),
              locale: const Locale('zh'),
              supportedLocales: AppLocalizations.supportedLocales,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              home: const Scaffold(body: PhoneMinePage()),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(PhoneMinePage.lineKey), findsOneWidget);
      expect(find.byKey(PhoneMinePage.settingsKey), findsOneWidget);
      expect(find.byType(LibraryCountsPanel), findsNothing);
      expect(find.text('库规模'), findsNothing);
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  testWidgets('tv settings prioritize server actions without statistics', (
    tester,
  ) async {
    isolateImageCache();
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final server =
        FakeEmbyServer(
            baseUrl: Uri.parse('http://counts-tv.test:8096'),
            items: const [],
          )
          ..itemCountsOverride = {
            'Movie': 5,
            'Series': 2,
            'Episode': 30,
            'Photo': 1,
          };
    final auth = authController([server]);
    await tester.runAsync(() async {
      await connect(auth, server);
      for (var i = 0; i < 100 && auth.libraryCounts == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });
    expect(auth.libraryCounts, isNotNull);

    final app = RillightApp(
      auth: auth,
      environment: PresentationEnvironment.tv,
      playerBindings: PlayerBindings(
        createBackend: () => FakeVideoBackend(),
        snapshotStore: MemoryPlaybackSessionSnapshotStore(),
        settingsStore: MemoryPlayerSettingsStore(),
      ),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      app.router.dispose();
    });
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();
    expect(find.byType(TvShell), findsOneWidget);

    FocusNode navFocus(int index) => tester
        .widget<FocusableActionDetector>(
          find.descendant(
            of: find.byKey(ValueKey('tv-nav-$index')),
            matching: find.byType(FocusableActionDetector),
          ),
        )
        .focusNode!;
    navFocus(3).requestFocus();
    FocusManager.instance.applyFocusChangesIfNeeded();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();

    expect(
      find.byKey(ValueKey('tv-line-add-${auth.session!.server.id}')),
      findsOneWidget,
    );
    expect(find.byType(LibraryCountsPanel), findsNothing);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);
}
