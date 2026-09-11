import 'package:flutter/material.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/widgets/app_hover_card.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/media_image/media_image.dart';

class PosterCard extends StatelessWidget {
  const PosterCard({
    super.key,
    required this.item,
    required this.onTap,
    this.showProgress = false,
    this.width = 120,
    this.wide = false,
  });

  final EmbyItem item;
  final VoidCallback onTap;
  final bool showProgress;
  final double width;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final height = wide ? width * 9 / 16 : width * 1.5;
    final l10n = AppLocalizations.of(context);
    final progress = item.playbackProgress;
    final title = item.isEpisode && (item.seriesName?.isNotEmpty ?? false)
        ? item.seriesName!
        : item.name;
    return SizedBox(
      width: width,
      child: AppHoverCard(
        inkKey: CatalogKeys.item(item.id),
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadii.sm),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadii.sm),
              child: SizedBox(
                width: width,
                height: height,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    MediaImage(
                      item: item,
                      width: width,
                      height: height,
                      preferBackdrop: wide,
                      maxWidth: wide ? 480 : 280,
                    ),
                    if (showProgress && progress > 0)
                      Align(
                        alignment: Alignment.bottomCenter,
                        child: _ResumeProgressBar(
                          key: CatalogKeys.resumeProgress,
                          value: progress,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            SizedBox(height: wide ? AppSpacing.xxs : AppSpacing.xs),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: wide
                  ? Theme.of(context).textTheme.bodySmall
                  : Theme.of(context).textTheme.bodyMedium,
            ),
            if (!wide && showProgress && progress > 0)
              Text(
                l10n.playbackProgress((progress * 100).round()),
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        ),
      ),
    );
  }
}

class EpisodeThumbCard extends StatelessWidget {
  const EpisodeThumbCard({
    super.key,
    required this.item,
    required this.onTap,
    this.width = 210,
  });

  final EmbyItem item;
  final VoidCallback onTap;
  final double width;

  @override
  Widget build(BuildContext context) {
    final height = width * 9 / 16;
    final progress = item.playbackProgress;
    final number = item.indexNumber;
    final title = number == null ? item.name : '$number. ${item.name}';
    return SizedBox(
      width: width,
      child: AppHoverCard(
        inkKey: CatalogKeys.episode(item.id),
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadii.sm),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadii.sm),
              child: SizedBox(
                width: width,
                height: height,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    MediaImage(
                      item: item,
                      width: width,
                      height: height,
                      maxWidth: 480,
                    ),
                    if (progress > 0)
                      Align(
                        alignment: Alignment.bottomCenter,
                        child: _ResumeProgressBar(value: progress),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class SeasonPosterCard extends StatelessWidget {
  const SeasonPosterCard({
    super.key,
    required this.item,
    required this.selected,
    required this.onTap,
    this.width = 132,
  });

  final EmbyItem item;
  final bool selected;
  final VoidCallback onTap;
  final double width;

  @override
  Widget build(BuildContext context) {
    final height = width * 3 / 2;
    final colorScheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: width,
      child: AppHoverCard(
        inkKey: CatalogKeys.season(item.id),
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadii.sm),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadii.sm),
                border: Border.all(
                  color: selected ? colorScheme.primary : Colors.transparent,
                  width: 2,
                ),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppRadii.sm),
                child: SizedBox(
                  width: width,
                  height: height,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      MediaImage(
                        item: item,
                        width: width,
                        height: height,
                        maxWidth: 280,
                      ),
                      if (item.childCount != null && item.childCount! > 0)
                        Positioned(
                          top: AppSpacing.xs,
                          right: AppSpacing.xs,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: colorScheme.scrim.withValues(alpha: 0.72),
                              borderRadius: BorderRadius.circular(AppRadii.md),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: AppSpacing.xs,
                                vertical: AppSpacing.xxs,
                              ),
                              child: Text(
                                '${item.childCount}',
                                style: Theme.of(context).textTheme.labelMedium
                                    ?.copyWith(color: colorScheme.onSurface),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              item.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _ResumeProgressBar extends StatelessWidget {
  const _ResumeProgressBar({super.key, required this.value});

  final double value;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: AppSpacing.xxs,
      child: ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Align(
          alignment: Alignment.centerLeft,
          child: FractionallySizedBox(
            widthFactor: value.clamp(0.0, 1.0),
            child: ColoredBox(color: Theme.of(context).colorScheme.primary),
          ),
        ),
      ),
    );
  }
}
