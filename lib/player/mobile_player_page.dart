import 'dart:async';
import 'package:flutter/material.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/widgets/liquid_glass.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/player/android_video_backend.dart';
import 'package:rillight/player/android_playback_lifecycle.dart';
import 'package:rillight/player/danmaku/danmaku_controller.dart';
import 'package:rillight/player/danmaku/danmaku_hash.dart';
import 'package:rillight/player/danmaku/danmaku_keys.dart';
import 'package:rillight/player/danmaku/danmaku_match_query.dart';
import 'package:rillight/player/danmaku/danmaku_panel.dart';
import 'package:rillight/player/danmaku/danmaku_renderer.dart';
import 'package:rillight/player/danmaku/dandanplay_models.dart';
import 'package:rillight/player/phone_orientation.dart';
import 'package:rillight/player/playback_models.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_controller.dart';
import 'package:rillight/player/player_keys.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/player_window.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

class MobilePlayerPage extends StatefulWidget {
  const MobilePlayerPage({
    super.key,
    required this.itemId,
    this.mediaSourceId,
    this.autoResume = true,
    this.audioStreamIndex,
    this.subtitleStreamIndex,
    this.orientation,
    this.wakeLock,
    this.danmakuHasher,
  });
  final String itemId;
  final String? mediaSourceId;
  final bool autoResume;

  /// 详情页选出的音轨/字幕。只作用于本次起播。
  final int? audioStreamIndex;
  final int? subtitleStreamIndex;

  /// Replaceable landscape request. Null uses [SystemChrome] and the viewport
  /// direction captured on entry.
  final PhoneOrientation? orientation;

  /// Replaceable screen wake. Null uses wakelock_plus directly.
  final PhonePlaybackWakeLock? wakeLock;

  /// Optional hash reader. Null uses the danmaku default, which never blocks
  /// playback when the stream head cannot be read.
  final DanmakuStreamHasher? danmakuHasher;
  @override
  State<MobilePlayerPage> createState() => MobilePlayerPageState();
}

/// Keeps the phone display on while playback is running.
///
/// Not [PlaybackWakeLock]: that lease is for the desktop libmpv process.
/// Pause, close, and background each release the hold. A platform failure
/// does not surface on the player.
class PhonePlaybackWakeLock {
  PhonePlaybackWakeLock({Future<void> Function(bool enabled)? toggle})
    : _toggle = toggle ?? _platform;

  static Future<void> _platform(bool enabled) {
    return WakelockPlus.toggle(enable: enabled);
  }

  final Future<void> Function(bool enabled) _toggle;
  bool _desired = false;
  Future<void> _queue = Future<void>.value();

  bool get held => _desired;
  Future<void> get settled => _queue;

  Future<void> hold(bool enabled) {
    if (_desired == enabled) return _queue;
    _desired = enabled;
    final target = enabled;
    _queue = _queue.then((_) async {
      if (_desired != target) return;
      try {
        await _toggle(target).timeout(const Duration(milliseconds: 300));
      } catch (_) {
        // Brightness lock must not block playback or route teardown.
      }
    });
    return _queue;
  }
}

class MobilePlayerPageState extends State<MobilePlayerPage> {
  PlayerController? controller;
  AndroidPlaybackLifecycle? _lifecycle;
  AuthController? _auth;
  Object? _identity;
  bool _closing = false;
  double? _seek;
  PhoneOrientation? _orientation;
  PhonePlaybackWakeLock? _wake;
  DanmakuController? _danmaku;
  bool _danmakuLayerPinned = false;
  String? _danmakuLayerItemId;

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
    _orientation =
        widget.orientation ??
        PhoneOrientation(
          restoreTo: phoneOrientationsFor(MediaQuery.orientationOf(context)),
        );
    _wake = widget.wakeLock ?? PhonePlaybackWakeLock();
    final created = PlayerController(
      client: auth.client,
      itemId: widget.itemId,
      backend: bindings.createBackend?.call() ?? AndroidVideoBackend(),
      window: bindings.window ?? PlayerWindow(),
      autoResume: widget.autoResume,
      preferredMediaSourceId: widget.mediaSourceId,
      preferredAudioStreamIndex: widget.audioStreamIndex,
      preferredSubtitleStreamIndex: widget.subtitleStreamIndex,
      progressInterval: bindings.progressInterval,
      controlsHideAfter: bindings.controlsHideAfter,
      nextEpisodeCountdown: bindings.nextEpisodeCountdown,
      settingsStore: bindings.settingsStore,
      snapshotStore: bindings.snapshotStore,
    );
    controller = created;
    created.addListener(_onPlayback);
    final danmaku = DanmakuController(
      settingsStore: bindings.settingsStore,
      client: bindings.danmakuClient,
      hasher: widget.danmakuHasher,
    );
    _danmaku = danmaku;
    danmaku.addListener(_onDanmaku);
    _lifecycle = AndroidPlaybackLifecycle(created);
    unawaited(_orientation!.enterPlayback());
    unawaited(created.start());
  }

  void _onPlayback() {
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
    final playing =
        current != null && current.isPlaying && !current.backgroundReleased;
    unawaited(_wake?.hold(playing));
    if (mounted) setState(() {});
  }

  void _onDanmaku() {
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
    if (mounted) setState(() {});
  }

  DanmakuEpisodeContext? _danmakuContext(PlayerController current) {
    final item = current.item;
    final resolved = current.resolved;
    if (item == null || resolved == null) return null;
    final path = resolved.mediaSource.path;
    return DanmakuEpisodeContext(
      itemId: current.itemId,
      mediaSourceId: resolved.mediaSource.id,
      seriesId: item.seriesId,
      seriesTitle: item.seriesName,
      title: item.name,
      fileName: danmakuMatchFileName(
        pathBaseName: _baseName(path),
        seriesTitle: item.seriesName,
        title: item.name,
        seasonIndex: item.parentIndexNumber,
        episodeIndex: item.indexNumber,
        height: resolved.mediaSource.height,
        productionYear: item.productionYear,
      ),
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
    if (value.isEmpty) return '';
    final normalized = value.replaceAll('\\', '/');
    final slash = normalized.lastIndexOf('/');
    return slash < 0 ? normalized : normalized.substring(slash + 1);
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
    await _orientation?.leavePlayback();
    await _wake?.hold(false);
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

  Future<void> _openDanmakuPanel() async {
    final danmaku = _danmaku;
    final current = controller;
    if (danmaku == null || current == null || _closing) return;
    await danmaku.refreshFromStore();
    if (!mounted || _closing) return;
    current.setControlsPinned(true);
    var openSearch = false;
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (sheetContext) {
        final height = MediaQuery.sizeOf(sheetContext).height * .75;
        return SizedBox(
          height: height,
          child: DanmakuPanel(
            embedded: true,
            topChromeExtent: 0,
            danmaku: danmaku,
            onClose: () => Navigator.pop(sheetContext),
            onSearch: () {
              openSearch = true;
              Navigator.pop(sheetContext);
            },
          ),
        );
      },
    );
    if (!mounted || _closing) return;
    if (openSearch) await _openDanmakuSearch();
    if (mounted && !_closing) current.setControlsPinned(false);
  }

  Future<void> _openDanmakuSearch() async {
    final danmaku = _danmaku;
    final current = controller;
    if (danmaku == null || current == null || !danmaku.isConfigured) return;
    current.setControlsPinned(true);
    final keyword = _searchKeyword(danmaku, current);
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) =>
          _PhoneDanmakuSearch(danmaku: danmaku, initialKeyword: keyword),
    );
    if (mounted && !_closing) current.setControlsPinned(false);
  }

  String _searchKeyword(DanmakuController danmaku, PlayerController current) {
    final matched = danmaku.matchedTitle?.trim();
    if (matched != null && matched.isNotEmpty) return matched;
    final series = current.item?.seriesName?.trim();
    if (series != null && series.isNotEmpty) return series;
    return current.item?.name ?? '';
  }

  Future<void> _retryDanmaku() async {
    final danmaku = _danmaku;
    final current = controller;
    if (danmaku == null || current == null) return;
    final episode = _danmakuContext(current);
    if (episode == null) return;
    await danmaku.startSession(episode);
  }

  bool _showDanmakuLayer(PlayerController current) {
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

  bool _danmakuNeedsAttention(DanmakuController danmaku) {
    if (!danmaku.danmakuOn) return false;
    switch (danmaku.status) {
      case DanmakuStatus.customUnreachable:
      case DanmakuStatus.noMatch:
        return true;
      case DanmakuStatus.unreachable:
        return danmaku.hasOfficialCredentials;
      case DanmakuStatus.off:
      case DanmakuStatus.idle:
      case DanmakuStatus.loading:
      case DanmakuStatus.active:
        return false;
    }
  }

  @override
  void dispose() {
    _auth?.removeListener(_authChanged);
    controller?.removeListener(_onPlayback);
    _danmaku?.removeListener(_onDanmaku);
    _lifecycle?.dispose();
    final orientation = _orientation;
    final wake = _wake;
    if (orientation != null) unawaited(orientation.leavePlayback());
    if (wake != null) unawaited(wake.hold(false));
    _danmaku?.dispose();
    final c = controller;
    if (c != null) {
      unawaited(c.disposeAsync());
      c.dispose();
    }
    super.dispose();
  }

  String _clock(Duration value) {
    final hours = value.inHours;
    final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = (value.inSeconds % 60).toString().padLeft(2, '0');
    if (hours > 0) return '$hours:$minutes:$seconds';
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final c = controller!, l = AppLocalizations.of(context);
    final danmaku = _danmaku;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (popped, _) {
        if (!popped) _close();
      },
      child: LiquidGlassBackdrop(
        enabled: false,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            fit: StackFit.expand,
            children: [
              c.backend.buildView(),
              if (danmaku != null && _showDanmakuLayer(c))
                Positioned.fill(
                  child: IgnorePointer(child: DanmakuView(controller: danmaku)),
                ),
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
                                    key: const Key('mobile-player-danmaku'),
                                    tooltip: l.danmaku,
                                    onPressed: c.loading
                                        ? null
                                        : _openDanmakuPanel,
                                    icon: Icon(
                                      danmaku != null && danmaku.danmakuOn
                                          ? Icons.subtitles
                                          : Icons.subtitles_outlined,
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
                                      if (c.playbackEnded)
                                        Text(l.playbackEnded),
                                      if (c.isBuffering && !c.loading)
                                        const LinearProgressIndicator(),
                                      Row(
                                        children: [
                                          Text(_clock(c.position)),
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
                                                        c
                                                            .duration
                                                            .inMilliseconds
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
                                                  : (v) => setState(
                                                      () => _seek = v,
                                                    ),
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
                                          Text(_clock(c.duration)),
                                        ],
                                      ),
                                      Row(
                                        children: [
                                          IconButton(
                                            key: const Key(
                                              'mobile-player-mute',
                                            ),
                                            tooltip: c.volume <= 0
                                                ? l.unmute
                                                : l.mute,
                                            onPressed:
                                                c.loading ||
                                                    c.error != null ||
                                                    c.disconnected ||
                                                    c.sessionExpired
                                                ? null
                                                : () => c.toggleMute(),
                                            icon: Icon(
                                              c.volume <= 0
                                                  ? Icons.volume_off
                                                  : Icons.volume_up,
                                            ),
                                          ),
                                          Expanded(
                                            child: Slider(
                                              key: const Key(
                                                'mobile-player-volume',
                                              ),
                                              value: c.volume
                                                  .clamp(
                                                    0,
                                                    PlayerSettings.volumeMax,
                                                  )
                                                  .toDouble(),
                                              max: PlayerSettings.volumeMax
                                                  .toDouble(),
                                              onChanged:
                                                  c.loading ||
                                                      c.error != null ||
                                                      c.disconnected ||
                                                      c.sessionExpired
                                                  ? null
                                                  : (value) => c.setVolume(
                                                      value.round(),
                                                    ),
                                            ),
                                          ),
                                          Text(l.volumePercent(c.volume)),
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
              if (c.nextEpisode != null && c.error == null && !c.sessionExpired)
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: 12,
                  child: SafeArea(child: _PhoneNextEpisode(controller: c)),
                ),
              if (danmaku != null &&
                  c.error == null &&
                  !c.loading &&
                  _danmakuNeedsAttention(danmaku))
                Positioned(
                  top: c.nextEpisode != null ? 148 : 8,
                  left: 12,
                  right: 12,
                  child: SafeArea(
                    child: _PhoneDanmakuFailure(
                      danmaku: danmaku,
                      onRetry: _retryDanmaku,
                      onDisable: () => unawaited(danmaku.toggleDanmaku()),
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

class _PhoneNextEpisode extends StatelessWidget {
  const _PhoneNextEpisode({required this.controller});

  final PlayerController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final offer = controller.nextEpisode!;
    final seconds = offer.remaining?.inSeconds;
    return Material(
      key: PlayerKeys.nextEpisode,
      color: Colors.black.withValues(alpha: 0.88),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.skip_next, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    seconds == null
                        ? l10n.playNextEpisode
                        : l10n.nextEpisodeIn(seconds),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  key: PlayerKeys.nextEpisodeCancel,
                  tooltip: l10n.cancelNextEpisode,
                  onPressed: controller.cancelNextEpisode,
                  icon: const Icon(Icons.close, size: 18),
                ),
              ],
            ),
            Text(
              offer.item.displayName,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                key: PlayerKeys.nextEpisodePlay,
                onPressed: controller.playNextEpisode,
                icon: const Icon(Icons.play_arrow),
                label: Text(l10n.playNextEpisode),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PhoneDanmakuFailure extends StatelessWidget {
  const _PhoneDanmakuFailure({
    required this.danmaku,
    required this.onRetry,
    required this.onDisable,
  });

  final DanmakuController danmaku;
  final VoidCallback onRetry;
  final VoidCallback onDisable;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Material(
      key: const Key('mobile-danmaku-failure'),
      color: Colors.black.withValues(alpha: 0.88),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(danmakuStatusText(l10n, danmaku)),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  key: const Key('mobile-danmaku-off'),
                  onPressed: onDisable,
                  child: Text(l10n.danmaku),
                ),
                TextButton(
                  key: const Key('mobile-danmaku-retry'),
                  onPressed: onRetry,
                  child: Text(l10n.retry),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PhoneDanmakuSearch extends StatefulWidget {
  const _PhoneDanmakuSearch({
    required this.danmaku,
    required this.initialKeyword,
  });

  final DanmakuController danmaku;
  final String initialKeyword;

  @override
  State<_PhoneDanmakuSearch> createState() => _PhoneDanmakuSearchState();
}

class _PhoneDanmakuSearchState extends State<_PhoneDanmakuSearch> {
  late final TextEditingController _field = TextEditingController(
    text: widget.initialKeyword,
  );
  List<DanmakuAnime> _results = const [];
  bool _loading = false;
  bool _searched = false;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    setState(() {
      _loading = true;
      _searched = true;
    });
    final results = await widget.danmaku.search(_field.text);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _results = results;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final height = MediaQuery.sizeOf(context).height * .75;
    return SizedBox(
      height: height,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l10n.danmakuSearchTitle),
            const SizedBox(height: 8),
            TextField(
              key: DanmakuKeys.searchField,
              controller: _field,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(hintText: l10n.danmakuSearchHint),
              onSubmitted: (_) => unawaited(_run()),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: IconButton(
                key: DanmakuKeys.searchSubmit,
                tooltip: l10n.danmakuSearch,
                onPressed: () => unawaited(_run()),
                icon: const Icon(Icons.arrow_forward),
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(
                      child: CircularProgressIndicator(
                        key: DanmakuKeys.searchLoading,
                      ),
                    )
                  : !_searched
                  ? Center(child: Text(l10n.danmakuSearchHint))
                  : _results.isEmpty
                  ? Center(child: Text(l10n.danmakuNoMatch))
                  : ListView(
                      children: [
                        for (final anime in _results)
                          ExpansionTile(
                            key: DanmakuKeys.searchAnime(anime.animeId),
                            title: Text(anime.animeTitle),
                            initiallyExpanded: _results.length == 1,
                            children: [
                              for (final episode in anime.episodes)
                                ListTile(
                                  key: DanmakuKeys.searchEpisode(
                                    episode.episodeId,
                                  ),
                                  title: Text(episode.episodeTitle),
                                  onTap: () {
                                    unawaited(
                                      widget.danmaku.selectEpisode(
                                        anime,
                                        episode,
                                      ),
                                    );
                                    Navigator.pop(context);
                                  },
                                ),
                            ],
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
