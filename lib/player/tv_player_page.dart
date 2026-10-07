import 'dart:async';
import 'source_switch_menu.dart';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/player/playback_ended_panel.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/tv_widgets.dart';
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
import 'package:rillight/player/player_controller.dart';
import 'player_window_host.dart';
import 'package:rillight/player/player_window.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/subtitle_viewport.dart';

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
  PlayerController? controller;
  AndroidPlaybackLifecycle? _lifecycle;
  AuthController? _auth;
  Object? _identity;
  bool _closing = false;
  bool _revocationExitScheduled = false;
  bool _focusedFailure = false;
  bool _focusedEnd = false;
  double? _seek;
  bool _surfaceSeeking = false;
  int _scanRepeats = 0;
  final _seekFocus = FocusNode();
  final _playFocus = FocusNode();
  final _surfaceFocus = FocusNode();
  final _retryFocus = FocusNode();
  final _nextPlayFocus = FocusNode();
  final _nextCancelFocus = FocusNode();
  final _endedReplayFocus = FocusNode();
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
      runtime: widget.sourceRequest?.source == null ? null : bindings.runtime,
      openRequest: widget.sourceRequest,
      routeLeaseKey: widget.routeLeaseKey,
      client: auth.client,
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
        final router = GoRouter.maybeOf(context);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) router?.go('/', extra: null);
        });
        WidgetsBinding.instance.ensureVisualUpdate();
      }
      return;
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
    final cardFocused = _nextPlayFocus.hasFocus || _nextCancelFocus.hasFocus;
    if (!c.controlsVisible &&
        _surfaceFocus.hasFocus &&
        !_surfaceFocus.hasPrimaryFocus &&
        !cardFocused) {
      _requestFocus(_surfaceFocus);
    }
    if (c.loading) return;
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context).progressSyncFailedMain),
        ),
      );
    }
    // Keep system back blocked during cleanup. Enabling it before an explicit
    // pop can let a predictive back gesture pop the following detail route.
    // A tracks sheet may cover this route when authentication changes. Remove
    // its overlays first, then pop the route whose session we actually closed.
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
  void _back() {
    final c = controller!;
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
        _requestFocus(c.nextEpisode == null ? _playFocus : _nextPlayFocus);
        return KeyEventResult.handled;
      }
    }
    if (horizontal ||
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown) {
      c.onUserActivity();
    }
    return KeyEventResult.ignored;
  }

  Future<void> _panel(_TvPanel panel) async {
    final c = controller!, l = AppLocalizations.of(context);
    final origin = FocusManager.instance.primaryFocus;
    c.setControlsPinned(true);
    final title = switch (panel) {
      _TvPanel.tracks => l.mobileTracks,
      _TvPanel.quality => l.quality,
      _TvPanel.source => l.mediaSource,
      _TvPanel.speed => l.mobileSpeed,
      _TvPanel.skip => l.playerSkipSettings,
    };
    final scheme = Theme.of(context).colorScheme;
    final screen = MediaQuery.sizeOf(context);
    final s = TvDesign.scaleOf(context);
    final panelWidth = math.min(400 * s, math.max(320 * s, screen.width * .38));
    await showDialog<void>(
      context: context,
      useRootNavigator: false,
      barrierColor: scheme.scrim.withValues(alpha: AppScrim.playerBarrier),
      builder: (context) => Dialog(
        key: const Key('tv-player-panel'),
        alignment: Alignment.centerRight,
        insetPadding: EdgeInsets.zero,
        backgroundColor: scheme.surfaceContainer,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.horizontal(
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
                style: Theme.of(
                  context,
                ).textTheme.bodyLarge!.copyWith(color: scheme.onSurface),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(color: scheme.onSurface),
                    ),
                    const SizedBox(height: 6),
                    ListenableBuilder(
                      listenable: c,
                      builder: (context, _) => Text(
                        _panelValue(c, panel, l),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
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
                                      onPressed: c.loading
                                          ? null
                                          : () => c.setAudio(track.index),
                                      child: _choiceLabel(
                                        track.label,
                                        selected:
                                            c.audioStreamIndex == track.index,
                                      ),
                                    ),
                                if (c.canConfigureSubtitles) ...[
                                  const SizedBox(height: 16),
                                  _panelLabel(l.subtitleTrack),
                                  TvAction(
                                    variant: TvActionVariant.tile,
                                    autofocus:
                                        !c.canSwitchAudioTrack &&
                                        (c.subtitleStreamIndex == null ||
                                            !c.selectableSubtitleTracks.any(
                                              (t) =>
                                                  t.index ==
                                                  c.subtitleStreamIndex,
                                            )),
                                    selected: c.subtitleStreamIndex == null,
                                    onPressed: c.loading
                                        ? null
                                        : () => c.setSubtitle(null),
                                    child: _choiceLabel(
                                      l.subtitleOff,
                                      selected: c.subtitleStreamIndex == null,
                                    ),
                                  ),
                                  for (final track
                                      in c.selectableSubtitleTracks)
                                    TvAction(
                                      variant: TvActionVariant.tile,
                                      key: ValueKey('subtitle-${track.index}'),
                                      autofocus:
                                          !c.canSwitchAudioTrack &&
                                          c.subtitleStreamIndex == track.index,
                                      selected:
                                          c.subtitleStreamIndex == track.index,
                                      onPressed: c.loading
                                          ? null
                                          : () => c.setSubtitle(track.index),
                                      child: _choiceLabel(
                                        track.label,
                                        selected:
                                            c.subtitleStreamIndex ==
                                            track.index,
                                      ),
                                    ),
                                  if (c.canAdjustSubtitleSize) ...[
                                    const SizedBox(height: 16),
                                    _panelLabel(l.phoneSubtitleSize),
                                    for (final size in PhoneSubtitleSize.values)
                                      TvAction(
                                        variant: TvActionVariant.tile,
                                        key: ValueKey(
                                          'tv-subtitle-size-${size.name}',
                                        ),
                                        selected:
                                            c.phoneSubtitleSettings.size ==
                                            size,
                                        onPressed: () =>
                                            c.setPhoneSubtitleSettings(
                                              PhoneSubtitleSettings(
                                                size: size,
                                                originalAss: c
                                                    .phoneSubtitleSettings
                                                    .originalAss,
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
                                              size:
                                                  c.phoneSubtitleSettings.size,
                                              originalAss: !c
                                                  .phoneSubtitleSettings
                                                  .originalAss,
                                            ),
                                          ),
                                      child: _choiceLabel(
                                        l.phoneSubtitleOriginal,
                                        selected:
                                            c.phoneSubtitleSettings.originalAss,
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
                                                  s.id == c.activeMediaSourceId,
                                            ) &&
                                            source == c.mediaSources.first),
                                    selected:
                                        c.activeMediaSourceId == source.id,
                                    onPressed: c.loading
                                        ? null
                                        : () async {
                                            await c.switchMediaVersion(
                                              source.id,
                                            );
                                          },
                                    child: _choiceLabel(
                                      source.name ?? source.id,
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
                                    selected: c.maxStreamingBitrate == bitrate,
                                    onPressed: c.loading
                                        ? null
                                        : () => c.setMaxBitrate(bitrate),
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
                              if (panel == _TvPanel.speed)
                                for (final rate in kPlaybackRateLadder)
                                  TvAction(
                                    variant: TvActionVariant.tile,
                                    key: ValueKey('tv-rate-$rate'),
                                    autofocus: rate == c.playbackRate,
                                    selected: c.playbackRate == rate,
                                    onPressed: c.loading
                                        ? null
                                        : () => c.setRate(rate),
                                    child: _choiceLabel(
                                      '${rate}x',
                                      selected: c.playbackRate == rate,
                                    ),
                                  ),
                              if (c.playbackLineFailure != null)
                                Text(
                                  l.playbackLineFailed(c.playbackLineFailure!),
                                  key: const Key('playback-line-failure'),
                                ),
                              if (c.trackFailure != null) Text(c.trackFailure!),
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
    _seekFocus.dispose();
    _nextPlayFocus.dispose();
    _nextCancelFocus.dispose();
    _endedReplayFocus.dispose();
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
    }
  }

  Widget _choiceLabel(String text, {required bool selected}) {
    return Row(
      children: [
        Expanded(
          child: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis),
        ),
        if (selected) ...[
          SizedBox(width: context.tvdp(10)),
          const Icon(Icons.check_rounded),
        ],
      ],
    );
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
      style: Theme.of(context).textTheme.labelLarge?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
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
  }) {
    return _TvPlaybackAction(
      key: Key(key),
      focusNode: focusNode,
      onPressed: onPressed,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon),
          SizedBox(width: context.tvdp(6)),
          Text(label),
        ],
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
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: Colors.white,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                Text(
                  _time(c.duration),
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: Colors.white70,
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
    final theme = Theme.of(context);
    final size = MediaQuery.sizeOf(context);
    final s = TvDesign.scaleOf(context);
    final gutter = tvSafeGutter(size.width);
    final vertical = tvSafeVertical(size.height);
    final secondary = theme.textTheme.bodyMedium?.copyWith(
      color: Colors.white.withValues(alpha: .72),
    );
    return DecoratedBox(
      key: const Key('tv-player-gradient'),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withValues(alpha: AppScrim.of(context, AppScrim.top)),
            Colors.black.withValues(alpha: 0),
            Colors.black.withValues(
              alpha: AppScrim.of(context, AppScrim.playerBarSoft),
            ),
            Colors.black.withValues(
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
              color: Colors.white,
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
                          Text(
                            c.item?.displayName ?? l.playerLoading,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.headlineSmall?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          SizedBox(height: 4 * s),
                          Row(
                            children: [
                              Icon(
                                c.isPlaying
                                    ? Icons.play_arrow_rounded
                                    : Icons.pause_rounded,
                                size: 16 * s,
                                color: Colors.white70,
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
                    _action(
                      'tv-player-close',
                      Icons.close_rounded,
                      l.closePlayer,
                      _close,
                    ),
                  ],
                ),
                Expanded(
                  child: Center(
                    child: c.loading
                        ? SizedBox.square(
                            dimension: 44 * s,
                            child: CircularProgressIndicator(
                              strokeWidth: 3 * s,
                              color: Colors.white,
                            ),
                          )
                        : _failed
                        ? _action(
                            'tv-player-retry',
                            Icons.refresh_rounded,
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
                            IconButton(
                              key: const Key('tv-dismiss-network-hint'),
                              tooltip: MaterialLocalizations.of(
                                context,
                              ).closeButtonTooltip,
                              color: Colors.white,
                              onPressed: c.dismissNetworkSlowHint,
                              icon: const Icon(Icons.close),
                            ),
                          ],
                        ),
                      if (c.playbackLineFailure != null)
                        Text(
                          l.playbackLineFailed(c.playbackLineFailure!),
                          key: const Key('playback-line-failure'),
                        ),
                      if (c.trackFailure != null) Text(c.trackFailure!),
                      if (c.backgroundReleased) Text(l.mobileBackgroundPaused),
                    ],
                  ),
                ),
                Tooltip(
                  message: l.playerNetworkSpeedTooltip,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: NetworkSpeedReadout(
                      key: const Key('tv-player-network-speed'),
                      bytesPerSecond: c.cacheSpeedBytesPerSec,
                      textStyle: theme.textTheme.labelMedium,
                      color: Colors.white70,
                    ),
                  ),
                ),
                SizedBox(height: 6 * s),
                _timeline(c),
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
                            c.isPlaying
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            c.isPlaying ? l.pause : l.play,
                            ready ? c.togglePlay : null,
                            focusNode: _playFocus,
                          ),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              for (final control in <Widget>[
                                if (c.canSwitchAudioTrack ||
                                    c.canConfigureSubtitles)
                                  _action(
                                    'tv-player-tracks',
                                    Icons.subtitles_outlined,
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
                                    Icons.high_quality_outlined,
                                    l.quality,
                                    ready
                                        ? () => _panel(_TvPanel.quality)
                                        : null,
                                  ),
                                SourceSwitchButton(
                                  controller: c,
                                  surface: PlaybackLineSurface.dialog,
                                ),
                                if (c.canSwitchMediaSource)
                                  _action(
                                    'tv-player-source',
                                    Icons.video_library_outlined,
                                    l.mediaSource,
                                    ready
                                        ? () => _panel(_TvPanel.source)
                                        : null,
                                  ),
                                _action(
                                  'tv-player-skip',
                                  Icons.fast_forward_rounded,
                                  l.playerSkipSettings,
                                  () => _panel(_TvPanel.skip),
                                ),
                                _action(
                                  'tv-player-speed',
                                  Icons.speed_rounded,
                                  '${c.playbackRate}x',
                                  ready ? () => _panel(_TvPanel.speed) : null,
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
  Widget build(BuildContext context) {
    final c = controller!, l = AppLocalizations.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (popped, _) {
        if (!popped) _back();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Focus(
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
                    return const ColoredBox(color: Colors.black);
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
                      c.loading ||
                      _failed ||
                      c.progressSyncFailed ||
                      c.trackFailure != null;
                  final ready = !c.loading && !_failed;
                  final status = c.loading
                      ? l.playerLoading
                      : _failed
                      ? (c.sessionExpired
                            ? l.playbackSessionExpired
                            : c.disconnected
                            ? l.playbackDisconnected
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
                  return Offstage(
                    offstage: !visible,
                    child: ExcludeFocus(
                      excluding: !visible,
                      child: TickerMode(
                        enabled: visible,
                        child: _overlay(context, c, l, status, ready),
                      ),
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
                  return Positioned(
                    left: tvSafeGutter(MediaQuery.sizeOf(context).width),
                    bottom: context.tvdp(150),
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

enum _TvPanel { tracks, quality, source, speed, skip }

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
    final theme = Theme.of(context);
    final focused = _focused;
    final foreground = focused && !widget.subtle ? Colors.black : Colors.white;
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
                        ? Colors.white.withValues(alpha: .12)
                        : Colors.transparent)
                  : focused
                  ? Colors.white
                  : Colors.black.withValues(alpha: .34),
              border: Border.all(
                color: widget.subtle && focused
                    ? Colors.white
                    : Colors.transparent,
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
