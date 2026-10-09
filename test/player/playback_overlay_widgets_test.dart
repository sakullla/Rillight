import 'dart:typed_data';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/player/bif_preview.dart';
import 'package:rillight/player/next_episode_card.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/playback_settings_menu.dart';
import 'package:rillight/player/playback_models.dart';
import 'package:rillight/player/playback_resolver.dart';
import 'package:rillight/player/player_controller.dart';
import 'package:rillight/player/player_keys.dart';
import 'package:rillight/player/player_setting_choices.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/player_window.dart';
import 'package:rillight/player/seek_preview.dart';
import 'package:rillight/player/video_backend.dart';

void main() {
  late PlayerController controller;
  late MemoryPlayerSettingsStore store;
  setUp(() {
    store = MemoryPlayerSettingsStore();
    controller = PlayerController(
      client: EmbyClient(
        device: const EmbyDeviceInfo(
          clientName: 'test',
          deviceName: 'test',
          deviceId: 'overlay',
          version: '1',
        ),
      ),
      itemId: 'current',
      backend: FakeVideoBackend(),
      window: PlayerWindow(),
      settingsStore: store,
      snapshotStore: MemoryPlaybackSessionSnapshotStore(),
    );
    controller.loading = false;
  });
  tearDown(() => controller.dispose());

  Widget app(Widget child, {Brightness brightness = Brightness.dark}) =>
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.teal,
            brightness: brightness,
          ),
        ),
        home: Scaffold(body: Center(child: child)),
      );

  testWidgets(
    'long source menu reveals selection on opening, without undoing manual scroll',
    (tester) async {
      controller.mediaSources = [
        for (var i = 0; i < 30; i++)
          PlaybackMediaSource(id: '$i', name: 'Source $i'),
      ];
      controller.resolved = ResolvedPlayback(
        playMethod: PlayMethod.directPlay,
        streamUrl: Uri.parse('https://example.test/movie'),
        playSessionId: 'session',
        mediaSource: controller.mediaSources.last,
        itemId: 'current',
      );
      await tester.pumpWidget(
        app(PlaybackSettingsMenu(controller: controller)),
      );
      await tester.tap(find.byKey(PlayerKeys.more));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(PlayerKeys.mediaSource));
      await tester.pumpAndSettle();
      final selected = find.byWidgetPredicate(
        (w) => w is ListTile && w.selected,
      );
      final content = find.byKey(
        const ValueKey('player-settings-content-source'),
      );
      expect(
        tester.getRect(content).contains(tester.getCenter(selected)),
        isTrue,
      );
      final scroll = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.descendant(of: content, matching: find.byType(ListView)),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(scroll.position.pixels, greaterThan(0));
      scroll.position.jumpTo(0);
      await tester.pumpWidget(
        app(PlaybackSettingsMenu(controller: controller)),
      );
      await tester.pumpAndSettle();
      expect(scroll.position.pixels, 0);
      await tester.tap(find.byKey(PlayerKeys.speed));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(PlayerKeys.mediaSource));
      await tester.pumpAndSettle();
      expect(
        tester.getRect(content).contains(tester.getCenter(selected)),
        isTrue,
      );
    },
  );

  for (final count in [0, 1, 2]) {
    testWidgets('settings hide unavailable or single choices ($count)', (
      tester,
    ) async {
      final source = PlaybackMediaSource(
        id: 'one',
        supportsTranscoding: count > 0,
        bitrate: count == 1 ? 500 : null,
        mediaStreams: [
          for (var i = 0; i < count; i++)
            MediaStreamInfo(index: i, type: 'Audio', displayTitle: 'Audio $i'),
        ],
      );
      controller.resolved = ResolvedPlayback(
        playMethod: PlayMethod.directPlay,
        streamUrl: Uri.parse('https://example.test/movie'),
        playSessionId: 'session',
        mediaSource: source,
        itemId: 'current',
      );
      controller.mediaSources = [
        for (var i = 0; i < count; i++) PlaybackMediaSource(id: '$i'),
      ];
      await tester.pumpWidget(
        app(PlaybackSettingsMenu(controller: controller)),
      );
      await tester.tap(find.byKey(PlayerKeys.more));
      await tester.pumpAndSettle();
      final expected = count > 1 ? findsOneWidget : findsNothing;
      expect(find.byKey(PlayerKeys.audio), expected);
      expect(find.byKey(PlayerKeys.quality), expected);
      expect(find.byKey(PlayerKeys.speed), findsOneWidget);
      if (count > 1) {
        await tester.scrollUntilVisible(
          find.byKey(PlayerKeys.mediaSource),
          80,
          scrollable: find.descendant(
            of: find.byKey(const Key('player-settings-categories')),
            matching: find.byType(Scrollable),
          ),
        );
      }
      expect(find.byKey(PlayerKeys.mediaSource), expected);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('desktop playback menu changes the shared subtitle size', (
    tester,
  ) async {
    controller.subtitleStreamIndex = 1;
    controller.resolved = ResolvedPlayback(
      playMethod: PlayMethod.directPlay,
      streamUrl: Uri.parse('https://example.test/movie'),
      playSessionId: 'session',
      mediaSource: const PlaybackMediaSource(
        id: 'one',
        mediaStreams: [
          MediaStreamInfo(
            index: 1,
            type: 'Subtitle',
            isTextSubtitleStream: true,
            displayTitle: 'Chinese',
          ),
        ],
      ),
      itemId: 'current',
    );
    await tester.pumpWidget(app(PlaybackSettingsMenu(controller: controller)));
    await tester.tap(find.byKey(PlayerKeys.more));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('player-subtitle-size-section')),
      80,
      scrollable: find.descendant(
        of: find.byKey(const Key('player-settings-categories')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.tap(find.byKey(const Key('player-subtitle-size-section')));
    await tester.pumpAndSettle();
    expect(find.text('字幕大小'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('phone-subtitle-extraLarge')));
    await tester.pumpAndSettle();
    expect(controller.phoneSubtitleSettings.size, PhoneSubtitleSize.extraLarge);
    expect(
      (await store.read()).effectivePhoneSubtitles.size,
      PhoneSubtitleSize.extraLarge,
    );
    await tester.tap(find.byKey(const Key('phone-subtitle-original')));
    await tester.pumpAndSettle();
    expect(controller.phoneSubtitleSettings.originalAss, isTrue);
    expect((await store.read()).effectivePhoneSubtitles.originalAss, isTrue);
  });

  testWidgets('desktop playback quality uses the same option grid as speed', (
    tester,
  ) async {
    const source = PlaybackMediaSource(
      id: 'one',
      supportsTranscoding: true,
      bitrate: 30000000,
    );
    controller.resolved = ResolvedPlayback(
      playMethod: PlayMethod.directPlay,
      streamUrl: Uri.parse('https://example.test/movie'),
      playSessionId: 'session',
      mediaSource: source,
      itemId: 'current',
    );
    controller.mediaSources = const [source];
    await tester.pumpWidget(app(PlaybackSettingsMenu(controller: controller)));
    await tester.tap(find.byKey(PlayerKeys.more));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(PlayerKeys.quality),
      80,
      scrollable: find.descendant(
        of: find.byKey(const Key('player-settings-categories')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.tap(find.byKey(PlayerKeys.quality));
    await tester.pumpAndSettle();

    final selected = find.byKey(const ValueKey('player-quality-140000000'));
    final alternate = find.byKey(const ValueKey('player-quality-8000000'));
    expect(tester.widget<PlayerRateCell>(selected).selected, isTrue);
    expect(tester.widget<PlayerRateCell>(alternate).selected, isFalse);
    expect(find.text('最高可用'), findsNWidgets(2));
    expect(find.byType(ListTile), findsNothing);
    final panel = tester.getRect(
      find.byKey(const Key('player-settings-panel')),
    );
    final last = tester.getRect(
      find.byKey(const ValueKey('player-quality-1000000')),
    );
    expect(last.bottom, lessThanOrEqualTo(panel.bottom + .5));
    expect(last.top, greaterThanOrEqualTo(panel.top));

    await tester.tap(find.byKey(const Key('player-skip-settings-section')));
    await tester.pumpAndSettle();
    expect(find.text('自动保存，应用于所有视频'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'settings categories stay available and persist both skip choices',
    (tester) async {
      await tester.pumpWidget(
        app(PlaybackSettingsMenu(controller: controller)),
      );
      await tester.tap(find.byKey(PlayerKeys.more));
      await tester.pumpAndSettle();
      final selectedRate = tester.getSize(
        find.byKey(const ValueKey('player-rate-1.0')),
      );
      expect(selectedRate.height, inInclusiveRange(36, 44));
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('player-rate-1.0')),
          matching: find.byIcon(Icons.check_rounded),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('player-rate-1.5')),
          matching: find.byIcon(Icons.check_rounded),
        ),
        findsNothing,
      );
      final panelRect = tester.getRect(
        find.byKey(const Key('player-settings-panel')),
      );
      final lastRate = tester.getRect(
        find.byKey(const ValueKey('player-rate-3.0')),
      );
      expect(lastRate.bottom, lessThanOrEqualTo(panelRect.bottom + .5));
      expect(lastRate.top, greaterThanOrEqualTo(panelRect.top));
      expect(lastRate.height, selectedRate.height);
      expect(find.byType(ExpansionTile), findsNothing);
      expect(find.byKey(const Key('player-skip-intro-enabled')), findsNothing);
      final panelSize = tester.getSize(
        find.byKey(const Key('player-settings-panel')),
      );
      await tester.tap(find.byKey(const Key('player-skip-settings-section')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      await tester.tap(find.byKey(const Key('player-skip-intro-enabled')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('player-skip-outro-enabled')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('player-skip-intro-enabled')),
        findsOneWidget,
      );
      expect(controller.skipIntroEnabled, isFalse);
      expect(controller.skipOutroEnabled, isFalse);
      expect(find.byKey(PlayerKeys.speed), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const Key('player-settings-panel'))),
        panelSize,
      );
      await tester.tap(find.byKey(PlayerKeys.speed));
      await tester.pumpAndSettle();
      expect(find.byKey(PlayerKeys.speed), findsOneWidget);
      expect(find.byKey(const Key('player-skip-intro-enabled')), findsNothing);
      await tester.tap(find.byKey(const Key('player-skip-settings-section')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('player-skip-intro-enabled')),
        findsOneWidget,
      );
      expect((await store.read()).isSkipIntroEnabled, isFalse);
      expect((await store.read()).isSkipOutroEnabled, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('settings categories drag with the left mouse button', (
    tester,
  ) async {
    final source = PlaybackMediaSource(
      id: 'one',
      supportsTranscoding: true,
      mediaStreams: [
        for (var i = 0; i < 2; i++)
          MediaStreamInfo(index: i, type: 'Audio', displayTitle: 'Audio $i'),
      ],
    );
    controller.resolved = ResolvedPlayback(
      playMethod: PlayMethod.directPlay,
      streamUrl: Uri.parse('https://example.test/movie'),
      playSessionId: 'session',
      mediaSource: source,
      itemId: 'current',
    );
    controller.mediaSources = [
      for (var i = 0; i < 2; i++) PlaybackMediaSource(id: '$i'),
    ];
    await tester.pumpWidget(app(PlaybackSettingsMenu(controller: controller)));
    await tester.tap(find.byKey(PlayerKeys.more));
    await tester.pumpAndSettle();
    final categories = find.byWidgetPredicate(
      (widget) =>
          widget is ListView && widget.scrollDirection == Axis.horizontal,
    );
    ScrollPosition position() {
      return tester
          .state<ScrollableState>(
            find.descendant(of: categories, matching: find.byType(Scrollable)),
          )
          .position;
    }

    expect(position().maxScrollExtent, greaterThan(0));
    expect(position().pixels, 0);
    final speedBefore = tester.getTopLeft(find.byKey(PlayerKeys.speed));
    await tester.drag(
      find.byKey(const Key('player-skip-settings-section')),
      const Offset(-72, 0),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    expect(position().pixels, greaterThan(40));
    expect(
      tester.getTopLeft(find.byKey(PlayerKeys.speed)).dx,
      lessThan(speedBefore.dx - 40),
    );
    expect(find.byKey(const ValueKey('player-rate-1.0')), findsOneWidget);
    await tester.tap(find.byKey(const Key('player-skip-settings-section')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('player-skip-intro-enabled')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'removing settings during source loading releases its control pin',
    (tester) async {
      controller.isPlaying = true;
      await tester.pumpWidget(
        app(PlaybackSettingsMenu(controller: controller)),
      );
      await tester.tap(find.byKey(PlayerKeys.more));
      await tester.pumpAndSettle();
      expect(controller.controlsPinned, isTrue);
      await tester.pumpWidget(app(const SizedBox()));
      await tester.pump();
      expect(controller.controlsPinned, isFalse);
      await tester.pump(const Duration(seconds: 6));
      expect(controller.controlsVisible, isFalse);
    },
  );

  testWidgets('settings teardown preserves another panels control pin', (
    tester,
  ) async {
    final other = Object();
    controller.setControlsPinned(true, owner: other);
    await tester.pumpWidget(app(PlaybackSettingsMenu(controller: controller)));
    await tester.tap(find.byKey(PlayerKeys.more));
    await tester.pumpAndSettle();
    await tester.pumpWidget(app(const SizedBox()));
    await tester.pump();
    expect(controller.controlsPinned, isTrue);
    controller.setControlsPinned(false, owner: other);
    expect(controller.controlsPinned, isFalse);
  });

  for (final width in [280.0, 480.0]) {
    for (final brightness in Brightness.values) {
      testWidgets(
        'next episode fits $width in $brightness without tall actions',
        (tester) async {
          controller.nextEpisode = NextEpisodeOffer(
            item: const EmbyItem(
              id: 'next',
              name: '一个很长的下一集标题用于检查窄屏截断',
              type: 'Episode',
              indexNumber: 9,
            ),
          );
          await tester.pumpWidget(
            app(
              SizedBox(
                width: width,
                child: NextEpisodeCard(controller: controller),
              ),
              brightness: brightness,
            ),
          );
          await tester.pumpAndSettle();
          expect(
            tester.getSize(find.byKey(PlayerKeys.nextEpisode)).height,
            lessThanOrEqualTo(88),
          );
          expect(
            tester.getSize(find.byKey(PlayerKeys.nextEpisodePlay)).height,
            greaterThanOrEqualTo(40),
          );
          await tester.tap(find.byKey(PlayerKeys.nextEpisodeCancel));
          expect(controller.nextEpisode, isNull);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'hover shows time immediately and exit removes preview without an image placeholder',
    (tester) async {
      controller.duration = const Duration(minutes: 10);
      await tester.pumpWidget(
        app(
          SizedBox(
            width: 400,
            child: SeekPreview(
              controller: controller,
              child: Slider(value: 0, onChanged: (_) {}),
            ),
          ),
        ),
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(find.byType(Slider)));
      await tester.pump();
      expect(find.text('05:00'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      await mouse.moveTo(Offset.zero);
      await tester.pump();
      expect(find.byKey(const Key('player-seek-preview')), findsNothing);
      await mouse.removePointer();
    },
  );

  testWidgets(
    'drag preview uses proposed position instead of current playback',
    (tester) async {
      controller.duration = const Duration(minutes: 10);
      await tester.pumpWidget(
        app(
          SizedBox(
            width: 400,
            child: SeekPreview(
              controller: controller,
              dragValue: .75,
              child: Slider(value: .75, onChanged: (_) {}),
            ),
          ),
        ),
      );
      expect(find.text('07:30'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    },
  );

  test(
    'BIF validates bounds and selects preview at or before requested time',
    () {
      final bytes = Uint8List(94);
      bytes.setRange(0, 8, [0x89, 0x42, 0x49, 0x46, 13, 10, 26, 10]);
      final data = ByteData.sublistView(bytes);
      data.setUint32(12, 2, Endian.little);
      data.setUint32(16, 1000, Endian.little);
      data.setUint32(64, 0, Endian.little);
      data.setUint32(68, 88, Endian.little);
      data.setUint32(72, 10, Endian.little);
      data.setUint32(76, 91, Endian.little);
      data.setUint32(80, 0xffffffff, Endian.little);
      data.setUint32(84, 94, Endian.little);
      bytes.setRange(88, 94, [1, 2, 3, 4, 5, 6]);
      final bif = BifPreview.parse(bytes)!;
      expect(bif.imageAt(const Duration(seconds: 9)), [1, 2, 3]);
      expect(bif.imageAt(const Duration(seconds: 10)), [4, 5, 6]);
      expect(bif.imageAt(const Duration(days: 1)), [4, 5, 6]);
      data.setUint32(76, 100, Endian.little);
      expect(BifPreview.parse(bytes), isNull);
      expect(BifPreview.parse(Uint8List(4)), isNull);
    },
  );
}
