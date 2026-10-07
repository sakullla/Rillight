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
    this.onUseAvailable,
    this.onRetry,
    this.onRefresh,
  });

  final PlaybackOutputStatus status;
  final VideoEnhancementSelection saved;
  final double playbackRate;
  final Future<void> Function()? onDisable;
  final Future<void> Function()? onKeepOutput;
  final Future<void> Function()? onUseAvailable;
  final Future<void> Function()? onRetry;
  final Future<void> Function()? onRefresh;

  @override
  State<PlaybackOutputPanel> createState() => _PlaybackOutputPanelState();
}

class _PlaybackOutputPanelState extends State<PlaybackOutputPanel> {
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
    final rows = <(String, String, String, String)>[
      (
        'playback-enhance-interpolation',
        l10n.playbackEnhanceInterpolation,
        requested(
          'interpolation',
          status.requestedInterpolation,
          saved.interpolation == FrameInterpolation.doubleRate ? 2 : 0,
        ),
        effective('interpolation', status.effectiveInterpolation),
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
              widget.onUseAvailable,
            ),
            _action(
              'playback-output-retry',
              l10n.playbackEnhanceRetry,
              widget.onRetry,
            ),
          ],
        ),
      ],
    );
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
        onUseAvailable: controller.useAvailableVideoOutput,
        onRetry: controller.retryVideoOutput,
        onRefresh: controller.refreshOutputStatus,
      ),
    );
  }
}
