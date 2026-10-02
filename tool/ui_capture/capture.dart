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
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/catalog_scope.dart';
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
        final adapter = CaptureAdapter([server]);
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
          credentials: MemoryCredentialStore(),
          servers: MemoryServerListStore(),
        );
        await tester.runAsync(() async {
          await auth.connect(
            address: server.baseUrl.toString(),
            username: 'alice',
            password: 'correct-horse',
          );
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
        final app = RillightApp(
          auth: auth,
          environment: config.$2,
          appearance: appearance,
          playerBindings: PlayerBindings(
            createBackend: () => backend,
            settingsStore: store,
            snapshotStore: MemoryPlaybackSessionSnapshotStore(),
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
            final card = find.byKey(CatalogKeys.item('movie-up')).first;
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
          final loading = Completer<void>();
          adapter.catalogGate = loading;
          await capture.activate(find.byKey(PhoneHero.openKey));
          expect(
            find.byKey(const Key('phone-detail-pending-action')),
            findsOneWidget,
          );
          final pendingAction = tester.getRect(
            find.byKey(const Key('mobile-detail-play')),
          );
          await capture.save('detail-from-home-loading');
          adapter.catalogGate = null;
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
        await capture.pages(app, auth, server);
        if (config.$1 == 'phone' && capture.wants('home')) {
          app.router.go('/');
          await capture.advance(400);
          await tester.tap(find.byType(NavigationDestination).first);
          await capture.advance(400);
          final catalog = CatalogScope.of(
            tester.element(find.byType(PhoneHero)),
          );
          final originals = [
            for (final item in server.items)
              (
                item,
                item.played,
                item.nextUp,
                item.playbackPositionTicks,
                item.playedPercentage,
              ),
          ];
          for (final item in server.items) {
            if (item.type == 'Movie') item.played = true;
            if (item.type == 'Movie' || item.type == 'Episode') {
              item.nextUp = false;
              item.playbackPositionTicks = 0;
              item.playedPercentage = 0;
            }
          }
          await tester.runAsync(catalog.reloadHomeRows);
          await capture.advance(700);
          await tester.ensureVisible(find.byKey(PhoneHero.bannerKey));
          await capture.advance(300);
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
          for (final original in originals) {
            original.$1.played = original.$2;
            original.$1.nextUp = original.$3;
            original.$1.playbackPositionTicks = original.$4;
            original.$1.playedPercentage = original.$5;
          }
          await tester.runAsync(catalog.reloadHomeRows);
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
        if (capture.wants('login')) await capture.loginPages(app, auth);
        await tester.pumpWidget(const SizedBox.shrink());
        await capture.advance(500);
        app.router.dispose();
        auth.dispose();
        appearance.dispose();
      }, tags: ['integration']);
    }
  }
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

  Future<void> tap(Key key) async {
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
                state.startsWith('detail-gallery')
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
}
