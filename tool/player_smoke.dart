// Release-mode validation wrapper: both processes enter the production main.
// This target is never used to package a public release.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/player/mpv_video_backend.dart';
import 'package:rillight/player/player_page.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/player_window_host.dart';
import 'package:window_manager/window_manager.dart';
import 'package:win32/win32.dart' as win32;
import 'package:rillight_player/rillight_player.dart';
import 'package:rillight/main.dart' as production;

Future<void> main(List<String> args) async {
  final path = Platform.environment['RILLIGHT_VALIDATION_DIRECTORY'];
  if (path == null || !Directory(path).isAbsolute) {
    throw StateError(
      'The smoke requires an isolated absolute validation directory',
    );
  }
  final root = Directory(path);
  final child = args.isNotEmpty && args.first == 'player';
  final log = File('${root.path}/${child ? 'player' : 'main'}.jsonl');
  Future<void> record(String event, [Object? value]) => log.writeAsString(
    '${jsonEncode({'at': DateTime.now().toIso8601String(), 'event': event, 'value': value})}\n',
    mode: FileMode.append,
    flush: true,
  );
  try {
    await production.main(args);
    await record('production-main', {'pid': pid, 'player': child});
    if (child) {
      PlayerPageState? page;
      await _until(() {
        page = _page();
        return page?.controller != null;
      });
      final controller = page!.controller!;
      final backend = controller.backend as MpvVideoBackend;
      Future<void> checkDisplayRequest(String phase, bool expected) async {
        if (!Platform.isWindows) return;
        var previous = 0;
        var thread = 0;
        await _until(() {
          // Windows exposes the previous calling-thread execution state via
          // this API. Temporarily clear and immediately restore it, without
          // changing the user's power plan or any other process's request.
          thread = win32.GetCurrentThreadId();
          previous = win32.SetThreadExecutionState(win32.ES_CONTINUOUS);
          if (previous == 0) {
            throw StateError('Cannot inspect thread execution state');
          }
          if (win32.SetThreadExecutionState(previous) == 0) {
            throw StateError('Cannot restore thread execution state');
          }
          return (previous & win32.ES_DISPLAY_REQUIRED != 0) == expected;
        }, timeout: const Duration(seconds: 3));
        await record('display-power-request', {
          'phase': phase,
          'pid': pid,
          'threadId': thread,
          'previousFlags': '0x${previous.toRadixString(16)}',
          'displayRequired': previous & win32.ES_DISPLAY_REQUIRED != 0,
          'method':
              'SetThreadExecutionState previous UI-thread flags; restored immediately',
        });
      }

      Future<void> captureCoreSubtitle(String label) async {
        // Let the selected subtitle decoder receive packets and render within
        // the synthetic fixture's 0–8/12 second subtitle interval.
        await Future<void>.delayed(const Duration(milliseconds: 350));
        final view = _find<MpvVideoView>(
          (element) => element.widget is MpvVideoView
              ? element.widget as MpvVideoView
              : null,
        );
        if (view == null) throw StateError('Native video view is not mounted');
        final target = '${root.path}/$label-core.png';
        await view.player.command(['screenshot-to-file', target, 'subtitles']);
        final properties = <String, Object?>{};
        for (final key in [
          'time-pos',
          'sid',
          'sub-start',
          'sub-end',
          'sub-text',
        ]) {
          try {
            properties[key] = await view.player.getProperty(key);
          } catch (_) {}
        }
        await record('core-subtitle-screenshot', {
          'label': label,
          'file': target,
          ...properties,
        });
      }

      final loadWatch = Stopwatch()..start();
      final hold = Duration(
        seconds:
            int.tryParse(
              Platform.environment['RILLIGHT_SMOKE_HOLD_SECONDS'] ?? '',
            ) ??
            0,
      );
      Future<void> loaded(String name) async {
        await _until(
          () => !controller.loading,
          timeout: const Duration(seconds: 60),
        );
        if (controller.error != null) {
          throw StateError(
            '$name failed: ${controller.error}; ${backend.lastFailure}; ${controller.loadFailure}',
          );
        }
        await _until(
          () =>
              controller.isPlaying &&
              controller.position > const Duration(milliseconds: 100),
        );
        await record(name, {
          ...await backend.diagnostics(),
          'openMs': loadWatch.elapsedMilliseconds,
          'rssBytes': ProcessInfo.currentRss,
          'positionMs': controller.position.inMilliseconds,
          'rate': controller.playbackRate,
        });
        if (hold > Duration.zero) {
          await controller.togglePlay();
          await Future<void>.delayed(hold);
          await controller.togglePlay();
        }
      }

      await loaded('baseline-loaded');
      await checkDisplayRequest('playing', true);
      if (controller.position < const Duration(seconds: 2)) {
        throw StateError('Server resume was not applied');
      }
      await record('server-resume', controller.position.inMilliseconds);
      await controller.setVolume(15);
      await controller.togglePlay();
      await _until(() => !controller.isPlaying);
      await checkDisplayRequest('paused', false);
      await controller.togglePlay();
      await _until(() => controller.isPlaying);
      await checkDisplayRequest('resumed', true);
      await controller.seekTo(const Duration(seconds: 2));
      await controller.setRate(1.25);
      await windowManager.setSize(const Size(960, 540));
      await controller.toggleFullScreen();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await controller.toggleFullScreen();
      await record('controls', {
        'position': controller.position.inMilliseconds,
        'playing': controller.isPlaying,
      });
      for (final item in [
        'tracks',
        'hls',
        '1080p60',
        '4k-hevc',
        'av1',
        'vp9',
      ]) {
        if (item == '1080p60') await controller.setRate(1);
        loadWatch.reset();
        await controller.playEpisode(
          EmbyItem.fromJson({'Id': item, 'Type': 'Movie', 'Name': item}),
        );
        await loaded('$item-loaded');
        if (item == 'tracks') {
          await controller.setAudio(2);
          await controller.setSubtitle(3);
          if (controller.trackFailure != null) {
            throw StateError('PGS selection failed');
          }
          await record('pgs', await backend.diagnostics());
          await captureCoreSubtitle('pgs');
          await Future<void>.delayed(const Duration(seconds: 2));
          await controller.setSubtitle(4);
          if (controller.trackFailure != null) {
            throw StateError('ASS selection failed');
          }
          await record('ass', await backend.diagnostics());
          await captureCoreSubtitle('ass');
          for (final index in [5, 6, 7]) {
            await controller.setSubtitle(index);
            if (controller.trackFailure != null) {
              throw StateError('External subtitle $index failed');
            }
            await record('subtitle-$index', await backend.diagnostics());
            await captureCoreSubtitle({5: 'srt', 6: 'vtt', 7: 'ssa'}[index]!);
          }
          await controller.setSubtitle(null);
          if (controller.subtitleStreamIndex != null) {
            throw StateError('Subtitle off failed');
          }
          await record('subtitles-off');
        }
        await Future<void>.delayed(const Duration(seconds: 3));
        await record('$item-sampled', {
          ...await backend.diagnostics(),
          'rssBytes': ProcessInfo.currentRss,
          'rate': controller.playbackRate,
        });
        // Linux Xvfb checks the actual child-window pixels after publication.
        // Keep the source stable for that bounded presentation check without
        // changing the existing three-second performance sampling interval.
        if (Platform.isLinux) {
          await Future<void>.delayed(const Duration(seconds: 3));
        }
      }
      await controller.playEpisode(
        EmbyItem.fromJson({
          'Id': 'baseline',
          'Type': 'Movie',
          'Name': 'baseline',
        }),
      );
      await loaded('reopened-baseline');
      final fixture =
          jsonDecode(await File('${root.path}/server.json').readAsString())
              as Map;
      final source = Uri.parse(fixture['url'] as String);
      final networkClient = HttpClient();
      Future<void> network(bool offline) async {
        final request = await networkClient.postUrl(
          source.resolve('/validation/network'),
        );
        request.headers.contentType = ContentType.json;
        final body = jsonEncode({'offline': offline});
        request.contentLength = utf8.encode(body).length;
        request.write(body);
        await (await request.close()).drain<void>();
      }

      try {
        // A resumed position and pause=no can arrive before the audio clock
        // starts. Establish actual progression before measuring an outage;
        // otherwise Linux's output startup is counted as a network stall.
        final resumedPosition = controller.position;
        await _until(
          () =>
              controller.isPlaying &&
              controller.position - resumedPosition >=
                  const Duration(milliseconds: 500),
        );
        await _until(
          () =>
              backend.buffer - controller.position > const Duration(seconds: 3),
        );
        await network(true);
        final probe = await (await networkClient.getUrl(
          source.resolve('/media/baseline.mp4'),
        )).close();
        final status = probe.statusCode;
        await probe.drain<void>();
        if (status != 503) throw StateError('Synthetic outage was not active');
        final before = controller.position;
        await Future<void>.delayed(const Duration(milliseconds: 900));
        final advanced = controller.position - before;
        await record('source-outage-progress', {
          'sourceStatus': status,
          'beforeMs': before.inMilliseconds,
          'afterMs': controller.position.inMilliseconds,
          'advancedMs': advanced.inMilliseconds,
          'playing': controller.isPlaying,
          'bufferMs': backend.buffer.inMilliseconds,
        });
        if (!controller.isPlaying ||
            advanced < const Duration(milliseconds: 500)) {
          throw StateError('Buffered playback did not continue during outage');
        }
        await controller.togglePlay();
        await _until(() => !controller.isPlaying);
        final paused = controller.position;
        await Future<void>.delayed(const Duration(milliseconds: 350));
        if (controller.isPlaying ||
            (controller.position - paused).abs() >
                const Duration(milliseconds: 100)) {
          throw StateError('Cache recovery overrode user pause');
        }
        await record('buffered-source-outage', {
          'sourceStatus': status,
          'advancedMs': advanced.inMilliseconds,
          'pausePreserved': true,
          ...await backend.diagnostics(),
        });
        await network(false);
        await controller.togglePlay();
      } finally {
        await network(false);
        networkClient.close(force: true);
      }
      final seekWatch = Stopwatch()..start();
      await controller.seekTo(const Duration(seconds: 3));
      await _until(
        () =>
            controller.position > const Duration(milliseconds: 3100) &&
            controller.isPlaying,
      );
      await record('seek-resume', {
        'positionMs': controller.position.inMilliseconds,
        'positionAdvanceMs': seekWatch.elapsedMilliseconds,
      });
      await controller.seekTo(
        controller.duration - const Duration(milliseconds: 500),
      );
      await _until(() => controller.playbackEnded);
      await checkDisplayRequest('eof', false);
      await controller.replay();
      await loaded('replayed-for-power-check');
      await checkDisplayRequest('replayed', true);
      await controller.shutdownSession();
      await record('cache-after-stop', await backend.diagnostics());
      await checkDisplayRequest('stopped', false);
      await controller.replay();
      await loaded('restarted-for-power-check');
      await checkDisplayRequest('restarted', true);
      await controller.playEpisode(
        EmbyItem.fromJson({'Id': 'broken', 'Type': 'Movie', 'Name': 'broken'}),
      );
      if (controller.error == null || controller.isPlaying) {
        throw StateError('Failed open did not stop');
      }
      await record('failed-open-stopped');
      await checkDisplayRequest('failed-open', false);
      await controller.playEpisode(
        EmbyItem.fromJson({
          'Id': 'baseline',
          'Type': 'Movie',
          'Name': 'baseline',
        }),
      );
      await loaded('dispose-power-check');
      await checkDisplayRequest('before-dispose', true);
      await controller.disposeAsync();
      await checkDisplayRequest('disposed', false);
      await controller.disposeAsync();
      await checkDisplayRequest('disposed-again', false);
      await record('disposed', await backend.diagnostics());
      await File(
        '${root.path}/player-result.json',
      ).writeAsString(jsonEncode({'passed': true}));
      // Let the main host exercise its normal close/exit confirmation path.
    } else {
      RillightApp? app;
      await _until(() {
        app = _app();
        return app != null;
      });
      final config =
          jsonDecode(await File('${root.path}/server.json').readAsString())
              as Map;
      await app!.auth.connect(
        address: config['url'] as String,
        username: 'validation',
        password: 'synthetic-only',
        userAgent: 'Rillight-Validation',
      );
      if (!app!.auth.isLoggedIn) throw StateError('Synthetic login failed');
      await app!.windowHost.open(const PlayerOpenRequest(itemId: 'baseline'));
      await record('opened-through-production-host');
      final settingsWrites = () async {
        final settings = await openPlayerSettingsStore();
        for (var index = 0; index < 20; index++) {
          await settings.write(PlayerSettings(diskCacheLimitMiB: 512 + index));
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }();
      final result = File('${root.path}/player-result.json');
      await _until(
        () => result.existsSync(),
        timeout: const Duration(minutes: 3),
      );
      final outcome = jsonDecode(await result.readAsString()) as Map;
      if (outcome['passed'] != true) {
        throw StateError('Player validation failed: ${outcome['error']}');
      }
      await app!.windowHost.close();
      await settingsWrites;
      final settings = await (await openPlayerSettingsStore()).read();
      if (settings.diskCacheLimitMiB != 531 ||
          settings.volume != 15 ||
          settings.playbackRate != 1) {
        throw StateError('Cross-process settings merge failed');
      }
      await record('cross-process-settings', {
        'volume': settings.volume,
        'rate': settings.playbackRate,
        'cacheMiB': settings.diskCacheLimitMiB,
      });
      await record('child-closed-main-alive', app!.windowHost.current == null);
      await File(
        '${root.path}/result.json',
      ).writeAsString(jsonEncode({'passed': true}));
      exit(0);
    }
  } catch (error, stack) {
    await record('failure', {
      'error': error.toString(),
      'stack': stack.toString(),
    });
    await File(
      '${root.path}/${child ? 'player-result' : 'result'}.json',
    ).writeAsString(jsonEncode({'passed': false, 'error': error.toString()}));
    exit(1);
  }
}

Future<void> _until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Playback validation condition');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

T? _find<T>(T? Function(Element) pick) {
  T? found;
  void visit(Element element) {
    found ??= pick(element);
    if (found == null) element.visitChildren(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildren(visit);
  return found;
}

RillightApp? _app() => _find(
  (element) =>
      element.widget is RillightApp ? element.widget as RillightApp : null,
);
PlayerPageState? _page() => _find(
  (element) => element is StatefulElement && element.state is PlayerPageState
      ? element.state as PlayerPageState
      : null,
);
