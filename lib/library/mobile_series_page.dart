import 'package:flutter/material.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_chrome.dart';
import 'package:rillight/app/mobile_motion.dart';
import 'package:rillight/app/mobile_widgets.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/widgets/skeleton.dart';
import 'package:rillight/auth/failure_message.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/library/detached_scroll.dart';
import 'package:rillight/library/detail_extras.dart';
import 'package:rillight/library/episode_detail_sections.dart';
import 'package:rillight/library/episode_list.dart';
import 'package:rillight/library/item_format.dart';
import 'package:rillight/media_image/media_image.dart';

/// 标题下的一行事实：年份、时长、评分、季数。
///
/// [highlight] 带星标强调评分；[badge] 画成描边小标签（分辨率、HDR、声道），
/// 与普通文字之间不再用圆点分隔。
class PhoneMetaEntry {
  const PhoneMetaEntry(
    this.label, {
    this.highlight = false,
    this.badge = false,
    this.onTap,
  });

  final String label;
  final bool highlight;
  final bool badge;
  final VoidCallback? onTap;
}

/// 头图、标题、元数据与播放操作各占一层，窄屏和大字体均可自然增高。
///
/// 头图形状与横幅不符时（从竖版海报点进来、条目只有海报）用同一张图的
/// 模糊放大铺底，海报完整居中，不再是一条窄图夹在两块色块之间。
class PhoneItemBanner extends StatelessWidget {
  const PhoneItemBanner({
    super.key,
    required this.item,
    required this.title,
    this.meta = const [],
    this.actions,
    this.onTitleTap,
    this.titleHint,
    this.preferBackdrop = true,
    this.maxWidth = PhoneMotion.pageRequestWidth,
    this.showCaption = true,
    this.maxImageHeight,
  });

  static const bannerKey = Key('phone-detail-banner');
  static const metaKey = Key('phone-detail-meta');

  final EmbyItem item;
  final String title;
  final List<PhoneMetaEntry> meta;
  final Widget? actions;

  /// 单集标题进所属剧集。非空时标题上方带剧集名和箭头。
  final VoidCallback? onTitleTap;
  final String? titleHint;
  final bool preferBackdrop;
  final int maxWidth;

  /// 为 false 时只画头图。加载中的标题和主操作由调用方放在头图下面。
  final bool showCaption;

  /// 剧集把季列表和分集当作主体时，压低背图，避免先滑过一大块画面。
  final double? maxImageHeight;

  /// 背图高度：16:9 全宽，横屏/矮窗封顶半屏，保证标题与主操作首屏可达。
  static double imageHeightOf(BuildContext context, {double? cap}) {
    final size = MediaQuery.sizeOf(context);
    final byWidth = size.width * 9 / 16;
    final heightCap = size.height * 0.5;
    var height = byWidth < heightCap ? byWidth : heightCap;
    if (cap != null && height > cap) height = cap;
    return height;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final imageHeight = imageHeightOf(context, cap: maxImageHeight);
    return Column(
      key: bannerKey,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: imageHeight,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(color: theme.colorScheme.surfaceContainerHigh),
              RepaintBoundary(
                child: PhoneMotion.sharedImage(
                  itemId: item.id,
                  preferBackdrop: preferBackdrop,
                  child: MediaImage(
                    item: item,
                    contributesToTheme: true,
                    preferBackdrop: preferBackdrop,
                    maxWidth: maxWidth,
                    blurFill: true,
                  ),
                ),
              ),
              // 顶带:保护透明顶栏与返回钮,向下溶到透明。
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: const [0, .42],
                    colors: [
                      Colors.black.withValues(
                        alpha: AppScrim.of(context, AppScrim.top),
                      ),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: imageHeight * 0.42,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        theme.colorScheme.surface.withValues(alpha: 0),
                        theme.colorScheme.surface.withValues(alpha: 0.66),
                        theme.colorScheme.surface,
                      ],
                      stops: const [0, 0.6, 1],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (showCaption)
          PhoneDetailCaption(
            title: _BannerTitle(
              title: title,
              hint: onTitleTap == null ? null : titleHint,
              onTap: onTitleTap,
            ),
            meta: meta,
            actions: actions,
          ),
      ],
    );
  }
}

/// Shared geometry for a loaded detail header and its loading placeholder.
class PhoneDetailCaption extends StatelessWidget {
  const PhoneDetailCaption({
    super.key,
    required this.title,
    this.meta = const [],
    this.actions,
    this.pendingMetadata,
  });
  final Widget title;
  final List<PhoneMetaEntry> meta;
  final Widget? actions, pendingMetadata;

  /// 标题字阶：比全局 headlineLarge 收一档，两行长标题也不压住主操作。
  static TextStyle? titleStyle(ThemeData theme) =>
      theme.textTheme.headlineLarge?.copyWith(
        color: theme.colorScheme.onSurface,
        fontSize: 26,
        fontWeight: FontWeight.w700,
        height: 1.22,
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Transform.translate(
      offset: const Offset(0, -20),
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        // 左右与分集、分区标题同取手机页面边距，整页内容落在同一条竖线上。
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.lg,
          AppSpacing.md,
          AppSpacing.xxs,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            title,
            if (meta.isNotEmpty || pendingMetadata != null) ...[
              const SizedBox(height: AppSpacing.xs),
              pendingMetadata ?? _MetaLine(entries: meta),
            ],
            if (actions != null) ...[
              const SizedBox(height: AppSpacing.md),
              actions!,
            ],
          ],
        ),
      ),
    );
  }
}

class _MetaLine extends StatelessWidget {
  const _MetaLine({required this.entries});

  final List<PhoneMetaEntry> entries;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dot = Text(
      '·',
      style: theme.textTheme.labelLarge?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
    final children = <Widget>[];
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      final previous = i > 0 ? entries[i - 1] : null;
      if (previous != null && !previous.badge && !entry.badge) {
        children.add(dot);
      }
      children.add(_MetaChip(entry: entry));
    }
    return Wrap(
      key: PhoneItemBanner.metaKey,
      spacing: AppSpacing.xs,
      runSpacing: AppSpacing.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: children,
    );
  }
}

class _BannerTitle extends StatelessWidget {
  const _BannerTitle({required this.title, this.hint, this.onTap});

  final String title;
  final String? hint;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final heading = Text(
      title,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: PhoneDetailCaption.titleStyle(theme),
    );
    final hint = this.hint;
    if (hint == null || hint.isEmpty) {
      return heading;
    }
    // 单集：所属剧集名作为标题上方的引导行，点按回到剧集页。
    final overline = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            hint,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        if (onTap != null)
          Icon(
            Icons.chevron_right_rounded,
            size: 20,
            color: theme.colorScheme.primary,
          ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (onTap == null)
          overline
        else
          InkWell(
            key: CatalogKeys.seriesLink,
            onTap: onTap,
            borderRadius: BorderRadius.circular(AppRadii.sm),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 32),
              child: Align(
                alignment: Alignment.centerLeft,
                widthFactor: 1,
                child: overline,
              ),
            ),
          ),
        const SizedBox(height: 2),
        heading,
      ],
    );
  }
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.entry});

  final PhoneMetaEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if (entry.badge) {
      return DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: scheme.onSurfaceVariant.withValues(alpha: .55),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          child: Text(
            entry.label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
              height: 1.3,
            ),
          ),
        ),
      );
    }
    final style = theme.textTheme.labelLarge?.copyWith(
      color: entry.highlight || entry.onTap != null
          ? scheme.primary
          : scheme.onSurfaceVariant,
      fontWeight: entry.highlight ? FontWeight.w700 : FontWeight.w500,
    );
    final chip = entry.highlight
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.star_rounded, size: 16, color: scheme.primary),
              const SizedBox(width: 2),
              Text(entry.label, style: style),
            ],
          )
        : Text(entry.label, style: style);
    final onTap = entry.onTap;
    if (onTap == null) {
      return chip;
    }
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadii.md),
        child: chip,
      ),
    );
  }
}

/// 流派：简介下方一行可横滑的小标签，点按进入该流派片单。
class PhoneGenreChips extends StatelessWidget {
  const PhoneGenreChips({super.key, required this.genres, this.onTap});

  static const rowKey = Key('phone-detail-genres');

  final List<String> genres;
  final ValueChanged<String>? onTap;

  @override
  Widget build(BuildContext context) {
    if (genres.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final height =
        36 * (MediaQuery.textScalerOf(context).scale(14) / 14).clamp(1.0, 2.0);
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: SizedBox(
        height: height,
        child: DetachedHorizontalScroll(
          builder: (controller) => ListView.separated(
            key: rowKey,
            controller: controller,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            itemCount: genres.length,
            separatorBuilder: (context, index) =>
                const SizedBox(width: AppSpacing.xs),
            itemBuilder: (context, index) {
              final genre = genres[index];
              final tap = onTap;
              return Material(
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(AppRadii.sm),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: tap == null ? null : () => tap(genre),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Center(
                      widthFactor: 1,
                      child: Text(
                        genre,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: scheme.onSurface,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// 季切换：单选标签。选中项实心主色，不画多选筛选那种勾。
class PhoneSeasonTab extends StatelessWidget {
  const PhoneSeasonTab({
    super.key,
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? scheme.onSurface : scheme.surfaceContainerHigh,
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 56, minHeight: 40),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                widthFactor: 1,
                child: Text(
                  label,
                  maxLines: 1,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: selected ? scheme.surface : scheme.onSurface,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 剧集页正文：简介、季切换与本季概况、分集，再往下是相册、演职员与信息。
class MobileSeriesPage extends StatelessWidget {
  const MobileSeriesPage({
    super.key,
    required this.item,
    required this.seasons,
    required this.seasonId,
    required this.episodes,
    required this.episodesLoading,
    required this.episodeError,
    required this.hasMore,
    required this.playTargetId,
    this.episodeTotal,
    this.focusEpisodeId,
    this.scrollCoordinator,
    required this.similar,
    this.onPickEpisode,
    this.onOpenGenre,
    required this.onSelectSeason,
    required this.onOpenEpisode,
    required this.onRetryEpisodes,
    required this.onLoadMore,
    required this.onOpenItem,
    required this.onOpenSimilar,
  });

  static const seasonSummaryKey = Key('phone-season-summary');

  final EmbyItem item;
  final List<EmbyItem> seasons;
  final String? seasonId;
  final List<EmbyItem> episodes;
  final bool episodesLoading;
  final EmbyException? episodeError;
  final bool hasMore;
  final String? playTargetId;

  /// 本季集数（服务器总数）。缺省时用季条目自带的 ChildCount。
  final int? episodeTotal;
  final String? focusEpisodeId;
  final EpisodeScrollCoordinator? scrollCoordinator;
  final List<EmbyItem> similar;
  final VoidCallback? onPickEpisode;
  final ValueChanged<String>? onOpenGenre;
  final ValueChanged<String> onSelectSeason;
  final ValueChanged<String> onOpenEpisode;
  final VoidCallback? onRetryEpisodes;
  final VoidCallback? onLoadMore;
  final ValueChanged<String> onOpenItem;
  final VoidCallback? onOpenSimilar;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final child in _content(context))
          if (child is _EpisodeListSlot)
            for (var index = 0; index < episodes.length; index++)
              _episodeWidget(episodes[index], index)
          else
            child,
      ],
    );
  }

  /// Embeds long episode lists in the parent's viewport, so offscreen rows are
  /// never built merely to determine the detail page's total height.
  List<Widget> buildSlivers(BuildContext context) {
    final content = _content(context);
    final split = content.indexWhere((child) => child is _EpisodeListSlot);
    scrollCoordinator?.locate(episodes, focusEpisodeId);
    return [
      SliverList.list(children: content.sublist(0, split)),
      SliverList.builder(
        itemCount: episodes.length,
        itemBuilder: (context, index) => _episodeWidget(episodes[index], index),
      ),
      SliverList.list(children: content.sublist(split + 1)),
    ];
  }

  Widget _episodeWidget(EmbyItem episode, int index) => _RevealEpisode(
    key: ValueKey('episode-${episode.id}'),
    index: index,
    scrollCoordinator: scrollCoordinator,
    reveal: episode.id == focusEpisodeId,
    child: _EpisodeRow(
      episode: episode,
      current: episode.id == (focusEpisodeId ?? playTargetId),
      onTap: () => onOpenEpisode(episode.id),
    ),
  );

  List<Widget> _content(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final showSeasons = seasons.length > 1;
    final selected = seasons.where((s) => s.id == seasonId).firstOrNull;
    final total = episodeTotal != null && episodeTotal! > 0
        ? episodeTotal
        : selected?.childCount;
    // 只有整季都已载入时才数已看集，分页中途数出来的比例是错的。
    final watched = !hasMore && total != null && episodes.length >= total
        ? episodes.where((episode) => episode.userData.played).length
        : null;
    final showHeader =
        seasons.isNotEmpty || episodes.isNotEmpty || episodesLoading;
    return [
      if (plainOverview(item.overview) != null)
        EpisodeOverviewSection(
          overview: item.overview,
          compact: true,
          collapsedLines: 3,
        ),
      PhoneGenreChips(genres: item.genres, onTap: onOpenGenre),
      if (showHeader)
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.xl,
            AppSpacing.xs,
            AppSpacing.xs,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  l.detailEpisodesHeader,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (onPickEpisode != null && (total ?? episodes.length) > 1)
                TextButton.icon(
                  key: CatalogKeys.locateEpisode,
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: onPickEpisode,
                  icon: const Icon(Icons.grid_view_rounded, size: 18),
                  label: Text(l.pickEpisode),
                ),
            ],
          ),
        ),
      if (showSeasons)
        SizedBox(
          height:
              40 *
              (MediaQuery.textScalerOf(context).scale(14) / 14).clamp(1, 2),
          child: DetachedHorizontalScroll(
            builder: (controller) => ListView.separated(
              controller: controller,
              key: const Key('phone-season-list'),
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              itemCount: seasons.length,
              separatorBuilder: (context, index) =>
                  const SizedBox(width: AppSpacing.xs),
              itemBuilder: (context, index) {
                final season = seasons[index];
                return PhoneSeasonTab(
                  key: CatalogKeys.season(season.id),
                  label: season.name,
                  selected: season.id == seasonId,
                  onPressed: () => onSelectSeason(season.id),
                );
              },
            ),
          ),
        ),
      if (selected != null)
        _SeasonSummary(
          key: seasonSummaryKey,
          season: selected,
          // 多季时名字已在标签上，概况里不再重复。
          showName: !showSeasons,
          episodeTotal: total,
          watched: watched,
        ),
      if (episodesLoading && episodes.isEmpty)
        LayoutBuilder(
          builder: (context, constraints) {
            // 三块固定 144 的 Row 在 360dp 上会横向溢出。卡片不超过内容宽，多的横滑。
            final inner = constraints.maxWidth - AppSpacing.md * 2;
            final cardWidth = inner >= 144
                ? 144.0
                : inner > 0
                ? inner
                : 0.0;
            final cardHeight = cardWidth * 9 / 16;
            return Padding(
              padding: const EdgeInsets.only(top: AppSpacing.sm),
              child: SizedBox(
                height: cardHeight,
                child: DetachedHorizontalScroll(
                  builder: (controller) => ListView.separated(
                    controller: controller,
                    key: const Key('phone-season-episode-placeholder'),
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.md,
                    ),
                    itemCount: cardWidth <= 0 ? 0 : 3,
                    separatorBuilder: (context, index) =>
                        const SizedBox(width: AppSpacing.sm),
                    itemBuilder: (context, index) =>
                        SkeletonBlock(width: cardWidth, height: cardHeight),
                  ),
                ),
              ),
            );
          },
        ),
      if (episodeError != null && onRetryEpisodes != null)
        MobileFailureState(
          message: embyFailureMessage(l, episodeError!),
          onRetry: onRetryEpisodes!,
        ),
      if (!episodesLoading &&
          episodeError == null &&
          episodes.isEmpty &&
          seasons.isNotEmpty)
        Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Text(l.mobileEmpty),
        ),
      if (episodes.isNotEmpty) const SizedBox(height: AppSpacing.xs),
      const _EpisodeListSlot(),
      if (hasMore && onLoadMore != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.xs,
            AppSpacing.md,
            0,
          ),
          child: FilledButton.tonal(
            style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: episodesLoading ? null : onLoadMore,
            child: Text(l.mobileLoadMore),
          ),
        ),
      DetailAlbumStrip(item: item),
      EpisodePeopleSection(people: item.people),
      EpisodeMetadataSection(item: item),
      DetailExternalLinks(links: item.externalUrls, title: item.name),
      if (similar.isNotEmpty)
        _SimilarRow(
          items: similar,
          onOpenItem: onOpenItem,
          onOpenSimilar: onOpenSimilar,
        ),
      const SizedBox(height: AppSpacing.lg),
    ];
  }
}

/// 本季概况（季详情）：季海报、名称、年份与集数、已看计数和本季简介。
class _SeasonSummary extends StatefulWidget {
  const _SeasonSummary({
    super.key,
    required this.season,
    required this.showName,
    required this.episodeTotal,
    required this.watched,
  });

  final EmbyItem season;
  final bool showName;
  final int? episodeTotal;
  final int? watched;

  @override
  State<_SeasonSummary> createState() => _SeasonSummaryState();
}

class _SeasonSummaryState extends State<_SeasonSummary> {
  bool _expanded = false;

  @override
  void didUpdateWidget(covariant _SeasonSummary oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.season.id != widget.season.id) _expanded = false;
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final season = widget.season;
    final year = season.productionYear ?? season.premiereDate?.toLocal().year;
    final total = widget.episodeTotal;
    final watched = widget.watched;
    final overview = plainOverview(season.overview);
    final facts = <String>[
      if (year != null) '$year',
      if (total != null && total > 0) l.episodeCount(total),
    ];
    if (!widget.showName && facts.isEmpty && overview == null) {
      return const SizedBox.shrink();
    }
    final muted = theme.textTheme.labelLarge?.copyWith(
      color: scheme.onSurfaceVariant,
      fontWeight: FontWeight.w500,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.sm,
        AppSpacing.md,
        0,
      ),
      child: Material(
        color: scheme.surfaceContainerHigh.withValues(alpha: .55),
        borderRadius: BorderRadius.circular(AppRadii.lg),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: overview == null
              ? null
              : () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.sm),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadii.sm),
                  child: SizedBox(
                    width: 56,
                    height: 84,
                    child: MediaImage(
                      item: season,
                      width: 56,
                      height: 84,
                      fit: BoxFit.cover,
                      maxWidth: 200,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (widget.showName)
                        Text(
                          season.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      if (facts.isNotEmpty)
                        Text(facts.join(' · '), style: muted),
                      if (watched != null && total != null && total > 0) ...[
                        if (facts.isNotEmpty)
                          const SizedBox(height: AppSpacing.xxs),
                        Text(
                          l.seasonWatchedCount(watched, total),
                          style: muted,
                        ),
                      ],
                      if (overview != null) ...[
                        const SizedBox(height: AppSpacing.xs),
                        AnimatedSize(
                          duration: AppMotion.durationOf(context),
                          curve: AppMotion.standard,
                          alignment: Alignment.topCenter,
                          child: Text(
                            overview,
                            maxLines: _expanded ? null : 3,
                            overflow: _expanded
                                ? TextOverflow.visible
                                : TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                              height: 1.45,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EpisodeListSlot extends StatelessWidget {
  const _EpisodeListSlot();

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// Finds a distant deep-linked episode without materializing every preceding
/// row. Visible row geometry refines the estimate until the target is built;
/// _RevealEpisode then performs the final alignment.
class EpisodeScrollCoordinator {
  EpisodeScrollCoordinator(this.scroll);

  final ScrollController scroll;
  final Map<int, BuildContext> _mountedRows = {};
  String? _request;
  int _generation = 0;
  bool _disposed = false;

  void locate(List<EmbyItem> episodes, String? episodeId) {
    if (_disposed || episodeId == null || episodeId.isEmpty) return;
    final target = episodes.indexWhere((episode) => episode.id == episodeId);
    if (target < 0) return;
    final request = '$episodeId:$target:${episodes.length}';
    if (_request == request) return;
    _request = request;
    final generation = ++_generation;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _seek(target, generation, 0);
    });
  }

  void register(int index, BuildContext context) {
    _mountedRows[index] = context;
  }

  void unregister(int index, BuildContext context) {
    if (identical(_mountedRows[index], context)) _mountedRows.remove(index);
  }

  void _seek(int target, int generation, int attempt) {
    if (_disposed || generation != _generation || !scroll.hasClients) return;
    if (_mountedRows[target]?.mounted == true) return;
    if (attempt >= 24) return;
    final rows = _mountedRows.entries.where((entry) => entry.value.mounted);
    if (rows.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _seek(target, generation, attempt + 1);
      });
      return;
    }
    final indices = rows.map((entry) => entry.key).toList()..sort();
    final nearest = target > indices.last ? indices.last : indices.first;
    final heights = rows
        .map((entry) => entry.value.findRenderObject())
        .whereType<RenderBox>()
        .where((box) => box.hasSize)
        .map((box) => box.size.height)
        .where((height) => height > 0)
        .toList();
    final rowHeight = heights.isEmpty
        ? 120.0
        : (heights.reduce((a, b) => a + b) / heights.length).clamp(80.0, 240.0);
    final position = scroll.position;
    final next = (position.pixels + (target - nearest) * rowHeight).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (next != position.pixels) position.jumpTo(next);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _seek(target, generation, attempt + 1);
    });
  }

  void dispose() {
    _disposed = true;
    _generation++;
    _mountedRows.clear();
  }
}

class _RevealEpisode extends StatefulWidget {
  const _RevealEpisode({
    super.key,
    required this.index,
    required this.scrollCoordinator,
    required this.reveal,
    required this.child,
  });

  final int index;
  final EpisodeScrollCoordinator? scrollCoordinator;
  final bool reveal;
  final Widget child;

  @override
  State<_RevealEpisode> createState() => _RevealEpisodeState();
}

class _RevealEpisodeState extends State<_RevealEpisode> {
  @override
  void initState() {
    super.initState();
    widget.scrollCoordinator?.register(widget.index, context);
    if (widget.reveal) _reveal();
  }

  void _reveal() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Scrollable.ensureVisible(context, alignment: 0.2);
    });
  }

  @override
  void didUpdateWidget(covariant _RevealEpisode oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index ||
        !identical(oldWidget.scrollCoordinator, widget.scrollCoordinator)) {
      oldWidget.scrollCoordinator?.unregister(oldWidget.index, context);
      widget.scrollCoordinator?.register(widget.index, context);
    }
    if (!oldWidget.reveal && widget.reveal) _reveal();
  }

  @override
  void dispose() {
    widget.scrollCoordinator?.unregister(widget.index, context);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// 分集行：左侧 16:9 剧照，右侧标题与「编号 · 时长 · 播出日期」，简介通栏排在下面。
///
/// 同一状态只表达一次：已看只由剧照上的勾和压暗表示；续播只由剧照底部进度条
/// 表示；当前集只用浅底色、主色标题和剧照中央播放钮标示。
class _EpisodeRow extends StatelessWidget {
  const _EpisodeRow({
    required this.episode,
    required this.current,
    required this.onTap,
  });

  final EmbyItem episode;
  final bool current;
  final VoidCallback onTap;

  static const double _thumbWidth = 148;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final overview = plainOverview(episode.overview);
    final runtime = runtimeLabel(l, episode);
    final code = seasonEpisodeCode(episode);
    final progress = episode.playbackProgress;
    final played = episode.userData.played;
    final premiere = episode.premiereDate;
    final facts = <String>[
      ?code,
      ?runtime,
      if (premiere != null) formatDateYmd(premiere),
    ];
    final title = Text(
      episode.name,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.titleSmall?.copyWith(
        fontWeight: current ? FontWeight.w700 : FontWeight.w600,
        color: current
            ? scheme.primary
            : played
            ? scheme.onSurfaceVariant
            : scheme.onSurface,
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.xs,
        AppSpacing.xxs,
        AppSpacing.xs,
        AppSpacing.xxs,
      ),
      child: Material(
        color: current
            ? scheme.surfaceContainerHigh.withValues(alpha: .7)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(AppRadii.lg),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: CatalogKeys.episode(episode.id),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.xs),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    _EpisodeThumb(
                      episode: episode,
                      width: _thumbWidth,
                      current: current,
                      played: played,
                      progress: progress,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          title,
                          if (facts.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              facts.join(' · '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: scheme.onSurfaceVariant,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
                // 该集简介:EmbyItem.overview 缺失(无字段/纯空白/HTML 残迹)
                // 时整行隐藏,卡片优雅降级为剧照 + 标题。
                if (overview != null)
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.xs),
                    child: Text(
                      overview,
                      key: const Key('phone-episode-overview'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        height: 1.45,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EpisodeThumb extends StatelessWidget {
  const _EpisodeThumb({
    required this.episode,
    required this.width,
    required this.current,
    required this.played,
    required this.progress,
  });

  final EmbyItem episode;
  final double width;
  final bool current;
  final bool played;
  final double progress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final showProgress = progress > 0 && !played;
    return SizedBox(
      width: width,
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadii.md),
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(color: scheme.surfaceContainerHigh),
              MediaImage(
                item: episode,
                preferThumb: true,
                fit: BoxFit.cover,
                maxWidth: 480,
              ),
              if (played && !current)
                ColoredBox(color: Colors.black.withValues(alpha: .38)),
              if (showProgress)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Semantics(
                    container: true,
                    label: AppLocalizations.of(
                      context,
                    ).playbackProgress((progress * 100).round()),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 4,
                      color: scheme.primary,
                      backgroundColor: Colors.black.withValues(alpha: .45),
                    ),
                  ),
                ),
              if (played)
                const Positioned(
                  right: 6,
                  top: 6,
                  child: EpisodeWatchedBadge(
                    iconKey: Key('phone-episode-watched'),
                  ),
                ),
              if (current)
                Center(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: .42),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Colors.white.withValues(alpha: .85),
                        width: 1.5,
                      ),
                    ),
                    child: const Padding(
                      padding: EdgeInsets.all(6),
                      child: Icon(
                        Icons.play_arrow_rounded,
                        key: Key('phone-episode-current'),
                        color: Colors.white,
                        size: 24,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SimilarRow extends StatelessWidget {
  const _SimilarRow({
    required this.items,
    required this.onOpenItem,
    required this.onOpenSimilar,
  });

  final List<EmbyItem> items;
  final ValueChanged<String> onOpenItem;
  final VoidCallback? onOpenSimilar;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          // 分区间距统一 xl=24(ADR-5)。
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.xl,
            AppSpacing.xs,
            AppSpacing.sm,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  l.similarRow,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              TextButton(
                key: CatalogKeys.shelfMore(CatalogKeys.shelfSimilar),
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: onOpenSimilar,
                child: Text(l.more),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 128 * 1.5 + phonePosterCardLabelExtent(context),
          child: DetachedHorizontalScroll(
            builder: (controller) => ListView.separated(
              controller: controller,
              key: CatalogKeys.similarRow,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              itemCount: items.length,
              separatorBuilder: (context, index) =>
                  const SizedBox(width: AppSpacing.sm),
              itemBuilder: (context, index) {
                final item = items[index];
                return SizedBox(
                  width: 128,
                  child: PhonePosterCard(
                    item: item,
                    pressKey: CatalogKeys.item(item.id),
                    imageMaxWidth: 320,
                    onTap: () => onOpenItem(item.id),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}
