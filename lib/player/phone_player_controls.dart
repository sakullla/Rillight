import 'dart:async';

import 'package:flutter/material.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_motion.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/player/danmaku/danmaku_controller.dart';
import 'package:rillight/player/danmaku/danmaku_keys.dart';
import 'package:rillight/player/phone_player_gestures.dart';
import 'package:rillight/player/player_controller.dart';
import 'package:rillight/player/player_settings.dart';

/// Control layer of the phone player: top bar (back / title / lock / more),
/// a bottom-edge transport (play, progress, time) and the "more" panel that
/// hosts picture scale, danmaku, tracks, speed, media source, mute and volume.
/// Transport hit targets stay at least 48dp with an 8dp gap.
///
/// The lock state is a state-machine field of this layer; the page mirrors
/// it through [onLockChanged] to disable the gesture layer. `PlayerController`
/// is not touched.
class PhonePlayerControls extends StatefulWidget {
  const PhonePlayerControls({
    super.key,
    required this.controller,
    required this.danmaku,
    required this.onClose,
    required this.onOpenDanmakuPanel,
    required this.onOpenDanmakuSearch,
    this.center = const SizedBox.shrink(),
    this.locked = false,
    this.onLockChanged,
    this.fillFrame = false,
    this.onFillFrame,
  });

  final PlayerController controller;
  final DanmakuController? danmaku;
  final VoidCallback onClose;
  final VoidCallback onOpenDanmakuPanel;
  final VoidCallback onOpenDanmakuSearch;

  /// Loading spinner / error retry area, owned by the page lifecycle.
  final Widget center;

  final bool locked;
  final ValueChanged<bool>? onLockChanged;

  /// True when the picture is cropped to remove aspect-ratio black bars.
  final bool fillFrame;
  final ValueChanged<bool>? onFillFrame;

  @override
  State<PhonePlayerControls> createState() => PhonePlayerControlsState();
}

final ButtonStyle _phoneChromeButton = IconButton.styleFrom(
  visualDensity: VisualDensity.standard,
  minimumSize: const Size(48, 48),
  tapTargetSize: MaterialTapTargetSize.padded,
);

class PhonePlayerControlsState extends State<PhonePlayerControls> {
  double? _seek;
  late bool _locked = widget.locked;

  bool get locked => _locked;

  PlayerController get _controller => widget.controller;

  @override
  void didUpdateWidget(covariant PhonePlayerControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 手势层单击解锁经页面回写,同步本层状态机。
    if (oldWidget.locked != widget.locked && _locked != widget.locked) {
      setState(() => _locked = widget.locked);
    }
  }

  /// Lock button tapped: hide every control and gesture except the unlock
  /// affordance. Unlocking re-shows the controls with the normal auto-hide.
  void toggleLock() {
    setState(() => _locked = !_locked);
    widget.onLockChanged?.call(_locked);
    if (!_locked) _controller.onUserActivity();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          _buildTopBar(context),
          Expanded(child: widget.center),
          if (!_locked) _buildBottomBar(context),
        ],
      ),
    );
  }

  Widget _buildTopBar(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = _controller;
    if (_locked) {
      // Locked: only the unlock affordance stays on screen.
      return DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.black.withValues(
                alpha: AppScrim.of(context, AppMobileControls.topAlpha),
              ),
              Colors.black.withValues(
                alpha: AppScrim.of(context, AppMobileControls.topMidAlpha),
              ),
              Colors.black.withValues(alpha: AppScrim.of(context, 0)),
            ],
            stops: const [0, 0.55, 1],
          ),
        ),
        child: Row(
          children: [
            IconButton(
              key: const Key('mobile-player-unlock'),
              tooltip: l.mobileUnlock,
              style: _phoneChromeButton,
              onPressed: toggleLock,
              icon: const Icon(Icons.lock),
            ),
          ],
        ),
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withValues(
              alpha: AppScrim.of(context, AppMobileControls.topAlpha),
            ),
            Colors.black.withValues(
              alpha: AppScrim.of(context, AppMobileControls.topMidAlpha),
            ),
            Colors.black.withValues(alpha: AppScrim.of(context, 0)),
          ],
          stops: const [0, 0.55, 1],
        ),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: l.closePlayer,
            style: _phoneChromeButton,
            onPressed: widget.onClose,
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
            key: const Key('mobile-player-lock'),
            tooltip: l.mobileLock,
            style: _phoneChromeButton,
            onPressed: toggleLock,
            icon: const Icon(Icons.lock_open),
          ),
          IconButton(
            key: const Key('mobile-player-more'),
            tooltip: l.mobileTracks,
            style: _phoneChromeButton,
            onPressed: c.loading ? null : () => unawaited(_openMore()),
            icon: const Icon(Icons.more_vert),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomBar(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = _controller;
    final durationMs = c.duration.inMilliseconds.toDouble();
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withValues(alpha: AppScrim.of(context, 0)),
            Colors.black.withValues(
              alpha: AppScrim.of(context, AppMobileControls.bottomSoftAlpha),
            ),
            Colors.black.withValues(
              alpha: AppScrim.of(context, AppMobileControls.bottomAlpha),
            ),
          ],
          stops: const [0, 0.55, 1],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 8, 0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (c.progressSyncFailed) Text(l.progressSyncFailed),
            if (c.trackFailure != null) Text(l.mobileTrackUnavailable),
            if (c.backgroundReleased) Text(l.mobileBackgroundPaused),
            if (c.playbackEnded) Text(l.playbackEnded),
            if (c.isBuffering && !c.loading) const LinearProgressIndicator(),
            Row(
              children: [
                _transportButton(
                  key: const Key('mobile-player-rewind'),
                  tooltip: l.mobileRewind,
                  onPressed: () => c.seekRelative(const Duration(seconds: -10)),
                  icon: Icons.replay_10,
                ),
                const SizedBox(width: 8),
                _transportButton(
                  key: const Key('mobile-player-toggle'),
                  tooltip: c.isPlaying ? l.pause : l.play,
                  onPressed:
                      c.loading ||
                          c.error != null ||
                          c.disconnected ||
                          c.sessionExpired
                      ? null
                      : c.togglePlay,
                  icon: c.isPlaying ? Icons.pause_circle : Icons.play_circle,
                ),
                const SizedBox(width: 8),
                _transportButton(
                  key: const Key('mobile-player-forward'),
                  tooltip: l.mobileForward,
                  onPressed: () => c.seekRelative(const Duration(seconds: 10)),
                  icon: Icons.forward_10,
                ),
                Text(phonePlayerClock(c.position)),
                Expanded(
                  child: Slider(
                    key: const Key('mobile-player-seek'),
                    value: (_seek ?? c.position.inMilliseconds.toDouble())
                        .clamp(0, durationMs),
                    max: durationMs.clamp(1, double.infinity),
                    onChanged:
                        c.loading ||
                            c.error != null ||
                            c.disconnected ||
                            c.sessionExpired
                        ? null
                        : (v) => setState(() => _seek = v),
                    onChangeEnd: (v) {
                      setState(() => _seek = null);
                      c.seekTo(Duration(milliseconds: v.round()));
                    },
                  ),
                ),
                Text(phonePlayerClock(c.duration)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _transportButton({
    required Key key,
    required String tooltip,
    required VoidCallback? onPressed,
    required IconData icon,
  }) {
    return SizedBox(
      key: key,
      width: 48,
      height: 48,
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        icon: Icon(icon),
        style: IconButton.styleFrom(
          fixedSize: const Size(48, 48),
          minimumSize: const Size(48, 48),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.standard,
          padding: EdgeInsets.zero,
        ),
      ),
    );
  }

  Future<void> _openMore() async {
    final c = _controller;
    final danmaku = widget.danmaku;
    final route = ModalRoute.of(context);
    c.setControlsPinned(true);
    await PhoneMotion.showBottomPanel<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (sheetContext) => FractionallySizedBox(
        heightFactor: .8,
        child: ListenableBuilder(
          listenable: c,
          builder: (context, _) => SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  AppLocalizations.of(context).mobileMore,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 16),
                _VideoScaleChoices(
                  fill: widget.fillFrame,
                  onChanged: (fill) => widget.onFillFrame?.call(fill),
                ),
                const SizedBox(height: 8),
                if (danmaku != null) ...[
                  Row(
                    children: [
                      Expanded(
                        child: Text(AppLocalizations.of(context).danmaku),
                      ),
                      Switch(
                        key: DanmakuKeys.toggle,
                        value: danmaku.danmakuOn,
                        onChanged: (_) => unawaited(danmaku.toggleDanmaku()),
                      ),
                    ],
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton.icon(
                        key: DanmakuKeys.search,
                        onPressed: () {
                          Navigator.pop(sheetContext);
                          widget.onOpenDanmakuSearch();
                        },
                        icon: const Icon(Icons.search),
                        label: Text(AppLocalizations.of(context).danmakuSearch),
                      ),
                      TextButton.icon(
                        key: DanmakuKeys.panel,
                        onPressed: () {
                          Navigator.pop(sheetContext);
                          widget.onOpenDanmakuPanel();
                        },
                        icon: const Icon(Icons.tune),
                        label: Text(
                          AppLocalizations.of(context).mobileDanmakuPanel,
                        ),
                      ),
                    ],
                  ),
                  const Divider(),
                ],
                Text(AppLocalizations.of(context).mobileTracks),
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
                Text(AppLocalizations.of(context).subtitleTrack),
                ListTile(
                  selected: c.subtitleStreamIndex == null,
                  leading: Icon(
                    c.subtitleStreamIndex == null
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                  ),
                  title: Text(AppLocalizations.of(context).subtitleOff),
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
                if (c.trackFailure != null)
                  Text(AppLocalizations.of(context).mobileTrackUnavailable),
                const Divider(),
                Text(AppLocalizations.of(context).mediaSource),
                for (final source in c.mediaSources)
                  ListTile(
                    selected: source.id == c.activeMediaSourceId,
                    title: Text(source.name ?? source.id),
                    onTap: () => c.switchMediaSource(source.id),
                  ),
                const Divider(),
                Text(AppLocalizations.of(context).mobileSpeed),
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
                const Divider(),
                Text(AppLocalizations.of(context).mobileAppVolume),
                Row(
                  children: [
                    IconButton(
                      key: const Key('mobile-player-mute'),
                      tooltip: c.volume <= 0
                          ? AppLocalizations.of(context).unmute
                          : AppLocalizations.of(context).mute,
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
                    Text(AppLocalizations.of(context).volumePercent(c.volume)),
                  ],
                ),
                TextButton(
                  onPressed: () => Navigator.pop(sheetContext),
                  child: Text(AppLocalizations.of(context).mobileBack),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (mounted && (route == null || route.isCurrent)) {
      _controller.setControlsPinned(false);
    }
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
      children: [
        ChoiceChip(
          key: const Key('mobile-player-scale-fit'),
          label: Text(l.playerFit),
          selected: !_fill,
          onSelected: (_) => _select(false),
        ),
        ChoiceChip(
          key: const Key('mobile-player-scale-fill'),
          label: Text(l.playerFill),
          selected: _fill,
          onSelected: (_) => _select(true),
        ),
      ],
    );
  }
}
