import 'package:rillight/auth/tv_connect_page.dart';
import 'package:rillight/app/tv_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/android_bootstrap.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/app_shell.dart';
import 'package:rillight/app/mobile_shell.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/auth/android_connect_page.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/player/player_page.dart';

import '../emby/fake_emby_server.dart';

void main() {
  test('desktop resolution never invokes an Android channel', () async {
    final environment = await PresentationEnvironment.resolve(
      isAndroid: false,
      detectTv: () => throw StateError('must not be called'),
    );
    expect(environment, PresentationEnvironment.desktop);
  });

  test(
    'Android device features select phone/TV; failure remains Android',
    () async {
      expect(
        await PresentationEnvironment.resolve(
          isAndroid: true,
          detectTv: () async => false,
        ),
        PresentationEnvironment.phone,
      );
      expect(
        await PresentationEnvironment.resolve(
          isAndroid: true,
          detectTv: () async => true,
        ),
        PresentationEnvironment.tv,
      );
      final failed = await PresentationEnvironment.resolve(
        isAndroid: true,
        detectTv: () => throw PlatformException(code: 'missing'),
      );
      expect(failed.isDesktop, isFalse);
      expect(failed.presentation, AppPresentation.androidPhone);
      expect(failed.detectionFailed, isTrue);
    },
  );

  for (final environment in [
    PresentationEnvironment.phone,
    PresentationEnvironment.tv,
  ]) {
    testWidgets(
      'Android ${environment.presentation.name} login and rotation keep platform boundary',
      (tester) async {
        tester.view.physicalSize = environment.isTv
            ? const Size(960, 540)
            : const Size(360, 780);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final desktopCalls = <MethodCall>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('window_manager'),
          (call) async {
            desktopCalls.add(call);
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            const MethodChannel('window_manager'),
            null,
          ),
        );
        final server = FakeEmbyServer();
        final auth = AuthController.memory(
          client: EmbyClient(
            device: const EmbyDeviceInfo(
              clientName: 'test',
              deviceName: 'Android',
              deviceId: 'android-bootstrap',
              version: '1',
            ),
            dio: dioForFakeEmby(FakeEmbyAdapter([server])),
          ),
        );
        final app = RillightApp(auth: auth, environment: environment);
        await tester.pumpWidget(app);
        await tester.pumpAndSettle();
        Future<void> enterField(String name, String value) async {
          if (environment.isTv) {
            await tester.tap(find.byKey(Key('tv-connect-$name')));
            await tester.pumpAndSettle();
            await tester.enterText(
              find.byKey(const Key('tv-input-editor')),
              value,
            );
            await tester.testTextInput.receiveAction(TextInputAction.done);
            await tester.pumpAndSettle();
          } else {
            await tester.enterText(
              find.byKey(Key('android-connect-$name')),
              value,
            );
          }
        }

        expect(
          find.byType(environment.isTv ? TvConnectPage : AndroidConnectPage),
          findsOneWidget,
        );
        expect(find.byType(MainWindowCloseGuard), findsNothing);
        expect(find.byType(AppShell), findsNothing);
        expect(find.byType(PlayerPage), findsNothing);
        await enterField('address', server.baseUrl.toString());
        await enterField('username', 'alice');
        await enterField('password', 'wrong');
        tester.view.physicalSize = environment.isTv
            ? const Size(1280, 720)
            : const Size(780, 360);
        await tester.pumpAndSettle();
        expect(
          PresentationScope.of(
            tester.element(
              find.byType(
                environment.isTv ? TvConnectPage : AndroidConnectPage,
              ),
            ),
          ),
          environment,
        );
        expect(find.textContaining(server.baseUrl.toString()), findsOneWidget);
        final submit = find.byKey(
          Key('${environment.isTv ? 'tv' : 'android'}-connect-submit'),
        );
        await tester.ensureVisible(submit);
        await tester.pumpAndSettle();
        await tester.tap(submit);
        await tester.pumpAndSettle();
        expect(auth.isLoggedIn, isFalse);
        expect(find.text('重试'), findsOneWidget);
        await enterField('password', 'correct-horse');
        await tester.ensureVisible(submit);
        await tester.pumpAndSettle();
        await tester.tap(submit);
        await tester.pumpAndSettle();
        expect(auth.isLoggedIn, isTrue);
        expect(
          find.byType(environment.isTv ? TvShell : MobileShell),
          findsOneWidget,
        );
        if (!environment.isTv) {
          await tester.tap(find.text('我的'));
          await tester.pumpAndSettle();
        }
        if (environment.isTv) {
          await tester.tap(find.text('设置'));
          await tester.pumpAndSettle();
        }
        expect(auth.savedServers, hasLength(1));
        if (!environment.isTv) {
          await tester.scrollUntilVisible(
            find.text('退出登录'),
            150,
            scrollable: find
                .descendant(
                  of: find.byType(MobileShell),
                  matching: find.byType(Scrollable),
                )
                .last,
          );
        }
        await tester.pumpAndSettle();
        await tester.tap(find.text('退出登录'));
        await tester.pumpAndSettle();
        expect(
          find.byType(environment.isTv ? TvConnectPage : AndroidConnectPage),
          findsOneWidget,
        );
        expect(desktopCalls, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        app.router.dispose();
        auth.dispose();
      },
      tags: ['integration'],
    );
  }

  testWidgets(
    'initialization failure retries without exposing exception contents',
    (tester) async {
      var attempts = 0;
      await tester.pumpWidget(
        AndroidBootstrap(
          resolveEnvironment: () async => PresentationEnvironment.phone,
          createAuth: () async {
            if (++attempts == 1) throw StateError('private-secret');
            return AuthController.memory();
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('private-secret'), findsNothing);
      expect(find.text('无法初始化应用，请重试。'), findsOneWidget);
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.byType(AndroidConnectPage), findsOneWidget);
      expect(attempts, 2);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    tags: ['integration'],
  );

  testWidgets('device failure offers retry and explicit phone fallback', (
    tester,
  ) async {
    await tester.pumpWidget(
      AndroidBootstrap(
        resolveEnvironment: () async => const PresentationEnvironment(
          AppPresentation.androidPhone,
          detectionFailed: true,
        ),
        createAuth: () async => AuthController.memory(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('重试'), findsOneWidget);
    await tester.tap(find.text('以手机模式继续'));
    await tester.pumpAndSettle();
    expect(find.byType(AndroidConnectPage), findsOneWidget);
    expect(find.byType(MainWindowCloseGuard), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  }, tags: ['integration']);
}
