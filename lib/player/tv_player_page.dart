import 'package:rillight/player/playback_skip_settings.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/player/network_throughput.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/device_profile.dart';
import 'package:rillight/player/rillight_video_backend.dart';
import 'package:rillight/player/buffered_ranges_track.dart';
import 'package:rillight/player/android_playback_lifecycle.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/next_episode_card.dart';
import 'package:rillight/player/player_controller.dart';
import 'package:rillight/player/player_window.dart';

class TvPlayerPage extends StatefulWidget {
  const TvPlayerPage({
    super.key,
    required this.itemId,
    this.mediaSourceId,
    this.autoResume = true,
  });
  final String itemId;
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
  bool _focusedFailure = false;
  double? _seek;
  bool _surfaceSeeking = false;
  int _scanRepeats = 0;
  final _seekFocus = FocusNode();
  final _playFocus = FocusNode();
  final _surfaceFocus = FocusNode();
  final _retryFocus = FocusNode();
  final _nextPlayFocus = FocusNode();
  final _nextCancelFocus = FocusNode();
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
    final created = PlayerController(
      client: auth.client,
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
    if (_identity !=
        (auth.client.baseUrl, auth.client.userId, auth.client.accessToken)) {
      unawaited(_close());
    }
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
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
    if (_surfaceFocus.hasPrimaryFocus && !c.loading && !_failed) {
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
    await showDialog<void>(
      context: context,
      useRootNavigator: false,
      barrierColor: Colors.black38,
      builder: (context) => Dialog(
        key: const Key('tv-player-panel'),
        alignment: Alignment.centerRight,
        insetPadding: EdgeInsets.zero,
        backgroundColor: const Color(0xff111923),
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(),
        child: SizedBox(
          width: MediaQuery.sizeOf(context).width * .46,
          height: double.infinity,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(28, 24, 28, 24),
              child: DefaultTextStyle.merge(
                style: const TextStyle(fontSize: 20, color: Colors.white),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 18),
                    Expanded(
                      child: ListenableBuilder(
                        listenable: c,
                        builder: (context, _) => SingleChildScrollView(
                          // Reserve the focused action's painted expansion
                          // inside the scroll viewport, including wide TVs.
                          padding: EdgeInsets.symmetric(
                            horizontal:
                                MediaQuery.sizeOf(context).width *
                                    .46 *
                                    (TvAction.focusedScale - 1) /
                                    2 +
                                4,
                            vertical: 6,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (panel == _TvPanel.tracks) ...[
                                Text(l.audioTrack),
                                for (final track in c.audioTracks)
                                  TvAction(
                                    key: ValueKey('audio-${track.index}'),
                                    autofocus: track == c.audioTracks.first,
                                    selected: c.audioStreamIndex == track.index,
                                    onPressed: c.loading
                                        ? null
                                        : () => c.setAudio(track.index),
                                    child: Text(track.label),
                                  ),
                                const SizedBox(height: 16),
                                Text(l.subtitleTrack),
                                TvAction(
                                  autofocus: c.audioTracks.isEmpty,
                                  selected: c.subtitleStreamIndex == null,
                                  onPressed: c.loading
                                      ? null
                                      : () => c.setSubtitle(null),
                                  child: Text(l.subtitleOff),
                                ),
                                for (final track in c.subtitleTracks)
                                  TvAction(
                                    key: ValueKey('subtitle-${track.index}'),
                                    selected:
                                        c.subtitleStreamIndex == track.index,
                                    onPressed: c.loading
                                        ? null
                                        : () => c.setSubtitle(track.index),
                                    child: Text(track.label),
                                  ),
                              ],
                              if (panel == _TvPanel.source)
                                for (final source in c.mediaSources)
                                  TvAction(
                                    key: ValueKey('source-${source.id}'),
                                    autofocus: source == c.mediaSources.first,
                                    selected:
                                        c.activeMediaSourceId == source.id,
                                    onPressed: c.loading
                                        ? null
                                        : () => c.switchMediaSource(source.id),
                                    child: Text(source.name ?? source.id),
                                  ),
                              if (panel == _TvPanel.quality)
                                for (final bitrate in c.availableBitrates)
                                  TvAction(
                                    key: ValueKey('tv-quality-$bitrate'),
                                    autofocus:
                                        bitrate == c.availableBitrates.first,
                                    selected: c.maxStreamingBitrate == bitrate,
                                    onPressed: c.loading
                                        ? null
                                        : () => c.setMaxBitrate(bitrate),
                                    child: Text(
                                      bitrate == kTranscodeBitrates.first
                                          ? l.qualityAuto
                                          : l.qualityMbps(bitrate ~/ 1000000),
                                    ),
                                  ),
                              if (panel == _TvPanel.skip)
                                PlaybackSkipSettings(controller: c),
                              if (panel == _TvPanel.speed)
                                for (final rate in kPlaybackRateLadder)
                                  TvAction(
                                    key: ValueKey('tv-rate-$rate'),
                                    autofocus: rate == c.playbackRate,
                                    selected: c.playbackRate == rate,
                                    onPressed: c.loading
                                        ? null
                                        : () => c.setRate(rate),
                                    child: Text('${rate}x'),
                                  ),
                              if (c.trackFailure != null) Text(c.trackFailure!),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TvAction(
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
    final c = controller;
    if (c != null) {
      c.removeListener(_playerChanged);
      unawaited(c.disposeAsync());
      c.dispose();
    }
    super.dispose();
  }

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
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 28),
            const SizedBox(width: 10),
            Text(
              label,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w500),
            ),
          ],
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
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _time(position),
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    _time(c.duration),
                    style: const TextStyle(fontSize: 22, color: Colors.white70),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              BufferedRangesProgressIndicator(
                snapshot: c.bufferSnapshot,
                duration: c.duration,
                value: c.duration.inMilliseconds <= 0
                    ? 0
                    : (position.inMilliseconds / c.duration.inMilliseconds)
                          .clamp(0, 1),
              ),
            ],
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
              ListenableBuilder(
                listenable: c,
                builder: (context, _) {
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
                        child: DecoratedBox(
                          key: const Key('tv-player-gradient'),
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Color(0xd9101822),
                                Color(0x00101822),
                                Color(0x90101822),
                                Color(0xfa101822),
                              ],
                              stops: [0, .35, .58, 1],
                            ),
                          ),
                          child: SafeArea(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(
                                40,
                                24,
                                40,
                                24,
                              ),
                              child: DefaultTextStyle.merge(
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 20,
                                ),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                c.item?.name ?? l.playerLoading,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  fontSize: 30,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                              const SizedBox(height: 8),
                                              Row(
                                                children: [
                                                  Icon(
                                                    c.isPlaying
                                                        ? Icons
                                                              .play_arrow_rounded
                                                        : Icons.pause_rounded,
                                                    size: 20,
                                                    color: Colors.white70,
                                                  ),
                                                  const SizedBox(width: 8),
                                                  Flexible(
                                                    child: Text(
                                                      status,
                                                      maxLines: 2,
                                                      style: const TextStyle(
                                                        fontSize: 20,
                                                        color: Colors.white70,
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(width: 24),
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
                                            ? const CircularProgressIndicator()
                                            : _failed
                                            ? _action(
                                                'tv-player-retry',
                                                Icons.refresh_rounded,
                                                c.sessionExpired
                                                    ? l.connect
                                                    : l.retry,
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
                                    if (c.progressSyncFailed)
                                      Text(l.progressSyncFailed),
                                    if (c.networkSlow)
                                      Row(
                                        children: [
                                          Expanded(
                                            child: Text(l.networkSlowHint),
                                          ),
                                          IconButton(
                                            key: const Key(
                                              'tv-dismiss-network-hint',
                                            ),
                                            tooltip: MaterialLocalizations.of(
                                              context,
                                            ).closeButtonTooltip,
                                            onPressed: c.dismissNetworkSlowHint,
                                            icon: const Icon(Icons.close),
                                          ),
                                        ],
                                      ),
                                    if (c.trackFailure != null)
                                      Text(c.trackFailure!),
                                    if (c.backgroundReleased)
                                      Text(l.mobileBackgroundPaused),
                                    Tooltip(
                                      message: l.playerNetworkSpeedTooltip,
                                      child: NetworkSpeedReadout(
                                        key: const Key(
                                          'tv-player-network-speed',
                                        ),
                                        bytesPerSecond: c.cacheSpeedBytesPerSec,
                                        textStyle: const TextStyle(
                                          fontSize: 20,
                                        ),
                                        color: Colors.white70,
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    _timeline(c),
                                    const SizedBox(height: 16),
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
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
                                        _action(
                                          'tv-player-tracks',
                                          Icons.subtitles_outlined,
                                          l.mobileTracks,
                                          ready
                                              ? () => _panel(_TvPanel.tracks)
                                              : null,
                                        ),
                                        _action(
                                          'tv-player-quality',
                                          Icons.high_quality_outlined,
                                          l.quality,
                                          ready
                                              ? () => _panel(_TvPanel.quality)
                                              : null,
                                        ),
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
                                          ready
                                              ? () => _panel(_TvPanel.speed)
                                              : null,
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
                    left: 48,
                    bottom: 220,
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

/// Playback controls update their focus ring immediately, including reduced motion.
/// The timeline stays transparent so the video remains the visual backdrop.
class _TvPlaybackAction extends StatefulWidget {
  const _TvPlaybackAction({
    super.key,
    required this.child,
    required this.onPressed,
    this.focusNode,
  });
  final Widget child;
  final FutureOr<void> Function()? onPressed;
  final FocusNode? focusNode;
  @override
  State<_TvPlaybackAction> createState() => _TvPlaybackActionState();
}

class _TvPlaybackActionState extends State<_TvPlaybackAction> {
  bool _focused = false;
  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
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
        focused: _focused,
        child: GestureDetector(
          onTap: widget.onPressed,
          child: Container(
            constraints: const BoxConstraints(minHeight: 56),
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: _focused ? const Color(0xff315d8c) : Colors.transparent,
              border: Border.all(
                color: _focused ? Colors.white : Colors.transparent,
                width: 3,
              ),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Opacity(opacity: enabled ? 1 : .4, child: widget.child),
          ),
        ),
      ),
    );
  }
}
