import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/library/item_format.dart';
import 'package:rillight/media_image/media_image.dart';
import 'package:rillight/media_server/models.dart';
import 'package:rillight/player/player_controller.dart';
import 'package:rillight/player/player_keys.dart';
import 'package:rillight/app/ui/app_icons.dart';

/// 播放器内「接下来播放」的简洁单集名：优先展示 `S1E2 · 集名`，
/// 不重复播放器顶栏已经写明的长剧名，避免剧名把集名挤成省略号。
String nextEpisodeCardTitle(MediaItem item) {
  final code = seasonEpisodeCode(item);
  final name = item.name.trim();
  if (code != null) {
    if (name.isEmpty || name.toLowerCase() == code.toLowerCase()) {
      return code;
    }
    if (name.toLowerCase().startsWith(code.toLowerCase())) {
      return name;
    }
    return '$code · $name';
  }
  return numberedEpisodeTitle(item);
}

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
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    final remaining = offer.remaining;
    final countdown = controller.nextEpisodeCountdown.inMilliseconds;
    final episodeTitle = nextEpisodeCardTitle(offer.item);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth.clamp(0.0, 440.0).toDouble()
            : 440.0;
        final showThumb = width >= 310;
        final radius = BorderRadius.circular(AppRadii.lg);
        return SizedBox(
          width: width,
          child: Container(
            key: PlayerKeys.nextEpisode,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh.withValues(alpha: .94),
              borderRadius: radius,
              border: Border.all(
                color: AppEdge.of(theme.brightness, strong: true),
                width: 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: scheme.scrim.withValues(alpha: .4),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
                  child: Row(
                    children: [
                      if (showThumb) ...[
                        DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(AppRadii.md),
                            border: Border.all(
                              color: CupertinoColors.white.withValues(
                                alpha: .14,
                              ),
                              width: 0.8,
                            ),
                          ),
                          position: DecorationPosition.foreground,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(AppRadii.md),
                            child: MediaImage(
                              item: offer.item,
                              width: 76,
                              height: 43,
                              preferThumb: true,
                              maxWidth: 320,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                      ],
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  width: 6,
                                  height: 6,
                                  decoration: BoxDecoration(
                                    color: scheme.primary,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Flexible(
                                  child: Text(
                                    remaining == null
                                        ? l10n.nextEpisodeHeading
                                        : l10n.nextEpisodeIn(
                                            (remaining.inMilliseconds / 1000)
                                                .ceil(),
                                          ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: scheme.onSurface.withValues(
                                        alpha: .8,
                                      ),
                                      fontSize: 11.5,
                                      height: 1.2,
                                      fontFeatures: const [
                                        FontFeature.tabularFigures(),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 3),
                            Text(
                              episodeTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall?.copyWith(
                                color: scheme.onSurface,
                                fontSize: 14,
                                height: 1.25,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      AppButton.icon(
                        key: PlayerKeys.nextEpisodePlay,
                        focusNode: playFocus,
                        onPressed: controller.playNextEpisode,
                        style: AppButtonStyle(
                          backgroundColor: scheme.primary,
                          foregroundColor: scheme.onPrimary,
                          minimumSize: const Size(0, 40),
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          shape: const StadiumBorder(),
                          textStyle: const TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        icon: const Icon(
                          AppIcons.skipNext,
                          fill: AppIcons.filled,
                          size: 19,
                        ),
                        label: Text(l10n.nextEpisode),
                      ),
                      const SizedBox(width: 2),
                      AppIconButton(
                        key: PlayerKeys.nextEpisodeCancel,
                        focusNode: cancelFocus,
                        tooltip: remaining == null
                            ? l10n.nextEpisodeKeepWatching
                            : l10n.nextEpisodeStay,
                        onPressed: controller.cancelNextEpisode,
                        style: AppButtonStyle(
                          foregroundColor: CupertinoColors.white.withValues(
                            alpha: .8,
                          ),
                          minimumSize: const Size(40, 40),
                          fixedSize: const Size(40, 40),
                          padding: EdgeInsets.zero,
                          shape: const CircleBorder(),
                        ),
                        icon: const Icon(
                          AppIcons.close,
                          fill: AppIcons.filled,
                          size: 17,
                        ),
                      ),
                    ],
                  ),
                ),
                if (remaining != null)
                  AppProgressBar(
                    value: countdown <= 0
                        ? 0
                        : (remaining.inMilliseconds / countdown).clamp(
                            0.0,
                            1.0,
                          ),
                    height: 3,
                    color: scheme.primary,
                    backgroundColor: CupertinoColors.white.withValues(
                      alpha: .15,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
