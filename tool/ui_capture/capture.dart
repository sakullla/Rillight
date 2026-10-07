import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/appearance_style.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/app/tv_appearance_picker.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/source_sessions.dart';
import 'package:rillight/auth/region_access.dart';
import 'package:rillight/aggregation/history/history_writer.dart';
import 'package:rillight/player/playback_runtime.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/auth/tv_connect_page.dart';
import 'package:rillight/auth/tv_lan_pair.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/home/phone_home_sections.dart';
import 'package:rillight/home/tv_section_prefs.dart';
import 'package:rillight/player/mobile_player_page.dart';
import 'package:rillight/home/phone_hero.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_keys.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/player_window_host.dart';
import 'package:rillight/player/buffer_snapshot.dart';
import 'package:rillight/player/video_backend.dart';
import 'package:rillight/player/danmaku/danmaku_glyph_cache.dart';

import '../../test/emby/fake_emby_server.dart';
import '../../test/helpers/image_cache_fixture.dart';
import 'fixtures.dart';
import 'pages.dart';
import 'danmaku.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  WidgetController.hitTestWarningShouldBeFatal = true;
  final out = Platform.environment['RILLIGHT_CAPTURE_OUT'];
  if (out == null) throw StateError('请运行 node tool/capture-ui.mjs');
  setUpAll(() async {
    final bytes = await File(
      Platform.environment['RILLIGHT_CAPTURE_FONT']!,
    ).readAsBytes();
    for (final family in {'Segoe UI', 'Roboto', ...danmakuFontFallbacks()}) {
      await (FontLoader(
        family,
      )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
    }
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  final configurations = <(String, PresentationEnvironment, Size)>[
    ('desktop', PresentationEnvironment.desktop, const Size(1440, 1000)),
    ('desktop', PresentationEnvironment.desktop, const Size(1024, 768)),
    ('phone', PresentationEnvironment.phone, const Size(360, 800)),
    ('phone', PresentationEnvironment.phone, const Size(412, 915)),
    ('tv', PresentationEnvironment.tv, const Size(1920, 1080)),
  ];
  for (final config in configurations) {
    final profiles = Platform.environment['RILLIGHT_CAPTURE_PROFILES'];
    if (profiles != null &&
        !profiles
            .split(',')
            .contains('${config.$1}-${config.$3.width.toInt()}')) {
      continue;
    }
    final selectedSizes =
        Platform.environment['RILLIGHT_CAPTURE_SIZE'] ?? 'all';
    if (selectedSizes != 'all' &&
        !selectedSizes.split(',').contains('${config.$3.width.toInt()}')) {
      continue;
    }
    final selectedPlatform = Platform.environment['RILLIGHT_CAPTURE_PLATFORM'];
    if (selectedPlatform != 'all' && selectedPlatform != config.$1) continue;
    for (final theme in ['dark', 'light']) {
      final selectedTheme = Platform.environment['RILLIGHT_CAPTURE_THEME'];
      if (selectedTheme != 'all' && selectedTheme != theme) continue;
      testWidgets('${config.$1} ${config.$3} $theme', (tester) async {
        isolateImageCache();
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = config.$3;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final capture = CaptureSession(
          tester,
          out,
          config.$1,
          theme,
          config.$3,
        );
        final server = captureServer();
        final mirror = FakeEmbyServer(
          serverId: 'capture-mirror',
          serverName: '合成来源 B',
          baseUrl: Uri.parse('http://capture-mirror.test:8096'),
          views: server.views,
          items: server.items,
        );
        final adapter = CaptureAdapter([server, mirror]);
        final credentials = MemoryCredentialStore();
        final servers = MemoryServerListStore();
        final sources = SourceSessionRegistry(
          access: RegionAccessController(),
          store: servers,
          credentials: credentials,
          createClient: () => EmbyClient(
            device: const EmbyDeviceInfo(
              clientName: '灯川原型',
              deviceName: 'UI capture',
              deviceId: 'synthetic-ui',
              version: '1',
            ),
            dio: dioForFakeEmby(adapter),
          ),
        );
        var backend = CaptureBackend();
        final store = MemoryPlayerSettingsStore(
          const PlayerSettings(
            danmakuAppId: 'capture-app',
            danmakuToken: 'synthetic-token',
          ),
        );
        final danmakuClient = captureDanmakuClient();
        final appearance = AppearanceController(
          store: MemoryPlayerSettingsStore(),
        );
        final auth = AuthController(
          client: EmbyClient(
            device: const EmbyDeviceInfo(
              clientName: '灯川原型',
              deviceName: 'UI capture',
              deviceId: 'synthetic-ui',
              version: '1',
            ),
            dio: dioForFakeEmby(adapter),
          ),
          credentials: credentials,
          servers: servers,
          sources: sources,
        );
        await tester.runAsync(() async {
          await auth.connect(
            address: server.baseUrl.toString(),
            username: 'alice',
            password: 'correct-horse',
          );
          final firstId = auth.session!.server.id;
          await sources.configureScope(
            firstId,
            participates: true,
            libraryIds: {'view-movies', 'view-tv'},
          );
          await auth.connect(
            address: mirror.baseUrl.toString(),
            username: 'alice',
            password: 'correct-horse',
          );
          await sources.configureScope(
            auth.session!.server.id,
            participates: true,
            libraryIds: {'view-movies', 'view-tv'},
          );
          await auth.switchTo(firstId);
          await appearance.setStyle(
            theme == 'dark' ? AppearanceStyle.dark : AppearanceStyle.light,
          );
          // Pre-render fixture images outside the fake animation clock.
          for (final item in [...server.items, ...server.views]) {
            for (final wide in [true, false]) {
              adapter.artwork['${item.id}-$wide'] = await drawArtwork(
                item.id,
                wide: wide,
              );
            }
          }
        });
        expect(auth.isLoggedIn, isTrue);
        final history = await HistoryWriter.open(
          registry: sources,
          store: MemoryHistoryStore(),
        );
        final runtime = PlaybackRuntime(auth: auth, history: history);
        final snapshots = MemoryPlaybackSessionSnapshotStore();
        final app = RillightApp(
          auth: auth,
          environment: config.$2,
          appearance: appearance,
          playerBindings: PlayerBindings(
            runtime: runtime,
            createBackend: () => backend,
            settingsStore: store,
            snapshotStore: snapshots,
            danmakuClient: danmakuClient,
            controlsHideAfter: const Duration(days: 1),
            progressInterval: const Duration(days: 1),
          ),
        );
        final gate = Completer<void>();
        adapter.catalogGate = gate;
        await tester.pumpWidget(
          RepaintBoundary(key: capture.boundary, child: app),
        );
        await capture.advance(120);
        await capture.save('home-loading-120ms');
        await capture.advance(360);
        await capture.save('home-loading-480ms');
        adapter.catalogGate = null;
        gate.complete();
        await capture.advance(1200);
        await capture.save('home-ready');
        if (config.$1 == 'phone' && capture.wants('home')) {
          for (final scale in [1.3, 2.0]) {
            tester.platformDispatcher.textScaleFactorTestValue = scale;
            await capture.advance(350);
            await capture.save(
              scale == 1.3 ? 'home-text-130' : 'home-text-200',
            );
          }
          tester.platformDispatcher.clearTextScaleFactorTestValue();
          await capture.advance(350);
        }

        if (capture.wants('home')) {
          if (config.$1 == 'desktop') {
            final card = find.byKey(CatalogKeys.item('movie-up'));
            await tester.scrollUntilVisible(
              card,
              320,
              scrollable: find
                  .descendant(
                    of: find.byKey(const PageStorageKey('home-scroll')),
                    matching: find.byType(Scrollable),
                  )
                  .first,
            );
            await tester.ensureVisible(card);
            await capture.advance(300);
            await capture.save('poster-normal');
            final mouse = await tester.createGesture(
              kind: PointerDeviceKind.mouse,
            );
            await mouse.addPointer(location: Offset.zero);
            await mouse.moveTo(tester.getCenter(card));
            await capture.advance(60);
            await capture.save('poster-hover-transition');
            await capture.advance(200);
            await capture.save('poster-hover');
            await mouse.removePointer();
          } else if (config.$1 == 'tv') {
            await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
            await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
            await capture.advance(300);
            await capture.save('home-remote-focus');
            await capture.captureTvSectionMove();
          } else {
            await tester.drag(
              find.byType(Scrollable).first,
              const Offset(0, -420),
            );
            await capture.advance(400);
            await capture.save('home-shelves');
          }
        }
        if (config.$1 == 'phone' && capture.wants('detail')) {
          app.router.go('/');
          await capture.advance(500);
          await revealPhoneHero(tester, capture);
          final loading = Completer<void>();
          adapter.detailGate = loading;
          await capture.activate(find.byKey(PhoneHero.openKey));
          expect(
            find.byKey(const Key('phone-detail-pending-action')),
            findsOneWidget,
          );
          final pendingAction = tester.getRect(
            find.byKey(const Key('mobile-detail-play')),
          );
          await capture.save('detail-from-home-loading');
          adapter.detailGate = null;
          loading.complete();
          await capture.advance(800);
          final loadedAction = tester.getRect(
            find.byKey(const Key('mobile-detail-play')),
          );
          expect(
            (loadedAction.top - pendingAction.top).abs(),
            lessThanOrEqualTo(4),
          );
          await capture.save('detail-from-home-ready');
        }
        await capture.pages(app, auth, server, adapter);
        if (config.$1 == 'phone' && capture.wants('home')) {
          app.router.go('/');
          await capture.advance(400);
          await tester.tap(find.byType(NavigationDestination).first);
          await capture.advance(400);
          await revealPhoneHero(tester, capture);
          final catalog = CatalogScope.of(
            tester.element(find.byType(PhoneHero)),
          );
          // 轮播只取最近入库的电影/剧集交错,与观看记录无关;用圆点切到
          // 剧集页,主操作「播放」要先解析出该播的那一集。
          final seriesPage = PhoneHero.featuredItemsOf(
            catalog,
          ).indexWhere((item) => item.id == 'series-friends');
          expect(seriesPage, greaterThanOrEqualTo(0));
          await tester.ensureVisible(find.byKey(PhoneHero.bannerKey));
          await capture.advance(300);
          await capture.tap(CatalogKeys.heroDot(seriesPage));
          await capture.advance(700);
          await capture.save('home-series-featured');
          await capture.tap(const ValueKey('hero-resume-series-friends'));
          await capture.advance(1000);
          expect(
            tester
                .widget<MobilePlayerPage>(find.byType(MobilePlayerPage))
                .itemId,
            'episode-friends-s1e2',
          );
          await capture.save('player-from-series-hero');
          app.router.pop();
          await capture.advance(500);
          backend = CaptureBackend();
        }

        if (capture.wants('player') || capture.wants('danmaku')) {
          app.router.go('/item/movie-up');
          await capture.advance(800);

          // Force a deterministic loading state, then use the actual player route.
          final openGate = Completer<void>();
          backend.openGate = openGate;
          if (config.$1 == 'desktop') {
            await capture.tap(PlayerKeys.open);
          } else {
            app.router.go('/play/movie-up');
          }
          await capture.advance(400);
          await capture.save('player-loading');
          backend.openGate = null;
          openGate.complete();
          await capture.advance(1200);
          if (find.byKey(PlayerKeys.resumeFromStart).evaluate().isNotEmpty) {
            await capture.tap(PlayerKeys.resumeFromStart);
          }
          await capture.save('player-controls');
          expect(backend.openCount, greaterThan(0));
          backend.emitEvent(VideoEventKind.cacheSpeed, 2621440);
          backend.emitEvent(
            VideoEventKind.bufferSnapshot,
            BufferSnapshot(
              sessionId: backend.sessionId,
              resourceId: 'capture-media',
              representationVersion: 'v1',
              trackVersion: 0,
              sequence: 1,
              ranges: const [
                BufferedRange(Duration.zero, Duration(minutes: 18)),
              ],
            ),
          );
          await capture.advance(200);
          await capture.save('player-cache-active');
          backend.emitEvent(VideoEventKind.cacheSpeed, 0);
          await capture.advance(200);
          await capture.save('player-cache-idle');
          backend.emitBuffering(true);
          await capture.advance(400);
          await capture.save('player-buffering');
          backend.emitBuffering(false);
          await capture.advance(200);

          if (config.$1 == 'desktop') {
            final mouse = await tester.createGesture(
              kind: PointerDeviceKind.mouse,
            );
            await mouse.addPointer(location: Offset.zero);
            await mouse.moveTo(
              tester.getCenter(find.byKey(PlayerKeys.seekBar)),
            );
            await capture.advance(200);
            await capture.save('player-seek-preview');
            await mouse.moveTo(
              tester.getCenter(find.byKey(PlayerKeys.playPause)),
            );
            await capture.advance(200);
            await capture.tap(PlayerKeys.playPause);
            await capture.save('player-paused');
            await capture.tap(PlayerKeys.more);
            await capture.save('player-settings-speed');
            await capture.tap(const Key('player-skip-settings-section'));
            await capture.save('player-settings-skip');
            for (final entry in [
              ('audio', PlayerKeys.audio),
              ('quality', PlayerKeys.quality),
              ('source', PlayerKeys.mediaSource),
            ]) {
              await capture.tap(entry.$2);
              await capture.save('player-settings-${entry.$1}');
            }
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
            await capture.advance(250);
            await capture.tap(PlayerKeys.subtitle);
            await capture.save('player-subtitles');
            await capture.dismiss();
            await capture.danmakuPages(danmakuClient);
            await mouse.removePointer();
          } else if (config.$1 == 'phone') {
            for (final scale in [1.3, 2.0]) {
              tester.platformDispatcher.textScaleFactorTestValue = scale;
              await capture.advance(200);
              await capture.revealPhoneControls();
              await capture.save(
                'player-controls-text-${(scale * 100).round()}',
              );
            }
            tester.platformDispatcher.clearTextScaleFactorTestValue();
            await capture.advance(200);
            await capture.revealPhoneControls();
            await capture.save('player-pip-entry');
            await capture.tap(const Key('mobile-player-pip'));
            expect(find.byKey(const Key('mobile-player-toggle')), findsNothing);
            await capture.save('player-pip-controls-hidden');
            backend.phonePresentation.value = {
              'supported': true,
              'foreground': true,
              'active': false,
            };
            await capture.advance(200);
            await capture.tap(const Key('mobile-player-lock'));
            await capture.save('player-locked');
            await capture.tap(const Key('mobile-player-unlock'));
            await capture.tap(const Key('mobile-player-toggle'));
            await capture.save('player-paused');
            await capture.phonePanels();
            tester.view.physicalSize = Size(config.$3.height, config.$3.width);
            await capture.advance(500);
            await capture.save('player-landscape-controls');
            await capture.phonePanels(prefix: 'player-landscape');
            await capture.danmakuPages(
              danmakuClient,
              prefix: 'danmaku-landscape',
            );
            tester.view.physicalSize = config.$3;
            await capture.advance(500);
            await capture.danmakuPages(danmakuClient);
          } else {
            await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
            await capture.advance(200);
            await capture.save('player-remote-focus');
            for (final section in [
              'tracks',
              'quality',
              'source',
              'skip',
              'speed',
            ]) {
              final key = Key('tv-player-$section');
              if (find.byKey(key).evaluate().isEmpty) continue;
              await capture.tap(key);
              await capture.save('player-settings-$section');
              await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
              await capture.advance(200);
              await capture.save('player-settings-$section-focus');
              await capture.tap(const Key('tv-panel-back'));
            }
          }
          if (capture.wants('player')) {
            Future<void> openExtra(
              String itemId, {
              bool autoResume = false,
            }) async {
              if (config.$1 == 'desktop') {
                await app.windowHost.close();
              } else {
                app.router.go('/item/$itemId');
                await capture.advance(300);
              }
              backend = CaptureBackend();
              final ticks = server.items
                  .firstWhere((item) => item.id == itemId)
                  .runTimeTicks;
              if (ticks != null) {
                backend.duration = Duration(microseconds: ticks ~/ 10);
              }
              final request = PlayerOpenRequest(
                itemId: itemId,
                autoResume: autoResume,
              );
              if (config.$1 == 'desktop') {
                await app.windowHost.open(request);
              } else {
                app.router.go('/play/$itemId', extra: request);
              }
              await capture.advance(800);
            }

            await openExtra('movie-inception', autoResume: true);
            expect(backend.position, greaterThan(Duration.zero));
            await capture.save('player-resumed');
            await capture.advance(400);
            backend.completePlayback();
            await capture.advance(500);
            await capture.save('player-ended');
            await openExtra('episode-friends-s1e2');
            await capture.save('player-episode');
            if (config.$1 == 'desktop') {
              await capture.tap(const Key('player-episodes'));
              await capture.save('player-episode-list');
              await capture.modal(
                const Key('player-season-picker'),
                'player-season-picker',
              );
              await capture.tap(const Key('player-episodes-close'));
            }
            await backend.seek(backend.duration - const Duration(seconds: 10));
            await capture.advance(500);
            expect(find.byKey(PlayerKeys.nextEpisode), findsOneWidget);
            await capture.save('player-next-episode');
            backend.emitError('Synthetic playback failure');
            await capture.advance(400);
            await capture.save('player-error');
          }
          if (config.$1 == 'desktop') {
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
            await app.windowHost.close();
            await capture.advance(400);
          }
        }
        tester.view.physicalSize = config.$3;
        if (config.$1 == 'tv') {
          await capture.captureTvAppearance(app, snapshots);
        }
        if (capture.wants('login')) {
          await capture.loginPages(app, auth);
          if (config.$1 == 'tv') {
            final probeAuth = AuthController(
              client: EmbyClient(
                device: const EmbyDeviceInfo(
                  clientName: '灯川原型',
                  deviceName: 'UI capture',
                  deviceId: 'synthetic-ui-lan',
                  version: '1',
                ),
                dio: dioForFakeEmby(adapter),
              ),
              credentials: MemoryCredentialStore(),
              servers: MemoryServerListStore(),
            );
            try {
              await capture.captureTvLan(
                auth,
                server.baseUrl.toString(),
                probeAuth,
              );
            } finally {
              probeAuth.dispose();
            }
          }
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await capture.advance(500);
        await history.close();
        app.router.dispose();
        auth.dispose();
        appearance.dispose();
      }, tags: ['integration']);
    }
  }
}

/// 首页分区截图把列表上拉过;懒构建列表里滚出视口的轮播不存在,先滚回顶部。
Future<void> revealPhoneHero(
  WidgetTester tester,
  CaptureSession capture,
) async {
  if (find.byKey(PhoneHero.bannerKey).evaluate().isNotEmpty) return;
  await tester.drag(find.byType(Scrollable).first, const Offset(0, 2000));
  await capture.advance(400);
}

class CaptureSession {
  CaptureSession(this.tester, this.out, this.platform, this.theme, this.size);
  final WidgetTester tester;
  final String out, platform, theme;
  final Size size;
  final boundary = GlobalKey();
  final records = <Map<String, Object>>[];
  static final knownStates =
      (jsonDecode(File('tool/ui_capture/scenarios.json').readAsStringSync())
              as List)
          .map((entry) => (entry as Map)['id'] as String)
          .toSet();
  final selectedStates = (Platform.environment['RILLIGHT_CAPTURE_STATES'] ?? '')
      .split(',')
      .where((s) => s.isNotEmpty)
      .toSet();
  final selectedFeatures =
      (Platform.environment['RILLIGHT_CAPTURE_FEATURES'] ?? '')
          .split(',')
          .where((s) => s.isNotEmpty)
          .toSet();

  bool wants(String feature) =>
      selectedFeatures.isEmpty || selectedFeatures.contains(feature);

  Future<void> advance(int milliseconds) async {
    for (var elapsed = 0; elapsed < milliseconds; elapsed += 20) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    // Decode in-memory images and finish genuine asynchronous I/O.
    // Decoding, sampled-pixel extraction and the content scheme are separate
    // engine futures. Alternate real I/O and fake frames so captures include
    // the same resolved palette as production, rather than its loading theme.
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(tester.takeException(), isNull);
  }

  Future<void> revealPhoneControls() async {
    final player = find.byType(MobilePlayerPage);
    if (player.evaluate().length != 1) return;
    if (tester
            .state<MobilePlayerPageState>(player)
            .controller
            ?.controlsVisible ==
        false) {
      await tester.tapAt(Offset(20, tester.view.physicalSize.height * .45));
      await advance(100);
    }
  }

  Future<void> tap(Key key) async {
    final player = find.byType(MobilePlayerPage);
    if (platform == 'phone' &&
        key is ValueKey<String> &&
        key.value.startsWith('mobile-player-') &&
        player.evaluate().length == 1) {
      final state = tester.state<MobilePlayerPageState>(player);
      if (state.controller?.controlsVisible == false &&
          find.byKey(const Key('mobile-player-options')).evaluate().isEmpty) {
        // Palette settling also advances time. Reveal expired controls using
        // the actual gesture tree before interacting with their buttons.
        await tester.tapAt(Offset(20, tester.view.physicalSize.height * .45));
        await advance(100);
      }
    }
    var target = find.byKey(key);
    expect(target, findsOneWidget, reason: 'Missing capture interaction: $key');
    // ExpansionTile's whole render box includes its expanded children. Click
    // the header, otherwise a tall section's midpoint can hit a child instead.
    if (tester.widget(target) is ExpansionTile) {
      target = find
          .descendant(of: target, matching: find.byType(ListTile))
          .first;
    }
    await Scrollable.ensureVisible(tester.element(target), alignment: .5);
    await advance(100);
    await tester.tap(target);
    await advance(350);
  }

  Future<void> phonePanels({String prefix = 'player'}) async {
    await tap(const Key('mobile-player-more'));
    await save('$prefix-settings');
    for (final section in [
      'speed',
      'tracks',
      'quality',
      'picture',
      'skip',
      'danmaku',
    ]) {
      final key = ValueKey('mobile-player-section-$section');
      await tap(key);
      await save('$prefix-settings-$section');
      if (section == 'tracks') {
        final controller = tester
            .state<MobilePlayerPageState>(find.byType(MobilePlayerPage))
            .controller!;
        final track = controller.selectableSubtitleTracks.firstWhere(
          (track) => track.isTextSubtitle,
        );
        unawaited(controller.setSubtitle(track.index));
        await advance(600);
        await tap(const Key('phone-subtitle-large'));
        await save('$prefix-subtitle-large');
        await tap(const Key('phone-subtitle-original'));
        await save('$prefix-subtitle-original');
        await tap(const Key('phone-subtitle-reset'));
      }
      await tap(const Key('mobile-player-panel-back'));
    }
    await tap(const Key('mobile-player-source-entry'));
    await save('$prefix-settings-source');
    await tap(const Key('mobile-player-panel-back'));
    await tap(const Key('mobile-player-panel-close'));
  }

  Future<void> save(String state) async {
    expect(
      knownStates.contains(state),
      isTrue,
      reason: 'Unregistered capture state: $state',
    );
    if (selectedStates.isNotEmpty && !selectedStates.contains(state)) return;
    expect(find.text('Page Not Found'), findsNothing);
    final width = tester.view.physicalSize.width.toInt();
    final height = tester.view.physicalSize.height.toInt();
    final file = '$platform-${size.width.toInt()}-$theme-$state.png';
    await tester.runAsync(() async {
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await render.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('$out/$file').writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
      records.add({
        'platform': platform,
        'theme': theme,
        'state': state,
        'width': width,
        'height': height,
        'profileWidth': size.width.toInt(),
        'renderedTheme':
            state.startsWith('player') ||
                state.startsWith('danmaku') ||
                state.startsWith('detail-gallery') ||
                state == 'tv-lan-phone'
            ? 'dark'
            : theme,
        'file': file,
      });
      await File(
        '$out/$platform-${size.width.toInt()}-$theme.json',
      ).writeAsString(jsonEncode(records));
    });
    // ignore: avoid_print
    print('CAPTURE $file');
  }

  bool shouldCapture(String state) =>
      selectedStates.isEmpty || selectedStates.contains(state);

  /// 电视首页栏目编辑。上移、下移后恢复原顺序，避免写进后续状态。
  Future<void> captureTvSectionMove() async {
    if (!shouldCapture('tv-home-section-move')) return;
    await tap(const ValueKey('tv-nav-0'));
    final homeScroll = find.descendant(
      of: find.byKey(const PageStorageKey('tv-home')),
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is Scrollable && widget.axisDirection == AxisDirection.down,
      ),
    );
    expect(homeScroll, findsOneWidget);
    final edit = find.byKey(const Key('tv-home-display'));
    final position = tester.state<ScrollableState>(homeScroll).position;
    for (var i = 0; i < 8 && edit.evaluate().isEmpty; i++) {
      position.jumpTo(position.maxScrollExtent);
      await tester.pump();
    }
    expect(edit, findsOneWidget);
    await tester.tap(edit);
    await advance(400);
    expect(find.byKey(TvSectionEditor.editorKey), findsOneWidget);
    final banner = TvSectionEditor.tileKey(PhoneHomeSectionId.banner);
    final resume = TvSectionEditor.tileKey(PhoneHomeSectionId.resume);
    var moved = false;
    try {
      await tap(TvSectionEditor.moveDownKey(PhoneHomeSectionId.banner));
      moved = true;
      expect(
        tester.getTopLeft(find.byKey(resume)).dy,
        lessThan(tester.getTopLeft(find.byKey(banner)).dy),
      );
      await save('tv-home-section-move');
    } finally {
      try {
        if (moved &&
            find
                .byKey(TvSectionEditor.moveUpKey(PhoneHomeSectionId.banner))
                .evaluate()
                .isNotEmpty) {
          await tap(TvSectionEditor.moveUpKey(PhoneHomeSectionId.banner));
          expect(
            tester.getTopLeft(find.byKey(banner)).dy,
            lessThan(tester.getTopLeft(find.byKey(resume)).dy),
          );
        }
      } finally {
        if (find.byKey(TvSectionEditor.editorKey).evaluate().isNotEmpty) {
          await tap(TvSectionEditor.closeKey);
        }
      }
    }
    expect(find.byKey(TvSectionEditor.editorKey), findsNothing);
  }

  /// 登录后的设置栏外观三态，与连接页共用同一控件。
  Future<void> captureTvAppearance(
    RillightApp app,
    MemoryPlaybackSessionSnapshotStore snapshots,
  ) async {
    if (!wants('settings') || !shouldCapture('tv-appearance-signed-in')) {
      return;
    }
    // 播放会留下会话快照。回到首页时电视壳用独立网络补报停止；
    // 捕获环境没有这条连接，恢复失败会换成重试页，设置里的外观三态就不在了。
    await tester.runAsync(snapshots.delete);
    app.router.go('/');
    for (
      var i = 0;
      i < 25 && find.byType(TvAppearancePicker).evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 50));
      if (find.text('重试').evaluate().isNotEmpty) {
        await tester.runAsync(snapshots.delete);
        await tester.tap(find.text('重试'));
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
    }
    await advance(300);
    await tap(const ValueKey('tv-nav-3'));
    expect(find.byType(TvAppearancePicker), findsOneWidget);
    for (final name in ['system', 'light', 'dark']) {
      expect(find.byKey(Key('tv-appearance-$name')), findsOneWidget);
    }
    await save('tv-appearance-signed-in');
  }

  /// 手机辅助页来自电视本机 HTML；确认页只显示服务器和账号。
  ///
  /// [probeAuth] 是成功的独立会话:登录成功会触发路由跳转并销毁连接页持有
  /// 的辅助实例,成功页送达不能用页面内流程,也不能改动应用会话。
  Future<void> captureTvLan(
    AuthController auth,
    String serverUrl,
    AuthController probeAuth,
  ) async {
    const ids = [
      'tv-lan-qr',
      'tv-lan-phone',
      'tv-lan-phone-pending',
      'tv-lan-confirm',
      'tv-lan-phone-failed',
      'tv-lan-phone-success',
    ];
    if (!ids.any(shouldCapture)) return;
    expect(auth.isLoggedIn, isFalse);
    expect(auth.session, isNull);
    expect(find.byType(TvConnectPage), findsOneWidget);
    const secret = 'capture-lan-secret';
    const unreachable = 'http://192.0.2.10:8096';
    const account = 'lan-capture';

    Future<String> submit(
      Uri manual,
      String server,
      String password, {
      String user = account,
    }) async {
      final body =
          'address=${Uri.encodeQueryComponent(server)}'
          '&username=${Uri.encodeQueryComponent(user)}'
          '&password=${Uri.encodeQueryComponent(password)}';
      final posted = await tester.runAsync(
        () => _lanRequest(manual.replace(path: '/submit'), body: body),
      );
      expect(posted, isNotNull);
      expect(posted!.contains(secret), isFalse);
      expect(posted.contains('correct-horse'), isFalse);
      return posted;
    }

    /// 轮询最终状态页:确认后入口只留 phoneGrace 供手机取页。
    Future<String> finalPage(Uri manual, String heading) async {
      for (var i = 0; i < 20; i++) {
        final page = await tester.runAsync(
          () => _lanRequest(manual.replace(path: '/status')),
        );
        if (page != null && page.contains(heading)) {
          expect(page.contains(secret), isFalse);
          expect(page.contains('correct-horse'), isFalse);
          return page;
        }
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)),
        );
      }
      fail('phone final page "$heading" was not delivered');
    }

    Uri? manual;
    try {
      await tap(const Key('tv-lan-assist'));
      await _waitForKey(const Key('tv-lan-address'));
      manual = Uri.parse(
        tester
            .widget<SelectableText>(find.byKey(const Key('tv-lan-address')))
            .data!,
      );
      final fingerprint = tester
          .widget<SelectableText>(find.byKey(const Key('tv-lan-fingerprint')))
          .data!;
      expect(manual.queryParameters.keys.toSet(), {'id', 'fp'});
      expect(manual.queryParameters['fp'], fingerprint);
      expect(manual.toString().contains(secret), isFalse);

      if (shouldCapture('tv-lan-qr')) {
        await Scrollable.ensureVisible(
          tester.element(find.byKey(const Key('tv-lan-qr'))),
          alignment: .3,
        );
        await advance(150);
        await save('tv-lan-qr');
      }

      final firstOffer = manual;
      final html = await tester.runAsync(() => _lanRequest(firstOffer));
      expect(html, isNotNull);
      expect(html!.contains(secret), isFalse);
      final page = _lanPhonePage(html, fingerprint);
      if (shouldCapture('tv-lan-phone')) {
        await _showPhone(_LanPhonePreview(page), 'tv-lan-phone');
      }

      final posted = await submit(manual, unreachable, secret);
      if (shouldCapture('tv-lan-phone-pending')) {
        await _showPhone(
          _LanStatePreview(_lanStatePage(posted)),
          'tv-lan-phone-pending',
        );
      }

      await _waitForKey(const Key('tv-lan-server'));
      expect(
        tester.widget<Text>(find.byKey(const Key('tv-lan-server'))).data,
        unreachable,
      );
      expect(
        tester.widget<Text>(find.byKey(const Key('tv-lan-account'))).data,
        account,
      );
      final passwordLabel = find.descendant(
        of: find.byKey(const Key('tv-connect-password')),
        matching: find.byType(Text),
      );
      expect(passwordLabel, findsOneWidget);
      final passwordText = tester.widget<Text>(passwordLabel).data ?? '';
      expect(passwordText.contains('•'), isFalse);
      expect(passwordText.contains(secret), isFalse);
      expect(find.textContaining(secret), findsNothing);
      if (shouldCapture('tv-lan-confirm')) {
        await Scrollable.ensureVisible(
          tester.element(find.byKey(const Key('tv-lan-server'))),
          alignment: .2,
        );
        await advance(150);
        await save('tv-lan-confirm');
      }

      if (shouldCapture('tv-lan-phone-failed')) {
        // 不可达地址确认后失败,手机在入口关闭前取到失败页。
        await Scrollable.ensureVisible(
          tester.element(find.byKey(const Key('tv-lan-confirm'))),
          alignment: .5,
        );
        await advance(100);
        await tap(const Key('tv-lan-confirm'));
        final failed = await finalPage(manual, '失败');
        await _showPhone(
          _LanStatePreview(_lanStatePage(failed)),
          'tv-lan-phone-failed',
        );
      } else {
        await _closeLan(manual);
      }

      if (shouldCapture('tv-lan-phone-success')) {
        // 独立驱动一次性配对:成功确认落在探针会话上,应用仍保持未登录,
        // 不触发路由跳转,辅助实例也不受页面生命周期影响。
        final lan = TvLanAssist();
        try {
          await tester.runAsync(() => lan.open());
          final offer = lan.offer!;
          final direct = Uri.parse(offer.manualUrl);
          final body =
              'address=${Uri.encodeQueryComponent(serverUrl)}'
              '&username=${Uri.encodeQueryComponent('alice')}'
              '&password=${Uri.encodeQueryComponent('correct-horse')}';
          final posted = await tester.runAsync(
            () => _lanRequest(direct.replace(path: '/submit'), body: body),
          );
          expect(posted, isNotNull);
          expect(posted!.contains('correct-horse'), isFalse);
          // confirm 会等到最终页送达并关闭入口才返回;手机取页必须与确认
          // 在同一个真实异步区内并发:首个状态请求会被挂起,随确认先拿到
          // 「连接中」,宽限期内再取到「成功」。
          final success = await tester.runAsync(() async {
            final confirmFuture = lan.confirm(probeAuth);
            String? page;
            for (var i = 0; i < 20 && page == null; i++) {
              try {
                final candidate = await _lanRequest(
                  direct.replace(path: '/status'),
                );
                if (candidate.contains('成功')) {
                  page = candidate;
                }
              } on Object {
                // 入口关闭前的重试窗口。
              }
              if (page == null) {
                await Future<void>.delayed(const Duration(milliseconds: 100));
              }
            }
            await confirmFuture;
            return page;
          });
          expect(
            success,
            isNotNull,
            reason: 'phone success page not delivered',
          );
          expect(success!.contains('correct-horse'), isFalse);
          await _showPhone(
            _LanStatePreview(_lanStatePage(success)),
            'tv-lan-phone-success',
          );
        } finally {
          await tester.runAsync(() => lan.close());
        }
      }
    } finally {
      final opened = manual;
      if (opened != null) {
        await _closeLan(opened);
      }
    }
  }

  /// 把单页手机预览盖在捕获页面上,保存后关闭。
  Future<void> _showPhone(Widget preview, String id) async {
    final context = tester.element(find.byType(TvConnectPage));
    unawaited(
      showGeneralDialog<void>(
        context: context,
        barrierDismissible: false,
        barrierColor: const Color(0xFF101726),
        transitionDuration: Duration.zero,
        pageBuilder: (_, _, _) => preview,
      ),
    );
    try {
      await advance(100);
      expect(find.byKey(_lanPreviewKey), findsOneWidget);
      expect(find.text('capture-lan-secret'), findsNothing);
      expect(find.text('correct-horse'), findsNothing);
      await save(id);
    } finally {
      final shown = find.byKey(_lanPreviewKey);
      if (shown.evaluate().isNotEmpty) {
        Navigator.of(tester.element(shown)).pop();
        await advance(100);
      }
    }
  }

  Future<void> _waitForKey(Key key) async {
    for (var i = 0; i < 40; i++) {
      await tester.pump();
      if (find.byKey(key).evaluate().isNotEmpty) return;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 250)),
      );
    }
    expect(find.byKey(key), findsOneWidget);
  }

  Future<void> _closeLan(Uri manual) async {
    if (find.byKey(const Key('tv-lan-reject')).evaluate().isNotEmpty) {
      await tap(const Key('tv-lan-reject'));
      try {
        await tester.runAsync(
          () => _lanRequest(manual.replace(path: '/status')),
        );
      } on Object {
        // 入口已经关闭时不再挡住后续清理。
      }
      await advance(2200);
      return;
    }
    if (find.byKey(const Key('tv-lan-incomplete')).evaluate().isNotEmpty) {
      await tap(const Key('tv-lan-incomplete'));
    }
  }
}

class _LanHttpOverrides extends HttpOverrides {}

Future<String> _lanRequest(Uri uri, {String? body}) {
  return HttpOverrides.runWithHttpOverrides(
    () => _lanRequestDirect(uri, body: body),
    _LanHttpOverrides(),
  );
}

Future<String> _lanRequestDirect(Uri uri, {String? body}) async {
  final client = HttpClient();
  try {
    client.badCertificateCallback = (_, _, _) => true;
    final request = await client
        .openUrl(body == null ? 'GET' : 'POST', uri)
        .timeout(const Duration(seconds: 5));
    if (body != null) {
      request.headers.contentType = ContentType(
        'application',
        'x-www-form-urlencoded',
        charset: 'utf-8',
      );
      request.write(body);
    }
    final response = await request.close().timeout(const Duration(seconds: 5));
    final text = await utf8.decoder.bind(response).join();
    if (response.statusCode != 200) {
      throw StateError('LAN assist HTTP ${response.statusCode}');
    }
    return text;
  } finally {
    client.close(force: true);
  }
}

class _LanPhonePage {
  const _LanPhonePage({
    required this.title,
    required this.intro,
    required this.fingerprint,
    required this.labels,
    required this.submit,
  });

  final String title;
  final String intro;
  final String fingerprint;
  final List<String> labels;
  final String submit;
}

_LanPhonePage _lanPhonePage(String html, String fingerprint) {
  expect(html.contains('<script'), isFalse);
  String tag(String name) {
    final match = RegExp(
      '<$name\\b[^>]*>(.*?)</$name>',
      dotAll: true,
    ).firstMatch(html);
    expect(match, isNotNull, reason: 'phone page missing <$name>');
    return _lanText(match!.group(1)!);
  }

  final labels = <String>[];
  for (final match in RegExp(
    r'<label>([^<]*)<input\b([^>]*)>',
    dotAll: true,
  ).allMatches(html)) {
    expect(match.group(2)!.contains('value='), isFalse);
    labels.add(_lanText(match.group(1)!));
  }
  final page = _LanPhonePage(
    title: tag('h1'),
    intro: tag('p'),
    fingerprint: tag('code'),
    labels: labels,
    submit: tag('button'),
  );
  expect(page.title, '灯川 Rillight');
  expect(page.intro, '证书指纹');
  expect(page.fingerprint, fingerprint);
  expect(page.labels, ['服务器地址', '用户名', '密码']);
  expect(page.submit, '提交到电视');
  return page;
}

String _lanText(String raw) {
  return raw
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .trim();
}

/// 把电视回给手机的 HTML 可见内容画进捕获边界,不是产品页面。
const _lanPreviewKey = Key('tv-lan-phone-preview');

class _LanPhonePreview extends StatelessWidget {
  const _LanPhonePreview(this.page);

  final _LanPhonePage page;

  @override
  Widget build(BuildContext context) {
    return Material(
      key: _lanPreviewKey,
      color: const Color(0xFF101726),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 32),
            children: [
              _LanCard(
                children: [
                  const _LanBrand(),
                  const SizedBox(height: 6),
                  const Text(
                    '在手机上为电视登录 Emby 服务器,提交后回到电视确认。',
                    style: TextStyle(
                      color: Color(0xFF9AA4B8),
                      fontSize: 14,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    page.intro,
                    style: const TextStyle(
                      color: Color(0xFF9AA4B8),
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: const Color(0x59000000),
                      border: Border.all(color: const Color(0x14FFFFFF)),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    child: Text(
                      page.fingerprint,
                      style: const TextStyle(
                        color: Color(0xFF8EA2C9),
                        fontSize: 11,
                        height: 1.6,
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  for (final label in page.labels) ...[
                    Text(
                      label,
                      style: const TextStyle(
                        color: Color(0xFFC6CDDC),
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      height: 50,
                      decoration: BoxDecoration(
                        color: const Color(0x52000000),
                        border: Border.all(color: const Color(0x1FFFFFFF)),
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  Container(
                    height: 50,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF8BA4FF), Color(0xFFB18CFF)],
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Center(
                      child: Text(
                        page.submit,
                        style: const TextStyle(
                          color: Color(0xFF0B1020),
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    '一次性配对,过期自动失效\n本页不含脚本与外部资源',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Color(0xFF7D8698),
                      fontSize: 12,
                      height: 1.6,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LanBrand extends StatelessWidget {
  const _LanBrand();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: [
        _LanLogo(),
        SizedBox(width: 10),
        Text(
          '灯川 Rillight',
          style: TextStyle(
            color: Color(0xFFE8ECF4),
            fontSize: 23,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }
}

class _LanLogo extends StatelessWidget {
  const _LanLogo();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF6D8DFF), Color(0xFF9A6DFF)],
        ),
        borderRadius: BorderRadius.circular(10),
      ),
      child: const Center(
        child: Text(
          '灯',
          style: TextStyle(
            color: Colors.white,
            fontSize: 17,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

class _LanCard extends StatelessWidget {
  const _LanCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0x0DFFFFFF),
        border: Border.all(color: const Color(0x17FFFFFF)),
        borderRadius: BorderRadius.circular(20),
      ),
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
    );
  }
}

class _LanStatePage {
  const _LanStatePage({
    required this.heading,
    required this.detail,
    required this.tone,
    required this.spinning,
  });

  final String heading;
  final String detail;

  /// ok / wait / err。
  final String tone;
  final bool spinning;
}

_LanStatePage _lanStatePage(String html) {
  expect(html.contains('<script'), isFalse);
  final headings = RegExp(
    '<h1\\b[^>]*>(.*?)</h1>',
    dotAll: true,
  ).allMatches(html).toList();
  // 第一个是品牌字标,状态标题在其后。
  expect(headings.length, greaterThanOrEqualTo(2));
  final heading = _lanText(headings.last.group(1)!);
  final detailMatch = RegExp(
    '<p class="detail">(.*?)</p>',
    dotAll: true,
  ).firstMatch(html);
  expect(detailMatch, isNotNull, reason: 'state page missing detail');
  final tone = switch (heading) {
    '成功' => 'ok',
    '待确认' || '连接中' => 'wait',
    _ => 'err',
  };
  return _LanStatePage(
    heading: heading,
    detail: _lanText(detailMatch!.group(1)!),
    tone: tone,
    spinning: html.contains('class="spin"'),
  );
}

/// 手机状态页(待确认/连接中/成功/失败)的捕获近似。
class _LanStatePreview extends StatelessWidget {
  const _LanStatePreview(this.page);

  final _LanStatePage page;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = switch (page.tone) {
      'ok' => (const Color(0x2954D391), const Color(0xFF54D391)),
      'wait' => (const Color(0x298BA4FF), const Color(0xFF8BA4FF)),
      _ => (const Color(0x29FF6B6B), const Color(0xFFFF6B6B)),
    };
    final icon = switch (page.tone) {
      'ok' => Icon(Icons.check_rounded, color: fg, size: 34),
      'wait' => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 3; i++) ...[
            Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(color: fg, shape: BoxShape.circle),
            ),
            if (i < 2) const SizedBox(width: 8),
          ],
        ],
      ),
      _ => Icon(Icons.close_rounded, color: fg, size: 34),
    };
    return Material(
      key: _lanPreviewKey,
      color: const Color(0xFF101726),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 32),
            child: _LanCard(
              children: [
                const _LanBrand(),
                const SizedBox(height: 28),
                Center(
                  child: page.spinning
                      ? Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: fg, width: 3),
                          ),
                        )
                      : Container(
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(
                            color: bg,
                            shape: BoxShape.circle,
                          ),
                          child: Center(child: icon),
                        ),
                ),
                const SizedBox(height: 18),
                Center(
                  child: Text(
                    page.heading,
                    style: const TextStyle(
                      color: Color(0xFFE8ECF4),
                      fontSize: 23,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Center(
                  child: Text(
                    page.detail,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xFF9AA4B8),
                      fontSize: 15,
                      height: 1.6,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
