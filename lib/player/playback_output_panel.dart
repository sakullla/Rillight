import 'dart:async';

import 'package:flutter/material.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/player/playback_output_status.dart';
import 'package:rillight/player/player_controller.dart';
import 'package:rillight/player/player_settings.dart';

/// Shared source / actual-output / enhancement block for desktop, phone, TV
/// and the independent settings page.
class PlaybackOutputPanel extends StatefulWidget {
  const PlaybackOutputPanel({
    super.key,
    required this.status,
    required this.saved,
    this.playbackRate = 1,
    this.onDisable,
    this.onKeepOutput,
    this.onRetry,
    this.onRefresh,
    this.onSelect,
  });

  final PlaybackOutputStatus status;
  final VideoEnhancementSelection saved;
  final double playbackRate;
  final Future<void> Function()? onDisable;
  final Future<void> Function()? onKeepOutput;
  final Future<void> Function()? onRetry;
  final Future<void> Function()? onRefresh;

  /// Called only after a required explanation is accepted. Cancel does not call it.
  final Future<void> Function(VideoEnhancementSelection selection)? onSelect;

  @override
  State<PlaybackOutputPanel> createState() => _PlaybackOutputPanelState();
}

class _PlaybackOutputPanelState extends State<PlaybackOutputPanel> {
  bool _confirming = false;
  int? _denoiseDrag;
  int? _sharpenDrag;

  @override
  void initState() {
    super.initState();
    final refresh = widget.onRefresh;
    if (refresh == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(refresh());
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final status = widget.status;
    final known = status.sampled;
    final reasons = playbackOutputReasons(
      l10n,
      status,
      playbackRate: widget.playbackRate,
    );
    String requested(String kind, int core, int saved) =>
        playbackEnhanceLevel(l10n, kind, known ? core : saved, known: true);
    String effective(String kind, int value) =>
        playbackEnhanceLevel(l10n, kind, value, known: known);
    final saved = widget.saved;
    final rateText = playbackFrameRateText(status.outputFrameRate);
    final interpolationEffective = effective(
      'interpolation',
      status.effectiveInterpolation,
    );
    final rows = <(String, String, String, String)>[
      (
        'playback-enhance-interpolation',
        l10n.playbackEnhanceInterpolation,
        requested(
          'interpolation',
          status.requestedInterpolation,
          saved.interpolation == FrameInterpolation.doubleRate ? 2 : 0,
        ),
        known && status.effectiveInterpolation == 2 && rateText.isNotEmpty
            ? '$interpolationEffective · $rateText fps'
            : interpolationEffective,
      ),
      (
        'playback-enhance-anime4k',
        l10n.playbackEnhanceAnime4k,
        requested('anime4k', status.requestedAnime4k, switch (saved.anime4k) {
          Anime4kLevel.light => 1,
          Anime4kLevel.strong => 2,
          Anime4kLevel.off => 0,
        }),
        effective('anime4k', status.effectiveAnime4k),
      ),
      (
        'playback-enhance-super-resolution',
        l10n.playbackEnhanceSuperResolution,
        requested(
          'super',
          status.requestedSuperResolution,
          saved.superResolution == SuperResolution.x2 ? 2 : 0,
        ),
        effective('super', status.effectiveSuperResolution),
      ),
      (
        'playback-enhance-denoise',
        l10n.playbackEnhanceDenoise,
        requested('strength', status.requestedDenoise, saved.denoise),
        effective('strength', status.effectiveDenoise),
      ),
      (
        'playback-enhance-sharpen',
        l10n.playbackEnhanceSharpen,
        requested('strength', status.requestedSharpen, saved.sharpen),
        effective('strength', status.effectiveSharpen),
      ),
    ];
    return Column(
      key: const Key('playback-output-panel'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _line(
          'playback-output-source',
          l10n.playbackOutputSource,
          playbackSourceLabel(l10n, status),
          theme,
        ),
        _line(
          'playback-output-video',
          l10n.playbackOutputVideo,
          playbackVideoOutputLabel(l10n, status),
          theme,
        ),
        _line(
          'playback-output-audio',
          l10n.playbackOutputAudio,
          playbackAudioOutputLabel(l10n, status),
          theme,
        ),
        if (status.hdrDisplayActive != null)
          Text(
            status.hdrDisplayActive!
                ? l10n.playbackOutputDisplayHdrOn
                : l10n.playbackOutputDisplayHdrOff,
            key: const Key('playback-output-display-hdr'),
            style: muted,
          ),
        const SizedBox(height: 8),
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              '${row.$2}  ${l10n.playbackOutputRequested} ${row.$3}  ${l10n.playbackOutputEffective} ${row.$4}',
              key: Key(row.$1),
            ),
          ),
        if (known && rateText.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              l10n.playbackEnhanceFrameRate(rateText),
              key: const Key('playback-output-frame-rate'),
            ),
          ),
        if (!known)
          Text(l10n.playbackOutputIdle, style: muted)
        else if (reasons.isNotEmpty)
          Text(
            reasons.join('\n'),
            key: const Key('playback-output-reason'),
            style: muted,
          ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _action(
              'playback-output-disable',
              l10n.playbackEnhanceDisable,
              widget.onDisable,
            ),
            _action(
              'playback-output-keep',
              l10n.playbackEnhanceKeepOutput,
              widget.onKeepOutput,
            ),
            _action(
              'playback-output-use-available',
              l10n.playbackEnhanceUseAvailable,
              widget.onSelect == null ? null : _useAvailable,
            ),
            _action(
              'playback-output-retry',
              l10n.playbackEnhanceRetry,
              widget.onRetry,
            ),
          ],
        ),
        const SizedBox(height: 8),
        _choices(l10n, saved),
      ],
    );
  }

  Widget _choices(AppLocalizations l10n, VideoEnhancementSelection saved) {
    final enabled = widget.onSelect != null && !_confirming;
    final denoise = _denoiseDrag ?? saved.denoise;
    final sharpen = _sharpenDrag ?? saved.sharpen;
    return Column(
      key: const Key('playback-enhance-choices'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _choiceRow(l10n.playbackEnhanceInterpolation, [
          _choice(
            'playback-select-interpolation-off',
            l10n.playerSettingOff,
            saved.interpolation == FrameInterpolation.off,
            enabled
                ? () =>
                      unawaited(_select(interpolation: FrameInterpolation.off))
                : null,
          ),
          _choice(
            'playback-select-interpolation-double',
            l10n.playbackEnhanceDouble,
            saved.interpolation == FrameInterpolation.doubleRate,
            enabled
                ? () => unawaited(
                    _select(interpolation: FrameInterpolation.doubleRate),
                  )
                : null,
          ),
        ]),
        _choiceRow(l10n.playbackEnhanceAnime4k, [
          _choice(
            'playback-select-anime4k-off',
            l10n.playerSettingOff,
            saved.anime4k == Anime4kLevel.off,
            enabled
                ? () => unawaited(_select(anime4k: Anime4kLevel.off))
                : null,
          ),
          _choice(
            'playback-select-anime4k-light',
            l10n.playbackEnhanceLight,
            saved.anime4k == Anime4kLevel.light,
            enabled
                ? () => unawaited(_select(anime4k: Anime4kLevel.light))
                : null,
          ),
          _choice(
            'playback-select-anime4k-strong',
            l10n.playbackEnhanceStrong,
            saved.anime4k == Anime4kLevel.strong,
            enabled
                ? () => unawaited(_select(anime4k: Anime4kLevel.strong))
                : null,
          ),
        ]),
        _choiceRow(l10n.playbackEnhanceSuperResolution, [
          _choice(
            'playback-select-super-off',
            l10n.playerSettingOff,
            saved.superResolution == SuperResolution.off,
            enabled
                ? () => unawaited(_select(superResolution: SuperResolution.off))
                : null,
          ),
          _choice(
            'playback-select-super-x2',
            l10n.playbackEnhanceX2,
            saved.superResolution == SuperResolution.x2,
            enabled
                ? () => unawaited(_select(superResolution: SuperResolution.x2))
                : null,
          ),
        ]),
        _strength(
          label: l10n.playbackEnhanceDenoise,
          sliderKey: 'playback-select-denoise',
          value: denoise,
          enabled: enabled,
          onChanged: (value) => setState(() => _denoiseDrag = value),
          onChangeEnd: (value) async {
            await _select(denoise: value);
            if (mounted) setState(() => _denoiseDrag = null);
          },
        ),
        _strength(
          label: l10n.playbackEnhanceSharpen,
          sliderKey: 'playback-select-sharpen',
          value: sharpen,
          enabled: enabled,
          onChanged: (value) => setState(() => _sharpenDrag = value),
          onChangeEnd: (value) async {
            await _select(sharpen: value);
            if (mounted) setState(() => _sharpenDrag = null);
          },
        ),
      ],
    );
  }

  Widget _choiceRow(String label, List<Widget> choices) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label),
          const SizedBox(height: 4),
          Wrap(spacing: 8, runSpacing: 8, children: choices),
        ],
      ),
    );
  }

  Widget _choice(
    String key,
    String label,
    bool selected,
    VoidCallback? onPressed,
  ) {
    final style = ButtonStyle(
      visualDensity: VisualDensity.compact,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      minimumSize: const WidgetStatePropertyAll(Size(44, 36)),
    );
    final child = Text(label);
    if (selected) {
      return FilledButton(
        key: Key(key),
        style: style,
        onPressed: onPressed,
        child: child,
      );
    }
    return OutlinedButton(
      key: Key(key),
      style: style,
      onPressed: onPressed,
      child: child,
    );
  }

  Widget _strength({
    required String label,
    required String sliderKey,
    required int value,
    required bool enabled,
    required ValueChanged<int> onChanged,
    required Future<void> Function(int value) onChangeEnd,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('$label  $value'),
          Slider(
            key: Key(sliderKey),
            value: value.clamp(0, 100).toDouble(),
            max: 100,
            divisions: 100,
            label: '$value',
            onChanged: enabled
                ? (next) => onChanged(next.round().clamp(0, 100))
                : null,
            onChangeEnd: enabled
                ? (next) => unawaited(onChangeEnd(next.round().clamp(0, 100)))
                : null,
          ),
        ],
      ),
    );
  }

  /// Saves leaving native Dolby only after this sample is native Dolby and
  /// the user confirms the explanation. Cancel, and any unsampled or other
  /// output, leave the saved choice and the current output unchanged.
  Future<void> _useAvailable() async {
    final select = widget.onSelect;
    if (_confirming || select == null || !mounted) return;
    if (!playbackOutputIsNativeDolby(widget.status)) return;
    setState(() => _confirming = true);
    try {
      final accepted = await _confirm(
        'playback-confirm-leave-dolby',
        AppLocalizations.of(context).playbackEnhanceLeaveDolby,
      );
      if (!accepted || !mounted) return;
      if (!playbackOutputIsNativeDolby(widget.status)) return;
      final saved = widget.saved;
      await select(
        VideoEnhancementSelection(
          interpolation: saved.interpolation,
          anime4k: saved.anime4k,
          superResolution: saved.superResolution,
          denoise: saved.denoise,
          sharpen: saved.sharpen,
          acceptLeaveNativeDolby: true,
        ),
      );
    } finally {
      if (mounted) setState(() => _confirming = false);
    }
  }

  Future<void> _select({
    FrameInterpolation? interpolation,
    Anime4kLevel? anime4k,
    SuperResolution? superResolution,
    int? denoise,
    int? sharpen,
  }) async {
    final select = widget.onSelect;
    if (_confirming || select == null || !mounted) return;
    final saved = widget.saved;
    final unchanged =
        (interpolation == null || interpolation == saved.interpolation) &&
        (anime4k == null || anime4k == saved.anime4k) &&
        (superResolution == null || superResolution == saved.superResolution) &&
        (denoise == null || denoise == saved.denoise) &&
        (sharpen == null || sharpen == saved.sharpen);
    if (unchanged) return;
    var nextAnime = anime4k ?? saved.anime4k;
    var nextSuper = superResolution ?? saved.superResolution;
    setState(() => _confirming = true);
    try {
      if (nextAnime != Anime4kLevel.off && nextSuper != SuperResolution.off) {
        final closingSuper = anime4k != null && anime4k != Anime4kLevel.off;
        final l10n = AppLocalizations.of(context);
        final accepted = await _confirm(
          'playback-confirm-exclusive',
          closingSuper
              ? l10n.playbackEnhanceReplaceSuper
              : l10n.playbackEnhanceReplaceAnime,
        );
        if (!accepted || !mounted) return;
        if (closingSuper) {
          nextSuper = SuperResolution.off;
        } else {
          nextAnime = Anime4kLevel.off;
        }
      }
      var next = VideoEnhancementSelection(
        interpolation: interpolation ?? saved.interpolation,
        anime4k: nextAnime,
        superResolution: nextSuper,
        denoise: denoise ?? saved.denoise,
        sharpen: sharpen ?? saved.sharpen,
        acceptLeaveNativeDolby: saved.acceptLeaveNativeDolby,
      );
      if (_leavesNativeDolby(widget.status, saved, next)) {
        final accepted = await _confirm(
          'playback-confirm-leave-dolby',
          AppLocalizations.of(context).playbackEnhanceLeaveDolby,
        );
        if (!accepted || !mounted) return;
        next = VideoEnhancementSelection(
          interpolation: next.interpolation,
          anime4k: next.anime4k,
          superResolution: next.superResolution,
          denoise: next.denoise,
          sharpen: next.sharpen,
          acceptLeaveNativeDolby: true,
        );
      }
      await select(next);
    } finally {
      if (mounted) setState(() => _confirming = false);
    }
  }

  bool _leavesNativeDolby(
    PlaybackOutputStatus status,
    VideoEnhancementSelection current,
    VideoEnhancementSelection next,
  ) {
    if (current.acceptLeaveNativeDolby) return false;
    if (!playbackOutputIsNativeDolby(status)) return false;
    return next.interpolation != FrameInterpolation.off ||
        next.anime4k != Anime4kLevel.off ||
        next.superResolution != SuperResolution.off ||
        next.denoise != 0 ||
        next.sharpen != 0;
  }

  Future<bool> _confirm(String key, String message) async {
    if (!mounted) return false;
    final l10n = AppLocalizations.of(context);
    final result = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        key: Key(key),
        content: Text(message),
        actions: [
          TextButton(
            key: Key('$key-cancel'),
            onPressed: () => Navigator.pop(dialog, false),
            child: Text(l10n.cancelAction),
          ),
          FilledButton(
            key: Key('$key-accept'),
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(l10n.playbackEnhanceConfirm),
          ),
        ],
      ),
    );
    return result == true;
  }

  Widget _line(String key, String label, String value, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        '$label  $value',
        key: Key(key),
        style: theme.textTheme.bodyMedium,
      ),
    );
  }

  Widget _action(String key, String label, Future<void> Function()? action) {
    return TextButton(
      key: Key(key),
      onPressed: action == null ? null : () => unawaited(action()),
      child: Text(label),
    );
  }
}

/// Player surfaces share one panel and refresh it without touching transport.
class PlaybackOutputPanelView extends StatelessWidget {
  const PlaybackOutputPanelView({super.key, required this.controller});

  final PlayerController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => PlaybackOutputPanel(
        status: controller.outputStatus,
        saved: controller.videoEnhancement,
        playbackRate: controller.playbackRate,
        onDisable: controller.disableVideoEnhancement,
        onKeepOutput: controller.keepCurrentVideoOutput,
        onRetry: controller.retryVideoOutput,
        onRefresh: controller.refreshOutputStatus,
        onSelect: controller.selectVideoEnhancement,
      ),
    );
  }
}
