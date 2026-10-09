// Explicit subprocess fixture, not a suite entrypoint. Uses simulated backend
// and synthetic HTTP only; no native window, decoder or physical audio evidence.
import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/player/desktop_player_window.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_process_protocol.dart';
import 'package:rillight/player/player_page.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/player_window.dart';
import 'package:rillight/player/source_switch_menu.dart';
import 'package:rillight/player/video_backend.dart';
import '../emby/fake_emby_server.dart';
import 'synthetic_mailbox.dart';

void main() {
  testWidgets(
    'isolated simulated desktop helper',
    (tester) async {
      final path = Platform.environment['RILLIGHT_TEST_LAUNCH'];
      if (path == null) return;
      Future<Map<String, dynamic>> readLaunch() async {
        final decoded = await tester.runAsync(() async {
          return jsonDecode(await File(path).readAsString())
              as Map<String, dynamic>;
        });
        return decoded!;
      }

      var payload = await readLaunch();
      // Warm launches omit source until the host writes the real payload and start.
      if (payload['warmPlayer'] == true) {
        final protocol = PlayerProcessProtocol.fromJson(payload);
        await tester.runAsync(() => protocol.write('ready'));
        final deadline = DateTime.now().add(const Duration(seconds: 65));
        var adopted = false;
        while (DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 20));
          if (await tester.runAsync(() => protocol.read('close')) != null) {
            return;
          }
          if (await tester.runAsync(() => protocol.parentExpired()) == true) {
            return;
          }
          final started = await tester.runAsync(
            () => protocol.read('start', consume: false),
          );
          if (started != null) {
            payload = await readLaunch();
            // start can land before the host's launch rewrite is visible.
            if (payload['source'] is Map) {
              await tester.runAsync(() => protocol.read('start'));
              adopted = true;
              break;
            }
          }
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
        }
        if (!adopted) return;
      }
      final launch = PlayerWindowLaunch.fromJson(payload);
      final source = launch.request.source;
      if (source == null) return;
      expect(
        await tester.runAsync(() => launch.protocol!.parentExpired()),
        isFalse,
        reason: 'Parent heartbeat expired while compiling the helper',
      );
      final server = FakeEmbyServer(
        serverId: source.account.verifiedServerId,
        baseUrl: Uri.parse(launch.baseUrl),
        items: [
          FakeEmbyItem(
            id: launch.request.itemId,
            name: '合成作品',
            type: 'Movie',
            parentId: launch.request.libraryId,
          ),
        ],
      );
      server.issuedTokens.add(launch.accessToken);
      final client = EmbyClient(
        device: launch.device,
        dio: dioForFakeEmby(FakeEmbyAdapter([server])),
      );
      final backend = FakeVideoBackend(duration: const Duration(seconds: 120));
      var exited = false;
      await tester.pumpWidget(
        PlayerWindowApp.testing(
          launch: launch,
          client: client,
          bindings: PlayerBindings(
            createBackend: () => backend,
            window: PlayerWindow(),
            settingsStore: MemoryPlayerSettingsStore(),
            progressInterval: const Duration(milliseconds: 200),
          ),
          onExit: () => exited = true,
        ),
      );
      final controller = tester
          .state<PlayerPageState>(find.byType(PlayerPage))
          .controller!;
      await tester.runAsync(() => launch.protocol!.write('ready'));
      Future<void> advance() async {
        await tester.pump(const Duration(milliseconds: 80));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
      }

      Future<void> menuAction(Map<String, dynamic> message) async {
        controller.onUserActivity();
        await advance();
        if (message['action'] == 'open-lock') {
          unawaited(
            controller
                .switchDispatcher!({
                  'action': 'catalogue',
                  'item': controller.itemId,
                })
                .then<void>((_) {}, onError: (_, _) {}),
          );
          return;
        }
        if (message['action'] == 'lock') {
          unawaited(
            controller.lockPrivateRegion().then<void>(
              (_) {},
              onError: (_, _) {},
            ),
          );
          return;
        }
        expect(find.byKey(const Key('player-playback-lines')), findsNothing);
        expect(find.text('手动切换'), findsNothing);
        expect(find.text('立即锁定'), findsNothing);
        expect(find.byType(PlaybackLineMenu), findsNothing);
        await tester.runAsync(
          () =>
              File(
                '${launch.protocol!.directory.path}/synthetic-menu-receipt.json',
              ).writeAsString(
                jsonEncode({
                  'lines': controller.playbackLines.length,
                  'itemId': controller.itemId,
                  'baseUrl': controller.client.baseUrl?.toString(),
                }),
              ),
        );
      }

      var observed = false;
      var framesAfterObservation = 0;
      final deadline = DateTime.now().add(const Duration(seconds: 200));
      while (!exited && DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 30));
        if (!observed && controller.resolved != null && !controller.loading) {
          observed = true;
          backend.emitEvent(
            VideoEventKind.position,
            const Duration(seconds: 7),
          );
        }
        if (observed && ++framesAfterObservation == 120) {
          backend.emitEvent(
            VideoEventKind.position,
            const Duration(seconds: 11),
          );
        }
        final message = await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          final file = File(
            '${launch.protocol!.directory.path}/synthetic-position.json',
          );
          return consumeSyntheticMessage(file);
        });
        final menu = await tester.runAsync(() async {
          final file = File(
            '${launch.protocol!.directory.path}/synthetic-menu.json',
          );
          return consumeSyntheticMessage(file);
        });
        if (menu != null) await menuAction(menu);
        if (message != null) {
          backend.emitEvent(
            VideoEventKind.position,
            Duration(seconds: message['seconds'] as int),
          );
        }
      }
      expect(
        observed,
        isTrue,
        reason:
            'loading=${controller.loading} error=${controller.error} phase=${controller.state.phase} resolved=${controller.resolved} failure=${controller.loadFailure} detail=${controller.disconnectDetail}',
      );
      expect(exited, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    tags: ['integration'],
    timeout: const Timeout(Duration(seconds: 210)),
  );
}
