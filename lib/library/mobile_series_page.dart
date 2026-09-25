import 'package:flutter/material.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_motion.dart';
import 'package:rillight/app/mobile_widgets.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/widgets/skeleton.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/library/detail_extras.dart';
import 'package:rillight/library/episode_detail_sections.dart';
import 'package:rillight/library/item_format.dart';
import 'package:rillight/media_image/media_image.dart';

/// 头部元数据条目:年份/时长/评级/季集数等,以胶囊形式排在标题下方。
/// [highlight] 用于评级等需要强调的值。
class PhoneMetaEntry {
  const PhoneMetaEntry(this.label, {this.highlight = false, this.onTap});

  final String label;
  final bool highlight;
  final VoidCallback? onTap;
}

/// 沉浸头部:全宽 16:9 背图,标题和元数据落在底部渐变上,主操作紧贴画面。
/// 背图缺失时以占位底色兜底,不出现空白区。
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

  /// 单集标题进所属剧集。非空时标题行带箭头，[titleHint] 写剧集名。
  final VoidCallback? onTitleTap;
  final String? titleHint;
  final bool preferBackdrop;
  final int maxWidth;

  /// 为 false 时只画头图。加载中的标题和主操作由调用方放在头图下面。
  final bool showCaption;

  /// 剧集把季列表和分集当作主体时，压低背图，避免先滑过一大块画面。
  final double? maxImageHeight;

  /// 背图高度上限(相对屏高):横屏/矮窗里 16:9 全宽会超过半屏,
  /// 压住标题与主操作,这里封顶保证头部信息首屏可达。
  static const double _maxHeightFactor = 0.5;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = MediaQuery.sizeOf(context);
    final byWidth = size.width * 9 / 16;
    final heightCap = size.height * _maxHeightFactor;
    var imageHeight = byWidth < heightCap ? byWidth : heightCap;
    final imageCap = maxImageHeight;
    if (imageCap != null && imageHeight > imageCap) {
      imageHeight = imageCap;
    }
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
              PhoneMotion.sharedImage(
                itemId: item.id,
                preferBackdrop: preferBackdrop,
                child: MediaImage(
                  item: item,
                  preferBackdrop: preferBackdrop,
                  maxWidth: maxWidth,
                ),
              ),
              // 顶带:保护透明顶栏与返回钮,向下溶到透明。
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
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
                height: imageHeight * 0.62,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        theme.colorScheme.surface.withValues(alpha: 0.72),
                        theme.colorScheme.surface,
                      ],
                      stops: const [0, 0.55, 1],
                    ),
                  ),
                ),
              ),
              if (showCaption)
                Positioned(
                  left: AppSpacing.md,
                  right: AppSpacing.md,
                  bottom: AppSpacing.sm,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _BannerTitle(
                              title: title,
                              hint: onTitleTap == null ? null : titleHint,
                              onTap: onTitleTap,
                            ),
                            if (meta.isNotEmpty) ...[
                              const SizedBox(height: AppSpacing.xs),
                              Wrap(
                                key: metaKey,
                                spacing: AppSpacing.xs,
                                runSpacing: AppSpacing.xxs,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  for (var i = 0; i < meta.length; i++) ...[
                                    if (i > 0)
                                      Text(
                                        '·',
                                        style: theme.textTheme.labelMedium
                                            ?.copyWith(
                                              color: theme
                                                  .colorScheme
                                                  .onSurfaceVariant,
                                            ),
                                      ),
                                    _MetaChip(entry: meta[i]),
                                  ],
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                      if (actions != null) ...[
                        const SizedBox(width: AppSpacing.sm),
                        actions!,
                      ],
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
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
    final titleStyle = theme.textTheme.headlineSmall?.copyWith(
      color: theme.colorScheme.onSurface,
      fontWeight: FontWeight.w700,
      height: 1.2,
    );
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: titleStyle,
        ),
        if (hint != null && hint!.isNotEmpty) ...[
          const SizedBox(height: 2),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  hint!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
              if (onTap != null)
                Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
            ],
          ),
        ],
      ],
    );
    if (onTap == null) {
      return text;
    }
    return InkWell(
      key: CatalogKeys.seriesLink,
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadii.sm),
      child: text,
    );
  }
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.entry});

  final PhoneMetaEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final highlight = entry.highlight;
    final chip = Text(
      entry.label,
      style: theme.textTheme.labelLarge?.copyWith(
        color: highlight || entry.onTap != null
            ? theme.colorScheme.primary
            : theme.colorScheme.onSurfaceVariant,
        fontWeight: highlight ? FontWeight.w700 : FontWeight.w500,
      ),
    );
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

/// 剧集页正文：横幅、横向季选项和横图分集。主操作由外层底栏承担。
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
    this.focusEpisodeId,
    required this.similar,
    this.onPickEpisode,
    required this.onSelectSeason,
    required this.onOpenEpisode,
    required this.onRetryEpisodes,
    required this.onLoadMore,
    required this.onOpenItem,
    required this.onOpenSimilar,
  });

  final EmbyItem item;
  final List<EmbyItem> seasons;
  final String? seasonId;
  final List<EmbyItem> episodes;
  final bool episodesLoading;
  final EmbyException? episodeError;
  final bool hasMore;
  final String? playTargetId;
  final String? focusEpisodeId;
  final List<EmbyItem> similar;
  final VoidCallback? onPickEpisode;
  final ValueChanged<String> onSelectSeason;
  final ValueChanged<String> onOpenEpisode;
  final VoidCallback? onRetryEpisodes;
  final VoidCallback? onLoadMore;
  final ValueChanged<String> onOpenItem;
  final VoidCallback onOpenSimilar;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final showSeasons = seasons.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (plainOverview(item.overview) != null)
          EpisodeOverviewSection(overview: item.overview, compact: true),
        if (showSeasons || onPickEpisode != null)
          SizedBox(
            height: 48,
            child: ListView.separated(
              key: const Key('phone-season-list'),
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              itemCount: seasons.length,
              separatorBuilder: (context, index) =>
                  const SizedBox(width: AppSpacing.xs),
              itemBuilder: (context, index) {
                final season = seasons[index];
                return ChoiceChip(
                  key: CatalogKeys.season(season.id),
                  label: Text(season.name),
                  selected: season.id == seasonId,
                  onSelected: (selected) {
                    if (selected) onSelectSeason(season.id);
                  },
                );
              },
            ),
          ),
        if (episodes.isNotEmpty || episodesLoading)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.sm,
              AppSpacing.md,
              AppSpacing.xxs,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    l.seasonEpisodes,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (onPickEpisode != null)
                  TextButton.icon(
                    key: CatalogKeys.locateEpisode,
                    onPressed: onPickEpisode,
                    icon: const Icon(Icons.apps_rounded, size: 18),
                    label: Text(l.pickEpisode),
                  ),
              ],
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
              return SizedBox(
                height: cardHeight,
                child: ListView.separated(
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
              );
            },
          ),
        if (episodeError != null && onRetryEpisodes != null)
          MobileFailure(error: episodeError!, retry: onRetryEpisodes!),
        if (!episodesLoading &&
            episodeError == null &&
            episodes.isEmpty &&
            showSeasons)
          Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Text(l.mobileEmpty),
          ),
        for (final episode in episodes)
          _RevealEpisode(
            reveal: episode.id == focusEpisodeId,
            child: _EpisodeRow(
              episode: episode,
              current: episode.id == (focusEpisodeId ?? playTargetId),
              onTap: () => onOpenEpisode(episode.id),
            ),
          ),
        if (hasMore && onLoadMore != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: FilledButton(
              onPressed: episodesLoading ? null : onLoadMore,
              child: Text(l.mobileLoadMore),
            ),
          ),
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
      ],
    );
  }
}

class _RevealEpisode extends StatefulWidget {
  const _RevealEpisode({required this.reveal, required this.child});

  final bool reveal;
  final Widget child;

  @override
  State<_RevealEpisode> createState() => _RevealEpisodeState();
}

class _RevealEpisodeState extends State<_RevealEpisode> {
  @override
  void initState() {
    super.initState();
    if (widget.reveal) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Scrollable.ensureVisible(context, alignment: 0.2);
      });
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _EpisodeRow extends StatelessWidget {
  const _EpisodeRow({
    required this.episode,
    required this.current,
    required this.onTap,
  });

  final EmbyItem episode;
  final bool current;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final overview = plainOverview(episode.overview);
    final runtime = runtimeLabel(l, episode);
    final code = seasonEpisodeCode(episode);
    final progress = episode.playbackProgress;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.xs,
        AppSpacing.md,
        AppSpacing.xs,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadii.md),
          border: Border.all(
            color: current ? theme.colorScheme.primary : Colors.transparent,
            width: 2,
          ),
        ),
        child: InkWell(
          key: CatalogKeys.episode(episode.id),
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadii.md),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.xs),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 144,
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(AppRadii.sm),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          MediaImage(
                            item: episode,
                            preferThumb: true,
                            maxWidth: 480,
                          ),
                          if (progress > 0 && !episode.userData.played)
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              child: LinearProgressIndicator(
                                value: progress,
                                minHeight: 3,
                              ),
                            ),
                          if (runtime != null)
                            Positioned(
                              right: 6,
                              bottom: progress > 0 && !episode.userData.played
                                  ? 8
                                  : 6,
                              child: Text(
                                runtime,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          if (code != null)
                            Positioned(
                              left: 6,
                              top: 6,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.55),
                                  borderRadius: BorderRadius.circular(
                                    AppRadii.sm,
                                  ),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  child: Text(
                                    code,
                                    style: theme.textTheme.labelMedium
                                        ?.copyWith(color: Colors.white),
                                  ),
                                ),
                              ),
                            ),
                          if (episode.userData.played)
                            Positioned(
                              right: 6,
                              top: 6,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.55),
                                  shape: BoxShape.circle,
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.all(2),
                                  child: Icon(
                                    Icons.check_circle,
                                    key: const Key('phone-episode-watched'),
                                    size: 18,
                                    color: Colors.white.withValues(alpha: 0.92),
                                  ),
                                ),
                              ),
                            ),
                          if (current)
                            Center(
                              child: Icon(
                                Icons.play_circle_fill,
                                key: const Key('phone-episode-current'),
                                color: Colors.white.withValues(alpha: 0.92),
                                size: 36,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(episode.name, style: theme.textTheme.titleSmall),
                      // 该集简介:EmbyItem.overview 缺失(无字段/纯空白/HTML 残迹)
                      // 时整行隐藏,卡片优雅降级为标题+时长。
                      if (overview != null)
                        Text(
                          overview,
                          key: const Key('phone-episode-overview'),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            height: 1.4,
                          ),
                        ),
                      if (episode.userData.played)
                        Text(
                          l.mobileWatched,
                          style: theme.textTheme.labelMedium,
                        ),
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

class _SimilarRow extends StatelessWidget {
  const _SimilarRow({
    required this.items,
    required this.onOpenItem,
    required this.onOpenSimilar,
  });

  final List<EmbyItem> items;
  final ValueChanged<String> onOpenItem;
  final VoidCallback onOpenSimilar;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.lg,
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
          height: 196,
          child: ListView.separated(
            key: CatalogKeys.similarRow,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            itemCount: items.length,
            separatorBuilder: (context, index) =>
                const SizedBox(width: AppSpacing.sm),
            itemBuilder: (context, index) {
              final item = items[index];
              return SizedBox(
                width: 104,
                child: InkWell(
                  key: CatalogKeys.item(item.id),
                  onTap: () => onOpenItem(item.id),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(AppRadii.sm),
                          child: MediaImage(item: item, maxWidth: 320),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xxs),
                      Text(
                        item.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
