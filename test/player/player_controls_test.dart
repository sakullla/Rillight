@Tags(['integration'])
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/library/item_detail_page.dart';
import 'package:rillight/player/playback_models.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/player_controller.dart';
import 'package:rillight/player/player_keys.dart';
import 'package:rillight/player/player_page.dart';
import 'package:rillight/player/player_window.dart';
import 'package:rillight/player/video_backend.dart';

import '../emby/fake_emby_server.dart';

const _device = EmbyDeviceInfo(
  clientName: '灯川 Rillight',
  deviceName: 'test',
  deviceId: 'device-player-ui',
  version: '0.1.0',
);

void main() {
  late FakeEmbyServer server;
  late FakeEmbyAdapter adapter;
  late FakeVideoBackend backend;
  late PlayerWindow window;
  late MemoryPlaybackSessionSnapshotStore snapshots;

  setUp(() {
    server = FakeEmbyServer();
    adapter = FakeEmbyAdapter([server]);
    backend = FakeVideoBackend();
    window = PlayerWindow();
    snapshots = MemoryPlaybackSessionSnapshotStore();
  });

  PlayerBindings bindings({
    Duration hideAfter = const Duration(days: 1),
    Duration progressInterval = const Duration(seconds: 10),
    PlayerSettingsStore? settingsStore,
  }) {
    return PlayerBindings(
      createBackend: () => backend,
      window: window,
      progressInterval: progressInterval,
      controlsHideAfter: hideAfter,
      nextEpisodeCountdown: const Duration(seconds: 3),
      settingsStore: settingsStore,
      snapshotStore: snapshots,
    );
  }

  Future<AuthController> pumpLoggedIn(
    WidgetTester tester, {
    Duration hideAfter = const Duration(days: 1),
    Duration progressInterval = const Duration(seconds: 10),
    PlayerSettingsStore? settingsStore,
  }) async {
    final auth = AuthController(
      client: EmbyClient(device: _device, dio: dioForFakeEmby(adapter)),
      credentials: MemoryCredentialStore(),
      servers: MemoryServerListStore(),
    );
    await tester.runAsync(() {
      return auth.connect(
        address: server.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      );
    });
    expect(auth.isLoggedIn, isTrue);
    await tester.pumpWidget(
      RillightApp(
        auth: auth,
        playerBindings: bindings(
          hideAfter: hideAfter,
          progressInterval: progressInterval,
          settingsStore: settingsStore ?? MemoryPlayerSettingsStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return auth;
  }

  /// 不经 widget 树直接驱动的控制器(真实异步),用于断言 close() 的
  /// Stopped→onClose 顺序与 3 秒上限。
  Future<PlayerController> startStandaloneController({
    VoidCallback? onClose,
    ValueChanged<String>? onOpenItem,
    void Function(String itemId, {String? seasonId})? onOpenItemDetail,
    Duration progressInterval = const Duration(seconds: 10),
    String itemId = 'movie-up',
  }) async {
    final client = EmbyClient(device: _device, dio: dioForFakeEmby(adapter));
    final auth = AuthController(
      client: client,
      credentials: MemoryCredentialStore(),
      servers: MemoryServerListStore(),
    );
    await auth.connect(
      address: server.baseUrl.toString(),
      username: 'alice',
      password: 'correct-horse',
    );
    expect(auth.isLoggedIn, isTrue);
    final controller = PlayerController(
      client: client,
      itemId: itemId,
      backend: backend,
      window: window,
      progressInterval: progressInterval,
      settingsStore: MemoryPlayerSettingsStore(),
      snapshotStore: snapshots,
      onClose: onClose,
      onOpenItem: onOpenItem,
      onOpenItemDetail: onOpenItemDetail,
    );
    await controller.start();
    expect(controller.loading, isFalse);
    expect(controller.resolved, isNotNull);
    return controller;
  }

  List<FakePlaybackEvent> stoppedEvents() =>
      server.playbackEvents.where((event) => event.kind == 'Stopped').toList();

  Future<void> waitFor(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 40; i++) {
      if (finder.evaluate().isNotEmpty) {
        return;
      }
      await tester.pump(const Duration(milliseconds: 20));
    }
    fail('never found $finder');
  }

  Future<void> waitForGone(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 40; i++) {
      if (finder.evaluate().isEmpty) {
        return;
      }
      await tester.pump(const Duration(milliseconds: 20));
    }
    fail('still found $finder');
  }

  Future<void> openPlayable(WidgetTester tester, String itemId) async {
    final item = find.byKey(CatalogKeys.item(itemId)).first;
    await tester.ensureVisible(item);
    await tester.tap(item);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(PlayerKeys.open));
    await tester.pump();
    await waitFor(tester, find.byType(PlayerPage));
    for (var i = 0; i < 40; i++) {
      if (find.byKey(PlayerKeys.playPause).evaluate().isNotEmpty ||
          find.byKey(PlayerKeys.resumeContinue).evaluate().isNotEmpty) {
        return;
      }
      await tester.pump(const Duration(milliseconds: 20));
    }
    fail('player did not show controls or resume prompt');
  }

  PlayerController controllerOf(WidgetTester tester) {
    return tester.state<PlayerPageState>(find.byType(PlayerPage)).controller!;
  }

  testWidgets('saved progress resumes without a continue-or-restart prompt', (
    tester,
  ) async {
    await pumpLoggedIn(tester);
    await openPlayable(tester, 'movie-inception');

    expect(find.text('要从上次的位置继续播放吗？'), findsNothing);
    expect(find.byKey(PlayerKeys.resumeContinue), findsNothing);
    await waitFor(tester, find.byKey(PlayerKeys.playPause));

    expect(find.byKey(PlayerKeys.volumePercent), findsOneWidget);
    expect(find.text('100%'), findsOneWidget);
    expect(backend.openedUrl, isNotNull);
    expect(backend.openedUrl!.queryParameters['static'], 'true');
    expect(backend.openedStart, greaterThan(Duration.zero));
    expect(
      server.playbackEvents.map((event) => event.kind),
      contains('Playing'),
    );
  });

  testWidgets('movie end shows replay card instead of a blank frame', (
    tester,
  ) async {
    await pumpLoggedIn(tester);
    await openPlayable(tester, 'movie-up');
    await waitFor(tester, find.byKey(PlayerKeys.playPause));

    backend.completePlayback();
    await tester.pump();
    await waitFor(tester, find.byKey(PlayerKeys.playbackEnded));
    expect(find.text('播放结束'), findsOneWidget);
    expect(find.byKey(PlayerKeys.replay), findsOneWidget);
    expect(find.byKey(PlayerKeys.nextEpisode), findsNothing);
    expect(find.byKey(PlayerKeys.playPause), findsNothing);

    final opens = backend.openCount;
    await tester.tap(find.byKey(PlayerKeys.replay));
    await tester.pump();
    await waitForGone(tester, find.byKey(PlayerKeys.playbackEnded));
    await waitFor(tester, find.byKey(PlayerKeys.playPause));
    expect(backend.openCount, opens + 1);
    expect(controllerOf(tester).playbackEnded, isFalse);
  });

  testWidgets('pausing on the last frame still shows the replay card', (
    tester,
  ) async {
    await pumpLoggedIn(tester);
    await openPlayable(tester, 'movie-up');
    await waitFor(tester, find.byKey(PlayerKeys.playPause));

    backend.pauseAtEndWithoutComplete(at: controllerOf(tester).duration);
    await tester.pump();
    await waitFor(tester, find.byKey(PlayerKeys.playbackEnded));
    expect(find.text('播放结束'), findsOneWidget);
    expect(find.byKey(PlayerKeys.replay), findsOneWidget);
    expect(find.byKey(PlayerKeys.nextEpisode), findsNothing);
    await tester.pump(PlayerController.stoppedDeadline);
    await tester.pump();
  });

  testWidgets('view series from the ended card opens series detail', (
    tester,
  ) async {
    await pumpLoggedIn(tester);
    await openPlayable(tester, 'episode-friends-s1e2');
    await waitFor(tester, find.byKey(PlayerKeys.playPause));

    backend.completePlayback();
    await tester.pump();
    await waitFor(tester, find.byKey(PlayerKeys.endedViewSeries));
    await tester.tap(find.byKey(PlayerKeys.endedViewSeries));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await waitForGone(tester, find.byType(PlayerPage));
    expect(find.text('条目不可用'), findsNothing);
    await waitFor(tester, find.byType(ItemDetailPage));
    final app = tester.widget<RillightApp>(find.byType(RillightApp));
    expect(app.router.state.uri.path, '/item/series-friends');
    expect(app.router.state.uri.queryParameters['season'], 'season-friends-1');
    await tester.pump(PlayerController.stoppedDeadline);
    await tester.pump();
  });

  test(
    'openEndedSeries opens series detail instead of playing the series',
    () async {
      String? detailId;
      String? detailSeasonId;
      String? openId;
      final controller = await startStandaloneController(
        itemId: 'episode-friends-s1e2',
        onOpenItem: (id) => openId = id,
        onOpenItemDetail: (id, {seasonId}) {
          detailId = id;
          detailSeasonId = seasonId;
        },
      );
      addTearDown(controller.dispose);

      controller.openEndedSeries();
      expect(detailId, 'series-friends');
      expect(detailSeasonId, 'season-friends-1');
      expect(openId, isNull);
      expect(controller.error, isNull);
    },
  );

  test(
    'openEndedSeries without a detail callback closes instead of playing',
    () async {
      final closed = Completer<void>();
      String? openId;
      final controller = await startStandaloneController(
        itemId: 'episode-friends-s1e2',
        onClose: closed.complete,
        onOpenItem: (id) => openId = id,
      );
      addTearDown(controller.dispose);

      controller.openEndedSeries();
      await closed.future.timeout(const Duration(seconds: 5));
      expect(openId, isNull);
    },
  );

  test(
    'episode pause at end offers the next episode without a completed event',
    () async {
      final controller = await startStandaloneController(
        itemId: 'episode-friends-s1e1',
      );
      addTearDown(controller.dispose);

      backend.pauseAtEndWithoutComplete(at: controller.duration);
      for (var i = 0; i < 50; i++) {
        if (controller.nextEpisode != null) {
          break;
        }
        await Future<void>.delayed(Duration.zero);
      }
      expect(controller.nextEpisode?.item.id, 'episode-friends-s1e2');
      expect(controller.playbackEnded, isFalse);
    },
  );

  testWidgets(
    'repeated progress failures keep the banner until a report succeeds',
    (tester) async {
      server.progressStatus = 500;
      await pumpLoggedIn(tester);
      await openPlayable(tester, 'movie-up');

      // 首次失败:4 秒后自动隐藏,无关闭钮。
      await tester.pump(const Duration(seconds: 10));
      await tester.pump();
      expect(find.byKey(PlayerKeys.progressSyncFailed), findsOneWidget);
      expect(controllerOf(tester).progressSyncPersistent, isFalse);
      expect(
        find.byKey(const Key('player-progress-sync-dismiss')),
        findsNothing,
      );
      await tester.pump(const Duration(seconds: 4));
      await tester.pump();
      expect(find.byKey(PlayerKeys.progressSyncFailed), findsNothing);

      // 连续第二次失败:持续显示,4 秒后仍在,带关闭钮。
      await tester.pump(const Duration(seconds: 6));
      await tester.pump();
      expect(find.byKey(PlayerKeys.progressSyncFailed), findsOneWidget);
      expect(find.text('进度同步失败'), findsOneWidget);
      expect(controllerOf(tester).progressSyncPersistent, isTrue);
      expect(
        find.byKey(const Key('player-progress-sync-dismiss')),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(find.byKey(PlayerKeys.progressSyncFailed), findsOneWidget);
      expect(backend.isPlaying, isTrue);

      // 下一次上报成功后消失。
      server.progressStatus = null;
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(find.byKey(PlayerKeys.progressSyncFailed), findsNothing);
      expect(controllerOf(tester).progressSyncPersistent, isFalse);
    },
  );

  test(
    'close waits for Stopped before onClose and reports the last position',
    () async {
      var stoppedAtClose = -1;
      final controller = await startStandaloneController(
        onClose: () => stoppedAtClose = stoppedEvents().length,
      );
      addTearDown(controller.dispose);

      await controller.seekTo(const Duration(seconds: 65));
      await controller.close();

      expect(stoppedAtClose, 1);
      final stopped = stoppedEvents();
      expect(stopped, hasLength(1));
      expect(
        stopped.single.body['PositionTicks'],
        ticksFromDuration(const Duration(seconds: 65)),
      );
      expect(snapshots.snapshot, isNull);
    },
  );

  test(
    'close gives up on a hanging Stopped within 3s and keeps the snapshot',
    () async {
      var closed = false;
      final controller = await startStandaloneController(
        onClose: () => closed = true,
      );
      addTearDown(controller.dispose);
      expect(snapshots.snapshot, isNotNull);

      server.sessionsHold = Completer<void>();
      addTearDown(() {
        final hold = server.sessionsHold;
        if (hold != null && !hold.isCompleted) {
          hold.complete();
        }
      });

      fakeAsync((async) {
        final closing = controller.close();
        expect(closed, isFalse);
        async.elapse(PlayerController.stoppedDeadline);
        async.flushMicrotasks();
        expect(closed, isTrue);
        closing.ignore();
      });

      // 假服务器在挂起前已记录事件:恰一次 Stopped;超时按失败处理,快照保留。
      expect(stoppedEvents(), hasLength(1));
      expect(snapshots.snapshot, isNotNull);
      expect(controller.progressSyncFailed, isTrue);
    },
  );

  test(
    'close waits for an in-flight Stopped started by setMaxBitrate',
    () async {
      var closeCount = 0;
      final controller = await startStandaloneController(
        onClose: () => closeCount++,
      );
      addTearDown(controller.dispose);

      server.sessionsHold = Completer<void>();
      addTearDown(() {
        final hold = server.sessionsHold;
        if (hold != null && !hold.isCompleted) {
          hold.complete();
        }
      });
      final switching = controller.setMaxBitrate(4000000);
      for (var i = 0; i < 50 && stoppedEvents().isEmpty; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(stoppedEvents(), isNotEmpty);
      expect(closeCount, 0);

      final closing = controller.close();
      await Future<void>.delayed(Duration.zero);
      expect(closeCount, 0);

      server.sessionsHold!.complete();
      await closing;
      await switching;

      expect(closeCount, 1);
      expect(stoppedEvents(), hasLength(1));
    },
  );

  test('a second close joins the first and fires onClose once', () async {
    var closeCount = 0;
    final controller = await startStandaloneController(
      onClose: () => closeCount++,
    );
    addTearDown(controller.dispose);
    server.sessionsHold = Completer<void>();
    addTearDown(() {
      final hold = server.sessionsHold;
      if (hold != null && !hold.isCompleted) {
        hold.complete();
      }
    });
    final first = controller.close();
    final second = controller.close();
    await Future<void>.delayed(Duration.zero);
    expect(closeCount, 0);
    server.sessionsHold!.complete();
    await Future.wait([first, second]);
    expect(closeCount, 1);
    expect(stoppedEvents(), hasLength(1));
  });

  test('close waits for snapshot delete before onClose', () async {
    final gated = _GatedDeleteStore();
    snapshots = gated;
    gated.deleteGate = Completer<void>();
    addTearDown(() {
      if (!gated.deleteGate!.isCompleted) {
        gated.deleteGate!.complete();
      }
    });

    var closed = false;
    Object? snapshotAtClose;
    final controller = await startStandaloneController(
      onClose: () {
        closed = true;
        snapshotAtClose = snapshots.snapshot;
      },
    );
    addTearDown(controller.dispose);
    expect(snapshots.snapshot, isNotNull);

    final closing = controller.close();
    await Future<void>.delayed(Duration.zero);
    expect(closed, isFalse);
    expect(snapshots.snapshot, isNotNull);

    gated.deleteGate!.complete();
    await closing;
    expect(closed, isTrue);
    expect(snapshotAtClose, isNull);
    expect(snapshots.snapshot, isNull);
    expect(snapshots.deleteCount, 1);
  });

  test('volume percent maps linearly to mpv volume', () {
    expect(mpvVolumeForPercent(0), 0.0);
    expect(mpvVolumeForPercent(10), 10.0);
    expect(mpvVolumeForPercent(17), 17.0);
    expect(mpvVolumeForPercent(50), 50.0);
    expect(mpvVolumeForPercent(90), 90.0);
    expect(mpvVolumeForPercent(100), 100.0);
    expect(mpvVolumeForPercent(120), 100.0);
    expect(mpvVolumeForPercent(-5), 0.0);
  });

  test('buffer fraction is cache end over duration', () {
    expect(
      playerBufferFraction(buffer: Duration.zero, duration: Duration.zero),
      0.0,
    );
    expect(
      playerBufferFraction(
        buffer: const Duration(minutes: 11),
        duration: const Duration(minutes: 22),
      ),
      0.5,
    );
    expect(
      playerBufferFraction(
        buffer: const Duration(minutes: 30),
        duration: const Duration(minutes: 22),
      ),
      1.0,
    );
  });

  test('episode list offset jumps by index without walking prior rows', () {
    expect(
      playerEpisodeListOffset(
        index: 0,
        itemCount: 120,
        itemExtent: 112,
        viewport: 560,
      ),
      0,
    );
    expect(
      playerEpisodeListOffset(
        index: 80,
        itemCount: 120,
        itemExtent: 112,
        viewport: 560,
      ),
      80 * 112 - 560 * 0.25,
    );
    expect(
      playerEpisodeListOffset(
        index: 119,
        itemCount: 120,
        itemExtent: 112,
        viewport: 560,
      ),
      120 * 112 - 560,
    );
  });

  test('episode window start fills a page around the current index', () {
    expect(playerEpisodeWindowStart(indexNumber: 1, total: 191), 0);
    expect(
      playerEpisodeWindowStart(indexNumber: 191, total: 191),
      191 - kPlayerEpisodePageSize,
    );
    expect(playerEpisodeWindowStart(indexNumber: 40, total: 191), 40 - 1 - 4);
  });
}

class _GatedDeleteStore extends MemoryPlaybackSessionSnapshotStore {
  Completer<void>? deleteGate;

  @override
  Future<void> delete() async {
    final gate = deleteGate;
    if (gate != null) {
      await gate.future;
    }
    await super.delete();
  }
}
