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
            ? constraints.maxWidth.clamp(0.0, 350.0).toDouble()
            : 350.0;
        return SizedBox(
          width: width,
          child: Material(
            key: PlayerKeys.nextEpisode,
            color: scheme.surfaceContainerHigh,
            elevation: 8,
            shadowColor: Colors.black54,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
              side: BorderSide(color: scheme.outlineVariant),
            ),
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    l10n.nextEpisodeHeading,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: MediaImage(
                          item: offer.item,
                          width: 96,
                          height: 60,
                          preferThumb: true,
                          maxWidth: 320,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          offer.item.displayName,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (remaining != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      l10n.nextEpisodeIn(
                        (remaining.inMilliseconds / 1000).ceil(),
                      ),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                      value: countdown <= 0
                          ? 0
                          : (remaining.inMilliseconds / countdown).clamp(
                              0.0,
                              1.0,
                            ),
                      borderRadius: BorderRadius.circular(4),
                      minHeight: 3,
                    ),
                  ],
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    key: PlayerKeys.nextEpisodePlay,
                    focusNode: playFocus,
                    onPressed: controller.playNextEpisode,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                    icon: const Icon(Icons.skip_next_rounded, size: 22),
                    label: Text(l10n.playNextEpisode),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    key: PlayerKeys.nextEpisodeCancel,
                    focusNode: cancelFocus,
                    onPressed: controller.cancelNextEpisode,
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(44),
                    ),
                    child: Text(
                      remaining == null
                          ? l10n.nextEpisodeKeepWatching
                          : l10n.nextEpisodeStay,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
