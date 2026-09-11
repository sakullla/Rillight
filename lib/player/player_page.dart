import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/widgets/app_error_view.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/device_profile.dart';
import 'package:rillight/home/catalog_failure.dart';
import 'package:rillight/player/media_kit_video_backend.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_controller.dart';
import 'package:rillight/player/player_keys.dart';
import 'package:rillight/player/player_window.dart';
import 'package:rillight/player/player_window_host.dart';
import 'package:rillight/player/video_backend.dart';

class PlayerPage extends StatefulWidget {
  const PlayerPage({
    super.key,
    required this.itemId,
    this.autoResume = false,
    this.mediaSourceId,
    this.audioStreamIndex,
    this.subtitleStreamIndex,
    this.startTimeTicks,
    this.onClosed,
    this.onOpenItem,
  });

  final String itemId;
  final bool autoResume;
  final String? mediaSourceId;
  final int? audioStreamIndex;
  final int? subtitleStreamIndex;
  final int? startTimeTicks;
  final VoidCallback? onClosed;
  final ValueChanged<String>? onOpenItem;

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
      preferredMediaSourceId: widget.mediaSourceId,
      preferredAudioStreamIndex: widget.audioStreamIndex,
      preferredSubtitleStreamIndex: widget.subtitleStreamIndex,
      startTimeTicks: widget.startTimeTicks,
      progressInterval: bindings.progressInterval,
      controlsHideAfter: bindings.controlsHideAfter,
      nextEpisodeCountdown: bindings.nextEpisodeCountdown,
      seekStep: bindings.seekStep,
      onClose: _leave,
      onOpenItem: _openItem,
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

  void _openItem(String itemId) {
    if (!mounted) {
      return;
    }
    final onOpenItem = widget.onOpenItem;
    if (onOpenItem != null) {
      onOpenItem(itemId);
      return;
    }
    final host = PlayerWindowScope.maybeOf(context);
    if (host != null) {
      unawaited(host.open(PlayerOpenRequest(itemId: itemId)));
    }
  }

  void _leave() {
    if (!mounted) {
      return;
    }
    final onClosed = widget.onClosed;
    if (onClosed != null) {
      onClosed();
      return;
    }
    final host = PlayerWindowScope.maybeOf(context);
    if (host != null) {
      unawaited(host.close());
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
            cursor:
                (!current.controlsVisible &&
                    !current.showResumePrompt &&
                    current.nextEpisode == null)
                ? SystemMouseCursors.none
                : MouseCursor.defer,
            child: Stack(
              fit: StackFit.expand,
              children: [
                IgnorePointer(child: current.backend.buildView()),
                Positioned.fill(
                  child: GestureDetector(
                    key: PlayerKeys.surface,
                    behavior: HitTestBehavior.opaque,
                    onTap: current.toggleControls,
                  ),
                ),
                if (current.loading)
                  Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(
                          width: 44,
                          height: 44,
                          child: CircularProgressIndicator(strokeWidth: 3),
                        ),
                        const SizedBox(height: AppSpacing.md),
                        Text(
                          l10n.playerLoading,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: Colors.white70),
                        ),
                      ],
                    ),
                  ),
                if (_errorText(l10n, current) != null)
                  AppErrorView(
                    message: _errorText(l10n, current)!,
                    onRetry: current.start,
                  ),
                if (current.showResumePrompt)
                  _ResumePrompt(controller: current),
                if (!current.loading &&
                    current.resolved != null &&
                    !current.showResumePrompt &&
                    current.error == null)
                  _ControlsBar(
                    controller: current,
                    visible: current.controlsVisible,
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
                if (current.disconnected && !current.isPlaying)
                  _Banner(
                    key: PlayerKeys.disconnect,
                    text: current.disconnectDetail ?? l10n.playbackDisconnected,
                  ),
                if (current.progressSyncFailed &&
                    !(current.disconnected && !current.isPlaying))
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
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Material(
          color: scheme.surfaceContainerHigh.withValues(alpha: 0.96),
          borderRadius: BorderRadius.circular(AppRadii.xl),
          elevation: 12,
          shadowColor: Colors.black.withValues(alpha: 0.5),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.xxl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.play_circle_outline_rounded,
                  size: 40,
                  color: scheme.primary,
                ),
                const SizedBox(height: AppSpacing.md),
                Text(
                  l10n.resumePrompt,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleLarge,
                ),
                const SizedBox(height: AppSpacing.xl),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FilledButton.icon(
                      key: PlayerKeys.resumeContinue,
                      onPressed: () =>
                          controller.chooseResume(fromBeginning: false),
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: Text(l10n.resumePlay),
                    ),
                    const SizedBox(width: AppSpacing.sm),
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
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final offer = controller.nextEpisode!;
    final seconds = offer.remaining?.inSeconds;
    return Positioned(
      right: AppSpacing.xl,
      bottom: 112,
      child: Material(
        key: PlayerKeys.nextEpisode,
        color: scheme.surfaceContainerHigh.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(AppRadii.lg),
        elevation: 12,
        shadowColor: Colors.black.withValues(alpha: 0.5),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.skip_next_rounded,
                    size: 20,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  Text(
                    seconds == null
                        ? l10n.playNextEpisode
                        : l10n.nextEpisodeIn(seconds),
                    style: theme.textTheme.titleMedium,
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.xxs),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 280),
                child: Text(
                  offer.item.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (seconds != null)
                    TextButton(
                      key: PlayerKeys.nextEpisodeCancel,
                      onPressed: controller.cancelNextEpisode,
                      child: Text(l10n.cancelNextEpisode),
                    ),
                  FilledButton(
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
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Positioned(
      left: 0,
      right: 0,
      top: AppSpacing.xl,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Material(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(AppRadii.md),
            elevation: 8,
            shadowColor: Colors.black.withValues(alpha: 0.45),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.sm,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    size: 18,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  Flexible(
                    child: Text(text, style: theme.textTheme.bodyMedium),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ControlsBar extends StatelessWidget {
  const _ControlsBar({
    required this.controller,
    required this.visible,
    required this.dragging,
    required this.dragValue,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  final PlayerController controller;
  final bool visible;
  final bool dragging;
  final double dragValue;
  final ValueChanged<double> onDragStart;
  final ValueChanged<double> onDragUpdate;
  final ValueChanged<double> onDragEnd;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final durationMs = controller.duration.inMilliseconds;
    final seekEnabled = durationMs > 0;
    final value = dragging
        ? dragValue
        : (durationMs <= 0
              ? 0.0
              : (controller.position.inMilliseconds / durationMs).clamp(
                  0.0,
                  1.0,
                ));
    final methodColor = controller.isTranscode
        ? Colors.orangeAccent
        : Colors.lightGreenAccent;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: AnimatedOpacity(
        opacity: visible ? 1.0 : 0.0,
        duration: AppMotion.normal,
        curve: AppMotion.standard,
        child: IgnorePointer(
          ignoring: !visible,
          child: DecoratedBox(
            key: PlayerKeys.controls,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  Color(0x8A000000),
                  Color(0xD9000000),
                ],
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.xl,
                AppSpacing.huge,
                AppSpacing.xl,
                AppSpacing.lg,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Text(
                        _clock(controller.position),
                        style: theme.textTheme.labelMedium,
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: SliderTheme(
                          data: theme.sliderTheme.copyWith(
                            trackHeight: 4,
                            thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 7,
                            ),
                            overlayShape: const RoundSliderOverlayShape(
                              overlayRadius: 16,
                            ),
                          ),
                          child: Slider(
                            key: PlayerKeys.seekBar,
                            value: value,
                            onChanged: !seekEnabled
                                ? null
                                : (next) {
                                    if (!dragging) {
                                      onDragStart(next);
                                    } else {
                                      onDragUpdate(next);
                                    }
                                  },
                            onChangeEnd: !seekEnabled ? null : onDragEnd,
                          ),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Text(
                        _clock(controller.duration),
                        style: theme.textTheme.labelMedium,
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Row(
                    children: [
                      SizedBox(
                        width: 56,
                        height: 56,
                        child: IconButton(
                          key: PlayerKeys.playPause,
                          tooltip: controller.isPlaying
                              ? l10n.pause
                              : l10n.play,
                          onPressed: controller.togglePlay,
                          iconSize: 32,
                          style: IconButton.styleFrom(
                            backgroundColor: scheme.primary,
                            foregroundColor: scheme.onPrimary,
                            shape: const CircleBorder(),
                          ),
                          icon: Icon(
                            controller.isPlaying
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                          ),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.md),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.sm,
                          vertical: AppSpacing.xxs,
                        ),
                        decoration: BoxDecoration(
                          color: methodColor.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(AppRadii.sm),
                          border: Border.all(
                            color: methodColor.withValues(alpha: 0.5),
                          ),
                        ),
                        child: Text(
                          key: PlayerKeys.playMethod,
                          controller.isTranscode
                              ? l10n.transcode
                              : l10n.directPlay,
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: methodColor,
                          ),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.lg),
                      Icon(
                        Icons.volume_up_rounded,
                        color: scheme.onSurface,
                        size: 20,
                        semanticLabel: l10n.volume,
                      ),
                      SizedBox(
                        width: 104,
                        child: Slider(
                          key: PlayerKeys.volume,
                          value: controller.volume.clamp(0, 100).toDouble(),
                          min: 0,
                          max: 100,
                          onChanged: (value) {
                            controller.setVolume(value.round());
                          },
                        ),
                      ),
                      const Spacer(),
                      if (controller.isTranscode) ...[
                        _ControlDropdown<int>(
                          key: PlayerKeys.quality,
                          tooltip: l10n.qualityAuto,
                          value:
                              kTranscodeBitrates.contains(
                                controller.maxStreamingBitrate,
                              )
                              ? controller.maxStreamingBitrate
                              : kTranscodeBitrates.first,
                          items: [
                            DropdownMenuItem(
                              value: kTranscodeBitrates.first,
                              child: Text(l10n.qualityAuto),
                            ),
                            for (final bitrate in kTranscodeBitrates.skip(1))
                              DropdownMenuItem(
                                value: bitrate,
                                child: Text(
                                  l10n.qualityMbps(bitrate ~/ 1000000),
                                ),
                              ),
                          ],
                          onChanged: (value) {
                            if (value != null) {
                              controller.setMaxBitrate(value);
                            }
                          },
                        ),
                        const SizedBox(width: AppSpacing.xs),
                      ],
                      if (controller.audioTracks.length > 1) ...[
                        _ControlDropdown<int>(
                          key: PlayerKeys.audio,
                          tooltip: l10n.audioTrack,
                          value: controller.audioStreamIndex,
                          hint: l10n.audioTrack,
                          items: [
                            for (final track in controller.audioTracks)
                              DropdownMenuItem(
                                value: track.index,
                                child: Text(track.label),
                              ),
                          ],
                          onChanged: (value) {
                            if (value != null) {
                              controller.setAudio(value);
                            }
                          },
                        ),
                        const SizedBox(width: AppSpacing.xs),
                      ],
                      if (controller.subtitleTracks.isNotEmpty) ...[
                        _ControlDropdown<int?>(
                          key: PlayerKeys.subtitle,
                          tooltip: l10n.subtitleTrack,
                          value: controller.subtitleStreamIndex,
                          hint: l10n.subtitleTrack,
                          items: [
                            DropdownMenuItem(
                              value: null,
                              child: Text(l10n.subtitleOff),
                            ),
                            for (final track in controller.subtitleTracks)
                              DropdownMenuItem(
                                value: track.index,
                                child: Text(track.label),
                              ),
                          ],
                          onChanged: controller.setSubtitle,
                        ),
                        const SizedBox(width: AppSpacing.xs),
                      ],
                      IconButton(
                        key: PlayerKeys.fullscreen,
                        tooltip: controller.isFullScreen
                            ? l10n.exitFullscreen
                            : l10n.fullscreen,
                        color: scheme.onSurface,
                        onPressed: controller.toggleFullScreen,
                        icon: Icon(
                          controller.isFullScreen
                              ? Icons.fullscreen_exit_rounded
                              : Icons.fullscreen_rounded,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 控制条右侧分组用的统一样式下拉(码率/音轨/字幕)。
class _ControlDropdown<T> extends StatelessWidget {
  const _ControlDropdown({
    super.key,
    required this.tooltip,
    required this.value,
    required this.items,
    required this.onChanged,
    this.hint,
  });

  final String tooltip;
  final T? value;
  final String? hint;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Tooltip(
      message: tooltip,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
        decoration: BoxDecoration(
          color: scheme.onSurface.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(AppRadii.sm),
        ),
        child: DropdownButton<T>(
          value: value,
          hint: hint == null
              ? null
              : Text(
                  hint!,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurface,
                  ),
                ),
          items: items,
          onChanged: onChanged,
          underline: const SizedBox.shrink(),
          dropdownColor: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(AppRadii.md),
          style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurface),
          icon: Icon(
            Icons.keyboard_arrow_down_rounded,
            color: scheme.onSurfaceVariant,
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
