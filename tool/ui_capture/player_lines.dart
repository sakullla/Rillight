import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/player/mobile_player_page.dart';
import 'package:rillight/player/player_controller.dart';
import 'package:rillight/player/playback_recovery_coordinator.dart';
import 'package:rillight/player/player_page.dart';
import 'package:rillight/player/source_switch_menu.dart';
import 'package:rillight/player/tv_player_page.dart';
import 'package:rillight/player/video_backend.dart';

import '../../test/emby/fake_emby_server.dart';
import 'capture.dart';
import 'fixtures.dart';

extension PlayerLineCaptures on CaptureSession {
  Future<void> playerLineStates(
    CaptureBackend backend,
    FakeEmbyServer backup,
    FakeEmbyServer remote,
  ) async {
    const states = [
      'player-lines-auto',
      'player-lines-fixed',
      'player-lines-pending',
      'player-line-reconnecting',
      'player-line-recovery-cancelled',
      'player-line-recovered',
      'player-line-recovery-failed',
      'player-line-confirmation',
      'player-lines-auto-landscape',
      'player-line-reconnecting-landscape',
      'player-line-confirmation-landscape',
      'player-line-certificate',
      'player-line-forbidden',
      'player-line-rate-limited',
    ];
    if (!states.any(shouldCapture)) return;
    final (
      BuildContext context,
      PlayerController controller,
    ) = switch (platform) {
      'phone' => (
        tester.element(
          find
              .descendant(
                of: find.byType(MobilePlayerPage),
                matching: find.byType(CupertinoPageScaffold),
              )
              .first,
        ),
        tester
            .state<MobilePlayerPageState>(find.byType(MobilePlayerPage))
            .controller!,
      ),
      'tv' => (
        tester.element(
          find
              .descendant(
                of: find.byType(TvPlayerPage),
                matching: find.byType(CupertinoPageScaffold),
              )
              .first,
        ),
        tester.state<TvPlayerPageState>(find.byType(TvPlayerPage)).controller!,
      ),
      _ => (
        tester.element(
          find
              .descendant(
                of: find.byType(PlayerPage),
                matching: find.byType(CupertinoPageScaffold),
              )
              .first,
        ),
        tester.state<PlayerPageState>(find.byType(PlayerPage)).controller!,
      ),
    };
    final failedPublicInfo = backup.publicInfoStatus;
    backup.publicInfoStatus = null;
    remote.publicInfoStatus = null;
    Future<void> openLines() async {
      expect(AppUiTheme.of(context).brightness, Brightness.dark);
      unawaited(
        platform == 'phone'
            ? showPlaybackLineSheet(context, controller)
            : showPlaybackLineDialog(context, controller),
      );
      await tester.pump();
      await advance(400);
    }

    Future<void> closeLines() async {
      if (platform == 'phone') {
        Navigator.of(context).pop();
      } else {
        await tester.tap(find.byKey(const Key('playback-lines-close')));
      }
      await advance(400);
    }

    Future<void> choose(Key key) async {
      final choice = find.byKey(key).last;
      await tester.ensureVisible(choice);
      await tester.pump();
      await tester.tap(choice);
      await advance(400);
    }

    final classifiedStates = {
      PlaybackRecoveryFailureKind.certificate: (
        'player-line-certificate',
        '证书验证失败，请检查服务器证书',
      ),
      PlaybackRecoveryFailureKind.forbidden: (
        'player-line-forbidden',
        '没有播放权限，请检查账号权限',
      ),
      PlaybackRecoveryFailureKind.rateLimited: (
        'player-line-rate-limited',
        '服务器请求过多，请稍后重试',
      ),
    };
    for (final entry in classifiedStates.entries) {
      if (!shouldCapture(entry.value.$1)) continue;
      backend.emitEvent(
        VideoEventKind.error,
        PlaybackRecoveryFailure(
          entry.key,
          retryAfter: entry.key == PlaybackRecoveryFailureKind.rateLimited
              ? const Duration(seconds: 30)
              : null,
        ),
      );
      await advance(300);
      expect(find.text(entry.value.$2).hitTestable(), findsOneWidget);
      expect(find.text('播放中断，请检查网络'), findsNothing);
      expect(controller.isRecovering, isFalse);
      final retry = tester.widget<AppButton>(
        find.byKey(const Key('playback-recovery-retry')),
      );
      expect(
        retry.onPressed == null,
        entry.key == PlaybackRecoveryFailureKind.rateLimited,
      );
      if (platform == 'tv' &&
          entry.key == PlaybackRecoveryFailureKind.rateLimited) {
        expect(
          tester
              .widget<AppButton>(
                find.byKey(const Key('playback-recovery-lines')),
              )
              .focusNode
              ?.hasFocus,
          isTrue,
        );
      }
      await save(entry.value.$1);
      if (entry.key == PlaybackRecoveryFailureKind.rateLimited) {
        // End the synthetic cooldown with a separate classified event before
        // continuing unrelated captures; no production clock is bypassed.
        backend.emitEvent(
          VideoEventKind.error,
          const PlaybackRecoveryFailure(
            PlaybackRecoveryFailureKind.certificate,
          ),
        );
        await advance(100);
      }
      await tap(const Key('playback-recovery-retry'));
      await advance(600);
      expect(controller.isPlaying, isTrue);
    }
    if (!states
        .where((id) => !classifiedStates.values.any((v) => v.$1 == id))
        .any(shouldCapture)) {
      backup.publicInfoStatus = failedPublicInfo;
      return;
    }

    Future<void> saveLineState(String state) async {
      await save(state);
      if (platform != 'phone' || !shouldCapture('$state-landscape')) return;
      final before = tester.view.physicalSize;
      tester.view.physicalSize = Size(before.height, before.width);
      await advance(200);
      final actionKey = state == 'player-line-reconnecting'
          ? const Key('playback-recovery-cancel')
          : state == 'player-line-confirmation'
          ? const Key('playback-confirm-cancel')
          : null;
      if (actionKey != null) {
        final action = find.byKey(actionKey).last;
        expect(action.hitTestable(), findsOneWidget);
        expect(action.hitTestable(at: const Alignment(0, .9)), findsOneWidget);
        final bounds = tester.getRect(action);
        expect(bounds.top, greaterThanOrEqualTo(0));
        expect(
          bounds.bottom,
          lessThanOrEqualTo(tester.view.physicalSize.height),
        );
      }
      await save('$state-landscape');
      tester.view.physicalSize = before;
      await advance(200);
    }

    final initialLine = controller.activeLineId!;
    await openLines();
    await choose(const Key('playback-line-auto'));
    expect(controller.playbackLineSelection.isAutomatic, isTrue);
    await saveLineState('player-lines-auto');
    await choose(ValueKey('playback-line-$initialLine'));
    expect(controller.playbackLineSelection.fixedLineId, initialLine);
    await save('player-lines-fixed');
    await choose(const Key('playback-line-auto'));
    await closeLines();

    // A real transport error enters the production recovery coordinator. Hold
    // the native-open test double to make its cancellable state deterministic.
    final gate = Completer<void>();
    backend.openGate = gate;
    backend.emitEvent(VideoEventKind.error, 'Connection reset by peer');
    await advance(500);
    expect(controller.isRecovering, isTrue);
    expect(find.byKey(const Key('playback-recovery-cancel')), findsOneWidget);
    if (platform == 'tv') {
      expect(
        tester
            .widget<AppButton>(
              find.byKey(const Key('playback-recovery-cancel')),
            )
            .focusNode
            ?.hasFocus,
        isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await advance(100);
      final choiceContext = FocusManager.instance.primaryFocus?.context;
      if (choiceContext == null || !choiceContext.mounted) {
        fail('TV recovery choice must own a mounted focus target');
      }
      expect(
        choiceContext.findAncestorWidgetOfExactType<AppButton>()?.key,
        const Key('playback-recovery-lines'),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await advance(100);
    }
    await saveLineState('player-line-reconnecting');
    await tap(const Key('playback-recovery-lines'));
    await save('player-lines-pending');
    if (platform == 'tv') {
      await closeLines();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await advance(200);
      expect(find.byType(TvPlayerPage), findsOneWidget);
    } else {
      await choose(const Key('playback-line-cancel'));
      await closeLines();
    }
    backend.openGate = null;
    gate.complete();
    await advance(500);
    expect(controller.isRecovering, isFalse);
    expect(controller.isPlaying, isFalse);
    await save('player-line-recovery-cancelled');

    backend.rejectNextOpens = 1;
    if (platform == 'tv') {
      expect(
        tester
            .widget<AppButton>(find.byKey(const Key('playback-recovery-retry')))
            .focusNode
            ?.hasFocus,
        isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    } else {
      await tap(const Key('playback-recovery-retry'));
    }
    await advance(1000);
    expect(controller.disconnected, isFalse);
    expect(controller.isPlaying, isTrue);
    await openLines();
    expect(controller.activeLineId, isNot(initialLine));
    await save('player-line-recovered');
    await closeLines();

    backend.rejectAllOpens = true;
    backend.emitEvent(VideoEventKind.error, 'Connection reset by peer');
    await advance(1800);
    expect(controller.isRecovering, isFalse);
    expect(controller.disconnected, isTrue);
    if (platform == 'tv') {
      expect(
        tester
            .widget<AppButton>(find.byKey(const Key('playback-recovery-retry')))
            .focusNode
            ?.hasFocus,
        isTrue,
      );
    }
    await save('player-line-recovery-failed');
    backend.rejectAllOpens = false;
    await tap(const Key('playback-recovery-retry'));
    await advance(1000);
    expect(controller.isPlaying, isTrue);
    expect(controller.playbackLineSelection, const LineSelection.auto());
    final currentAddress = controller.playbackLines
        .firstWhere((line) => line.id == controller.activeLineId)
        .address;
    final confirmationServer =
        Uri.parse(currentAddress).host == backup.baseUrl.host ? remote : backup;
    backend.emitEvent(VideoEventKind.position, const Duration(seconds: 30));
    await advance(100);
    final originalItems = confirmationServer.items;
    confirmationServer.items = captureServer().items;
    final replacement = confirmationServer.items.firstWhere(
      (item) => item.id == 'movie-up',
    );
    replacement.runtime = const Duration(seconds: 5);
    replacement.mediaStreams = const [
      FakeMediaStream(index: 0, type: 'Video', codec: 'h264'),
      FakeMediaStream(
        index: 7,
        type: 'Audio',
        codec: 'aac',
        language: 'jpn',
        displayTitle: '日本語 · AAC',
        isDefault: true,
      ),
    ];
    final backupLine = controller.playbackLines.firstWhere(
      (line) => Uri.parse(line.address).host == confirmationServer.baseUrl.host,
    );
    await openLines();
    await choose(ValueKey('playback-line-${backupLine.id}'));
    expect(controller.switchConfirmation, isNotNull);
    expect(controller.switchConfirmation!.positionTicks, 300000000);
    expect(controller.switchConfirmation!.targetRuntimeTicks, 50000000);
    expect(controller.switchConfirmation!.canTryCurrentPosition, isFalse);
    expect(find.byKey(const Key('playback-confirm-resume')), findsNothing);
    await saveLineState('player-line-confirmation');
    await choose(const Key('playback-confirm-cancel'));
    expect(controller.playbackLineSelection, const LineSelection.auto());
    await closeLines();
    confirmationServer.items = originalItems;
    backup.publicInfoStatus = failedPublicInfo;
  }
}
