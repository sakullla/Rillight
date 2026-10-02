import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/player/android_playback_lifecycle.dart';
import 'package:rillight/player/player_controller.dart';
import 'package:rillight/player/player_window.dart';
import 'package:rillight/player/video_backend.dart';

class _Controller extends PlayerController {
  _Controller()
    : super(
        client: EmbyClient(
          device: const EmbyDeviceInfo(
            clientName: 'test',
            deviceName: 'test',
            deviceId: 'test',
            version: '1',
          ),
        ),
        itemId: 'synthetic',
        backend: FakeVideoBackend(),
        window: PlayerWindow(),
      );
  int suspends = 0, restores = 0;
  @override
  Future<void> suspendPlayback() async {
    suspends++;
  }

  @override
  Future<void> restorePlayback() async {
    restores++;
  }
}

class _Presentation implements VideoBackendPhonePresentation {
  @override
  final ValueNotifier<Map<String, dynamic>> phonePresentation = ValueNotifier(
    const {},
  );
  Future<Map<String, dynamic>> Function()? query;
  @override
  Future<Map<String, dynamic>> refreshPhonePresentation() async =>
      query == null ? phonePresentation.value : await query!();
  @override
  Future<void> configurePhonePresentation(bool enabled) async {}
  @override
  Future<bool> enterPictureInPicture() async => true;
}

void main() {
  testWidgets(
    'native transition and PiP retain the same paused/playing session',
    (tester) async {
      final c = _Controller(), p = _Presentation();
      final lifecycle = AndroidPlaybackLifecycle(c, phonePresentation: p);
      addTearDown(lifecycle.dispose);
      p.phonePresentation.value = {'retainPlayback': true, 'entering': true};
      lifecycle.didChangeAppLifecycleState(AppLifecycleState.paused);
      await tester.pump();
      expect(c.suspends, 0);
      p.phonePresentation.value = {'retainPlayback': true, 'active': true};
      await tester.pump();
      expect(c.suspends, 0);
      p.phonePresentation.value = {
        'retainPlayback': false,
        'shouldSuspend': true,
      };
      await tester.pump();
      expect(c.suspends, 1);
      p.phonePresentation.value = {
        'retainPlayback': false,
        'shouldSuspend': true,
      };
      await tester.pump();
      expect(
        c.suspends,
        1,
        reason: 'duplicate native callbacks do not release twice',
      );
    },
  );
  testWidgets(
    'queued native stop cannot release a replacement foreground session',
    (tester) async {
      final c = _Controller(), p = _Presentation();
      final lifecycle = AndroidPlaybackLifecycle(c, phonePresentation: p);
      addTearDown(lifecycle.dispose);
      p.phonePresentation.value = {'session': 'old', 'shouldSuspend': true};
      p.phonePresentation.value = {
        'session': 'new',
        'foreground': true,
        'shouldSuspend': false,
      };
      await tester.pump();
      expect(c.suspends, 0);
    },
  );

  testWidgets('failed native query cannot bypass background release', (
    tester,
  ) async {
    final c = _Controller(), p = _Presentation();
    p.query = () async => throw StateError('bridge gone');
    final lifecycle = AndroidPlaybackLifecycle(c, phonePresentation: p);
    addTearDown(lifecycle.dispose);
    lifecycle.didChangeAppLifecycleState(AppLifecycleState.paused);
    await tester.pump();
    expect(c.suspends, 1);
  });
  testWidgets('unanswered native query has bounded background grace', (
    tester,
  ) async {
    final c = _Controller(), p = _Presentation();
    p.query = () => Completer<Map<String, dynamic>>().future;
    final lifecycle = AndroidPlaybackLifecycle(c, phonePresentation: p);
    addTearDown(lifecycle.dispose);
    lifecycle.didChangeAppLifecycleState(AppLifecycleState.paused);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 701));
    expect(c.suspends, 1);
  });
}
