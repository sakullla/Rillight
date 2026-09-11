import 'package:flutter/widgets.dart';
import 'package:rillight/player/player_window.dart';
import 'package:rillight/player/video_backend.dart';

class PlayerBindings {
  const PlayerBindings({
    this.createBackend,
    this.window,
    this.progressInterval = const Duration(seconds: 10),
    this.controlsHideAfter = const Duration(seconds: 3),
    this.nextEpisodeCountdown = const Duration(seconds: 10),
    this.seekStep = const Duration(seconds: 10),
  });

  final VideoBackend Function()? createBackend;
  final PlayerWindow? window;
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
