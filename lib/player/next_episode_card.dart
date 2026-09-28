import 'package:flutter/material.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/media_image/media_image.dart';
import 'package:rillight/player/player_controller.dart';
import 'package:rillight/player/player_keys.dart';

/// Shared next-episode offer for desktop, phone, and TV.
/// The episode name identifies the target; play and cancel stay separate.
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
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final offer = controller.nextEpisode!;
    final seconds = offer.remaining?.inSeconds;
    final scheme = theme.colorScheme;
    return Material(
      key: PlayerKeys.nextEpisode,
      color: scheme.surface.withValues(alpha: 0.94),
      elevation: 8,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 4, 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            MediaImage(
              item: offer.item,
              width: 72,
              height: 40,
              preferThumb: true,
              maxWidth: 240,
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 120,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    offer.item.displayName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (seconds != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      l10n.nextEpisodeIn(seconds),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                  const SizedBox(height: 6),
                  FilledButton.icon(
                    key: PlayerKeys.nextEpisodePlay,
                    focusNode: playFocus,
                    onPressed: controller.playNextEpisode,
                    icon: const Icon(Icons.play_arrow_rounded, size: 18),
                    label: Text(l10n.playNextEpisode),
                  ),
                ],
              ),
            ),
            IconButton(
              key: PlayerKeys.nextEpisodeCancel,
              focusNode: cancelFocus,
              tooltip: l10n.cancelNextEpisode,
              onPressed: controller.cancelNextEpisode,
              icon: const Icon(Icons.close_rounded, size: 18),
            ),
          ],
        ),
      ),
    );
  }
}
