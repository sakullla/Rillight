import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/content_theme.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/widgets/backdrop_scrim.dart';
import 'package:rillight/app/widgets/scrim_icon_button.dart';
import 'package:rillight/app/widgets/skeleton.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/home/featured_items.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/media_shelf.dart';
import 'package:rillight/library/item_format.dart';
import 'package:rillight/media_image/media_image.dart';

/// 首页全宽 hero 轮播:最多 5 条候选(继续观看优先,其次最新电影/剧集)。
/// 只支持两侧大箭头与指示点手动切换,无自动轮换;
/// [MediaQuery.disableAnimations] 或 [AppMotion.durationOf] 为零时切换即时完成。
/// backdrop 顶到内容区边缘,[BackdropScrim] 三段遮罩上叠大标题、元信息与主操作。
class HomeHero extends StatefulWidget {
  const HomeHero({super.key, required this.catalog, this.topOverlap = 0});

  final CatalogController catalog;

  /// 向上叠过 [AppShell] 顶栏的高度;由首页传入,本组件只增加画面高度。
  final double topOverlap;

  /// hero 高度:桌面流媒体首页约 2:1 画幅、视口 68%,顶栏叠在画面上缘。
  static double heightFor(double width, {double? viewportHeight}) {
    final fromWidth = width * 0.50;
    final fromViewport = viewportHeight == null
        ? fromWidth
        : viewportHeight * 0.68;
    final base = math.min(fromWidth, fromViewport);
    if (width < AppBreakpoints.compact) {
      return base.clamp(380.0, 560.0);
    }
    if (width < AppBreakpoints.large) {
      return base.clamp(460.0, 680.0);
    }
    return base.clamp(520.0, 780.0);
  }

  /// 高度足够时才放得下简介。
  static bool showsOverview(double width, {double? viewportHeight}) =>
      heightFor(width, viewportHeight: viewportHeight) >= 400;

  /// 轮播候选上限,避免指示点过多。
  static const maxFeatured = 5;

  /// 顶带在顶栏下方继续溶入的高度;与 [AppScrim.topBandHeight] 的默认
  /// 构成(顶栏 56 + 溶入 36)一致。
  static const double topBandFade = 36;

  /// 文字块最大宽度:不超过 60% 视口且 ≤ 640,与 [AppScrim.textBandWidthFactor]
  /// 的文字带对齐。
  static double textBlockWidthFor(double width) =>
      width < AppBreakpoints.compact
      ? width - AppSpacing.page * 2
      : math.min(width * 0.6, 640);

  @override
  State<HomeHero> createState() => _HomeHeroState();
}

class _HomeHeroState extends State<HomeHero> {
  int _index = 0;

  /// 候选:继续观看优先,其次最新电影、最新剧集,按 id 去重。
  List<EmbyItem> get _featuredItems {
    return featuredHomeItems(widget.catalog, limit: HomeHero.maxFeatured);
  }

  bool get _loading =>
      widget.catalog.resume.loading ||
      widget.catalog.latestMovies.loading ||
      widget.catalog.latestSeries.loading;

  void _go(int delta) {
    final count = _featuredItems.length;
    if (count < 2) {
      return;
    }
    _goTo(_index + delta);
  }

  void _goTo(int index) {
    final count = _featuredItems.length;
    if (count < 2) {
      return;
    }
    setState(() => _index = (index % count + count) % count);
  }

  @override
  Widget build(BuildContext context) {
    final items = _featuredItems;
    return LayoutBuilder(
      builder: (context, constraints) {
        final index = items.isEmpty ? 0 : _index % items.length;
        final item = items.isEmpty ? null : items[index];
        final hasImage =
            item != null &&
            (item.backdropImageTag != null ||
                item.primaryImageTag != null ||
                item.parentBackdropImageTag != null);
        final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
        final viewportHeight = MediaQuery.sizeOf(context).height;
        final ratioHeight = hasImage
            ? HomeHero.heightFor(
                constraints.maxWidth,
                viewportHeight: viewportHeight,
              )
            : 0.0;
        final textFloor =
            (HomeHero.showsOverview(
                      constraints.maxWidth,
                      viewportHeight: viewportHeight,
                    )
                    ? 280
                    : 200) *
                scale +
            widget.topOverlap +
            64;
        final preferred = math.max(ratioHeight, textFloor);
        final cap =
            viewportHeight -
            MediaShelf.heroClearanceFor(context, constraints.maxWidth);
        final height = cap >= textFloor ? math.min(preferred, cap) : preferred;
        if (items.isEmpty) {
          if (!_loading) {
            return const SizedBox.shrink();
          }
          return SkeletonBlock(
            width: double.infinity,
            height: height,
            borderRadius: BorderRadius.zero,
          );
        }
        final featured = item!;
        return SizedBox(
          height: height,
          width: double.infinity,
          child: Stack(
            fit: StackFit.expand,
            children: [
              AnimatedSwitcher(
                duration: AppMotion.durationOf(context, AppMotion.slow),
                child: KeyedSubtree(
                  key: ValueKey(featured.id),
                  child: ContentTheme(
                    item: featured,
                    preferBackdrop: true,
                    fillSurface: false,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        BackdropScrim(
                          topBandHeight: math.max(
                            AppScrim.topBandHeight,
                            widget.topOverlap + HomeHero.topBandFade,
                          ),
                          backdrop: !hasImage
                              ? const SizedBox.expand()
                              : MediaImage(
                                  item: featured,
                                  height: height,
                                  preferBackdrop: true,
                                  maxWidth: mediaBackdropRequestWidth(
                                    layoutWidth: constraints.maxWidth,
                                    devicePixelRatio:
                                        MediaQuery.devicePixelRatioOf(context),
                                  ),
                                ),
                        ),
                        Padding(
                          padding: EdgeInsets.fromLTRB(
                            AppSpacing.page,
                            math.max(AppSpacing.xl, widget.topOverlap),
                            AppSpacing.page,
                            items.length > 1 ? 64 : AppSpacing.xl,
                          ),
                          child: _HeroContent(
                            item: featured,
                            width: constraints.maxWidth,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (items.length > 1) ...[
                Positioned(
                  left: AppSpacing.sm,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: ScrimIconButton(
                      key: CatalogKeys.heroPrev,
                      tooltip: AppLocalizations.of(context).scrollLeft,
                      icon: const Icon(Icons.chevron_left),
                      size: ScrimIconButtonSize.large,
                      onPressed: () => _go(-1),
                    ),
                  ),
                ),
                Positioned(
                  right: AppSpacing.sm,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: ScrimIconButton(
                      key: CatalogKeys.heroNext,
                      tooltip: AppLocalizations.of(context).scrollRight,
                      icon: const Icon(Icons.chevron_right),
                      size: ScrimIconButtonSize.large,
                      onPressed: () => _go(1),
                    ),
                  ),
                ),
                Positioned(
                  left: AppSpacing.page,
                  bottom: AppSpacing.xs,
                  child: _HeroIndicators(
                    key: Key('catalog-hero-index-$index'),
                    count: items.length,
                    index: index,
                    onSelect: _goTo,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _HeroIndicators extends StatelessWidget {
  const _HeroIndicators({
    super.key,
    required this.count,
    required this.index,
    required this.onSelect,
  });

  final int count;
  final int index;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const inactiveAlpha = 0.35;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < count; i++)
          SizedBox(
            width: 24,
            height: 32,
            child: IconButton(
              key: CatalogKeys.heroDot(i),
              tooltip: '${i + 1} / $count',
              isSelected: i == index,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 24, height: 32),
              onPressed: () => onSelect(i),
              icon: Center(
                child: AnimatedContainer(
                  duration: AppMotion.durationOf(context, AppMotion.fast),
                  curve: AppMotion.standard,
                  width: i == index ? 18 : 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: scheme.onSurface.withValues(
                      alpha: i == index ? 1.0 : inactiveAlpha,
                    ),
                    borderRadius: BorderRadius.circular(AppRadii.sm / 2),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _HeroContent extends StatelessWidget {
  const _HeroContent({required this.item, required this.width});

  final EmbyItem item;
  final double width;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final compact = width < AppBreakpoints.compact;
    final titleStyle = compact
        ? theme.textTheme.headlineLarge
        : theme.textTheme.displayMedium;
    final title = item.isEpisode && (item.seriesName?.isNotEmpty ?? false)
        ? item.seriesName!
        : item.name;
    // Episode names often contain release-group/codec filenames. The series
    // title is already the hero title; keep only the useful episode code here.
    final episodeLine = item.isEpisode ? seasonEpisodeCode(item) ?? '' : '';
    final meta = <String>[
      if (!item.isEpisode &&
          item.productionYear != null &&
          item.productionYear! > 0)
        '${item.productionYear}',
      ?runtimeLabel(l10n, item),
      if (item.canResume)
        l10n.playbackProgress((item.playbackProgress * 100).round()),
    ];
    final textBlockWidth = HomeHero.textBlockWidthFor(width);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Spacer(),
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: textBlockWidth),
          child: Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: titleStyle?.copyWith(
              color: theme.colorScheme.onSurface,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        if (episodeLine.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(
            episodeLine,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.86),
            ),
          ),
        ],
        if (meta.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(
            meta.join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.78),
            ),
          ),
        ],
        if (item.overview != null &&
            item.overview!.trim().isNotEmpty &&
            HomeHero.showsOverview(
              width,
              viewportHeight: MediaQuery.sizeOf(context).height,
            )) ...[
          const SizedBox(height: AppSpacing.sm),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: textBlockWidth),
            child: Text(
              item.overview!,
              maxLines: compact ? 2 : 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.86),
              ),
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.lg),
        OutlinedButton(
          onPressed: () => context.push(AppRoutes.item(item.id)),
          style: OutlinedButton.styleFrom(
            foregroundColor: theme.colorScheme.onSurface,
            side: BorderSide(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.42),
            ),
            minimumSize: const Size(0, 48),
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.sm,
            ),
          ),
          child: Text(l10n.details),
        ),
      ],
    );
  }
}
