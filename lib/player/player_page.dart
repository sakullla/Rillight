import 'playback_line_recovery_ui.dart';
import 'source_switch_menu.dart';

import 'dart:async';

import 'package:rillight/player/player_host_command.dart';
import 'package:flutter/foundation.dart';

import 'package:flutter/gestures.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:flutter/services.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/desktop_gestures.dart';
import 'package:rillight/app/widgets/app_error_view.dart';
import 'package:rillight/app/window_chrome.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/home/catalog_failure.dart';
import 'package:rillight/player/danmaku/danmaku_controller.dart';
import 'package:rillight/player/danmaku/danmaku_keys.dart';
import 'package:rillight/player/danmaku/danmaku_match_query.dart';
import 'package:rillight/player/danmaku/danmaku_panel.dart';
import 'package:rillight/player/danmaku/danmaku_renderer.dart';
import 'package:rillight/player/danmaku/dandanplay_models.dart';
import 'package:rillight/player/episode_browser.dart';
import 'package:rillight/player/rillight_video_backend.dart';
import 'package:rillight/player/network_throughput.dart';
import 'package:rillight/player/next_episode_card.dart';
import 'package:rillight/player/playback_ended_panel.dart';
import 'package:rillight/player/playback_wake_lock.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_controller.dart';
import 'package:rillight/player/buffered_ranges_track.dart';
import 'package:rillight/player/player_keys.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/playback_settings_menu.dart';
import 'package:rillight/player/playback_control_scrims.dart';
import 'package:rillight/player/seek_preview.dart';
import 'package:rillight/player/subtitle_viewport.dart';
import 'package:rillight/player/track_picker.dart';
import 'package:rillight/player/player_window.dart';
import 'package:rillight/player/player_window_host.dart';
import 'package:rillight/player/video_backend.dart';
import 'package:rillight/player/playback_title.dart';
import 'package:rillight/app/ui/app_icons.dart';

export 'package:rillight/player/episode_browser.dart'
    show kPlayerEpisodeRowExtent, playerEpisodeListOffset;

/// 播放器顶栏命中高度:内边距 + 标题行。剧集面板从这之下铺开,避免挡住关闭/置顶。
const double kPlayerChromeBarExtent =
    AppSpacing.sm + kWindowChromeHeight + AppSpacing.sm + AppSpacing.lg;

/// 顶栏实时网速占用宽度,给标题右侧留空。
const double kPlayerNetworkSpeedExtent = 148;

class PlayerPage extends StatefulWidget {
  const PlayerPage({
    super.key,
    required this.itemId,
    this.autoResume = true,
    this.mediaSourceId,
    this.audioStreamIndex,
    this.subtitleStreamIndex,
    this.startPosition,
    this.secondarySubtitleStreamIndex,
    this.sourceRequest,
    this.onClosed,
    this.onOpenItem,
    this.onOpenItemDetail,
    this.playbackLines,
    this.verifiedPlaybackServerId,
  });

  final String itemId;
  final bool autoResume;
  final String? mediaSourceId;
  final int? audioStreamIndex;
  final int? subtitleStreamIndex;
  final Duration? startPosition;

  /// 次字幕显式预选;null 表示次字幕保持关闭。
  final int? secondarySubtitleStreamIndex;
  final PlayerOpenRequest? sourceRequest;
  final VoidCallback? onClosed;
  final ValueChanged<String>? onOpenItem;
  final void Function(
    String itemId, {
    String? seasonId,
    PlayerHostOpenItemCommand? command,
  })?
  onOpenItemDetail;
  final List<ServerLine>? playbackLines;
  final String? verifiedPlaybackServerId;

  @override
  State<PlayerPage> createState() => PlayerPageState();
}

class PlayerPageState extends State<PlayerPage> {
  PlayerController? controller;
  DanmakuController? get danmaku => _danmaku;
  ValueListenable<bool>? _nativePresentation;
  void _onNativePresentation() {
    if (mounted) setState(() {});
  }

  final PlaybackWakeLock _wakeLock = PlaybackWakeLock();
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

  /// 系统重新激活窗口时，恢复控制栏及播放器键盘入口。
  void restoreWindowInteraction() {
    if (!mounted) return;
    controller?.onUserActivity();
    if (!_danmakuSearchOpen && !_danmakuPanelOpen) {
      _playerShortcuts.requestFocus();
    }
  }

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
    final auth = AuthScope.of(context);
    final matched = widget.playbackLines == null
        ? serverMatchingPlayback(auth, auth.client.baseUrl)
        : null;
    final created = PlayerController(
      client: auth.client,
      initialLineSelection:
          bindings.playbackLineSelectionSnapshot ?? matched?.lineSelection,
      playbackLineSnapshot: widget.playbackLines ?? matched?.lines ?? const [],
      verifiedPlaybackServerId:
          widget.verifiedPlaybackServerId ?? matched?.verifiedServerId,
      runtime: bindings.runtime,
      recoveryDeadlineUtc: bindings.recoveryDeadlineUtc,
      recoveryAttemptDeadlineUtc: bindings.recoveryAttemptDeadlineUtc,
      recoveryAttemptedLineIds: bindings.recoveryAttemptedLineIds,
      observationSink: bindings.observationSink,
      switchDispatcher: bindings.switchDispatcher,
      reportOutcomeSink: bindings.reportOutcomeSink,
      sourceOpenResult: bindings.sourceOpenResult,
      openRequest: widget.sourceRequest,
      itemId: widget.itemId,
      backend: _createBackend(bindings),
      window: bindings.window ?? WindowManagerPlayerWindow(),
      autoResume: widget.autoResume,
      preferredMediaSourceId: widget.mediaSourceId,
      preferredAudioStreamIndex: widget.audioStreamIndex,
      preferredSubtitleStreamIndex: widget.subtitleStreamIndex,
      startPosition: widget.startPosition,
      preferredSecondarySubtitleStreamIndex:
          widget.secondarySubtitleStreamIndex,
      progressInterval: bindings.progressInterval,
      controlsHideAfter: bindings.controlsHideAfter,
      nextEpisodeCountdown: bindings.nextEpisodeCountdown,
      seekStep: bindings.seekStep,
      settingsStore: bindings.settingsStore,
      startupData: bindings.startupData,
      snapshotStore: bindings.snapshotStore,
      onClose: _leave,
      onOpenItem: _openItem,
      onOpenItemDetail: widget.onOpenItemDetail,
    );
    controller = created;
    final backend = created.backend;
    if (backend is VideoBackendNativeOverlay) {
      _nativePresentation =
          (backend as VideoBackendNativeOverlay).nativeOverlay;
      _nativePresentation!.addListener(_onNativePresentation);
    }
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
    _nativePresentation?.removeListener(_onNativePresentation);
    _danmaku?.removeListener(_onDanmakuChanged);
    _danmaku?.dispose();
    final current = controller;
    current?.removeListener(_onController);
    _wakeLock.disposeNow();
    current?.dispose();
    _playerShortcuts.dispose();
    super.dispose();
  }

  void _onController() {
    final current = controller;
    if (current?.permissionRevoked == true) {
      _danmaku?.removeListener(_onDanmakuChanged);
      _danmaku?.dispose();
      _danmaku = null;
      _danmakuPanelOpen = false;
      _danmakuSearchOpen = false;
      _danmakuLayerPinned = false;
      _danmakuLayerItemId = null;
    }
    _wakeLock.update(
      current != null &&
          current.isPlaying &&
          !current.loading &&
          current.error == null &&
          !current.playbackEnded,
    );
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
          : (resolved.mediaSource.runtime ?? Duration.zero),
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
  Widget build(BuildContext context) => AppUiTheme(
    data: AppUiTheme.dark(),
    child: Builder(builder: _buildPlayer),
  );

  Widget _buildPlayer(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final current = controller;
    if (current == null) {
      return const ColoredBox(color: CupertinoColors.black);
    }
    return Focus(
      focusNode: _playerShortcuts,
      autofocus: true,
      descendantsAreFocusable: true,
      onFocusChange: (focused) {
        if (focused) controller?.onUserActivity();
      },
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) {
          return KeyEventResult.ignored;
        }
        // Any key press reveals the controls once, like pointer movement.
        // Shortcut handling below is unchanged.
        current.onUserActivity();
        if (_danmakuSearchOpen) {
          if (event.logicalKey == LogicalKeyboardKey.escape) {
            _closeDanmakuSearch();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        }
        // An open settings panel owns its keyboard interactions. Arrow and
        // space keys must not seek or toggle playback behind that panel.
        if (current.controlsPinned && !_danmakuPanelOpen && !_episodesOpen) {
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
        child: DesktopPlaybackGestures(
          position: current.position,
          duration: current.duration,
          volume: current.volume,
          isFullScreen: current.isFullScreen,
          enabled:
              !current.loading &&
              !current.disconnected &&
              !_episodesOpen &&
              !_danmakuPanelOpen &&
              !_danmakuSearchOpen,
          onSeek: current.seekTo,
          onVolume: current.setVolume,
          onFullScreen: current.window.setFullScreen,
          child: CupertinoPageScaffold(
            backgroundColor: _nativePresentation?.value == true
                ? CupertinoColors.transparent
                : CupertinoColors.black,
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerSignal: (event) {
                if (defaultTargetPlatform == TargetPlatform.macOS) return;
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
                onEnter: (_) => current.onUserActivity(),
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
                    Positioned.fill(
                      child: IgnorePointer(
                        child: SubtitleViewportReporter(controller: current),
                      ),
                    ),
                    if (current.loading)
                      const Positioned.fill(
                        child: IgnorePointer(
                          child: ColoredBox(color: CupertinoColors.black),
                        ),
                      ),
                    Positioned.fill(
                      child: PlaybackControlScrims(
                        key: const Key('player-control-scrims'),
                        visible: current.controlsVisible,
                        topExtent: kPlayerChromeBarExtent,
                        showBottom:
                            !current.loading &&
                            current.resolved != null &&
                            !current.playbackEnded &&
                            current.error == null,
                      ),
                    ),
                    // 弹幕只绘制,叠在点击层下面,避免 CustomPaint 吃掉单击。
                    // 弹幕让出顶栏一带:标题、置顶/最小化/关闭钮不再被飘过的
                    // 弹幕压住;画面区域固定,不随控制层显隐重排轨道。
                    if (_danmakuOverlayVisible(current))
                      Positioned(
                        top: kPlayerChromeBarExtent,
                        left: 0,
                        right: 0,
                        bottom: 0,
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
                    if (!playbackNeedsLineStatus(current) &&
                        (current.loading || current.isBuffering))
                      Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(
                              width: 44,
                              height: 44,
                              child: CupertinoActivityIndicator(),
                            ),
                            const SizedBox(height: AppSpacing.md),
                            Text(
                              l10n.playerLoading,
                              style: AppUiTheme.of(context).textTheme.bodyMedium
                                  ?.copyWith(
                                    color: AppUiTheme.of(context)
                                        .colorScheme
                                        .onSurface
                                        .withValues(alpha: 0.7),
                                  ),
                            ),
                          ],
                        ),
                      ),
                    if (!playbackNeedsLineStatus(current) &&
                        _errorText(l10n, current) != null)
                      AppErrorView(
                        message: _errorText(l10n, current)!,
                        onRetry: () {
                          unawaited(current.retryPlayback());
                        },
                      ),
                    if (playbackNeedsLineStatus(current))
                      PlayerLineStatus(
                        controller: current,
                        onChooseLines: () =>
                            unawaited(showPlaybackLineDialog(context, current)),
                        onDismiss: () => unawaited(current.close()),
                      ),
                    if (!current.playbackEnded && current.error == null)
                      _ControlsBar(
                        controller: current,
                        visible: current.controlsVisible || current.loading,
                        dragging: _dragSeeking,
                        dragValue: _dragValue,
                        danmaku: _danmaku,
                        onOpenEpisodes: _openEpisodeList,
                        onDanmakuSearch: _openDanmakuPanel,
                        onDragStart: (value) {
                          current.setControlsPinned(true);
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
                          current.setControlsPinned(false);
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
                    if (!playbackNeedsLineStatus(current) &&
                        current.disconnected &&
                        !current.isPlaying)
                      _Banner(
                        key: PlayerKeys.disconnect,
                        text:
                            current.disconnectDetail ??
                            l10n.playbackDisconnected,
                      ),
                    if (current.networkSlow && !current.disconnected)
                      _Banner(
                        key: const ValueKey('player-network-slow'),
                        text: l10n.networkSlowHint,
                        onDismiss: current.dismissNetworkSlowHint,
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
                    if (!playbackNeedsLineStatus(current) &&
                        current.playbackLineFailure != null)
                      _Banner(
                        key: const ValueKey('playback-line-failure'),
                        text: current.playbackLineFailure!,
                        onDismiss: current.dismissPlaybackLineFailure,
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
                      _DanmakuSourceBanner(
                        controller: _danmaku!,
                        visible: current.controlsVisible,
                      ),
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
                      _DanmakuMatchChip(
                        visible: current.controlsVisible,
                        onSearch: _openDanmakuSearch,
                      ),
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
                      _EpisodeOverlay(
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
        if (current.loadFailure != null) {
          return catalogFailureMessage(l10n, current.loadFailure!);
        }
        final detail = current.disconnectDetail?.trim();
        if (detail == 'unsupportedDolbyVision') {
          return l10n.playbackDolbyVisionUnsupported;
        }
        if (detail != null && detail.isNotEmpty) {
          return '${l10n.playbackFailed}\n$detail';
        }
        return l10n.playbackFailed;
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
      child: ExcludeFocus(
        excluding: !visible,
        child: IgnorePointer(ignoring: !visible, child: child),
      ),
    );
  }
}

class _PlayerChromeBar extends StatelessWidget {
  const _PlayerChromeBar({required this.controller, required this.visible});

  final PlayerController controller;
  final bool visible;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final l10n = AppLocalizations.of(context);
    final parts = playbackTitleParts(controller.item, fallback: '');
    final title = parts.title;
    final statusWidth = (MediaQuery.sizeOf(context).width * 0.4).clamp(
      148.0,
      kPlayerNetworkSpeedExtent,
    );
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
                  decoration: const BoxDecoration(),
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      AppSpacing.md,
                      AppSpacing.sm,
                      AppSpacing.sm +
                          kTitleBarIconConstraints.maxWidth * 3 +
                          statusWidth,
                      AppSpacing.lg,
                    ),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: title.isEmpty
                          ? const SizedBox.shrink()
                          : Column(
                              key: const Key('player-title'),
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (parts.eyebrow case final eyebrow?)
                                  Text(
                                    eyebrow,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.labelMedium
                                        ?.copyWith(
                                          color: theme.colorScheme.onSurface
                                              .withValues(alpha: .72),
                                          height: 1.1,
                                        ),
                                  ),
                                Text(
                                  title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w700,
                                    height: 1.2,
                                    shadows: [
                                      Shadow(
                                        color: theme.colorScheme.scrim
                                            .withValues(alpha: .4),
                                        blurRadius: 6,
                                      ),
                                    ],
                                  ),
                                ),
                              ],
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
                    Padding(
                      padding: const EdgeInsets.only(right: AppSpacing.sm),
                      child: SizedBox(
                        width: statusWidth,
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: AppTooltip(
                            message: l10n.playerNetworkSpeedTooltip,
                            child: NetworkSpeedReadout(
                              key: PlayerKeys.networkSpeed,
                              bytesPerSecond: controller.cacheSpeedBytesPerSec,
                              color: theme.colorScheme.onSurface.withValues(
                                alpha: 0.86,
                              ),
                            ),
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
                    icon: AppIcons.pin,
                    symbolFill: controller.isAlwaysOnTop
                        ? AppIcons.filled
                        : AppIcons.outline,
                  ),
                  _PlayerChromeIconButton(
                    buttonKey: const Key('player-window-minimize'),
                    tooltip: l10n.minimizeWindow,
                    color: theme.colorScheme.onSurface,
                    onPressed: () {
                      unawaited(controller.minimize());
                    },
                    icon: CupertinoIcons.minus,
                  ),
                  _PlayerChromeIconButton(
                    buttonKey: const Key('player-window-close'),
                    tooltip: '关闭',
                    color: theme.colorScheme.onSurface,
                    onPressed: () {
                      unawaited(controller.close());
                    },
                    icon: CupertinoIcons.xmark,
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

/// 播放窗顶栏按钮:与主窗口搜索/会话钮同高同字号,避免默认 48 点 AppIconButton
/// 在标题栏里画出一块大方块。
class _PlayerChromeIconButton extends StatelessWidget {
  const _PlayerChromeIconButton({
    required this.buttonKey,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.color,
    this.symbolFill = AppIcons.filled,
  });

  final Key buttonKey;
  final String tooltip;
  final IconData icon;
  final Color? color;
  final double symbolFill;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = AppUiTheme.of(context).colorScheme;
    final foreground = color ?? scheme.onSurface;
    return AppTooltip(
      message: tooltip,
      child: AppIconButton(
        key: buttonKey,
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        constraints: kTitleBarIconConstraints,

        size: 18,
        color: foreground,
        icon: Icon(icon, fill: symbolFill),
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
    final theme = AppUiTheme.of(context);
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
            constraints: BoxConstraints(
              maxWidth: AppViewport.fit(
                420,
                MediaQuery.sizeOf(context).width - 48,
                MediaQuery.sizeOf(context),
              ),
            ),
            child: DecoratedBox(
              decoration: playerSurfaceDecoration(
                theme,
                borderRadius: BorderRadius.circular(AppRadii.xl),
              ),
              child: Container(
                key: PlayerKeys.playbackEnded,
                padding: const EdgeInsets.all(AppSpacing.xxl),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      AppIcons.replay,
                      fill: AppIcons.filled,
                      size: 40,
                      color: scheme.primary,
                    ),
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
                        AppButton.icon(
                          key: PlayerKeys.replay,
                          variant: AppButtonVariant.filled,
                          onPressed: () => unawaited(controller.replay()),
                          style: _endedActionStyle(theme),
                          icon: const Icon(
                            AppIcons.replay,
                            fill: AppIcons.filled,
                          ),
                          label: Text(l10n.replay),
                        ),
                        if (hasSeries)
                          AppButton.icon(
                            key: PlayerKeys.endedViewSeries,
                            variant: AppButtonVariant.outlined,
                            onPressed: controller.openEndedSeries,
                            style: _endedActionStyle(theme),
                            icon: const Icon(
                              AppIcons.series,
                              fill: AppIcons.filled,
                            ),
                            label: Text(l10n.viewSeries),
                          ),
                        AppButton.icon(
                          key: PlayerKeys.endedClose,
                          onPressed: () => unawaited(controller.close()),
                          style: _endedActionStyle(theme),
                          icon: const Icon(
                            AppIcons.close,
                            fill: AppIcons.filled,
                          ),
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

AppButtonStyle _endedActionStyle(AppUiThemeData theme) {
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
  return AppButtonStyle(
    minimumSize: size,
    padding: padding,
    textStyle: label,
    shape: const StadiumBorder(),
  );
}

class _NextEpisodeBanner extends StatelessWidget {
  const _NextEpisodeBanner({required this.controller});

  final PlayerController controller;

  @override
  Widget build(BuildContext context) {
    // Fade padding, seek row, gap, button row, and the bar's own bottom inset.
    const controlsStack =
        AppSpacing.huge + 48 + AppSpacing.xs + 48 + AppSpacing.md;
    return Positioned(
      right: AppSpacing.xl,
      bottom: controller.controlsVisible
          ? controlsStack + AppSpacing.md
          : AppSpacing.xl,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: (MediaQuery.sizeOf(context).width - AppSpacing.xl * 2)
              .clamp(0.0, AppViewport.dp(480, MediaQuery.sizeOf(context))),
        ),
        child: NextEpisodeCard(controller: controller),
      ),
    );
  }
}

/// 播放到片头/片尾区间时右下角的跳过按钮:点击跳到区间终点。
/// 中性深色半透明胶囊加细边,不带品牌色描边与圆点。
class _SkipSegmentButton extends StatelessWidget {
  const _SkipSegmentButton({required this.controller});

  final PlayerController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    final segment = controller.activeSkipSegment!;
    return Positioned(
      right: AppSpacing.xl,
      bottom: controller.controlsVisible ? 112 : AppSpacing.xl,
      child: Container(
        key: const Key('player-skip-segment'),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow.withValues(alpha: .88),
          borderRadius: BorderRadius.circular(AppRadii.pill),
          border: Border.all(color: AppEdge.of(Brightness.dark, strong: true)),
        ),
        child: AppSurfaceAction(
          onTap: () => unawaited(controller.skipCurrentSegment()),
          borderRadius: BorderRadius.circular(AppRadii.pill),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 9, 16, 9),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  AppIcons.skipNext,
                  fill: AppIcons.filled,
                  size: 18,
                  color: CupertinoColors.white,
                ),
                const SizedBox(width: AppSpacing.xs),
                Text(
                  segment.kind == PlayerSkipKind.outro
                      ? l10n.skipOutro
                      : l10n.skipIntro,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: CupertinoColors.white,
                    fontWeight: FontWeight.w700,
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

/// 播放中的剧集列表:点遮罩或关闭钮收起,列表从顶栏下方开始以免挡住窗口关闭。
class _EpisodeOverlay extends StatelessWidget {
  const _EpisodeOverlay({required this.controller, required this.onClose});

  final PlayerController controller;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = AppUiTheme.of(context).colorScheme;
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
          // 悬浮面板:四周留白、圆角与细边,不再是贴着窗口右缘的一整条
          // 黑框实色栏。
          Positioned(
            top: AppSpacing.xs,
            bottom: AppSpacing.md,
            right: AppSpacing.md,
            width: AppViewport.fit(
              420,
              MediaQuery.sizeOf(context).width - AppSpacing.md * 2,
              MediaQuery.sizeOf(context),
            ),
            child: Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh.withValues(alpha: .97),
                borderRadius: BorderRadius.circular(AppRadii.xl),
                border: Border.all(
                  color: scheme.outlineVariant.withValues(alpha: 0.65),
                ),
              ),
              child: PlayerEpisodeBrowser(
                controller: controller,
                onClose: onClose,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 画面底部的一行提示,避开画面中部;[onDismiss] 非空时附带关闭钮。
class _Banner extends StatelessWidget {
  const _Banner({super.key, required this.text, this.onDismiss});

  final String text;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    final dismiss = onDismiss;
    return Positioned(
      left: AppSpacing.page,
      bottom: 88,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: AppViewport.fit(
            420,
            MediaQuery.sizeOf(context).width - 48,
            MediaQuery.sizeOf(context),
          ),
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.surface.withValues(alpha: 0.94),
            borderRadius: BorderRadius.circular(AppRadii.sm),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm,
              vertical: AppSpacing.xs,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(child: Text(text, style: theme.textTheme.bodyMedium)),
                if (dismiss != null) ...[
                  const SizedBox(width: AppSpacing.xxs),
                  AppIconButton(
                    key: const Key('player-progress-sync-dismiss'),
                    tooltip: '关闭',
                    onPressed: dismiss,
                    size: 16,

                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 28,
                      height: 28,
                    ),
                    icon: const Icon(AppIcons.close, fill: AppIcons.filled),
                  ),
                ],
              ],
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
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: _FadeThrough(
        visible: visible,
        child: DecoratedBox(
          key: PlayerKeys.controls,
          decoration: const BoxDecoration(),
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

/// 时间轴行:当前时间 + 进度滑条 + 总时长。点右侧时长切换为剩余时间。
class _SeekTimeline extends StatefulWidget {
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
  State<_SeekTimeline> createState() => _SeekTimelineState();
}

class _SeekTimelineState extends State<_SeekTimeline> {
  bool _remaining = false;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final l10n = AppLocalizations.of(context);
    final controller = widget.controller;
    final dragging = widget.dragging;
    final durationMs = controller.duration.inMilliseconds;
    final seekEnabled = durationMs > 0;
    final value = dragging
        ? widget.dragValue
        : (durationMs <= 0
              ? 0.0
              : (controller.position.inMilliseconds / durationMs).clamp(
                  0.0,
                  1.0,
                ));
    final shown = Duration(milliseconds: (durationMs * value).round());
    final remaining = controller.duration - shown;
    final trailing = _remaining && seekEnabled
        ? l10n.playerRemainingClock(
            _clock(remaining.isNegative ? Duration.zero : remaining),
          )
        : _clock(controller.duration);
    return Row(
      children: [
        Text(
          _clock(dragging ? shown : controller.position),
          style: _overlayTimeStyle(theme),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: SeekPreview(
            controller: controller,
            dragValue: dragging ? widget.dragValue : null,
            child: BufferedRangesTrack(
              snapshot: controller.bufferSnapshot,
              duration: controller.duration,
              child: PlayerSlider(
                key: PlayerKeys.seekBar,
                value: value,
                onChanged: !seekEnabled
                    ? null
                    : (next) {
                        if (!dragging) {
                          widget.onDragStart(next);
                        } else {
                          widget.onDragUpdate(next);
                        }
                      },
                onChangeEnd: !seekEnabled ? null : widget.onDragEnd,
              ),
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        AppTooltip(
          message: _remaining
              ? l10n.playerShowDuration
              : l10n.playerShowRemaining,
          child: MouseRegion(
            cursor: seekEnabled ? SystemMouseCursors.click : MouseCursor.defer,
            child: GestureDetector(
              key: const Key('player-time-toggle'),
              behavior: HitTestBehavior.opaque,
              onTap: seekEnabled
                  ? () => setState(() => _remaining = !_remaining)
                  : null,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 44),
                child: Text(
                  trailing,
                  textAlign: TextAlign.right,
                  style: _overlayTimeStyle(theme),
                ),
              ),
            ),
          ),
        ),
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
          iconSize: 22,
          filled: true,
          icon: controller.isPlaying ? AppIcons.pause : AppIcons.play,
        ),
        const SizedBox(width: AppSpacing.xxs),
        _PlayerIconButton(
          key: const Key('player-rewind'),
          tooltip: l10n.mobileRewind,
          onPressed: controller.duration > Duration.zero
              ? () => unawaited(
                  controller.seekRelative(const Duration(seconds: -10)),
                )
              : null,
          icon: AppIcons.replay10,
        ),
        _PlayerIconButton(
          key: const Key('player-forward'),
          tooltip: l10n.mobileForward,
          onPressed: controller.duration > Duration.zero
              ? () => unawaited(
                  controller.seekRelative(const Duration(seconds: 10)),
                )
              : null,
          icon: AppIcons.forward10,
        ),
        _VolumeControl(controller: controller),
        const Spacer(),
        if (danmakuController != null && danmakuController.isConfigured)
          _DanmakuButton(
            danmaku: danmakuController,
            onPressed: onDanmakuSearch,
          ),
        // 无自带字幕的媒体也保留字幕入口:本地导入在菜单内。
        if (controller.canConfigureSubtitles ||
            controller.canImportSubtitleFiles)
          SubtitleTrackMenu(controller: controller),
        if (controller.canBrowseEpisodes)
          _PlayerIconButton(
            key: const Key('player-episodes'),
            tooltip: l10n.playerEpisodes,
            onPressed: onOpenEpisodes,
            icon: AppIcons.episodes,
          ),
        PlaybackSettingsMenu(controller: controller),
        _PlayerIconButton(
          key: PlayerKeys.fullscreen,
          tooltip: controller.isFullScreen
              ? l10n.exitFullscreen
              : l10n.fullscreen,
          onPressed: controller.toggleFullScreen,
          icon: AppIcons.fullscreen,
          symbolFill: controller.isFullScreen
              ? AppIcons.filled
              : AppIcons.outline,
        ),
      ],
    );
  }
}

/// 控制条弹幕入口:打开设置面板(开关、搜索、显示参数都在面板里)。
class _DanmakuButton extends StatelessWidget {
  const _DanmakuButton({required this.danmaku, this.onPressed});

  final DanmakuController danmaku;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = AppUiTheme.of(context).colorScheme;
    return _PlayerIconButton(
      key: DanmakuKeys.menu,
      tooltip: l10n.danmaku,
      onPressed: onPressed,
      icon: AppIcons.danmaku,
      symbolFill: danmaku.danmakuOn ? AppIcons.filled : AppIcons.outline,
      iconColor: danmaku.danmakuOn ? scheme.primary : null,
    );
  }
}

/// 未自动匹配时的提示胶囊:点开手动搜索,不必翻设置菜单。
class _DanmakuMatchChip extends StatelessWidget {
  const _DanmakuMatchChip({required this.visible, required this.onSearch});

  /// 随控制层显隐:播放中静置后不在画面上残留。
  final bool visible;
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    return Positioned(
      left: AppSpacing.xl,
      bottom: 112,
      child: _FadeThrough(
        visible: visible,
        child: Container(
          key: DanmakuKeys.matchChip,
          clipBehavior: Clip.antiAlias,
          decoration: playerSurfaceDecoration(
            theme,
            borderRadius: BorderRadius.circular(AppRadii.pill),
          ),
          child: AppSurfaceAction(
            onTap: () {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                onSearch();
              });
            },
            borderRadius: BorderRadius.circular(AppRadii.pill),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.xs,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    AppIcons.subtitles,
                    fill: AppIcons.filled,
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
  const _DanmakuSourceBanner({required this.controller, required this.visible});

  final DanmakuController controller;

  /// 随控制层显隐:播放中静置后不在画面上残留。
  final bool visible;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    return Positioned(
      left: 0,
      right: 0,
      top: kWindowChromeHeight + AppSpacing.xxl,
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: AppViewport.fit(
              560,
              MediaQuery.sizeOf(context).width - 48,
              MediaQuery.sizeOf(context),
            ),
          ),
          child: _FadeThrough(
            visible: visible,
            child: Container(
              key: DanmakuKeys.sourceBanner,
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.sm,
              ),
              decoration: playerSurfaceDecoration(
                theme,
                borderRadius: BorderRadius.circular(AppRadii.lg),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    AppIcons.wifiOff,
                    fill: AppIcons.filled,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  Flexible(child: Text(l10n.danmakuCustomUnreachable)),
                  const SizedBox(width: AppSpacing.sm),
                  AppButton(
                    variant: AppButtonVariant.tinted,
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
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    final viewport = MediaQuery.sizeOf(context);
    final overlayWidth = viewport.width;
    final designWidth = AppViewport.dp(400, viewport);
    final panelWidth = overlayWidth < designWidth + 40
        ? overlayWidth
        : designWidth;
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
            child: Container(
              key: DanmakuKeys.searchPanel,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                border: Border(
                  left: BorderSide(
                    color: scheme.outlineVariant.withValues(alpha: 0.65),
                  ),
                ),
              ),
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
                        AppIconButton(
                          tooltip: '关闭',
                          color: scheme.onSurface,
                          onPressed: widget.onClose,
                          icon: const Icon(
                            AppIcons.close,
                            fill: AppIcons.filled,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    AppTextField(
                      key: DanmakuKeys.searchField,
                      controller: _field,
                      focusNode: _fieldFocus,
                      autofocus: true,
                      enabled: true,
                      enableInteractiveSelection: true,
                      textInputAction: TextInputAction.search,
                      style: theme.textTheme.bodyMedium,
                      onSubmitted: (_) => unawaited(_runSearch()),
                      placeholder: l10n.danmakuSearchHint,
                      prefix: const Icon(
                        AppIcons.search,
                        fill: AppIcons.filled,
                        size: 20,
                      ),
                      suffix: AppIconButton(
                        key: DanmakuKeys.searchSubmit,
                        tooltip: l10n.danmakuSearch,
                        onPressed: () => unawaited(_runSearch()),
                        icon: const Icon(
                          AppIcons.forward,
                          fill: AppIcons.filled,
                        ),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.md,
                        vertical: AppSpacing.sm,
                      ),
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

  Widget _results(
    AppLocalizations l10n,
    AppUiThemeData theme,
    AppColorScheme scheme,
  ) {
    if (_loading) {
      return const Center(
        child: CupertinoActivityIndicator(key: DanmakuKeys.searchLoading),
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
    if (widget.danmaku.searchFailure != null) {
      return DanmakuSearchError(onRetry: () => unawaited(_runSearch()));
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
        return AppDisclosure(
          key: DanmakuKeys.searchAnime(anime.animeId),
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
              AppListTile(
                title: Text(
                  l10n.danmakuNoMatch,
                  style: theme.textTheme.bodySmall,
                ),
              )
            else
              for (final episode in anime.episodes)
                AppListTile(
                  key: DanmakuKeys.searchEpisode(episode.episodeId),
                  title: Text(episode.episodeTitle),
                  onTap: () {
                    unawaited(widget.danmaku.selectEpisode(anime, episode));
                    widget.onClose();
                  },
                ),
          ],
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
    final theme = AppUiTheme.of(context);
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
          child: PlayerSlider(
            key: PlayerKeys.volume,
            unityFraction: unity,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 14),
            value: volume.toDouble(),
            min: 0,
            max: PlayerSettings.volumeMax.toDouble(),
            onChanged: (value) {
              controller.setVolume(value.round());
            },
          ),
        ),
        SizedBox(
          width: 44,
          child: Text(
            key: PlayerKeys.volumePercent,
            l10n.volumePercent(volume),
            maxLines: 1,
            textAlign: TextAlign.end,
            style: _overlayTimeStyle(theme)
                ?.copyWith(color: boosted ? scheme.primary : scheme.onSurface),
          ),
        ),
      ],
    );
  }
}

IconData _volumeIconForLevel(int volume) {
  if (volume <= 0) {
    return AppIcons.volumeOff;
  }
  if (volume < 34) {
    return AppIcons.volumeDown;
  }
  if (volume < 67) {
    return AppIcons.volumeDown;
  }
  return AppIcons.volumeUp;
}

/// 在 100%(0 dB)处画刻度,拖动时不量化,避免 5% 一格的粘滞感。
/// 控制层图标按钮:统一的暖白前景,供按钮行各处复用。
class _PlayerIconButton extends StatelessWidget {
  const _PlayerIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.iconSize = 24,
    this.iconColor,
    this.filled = false,
    this.symbolFill = AppIcons.filled,
  });

  final String? tooltip;
  final double iconSize;
  final IconData icon;
  final Color? iconColor;
  final bool filled;
  final double symbolFill;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = AppUiTheme.of(context).colorScheme;
    if (!filled) {
      return AppIconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        color: iconColor ?? scheme.onSurface,
        size: iconSize,
        icon: Icon(icon, fill: symbolFill),
      );
    }
    return AppIconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      size: iconSize,
      style: AppButtonStyle(
        foregroundColor: scheme.surface,
        backgroundColor: scheme.onSurface,
        disabledForegroundColor: scheme.surface.withValues(alpha: .45),
        fixedSize: const Size(44, 44),
        padding: EdgeInsets.zero,
        shape: const CircleBorder(),
      ),
      icon: Icon(icon, fill: symbolFill),
    );
  }
}

TextStyle? _overlayTimeStyle(AppUiThemeData theme) {
  return theme.textTheme.labelMedium?.copyWith(
    color: theme.colorScheme.onSurface,
    fontFeatures: const [FontFeature.tabularFigures()],
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
  return RillightVideoBackend(settingsStore: bindings.settingsStore);
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
