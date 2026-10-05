// Explicit subprocess fixture, not a suite entrypoint. Uses simulated backend
// and synthetic HTTP only; no native window, decoder or physical audio evidence.
import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/player/desktop_player_window.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_page.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/player_window.dart';
import 'package:rillight/player/source_switch_menu.dart';
import 'package:rillight/player/video_backend.dart';
import '../emby/fake_emby_server.dart';

void main() {
  testWidgets(
    'isolated simulated desktop helper',
    (tester) async {
      final path = Platform.environment['RILLIGHT_TEST_LAUNCH'];
      if (path == null) return;
      final json = await tester.runAsync(
        () async =>
            jsonDecode(await File(path).readAsString()) as Map<String, dynamic>,
      );
      final launch = PlayerWindowLaunch.fromJson(json!);
      final server = FakeEmbyServer(
        serverId: launch.request.source!.account.verifiedServerId,
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
        if (find.byType(SourceSwitchMenu).evaluate().isEmpty) {
          await tester.tap(find.byKey(const Key('player-manual-switch')));
          await advance();
        }
        expect(find.byType(SourceSwitchMenu), findsOneWidget);
        if (message['action'] == 'open-lock') return;
        if (message['action'] == 'lock') {
          final lock = find.byKey(const Key('player-lock-private'));
          for (var frame = 0; frame < 120; frame++) {
            if (lock.evaluate().isNotEmpty &&
                tester.widget<FilledButton>(lock).onPressed != null) {
              break;
            }
            await advance();
          }
          expect(lock, findsOneWidget);
          expect(tester.widget<FilledButton>(lock).onPressed, isNotNull);
          await tester.ensureVisible(lock);
          await tester.tap(lock);
          return;
        }
        final targetId = message['targetId'] as String;
        final target = find.byWidgetPredicate(
          (widget) =>
              widget is ListTile &&
              widget.key is ValueKey<String> &&
              (widget.key as ValueKey<String>).value.startsWith(
                'switch-host-target-',
              ) &&
              (widget.key as ValueKey<String>).value.contains(targetId),
        );
        for (var frame = 0; frame < 120 && target.evaluate().isEmpty; frame++) {
          await advance();
        }
        expect(target, findsOneWidget);
        final key =
            (tester.widget<ListTile>(target).key as ValueKey<String>).value;
        await tester.ensureVisible(target);
        await tester.tap(target);
        for (
          var frame = 0;
          frame < 120 && controller.switchConfirmation == null;
          frame++
        ) {
          await advance();
        }
        expect(controller.switchConfirmation, isNotNull);
        if (controller.switchConfirmation!.audioNeedsChoice) {
          await tester.ensureVisible(find.byType(CheckboxListTile).first);
          await tester.tap(find.byType(CheckboxListTile).first);
        }
        if (controller.switchConfirmation!.subtitleNeedsChoice) {
          await tester.ensureVisible(find.byType(CheckboxListTile).last);
          await tester.tap(find.byType(CheckboxListTile).last);
        }
        await advance();
        await tester.ensureVisible(find.text('从头播放'));
        await tester.tap(find.text('从头播放'));
        await tester.runAsync(
          () =>
              File(
                '${launch.protocol!.directory.path}/synthetic-menu-receipt.json',
              ).writeAsString(
                jsonEncode({
                  'targetKey': key,
                  'itemId': controller.itemId,
                  'version': controller.activeMediaSourceId,
                }),
              ),
        );
      }

      var observed = false;
      var framesAfterObservation = 0;
      final deadline = DateTime.now().add(const Duration(seconds: 60));
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
          if (!await file.exists()) return null;
          final result =
              jsonDecode(await file.readAsString()) as Map<String, dynamic>;
          await file.delete();
          return result;
        });
        final menu = await tester.runAsync(() async {
          final file = File(
            '${launch.protocol!.directory.path}/synthetic-menu.json',
          );
          if (!await file.exists()) return null;
          final result =
              jsonDecode(await file.readAsString()) as Map<String, dynamic>;
          await file.delete();
          return result;
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
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
