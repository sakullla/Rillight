import 'package:rillight/app/ui/app_icons.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_chrome.dart';
import 'package:rillight/app/mobile_motion.dart';
import 'package:rillight/app/mobile_widgets.dart';
import 'package:rillight/app/widgets/skeleton.dart';
import 'package:rillight/auth/failure_message.dart';
import 'package:rillight/media_server/errors.dart';
import 'package:rillight/media_server/models.dart';
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

/// 详情头部：整宽背景画面出血到状态栏，电影/剧集的竖版海报以卡片
/// 压在背景下缘，标题与元数据排在海报右侧；主操作在头部下方通栏。
///
/// 背景一律取横版画面（背景图、剧照、单集剧照）。条目确实没有横版画面时，
/// 才用海报大半径模糊做氛围底，海报本身完整地留在卡片里，不再出现
/// 「一条窄海报夹在两块模糊色块之间」。
///
/// 从海报点进来时，共享图过渡落在海报卡上；从横版卡片点进来时落在背景上。
/// 两种情况都只由落点那一张图取色，加载完成后不换图。
class PhoneItemBanner extends StatelessWidget {
  const PhoneItemBanner({
    super.key,
    required this.item,
    required this.title,
    this.titleWidget,
    this.meta = const [],
    this.pendingMeta,
    this.actions,
    this.onTitleTap,
    this.titleHint,
    this.preferBackdrop = true,
    this.imagePrefersBackdrop,
    this.maxWidth = PhoneMotion.pageRequestWidth,
    this.posterItem,
  });

  static const bannerKey = Key('phone-detail-banner');
  static const metaKey = Key('phone-detail-meta');
  static const posterKey = Key('phone-detail-poster');
  static const backdropKey = Key('phone-detail-backdrop');

  /// 承接共享图过渡的那一张（海报卡或背景），参数与来源卡片一致。
  static const handoffImageKey = Key('phone-detail-handoff-image');

  final MediaItem item;

  /// 海报卡显示的条目。剧集切季时背景跟着季走，海报卡仍是剧集本身，
  /// 失效或缺失的季海报不会被请求。缺省为 [item]。
  final MediaItem? posterItem;
  final String title;

  /// 加载中的标题占位；非空时替代 [title]。
  final Widget? titleWidget;
  final List<PhoneMetaEntry> meta;
  final Widget? pendingMeta;
  final Widget? actions;

  /// 单集标题进所属剧集。非空时标题上方带剧集名和箭头。
  final VoidCallback? onTitleTap;
  final String? titleHint;

  /// 来源卡片是横版（true）还是海报（false）。决定海报卡和共享图落点，进入后保持不变。
  final bool preferBackdrop;

  /// 大图实际请求的候选。缺省同 [preferBackdrop]，因此从海报或横卡进入时
  /// 背景就是点中的那一张。切换季时可以改成该季的横图，旧画面留到新图第一帧。
  final bool? imagePrefersBackdrop;
  final int maxWidth;

  bool get _imagePrefersBackdrop => imagePrefersBackdrop ?? preferBackdrop;

  /// 背景高度：约 3:2 加状态栏，横屏/矮窗封顶半屏多一点，标题与主操作首屏可达。
  static double imageHeightOf(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    // viewPadding 只含状态栏；padding 在透明顶栏下还加了顶栏高度。
    final top = MediaQuery.viewPaddingOf(context).top;
    final byWidth = size.width * .68 + top;
    final cap = size.height * 0.52;
    // 取整：半像素的画面下缘会和页面底色叠出一条细线。
    return (byWidth < cap ? byWidth : cap).floorToDouble();
  }

  /// 海报卡宽：窄屏收一档，给标题留出两行半汉字的宽度。
  static double posterWidthOf(BuildContext context) =>
      MediaQuery.sizeOf(context).width < 380 ? 104 : 118;

  /// 单集默认不画海报卡（背景就是本集剧照）；从海报点进来的单集仍保留，
  /// 共享图才有落点。
  bool get _showPoster => !item.isEpisode || !preferBackdrop;

  /// 是否有可铺满横幅的横版画面。单集的主图本身就是 16:9 剧照。
  static bool hasLandscapeArt(MediaItem item) =>
      item.isEpisode ||
      (item.backdropImageTag?.isNotEmpty ?? false) ||
      (item.parentBackdropImageTag?.isNotEmpty ?? false) ||
      (item.thumbImageTag?.isNotEmpty ?? false);

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final page = theme.scaffoldBackgroundColor;
    final imageHeight = imageHeightOf(context);
    final showPoster = _showPoster;
    final posterWidth = posterWidthOf(context);
    final posterHeight = posterWidth * 1.5;
    // 海报卡上半截压在画面上，标题块与海报底边对齐。
    final rise = showPoster ? posterHeight * .62 : AppSpacing.xxl;
    final landscape = hasLandscapeArt(item);
    final sameAsEntry = _imagePrefersBackdrop == preferBackdrop;
    // 和点进来的那一张用同一请求宽度，内存里已有的画面才能在第一帧画上。
    // 季画面用页面宽度；旧图由 [MediaImage.retainVisibleFrame] 留到新帧。
    final imageMaxWidth = sameAsEntry ? maxWidth : PhoneMotion.pageRequestWidth;
    Widget backdrop = MediaImage(
      key: preferBackdrop ? handoffImageKey : backdropKey,
      item: item,
      contributesToTheme: preferBackdrop && sameAsEntry,
      preferBackdrop: _imagePrefersBackdrop,
      smartCrop: landscape && _imagePrefersBackdrop,
      fit: BoxFit.cover,
      maxWidth: imageMaxWidth,
      retainVisibleFrame: true,
    );
    if (preferBackdrop) {
      backdrop = PhoneMotion.sharedImage(
        itemId: item.id,
        preferBackdrop: true,
        child: backdrop,
      );
    }

    final titleBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        titleWidget ??
            _BannerTitle(
              title: title,
              hint: onTitleTap == null ? null : titleHint,
              onTap: onTitleTap,
              compact: showPoster,
            ),
        if (meta.isNotEmpty || pendingMeta != null) ...[
          const SizedBox(height: AppSpacing.xs),
          pendingMeta ?? _MetaLine(entries: meta),
        ],
      ],
    );

    return Column(
      key: bannerKey,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              height: imageHeight,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  RepaintBoundary(child: ClipRect(child: backdrop)),
                  // 顶带:保护透明顶栏与返回钮,向下溶到透明。
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        stops: const [0, .38],
                        colors: [
                          const Color(0xff000000).withValues(
                            alpha: AppScrim.of(context, AppScrim.top),
                          ),
                          const Color(0x00000000),
                        ],
                      ),
                    ),
                  ),
                  // 底带:画面下缘溶进页面底色，海报卡与标题压在上面也读得清。
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        stops: const [.36, .74, .97],
                        colors: [
                          page.withValues(alpha: 0),
                          page.withValues(alpha: .78),
                          page,
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (showPoster) ...[
              // 海报行以底边定位：标题或元数据换行变高时向上长进画面下缘，
              // 主操作的位置不随标题长短浮动。
              SizedBox(height: imageHeight - rise + posterHeight),
              Positioned(
                left: AppSpacing.md,
                right: AppSpacing.md,
                bottom: 0,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    _PosterCard(
                      item: posterItem ?? item,
                      width: posterWidth,
                      handoff: !preferBackdrop,
                      maxWidth: preferBackdrop
                          ? PhoneMotion.posterRequestWidth
                          : maxWidth,
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: titleBlock,
                      ),
                    ),
                  ],
                ),
              ),
            ] else
              Padding(
                padding: EdgeInsets.fromLTRB(
                  AppSpacing.md,
                  imageHeight - rise,
                  AppSpacing.md,
                  0,
                ),
                child: titleBlock,
              ),
          ],
        ),
        if (actions != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.md,
              AppSpacing.md,
              AppSpacing.xs,
            ),
            child: actions,
          ),
      ],
    );
  }
}

/// 头部海报卡：圆角、细描边与投影，从海报点进来时承接共享图。
class _PosterCard extends StatelessWidget {
  const _PosterCard({
    required this.item,
    required this.width,
    required this.handoff,
    required this.maxWidth,
  });

  final MediaItem item;
  final double width;
  final bool handoff;
  final int maxWidth;

  @override
  Widget build(BuildContext context) {
    final scheme = AppUiTheme.of(context).colorScheme;
    final light = scheme.brightness == Brightness.light;
    final height = width * 1.5;
    Widget image = MediaImage(
      key: handoff ? PhoneItemBanner.handoffImageKey : null,
      item: item,
      contributesToTheme: handoff,
      width: width,
      height: height,
      fit: BoxFit.cover,
      maxWidth: maxWidth,
      retainVisibleFrame: true,
    );
    if (handoff) {
      image = PhoneMotion.sharedImage(
        itemId: item.id,
        preferBackdrop: false,
        child: image,
      );
    }
    return DecoratedBox(
      key: PhoneItemBanner.posterKey,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadii.md),
        boxShadow: [
          BoxShadow(
            color: const Color(0xff000000).withValues(alpha: light ? .22 : .55),
            blurRadius: light ? 18 : 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadii.md),
        child: SizedBox(
          width: width,
          height: height,
          child: Stack(
            fit: StackFit.expand,
            children: [
              image,
              IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(AppRadii.md),
                    border: Border.all(
                      color: light
                          ? const Color(0xff000000).withValues(alpha: .08)
                          : const Color(0xffffffff).withValues(alpha: .12),
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

/// 头部标题字阶：比全局 headlineLarge 收一档；海报右侧再收一档，
/// 两行长标题也不把海报卡顶高。
TextStyle? phoneDetailTitleStyle(
  AppUiThemeData theme, {
  bool compact = false,
}) => theme.textTheme.headlineLarge?.copyWith(
  color: theme.colorScheme.onSurface,
  fontSize: compact ? 23 : 28,
  fontWeight: FontWeight.w800,
  height: 1.2,
  letterSpacing: -0.3,
);

class _MetaLine extends StatelessWidget {
  const _MetaLine({required this.entries});

  final List<PhoneMetaEntry> entries;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final dot = Text(
      '·',
      style: theme.textTheme.labelLarge?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
    // 年份、时长、评分一行，用圆点隔开；画质/声道标签另起一行描边小牌。
    final facts = <Widget>[];
    final badges = <Widget>[];
    for (final entry in entries) {
      if (entry.badge) {
        badges.add(_MetaChip(entry: entry));
        continue;
      }
      if (facts.isNotEmpty) facts.add(dot);
      facts.add(_MetaChip(entry: entry));
    }
    return Column(
      key: PhoneItemBanner.metaKey,
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (facts.isNotEmpty)
          Wrap(
            spacing: 6,
            runSpacing: AppSpacing.xxs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: facts,
          ),
        if (facts.isNotEmpty && badges.isNotEmpty) const SizedBox(height: 8),
        if (badges.isNotEmpty)
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: badges,
          ),
      ],
    );
  }
}

class _BannerTitle extends StatelessWidget {
  const _BannerTitle({
    required this.title,
    this.hint,
    this.onTap,
    this.compact = false,
  });

  final String title;
  final String? hint;
  final VoidCallback? onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final heading = Text(
      title,
      maxLines: compact ? 3 : 2,
      overflow: TextOverflow.ellipsis,
      style: phoneDetailTitleStyle(theme, compact: compact),
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
            AppIcons.chevronRight,
            fill: AppIcons.filled,
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
          AppSurfaceAction(
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
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    if (entry.badge) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.onSurface.withValues(alpha: .08),
          borderRadius: BorderRadius.circular(5),
          border: Border.all(
            color: scheme.onSurface.withValues(alpha: .28),
            width: 0.8,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
          child: Text(
            entry.label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurface.withValues(alpha: .86),
              fontSize: 11,
              fontWeight: FontWeight.w800,
              height: 1.3,
              letterSpacing: .3,
            ),
          ),
        ),
      );
    }
    final style = theme.textTheme.labelLarge?.copyWith(
      color: entry.highlight
          ? scheme.onSurface
          : entry.onTap != null
          ? scheme.primary
          : scheme.onSurfaceVariant,
      fontWeight: entry.highlight ? FontWeight.w700 : FontWeight.w500,
    );
    final chip = entry.highlight
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                AppIcons.star,
                fill: AppIcons.filled,
                size: 15,
                color: phoneRatingStarColor,
              ),
              const SizedBox(width: 3),
              Text(entry.label, style: style),
            ],
          )
        : Text(entry.label, style: style);
    final onTap = entry.onTap;
    if (onTap == null) {
      return chip;
    }
    return Container(
      decoration: BoxDecoration(color: const Color(0x00000000)),
      child: AppSurfaceAction(
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
    final theme = AppUiTheme.of(context);
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
              return Container(
                decoration: BoxDecoration(
                  color: scheme.onSurface.withValues(alpha: .06),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: scheme.onSurface.withValues(alpha: .14),
                    width: 0.8,
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: AppSurfaceAction(
                  onTap: tap == null ? null : () => tap(genre),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
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
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      child: Container(
        decoration: BoxDecoration(
          color: selected ? scheme.onSurface : scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(999),
        ),
        clipBehavior: Clip.antiAlias,
        child: AppSurfaceAction(
          onTap: onPressed,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 64, minHeight: 36),
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

  final MediaItem item;
  final List<MediaItem> seasons;
  final String? seasonId;
  final List<MediaItem> episodes;
  final bool episodesLoading;
  final MediaServerException? episodeError;
  final bool hasMore;
  final String? playTargetId;

  /// 本季集数（服务器总数）。缺省时用季条目自带的 ChildCount。
  final int? episodeTotal;
  final String? focusEpisodeId;
  final EpisodeScrollCoordinator? scrollCoordinator;
  final List<MediaItem> similar;
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

  Widget _episodeWidget(MediaItem episode, int index) => _RevealEpisode(
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
    final theme = AppUiTheme.of(context);
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
    // 本季概况只剩一行小字跟在分区标题下：集数与整季载入后的已看进度。
    final summary = <String>[
      if (total != null && total > 0) l.episodeCount(total),
      if (watched != null && total != null && total > 0)
        l.seasonWatchedCount(watched, total),
    ];
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
            AppSpacing.lg,
            AppSpacing.xs,
            AppSpacing.xs,
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  key: seasonSummaryKey,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      l.detailEpisodesHeader,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.2,
                      ),
                    ),
                    if (summary.isNotEmpty)
                      Text(
                        summary.join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                  ],
                ),
              ),
              if (onPickEpisode != null && (total ?? episodes.length) > 1)
                AppButton.icon(
                  key: CatalogKeys.locateEpisode,
                  style: AppButtonStyle(minimumSize: const Size(48, 48)),
                  onPressed: onPickEpisode,
                  icon: const Icon(
                    AppIcons.episodes,
                    fill: AppIcons.filled,
                    size: 18,
                  ),
                  label: Text(l.pickEpisode),
                  variant: AppButtonVariant.plain,
                ),
            ],
          ),
        ),
      if (showSeasons)
        SizedBox(
          height:
              36 *
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
          child: AppButton(
            style: AppButtonStyle(minimumSize: const Size(48, 48)),
            onPressed: episodesLoading ? null : onLoadMore,
            variant: AppButtonVariant.tinted,
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

  void locate(List<MediaItem> episodes, String? episodeId) {
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

  final MediaItem episode;
  final bool current;
  final VoidCallback onTap;

  static const double _thumbWidth = 140;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = AppUiTheme.of(context);
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
        fontSize: 15,
        fontWeight: current ? FontWeight.w700 : FontWeight.w600,
        height: 1.3,
        color: current
            ? scheme.primary
            : played
            ? scheme.onSurfaceVariant
            : scheme.onSurface,
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.sm, 3, AppSpacing.sm, 3),
      child: Container(
        decoration: BoxDecoration(
          color: current
              ? scheme.primary.withValues(alpha: .12)
              : scheme.surfaceContainerLow.withValues(alpha: .42),
          borderRadius: BorderRadius.circular(AppRadii.lg),
          border: Border.all(
            color: current
                ? scheme.primary.withValues(alpha: .32)
                : scheme.outlineVariant.withValues(alpha: .28),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: AppSurfaceAction(
          key: CatalogKeys.episode(episode.id),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.xs,
              vertical: 8,
            ),
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
                            const SizedBox(height: 3),
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

                if (overview != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
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

  final MediaItem episode;
  final double width;
  final bool current;
  final bool played;
  final double progress;

  @override
  Widget build(BuildContext context) {
    final scheme = AppUiTheme.of(context).colorScheme;
    final showProgress = progress > 0 && !played;
    return SizedBox(
      width: width,
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadii.sm),
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
                ColoredBox(
                  color: const Color(0xff000000).withValues(alpha: .38),
                ),
              if (showProgress)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Semantics(
                    container: true,
                    label: AppLocalizations.of(context)
                        .playbackProgress((progress * 100).round()),
                    child: AppLoadingBar(
                      value: progress,
                      minHeight: 4,
                      color: scheme.primary,
                      backgroundColor: const Color(0xff000000)
                          .withValues(alpha: .45),
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
                const Center(
                  child: EpisodeCurrentMark(
                    size: 24,
                    iconKey: Key('phone-episode-current'),
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

  final List<MediaItem> items;
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
                  style: AppUiTheme.of(context).textTheme.titleMedium?.copyWith(
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                  ),
                ),
              ),
              AppButton(
                key: CatalogKeys.shelfMore(CatalogKeys.shelfSimilar),
                style: AppButtonStyle(minimumSize: const Size(48, 48)),
                onPressed: onOpenSimilar,
                variant: AppButtonVariant.plain,
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

/// 评分星标的固定金色，不随画面取色变化，一眼认出是评分。
const Color phoneRatingStarColor = Color(0xFFF5C518);
