import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/device_profile.dart';
import 'package:rillight/player/rillight_video_backend.dart';
import 'package:rillight/player/buffered_ranges_track.dart';
import 'package:rillight/player/android_playback_lifecycle.dart';
import 'package:rillight/player/player_bindings.dart';
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
  bool _focusedReady = false;
  bool _focusedFailure = false;
  double? _seek;
  final _playFocus = FocusNode();
  final _surfaceFocus = FocusNode();
  final _retryFocus = FocusNode();
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
    if (controller!.loading || _closing) return;
    if (_failed) {
      if (_focusedFailure) return;
      _focusedFailure = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_closing && ModalRoute.of(context)?.isCurrent == true) {
          _retryFocus.requestFocus();
        }
      });
      return;
    }
    if (_focusedReady && !_focusedFailure) return;
    _focusedFailure = false;
    _focusedReady = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_closing) _playFocus.requestFocus();
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

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final c = controller!, key = event.logicalKey;
    if (key == LogicalKeyboardKey.mediaPlayPause ||
        key == LogicalKeyboardKey.mediaPlay ||
        key == LogicalKeyboardKey.mediaPause) {
      if (event is KeyDownEvent && !c.loading && !_failed) {
        if (key == LogicalKeyboardKey.mediaPlayPause ||
            (key == LogicalKeyboardKey.mediaPlay) != c.isPlaying) {
          c.togglePlay();
        }
        c.onUserActivity();
        if (_surfaceFocus.hasPrimaryFocus) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && !_closing) _playFocus.requestFocus();
          });
        }
      }
      return KeyEventResult.handled;
    }
    // Android Back also invokes PopScope. Handle it there once; Escape is a
    // keyboard-only shortcut and does not produce that platform route event.
    if (key == LogicalKeyboardKey.escape) {
      if (event is KeyDownEvent) _back();
      return KeyEventResult.handled;
    }
    if (!c.controlsVisible && !_failed && !c.loading) {
      if ([
        LogicalKeyboardKey.arrowUp,
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.arrowLeft,
        LogicalKeyboardKey.arrowRight,
        LogicalKeyboardKey.select,
        LogicalKeyboardKey.enter,
      ].contains(key)) {
        c.onUserActivity();
        if (key == LogicalKeyboardKey.select ||
            key == LogicalKeyboardKey.enter) {
          c.togglePlay();
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _playFocus.requestFocus();
        });
        return KeyEventResult.handled;
      }
    } else if ([
      LogicalKeyboardKey.arrowUp,
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.arrowRight,
    ].contains(key)) {
      c.onUserActivity();
      if (_surfaceFocus.hasPrimaryFocus && !c.loading && !_failed) {
        _playFocus.requestFocus();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  Future<void> _tracks() async {
    final c = controller!, l = AppLocalizations.of(context);
    c.setControlsPinned(true);
    await showDialog<void>(
      context: context,
      useRootNavigator: false,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xff151a22),
        surfaceTintColor: Colors.transparent,
        title: Text(l.mobileTracks),
        content: SizedBox(
          width: 640,
          child: ListenableBuilder(
            listenable: c,
            builder: (context, _) => SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(l.audioTrack),
                  for (final track in c.audioTracks)
                    TvAction(
                      key: ValueKey('audio-${track.index}'),
                      autofocus: track == c.audioTracks.first,
                      selected: c.audioStreamIndex == track.index,
                      onPressed: () => c.setAudio(track.index),
                      child: Text(track.label),
                    ),
                  Text(l.subtitleTrack),
                  TvAction(
                    selected: c.subtitleStreamIndex == null,
                    onPressed: () => c.setSubtitle(null),
                    child: Text(l.subtitleOff),
                  ),
                  for (final track in c.subtitleTracks)
                    TvAction(
                      key: ValueKey('subtitle-${track.index}'),
                      selected: c.subtitleStreamIndex == track.index,
                      onPressed: () => c.setSubtitle(track.index),
                      child: Text(track.label),
                    ),
                  if (c.trackFailure != null) Text(c.trackFailure!),
                  Text(l.mediaSource),
                  for (final source in c.mediaSources)
                    TvAction(
                      key: ValueKey('source-${source.id}'),
                      selected: c.activeMediaSourceId == source.id,
                      onPressed: () => c.switchMediaSource(source.id),
                      child: Text(source.name ?? source.id),
                    ),
                  Text(l.quality),
                  for (final bitrate in c.availableBitrates)
                    TvAction(
                      key: ValueKey('tv-quality-$bitrate'),
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
                  Text(l.mobileSpeed),
                  for (final rate in [.5, 1.0, 1.25, 1.5, 2.0])
                    TvAction(
                      selected: c.playbackRate == rate,
                      onPressed: () => c.setRate(rate),
                      child: Text('${rate}x'),
                    ),
                  TvAction(
                    onPressed: () => Navigator.pop(context),
                    child: Text(l.mobileBack),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (mounted && !_closing) c.setControlsPinned(false);
  }

  @override
  void dispose() {
    _auth?.removeListener(_authChanged);
    _lifecycle?.dispose();
    _playFocus.dispose();
    _surfaceFocus.dispose();
    _retryFocus.dispose();
    final c = controller;
    if (c != null) {
      c.removeListener(_playerChanged);
      unawaited(c.disposeAsync());
      c.dispose();
    }
    super.dispose();
  }

  String _time(Duration value) =>
      '${value.inMinutes}:${(value.inSeconds % 60).toString().padLeft(2, '0')}';
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
                  return Offstage(
                    offstage: !visible,
                    child: ExcludeFocus(
                      excluding: !visible,
                      child: SafeArea(
                        child: Padding(
                          padding: const EdgeInsets.all(32),
                          child: Column(
                            children: [
                              ColoredBox(
                                color: Colors.black87,
                                child: Row(
                                  children: [
                                    TvAction(
                                      onPressed: _close,
                                      child: Text(l.closePlayer),
                                    ),
                                    Expanded(
                                      child: Text(
                                        c.item?.name ?? l.playerLoading,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 22),
                                      ),
                                    ),
                                    TvAction(
                                      key: const Key('tv-player-tracks'),
                                      onPressed: c.loading ? null : _tracks,
                                      child: Text(l.mobileTracks),
                                    ),
                                  ],
                                ),
                              ),
                              Expanded(
                                child: Center(
                                  child: c.loading
                                      ? const CircularProgressIndicator()
                                      : _failed
                                      ? ColoredBox(
                                          color: Colors.black87,
                                          child: Padding(
                                            padding: const EdgeInsets.all(20),
                                            child: Column(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Text(
                                                  c.sessionExpired
                                                      ? l.playbackSessionExpired
                                                      : c.disconnected
                                                      ? l.playbackDisconnected
                                                      : c.error ==
                                                            PlayerErrorKind
                                                                .noStream
                                                      ? l.noPlayableStream
                                                      : l.playbackFailed,
                                                ),
                                                TvAction(
                                                  focusNode: _retryFocus,
                                                  autofocus: true,
                                                  onPressed: c.sessionExpired
                                                      ? () async {
                                                          await _close();
                                                          await _auth?.logout();
                                                        }
                                                      : c.retryPlayback,
                                                  child: Text(
                                                    c.sessionExpired
                                                        ? l.connect
                                                        : l.retry,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        )
                                      : const SizedBox.shrink(),
                                ),
                              ),
                              ColoredBox(
                                color: Colors.black87,
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Column(
                                    children: [
                                      if (c.progressSyncFailed)
                                        Text(l.progressSyncFailed),
                                      if (c.networkSlow)
                                        Text(l.networkSlowHint),
                                      if (c.trackFailure != null)
                                        Text(c.trackFailure!),
                                      if (c.backgroundReleased)
                                        Text(l.mobileBackgroundPaused),
                                      if (c.playbackEnded)
                                        Text(l.playbackEnded),
                                      if (c.isBuffering && !c.loading)
                                        const LinearProgressIndicator(),
                                      Focus(
                                        skipTraversal: true,
                                        canRequestFocus: false,
                                        onFocusChange: (focused) {
                                          if (!focused &&
                                              _seek != null &&
                                              mounted &&
                                              !_closing) {
                                            setState(() => _seek = null);
                                            c.setControlsPinned(false);
                                          }
                                        },
                                        onKeyEvent: (_, event) {
                                          if (event is! KeyDownEvent &&
                                              event is! KeyRepeatEvent) {
                                            return KeyEventResult.ignored;
                                          }
                                          if (event.logicalKey !=
                                                  LogicalKeyboardKey
                                                      .arrowLeft &&
                                              event.logicalKey !=
                                                  LogicalKeyboardKey
                                                      .arrowRight) {
                                            return KeyEventResult.ignored;
                                          }
                                          if (!c.loading && !_failed) {
                                            c.setControlsPinned(true);
                                            setState(
                                              () => _seek =
                                                  ((_seek ??
                                                              c
                                                                  .position
                                                                  .inMilliseconds
                                                                  .toDouble()) +
                                                          (event.logicalKey ==
                                                                  LogicalKeyboardKey
                                                                      .arrowLeft
                                                              ? -10000
                                                              : 10000))
                                                      .clamp(
                                                        0,
                                                        c
                                                            .duration
                                                            .inMilliseconds
                                                            .toDouble(),
                                                      ),
                                            );
                                          }
                                          return KeyEventResult.handled;
                                        },
                                        child: TvAction(
                                          key: const Key('tv-player-seek'),
                                          onPressed: c.loading || _failed
                                              ? null
                                              : () async {
                                                  if (_seek != null) {
                                                    await c.seekTo(
                                                      Duration(
                                                        milliseconds: _seek!
                                                            .round(),
                                                      ),
                                                    );
                                                  }
                                                  if (mounted) {
                                                    setState(
                                                      () => _seek = null,
                                                    );
                                                  }
                                                  c.setControlsPinned(false);
                                                },
                                          child: Column(
                                            children: [
                                              Row(
                                                mainAxisAlignment:
                                                    MainAxisAlignment
                                                        .spaceBetween,
                                                children: [
                                                  Text(
                                                    _time(
                                                      Duration(
                                                        milliseconds:
                                                            (_seek ??
                                                                    c
                                                                        .position
                                                                        .inMilliseconds)
                                                                .round(),
                                                      ),
                                                    ),
                                                  ),
                                                  Text(_time(c.duration)),
                                                ],
                                              ),
                                              const SizedBox(height: 8),
                                              BufferedRangesTrack(
                                                snapshot: c.bufferSnapshot,
                                                duration: c.duration,
                                                horizontalInset: 0,
                                                child: LinearProgressIndicator(
                                                  value:
                                                      c
                                                              .duration
                                                              .inMilliseconds <=
                                                          0
                                                      ? 0
                                                      : ((_seek ??
                                                                    c
                                                                        .position
                                                                        .inMilliseconds) /
                                                                c
                                                                    .duration
                                                                    .inMilliseconds)
                                                            .clamp(0, 1),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                      TvAction(
                                        key: const Key('tv-player-toggle'),
                                        focusNode: _playFocus,
                                        autofocus: true,
                                        onPressed: c.loading || _failed
                                            ? null
                                            : c.togglePlay,
                                        child: Text(
                                          c.isPlaying ? l.pause : l.play,
                                          style: const TextStyle(fontSize: 22),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
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
