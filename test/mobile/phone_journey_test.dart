import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/app_shell.dart';
import 'package:rillight/app/mobile_shell.dart';
import 'package:rillight/app/phone_mine_page.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/app/tv_shell.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/library/item_detail_page.dart';
import 'package:rillight/library/library_page.dart';
import 'package:rillight/library/mobile_detail_page.dart';
import 'package:rillight/library/mobile_series_page.dart';
import 'package:rillight/library/tv_detail_page.dart';
import 'package:rillight/library/tv_library_page.dart';
import 'package:rillight/player/mobile_player_page.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_page.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/tv_player_page.dart';
import 'package:rillight/player/video_backend.dart';

import '../emby/fake_emby_server.dart';
import '../helpers/image_cache_fixture.dart';

void main() {
  setUp(isolateImageCache);

  Future<(RillightApp, FakeVideoBackend)> start(
    WidgetTester tester,
    FakeEmbyServer server, {
    required double width,
  }) async {
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final auth = AuthController.memory(
      client: EmbyClient(
        device: const EmbyDeviceInfo(
          clientName: 'test',
          deviceName: 'phone',
          deviceId: 'phone-journey',
          version: '1',
        ),
        dio: dioForFakeEmby(FakeEmbyAdapter([server])),
      ),
    );
    final backend = FakeVideoBackend(duration: const Duration(hours: 3));
    final app = RillightApp(
      auth: auth,
      environment: PresentationEnvironment.phone,
      playerBindings: PlayerBindings(
        createBackend: () => backend,
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
    return (app, backend);
  }

  Future<void> login(WidgetTester tester, FakeEmbyServer server) async {
    await tester.enterText(
      find.byKey(const Key('android-connect-address')),
      server.baseUrl.toString(),
    );
    await tester.enterText(
      find.byKey(const Key('android-connect-username')),
      'alice',
    );
    await tester.enterText(
      find.byKey(const Key('android-connect-password')),
      'correct-horse',
    );
    await tester.ensureVisible(find.byKey(const Key('android-connect-submit')));
    await tester.tap(find.byKey(const Key('android-connect-submit')));
    await tester.pumpAndSettle();
  }

  Future<void> tapKey(WidgetTester tester, Key key) async {
    final finder = find.byKey(key);
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> tapSheetText(WidgetTester tester, String text) async {
    final list = find.descendant(
      of: find.byType(BottomSheet),
      matching: find.byType(Scrollable),
    );
    final target = find.text(text);
    for (var i = 0; i < 12; i++) {
      if (target.evaluate().isNotEmpty) {
        final box = tester.renderObject<RenderBox>(target);
        final top = box.localToGlobal(Offset.zero).dy;
        final bottom = top + box.size.height;
        final screen = tester.view.physicalSize.height;
        if (top >= 0 && bottom <= screen) {
          await tester.tap(target);
          await tester.pumpAndSettle();
          return;
        }
      }
      await tester.drag(list, const Offset(0, -120));
      await tester.pumpAndSettle();
    }
    fail('could not tap $text in the tracks sheet');
  }

  void expectPhoneOnly(WidgetTester tester) {
    expect(find.byType(AppShell, skipOffstage: false), findsNothing);
    expect(find.byType(TvShell, skipOffstage: false), findsNothing);
    expect(find.byType(LibraryPage, skipOffstage: false), findsNothing);
    expect(find.byType(ItemDetailPage, skipOffstage: false), findsNothing);
    expect(find.byType(PlayerPage, skipOffstage: false), findsNothing);
    expect(find.byType(TvLibraryPage, skipOffstage: false), findsNothing);
    expect(find.byType(TvDetailPage, skipOffstage: false), findsNothing);
    expect(find.byType(TvPlayerPage, skipOffstage: false), findsNothing);
  }

  for (final width in [360.0, 412.0]) {
    testWidgets('$width connects, opens series and a movie, pauses landscape, '
        'changes subtitle, then shows updated progress', (tester) async {
      final server = FakeEmbyServer();
      final movie = server.items.firstWhere(
        (item) => item.id == 'movie-inception',
      );
      movie.mediaStreams = [
        ...movie.mediaStreams,
        const FakeMediaStream(
          index: 4,
          type: 'Subtitle',
          codec: 'subrip',
          language: 'eng',
          displayTitle: '英文字幕',
          isTextSubtitleStream: true,
        ),
      ];
      final (_, backend) = await start(tester, server, width: width);
      await login(tester, server);

      expect(find.byType(MobileShell), findsOneWidget);
      expect(find.text('已看 40%'), findsWidgets);
      expectPhoneOnly(tester);

      // 三 tab 之外,"我的"经顶栏头像入口进入 /mine,返回回到 shell。
      await tester.tap(find.byKey(const Key('mobile-shell-mine-entry')));
      await tester.pumpAndSettle();
      expect(find.byType(PhoneMinePage), findsOneWidget);
      // /mine 与 MobileShell 平级,进入后 shell 被顶离路由栈。
      expect(find.byType(MobileShell), findsNothing);
      expect(find.text('alice'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(PhoneMinePage), findsNothing);
      expect(find.byType(MobileShell), findsOneWidget);

      await tester.tap(find.text('片库').last);
      await tester.pumpAndSettle();
      await tapKey(tester, const Key('phone-library-block-view-tv'));
      expect(
        tester.widget<Text>(find.byKey(const Key('phone-library-title'))).data,
        '剧集',
      );
      await tester.ensureVisible(find.text('老友记'));
      await tester.tap(find.text('老友记'));
      await tester.pumpAndSettle();
      expect(find.byType(MobileSeriesPage), findsOneWidget);
      expect(find.byKey(const Key('phone-season-list')), findsOneWidget);
      expect(find.text('The Pilot'), findsWidgets);
      expectPhoneOnly(tester);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(MobileShell), findsOneWidget);

      await tapKey(tester, const Key('phone-library-block-view-movies'));
      expect(
        tester.widget<Text>(find.byKey(const Key('phone-library-title'))).data,
        '电影',
      );
      await tester.ensureVisible(find.text('Inception').first);
      await tester.tap(find.text('Inception').first);
      await tester.pumpAndSettle();
      expect(find.byType(MobileDetailPage), findsOneWidget);
      expect(find.byType(MobileSeriesPage), findsNothing);
      expect(find.text('继续播放'), findsOneWidget);
      expect(find.text('从头播放'), findsOneWidget);
      expectPhoneOnly(tester);

      await tester.tap(find.byKey(const Key('mobile-detail-play')));
      await tester.pumpAndSettle();
      expect(find.byType(MobilePlayerPage), findsOneWidget);
      final player = tester.state<MobilePlayerPageState>(
        find.byType(MobilePlayerPage),
      );
      expect(player.controller, isNotNull);
      expect(player.controller!.loading, isFalse);
      expect(
        player.controller!.error,
        isNull,
        reason: player.controller!.trackFailure,
      );
      expect(backend.isPlaying, isTrue);
      expect(backend.position, const Duration(minutes: 59));
      expect(player.controller!.subtitleStreamIndex, isNot(4));

      tester.view.physicalSize = Size(800, width);
      await tester.pumpAndSettle();
      expect(
        tester.view.physicalSize.width,
        greaterThan(tester.view.physicalSize.height),
      );
      expect(backend.isPlaying, isTrue);
      expect(backend.openCount, 1);
      expectPhoneOnly(tester);

      final toggle = find.byKey(const Key('mobile-player-toggle'));
      await tester.ensureVisible(toggle);
      await tester.pumpAndSettle();
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(backend.isPlaying, isFalse);
      expect(
        tester.view.physicalSize.width,
        greaterThan(tester.view.physicalSize.height),
      );

      final seek = find.byKey(const Key('mobile-player-seek'));
      await tester.ensureVisible(seek);
      await tester.pumpAndSettle();
      final slider = tester.widget<Slider>(seek);
      slider.onChangeEnd!(slider.max * .75);
      await tester.pumpAndSettle();
      expect(backend.position, greaterThan(const Duration(minutes: 70)));

      await tester.ensureVisible(find.byTooltip('音轨与字幕'));
      await tester.tap(find.byTooltip('音轨与字幕'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      await tapSheetText(tester, '英文字幕');
      expect(player.controller!.subtitleStreamIndex, 4);
      expect(player.controller!.trackFailure, isNull);
      expect(backend.subtitleIndex, 4);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byType(MobilePlayerPage), findsOneWidget);
      expectPhoneOnly(tester);

      tester.view.physicalSize = Size(width, 800);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byTooltip('关闭'));
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(find.byType(MobilePlayerPage), findsNothing);
      expect(find.byType(MobileDetailPage), findsOneWidget);
      expect(find.text('继续播放'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(MobileShell), findsOneWidget);
      await tester.tap(find.text('首页').last);
      await tester.pumpAndSettle();

      final updated = server.items.firstWhere(
        (item) => item.id == 'movie-inception',
      );
      expect(
        updated.playbackPositionTicks,
        greaterThan(movie.runTimeTicks! ~/ 2),
      );
      final percent = (updated.playedPercentage ?? 0).round();
      expect(percent, isNot(40));
      expect(find.text('已看 40%'), findsNothing);
      expect(find.text('已看 $percent%'), findsWidgets);
      expectPhoneOnly(tester);
      expect(tester.takeException(), isNull);
    }, tags: ['integration']);
  }
}
