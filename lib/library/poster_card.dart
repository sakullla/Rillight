import 'package:flutter/material.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
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
  });

  final EmbyItem item;
  final VoidCallback onTap;
  final bool showProgress;
  final double width;

  @override
  Widget build(BuildContext context) {
    final height = width * 1.5;
    final l10n = AppLocalizations.of(context);
    final progress = item.playbackProgress;
    return SizedBox(
      width: width,
      child: InkWell(
        key: CatalogKeys.item(item.id),
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: width,
                height: height,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    MediaImage(item: item, width: width, height: height),
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
            const SizedBox(height: 8),
            Text(
              item.displayName,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            if (showProgress && progress > 0)
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

class _ResumeProgressBar extends StatelessWidget {
  const _ResumeProgressBar({super.key, required this.value});

  final double value;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 4,
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
