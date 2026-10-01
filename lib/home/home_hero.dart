import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/content_theme.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/widgets/skeleton.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/featured_items.dart';
import 'package:rillight/home/hero_artwork.dart';
import 'package:rillight/home/hero_playback_actions.dart';
import 'package:rillight/library/item_format.dart';
import 'package:rillight/media_image/media_image.dart';

/// Manual featured selection, with readable copy beside official artwork.
class HomeHero extends StatefulWidget {
  const HomeHero({super.key, required this.catalog, this.topOverlap = 0});
  final CatalogController catalog;
  final double topOverlap;
  static const maxFeatured = 5;
  static double heightFor(double width, {double? viewportHeight}) =>
      math.min(width * .32, (viewportHeight ?? 900) * .48).clamp(300, 440);
  static bool showsOverview(double width, {double? viewportHeight}) =>
      width >= 720;
  static double textBlockWidthFor(double width) => math.min(width * .44, 560);
  @override
  State<HomeHero> createState() => _HomeHeroState();
}

class _HomeHeroState extends State<HomeHero> {
  int _index = 0;
  void _select(int value, int count) =>
      setState(() => _index = (value % count + count) % count);
  @override
  Widget build(BuildContext context) {
    final items = featuredHomeItems(
      widget.catalog,
      limit: HomeHero.maxFeatured,
    );
    if (items.isEmpty) {
      if (!widget.catalog.resume.loading &&
          !widget.catalog.latestMovies.loading &&
          !widget.catalog.latestSeries.loading) {
        return const SizedBox.shrink();
      }
      return Padding(
        padding: EdgeInsets.fromLTRB(
          AppSpacing.page,
          widget.topOverlap + 16,
          AppSpacing.page,
          16,
        ),
        child: const SkeletonBlock(width: double.infinity, height: 300),
      );
    }
    final index = _index % items.length;
    final item = items[index];
    final artwork = heroArtworkSources(
      item,
      series: widget.catalog.latestSeries.items,
    );
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.page,
        widget.topOverlap + 16,
        AppSpacing.page,
        16,
      ),
      child: Column(
        children: [
          ContentTheme(
            item: artwork.themeItem,
            preferBackdrop: true,
            fillSurface: false,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final scheme = Theme.of(context).colorScheme;
                final compact = constraints.maxWidth < 720;
                final height = math.max(
                  HomeHero.heightFor(
                    constraints.maxWidth,
                    viewportHeight: MediaQuery.sizeOf(context).height,
                  ),
                  252 * scale + 32,
                );
                final image = HeroArtwork(
                  key: ValueKey('hero-artwork-${item.id}'),
                  sources: artwork,
                  requestWidth: mediaBackdropRequestWidth(
                    layoutWidth: constraints.maxWidth,
                    devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
                  ),
                  compact: compact,
                );
                final copy = Padding(
                  padding: EdgeInsets.all(compact ? 24 : 32),
                  child: _HeroContent(item: item, showOverview: !compact),
                );
                return Material(
                  key: const Key('home-hero-card'),
                  color: scheme.surfaceContainerLow,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(24),
                    side: BorderSide(
                      color: scheme.outlineVariant.withValues(alpha: .35),
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: SizedBox(
                    height: compact ? height + 180 : height,
                    child: compact
                        ? Column(
                            children: [
                              SizedBox(height: 180, child: image),
                              Expanded(child: copy),
                            ],
                          )
                        : Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(flex: 5, child: copy),
                              Expanded(flex: 6, child: image),
                            ],
                          ),
                  ),
                );
              },
            ),
          ),
          if (items.length > 1) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                IconButton(
                  key: CatalogKeys.heroPrev,
                  tooltip: AppLocalizations.of(context).scrollLeft,
                  onPressed: () => _select(index - 1, items.length),
                  icon: const Icon(Icons.chevron_left),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (var i = 0; i < items.length; i++)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: TextButton(
                              key: CatalogKeys.heroDot(i),
                              onPressed: () => _select(i, items.length),
                              style: TextButton.styleFrom(
                                minimumSize: const Size(44, 44),
                                foregroundColor: i == index
                                    ? Theme.of(
                                        context,
                                      ).colorScheme.onSecondaryContainer
                                    : Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                                backgroundColor: i == index
                                    ? Theme.of(
                                        context,
                                      ).colorScheme.secondaryContainer
                                    : Colors.transparent,
                              ),
                              child: Semantics(
                                selected: i == index,
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxWidth: 160,
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (i == index) ...[
                                        const Icon(
                                          Icons.play_arrow_rounded,
                                          size: 16,
                                        ),
                                        const SizedBox(width: 4),
                                      ],
                                      Flexible(
                                        child: Text(
                                          _title(items[i]),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  key: CatalogKeys.heroNext,
                  tooltip: AppLocalizations.of(context).scrollRight,
                  onPressed: () => _select(index + 1, items.length),
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

String _title(EmbyItem item) =>
    item.isEpisode && item.seriesName?.isNotEmpty == true
    ? item.seriesName!
    : item.name;

class _HeroContent extends StatelessWidget {
  const _HeroContent({required this.item, required this.showOverview});
  final EmbyItem item;
  final bool showOverview;
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final meta = <String>[
      if (item.isEpisode) ?seasonEpisodeCode(item),
      if (!item.isEpisode && item.productionYear != null)
        '${item.productionYear}',
      ?runtimeLabel(l10n, item),
      if (item.canResume)
        l10n.playbackProgress((item.playbackProgress * 100).round()),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          _title(item),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        if (meta.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            meta.join(' · '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        if (showOverview && item.overview?.trim().isNotEmpty == true) ...[
          const SizedBox(height: 16),
          Text(
            item.overview!,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.6,
            ),
          ),
        ],
        const SizedBox(height: 24),
        HeroPlaybackActions(
          item: item,
          onDetails: () => context.push(AppRoutes.item(item.id)),
        ),
      ],
    );
  }
}
