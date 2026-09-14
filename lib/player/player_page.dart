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
import 'package:rillight/player/danmaku/danmaku_controller.dart';
import 'package:rillight/player/danmaku/danmaku_renderer.dart';
import 'package:rillight/player/danmaku/dandanplay_models.dart';
import 'package:rillight/player/media_kit_video_backend.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_controller.dart';
import 'package:rillight/player/player_keys.dart';
import 'package:rillight/player/player_window.dart';
import 'package:rillight/player/player_window_host.dart';
import 'package:rillight/player/video_backend.dart';

/// 播放器顶栏命中高度:内边距 + 标题行。剧集面板从这之下铺开,避免挡住关闭/置顶。
const double kPlayerChromeBarExtent =
    AppSpacing.sm + kWindowChromeHeight + AppSpacing.sm + AppSpacing.lg;

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
  DanmakuController? _danmaku;
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
      snapshotStore: bindings.snapshotStore,
      onClose: _leave,
      onOpenItem: _openItem,
    );
    controller = created;
    created.addListener(_onController);
    final danmaku = DanmakuController(settingsStore: bindings.settingsStore);
    _danmaku = danmaku;
    danmaku.addListener(_onDanmakuChanged);
    unawaited(created.start());
  }

  @override
  void dispose() {
    _danmaku?.removeListener(_onDanmakuChanged);
    _danmaku?.dispose();
    final current = controller;
    current?.removeListener(_onController);
    current?.dispose();
    super.dispose();
  }

  void _onController() {
    final current = controller;
    final danmaku = _danmaku;
    if (current != null && danmaku != null) {
      danmaku.syncFromPlayback(
        _danmakuContext(current),
        position: current.position,
        playing: current.isPlaying,
        rate: current.playbackRate,
      );
    }
    if (mounted) {
      setState(() {});
    }
  }

  void _onDanmakuChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  /// 从当前播放状态构建弹幕会话上下文（未解析完成时为 null）。
  DanmakuEpisodeContext? _danmakuContext(PlayerController current) {
    final item = current.item;
    final resolved = current.resolved;
    if (item == null || resolved == null) {
      return null;
    }
    final path = resolved.mediaSource.path;
    final fileName = _baseName(path).isNotEmpty ? _baseName(path) : item.name;
    return DanmakuEpisodeContext(
      itemId: current.itemId,
      mediaSourceId: resolved.mediaSource.id,
      seriesId: item.seriesId,
      seriesTitle: item.seriesName,
      title: item.name,
      fileName: fileName,
      episodeIndex: item.indexNumber,
      streamUrl: resolved.isTranscode ? null : resolved.streamUrl,
      duration: current.duration,
      isMovie: !item.isEpisode,
    );
  }

  static String _baseName(String? path) {
    final value = path?.trim() ?? '';
    if (value.isEmpty) {
      return '';
    }
    final normalized = value.replaceAll('\\', '/');
    final slash = normalized.lastIndexOf('/');
    return slash < 0 ? normalized : normalized.substring(slash + 1);
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
    if (_episodesOpen) {
      _closeEpisodeList();
      return;
    }
    unawaited(current.loadEpisodeList());
    current.setControlsPinned(true);
    setState(() => _episodesOpen = true);
  }

  void _closeEpisodeList() {
    if (!_episodesOpen) {
      return;
    }
    controller?.setControlsPinned(false);
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
          if (_episodesOpen) {
            _closeEpisodeList();
            return KeyEventResult.handled;
          }
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
                      !current.playbackEnded &&
                      !_episodesOpen)
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
                  if (_danmakuOverlayVisible(current))
                    Positioned.fill(
                      child: IgnorePointer(
                        child: DanmakuView(controller: _danmaku!),
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
                                ?.copyWith(
                                  color: Theme.of(context).colorScheme.onSurface
                                      .withValues(alpha: 0.7),
                                ),
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
                      danmaku: _danmaku,
                      onOpenEpisodes: _openEpisodeList,
                      onDanmakuSearch: _openDanmakuSearch,
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
                  if (current.activeSkipSegment != null &&
                      current.skipPromptVisible &&
                      current.nextEpisode == null &&
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
                      text: current.sessionExpired
                          ? l10n.playbackSessionExpired
                          : l10n.progressSyncFailed,
                      onDismiss: current.progressSyncPersistent
                          ? current.dismissProgressSyncBanner
                          : null,
                    ),
                  if (current.subtitleNotice != null)
                    _Banner(
                      key: PlayerKeys.subtitleNotice,
                      text: _subtitleNoticeText(l10n, current.subtitleNotice!),
                    ),
                  if (_danmaku?.status == DanmakuStatus.customUnreachable &&
                      !current.loading)
                    _DanmakuSourceBanner(controller: _danmaku!),
                  _PlayerChromeBar(
                    controller: current,
                    visible: current.controlsVisible,
                  ),
                  if (_episodesOpen && current.canBrowseEpisodes)
                    _EpisodeListPanel(
                      controller: current,
                      onClose: _closeEpisodeList,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 弹幕渲染层仅在「开启且有弹幕」时挂载，其余情况零渲染开销。
  bool _danmakuOverlayVisible(PlayerController current) {
    final danmaku = _danmaku;
    return danmaku != null &&
        danmaku.danmakuOn &&
        danmaku.hasComments &&
        !current.loading &&
        current.error == null &&
        !current.playbackEnded;
  }

  Future<void> _openDanmakuSearch() async {
    final danmaku = _danmaku;
    if (danmaku == null || !mounted) {
      return;
    }
    final l10n = AppLocalizations.of(context);
    final keyword = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        final field = TextEditingController();
        return AlertDialog(
          title: Text(l10n.danmakuSearchTitle),
          content: TextField(
            key: const Key('player-danmaku-search-field'),
            controller: field,
            autofocus: true,
            decoration: InputDecoration(hintText: l10n.danmakuSearchHint),
            onSubmitted: (value) => Navigator.pop(dialogContext, value),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(
                MaterialLocalizations.of(dialogContext).cancelButtonLabel,
              ),
            ),
            FilledButton(
              key: const Key('player-danmaku-search-submit'),
              onPressed: () => Navigator.pop(dialogContext, field.text),
              child: Text(l10n.danmakuSearch),
            ),
          ],
        );
      },
    );
    final term = keyword?.trim() ?? '';
    if (term.isEmpty) {
      return;
    }
    final animes = await danmaku.search(term);
    if (!mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (dialogContext) =>
          _DanmakuSearchResults(danmaku: danmaku, animes: animes),
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
      duration: AppMotion.durationOf(context),
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
    final l10n = AppLocalizations.of(context);
    final scrim = theme.colorScheme.scrim;
    final title = controller.item?.displayName ?? '';
    return Positioned(
      left: 0,
      right: 0,
      top: 0,
      child: _FadeThrough(
        visible: visible,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [
                Colors.transparent,
                scrim.withValues(
                  alpha: AppScrim.of(context, AppScrim.playerBarSoft),
                ),
                scrim.withValues(
                  alpha: AppScrim.of(context, AppScrim.playerPanel),
                ),
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
                    key: const Key('player-always-on-top'),
                    tooltip: controller.isAlwaysOnTop
                        ? l10n.alwaysOnTopOff
                        : l10n.alwaysOnTop,
                    color: controller.isAlwaysOnTop
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurface,
                    onPressed: () {
                      unawaited(controller.toggleAlwaysOnTop());
                    },
                    icon: Icon(
                      controller.isAlwaysOnTop
                          ? Icons.push_pin_rounded
                          : Icons.push_pin_outlined,
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
        color: scheme.scrim.withValues(
          alpha: AppScrim.of(context, AppScrim.playerBarrier),
        ),
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

/// 播放中的剧集列表:点遮罩或关闭钮收起,列表从顶栏下方开始以免挡住窗口关闭。
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
      top: kPlayerChromeBarExtent,
      left: 0,
      right: 0,
      bottom: 0,
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              key: const Key('player-episodes-dismiss'),
              behavior: HitTestBehavior.opaque,
              onTap: onClose,
              child: ColoredBox(
                color: scheme.scrim.withValues(
                  alpha: AppScrim.of(context, AppScrim.barrier),
                ),
              ),
            ),
          ),
          Positioned(
            top: 0,
            bottom: 0,
            right: 0,
            width: 360,
            child: Material(
              key: const Key('player-episodes-panel'),
              color: scheme.surfaceContainerHigh,
              elevation: 8,
              shadowColor: scheme.shadow,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md,
                  AppSpacing.md,
                  AppSpacing.md,
                  AppSpacing.lg,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            l10n.playerEpisodes,
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: scheme.onSurface,
                            ),
                          ),
                        ),
                        if (seasons.length > 1)
                          _SeasonPicker(controller: controller),
                        IconButton(
                          key: const Key('player-episodes-close'),
                          tooltip: MaterialLocalizations.of(
                            context,
                          ).closeButtonTooltip,
                          color: scheme.onSurface,
                          onPressed: onClose,
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Expanded(child: _episodeListBody(context, l10n, scheme)),
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
          ),
        ],
      ),
    );
  }

  Widget _episodeListBody(
    BuildContext context,
    AppLocalizations l10n,
    ColorScheme scheme,
  ) {
    if (controller.episodeListLoading && controller.episodes.isEmpty) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 3));
    }
    if (controller.episodeListFailed && controller.episodes.isEmpty) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            l10n.playbackFailed,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: AppSpacing.sm),
          OutlinedButton(
            key: const Key('player-episodes-retry'),
            onPressed: () {
              unawaited(controller.loadEpisodeList());
            },
            child: Text(l10n.retry),
          ),
        ],
      );
    }
    return Scrollbar(
      child: ListView.builder(
        key: const Key('player-episodes-list'),
        itemCount: controller.episodes.length,
        itemBuilder: (context, index) {
          final episode = controller.episodes[index];
          final isCurrent = episode.id == controller.itemId;
          return _EnsureCurrentEpisodeVisible(
            selected: isCurrent,
            token: controller.itemId,
            child: _EpisodeRow(
              episode: episode,
              isCurrent: isCurrent,
              onTap: () {
                unawaited(controller.playEpisode(episode));
              },
            ),
          );
        },
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
      selected: isCurrent,
      selectedTileColor: scheme.surfaceContainerHighest,
      selectedColor: scheme.onSurface,
      textColor: scheme.onSurface,
      iconColor: scheme.onSurface,
      leading: number == null
          ? null
          : SizedBox(
              width: 28,
              child: Text(
                '$number',
                textAlign: TextAlign.end,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: scheme.onSurface,
                ),
              ),
            ),
      title: Text(
        episode.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyLarge?.copyWith(
          color: scheme.onSurface,
          fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w400,
        ),
      ),
      trailing: episode.userData.played
          ? Icon(Icons.check_rounded, size: 18, color: scheme.onSurfaceVariant)
          : null,
      onTap: onTap,
    );
  }
}

/// 当前集进入可视区,长列表打开时能看到正在播放的那一集。
class _EnsureCurrentEpisodeVisible extends StatefulWidget {
  const _EnsureCurrentEpisodeVisible({
    required this.selected,
    required this.token,
    required this.child,
  });

  final bool selected;
  final String token;
  final Widget child;

  @override
  State<_EnsureCurrentEpisodeVisible> createState() =>
      _EnsureCurrentEpisodeVisibleState();
}

class _EnsureCurrentEpisodeVisibleState
    extends State<_EnsureCurrentEpisodeVisible> {
  @override
  void initState() {
    super.initState();
    if (widget.selected) {
      _schedule();
    }
  }

  @override
  void didUpdateWidget(_EnsureCurrentEpisodeVisible oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selected &&
        (!oldWidget.selected || oldWidget.token != widget.token)) {
      _schedule();
    }
  }

  void _schedule() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      Scrollable.ensureVisible(
        context,
        alignment: 0.25,
        duration: AppMotion.durationOf(context, AppMotion.fast),
        curve: AppMotion.standard,
      );
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// 顶部提示横幅;[onDismiss] 非空时(持续显示态)附带关闭钮。
class _Banner extends StatelessWidget {
  const _Banner({super.key, required this.text, this.onDismiss});

  final String text;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dismiss = onDismiss;
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
                  if (dismiss != null) ...[
                    const SizedBox(width: AppSpacing.xs),
                    IconButton(
                      key: const Key('player-progress-sync-dismiss'),
                      tooltip: MaterialLocalizations.of(
                        context,
                      ).closeButtonTooltip,
                      onPressed: dismiss,
                      iconSize: 18,
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
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
    this.danmaku,
    this.onOpenEpisodes,
    this.onDanmakuSearch,
  });

  final PlayerController controller;
  final DanmakuController? danmaku;
  final bool visible;
  final bool dragging;
  final double dragValue;
  final ValueChanged<double> onDragStart;
  final ValueChanged<double> onDragUpdate;
  final ValueChanged<double> onDragEnd;
  final VoidCallback? onOpenEpisodes;
  final VoidCallback? onDanmakuSearch;

  @override
  Widget build(BuildContext context) {
    final scrim = Theme.of(context).colorScheme.scrim;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: _FadeThrough(
        visible: visible,
        child: DecoratedBox(
          key: PlayerKeys.controls,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.transparent,
                scrim.withValues(
                  alpha: AppScrim.of(context, AppScrim.playerBar),
                ),
              ],
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
                  danmaku: danmaku,
                  onOpenEpisodes: onOpenEpisodes,
                  onDanmakuSearch: onDanmakuSearch,
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
  const _ControlsRow({
    required this.controller,
    this.danmaku,
    this.onOpenEpisodes,
    this.onDanmakuSearch,
  });

  final PlayerController controller;
  final DanmakuController? danmaku;
  final VoidCallback? onOpenEpisodes;
  final VoidCallback? onDanmakuSearch;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
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
        if (danmaku != null)
          _DanmakuSettingsMenu(danmaku: danmaku!, onSearch: onDanmakuSearch),
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
        _PlaybackOverflowMenu(controller: controller),
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

/// 低频播放设置收入溢出菜单,控制条只留主操作与高频入口
/// (播放/音量/弹幕/字幕/剧集/全屏)。点开后再进子菜单选具体项。
class _PlaybackOverflowMenu extends StatelessWidget {
  const _PlaybackOverflowMenu({required this.controller});

  final PlayerController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return PopupMenuButton<_PlaybackOverflowAction>(
      key: PlayerKeys.more,
      tooltip: l10n.playerPlaybackSettings,
      padding: EdgeInsets.zero,
      splashRadius: 20,
      constraints: _controlMenuConstraints,
      icon: Icon(Icons.settings_outlined, color: scheme.onSurface),
      onSelected: (action) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (context.mounted) {
            unawaited(_openAction(context, action));
          }
        });
      },
      itemBuilder: (context) {
        final l10n = AppLocalizations.of(context);
        return [
          PopupMenuItem(
            key: PlayerKeys.speed,
            value: _PlaybackOverflowAction.speed,
            child: _PlaybackSettingRow(
              label: l10n.playbackRate,
              value: _rateLabel(controller.playbackRate),
              valueKey: PlayerKeys.speedLabel,
            ),
          ),
          if (controller.audioTracks.length > 1)
            PopupMenuItem(
              key: PlayerKeys.audio,
              value: _PlaybackOverflowAction.audio,
              child: _PlaybackSettingRow(
                label: l10n.audioTrack,
                value: _currentAudioLabel(controller, l10n),
              ),
            ),
          if (controller.isTranscode)
            PopupMenuItem(
              key: PlayerKeys.quality,
              value: _PlaybackOverflowAction.quality,
              child: _PlaybackSettingRow(
                label: l10n.quality,
                value: _qualityLabel(l10n, controller.maxStreamingBitrate),
              ),
            ),
          if (controller.canSwitchMediaSource)
            PopupMenuItem(
              key: PlayerKeys.mediaSource,
              value: _PlaybackOverflowAction.mediaSource,
              child: _PlaybackSettingRow(
                label: l10n.mediaSource,
                value: _compactMediaSourceLabel(
                  controller.resolved?.mediaSource.label ?? l10n.mediaSource,
                ),
                valueKey: PlayerKeys.mediaSourceLabel,
              ),
            ),
          if (controller.canSetManualSkip)
            PopupMenuItem(
              key: PlayerKeys.skipSettings,
              value: _PlaybackOverflowAction.skip,
              child: _PlaybackSettingRow(
                label: l10n.skipSettings,
                value: _skipSummary(controller, l10n),
              ),
            ),
        ];
      },
    );
  }

  Future<void> _openAction(
    BuildContext context,
    _PlaybackOverflowAction action,
  ) async {
    if (!context.mounted) {
      return;
    }
    final position = _buttonMenuPosition(context);
    switch (action) {
      case _PlaybackOverflowAction.speed:
        final rate = await showMenu<double>(
          context: context,
          position: position,
          constraints: _controlMenuConstraints,
          items: [
            for (final value in kPlaybackRateLadder)
              CheckedPopupMenuItem(
                value: value,
                checked: value == controller.playbackRate,
                child: Text(_rateLabel(value)),
              ),
          ],
        );
        if (rate != null && context.mounted) {
          unawaited(controller.setRate(rate));
        }
      case _PlaybackOverflowAction.audio:
        final index = await showMenu<int>(
          context: context,
          position: position,
          constraints: _controlMenuConstraints,
          items: [
            for (final track in controller.audioTracks)
              CheckedPopupMenuItem(
                value: track.index,
                checked: track.index == controller.audioStreamIndex,
                child: Text(track.label),
              ),
          ],
        );
        if (index != null && context.mounted) {
          unawaited(controller.setAudio(index));
        }
      case _PlaybackOverflowAction.quality:
        final bitrate = await showMenu<int>(
          context: context,
          position: position,
          constraints: _controlMenuConstraints,
          items: [
            CheckedPopupMenuItem(
              value: kTranscodeBitrates.first,
              checked:
                  controller.maxStreamingBitrate == kTranscodeBitrates.first ||
                  !kTranscodeBitrates.contains(controller.maxStreamingBitrate),
              child: Text(AppLocalizations.of(context).qualityAuto),
            ),
            for (final value in kTranscodeBitrates.skip(1))
              CheckedPopupMenuItem(
                value: value,
                checked: controller.maxStreamingBitrate == value,
                child: Text(
                  AppLocalizations.of(context).qualityMbps(value ~/ 1000000),
                ),
              ),
          ],
        );
        if (bitrate != null && context.mounted) {
          unawaited(controller.setMaxBitrate(bitrate));
        }
      case _PlaybackOverflowAction.mediaSource:
        if (controller.loading) {
          return;
        }
        final sourceId = await showMenu<String>(
          context: context,
          position: position,
          constraints: _controlMenuConstraints,
          items: [
            for (final source in controller.mediaSources)
              CheckedPopupMenuItem(
                value: source.id,
                checked: source.id == controller.resolved?.mediaSource.id,
                child: Text(source.label),
              ),
          ],
        );
        if (sourceId != null && context.mounted) {
          unawaited(controller.switchMediaSource(sourceId));
        }
      case _PlaybackOverflowAction.skip:
        final selected = await showMenu<String>(
          context: context,
          position: position,
          constraints: _controlMenuConstraints,
          items: [
            CheckedPopupMenuItem(
              value: 'off',
              checked:
                  controller.manualIntroSkipSeconds == null &&
                  controller.manualOutroSkipSeconds == null,
              child: Text(AppLocalizations.of(context).skipManualOff),
            ),
            for (final seconds in kManualSkipChoices)
              CheckedPopupMenuItem(
                value: 'intro:$seconds',
                checked: controller.manualIntroSkipSeconds == seconds,
                child: Text(
                  AppLocalizations.of(context).skipIntroSeconds(seconds),
                ),
              ),
            for (final seconds in kManualSkipChoices)
              CheckedPopupMenuItem(
                value: 'outro:$seconds',
                checked: controller.manualOutroSkipSeconds == seconds,
                child: Text(
                  AppLocalizations.of(context).skipOutroSeconds(seconds),
                ),
              ),
          ],
        );
        if (selected == null || !context.mounted) {
          return;
        }
        if (selected == 'off') {
          unawaited(controller.clearManualSkip());
          return;
        }
        final parts = selected.split(':');
        final seconds = int.tryParse(parts.length > 1 ? parts[1] : '');
        if (seconds == null) {
          return;
        }
        if (selected.startsWith('intro:')) {
          unawaited(controller.setManualIntroSkip(seconds));
        } else if (selected.startsWith('outro:')) {
          unawaited(controller.setManualOutroSkip(seconds));
        }
    }
  }
}

enum _PlaybackOverflowAction { speed, quality, audio, mediaSource, skip }

/// 溢出菜单第一层:左侧类别,右侧当前值。
class _PlaybackSettingRow extends StatelessWidget {
  const _PlaybackSettingRow({
    required this.label,
    required this.value,
    this.valueKey,
  });

  final String label;
  final String value;
  final Key? valueKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(child: Text(label)),
        const SizedBox(width: AppSpacing.md),
        Text(
          value,
          key: valueKey,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
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

String _qualityLabel(AppLocalizations l10n, int bitrate) {
  if (bitrate == kTranscodeBitrates.first ||
      !kTranscodeBitrates.contains(bitrate)) {
    return l10n.qualityAuto;
  }
  return l10n.qualityMbps(bitrate ~/ 1000000);
}

String _currentAudioLabel(PlayerController controller, AppLocalizations l10n) {
  for (final track in controller.audioTracks) {
    if (track.index == controller.audioStreamIndex) {
      return track.label;
    }
  }
  return l10n.audioTrack;
}

String _skipSummary(PlayerController controller, AppLocalizations l10n) {
  final intro = controller.manualIntroSkipSeconds;
  final outro = controller.manualOutroSkipSeconds;
  if (intro == null && outro == null) {
    return l10n.skipManualOff;
  }
  if (intro != null && outro != null) {
    return '${l10n.skipIntroSeconds(intro)} · ${l10n.skipOutroSeconds(outro)}';
  }
  if (intro != null) {
    return l10n.skipIntroSeconds(intro);
  }
  return l10n.skipOutroSeconds(outro!);
}

String _compactMediaSourceLabel(String label, {int maxChars = 12}) {
  final trimmed = label.trim();
  if (trimmed.length <= maxChars) {
    return trimmed;
  }
  return '${trimmed.substring(0, maxChars - 1)}…';
}

RelativeRect _buttonMenuPosition(BuildContext context) {
  final box = context.findRenderObject() as RenderBox?;
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
  if (box == null || overlay == null) {
    return RelativeRect.fill;
  }
  return RelativeRect.fromRect(
    Rect.fromPoints(
      box.localToGlobal(Offset.zero, ancestor: overlay),
      box.localToGlobal(box.size.bottomRight(Offset.zero), ancestor: overlay),
    ),
    Offset.zero & overlay.size,
  );
}

/// 弹幕设置菜单:状态回显 + 显示参数(不透明度/字号/速度/区域/密度)
/// + 手动搜索 + 自定义服务不可用时的回退入口。
class _DanmakuSettingsMenu extends StatelessWidget {
  const _DanmakuSettingsMenu({required this.danmaku, this.onSearch});

  static const List<double> _opacityChoices = [0.25, 0.5, 0.75, 1];
  static const List<double> _fontChoices = [0.5, 0.75, 1, 1.25, 1.5, 2];
  static const List<double> _speedChoices = [0.5, 1, 1.5, 2];
  static const List<double> _areaChoices = [0.25, 0.5, 0.75, 1];
  static const List<int> _densityChoices = [10, 20, 40];

  final DanmakuController danmaku;
  final VoidCallback? onSearch;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return _ControlMenu<String>(
      key: const Key('player-danmaku-menu'),
      tooltip: l10n.danmaku,
      icon: danmaku.danmakuOn ? Icons.forum_rounded : Icons.forum_outlined,
      iconColor: danmaku.danmakuOn ? scheme.primary : null,
      onSelected: (value) {
        if (value == 'toggle') {
          unawaited(danmaku.toggleDanmaku());
          return;
        }
        if (value == 'search') {
          onSearch?.call();
          return;
        }
        if (value == 'fallback') {
          unawaited(danmaku.useOfficialSource());
          return;
        }
        final parts = value.split(':');
        if (parts.length < 2) {
          return;
        }
        if (parts[0] == 'density') {
          final unlimited = parts[1] == 'unlimited';
          final cap = int.tryParse(parts[1]);
          if (!unlimited && cap == null) {
            return;
          }
          unawaited(
            danmaku.setDisplay(
              danmaku.display.copyWith(
                maxVisibleCount: cap,
                unlimitedDensity: unlimited,
              ),
            ),
          );
          return;
        }
        final parsed = double.tryParse(parts[1]);
        if (parsed == null) {
          return;
        }
        unawaited(
          danmaku.setDisplay(
            danmaku.display.copyWith(
              opacity: parts[0] == 'opacity' ? parsed : null,
              fontScale: parts[0] == 'font' ? parsed : null,
              speed: parts[0] == 'speed' ? parsed : null,
              areaFraction: parts[0] == 'area' ? parsed : null,
            ),
          ),
        );
      },
      items: [
        CheckedPopupMenuItem(
          value: 'toggle',
          checked: danmaku.danmakuOn,
          child: Text(l10n.danmaku),
        ),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          enabled: false,
          height: AppSpacing.lg,
          child: Text(
            _statusText(l10n),
            key: const Key('player-danmaku-status'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        _section(theme, l10n.danmakuOpacity),
        for (final choice in _opacityChoices)
          CheckedPopupMenuItem(
            value: 'opacity:$choice',
            checked: _near(danmaku.display.opacity, choice),
            child: Text(_percentLabel(choice)),
          ),
        _section(theme, l10n.danmakuFontSize),
        for (final choice in _fontChoices)
          CheckedPopupMenuItem(
            value: 'font:$choice',
            checked: _near(danmaku.display.fontScale, choice),
            child: Text(_percentLabel(choice)),
          ),
        _section(theme, l10n.danmakuSpeed),
        for (final choice in _speedChoices)
          CheckedPopupMenuItem(
            value: 'speed:$choice',
            checked: _near(danmaku.display.speed, choice),
            child: Text(_percentLabel(choice)),
          ),
        _section(theme, l10n.danmakuDisplayArea),
        for (final choice in _areaChoices)
          CheckedPopupMenuItem(
            value: 'area:$choice',
            checked: _near(danmaku.display.areaFraction, choice),
            child: Text(_percentLabel(choice)),
          ),
        _section(theme, l10n.danmakuDensity),
        CheckedPopupMenuItem(
          value: 'density:unlimited',
          checked: danmaku.display.maxVisibleCount == null,
          child: Text(l10n.danmakuUnlimited),
        ),
        for (final choice in _densityChoices)
          CheckedPopupMenuItem(
            value: 'density:$choice',
            checked: danmaku.display.maxVisibleCount == choice,
            child: Text('$choice'),
          ),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          value: 'search',
          height: 40,
          child: Text(l10n.danmakuSearch),
        ),
        if (danmaku.status == DanmakuStatus.customUnreachable)
          PopupMenuItem<String>(
            value: 'fallback',
            height: 40,
            child: Text(l10n.danmakuUseOfficial),
          ),
      ],
    );
  }

  /// 菜单顶部状态行:来源 + 匹配状态回显。
  String _statusText(AppLocalizations l10n) {
    final source = danmaku.usesCustomSource
        ? l10n.danmakuCustom
        : l10n.danmakuOfficial;
    final String state;
    switch (danmaku.status) {
      case DanmakuStatus.active:
        state = danmaku.matchedTitle == null || danmaku.matchedTitle!.isEmpty
            ? (danmaku.hasComments ? '' : l10n.danmakuNoComments)
            : l10n.danmakuMatchedTo(danmaku.matchedTitle!);
      case DanmakuStatus.loading:
        state = l10n.danmakuMatching;
      case DanmakuStatus.noMatch:
        state = l10n.danmakuNoMatch;
      case DanmakuStatus.customUnreachable:
        state = l10n.danmakuCustomUnreachable;
      case DanmakuStatus.unreachable:
        state = l10n.danmakuOfficialUnreachable;
      case DanmakuStatus.off:
      case DanmakuStatus.idle:
        state = '';
    }
    return state.isEmpty ? source : '$source · $state';
  }

  static PopupMenuItem<String> _section(ThemeData theme, String label) {
    return PopupMenuItem<String>(
      enabled: false,
      height: AppSpacing.xl,
      child: Text(
        label,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  static String _percentLabel(double value) => '${(value * 100).round()}%';

  static bool _near(double a, double b) => (a - b).abs() < 0.01;
}

/// 自定义弹幕服务不可用提示:明确提示并可一键回退官方源。
class _DanmakuSourceBanner extends StatelessWidget {
  const _DanmakuSourceBanner({required this.controller});

  final DanmakuController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
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
              key: const Key('player-danmaku-source-banner'),
              type: MaterialType.transparency,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.wifi_off_rounded, size: 18, color: scheme.primary),
                  const SizedBox(width: AppSpacing.xs),
                  Flexible(child: Text(l10n.danmakuCustomUnreachable)),
                  const SizedBox(width: AppSpacing.sm),
                  FilledButton.tonal(
                    key: const Key('player-danmaku-use-official'),
                    onPressed: () => unawaited(controller.useOfficialSource()),
                    child: Text(l10n.danmakuUseOfficial),
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

/// 弹幕手动搜索结果:动画展开为分集,选择后加载该集弹幕并写入按剧记忆。
class _DanmakuSearchResults extends StatelessWidget {
  const _DanmakuSearchResults({required this.danmaku, required this.animes});

  final DanmakuController danmaku;
  final List<DanmakuAnime> animes;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.danmakuSearchTitle),
      content: SizedBox(
        width: 460,
        height: 380,
        child: animes.isEmpty
            ? Center(child: Text(l10n.danmakuNoMatch))
            : ListView.builder(
                itemCount: animes.length,
                itemBuilder: (context, index) {
                  final anime = animes[index];
                  return ExpansionTile(
                    key: Key('player-danmaku-anime-${anime.animeId}'),
                    dense: true,
                    title: Text(
                      anime.animeTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: anime.type == null ? null : Text(anime.type!),
                    children: [
                      for (final episode in anime.episodes)
                        ListTile(
                          dense: true,
                          key: Key(
                            'player-danmaku-episode-${episode.episodeId}',
                          ),
                          title: Text(episode.episodeTitle),
                          onTap: () {
                            unawaited(danmaku.selectEpisode(anime, episode));
                            Navigator.pop(context);
                          },
                        ),
                    ],
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(MaterialLocalizations.of(context).closeButtonLabel),
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

/// 控制层图标按钮:统一的暖白前景,供按钮行各处复用。
class _PlayerIconButton extends StatelessWidget {
  const _PlayerIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.iconSize = 24,
  });

  final String? tooltip;
  final double iconSize;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      color: scheme.onSurface,
      iconSize: iconSize,
      icon: Icon(icon),
    );
  }
}

const _subtitleOffToken = -1;

/// 倍速阶梯约 8 项需完整显示,避免菜单内滚动。
const _controlMenuConstraints = BoxConstraints(
  minWidth: 200,
  maxWidth: 360,
  maxHeight: 416,
);

/// 控制条右侧用图标打开菜单,长轨名只出现在弹出层。
///
/// 音轨/字幕/画质共用主题级 popupMenuTheme 外观,不做局部覆盖。
class _ControlMenu<T> extends StatelessWidget {
  const _ControlMenu({
    super.key,
    required this.tooltip,
    required this.items,
    required this.onSelected,
    this.icon,
    this.iconColor,
    this.child,
  }) : assert(icon != null || child != null);

  final String tooltip;
  final IconData? icon;
  final Color? iconColor;
  final Widget? child;
  final List<PopupMenuEntry<T>> items;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (child != null) {
      return PopupMenuButton<T>(
        tooltip: tooltip,
        onSelected: onSelected,
        constraints: _controlMenuConstraints,
        padding: EdgeInsets.zero,
        splashRadius: 20,
        itemBuilder: (context) => items,
        child: child,
      );
    }
    return PopupMenuButton<T>(
      tooltip: tooltip,
      onSelected: onSelected,
      constraints: _controlMenuConstraints,
      padding: EdgeInsets.zero,
      splashRadius: 20,
      icon: Icon(icon, color: iconColor ?? scheme.onSurface),
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
