import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_motion.dart';
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
import 'package:rillight/player/phone_player_controls.dart';
import 'package:rillight/player/phone_player_gestures.dart';
import 'package:rillight/player/playback_models.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_controller.dart';
import 'package:rillight/player/player_keys.dart';
import 'package:rillight/player/player_window.dart';
import 'package:rillight_android_player/rillight_android_player.dart';
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
    this.systemBars,
    this.wakeLock,
    this.danmakuHasher,
    this.displayControl,
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

  /// Replaceable status and navigation bar hide. Null uses
  /// [PhoneSystemBars.platformRequest].
  final PhoneSystemBars? systemBars;

  /// Replaceable screen wake. Null uses wakelock_plus directly.
  final PhonePlaybackWakeLock? wakeLock;

  /// Optional hash reader. Null uses the danmaku default, which never blocks
  /// playback when the stream head cannot be read.
  final DanmakuStreamHasher? danmakuHasher;

  /// Optional system brightness / volume access for the gesture layer.
  /// Null uses the MethodChannel backed by `RillightAndroidPlayerPlugin`.
  final PhoneDisplayControl? displayControl;
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

/// Hides status and navigation bars while the phone player is on screen.
///
/// [request] is replaceable so tests can observe hide and restore without
/// changing the host. The default is [platformRequest]. A failed request is
/// swallowed. Leaving the page, or returning to it after the system shows
/// the bars, is applied in order.
class PhoneSystemBars {
  PhoneSystemBars({Future<void> Function(bool hidden)? request})
    : _request = request ?? platformRequest;

  static const MethodChannel _channel = MethodChannel(
    'rillight/android_player',
  );

  /// Hides or shows Android system bars through `RillightAndroidPlayerPlugin`.
  ///
  /// The plugin uses `WindowInsetsControllerCompat` with
  /// `BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE`. [SystemChrome.setEnabledSystemUIMode]
  /// is not used: Flutter ignores it when the app targets Android SDK 16.
  static Future<void> platformRequest(bool hidden) {
    return _channel.invokeMethod<void>('setSystemBarsHidden', <String, Object>{
      'hidden': hidden,
    });
  }

  final Future<void> Function(bool hidden) _request;
  final List<bool> calls = [];
  bool _hidden = false;
  bool _applied = false;
  Future<void> _queue = Future<void>.value();

  Future<void> get settled => _queue;

  Future<void> hide() => _enqueue(true, force: false);

  Future<void> restore() => _enqueue(false, force: false);

  /// Sends the current mode again after a transient system-bar restore.
  Future<void> reassert() => _enqueue(_hidden, force: true);

  Future<void> _enqueue(bool hidden, {required bool force}) {
    final changed = !_applied || _hidden != hidden;
    _hidden = hidden;
    if (!force && !changed) return _queue;
    _queue = _queue.then((_) async {
      if (_hidden != hidden) return;
      _applied = true;
      calls.add(hidden);
      try {
        await _request(hidden).timeout(const Duration(milliseconds: 300));
      } catch (_) {
        // System UI must not block playback or route teardown.
      }
    });
    return _queue;
  }
}

class MobilePlayerPageState extends State<MobilePlayerPage>
    with WidgetsBindingObserver {
  PlayerController? controller;
  AndroidPlaybackLifecycle? _lifecycle;
  AuthController? _auth;
  Object? _identity;
  bool _closing = false;
  PhoneOrientation? _orientation;
  PhoneSystemBars? _bars;
  PhonePlaybackWakeLock? _wake;
  DanmakuController? _danmaku;
  bool _danmakuLayerPinned = false;
  String? _danmakuLayerItemId;
  PhoneDisplayControl? _display;
  bool _controlsLocked = false;
  bool _fillFrame = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_closing) {
      unawaited(_bars?.reassert());
    }
  }

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
    _bars = widget.systemBars ?? PhoneSystemBars();
    _wake = widget.wakeLock ?? PhonePlaybackWakeLock();
    _display = widget.displayControl ?? MethodChannelPhoneDisplayControl();
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
      // 手机控制层自动隐藏 4s(T6);桌面/TV 仍用 bindings 档。
      controlsHideAfter: const Duration(seconds: 4),
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
    unawaited(_bars!.hide());
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
    await _bars?.restore();
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
    WidgetsBinding.instance.removeObserver(this);
    _auth?.removeListener(_authChanged);
    controller?.removeListener(_onPlayback);
    _danmaku?.removeListener(_onDanmaku);
    _lifecycle?.dispose();
    final orientation = _orientation;
    final bars = _bars;
    final wake = _wake;
    if (bars != null) unawaited(bars.restore());
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

  void _onLockChanged(bool locked) {
    setState(() => _controlsLocked = locked);
  }

  void _unlock() {
    setState(() => _controlsLocked = false);
    controller?.onUserActivity();
  }

  Widget _centerStatus(PlayerController c) {
    final l = AppLocalizations.of(context);
    return Center(
      child: c.loading
          ? const CircularProgressIndicator()
          : c.error != null || c.sessionExpired || c.disconnected
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
                        : c.error == PlayerErrorKind.noStream
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
                    child: Text(c.sessionExpired ? l.connect : l.retry),
                  ),
                ],
              ),
            )
          : const SizedBox.shrink(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = controller!;
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
          body: AndroidVideoScaleScope(
            scale: _fillFrame ? AndroidVideoScale.fill : AndroidVideoScale.fit,
            child: Stack(
              fit: StackFit.expand,
              children: [
                c.backend.buildView(),
                if (danmaku != null && _showDanmakuLayer(c))
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DanmakuView(controller: danmaku),
                    ),
                  ),
                PhonePlayerGestures(
                  controller: c,
                  display: _display!,
                  locked: _controlsLocked,
                  onUnlock: _unlock,
                ),
                ListenableBuilder(
                  listenable: c,
                  builder: (context, _) {
                    final showControls =
                        c.controlsVisible ||
                        c.loading ||
                        c.error != null ||
                        c.disconnected ||
                        c.sessionExpired ||
                        c.progressSyncFailed ||
                        c.trackFailure != null;
                    return PhoneMotion.reveal(
                      context: context,
                      visible: showControls || _controlsLocked,
                      child: PhonePlayerControls(
                        controller: c,
                        danmaku: danmaku,
                        onClose: _close,
                        onOpenDanmakuPanel: _openDanmakuPanel,
                        onOpenDanmakuSearch: _openDanmakuSearch,
                        center: _centerStatus(c),
                        locked: _controlsLocked,
                        onLockChanged: _onLockChanged,
                        fillFrame: _fillFrame,
                        onFillFrame: (fill) {
                          if (_fillFrame == fill) return;
                          setState(() => _fillFrame = fill);
                        },
                      ),
                    );
                  },
                ),
                if (c.nextEpisode != null &&
                    c.error == null &&
                    !c.sessionExpired)
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
