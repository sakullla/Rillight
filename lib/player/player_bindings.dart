import 'package:flutter/widgets.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/player_window.dart';
import 'package:rillight/player/player_window_host.dart';
import 'package:rillight/player/video_backend.dart';

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
  });

  final VideoBackend Function()? createBackend;
  final PlayerWindow? window;
  final PlayerWindowHost? windowHost;
  final PlayerSettingsStore? settingsStore;

  /// 会话快照存储;为 null 时 [PlayerController] 使用当前进程 pid 命名的
  /// `FilePlaybackSessionSnapshotStore`,测试注入
  /// `MemoryPlaybackSessionSnapshotStore`。
  final PlaybackSessionSnapshotStore? snapshotStore;
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
