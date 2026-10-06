import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/appearance_style.dart';
import 'package:rillight/app/mobile_shell.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/app/tv_appearance_picker.dart';
import 'package:rillight/app/tv_shell.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/auth/android_connect_page.dart';
import 'package:rillight/auth/tv_connect_page.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/home/tv_home_page.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/video_backend.dart';
import 'package:rillight/library/aggregation_page.dart';

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
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      // The first pane's post-frame focus callback is still pending here.
      focusNav(2);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();

      expect(find.byType(AggregationPage), findsOneWidget);
      expect(
        tester.widget<AggregationPage>(find.byType(AggregationPage)).search,
        isTrue,
      );
      expect(
        tester
            .widget<TvAction>(find.byKey(const ValueKey('tv-nav-2')))
            .selected,
        isTrue,
      );
      expect(
        FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<AggregationPage>(),
        isNotNull,
      );

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(TvHomePage), findsOneWidget);
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

  testWidgets('up from pane content returns focus to the top nav', (
    tester,
  ) async {
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
          deviceId: 'tv-nav-up-return',
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

    FocusNode navFocus(int index) => tester
        .widget<FocusableActionDetector>(
          find.descendant(
            of: find.byKey(ValueKey('tv-nav-$index')),
            matching: find.byType(FocusableActionDetector),
          ),
        )
        .focusNode!;

    // 下键进入首页面板,焦点落在 hero 区;连按上键最终回到顶部导航。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(navFocus(0).hasFocus, isFalse);
    for (var i = 0; i < 40 && !navFocus(0).hasFocus; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
    }
    expect(navFocus(0).hasFocus, isTrue);
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);

  testWidgets('a phone install opens phone pages', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final server = FakeEmbyServer();
    final auth = AuthController.memory(
      client: EmbyClient(
        device: const EmbyDeviceInfo(
          clientName: 'test',
          deviceName: 'phone',
          deviceId: 'phone-shell-navigation',
          version: '1',
        ),
        dio: dioForFakeEmby(FakeEmbyAdapter([server])),
      ),
    );
    final app = RillightApp(
      auth: auth,
      environment: PresentationEnvironment.phone,
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
    expect(find.byType(AndroidConnectPage), findsOneWidget);
    expect(find.byType(TvConnectPage), findsNothing);
    expect(find.byType(TvShell), findsNothing);

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
    expect(find.byType(MobileShell), findsOneWidget);
    expect(find.byType(TvShell), findsNothing);
    expect(find.byType(TvConnectPage), findsNothing);
  }, tags: ['integration']);

  testWidgets('logged-in TV settings can change appearance', (tester) async {
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
          deviceId: 'tv-settings-appearance',
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
    final appearance = AppearanceController(store: MemoryPlayerSettingsStore());
    final app = RillightApp(
      auth: auth,
      appearance: appearance,
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

    await tester.tap(find.byKey(const ValueKey('tv-nav-3')));
    await tester.pumpAndSettle();
    expect(find.byType(TvAppearancePicker), findsOneWidget);
    expect(find.byKey(const Key('tv-appearance-system')), findsOneWidget);
    expect(find.byKey(const Key('tv-appearance-light')), findsOneWidget);
    expect(find.byKey(const Key('tv-appearance-dark')), findsOneWidget);

    await tester.tap(find.byKey(const Key('tv-appearance-light')));
    await tester.pumpAndSettle();
    expect(appearance.style, AppearanceStyle.light);
    expect(
      tester
          .widget<TvAction>(find.byKey(const Key('tv-appearance-light')))
          .selected,
      isTrue,
    );
  }, tags: ['integration']);

  testWidgets('TV search back returns home and settings opens private', (
    tester,
  ) async {
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
          deviceId: 'tv-search-private',
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

    await tester.tap(find.byKey(const ValueKey('tv-nav-2')));
    await tester.pumpAndSettle();
    final searchBack = find.descendant(
      of: find.byWidgetPredicate(
        (widget) => widget is AggregationPage && widget.search,
      ),
      matching: find.byType(BackButton),
    );
    expect(searchBack, findsOneWidget);
    await tester.tap(searchBack);
    await tester.pumpAndSettle();
    expect(find.byType(TvHomePage), findsOneWidget);
    expect(
      tester.widget<TvAction>(find.byKey(const ValueKey('tv-nav-0'))).selected,
      isTrue,
    );

    await tester.tap(find.byKey(const ValueKey('tv-nav-2')));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(TvHomePage), findsOneWidget);
    expect(app.router.state.uri.path, '/');

    await tester.tap(find.byKey(const ValueKey('tv-nav-3')));
    await tester.pumpAndSettle();
    final sessionList = find.descendant(
      of: find.byKey(const PageStorageKey('tv-session')),
      matching: find.byType(Scrollable),
    );
    for (final label in ['连接其他服务器', '修改密码', '退出登录']) {
      await tester.scrollUntilVisible(
        find.text(label),
        200,
        scrollable: sessionList,
      );
      expect(find.text(label), findsOneWidget);
    }
    await tester.scrollUntilVisible(
      find.byKey(const Key('tv-session-private')),
      -200,
      scrollable: sessionList,
    );
    expect(find.byKey(const Key('tv-session-private')), findsOneWidget);
    await tester.runAsync(() async {
      await auth.setPrivatePin('1234', '1234');
      await auth.regionAccess.unlock('1234');
    });
    await tester.ensureVisible(find.byKey(const Key('tv-session-private')));
    await tester.tap(find.byKey(const Key('tv-session-private')));
    await tester.pumpAndSettle();
    expect(app.router.state.uri.path, '/private');
    expect(tester.takeException(), isNull);
  }, tags: ['integration']);
}
