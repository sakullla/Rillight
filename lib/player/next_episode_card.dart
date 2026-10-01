import 'package:flutter/material.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/media_image/media_image.dart';
import 'package:rillight/player/player_controller.dart';
import 'package:rillight/player/player_keys.dart';

class NextEpisodeCard extends StatelessWidget {
  const NextEpisodeCard({
    super.key,
    required this.controller,
    this.playFocus,
    this.cancelFocus,
  });
  final PlayerController controller;
  final FocusNode? playFocus;
  final FocusNode? cancelFocus;

  @override
  Widget build(BuildContext context) {
    final offer = controller.nextEpisode;
    if (offer == null) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final remaining = offer.remaining;
    final countdown = controller.nextEpisodeCountdown.inMilliseconds;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth.clamp(0.0, 480.0).toDouble()
            : 480.0;
        final compact = width < 400;
        return SizedBox(
          width: width,
          child: Material(
            key: PlayerKeys.nextEpisode,
            color: scheme.surfaceContainerHigh,
            elevation: 4,
            shadowColor: Colors.black38,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: scheme.outlineVariant),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.all(10),
                  child: Row(
                    children: [
                      if (!compact) ...[
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: MediaImage(
                            item: offer.item,
                            width: 56,
                            height: 36,
                            preferThumb: true,
                            maxWidth: 320,
                          ),
                        ),
                        const SizedBox(width: 10),
                      ],
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              remaining == null
                                  ? l10n.nextEpisodeHeading
                                  : l10n.nextEpisodeIn(
                                      (remaining.inMilliseconds / 1000).ceil(),
                                    ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              offer.item.displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      FilledButton.icon(
                        key: PlayerKeys.nextEpisodePlay,
                        focusNode: playFocus,
                        onPressed: controller.playNextEpisode,
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(0, 40),
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          visualDensity: VisualDensity.standard,
                        ),
                        icon: const Icon(Icons.skip_next_rounded, size: 20),
                        label: Text(l10n.nextEpisode),
                      ),
                      const SizedBox(width: 4),
                      IconButton(
                        key: PlayerKeys.nextEpisodeCancel,
                        focusNode: cancelFocus,
                        tooltip: remaining == null
                            ? l10n.nextEpisodeKeepWatching
                            : l10n.nextEpisodeStay,
                        onPressed: controller.cancelNextEpisode,
                        icon: const Icon(Icons.close_rounded, size: 18),
                      ),
                    ],
                  ),
                ),
                if (remaining != null)
                  LinearProgressIndicator(
                    value: countdown <= 0
                        ? 0
                        : (remaining.inMilliseconds / countdown).clamp(
                            0.0,
                            1.0,
                          ),
                    minHeight: 2,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
