// Release-mode validation wrapper for the real-window two-slot subtitle
// check. This target is never used to package a public release.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/emby/emby_codec.dart';
import 'package:rillight/player/desktop_player_window.dart';
import 'package:rillight/player/player_page.dart';
import 'package:rillight/player/rillight_video_backend.dart';
import 'package:rillight/player/player_window_host.dart';
import 'package:rillight/main.dart' as production;

Future<void> main(List<String> args) async {
  final path = Platform.environment['RILLIGHT_VALIDATION_DIRECTORY'];
  if (path == null || !Directory(path).isAbsolute) {
    throw StateError(
      'The subtitle window check requires an isolated absolute '
      'validation directory',
    );
  }
  final root = Directory(path);
  final child = args.isNotEmpty && args.first == 'player';
  final log = File('${root.path}/${child ? 'player' : 'main'}.jsonl');
  var pendingLog = Future<void>.value();
  Future<void> record(String event, [Object? value]) {
    final line =
        '${jsonEncode({'at': DateTime.now().toIso8601String(), 'event': event, 'value': value})}\n';
    pendingLog = pendingLog.then(
      (_) => log.writeAsString(line, mode: FileMode.append, flush: true),
    );
    return pendingLog;
  }

  /// 每个阶段写 ready 文件并等待外部截图回执,保证真实窗口像素证据
  /// 与核心状态一一对应。
  Future<void> phase(String name) async {
    await File('${root.path}/phase-$name.ready')
        .writeAsString('1', flush: true);
    final ack = File('${root.path}/phase-$name.ack');
    final deadline = DateTime.now().add(const Duration(seconds: 120));
    while (!ack.existsSync()) {
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('Window capture acknowledgement for $name');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

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
      final backend = controller.backend;
      await record('controller-ready', {'itemId': controller.itemId});

      Future<void> loaded(String name) async {
        await _until(
          () => !controller.loading,
          timeout: const Duration(seconds: 60),
        );
        if (controller.error != null) {
          throw StateError(
            '$name failed: ${controller.error}; ${controller.disconnectDetail}',
          );
        }
        await _until(() => controller.isPlaying);
        await record(name, {'positionMs': controller.position.inMilliseconds});
      }

      /// 字幕 cue 覆盖 0.5–10.5 s:每阶段前把播放位置拉回 cue 区间并等
      /// 播放真实恢复,避免截图落在 seek 恢复期的加载封面或冻结帧上。
      Future<void> holdForPhase(String name) async {
        if (controller.position < const Duration(milliseconds: 500) ||
            controller.position > const Duration(seconds: 9)) {
          await controller.seekTo(const Duration(seconds: 2));
        }
        await _until(
          () => !controller.loading && controller.isPlaying,
          timeout: const Duration(seconds: 30),
        );
        await Future<void>.delayed(const Duration(milliseconds: 700));
        await phase(name);
      }

      await controller.playEpisode(
        decodeEmbyMediaItem({
          'Id': 'subtitle-window',
          'Type': 'Movie',
          'Name': 'subtitle-window',
        }),
      );
      await loaded('subtitle-window-loaded');

      // 阶段一:两槽都关闭的对照画面。
      await controller.setSubtitle(null);
      await controller.setSecondarySubtitle(null);
      await Future<void>.delayed(const Duration(milliseconds: 800));
      await holdForPhase('subtitles-off');

      // 阶段二:主字幕选择多行 SRT 外挂轨(显式 2/3 行,CRLF 原文)。
      // 控制器提交发生在核心槽位确认快照之后,提交即核心确认。
      await controller.setSubtitle(2).timeout(const Duration(seconds: 20));
      if (controller.trackFailure != null ||
          controller.subtitleStreamIndex != 2) {
        throw StateError('Primary multiline SRT was not confirmed');
      }
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      await holdForPhase('primary-multiline');
      await record('primary-multiline-state', {
        'controllerSubtitleIndex': controller.subtitleStreamIndex,
        'controllerSecondaryIndex': controller.secondarySubtitleStreamIndex,
        'backendSelectedSubtitleIndex': backend.selectedSubtitleIndex,
        ...await _backendDiagnostics(backend),
      });

      // 阶段三:次字幕选择 \N 硬换行 ASS 外挂轨,两槽同时渲染。
      await controller
          .setSecondarySubtitle(3)
          .timeout(const Duration(seconds: 20));
      if (controller.trackFailure != null ||
          controller.secondarySubtitleStreamIndex != 3) {
        throw StateError('Secondary ASS subtitle was not confirmed');
      }
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      await holdForPhase('dual-subtitle');
      await record('dual-subtitle-state', {
        'controllerSubtitleIndex': controller.subtitleStreamIndex,
        'controllerSecondaryIndex': controller.secondarySubtitleStreamIndex,
        'backendSelectedSubtitleIndex': backend.selectedSubtitleIndex,
        'backendSelectedSecondaryIndex': backend.selectedSecondarySubtitleIndex,
        ...await _backendDiagnostics(backend),
      });
      if (controller.subtitleStreamIndex != 2 ||
          controller.secondarySubtitleStreamIndex != 3 ||
          backend.selectedSecondarySubtitleIndex != 3) {
        throw StateError('Core did not confirm both subtitle slots');
      }

      // 阶段四:回到关闭,给对照差异一个反向样本。
      await controller.setSecondarySubtitle(null);
      await controller.setSubtitle(null);
      await Future<void>.delayed(const Duration(milliseconds: 800));
      await holdForPhase('subtitles-off-again');

      await File('${root.path}/player-result.json')
          .writeAsString(jsonEncode({'passed': true}));
    } else {
      RillightApp? app;
      await _until(() {
        app = _app();
        return app != null;
      });
      final config = jsonDecode(
        await File('${root.path}/server.json').readAsString(),
      ) as Map;
      await app!.auth.connect(
        address: config['url'] as String,
        username: 'validation',
        password: 'synthetic-only',
        userAgent: 'Rillight-Validation',
      );
      if (!app!.auth.isLoggedIn) throw StateError('Synthetic login failed');
      final host = app!.windowHost;
      if (host is DesktopPlayerWindowHost) await host.prepare();
      await app!.windowHost.open(
        const PlayerOpenRequest(itemId: 'subtitle-window'),
      );
      await record('opened-through-production-host');
      final result = File('${root.path}/player-result.json');
      await _until(
        () => result.existsSync(),
        timeout: const Duration(minutes: 6),
      );
      final outcome = jsonDecode(await result.readAsString()) as Map;
      if (outcome['passed'] != true) {
        throw StateError(
          'Subtitle window validation failed: ${outcome['error']}',
        );
      }
      await app!.windowHost.close();
      await record('child-closed-main-alive', app!.windowHost.current == null);
      await File('${root.path}/result.json')
          .writeAsString(jsonEncode({'passed': true}));
      exit(0);
    }
  } catch (error, stack) {
    try {
      final current = _page()?.controller;
      if (current != null) {
        await record('failure-state', {
          'itemId': current.itemId,
          'playing': current.isPlaying,
          'loading': current.loading,
          'error': current.error?.name,
          'trackFailure': current.trackFailure,
          'subtitleIndex': current.subtitleStreamIndex,
          'secondaryIndex': current.secondarySubtitleStreamIndex,
        });
      }
    } catch (_) {}
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

Future<Map<String, Object?>> _backendDiagnostics(dynamic backend) async {
  if (backend is RillightVideoBackend) {
    try {
      return await backend.diagnostics().timeout(const Duration(seconds: 8));
    } catch (_) {
      return const {};
    }
  }
  return const {};
}

Future<void> _until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Subtitle window validation condition');
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
