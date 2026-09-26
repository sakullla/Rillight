import 'package:flutter/material.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/player/buffer_snapshot.dart';
import 'package:rillight/player/network_throughput.dart';

/// Download throughput and verified cache coverage are independent facts.
/// Layouts can change the typography without changing their meaning.
class PlayerCacheStatus extends StatelessWidget {
  const PlayerCacheStatus({
    super.key,
    required this.snapshot,
    required this.bytesPerSecond,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.textStyle,
    this.color,
  });

  final BufferSnapshot snapshot;
  final num bytesPerSecond;
  final Duration position;
  final Duration duration;
  final TextStyle? textStyle;
  final Color? color;

  String _coverage(AppLocalizations l10n) {
    if (!snapshot.isKnown) return l10n.playerCacheUnknown;
    if (snapshot.ranges.isEmpty) return l10n.playerCacheEmpty;
    if (duration > Duration.zero &&
        snapshot.ranges.any(
          (range) => range.start == Duration.zero && range.end >= duration,
        )) {
      return l10n.playerCacheComplete;
    }
    for (final range in snapshot.ranges) {
      if (range.start <= position && position < range.end) {
        final end = duration > Duration.zero && range.end > duration
            ? duration
            : range.end;
        final seconds = (end - position).inSeconds;
        if (seconds <= 0) break;
        final minutes = seconds ~/ 60;
        return l10n.playerCacheAhead(
          '$minutes:${(seconds % 60).toString().padLeft(2, '0')}',
        );
      }
    }
    return l10n.playerCacheFragments;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final style = (textStyle ?? Theme.of(context).textTheme.bodySmall)
        ?.copyWith(color: color);
    return Wrap(
      spacing: 12,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Tooltip(
          message: l10n.playerNetworkSpeedTooltip,
          child: NetworkSpeedReadout(
            bytesPerSecond: bytesPerSecond,
            textStyle: style,
            color: color,
          ),
        ),
        Text(_coverage(l10n), style: style),
      ],
    );
  }
}
