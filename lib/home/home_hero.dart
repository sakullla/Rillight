import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/widgets/skeleton.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/featured_items.dart';
import 'package:rillight/home/hero_artwork.dart';
import 'package:rillight/home/hero_carousel.dart';
import 'package:rillight/home/hero_playback_actions.dart';
import 'package:rillight/media_image/media_image.dart';

/// Netflix 式全出血轮播:图片铺满卡片,底部渐变遮罩上排文字,
/// 圆点指示,悬停暂停的 7 秒自动轮播。仅海报的条目走海报聚焦版式。
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

class _HomeHeroState extends State<HomeHero> with HeroAutoRotate {
  int _index = 0;
  final Map<String, HeroLayout> _layoutOverride = {};

  void _select(int value, int count) {
    setState(() => _index = (value % count + count) % count);
    resetAutoRotate(count);
  }

  @override
  void advanceCarousel() {
    final count = featuredHomeItems(
      widget.catalog,
      limit: HomeHero.maxFeatured,
    ).length;
    if (count >= 2 && mounted) {
      setState(() => _index = (_index + 1) % count);
    }
  }

  @override
  void dispose() {
    cancelAutoRotate();
    super.dispose();
  }

  /// 背景图校验失败落到海报时修正版式(反之亦然),按条目记忆。
  void _onArtworkResolved(
    EmbyItem item,
    HeroArtworkSources sources,
    HeroArtworkData data,
  ) {
    final guessed = _layoutOverride[item.id] ?? heroLayoutFor(sources);
    final actual = data.poster
        ? HeroLayout.posterSpotlight
        : HeroLayout.fullBleed;
    if (guessed == actual) return;
    setState(() => _layoutOverride[item.id] = actual);
  }

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
    armAutoRotate(items.length);
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
        widget.topOverlap > 0 ? 0 : 16,
        AppSpacing.page,
        16,
      ),
      child: MouseRegion(
        onEnter: (_) => pauseAutoRotate(),
        onExit: (_) => resumeAutoRotate(items.length),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final scheme = Theme.of(context).colorScheme;
            final compact = constraints.maxWidth < 720;
            final height =
                math.max(
                  HomeHero.heightFor(
                    constraints.maxWidth,
                    viewportHeight: MediaQuery.sizeOf(context).height,
                  ),
                  252 * scale + 32,
                ) +
                widget.topOverlap;
            final layout = _layoutOverride[item.id] ?? heroLayoutFor(artwork);
            final requestWidth = mediaHeroBackdropRequestWidth(
              layoutWidth: constraints.maxWidth,
              devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
            );
            final actions = HeroPlaybackActions(
              item: item,
              onDetails: () => context.push(AppRoutes.item(item.id)),
            );
            final text = HeroTextBlock(
              item: item,
              compact: compact,
              includeActions: layout == HeroLayout.fullBleed || !compact,
              showOverview: HomeHero.showsOverview(
                constraints.maxWidth,
                viewportHeight: MediaQuery.sizeOf(context).height,
              ),
              actions: actions,
            );
            final Widget visual = layout == HeroLayout.fullBleed
                ? Stack(
                    fit: StackFit.expand,
                    children: [
                      HeroArtwork(
                        key: ValueKey('hero-artwork-${item.id}'),
                        sources: artwork,
                        requestWidth: requestWidth,
                        compact: compact,
                        onResolved: (data) =>
                            _onArtworkResolved(item, artwork, data),
                      ),
                      HeroScrim(top: widget.topOverlap > 0),
                      Positioned(
                        left: compact ? 20 : 32,
                        right: compact ? 20 : 32,
                        bottom: compact ? 20 : 28,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: HomeHero.textBlockWidthFor(
                              constraints.maxWidth,
                            ),
                          ),
                          child: text,
                        ),
                      ),
                    ],
                  )
                : HeroPosterSpotlight(
                    key: ValueKey('hero-spotlight-${item.id}'),
                    sources: artwork,
                    requestWidth: requestWidth,
                    compact: compact,
                    text: text,
                    actions: compact ? actions : null,
                    onResolved: (data) =>
                        _onArtworkResolved(item, artwork, data),
                  );
            return Material(
              key: const Key('home-hero-card'),
              color: scheme.surfaceContainerLow,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(
                  widget.topOverlap > 0 ? 0 : 24,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                key: const Key('home-hero-details-target'),
                onTap: () => context.push(AppRoutes.item(item.id)),
                child: SizedBox(
                  height: compact ? height + 180 : height,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      AnimatedSwitcher(
                        duration: AppMotion.durationOf(context, AppMotion.slow),
                        child: RepaintBoundary(
                          key: ValueKey('home-hero-slide-${item.id}'),
                          child: visual,
                        ),
                      ),
                      if (items.length > 1) ...[
                        Positioned(
                          left: 4,
                          top: 0,
                          bottom: 0,
                          child: Center(
                            child: _chevron(
                              key: CatalogKeys.heroPrev,
                              tooltip: AppLocalizations.of(context).scrollLeft,
                              icon: Icons.chevron_left,
                              onPressed: () => _select(index - 1, items.length),
                            ),
                          ),
                        ),
                        Positioned(
                          right: 4,
                          top: 0,
                          bottom: 0,
                          child: Center(
                            child: _chevron(
                              key: CatalogKeys.heroNext,
                              tooltip: AppLocalizations.of(context).scrollRight,
                              icon: Icons.chevron_right,
                              onPressed: () => _select(index + 1, items.length),
                            ),
                          ),
                        ),
                        Positioned(
                          right: 20,
                          bottom: 20,
                          child: HeroDots(
                            index: index,
                            count: items.length,
                            onSelect: (i) => _select(i, items.length),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _chevron({
    required Key key,
    required String tooltip,
    required IconData icon,
    required VoidCallback onPressed,
  }) {
    return IconButton(
      key: key,
      tooltip: tooltip,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        backgroundColor: Colors.black38,
        foregroundColor: Colors.white,
      ),
      icon: Icon(icon),
    );
  }
}
