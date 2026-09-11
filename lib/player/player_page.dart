import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/widgets/app_error_view.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/device_profile.dart';
import 'package:rillight/home/catalog_failure.dart';
import 'package:rillight/player/media_kit_video_backend.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_controller.dart';
import 'package:rillight/player/player_keys.dart';
import 'package:rillight/player/player_window.dart';
import 'package:rillight/player/video_backend.dart';

class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key, required this.itemId, this.autoResume = false});

  final String itemId;
  final bool autoResume;

  @override
  State<PlayerPage> createState() => PlayerPageState();
}

class PlayerPageState extends State<PlayerPage> {
  PlayerController? controller;
  bool _dragSeeking = false;
  double _dragValue = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (controller != null) {
      return;
    }
    final bindings = PlayerScope.of(context);
    final created = PlayerController(
      client: AuthScope.of(context).client,
      itemId: widget.itemId,
      backend: _createBackend(bindings),
      window: bindings.window ?? WindowManagerPlayerWindow(),
      autoResume: widget.autoResume,
      progressInterval: bindings.progressInterval,
      controlsHideAfter: bindings.controlsHideAfter,
      nextEpisodeCountdown: bindings.nextEpisodeCountdown,
      seekStep: bindings.seekStep,
      onClose: _leave,
      onOpenItem: (id) {
        if (!mounted) {
          return;
        }
        context.pushReplacement(AppRoutes.play(id));
      },
    );
    controller = created;
    created.addListener(_onController);
    unawaited(created.start());
  }

  @override
  void dispose() {
    final current = controller;
    current?.removeListener(_onController);
    current?.dispose();
    super.dispose();
  }

  void _onController() {
    if (mounted) {
      setState(() {});
    }
  }

  void _leave() {
    if (!mounted) {
      return;
    }
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRoutes.home);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final current = controller;
    if (current == null) {
      return const ColoredBox(color: Colors.black);
    }
    return Focus(
      autofocus: true,
      descendantsAreFocusable: false,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) {
          return KeyEventResult.ignored;
        }
        if (event.logicalKey == LogicalKeyboardKey.space) {
          current.togglePlay();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
          current.seekRelative(-current.seekStep);
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
          current.seekRelative(current.seekStep);
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.keyF) {
          current.toggleFullScreen();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.escape) {
          current.onEscape();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: PopScope(
        onPopInvokedWithResult: (didPop, result) {
          if (didPop) {
            unawaited(current.shutdownSession());
          }
        },
        child: Scaffold(
          backgroundColor: Colors.black,
          body: MouseRegion(
            onHover: (_) => current.onUserActivity(),
            child: GestureDetector(
              onTap: current.onUserActivity,
              behavior: HitTestBehavior.opaque,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  current.backend.buildView(key: PlayerKeys.surface),
                  if (current.loading)
                    Center(
                      child: Text(
                        l10n.playerLoading,
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                  if (_errorText(l10n, current) != null)
                    AppErrorView(
                      message: _errorText(l10n, current)!,
                      onRetry: current.start,
                    ),
                  if (current.showResumePrompt)
                    _ResumePrompt(controller: current),
                  if (current.controlsVisible &&
                      !current.loading &&
                      current.resolved != null &&
                      !current.showResumePrompt &&
                      current.error == null)
                    _ControlsBar(
                      controller: current,
                      dragging: _dragSeeking,
                      dragValue: _dragValue,
                      onDragStart: (value) {
                        setState(() {
                          _dragSeeking = true;
                          _dragValue = value;
                        });
                      },
                      onDragUpdate: (value) {
                        setState(() => _dragValue = value);
                      },
                      onDragEnd: (value) {
                        setState(() => _dragSeeking = false);
                        final duration = current.duration;
                        if (duration <= Duration.zero) {
                          return;
                        }
                        unawaited(
                          current.seekTo(
                            Duration(
                              milliseconds: (duration.inMilliseconds * value)
                                  .round(),
                            ),
                          ),
                        );
                      },
                    ),
                  if (current.nextEpisode != null)
                    _NextEpisodeBanner(controller: current),
                  if (current.disconnected)
                    _Banner(
                      key: PlayerKeys.disconnect,
                      text: l10n.playbackDisconnected,
                    ),
                  if (current.progressSyncFailed && !current.disconnected)
                    _Banner(
                      key: PlayerKeys.progressSyncFailed,
                      text: l10n.progressSyncFailed,
                    ),
                  if (current.subtitleNotice != null)
                    _Banner(
                      key: PlayerKeys.subtitleNotice,
                      text:
                          current.subtitleNotice ==
                              SubtitleNoticeKind.bitmapFailed
                          ? l10n.subtitleBitmapFailed
                          : l10n.subtitleBitmapBurnIn,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String? _errorText(AppLocalizations l10n, PlayerController current) {
    switch (current.error) {
      case PlayerErrorKind.notPlayable:
        return l10n.itemUnavailable;
      case PlayerErrorKind.noStream:
        return l10n.noPlayableStream;
      case PlayerErrorKind.load:
        return current.loadFailure == null
            ? l10n.playbackFailed
            : catalogFailureMessage(l10n, current.loadFailure!);
      case null:
        return null;
    }
  }
}

class _ResumePrompt extends StatelessWidget {
  const _ResumePrompt({required this.controller});

  final PlayerController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Center(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                l10n.resumePrompt,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FilledButton(
                    key: PlayerKeys.resumeContinue,
                    onPressed: () =>
                        controller.chooseResume(fromBeginning: false),
                    child: Text(l10n.resumePlay),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton(
                    key: PlayerKeys.resumeFromStart,
                    onPressed: () =>
                        controller.chooseResume(fromBeginning: true),
                    child: Text(l10n.playFromStart),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NextEpisodeBanner extends StatelessWidget {
  const _NextEpisodeBanner({required this.controller});

  final PlayerController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final offer = controller.nextEpisode!;
    final seconds = offer.remaining?.inSeconds;
    return Positioned(
      right: 24,
      bottom: 96,
      child: Material(
        key: PlayerKeys.nextEpisode,
        color: Colors.black.withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                seconds == null
                    ? l10n.playNextEpisode
                    : l10n.nextEpisodeIn(seconds),
                style: const TextStyle(color: Colors.white),
              ),
              Text(
                offer.item.displayName,
                style: const TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  if (seconds != null)
                    TextButton(
                      key: PlayerKeys.nextEpisodeCancel,
                      onPressed: controller.cancelNextEpisode,
                      child: Text(l10n.cancelNextEpisode),
                    ),
                  TextButton(
                    key: PlayerKeys.nextEpisodePlay,
                    onPressed: controller.playNextEpisode,
                    child: Text(l10n.playNextEpisode),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 24,
      right: 24,
      top: 24,
      child: Material(
        color: Colors.black.withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(text, style: const TextStyle(color: Colors.white)),
        ),
      ),
    );
  }
}

class _ControlsBar extends StatelessWidget {
  const _ControlsBar({
    required this.controller,
    required this.dragging,
    required this.dragValue,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  final PlayerController controller;
  final bool dragging;
  final double dragValue;
  final ValueChanged<double> onDragStart;
  final ValueChanged<double> onDragUpdate;
  final ValueChanged<double> onDragEnd;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final durationMs = controller.duration.inMilliseconds;
    final value = dragging
        ? dragValue
        : (durationMs <= 0
              ? 0.0
              : (controller.position.inMilliseconds / durationMs).clamp(
                  0.0,
                  1.0,
                ));
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Material(
        key: PlayerKeys.controls,
        color: Colors.black.withValues(alpha: 0.72),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Slider(
                key: PlayerKeys.seekBar,
                value: value,
                onChanged: durationMs <= 0
                    ? null
                    : (next) {
                        if (!dragging) {
                          onDragStart(next);
                        } else {
                          onDragUpdate(next);
                        }
                      },
                onChangeEnd: durationMs <= 0 ? null : onDragEnd,
              ),
              Row(
                children: [
                  IconButton(
                    key: PlayerKeys.playPause,
                    tooltip: controller.isPlaying ? l10n.pause : l10n.play,
                    color: Colors.white,
                    onPressed: controller.togglePlay,
                    icon: Icon(
                      controller.isPlaying ? Icons.pause : Icons.play_arrow,
                    ),
                  ),
                  Text(
                    '${_clock(controller.position)} / ${_clock(controller.duration)}',
                    style: const TextStyle(color: Colors.white),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    key: PlayerKeys.playMethod,
                    controller.isTranscode ? l10n.transcode : l10n.directPlay,
                    style: TextStyle(
                      color: controller.isTranscode
                          ? Colors.orangeAccent
                          : Colors.lightGreenAccent,
                    ),
                  ),
                  if (controller.isTranscode) ...[
                    const SizedBox(width: 12),
                    DropdownButton<int>(
                      key: PlayerKeys.quality,
                      dropdownColor: Colors.black87,
                      value:
                          kTranscodeBitrates.contains(
                            controller.maxStreamingBitrate,
                          )
                          ? controller.maxStreamingBitrate
                          : kTranscodeBitrates.first,
                      items: [
                        DropdownMenuItem(
                          value: kTranscodeBitrates.first,
                          child: Text(
                            l10n.qualityAuto,
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                        for (final bitrate in kTranscodeBitrates.skip(1))
                          DropdownMenuItem(
                            value: bitrate,
                            child: Text(
                              l10n.qualityMbps(bitrate ~/ 1000000),
                              style: const TextStyle(color: Colors.white),
                            ),
                          ),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          controller.setMaxBitrate(value);
                        }
                      },
                    ),
                  ],
                  const Spacer(),
                  if (controller.audioTracks.length > 1)
                    DropdownButton<int>(
                      key: PlayerKeys.audio,
                      dropdownColor: Colors.black87,
                      value: controller.audioStreamIndex,
                      hint: Text(
                        l10n.audioTrack,
                        style: const TextStyle(color: Colors.white),
                      ),
                      items: [
                        for (final track in controller.audioTracks)
                          DropdownMenuItem(
                            value: track.index,
                            child: Text(
                              track.label,
                              style: const TextStyle(color: Colors.white),
                            ),
                          ),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          controller.setAudio(value);
                        }
                      },
                    ),
                  if (controller.subtitleTracks.isNotEmpty)
                    DropdownButton<int?>(
                      key: PlayerKeys.subtitle,
                      dropdownColor: Colors.black87,
                      value: controller.subtitleStreamIndex,
                      hint: Text(
                        l10n.subtitleTrack,
                        style: const TextStyle(color: Colors.white),
                      ),
                      items: [
                        DropdownMenuItem(
                          value: null,
                          child: Text(
                            l10n.subtitleOff,
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                        for (final track in controller.subtitleTracks)
                          DropdownMenuItem(
                            value: track.index,
                            child: Text(
                              track.label,
                              style: const TextStyle(color: Colors.white),
                            ),
                          ),
                      ],
                      onChanged: controller.setSubtitle,
                    ),
                  IconButton(
                    key: PlayerKeys.fullscreen,
                    tooltip: controller.isFullScreen
                        ? l10n.exitFullscreen
                        : l10n.fullscreen,
                    color: Colors.white,
                    onPressed: controller.toggleFullScreen,
                    icon: Icon(
                      controller.isFullScreen
                          ? Icons.fullscreen_exit
                          : Icons.fullscreen,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

VideoBackend _createBackend(PlayerBindings bindings) {
  final create = bindings.createBackend;
  if (create != null) {
    return create();
  }
  assert(() {
    final binding = WidgetsBinding.instance.runtimeType.toString();
    if (binding.contains('TestWidgetsFlutterBinding')) {
      throw FlutterError(
        'Player widget tests must inject PlayerBindings.createBackend',
      );
    }
    return true;
  }());
  return MediaKitVideoBackend();
}

String _clock(Duration duration) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  if (hours > 0) {
    return '$hours:$minutes:$seconds';
  }
  return '$minutes:$seconds';
}
