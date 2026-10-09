import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/player_controller.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/player_window.dart';
import 'package:rillight/player/subtitle_viewport.dart';
import 'package:rillight/player/video_backend.dart';

import '../emby/fake_emby_server.dart';

void main() {
  testWidgets('desktop and TV surfaces apply the saved subtitle size', (
    tester,
  ) async {
    final server = FakeEmbyServer();
    final auth = AuthController(
      client: EmbyClient(
        device: const EmbyDeviceInfo(
          clientName: 'Rillight',
          deviceName: 'test',
          deviceId: 'subtitle-viewport',
          version: '1',
        ),
        dio: dioForFakeEmby(FakeEmbyAdapter([server])),
      ),
      credentials: MemoryCredentialStore(),
      servers: MemoryServerListStore(),
    );
    final backend = FakeVideoBackend();
    late final PlayerController controller;
    await tester.runAsync(() async {
      await auth.connect(
        address: server.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      );
      controller = PlayerController(
        client: auth.client,
        itemId: 'movie-inception',
        backend: backend,
        window: PlayerWindow(),
        stoppedTimeout: const Duration(milliseconds: 10),
        disposeTimeout: const Duration(milliseconds: 10),
        settingsStore: MemoryPlayerSettingsStore(
          const PlayerSettings(
            phoneSubtitles: PhoneSubtitleSettings(
              size: PhoneSubtitleSize.large,
            ),
          ),
        ),
        snapshotStore: MemoryPlaybackSessionSnapshotStore(),
      );
      await controller.start();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 800,
            height: 450,
            child: SubtitleViewportReporter(controller: controller),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));

    final presentation = backend.subtitlePresentation;
    expect(presentation, isNotNull);
    expect(presentation!.displayWidth, 800);
    expect(presentation.displayHeight, 450);
    expect(presentation.fontSize, 24);
    expect(presentation.userScale, 1.25);

    await tester.runAsync(() async {
      await controller.setPhoneSubtitleSettings(
        const PhoneSubtitleSettings(size: PhoneSubtitleSize.extraLarge),
      );
      await controller.updateSubtitleViewport(
        width: 1920,
        height: 1080,
        landscape: true,
      );
      expect(backend.subtitlePresentation!.fontSize, closeTo(48.6, 0.001));
      expect(backend.subtitlePresentation!.userScale, 1.5);
      await controller.updateSubtitleViewport(
        width: 2560,
        height: 1440,
        landscape: true,
      );
      expect(backend.subtitlePresentation!.fontSize, closeTo(64.8, 0.001));
      await controller.disposeAsync();
      controller.dispose();
      auth.dispose();
    });
    expect(backend.subtitlePresentation!.userScale, 1.5);
  });
}
