import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/app/updates/update_download.dart';
import 'package:rillight/app/updates/update_platform_contract.dart';

import '../../test/app/update_ui_fixture.dart';
import 'capture.dart';

extension UpdateCaptures on CaptureSession {
  Future<void> _updateFrame(
    String state, {
    String target = 'app-update-status',
    String? action,
  }) async {
    final finder = find.byKey(Key(target));
    // Align the state inside the viewport, not at its edge beneath TV chrome.
    // Recheck after layout/focus scrolling settles; a PNG alone is not evidence
    // that its named state or operation is actually on screen.
    await Scrollable.ensureVisible(
      tester.element(finder),
      alignment:
          action == 'app-update-open' ||
              (action == 'app-update-install' &&
                  target == 'app-update-install-result')
          ? .6
          : .35,
    );
    await advance(450);
    final height =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;
    final rect = tester.getRect(finder);
    expect(
      rect.top,
      greaterThanOrEqualTo(platform == 'tv' ? 60 : 0),
      reason: '$state state obscured at top',
    );
    expect(
      rect.bottom,
      lessThanOrEqualTo(height),
      reason: '$state state outside viewport',
    );
    if (action != null) {
      expect(
        find.byKey(Key(action)).hitTestable(),
        findsOneWidget,
        reason: '$state action not visible',
      );
    }
    await save(state);
  }

  Future<void> updatePages(RillightApp app, UpdateUiFixture fixture) async {
    if (platform == 'tv') {
      app.router.go('/');
      await advance(700);
      await tap(const ValueKey('tv-nav-3'));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await advance(300);
    } else if (platform == 'phone') {
      app.router.go('/mine');
      await advance(700);
    } else {
      app.router.go('/settings');
      await advance(700);
      await tap(const ValueKey('settings-section-关于'));
    }
    await tester.ensureVisible(
      find.byKey(const Key('app-update-check-button')),
    );
    await advance(300);
    await _updateFrame('settings-update', action: 'app-update-check-button');
    await tester.ensureVisible(
      find.byKey(const Key('app-update-auto-reminder')),
    );
    await advance(200);
    await tap(const Key('app-update-auto-reminder'));
    await _updateFrame(
      'settings-update-auto-disabled',
      target: 'app-update-auto-reminder',
      action: 'app-update-auto-reminder',
    );
    await tap(const Key('app-update-auto-reminder'));
    fixture.service.gate = Completer<void>();
    await tap(const Key('app-update-check-button'));
    await _updateFrame('settings-update-checking');
    fixture.service.gate!.complete();
    await advance(400);
    await _updateFrame(
      'settings-update-available',
      action: 'app-update-download',
    );
    await tester.ensureVisible(
      find.byKey(const Key('app-update-ignore-version')),
    );
    await advance(200);
    await tap(const Key('app-update-ignore-version'));
    await _updateFrame(
      'settings-update-ignored',
      target: 'app-update-ignored-badge',
      action: 'app-update-ignore-version',
    );
    await tap(const Key('app-update-ignore-version'));
    await fixture.controller.check(automatic: true);
    await advance(350);
    expect(find.byKey(const Key('app-update-reminder')), findsOneWidget);
    expect(
      find.byKey(const Key('app-update-reminder-ignore-version')).hitTestable(),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('app-update-reminder-disable')).hitTestable(),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('app-update-reminder-close')).hitTestable(),
      findsOneWidget,
    );
    await save('settings-update-reminder');
    await tap(const Key('app-update-reminder-close'));
    await advance(300);
    expect(find.byKey(const Key('app-update-reminder')), findsNothing);
    fixture.platform.noPackage = true;
    await tap(const Key('app-update-check-button'));
    await tester.ensureVisible(find.byKey(const Key('app-update-no-package')));
    await advance(200);
    await _updateFrame(
      'settings-update-no-package',
      target: 'app-update-no-package',
      action: 'app-update-open',
    );
    fixture.platform.noPackage = false;
    await tap(const Key('app-update-check-button'));
    await tap(const Key('app-update-download'));
    fixture.downloader.progress();
    await advance(250);
    await tester.ensureVisible(
      find.byKey(const Key('app-update-download-status')),
    );
    await advance(200);
    await _updateFrame(
      'settings-update-downloading',
      target: 'app-update-download-status',
      action: 'app-update-cancel',
    );
    fixture.downloader.verifying();
    await advance(200);
    await _updateFrame(
      'settings-update-verifying',
      target: 'app-update-download-status',
      action: 'app-update-cancel',
    );
    fixture.downloader.fail(UpdateDownloadFailure.checksum);
    await advance(300);
    await _updateFrame(
      'settings-update-checksum-failed',
      target: 'app-update-download-status',
      action: 'app-update-retry',
    );
    await tap(const Key('app-update-retry'));
    fixture.downloader.fail(UpdateDownloadFailure.network);
    await advance(300);
    await _updateFrame(
      'settings-update-download-failed',
      target: 'app-update-download-status',
      action: 'app-update-retry',
    );
    await tap(const Key('app-update-retry'));
    fixture.downloader.finish();
    await advance(300);
    await tester.ensureVisible(find.byKey(const Key('app-update-install')));
    await advance(200);
    await _updateFrame(
      'settings-update-ready',
      target: 'app-update-download-status',
      action: 'app-update-install',
    );
    if (platform != 'desktop') {
      fixture.platform.installResult = const UpdateActionResult(
        UpdateActionStatus.permissionRequired,
      );
      await tap(const Key('app-update-install'));
      await tester.ensureVisible(
        find.byKey(const Key('app-update-permission')),
      );
      await advance(200);
      await _updateFrame(
        'settings-update-permission',
        target: 'app-update-install-result',
        action: 'app-update-permission',
      );
      await tap(const Key('app-update-permission'));
      await tester.ensureVisible(
        find.byKey(const Key('app-update-permission-result')),
      );
      await advance(200);
      await _updateFrame(
        'settings-update-permission-settings',
        target: 'app-update-permission-result',
      );
    }
    fixture.platform.installResult = const UpdateActionResult(
      UpdateActionStatus.failed,
      failure: UpdateActionFailure.unavailable,
    );
    await Scrollable.ensureVisible(
      tester.element(find.byKey(const Key('app-update-install'))),
      alignment: .35,
    );
    await advance(200);
    await tap(const Key('app-update-install'));
    await tester.ensureVisible(
      find.byKey(const Key('app-update-install-result')),
    );
    await advance(200);
    await _updateFrame(
      'settings-update-install-failed',
      target: 'app-update-install-result',
      action: 'app-update-install',
    );
    fixture.platform.openResult = const UpdateActionResult(
      UpdateActionStatus.failed,
      failure: UpdateActionFailure.unavailable,
    );
    await tap(const Key('app-update-open'));
    await tester.ensureVisible(find.byKey(const Key('app-update-open-failed')));
    await advance(200);
    await _updateFrame(
      'settings-update-release-failed',
      target: 'app-update-open-failed',
      action: 'app-update-open',
    );
  }
}
