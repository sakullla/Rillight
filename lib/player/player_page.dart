import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/widgets/app_error_view.dart';
import 'package:rillight/app/widgets/liquid_glass.dart';
import 'package:rillight/app/widgets/media_source_menu_tile.dart';
import 'package:rillight/app/widgets/skeleton.dart';
import 'package:rillight/app/window_chrome.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/device_profile.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_failure.dart';
import 'package:rillight/library/item_format.dart';
import 'package:rillight/media_image/media_image.dart';
import 'package:rillight/player/danmaku/danmaku_controller.dart';
import 'package:rillight/player/danmaku/danmaku_keys.dart';
import 'package:rillight/player/danmaku/danmaku_match_query.dart';
import 'package:rillight/player/danmaku/danmaku_panel.dart';
import 'package:rillight/player/danmaku/danmaku_renderer.dart';
import 'package:rillight/player/danmaku/dandanplay_models.dart';
import 'package:rillight/player/mpv_video_backend.dart';
import 'package:rillight/player/network_throughput.dart';
import 'package:rillight/player/playback_models.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_controller.dart';
import 'package:rillight/player/player_keys.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/player_window.dart';
import 'package:rillight/player/player_window_host.dart';
import 'package:rillight/player/video_backend.dart';

/// 播放器顶栏命中高度:内边距 + 标题行。剧集面板从这之下铺开,避免挡住关闭/置顶。
const double kPlayerChromeBarExtent =
    AppSpacing.sm + kWindowChromeHeight + AppSpacing.sm + AppSpacing.lg;

/// 顶栏实时网速占用宽度,给标题右侧留空,避免叠到读数上。
const double kPlayerNetworkSpeedExtent = 96;

/// 剧集行固定高度,给 ListView 按 index 做 O(1) jumpTo。
///
/// [Scrollable.ensureVisible] 只能滚到已经建出来的行;120 集时当前集
/// 往往还在 builder 窗口外,打开面板会停在第 1 集。行高固定后
/// `offset = index * extent` 不必先构建前面的行。
const double kPlayerEpisodeRowExtent = 112;

/// 把当前集放到视口约 [alignment] 处;打开面板用 jumpTo,不 animate,
/// 避免长列表滑过上百行。
double playerEpisodeListOffset({
  required int index,
  required int itemCount,
  required double itemExtent,
  required double viewport,
  double alignment = 0.25,
}) {
  if (index <= 0 || itemCount <= 0 || itemExtent <= 0) {
    return 0;
  }
  final maxOffset = itemCount * itemExtent > viewport
      ? itemCount * itemExtent - viewport
      : 0.0;
  if (maxOffset <= 0) {
    return 0;
  }
  final raw = index * itemExtent - viewport * alignment;
  if (raw < 0) {
    return 0;
  }
  if (raw > maxOffset) {
    return maxOffset;
  }
  return raw;
}

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
    this.onOpenItemDetail,
  });

  final String itemId;
  final bool autoResume;
  final String? mediaSourceId;
  final int? audioStreamIndex;
  final int? subtitleStreamIndex;
  final int? startTimeTicks;
  final VoidCallback? onClosed;
  final ValueChanged<String>? onOpenItem;
  final void Function(String itemId, {String? seasonId})? onOpenItemDetail;

  @override
  State<PlayerPage> createState() => PlayerPageState();
}

class PlayerPageState extends State<PlayerPage> {
  PlayerController? controller;
  DanmakuController? _danmaku;
  bool _dragSeeking = false;
  double _dragValue = 0;
  bool _episodesOpen = false;
  bool _danmakuPanelOpen = false;
  bool _danmakuSearchOpen = false;

  /// 弹幕层一旦挂上就别随开关卸掉:开关时拆全屏 CustomPaint
  /// 叠在 Texture 上,Impeller 会把后续点击吞掉。
  bool _danmakuLayerPinned = false;
  String? _danmakuLayerItemId;
  final FocusNode _playerShortcuts = FocusNode(debugLabel: 'player-shortcuts');

  bool _pointerNearWindowEdge(Offset local) {
    final size = MediaQuery.sizeOf(context);
    const margin = 12.0;
    // Close/minimize sit on the top-right. Treating that corner as an edge
    // leaves the OSD hidden, so the click hits the drag layer instead.
    return local.dx < margin || local.dy > size.height - margin;
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
      onOpenItemDetail: widget.onOpenItemDetail,
    );
    controller = created;
    created.addListener(_onController);
    final danmaku = DanmakuController(
      settingsStore: bindings.settingsStore,
      client: bindings.danmakuClient,
    );
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
    _playerShortcuts.dispose();
    super.dispose();
  }

  void _onController() {
    final current = controller;
    final danmaku = _danmaku;
    if (current != null &&
        ((_danmakuLayerItemId != null &&
                _danmakuLayerItemId != current.itemId) ||
            current.loading ||
            current.error != null ||
            current.playbackEnded)) {
      _danmakuLayerPinned = false;
      _danmakuLayerItemId = null;
    }
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
    final danmaku = _danmaku;
    final current = controller;
    if (danmaku != null &&
        danmaku.hasComments &&
        current != null &&
        !current.loading &&
        current.error == null &&
        !current.playbackEnded) {
      _danmakuLayerPinned = true;
      _danmakuLayerItemId = current.itemId;
    }
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
    final fileName = danmakuMatchFileName(
      pathBaseName: _baseName(path),
      seriesTitle: item.seriesName,
      title: item.name,
      seasonIndex: item.parentIndexNumber,
      episodeIndex: item.indexNumber,
      height: resolved.mediaSource.height,
      productionYear: item.productionYear,
    );
    return DanmakuEpisodeContext(
      itemId: current.itemId,
      mediaSourceId: resolved.mediaSource.id,
      seriesId: item.seriesId,
      seriesTitle: item.seriesName,
      title: item.name,
      fileName: fileName,
      fileSize: resolved.mediaSource.size ?? 0,
      episodeIndex: item.indexNumber,
      seasonIndex: item.parentIndexNumber,
      streamUrl: resolved.isTranscode ? null : resolved.streamUrl,
      duration: current.duration > Duration.zero
          ? current.duration
          : durationFromTicks(resolved.mediaSource.runTimeTicks ?? 0),
      isMovie: !item.isEpisode,
      productionYear: item.productionYear,
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
    final onClosed = widget.onClosed;
    if (onClosed != null) {
      onClosed();
      return;
    }
    if (!mounted) {
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
    if (_danmakuPanelOpen) {
      setState(() => _danmakuPanelOpen = false);
    }
    if (_danmakuSearchOpen) {
      _closeDanmakuSearch();
    }
    unawaited(current.loadEpisodeList());
    current.setControlsPinned(true);
    setState(() => _episodesOpen = true);
  }

  void _closeEpisodeList() {
    if (!_episodesOpen) {
      return;
    }
    if (!_danmakuPanelOpen && !_danmakuSearchOpen) {
      controller?.setControlsPinned(false);
    }
    setState(() => _episodesOpen = false);
  }

  Future<void> _openDanmakuPanel() async {
    final danmaku = _danmaku;
    if (danmaku == null) {
      return;
    }
    if (_danmakuPanelOpen) {
      _closeDanmakuPanel();
      return;
    }
    if (_episodesOpen) {
      _closeEpisodeList();
    }
    if (_danmakuSearchOpen) {
      _closeDanmakuSearch();
    }
    await danmaku.refreshFromStore();
    if (!mounted) {
      return;
    }
    controller?.setControlsPinned(true);
    setState(() => _danmakuPanelOpen = true);
  }

  void _closeDanmakuPanel() {
    if (!_danmakuPanelOpen) {
      return;
    }
    if (!_episodesOpen && !_danmakuSearchOpen) {
      controller?.setControlsPinned(false);
    }
    setState(() => _danmakuPanelOpen = false);
  }

  void _openDanmakuSearch() {
    if (_danmaku == null || !_danmaku!.isConfigured) {
      return;
    }
    if (_episodesOpen) {
      setState(() => _episodesOpen = false);
    }
    if (_danmakuPanelOpen) {
      setState(() => _danmakuPanelOpen = false);
    }
    controller?.setControlsPinned(true);
    setState(() => _danmakuSearchOpen = true);
  }

  void _closeDanmakuSearch() {
    if (!_danmakuSearchOpen) {
      return;
    }
    setState(() => _danmakuSearchOpen = false);
    if (!_episodesOpen && !_danmakuPanelOpen) {
      controller?.setControlsPinned(false);
      controller?.onUserActivity();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _danmakuSearchOpen) {
        return;
      }
      _playerShortcuts.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final current = controller;
    if (current == null) {
      return const ColoredBox(color: Colors.black);
    }
    return LiquidGlassBackdrop(
      enabled: false,
      child: Focus(
        focusNode: _playerShortcuts,
        autofocus: true,
        descendantsAreFocusable: _danmakuSearchOpen || _danmakuPanelOpen,
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent) {
            return KeyEventResult.ignored;
          }
          if (_danmakuSearchOpen) {
            if (event.logicalKey == LogicalKeyboardKey.escape) {
              _closeDanmakuSearch();
              return KeyEventResult.handled;
            }
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
            if (_danmakuSearchOpen) {
              _closeDanmakuSearch();
              return KeyEventResult.handled;
            }
            if (_danmakuPanelOpen) {
              _closeDanmakuPanel();
              return KeyEventResult.handled;
            }
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
                // 剧集/弹幕侧栏自己吃滚轮;根 Listener 是 translucent,
                // 不拦住的话滑列表会把音量一起改掉。
                if (_episodesOpen || _danmakuPanelOpen || _danmakuSearchOpen) {
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
                  current.onPointerHover();
                },
                onExit: (_) {
                  current.hideControlsOnPointerExit();
                },
                cursor:
                    (!current.controlsVisible &&
                        current.nextEpisode == null &&
                        !current.playbackEnded &&
                        !_episodesOpen &&
                        !_danmakuPanelOpen &&
                        !_danmakuSearchOpen)
                    ? SystemMouseCursors.none
                    : MouseCursor.defer,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    RepaintBoundary(
                      child: IgnorePointer(
                        child: current.backend.buildView(
                          key: const ValueKey('player-video-surface'),
                        ),
                      ),
                    ),
                    // 弹幕只绘制,叠在点击层下面,避免 CustomPaint 吃掉单击。
                    if (_danmakuOverlayVisible(current))
                      Positioned.fill(
                        child: IgnorePointer(
                          child: TickerMode(
                            enabled: _danmaku!.danmakuOn,
                            child: DanmakuView(controller: _danmaku!),
                          ),
                        ),
                      ),
                    Positioned.fill(
                      child: GestureDetector(
                        key: PlayerKeys.surface,
                        behavior: HitTestBehavior.opaque,
                        onTapUp: (_) {
                          if (_danmakuPanelOpen) {
                            _closeDanmakuPanel();
                            return;
                          }
                          current.toggleControls();
                        },
                        child: const SizedBox.expand(),
                      ),
                    ),
                    if (current.loading || current.isBuffering)
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
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurface
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
                        onDanmakuSearch: _openDanmakuPanel,
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
                            current.disconnectDetail ??
                            l10n.playbackDisconnected,
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
                        text: _subtitleNoticeText(
                          l10n,
                          current.subtitleNotice!,
                        ),
                      ),
                    if (current.trackFailure != null)
                      _Banner(
                        key: const ValueKey('player-track-failure'),
                        text:
                            '${l10n.audioTrack} / ${l10n.subtitleTrack}：${l10n.errorLoadFailed}',
                        onDismiss: current.dismissTrackFailure,
                      ),
                    if (_danmaku?.status == DanmakuStatus.customUnreachable &&
                        !current.loading)
                      _DanmakuSourceBanner(controller: _danmaku!),
                    _PlayerChromeBar(
                      controller: current,
                      visible: current.controlsVisible,
                    ),
                    if (_danmaku != null &&
                        _danmaku!.isConfigured &&
                        _danmaku!.danmakuOn &&
                        !_danmakuPanelOpen &&
                        !_danmakuSearchOpen &&
                        !_episodesOpen &&
                        !current.loading &&
                        current.error == null &&
                        (_danmaku!.status == DanmakuStatus.noMatch))
                      _DanmakuMatchChip(onSearch: _openDanmakuSearch),
                    if (_danmakuPanelOpen && _danmaku != null)
                      DanmakuPanel(
                        danmaku: _danmaku!,
                        onClose: _closeDanmakuPanel,
                        onSearch: _openDanmakuSearch,
                      ),
                    if (_danmakuSearchOpen && _danmaku != null)
                      _DanmakuSearchPanel(
                        danmaku: _danmaku!,
                        initialKeyword: _danmakuSearchKeyword(),
                        onClose: _closeDanmakuSearch,
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
      ),
    );
  }

  /// 弹幕层一旦画过就钉住。开关只停绘制,不卸全屏层,避免 Impeller
  /// 在 Texture 上拆装 CustomPaint 后点不穿。
  bool _danmakuOverlayVisible(PlayerController current) {
    final danmaku = _danmaku;
    if (danmaku == null ||
        current.loading ||
        current.error != null ||
        current.playbackEnded) {
      return false;
    }
    if (_danmakuLayerPinned && _danmakuLayerItemId == current.itemId) {
      return true;
    }
    return danmaku.danmakuOn && danmaku.hasComments;
  }

  String _danmakuSearchKeyword() {
    final matched = _danmaku?.matchedTitle?.trim();
    if (matched != null && matched.isNotEmpty) {
      return matched;
    }
    final series = controller?.item?.seriesName?.trim();
    if (series != null && series.isNotEmpty) {
      return series;
    }
    return controller?.item?.name ?? '';
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
    // 标题和窗口钮必须在同一层全宽淡出。右上角单独一块小 Opacity
    // 叠在 mpv Texture 上时,Impeller 常常不把透明度合成进去,按钮会
    // 一直亮着。独立播放器没有系统关闭钮,指针移入画面会重新唤出 OSD。
    return Positioned(
      left: 0,
      right: 0,
      top: 0,
      height: kPlayerChromeBarExtent,
      child: _FadeThrough(
        visible: visible,
        child: Stack(
          children: [
            Positioned.fill(
              child: WindowDragArea(
                key: const Key('player-window-drag'),
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
                    padding: EdgeInsets.fromLTRB(
                      AppSpacing.md,
                      AppSpacing.sm,
                      AppSpacing.sm +
                          kTitleBarIconConstraints.maxWidth * 3 +
                          kPlayerNetworkSpeedExtent,
                      AppSpacing.lg,
                    ),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: title.isEmpty
                          ? const SizedBox.shrink()
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
            ),
            Positioned(
              top: AppSpacing.sm,
              right: AppSpacing.sm,
              height: kWindowChromeHeight + AppSpacing.sm,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (controller.resolved != null &&
                      !controller.playbackEnded &&
                      controller.error == null)
                    Tooltip(
                      message: l10n.playerNetworkSpeedTooltip,
                      child: Padding(
                        padding: const EdgeInsets.only(right: AppSpacing.sm),
                        child: NetworkSpeedReadout(
                          key: PlayerKeys.networkSpeed,
                          bytesPerSecond: controller.cacheSpeedBytesPerSec,
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.86,
                          ),
                        ),
                      ),
                    ),
                  _PlayerChromeIconButton(
                    buttonKey: const Key('player-always-on-top'),
                    tooltip: controller.isAlwaysOnTop
                        ? l10n.alwaysOnTopOff
                        : l10n.alwaysOnTop,
                    color: controller.isAlwaysOnTop
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurface,
                    onPressed: () {
                      unawaited(controller.toggleAlwaysOnTop());
                    },
                    icon: controller.isAlwaysOnTop
                        ? Icons.push_pin_rounded
                        : Icons.push_pin_outlined,
                  ),
                  _PlayerChromeIconButton(
                    buttonKey: const Key('player-window-minimize'),
                    tooltip: l10n.minimizeWindow,
                    color: theme.colorScheme.onSurface,
                    onPressed: () {
                      unawaited(controller.minimize());
                    },
                    icon: Icons.remove_rounded,
                  ),
                  _PlayerChromeIconButton(
                    buttonKey: const Key('player-window-close'),
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).closeButtonTooltip,
                    color: theme.colorScheme.onSurface,
                    onPressed: () {
                      unawaited(controller.close());
                    },
                    icon: Icons.close_rounded,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 播放窗顶栏按钮:与主窗口搜索/会话钮同高同字号,避免默认 48 点 IconButton
/// 在标题栏里画出一块大方块。
class _PlayerChromeIconButton extends StatelessWidget {
  const _PlayerChromeIconButton({
    required this.buttonKey,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.color,
  });

  final Key buttonKey;
  final String tooltip;
  final IconData icon;
  final Color? color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final foreground = color ?? scheme.onSurface;
    return Tooltip(
      message: tooltip,
      preferBelow: true,
      child: IconButton(
        key: buttonKey,
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        constraints: kTitleBarIconConstraints,
        visualDensity: VisualDensity.compact,
        iconSize: 18,
        color: foreground,
        icon: Icon(icon),
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
                          style: _endedActionStyle(theme, filled: true),
                          icon: const Icon(Icons.replay_rounded),
                          label: Text(l10n.replay),
                        ),
                        if (hasSeries)
                          OutlinedButton.icon(
                            key: PlayerKeys.endedViewSeries,
                            onPressed: controller.openEndedSeries,
                            style: _endedActionStyle(theme),
                            icon: const Icon(Icons.video_library_outlined),
                            label: Text(l10n.viewSeries),
                          ),
                        OutlinedButton.icon(
                          key: PlayerKeys.endedClose,
                          onPressed: () => unawaited(controller.close()),
                          style: _endedActionStyle(theme),
                          icon: const Icon(Icons.close_rounded),
                          label: Text(l10n.closePlayer),
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

ButtonStyle _endedActionStyle(ThemeData theme, {bool filled = false}) {
  final label = theme.textTheme.labelLarge?.copyWith(
    fontSize: 15,
    height: 1.25,
    fontWeight: FontWeight.w600,
    letterSpacing: 0,
  );
  const size = Size(0, 44);
  const padding = EdgeInsets.symmetric(
    horizontal: AppSpacing.lg,
    vertical: AppSpacing.sm,
  );
  if (filled) {
    return FilledButton.styleFrom(
      minimumSize: size,
      padding: padding,
      textStyle: label,
      iconSize: 20,
    );
  }
  return OutlinedButton.styleFrom(
    minimumSize: size,
    padding: padding,
    textStyle: label,
    iconSize: 20,
  );
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
      bottom: controller.controlsVisible ? 112 : AppSpacing.xl,
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
                  const SizedBox(width: AppSpacing.sm),
                  // 无论是否倒计时,都可以点击关闭本次推荐。
                  IconButton(
                    key: PlayerKeys.nextEpisodeCancel,
                    tooltip: l10n.cancelNextEpisode,
                    onPressed: controller.cancelNextEpisode,
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close_rounded, size: 18),
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
              FilledButton(
                key: PlayerKeys.nextEpisodePlay,
                onPressed: controller.playNextEpisode,
                child: Text(l10n.playNextEpisode),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 播放到片头/片尾区间时右下角的跳过按钮:点击跳到区间终点。
/// 用贴合文字的玻璃胶囊,不再套主题 [FilledButton],避免两侧空一截。
class _SkipSegmentButton extends StatelessWidget {
  const _SkipSegmentButton({required this.controller});

  final PlayerController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final segment = controller.activeSkipSegment!;
    return Positioned(
      right: AppSpacing.xl,
      bottom: 112,
      child: LiquidGlass(
        kind: LiquidGlassKind.pill,
        child: Material(
          key: const Key('player-skip-segment'),
          type: MaterialType.transparency,
          child: InkWell(
            onTap: () => unawaited(controller.skipCurrentSegment()),
            borderRadius: BorderRadius.circular(999),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.xs,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.fast_forward_rounded,
                    size: 18,
                    color: scheme.onSurface,
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  Text(
                    segment.kind == PlayerSkipKind.outro
                        ? l10n.skipOutro
                        : l10n.skipIntro,
                    style: theme.textTheme.labelLarge,
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
            width: 400,
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
                            _episodePanelTitle(l10n),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: scheme.onSurface,
                            ),
                          ),
                        ),
                        if (seasons.length > 1)
                          _SeasonPicker(controller: controller)
                        else if (currentSeason.length == 1)
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: AppSpacing.sm,
                            ),
                            child: Text(
                              currentSeason.first.name,
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
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
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _episodePanelTitle(AppLocalizations l10n) {
    final seriesName = controller.item?.seriesName?.trim();
    if (seriesName != null && seriesName.isNotEmpty) {
      return seriesName;
    }
    return l10n.playerEpisodes;
  }

  Widget _episodeListBody(
    BuildContext context,
    AppLocalizations l10n,
    ColorScheme scheme,
  ) {
    if (controller.episodeListLoading && controller.episodes.isEmpty) {
      return ListView.separated(
        padding: EdgeInsets.zero,
        itemCount: 6,
        separatorBuilder: (context, index) =>
            const SizedBox(height: AppSpacing.xxs),
        itemBuilder: (context, index) => const _EpisodeRowSkeleton(),
      );
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
    return _EpisodeListView(
      episodes: controller.episodes,
      currentId: controller.itemId,
      currentIndexNumber: controller.item?.indexNumber,
      currentSeasonId: controller.item?.seasonId,
      hasEarlier: controller.hasEarlierEpisodes,
      hasMore: controller.hasMoreEpisodes,
      loadingEarlier: controller.episodeLoadingEarlier,
      loadingMore: controller.episodeLoadingMore,
      progressFor: (episode, isCurrent) => _episodeProgress(episode, isCurrent),
      onPlay: (episode) {
        unawaited(controller.playEpisode(episode));
      },
      onLoadEarlier: () => unawaited(controller.loadEarlierEpisodes()),
      onLoadMore: () => unawaited(controller.loadMoreEpisodes()),
    );
  }

  double _episodeProgress(EmbyItem episode, bool isCurrent) {
    if (isCurrent) {
      final duration = controller.duration;
      if (duration > Duration.zero) {
        return (controller.position.inMilliseconds / duration.inMilliseconds)
            .clamp(0.0, 1.0);
      }
    }
    return episode.playbackProgress;
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

/// 单集行:16:9 缩略图 + 集号标题 + 时长/进度 + 简介,当前集高亮。
/// 固定高度交给外层 [itemExtent],内部用 Flexible 吃掉多余文案,避免 ListTile 撑破。
class _EpisodeRow extends StatefulWidget {
  const _EpisodeRow({
    required this.episode,
    required this.isCurrent,
    required this.progress,
    required this.onTap,
  });

  static const thumbWidth = 128.0;
  static const thumbHeight = thumbWidth * 9 / 16;

  final EmbyItem episode;
  final bool isCurrent;
  final double progress;
  final VoidCallback onTap;

  @override
  State<_EpisodeRow> createState() => _EpisodeRowState();
}

class _EpisodeRowState extends State<_EpisodeRow> {
  OverlayEntry? _hoverEntry;
  Timer? _showTimer;
  Timer? _hideTimer;

  bool get _isCurrent => widget.isCurrent;
  EmbyItem get episode => widget.episode;

  @override
  void dispose() {
    _showTimer?.cancel();
    _hideTimer?.cancel();
    _hoverEntry?.remove();
    _hoverEntry = null;
    super.dispose();
  }

  void _onEnter() {
    _hideTimer?.cancel();
    _showTimer ??= Timer(const Duration(milliseconds: 350), _showCard);
  }

  void _onExit() {
    _showTimer?.cancel();
    _showTimer = null;
    _scheduleHide();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(milliseconds: 300), _removeCard);
  }

  void _cancelHide() {
    _hideTimer?.cancel();
    _hideTimer = null;
  }

  void _removeCard() {
    _hoverEntry?.remove();
    _hoverEntry = null;
  }

  void _showCard() {
    _showTimer = null;
    if (!mounted || _hoverEntry != null) {
      return;
    }
    final overlay = Overlay.maybeOf(context);
    final box = context.findRenderObject();
    if (overlay == null || box is! RenderBox || !box.attached) {
      return;
    }
    final target = box.localToGlobal(Offset.zero);
    final rowSize = box.size;
    final screen = MediaQuery.sizeOf(context);
    const cardWidth = 320.0;
    const gap = 12.0;
    // 面板在窗口右侧,卡片优先弹到行左侧(视频区上方),空间不足再弹右侧。
    var left = target.dx - cardWidth - gap;
    if (left < 8) {
      left = target.dx + rowSize.width + gap;
    }
    if (left + cardWidth > screen.width - 8) {
      left = (screen.width - cardWidth - 8).clamp(8.0, double.infinity);
    }
    // 卡片估算高:缩略图 + 文本区(简介上限 148 + 标题/元信息/按钮)。
    final cardHeight = (cardWidth * 9 / 16) + 320;
    var top = target.dy;
    if (top + cardHeight > screen.height - 8) {
      top = (screen.height - cardHeight - 8).clamp(8.0, double.infinity);
    }
    _hoverEntry = OverlayEntry(
      builder: (context) => _EpisodeHoverCard(
        episode: episode,
        left: left,
        top: top,
        width: cardWidth,
        onPlay: widget.onTap,
        onEnter: _cancelHide,
        onExit: _scheduleHide,
      ),
    );
    overlay.insert(_hoverEntry!);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final number = episode.indexNumber;
    final title = number == null ? episode.name : '$number. ${episode.name}';
    final played = episode.userData.played;
    final overview = _playerEpisodeOverview(episode.overview);
    final meta = <String>[
      ?runtimeLabel(l10n, episode),
      if (_isCurrent) l10n.nowPlayingEpisode,
      if (!_isCurrent && episode.canResume)
        l10n.playbackProgress((widget.progress * 100).round()),
    ];
    return MouseRegion(
      onEnter: (_) => _onEnter(),
      onExit: (_) => _onExit(),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              width: 3,
              color: _isCurrent ? scheme.primary : Colors.transparent,
            ),
          ),
        ),
        child: Material(
          color: _isCurrent
              ? scheme.surfaceContainerHighest
              : Colors.transparent,
          child: InkWell(
            key: Key('player-episode-${episode.id}'),
            onTap: widget.onTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.sm,
                AppSpacing.xs,
                AppSpacing.sm,
                AppSpacing.xs,
              ),
              child: Row(
                children: [
                  _EpisodeThumb(
                    episode: episode,
                    isCurrent: _isCurrent,
                    played: played,
                    progress: widget.progress,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: scheme.onSurface,
                            fontWeight: _isCurrent
                                ? FontWeight.w700
                                : FontWeight.w500,
                          ),
                        ),
                        if (meta.isNotEmpty) ...[
                          const SizedBox(height: AppSpacing.xxs),
                          Text(
                            meta.join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: _isCurrent
                                  ? scheme.primary
                                  : scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                        if (overview != null) ...[
                          const SizedBox(height: AppSpacing.xxs),
                          Expanded(
                            child: Text(
                              overview,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: scheme.onSurface.withValues(alpha: 0.72),
                                height: 1.35,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
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

/// 悬停详情卡:鼠标悬停剧集行 350ms 后弹出(Netflix 式 hover card),
/// 大图 + 标题 + 元信息 + 完整简介 + 播放按钮;移入卡片可交互,移出消失。
class _EpisodeHoverCard extends StatelessWidget {
  const _EpisodeHoverCard({
    required this.episode,
    required this.left,
    required this.top,
    required this.width,
    required this.onPlay,
    required this.onEnter,
    required this.onExit,
  });

  final EmbyItem episode;
  final double left;
  final double top;
  final double width;
  final VoidCallback onPlay;
  final VoidCallback onEnter;
  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final number = episode.indexNumber;
    final title = number == null ? episode.name : '$number. ${episode.name}';
    final overview = _playerEpisodeOverview(episode.overview);
    final meta = <String>[
      ?seasonEpisodeCode(episode),
      ?runtimeLabel(l10n, episode),
      if (episode.productionYear != null && episode.productionYear! > 0)
        '${episode.productionYear}',
    ];
    return Positioned(
      left: left,
      top: top,
      child: MouseRegion(
        onEnter: (_) => onEnter(),
        onExit: (_) => onExit(),
        child: Material(
          color: scheme.surfaceContainerHigh,
          elevation: 16,
          shadowColor: Colors.black.withValues(alpha: 0.5),
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.lg),
            side: BorderSide(
              color: Colors.white.withValues(alpha: AppGlass.edgeLight),
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            width: width,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                MediaImage(
                  key: ValueKey('episode-hover-${episode.id}'),
                  item: episode,
                  width: width,
                  height: width * 9 / 16,
                  preferThumb: true,
                  maxWidth: 640,
                ),
                Padding(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (meta.isNotEmpty) ...[
                        const SizedBox(height: AppSpacing.xxs),
                        Text(
                          meta.join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                      if (overview != null) ...[
                        const SizedBox(height: AppSpacing.xs),
                        // Overlay 中高度无界,Flexible 失效;
                        // 固定上限避免长简介把卡片撑出屏幕。
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 148),
                          child: SingleChildScrollView(
                            child: Text(
                              overview,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: scheme.onSurface.withValues(alpha: 0.78),
                                height: 1.4,
                              ),
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: AppSpacing.sm),
                      FilledButton.icon(
                        onPressed: onPlay,
                        icon: const Icon(Icons.play_arrow_rounded),
                        label: Text(
                          episode.canResume ? l10n.resumePlay : l10n.play,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EpisodeThumb extends StatelessWidget {
  const _EpisodeThumb({
    required this.episode,
    required this.isCurrent,
    required this.played,
    required this.progress,
  });

  final EmbyItem episode;
  final bool isCurrent;
  final bool played;
  final double progress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadii.sm),
      child: SizedBox(
        width: _EpisodeRow.thumbWidth,
        height: _EpisodeRow.thumbHeight,
        child: Stack(
          fit: StackFit.expand,
          children: [
            RepaintBoundary(
              child: MediaImage(
                key: ValueKey(episode.id),
                item: episode,
                width: _EpisodeRow.thumbWidth,
                height: _EpisodeRow.thumbHeight,
                preferThumb: true,
                maxWidth: 240,
              ),
            ),
            if (isCurrent)
              ColoredBox(
                color: scheme.scrim.withValues(alpha: 0.42),
                child: Icon(
                  Icons.play_arrow_rounded,
                  color: scheme.onSurface,
                  size: 28,
                ),
              ),
            if (played && !isCurrent)
              Align(
                alignment: Alignment.topRight,
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.xxs),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: scheme.scrim.withValues(alpha: 0.55),
                      shape: BoxShape.circle,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: Icon(
                        Icons.check_rounded,
                        size: 14,
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                ),
              ),
            if (progress > 0 && (isCurrent || episode.canResume))
              Align(
                alignment: Alignment.bottomCenter,
                child: _EpisodeProgressBar(value: progress),
              ),
          ],
        ),
      ),
    );
  }
}

class _EpisodeProgressBar extends StatelessWidget {
  const _EpisodeProgressBar({required this.value});

  final double value;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 3,
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.45),
        child: Align(
          alignment: Alignment.centerLeft,
          child: FractionallySizedBox(
            widthFactor: value.clamp(0.0, 1.0),
            child: ColoredBox(color: Theme.of(context).colorScheme.primary),
          ),
        ),
      ),
    );
  }
}

class _EpisodeRowSkeleton extends StatelessWidget {
  const _EpisodeRowSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SkeletonBlock(
            width: _EpisodeRow.thumbWidth,
            height: _EpisodeRow.thumbHeight,
          ),
          SizedBox(width: AppSpacing.sm),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SkeletonBlock(width: 168, height: 14),
              SizedBox(height: AppSpacing.xs),
              SkeletonBlock(width: 88, height: 12),
            ],
          ),
        ],
      ),
    );
  }
}

String? _playerEpisodeOverview(String? raw) {
  final text = raw?.trim();
  if (text == null || text.isEmpty) {
    return null;
  }
  final stripped = text
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), ' ')
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return stripped.isEmpty ? null : stripped;
}

/// 惰性剧集列表:按固定行高 jumpTo 当前集,长季不必先构建第 1..N 行。
class _EpisodeListView extends StatefulWidget {
  const _EpisodeListView({
    required this.episodes,
    required this.currentId,
    this.currentIndexNumber,
    this.currentSeasonId,
    required this.hasEarlier,
    required this.hasMore,
    required this.loadingEarlier,
    required this.loadingMore,
    required this.progressFor,
    required this.onPlay,
    required this.onLoadEarlier,
    required this.onLoadMore,
  });

  final List<EmbyItem> episodes;
  final String currentId;

  /// 当前集的集号与季 id;媒体库把同一集重复入库为多个条目时,
  /// 列表里的条目 id 与播放中的 itemId 不同,按 id 匹配不到,
  /// 需要按 季+集号 兜底定位与高亮。
  final int? currentIndexNumber;
  final String? currentSeasonId;
  final bool hasEarlier;
  final bool hasMore;
  final bool loadingEarlier;
  final bool loadingMore;
  final double Function(EmbyItem episode, bool isCurrent) progressFor;
  final ValueChanged<EmbyItem> onPlay;
  final VoidCallback onLoadEarlier;
  final VoidCallback onLoadMore;

  bool isCurrentEpisode(EmbyItem episode) {
    if (episode.id == currentId) {
      return true;
    }
    final indexNumber = currentIndexNumber;
    final seasonId = currentSeasonId;
    return indexNumber != null &&
        episode.indexNumber == indexNumber &&
        seasonId != null &&
        seasonId.isNotEmpty &&
        episode.seasonId == seasonId;
  }

  @override
  State<_EpisodeListView> createState() => _EpisodeListViewState();
}

class _EpisodeListViewState extends State<_EpisodeListView> {
  static const _estimatedViewport = 560.0;
  static const _edgeExtent = kPlayerEpisodeRowExtent * 2;

  late final ScrollController _scroll = ScrollController(
    initialScrollOffset: _offsetFor(_estimatedViewport),
  );

  int get _currentIndex {
    return widget.episodes.indexWhere(widget.isCurrentEpisode);
  }

  double _offsetFor(double viewport) {
    return playerEpisodeListOffset(
      index: _currentIndex < 0 ? 0 : _currentIndex,
      itemCount: widget.episodes.length,
      itemExtent: kPlayerEpisodeRowExtent,
      viewport: viewport,
    );
  }

  int _prependedCount(List<EmbyItem> previous, List<EmbyItem> next) {
    if (previous.isEmpty || next.length <= previous.length) {
      return 0;
    }
    final index = next.indexWhere((episode) => episode.id == previous.first.id);
    return index > 0 ? index : 0;
  }

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _jumpToCurrent();
      _maybeLoadEdges();
    });
  }

  @override
  void didUpdateWidget(_EpisodeListView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final prepended = _prependedCount(oldWidget.episodes, widget.episodes);
    if (prepended > 0 && _scroll.hasClients) {
      _scroll.position.correctBy(prepended * kPlayerEpisodeRowExtent);
    }
    final wasIn = oldWidget.episodes.any(oldWidget.isCurrentEpisode);
    final isIn = widget.episodes.any(widget.isCurrentEpisode);
    final shouldJump =
        oldWidget.currentId != widget.currentId || (!wasIn && isIn);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (shouldJump) {
        _jumpToCurrent();
      }
      _maybeLoadEdges();
    });
  }

  void _onScroll() => _maybeLoadEdges();

  void _maybeLoadEdges() {
    if (!mounted || !_scroll.hasClients) {
      return;
    }
    final position = _scroll.position;
    if (widget.hasEarlier &&
        !widget.loadingEarlier &&
        position.pixels <= _edgeExtent) {
      widget.onLoadEarlier();
    }
    if (widget.hasMore &&
        !widget.loadingMore &&
        position.pixels >= position.maxScrollExtent - _edgeExtent) {
      widget.onLoadMore();
    }
  }

  void _jumpToCurrent() {
    if (!mounted || !_scroll.hasClients) {
      return;
    }
    final viewport = _scroll.position.viewportDimension;
    if (viewport <= 0) {
      return;
    }
    final next = _offsetFor(viewport);
    if ((next - _scroll.offset).abs() < 1) {
      return;
    }
    _scroll.jumpTo(next);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scrollbar(
      controller: _scroll,
      child: ListView.builder(
        key: const Key('player-episodes-list'),
        controller: _scroll,
        itemExtent: kPlayerEpisodeRowExtent,
        itemCount: widget.episodes.length,
        itemBuilder: (context, index) {
          final episode = widget.episodes[index];
          final isCurrent = widget.isCurrentEpisode(episode);
          return ClipRect(
            child: SizedBox(
              height: kPlayerEpisodeRowExtent,
              child: _EpisodeRow(
                episode: episode,
                isCurrent: isCurrent,
                progress: widget.progressFor(episode, isCurrent),
                onTap: () => widget.onPlay(episode),
              ),
            ),
          );
        },
      ),
    );
  }
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
    final bufferValue = playerBufferFraction(
      buffer: controller.buffer,
      duration: controller.duration,
    );
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
              secondaryTrackValue: bufferValue,
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
    final danmakuController = danmaku;
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
        if (danmakuController != null)
          _DanmakuButton(
            danmaku: danmakuController,
            onPressed: onDanmakuSearch,
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
            icon: Icons.video_library_rounded,
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
                  controller.resolved?.mediaSource.presentation.compact ??
                      l10n.mediaSource,
                ),
                valueKey: PlayerKeys.mediaSourceLabel,
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
                child: MediaSourceMenuTile(view: source.presentation),
              ),
          ],
        );
        if (sourceId != null && context.mounted) {
          unawaited(controller.switchMediaSource(sourceId));
        }
    }
  }
}

enum _PlaybackOverflowAction { speed, quality, audio, mediaSource }

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

/// 控制条弹幕入口:打开设置面板(开关、搜索、显示参数都在面板里)。
class _DanmakuButton extends StatelessWidget {
  const _DanmakuButton({required this.danmaku, this.onPressed});

  final DanmakuController danmaku;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return _PlayerIconButton(
      key: DanmakuKeys.menu,
      tooltip: l10n.danmaku,
      onPressed: onPressed,
      icon: danmaku.danmakuOn
          ? Icons.chat_bubble_rounded
          : Icons.chat_bubble_outline_rounded,
      iconColor: danmaku.danmakuOn ? scheme.primary : null,
    );
  }
}

/// 未自动匹配时的提示胶囊:点开手动搜索,不必翻设置菜单。
class _DanmakuMatchChip extends StatelessWidget {
  const _DanmakuMatchChip({required this.onSearch});

  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Positioned(
      left: AppSpacing.xl,
      bottom: 112,
      child: LiquidGlass(
        kind: LiquidGlassKind.pill,
        child: Material(
          key: DanmakuKeys.matchChip,
          type: MaterialType.transparency,
          child: InkWell(
            onTap: () {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                onSearch();
              });
            },
            borderRadius: BorderRadius.circular(999),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.xs,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.subtitles_off_rounded,
                    size: 18,
                    color: scheme.onSurface,
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  Text(
                    l10n.danmakuMatchHint,
                    style: theme.textTheme.labelLarge,
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
              key: DanmakuKeys.sourceBanner,
              type: MaterialType.transparency,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.wifi_off_rounded, size: 18, color: scheme.primary),
                  const SizedBox(width: AppSpacing.xs),
                  Flexible(child: Text(l10n.danmakuCustomUnreachable)),
                  const SizedBox(width: AppSpacing.sm),
                  FilledButton.tonal(
                    key: DanmakuKeys.useOfficial,
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

/// 弹幕手动搜索:右侧实色面板,与剧集列表同一套浮层,不走透明 Dialog。
class _DanmakuSearchPanel extends StatefulWidget {
  const _DanmakuSearchPanel({
    required this.danmaku,
    required this.initialKeyword,
    required this.onClose,
  });

  final DanmakuController danmaku;
  final String initialKeyword;
  final VoidCallback onClose;

  @override
  State<_DanmakuSearchPanel> createState() => _DanmakuSearchPanelState();
}

class _DanmakuSearchPanelState extends State<_DanmakuSearchPanel> {
  late final TextEditingController _field;
  final FocusNode _fieldFocus = FocusNode();
  List<DanmakuAnime> _animes = const [];
  bool _loading = false;
  bool _searched = false;
  int _searchGeneration = 0;

  @override
  void initState() {
    super.initState();
    _field = TextEditingController(text: widget.initialKeyword);
    _field.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _field.text.length,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _fieldFocus.requestFocus();
      if (widget.initialKeyword.trim().isNotEmpty) {
        unawaited(_runSearch());
      }
    });
  }

  @override
  void dispose() {
    _searchGeneration++;
    _fieldFocus.dispose();
    _field.dispose();
    super.dispose();
  }

  Future<void> _runSearch() async {
    final term = _field.text.trim();
    if (term.isEmpty) {
      return;
    }
    final generation = ++_searchGeneration;
    setState(() {
      _loading = true;
      _searched = true;
    });
    final results = await widget.danmaku.search(term);
    if (!mounted || generation != _searchGeneration) {
      return;
    }
    setState(() {
      _animes = results;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final overlayWidth = MediaQuery.sizeOf(context).width;
    final panelWidth = overlayWidth < 440 ? overlayWidth : 400.0;
    return Positioned(
      top: kPlayerChromeBarExtent,
      left: 0,
      right: 0,
      bottom: 0,
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              key: DanmakuKeys.searchDismiss,
              behavior: HitTestBehavior.opaque,
              onTap: widget.onClose,
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
            width: panelWidth,
            child: Material(
              key: DanmakuKeys.searchPanel,
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
                            l10n.danmakuSearchTitle,
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: scheme.onSurface,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: MaterialLocalizations.of(
                            context,
                          ).closeButtonTooltip,
                          color: scheme.onSurface,
                          onPressed: widget.onClose,
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    TextField(
                      key: DanmakuKeys.searchField,
                      controller: _field,
                      focusNode: _fieldFocus,
                      autofocus: true,
                      enabled: true,
                      enableInteractiveSelection: true,
                      textInputAction: TextInputAction.search,
                      style: theme.textTheme.bodyMedium,
                      decoration: InputDecoration(
                        hintText: l10n.danmakuSearchHint,
                        filled: true,
                        fillColor: scheme.surfaceContainerHighest,
                        prefixIcon: const Icon(Icons.search_rounded, size: 20),
                        suffixIcon: IconButton(
                          key: DanmakuKeys.searchSubmit,
                          tooltip: l10n.danmakuSearch,
                          onPressed: () => unawaited(_runSearch()),
                          icon: const Icon(Icons.arrow_forward_rounded),
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(AppRadii.md),
                          borderSide: BorderSide.none,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(AppRadii.md),
                          borderSide: BorderSide.none,
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(AppRadii.md),
                          borderSide: BorderSide(
                            color: scheme.outline.withValues(alpha: 0.4),
                          ),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.md,
                          vertical: AppSpacing.sm,
                        ),
                      ),
                      onSubmitted: (_) => unawaited(_runSearch()),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Expanded(child: _results(l10n, theme, scheme)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _results(AppLocalizations l10n, ThemeData theme, ColorScheme scheme) {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(
          key: DanmakuKeys.searchLoading,
          strokeWidth: 3,
        ),
      );
    }
    if (!_searched) {
      return Center(
        child: Text(
          l10n.danmakuSearchHint,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      );
    }
    if (_animes.isEmpty) {
      return Center(
        child: Text(
          l10n.danmakuNoMatch,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return ListView.builder(
      itemCount: _animes.length,
      itemBuilder: (context, index) {
        final anime = _animes[index];
        return Theme(
          data: theme.copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            key: DanmakuKeys.searchAnime(anime.animeId),
            dense: true,
            initiallyExpanded: _animes.length == 1,
            tilePadding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
            childrenPadding: const EdgeInsets.only(left: AppSpacing.md),
            title: Text(
              anime.animeTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall,
            ),
            subtitle: anime.type == null
                ? null
                : Text(
                    anime.type!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
            children: [
              if (anime.episodes.isEmpty)
                ListTile(
                  dense: true,
                  title: Text(
                    l10n.danmakuNoMatch,
                    style: theme.textTheme.bodySmall,
                  ),
                )
              else
                for (final episode in anime.episodes)
                  ListTile(
                    dense: true,
                    key: DanmakuKeys.searchEpisode(episode.episodeId),
                    title: Text(episode.episodeTitle),
                    onTap: () {
                      unawaited(widget.danmaku.selectEpisode(anime, episode));
                      widget.onClose();
                    },
                  ),
            ],
          ),
        );
      },
    );
  }
}

/// 音量组:静音按钮 + 连续滑条 + 百分比。滚轮仍按 5% 一档;拖动按 1%。
///
/// 100 为原片 0 dB,滑条上限 [PlayerSettings.volumeMax] 含增益。
/// 轨道在 100% 处画刻度,超过 100 时数字改用强调色。
class _VolumeControl extends StatelessWidget {
  const _VolumeControl({required this.controller});

  final PlayerController controller;

  static const _sliderWidth = 148.0;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final volume = controller.volume.clamp(0, PlayerSettings.volumeMax);
    final boosted = volume > 100;
    const unity = 100 / PlayerSettings.volumeMax;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _PlayerIconButton(
          key: PlayerKeys.mute,
          tooltip: volume <= 0 ? l10n.unmute : l10n.mute,
          onPressed: controller.toggleMute,
          iconSize: 20,
          icon: _volumeIconForLevel(volume),
        ),
        SizedBox(
          width: _sliderWidth,
          child: SliderTheme(
            data: _overlaySliderTheme(theme, thumbRadius: 6).copyWith(
              secondaryActiveTrackColor: scheme.primary,
              trackShape: const _VolumeSliderTrackShape(unityFraction: unity),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            ),
            child: Slider(
              key: PlayerKeys.volume,
              value: volume.toDouble(),
              min: 0,
              max: PlayerSettings.volumeMax.toDouble(),
              onChanged: (value) {
                controller.setVolume(value.round());
              },
            ),
          ),
        ),
        SizedBox(
          width: 44,
          child: Text(
            key: PlayerKeys.volumePercent,
            l10n.volumePercent(volume),
            maxLines: 1,
            textAlign: TextAlign.end,
            style: _overlayTimeStyle(
              theme,
            )?.copyWith(color: boosted ? scheme.primary : scheme.onSurface),
          ),
        ),
      ],
    );
  }
}

IconData _volumeIconForLevel(int volume) {
  if (volume <= 0) {
    return Icons.volume_off_rounded;
  }
  if (volume < 34) {
    return Icons.volume_mute_rounded;
  }
  if (volume < 67) {
    return Icons.volume_down_rounded;
  }
  return Icons.volume_up_rounded;
}

/// 在 100%(0 dB)处画刻度,拖动时不量化,避免 5% 一格的粘滞感。
class _VolumeSliderTrackShape extends RoundedRectSliderTrackShape {
  const _VolumeSliderTrackShape({required this.unityFraction});

  final double unityFraction;

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 2,
  }) {
    super.paint(
      context,
      offset,
      parentBox: parentBox,
      sliderTheme: sliderTheme,
      enableAnimation: enableAnimation,
      textDirection: textDirection,
      thumbCenter: thumbCenter,
      secondaryOffset: secondaryOffset,
      isDiscrete: isDiscrete,
      isEnabled: isEnabled,
      additionalActiveTrackHeight: additionalActiveTrackHeight,
    );
    final trackRect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    final x = trackRect.left + trackRect.width * unityFraction.clamp(0.0, 1.0);
    final paint = Paint()
      ..color = (sliderTheme.activeTrackColor ?? const Color(0xFFFFFFFF))
          .withValues(alpha: 0.78)
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    context.canvas.drawLine(
      Offset(x, trackRect.center.dy - 5),
      Offset(x, trackRect.center.dy + 5),
      paint,
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
    this.iconColor,
  });

  final String? tooltip;
  final double iconSize;
  final IconData icon;
  final Color? iconColor;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      color: iconColor ?? scheme.onSurface,
      iconSize: iconSize,
      icon: Icon(icon),
    );
  }
}

const _subtitleOffToken = -1;

/// 倍速阶梯约 8 项需完整显示,避免菜单内滚动。
const _controlMenuConstraints = BoxConstraints(
  minWidth: 280,
  maxWidth: 420,
  maxHeight: 480,
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
        onSelected: (value) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            onSelected(value);
          });
        },
        constraints: _controlMenuConstraints,
        padding: EdgeInsets.zero,
        splashRadius: 20,
        itemBuilder: (context) => items,
        child: child,
      );
    }
    return PopupMenuButton<T>(
      tooltip: tooltip,
      onSelected: (value) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          onSelected(value);
        });
      },
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
    secondaryActiveTrackColor: onSurface.withValues(alpha: 0.52),
    inactiveTrackColor: onSurface.withValues(alpha: 0.22),
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
  return MpvVideoBackend(settingsStore: bindings.settingsStore);
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
