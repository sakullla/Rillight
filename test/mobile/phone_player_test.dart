import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/app/tv_shell.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/player/danmaku/danmaku_hash.dart';
import 'package:rillight/player/danmaku/danmaku_keys.dart';
import 'package:rillight/player/danmaku/danmaku_renderer.dart';
import 'package:rillight/player/danmaku/dandanplay_client.dart';
import 'package:rillight/player/danmaku/dandanplay_models.dart';
import 'package:rillight/player/mobile_player_page.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/phone_orientation.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_controller.dart';
import 'package:rillight/player/player_keys.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/tv_player_page.dart';
import 'package:rillight/player/video_backend.dart';

import '../emby/fake_emby_server.dart';

const _device = EmbyDeviceInfo(
  clientName: 'test',
  deviceName: 'phone',
  deviceId: 'phone-player',
  version: '1',
);

void main() {
  Future<AuthController> login(FakeEmbyServer server) async {
    final auth = AuthController(
      client: EmbyClient(
        device: _device,
        dio: dioForFakeEmby(FakeEmbyAdapter([server])),
      ),
      credentials: MemoryCredentialStore(),
      servers: MemoryServerListStore(),
    );
    await auth.connect(
      address: server.baseUrl.toString(),
      username: 'alice',
      password: 'correct-horse',
    );
    return auth;
  }

  Future<PlayerController> showPlayer(
    WidgetTester tester, {
    required String itemId,
    FakeVideoBackend? backend,
    PlayerSettingsStore? settings,
    DandanplayClient? danmakuClient,
    PhoneOrientation? orientation,
    PhonePlaybackWakeLock? wakeLock,
    DanmakuStreamHasher? hasher,
    Size size = const Size(800, 360),
    Duration? mediaDuration,
  }) async {
    final server = FakeEmbyServer();
    final auth = await tester.runAsync(() => login(server));
    final video = backend ?? FakeVideoBackend();
    if (mediaDuration != null) video.duration = mediaDuration;
    addTearDown(auth!.dispose);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 4));
      await tester.pump();
    });
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      AuthScope(
        controller: auth,
        child: PlayerScope(
          bindings: PlayerBindings(
            createBackend: () => video,
            settingsStore: settings ?? MemoryPlayerSettingsStore(),
            snapshotStore: MemoryPlaybackSessionSnapshotStore(),
            danmakuClient: danmakuClient,
          ),
          child: MaterialApp(
            locale: const Locale('zh', 'CN'),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            theme: AppTheme.dark(),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => MobilePlayerPage(
                          itemId: itemId,
                          orientation: orientation,
                          wakeLock: wakeLock,
                          danmakuHasher: hasher,
                        ),
                      ),
                    );
                  },
                  child: const Text('open-player'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open-player'));
    await tester.pump();
    PlayerController? ready;
    for (var i = 0; i < 40; i++) {
      final page = find.byType(MobilePlayerPage);
      if (page.evaluate().isNotEmpty) {
        final current = tester.state<MobilePlayerPageState>(page).controller;
        if (current != null && !current.loading) {
          ready = current;
          break;
        }
      }
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pump(const Duration(milliseconds: 400));
    if (ready == null || ready.loading) fail('player did not become ready');
    return ready;
  }

  Future<void> closePlayer(WidgetTester tester) async {
    final button = find.byTooltip('关闭');
    expect(button, findsOneWidget);
    await tester.ensureVisible(button);
    await tester.tap(button);
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 200));
      if (find.byType(MobilePlayerPage).evaluate().isEmpty) return;
    }
    expect(find.byType(MobilePlayerPage), findsNothing);
  }

  testWidgets(
    'landscape request restores the entry direction and survives failure',
    (tester) async {
      final orientation = PhoneOrientation(
        restoreTo: const [DeviceOrientation.portraitUp],
        request: (orientations) async {},
      );
      final current = await showPlayer(
        tester,
        itemId: 'movie-inception',
        orientation: orientation,
        wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
      );
      expect(current.error, isNull);
      expect(orientation.calls.first, PhoneOrientation.landscape);
      await closePlayer(tester);
      await orientation.settled;
      expect(find.byType(MobilePlayerPage), findsNothing);
      expect(orientation.calls[1], const [DeviceOrientation.portraitUp]);
      expect(orientation.calls.last, PhoneOrientation.unlocked);
    },
  );

  testWidgets('a failed orientation request still starts playback', (
    tester,
  ) async {
    final denied = PhoneOrientation(
      restoreTo: const [DeviceOrientation.portraitUp],
      request: (_) async => throw StateError('orientation denied'),
    );
    final failed = await showPlayer(
      tester,
      itemId: 'movie-inception',
      orientation: denied,
      wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
    );
    expect(failed.error, isNull);
    expect(failed.loading, isFalse);
    expect(denied.calls.first, PhoneOrientation.landscape);
    expect(denied.lastError, isA<StateError>());
    expect(find.byType(MobilePlayerPage), findsOneWidget);
    await closePlayer(tester);
  });

  testWidgets('turning back to portrait keeps the phone player usable', (
    tester,
  ) async {
    final backend = FakeVideoBackend();
    final current = await showPlayer(
      tester,
      itemId: 'movie-inception',
      backend: backend,
      wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
    );
    expect(backend.isPlaying, isTrue);
    tester.view.physicalSize = const Size(360, 800);
    await tester.pump();
    expect(find.byType(MobilePlayerPage), findsOneWidget);
    expect(find.byType(TvShell), findsNothing);
    expect(find.byType(TvPlayerPage), findsNothing);
    await tester.ensureVisible(find.byKey(const Key('mobile-player-toggle')));
    await tester.tap(find.byKey(const Key('mobile-player-toggle')));
    await tester.pumpAndSettle();
    expect(backend.isPlaying, isFalse);
    await tester.tap(find.byTooltip('快进 10 秒'));
    await tester.pumpAndSettle();
    expect(backend.position, greaterThan(Duration.zero));
    expect(current.error, isNull);
    await closePlayer(tester);
  });

  testWidgets('next episode countdown can be cancelled or played immediately', (
    tester,
  ) async {
    final backend = FakeVideoBackend();
    final current = await showPlayer(
      tester,
      itemId: 'episode-friends-s1e1',
      backend: backend,
      wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
    );
    expect(current.nextEpisode, isNull);
    backend.completePlayback();
    for (var i = 0; i < 20; i++) {
      if (current.nextEpisode?.remaining != null) break;
      await tester.pump(Duration.zero);
    }
    expect(current.nextEpisode?.remaining, const Duration(seconds: 10));
    expect(find.text('10 秒后播放下一集'), findsOneWidget);
    await tester.ensureVisible(find.byKey(PlayerKeys.nextEpisodeCancel));
    await tester.tap(find.byKey(PlayerKeys.nextEpisodeCancel));
    await tester.pump(const Duration(seconds: 12));
    expect(current.itemId, 'episode-friends-s1e1');
    expect(current.nextEpisode, isNull);
    expect(backend.openCount, 1);
    await closePlayer(tester);
  });

  testWidgets('next episode play starts the following episode immediately', (
    tester,
  ) async {
    final playing = FakeVideoBackend();
    final next = await showPlayer(
      tester,
      itemId: 'episode-friends-s1e1',
      backend: playing,
      wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
    );
    playing.completePlayback();
    for (var i = 0; i < 20; i++) {
      if (next.nextEpisode?.remaining != null) break;
      await tester.pump(Duration.zero);
    }
    expect(find.text('10 秒后播放下一集'), findsOneWidget);
    await tester.ensureVisible(find.byKey(PlayerKeys.nextEpisodePlay));
    await tester.tap(find.byKey(PlayerKeys.nextEpisodePlay));
    for (var i = 0; i < 40; i++) {
      if (next.itemId == 'episode-friends-s1e2' && !next.loading) break;
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(next.itemId, 'episode-friends-s1e2');
    expect(playing.openCount, greaterThan(1));
    await closePlayer(tester);
  });

  testWidgets('a movie does not offer a next-episode countdown', (
    tester,
  ) async {
    final movie = FakeVideoBackend();
    final film = await showPlayer(
      tester,
      itemId: 'movie-inception',
      backend: movie,
      wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
    );
    movie.completePlayback();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(film.nextEpisode, isNull);
    expect(find.byKey(PlayerKeys.nextEpisode), findsNothing);
    await closePlayer(tester);
  });

  testWidgets('danmaku can be shown, hidden, and fail without stopping video', (
    tester,
  ) async {
    final settings = MemoryPlayerSettingsStore(
      const PlayerSettings(danmakuAppId: 'app', danmakuToken: 'secret'),
    );
    final backend = FakeVideoBackend();
    final current = await showPlayer(
      tester,
      itemId: 'movie-inception',
      backend: backend,
      settings: settings,
      danmakuClient: _CommentClient(),
      hasher: _NullHasher(),
      wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
    );
    for (var i = 0; i < 40; i++) {
      if (find.byType(DanmakuView).evaluate().isNotEmpty) break;
      await tester.pump(const Duration(milliseconds: 20));
    }
    final view = tester.widget<DanmakuView>(find.byType(DanmakuView));
    expect(view.controller.danmakuOn, isTrue);
    expect(view.controller.comments.single.text, '滚动评论');
    expect(backend.isPlaying, isTrue);
    expect(current.error, isNull);
    await tester.ensureVisible(find.byKey(const Key('mobile-player-danmaku')));
    await tester.tap(find.byKey(const Key('mobile-player-danmaku')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(DanmakuKeys.opacity), findsOneWidget);
    expect(find.byKey(DanmakuKeys.fontScale), findsOneWidget);
    await tester.ensureVisible(find.byKey(DanmakuKeys.toggle));
    await tester.tap(find.byKey(DanmakuKeys.toggle));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(view.controller.danmakuOn, isFalse);
    expect(view.controller.comments, isEmpty);
    expect(backend.isPlaying, isTrue);
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await closePlayer(tester);
  });

  testWidgets('danmaku failure leaves the film playing', (tester) async {
    final failingBackend = FakeVideoBackend();
    final failing = await showPlayer(
      tester,
      itemId: 'movie-inception',
      backend: failingBackend,
      settings: MemoryPlayerSettingsStore(
        const PlayerSettings(danmakuAppId: 'app', danmakuToken: 'secret'),
      ),
      danmakuClient: _FailingDanmakuClient(),
      hasher: _NullHasher(),
      wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
    );
    for (var i = 0; i < 40; i++) {
      if (find
          .byKey(const Key('mobile-danmaku-failure'))
          .evaluate()
          .isNotEmpty) {
        break;
      }
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.textContaining('弹幕服务不可达'), findsWidgets);
    expect(failing.error, isNull);
    expect(failingBackend.isPlaying, isTrue);
    await tester.ensureVisible(find.byKey(const Key('mobile-danmaku-off')));
    await tester.tap(find.byKey(const Key('mobile-danmaku-off')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const Key('mobile-danmaku-failure')), findsNothing);
    expect(failingBackend.isPlaying, isTrue);
    await closePlayer(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'screen stays on only while playing and background stays paused',
    (tester) async {
      final calls = <bool>[];
      final wake = PhonePlaybackWakeLock(
        toggle: (enabled) async {
          calls.add(enabled);
        },
      );
      final backend = FakeVideoBackend(
        duration: const Duration(hours: 1, minutes: 5),
      );
      final current = await showPlayer(
        tester,
        itemId: 'movie-inception',
        backend: backend,
        wakeLock: wake,
        mediaDuration: const Duration(hours: 1, minutes: 5),
      );
      await wake.settled;
      expect(calls, [true]);
      expect(wake.held, isTrue);
      expect(current.duration.inHours, greaterThan(0));
      final hours = current.duration.inHours;
      final minutes = current.duration.inMinutes
          .remainder(60)
          .toString()
          .padLeft(2, '0');
      final seconds = (current.duration.inSeconds % 60).toString().padLeft(
        2,
        '0',
      );
      expect(find.text('$hours:$minutes:$seconds'), findsOneWidget);
      final slider = tester.widget<Slider>(
        find.byKey(const Key('mobile-player-volume')),
      );
      slider.onChanged!(40);
      await tester.pump();
      expect(current.volume, 40);
      expect(backend.volume, 40);

      await tester.tap(find.byKey(const Key('mobile-player-toggle')));
      await tester.pump();
      await wake.settled;
      expect(backend.isPlaying, isFalse);
      expect(calls.last, isFalse);

      await tester.tap(find.byKey(const Key('mobile-player-toggle')));
      await tester.pump();
      await wake.settled;
      expect(calls.last, isTrue);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pumpAndSettle();
      await wake.settled;
      expect(backend.isPlaying, isFalse);
      expect(wake.held, isFalse);
      expect(calls.last, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      await wake.settled;
      expect(backend.openCount, 2);
      expect(backend.openedPaused, isTrue);
      expect(backend.isPlaying, isFalse);
      expect(wake.held, isFalse);
      expect(find.text('画中画'), findsNothing);
      await closePlayer(tester);
      expect(tester.takeException(), isNull);
    },
  );
}

class _NullHasher extends DanmakuStreamHasher {
  _NullHasher() : super(dio: Dio());

  @override
  Future<String?> hashOf(Uri streamUrl) async => null;
}

class _CommentClient extends DandanplayClient {
  _CommentClient() : super(dio: Dio());

  @override
  Future<DanmakuMatchResponse> match(
    DandanplaySource source, {
    required String fileName,
    required String fileHash,
    required int fileSize,
    required int videoDuration,
    String matchMode = 'hashAndFileName',
    CancelToken? cancelToken,
  }) async {
    return const DanmakuMatchResponse(
      isMatched: true,
      matches: [
        DanmakuMatchCandidate(
          animeId: 1,
          animeTitle: 'Inception',
          episodeId: 7,
          episodeTitle: '正片',
        ),
      ],
    );
  }

  @override
  Future<List<DanmakuComment>> fetchComments(
    DandanplaySource source,
    int episodeId, {
    int? serverTimestamp,
    CancelToken? cancelToken,
  }) async {
    return const [
      DanmakuComment(cid: 1, time: 1, mode: 1, color: 16777215, text: '滚动评论'),
    ];
  }

  @override
  Future<List<DanmakuAnime>> searchAnime(
    DandanplaySource source,
    String keyword, {
    CancelToken? cancelToken,
  }) async {
    return const [];
  }

  @override
  Future<List<DanmakuAnime>> searchEpisodes(
    DandanplaySource source, {
    required String anime,
    int? episode,
    CancelToken? cancelToken,
  }) async {
    return const [];
  }
}

class _FailingDanmakuClient extends DandanplayClient {
  _FailingDanmakuClient() : super(dio: Dio());

  static const _failure = DanmakuApiException(
    DanmakuApiFailureKind.unreachable,
    detail: 'down',
  );

  @override
  Future<DanmakuMatchResponse> match(
    DandanplaySource source, {
    required String fileName,
    required String fileHash,
    required int fileSize,
    required int videoDuration,
    String matchMode = 'hashAndFileName',
    CancelToken? cancelToken,
  }) async {
    throw _failure;
  }

  @override
  Future<List<DanmakuComment>> fetchComments(
    DandanplaySource source,
    int episodeId, {
    int? serverTimestamp,
    CancelToken? cancelToken,
  }) async {
    throw _failure;
  }

  @override
  Future<List<DanmakuAnime>> searchAnime(
    DandanplaySource source,
    String keyword, {
    CancelToken? cancelToken,
  }) async {
    throw _failure;
  }

  @override
  Future<List<DanmakuAnime>> searchEpisodes(
    DandanplaySource source, {
    required String anime,
    int? episode,
    CancelToken? cancelToken,
  }) async {
    throw _failure;
  }
}
