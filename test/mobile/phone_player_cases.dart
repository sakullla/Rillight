import 'package:rillight/aggregation/history/history_writer.dart';
import 'package:rillight/player/playback_runtime.dart';

import '../helpers/case_shard.dart';
import '../helpers/settle.dart';

import 'dart:async';
import 'dart:ui' as ui;
import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:dio/dio.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/app/ui/app_icons.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_motion.dart';
import 'package:rillight/app/widgets/option_pill.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/media_server/device.dart';
import 'package:rillight/player/danmaku/danmaku_hash.dart';
import 'package:rillight/player/danmaku/danmaku_keys.dart';
import 'package:rillight/player/danmaku/danmaku_renderer.dart';
import 'package:rillight/player/danmaku/dandanplay_client.dart';
import 'package:rillight/player/danmaku/dandanplay_models.dart';
import 'package:rillight/player/mobile_player_page.dart';
import 'package:rillight/player/source_switch_menu.dart';
import 'package:rillight/player/phone_player_controls.dart';
import 'package:rillight/player/phone_player_gestures.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/phone_orientation.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_controller.dart';
import 'package:rillight/media_server/playback.dart';
import 'package:rillight/player/player_keys.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/video_backend.dart';
import 'package:rillight/player/buffer_snapshot.dart';
import 'package:rillight/player/buffered_ranges_track.dart';

import '../emby/fake_emby_server.dart';

const _androidPlayerChannel = MethodChannel('rillight/android_core');

void _mockAndroidPlayerChannel(List<MethodCall> calls, {int sdk = 34}) {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(_androidPlayerChannel, (call) async {
    calls.add(call);
    if (call.method == 'androidSdkInt') return sdk;
    return null;
  });
  addTearDown(
    () => messenger.setMockMethodCallHandler(_androidPlayerChannel, null),
  );
}

List<bool> _systemBarHidden(List<MethodCall> calls) {
  return calls
      .where((call) => call.method == 'setSystemBarsHidden')
      .map((call) => (call.arguments as Map)['hidden'] as bool)
      .toList();
}

const _device = ClientDeviceInfo(
  clientName: 'test',
  deviceName: 'phone',
  deviceId: 'phone-player',
  version: '1',
);

void _setVideoSize(FakeEmbyServer server, String id, int width, int height) {
  final item = server.items.firstWhere((item) => item.id == id);
  item.mediaStreams = [
    FakeMediaStream(
      index: 0,
      type: 'Video',
      codec: 'h264',
      width: width,
      height: height,
    ),
    const FakeMediaStream(
      index: 1,
      type: 'Audio',
      codec: 'aac',
      isDefault: true,
      channels: 2,
    ),
  ];
}

void main() {
  Future<void> enterSection(WidgetTester tester, String section) async {
    final entry = find.byKey(ValueKey('mobile-player-section-$section'));
    await tester.ensureVisible(entry);
    await tester.pump();
    await tester.tap(entry);
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> closeOptions(WidgetTester tester) async {
    final back = find.widgetWithText(AppButton, '返回');
    await tester.ensureVisible(back);
    await tester.pump();
    await tester.tap(back);
    await tester.pump();
    expect(
      find.byKey(const Key('mobile-player-section-speed')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('mobile-player-options')), findsOneWidget);
    await tester.ensureVisible(back);
    await tester.pump();
    await tester.tap(back);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('mobile-player-options')), findsNothing);
  }

  Future<AuthController> login(FakeEmbyServer server) async {
    final alias = FakeEmbyServer(
      serverId: server.serverId,
      serverName: server.serverName,
      baseUrl: Uri.parse('https://mirror.example:8443'),
      views: server.views,
      items: server.items,
    );
    final auth = AuthController(
      client: EmbyClient(
        device: _device,
        dio: dioForFakeEmby(FakeEmbyAdapter([server, alias])),
      ),
      credentials: MemoryCredentialStore(),
      servers: MemoryServerListStore(),
    );
    await auth.connect(
      address: server.baseUrl.toString(),
      username: 'alice',
      password: 'correct-horse',
    );
    alias.issuedTokens.addAll(server.issuedTokens);
    return auth;
  }

  Future<PlayerController> showPlayer(
    WidgetTester tester, {
    required String itemId,
    FakeVideoBackend? backend,
    PlayerSettingsStore? settings,
    DandanplayClient? danmakuClient,
    PhoneOrientation? orientation,
    PhoneSystemBars? systemBars,
    PhonePlaybackWakeLock? wakeLock,
    void Function(FakeEmbyServer server)? prepare,
    DanmakuStreamHasher? hasher,
    PhoneDisplayControl? display,
    Size size = const Size(800, 360),
    Duration? mediaDuration,
    bool lightApp = false,
    bool withRuntime = false,
    Future<void> Function(AuthController auth)? prepareAuth,
  }) async {
    final server = FakeEmbyServer();
    prepare?.call(server);
    final auth = await tester.runAsync(() => login(server));
    if (prepareAuth != null) {
      await tester.runAsync(() => prepareAuth(auth!));
    }
    final video = backend ?? FakeVideoBackend();
    if (mediaDuration != null) video.duration = mediaDuration;
    addTearDown(auth!.dispose);
    final history = withRuntime
        ? await tester.runAsync(
            () => HistoryWriter.open(
              registry: auth.sources,
              store: MemoryHistoryStore(),
            ),
          )
        : null;
    if (history != null) {
      addTearDown(() async {
        var closed = false;
        final closing = history.close().then((_) => closed = true);
        for (var frame = 0; frame < 80 && !closed; frame++) {
          await tester.pump(const Duration(milliseconds: 50));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        expect(
          closed,
          isTrue,
          reason: 'History must drain after the player unmounts',
        );
        await closing;
      });
    }
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
            runtime: history == null
                ? null
                : PlaybackRuntime(auth: auth, history: history),
            createBackend: () => video,
            settingsStore: settings ?? MemoryPlayerSettingsStore(),
            snapshotStore: MemoryPlaybackSessionSnapshotStore(),
            danmakuClient: danmakuClient,
          ),
          child: CupertinoApp(
            locale: const Locale('zh', 'CN'),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: [
              AppLocalizations.delegate,
              ...GlobalCupertinoLocalizations.delegates,
            ],
            theme: lightApp
                ? AppUiTheme.light().cupertino
                : AppUiTheme.dark().cupertino,
            home: Builder(
              builder: (context) => CupertinoPageScaffold(
                child: AppButton(
                  onPressed: () {
                    Navigator.of(context).push(
                      CupertinoPageRoute<void>(
                        builder: (_) => MobilePlayerPage(
                          itemId: itemId,
                          orientation: orientation,
                          systemBars: systemBars,
                          wakeLock: wakeLock,
                          danmakuHasher: hasher,
                          displayControl: display,
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
        if (current != null &&
            !current.loading &&
            (!withRuntime ||
                current.activeLineId != null ||
                current.error != null)) {
          ready = current;
          break;
        }
      }
      await tester.pump(const Duration(milliseconds: 20));
      if (withRuntime) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
      }
    }
    final route = ModalRoute.of(tester.element(find.byType(MobilePlayerPage)))!;
    await tester.pump(route.transitionDuration);
    if (ready == null || ready.loading) {
      final current = tester
          .state<MobilePlayerPageState>(find.byType(MobilePlayerPage))
          .controller!;
      fail(
        'player did not become ready: loading=${current.loading}; '
        'line=${current.activeLineId}; failure=${current.playbackLineFailure}; '
        'load=${current.loadFailure}; disconnect=${current.disconnectDetail}',
      );
    }
    return ready;
  }

  Future<void> closePlayer(WidgetTester tester) async {
    final button = find.byKey(const Key('mobile-player-close'));
    expect(button, findsOneWidget);
    await tester.ensureVisible(button);
    await tester.tap(button);
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 200));
      if (find.byType(MobilePlayerPage).evaluate().isEmpty) return;
    }
    expect(find.byType(MobilePlayerPage), findsNothing);
  }

  cases.testWidgets(
    'phone PiP removes controls and keeps the same mounted video session',
    (tester) async {
      final backend = _PhonePresentationBackend();
      final c = await showPlayer(
        tester,
        itemId: 'movie-inception',
        backend: backend,
        wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
      );
      final opens = backend.openCount;
      await tester.tap(find.byKey(const Key('mobile-player-pip')));
      await tester.pump();
      expect(find.byKey(const Key('mobile-player-toggle')), findsNothing);
      expect(find.byType(PhonePlayerGestures), findsNothing);
      expect(backend.openCount, opens);
      expect(c.isPlaying, isTrue);
      backend.phonePresentation.value = {
        'supported': true,
        'foreground': true,
        'active': false,
      };
      await tester.pump();
      expect(find.byKey(const Key('mobile-player-toggle')), findsOneWidget);
      expect(backend.openCount, opens);
      await closePlayer(tester);
    },
    tags: ['integration'],
  );

  for (final size in [const Size(360, 800), const Size(800, 360)]) {
    cases.testWidgets(
      'phone large text keeps shortcuts and fixed panel exit reachable $size',
      (tester) async {
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await showPlayer(
          tester,
          itemId: 'movie-inception',
          size: size,
          wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
        );
        for (final name in ['speed', 'tracks', 'more']) {
          final button = find.byKey(Key('mobile-player-$name'));
          expect(button.hitTestable(), findsOneWidget);
          expect(tester.getRect(button).right, lessThanOrEqualTo(size.width));
        }
        await tester.tap(find.byKey(const Key('mobile-player-tracks')));
        await settle(tester);
        final exit = find.byKey(const Key('mobile-player-panel-close'));
        expect(exit.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(exit);
        await settle(tester);
        await closePlayer(tester);
      },
      tags: ['integration'],
    );
  }

  cases.testWidgets(
    'phone timeline paints verified cache coverage and updates network speed',
    (tester) async {
      final backend = FakeVideoBackend();
      final controller = await showPlayer(
        tester,
        itemId: 'movie-up',
        backend: backend,
      );
      backend.emitEvent(VideoEventKind.duration, const Duration(seconds: 100));
      backend.emitEvent(VideoEventKind.cacheSpeed, 2621440);
      backend.emitEvent(
        VideoEventKind.bufferSnapshot,
        BufferSnapshot(
          sessionId: controller.bufferSnapshot.sessionId,
          resourceId: 'fixture',
          representationVersion: 'v1',
          trackVersion: 0,
          sequence: 1,
          ranges: const [BufferedRange(Duration.zero, Duration(seconds: 60))],
        ),
      );
      await tester.pump();
      expect(find.text('2.5 MB/s'), findsOneWidget);
      final element = tester.element(
        find.byKey(const Key('mobile-player-seek')),
      );
      final box = element.findRenderObject()! as RenderBox;
      final boundary = element
          .findAncestorRenderObjectOfType<RenderRepaintBoundary>()!;
      final slider = tester.widget<PlayerSlider>(
        find.byKey(const Key('mobile-player-seek')),
      );
      final rect = Rect.fromLTWH(
        slider.padding.left,
        box.size.height / 2 - 1.5,
        box.size.width - slider.padding.horizontal,
        3,
      );
      final point = box.localToGlobal(
        Offset(rect.left + rect.width * .4, rect.center.dy),
        ancestor: boundary,
      );
      final bytes = await tester.runAsync(() async {
        final image = await boundary.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        final index = (point.dy.floor() * image.width + point.dx.floor()) * 4;
        final pixel = data!.buffer.asUint8List().sublist(index, index + 4);
        image.dispose();
        return pixel;
      });
      expect(bytes, [0x69, 0x77, 0x83, 0xff]);
      backend.emitEvent(VideoEventKind.cacheSpeed, 0);
      await settle(tester);
      expect(find.text('0 KB/s'), findsOneWidget);
      expect(controller.bufferSnapshot.ranges, isNotEmpty);
      await closePlayer(tester);
    },
    tags: ['integration'],
  );

  cases.testWidgets(
    'landscape options inherit the dark player inside a light application',
    (tester) async {
      await showPlayer(tester, itemId: 'movie-up', lightApp: true);
      await tester.tap(find.byKey(const Key('mobile-player-more')));
      await settle(tester);
      final panel = find.byKey(const Key('mobile-player-options'));
      final panelTheme = AppUiTheme.of(tester.element(panel));
      expect(panelTheme.brightness, Brightness.dark);
      expect(
        panelTheme.colorScheme.primary,
        AppUiTheme.phoneDark().colorScheme.primary,
      );
      expect(
        (tester.widget<Container>(panel).decoration! as BoxDecoration).color,
        AppUiTheme.phoneDark().colorScheme.surface,
      );
      await tester.tap(find.byKey(const Key('mobile-player-panel-close')));
      await settle(tester);
      await closePlayer(tester);
    },
    tags: ['integration'],
  );

  cases.testWidgets(
    'phone player keeps a black stage and phone-dark control chrome',
    (tester) async {
      await showPlayer(
        tester,
        itemId: 'movie-inception',
        wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
        size: const Size(360, 640),
      );
      final scaffold = tester.widget<CupertinoPageScaffold>(
        find.descendant(
          of: find.byType(MobilePlayerPage),
          matching: find.byType(CupertinoPageScaffold),
        ),
      );
      expect(scaffold.backgroundColor, CupertinoColors.black);
      final video = find.byWidgetPredicate(
        (widget) =>
            widget is ColoredBox && widget.color == const Color(0xFF000000),
      );
      expect(video, findsOneWidget);
      final theme = AppUiTheme.of(
        tester.element(find.byKey(const Key('mobile-player-toggle'))),
      );
      expect(theme.brightness, Brightness.dark);
      expect(
        theme.colorScheme.primary,
        AppUiTheme.phoneDark().colorScheme.primary,
      );
      expect(
        theme.colorScheme.surface,
        AppUiTheme.phoneDark().colorScheme.surface,
      );
      final play = tester.widget<AnimatedContainer>(
        find.descendant(
          of: find.byKey(const Key('mobile-player-toggle')),
          matching: find.byType(AnimatedContainer),
        ),
      );
      final playDecoration = play.decoration! as ShapeDecoration;
      expect(playDecoration.color, theme.colorScheme.primary);
      expect(playDecoration.shape, isA<CircleBorder>());
      final rewind = tester.widget<AnimatedContainer>(
        find.descendant(
          of: find.byKey(const Key('mobile-player-rewind')),
          matching: find.byType(AnimatedContainer),
        ),
      );
      expect(
        (rewind.decoration! as ShapeDecoration).color,
        const Color(0x29FFFFFF),
      );
      expect(find.byKey(const Key('mobile-player-dock')), findsNothing);
      await closePlayer(tester);
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  cases.test('picture orientation follows video width and height', () {
    expect(videoPictureIsLandscape(1920, 1080), isTrue);
    expect(videoPictureIsLandscape(1080, 1920), isFalse);
    expect(videoPictureIsLandscape(1080, 1080), isFalse);
    expect(videoPictureIsLandscape(null, 1080), isNull);
    expect(videoPictureIsLandscape(0, 1080), isNull);
  });

  cases.test(
    'old player cannot overwrite a newer picture orientation',
    () async {
      final gate = Completer<void>();
      late final PhoneOrientation a;
      a = PhoneOrientation(
        request: (_) async {
          if (a.calls.length == 1 && !gate.isCompleted) await gate.future;
        },
      );
      final b = PhoneOrientation(request: (_) async {});

      await a.enterPlayback();
      final first = a.applyPicture(landscape: true);
      await Future<void>.delayed(Duration.zero);
      expect(a.calls, [PhoneOrientation.landscape]);
      final oldLeave = a.leavePlayback();
      await b.enterPlayback();
      final newer = b.applyPicture(landscape: false);
      gate.complete();
      await first;
      await oldLeave;
      await newer;
      await a.settled;
      await b.settled;
      expect(a.calls, [PhoneOrientation.landscape]);
      expect(b.calls, [PhoneOrientation.portrait]);
    },
  );

  cases.test(
    'reentering the same orientation owner cancels its old exit',
    () async {
      final gate = Completer<void>();
      late final PhoneOrientation orientation;
      orientation = PhoneOrientation(
        request: (_) async {
          if (orientation.calls.length == 1 && !gate.isCompleted) {
            await gate.future;
          }
        },
      );

      await orientation.enterPlayback();
      final first = orientation.applyPicture(landscape: true);
      await Future<void>.delayed(Duration.zero);
      final oldLeave = orientation.leavePlayback();
      await orientation.enterPlayback();
      final second = orientation.applyPicture(landscape: true);
      gate.complete();
      await first;
      await oldLeave;
      await second;
      expect(orientation.calls, [
        PhoneOrientation.landscape,
        PhoneOrientation.landscape,
      ]);

      await orientation.leavePlayback();
      await orientation.settled;
      expect(orientation.calls.last, PhoneOrientation.unlocked);
    },
  );

  cases.testWidgets(
    'playback follows the video picture and exit does not force portrait',
    (tester) async {
      final orientation = PhoneOrientation(request: (orientations) async {});
      final current = await showPlayer(
        tester,
        itemId: 'movie-inception',
        orientation: orientation,
        wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
        prepare: (server) =>
            _setVideoSize(server, 'movie-inception', 1920, 1080),
      );
      expect(current.error, isNull);
      await orientation.settled;
      expect(orientation.calls, [PhoneOrientation.landscape]);
      await closePlayer(tester);
      await orientation.settled;
      expect(find.byType(MobilePlayerPage), findsNothing);
      expect(orientation.calls, [
        PhoneOrientation.landscape,
        PhoneOrientation.unlocked,
      ]);

      final portrait = PhoneOrientation(request: (_) async {});
      final vertical = await showPlayer(
        tester,
        itemId: 'movie-inception',
        orientation: portrait,
        wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
        prepare: (server) =>
            _setVideoSize(server, 'movie-inception', 1080, 1920),
      );
      expect(vertical.error, isNull);
      await portrait.settled;
      expect(portrait.calls, [PhoneOrientation.portrait]);
      await closePlayer(tester);
      await portrait.settled;
      expect(portrait.calls, [
        PhoneOrientation.portrait,
        PhoneOrientation.unlocked,
      ]);

      // 系统拒绝方向请求时播放仍要能启动，退出也不改成只允许竖屏。
      final denied = PhoneOrientation(
        request: (_) async => throw StateError('orientation denied'),
      );
      final failed = await showPlayer(
        tester,
        itemId: 'movie-inception',
        orientation: denied,
        wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
        prepare: (server) =>
            _setVideoSize(server, 'movie-inception', 1920, 1080),
      );
      expect(failed.error, isNull);
      expect(failed.loading, isFalse);
      await denied.settled;
      expect(denied.calls.first, PhoneOrientation.landscape);
      expect(denied.lastError, isA<StateError>());
      expect(find.byType(MobilePlayerPage), findsOneWidget);
      await closePlayer(tester);
      await denied.settled;
      expect(find.byType(MobilePlayerPage), findsNothing);
      expect(denied.calls.last, PhoneOrientation.unlocked);
    },
    tags: ['integration'],
  );

  cases.testWidgets(
    'decoded portrait geometry wins over landscape server metadata',
    (tester) async {
      final backend = _PhonePresentationBackend();
      final orientation = PhoneOrientation(request: (_) async {});
      final current = await showPlayer(
        tester,
        itemId: 'movie-inception',
        backend: backend,
        orientation: orientation,
        wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
        prepare: (server) =>
            _setVideoSize(server, 'movie-inception', 1920, 1080),
      );
      await orientation.settled;
      expect(orientation.calls, [PhoneOrientation.landscape]);
      backend.phonePresentation.value = {
        'supported': true,
        'foreground': true,
        'geometry': {
          'contentWidth': 1080,
          'contentHeight': 1920,
          'width': 360,
          'height': 640,
          'density': 1,
        },
      };
      await tester.pump();
      await orientation.settled;
      expect(orientation.calls.last, PhoneOrientation.portrait);
      // A subsequent playback notification used to reapply the stale metadata.
      current.toggleControls();
      await tester.pump();
      await orientation.settled;
      expect(orientation.calls, [
        PhoneOrientation.landscape,
        PhoneOrientation.portrait,
      ]);
      current.onUserActivity();
      await tester.pump(const Duration(milliseconds: 300));
      await closePlayer(tester);
      expect(orientation.calls.last, PhoneOrientation.unlocked);
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  cases.testWidgets(
    'phone blank control dock taps hide and reveal the timeline',
    (tester) async {
      final current = await showPlayer(
        tester,
        itemId: 'movie-inception',
        size: const Size(800, 360),
        wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
      );
      final timeline = find.byKey(const Key('mobile-player-seek'));
      final toggle = find.byKey(const Key('mobile-player-toggle'));
      final gap = Offset(400, tester.getCenter(toggle).dy);
      expect(current.controlsVisible, isTrue);
      await tester.tapAt(gap);
      await tester.pump(const Duration(milliseconds: 400));
      expect(current.controlsVisible, isFalse);
      expect(timeline.hitTestable(), findsNothing);
      await tester.tapAt(gap);
      await tester.pump(const Duration(milliseconds: 400));
      expect(current.controlsVisible, isTrue);
      expect(timeline.hitTestable(), findsOneWidget);
      // A button consumes its own tap; it must not also hide the controls.
      await tester.tap(toggle);
      await tester.pump(const Duration(milliseconds: 400));
      expect(current.controlsVisible, isTrue);
      // The center of the picture also toggles chrome while paused.
      await tester.tapAt(const Offset(400, 150));
      await tester.pump(const Duration(milliseconds: 400));
      expect(current.controlsVisible, isFalse);
      await tester.tapAt(const Offset(400, 150));
      await tester.pump(const Duration(milliseconds: 400));
      expect(current.controlsVisible, isTrue);
      await closePlayer(tester);
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  cases.testWidgets(
    'unknown picture starts fullscreen landscape and exit releases orientation',
    (tester) async {
      final orientation = PhoneOrientation(request: (_) async {});
      final player = await showPlayer(
        tester,
        itemId: 'movie-inception',
        size: const Size(360, 800),
        orientation: orientation,
        wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
      );
      await orientation.settled;
      expect(orientation.calls, [PhoneOrientation.landscape]);
      expect(player.error, isNull);
      expect(find.byKey(const Key('mobile-player-lock')), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (widget) => widget is AppTooltip && widget.message == '关闭',
        ),
        findsOneWidget,
      );

      await closePlayer(tester);
      await tester.pump();
      await orientation.settled;
      expect(orientation.calls, [
        PhoneOrientation.landscape,
        PhoneOrientation.unlocked,
      ]);
    },
    tags: ['integration'],
  );

  for (final size in [const Size(360, 800), const Size(800, 360)]) {
    cases.testWidgets('phone completion offers replay and close at $size', (
      tester,
    ) async {
      final backend = FakeVideoBackend(duration: const Duration(minutes: 96));
      final current = await showPlayer(
        tester,
        itemId: 'movie-up',
        backend: backend,
        size: size,
        wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
      );
      backend.completePlayback();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(seconds: 5));
      expect(find.byKey(PlayerKeys.playbackEnded), findsOneWidget);
      expect(find.byKey(PlayerKeys.endedViewSeries), findsNothing);
      expect(find.byKey(PlayerKeys.replay).hitTestable(), findsOneWidget);
      expect(find.byKey(PlayerKeys.endedClose).hitTestable(), findsOneWidget);
      final opens = backend.openCount;
      await tester.tap(find.byKey(PlayerKeys.replay));
      await settle(tester);
      expect(current.playbackEnded, isFalse);
      expect(backend.openCount, greaterThan(opens));
      expect(find.byKey(PlayerKeys.playbackEnded), findsNothing);
      backend.completePlayback();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.byKey(PlayerKeys.endedClose));
      for (
        var i = 0;
        i < 40 && find.byType(MobilePlayerPage).evaluate().isNotEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(find.byType(MobilePlayerPage), findsNothing);
    }, tags: ['integration']);
  }

  cases.testWidgets(
    'next episode countdown can be cancelled, played, or absent for movies',
    (tester) async {
      // 取消倒计时停留在本集。
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
      await tester.tap(find.byKey(const Key('mobile-player-lock')));
      await tester.pump();
      expect(find.byKey(PlayerKeys.nextEpisodePlay), findsNothing);
      await tester.tap(find.byKey(const Key('mobile-player-unlock')));
      await tester.pump();
      expect(find.byKey(PlayerKeys.nextEpisodePlay), findsOneWidget);
      await tester.ensureVisible(find.byKey(PlayerKeys.nextEpisodeCancel));
      await tester.tap(find.byKey(PlayerKeys.nextEpisodeCancel));
      await tester.pump(const Duration(seconds: 12));
      expect(current.itemId, 'episode-friends-s1e1');
      expect(current.nextEpisode, isNull);
      expect(backend.openCount, 1);
      await closePlayer(tester);

      // 立即播放切换到下一集。
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
      final nextCard = tester.getRect(find.byKey(PlayerKeys.nextEpisode));
      expect(nextCard.top, greaterThanOrEqualTo(0));
      expect(nextCard.bottom, lessThanOrEqualTo(360));
      expect(nextCard.left, greaterThanOrEqualTo(0));
      expect(nextCard.right, lessThanOrEqualTo(800));
      expect(
        find.byKey(PlayerKeys.nextEpisodePlay).hitTestable(),
        findsOneWidget,
      );
      await tester.ensureVisible(find.byKey(PlayerKeys.nextEpisodePlay));
      await tester.tap(find.byKey(PlayerKeys.nextEpisodePlay));
      for (var i = 0; i < 40; i++) {
        if (next.itemId == 'episode-friends-s1e2' && !next.loading) break;
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(next.itemId, 'episode-friends-s1e2');
      expect(playing.openCount, greaterThan(1));
      expect(playing.openedPaused, isFalse);
      expect(playing.isPlaying, isTrue);
      await closePlayer(tester);

      // 电影播完不出现下集倒计时。
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
    },
    tags: ['integration'],
  );

  cases.testWidgets(
    'danmaku works from the more panel and failure leaves the film playing',
    (tester) async {
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
      final danmakuRect = tester.getRect(find.byType(DanmakuView));
      final closeRect = tester.getRect(
        find.byKey(const Key('mobile-player-close')),
      );
      final titleRect = tester.getRect(
        find.byKey(const Key('mobile-player-title')),
      );
      final insets = phonePlayerControlInsets(
        MediaQuery.of(tester.element(find.byType(DanmakuView))),
      );
      expect(danmakuRect.top, closeTo(insets.top + 56, 0.01));
      expect(danmakuRect.top, greaterThanOrEqualTo(closeRect.bottom - 0.01));
      expect(danmakuRect.top, greaterThanOrEqualTo(titleRect.bottom - 0.01));
      expect(view.controller.danmakuOn, isTrue);
      expect(view.controller.comments.single.text, '滚动评论');
      expect(backend.isPlaying, isTrue);
      expect(current.error, isNull);
      // 底部提供弹幕快捷入口，完整设置仍保留原有选项。
      expect(find.byKey(const Key('mobile-player-danmaku')), findsOneWidget);
      await tester.tap(find.byKey(const Key('mobile-player-more')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      // 一级分类保留所有入口，弹幕能力在二级分类中。
      for (final section in ['tracks', 'speed', 'picture', 'danmaku']) {
        expect(
          find.byKey(ValueKey('mobile-player-section-$section')),
          findsOneWidget,
        );
      }
      expect(find.text('来源'), findsNothing);
      await enterSection(tester, 'danmaku');
      expect(find.byKey(DanmakuKeys.toggle), findsOneWidget);
      expect(find.byKey(DanmakuKeys.search), findsOneWidget);
      expect(find.byKey(DanmakuKeys.panel), findsOneWidget);

      // 弹幕子面板:透明度/字号可调,开关即时生效(此时面板未滚动)。
      await tester.tap(find.byKey(DanmakuKeys.panel));
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

      // 重新打开"更多"面板本体,静音能力保留(R10)。
      await tester.tap(find.byKey(const Key('mobile-player-more')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await enterSection(tester, 'picture');
      final mute = find.byKey(const Key('mobile-player-mute'));
      await tester.ensureVisible(mute);
      await tester.pump();
      await tester.tap(mute);
      await tester.pump();
      expect(backend.volume, 0);
      await closeOptions(tester);
      await closePlayer(tester);

      // 弹幕服务不可达时提示可关闭,视频继续播放。
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
    },
    tags: ['integration'],
  );

  cases.testWidgets(
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
      expect(find.textContaining('$hours:$minutes:$seconds'), findsOneWidget);
      // 应用内音量 PlayerSlider 已移出控制层,收入"更多"面板(R10 能力不减)。
      await tester.tap(find.byKey(const Key('mobile-player-more')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await enterSection(tester, 'picture');
      final slider = tester.widget<PlayerSlider>(
        find.byKey(const Key('mobile-player-volume')),
      );
      slider.onChanged!(40);
      await tester.pump();
      expect(current.volume, 40);
      expect(backend.volume, 40);
      await closeOptions(tester);

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
      await settle(tester);
      await wake.settled;
      expect(backend.isPlaying, isFalse);
      expect(wake.held, isFalse);
      expect(calls.last, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await settle(tester);
      await wake.settled;
      expect(backend.openCount, 2);
      expect(backend.openedPaused, isTrue);
      expect(backend.isPlaying, isFalse);
      expect(wake.held, isFalse);
      expect(find.text('画中画'), findsNothing);
      await closePlayer(tester);
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  cases.testWidgets('double-tap on the right and left half seeks ±10 seconds', (
    tester,
  ) async {
    final backend = FakeVideoBackend(duration: const Duration(hours: 2));
    await showPlayer(
      tester,
      itemId: 'movie-inception',
      backend: backend,
      mediaDuration: const Duration(hours: 2),
      wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
    );
    // 详情页 resume 点(59:00)会自动续播;手势断言全部用相对量。
    final initial = backend.position;
    expect(initial, greaterThan(Duration.zero));
    await tester.tapAt(const Offset(600, 150));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(const Offset(600, 150));
    await tester.pump(const Duration(milliseconds: 400));
    expect(backend.position, initial + const Duration(seconds: 10));
    await tester.tapAt(const Offset(200, 150));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(const Offset(200, 150));
    await tester.pump(const Duration(milliseconds: 400));
    expect(backend.position, initial);
    await closePlayer(tester);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  cases.testWidgets(
    'drives brightness, volume and seek previews with edge gestures',
    (tester) async {
      final display = _FakeDisplayControl();
      final backend = FakeVideoBackend();
      await showPlayer(
        tester,
        itemId: 'movie-inception',
        backend: backend,
        display: display,
        mediaDuration: const Duration(hours: 1, minutes: 5),
        wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
      );
      final brightness = await tester.startGesture(const Offset(200, 170));
      await brightness.moveBy(const Offset(0, -20));
      await brightness.moveBy(const Offset(0, -40));
      await brightness.moveBy(const Offset(0, -40));
      await tester.pump();
      expect(
        find.byKey(const Key('mobile-player-gesture-overlay')),
        findsOneWidget,
      );
      // 浮层实时反映亮度通道值。
      final shownBrightness = tester
          .widget<Text>(find.byKey(const Key('mobile-player-gesture-value')))
          .data;
      expect(display.brightnessValue, greaterThan(0.5));
      expect(shownBrightness, '${(display.brightnessValue * 100).round()}%');
      await brightness.up();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.byKey(const Key('mobile-player-gesture-overlay')),
        findsNothing,
      );

      final volume = await tester.startGesture(const Offset(600, 170));
      await volume.moveBy(const Offset(0, -25));
      await volume.moveBy(const Offset(0, -25));
      await tester.pump();
      final shownVolume = tester
          .widget<Text>(find.byKey(const Key('mobile-player-gesture-value')))
          .data;
      expect(display.volumeValue, greaterThan(0.5));
      expect(shownVolume, '${(display.volumeValue * 100).round()}%');
      await volume.up();
      await tester.pump(const Duration(milliseconds: 400));
      expect(backend.isPlaying, isTrue);

      // 横向拖动预览目标时间,松手后实际 seek 与预览一致。
      final initial = backend.position;
      final gesture = await tester.startGesture(const Offset(300, 120));
      await gesture.moveBy(const Offset(50, 0));
      await gesture.moveBy(const Offset(50, 0));
      await gesture.moveBy(const Offset(50, 0));
      await gesture.moveBy(const Offset(50, 0));
      await tester.pump();
      expect(
        find.byKey(const Key('mobile-player-gesture-seek')),
        findsOneWidget,
      );
      final preview = tester
          .widget<Text>(find.byKey(const Key('mobile-player-gesture-seek')))
          .data!;
      final parts = preview.split(':').map(int.parse).toList();
      final target = parts.length == 3
          ? Duration(hours: parts[0], minutes: parts[1], seconds: parts[2])
          : Duration(minutes: parts[0], seconds: parts[1]);
      expect(target, greaterThan(initial));
      expect(backend.position, initial);
      await gesture.up();
      await tester.pump();
      expect(backend.position, target);
      await closePlayer(tester);
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  cases.testWidgets(
    'failed system brightness gesture shows no invented percent',
    (tester) async {
      final display = _FailDisplayControl();
      final backend = FakeVideoBackend(duration: const Duration(hours: 2));
      await showPlayer(
        tester,
        itemId: 'movie-inception',
        backend: backend,
        display: display,
        mediaDuration: const Duration(hours: 2),
        wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
      );
      final initial = backend.position;
      final drag = await tester.startGesture(const Offset(200, 170));
      await drag.moveBy(const Offset(0, -40));
      await drag.moveBy(const Offset(0, -40));
      await tester.pump();
      expect(find.text('系统调节暂不可用'), findsOneWidget);
      expect(
        find.byKey(const Key('mobile-player-gesture-value')),
        findsNothing,
      );
      expect(backend.position, initial);
      await drag.up();
      await tester.pump();
      expect(backend.position, initial);
      final volume = await tester.startGesture(const Offset(600, 170));
      await volume.moveBy(const Offset(0, -40));
      await volume.moveBy(const Offset(0, -40));
      await tester.pump();
      expect(display.volumeValue, greaterThan(0.5));
      expect(
        find.byKey(const Key('mobile-player-gesture-value')),
        findsOneWidget,
      );
      await volume.up();
      await closePlayer(tester);
    },
    tags: ['integration'],
  );

  cases.testWidgets('invalid brightness read leaves volume gesture available', (
    tester,
  ) async {
    final display = _InvalidBrightnessDisplayControl();
    await showPlayer(
      tester,
      itemId: 'movie-inception',
      display: display,
      wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
    );
    final brightness = await tester.startGesture(const Offset(200, 170));
    await brightness.moveBy(const Offset(0, -40));
    await brightness.moveBy(const Offset(0, -40));
    await tester.pump();
    expect(find.text('系统调节暂不可用'), findsOneWidget);
    await brightness.up();
    final volume = await tester.startGesture(const Offset(600, 170));
    await volume.moveBy(const Offset(0, -40));
    await volume.moveBy(const Offset(0, -40));
    await tester.pump();
    expect(display.volumeValue, greaterThan(0.5));
    expect(
      find.byKey(const Key('mobile-player-gesture-value')),
      findsOneWidget,
    );
    await volume.up();
    await closePlayer(tester);
  }, tags: ['integration']);

  cases.testWidgets('unavailable volume gesture keeps the playback position', (
    tester,
  ) async {
    final backend = FakeVideoBackend(duration: const Duration(hours: 2));
    await showPlayer(
      tester,
      itemId: 'movie-inception',
      backend: backend,
      display: _FailVolumeDisplayControl(),
      mediaDuration: const Duration(hours: 2),
      wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
    );
    final initial = backend.position;
    final drag = await tester.startGesture(const Offset(600, 170));
    await drag.moveBy(const Offset(0, -40));
    await drag.moveBy(const Offset(0, -40));
    await tester.pump();
    expect(find.text('系统调节暂不可用'), findsOneWidget);
    expect(find.byKey(const Key('mobile-player-gesture-value')), findsNothing);
    expect(backend.position, initial);
    await drag.up();
    await tester.pump();
    expect(backend.position, initial);
    await closePlayer(tester);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  cases.testWidgets('locked screen needs an explicit unlock button tap', (
    tester,
  ) async {
    final backend = FakeVideoBackend(duration: const Duration(hours: 2));
    await showPlayer(
      tester,
      itemId: 'movie-inception',
      backend: backend,
      mediaDuration: const Duration(hours: 2),
      wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
    );
    await tester.tap(find.byKey(const Key('mobile-player-lock')));
    await tester.pump();
    expect(find.byKey(const Key('mobile-player-toggle')), findsNothing);
    expect(find.byKey(const Key('mobile-player-more')), findsNothing);
    expect(find.byIcon(CupertinoIcons.rotate_right), findsNothing);
    expect(find.byKey(const Key('mobile-player-unlock')), findsOneWidget);
    final lockCenter = tester.getCenter(
      find.byKey(const Key('mobile-player-unlock')),
    );
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(MobilePlayerPage), findsOneWidget);
    expect(find.byKey(const Key('mobile-player-toggle')), findsNothing);
    await tester.pump(const Duration(seconds: 5));
    expect(find.byKey(const Key('mobile-player-unlock')), findsNothing);
    await tester.tapAt(lockCenter);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('mobile-player-toggle')), findsNothing);
    expect(
      tester.getCenter(find.byKey(const Key('mobile-player-unlock'))).dx,
      closeTo(lockCenter.dx, 1),
    );

    // Gestures are inert while locked: dragging must not seek or show
    // gesture feedback (single tap is the unlock affordance).
    final initial = backend.position;
    final drag = await tester.startGesture(const Offset(600, 150));
    await drag.moveBy(const Offset(0, -40));
    await drag.moveBy(const Offset(0, -40));
    await tester.pump();
    await drag.up();
    expect(
      find.byKey(const Key('mobile-player-gesture-overlay')),
      findsNothing,
    );
    expect(backend.position, initial);
    // 锁定态不隐藏锁钮。
    expect(find.byKey(const Key('mobile-player-unlock')), findsOneWidget);

    // Tapping the picture reveals the entry but consumes that gesture.
    await tester.tapAt(const Offset(400, 150));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('mobile-player-toggle')), findsNothing);
    expect(find.byKey(const Key('mobile-player-more')), findsNothing);
    expect(find.byKey(const Key('mobile-player-close')), findsNothing);
    expect(find.byKey(const Key('mobile-player-unlock')), findsOneWidget);
    expect(backend.position, initial);
    await tester.tap(find.byKey(const Key('mobile-player-unlock')));
    await tester.pump();
    expect(find.byKey(const Key('mobile-player-unlock')), findsNothing);
    expect(find.byKey(const Key('mobile-player-toggle')), findsOneWidget);
    await closePlayer(tester);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  cases.testWidgets(
    'single-choice phone controls and more entries stay hidden',
    (tester) async {
      final c = await showPlayer(tester, itemId: 'movie-inception');
      const source = PlaybackMediaSource(
        id: 'only',
        mediaStreams: [MediaStreamInfo(index: 1, type: 'Audio', codec: 'aac')],
      );
      c.resolved = ResolvedPlayback(
        playMethod: PlayMethod.directPlay,
        streamUrl: Uri.parse('https://example.test/media'),
        playSessionId: 'session',
        mediaSource: source,
        itemId: c.itemId,
      );
      c.mediaSources = const [source];
      c.onUserActivity();
      await tester.pump();
      for (final key in ['mobile-player-quality', 'mobile-player-danmaku']) {
        expect(find.byKey(Key(key)), findsNothing);
      }
      await tester.tap(find.byKey(const Key('mobile-player-more')));
      await settle(tester);
      for (final key in [
        'mobile-player-section-quality',
        'mobile-player-source-entry',
        'mobile-player-section-danmaku',
      ]) {
        expect(find.byKey(Key(key)), findsNothing);
      }
      // 无自带字幕的媒体也保留轨道入口:本地导入在那里(R1/R2)。
      expect(
        find.byKey(const Key('mobile-player-section-tracks')),
        findsOneWidget,
      );
      await enterSection(tester, 'tracks');
      // 双槽字幕面板:主/次字幕各有一个"关闭字幕"项。
      expect(find.text('关闭字幕'), findsNWidgets(2));
      expect(find.byKey(const Key('mobile-subtitle-import')), findsOneWidget);
      await tester.tap(find.byKey(const Key('mobile-player-panel-close')));
      await settle(tester);
      await closePlayer(tester);
    },
    tags: ['integration'],
  );

  cases.testWidgets(
    'more panel hosts danmaku, tracks, speed, source, mute and volume',
    (tester) async {
      final backend = FakeVideoBackend();
      await showPlayer(
        tester,
        itemId: 'movie-inception',
        backend: backend,
        wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
      );
      // 顶栏不再出现弹幕按钮（R11）。
      expect(find.byKey(const Key('mobile-player-danmaku')), findsNothing);
      await tester.tap(find.byKey(const Key('mobile-player-more')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(DanmakuKeys.toggle), findsNothing);
      expect(find.byKey(DanmakuKeys.search), findsNothing);
      expect(find.byKey(DanmakuKeys.panel), findsNothing);
      expect(
        find.byKey(const Key('mobile-player-section-speed')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('mobile-player-section-tracks')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('mobile-player-volume')), findsNothing);
      await enterSection(tester, 'picture');
      expect(find.text('来源'), findsNothing);
      expect(find.byKey(const Key('mobile-player-mute')), findsOneWidget);
      expect(find.byKey(const Key('mobile-player-volume')), findsOneWidget);
      // Mute from the more panel keeps the ability (R10).
      final mute = find.byKey(const Key('mobile-player-mute'));
      await tester.ensureVisible(mute);
      await tester.pump();
      await tester.tap(mute);
      await tester.pump();
      expect(backend.volume, 0);
      await closeOptions(tester);
      expect(find.byType(CupertinoPopupSurface), findsNothing);
      await closePlayer(tester);
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  cases.testWidgets('source panel announces initial selection state', (
    tester,
  ) async {
    final current = await showPlayer(
      tester,
      itemId: 'movie-inception',
      backend: FakeVideoBackend(),
      size: const Size(360, 800),
      prepare: (server) {
        server.items
            .firstWhere((item) => item.id == 'movie-inception')
            .extraSources = const [
          FakeMediaSource(id: 'alternate', name: '另一个版本'),
        ];
      },
      wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
    );
    expect(current.canSwitchMediaSource, isTrue);
    await tester.tap(find.byKey(const Key('mobile-player-more')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const Key('mobile-player-source-entry')));
    await tester.pump();
    expect(find.text('另一个版本'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('另一个版本')), findsWidgets);
    if (current.activeMediaSourceId == null) {
      expect(find.text('正在确认当前来源…'), findsOneWidget);
      for (final source in current.mediaSources) {
        expect(
          tester
              .widget<AppListTile>(
                find.byKey(ValueKey('mobile-source-${source.id}')),
              )
              .selected,
          isFalse,
        );
      }
    }
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await closePlayer(tester);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  cases.testWidgets(
    'multiple sources appear only in more, never in quality',
    (tester) async {
      final backend = _ControlledSourceBackend();
      final reportGate = Completer<void>();
      addTearDown(() {
        if (!reportGate.isCompleted) reportGate.complete();
      });
      final current = await showPlayer(
        tester,
        itemId: 'movie-inception',
        backend: backend,
        size: const Size(360, 800),
        prepare: (server) {
          server.sessionsHold = reportGate;
          server.items
              .firstWhere((item) => item.id == 'movie-inception')
              .extraSources = const [
            FakeMediaSource(id: 'alternate', name: '另一个版本'),
          ];
        },
        wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
      );
      expect(current.canSwitchMediaSource, isTrue);
      expect(current.loading, isFalse);
      expect(backend.isPlaying, isTrue);
      // This ordinary playback path has no observation sink. Successful native
      // startup must identify its source even while the Playing report is held.
      expect(reportGate.isCompleted, isFalse);
      expect(current.activeMediaSourceId, 'movie-inception');
      reportGate.complete();

      Future<void> waitForSource(String source) async {
        final elapsed = Stopwatch()..start();
        while (current.loading ||
            current.isRecovering ||
            current.activeMediaSourceId != source) {
          if (elapsed.elapsed >= const Duration(seconds: 5)) {
            fail(
              'Source $source did not settle: active=${current.activeMediaSourceId} '
              'pending=${current.pendingMediaSourceId} phase=${current.state.phase} '
              'failure=${current.loadFailure} track=${current.trackFailure} '
              'detail=${current.disconnectDetail}',
            );
          }
          // Advance scheduled controller work and yield for real subtitle I/O.
          // Completion is decided by state, with a wall-clock deadline.
          await tester.pump(const Duration(milliseconds: 20));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        await tester.pump();
      }

      await tester.tap(find.byKey(const Key('mobile-player-toggle')));
      await tester.pump();
      expect(backend.isPlaying, isFalse);
      expect(find.text('来源'), findsNothing);
      await tester.tap(find.byKey(const Key('mobile-player-more')));
      await settle(tester);
      await enterSection(tester, 'quality');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('来源'), findsNothing);
      expect(find.text('另一个版本'), findsNothing);
      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const Key('mobile-player-more')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('来源'), findsOneWidget);
      expect(find.text('另一个版本'), findsNothing);
      final sourceEntry = find.byKey(const Key('mobile-player-source-entry'));
      await tester.ensureVisible(sourceEntry);
      await tester.pump();
      await tester.tap(sourceEntry);
      await tester.pump();
      expect(find.text('来源'), findsOneWidget);
      expect(find.text('另一个版本'), findsOneWidget);
      final alternate = find.byKey(const Key('mobile-source-alternate'));
      expect(alternate, findsOneWidget);
      await tester.ensureVisible(alternate);
      await tester.pump();
      final originalId = current.resolved!.mediaSource.id;
      final opensBeforeSwitch = backend.openCount;
      await tester.tap(alternate);
      expect(find.byType(PlaybackLineMenu), findsNothing);
      expect(current.switchConfirmation, isNull);
      await waitForSource('alternate');
      expect(
        current.activeMediaSourceId,
        'alternate',
        reason:
            'phase=${current.state.phase} failure=${current.loadFailure} track=${current.trackFailure} detail=${current.disconnectDetail}',
      );
      expect(current.pendingMediaSourceId, isNull);
      expect(backend.openCount, opensBeforeSwitch + 1);
      expect(
        backend.isPlaying,
        isFalse,
        reason:
            'Direct version switching preserves the original user pause intent',
      );
      expect(find.byType(PlaybackLineMenu), findsNothing);
      expect(find.text('正在切换来源…'), findsNothing);
      await tester.tap(find.widgetWithText(AppButton, '返回'));
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const Key('mobile-player-more')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const Key('mobile-player-source-entry')));
      await tester.pump();
      final gate = Completer<void>();
      backend.blockNext = gate;
      backend.failNext = true;
      final original = find.byKey(ValueKey('mobile-source-$originalId'));
      await tester.ensureVisible(original);
      await tester.pump();
      await tester.tap(original);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(current.pendingMediaSourceId, originalId);
      expect(current.activeMediaSourceId, 'alternate');
      expect(find.text('正在切换来源…'), findsOneWidget);
      expect(
        tester
            .widget<Icon>(
              find.byKey(ValueKey('mobile-source-icon-$originalId')),
            )
            .icon,
        AppIcons.hourglass,
      );
      expect(tester.widget<AppListTile>(alternate).selected, isTrue);
      expect(tester.widget<AppListTile>(original).selected, isFalse);
      gate.complete();
      await waitForSource('alternate');
      expect(current.activeMediaSourceId, 'alternate');
      expect(current.error, isNull);
      expect(find.byType(PlaybackLineMenu), findsNothing);
      expect(find.text('来源切换失败，原来源已恢复'), findsOneWidget);
      await tester.tap(find.widgetWithText(AppButton, '返回'));
      await tester.pump();
      expect(
        find.byKey(const Key('mobile-player-source-entry')),
        findsOneWidget,
      );
      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await closePlayer(tester);
    },
    tags: ['integration'],
    semanticsEnabled: false,
  );

  cases.testWidgets(
    'fit is the default scale with transport under a full-width timeline',
    (tester) async {
      final backend = FakeVideoBackend(
        duration: const Duration(hours: 1, minutes: 5),
      );
      await showPlayer(
        tester,
        itemId: 'movie-inception',
        backend: backend,
        mediaDuration: const Duration(hours: 1, minutes: 5),
        wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
        size: const Size(800, 360),
      );
      final toggle = tester.getRect(
        find.byKey(const Key('mobile-player-toggle')),
      );
      final seek = tester.getRect(find.byKey(const Key('mobile-player-seek')));
      expect(seek.width, greaterThan(740));
      expect(toggle.top, greaterThan(seek.bottom - 1));
      expect(toggle.center.dx, lessThan(320));

      await tester.tap(find.byKey(const Key('mobile-player-more')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await enterSection(tester, 'picture');
      expect(
        tester
            .widget<OptionPill>(
              find.byKey(const Key('mobile-player-scale-fit')),
            )
            .selected,
        isTrue,
      );
      expect(find.text('适应'), findsOneWidget);
      expect(find.text('填充'), findsOneWidget);
      await tester.tap(find.byKey(const Key('mobile-player-scale-fill')));
      await tester.pump();
      expect(
        tester
            .widget<OptionPill>(
              find.byKey(const Key('mobile-player-scale-fill')),
            )
            .selected,
        isTrue,
      );
      await closeOptions(tester);

      await tester.pump(const Duration(seconds: 5));
      expect(
        find.byKey(const Key('mobile-player-toggle')).hitTestable(),
        findsNothing,
      );
      await tester.tapAt(const Offset(400, 80));
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.byKey(const Key('mobile-player-toggle')).hitTestable(),
        findsOneWidget,
      );
      await closePlayer(tester);
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  cases.testWidgets('unknown duration disables every phone seek entry', (
    tester,
  ) async {
    final backend = FakeVideoBackend(duration: Duration.zero);
    final current = await showPlayer(
      tester,
      itemId: 'movie-inception',
      backend: backend,
      mediaDuration: Duration.zero,
      prepare: (server) {
        final movie = server.items.firstWhere(
          (item) => item.id == 'movie-inception',
        );
        movie.runtime = Duration(microseconds: (0) ~/ 10);
        movie.playbackPosition = Duration(microseconds: 0 ~/ 10);
      },
      wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
    );
    expect(current.duration, Duration.zero);
    expect(
      tester
          .widget<AppIconButton>(find.byKey(const Key('mobile-player-rewind')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<AppIconButton>(find.byKey(const Key('mobile-player-forward')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<PlayerSlider>(find.byKey(const Key('mobile-player-seek')))
          .onChanged,
      isNull,
    );
    await tester.tapAt(const Offset(600, 150));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(const Offset(600, 150));
    await tester.pump(const Duration(milliseconds: 400));
    expect(backend.position, Duration.zero);
    await closePlayer(tester);
  }, tags: ['integration']);

  cases.testWidgets('player controls fade instead of popping', (tester) async {
    final current = await showPlayer(
      tester,
      itemId: 'movie-inception',
      wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
    );
    expect(
      tester
          .widget<AnimatedOpacity>(find.byKey(PhoneMotion.playerControlsKey))
          .duration,
      AppMotion.normal,
    );
    double controlsOpacity() => tester
        .widget<FadeTransition>(
          find.descendant(
            of: find.byKey(PhoneMotion.playerControlsKey),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is FadeTransition && widget.child is ExcludeSemantics,
            ),
          ),
        )
        .opacity
        .value;
    expect(controlsOpacity(), 1);

    current.toggleControls();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    final fading = controlsOpacity();
    expect(fading, greaterThan(0));
    expect(fading, lessThan(1));
    await tester.pump(const Duration(milliseconds: 300));
    expect(controlsOpacity(), 0);

    current.toggleControls();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    final showing = controlsOpacity();
    expect(showing, greaterThan(0));
    expect(showing, lessThan(1));
    await tester.pump(const Duration(milliseconds: 300));
    expect(controlsOpacity(), 1);
    await tester.tap(find.byKey(const Key('mobile-player-toggle')));
    await tester.pump();
    expect(current.isPlaying, isFalse);
    await closePlayer(tester);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  cases.testWidgets('hidden controls are not rebuilt on every playback tick', (
    tester,
  ) async {
    final current = await showPlayer(
      tester,
      itemId: 'movie-inception',
      wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
    );
    final backend = current.backend as FakeVideoBackend;
    PhonePlayerControls controls() =>
        tester.widget<PhonePlayerControls>(find.byType(PhonePlayerControls));
    current.toggleControls();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(current.controlsVisible, isFalse);
    final hidden = controls();
    var notified = 0;
    void count() => notified++;
    current.addListener(count);
    // Each distinct throughput readout notifies the controller.
    for (var i = 1; i <= 5; i++) {
      backend.emitEvent(VideoEventKind.cacheSpeed, i * 3.0 * 1024 * 1024);
      await tester.pump(kPlaybackUiMinInterval);
    }
    current.removeListener(count);
    expect(notified, greaterThan(0));
    expect(identical(controls(), hidden), isTrue);

    // Revealing rebuilds immediately with the current playback state.
    current.toggleControls();
    await tester.pump();
    expect(identical(controls(), hidden), isFalse);
    expect(current.controlsVisible, isTrue);
    await closePlayer(tester);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  cases.testWidgets(
    'playback hides system bars, defaults landscape, and reasserts on resume',
    (tester) async {
      final channelCalls = <MethodCall>[];
      _mockAndroidPlayerChannel(channelCalls);
      final bars = PhoneSystemBars();
      final orientation = PhoneOrientation(request: (_) async {});
      await showPlayer(
        tester,
        itemId: 'movie-inception',
        orientation: orientation,
        systemBars: bars,
        wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
      );
      await bars.settled;
      expect(bars.calls, [true]);
      expect(_systemBarHidden(channelCalls), [true]);
      await orientation.settled;
      expect(orientation.calls, [PhoneOrientation.landscape]);
      expect(find.byIcon(CupertinoIcons.rotate_right), findsNothing);
      expect(find.byKey(const Key('mobile-player-lock')), findsOneWidget);
      expect(find.byKey(const Key('mobile-player-more')), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (widget) => widget is AppTooltip && widget.message == '关闭',
        ),
        findsOneWidget,
      );

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await bars.settled;
      expect(bars.calls, [true, true]);
      expect(_systemBarHidden(channelCalls), [true, true]);
      await orientation.settled;
      expect(orientation.calls, [
        PhoneOrientation.landscape,
        PhoneOrientation.landscape,
      ]);

      await closePlayer(tester);
      await bars.settled;
      await orientation.settled;
      expect(bars.calls, [true, true, false]);
      expect(_systemBarHidden(channelCalls), [true, true, false]);
      expect(orientation.calls, [
        PhoneOrientation.landscape,
        PhoneOrientation.landscape,
        PhoneOrientation.unlocked,
      ]);
      expect(find.byType(MobilePlayerPage), findsNothing);
    },
    tags: ['integration'],
  );

  cases.testWidgets(
    'transport targets are at least 48dp and still step 10 seconds',
    (tester) async {
      final backend = FakeVideoBackend(duration: const Duration(hours: 3));
      await showPlayer(
        tester,
        itemId: 'movie-inception',
        backend: backend,
        mediaDuration: const Duration(hours: 3),
        wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
        size: const Size(360, 640),
      );
      final rewind = tester.getRect(
        find.byKey(const Key('mobile-player-rewind')),
      );
      final toggle = tester.getRect(
        find.byKey(const Key('mobile-player-toggle')),
      );
      final forward = tester.getRect(
        find.byKey(const Key('mobile-player-forward')),
      );
      for (final rect in [rewind, toggle, forward]) {
        expect(rect.width, greaterThanOrEqualTo(48 - 0.01));
        expect(rect.height, greaterThanOrEqualTo(48 - 0.01));
      }
      expect(toggle.left - rewind.right, greaterThanOrEqualTo(8 - 0.01));
      expect(forward.left - toggle.right, greaterThanOrEqualTo(8 - 0.01));
      for (final key in [
        find.byWidgetPredicate(
          (widget) => widget is AppTooltip && widget.message == '关闭',
        ),
        find.byKey(const Key('mobile-player-lock')),
        find.byKey(const Key('mobile-player-more')),
      ]) {
        expect(
          tester.getSize(key).shortestSide,
          greaterThanOrEqualTo(48 - 0.01),
        );
      }
      expect(tester.takeException(), isNull);

      final start = backend.position;
      await tester.tap(find.byKey(const Key('mobile-player-forward')));
      await tester.pump();
      expect(backend.position - start, const Duration(seconds: 10));
      await tester.tap(find.byKey(const Key('mobile-player-rewind')));
      await tester.pump();
      expect(backend.position, start);
      await closePlayer(tester);
    },
    tags: ['integration'],
  );

  cases.testWidgets(
    'landscape controls use actual top obstruction while video stays full bleed',
    (tester) async {
      const size = Size(800, 360);
      tester.view.padding = FakeViewPadding();
      tester.view.viewPadding = const FakeViewPadding(top: 30);
      tester.view.systemGestureInsets = const FakeViewPadding(
        left: 24,
        top: 12,
        right: 24,
        bottom: 40,
      );
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      addTearDown(tester.view.resetSystemGestureInsets);
      final channelCalls = <MethodCall>[];
      _mockAndroidPlayerChannel(channelCalls, sdk: 34);
      await showPlayer(
        tester,
        itemId: 'movie-inception',
        wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
        size: size,
      );
      expect(
        channelCalls.map((call) => call.method),
        contains('androidSdkInt'),
      );

      final back = tester.getRect(
        find.byWidgetPredicate(
          (widget) => widget is AppTooltip && widget.message == '关闭',
        ),
      );
      final more = tester.getRect(find.byKey(const Key('mobile-player-more')));
      final rewind = tester.getRect(
        find.byKey(const Key('mobile-player-rewind')),
      );
      final video = find.byWidgetPredicate(
        (widget) =>
            widget is ColoredBox && widget.color == const Color(0xFF000000),
      );
      expect(video, findsOneWidget);
      final picture = tester.getRect(video);
      expect(picture.left, closeTo(0, 0.2));
      expect(picture.top, closeTo(0, 0.2));
      expect(picture.width, closeTo(size.width, 0.2));
      expect(picture.height, closeTo(size.height, 0.2));
      final topScrim = find.byKey(const Key('mobile-player-top-scrim'));
      final bottomScrim = find.byKey(const Key('mobile-player-bottom-scrim'));
      expect(tester.getRect(topScrim).top, closeTo(picture.top, 0.01));
      expect(tester.getRect(topScrim).left, closeTo(picture.left, 0.01));
      expect(tester.getRect(topScrim).right, closeTo(picture.right, 0.01));
      expect(tester.getRect(bottomScrim).bottom, closeTo(picture.bottom, 0.01));
      expect(tester.getRect(bottomScrim).left, closeTo(picture.left, 0.01));
      expect(tester.getRect(bottomScrim).right, closeTo(picture.right, 0.01));
      final topDecoration =
          tester.widget<DecoratedBox>(topScrim).decoration as BoxDecoration;
      expect(topDecoration.gradient!.colors.first.a, greaterThan(0));
      expect(back.top - picture.top, closeTo(0, 0.01));
      expect(back.left - picture.left, closeTo(24, 0.01));
      expect(picture.right - more.right, greaterThanOrEqualTo(24));
      expect(rewind.left - picture.left, greaterThanOrEqualTo(24));
      expect(picture.bottom - more.bottom, greaterThanOrEqualTo(40));
      final seek = tester.getRect(find.byKey(const Key('mobile-player-seek')));
      expect(rewind.top, greaterThan(seek.bottom - 1));
      expect(more.left, greaterThan(rewind.right));
      expect((rewind.center.dy - more.center.dy).abs(), lessThan(1));
      await tester.tap(find.byKey(const Key('mobile-player-lock')));
      await tester.pump();
      expect(tester.getRect(topScrim).top, closeTo(picture.top, 0.01));
      expect(tester.getRect(topScrim).left, closeTo(picture.left, 0.01));
      expect(
        tester.getTopLeft(find.byKey(const Key('mobile-player-unlock'))).dy,
        closeTo(0, 0.01),
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const Key('mobile-player-unlock')));
      await tester.pump();
      await closePlayer(tester);
    },
    tags: ['integration'],
  );

  cases.testWidgets(
    'pre-30 display cutouts inset controls and API 30 keeps them in view padding',
    (tester) async {
      const size = Size(800, 360);
      const cutout = DisplayFeature(
        bounds: Rect.fromLTWH(0, 40, 32, 120),
        type: DisplayFeatureType.cutout,
        state: DisplayFeatureState.unknown,
      );

      Future<double> backLeft(int sdk) async {
        tester.view.padding = FakeViewPadding();
        tester.view.viewPadding = FakeViewPadding();
        tester.view.systemGestureInsets = FakeViewPadding();
        tester.view.displayFeatures = const [cutout];
        addTearDown(tester.view.resetPadding);
        addTearDown(tester.view.resetViewPadding);
        addTearDown(tester.view.resetSystemGestureInsets);
        addTearDown(tester.view.resetDisplayFeatures);
        _mockAndroidPlayerChannel(<MethodCall>[], sdk: sdk);
        await showPlayer(
          tester,
          itemId: 'movie-inception',
          wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
          size: size,
        );
        final video = find.byWidgetPredicate(
          (widget) =>
              widget is ColoredBox && widget.color == const Color(0xFF000000),
        );
        final picture = tester.getRect(video);
        expect(picture.left, closeTo(0, 0.2));
        expect(picture.width, closeTo(size.width, 0.2));
        expect(picture.height, closeTo(size.height, 0.2));
        final left =
            tester
                .getTopLeft(
                  find.byWidgetPredicate(
                    (widget) => widget is AppTooltip && widget.message == '关闭',
                  ),
                )
                .dx -
            picture.left;
        await closePlayer(tester);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        return left;
      }

      expect(await backLeft(29), greaterThanOrEqualTo(32 - 0.01));
      expect(await backLeft(30), lessThan(1));
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  cases.testWidgets('landscape top cutout still insets the top controls', (
    tester,
  ) async {
    tester.view.padding = FakeViewPadding();
    tester.view.viewPadding = const FakeViewPadding(top: 36);
    tester.view.systemGestureInsets = FakeViewPadding();
    tester.view.displayFeatures = const [
      DisplayFeature(
        bounds: Rect.fromLTWH(350, 0, 100, 24),
        type: DisplayFeatureType.cutout,
        state: DisplayFeatureState.unknown,
      ),
    ];
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    addTearDown(tester.view.resetSystemGestureInsets);
    addTearDown(tester.view.resetDisplayFeatures);
    _mockAndroidPlayerChannel(<MethodCall>[], sdk: 36);
    await showPlayer(
      tester,
      itemId: 'movie-inception',
      wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
      size: const Size(800, 360),
    );
    expect(
      tester
          .getTopLeft(
            find.byWidgetPredicate(
              (widget) => widget is AppTooltip && widget.message == '关闭',
            ),
          )
          .dy,
      closeTo(24, 0.01),
    );
    await closePlayer(tester);
  }, tags: ['integration']);

  cases.testWidgets(
    'unsupported startup tracks stay silent and a manual choice is in Chinese',
    (tester) async {
      final backend = _PhoneTrackBackend(
        rejectedAudio: {8},
        rejectedSubtitles: {4},
      );
      final current = await showPlayer(
        tester,
        itemId: 'movie-inception',
        backend: backend,
        wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
        size: const Size(800, 800),
        prepare: (server) {
          server.items
              .firstWhere((item) => item.id == 'movie-inception')
              .mediaStreams = const [
            FakeMediaStream(index: 0, type: 'Video', codec: 'h264'),
            FakeMediaStream(
              index: 1,
              type: 'Audio',
              codec: 'aac',
              displayTitle: 'English',
              isDefault: true,
            ),
            FakeMediaStream(
              index: 8,
              type: 'Audio',
              codec: 'ac3',
              displayTitle: 'Commentary',
            ),
            FakeMediaStream(
              index: 4,
              type: 'Subtitle',
              codec: 'ass',
              displayTitle: '中文',
              isDefault: true,
              isTextSubtitleStream: true,
            ),
          ];
        },
      );
      expect(current.error, isNull);
      expect(current.trackFailure, isNull);
      expect(current.isPlaying, isTrue);
      expect(backend.audioCalls, [1]);
      expect(backend.subtitleCalls, isEmpty);
      expect(find.text('此轨道在当前设备上不可用'), findsNothing);
      expect(find.textContaining('Bad state:'), findsNothing);
      expect(find.textContaining('Unsupported media track'), findsNothing);

      await tester.tap(find.byKey(const Key('mobile-player-more')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.byKey(const Key('mobile-player-section-tracks')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('mobile-player-panel-close')));
      await settle(tester);
      // A late selection from a stale control still reports a localized error.
      await current.setAudio(8);
      await tester.pump();
      expect(find.text('此轨道在当前设备上不可用'), findsWidgets);
      expect(find.textContaining('Bad state:'), findsNothing);
      expect(find.textContaining('Unsupported media track'), findsNothing);
      expect(find.text('Device track is not playable'), findsNothing);
      expect(current.error, isNull);
      expect(current.isPlaying, isTrue);
      expect(current.audioStreamIndex, 1);
      expect(backend.audioCalls, [1]);
      expect(backend.openCount, 1);
      expect(find.text('重试'), findsNothing);

      // A nonfatal track error must not pin the timeline over the video.
      await tester.tapAt(const Offset(400, 220));
      await tester.pump(const Duration(milliseconds: 400));
      expect(current.controlsVisible, isFalse);
      expect(
        find.byKey(const Key('mobile-player-seek')).hitTestable(),
        findsNothing,
      );
      await tester.tapAt(const Offset(400, 220));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const Key('mobile-dismiss-track-failure')));
      await tester.pump();
      expect(current.trackFailure, isNull);
      expect(find.text('此轨道在当前设备上不可用'), findsNothing);

      final before = backend.position;
      await tester.tap(find.byKey(const Key('mobile-player-forward')));
      await tester.pump();
      expect(backend.position - before, const Duration(seconds: 10));
      await closePlayer(tester);
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );

  for (final size in [
    const Size(320, 568),
    const Size(360, 800),
    const Size(412, 915),
    const Size(640, 320),
    const Size(800, 360),
    const Size(915, 412),
  ]) {
    cases.testWidgets(
      'phone shortcuts and single timeline remain usable at $size',
      (tester) async {
        final backend = FakeVideoBackend();
        final current = await showPlayer(
          tester,
          itemId: 'movie-inception',
          backend: backend,
          size: size,
          wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
        );
        for (final key in ['speed', 'more']) {
          final button = find.byKey(Key('mobile-player-$key'));
          expect(tester.getSize(button).shortestSide, greaterThanOrEqualTo(48));
        }
        final timeline = find.byKey(const Key('mobile-player-seek'));
        expect(tester.getSize(timeline).width, greaterThan(size.width - 50));
        final cache = find.byKey(const Key('mobile-player-cache-status'));
        final clock = find.byKey(const Key('mobile-player-clock'));
        final clockRect = tester.getRect(clock),
            cacheRect = tester.getRect(cache);
        expect(clockRect.overlaps(cacheRect), isFalse);
        expect(cacheRect.bottom, lessThanOrEqualTo(size.height));
        expect(cacheRect.left, greaterThanOrEqualTo(0));
        backend.emitEvent(VideoEventKind.cacheSpeed, 1048576);
        backend.emitEvent(
          VideoEventKind.bufferSnapshot,
          BufferSnapshot(
            sessionId: current.bufferSnapshot.sessionId,
            resourceId: 'phone-test',
            representationVersion: 'v1',
            trackVersion: 0,
            sequence: 1,
            ranges: const [BufferedRange(Duration.zero, Duration(minutes: 1))],
          ),
        );
        await tester.pump();
        expect(find.text('1.0 MB/s'), findsOneWidget);
        expect(
          tester
              .widget<BufferedRangesTrack>(find.byType(BufferedRangesTrack))
              .snapshot
              .ranges,
          hasLength(1),
        );
        backend.emitEvent(VideoEventKind.cacheSpeed, 0);
        await settle(tester);
        expect(find.text('0 KB/s'), findsOneWidget);
        expect(
          tester
              .widget<BufferedRangesTrack>(find.byType(BufferedRangesTrack))
              .snapshot
              .ranges,
          hasLength(1),
        );

        backend.emitEvent(
          VideoEventKind.bufferSnapshot,
          BufferSnapshot(
            sessionId: current.bufferSnapshot.sessionId,
            resourceId: 'phone-test',
            representationVersion: 'v1',
            trackVersion: 0,
            sequence: 2,
            ranges: const [],
            unknownReason: 'indexUnavailable',
            byteCoverage: BufferedByteCoverage(
              totalBytes: 1000,
              ranges: const [
                BufferedByteRange(0, 300),
                BufferedByteRange(600, 800),
              ],
            ),
          ),
        );
        await tester.pump();
        expect(find.text('缓存时间范围暂不可用'), findsNothing);
        expect(
          find.byKey(const Key('mobile-player-byte-cache-track')),
          findsNothing,
        );
        expect(find.byType(BufferedRangesTrack), findsOneWidget);
        backend.emitEvent(
          VideoEventKind.bufferSnapshot,
          BufferSnapshot.empty(
            sessionId: current.bufferSnapshot.sessionId,
            resourceId: 'phone-test',
            representationVersion: 'v1',
            trackVersion: 0,
            sequence: 3,
            unknownReason: 'cacheUncertain',
          ),
        );
        await tester.pump();
        expect(find.text('缓存时间范围暂不可用'), findsNothing);
        expect(
          find.byKey(const Key('mobile-player-byte-cache-track')),
          findsNothing,
        );
        expect(find.byType(BufferedRangesTrack), findsOneWidget);

        backend.emitEvent(VideoEventKind.buffering, true);
        await tester.pump();
        expect(find.byType(AppProgressBar), findsNothing);
        expect(find.text('正在缓冲…'), findsOneWidget);
        backend.emitEvent(VideoEventKind.buffering, false);
        await tester.pump();

        await tester.tap(find.byKey(const Key('mobile-player-speed')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        final options = tester.getRect(
          find.byKey(const Key('mobile-player-options')),
        );
        expect(find.text('播放速度'), findsOneWidget);
        if (size.width > size.height) {
          expect(options.width, lessThanOrEqualTo(360));
          expect(options.right, closeTo(size.width, .2));
          expect(options.left, greaterThan(size.width * .3));
        } else {
          expect(options.bottom, closeTo(size.height, .2));
          expect(options.height, lessThan(size.height * .8));
        }
        await tester.tap(find.byKey(const ValueKey('player-rate-1.5')));
        await tester.pump();
        expect(current.playbackRate, 1.5);
        await tester.tap(find.byKey(const Key('mobile-player-panel-back')));
        await tester.pump();
        expect(
          find.byKey(const Key('mobile-player-section-speed')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const Key('mobile-player-panel-close')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          find.descendant(
            of: find.byKey(const Key('mobile-player-speed')),
            matching: find.text('1.5x'),
          ),
          findsOneWidget,
        );

        expect(find.byKey(const Key('mobile-player-quality')), findsNothing);
        expect(find.byKey(const Key('mobile-player-tracks')), findsOneWidget);
        expect(find.byKey(const Key('mobile-player-danmaku')), findsNothing);
        await tester.tap(find.byKey(const Key('mobile-player-more')));
        await settle(tester);
        await enterSection(tester, 'quality');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('来源'), findsNothing);
        expect(find.text('最高可用'), findsOneWidget);
        expect(find.byType(AppChoiceChip), findsNothing);
        await tester.binding.handlePopRoute();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        // A long scrub must not lose its controls halfway through the gesture.
        final gesture = await tester.startGesture(tester.getCenter(timeline));
        await gesture.moveBy(const Offset(20, 0));
        await tester.pump(const Duration(seconds: 5));
        expect(current.controlsVisible, isTrue);
        expect(tester.widget<PlayerSlider>(timeline).label, isNotEmpty);
        await gesture.up();
        await tester.pump();
        expect(backend.position, greaterThan(Duration.zero));
        tester.platformDispatcher.accessibilityFeaturesTestValue =
            const FakeAccessibilityFeatures(disableAnimations: true);
        addTearDown(
          tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
        );
        await tester.pump();
        current.toggleControls();
        await tester.pump();
        expect(
          tester
              .widget<AnimatedOpacity>(
                find.byKey(PhoneMotion.playerControlsKey),
              )
              .duration,
          Duration.zero,
        );
        expect(
          find.byKey(const Key('mobile-player-toggle')).hitTestable(),
          findsNothing,
        );
        current.toggleControls();
        await tester.pump();
        expect(
          find.byKey(const Key('mobile-player-toggle')).hitTestable(),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await closePlayer(tester);
      },
      tags: ['integration'],
    );
  }

  cases.testWidgets('a video that cannot open still offers retry', (
    tester,
  ) async {
    await showPlayer(
      tester,
      itemId: 'movie-inception',
      backend: _FailOpenBackend(),
      wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
    );
    expect(find.text('连接尚未恢复'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.textContaining('Bad state:'), findsNothing);
    await tester.tap(find.byKey(const Key('mobile-player-lock')));
    await tester.pump();
    expect(find.text('重试'), findsNothing);
    await tester.tapAt(const Offset(400, 160));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('重试'), findsNothing);
    await tester.tap(find.byKey(const Key('mobile-player-unlock')));
    await tester.pump();
    expect(find.text('重试'), findsOneWidget);
    await closePlayer(tester);
  }, tags: ['integration']);

  cases.testWidgets('retry button actually opens the failed phone playback', (
    tester,
  ) async {
    final backend = _RetryOpenBackend();
    final current = await showPlayer(
      tester,
      itemId: 'movie-inception',
      backend: backend,
      prepareAuth: (auth) => auth.selectLine(
        auth.session!.server.id,
        LineSelection.fixed(auth.session!.server.activeLineId!),
      ),
      wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
    );
    expect(current.error, isNotNull);
    await tester.tap(find.text('重试'));
    await tester.pump();
    expect(current.loading, isTrue);
    final previousSession = current.bufferSnapshot.sessionId;
    for (
      var i = 0;
      i < 30 && current.bufferSnapshot.sessionId == previousSession;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    final session = current.bufferSnapshot.sessionId;
    backend.emitEvent(
      VideoEventKind.bufferSnapshot,
      BufferSnapshot(
        sessionId: session,
        resourceId: current.bufferSnapshot.resourceId,
        representationVersion: current.bufferSnapshot.representationVersion,
        trackVersion: current.bufferSnapshot.trackVersion,
        sequence: current.bufferSnapshot.sequence + 1,
        ranges: const [],
        unknownReason: 'preparing',
        byteCoverage: BufferedByteCoverage(
          totalBytes: 1000,
          ranges: const [BufferedByteRange(0, 400)],
        ),
      ),
      forSession: session,
    );
    await tester.pump();
    await tester.pump();
    expect(
      find.byKey(const Key('mobile-player-byte-cache-track')),
      findsNothing,
    );
    for (var i = 0; i < 30 && current.loading; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(current.error, isNull);
    expect(find.byType(BufferedRangesTrack), findsOneWidget);
    expect(backend.attempts, 2);
    await closePlayer(tester);
  }, tags: ['integration']);

  cases.testWidgets(
    'phone single line still offers automatic mode without reopening healthy playback',
    (tester) async {
      final backend = FakeVideoBackend();
      final current = await showPlayer(
        tester,
        itemId: 'movie-inception',
        backend: backend,
        withRuntime: true,
        prepareAuth: (auth) async {
          final server = auth.session!.server;
          await auth.selectLine(
            server.id,
            LineSelection.fixed(server.activeLineId!),
          );
        },
      );
      expect(current.playbackLineSelection.isAutomatic, isFalse);
      backend.emitEvent(VideoEventKind.position, const Duration(seconds: 4));
      await tester.pump();
      final opens = backend.openCount;
      await tester.tap(find.byKey(const Key('mobile-player-more')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.ensureVisible(
        find.byKey(const Key('player-playback-lines')),
      );
      await tester.tap(find.byKey(const Key('player-playback-lines')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(current.playbackLines, hasLength(1));
      expect(find.byKey(const Key('playback-line-auto')), findsOneWidget);
      expect(find.byKey(const Key('playback-line-actual')), findsOneWidget);
      await tester.tap(find.byKey(const Key('playback-line-auto')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(current.playbackLineSelection.isAutomatic, isTrue);
      expect(
        current.runtime!.registry
            .server(current.origin!.source.account.configuredServerId)
            .lineSelection
            .isAutomatic,
        isTrue,
      );
      expect(backend.openCount, opens);
      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await closePlayer(tester);
    },
    tags: ['integration'],
  );

  cases.testWidgets('phone automatic first playback reaches the video backend', (
    tester,
  ) async {
    late FakeEmbyServer fixture;
    final backend = FakeVideoBackend();
    final current = await showPlayer(
      tester,
      itemId: 'movie-up',
      backend: backend,
      withRuntime: true,
      prepare: (server) => fixture = server,
    );
    expect(
      current.error,
      isNull,
      reason:
          'line=${current.playbackLineFailure}; load=${current.loadFailure}; '
          'disconnect=${current.disconnectDetail}; requests=${fixture.requests}',
    );
    expect(backend.openCount, 1);
    expect(current.playbackLineSelection.isAutomatic, isTrue);
    await closePlayer(tester);
  }, tags: ['integration']);

  cases.testWidgets(
    'phone back cancels line recovery while the video surface stays mounted',
    (tester) async {
      final backend = _RecoveryGateBackend();
      final current = await showPlayer(
        tester,
        itemId: 'movie-inception',
        backend: backend,
        withRuntime: true,
        prepareAuth: (auth) async {
          final server = auth.session!.server;
          await auth.selectLine(
            server.id,
            LineSelection.fixed(server.activeLineId!),
          );
        },
      );
      expect(current.isPlaying, isTrue);
      await current.selectPlaybackLine(const LineSelection.auto());
      final surface = tester.element(
        find.byKey(_RecoveryGateBackend.surfaceKey),
      );
      final gate = Completer<void>();
      backend.openGate = gate;
      backend.emitEvent(VideoEventKind.error, 'Connection reset by peer');
      for (var frame = 0; frame < 40 && !backend.waiting; frame++) {
        await tester.pump(const Duration(milliseconds: 20));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
      }
      expect(
        backend.waiting,
        isTrue,
        reason:
            'recovering=${current.isRecovering}, disconnected=${current.disconnected}, mode=${current.playbackLineSelection.toJson()}, failure=${current.playbackLineFailure}, confirmation=${current.switchConfirmation != null}, phase=${current.state.phase}',
      );
      expect(current.isRecovering, isTrue);
      expect(
        find
            .byKey(const Key('playback-recovery-cancel'))
            .hitTestable(at: const Alignment(0, .9)),
        findsOneWidget,
      );
      expect(
        tester.element(find.byKey(_RecoveryGateBackend.surfaceKey)),
        same(surface),
      );
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(current.isRecovering, isFalse);
      expect(find.byType(MobilePlayerPage), findsOneWidget);
      expect(
        tester.element(find.byKey(_RecoveryGateBackend.surfaceKey)),
        same(surface),
      );
      backend.openGate = null;
      gate.complete();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      expect(current.isPlaying, isFalse);
      expect(
        find.byKey(const Key('playback-recovery-retry')).hitTestable(),
        findsOneWidget,
      );
      await closePlayer(tester);
    },
    tags: ['integration'],
  );

  cases.testWidgets('phone line sheet lists only this server', (tester) async {
    final backend = FakeVideoBackend();
    final current = await showPlayer(
      tester,
      itemId: 'movie-inception',
      backend: backend,
      prepareAuth: (auth) async {
        final server = auth.session!.server;
        expect(
          await auth.addLine(server.id, 'https://mirror.example:8443'),
          isTrue,
        );
      },
    );
    backend.emitEvent(VideoEventKind.position, const Duration(seconds: 4));
    await tester.pump();
    expect(find.text('手动切换'), findsNothing);
    expect(find.byKey(const Key('player-playback-lines')), findsNothing);
    await tester.tap(find.byKey(const Key('mobile-player-more')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('线路'), findsOneWidget);
    expect(find.text('立即锁定'), findsNothing);
    await tester.ensureVisible(find.byKey(const Key('player-playback-lines')));
    await tester.tap(find.byKey(const Key('player-playback-lines')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(PlaybackLineMenu), findsOneWidget);
    expect(find.text('正在使用'), findsOneWidget);
    expect(find.text('mirror.example:8443'), findsOneWidget);
    expect(current.playbackLines, hasLength(2));
    expect(current.client.baseUrl?.host, isNot('mirror.example'));
    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 400));
    await closePlayer(tester);
  }, tags: ['integration']);

  cases.testWidgets('phone series playback opens the episode list', (
    tester,
  ) async {
    final backend = FakeVideoBackend();
    final current = await showPlayer(
      tester,
      itemId: 'episode-friends-s1e2',
      backend: backend,
      wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
    );
    expect(find.byKey(const Key('mobile-player-episodes')), findsOneWidget);
    expect(find.textContaining('S1E2'), findsOneWidget);
    await tester.tap(find.byKey(const Key('mobile-player-episodes')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('player-episodes-panel')), findsOneWidget);
    const earlier = Key('player-episode-episode-friends-s1e1');
    for (var i = 0; i < 30 && find.byKey(earlier).evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byKey(earlier), findsOneWidget);
    await tester.tap(find.byKey(earlier));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('player-episodes-panel')), findsNothing);
    for (
      var i = 0;
      i < 40 && (current.itemId != 'episode-friends-s1e1' || current.loading);
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(current.itemId, 'episode-friends-s1e1');
    expect(tester.takeException(), isNull);
    await closePlayer(tester);
  }, tags: ['integration']);

  cases.testWidgets('phone playback shows skip intro after the controls hide', (
    tester,
  ) async {
    const second = 10000000;
    final backend = FakeVideoBackend();
    final current = await showPlayer(
      tester,
      itemId: 'episode-friends-s1e1',
      backend: backend,
      wakeLock: PhonePlaybackWakeLock(toggle: (_) async {}),
      prepare: (server) {
        final episode = server.items.firstWhere(
          (item) => item.id == 'episode-friends-s1e1',
        );
        episode.played = false;
        episode.playedPercentage = 0;
        episode.playbackPosition = Duration(microseconds: (20 * second) ~/ 10);
        episode.chapters = const [
          FakeChapter(
            name: 'Intro',
            startPosition: Duration(microseconds: 0),
            markerType: 'IntroStart',
          ),
          FakeChapter(
            name: 'Intro End',
            startPosition: Duration(microseconds: (90 * second) ~/ 10),
            markerType: 'IntroEnd',
          ),
        ];
      },
    );
    const skip = Key('mobile-player-skip-segment');
    expect(find.byKey(skip), findsOneWidget);
    expect(find.text('跳过片头'), findsOneWidget);
    if (!current.controlsVisible) current.onUserActivity();
    await tester.pump();
    final skipRect = tester.getRect(find.byKey(skip));
    final clockRect = tester.getRect(
      find.byKey(const Key('mobile-player-clock')),
    );
    expect(skipRect.bottom, lessThanOrEqualTo(clockRect.top));
    current.toggleControls();
    await tester.pump();
    expect(current.controlsVisible, isFalse);
    expect(find.byKey(skip), findsOneWidget);
    expect(find.byKey(skip).hitTestable(), findsOneWidget);
    await tester.tap(find.byKey(skip));
    for (
      var i = 0;
      i < 20 && backend.position != const Duration(seconds: 90);
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(backend.position, const Duration(seconds: 90));
    for (var i = 0; i < 10 && find.byKey(skip).evaluate().isNotEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(
      find.byKey(skip),
      findsNothing,
      reason:
          'position ${current.position} segment ${current.activeSkipSegment} '
          'prompt ${current.skipPromptVisible}',
    );
    expect(tester.takeException(), isNull);
    await closePlayer(tester);
  }, tags: ['integration']);
}

class _PhoneTrackBackend extends FakeVideoBackend
    implements VideoBackendTrackSupport {
  _PhoneTrackBackend({
    this.rejectedAudio = const {},
    this.rejectedSubtitles = const {},
  }) : super(duration: const Duration(hours: 3));

  final Set<int> rejectedAudio;
  final Set<int> rejectedSubtitles;
  final List<int> audioCalls = [];
  final List<int> subtitleCalls = [];

  @override
  bool? audioTrackSupported(int index) =>
      rejectedAudio.contains(index) ? false : true;

  @override
  bool? subtitleTrackSupported(int index) =>
      rejectedSubtitles.contains(index) ? false : true;

  @override
  Future<void> setAudioIndex(int index) async {
    audioCalls.add(index);
    await super.setAudioIndex(index);
  }

  @override
  Future<void> setSubtitleIndex(int index, {int slot = 0}) async {
    subtitleCalls.add(index);
    await super.setSubtitleIndex(index, slot: slot);
  }
}

class _FailOpenBackend extends FakeVideoBackend {
  @override
  Future<void> open(VideoOpenRequest request) async {
    throw StateError('media open failed');
  }
}

class _RetryOpenBackend extends FakeVideoBackend {
  int attempts = 0;

  @override
  Future<void> open(VideoOpenRequest request) async {
    attempts++;
    if (attempts == 1) throw StateError('first open failed');
    await super.open(request);
  }
}

class _ControlledSourceBackend extends FakeVideoBackend {
  Completer<void>? blockNext;
  bool failNext = false;

  @override
  Future<void> open(VideoOpenRequest request) async {
    final gate = blockNext;
    blockNext = null;
    if (gate != null) await gate.future;
    if (failNext) {
      failNext = false;
      throw StateError('selected source could not open');
    }
    await super.open(request);
  }
}

class _FakeDisplayControl implements PhoneDisplayControl {
  double _brightness = 0.5;
  double _volume = 0.5;

  double get brightnessValue => _brightness;
  double get volumeValue => _volume;

  @override
  Future<double> brightness() async => _brightness;

  @override
  Future<void> setBrightness(double value) async => _brightness = value;

  @override
  Future<double> volume() async => _volume;

  @override
  Future<void> setVolume(double value) async => _volume = value;
}

class _FailDisplayControl extends _FakeDisplayControl {
  @override
  Future<void> setBrightness(double value) async {
    throw StateError('platform denied brightness');
  }
}

class _FailVolumeDisplayControl extends _FakeDisplayControl {
  @override
  Future<void> setVolume(double value) async {
    throw StateError('platform denied volume');
  }
}

class _InvalidBrightnessDisplayControl extends _FakeDisplayControl {
  @override
  Future<double> brightness() async => -1;
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

class _PhonePresentationBackend extends FakeVideoBackend
    implements VideoBackendPhonePresentation {
  @override
  final ValueNotifier<Map<String, dynamic>> phonePresentation = ValueNotifier({
    'supported': true,
    'foreground': true,
  });
  @override
  Future<void> configurePhonePresentation(bool enabled) async {}
  @override
  Future<Map<String, dynamic>> refreshPhonePresentation() async =>
      phonePresentation.value;
  @override
  Future<bool> enterPictureInPicture() async {
    phonePresentation.value = {
      'supported': true,
      'active': true,
      'retainPlayback': true,
      'foreground': false,
    };
    return true;
  }
}

final cases = CaseShard(4, defaultSemantics: true);

void mainShard(int part, int expectedParts) =>
    cases.register(part, main, expectedParts: expectedParts);

class _RecoveryGateBackend extends FakeVideoBackend {
  static const surfaceKey = Key('recovery-test-video-surface');
  Completer<void>? openGate;
  bool waiting = false;

  @override
  Future<void> open(VideoOpenRequest request) async {
    final gate = openGate;
    if (gate != null) {
      waiting = true;
      await gate.future;
    }
    await super.open(request);
  }

  @override
  Widget buildView({Key? key}) => const SizedBox.expand(key: surfaceKey);
}
