import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/appearance_style.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/app/updates/update_download.dart';
import 'package:rillight/app/updates/update_scope.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/media_server/device.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/player_window_host.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/video_backend.dart';

import '../emby/fake_emby_server.dart';
import '../helpers/image_cache_fixture.dart';
import 'update_ui_fixture.dart';

class _Host extends PlayerWindowHost {
  bool opening = false;
  @override
  PlayerOpenRequest? current;
  @override
  bool get playbackOccupied => opening || current != null;
  @override
  bool get embedsPlayerInCaller => false;
  void begin() {
    opening = true;
    notifyListeners();
  }

  @override
  Future<void> open(PlayerOpenRequest request) async {
    opening = false;
    current = request;
    notifyListeners();
  }

  @override
  Future<void> close() async {
    opening = false;
    current = null;
    notifyListeners();
  }
}

void main() {
  setUp(isolateImageCache);
  testWidgets(
    'app defaults stay offline without creating an update controller',
    (tester) async {
      final app = RillightApp(
        appearance: AppearanceController(store: MemoryPlayerSettingsStore()),
      );
      await tester.pumpWidget(app);
      await tester.pumpAndSettle();
      expect(
        tester.widget<UpdateScope>(find.byType(UpdateScope)).notifier,
        isNull,
      );
      expect(find.byKey(const Key('app-update-reminder')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      app.router.dispose();
      app.auth.dispose();
      app.appearance.dispose();
      app.windowHost.dispose();
    },
    tags: ['integration'],
  );

  for (final environment in [
    PresentationEnvironment.desktop,
    PresentationEnvironment.phone,
    PresentationEnvironment.tv,
  ]) {
    testWidgets(
      '${environment.presentation.name} actual settings keeps shared download through navigation',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = environment.isTv
            ? const Size(960, 540)
            : environment.isDesktop
            ? const Size(1024, 768)
            : const Size(360, 800);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final server = FakeEmbyServer();
        final auth = AuthController.memory(
          client: EmbyClient(
            device: const ClientDeviceInfo(
              clientName: 'test',
              deviceName: 'updates',
              deviceId: 'updates',
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
        final fixture = UpdateUiFixture();
        final app = RillightApp(
          auth: auth,
          environment: environment,
          updateController: fixture.controller,
          appearance: AppearanceController(store: MemoryPlayerSettingsStore()),
          playerBindings: PlayerBindings(
            createBackend: FakeVideoBackend.new,
            settingsStore: MemoryPlayerSettingsStore(),
            snapshotStore: MemoryPlaybackSessionSnapshotStore(),
          ),
        );
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          app.router.dispose();
          auth.dispose();
          app.appearance.dispose();
          app.windowHost.dispose();
          fixture.dispose();
        });
        await tester.pumpWidget(app);
        await tester.pumpAndSettle();
        Future<void> settings() async {
          if (environment.isTv) {
            await tester.tap(find.byKey(const ValueKey('tv-nav-3')));
            await tester.pumpAndSettle();
          } else {
            app.router.go(environment.isDesktop ? '/settings' : '/mine');
            await tester.pumpAndSettle();
            if (environment.isDesktop) {
              final section = find.byKey(const ValueKey('settings-section-关于'));
              await tester.ensureVisible(section);
              await tester.tap(section);
              await tester.pumpAndSettle();
            }
          }
          await tester.ensureVisible(
            find.byKey(const Key('app-update-check-button')),
          );
          await tester.pumpAndSettle();
        }

        await settings();
        if (environment.isTv) {
          final detector = tester.widget<FocusableActionDetector>(
            find
                .descendant(
                  of: find.byKey(const Key('app-update-check-button')),
                  matching: find.byType(FocusableActionDetector),
                )
                .first,
          );
          Focus.of(tester.element(find.byWidget(detector.child)))
              .requestFocus();
          await tester.pumpAndSettle();
          await tester.sendKeyEvent(LogicalKeyboardKey.select);
        } else {
          await tester.tap(find.byKey(const Key('app-update-check-button')));
        }
        await tester.pumpAndSettle();
        if (environment.isTv) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
          await tester.pumpAndSettle();
          expect(
            find.byKey(const Key('app-update-download')).hitTestable(),
            findsOneWidget,
          );
          await tester.sendKeyEvent(LogicalKeyboardKey.select);
        } else {
          await tester.ensureVisible(
            find.byKey(const Key('app-update-download')),
          );
          await tester.tap(find.byKey(const Key('app-update-download')));
        }
        fixture.downloader.progress();
        await tester.pumpAndSettle();
        if (environment.isTv) {
          await tester.ensureVisible(find.byKey(const ValueKey('tv-nav-0')));
          await tester.tap(find.byKey(const ValueKey('tv-nav-0')));
        } else {
          app.router.go('/');
        }
        await tester.pumpAndSettle();
        await settings();
        await tester.ensureVisible(
          find.byKey(const Key('app-update-download-status')),
        );
        expect(find.textContaining('42%'), findsOneWidget);
        expect(fixture.downloader.calls, 1);
        fixture.downloader.fail(UpdateDownloadFailure.checksum);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('app-update-install')), findsNothing);
        expect(find.textContaining('复制'), findsNothing);
      },
      tags: ['integration'],
    );
  }

  testWidgets(
    'startup check once; desktop opening, paused playback and background defer reminder',
    (tester) async {
      final fixture = UpdateUiFixture();
      fixture.service.gate = Completer<void>();
      final host = _Host();
      final router = GoRouter(
        routes: [
          GoRoute(path: '/', builder: (_, _) => const SizedBox()),
          GoRoute(path: '/other', builder: (_, _) => const SizedBox()),
        ],
      );
      final appearance = AppearanceController(
        store: MemoryPlayerSettingsStore(),
      );
      final app = RillightApp(
        router: router,
        appearance: appearance,
        updateController: fixture.controller,
        enableUpdates: true,
        playerBindings: PlayerBindings(windowHost: host),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      addTearDown(() async {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        router.dispose();
        app.auth.dispose();
        appearance.dispose();
        host.dispose();
        fixture.dispose();
      });
      await tester.pumpWidget(app);
      host.begin();
      fixture.service.gate!.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('app-update-reminder')), findsNothing);
      await host.open(
        const PlayerOpenRequest(itemId: 'synthetic', startPaused: true),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('app-update-reminder')), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await host.close();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('app-update-reminder')), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('app-update-reminder')), findsOneWidget);
      // A new playback start wins even after the reminder has been presented.
      host.begin();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('app-update-reminder')), findsNothing);
      await host.close();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('app-update-reminder')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('app-update-reminder')), findsNothing);
      router.go('/other');
      await appearance.setStyle(AppearanceStyle.light);
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(fixture.service.calls, 1);
      expect(find.byKey(const Key('app-update-reminder')), findsNothing);
    },
    tags: ['integration'],
  );

  for (final environment in [
    PresentationEnvironment.phone,
    PresentationEnvironment.tv,
  ]) {
    testWidgets(
      '${environment.presentation.name} play route and background/PiP defer reminder until exit',
      (tester) async {
        final fixture = UpdateUiFixture();
        fixture.service.gate = Completer<void>();
        final router = GoRouter(
          routes: [
            GoRoute(path: '/', builder: (_, _) => const SizedBox()),
            GoRoute(path: '/play/:id', builder: (_, _) => const SizedBox()),
          ],
        );
        final app = RillightApp(
          router: router,
          environment: environment,
          appearance: AppearanceController(store: MemoryPlayerSettingsStore()),
          updateController: fixture.controller,
          enableUpdates: true,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        addTearDown(() async {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
          await tester.pumpWidget(const SizedBox.shrink());
          router.dispose();
          app.auth.dispose();
          app.appearance.dispose();
          app.windowHost.dispose();
          fixture.dispose();
        });
        await tester.pumpWidget(app);
        router.go('/play/synthetic');
        fixture.service.gate!.complete();
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('app-update-reminder')), findsNothing);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        router.go('/');
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('app-update-reminder')), findsNothing);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('app-update-reminder')), findsOneWidget);
        await tester.tap(find.byKey(const Key('app-update-reminder-close')));
        await tester.pumpAndSettle();
        expect(fixture.service.calls, 1);
      },
      tags: ['integration'],
    );
  }
}
