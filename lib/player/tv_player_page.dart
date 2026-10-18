import 'playback_entry_access.dart';
import 'playback_line_recovery_ui.dart';

import 'dart:async';

import 'source_switch_menu.dart';

import 'dart:math' as math;

import 'package:rillight/app/ui/ui.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/player/playback_title.dart';
import 'package:rillight/player/playback_ended_panel.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/player/episode_browser.dart';
import 'package:rillight/player/network_throughput.dart';
import 'package:rillight/player/player_setting_choices.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/player/rillight_video_backend.dart';
import 'package:rillight/player/buffered_ranges_track.dart';
import 'package:rillight/player/android_playback_lifecycle.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/next_episode_card.dart';
import 'package:rillight/player/playback_output_panel.dart';
import 'package:rillight/player/playback_output_status.dart';
import 'package:rillight/player/player_controller.dart';
import 'package:rillight/player/session_subtitle_files.dart';

import 'player_window_host.dart';

import 'package:rillight/player/player_window.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/subtitle_viewport.dart';
import 'package:rillight/app/ui/app_icons.dart';

class TvPlayerPage extends StatefulWidget {
  const TvPlayerPage({
    super.key,
    required this.itemId,
    this.mediaSourceId,
    this.sourceRequest,
    this.routeLeaseKey,
    this.autoResume = true,
  });
  final String itemId;
  final PlayerOpenRequest? sourceRequest;
  final Object? routeLeaseKey;
  final String? mediaSourceId;
  final bool autoResume;
  @override
  State<TvPlayerPage> createState() => TvPlayerPageState();
}

class TvPlayerPageState extends State<TvPlayerPage> {
  final _presentationThemeKey = GlobalKey();

  PlayerController? controller;
  AndroidPlaybackLifecycle? _lifecycle;
  AuthController? _auth;
  Object? _identity;
  bool _closing = false;
  bool _revocationExitScheduled = false;
  bool _focusedFailure = false;
  String? _focusedLineStatus;
  bool _focusedEnd = false;
  String? _focusedNextId;
  double? _seek;
  bool _surfaceSeeking = false;
  int _scanRepeats = 0;
  final _seekFocus = FocusNode();
  final _playFocus = FocusNode();
  final _surfaceFocus = FocusNode();
  final _retryFocus = FocusNode();
  final _lineStatusFocus = FocusNode(debugLabel: 'playback line decision');
  final _lineConfirmationFocus = FocusNode(
    debugLabel: 'playback line confirmation',
  );
  final _nextPlayFocus = FocusNode();
  final _nextCancelFocus = FocusNode();
  final _endedReplayFocus = FocusNode();
  final _skipFocus = FocusNode();
  String? _focusedSkipId;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (controller != null) return;
    final bindings = PlayerScope.of(context), auth = AuthScope.of(context);
    _auth = auth;
    _identity = (
      auth.client.baseUrl,
      auth.client.userId,
      auth.client.accessToken,
    );
    auth.addListener(_authChanged);
    final matched = serverMatchingPlayback(auth, auth.client.baseUrl);
    final created = PlayerController(
      runtime: bindings.runtime,
      recoveryDeadlineUtc: bindings.recoveryDeadlineUtc,
      recoveryAttemptDeadlineUtc: bindings.recoveryAttemptDeadlineUtc,
      recoveryAttemptedLineIds: bindings.recoveryAttemptedLineIds,
      openRequest: widget.sourceRequest,
      routeLeaseKey: widget.routeLeaseKey,
      client: auth.client,
      initialLineSelection:
          bindings.playbackLineSelectionSnapshot ?? matched?.lineSelection,
      playbackLineSnapshot: matched?.lines ?? const [],
      verifiedPlaybackServerId: matched?.verifiedServerId,
      itemId: widget.itemId,
      backend: bindings.createBackend?.call() ?? RillightVideoBackend(),
      window: bindings.window ?? PlayerWindow(),
      autoResume: widget.autoResume,
      preferredMediaSourceId: widget.mediaSourceId,
      progressInterval: bindings.progressInterval,
      controlsHideAfter: bindings.controlsHideAfter,
      settingsStore: bindings.settingsStore,
      snapshotStore: bindings.snapshotStore,
    );
    controller = created;
    created.addListener(_playerChanged);
    _lifecycle = AndroidPlaybackLifecycle(created);
    unawaited(created.start());
  }

  void _playerChanged() {
    final c = controller!;
    if (_closing) return;
    if (c.permissionRevoked) {
      if (!_revocationExitScheduled) {
        _revocationExitScheduled = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(_close());
        });
        WidgetsBinding.instance.ensureVisualUpdate();
      }
      return;
    }
    if (playbackNeedsLineStatus(c)) {
      final status = c.switchConfirmation != null
          ? 'confirmation'
          : c.isRecovering
          ? 'recovering'
          : 'stopped';
      if (_focusedLineStatus != status) {
        _requestFocus(switch (status) {
          'confirmation' => _lineConfirmationFocus,
          'stopped' => _retryFocus,
          _ => _lineStatusFocus,
        });
      }
      _focusedLineStatus = status;
      return;
    }
    if (_focusedLineStatus != null) {
      _focusedLineStatus = null;
      _requestFocus(_surfaceFocus);
    }
    final ended =
        c.playbackEnded && c.nextEpisode == null && !c.loading && !_failed;
    if (ended) {
      if (!_focusedEnd) _requestFocus(_endedReplayFocus);
      _focusedEnd = true;
      return;
    }
    if (_focusedEnd) {
      _focusedEnd = false;
      _requestFocus(c.nextEpisode == null ? _surfaceFocus : _nextPlayFocus);
    }
    final nextId = c.error == null ? c.nextEpisode?.item.id : null;
    if (nextId == null) {
      _focusedNextId = null;
    } else if (nextId != _focusedNextId) {
      _focusedNextId = nextId;
      _requestFocus(_nextPlayFocus);
    }
    final skipId = _skipPromptId(c);
    if (skipId == null) {
      if (_focusedSkipId != null && _skipFocus.hasFocus) {
        _requestFocus(ended ? _endedReplayFocus : _surfaceFocus);
      }
      _focusedSkipId = null;
    } else if (skipId != _focusedSkipId) {
      _focusedSkipId = skipId;
      _requestFocus(_skipFocus);
    }
    final cardFocused = _nextPlayFocus.hasFocus || _nextCancelFocus.hasFocus;
    if (!c.controlsVisible &&
        _surfaceFocus.hasFocus &&
        !_surfaceFocus.hasPrimaryFocus &&
        !cardFocused &&
        !_skipFocus.hasFocus) {
      _requestFocus(_surfaceFocus);
    }
    if (c.loading || playbackNeedsLineStatus(c)) return;
    if (_failed) {
      if (!_focusedFailure) _requestFocus(_retryFocus);
      _focusedFailure = true;
    } else if (_focusedFailure) {
      _focusedFailure = false;
      _requestFocus(_surfaceFocus);
    }
  }

  void _requestFocus(FocusNode node) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_closing && ModalRoute.of(context)?.isCurrent == true) {
        node.requestFocus();
      }
    });
  }

  void _authChanged() {
    final auth = _auth!;
    final current = controller;
    if (current?.runtime != null && current?.origin != null) {
      if (!current!.origin!.permit.isValid) unawaited(_close());
      return;
    }
    final next = (
      auth.client.baseUrl,
      auth.client.userId,
      auth.client.accessToken,
    );
    final previous = _identity;
    final sameAccount =
        previous is (Uri?, String?, String?) &&
        next.$2 == previous.$2 &&
        next.$3 == previous.$3;
    final keepLine =
        sameAccount &&
        (next.$1 == previous.$1 ||
            (current?.isConfiguredPlaybackUrl(next.$1) ?? false));
    if (keepLine) {
      _identity = next;
      final matched = serverMatchingPlayback(auth, next.$1);
      if (current != null && matched != null) {
        current.bindPlaybackLineSnapshot(
          matched.lines,
          verifiedServerId: matched.verifiedServerId,
        );
      }
      return;
    }
    unawaited(_close());
  }

  Future<void> _close({String? viewSeriesId, String? seasonId}) async {
    if (_closing) return;
    _closing = true;
    final actualOrigin = controller?.origin;
    final command = controller?.endedSeriesCommand;
    final lease = controller?.origin?.permit;
    final sourceBound =
        controller?.origin != null || widget.sourceRequest?.source != null;
    final router = viewSeriesId == null ? null : GoRouter.maybeOf(context);
    final route = ModalRoute.of(context);
    final navigator = Navigator.of(context);
    _lifecycle?.dispose();
    await controller?.close();
    if (!mounted || route == null || !route.isActive) return;
    final failed = controller?.progressSyncFailed == true;
    if (failed) {
      showAppNotice(
        context,
        AppLocalizations.of(context).progressSyncFailedMain,
      );
    }
    // Keep system back blocked during cleanup. Enabling it before an explicit
    // pop can let a predictive back gesture pop the following detail route.
    // A tracks sheet may cover this route when authentication changes. Remove
    // its overlays first, then pop the route whose session we actually closed.
    if (controller?.permissionRevoked == true &&
        !playbackEntryStillAllowed(_auth!, actualOrigin)) {
      GoRouter.of(context).go(AppRoutes.home, extra: null);
      return;
    }
    navigator.popUntil((candidate) => identical(candidate, route));
    navigator.pop();
    if (router != null &&
        viewSeriesId != null &&
        (!sourceBound || (command != null && lease?.isValid == true))) {
      router.push(
        AppRoutes.item(viewSeriesId, seasonId: seasonId),
        extra: command,
      );
    }
  }

  bool get _failed =>
      controller!.error != null ||
      controller!.sessionExpired ||
      controller!.disconnected;

  /// 当前片头/片尾提示。同一段只抢一次焦点，控制条收起后按钮仍留在画面上。
  String? _skipPromptId(PlayerController c) {
    final segment = c.activeSkipSegment;
    if (segment == null ||
        !c.skipPromptVisible ||
        c.nextEpisode != null ||
        c.loading ||
        _failed ||
        c.playbackEnded ||
        c.permissionRevoked) {
      return null;
    }
    return '${segment.kind.name}:${segment.start.inMilliseconds}';
  }

  void _back() {
    final c = controller!;
    if (c.switchConfirmation != null) {
      unawaited(c.confirmMediaSourceSwitch(SwitchResumeChoice.cancel));
      return;
    }
    if (c.isRecovering) {
      c.cancelLineRecovery();
      return;
    }
    if (_skipFocus.hasPrimaryFocus) {
      _seek = null;
      c.setControlsPinned(false);
      if (c.controlsVisible && !_failed && !c.loading && !c.playbackEnded) {
        c.toggleControls();
      }
      _surfaceFocus.requestFocus();
      return;
    }
    if (c.controlsVisible && !_failed && !c.loading && !c.playbackEnded) {
      _seek = null;
      c.setControlsPinned(false);
      c.toggleControls();
      _surfaceFocus.requestFocus();
    } else {
      unawaited(_close());
    }
  }

  void _previewSeek(LogicalKeyboardKey key, {required bool repeat}) {
    final c = controller!;
    if (c.loading || _failed || c.duration <= Duration.zero) return;
    c.setControlsPinned(true);
    if (repeat) _scanRepeats++;
    final step = _scanRepeats >= 6 ? 30000 : 10000;
    setState(() {
      _seek =
          ((_seek ?? c.position.inMilliseconds.toDouble()) +
                  (key == LogicalKeyboardKey.arrowLeft ? -step : step))
              .clamp(0, c.duration.inMilliseconds.toDouble());
    });
  }

  Future<void> _commitSeek() async {
    final c = controller!;
    final target = _seek;
    _surfaceSeeking = false;
    _scanRepeats = 0;
    if (target != null) {
      // Controller/backend preserve the user's playing or paused intent.
      await c.seekTo(Duration(milliseconds: target.round()));
    }
    if (!mounted || _closing) return;
    setState(() => _seek = null);
    c.setControlsPinned(false);
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    final c = controller!, key = event.logicalKey;
    final horizontal =
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight;
    if (event is KeyUpEvent) {
      if (horizontal && _surfaceSeeking) {
        unawaited(_commitSeek());
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.escape) {
      if (event is KeyDownEvent) _back();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaPlayPause ||
        key == LogicalKeyboardKey.mediaPlay ||
        key == LogicalKeyboardKey.mediaPause) {
      if (event is KeyDownEvent && !c.loading && !_failed) {
        if (key == LogicalKeyboardKey.mediaPlayPause ||
            (key == LogicalKeyboardKey.mediaPlay) != c.isPlaying) {
          unawaited(c.togglePlay());
        }
        c.onUserActivity();
      }
      return KeyEventResult.handled;
    }
    if (_surfaceFocus.hasPrimaryFocus &&
        !c.loading &&
        !_failed &&
        !c.playbackEnded) {
      if (horizontal) {
        _surfaceSeeking = true;
        _previewSeek(key, repeat: event is KeyRepeatEvent);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.select ||
          key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.space) {
        if (event is KeyDownEvent) {
          unawaited(c.togglePlay());
          c.onUserActivity();
        }
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowUp ||
          key == LogicalKeyboardKey.arrowDown) {
        c.onUserActivity();
        if (c.nextEpisode != null) {
          _requestFocus(_nextPlayFocus);
        } else if (_skipPromptId(c) != null) {
          _requestFocus(_skipFocus);
        } else {
          _requestFocus(_playFocus);
        }
        return KeyEventResult.handled;
      }
    }
    if (_skipFocus.hasPrimaryFocus &&
        (key == LogicalKeyboardKey.arrowDown ||
            key == LogicalKeyboardKey.arrowUp)) {
      if (key == LogicalKeyboardKey.arrowDown) {
        c.onUserActivity();
        _requestFocus(_playFocus);
      } else {
        _requestFocus(_surfaceFocus);
      }
      return KeyEventResult.handled;
    }
    if (horizontal ||
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown) {
      c.onUserActivity();
    }
    return KeyEventResult.ignored;
  }

  Future<void> _openEpisodes() async {
    final c = controller!;
    if (!c.canBrowseEpisodes) return;
    final origin = FocusManager.instance.primaryFocus;
    c.setControlsPinned(true);
    unawaited(c.loadEpisodeList());
    final scheme = AppUiTheme.of(
      _presentationThemeKey.currentContext ?? context,
    ).colorScheme;
    final screen = MediaQuery.sizeOf(context);
    final s = TvDesign.scaleOf(context);
    final panelWidth = math.min(460 * s, math.max(360 * s, screen.width * .42));
    await showAppDialog<void>(
      context: _presentationThemeKey.currentContext!,
      useRootNavigator: false,

      builder: (context) => Align(
        alignment: Alignment.centerRight,
        child: Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: scheme.surfaceContainer,
            borderRadius: const BorderRadius.horizontal(
              left: Radius.circular(AppRadii.xl),
            ),
          ),
          child: SizedBox(
            width: panelWidth,
            height: double.infinity,
            child: SafeArea(
              child: ListenableBuilder(
                listenable: c,
                builder: (context, _) => PlayerEpisodeBrowser(
                  controller: c,
                  tv: true,
                  onClose: () => Navigator.pop(context),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (mounted && !_closing) {
      c.setControlsPinned(false);
      c.onUserActivity();
      _requestFocus(origin?.canRequestFocus == true ? origin! : _playFocus);
    }
  }

  Future<void> _panel(_TvPanel panel) async {
    final c = controller!, l = AppLocalizations.of(context);
    final origin = FocusManager.instance.primaryFocus;
    c.setControlsPinned(true);
    // Keep the remote target mounted/focusable while opening another source.
    // A disabled action drops focus; autofocus does not run again on re-enable.
    var applying = false;
    Future<void> apply(Future<void> Function() operation) async {
      if (applying || c.loading) return;
      applying = true;
      try {
        await operation();
      } finally {
        applying = false;
      }
    }

    final title = switch (panel) {
      _TvPanel.tracks => l.mobileTracks,
      _TvPanel.quality => l.quality,
      _TvPanel.source => l.mediaSource,
      _TvPanel.speed => l.mobileSpeed,
      _TvPanel.skip => l.playerSkipSettings,
      _TvPanel.output => l.playbackOutputSection,
    };
    final scheme = AppUiTheme.of(
      _presentationThemeKey.currentContext ?? context,
    ).colorScheme;
    final screen = MediaQuery.sizeOf(context);
    final s = TvDesign.scaleOf(context);
    final panelWidth = math.min(400 * s, math.max(320 * s, screen.width * .38));
    await showAppDialog<void>(
      context: _presentationThemeKey.currentContext!,
      useRootNavigator: false,

      builder: (context) => Align(
        key: const Key('tv-player-panel'),
        alignment: Alignment.centerRight,
        child: Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: scheme.surfaceContainer,
            borderRadius: const BorderRadius.horizontal(
              left: Radius.circular(AppRadii.xl),
            ),
          ),
          child: SizedBox(
            width: panelWidth,
            height: double.infinity,
            child: SafeArea(
              child: Padding(
                padding: EdgeInsets.fromLTRB(24 * s, 24 * s, 24 * s, 20 * s),
                child: DefaultTextStyle.merge(
                  style: AppUiTheme.of(context).textTheme.bodyLarge!
                      .copyWith(color: scheme.onSurface),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        title,
                        style: AppUiTheme.of(context).textTheme.headlineSmall
                            ?.copyWith(color: scheme.onSurface),
                      ),
                      const SizedBox(height: 6),
                      ListenableBuilder(
                        listenable: c,
                        builder: (context, _) => Text(
                          _panelValue(c, panel, l),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppUiTheme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ),
                      SizedBox(height: 14 * s),
                      Expanded(
                        child: ListenableBuilder(
                          listenable: c,
                          builder: (context, _) => SingleChildScrollView(
                            // Reserve the focused action's painted expansion
                            // inside the scroll viewport, including wide TVs.
                            padding: EdgeInsets.symmetric(
                              horizontal:
                                  panelWidth * (TvAction.focusedScale - 1) / 2 +
                                  8,
                              vertical: 6,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              spacing: 6 * s,
                              children: [
                                if (panel == _TvPanel.tracks) ...[
                                  if (c.canSwitchAudioTrack)
                                    _panelLabel(l.audioTrack),
                                  if (c.canSwitchAudioTrack)
                                    for (final track in c.selectableAudioTracks)
                                      TvAction(
                                        variant: TvActionVariant.tile,
                                        key: ValueKey('audio-${track.index}'),
                                        autofocus:
                                            track.index == c.audioStreamIndex ||
                                            (!c.selectableAudioTracks.any(
                                                  (t) =>
                                                      t.index ==
                                                      c.audioStreamIndex,
                                                ) &&
                                                track ==
                                                    c
                                                        .selectableAudioTracks
                                                        .first),
                                        selected:
                                            c.audioStreamIndex == track.index,
                                        onPressed: () => apply(
                                          () => c.setAudio(track.index),
                                        ),
                                        child: _choiceLabel(
                                          track.label,
                                          selected:
                                              c.audioStreamIndex == track.index,
                                        ),
                                      ),
                                  if (c.canConfigureSubtitles ||
                                      c.canImportSubtitleFiles) ...[
                                    const SizedBox(height: 16),
                                    _panelLabel(l.subtitleTrackPrimary),
                                    TvAction(
                                      variant: TvActionVariant.tile,
                                      key: const Key('tv-subtitle-off'),
                                      autofocus:
                                          !c.canSwitchAudioTrack &&
                                          (c.subtitleStreamIndex == null ||
                                              !c.selectableSubtitleTracks.any(
                                                (t) =>
                                                    t.index ==
                                                    c.subtitleStreamIndex,
                                              )),
                                      selected:
                                          c.subtitleStreamIndex == null &&
                                          c.primarySubtitleFileId == null,
                                      onPressed: () =>
                                          apply(() => c.setSubtitle(null)),
                                      child: _choiceLabel(
                                        l.subtitleOff,
                                        selected:
                                            c.subtitleStreamIndex == null &&
                                            c.primarySubtitleFileId == null,
                                      ),
                                    ),
                                    for (final track
                                        in c.selectableSubtitleTracks)
                                      TvAction(
                                        variant: TvActionVariant.tile,
                                        key: ValueKey(
                                          'subtitle-${track.index}',
                                        ),
                                        autofocus:
                                            !c.canSwitchAudioTrack &&
                                            c.subtitleStreamIndex ==
                                                track.index,
                                        selected:
                                            c.subtitleStreamIndex ==
                                            track.index,
                                        onPressed: () => apply(
                                          () => c.setSubtitle(track.index),
                                        ),
                                        child: _choiceLabel(
                                          track.label,
                                          detail:
                                              c.subtitleStreamOccupiesOtherSlot(
                                                0,
                                                track.index,
                                              )
                                              ? l.subtitleSlotOccupied
                                              : null,
                                          selected:
                                              c.subtitleStreamIndex ==
                                              track.index,
                                        ),
                                      ),
                                    for (final file in c.sessionSubtitleFiles)
                                      TvAction(
                                        variant: TvActionVariant.tile,
                                        key: ValueKey(
                                          'tv-subtitle-file-${file.id}',
                                        ),
                                        autofocus: false,
                                        selected:
                                            c.primarySubtitleFileId == file.id,
                                        onPressed: () => apply(
                                          () => c.setSubtitleFromFile(file.id),
                                        ),
                                        child: _choiceLabel(
                                          file.label,
                                          detail:
                                              c.subtitleFileOccupiesOtherSlot(
                                                0,
                                                file.id,
                                              )
                                              ? l.subtitleSlotOccupied
                                              : null,
                                          selected:
                                              c.primarySubtitleFileId ==
                                              file.id,
                                        ),
                                      ),
                                    const SizedBox(height: 16),
                                    _panelLabel(l.subtitleTrackSecondary),
                                    TvAction(
                                      variant: TvActionVariant.tile,
                                      key: const Key(
                                        'tv-subtitle-secondary-off',
                                      ),
                                      autofocus: false,
                                      selected: !c.hasSecondarySubtitle,
                                      onPressed: () => apply(
                                        () => c.setSecondarySubtitle(null),
                                      ),
                                      child: _choiceLabel(
                                        l.subtitleOff,
                                        selected: !c.hasSecondarySubtitle,
                                      ),
                                    ),
                                    for (final track
                                        in c.selectableSubtitleTracks)
                                      if (!c.streamIsBurnedIn(track.index))
                                        TvAction(
                                          variant: TvActionVariant.tile,
                                          key: ValueKey(
                                            'tv-subtitle-secondary-${track.index}',
                                          ),
                                          autofocus: false,
                                          selected:
                                              c.secondarySubtitleStreamIndex ==
                                              track.index,
                                          onPressed: () => apply(
                                            () => c.setSecondarySubtitle(
                                              track.index,
                                            ),
                                          ),
                                          child: _choiceLabel(
                                            track.label,
                                            detail:
                                                c.subtitleStreamOccupiesOtherSlot(
                                                  1,
                                                  track.index,
                                                )
                                                ? l.subtitleSlotOccupied
                                                : null,
                                            selected:
                                                c.secondarySubtitleStreamIndex ==
                                                track.index,
                                          ),
                                        ),
                                    for (final file in c.sessionSubtitleFiles)
                                      TvAction(
                                        variant: TvActionVariant.tile,
                                        key: ValueKey(
                                          'tv-subtitle-secondary-file-${file.id}',
                                        ),
                                        autofocus: false,
                                        selected:
                                            c.secondarySubtitleFileId ==
                                            file.id,
                                        onPressed: () => apply(
                                          () => c.setSecondarySubtitleFromFile(
                                            file.id,
                                          ),
                                        ),
                                        child: _choiceLabel(
                                          file.label,
                                          detail:
                                              c.subtitleFileOccupiesOtherSlot(
                                                1,
                                                file.id,
                                              )
                                              ? l.subtitleSlotOccupied
                                              : null,
                                          selected:
                                              c.secondarySubtitleFileId ==
                                              file.id,
                                        ),
                                      ),
                                    if (c.canImportSubtitleFiles)
                                      TvAction(
                                        variant: TvActionVariant.tile,
                                        key: const Key('tv-subtitle-import'),
                                        autofocus: false,
                                        selected: false,
                                        onPressed: () =>
                                            apply(() => c.importSubtitleFile()),
                                        child: _choiceLabel(
                                          l.subtitleImportLocal,
                                          selected: false,
                                        ),
                                      ),
                                    if (_tvSubtitleNotice(l, c) != null)
                                      Padding(
                                        key: const Key(
                                          'tv-subtitle-import-notice',
                                        ),
                                        padding: const EdgeInsets.only(top: 4),
                                        child: Text(
                                          _tvSubtitleNotice(l, c)!,
                                          style: AppUiTheme.of(context)
                                              .textTheme
                                              .bodySmall
                                              ?.copyWith(
                                                color: AppUiTheme.of(context)
                                                    .colorScheme
                                                    .onSurfaceVariant,
                                              ),
                                        ),
                                      ),
                                    if (c.canAdjustSubtitleSize) ...[
                                      const SizedBox(height: 16),
                                      _panelLabel(l.phoneSubtitleSize),
                                      for (final size
                                          in PhoneSubtitleSize.values)
                                        TvAction(
                                          variant: TvActionVariant.tile,
                                          key: ValueKey(
                                            'tv-subtitle-size-${size.name}',
                                          ),
                                          selected:
                                              !c
                                                  .phoneSubtitleSettings
                                                  .originalAss &&
                                              c.phoneSubtitleSettings.size ==
                                                  size,
                                          onPressed: () =>
                                              c.setPhoneSubtitleSettings(
                                                PhoneSubtitleSettings(
                                                  size: size,
                                                  originalAss: false,
                                                ),
                                              ),
                                          child: _choiceLabel(
                                            switch (size) {
                                              PhoneSubtitleSize.small =>
                                                l.phoneSubtitleSmall,
                                              PhoneSubtitleSize.standard =>
                                                l.phoneSubtitleStandard,
                                              PhoneSubtitleSize.large =>
                                                l.phoneSubtitleLarge,
                                              PhoneSubtitleSize.extraLarge =>
                                                l.phoneSubtitleExtraLarge,
                                            },
                                            selected:
                                                !c
                                                    .phoneSubtitleSettings
                                                    .originalAss &&
                                                c.phoneSubtitleSettings.size ==
                                                    size,
                                          ),
                                        ),
                                      TvAction(
                                        variant: TvActionVariant.tile,
                                        key: const Key('tv-subtitle-original'),
                                        selected:
                                            c.phoneSubtitleSettings.originalAss,
                                        onPressed: () =>
                                            c.setPhoneSubtitleSettings(
                                              PhoneSubtitleSettings(
                                                size: c
                                                    .phoneSubtitleSettings
                                                    .size,
                                                originalAss: !c
                                                    .phoneSubtitleSettings
                                                    .originalAss,
                                              ),
                                            ),
                                        child: _choiceLabel(
                                          l.phoneSubtitleOriginal,
                                          selected: c
                                              .phoneSubtitleSettings
                                              .originalAss,
                                        ),
                                      ),
                                    ] else
                                      Padding(
                                        padding: const EdgeInsets.only(top: 12),
                                        child: Text(l.phoneSubtitleUnavailable),
                                      ),
                                  ],
                                ],
                                if (panel == _TvPanel.source)
                                  for (final source in c.mediaSources)
                                    TvAction(
                                      variant: TvActionVariant.tile,
                                      key: ValueKey('source-${source.id}'),
                                      autofocus:
                                          source.id == c.activeMediaSourceId ||
                                          (!c.mediaSources.any(
                                                (s) =>
                                                    s.id ==
                                                    c.activeMediaSourceId,
                                              ) &&
                                              source == c.mediaSources.first),
                                      selected:
                                          c.activeMediaSourceId == source.id,
                                      onPressed: () => apply(
                                        () => c.switchMediaVersion(source.id),
                                      ),
                                      child: _choiceLabel(
                                        source.presentation.headline,
                                        detail: source.presentation.detail,
                                        selected:
                                            c.activeMediaSourceId == source.id,
                                      ),
                                    ),
                                if (panel == _TvPanel.quality)
                                  for (final bitrate in c.availableBitrates)
                                    TvAction(
                                      variant: TvActionVariant.tile,
                                      key: ValueKey('tv-quality-$bitrate'),
                                      autofocus:
                                          bitrate == c.maxStreamingBitrate ||
                                          (!c.availableBitrates.contains(
                                                c.maxStreamingBitrate,
                                              ) &&
                                              bitrate ==
                                                  c.availableBitrates.first),
                                      selected:
                                          c.maxStreamingBitrate == bitrate,
                                      onPressed: () =>
                                          apply(() => c.setMaxBitrate(bitrate)),
                                      child: _choiceLabel(
                                        playerQualityLabel(l, bitrate),
                                        selected:
                                            c.maxStreamingBitrate == bitrate,
                                      ),
                                    ),
                                if (panel == _TvPanel.skip) ...[
                                  TvAction(
                                    variant: TvActionVariant.tile,
                                    key: const Key('tv-skip-intro-enabled'),
                                    autofocus: true,
                                    selected: c.skipIntroEnabled,
                                    onPressed: () => c.setSkipEnabled(
                                      PlayerSkipKind.intro,
                                      !c.skipIntroEnabled,
                                    ),
                                    child: _choiceLabel(
                                      l.settingsSkipIntro,
                                      selected: c.skipIntroEnabled,
                                    ),
                                  ),
                                  TvAction(
                                    variant: TvActionVariant.tile,
                                    key: const Key('tv-skip-outro-enabled'),
                                    selected: c.skipOutroEnabled,
                                    onPressed: () => c.setSkipEnabled(
                                      PlayerSkipKind.outro,
                                      !c.skipOutroEnabled,
                                    ),
                                    child: _choiceLabel(
                                      l.settingsSkipOutro,
                                      selected: c.skipOutroEnabled,
                                    ),
                                  ),
                                ],
                                if (panel == _TvPanel.output)
                                  PlaybackOutputPanelView(controller: c),
                                if (panel == _TvPanel.speed)
                                  for (final rate in kPlaybackRateLadder)
                                    TvAction(
                                      variant: TvActionVariant.tile,
                                      key: ValueKey('tv-rate-$rate'),
                                      autofocus: rate == c.playbackRate,
                                      selected: c.playbackRate == rate,
                                      onPressed: () =>
                                          apply(() => c.setRate(rate)),
                                      child: _choiceLabel(
                                        '${rate}x',
                                        selected: c.playbackRate == rate,
                                      ),
                                    ),
                                if (c.playbackLineFailure != null &&
                                    !playbackNeedsLineStatus(c))
                                  Text(
                                    c.playbackLineFailure!,
                                    key: const Key('playback-line-failure'),
                                  ),
                                if (c.trackFailure != null)
                                  Text(c.trackFailure!),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TvAction(
                        variant: TvActionVariant.tile,
                        key: const Key('tv-panel-back'),
                        onPressed: () => Navigator.pop(context),
                        child: Text(l.mobileBack),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (mounted && !_closing) {
      c.setControlsPinned(false);
      c.onUserActivity();
      _requestFocus(origin?.canRequestFocus == true ? origin! : _playFocus);
    }
  }

  @override
  void dispose() {
    _auth?.removeListener(_authChanged);
    _lifecycle?.dispose();
    _playFocus.dispose();
    _surfaceFocus.dispose();
    _retryFocus.dispose();
    _lineStatusFocus.dispose();
    _lineConfirmationFocus.dispose();
    _seekFocus.dispose();
    _nextPlayFocus.dispose();
    _nextCancelFocus.dispose();
    _endedReplayFocus.dispose();
    _skipFocus.dispose();
    final c = controller;
    if (c != null) {
      c.removeListener(_playerChanged);
      unawaited(c.disposeAsync(notifyStopped: false));
      c.dispose();
    }
    super.dispose();
  }

  String _panelValue(PlayerController c, _TvPanel panel, AppLocalizations l) {
    switch (panel) {
      case _TvPanel.tracks:
        for (final track in c.audioTracks) {
          if (track.index == c.audioStreamIndex) return track.label;
        }
        return c.subtitleStreamIndex == null ? l.subtitleOff : l.subtitleTrack;
      case _TvPanel.quality:
        return playerQualityLabel(l, c.maxStreamingBitrate);
      case _TvPanel.source:
        for (final source in c.mediaSources) {
          if (source.id == c.activeMediaSourceId) {
            return source.name ?? source.id;
          }
        }
        return l.mediaSource;
      case _TvPanel.speed:
        return '${c.playbackRate}x';
      case _TvPanel.skip:
        final enabled = <String>[
          if (c.skipIntroEnabled) l.settingsSkipIntro,
          if (c.skipOutroEnabled) l.settingsSkipOutro,
        ];
        return enabled.isEmpty ? l.playerSettingOff : enabled.join(' · ');
      case _TvPanel.output:
        return playbackVideoOutputLabel(l, c.outputStatus);
    }
  }

  Widget _choiceLabel(String text, {required bool selected, String? detail}) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(text, maxLines: 2, overflow: TextOverflow.ellipsis),
              if (detail != null) ...[
                const SizedBox(height: 4),
                Text(
                  detail,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: context.tvdp(12)),
                ),
              ],
            ],
          ),
        ),
        if (selected) ...[
          SizedBox(width: context.tvdp(10)),
          const Icon(AppIcons.check, fill: AppIcons.filled),
        ],
      ],
    );
  }

  /// 字幕导入/槽位限制的提示文案;无提示时返回 null。
  String? _tvSubtitleNotice(AppLocalizations l, PlayerController c) {
    final refusal = c.subtitleSelectionNotice;
    if (refusal == 'occupied') return l.subtitleSlotOccupied;
    if (refusal == 'burn-in') return l.subtitleBurnInSecondary;
    switch (c.subtitleImportNotice) {
      case SubtitleImportOutcome.duplicate:
        return l.subtitleImportDuplicate;
      case SubtitleImportOutcome.invalidFormat:
        return l.subtitleImportInvalid;
      case SubtitleImportOutcome.tooLarge:
        return l.subtitleImportTooLarge;
      case SubtitleImportOutcome.sessionLimit:
        return l.subtitleImportSessionLimit;
      case SubtitleImportOutcome.unreadable:
        return l.subtitleImportUnreadable;
      case SubtitleImportOutcome.pickerUnavailable:
        return l.subtitleImportPickerUnavailable;
      default:
        return null;
    }
  }

  Widget _panelLabel(String text) => Padding(
    padding: EdgeInsets.fromLTRB(
      context.tvdp(4),
      context.tvdp(10),
      0,
      context.tvdp(6),
    ),
    child: Text(
      text,
      style: AppUiTheme.of(context).textTheme.labelLarge?.copyWith(
        color: AppUiTheme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );

  String _time(Duration value) {
    final seconds = (value.inSeconds % 60).toString().padLeft(2, '0');
    if (value.inHours == 0) return '${value.inMinutes}:$seconds';
    return '${value.inHours}:${(value.inMinutes % 60).toString().padLeft(2, '0')}:$seconds';
  }

  Widget _action(
    String key,
    IconData icon,
    String label,
    FutureOr<void> Function()? onPressed, {
    FocusNode? focusNode,
    bool showLabel = true,
  }) {
    return ExcludeFocus(
      excluding: playbackNeedsLineStatus(controller!),
      child: _TvPlaybackAction(
        key: Key(key),
        focusNode: focusNode,
        onPressed: onPressed,
        child: showLabel
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, fill: AppIcons.filled),
                  SizedBox(width: context.tvdp(6)),
                  Text(label),
                ],
              )
            : AppTooltip(
                message: label,
                child: Icon(icon, fill: AppIcons.filled),
              ),
      ),
    );
  }

  Widget _timeline(PlayerController c) {
    final position = Duration(
      milliseconds: (_seek ?? c.position.inMilliseconds).round(),
    );
    return Focus(
      skipTraversal: true,
      canRequestFocus: false,
      onFocusChange: (focused) {
        if (!focused &&
            !_surfaceSeeking &&
            _seek != null &&
            mounted &&
            !_closing) {
          setState(() => _seek = null);
          c.setControlsPinned(false);
        }
      },
      onKeyEvent: (_, event) {
        if ((event is KeyDownEvent || event is KeyRepeatEvent) &&
            (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
                event.logicalKey == LogicalKeyboardKey.arrowRight)) {
          _previewSeek(event.logicalKey, repeat: event is KeyRepeatEvent);
          return KeyEventResult.handled;
        }
        if (event is KeyUpEvent) _scanRepeats = 0;
        return KeyEventResult.ignored;
      },
      child: _TvPlaybackAction(
        key: const Key('tv-player-seek'),
        focusNode: _seekFocus,
        onPressed: c.loading || _failed || c.duration <= Duration.zero
            ? null
            : _commitSeek,
        subtle: true,
        child: Column(
          children: [
            BufferedRangesProgressIndicator(
              height: context.tvdp(7),
              snapshot: c.bufferSnapshot,
              duration: c.duration,
              value: c.duration.inMilliseconds <= 0
                  ? 0
                  : (position.inMilliseconds / c.duration.inMilliseconds).clamp(
                      0,
                      1,
                    ),
            ),
            SizedBox(height: context.tvdp(6)),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _time(position),
                  style: AppUiTheme.of(context).textTheme.labelLarge?.copyWith(
                    color: CupertinoColors.white,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                Text(
                  c.duration > Duration.zero
                      ? '${AppLocalizations.of(context).playerRemainingClock(_time(c.duration - position < Duration.zero ? Duration.zero : c.duration - position))}  /  ${_time(c.duration)}'
                      : _time(c.duration),
                  style: AppUiTheme.of(context).textTheme.labelLarge?.copyWith(
                    color: const Color(0xb3ffffff),
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 控制层:左上标题与状态,右上关闭;底部依次是网速、时间轴与控制行。
  /// 尺寸按 960 画布换算,4K 面板上同样比例。
  Widget _overlay(
    BuildContext context,
    PlayerController c,
    AppLocalizations l,
    String status,
    bool ready,
  ) {
    final theme = AppUiTheme.of(context);
    final size = MediaQuery.sizeOf(context);
    final s = TvDesign.scaleOf(context);
    final gutter = tvSafeGutter(size.width);
    final vertical = tvSafeVertical(size.height);
    final secondary = theme.textTheme.bodyMedium?.copyWith(
      color: CupertinoColors.white.withValues(alpha: .72),
    );
    return DecoratedBox(
      key: const Key('tv-player-gradient'),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            CupertinoColors.black.withValues(
              alpha: AppScrim.of(context, AppScrim.top),
            ),
            CupertinoColors.black.withValues(alpha: 0),
            CupertinoColors.black.withValues(
              alpha: AppScrim.of(context, AppScrim.playerBarSoft),
            ),
            CupertinoColors.black.withValues(
              alpha: AppScrim.of(context, AppScrim.playerBar),
            ),
          ],
          stops: const [0, .32, .6, 1],
        ),
      ),
      child: SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(gutter, vertical, gutter, vertical),
          child: DefaultTextStyle.merge(
            style: (theme.textTheme.bodyMedium ?? const TextStyle()).copyWith(
              color: CupertinoColors.white,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (playbackTitleParts(
                                c.item,
                                fallback: l.playerLoading,
                              ).eyebrow
                              case final eyebrow?)
                            Text(
                              eyebrow,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall?.copyWith(
                                color: CupertinoColors.white.withValues(
                                  alpha: .78,
                                ),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          Text(
                            playbackTitleParts(
                              c.item,
                              fallback: l.playerLoading,
                            ).title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.headlineSmall?.copyWith(
                              color: CupertinoColors.white,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          SizedBox(height: 4 * s),
                          Row(
                            children: [
                              Icon(
                                c.isPlaying ? AppIcons.play : AppIcons.pause,
                                fill: AppIcons.filled,
                                size: 16 * s,
                                color: const Color(0xb3ffffff),
                              ),
                              SizedBox(width: 6 * s),
                              Flexible(
                                child: Text(
                                  status,
                                  maxLines: 2,
                                  style: secondary,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    SizedBox(width: 16 * s),
                    Padding(
                      padding: EdgeInsets.only(top: 10 * s, right: 14 * s),
                      child: AppTooltip(
                        message: l.playerNetworkSpeedTooltip,
                        child: NetworkSpeedReadout(
                          key: const Key('tv-player-network-speed'),
                          bytesPerSecond: c.cacheSpeedBytesPerSec,
                          textStyle: theme.textTheme.labelMedium,
                          color: const Color(0xb3ffffff),
                        ),
                      ),
                    ),
                    _action(
                      'tv-player-close',
                      AppIcons.close,
                      l.closePlayer,
                      _close,
                    ),
                  ],
                ),
                Expanded(
                  child: Center(
                    child: playbackNeedsLineStatus(c)
                        ? PlayerLineStatus(
                            controller: c,
                            primaryFocusNode: c.switchConfirmation != null
                                ? _lineConfirmationFocus
                                : c.isRecovering
                                ? _lineStatusFocus
                                : _retryFocus,
                            onChooseLines: () =>
                                unawaited(showPlaybackLineDialog(context, c)),
                          )
                        : c.loading
                        ? SizedBox.square(
                            dimension: 44 * s,
                            child: CupertinoActivityIndicator(
                              radius: 10 * s,
                              color: CupertinoColors.white,
                            ),
                          )
                        : _failed
                        ? _action(
                            'tv-player-retry',
                            AppIcons.refresh,
                            c.sessionExpired ? l.connect : l.retry,
                            c.sessionExpired
                                ? () async {
                                    await _close();
                                    await _auth?.logout();
                                  }
                                : c.retryPlayback,
                            focusNode: _retryFocus,
                          )
                        : const SizedBox.shrink(),
                  ),
                ),
                DefaultTextStyle.merge(
                  style: secondary,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (c.progressSyncFailed) Text(l.progressSyncFailed),
                      if (c.networkSlow)
                        Row(
                          children: [
                            Expanded(child: Text(l.networkSlowHint)),
                            AppIconButton(
                              key: const Key('tv-dismiss-network-hint'),
                              tooltip: '关闭',
                              color: CupertinoColors.white,
                              onPressed: c.dismissNetworkSlowHint,
                              icon: const Icon(
                                AppIcons.close,
                                fill: AppIcons.filled,
                              ),
                            ),
                          ],
                        ),
                      if (c.playbackLineFailure != null &&
                          !playbackNeedsLineStatus(c))
                        Text(
                          c.playbackLineFailure!,
                          key: const Key('playback-line-failure'),
                        ),
                      if (c.trackFailure != null) Text(c.trackFailure!),
                      if (c.backgroundReleased) Text(l.mobileBackgroundPaused),
                    ],
                  ),
                ),
                ExcludeFocus(
                  excluding: playbackNeedsLineStatus(c),
                  child: _timeline(c),
                ),
                SizedBox(height: 10 * s),
                LayoutBuilder(
                  builder: (context, constraints) => SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    clipBehavior: Clip.none,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minWidth: constraints.maxWidth,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          _action(
                            'tv-player-toggle',
                            c.isPlaying ? AppIcons.pause : AppIcons.play,
                            c.isPlaying ? l.pause : l.play,
                            ready ? c.togglePlay : null,
                            focusNode: _playFocus,
                          ),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              for (final control in <Widget>[
                                if (c.canBrowseEpisodes)
                                  _action(
                                    'tv-player-episodes',
                                    AppIcons.episodes,
                                    l.playerEpisodes,
                                    ready ? _openEpisodes : null,
                                  ),
                                if (c.canSwitchAudioTrack ||
                                    c.canConfigureSubtitles ||
                                    c.canImportSubtitleFiles)
                                  _action(
                                    'tv-player-tracks',
                                    AppIcons.subtitles,
                                    c.canSwitchAudioTrack
                                        ? l.mobileTracks
                                        : l.subtitleTrack,
                                    ready
                                        ? () => _panel(_TvPanel.tracks)
                                        : null,
                                  ),
                                if (c.canSwitchQuality)
                                  _action(
                                    'tv-player-quality',
                                    AppIcons.quality,
                                    l.quality,
                                    ready
                                        ? () => _panel(_TvPanel.quality)
                                        : null,
                                  ),
                                ExcludeFocus(
                                  excluding: playbackNeedsLineStatus(c),
                                  child: SourceSwitchButton(
                                    controller: c,
                                    surface: PlaybackLineSurface.dialog,
                                  ),
                                ),
                                if (c.canSwitchMediaSource)
                                  _action(
                                    'tv-player-source',
                                    AppIcons.mediaSource,
                                    l.mediaSource,
                                    ready
                                        ? () => _panel(_TvPanel.source)
                                        : null,
                                  ),
                                _action(
                                  'tv-player-skip',
                                  AppIcons.skipNext,
                                  l.playerSkipSettings,
                                  () => _panel(_TvPanel.skip),
                                ),
                                _action(
                                  'tv-player-speed',
                                  AppIcons.speed,
                                  '${c.playbackRate}x',
                                  ready ? () => _panel(_TvPanel.speed) : null,
                                ),
                                _action(
                                  'tv-player-output',
                                  AppIcons.output,
                                  l.playbackOutputSection,
                                  () => _panel(_TvPanel.output),
                                ),
                              ]) ...[SizedBox(width: 8 * s), control],
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AppUiTheme(
    // Playback stays dark even under a light application theme. Generate the
    // TV roles directly because an ancestor TvStageTheme already owns its guard.
    data: TvStageTheme.themeFor(AppUiTheme.tvDark(), TvDesign.scaleOf(context)),
    child: Builder(key: _presentationThemeKey, builder: _buildPlayer),
  );

  Widget _buildPlayer(BuildContext context) {
    final c = controller!, l = AppLocalizations.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (popped, _) {
        if (!popped) _back();
      },
      child: CupertinoPageScaffold(
        backgroundColor: CupertinoColors.black,
        child: Focus(
          focusNode: _surfaceFocus,
          skipTraversal: true,
          autofocus: true,
          onKeyEvent: _key,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Keep this sibling mounted while loading, showing controls or panels.
              ExcludeFocus(child: c.backend.buildView()),
              Positioned.fill(
                child: IgnorePointer(
                  child: SubtitleViewportReporter(controller: c),
                ),
              ),
              ListenableBuilder(
                listenable: c,
                builder: (context, _) {
                  if (c.permissionRevoked) {
                    // Cover stale texture and semantics until the owned
                    // revocation cleanup exits this actual-source route.
                    return const ColoredBox(color: CupertinoColors.black);
                  }
                  if (c.playbackEnded &&
                      c.nextEpisode == null &&
                      !c.loading &&
                      !_failed) {
                    return PlaybackEndedPanel(
                      tv: true,
                      replayFocus: _endedReplayFocus,
                      title: c.item?.displayName ?? '',
                      onReplay: () => unawaited(c.replay()),
                      onClose: () => unawaited(_close()),
                      onViewSeries: c.item?.seriesId?.isNotEmpty == true
                          ? () => unawaited(
                              _close(
                                viewSeriesId: c.item!.seriesId,
                                seasonId: c.item!.seasonId,
                              ),
                            )
                          : null,
                    );
                  }
                  final visible =
                      c.controlsVisible ||
                      playbackNeedsLineStatus(c) ||
                      c.loading ||
                      _failed ||
                      c.progressSyncFailed ||
                      c.trackFailure != null;
                  // Offstage still rebuilds and lays out its child on every
                  // position/cache notification. Keep the native video sibling
                  // mounted, but do no control layout while it is hidden.
                  if (!visible) return const SizedBox.shrink();
                  final ready = !c.loading && !_failed;
                  final status = c.loading
                      ? l.playerLoading
                      : _failed
                      ? (c.sessionExpired
                            ? l.playbackSessionExpired
                            : c.disconnected
                            ? playbackClassifiedFailureTitle(
                                    c.loadFailure?.kind,
                                    l,
                                  ) ??
                                  l.playbackDisconnected
                            : c.error == PlayerErrorKind.noStream
                            ? l.noPlayableStream
                            : l.playbackFailed)
                      : c.playbackEnded
                      ? l.playbackEnded
                      : c.isBuffering
                      ? l.playerBuffering
                      : c.isPlaying
                      ? l.playerPlaying
                      : l.pause;
                  return _overlay(context, c, l, status, ready);
                },
              ),
              ListenableBuilder(
                listenable: c,
                builder: (context, _) {
                  final segment = c.activeSkipSegment;
                  if (_skipPromptId(c) == null || segment == null) {
                    return const SizedBox.shrink();
                  }
                  final screen = MediaQuery.sizeOf(context);
                  final lifted = c.controlsVisible;
                  return Positioned(
                    right: tvSafeGutter(screen.width),
                    bottom:
                        tvSafeVertical(screen.height) +
                        (lifted ? context.tvdp(148) : context.tvdp(28)),
                    child: _action(
                      'tv-player-skip-segment',
                      AppIcons.skipNext,
                      segment.kind == PlayerSkipKind.outro
                          ? l.skipOutro
                          : l.skipIntro,
                      () => c.skipCurrentSegment(),
                      focusNode: _skipFocus,
                    ),
                  );
                },
              ),
              ListenableBuilder(
                listenable: c,
                builder: (context, _) {
                  if (c.nextEpisode == null || c.error != null) {
                    return const SizedBox.shrink();
                  }
                  final screen = MediaQuery.sizeOf(context);
                  return Positioned(
                    left: tvSafeGutter(screen.width),
                    bottom: tvSafeVertical(screen.height) + context.tvdp(188),
                    child: NextEpisodeCard(
                      controller: c,
                      playFocus: _nextPlayFocus,
                      cancelFocus: _nextCancelFocus,
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _TvPanel { tracks, quality, source, speed, skip, output }

/// 播放控制按钮:静止时半透明黑底白字,聚焦整块反相为白底黑字,
/// 减少动效时同样即时生效。时间轴用 [subtle]:只加描边,画面仍是背景。
class _TvPlaybackAction extends StatefulWidget {
  const _TvPlaybackAction({
    super.key,
    required this.child,
    required this.onPressed,
    this.focusNode,
    this.subtle = false,
  });
  final Widget child;
  final FutureOr<void> Function()? onPressed;
  final FocusNode? focusNode;
  final bool subtle;
  @override
  State<_TvPlaybackAction> createState() => _TvPlaybackActionState();
}

class _TvPlaybackActionState extends State<_TvPlaybackAction> {
  bool _focused = false;
  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final s = TvDesign.scaleOf(context);
    final theme = AppUiTheme.of(context);
    final focused = _focused;
    final foreground = focused && !widget.subtle
        ? CupertinoColors.black
        : CupertinoColors.white;
    return FocusableActionDetector(
      enabled: enabled,
      focusNode: widget.focusNode,
      onFocusChange: (value) => setState(() => _focused = value),
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.select, includeRepeats: false):
            ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.enter, includeRepeats: false):
            ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space, includeRepeats: false):
            ActivateIntent(),
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onPressed?.call();
            return null;
          },
        ),
      },
      child: Semantics(
        button: true,
        enabled: enabled,
        focused: focused,
        child: GestureDetector(
          onTap: widget.onPressed,
          child: Container(
            constraints: BoxConstraints(minHeight: 38 * s),
            padding: widget.subtle
                ? EdgeInsets.symmetric(horizontal: 12 * s, vertical: 10 * s)
                : EdgeInsets.symmetric(horizontal: 14 * s, vertical: 8 * s),
            decoration: BoxDecoration(
              color: widget.subtle
                  ? (focused
                        ? CupertinoColors.white.withValues(alpha: .12)
                        : const Color(0x00000000))
                  : focused
                  ? CupertinoColors.white
                  : CupertinoColors.black.withValues(alpha: .34),
              border: Border.all(
                color: widget.subtle && focused
                    ? CupertinoColors.white
                    : const Color(0x00000000),
                width: 2 * s,
              ),
              borderRadius: BorderRadius.circular(widget.subtle ? 12 * s : 999),
            ),
            child: IconTheme.merge(
              data: IconThemeData(color: foreground, size: 20 * s),
              child: DefaultTextStyle.merge(
                style: (theme.textTheme.labelLarge ?? const TextStyle())
                    .copyWith(color: foreground),
                child: Opacity(opacity: enabled ? 1 : .4, child: widget.child),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
