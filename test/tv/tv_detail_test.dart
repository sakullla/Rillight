import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/tv_shell.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/library/tv_detail_page.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/tv_player_page.dart';
import 'package:rillight/player/video_backend.dart';
import '../emby/fake_emby_server.dart';
import '../helpers/image_cache_fixture.dart';

void main() {
  setUp(isolateImageCache);
  Future<RillightApp> start(WidgetTester tester, FakeEmbyServer server) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final auth = AuthController.memory(
      client: EmbyClient(
        device: const EmbyDeviceInfo(
          clientName: 'test',
          deviceName: 'tv',
          deviceId: 'tv-widget',
          version: '1',
        ),
        dio: dioForFakeEmby(FakeEmbyAdapter([server])),
      ),
    );
    final app = RillightApp(
      auth: auth,
      environment: PresentationEnvironment.tv,
      playerBindings: PlayerBindings(
        createBackend: () => FakeVideoBackend(),
        snapshotStore: MemoryPlaybackSessionSnapshotStore(),
        settingsStore: MemoryPlayerSettingsStore(),
      ),
    );
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      app.router.dispose();
      auth.dispose();
    });
    return app;
  }

  Future<void> key(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pumpAndSettle();
  }

  Future<void> edit(WidgetTester tester, String text) async {
    await key(tester, LogicalKeyboardKey.select);
    expect(find.byKey(const Key('tv-input-editor')), findsOneWidget);
    // Text input represents the platform IME; all application navigation is D-pad.
    await tester.enterText(find.byKey(const Key('tv-input-editor')), text);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
  }

  Future<void> login(WidgetTester tester, FakeEmbyServer server) async {
    await edit(tester, server.baseUrl.toString());
    await key(tester, LogicalKeyboardKey.arrowDown);
    await edit(tester, 'alice');
    await key(tester, LogicalKeyboardKey.arrowDown);
    await edit(tester, 'correct-horse');
    await key(tester, LogicalKeyboardKey.arrowDown);
    await key(tester, LogicalKeyboardKey.arrowDown);
    await key(tester, LogicalKeyboardKey.select);
    expect(find.byType(TvShell), findsOneWidget);
  }

  Future<void> openItem(WidgetTester tester, RillightApp app, String id) async {
    unawaited(app.router.push(AppRoutes.item(id)));
    await tester.pumpAndSettle();
  }

  Finder focusedAction() => find.byWidgetPredicate(
    (w) =>
        w is Semantics &&
        w.properties.focused == true &&
        w.properties.button == true,
  );
  String focusedLabel(WidgetTester tester) => tester
      .widgetList<Text>(
        find.descendant(of: focusedAction(), matching: find.byType(Text)),
      )
      .map((t) => t.data)
      .join(' ');

  int detailRequests(FakeEmbyServer server, String itemId) => server.requests
      .where((r) => r.startsWith('GET') && r.contains('/Items/$itemId'))
      .length;

  testWidgets(
    'series detail shows immersive header, episode states and refreshes after remote play',
    (tester) async {
      const minute = 10000000 * 60;
      final server = FakeEmbyServer();
      server.setEpisodes('series-friends', [
        const FakeEpisode(
          id: 'episode-friends-s1e1',
          name: 'The Pilot',
          seasonId: 'season-friends-1',
          indexNumber: 1,
          parentIndexNumber: 1,
          played: true,
          runTimeTicks: minute * 22,
        ),
        const FakeEpisode(
          id: 'episode-friends-s1e2',
          name: 'The One with the Resume',
          seasonId: 'season-friends-1',
          indexNumber: 2,
          parentIndexNumber: 1,
          playbackPositionTicks: minute * 5,
          playedPercentage: 20,
          runTimeTicks: minute * 22,
          primaryImageTag: 'tag-e2',
        ),
        const FakeEpisode(
          id: 'episode-friends-s1e3',
          name: 'The Next One',
          seasonId: 'season-friends-1',
          indexNumber: 3,
          parentIndexNumber: 1,
          runTimeTicks: minute * 22,
        ),
      ]);
      final app = await start(tester, server);
      await login(tester, server);
      await openItem(tester, app, 'series-friends');

      expect(find.byType(TvDetailPage), findsOneWidget);
      expect(find.byKey(const Key('tv-detail-backdrop')), findsOneWidget);
      expect(find.byKey(const Key('tv-detail-episodes')), findsOneWidget);

      // 续播集是主操作,自动聚焦在播放上。
      expect(focusedLabel(tester), '继续播放');

      // 当前集(续播目标)有可识别标识,行内带进度条;已看集有已看标记。
      final currentTile = find.byKey(const ValueKey('episode-friends-s1e2'));
      expect(
        find.descendant(
          of: currentTile,
          matching: find.byKey(const Key('tv-episode-current')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: currentTile,
          matching: find.byType(LinearProgressIndicator),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('episode-friends-s1e1')),
          matching: find.textContaining('已看'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('episode-friends-s1e3')),
          matching: find.textContaining('已看'),
        ),
        findsNothing,
      );

      // 遥控器确认开播;返回后详情重新加载,分集进度/已看状态随刷新更新。
      // 播放器会拦截返回键(先收控制层/结束页),逐级弹出直到回到详情。
      final before = detailRequests(server, 'series-friends');
      await key(tester, LogicalKeyboardKey.select);
      expect(find.byType(TvPlayerPage), findsOneWidget);
      for (
        var i = 0;
        i < 4 && find.byType(TvDetailPage).evaluate().isEmpty;
        i++
      ) {
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 4));
        await tester.pumpAndSettle();
      }
      expect(find.byType(TvDetailPage), findsOneWidget);
      expect(
        detailRequests(server, 'series-friends'),
        greaterThan(before),
        reason: '播放返回后详情必须重新拉取,分集进度与已看状态才刷新',
      );
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  testWidgets(
    'remote selects an episode from the list and returns to the series',
    (tester) async {
      final server = FakeEmbyServer();
      final app = await start(tester, server);
      await login(tester, server);
      await openItem(tester, app, 'series-friends');

      // 焦点从播放出发,纯方向键下移到分集行。
      expect(focusedLabel(tester), '播放');
      for (
        var i = 0;
        i < 15 && !focusedLabel(tester).contains('The Pilot');
        i++
      ) {
        await key(tester, LogicalKeyboardKey.arrowDown);
      }
      expect(focusedLabel(tester), contains('The Pilot'));
      await key(tester, LogicalKeyboardKey.select);

      // 单集详情:头部为集名(标题栏与头部各一处),且单集提供标记已看操作。
      expect(find.text('The Pilot'), findsWidgets);
      expect(find.byKey(const Key('tv-detail-played-toggle')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('tv-detail-played-toggle')),
          matching: find.text('标记未看'),
        ),
        findsOneWidget,
      );

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tv-detail-episodes')), findsOneWidget);
      expect(focusedAction(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  testWidgets(
    'movie detail toggles played state optimistically and hides episode section',
    (tester) async {
      final server = FakeEmbyServer();
      final app = await start(tester, server);
      await login(tester, server);
      await openItem(tester, app, 'movie-inception');

      expect(find.byKey(const Key('tv-detail-backdrop')), findsOneWidget);
      // 无分集数据(电影)时分集区隐藏。
      expect(find.byKey(const Key('tv-detail-episodes')), findsNothing);
      expect(find.byKey(const ValueKey('season-friends-1')), findsNothing);

      final toggle = find.byKey(const Key('tv-detail-played-toggle'));
      expect(
        find.descendant(of: toggle, matching: find.text('标记已看')),
        findsOneWidget,
      );
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(
        server.items.firstWhere((item) => item.id == 'movie-inception').played,
        isTrue,
      );
      expect(
        find.descendant(of: toggle, matching: find.text('标记未看')),
        findsOneWidget,
      );
      expect(find.byType(SnackBar), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();

      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(
        server.items.firstWhere((item) => item.id == 'movie-inception').played,
        isFalse,
      );
      expect(
        find.descendant(of: toggle, matching: find.text('标记已看')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );
}
