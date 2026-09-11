import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/library/item_format.dart';
import 'package:rillight/media_image/media_image.dart';
import 'package:rillight/player/player_window_host.dart';

class HomeHero extends StatelessWidget {
  const HomeHero({super.key, required this.catalog});

  final CatalogController catalog;

  EmbyItem? get _featured {
    for (final item in catalog.resume.items) {
      if (item.isPlayable || item.isSeries) {
        return item;
      }
    }
    for (final item in catalog.latestMovies.items) {
      return item;
    }
    for (final item in catalog.latestSeries.items) {
      return item;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final item = _featured;
    if (item == null) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          height: 360,
          width: double.infinity,
          child: Stack(
            fit: StackFit.expand,
            children: [
              MediaImage(
                item: item,
                height: 360,
                preferBackdrop: true,
                maxWidth: 1600,
              ),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [Color(0xCC000000), Color(0x00000000)],
                  ),
                ),
              ),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [Color(0xDD000000), Color(0x00000000)],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(28, 28, 28, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Spacer(),
                    Text(
                      itemTitle(item),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.displaySmall?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (item.overview != null &&
                        item.overview!.trim().isNotEmpty) ...[
                      const SizedBox(height: 8),
                      SizedBox(
                        width: 520,
                        child: Text(
                          item.overview!,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: Colors.white.withValues(alpha: 0.86),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 12,
                      children: [
                        if (item.isPlayable || item.isSeries)
                          FilledButton.icon(
                            onPressed: () {
                              if (item.isPlayable) {
                                unawaited(
                                  PlayerWindowScope.of(
                                    context,
                                  ).open(PlayerOpenRequest(itemId: item.id)),
                                );
                                return;
                              }
                              context.push(AppRoutes.item(item.id));
                            },
                            icon: const Icon(Icons.play_arrow),
                            label: Text(l10n.play),
                          ),
                        OutlinedButton(
                          onPressed: () =>
                              context.push(AppRoutes.item(item.id)),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white,
                          ),
                          child: Text(item.name),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
