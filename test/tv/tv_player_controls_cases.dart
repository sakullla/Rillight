import '../helpers/widget_harness.dart';
import '../helpers/settle.dart';
import '../helpers/synthetic_source_fixture.dart';
import '../helpers/image_cache_fixture.dart';

import 'package:rillight/app/app.dart';
import 'package:rillight/app/appearance_style.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/player/player_window_host.dart';

import 'dart:async';

import 'package:rillight/app/ui/ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/player/player_keys.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/media_server/device.dart';
import 'package:rillight/player/buffer_snapshot.dart';
import 'package:rillight/player/buffered_ranges_track.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/network_throughput.dart';
import 'package:rillight/player/playback_output_status.dart';
import 'package:rillight/player/player_controller.dart';
import 'package:rillight/media_server/playback.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/source_switch_menu.dart';
import 'package:rillight/player/tv_player_page.dart';
import 'package:rillight/player/video_backend.dart';

import '../emby/fake_emby_server.dart';

void main() {
  Future<PlayerController> start(
    WidgetTester tester,
    FakeVideoBackend video, {
    bool reducedMotion = false,
    Size size = const Size(960, 540),
    String itemId = 'movie-inception',
    String? extraLine,
    bool multipleSources = false,
    void Function(FakeEmbyServer server)? prepare,
  }) async {
    final server = FakeEmbyServer();
    prepare?.call(server);
    if (multipleSources) {
      server.items.firstWhere((i) => i.id == itemId).extraSources = const [
        FakeMediaSource(id: 'alternate', name: 'HDR60 alternate'),
      ];
    }
    final alias = extraLine == null
        ? null
        : FakeEmbyServer(
            serverId: server.serverId,
            serverName: server.serverName,
            baseUrl: Uri.parse(extraLine),
            views: server.views,
            items: server.items,
          );
    final auth = AuthController.memory(
      client: EmbyClient(
        device: const ClientDeviceInfo(
          clientName: 'test',
          deviceName: 'tv',
          deviceId: 'tv-controls',
          version: '1',
        ),
        dio: dioForFakeEmby(FakeEmbyAdapter([server, ?alias])),
      ),
    );
    await tester.runAsync(
      () => auth.connect(
        address: server.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      ),
    );
    await tester.runAsync(
      () => auth.selectLine(
        auth.session!.server.id,
        LineSelection.fixed(auth.session!.server.activeLineId!),
      ),
    );
    alias?.issuedTokens.addAll(server.issuedTokens);
    if (extraLine != null) {
      final line = extraLine;
      await tester.runAsync(() => auth.addLine(auth.session!.server.id, line));
    }
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 4));
      auth.dispose();
    });
    await tester.pumpWidget(
      AuthScope(
        controller: auth,
        child: PlayerScope(
          bindings: PlayerBindings(
            createBackend: () => video,
            controlsHideAfter: const Duration(seconds: 2),
            snapshotStore: MemoryPlaybackSessionSnapshotStore(),
            settingsStore: MemoryPlayerSettingsStore(),
          ),
          child: CupertinoApp(
            locale: const Locale('zh', 'CN'),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: [
              AppLocalizations.delegate,
              ...GlobalCupertinoLocalizations.delegates,
            ],
            theme: AppUiTheme.dark().cupertino,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(disableAnimations: reducedMotion),
              child: child!,
            ),
            home: Builder(
              builder: (context) => AppButton(
                onPressed: () => Navigator.of(context).push(
                  CupertinoPageRoute<void>(
                    builder: (_) =>
                        TvPlayerPage(itemId: itemId, autoResume: false),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    // A pending native open must not be awaited by pumpAndSettle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    return tester
        .state<TvPlayerPageState>(find.byType(TvPlayerPage))
        .controller!;
  }

  for (final width in [960.0, 1280.0, 1920.0]) {
    testWidgets(
      'routed TV player and panels retain scaled dark theme at $width',
      (tester) async {
        isolateImageCache();
        tester.view.physicalSize = Size(width, width * 9 / 16);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final server = FakeEmbyServer();
        final auth = SyntheticSourceAuth(
          adapter: FakeEmbyAdapter([server]),
          device: const ClientDeviceInfo(
            clientName: 'test',
            deviceName: 'tv',
            deviceId: 'tv-theme',
            version: '1',
          ),
          libraryIds: {'view-movies', 'view-tv'},
        );
        await tester.runAsync(
          () => auth.connect(
            address: server.baseUrl.toString(),
            username: 'alice',
            password: 'correct-horse',
          ),
        );
        final runtime = (await tester.runAsync(auth.runtime))!;
        final appearance = AppearanceController(
          store: MemoryPlayerSettingsStore(
            const PlayerSettings(appearanceStyle: 'light'),
          ),
        );
        await appearance.ready;
        final app = RillightApp(
          auth: auth,
          appearance: appearance,
          environment: PresentationEnvironment.tv,
          playerBindings: PlayerBindings(
            runtime: runtime,
            createBackend: () => FakeVideoBackend(),
            controlsHideAfter: const Duration(minutes: 10),
            snapshotStore: MemoryPlaybackSessionSnapshotStore(),
            settingsStore: MemoryPlayerSettingsStore(),
          ),
        );
        PlayerController? playing;
        var finished = false;
        Future<void> finishRoutedPlayer() async {
          if (finished) return;
          finished = true;
          await tester.pumpWidget(const SizedBox.shrink());
          var closed = false;
          final cleanup = playing?.disposeAsync().then((_) => closed = true);
          for (var frame = 0; frame < 80 && !closed; frame++) {
            await tester.pump(const Duration(milliseconds: 50));
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 5)),
            );
          }
          if (cleanup != null) {
            expect(
              closed,
              isTrue,
              reason: 'Actual TV controller cleanup must complete',
            );
            await cleanup;
          }
          app.router.dispose();
          await tester.runAsync(runtime.history.close);
          appearance.dispose();
          auth.dispose();
        }

        addTearDown(finishRoutedPlayer);
        await tester.pumpWidget(app);
        await settle(tester);
        expect(appearance.brightness, Brightness.light);
        unawaited(
          app.router.push(
            '/play/movie-inception',
            extra: PlayerOpenRequest(
              itemId: 'movie-inception',
              autoResume: false,
            ),
          ),
        );
        await settle(tester);
        final current = tester
            .state<TvPlayerPageState>(find.byType(TvPlayerPage))
            .controller!;
        playing = current;
        expect(current.loading, isFalse);
        current.setControlsPinned(true);
        final scale = width / 960;
        void expectTheme(BuildContext context) {
          final theme = AppUiTheme.of(context);
          expect(theme.brightness, Brightness.dark);
          expect(theme.tv, isTrue);
          expect(
            theme.textTheme.bodyMedium!.fontSize,
            closeTo(13.5 * scale, .001),
          );
          expect(
            theme.textTheme.headlineSmall!.fontSize,
            closeTo(19 * scale, .001),
          );
          expect(
            CupertinoTheme.of(context).textTheme.textStyle.fontSize,
            closeTo(13.5 * scale, .001),
          );
        }

        expectTheme(tester.element(find.byKey(const Key('tv-player-speed'))));
        current.networkSlow = true;
        current.notifyListeners();
        await tester.pump();
        final dismiss = find.byKey(const Key('tv-dismiss-network-hint'));
        final buttonSurface = find.descendant(
          of: dismiss,
          matching: find.byType(AnimatedContainer),
        );
        Focus.of(tester.element(buttonSurface)).requestFocus();
        await settle(tester);
        final theme = AppUiTheme.of(tester.element(dismiss));
        final decoration =
            tester
                    .widget<AnimatedContainer>(
                      find.descendant(
                        of: dismiss,
                        matching: find.byType(AnimatedContainer),
                      ),
                    )
                    .decoration!
                as ShapeDecoration;
        expect(decoration.color, theme.colorScheme.inverseSurface);
        final icon = find.descendant(of: dismiss, matching: find.byType(Icon));
        expect(
          IconTheme.of(tester.element(icon)).color,
          theme.colorScheme.onInverseSurface,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await tester.pump();
        expect(current.networkSlow, isFalse);
        expect(dismiss, findsNothing);
        await tester.tap(find.byKey(const Key('tv-player-speed')));
        await settle(tester);
        final panel = find.byKey(const Key('tv-player-panel'));
        expectTheme(tester.element(panel));
        final text = tester.widgetList<Text>(
          find.descendant(of: panel, matching: find.byType(Text)),
        );
        expect(text.any((t) => t.style?.fontSize == 19 * scale), isTrue);
        expect(text.any((t) => t.style?.fontSize == 13.5 * scale), isTrue);
        final selected = find.byKey(const Key('tv-rate-1.0'));
        final focusFill = tester
            .widgetList<DecoratedBox>(
              find.descendant(
                of: selected,
                matching: find.byType(DecoratedBox),
              ),
            )
            .map((box) => box.decoration)
            .whereType<BoxDecoration>();
        expect(
          focusFill.any((d) => d.color == theme.colorScheme.inverseSurface),
          isTrue,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await settle(tester);
        expect(current.playbackRate, isNot(1.0));
        expect(tester.takeException(), isNull);
        await finishRoutedPlayer();
      },
      tags: ['integration'],
    );
  }

  testWidgets('TV idle controls hide while playback is rebuffering', (
    tester,
  ) async {
    final backend = FakeVideoBackend();
    final current = await start(tester, backend);
    current.onUserActivity();
    backend.emitBuffering(true);
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(current.controlsVisible, isFalse);
    expect(
      find.byKey(const Key('tv-player-gradient'), skipOffstage: false),
      findsNothing,
    );
    backend.emitBuffering(false);
    await tester.pump();
    expect(current.controlsVisible, isFalse);
    await current.togglePlay();
    await tester.pump();
    expect(current.controlsVisible, isTrue);
    expect(find.byKey(const Key('tv-player-gradient')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 4));
    await settle(tester);
  }, tags: ['integration']);

  testWidgets('TV completion focuses replay and remote can replay or close', (
    tester,
  ) async {
    final backend = FakeVideoBackend(duration: const Duration(minutes: 148));
    final current = await start(tester, backend);
    backend.completePlayback();
    await settle(tester);
    expect(find.byKey(PlayerKeys.playbackEnded), findsOneWidget);
    expect(
      tester
          .widget<TvAction>(find.byKey(PlayerKeys.replay))
          .focusNode!
          .hasFocus,
      isTrue,
    );
    final opens = backend.openCount;
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await settle(tester);
    expect(current.playbackEnded, isFalse);
    expect(backend.openCount, greaterThan(opens));
    backend.completePlayback();
    await settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    for (
      var i = 0;
      i < 40 && find.byType(TvPlayerPage).evaluate().isNotEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.byType(TvPlayerPage), findsNothing);
    expect(find.text('open'), findsOneWidget);
  }, tags: ['integration']);

  Future<void> key(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await settle(tester);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 4));
    await settle(tester);
  }

  bool focused(WidgetTester tester, String key) => tester
      .widgetList<Semantics>(
        find.descendant(
          of: find.byKey(Key(key)),
          matching: find.byType(Semantics),
        ),
      )
      .any((s) => s.properties.focused == true);

  testWidgets(
    'single-choice TV tracks quality and source actions stay hidden',
    (tester) async {
      final c = await start(tester, FakeVideoBackend());
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
      for (final key in ['tv-player-quality', 'tv-player-source']) {
        expect(find.byKey(Key(key)), findsNothing);
      }
      // 无自带字幕的媒体也保留轨道入口:本地导入在那里(R1/R2)。
      expect(find.byKey(const Key('tv-player-tracks')), findsOneWidget);
      await tester.tap(find.byKey(const Key('tv-player-tracks')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tv-subtitle-off')), findsOneWidget);
      expect(find.byKey(const Key('tv-subtitle-import')), findsOneWidget);
      expect(find.byKey(const Key('tv-player-speed')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
    tags: ['integration'],
  );

  testWidgets('TV tracks panel applies subtitle size on the shared surface', (
    tester,
  ) async {
    final video = FakeVideoBackend();
    final c = await start(tester, video);
    c.subtitleStreamIndex = 1;
    c.resolved = ResolvedPlayback(
      playMethod: PlayMethod.directPlay,
      streamUrl: Uri.parse('https://example.test/media'),
      playSessionId: 'session',
      mediaSource: const PlaybackMediaSource(
        id: 'only',
        mediaStreams: [
          MediaStreamInfo(
            index: 1,
            type: 'Subtitle',
            isTextSubtitleStream: true,
            displayTitle: 'Chinese',
          ),
        ],
      ),
      itemId: c.itemId,
    );
    c.onUserActivity();
    await settle(tester);
    expect(c.canAdjustSubtitleSize, isTrue);
    await tester.tap(find.byKey(const Key('tv-player-tracks')));
    await settle(tester);
    final extraLarge = find.byKey(
      const ValueKey('tv-subtitle-size-extraLarge'),
    );
    await tester.ensureVisible(extraLarge);
    await settle(tester);
    await tester.tap(extraLarge);
    await settle(tester);
    expect(c.phoneSubtitleSettings.size, PhoneSubtitleSize.extraLarge);
    expect(video.subtitlePresentation, isNotNull);
    expect(video.subtitlePresentation!.userScale, 1.5);
    expect(video.subtitlePresentation!.displayWidth, 960);
    expect(video.subtitlePresentation!.displayHeight, 540);
    expect(tester.takeException(), isNull);
    await finish(tester);
  }, tags: ['integration']);

  testWidgets('TV tracks panel selects an independent secondary subtitle', (
    tester,
  ) async {
    final video = FakeVideoBackend();
    final c = await start(tester, video);
    c.subtitleStreamIndex = 1;
    c.resolved = ResolvedPlayback(
      playMethod: PlayMethod.directPlay,
      streamUrl: Uri.parse('https://example.test/media'),
      playSessionId: 'session',
      mediaSource: const PlaybackMediaSource(
        id: 'only',
        mediaStreams: [
          MediaStreamInfo(
            index: 1,
            type: 'Subtitle',
            isTextSubtitleStream: true,
            displayTitle: 'Chinese',
          ),
          MediaStreamInfo(
            index: 2,
            type: 'Subtitle',
            isTextSubtitleStream: true,
            displayTitle: 'English',
          ),
        ],
      ),
      itemId: c.itemId,
    );
    c.onUserActivity();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tv-player-tracks')));
    await tester.pumpAndSettle();
    expect(find.text('主字幕'), findsOneWidget);
    expect(find.text('次字幕'), findsOneWidget);
    expect(find.byKey(const Key('tv-subtitle-import')), findsOneWidget);

    final panelScroll = find
        .descendant(
          of: find.byType(TvPlayerPage),
          matching: find.byType(Scrollable),
        )
        .first;
    final secondary = find.byKey(const ValueKey('tv-subtitle-secondary-2'));
    await tester.scrollUntilVisible(secondary, 240, scrollable: panelScroll);
    await tester.pumpAndSettle();
    await tester.tap(secondary);
    await tester.pumpAndSettle();
    expect(c.secondarySubtitleStreamIndex, 2);
    expect(video.secondarySubtitleIndex, 2);
    expect(c.subtitleStreamIndex, 1, reason: '另一槽位不受影响');

    // 同一来源不可重复占用两槽:选择次槽已占用轨时给出提示且不改变现状。
    final occupied = find.byKey(const ValueKey('subtitle-2'));
    await tester.scrollUntilVisible(occupied, -240, scrollable: panelScroll);
    await tester.pumpAndSettle();
    await tester.tap(occupied);
    await tester.pumpAndSettle();
    expect(c.subtitleStreamIndex, 1);
    expect(c.secondarySubtitleStreamIndex, 2);
    expect(find.byKey(const Key('tv-subtitle-import-notice')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await finish(tester);
  }, tags: ['integration']);

  testWidgets(
    'surface remote seek and scan preserve playing and paused intent',
    (tester) async {
      final video = FakeVideoBackend();
      await start(tester, video);
      await settle(tester);
      expect(video.isPlaying, isTrue);
      await key(tester, LogicalKeyboardKey.arrowRight);
      expect(video.position, const Duration(seconds: 10));
      expect(video.isPlaying, isTrue);
      await key(tester, LogicalKeyboardKey.select);
      expect(video.isPlaying, isFalse);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      for (var i = 0; i < 8; i++) {
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump(const Duration(milliseconds: 40));
      }
      // Scan previews locally and commits once on release.
      expect(video.position, const Duration(seconds: 10));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
      await settle(tester);
      expect(video.position, const Duration(seconds: 160));
      expect(video.isPlaying, isFalse);
      await key(tester, LogicalKeyboardKey.arrowLeft);
      expect(video.position, const Duration(seconds: 150));
      await key(tester, LogicalKeyboardKey.select);
      expect(video.isPlaying, isTrue);
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
    tags: ['integration'],
  );

  testWidgets(
    'TV source target retains focus while opening and ignores repeated selection',
    (tester) async {
      final video = _SourceSwitchBackend();
      final c = await start(
        tester,
        video,
        reducedMotion: true,
        multipleSources: true,
      );
      await settle(tester);
      c.onUserActivity();
      await settle(tester);
      await tester.tap(find.byKey(const Key('tv-player-source')));
      await settle(tester);
      final target = find.byKey(const ValueKey('source-alternate'));
      await tester.ensureVisible(target);
      video.gate = Completer<void>();
      await tester.tap(target);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final node = FocusManager.instance.primaryFocus;
      expect(c.loading, isTrue);
      expect(node?.canRequestFocus, isTrue);
      expect(
        node?.context?.findAncestorWidgetOfExactType<TvAction>()?.key,
        target.evaluate().single.widget.key,
      );
      final opens = video.attempts;
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(video.attempts, opens);
      video.gate!.complete();
      await settle(tester);
      expect(c.loading, isFalse);
      expect(FocusManager.instance.primaryFocus, same(node));
      await finish(tester);
    },
    tags: ['integration'],
  );

  testWidgets('D-pad reaches every panel and back restores its entry focus', (
    tester,
  ) async {
    final c = await start(tester, FakeVideoBackend(), reducedMotion: true);
    c.mediaSources = [
      ...c.mediaSources,
      const PlaybackMediaSource(id: 'alternate'),
    ];
    c.onUserActivity();
    await settle(tester);
    await key(tester, LogicalKeyboardKey.arrowDown);
    expect(focused(tester, 'tv-player-toggle'), isTrue);
    expect(find.byKey(const Key('player-playback-lines')), findsOneWidget);
    expect(find.text('手动切换'), findsNothing);
    for (final entry in [
      'tracks',
      'quality',
      'lines',
      'source',
      'skip',
      'speed',
    ]) {
      await key(tester, LogicalKeyboardKey.arrowRight);
      if (entry == 'lines') {
        expect(focused(tester, 'player-playback-lines'), isTrue);
        final origin = FocusManager.instance.primaryFocus;
        await key(tester, LogicalKeyboardKey.select);
        expect(find.byType(PlaybackLineMenu), findsOneWidget);
        expect(find.byKey(const Key('playback-line-auto')), findsOneWidget);
        expect(c.controlsPinned, isTrue);
        await tester.binding.handlePopRoute();
        await settle(tester);
        expect(FocusManager.instance.primaryFocus, same(origin));
        expect(c.controlsPinned, isFalse);
        continue;
      }
      expect(focused(tester, 'tv-player-$entry'), isTrue);
      final origin = FocusManager.instance.primaryFocus;
      await key(tester, LogicalKeyboardKey.select);
      expect(find.byKey(const Key('tv-player-panel')), findsOneWidget);
      expect(c.controlsPinned, isTrue);
      expect(FocusManager.instance.primaryFocus, isNot(same(origin)));
      final viewport = tester.getRect(
        find.descendant(
          of: find.byKey(const Key('tv-player-panel')),
          matching: find.byType(SingleChildScrollView),
        ),
      );
      final focusedOption = find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            widget.properties.focused == true &&
            widget.properties.button == true,
      );
      final border = tester.renderObject<RenderBox>(
        find
            .descendant(of: focusedOption, matching: find.byType(DecoratedBox))
            .first,
      );
      final paintedBorder = MatrixUtils.transformRect(
        border.getTransformTo(null),
        Offset.zero & border.size,
      );
      expect(paintedBorder.left, greaterThanOrEqualTo(viewport.left));
      expect(paintedBorder.right, lessThanOrEqualTo(viewport.right));
      if (entry == 'skip') {
        expect(c.skipIntroEnabled, isTrue);
        await key(tester, LogicalKeyboardKey.select);
        expect(c.skipIntroEnabled, isFalse);
        await key(tester, LogicalKeyboardKey.arrowDown);
        await key(tester, LogicalKeyboardKey.select);
        expect(c.skipOutroEnabled, isFalse);
        expect(c.controlsPinned, isTrue);
      }
      await tester.binding.handlePopRoute();
      await settle(tester);
      expect(FocusManager.instance.primaryFocus, same(origin));
      expect(c.controlsPinned, isFalse);
    }
    await key(tester, LogicalKeyboardKey.select);
    await key(tester, LogicalKeyboardKey.arrowDown);
    await key(tester, LogicalKeyboardKey.select);
    expect(c.playbackRate, 1.25);
    await tester.binding.handlePopRoute();
    await settle(tester);
    await tester.binding.handlePopRoute();
    await settle(tester);
    expect(c.controlsVisible, isFalse);
    await key(tester, LogicalKeyboardKey.select);
    expect(c.isPlaying, isFalse);
    expect(tester.takeException(), isNull);
    await finish(tester);
  }, tags: ['integration']);

  testWidgets('TV line list shows only this server and the line in use', (
    tester,
  ) async {
    final c = await start(
      tester,
      FakeVideoBackend(),
      reducedMotion: true,
      extraLine: 'https://mirror.example:8443',
    );
    expect(c.playbackLines, hasLength(2));
    c.onUserActivity();
    await settle(tester);
    expect(find.text('手动切换'), findsNothing);
    expect(find.text('立即锁定'), findsNothing);
    await key(tester, LogicalKeyboardKey.arrowDown);
    var found = false;
    for (var step = 0; step < 6; step++) {
      await key(tester, LogicalKeyboardKey.arrowRight);
      if (focused(tester, 'player-playback-lines')) {
        found = true;
        break;
      }
    }
    expect(found, isTrue);
    await key(tester, LogicalKeyboardKey.select);
    await settle(tester);
    expect(find.byType(PlaybackLineMenu), findsOneWidget);
    expect(find.text('正在使用'), findsOneWidget);
    expect(find.text('mirror.example:8443'), findsOneWidget);
    expect(find.text('手动切换'), findsNothing);
    expect(tester.takeException(), isNull);
    await finish(tester);
  }, tags: ['integration']);

  testWidgets(
    'timeline confirms preview, hide returns surface focus and zero speed remains visible',
    (tester) async {
      final video = FakeVideoBackend();
      final c = await start(tester, video);
      await settle(tester);
      final snapshot = BufferSnapshot(
        sessionId: video.sessionId,
        resourceId: 'test',
        representationVersion: '1',
        trackVersion: 0,
        sequence: 1,
        ranges: const [
          BufferedRange(Duration.zero, Duration(seconds: 30)),
          BufferedRange(Duration(seconds: 60), Duration(seconds: 90)),
        ],
      );
      video.emitEvent(VideoEventKind.bufferSnapshot, snapshot);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final speed = tester.widget<NetworkSpeedReadout>(
        find.byKey(const Key('tv-player-network-speed')),
      );
      expect(speed.bytesPerSecond, 0);
      // 960 画布下不低于 12(1080p 上 24 像素、4K 上 48 像素),
      // 3 米外仍可读,又不和标题抢视线。
      expect(speed.textStyle!.fontSize, greaterThanOrEqualTo(12));
      expect(find.textContaining('缓存'), findsNothing);
      expect(
        tester
            .widget<BufferedRangesProgressIndicator>(
              find.byType(BufferedRangesProgressIndicator),
            )
            .snapshot
            .ranges,
        hasLength(2),
      );
      expect(
        tester.getRect(find.byKey(const Key('tv-player-gradient'))),
        const Rect.fromLTWH(0, 0, 960, 540),
      );
      await key(tester, LogicalKeyboardKey.arrowUp);
      await key(tester, LogicalKeyboardKey.arrowUp);
      expect(focused(tester, 'tv-player-seek'), isTrue);
      await key(tester, LogicalKeyboardKey.arrowRight);
      expect(video.position, Duration.zero);
      await key(tester, LogicalKeyboardKey.select);
      expect(video.position, const Duration(seconds: 10));
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(c.controlsVisible, isFalse);
      expect(find.byKey(const Key('tv-player-toggle')), findsNothing);
      await key(tester, LogicalKeyboardKey.arrowRight);
      expect(video.position, const Duration(seconds: 20));
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
    tags: ['integration'],
  );

  testWidgets(
    'native view stays mounted while loading and retry recovers focus',
    (tester) async {
      final video = _DelayedBackend();
      final c = await start(tester, video);
      expect(c.loading, isTrue);
      final session = c.bufferSnapshot.sessionId;
      video.emitEvent(
        VideoEventKind.bufferSnapshot,
        BufferSnapshot(
          sessionId: session,
          resourceId: 'tv-retry',
          representationVersion: 'v1',
          trackVersion: c.bufferSnapshot.trackVersion,
          sequence: c.bufferSnapshot.sequence + 1,
          ranges: const [],
          unknownReason: 'indexUnavailable',
          byteCoverage: BufferedByteCoverage(
            totalBytes: 800,
            ranges: const [BufferedByteRange(0, 200)],
          ),
        ),
        forSession: session,
      );
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('tv-player-byte-cache-track')), findsNothing);
      expect(find.byType(BufferedRangesProgressIndicator), findsOneWidget);
      final view = tester.element(find.byKey(const Key('native-view')));
      video.openGate.complete();
      await settle(tester);
      expect(c.loading, isFalse);
      expect(tester.element(find.byKey(const Key('native-view'))), same(view));
      video.emitError('network timeout');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await settle(tester);
      expect(c.disconnected, isTrue);
      expect(
        focused(tester, 'playback-recovery-retry'),
        isTrue,
        reason: '${FocusManager.instance.primaryFocus}',
      );
      await key(tester, LogicalKeyboardKey.select);
      expect(c.error, isNull);
      expect(c.disconnected, isFalse);
      expect(tester.element(find.byKey(const Key('native-view'))), same(view));
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
    tags: ['integration'],
  );

  testWidgets(
    'cancelling next episode blocks another auto countdown at natural end',
    (tester) async {
      final backend = FakeVideoBackend();
      final current = await start(
        tester,
        backend,
        itemId: 'episode-friends-s1e1',
      );
      for (var i = 0; i < 40 && current.loading; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(current.loading, isFalse);
      expect(current.itemId, 'episode-friends-s1e1');
      backend.emitEvent(
        VideoEventKind.position,
        backend.duration - const Duration(minutes: 1),
      );
      for (var i = 0; i < 40 && current.nextEpisode == null; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(current.nextEpisode?.item.id, 'episode-friends-s1e2');
      expect(current.nextEpisode?.remaining, isNull);
      await tester.pump();
      final nextCard = tester.getRect(find.byKey(PlayerKeys.nextEpisode));
      expect(nextCard.top, greaterThanOrEqualTo(0));
      expect(nextCard.bottom, lessThanOrEqualTo(540));
      expect(nextCard.left, greaterThanOrEqualTo(0));
      expect(nextCard.right, lessThanOrEqualTo(960));
      expect(
        find.byKey(PlayerKeys.nextEpisodePlay).hitTestable(),
        findsOneWidget,
      );
      expect(focused(tester, 'player-next-episode-play'), isTrue);
      await tester.ensureVisible(find.byKey(PlayerKeys.nextEpisodeCancel));
      await tester.tap(find.byKey(PlayerKeys.nextEpisodeCancel));
      await tester.pump();
      expect(current.nextEpisode, isNull);
      expect(current.itemId, 'episode-friends-s1e1');

      final opens = backend.openCount;
      backend.completePlayback();
      for (var i = 0; i < 40 && current.nextEpisode == null; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(current.itemId, 'episode-friends-s1e1');
      expect(current.nextEpisode?.item.id, 'episode-friends-s1e2');
      expect(current.nextEpisode?.remaining, isNull);
      expect(find.textContaining('秒后播放下一集'), findsNothing);
      await tester.pump(
        current.nextEpisodeCountdown + const Duration(seconds: 2),
      );
      expect(current.itemId, 'episode-friends-s1e1');
      expect(current.nextEpisode?.remaining, isNull);
      expect(backend.openCount, opens);
      expect(find.textContaining('秒后播放下一集'), findsNothing);

      await tester.ensureVisible(find.byKey(PlayerKeys.nextEpisodePlay));
      await tester.tap(find.byKey(PlayerKeys.nextEpisodePlay));
      for (
        var i = 0;
        i < 40 && (current.itemId != 'episode-friends-s1e2' || current.loading);
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(current.itemId, 'episode-friends-s1e2');
      expect(backend.openCount, greaterThan(opens));
      expect(backend.openedPaused, isFalse);
      expect(backend.isPlaying, isTrue);
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
    tags: ['integration'],
  );

  testWidgets(
    'TV output panel shows actual output without enhancement controls',
    (tester) async {
      final video = FakeVideoBackend()..isPlaying = true;
      final c = await start(tester, video);
      await settle(tester);
      final playing = video.isPlaying;
      final position = video.position;
      c.applyObservedOutput(
        PlaybackOutputStatus.fromCoreMap({
          'dolbyVisionProfile': 8,
          'dolbyVisionCompatibility': 2,
          'videoOutputKind': 1,
          'audioDelivery': 3,
          'audioChannels': 6,
          'audioAtmos': 1,
          'requestedSuperResolution': 2,
          'effectiveSuperResolution': 0,
          'reasonSuperResolution': 4,
          'catalogVideo': '杜比视界',
          'catalogAudio': 'Atmos',
        }),
      );
      c.onUserActivity();
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('tv-player-output')));
      await tester.tap(find.byKey(const Key('tv-player-output')));
      await settle(tester);
      expect(find.byKey(const Key('playback-output-panel')), findsOneWidget);
      final picture = tester
          .widget<Text>(find.byKey(const Key('playback-output-video')))
          .data!;
      final audio = tester
          .widget<Text>(find.byKey(const Key('playback-output-audio')))
          .data!;
      expect(picture, contains('SDR 映射'));
      expect(picture, isNot(contains('杜比')));
      expect(audio, contains('6 声道 PCM'));
      expect(audio, isNot(contains('Atmos')));
      expect(find.byKey(const Key('playback-enhance-choices')), findsNothing);
      c.applyObservedOutput(
        PlaybackOutputStatus.fromCoreMap({
          'dolbyVisionProfile': 8,
          'dolbyVisionCompatibility': 1,
          'videoOutputKind': 2,
          'outputColorSpace': 'BT.2020 PQ',
          'audioDelivery': 3,
          'audioChannels': 6,
          'requestedSuperResolution': 2,
          'effectiveSuperResolution': 0,
          'reasonSuperResolution': 4,
          'catalogVideo': '杜比视界',
          'catalogAudio': 'Atmos',
        }),
      );
      await tester.pump();
      expect(
        tester
            .widget<Text>(find.byKey(const Key('playback-output-video')))
            .data,
        contains('HDR（PQ）'),
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('playback-output-video')))
            .data,
        isNot(contains('杜比')),
      );
      expect(video.isPlaying, playing);
      expect(video.position, position);
      await finish(tester);
    },
    tags: ['integration'],
  );

  testWidgets('series playback opens a focusable episode list', (tester) async {
    final backend = FakeVideoBackend();
    final current = await start(
      tester,
      backend,
      itemId: 'episode-friends-s1e2',
    );
    for (var i = 0; i < 40 && current.loading; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(current.loading, isFalse);
    expect(find.byKey(const Key('tv-player-episodes')), findsOneWidget);
    await tester.tap(find.byKey(const Key('tv-player-episodes')));
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
    for (
      var i = 0;
      i < 40 && (current.itemId != 'episode-friends-s1e1' || current.loading);
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(current.itemId, 'episode-friends-s1e1');
    expect(find.byKey(const Key('player-episodes-panel')), findsOneWidget);
    await tester.tap(find.byKey(const Key('player-episodes-close')));
    await settle(tester);
    expect(find.byKey(const Key('player-episodes-panel')), findsNothing);
    expect(tester.takeException(), isNull);
    await finish(tester);
  }, tags: ['integration']);

  testWidgets('TV playback shows skip intro after the controls hide', (
    tester,
  ) async {
    const second = 10000000;
    final backend = FakeVideoBackend();
    final current = await start(
      tester,
      backend,
      itemId: 'episode-friends-s1e1',
      prepare: (server) {
        final episode = server.items.firstWhere(
          (item) => item.id == 'episode-friends-s1e1',
        );
        episode.played = false;
        episode.playedPercentage = 0;
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
    const skip = Key('tv-player-skip-segment');
    for (var i = 0; i < 40 && find.byKey(skip).evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(current.loading, isFalse);
    expect(find.byKey(skip), findsOneWidget);
    expect(find.text('跳过片头'), findsOneWidget);
    if (!current.controlsVisible) current.onUserActivity();
    await tester.pump();
    final skipRect = tester.getRect(find.byKey(skip));
    final seekRect = tester.getRect(find.byKey(const Key('tv-player-seek')));
    expect(skipRect.bottom, lessThanOrEqualTo(seekRect.top));
    expect(skipRect.top, greaterThanOrEqualTo(0));
    expect(skipRect.right, lessThanOrEqualTo(960));
    for (var i = 0; i < 10 && !focused(tester, 'tv-player-skip-segment'); i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(focused(tester, 'tv-player-skip-segment'), isTrue);
    if (current.controlsVisible) current.toggleControls();
    await tester.pump();
    expect(current.controlsVisible, isFalse);
    expect(find.byKey(skip), findsOneWidget);
    expect(focused(tester, 'tv-player-skip-segment'), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
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
    await finish(tester);
  }, tags: ['integration']);
}

class _DelayedBackend extends FakeVideoBackend {
  final openGate = Completer<void>();
  @override
  Future<void> open(VideoOpenRequest request) async {
    await openGate.future;
    await super.open(request);
  }

  @override
  Widget buildView({Key? key}) =>
      const ColoredBox(key: Key('native-view'), color: Color(0xff2196f3));
}

class _SourceSwitchBackend extends FakeVideoBackend {
  Completer<void>? gate;
  int attempts = 0;
  @override
  Future<void> open(VideoOpenRequest request) async {
    attempts++;
    await gate?.future;
    await super.open(request);
  }
}
