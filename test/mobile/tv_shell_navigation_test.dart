import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/app/tv_shell.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/video_backend.dart';
import 'package:rillight/search/tv_search_page.dart';

import '../emby/fake_emby_server.dart';
import '../helpers/image_cache_fixture.dart';

void main() {
  setUp(isolateImageCache);

  testWidgets(
    'TV rapid right keys keep the latest pane and Back restores home',
    (tester) async {
      tester.view.physicalSize = const Size(960, 540);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final server = FakeEmbyServer();
      final auth = AuthController.memory(
        client: EmbyClient(
          device: const EmbyDeviceInfo(
            clientName: 'test',
            deviceName: 'tv',
            deviceId: 'tv-rapid-navigation',
            version: '1',
          ),
          dio: dioForFakeEmby(FakeEmbyAdapter([server])),
        ),
      );
      await tester.runAsync(
        () => auth.connect(
          address: server.baseUrl.toString(),
          username: 'alice',
          password: 'correct-horse',
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
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        app.router.dispose();
        auth.dispose();
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
      void focusNav(int index) {
        navFocus(index).requestFocus();
        FocusManager.instance.applyFocusChangesIfNeeded();
      }

      focusNav(1);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      // The first pane's post-frame focus callback is still pending here.
      focusNav(2);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();

      expect(
        tester.widget<TvFrame>(find.byType(TvFrame)).title,
        endsWith('搜索'),
      );
      expect(
        tester
            .widget<TvAction>(find.byKey(const ValueKey('tv-nav-2')))
            .selected,
        isTrue,
      );
      expect(
        FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<TvSearchPage>(),
        isNotNull,
      );

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(
        tester.widget<TvFrame>(find.byType(TvFrame)).title,
        endsWith('首页'),
      );
      expect(
        tester
            .widget<TvAction>(find.byKey(const ValueKey('tv-nav-0')))
            .selected,
        isTrue,
      );
      expect(navFocus(0).hasFocus, isTrue);
      expect(tester.takeException(), isNull);
    },
    tags: ['integration'],
  );
}
