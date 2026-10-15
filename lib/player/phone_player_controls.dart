import 'dart:async';

import 'source_switch_menu.dart';

import 'dart:math' as math;
import 'dart:ui' show DisplayFeature, DisplayFeatureType;

import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/app/widgets/option_pill.dart';
import 'package:rillight/app/widgets/reveal_selected.dart';
import 'package:flutter/services.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_motion.dart';
import 'package:rillight/app/widgets/media_source_menu_tile.dart';
import 'package:rillight/library/item_format.dart';
import 'package:rillight/player/danmaku/danmaku_controller.dart';
import 'package:rillight/player/episode_browser.dart';
import 'package:rillight/player/danmaku/danmaku_keys.dart';
import 'package:rillight/player/phone_player_gestures.dart';
import 'package:rillight/player/buffered_ranges_track.dart';
import 'package:rillight/player/network_throughput.dart';
import 'package:rillight/player/player_controller.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/phone_subtitle_settings.dart';
import 'package:rillight/player/playback_output_panel.dart';
import 'package:rillight/player/playback_output_status.dart';
import 'package:rillight/player/playback_skip_settings.dart';
import 'package:rillight/player/player_setting_choices.dart';
import 'package:rillight/player/phone/phone_player_interaction.dart';
import 'package:rillight/media_server/playback.dart';
import 'package:rillight/player/session_subtitle_files.dart';
import 'package:rillight/player/track_picker.dart';
import 'package:rillight/app/ui/app_icons.dart';

/// 轨道选项的辅助行(内嵌/外挂、编码、默认),复用桌面同款描述。
Widget? _phoneTrackMeta(BuildContext context, MediaStreamInfo track) {
  final meta = trackMetaLabel(AppLocalizations.of(context), track);
  if (meta.isEmpty) return null;
  final theme = AppUiTheme.of(context);
  return Text(
    meta,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: .68),
    ),
  );
}

/// 字幕导入/槽位限制的提示文案;无提示时返回 null。
String? _phoneSubtitleImportNotice(AppLocalizations l, PlayerController c) {
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

/// Phone controls with a title bar, a timeline, and transport sitting on the
/// timeline instead of covering the picture. Series playback gets an episode
/// list. Less frequent picture, volume and media choices stay in the panel.
///
/// The video surface and control scrims extend to the screen edges. Buttons
/// and center content avoid gesture regions and cutouts. In landscape an OEM
/// may report a top system gesture inset even with the status bar hidden;
/// the top bar only uses the actual top display cutout so its buttons reach
/// the screen edge. Below Android API 30 display cutouts are also applied to
/// the other edges from [MediaQueryData.displayFeatures].
///
/// The page-owned [PhonePlayerInteraction] governs lock and panel occupancy.
/// Playback state still comes from [PlayerController].
class PhonePlayerControls extends StatefulWidget {
  const PhonePlayerControls({
    super.key,
    required this.controller,
    required this.danmaku,
    required this.onClose,
    required this.onOpenDanmakuPanel,
    required this.onOpenDanmakuSearch,
    required this.interaction,
    this.center = const SizedBox.shrink(),
    this.fillFrame = false,
    this.onFillFrame,
    this.onPictureInPicture,
    this.pipSupported = true,
  });

  final PlayerController controller;
  final DanmakuController? danmaku;
  final VoidCallback onClose;
  final VoidCallback onOpenDanmakuPanel;
  final VoidCallback onOpenDanmakuSearch;
  final PhonePlayerInteraction interaction;

  /// Loading spinner / error retry area, owned by the page lifecycle.
  final Widget center;

  /// True when the picture is cropped to remove aspect-ratio black bars.
  final bool fillFrame;
  final ValueChanged<bool>? onFillFrame;
  final Future<void> Function()? onPictureInPicture;
  final bool pipSupported;

  @override
  State<PhonePlayerControls> createState() => PhonePlayerControlsState();
}

const MethodChannel _androidPlayerChannel = MethodChannel(
  'rillight/android_core',
);

/// Obstruction insets for the phone player controls.
///
/// [androidSdkInt] null means the device SDK is not known yet. Cutouts are
/// included in that case; on API 30+ they are already inside
/// [MediaQueryData.viewPadding], so the per-edge maximum does not add them
/// twice once the SDK is known.
EdgeInsets phonePlayerControlInsets(
  MediaQueryData media, {
  int? androidSdkInt,
}) {
  final padding = media.padding;
  final view = media.viewPadding;
  final gesture = media.systemGestureInsets;
  final cutout = _displayCutoutInsets(media.size, media.displayFeatures);
  var left = math.max(padding.left, math.max(view.left, gesture.left));
  var top = media.size.width > media.size.height
      ? cutout.top
      : math.max(padding.top, math.max(view.top, gesture.top));
  var right = math.max(padding.right, math.max(view.right, gesture.right));
  var bottom = math.max(padding.bottom, math.max(view.bottom, gesture.bottom));
  if (androidSdkInt == null || androidSdkInt < 30) {
    left = math.max(left, cutout.left);
    top = math.max(top, cutout.top);
    right = math.max(right, cutout.right);
    bottom = math.max(bottom, cutout.bottom);
  }
  return EdgeInsets.fromLTRB(left, top, right, bottom);
}

EdgeInsets _displayCutoutInsets(Size size, List<DisplayFeature> features) {
  if (size.isEmpty) return EdgeInsets.zero;
  var left = 0.0, top = 0.0, right = 0.0, bottom = 0.0;
  for (final feature in features) {
    if (feature.type != DisplayFeatureType.cutout) continue;
    final rect = feature.bounds;
    if (rect.left <= 0) left = math.max(left, rect.right);
    if (rect.top <= 0) top = math.max(top, rect.bottom);
    if (rect.right >= size.width) {
      right = math.max(right, size.width - rect.left);
    }
    if (rect.bottom >= size.height) {
      bottom = math.max(bottom, size.height - rect.top);
    }
  }
  return EdgeInsets.fromLTRB(left, top, right, bottom);
}

Future<int?> _androidSdkInt() async {
  try {
    return await _androidPlayerChannel.invokeMethod<int>(
      'androidSdkInt',
      const <String, Object>{},
    );
  } catch (_) {
    return null;
  }
}

final AppButtonStyle _phoneChromeButton = AppButtonStyle(
  minimumSize: const Size(48, 48),
);

class PhonePlayerControlsState extends State<PhonePlayerControls> {
  double? _seek;
  VoidCallback? _seekRelease;
  int? _androidSdk;

  /// Seek bar is unmounted while a sheet is open, and for the frame that
  /// sheet route leaves. Rebuilding a [PlayerSlider] in that frame leaves its
  /// semantics node parented to a render object that is no longer its ancestor.
  bool _holdSeek = false;
  bool _seekReleaseScheduled = false;

  void _syncHoldSeek() {
    if (widget.interaction.panel != null) {
      _holdSeek = true;
      return;
    }
    if (!_holdSeek || _seekReleaseScheduled) return;
    _seekReleaseScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _seekReleaseScheduled = false;
      if (!mounted || widget.interaction.panel != null) return;
      setState(() => _holdSeek = false);
    });
  }

  double _seekSlotHeight(BuildContext context) => playerSliderHeight;

  bool get locked => widget.interaction.locked;

  PlayerController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    unawaited(_loadAndroidSdk());
  }

  Future<void> _loadAndroidSdk() async {
    final sdk = await _androidSdkInt();
    if (!mounted || sdk == _androidSdk) return;
    setState(() => _androidSdk = sdk);
  }

  @override
  void didUpdateWidget(covariant PhonePlayerControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.interaction.locked ||
        !_canControl ||
        oldWidget.controller.itemId != widget.controller.itemId) {
      _seek = null;
      _releaseSeek();
    }
  }

  void _releaseSeek() {
    final release = _seekRelease;
    if (release == null) return;
    release();
    _seekRelease = null;
    if (!widget.interaction.occupied) _controller.setControlsPinned(false);
  }

  @override
  void dispose() {
    _releaseSeek();
    super.dispose();
  }

  /// Lock button tapped: hide every control and gesture except the unlock
  /// affordance. Unlocking re-shows the controls with the normal auto-hide.
  void toggleLock() {
    if (locked) {
      widget.interaction.unlock();
      _controller.onUserActivity();
    } else {
      widget.interaction.lock();
      _seek = null;
      _controller.setControlsPinned(false);
    }
  }

  bool get _canControl =>
      !_controller.loading &&
      _controller.error == null &&
      !_controller.disconnected &&
      !_controller.sessionExpired;

  @override
  Widget build(BuildContext context) {
    _syncHoldSeek();
    final media = MediaQuery.of(context);
    final insets = phonePlayerControlInsets(media, androidSdkInt: _androidSdk);
    return IconTheme(
      data: const IconThemeData(color: CupertinoColors.white),
      child: DefaultTextStyle.merge(
        style: const TextStyle(color: CupertinoColors.white),
        child: Column(
          children: [
            _buildTopBar(context, insets),
            Expanded(
              child: locked || _canControl
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: EdgeInsets.only(
                        left: insets.left,
                        right: insets.right,
                      ),
                      child: widget.center,
                    ),
            ),
            if (!locked) _buildBottomBar(context, insets),
          ],
        ),
      ),
    );
  }

  BoxDecoration _scrim(BuildContext context, {required bool top}) {
    return BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          CupertinoColors.black.withValues(
            alpha: AppScrim.of(context, top ? AppScrim.top : 0),
          ),
          CupertinoColors.black.withValues(
            alpha: AppScrim.of(
              context,
              top ? AppScrim.topBarMid : AppScrim.playerBarSoft,
            ),
          ),
          CupertinoColors.black.withValues(
            alpha: AppScrim.of(context, top ? 0 : AppScrim.playerBar),
          ),
        ],
        stops: const [0, .55, 1],
      ),
    );
  }

  /// A decorated box hit-tests its entire rectangle, including empty padding
  /// and spacers. Paint the scrim in a separate, pointer-transparent layer so
  /// dock gaps reach PhonePlayerGestures underneath without involving button
  /// taps in the surface's double-tap recognizer.
  Widget _scrimBehindControls(
    BuildContext context, {
    required Key key,
    required bool top,
    required Widget child,
  }) => Stack(
    children: [
      Positioned.fill(
        child: IgnorePointer(
          child: DecoratedBox(
            key: key,
            decoration: _scrim(context, top: top),
          ),
        ),
      ),
      child,
    ],
  );

  Widget _buildTopBar(BuildContext context, EdgeInsets insets) {
    final l = AppLocalizations.of(context);
    return _scrimBehindControls(
      context,
      key: const Key('mobile-player-top-scrim'),
      top: true,
      child: Padding(
        padding: EdgeInsets.only(
          left: insets.left,
          top: insets.top,
          right: insets.right,
          bottom: 12,
        ),
        child: Row(
          children: locked
              ? [
                  if (widget.interaction.unlockVisible)
                    Expanded(
                      child: Text(
                        l.mobileLockedHint,
                        textAlign: TextAlign.right,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    )
                  else
                    const Spacer(),
                  if (widget.interaction.unlockVisible)
                    AppIconButton(
                      key: const Key('mobile-player-unlock'),
                      tooltip: l.mobileUnlock,
                      style: _phoneChromeButton,
                      onPressed: toggleLock,
                      icon: const Icon(
                        AppIcons.lockOpen,
                        fill: AppIcons.filled,
                      ),
                    ),
                  if (!widget.interaction.unlockVisible)
                    const SizedBox(width: 48, height: 48),
                ]
              : [
                  AppIconButton(
                    key: const Key('mobile-player-close'),
                    tooltip: l.closePlayer,
                    style: _phoneChromeButton,
                    onPressed: widget.onClose,
                    icon: const Icon(AppIcons.back, fill: AppIcons.filled),
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: _title(l)),
                  if (widget.onPictureInPicture != null)
                    AppIconButton(
                      key: const Key('mobile-player-pip'),
                      tooltip: widget.pipSupported
                          ? l.phonePictureInPicture
                          : l.phonePipUnavailable,
                      style: _phoneChromeButton,
                      onPressed:
                          _canControl &&
                              widget.pipSupported &&
                              !_controller.playbackEnded
                          ? widget.onPictureInPicture
                          : null,
                      icon: const Icon(
                        AppIcons.pictureInPicture,
                        fill: AppIcons.filled,
                      ),
                    ),
                  AppIconButton(
                    key: const Key('mobile-player-lock'),
                    tooltip: l.mobileLock,
                    style: _phoneChromeButton,
                    onPressed: toggleLock,
                    icon: const Icon(AppIcons.lock, fill: AppIcons.filled),
                  ),
                ],
        ),
      ),
    );
  }

  Widget _title(AppLocalizations l) {
    final item = _controller.item;
    final rawTitle = item?.name ?? l.playerLoading;
    final series = item != null && item.isEpisode ? item.seriesName : null;
    final code = item != null && item.isEpisode
        ? seasonEpisodeCode(item)
        : null;
    final title =
        code == null || rawTitle.toLowerCase().startsWith(code.toLowerCase())
        ? rawTitle
        : '$code · $rawTitle';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (series != null && series.isNotEmpty && series != rawTitle)
          Text(
            series,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: Color(0xb3ffffff),
            ),
          ),
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }

  Widget _buildTransport(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = _controller;
    final canSeek = widget.interaction.canSeek(c);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _transportButton(
          key: const Key('mobile-player-rewind'),
          tooltip: l.mobileRewind,
          onPressed: canSeek
              ? () => c.seekRelative(const Duration(seconds: -10))
              : null,
          icon: AppIcons.replay10,
        ),
        const SizedBox(width: 8),
        _transportButton(
          key: const Key('mobile-player-toggle'),
          tooltip: c.isPlaying ? l.pause : l.play,
          onPressed: c.togglePlay,
          icon: c.isPlaying ? AppIcons.pause : AppIcons.play,
          primary: true,
        ),
        const SizedBox(width: 8),
        _transportButton(
          key: const Key('mobile-player-forward'),
          tooltip: l.mobileForward,
          onPressed: canSeek
              ? () => c.seekRelative(const Duration(seconds: 10))
              : null,
          icon: AppIcons.forward10,
        ),
      ],
    );
  }

  Widget _buildBottomBar(BuildContext context, EdgeInsets insets) {
    final l = AppLocalizations.of(context);
    final c = _controller;
    final canSeek = widget.interaction.canSeek(c);
    final durationMs = c.duration.inMilliseconds.toDouble();
    final cache = AppTooltip(
      key: const Key('mobile-player-cache-status'),
      message: l.playerNetworkSpeedTooltip,
      child: NetworkSpeedReadout(
        bytesPerSecond: c.cacheSpeedBytesPerSec,
        textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
        color: const Color(0xb3ffffff),
      ),
    );
    final clock = Text(
      '${phonePlayerClock(Duration(milliseconds: (_seek ?? c.position.inMilliseconds).round()))}  /  ${phonePlayerClock(c.duration)}',
      key: const Key('mobile-player-clock'),
      style: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        fontFeatures: [FontFeature.tabularFigures()],
      ),
    );
    final notices = [
      if (c.progressSyncFailed) l.progressSyncFailed,
      if (c.backgroundReleased) l.mobileBackgroundPaused,
      if (c.playbackEnded) l.playbackEnded,
    ];
    return _scrimBehindControls(
      context,
      key: const Key('mobile-player-bottom-scrim'),
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          insets.left + 12,
          12,
          insets.right + 12,
          insets.bottom + 4,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (c.networkSlow)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      l.networkSlowHint,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xb3ffffff),
                      ),
                    ),
                  ),
                  AppIconButton(
                    key: const Key('mobile-dismiss-network-hint'),
                    tooltip: '关闭',
                    onPressed: c.dismissNetworkSlowHint,
                    icon: const Icon(
                      AppIcons.close,
                      fill: AppIcons.filled,
                      size: 18,
                    ),
                  ),
                ],
              ),
            if (c.playbackLineFailure != null)
              Text(
                l.playbackLineFailed(c.playbackLineFailure!),
                key: const Key('playback-line-failure'),
                style: const TextStyle(fontSize: 12, color: Color(0xb3ffffff)),
              ),
            if (c.trackFailure != null)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      l.mobileTrackUnavailable,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xb3ffffff),
                      ),
                    ),
                  ),
                  AppIconButton(
                    key: const Key('mobile-dismiss-track-failure'),
                    tooltip: '关闭',
                    onPressed: c.dismissTrackFailure,
                    icon: const Icon(
                      AppIcons.close,
                      fill: AppIcons.filled,
                      size: 18,
                    ),
                  ),
                ],
              ),
            if (notices.isNotEmpty)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 40),
                child: SingleChildScrollView(
                  child: Text(
                    notices.join(' · '),
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xb3ffffff),
                    ),
                  ),
                ),
              ),
            // Buffering text and accessibility scaling can exceed a phone's
            // width. Keep every readout visible by wrapping whole groups.
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 10,
              runSpacing: 4,
              children: [
                clock,
                if (c.isBuffering && !c.loading)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox.square(
                        dimension: 12,
                        child: CupertinoActivityIndicator(),
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          l.playerBuffering,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xb3ffffff),
                          ),
                        ),
                      ),
                    ],
                  ),
                cache,
              ],
            ),
            if (_holdSeek)
              SizedBox(height: _seekSlotHeight(context))
            else
              BufferedRangesTrack(
                snapshot: c.bufferSnapshot,
                duration: c.duration,
                trackHeight: 3,
                child: PlayerSlider(
                  key: const Key('mobile-player-seek'),
                  value: (_seek ?? c.position.inMilliseconds.toDouble()).clamp(
                    0,
                    durationMs,
                  ),
                  max: durationMs.clamp(1, double.infinity),
                  label: phonePlayerClock(
                    Duration(
                      milliseconds: (_seek ?? c.position.inMilliseconds)
                          .round(),
                    ),
                  ),
                  onChangeStart: canSeek
                      ? (_) {
                          _seekRelease ??= widget.interaction.occupy();
                          c.setControlsPinned(true);
                        }
                      : null,
                  onChanged: canSeek ? (v) => setState(() => _seek = v) : null,
                  onChangeEnd: (v) {
                    setState(() => _seek = null);
                    if (widget.interaction.canSeek(c)) {
                      c.seekTo(Duration(milliseconds: v.round()));
                    }
                    _releaseSeek();
                  },
                ),
              ),
            _buildControlDock(context),
          ],
        ),
      ),
    );
  }

  /// Wide landscape keeps transport on the left and tools on the right.
  /// Narrow portrait stacks them so every target stays at least 48dp.
  Widget _buildControlDock(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 640;
    final transport = _buildTransport(context);
    final actions = _buildActionRow(context);
    if (!wide) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [transport, const SizedBox(height: 8), actions],
      );
    }
    return Row(children: [transport, const Spacer(), actions]);
  }

  Widget _buildActionRow(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = _controller;
    final buttons = <Widget>[
      if (c.canBrowseEpisodes)
        _actionButton(
          keyName: 'mobile-player-episodes',
          tooltip: l.playerEpisodes,
          icon: const Icon(AppIcons.episodes, fill: AppIcons.filled, size: 22),
          action: _openEpisodes,
        ),
      _actionButton(
        keyName: 'mobile-player-speed',
        tooltip: l.playbackRate,
        icon: Text(
          playerRateLabel(c.playbackRate),
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
        ),
        action: () => _openMore(section: 'speed'),
      ),
      if (c.canSwitchAudioTrack || c.canConfigureSubtitles)
        _actionButton(
          keyName: 'mobile-player-tracks',
          tooltip: c.canSwitchAudioTrack ? l.mobileTracks : l.subtitleTrack,
          icon: const Icon(AppIcons.subtitles, fill: AppIcons.filled, size: 22),
          action: () => _openMore(section: 'tracks'),
        ),
      if (widget.danmaku?.isConfigured == true)
        _actionButton(
          keyName: 'mobile-player-danmaku',
          tooltip: l.danmaku,
          icon: const Icon(AppIcons.danmaku, fill: AppIcons.filled, size: 22),
          action: () => _openMore(section: 'danmaku'),
        ),
      _actionButton(
        keyName: 'mobile-player-more',
        tooltip: l.mobileMore,
        icon: const Icon(AppIcons.tune, fill: AppIcons.filled, size: 22),
        action: () => _openMore(),
      ),
    ];
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var index = 0; index < buttons.length; index++) ...[
          if (index > 0) const SizedBox(width: 2),
          buttons[index],
        ],
      ],
    );
  }

  Widget _actionButton({
    required String keyName,
    required String tooltip,
    required Widget icon,
    required Future<void> Function() action,
  }) {
    return AppIconButton(
      key: Key(keyName),
      tooltip: tooltip,
      onPressed: _controller.loading ? null : () => unawaited(action()),
      icon: icon,
      style: AppButtonStyle(
        foregroundColor: CupertinoColors.white,
        minimumSize: const Size(48, 48),
        fixedSize: const Size(48, 48),
        padding: EdgeInsets.zero,
      ),
    );
  }

  Widget _transportButton({
    required Key key,
    required String tooltip,
    required VoidCallback? onPressed,
    required IconData icon,
    bool primary = false,
  }) {
    const size = 48.0;
    final scheme = AppUiTheme.of(context).colorScheme;
    return SizedBox(
      width: size,
      height: size,
      child: AppIconButton(
        key: key,
        tooltip: tooltip,
        onPressed: onPressed,
        icon: Icon(icon, fill: AppIcons.filled, size: primary ? 30 : 24),
        style: AppButtonStyle(
          foregroundColor: primary ? scheme.surface : CupertinoColors.white,
          backgroundColor: primary
              ? scheme.onSurface
              : CupertinoColors.white.withValues(alpha: .16),
          side: primary
              ? null
              : BorderSide(color: CupertinoColors.white.withValues(alpha: .28)),
          shape: const CircleBorder(),
          fixedSize: const Size(size, size),
          minimumSize: const Size(size, size),
          padding: EdgeInsets.zero,
        ),
      ),
    );
  }

  Future<void> _openEpisodes() async {
    final c = _controller;
    if (!c.canBrowseEpisodes || c.loading) return;
    final route = ModalRoute.of(context);
    final release = widget.interaction.occupy();
    widget.interaction.setPanel('episodes');
    c.setControlsPinned(true);
    unawaited(c.loadEpisodeList());
    try {
      await _showOptionsPanel(
        panelKey: const Key('mobile-player-episodes-sheet'),
        (sheetContext) => LayoutBuilder(
          builder: (context, constraints) {
            final maxHeight = constraints.maxHeight;
            final height = maxHeight.isFinite
                ? maxHeight
                : MediaQuery.sizeOf(context).height * .8;
            return SizedBox(
              height: height,
              child: ListenableBuilder(
                listenable: c,
                builder: (context, _) => PlayerEpisodeBrowser(
                  controller: c,
                  closeOnPlay: true,
                  onClose: () => Navigator.pop(sheetContext),
                ),
              ),
            );
          },
        ),
      );
    } finally {
      if (mounted && widget.interaction.panel == 'episodes') {
        widget.interaction.setPanel(null);
      }
      if (mounted) release();
      if (mounted &&
          !widget.interaction.occupied &&
          (route == null || route.isCurrent)) {
        c.setControlsPinned(false);
      }
    }
  }

  Future<void> _openMore({String? section}) async {
    final c = _controller;
    String? panelSection = section;
    String? attemptedSourceId;
    final danmaku = widget.danmaku?.isConfigured == true
        ? widget.danmaku
        : null;
    final route = ModalRoute.of(context);
    final release = widget.interaction.occupy();
    widget.interaction.setPanel(section ?? 'more');
    c.setControlsPinned(true);
    Widget panel(BuildContext sheetContext) => StatefulBuilder(
      builder: (context, panelSetState) => ListenableBuilder(
        listenable: Listenable.merge([c, danmaku]),
        builder: (context, _) {
          final section = panelSection;
          final sourceSwitchFailed =
              (attemptedSourceId != null &&
                  c.activeMediaSourceId != attemptedSourceId) ||
              c.trackFailure?.startsWith('Source change failed') == true;
          final sourceStatus = c.isRecovering && c.pendingMediaSourceId != null
              ? AppLocalizations.of(context).mobileSourceSwitching
              : sourceSwitchFailed
              ? c.error == null
                    ? AppLocalizations.of(context).mobileSourceSwitchFailed
                    : AppLocalizations.of(context).mobileSourceSwitchFailedRetry
              : c.activeMediaSourceId == null
              ? AppLocalizations.of(context).mobileSourceConfirming
              : '';
          final l = AppLocalizations.of(context);
          final theme = AppUiTheme.of(context);
          final scheme = theme.colorScheme;
          String sectionValue(String key) {
            switch (key) {
              case 'speed':
                return '${c.playbackRate}x';
              case 'tracks':
                for (final track in c.audioTracks) {
                  if (track.index == c.audioStreamIndex) return track.label;
                }
                return c.subtitleStreamIndex == null
                    ? l.subtitleOff
                    : l.subtitleTrack;
              case 'quality':
                return playerQualityLabel(l, c.maxStreamingBitrate);
              case 'picture':
                return widget.fillFrame ? l.playerFill : l.playerFit;
              case 'skip':
                final enabled = <String>[
                  if (c.skipIntroEnabled) l.settingsSkipIntro,
                  if (c.skipOutroEnabled) l.settingsSkipOutro,
                ];
                return enabled.isEmpty
                    ? l.playerSettingOff
                    : enabled.join(' · ');
              case 'danmaku':
                return danmaku?.danmakuOn == true
                    ? l.playerSettingOn
                    : l.playerSettingOff;
              case 'source':
                for (final source in c.mediaSources) {
                  if (source.id == c.activeMediaSourceId) {
                    return source.name ?? source.id;
                  }
                }
                return '';
              case 'output':
                return playbackVideoOutputLabel(l, c.outputStatus);
              default:
                return '';
            }
          }

          Widget optionTile({
            Key? key,
            required bool selected,
            bool reveal = true,
            required Widget title,
            Widget? leading,
            Widget? trailing,
            Widget? subtitle,
            VoidCallback? onTap,
          }) {
            return Padding(
              key: key == null ? null : ValueKey('option-shell-$key'),
              padding: const EdgeInsets.only(bottom: 8),
              child: RevealSelected(
                selected: selected && reveal,
                child: AppListTile(
                  key: key,
                  selected: selected,
                  leading: leading,
                  title: title,
                  subtitle: subtitle,
                  trailing: trailing,
                  onTap: onTap,
                ),
              ),
            );
          }

          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    if (section != null)
                      AppIconButton(
                        key: const Key('mobile-player-panel-back'),
                        tooltip: l.mobileBack,
                        onPressed: () {
                          panelSetState(() => panelSection = null);
                          widget.interaction.setPanel('more');
                        },
                        icon: const Icon(AppIcons.back, fill: AppIcons.filled),
                      ),
                    Expanded(
                      child: Text(
                        switch (section) {
                          'skip' => l.playerSkipSettings,
                          'speed' => l.mobileSpeed,
                          'quality' => l.quality,
                          'tracks' =>
                            c.canSwitchAudioTrack
                                ? l.mobileTracks
                                : l.subtitleTrack,
                          'danmaku' => l.danmaku,
                          'source' => l.mobileSource,
                          'picture' => l.playerPictureSettings,
                          'output' => l.playbackOutputSection,
                          _ => l.mobileMore,
                        },
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    // 长列表分区显示条目数,让用户对规模有预期。
                    if (switch (section) {
                          'source' => c.mediaSources.length,
                          'tracks' => c.selectableSubtitleTracks.length,
                          _ => 0,
                        } >
                        1)
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Text(
                          l.trackPickerCount(
                            section == 'source'
                                ? c.mediaSources.length
                                : c.selectableSubtitleTracks.length,
                          ),
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    if (section == 'danmaku' && danmaku != null)
                      CupertinoSwitch(
                        key: DanmakuKeys.toggle,
                        value: danmaku.danmakuOn,
                        onChanged: (_) => unawaited(danmaku.toggleDanmaku()),
                      ),
                    AppIconButton(
                      key: const Key('mobile-player-panel-close'),
                      tooltip: '关闭',
                      onPressed: () => Navigator.pop(sheetContext),
                      icon: const Icon(AppIcons.close, fill: AppIcons.filled),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (section == null) ...[
                          SourceSwitchButton(
                            controller: c,
                            surface: PlaybackLineSurface.sheet,
                          ),
                          for (final entry in <String, (IconData, String)>{
                            'speed': (AppIcons.speed, l.playbackRate),
                            if (c.canSwitchAudioTrack ||
                                c.canConfigureSubtitles ||
                                c.canImportSubtitleFiles)
                              'tracks': (
                                AppIcons.subtitles,
                                c.canSwitchAudioTrack
                                    ? l.mobileTracks
                                    : l.subtitleTrack,
                              ),
                            if (c.canSwitchQuality)
                              'quality': (AppIcons.quality, l.quality),
                            'picture': (
                              AppIcons.aspectRatio,
                              l.playerPictureSettings,
                            ),
                            'skip': (AppIcons.skipNext, l.playerSkipSettings),
                            'output': (
                              AppIcons.output,
                              l.playbackOutputSection,
                            ),
                            if (danmaku != null)
                              'danmaku': (AppIcons.danmaku, l.danmaku),
                          }.entries)
                            optionTile(
                              key: ValueKey(
                                'mobile-player-section-${entry.key}',
                              ),
                              selected: false,
                              leading: Icon(
                                entry.value.$1,
                                fill: AppIcons.filled,
                              ),
                              title: Text(entry.value.$2),
                              subtitle: Text(
                                sectionValue(entry.key),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: const Icon(
                                AppIcons.chevronRight,
                                fill: AppIcons.filled,
                              ),
                              onTap: () {
                                panelSetState(() => panelSection = entry.key);
                                widget.interaction.setPanel(entry.key);
                              },
                            ),
                          if (c.canSwitchMediaSource)
                            optionTile(
                              key: const Key('mobile-player-source-entry'),
                              selected: false,
                              leading: const Icon(
                                AppIcons.mediaSource,
                                fill: AppIcons.filled,
                              ),
                              title: Text(l.mobileSource),
                              subtitle: Text(
                                sectionValue('source'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: const Icon(
                                AppIcons.chevronRight,
                                fill: AppIcons.filled,
                              ),
                              onTap: () {
                                panelSetState(() => panelSection = 'source');
                                widget.interaction.setPanel('source');
                              },
                            ),
                        ],
                        if (section == 'skip')
                          PlaybackSkipSettings(controller: c),
                        if (section == 'output')
                          PlaybackOutputPanelView(controller: c),
                        if (section == 'source' && c.canSwitchMediaSource) ...[
                          SizedBox(
                            height: 40,
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                sourceStatus,
                                key: const Key('mobile-source-status'),
                              ),
                            ),
                          ),
                          // 多版本(如 20 个片源)时自动带搜索;保留逐源状态图标。
                          TrackPickerList(
                            shrinkWrap: true,
                            options: [
                              for (final source in c.mediaSources)
                                TrackPickerOption(
                                  key: ValueKey('mobile-source-${source.id}'),
                                  selected: source.id == c.activeMediaSourceId,
                                  leading: Icon(
                                    c.pendingMediaSourceId == source.id &&
                                            c.isRecovering
                                        ? AppIcons.hourglass
                                        : source.id == c.activeMediaSourceId
                                        ? AppIcons.checkCircle
                                        : AppIcons.circle,
                                    fill:
                                        (c.pendingMediaSourceId == source.id &&
                                                c.isRecovering) ||
                                            source.id == c.activeMediaSourceId
                                        ? AppIcons.filled
                                        : AppIcons.outline,
                                    key: ValueKey(
                                      'mobile-source-icon-${source.id}',
                                    ),
                                  ),
                                  title: MediaSourceMenuTile(
                                    view: source.presentation,
                                  ),
                                  searchText:
                                      '${source.name ?? ''} ${source.id} '
                                      '${source.presentation.headline} '
                                      '${source.presentation.detail ?? ''}',
                                  onTap: c.loading
                                      ? null
                                      : () async {
                                          attemptedSourceId = source.id;
                                          await c.switchMediaVersion(source.id);
                                        },
                                ),
                            ],
                            tileBuilder: (context, option) => optionTile(
                              key: option.key,
                              selected: option.selected,
                              leading: option.leading,
                              title: option.title,
                              onTap: option.onTap,
                            ),
                          ),
                        ],
                        if (section == 'picture') ...[
                          _VideoScaleChoices(
                            fill: widget.fillFrame,
                            onChanged: (fill) => widget.onFillFrame?.call(fill),
                          ),
                          const SizedBox(height: 16),
                          Text(l.mobileAppVolume),
                          Row(
                            children: [
                              AppIconButton(
                                key: const Key('mobile-player-mute'),
                                tooltip: c.volume <= 0 ? l.unmute : l.mute,
                                onPressed:
                                    c.loading ||
                                        c.error != null ||
                                        c.disconnected ||
                                        c.sessionExpired
                                    ? null
                                    : () => c.toggleMute(),
                                icon: Icon(
                                  c.volume <= 0
                                      ? AppIcons.volumeOff
                                      : AppIcons.volumeUp,
                                  fill: AppIcons.filled,
                                ),
                              ),
                              Expanded(
                                child: PlayerSlider(
                                  key: const Key('mobile-player-volume'),
                                  value: c.volume
                                      .clamp(0, PlayerSettings.volumeMax)
                                      .toDouble(),
                                  max: PlayerSettings.volumeMax.toDouble(),
                                  onChanged:
                                      c.loading ||
                                          c.error != null ||
                                          c.disconnected ||
                                          c.sessionExpired
                                      ? null
                                      : (value) => c.setVolume(value.round()),
                                ),
                              ),
                              Text(l.volumePercent(c.volume)),
                            ],
                          ),
                        ],
                        if (danmaku != null && section == 'danmaku') ...[
                          AppButton.icon(
                            key: DanmakuKeys.search,
                            style: AppButtonStyle(
                              minimumSize: const Size.fromHeight(48),
                              backgroundColor: scheme.surfaceContainerHighest,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(
                                  AppRadii.md,
                                ),
                              ),
                            ),
                            onPressed: () {
                              Navigator.pop(sheetContext);
                              widget.onOpenDanmakuSearch();
                            },
                            icon: const Icon(
                              AppIcons.search,
                              fill: AppIcons.filled,
                            ),
                            label: Text(l.danmakuSearch),
                          ),
                          const SizedBox(height: 8),
                          AppButton.icon(
                            key: DanmakuKeys.panel,
                            style: AppButtonStyle(
                              minimumSize: const Size.fromHeight(48),
                              backgroundColor: scheme.surfaceContainerHighest,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(
                                  AppRadii.md,
                                ),
                              ),
                            ),
                            onPressed: () {
                              Navigator.pop(sheetContext);
                              widget.onOpenDanmakuPanel();
                            },
                            icon: const Icon(
                              AppIcons.danmaku,
                              fill: AppIcons.filled,
                            ),
                            label: Text(l.mobileDanmakuPanel),
                          ),
                        ],
                        if (section == 'tracks') ...[
                          if (c.canAdjustSubtitleSize)
                            PhoneSubtitleSettingsControls(
                              value: c.phoneSubtitleSettings,
                              onChanged: (value) =>
                                  unawaited(c.setPhoneSubtitleSettings(value)),
                              error: c.subtitlePresentationError,
                            )
                          else if (c.canConfigureSubtitles)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 16),
                              child: Text(l.phoneSubtitleUnavailable),
                            ),
                          if (c.canSwitchAudioTrack)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Text(
                                l.audioTrack,
                                style: theme.textTheme.titleSmall,
                              ),
                            ),
                          if (c.canSwitchAudioTrack)
                            for (final track in c.selectableAudioTracks)
                              optionTile(
                                reveal: c.subtitleStreamIndex == null,
                                selected: c.audioStreamIndex == track.index,
                                leading: Icon(
                                  c.audioStreamIndex == track.index
                                      ? AppIcons.checkCircle
                                      : AppIcons.circle,
                                  fill: c.audioStreamIndex == track.index
                                      ? AppIcons.filled
                                      : AppIcons.outline,
                                ),
                                title: Text(track.label),
                                onTap: () => c.setAudio(track.index),
                              ),
                          if (c.canConfigureSubtitles ||
                              c.canImportSubtitleFiles) ...[
                            Padding(
                              padding: const EdgeInsets.only(top: 8, bottom: 8),
                              child: Text(
                                l.subtitleTrackPrimary,
                                style: theme.textTheme.titleSmall,
                              ),
                            ),
                            // 多语字幕(如 60 条)时搜索框紧跟分区标题,
                            // 辅助行标出内嵌/外挂与编码。
                            TrackPickerList(
                              shrinkWrap: true,
                              options: [
                                TrackPickerOption(
                                  selected:
                                      c.subtitleStreamIndex == null &&
                                      c.primarySubtitleFileId == null,
                                  reveal: !c.canSwitchAudioTrack,
                                  leading: Icon(
                                    c.subtitleStreamIndex == null &&
                                            c.primarySubtitleFileId == null
                                        ? AppIcons.checkCircle
                                        : AppIcons.circle,
                                    fill:
                                        c.subtitleStreamIndex == null &&
                                            c.primarySubtitleFileId == null
                                        ? AppIcons.filled
                                        : AppIcons.outline,
                                  ),
                                  title: Text(l.subtitleOff),
                                  searchText: l.subtitleOff,
                                  onTap: () => c.setSubtitle(null),
                                ),
                                for (final track in c.selectableSubtitleTracks)
                                  TrackPickerOption(
                                    selected:
                                        c.subtitleStreamIndex == track.index &&
                                        c.primarySubtitleFileId == null,
                                    reveal: false,
                                    leading: Icon(
                                      c.subtitleStreamIndex == track.index &&
                                              c.primarySubtitleFileId == null
                                          ? AppIcons.checkCircle
                                          : AppIcons.circle,
                                      fill:
                                          c.subtitleStreamIndex ==
                                                  track.index &&
                                              c.primarySubtitleFileId == null
                                          ? AppIcons.filled
                                          : AppIcons.outline,
                                    ),
                                    title: Text(track.label),
                                    subtitle: _phoneTrackMeta(context, track),
                                    trailing:
                                        c.subtitleStreamOccupiesOtherSlot(
                                          0,
                                          track.index,
                                        )
                                        ? Text(
                                            l.subtitleSlotOccupied,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            textAlign: TextAlign.end,
                                            style: theme.textTheme.labelSmall
                                                ?.copyWith(
                                                  color:
                                                      scheme.onSurfaceVariant,
                                                ),
                                          )
                                        : null,
                                    searchText:
                                        '${track.label} ${track.language ?? ''} '
                                        '${track.codec ?? ''} '
                                        '${track.displayTitle ?? ''}',
                                    onTap:
                                        c.subtitleStreamOccupiesOtherSlot(
                                          0,
                                          track.index,
                                        )
                                        ? null
                                        : () => c.setSubtitle(track.index),
                                  ),
                                for (final file in c.sessionSubtitleFiles)
                                  TrackPickerOption(
                                    key: ValueKey(
                                      'mobile-subtitle-file-${file.id}',
                                    ),
                                    selected:
                                        c.primarySubtitleFileId == file.id,
                                    reveal: false,
                                    leading: Icon(
                                      c.primarySubtitleFileId == file.id
                                          ? AppIcons.checkCircle
                                          : AppIcons.circle,
                                      fill: c.primarySubtitleFileId == file.id
                                          ? AppIcons.filled
                                          : AppIcons.outline,
                                    ),
                                    title: Text(file.label),
                                    subtitle: Text(l.subtitleMetaImported),
                                    trailing:
                                        c.subtitleFileOccupiesOtherSlot(
                                          0,
                                          file.id,
                                        )
                                        ? Text(
                                            l.subtitleSlotOccupied,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            textAlign: TextAlign.end,
                                            style: theme.textTheme.labelSmall
                                                ?.copyWith(
                                                  color:
                                                      scheme.onSurfaceVariant,
                                                ),
                                          )
                                        : null,
                                    searchText: file.label,
                                    onTap:
                                        c.subtitleFileOccupiesOtherSlot(
                                          0,
                                          file.id,
                                        )
                                        ? null
                                        : () => c.setSubtitleFromFile(file.id),
                                  ),
                              ],
                              tileBuilder: (context, option) => optionTile(
                                key: option.key,
                                selected: option.selected,
                                reveal: option.reveal,
                                leading: option.leading,
                                title: option.title,
                                subtitle: option.subtitle,
                                trailing: option.trailing,
                                onTap: option.onTap,
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.only(top: 8, bottom: 8),
                              child: Text(
                                l.subtitleTrackSecondary,
                                style: theme.textTheme.titleSmall,
                              ),
                            ),
                            TrackPickerList(
                              shrinkWrap: true,
                              searchThreshold: 12,
                              options: [
                                TrackPickerOption(
                                  selected: !c.hasSecondarySubtitle,
                                  reveal: false,
                                  leading: Icon(
                                    c.hasSecondarySubtitle
                                        ? AppIcons.circle
                                        : AppIcons.checkCircle,
                                    fill: c.hasSecondarySubtitle
                                        ? AppIcons.outline
                                        : AppIcons.filled,
                                  ),
                                  title: Text(l.subtitleOff),
                                  searchText: l.subtitleOff,
                                  onTap: () => c.setSecondarySubtitle(null),
                                ),
                                for (final track in c.selectableSubtitleTracks)
                                  if (!c.streamIsBurnedIn(track.index))
                                    TrackPickerOption(
                                      selected:
                                          c.secondarySubtitleStreamIndex ==
                                          track.index,
                                      reveal: false,
                                      leading: Icon(
                                        c.secondarySubtitleStreamIndex ==
                                                track.index
                                            ? AppIcons.checkCircle
                                            : AppIcons.circle,
                                        fill:
                                            c.secondarySubtitleStreamIndex ==
                                                track.index
                                            ? AppIcons.filled
                                            : AppIcons.outline,
                                      ),
                                      title: Text(track.label),
                                      subtitle: _phoneTrackMeta(context, track),
                                      trailing:
                                          c.subtitleStreamOccupiesOtherSlot(
                                            1,
                                            track.index,
                                          )
                                          ? Text(
                                              l.subtitleSlotOccupied,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              textAlign: TextAlign.end,
                                              style: theme.textTheme.labelSmall
                                                  ?.copyWith(
                                                    color:
                                                        scheme.onSurfaceVariant,
                                                  ),
                                            )
                                          : null,
                                      searchText:
                                          '${track.label} ${track.language ?? ''} '
                                          '${track.codec ?? ''} '
                                          '${track.displayTitle ?? ''}',
                                      onTap:
                                          c.subtitleStreamOccupiesOtherSlot(
                                            1,
                                            track.index,
                                          )
                                          ? null
                                          : () => c.setSecondarySubtitle(
                                              track.index,
                                            ),
                                    ),
                                for (final file in c.sessionSubtitleFiles)
                                  TrackPickerOption(
                                    key: ValueKey(
                                      'mobile-subtitle-secondary-${file.id}',
                                    ),
                                    selected:
                                        c.secondarySubtitleFileId == file.id,
                                    reveal: false,
                                    leading: Icon(
                                      c.secondarySubtitleFileId == file.id
                                          ? AppIcons.checkCircle
                                          : AppIcons.circle,
                                      fill: c.secondarySubtitleFileId == file.id
                                          ? AppIcons.filled
                                          : AppIcons.outline,
                                    ),
                                    title: Text(file.label),
                                    subtitle: Text(l.subtitleMetaImported),
                                    trailing:
                                        c.subtitleFileOccupiesOtherSlot(
                                          1,
                                          file.id,
                                        )
                                        ? Text(
                                            l.subtitleSlotOccupied,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            textAlign: TextAlign.end,
                                            style: theme.textTheme.labelSmall
                                                ?.copyWith(
                                                  color:
                                                      scheme.onSurfaceVariant,
                                                ),
                                          )
                                        : null,
                                    searchText: file.label,
                                    onTap:
                                        c.subtitleFileOccupiesOtherSlot(
                                          1,
                                          file.id,
                                        )
                                        ? null
                                        : () => c.setSecondarySubtitleFromFile(
                                            file.id,
                                          ),
                                  ),
                              ],
                              tileBuilder: (context, option) => optionTile(
                                key: option.key,
                                selected: option.selected,
                                reveal: option.reveal,
                                leading: option.leading,
                                title: option.title,
                                subtitle: option.subtitle,
                                trailing: option.trailing,
                                onTap: option.onTap,
                              ),
                            ),
                            if (c.canImportSubtitleFiles) ...[
                              AppButton.icon(
                                key: const Key('mobile-subtitle-import'),
                                style: AppButtonStyle(
                                  minimumSize: const Size.fromHeight(48),
                                  backgroundColor:
                                      scheme.surfaceContainerHighest,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(
                                      AppRadii.md,
                                    ),
                                  ),
                                ),
                                onPressed: () =>
                                    c.importSubtitleFile().then((_) {}),
                                icon: const Icon(
                                  AppIcons.download,
                                  fill: AppIcons.filled,
                                ),
                                label: Text(l.subtitleImportLocal),
                              ),
                              if (_phoneSubtitleImportNotice(l, c) != null)
                                Padding(
                                  key: const Key(
                                    'mobile-subtitle-import-notice',
                                  ),
                                  padding: const EdgeInsets.only(top: 8),
                                  child: Text(
                                    _phoneSubtitleImportNotice(l, c)!,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                            ],
                          ],
                          if (c.trackFailure != null)
                            Text(l.mobileTrackUnavailable),
                        ],
                        if (section == 'quality')
                          PlayerOptionGrid(
                            options: [
                              for (final bitrate in c.availableBitrates)
                                PlayerOption(
                                  key: ValueKey('mobile-quality-$bitrate'),
                                  label: playerQualityLabel(l, bitrate),
                                  selected: c.maxStreamingBitrate == bitrate,
                                  onPressed: c.loading
                                      ? null
                                      : () =>
                                            unawaited(c.setMaxBitrate(bitrate)),
                                ),
                            ],
                          ),
                        if (section == 'speed')
                          PlayerRateGrid(
                            selected: c.playbackRate,
                            enabled: !c.loading,
                            onSelected: (rate) => unawaited(c.setRate(rate)),
                          ),
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: AppButton.icon(
                            onPressed: section != null
                                ? () {
                                    panelSetState(() => panelSection = null);
                                    widget.interaction.setPanel('more');
                                  }
                                : () => Navigator.pop(sheetContext),
                            icon: Icon(
                              section != null ? AppIcons.back : AppIcons.close,
                              fill: AppIcons.filled,
                            ),
                            label: Text(l.mobileBack),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
    try {
      await _showOptionsPanel(panel);
    } finally {
      if (mounted && widget.interaction.panel == (panelSection ?? 'more')) {
        widget.interaction.setPanel(null);
      }
      if (mounted) release();
      if (mounted &&
          !widget.interaction.occupied &&
          (route == null || route.isCurrent)) {
        _controller.setControlsPinned(false);
      }
    }
  }

  Future<void> _showOptionsPanel(
    WidgetBuilder builder, {
    Key panelKey = const Key('mobile-player-options'),
  }) {
    final media = MediaQuery.of(context);
    if (media.size.width <= media.size.height) {
      return PhoneMotion.showBottomPanel<void>(
        context: context,
        useSafeArea: true,
        isScrollControlled: true,
        showDragHandle: true,

        builder: (context) => SafeArea(
          top: false,
          child: ConstrainedBox(
            key: panelKey,
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * .8,
            ),
            child: builder(context),
          ),
        ),
      );
    }
    final playerTheme = AppUiTheme.of(context);
    final themes = InheritedTheme.capture(
      from: context,
      to: Navigator.of(context).context,
    );
    return showGeneralDialog<void>(
      context: context,
      useRootNavigator: false,
      barrierDismissible: true,
      barrierLabel: '关闭',
      barrierColor: const Color(0x8a000000),
      transitionDuration: AppMotion.durationOf(context),
      pageBuilder: (context, animation, secondaryAnimation) => themes.wrap(
        AppUiTheme(
          data: playerTheme,
          child: Builder(
            builder: (context) => SafeArea(
              child: Align(
                alignment: Alignment.centerRight,
                child: SizedBox(
                  width: math.min(360, MediaQuery.sizeOf(context).width * .65),
                  height: double.infinity,
                  child: Container(
                    key: panelKey,
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      color: AppUiTheme.of(context).colorScheme.surface,
                      borderRadius: const BorderRadius.horizontal(
                        left: Radius.circular(20),
                      ),
                    ),
                    child: builder(context),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      transitionBuilder: (context, animation, secondaryAnimation, child) =>
          SlideTransition(
            position: Tween(begin: const Offset(1, 0), end: Offset.zero)
                .animate(
                  CurvedAnimation(
                    parent: animation,
                    curve: AppMotion.emphasized,
                    reverseCurve: AppMotion.exit,
                  ),
                ),
            child: child,
          ),
    );
  }
}

class _VideoScaleChoices extends StatefulWidget {
  const _VideoScaleChoices({required this.fill, required this.onChanged});

  final bool fill;
  final ValueChanged<bool> onChanged;

  @override
  State<_VideoScaleChoices> createState() => _VideoScaleChoicesState();
}

class _VideoScaleChoicesState extends State<_VideoScaleChoices> {
  late bool _fill = widget.fill;

  @override
  void didUpdateWidget(covariant _VideoScaleChoices oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.fill != widget.fill) _fill = widget.fill;
  }

  void _select(bool fill) {
    setState(() => _fill = fill);
    widget.onChanged(fill);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        OptionPill(
          key: const Key('mobile-player-scale-fit'),
          label: l.playerFit,
          selected: !_fill,
          onPressed: () => _select(false),
        ),
        OptionPill(
          key: const Key('mobile-player-scale-fill'),
          label: l.playerFill,
          selected: _fill,
          onPressed: () => _select(true),
        ),
      ],
    );
  }
}
