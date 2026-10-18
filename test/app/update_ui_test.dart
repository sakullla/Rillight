import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/app/updates/update_check.dart';
import 'package:rillight/app/updates/update_controller.dart';
import 'package:rillight/app/updates/update_download.dart';
import 'package:rillight/app/updates/update_platform_contract.dart';
import 'package:rillight/app/updates/update_reminder_host.dart';

import '../helpers/cupertino_test_app.dart';
import 'update_ui_fixture.dart';

void main() {
  late UpdateUiFixture fixture;
  setUp(() => fixture = UpdateUiFixture(system: UpdateOperatingSystem.android));
  tearDown(() => fixture.dispose());
  Future<void> pump(WidgetTester tester, {bool occupied = false}) =>
      tester.pumpWidget(
        CupertinoTestApp(
          home: CupertinoPageScaffold(
            child: UpdateActivityScope(
              playbackOccupied: () => occupied,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: UpdateCheck(controller: fixture.controller),
              ),
            ),
          ),
        ),
      );
  Future<void> tap(WidgetTester tester, String key) async {
    await tester.ensureVisible(find.byKey(Key(key)));
    await tester.tap(find.byKey(Key(key)));
    await tester.pump();
  }

  void noCopy() {
    expect(find.byType(AppSelectableText), findsNothing);
    expect(find.textContaining('复制'), findsNothing);
    expect(find.textContaining('https://'), findsNothing);
  }

  testWidgets(
    'progress cancel retry checksum failure and Release failure never copy addresses',
    (tester) async {
      await pump(tester);
      await tap(tester, 'app-update-check-button');
      await tester.pumpAndSettle();
      expect(find.text('应用内下载'), findsOneWidget);
      await tap(tester, 'app-update-download');
      fixture.downloader.progress(total: null);
      await tester.pump();
      expect(find.textContaining('已下载 42.0 MB'), findsOneWidget);
      expect(find.byType(AppProgressBar), findsNothing);
      noCopy();
      await tap(tester, 'app-update-cancel');
      await tester.pumpAndSettle();
      expect(find.textContaining('下载已取消'), findsOneWidget);
      await tap(tester, 'app-update-retry');
      fixture.downloader.progress();
      await tester.pump();
      expect(find.textContaining('42%'), findsOneWidget);
      fixture.downloader.verifying();
      await tester.pump();
      expect(find.text('正在校验安装包…'), findsOneWidget);
      fixture.downloader.fail(UpdateDownloadFailure.checksum);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('app-update-install')), findsNothing);
      noCopy();
      fixture.platform.openResult = const UpdateActionResult(
        UpdateActionStatus.failed,
      );
      await tap(tester, 'app-update-open');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('app-update-open-failed')), findsOneWidget);
      noCopy();
      fixture.platform.openResult = const UpdateActionResult(
        UpdateActionStatus.handedOff,
      );
      await tap(tester, 'app-update-open');
      expect(fixture.platform.opened, 2);
    },
  );
  testWidgets(
    'permission settings are distinct from installation; playback blocks handoff',
    (tester) async {
      await fixture.controller.check();
      final download = fixture.controller.startDownload();
      fixture.downloader.finish();
      await download;
      await pump(tester, occupied: true);
      await tap(tester, 'app-update-install');
      expect(fixture.platform.installed, 0);
      expect(
        find.byKey(const Key('app-update-playback-blocked')),
        findsOneWidget,
      );
      await pump(tester);
      fixture.platform.installResult = const UpdateActionResult(
        UpdateActionStatus.permissionRequired,
      );
      await tap(tester, 'app-update-install');
      await tester.pumpAndSettle();
      expect(fixture.platform.authorized, 0);
      await tap(tester, 'app-update-permission');
      await tester.pumpAndSettle();
      expect(fixture.platform.authorized, 1);
      expect(fixture.platform.installed, 1);
      expect(find.textContaining('尚未开始安装'), findsOneWidget);
      expect(find.textContaining('已交给系统安装流程'), findsNothing);
      noCopy();
      fixture.platform.installResult = const UpdateActionResult(
        UpdateActionStatus.cancelled,
      );
      await tap(tester, 'app-update-install');
      await tester.pumpAndSettle();
      expect(find.textContaining('已取消系统操作'), findsOneWidget);
      expect(find.textContaining('更新成功'), findsNothing);
    },
  );
  testWidgets(
    'no compatible package keeps Release; auto failure is silent and manual joins check',
    (tester) async {
      fixture.service.failure = StateError('synthetic network failure');
      await fixture.controller.checkAtStartup();
      await pump(tester);
      expect(find.textContaining('暂时无法检查更新'), findsNothing);
      await tap(tester, 'app-update-check-button');
      await tester.pumpAndSettle();
      expect(find.textContaining('暂时无法检查更新'), findsOneWidget);
      fixture.service.failure = null;
      fixture.platform.noPackage = true;
      fixture.service.gate = Completer<void>();
      final automatic = fixture.controller.check(automatic: true);
      await tester.pump();
      await tap(tester, 'app-update-check-button');
      expect(find.text('正在检查更新…'), findsOneWidget);
      fixture.service.gate!.complete();
      await automatic;
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('app-update-no-package')), findsOneWidget);
      expect(find.byKey(const Key('app-update-download')), findsNothing);
      expect(find.byKey(const Key('app-update-open')), findsOneWidget);
      noCopy();
    },
  );
  testWidgets('keyboard can activate update action', (tester) async {
    await pump(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(fixture.controller.checkPhase, UpdateCheckPhase.available);
  });
  testWidgets(
    'can ignore and restore version reminder and toggle automatic startup reminders',
    (tester) async {
      await pump(tester);
      expect(fixture.controller.autoReminderEnabled, isTrue);
      await tap(tester, 'app-update-auto-reminder');
      await tester.pumpAndSettle();
      expect(fixture.controller.autoReminderEnabled, isFalse);
      await tap(tester, 'app-update-auto-reminder');
      await tester.pumpAndSettle();
      expect(fixture.controller.autoReminderEnabled, isTrue);

      await tap(tester, 'app-update-check-button');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('app-update-ignored-badge')), findsNothing);
      await tap(tester, 'app-update-ignore-version');
      await tester.pumpAndSettle();
      expect(fixture.controller.ignoredVersion, '99.0.0');
      expect(find.byKey(const Key('app-update-ignored-badge')), findsOneWidget);
      expect(find.text('恢复此版本提醒'), findsOneWidget);

      await tap(tester, 'app-update-ignore-version');
      await tester.pumpAndSettle();
      expect(fixture.controller.ignoredVersion, isNull);
      expect(find.byKey(const Key('app-update-ignored-badge')), findsNothing);
    },
  );
}
