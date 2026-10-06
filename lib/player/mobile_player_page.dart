import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/player/playback_ended_panel.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_motion.dart';
import 'package:rillight/app/widgets/liquid_glass.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/player/rillight_video_backend.dart';
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
import 'player_window_host.dart';
import 'package:rillight/player/next_episode_card.dart';
import 'package:rillight/player/player_window.dart';
import 'package:rillight/player/video_backend.dart';
import 'package:rillight/player/phone/phone_player_interaction.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

class MobilePlayerPage extends StatefulWidget {
  const MobilePlayerPage({
    super.key,
    required this.itemId,
    this.mediaSourceId,
    this.sourceRequest,
    this.routeLeaseKey,
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
  final PlayerOpenRequest? sourceRequest;
  final Object? routeLeaseKey;
  final String? mediaSourceId;
  final bool autoResume;

  /// 详情页选出的音轨/字幕。只作用于本次起播。
  final int? audioStreamIndex;
  final int? subtitleStreamIndex;

  /// Replaceable landscape request. Null uses [SystemChrome] and restores
  /// portrait after playback.
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
  /// Null uses the owned Android core's platform channel.
  final PhoneDisplayControl? displayControl;
  @override
  State<MobilePlayerPage> createState() => MobilePlayerPageState();
}

/// Keeps the phone display on while playback is running.
///
/// The phone page owns this lease separately from the desktop player page.
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

  static const MethodChannel _channel = MethodChannel('rillight/android_core');

  /// Hides or shows Android system bars through the owned core plugin.
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
  final PhonePlayerInteraction _interaction = PhonePlayerInteraction();
  Object? _visualSignature;
  bool _fillFrame = false;
  VideoBackendPhonePresentation? _presentation;
  bool _pip = false;
  bool _pipSupported = false;
  bool _viewportScheduled = false;
  void _onPresentation() {
    if (!mounted || _closing) return;
    final state = _presentation?.phonePresentation.value ?? const {};
    final supported = state['supported'] == true;
    if (_pipSupported != supported) setState(() => _pipSupported = supported);
    final pip =
        state['active'] == true ||
        state['entering'] == true ||
        state['returning'] == true;
    if (_pip != pip) {
      _pip = pip;
      if (pip) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        final route = ModalRoute.of(context);
        Navigator.of(
          context,
        ).popUntil((candidate) => identical(candidate, route));
        controller?.setControlsPinned(false);
      } else if (state['foreground'] == true) {
        unawaited(_bars?.reassert());
        unawaited(_orientation?.reassert());
      }
      setState(() {});
    }
    _scheduleSubtitleViewport();
  }

  void _scheduleSubtitleViewport() {
    if (_viewportScheduled || !mounted) return;
    _viewportScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _viewportScheduled = false;
      if (!mounted || _closing) return;
      final media = MediaQuery.of(context);
      final raw = _presentation?.phonePresentation.value['geometry'];
      if (raw is! Map) return; // Never invent decoded dimensions/SAR.
      final density =
          (raw['density'] as num?)?.toDouble() ?? media.devicePixelRatio;
      final width = (raw['width'] as num?)?.toDouble();
      final height = (raw['height'] as num?)?.toDouble();
      if (width == null || height == null || density <= 0) return;
      final landscape = media.size.width > media.size.height;
      final base = landscape ? 24.0 : 20.0;
      unawaited(
        controller?.updateSubtitleViewport(
          width: width / density,
          height: height / density,
          landscape: landscape,
          textScale: media.textScaler.scale(base) / base,
          safeHorizontal:
              12 + ((raw['safeHorizontal'] as num?)?.toDouble() ?? 0) / density,
          safeVertical:
              8 + ((raw['safeVertical'] as num?)?.toDouble() ?? 0) / density,
        ),
      );
    });
  }

  Future<void> _configurePhone(bool enabled) async {
    try {
      await _presentation?.configurePhonePresentation(enabled);
    } catch (_) {
      // Native teardown and controller close must still run if the bridge left.
    }
  }

  Future<void> _enterPip() async {
    var accepted = false;
    try {
      accepted = await _presentation?.enterPictureInPicture() ?? false;
    } catch (_) {}
    if (!accepted && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).phonePipFailed)),
      );
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _interaction.addListener(_onInteraction);
  }

  void _onInteraction() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_closing && !_pip) {
      unawaited(_bars?.reassert());
      unawaited(_orientation?.reassert());
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
    _orientation = widget.orientation ?? PhoneOrientation();
    _bars = widget.systemBars ?? PhoneSystemBars();
    _wake = widget.wakeLock ?? PhonePlaybackWakeLock();
    _display = widget.displayControl ?? MethodChannelPhoneDisplayControl();
    final created = PlayerController(
      runtime: widget.sourceRequest?.source == null ? null : bindings.runtime,
      openRequest: widget.sourceRequest,
      routeLeaseKey: widget.routeLeaseKey,
      client: auth.client,
      itemId: widget.itemId,
      backend: bindings.createBackend?.call() ?? RillightVideoBackend(),
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
    if (created.backend is VideoBackendPhonePresentation) {
      _presentation = created.backend as VideoBackendPhonePresentation;
      _presentation!.phonePresentation.addListener(_onPresentation);
      unawaited(_configurePhone(true).then((_) => _onPresentation()));
    }
    _lifecycle = AndroidPlaybackLifecycle(
      created,
      phonePresentation: _presentation,
    );
    unawaited(_bars!.hide());
    unawaited(_orientation!.enterPlayback());
    unawaited(created.start());
  }

  bool _revocationExitScheduled = false;

  void _onPlayback() {
    final current = controller;
    if (current?.permissionRevoked == true) {
      if (!_revocationExitScheduled) {
        _revocationExitScheduled = true;
        // The active origin can differ from the detail route that opened it.
        // Revocation must clear playback/history using that actual controller,
        // not wait for the original detail gate's unrelated source lease.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) GoRouter.of(context).go('/', extra: null);
        });
      }
      _danmaku?.removeListener(_onDanmaku);
      _danmaku?.dispose();
      _danmaku = null;
      _danmakuLayerPinned = false;
      _danmakuLayerItemId = null;
    }
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
    _refreshVisuals();
  }

  void _onDanmaku() {
    final danmaku = _danmaku;
    final current = controller;
    if (danmaku != null &&
        danmaku.isConfigured &&
        danmaku.danmakuOn &&
        danmaku.hasComments &&
        current != null &&
        !current.loading &&
        current.error == null &&
        !current.playbackEnded) {
      _danmakuLayerPinned = true;
      _danmakuLayerItemId = current.itemId;
    }
    _refreshVisuals();
  }

  void _refreshVisuals() {
    final current = controller;
    if (current == null) return;
    final danmaku = _danmaku;
    final next = (
      current.itemId,
      current.loading,
      current.error,
      current.disconnected,
      current.sessionExpired,
      current.playbackEnded,
      current.nextEpisode?.item.id,
      current.nextEpisode?.remaining,
      danmaku?.isConfigured,
      danmaku == null ? false : _showDanmakuLayer(current),
      danmaku == null ? false : _danmakuNeedsAttention(danmaku),
    );
    if (_visualSignature == next) return;
    _visualSignature = next;
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
    final current = controller;
    if (current?.runtime != null && current?.origin != null) {
      if (!current!.origin!.permit.isValid) unawaited(_close());
      return;
    }
    if (_identity !=
        (auth.client.baseUrl, auth.client.userId, auth.client.accessToken)) {
      unawaited(_close());
    }
  }

  Future<void> _close({String? viewSeriesId, String? seasonId}) async {
    if (_closing) return;
    _closing = true;
    final command = controller?.endedSeriesCommand;
    final lease = controller?.origin?.permit;
    final sourceBound =
        controller?.origin != null || widget.sourceRequest?.source != null;
    final router = viewSeriesId == null ? null : GoRouter.maybeOf(context);
    await _configurePhone(false);
    if (!mounted) return;
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
    if (router != null &&
        viewSeriesId != null &&
        (!sourceBound || (command != null && lease?.isValid == true))) {
      router.push(
        AppRoutes.item(viewSeriesId, seasonId: seasonId),
        extra: command,
      );
    }
  }

  Future<void> _openDanmakuPanel() async {
    final danmaku = _danmaku;
    final current = controller;
    if (danmaku == null ||
        !danmaku.isConfigured ||
        current == null ||
        _closing ||
        _interaction.locked) {
      return;
    }
    await danmaku.refreshFromStore();
    if (!mounted || _closing) return;
    final release = _interaction.occupy();
    _interaction.setPanel('danmaku');
    current.setControlsPinned(true);
    var openSearch = false;
    try {
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
      if (mounted && !_closing && openSearch) await _openDanmakuSearch();
    } finally {
      if (mounted) {
        if (_interaction.panel == 'danmaku') _interaction.setPanel(null);
        release();
      }
      if (mounted && !_closing && !_interaction.occupied) {
        current.setControlsPinned(false);
      }
    }
  }

  Future<void> _openDanmakuSearch() async {
    final danmaku = _danmaku;
    final current = controller;
    if (danmaku == null ||
        current == null ||
        !danmaku.isConfigured ||
        _interaction.locked) {
      return;
    }
    final release = _interaction.occupy();
    _interaction.setPanel('danmakuSearch');
    current.setControlsPinned(true);
    final keyword = _searchKeyword(danmaku, current);
    try {
      await showModalBottomSheet<void>(
        context: context,
        useSafeArea: true,
        isScrollControlled: true,
        builder: (context) =>
            _PhoneDanmakuSearch(danmaku: danmaku, initialKeyword: keyword),
      );
    } finally {
      if (mounted) {
        if (_interaction.panel == 'danmakuSearch') {
          _interaction.setPanel(null);
        }
        release();
      }
      if (mounted && !_closing && !_interaction.occupied) {
        current.setControlsPinned(false);
      }
    }
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
    if (danmaku == null || current == null || _interaction.locked) return;
    final episode = _danmakuContext(current);
    if (episode == null) return;
    await danmaku.startSession(episode);
  }

  bool _showDanmakuLayer(PlayerController current) {
    final danmaku = _danmaku;
    if (danmaku == null ||
        !danmaku.isConfigured ||
        !danmaku.danmakuOn ||
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
    _presentation?.phonePresentation.removeListener(_onPresentation);
    unawaited(_configurePhone(false));
    final orientation = _orientation;
    final bars = _bars;
    final wake = _wake;
    if (bars != null) unawaited(bars.restore());
    if (orientation != null) unawaited(orientation.leavePlayback());
    if (wake != null) unawaited(wake.hold(false));
    _danmaku?.dispose();
    _interaction.removeListener(_onInteraction);
    _interaction.dispose();
    final c = controller;
    if (c != null) {
      unawaited(c.disposeAsync(notifyStopped: false));
      c.dispose();
    }
    super.dispose();
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
    if (c.permissionRevoked) {
      // No revoked source controls or semantics survive the cleanup frame.
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Text(AppLocalizations.of(context).aggregationPrivateLocked),
        ),
      );
    }
    final danmaku = _danmaku;
    final ended =
        c.playbackEnded &&
        c.nextEpisode == null &&
        !c.loading &&
        c.error == null &&
        !c.sessionExpired &&
        !c.disconnected &&
        !_interaction.locked;
    _scheduleSubtitleViewport();
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (popped, _) {
        if (popped) return;
        if (_interaction.locked) {
          _interaction.revealUnlock();
        } else {
          _close();
        }
      },
      child: LiquidGlassBackdrop(
        enabled: false,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            fit: StackFit.expand,
            children: [
              c.backend.buildView(),
              if (!_pip) ...[
                if (danmaku != null && _showDanmakuLayer(c))
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DanmakuView(controller: danmaku),
                    ),
                  ),
                if (!ended)
                  PhonePlayerGestures(
                    controller: c,
                    display: _display!,
                    interaction: _interaction,
                  ),
                if (!ended)
                  ListenableBuilder(
                    listenable: Listenable.merge([c, _interaction]),
                    builder: (context, _) {
                      return PhoneMotion.reveal(
                        context: context,
                        visible: _interaction.controlsVisibleFor(c),
                        child: PhonePlayerControls(
                          controller: c,
                          danmaku: danmaku,
                          onClose: _close,
                          pipSupported: _pipSupported,
                          onPictureInPicture: _presentation == null
                              ? null
                              : _enterPip,
                          onOpenDanmakuPanel: _openDanmakuPanel,
                          onOpenDanmakuSearch: _openDanmakuSearch,
                          center: _centerStatus(c),
                          interaction: _interaction,
                          fillFrame: _fillFrame,
                          onFillFrame: (fill) {
                            if (_fillFrame == fill) return;
                            setState(() => _fillFrame = fill);
                            final backend = c.backend;
                            if (backend is RillightVideoBackend) {
                              unawaited(
                                backend.setVideoScale(fill ? 'fill' : 'fit'),
                              );
                            }
                          },
                        ),
                      );
                    },
                  ),
                if (!_interaction.locked &&
                    c.nextEpisode != null &&
                    c.error == null &&
                    !c.sessionExpired)
                  Positioned(
                    left: 12,
                    right: 12,
                    top: 64,
                    child: NextEpisodeCard(controller: c),
                  ),
                if (!ended &&
                    !_interaction.locked &&
                    danmaku != null &&
                    danmaku.isConfigured &&
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
                if (ended)
                  Positioned.fill(
                    child: PlaybackEndedPanel(
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
                    ),
                  ),
              ],
            ],
          ),
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
  int _searchGeneration = 0;

  @override
  void dispose() {
    _searchGeneration++;
    _field.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final term = _field.text.trim();
    if (term.isEmpty) return;
    final generation = ++_searchGeneration;
    setState(() {
      _loading = true;
      _searched = true;
    });
    final results = await widget.danmaku.search(term);
    if (!mounted || generation != _searchGeneration) return;
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
                onPressed: _loading ? null : () => unawaited(_run()),
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
                  : widget.danmaku.searchFailure != null
                  ? DanmakuSearchError(onRetry: () => unawaited(_run()))
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
