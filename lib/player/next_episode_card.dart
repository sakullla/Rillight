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
    final remaining = offer.remaining;
    final countdown = controller.nextEpisodeCountdown.inMilliseconds;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth.clamp(0.0, 480.0).toDouble()
            : 480.0;
        final compact = width < 400;
        const ink = Color(0xF214161C);
        return SizedBox(
          width: width,
          child: Material(
            key: PlayerKeys.nextEpisode,
            color: ink,
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: const BorderSide(color: Color(0x24FFFFFF)),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 4, 8),
                  child: Row(
                    children: [
                      if (!compact) ...[
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: MediaImage(
                            item: offer.item,
                            width: 84,
                            height: 47,
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
                                color: const Color(0xB3FFFFFF),
                                fontSize: 11,
                                height: 1.2,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              offer.item.displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall?.copyWith(
                                color: Colors.white,
                                fontSize: 14,
                                height: 1.25,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.icon(
                        key: PlayerKeys.nextEpisodePlay,
                        focusNode: playFocus,
                        onPressed: controller.playNextEpisode,
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: Colors.black,
                          minimumSize: const Size(0, 40),
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          visualDensity: VisualDensity.standard,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        icon: const Icon(Icons.skip_next_rounded, size: 20),
                        label: Text(l10n.nextEpisode),
                      ),
                      IconButton(
                        key: PlayerKeys.nextEpisodeCancel,
                        focusNode: cancelFocus,
                        tooltip: remaining == null
                            ? l10n.nextEpisodeKeepWatching
                            : l10n.nextEpisodeStay,
                        onPressed: controller.cancelNextEpisode,
                        style: IconButton.styleFrom(
                          foregroundColor: const Color(0xB3FFFFFF),
                          minimumSize: const Size(40, 40),
                          fixedSize: const Size(40, 40),
                          padding: EdgeInsets.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
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
                    color: Colors.white,
                    backgroundColor: const Color(0x33FFFFFF),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
