import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/android_bootstrap.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/auth/android_connect_page.dart';
import 'package:rillight/auth/auth_controller.dart';

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
