import 'package:flutter/widgets.dart';
import 'playback_runtime.dart';
import 'playback_models.dart';
import '../aggregation/history/history_models.dart';

import 'package:rillight/player/danmaku/dandanplay_client.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/player_window.dart';
import 'package:rillight/player/player_window_host.dart';
import 'package:rillight/player/video_backend.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/player/player_startup.dart';

typedef PlaybackObservationSink =
    Future<bool> Function(
      PlaybackReport report,
      WatchTimeline timeline,
      int sequence, {
      bool played,
    });

typedef PlaybackReportOutcomeSink =
    Future<void> Function(
      PlaybackReport report,
      int observationSequence,
      bool succeeded,
    );

typedef PlaybackSwitchDispatcher =
    Future<Map<String, dynamic>> Function(Map<String, dynamic> command);

class PlayerBindings {
  const PlayerBindings({
    this.createBackend,
    this.window,
    this.windowHost,
    this.progressInterval = const Duration(seconds: 10),
    this.controlsHideAfter = const Duration(seconds: 5),
    this.nextEpisodeCountdown = const Duration(seconds: 10),
    this.seekStep = const Duration(seconds: 10),
    this.settingsStore,
    this.snapshotStore,
    this.danmakuClient,
    this.runtime,
    this.observationSink,
    this.switchDispatcher,
    this.reportOutcomeSink,
    this.startupData,
    this.playbackLineSnapshot,
    this.verifiedPlaybackServerId,
  });

  final VideoBackend Function()? createBackend;
  final PlayerWindow? window;
  final PlayerWindowHost? windowHost;
  final PlayerSettingsStore? settingsStore;
  final PlaybackRuntime? runtime;
  final PlaybackObservationSink? observationSink;
  final PlaybackSwitchDispatcher? switchDispatcher;
  final PlaybackReportOutcomeSink? reportOutcomeSink;
  final Future<PlayerStartupData?>? startupData;

  /// Desktop playback process reads this snapshot. Null means the page
  /// resolves lines from the signed-in server list.
  final List<ServerLine>? playbackLineSnapshot;
  final String? verifiedPlaybackServerId;

  /// 会话快照存储;为 null 时 [PlayerController] 使用当前进程 pid 命名的
  /// `FilePlaybackSessionSnapshotStore`,测试注入
  /// `MemoryPlaybackSessionSnapshotStore`。
  final PlaybackSessionSnapshotStore? snapshotStore;

  /// 弹幕 API 客户端;为 null 时 [DanmakuController] 使用默认
  /// [DandanplayClient],测试注入不拨号的 fake。
  final DandanplayClient? danmakuClient;
  final Duration progressInterval;
  final Duration controlsHideAfter;
  final Duration nextEpisodeCountdown;
  final Duration seekStep;
}

class PlayerScope extends InheritedWidget {
  const PlayerScope({super.key, required this.bindings, required super.child});

  final PlayerBindings bindings;

  static PlayerBindings of(BuildContext context) {
    return context
            .dependOnInheritedWidgetOfExactType<PlayerScope>()
            ?.bindings ??
        const PlayerBindings();
  }

  @override
  bool updateShouldNotify(PlayerScope oldWidget) =>
      bindings != oldWidget.bindings;
}
