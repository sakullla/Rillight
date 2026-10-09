import 'dart:async';

import 'package:flutter/material.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/player/playback_output_status.dart';
import 'package:rillight/player/player_controller.dart';

/// Shared source / actual-output block for desktop, phone, TV
/// and the independent settings page.
class PlaybackOutputPanel extends StatefulWidget {
  const PlaybackOutputPanel({
    super.key,
    required this.status,
    this.playbackRate = 1,
    this.onRefresh,
  });

  final PlaybackOutputStatus status;
  final double playbackRate;
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
    final rateText = playbackFrameRateText(status.outputFrameRate);
    final reasons = playbackOutputReasons(
      l10n,
      status,
      playbackRate: widget.playbackRate,
    );
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
        if (known && rateText.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              l10n.playbackOutputFrameRate(rateText),
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
        playbackRate: controller.playbackRate,
        onRefresh: controller.refreshOutputStatus,
      ),
    );
  }
}
