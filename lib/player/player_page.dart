import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/widgets/app_error_view.dart';
import 'package:rillight/app/widgets/liquid_glass.dart';
import 'package:rillight/app/window_chrome.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/device_profile.dart';
import 'package:rillight/emby/emby_models.dart';
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
    this.autoResume = true,
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
  bool _episodesOpen = false;

  bool _pointerNearWindowEdge(Offset local) {
    final size = MediaQuery.sizeOf(context);
    const margin = 12.0;
    return local.dx < margin ||
        local.dy < margin ||
        local.dx > size.width - margin ||
        local.dy > size.height - margin;
  }

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
      settingsStore: bindings.settingsStore,
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
      unawaited(
        host.open(PlayerOpenRequest(itemId: itemId, autoResume: false)),
      );
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

  void _openEpisodeList() {
    final current = controller;
    if (current == null || !current.canBrowseEpisodes) {
      return;
    }
    unawaited(current.loadEpisodeList());
    setState(() => _episodesOpen = true);
  }

  void _closeEpisodeList() {
    setState(() => _episodesOpen = false);
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
        if (event.logicalKey == LogicalKeyboardKey.bracketLeft) {
          current.nudgeRateDown();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.bracketRight) {
          current.nudgeRateUp();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.keyT) {
          unawaited(current.toggleAlwaysOnTop());
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
          body: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerSignal: (event) {
              if (event is! PointerScrollEvent) {
                return;
              }
              if (event.scrollDelta.dy == 0) {
                return;
              }
              final delta = event.scrollDelta.dy < 0
                  ? PlayerController.volumeWheelStep
                  : -PlayerController.volumeWheelStep;
              unawaited(current.nudgeVolume(delta));
            },
            child: MouseRegion(
              onHover: (event) {
                if (_pointerNearWindowEdge(event.localPosition)) {
                  return;
                }
                current.onUserActivity();
              },
              onExit: (_) {
                current.hideControlsOnPointerExit();
              },
              cursor:
                  (!current.controlsVisible &&
                      current.nextEpisode == null &&
                      !current.playbackEnded)
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
                      onTapUp: (_) {
                        current.toggleControls();
                      },
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
                  if (!current.loading &&
                      current.resolved != null &&
                      !current.playbackEnded &&
                      current.error == null)
                    _ControlsBar(
                      controller: current,
                      visible: current.controlsVisible,
                      dragging: _dragSeeking,
                      dragValue: _dragValue,
                      onOpenEpisodes: _openEpisodeList,
                      onDragStart: (value) {
                        current.onUserActivity();
                        setState(() {
                          _dragSeeking = true;
                          _dragValue = value;
                        });
                      },
                      onDragUpdate: (value) {
                        current.onUserActivity();
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
                  if (_episodesOpen && current.canBrowseEpisodes)
                    _EpisodeListPanel(
                      controller: current,
                      onClose: _closeEpisodeList,
                    ),
                  if (current.activeSkipSegment != null &&
                      !current.loading &&
                      !current.playbackEnded)
                    _SkipSegmentButton(controller: current),
                  if (current.playbackEnded && current.nextEpisode == null)
                    _PlaybackEndedOverlay(controller: current),
                  if (current.disconnected && !current.isPlaying)
                    _Banner(
                      key: PlayerKeys.disconnect,
                      text:
                          current.disconnectDetail ?? l10n.playbackDisconnected,
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
                      text: _subtitleNoticeText(l10n, current.subtitleNotice!),
                    ),
                  _PlayerChromeBar(
                    controller: current,
                    visible: current.controlsVisible,
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

  String _subtitleNoticeText(AppLocalizations l10n, SubtitleNoticeKind kind) {
    switch (kind) {
      case SubtitleNoticeKind.bitmapBurnIn:
        return l10n.subtitleBitmapBurnIn;
      case SubtitleNoticeKind.bitmapFailed:
        return l10n.subtitleBitmapFailed;
    }
  }
}

/// 控制层共享的显隐包装:统一淡入淡出节奏与隐藏期命中忽略。
class _FadeThrough extends StatelessWidget {
  const _FadeThrough({required this.visible, required this.child});

  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: visible ? 1.0 : 0.0,
      duration: AppMotion.normal,
      curve: AppMotion.standard,
      child: IgnorePointer(ignoring: !visible, child: child),
    );
  }
}

class _PlayerChromeBar extends StatelessWidget {
  const _PlayerChromeBar({required this.controller, required this.visible});

  final PlayerController controller;
  final bool visible;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = controller.item?.displayName ?? '';
    return Positioned(
      left: 0,
      right: 0,
      top: 0,
      child: _FadeThrough(
        visible: visible,
        child: DecoratedBox(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [
                Colors.transparent,
                Color(0x8A000000),
                Color(0xD9000000),
              ],
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.sm,
              AppSpacing.sm,
              AppSpacing.lg,
            ),
            child: SizedBox(
              height: kWindowChromeHeight + AppSpacing.sm,
              child: Row(
                children: [
                  Expanded(
                    child: WindowDragArea(
                      key: const Key('player-window-drag'),
                      child: SizedBox.expand(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: title.isEmpty
                              ? const SizedBox.expand()
                              : Text(
                                  title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleMedium,
                                ),
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    key: const Key('player-window-close'),
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).closeButtonTooltip,
                    color: theme.colorScheme.onSurface,
                    onPressed: () {
                      unawaited(controller.close());
                    },
                    icon: const Icon(Icons.close_rounded),
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

class _PlaybackEndedOverlay extends StatelessWidget {
  const _PlaybackEndedOverlay({required this.controller});

  final PlayerController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final title = controller.item?.displayName ?? '';
    final seriesId = controller.item?.seriesId;
    final hasSeries = seriesId != null && seriesId.isNotEmpty;
    return Positioned.fill(
      child: ColoredBox(
        color: const Color(0x99000000),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: LiquidGlass(
              kind: LiquidGlassKind.panel,
              padding: const EdgeInsets.all(AppSpacing.xxl),
              child: Material(
                key: PlayerKeys.playbackEnded,
                type: MaterialType.transparency,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.replay_rounded, size: 40, color: scheme.primary),
                    const SizedBox(height: AppSpacing.md),
                    Text(
                      l10n.playbackEnded,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleLarge,
                    ),
                    if (title.isNotEmpty) ...[
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        title,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    const SizedBox(height: AppSpacing.xl),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: AppSpacing.sm,
                      runSpacing: AppSpacing.sm,
                      children: [
                        FilledButton.icon(
                          key: PlayerKeys.replay,
                          onPressed: () => unawaited(controller.replay()),
                          icon: const Icon(Icons.replay_rounded),
                          label: Text(l10n.replay),
                        ),
                        if (hasSeries)
                          OutlinedButton(
                            key: PlayerKeys.endedViewSeries,
                            onPressed: controller.openEndedSeries,
                            child: Text(l10n.viewSeries),
                          ),
                        OutlinedButton(
                          key: PlayerKeys.endedClose,
                          onPressed: () => unawaited(controller.close()),
                          child: Text(l10n.closePlayer),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
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
      child: LiquidGlass(
        kind: LiquidGlassKind.control,
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Material(
          key: PlayerKeys.nextEpisode,
          type: MaterialType.transparency,
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

/// 播放到片头/片尾区间时右下角的跳过按钮:点击跳到区间终点。
class _SkipSegmentButton extends StatelessWidget {
  const _SkipSegmentButton({required this.controller});

  final PlayerController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final segment = controller.activeSkipSegment!;
    return Positioned(
      right: AppSpacing.xl,
      bottom: 112,
      child: LiquidGlass(
        kind: LiquidGlassKind.control,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
        child: Material(
          key: const Key('player-skip-segment'),
          type: MaterialType.transparency,
          child: FilledButton.icon(
            onPressed: () => unawaited(controller.skipCurrentSegment()),
            icon: const Icon(Icons.fast_forward_rounded, size: 18),
            label: Text(
              segment.kind == PlayerSkipKind.outro
                  ? l10n.skipOutro
                  : l10n.skipIntro,
            ),
          ),
        ),
      ),
    );
  }
}

/// 播放中的剧集列表面板:当前季分集 ListView.builder 惰性构建,
/// 可切换季,点击任意集立即切集。
class _EpisodeListPanel extends StatelessWidget {
  const _EpisodeListPanel({required this.controller, required this.onClose});

  final PlayerController controller;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final seasons = controller.seasons;
    final currentSeason = seasons
        .where((season) => season.id == controller.episodeSeasonId)
        .toList();
    return Positioned(
      top: 0,
      bottom: 0,
      right: 0,
      width: 340,
      child: LiquidGlass(
        kind: LiquidGlassKind.panel,
        // 顶部让位给窗口标题栏(拖拽/关闭),底部让位给控制条。
        padding: EdgeInsets.fromLTRB(
          AppSpacing.lg,
          kWindowChromeHeight + AppSpacing.xl,
          AppSpacing.lg,
          AppSpacing.huge,
        ),
        child: Material(
          key: const Key('player-episodes-panel'),
          type: MaterialType.transparency,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.playerEpisodes,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  if (seasons.length > 1) _SeasonPicker(controller: controller),
                  IconButton(
                    key: const Key('player-episodes-close'),
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).closeButtonTooltip,
                    onPressed: onClose,
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Expanded(
                child:
                    controller.episodeListLoading && controller.episodes.isEmpty
                    ? const Center(
                        child: CircularProgressIndicator(strokeWidth: 3),
                      )
                    : controller.episodeListFailed &&
                          controller.episodes.isEmpty
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            l10n.playbackFailed,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          OutlinedButton(
                            onPressed: () {
                              unawaited(controller.loadEpisodeList());
                            },
                            child: Text(l10n.retry),
                          ),
                        ],
                      )
                    : ListView.builder(
                        key: const Key('player-episodes-list'),
                        itemCount: controller.episodes.length,
                        itemBuilder: (context, index) {
                          final episode = controller.episodes[index];
                          final isCurrent = episode.id == controller.itemId;
                          return _EpisodeRow(
                            episode: episode,
                            isCurrent: isCurrent,
                            onTap: () {
                              unawaited(controller.playEpisode(episode));
                            },
                          );
                        },
                      ),
              ),
              if (currentSeason.length == 1)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.sm),
                  child: Text(
                    currentSeason.first.name,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 季选择菜单(仅多季时显示)。
class _SeasonPicker extends StatelessWidget {
  const _SeasonPicker({required this.controller});

  final PlayerController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final seasons = controller.seasons;
    var current = seasons.first;
    for (final season in seasons) {
      if (season.id == controller.episodeSeasonId) {
        current = season;
        break;
      }
    }
    return PopupMenuButton<String>(
      key: const Key('player-season-picker'),
      tooltip: AppLocalizations.of(context).seasons,
      onSelected: (seasonId) {
        unawaited(controller.selectSeason(seasonId));
      },
      initialValue: current.id,
      color: theme.colorScheme.surface.withValues(alpha: 0.96),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.md),
        side: BorderSide(
          color: Colors.white.withValues(alpha: AppGlass.edgeLight),
        ),
      ),
      constraints: const BoxConstraints(minWidth: 160, maxWidth: 280),
      padding: EdgeInsets.zero,
      splashRadius: 20,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 120),
              child: Text(
                current.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium,
              ),
            ),
            const Icon(Icons.arrow_drop_down_rounded, size: 20),
          ],
        ),
      ),
      itemBuilder: (context) => [
        for (final season in seasons)
          PopupMenuItem(value: season.id, child: Text(season.name)),
      ],
    );
  }
}

/// 单集行:集号+名称+已看勾选,当前集高亮。
class _EpisodeRow extends StatelessWidget {
  const _EpisodeRow({
    required this.episode,
    required this.isCurrent,
    required this.onTap,
  });

  final EmbyItem episode;
  final bool isCurrent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final number = episode.indexNumber;
    return ListTile(
      key: Key('player-episode-${episode.id}'),
      dense: true,
      selected: isCurrent,
      selectedColor: scheme.primary,
      leading: number == null
          ? null
          : SizedBox(
              width: 28,
              child: Text(
                '$number',
                textAlign: TextAlign.end,
                style: theme.textTheme.labelMedium,
              ),
            ),
      title: Text(
        episode.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: isCurrent
            ? theme.textTheme.bodyMedium?.copyWith(color: scheme.primary)
            : theme.textTheme.bodyMedium,
      ),
      trailing: episode.userData.played
          ? Icon(Icons.check_rounded, size: 18, color: scheme.onSurfaceVariant)
          : null,
      onTap: onTap,
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
      top: kWindowChromeHeight + AppSpacing.xxl,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: LiquidGlass(
            kind: LiquidGlassKind.control,
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            child: Material(
              type: MaterialType.transparency,
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

/// 底部控制条:渐变承托层内组合时间轴与按钮行,只负责布局与显隐。
class _ControlsBar extends StatelessWidget {
  const _ControlsBar({
    required this.controller,
    required this.visible,
    required this.dragging,
    required this.dragValue,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    this.onOpenEpisodes,
  });

  final PlayerController controller;
  final bool visible;
  final bool dragging;
  final double dragValue;
  final ValueChanged<double> onDragStart;
  final ValueChanged<double> onDragUpdate;
  final ValueChanged<double> onDragEnd;
  final VoidCallback? onOpenEpisodes;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: _FadeThrough(
        visible: visible,
        child: DecoratedBox(
          key: PlayerKeys.controls,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.transparent, Color(0xCC000000)],
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.huge,
              AppSpacing.lg,
              AppSpacing.md,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _SeekTimeline(
                  controller: controller,
                  dragging: dragging,
                  dragValue: dragValue,
                  onDragStart: onDragStart,
                  onDragUpdate: onDragUpdate,
                  onDragEnd: onDragEnd,
                ),
                const SizedBox(height: AppSpacing.xs),
                _ControlsRow(
                  controller: controller,
                  onOpenEpisodes: onOpenEpisodes,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 时间轴行:当前时间 + 进度滑条 + 总时长。
class _SeekTimeline extends StatelessWidget {
  const _SeekTimeline({
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
    final theme = Theme.of(context);
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
    return Row(
      children: [
        Text(_clock(controller.position), style: _overlayTimeStyle(theme)),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: SliderTheme(
            data: _overlaySliderTheme(theme, thumbRadius: 6),
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
        Text(_clock(controller.duration), style: _overlayTimeStyle(theme)),
      ],
    );
  }
}

/// 主按钮行:播放/暂停、音量组、轨道菜单与全屏。
class _ControlsRow extends StatelessWidget {
  const _ControlsRow({required this.controller, this.onOpenEpisodes});

  final PlayerController controller;
  final VoidCallback? onOpenEpisodes;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Row(
      children: [
        _PlayerIconButton(
          key: PlayerKeys.playPause,
          tooltip: controller.isPlaying ? l10n.pause : l10n.play,
          onPressed: controller.togglePlay,
          iconSize: 28,
          icon: controller.isPlaying
              ? Icons.pause_rounded
              : Icons.play_arrow_rounded,
        ),
        _VolumeControl(controller: controller),
        const Spacer(),
        if (controller.isTranscode)
          _ControlMenu<int>(
            key: PlayerKeys.quality,
            tooltip: l10n.qualityAuto,
            icon: Icons.high_quality_outlined,
            onSelected: controller.setMaxBitrate,
            items: [
              CheckedPopupMenuItem(
                value: kTranscodeBitrates.first,
                checked:
                    controller.maxStreamingBitrate ==
                        kTranscodeBitrates.first ||
                    !kTranscodeBitrates.contains(
                      controller.maxStreamingBitrate,
                    ),
                child: Text(l10n.qualityAuto),
              ),
              for (final bitrate in kTranscodeBitrates.skip(1))
                CheckedPopupMenuItem(
                  value: bitrate,
                  checked: controller.maxStreamingBitrate == bitrate,
                  child: Text(l10n.qualityMbps(bitrate ~/ 1000000)),
                ),
            ],
          ),
        _SpeedControl(controller: controller),
        if (controller.canSetManualSkip)
          _SkipSettingsControl(controller: controller),
        if (controller.audioTracks.length > 1)
          _ControlMenu<int>(
            key: PlayerKeys.audio,
            tooltip: l10n.audioTrack,
            icon: Icons.audiotrack_rounded,
            onSelected: controller.setAudio,
            items: [
              for (final track in controller.audioTracks)
                CheckedPopupMenuItem(
                  value: track.index,
                  checked: track.index == controller.audioStreamIndex,
                  child: Text(track.label),
                ),
            ],
          ),
        if (controller.subtitleTracks.isNotEmpty)
          _ControlMenu<int>(
            key: PlayerKeys.subtitle,
            tooltip: l10n.subtitleTrack,
            icon: controller.subtitleStreamIndex == null
                ? Icons.closed_caption_off_rounded
                : Icons.closed_caption_rounded,
            onSelected: (value) {
              controller.setSubtitle(value == _subtitleOffToken ? null : value);
            },
            items: [
              CheckedPopupMenuItem(
                value: _subtitleOffToken,
                checked: controller.subtitleStreamIndex == null,
                child: Text(l10n.subtitleOff),
              ),
              for (final track in controller.subtitleTracks)
                CheckedPopupMenuItem(
                  value: track.index,
                  checked: track.index == controller.subtitleStreamIndex,
                  child: Text(track.label),
                ),
            ],
          ),
        if (controller.canBrowseEpisodes)
          _PlayerIconButton(
            key: const Key('player-episodes'),
            tooltip: l10n.playerEpisodes,
            onPressed: onOpenEpisodes,
            iconSize: 22,
            icon: Icons.playlist_play_rounded,
          ),
        if (controller.canSwitchMediaSource)
          _ControlMenu<String>(
            key: const Key('player-media-source'),
            tooltip: l10n.mediaSource,
            icon: Icons.layers_outlined,
            onSelected: controller.switchMediaSource,
            items: [
              for (final source in controller.mediaSources)
                CheckedPopupMenuItem(
                  value: source.id,
                  checked: source.id == controller.resolved?.mediaSource.id,
                  child: Text(source.label),
                ),
            ],
          ),
        _PlayerIconButton(
          key: const Key('player-always-on-top'),
          tooltip: controller.isAlwaysOnTop
              ? l10n.alwaysOnTopOff
              : l10n.alwaysOnTop,
          color: controller.isAlwaysOnTop ? scheme.primary : null,
          onPressed: controller.toggleAlwaysOnTop,
          iconSize: 20,
          icon: controller.isAlwaysOnTop
              ? Icons.push_pin_rounded
              : Icons.push_pin_outlined,
        ),
        _PlayerIconButton(
          key: PlayerKeys.fullscreen,
          tooltip: controller.isFullScreen
              ? l10n.exitFullscreen
              : l10n.fullscreen,
          onPressed: controller.toggleFullScreen,
          icon: controller.isFullScreen
              ? Icons.fullscreen_exit_rounded
              : Icons.fullscreen_rounded,
        ),
      ],
    );
  }
}

/// 倍速组:固定阶梯菜单 + 当前倍速回显。
class _SpeedControl extends StatelessWidget {
  const _SpeedControl({required this.controller});

  final PlayerController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ControlMenu<double>(
          key: const Key('player-speed'),
          tooltip: l10n.playbackRate,
          icon: Icons.speed,
          onSelected: controller.setRate,
          items: [
            for (final rate in kPlaybackRateLadder)
              CheckedPopupMenuItem(
                value: rate,
                checked: rate == controller.playbackRate,
                child: Text(_rateLabel(rate)),
              ),
          ],
        ),
        SizedBox(
          width: 38,
          child: Text(
            key: const Key('player-speed-label'),
            _rateLabel(controller.playbackRate),
            textAlign: TextAlign.end,
            style: _overlayTimeStyle(theme),
          ),
        ),
      ],
    );
  }
}

/// 阶梯倍速的显示文案,如 0.5x / 0.75x / 1x / 2x。
String _rateLabel(double rate) {
  final trimmed = rate == rate.roundToDouble()
      ? rate.round().toString()
      : rate.toString();
  return '${trimmed}x';
}

/// 手动片头/片尾设置(仅无服务器章节标记的剧集显示):
/// 固定档位菜单,选择即按剧记忆并立即生效。
class _SkipSettingsControl extends StatelessWidget {
  const _SkipSettingsControl({required this.controller});

  final PlayerController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return _ControlMenu<String>(
      key: const Key('player-skip-settings'),
      tooltip: l10n.skipSettings,
      icon: Icons.skip_next_rounded,
      onSelected: (value) {
        if (value == 'off') {
          unawaited(controller.clearManualSkip());
          return;
        }
        final parts = value.split(':');
        final seconds = int.tryParse(parts.length > 1 ? parts[1] : '');
        if (seconds == null) {
          return;
        }
        if (value.startsWith('intro:')) {
          unawaited(controller.setManualIntroSkip(seconds));
        } else if (value.startsWith('outro:')) {
          unawaited(controller.setManualOutroSkip(seconds));
        }
      },
      items: [
        CheckedPopupMenuItem(
          value: 'off',
          checked:
              controller.manualIntroSkipSeconds == null &&
              controller.manualOutroSkipSeconds == null,
          child: Text(l10n.skipManualOff),
        ),
        for (final seconds in kManualSkipChoices)
          CheckedPopupMenuItem(
            value: 'intro:$seconds',
            checked: controller.manualIntroSkipSeconds == seconds,
            child: Text(l10n.skipIntroSeconds(seconds)),
          ),
        for (final seconds in kManualSkipChoices)
          CheckedPopupMenuItem(
            value: 'outro:$seconds',
            checked: controller.manualOutroSkipSeconds == seconds,
            child: Text(l10n.skipOutroSeconds(seconds)),
          ),
      ],
    );
  }
}

/// 音量组:静音按钮 + 音量滑条 + 百分比回显。
///
/// 滑条、显示与持久化均使用 [PlayerController.volume] 的用户百分比,
/// mpv 换算统一在 [PlayerController.setVolume] 内经 [mpvVolumeForPercent] 完成。
class _VolumeControl extends StatelessWidget {
  const _VolumeControl({required this.controller});

  final PlayerController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _PlayerIconButton(
          key: PlayerKeys.mute,
          tooltip: controller.volume <= 0 ? l10n.unmute : l10n.mute,
          onPressed: controller.toggleMute,
          iconSize: 20,
          icon: controller.volume <= 0
              ? Icons.volume_off_rounded
              : Icons.volume_up_rounded,
        ),
        SizedBox(
          width: 110,
          child: SliderTheme(
            data: _overlaySliderTheme(theme, thumbRadius: 5),
            child: Slider(
              key: PlayerKeys.volume,
              value: controller.volume.clamp(0, 100).toDouble(),
              min: 0,
              max: 100,
              label: l10n.volumePercent(controller.volume),
              onChanged: (value) {
                controller.setVolume(value.round());
              },
            ),
          ),
        ),
        SizedBox(
          width: 40,
          child: Text(
            key: PlayerKeys.volumePercent,
            l10n.volumePercent(controller.volume),
            textAlign: TextAlign.end,
            style: _overlayTimeStyle(theme),
          ),
        ),
      ],
    );
  }
}

/// 控制层图标按钮:统一的暖白前景,供按钮行各处复用;
/// [color] 非空时(如置顶开启)以高亮色标识激活状态。
class _PlayerIconButton extends StatelessWidget {
  const _PlayerIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.iconSize = 24,
    this.color,
  });

  final String? tooltip;
  final double iconSize;
  final IconData icon;
  final Color? color;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      color: color ?? scheme.onSurface,
      iconSize: iconSize,
      icon: Icon(icon),
    );
  }
}

const _subtitleOffToken = -1;

/// 控制条右侧用图标打开菜单,长轨名只出现在弹出层。
///
/// 音轨/字幕/画质共用同一视觉:近黑面板、token 圆角与高光描边。
class _ControlMenu<T> extends StatelessWidget {
  const _ControlMenu({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.items,
    required this.onSelected,
  });

  final String tooltip;
  final IconData icon;
  final List<PopupMenuEntry<T>> items;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopupMenuButton<T>(
      tooltip: tooltip,
      onSelected: onSelected,
      color: scheme.surface.withValues(alpha: 0.96),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.md),
        side: BorderSide(
          color: Colors.white.withValues(alpha: AppGlass.edgeLight),
        ),
      ),
      constraints: const BoxConstraints(
        minWidth: 200,
        maxWidth: 360,
        // 倍速阶梯 8 项(约 384px)需完整显示,避免菜单内滚动。
        maxHeight: 416,
      ),
      padding: EdgeInsets.zero,
      splashRadius: 20,
      icon: Icon(icon, color: scheme.onSurface),
      itemBuilder: (context) => items,
    );
  }
}

TextStyle? _overlayTimeStyle(ThemeData theme) {
  return theme.textTheme.labelMedium?.copyWith(
    color: theme.colorScheme.onSurface,
    fontFeatures: const [FontFeature.tabularFigures()],
  );
}

SliderThemeData _overlaySliderTheme(
  ThemeData theme, {
  required double thumbRadius,
}) {
  final onSurface = theme.colorScheme.onSurface;
  return theme.sliderTheme.copyWith(
    trackHeight: 3,
    activeTrackColor: onSurface,
    inactiveTrackColor: onSurface.withValues(alpha: 0.28),
    thumbColor: onSurface,
    overlayColor: onSurface.withValues(alpha: 0.18),
    thumbShape: RoundSliderThumbShape(enabledThumbRadius: thumbRadius),
    overlayShape: RoundSliderOverlayShape(overlayRadius: thumbRadius * 2.2),
  );
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
