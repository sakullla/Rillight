import 'dart:async';
import 'package:flutter/material.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/player/android_video_backend.dart';
import 'package:rillight/player/android_playback_lifecycle.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_controller.dart';
import 'package:rillight/player/player_window.dart';

class MobilePlayerPage extends StatefulWidget {
  const MobilePlayerPage({
    super.key,
    required this.itemId,
    this.mediaSourceId,
    this.autoResume = true,
  });
  final String itemId;
  final String? mediaSourceId;
  final bool autoResume;
  @override
  State<MobilePlayerPage> createState() => MobilePlayerPageState();
}

class MobilePlayerPageState extends State<MobilePlayerPage> {
  PlayerController? controller;
  AndroidPlaybackLifecycle? _lifecycle;
  AuthController? _auth;
  Object? _identity;
  bool _closing = false;
  double? _seek;
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
      backend: bindings.createBackend?.call() ?? AndroidVideoBackend(),
      window: bindings.window ?? PlayerWindow(),
      autoResume: widget.autoResume,
      preferredMediaSourceId: widget.mediaSourceId,
      progressInterval: bindings.progressInterval,
      controlsHideAfter: bindings.controlsHideAfter,
      settingsStore: bindings.settingsStore,
      snapshotStore: bindings.snapshotStore,
    );
    controller = created;
    _lifecycle = AndroidPlaybackLifecycle(created);
    unawaited(created.start());
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

  Future<void> _tracks() async {
    final c = controller!, l = AppLocalizations.of(context);
    c.setControlsPinned(true);
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) => FractionallySizedBox(
        heightFactor: .8,
        child: ListenableBuilder(
          listenable: c,
          builder: (context, _) => ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text(
                l.mobileTracks,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              Text(l.audioTrack),
              for (final track in c.audioTracks)
                ListTile(
                  selected: c.audioStreamIndex == track.index,
                  leading: Icon(
                    c.audioStreamIndex == track.index
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                  ),
                  title: Text(track.label),
                  onTap: () => c.setAudio(track.index),
                ),
              const Divider(),
              Text(l.subtitleTrack),
              ListTile(
                selected: c.subtitleStreamIndex == null,
                leading: Icon(
                  c.subtitleStreamIndex == null
                      ? Icons.check_circle
                      : Icons.radio_button_unchecked,
                ),
                title: Text(l.subtitleOff),
                onTap: () => c.setSubtitle(null),
              ),
              for (final track in c.subtitleTracks)
                ListTile(
                  selected: c.subtitleStreamIndex == track.index,
                  leading: Icon(
                    c.subtitleStreamIndex == track.index
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                  ),
                  title: Text(track.label),
                  onTap: () => c.setSubtitle(track.index),
                ),
              if (c.trackFailure != null) Text(c.trackFailure!),
              const Divider(),
              Text(l.mediaSource),
              for (final source in c.mediaSources)
                ListTile(
                  selected: source.id == c.activeMediaSourceId,
                  title: Text(source.name ?? source.id),
                  onTap: () => c.switchMediaSource(source.id),
                ),
              const Divider(),
              Text(l.mobileSpeed),
              Wrap(
                spacing: 8,
                children: [
                  for (final rate in [.5, 1.0, 1.25, 1.5, 2.0])
                    ChoiceChip(
                      label: Text('${rate}x'),
                      selected: c.playbackRate == rate,
                      onSelected: (_) => c.setRate(rate),
                    ),
                ],
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(l.mobileBack),
              ),
            ],
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
    final c = controller;
    if (c != null) {
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
        if (!popped) _close();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            c.backend.buildView(),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: c.toggleControls,
              child: const SizedBox.expand(),
            ),
            ListenableBuilder(
              listenable: c,
              builder: (context, _) =>
                  !c.controlsVisible &&
                      !c.loading &&
                      c.error == null &&
                      !c.disconnected &&
                      !c.sessionExpired &&
                      !c.progressSyncFailed &&
                      c.trackFailure == null
                  ? const SizedBox.shrink()
                  : SafeArea(
                      child: Column(
                        children: [
                          ColoredBox(
                            color: Colors.black54,
                            child: Row(
                              children: [
                                IconButton(
                                  tooltip: l.closePlayer,
                                  onPressed: _close,
                                  icon: const Icon(Icons.arrow_back),
                                ),
                                Expanded(
                                  child: Text(
                                    c.item?.name ?? l.playerLoading,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                IconButton(
                                  tooltip: l.mobileTracks,
                                  onPressed: c.loading ? null : _tracks,
                                  icon: const Icon(Icons.tune),
                                ),
                              ],
                            ),
                          ),
                          Expanded(
                            child: Center(
                              child: c.loading
                                  ? const CircularProgressIndicator()
                                  : c.error != null ||
                                        c.sessionExpired ||
                                        c.disconnected
                                  ? SingleChildScrollView(
                                      padding: const EdgeInsets.all(24),
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            c.sessionExpired
                                                ? l.playbackSessionExpired
                                                : c.disconnected
                                                ? l.playbackDisconnected
                                                : c.error ==
                                                      PlayerErrorKind.noStream
                                                ? l.noPlayableStream
                                                : l.playbackFailed,
                                            textAlign: TextAlign.center,
                                          ),
                                          const SizedBox(height: 16),
                                          FilledButton(
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
                                    )
                                  : const SizedBox.shrink(),
                            ),
                          ),
                          ColoredBox(
                            color: Colors.black87,
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                maxHeight:
                                    MediaQuery.sizeOf(context).height * .48,
                              ),
                              child: SingleChildScrollView(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                ),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (c.progressSyncFailed)
                                      Text(l.progressSyncFailed),
                                    if (c.trackFailure != null)
                                      Text(c.trackFailure!),
                                    if (c.backgroundReleased)
                                      Text(l.mobileBackgroundPaused),
                                    if (c.playbackEnded) Text(l.playbackEnded),
                                    if (c.isBuffering && !c.loading)
                                      const LinearProgressIndicator(),
                                    Row(
                                      children: [
                                        Text(_time(c.position)),
                                        Expanded(
                                          child: Slider(
                                            key: const Key(
                                              'mobile-player-seek',
                                            ),
                                            value:
                                                (_seek ??
                                                        c
                                                            .position
                                                            .inMilliseconds
                                                            .toDouble())
                                                    .clamp(
                                                      0,
                                                      c.duration.inMilliseconds
                                                          .toDouble()
                                                          .clamp(
                                                            1,
                                                            double.infinity,
                                                          ),
                                                    ),
                                            max: c.duration.inMilliseconds
                                                .toDouble()
                                                .clamp(1, double.infinity),
                                            onChanged:
                                                c.loading ||
                                                    c.error != null ||
                                                    c.disconnected ||
                                                    c.sessionExpired
                                                ? null
                                                : (v) =>
                                                      setState(() => _seek = v),
                                            onChangeEnd: (v) {
                                              setState(() => _seek = null);
                                              c.seekTo(
                                                Duration(
                                                  milliseconds: v.round(),
                                                ),
                                              );
                                            },
                                          ),
                                        ),
                                        Text(_time(c.duration)),
                                      ],
                                    ),
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        IconButton(
                                          tooltip: l.mobileRewind,
                                          onPressed: () => c.seekRelative(
                                            const Duration(seconds: -10),
                                          ),
                                          icon: const Icon(Icons.replay_10),
                                          iconSize: 32,
                                        ),
                                        IconButton(
                                          key: const Key(
                                            'mobile-player-toggle',
                                          ),
                                          tooltip: c.isPlaying
                                              ? l.pause
                                              : l.play,
                                          onPressed:
                                              c.loading ||
                                                  c.error != null ||
                                                  c.disconnected ||
                                                  c.sessionExpired
                                              ? null
                                              : c.togglePlay,
                                          icon: Icon(
                                            c.isPlaying
                                                ? Icons.pause_circle
                                                : Icons.play_circle,
                                          ),
                                          iconSize: 48,
                                        ),
                                        IconButton(
                                          tooltip: l.mobileForward,
                                          onPressed: () => c.seekRelative(
                                            const Duration(seconds: 10),
                                          ),
                                          icon: const Icon(Icons.forward_10),
                                          iconSize: 32,
                                        ),
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
          ],
        ),
      ),
    );
  }
}
