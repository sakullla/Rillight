import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show DisplayFeature, DisplayFeatureType;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_motion.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/player/danmaku/danmaku_controller.dart';
import 'package:rillight/player/danmaku/danmaku_keys.dart';
import 'package:rillight/player/phone_player_gestures.dart';
import 'package:rillight/player/buffered_ranges_track.dart';
import 'package:rillight/player/network_throughput.dart';
import 'package:rillight/player/player_controller.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/playback_skip_settings.dart';
import 'package:rillight/player/player_setting_choices.dart';
import 'package:rillight/player/phone/phone_player_interaction.dart';

/// Phone controls with a title bar, central transport and a full-width timeline.
/// Common options have direct bottom shortcuts; the full settings panel keeps
/// the less frequent picture, volume and media choices together.
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

final ButtonStyle _phoneChromeButton = IconButton.styleFrom(
  visualDensity: VisualDensity.standard,
  minimumSize: const Size(48, 48),
  tapTargetSize: MaterialTapTargetSize.padded,
);

class PhonePlayerControlsState extends State<PhonePlayerControls> {
  double? _seek;
  VoidCallback? _seekRelease;
  int? _androidSdk;

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
    final media = MediaQuery.of(context);
    final insets = phonePlayerControlInsets(media, androidSdkInt: _androidSdk);
    final landscape = media.size.width > media.size.height;
    return IconTheme(
      data: const IconThemeData(color: Colors.white),
      child: DefaultTextStyle.merge(
        style: const TextStyle(color: Colors.white),
        child: Column(
          children: [
            _buildTopBar(context, insets),
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(
                  left: insets.left,
                  right: insets.right,
                ),
                child: locked
                    ? const SizedBox.shrink()
                    : _canControl
                    ? Center(child: _buildTransport(context, landscape))
                    : widget.center,
              ),
            ),
            if (!locked) _buildBottomBar(context, insets, landscape),
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
          Colors.black.withValues(
            alpha: AppScrim.of(context, top ? AppScrim.top : 0),
          ),
          Colors.black.withValues(
            alpha: AppScrim.of(
              context,
              top ? AppScrim.topBarMid : AppScrim.playerBarSoft,
            ),
          ),
          Colors.black.withValues(
            alpha: AppScrim.of(context, top ? 0 : AppScrim.playerBar),
          ),
        ],
        stops: const [0, .55, 1],
      ),
    );
  }

  Widget _buildTopBar(BuildContext context, EdgeInsets insets) {
    final l = AppLocalizations.of(context);
    return DecoratedBox(
      key: const Key('mobile-player-top-scrim'),
      decoration: _scrim(context, top: true),
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
                    IconButton(
                      key: const Key('mobile-player-unlock'),
                      tooltip: l.mobileUnlock,
                      style: _phoneChromeButton,
                      onPressed: toggleLock,
                      icon: const Icon(Icons.lock),
                    ),
                  if (!widget.interaction.unlockVisible)
                    const SizedBox(width: 48, height: 48),
                ]
              : [
                  IconButton(
                    tooltip: l.closePlayer,
                    style: _phoneChromeButton,
                    onPressed: widget.onClose,
                    icon: const Icon(Icons.arrow_back),
                  ),
                  const SizedBox(width: 4),
                  Expanded(child: _title(l)),
                  IconButton(
                    key: const Key('mobile-player-lock'),
                    tooltip: l.mobileLock,
                    style: _phoneChromeButton,
                    onPressed: toggleLock,
                    icon: const Icon(Icons.lock_open),
                  ),
                ],
        ),
      ),
    );
  }

  Widget _title(AppLocalizations l) {
    final item = _controller.item;
    final title = item?.name ?? l.playerLoading;
    final series = item != null && item.isEpisode ? item.seriesName : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (series != null && series.isNotEmpty && series != title)
          Text(
            series,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: Colors.white70,
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

  Widget _buildTransport(BuildContext context, bool landscape) {
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
          icon: Icons.replay_10,
        ),
        SizedBox(width: landscape ? 40 : 28),
        _transportButton(
          key: const Key('mobile-player-toggle'),
          tooltip: c.isPlaying ? l.pause : l.play,
          onPressed: c.togglePlay,
          icon: c.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
          primary: true,
        ),
        SizedBox(width: landscape ? 40 : 28),
        _transportButton(
          key: const Key('mobile-player-forward'),
          tooltip: l.mobileForward,
          onPressed: canSeek
              ? () => c.seekRelative(const Duration(seconds: 10))
              : null,
          icon: Icons.forward_10,
        ),
      ],
    );
  }

  Widget _buildBottomBar(
    BuildContext context,
    EdgeInsets insets,
    bool landscape,
  ) {
    final l = AppLocalizations.of(context);
    final c = _controller;
    final canSeek = widget.interaction.canSeek(c);
    final durationMs = c.duration.inMilliseconds.toDouble();
    final cache = Tooltip(
      key: const Key('mobile-player-cache-status'),
      message: l.playerNetworkSpeedTooltip,
      child: NetworkSpeedReadout(
        bytesPerSecond: c.cacheSpeedBytesPerSec,
        textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
        color: Colors.white70,
      ),
    );
    final clock = Text(
      '${phonePlayerClock(Duration(milliseconds: (_seek ?? c.position.inMilliseconds).round()))} / ${phonePlayerClock(c.duration)}',
      key: const Key('mobile-player-clock'),
      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
    );
    final notices = [
      if (c.progressSyncFailed) l.progressSyncFailed,
      if (c.trackFailure != null) l.mobileTrackUnavailable,
      if (c.backgroundReleased) l.mobileBackgroundPaused,
      if (c.playbackEnded) l.playbackEnded,
    ];
    return DecoratedBox(
      key: const Key('mobile-player-bottom-scrim'),
      decoration: _scrim(context, top: false),
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
                        color: Colors.white70,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const Key('mobile-dismiss-network-hint'),
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).closeButtonTooltip,
                    onPressed: c.dismissNetworkSlowHint,
                    icon: const Icon(Icons.close, size: 18),
                  ),
                ],
              ),
            if (notices.isNotEmpty)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 40),
                child: SingleChildScrollView(
                  child: Text(
                    notices.join(' · '),
                    style: const TextStyle(fontSize: 12, color: Colors.white70),
                  ),
                ),
              ),
            if (c.isBuffering && !c.loading)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox.square(
                      dimension: 12,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      l.playerBuffering,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.white70,
                      ),
                    ),
                  ],
                ),
              ),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                showValueIndicator: ShowValueIndicator.onDrag,
                valueIndicatorColor: Colors.white,
                valueIndicatorTextStyle: const TextStyle(
                  color: Colors.black,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              child: BufferedRangesTrack(
                snapshot: c.bufferSnapshot,
                duration: c.duration,
                trackHeight: 6,
                child: Slider(
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
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  clock,
                  const SizedBox(width: 12),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: FittedBox(fit: BoxFit.scaleDown, child: cache),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _shortcut(
                          'mobile-player-speed',
                          Icons.speed,
                          '${c.playbackRate}x',
                          () => _openMore(section: 'speed'),
                        ),
                        if (c.canSwitchQuality)
                          _shortcut(
                            'mobile-player-quality',
                            Icons.high_quality_outlined,
                            playerQualityLabel(l, c.maxStreamingBitrate),
                            () => _openMore(section: 'quality'),
                          ),
                        _shortcut(
                          'mobile-player-tracks',
                          Icons.subtitles_outlined,
                          c.canSwitchAudioTrack
                              ? l.mobileTracks
                              : l.subtitleTrack,
                          () => _openMore(section: 'tracks'),
                        ),
                        if (widget.danmaku?.isConfigured == true)
                          _shortcut(
                            'mobile-player-danmaku',
                            Icons.forum_outlined,
                            l.danmaku,
                            () => _openMore(section: 'danmaku'),
                          ),
                      ],
                    ),
                  ),
                ),
                _shortcut(
                  'mobile-player-more',
                  Icons.tune,
                  l.mobileMore,
                  () => _openMore(),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _shortcut(
    String key,
    IconData icon,
    String label,
    Future<void> Function() action,
  ) {
    return Padding(
      key: ValueKey('shortcut-shell-$key'),
      padding: const EdgeInsets.only(right: 8),
      child: TextButton.icon(
        key: Key(key),
        style: TextButton.styleFrom(
          foregroundColor: Colors.white,
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          backgroundColor: Colors.white.withValues(alpha: .14),
          side: BorderSide(color: Colors.white.withValues(alpha: .22)),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.lg),
          ),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        onPressed: _controller.loading ? null : () => unawaited(action()),
        icon: Icon(icon, size: 20),
        label: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13),
        ),
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
    final size = primary ? 76.0 : 54.0;
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: size,
      height: size,
      child: IconButton(
        key: key,
        tooltip: tooltip,
        onPressed: onPressed,
        icon: Icon(icon, size: primary ? 40 : 28),
        style: IconButton.styleFrom(
          foregroundColor: primary ? scheme.surface : Colors.white,
          backgroundColor: primary
              ? scheme.onSurface
              : Colors.white.withValues(alpha: .16),
          side: primary
              ? null
              : BorderSide(color: Colors.white.withValues(alpha: .28)),
          shape: const CircleBorder(),
          fixedSize: Size(size, size),
          minimumSize: const Size(48, 48),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.standard,
          padding: EdgeInsets.zero,
        ),
      ),
    );
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
          final theme = Theme.of(context);
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
              default:
                return '';
            }
          }

          Widget optionTile({
            Key? key,
            required bool selected,
            required Widget title,
            Widget? leading,
            Widget? trailing,
            Widget? subtitle,
            VoidCallback? onTap,
          }) {
            return Padding(
              key: key == null ? null : ValueKey('option-shell-$key'),
              padding: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                key: key,
                selected: selected,
                selectedTileColor: scheme.surfaceBright,
                selectedColor: scheme.onSurface,
                iconColor: scheme.onSurfaceVariant,
                textColor: scheme.onSurface,
                tileColor: scheme.surfaceContainerHighest,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadii.md),
                ),
                minTileHeight: 56,
                leading: leading,
                title: title,
                subtitle: subtitle,
                trailing: trailing,
                onTap: onTap,
              ),
            );
          }

          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    if (section != null)
                      IconButton(
                        key: const Key('mobile-player-panel-back'),
                        tooltip: l.mobileBack,
                        onPressed: () {
                          panelSetState(() => panelSection = null);
                          widget.interaction.setPanel('more');
                        },
                        icon: const Icon(Icons.arrow_back_rounded),
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
                          _ => l.mobileMore,
                        },
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (section == 'danmaku' && danmaku != null)
                      Switch(
                        key: DanmakuKeys.toggle,
                        value: danmaku.danmakuOn,
                        onChanged: (_) => unawaited(danmaku.toggleDanmaku()),
                      ),
                    IconButton(
                      key: const Key('mobile-player-panel-close'),
                      tooltip: MaterialLocalizations.of(
                        context,
                      ).closeButtonTooltip,
                      onPressed: () => Navigator.pop(sheetContext),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (section == null) ...[
                  for (final entry in <String, (IconData, String)>{
                    'speed': (Icons.speed, l.playbackRate),
                    'tracks': (
                      Icons.subtitles_outlined,
                      c.canSwitchAudioTrack ? l.mobileTracks : l.subtitleTrack,
                    ),
                    if (c.canSwitchQuality)
                      'quality': (Icons.high_quality_outlined, l.quality),
                    'picture': (Icons.aspect_ratio, l.playerPictureSettings),
                    'skip': (Icons.fast_forward_rounded, l.playerSkipSettings),
                    if (danmaku != null)
                      'danmaku': (Icons.chat_bubble_outline, l.danmaku),
                  }.entries)
                    optionTile(
                      key: ValueKey('mobile-player-section-${entry.key}'),
                      selected: false,
                      leading: Icon(entry.value.$1),
                      title: Text(entry.value.$2),
                      subtitle: Text(
                        sectionValue(entry.key),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () {
                        panelSetState(() => panelSection = entry.key);
                        widget.interaction.setPanel(entry.key);
                      },
                    ),
                  if (c.canSwitchMediaSource)
                    optionTile(
                      key: const Key('mobile-player-source-entry'),
                      selected: false,
                      leading: const Icon(Icons.video_library_outlined),
                      title: Text(l.mobileSource),
                      subtitle: Text(
                        sectionValue('source'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () {
                        panelSetState(() => panelSection = 'source');
                        widget.interaction.setPanel('source');
                      },
                    ),
                ],
                if (section == 'skip') PlaybackSkipSettings(controller: c),
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
                  for (final source in c.mediaSources)
                    optionTile(
                      key: ValueKey('mobile-source-${source.id}'),
                      selected: source.id == c.activeMediaSourceId,
                      leading: Icon(
                        c.pendingMediaSourceId == source.id && c.isRecovering
                            ? Icons.hourglass_top
                            : source.id == c.activeMediaSourceId
                            ? Icons.check_circle
                            : Icons.radio_button_unchecked,
                        key: ValueKey('mobile-source-icon-${source.id}'),
                      ),
                      title: Text(source.name ?? source.id),
                      onTap: c.loading
                          ? null
                          : () {
                              attemptedSourceId = source.id;
                              unawaited(c.switchMediaSource(source.id));
                            },
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
                      IconButton(
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
                          c.volume <= 0 ? Icons.volume_off : Icons.volume_up,
                        ),
                      ),
                      Expanded(
                        child: Slider(
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
                  TextButton.icon(
                    key: DanmakuKeys.search,
                    style: TextButton.styleFrom(
                      alignment: Alignment.centerLeft,
                      minimumSize: const Size.fromHeight(48),
                      backgroundColor: scheme.surfaceContainerHighest,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadii.md),
                      ),
                    ),
                    onPressed: () {
                      Navigator.pop(sheetContext);
                      widget.onOpenDanmakuSearch();
                    },
                    icon: const Icon(Icons.search),
                    label: Text(l.danmakuSearch),
                  ),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    key: DanmakuKeys.panel,
                    style: TextButton.styleFrom(
                      alignment: Alignment.centerLeft,
                      minimumSize: const Size.fromHeight(48),
                      backgroundColor: scheme.surfaceContainerHighest,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadii.md),
                      ),
                    ),
                    onPressed: () {
                      Navigator.pop(sheetContext);
                      widget.onOpenDanmakuPanel();
                    },
                    icon: const Icon(Icons.tune),
                    label: Text(l.mobileDanmakuPanel),
                  ),
                ],
                if (section == 'tracks') ...[
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
                        selected: c.audioStreamIndex == track.index,
                        leading: Icon(
                          c.audioStreamIndex == track.index
                              ? Icons.check_circle
                              : Icons.radio_button_unchecked,
                        ),
                        title: Text(track.label),
                        onTap: () => c.setAudio(track.index),
                      ),
                  ...[
                    Padding(
                      padding: const EdgeInsets.only(top: 8, bottom: 8),
                      child: Text(
                        l.subtitleTrack,
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                    optionTile(
                      selected: c.subtitleStreamIndex == null,
                      leading: Icon(
                        c.subtitleStreamIndex == null
                            ? Icons.check_circle
                            : Icons.radio_button_unchecked,
                      ),
                      title: Text(l.subtitleOff),
                      onTap: () => c.setSubtitle(null),
                    ),
                    for (final track in c.selectableSubtitleTracks)
                      optionTile(
                        selected: c.subtitleStreamIndex == track.index,
                        leading: Icon(
                          c.subtitleStreamIndex == track.index
                              ? Icons.check_circle
                              : Icons.radio_button_unchecked,
                        ),
                        title: Text(track.label),
                        onTap: () => c.setSubtitle(track.index),
                      ),
                  ],
                  if (c.trackFailure != null) Text(l.mobileTrackUnavailable),
                ],
                if (section == 'quality')
                  ChipTheme(
                    data: playerChoiceChipTheme(theme),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final bitrate in c.availableBitrates)
                          ChoiceChip(
                            key: ValueKey('mobile-quality-$bitrate'),
                            label: Text(playerQualityLabel(l, bitrate)),
                            selected: c.maxStreamingBitrate == bitrate,
                            showCheckmark: false,
                            onSelected: c.loading
                                ? null
                                : (_) => unawaited(c.setMaxBitrate(bitrate)),
                          ),
                      ],
                    ),
                  ),
                if (section == 'speed')
                  ChipTheme(
                    data: playerChoiceChipTheme(theme),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final rate in kPlaybackRateLadder)
                          ChoiceChip(
                            label: Text('${rate}x'),
                            selected: c.playbackRate == rate,
                            showCheckmark: false,
                            onSelected: c.loading
                                ? null
                                : (_) => c.setRate(rate),
                          ),
                      ],
                    ),
                  ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: section != null
                        ? () {
                            panelSetState(() => panelSection = null);
                            widget.interaction.setPanel('more');
                          }
                        : () => Navigator.pop(sheetContext),
                    icon: Icon(
                      section != null
                          ? Icons.arrow_back_rounded
                          : Icons.close_rounded,
                    ),
                    label: Text(l.mobileBack),
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

  Future<void> _showOptionsPanel(WidgetBuilder builder) {
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
            key: const Key('mobile-player-options'),
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * .8,
            ),
            child: builder(context),
          ),
        ),
      );
    }
    final themes = InheritedTheme.capture(
      from: context,
      to: Navigator.of(context, rootNavigator: true).context,
    );
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: Colors.black54,
      transitionDuration: AppMotion.durationOf(context),
      pageBuilder: (context, animation, secondaryAnimation) => themes.wrap(
        Builder(
          builder: (context) => SafeArea(
            child: Align(
              alignment: Alignment.centerRight,
              child: SizedBox(
                width: math.min(360, MediaQuery.sizeOf(context).width * .65),
                height: double.infinity,
                child: Material(
                  key: const Key('mobile-player-options'),
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: const BorderRadius.horizontal(
                    left: Radius.circular(20),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: builder(context),
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
    final theme = Theme.of(context);
    return ChipTheme(
      data: playerChoiceChipTheme(theme),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          ChoiceChip(
            key: const Key('mobile-player-scale-fit'),
            label: Text(l.playerFit),
            selected: !_fill,
            showCheckmark: false,
            onSelected: (_) => _select(false),
          ),
          ChoiceChip(
            key: const Key('mobile-player-scale-fill'),
            label: Text(l.playerFill),
            selected: _fill,
            showCheckmark: false,
            onSelected: (_) => _select(true),
          ),
        ],
      ),
    );
  }
}
