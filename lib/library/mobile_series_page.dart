import 'package:flutter/material.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_motion.dart';
import 'package:rillight/app/mobile_widgets.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/library/episode_detail_sections.dart';
import 'package:rillight/library/item_format.dart';
import 'package:rillight/media_image/media_image.dart';

/// 头部元数据条目:年份/时长/评级/季集数等,以胶囊形式排在标题下方。
/// [highlight] 用于评级等需要强调的值。
class PhoneMetaEntry {
  const PhoneMetaEntry(this.label, {this.highlight = false});

  final String label;
  final bool highlight;
}

/// 沉浸头部:全宽 16:9 背图 + 顶带/底带渐变(收敛到 [AppScrim]/[AppMobileHero]
/// token),标题、元数据胶囊与主操作排在图片下方的衔接带上,不再叠字压图。
/// 背图缺失时以占位底色兜底,不出现空白区。
class PhoneItemBanner extends StatelessWidget {
  const PhoneItemBanner({
    super.key,
    required this.item,
    required this.title,
    this.meta = const [],
    this.actions,
    this.preferBackdrop = true,
    this.maxWidth = PhoneMotion.pageRequestWidth,
    this.maxImageHeight,
  });

  static const bannerKey = Key('phone-detail-banner');
  static const metaKey = Key('phone-detail-meta');

  final EmbyItem item;
  final String title;
  final List<PhoneMetaEntry> meta;
  final Widget? actions;
  final bool preferBackdrop;
  final int maxWidth;

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
              // 底带:画面溶入页面底色,与下方信息块无缝衔接。
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.transparent,
                      theme.colorScheme.surface,
                    ],
                    stops: const [
                      0,
                      AppMobileHero.bottomStart,
                      AppMobileHero.bottomEnd,
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.sm,
            AppSpacing.md,
            AppSpacing.md,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: theme.textTheme.headlineSmall),
              if (meta.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.xs),
                Wrap(
                  key: metaKey,
                  spacing: AppSpacing.xs,
                  runSpacing: AppSpacing.xxs,
                  children: [for (final entry in meta) _MetaChip(entry: entry)],
                ),
              ],
              if (actions != null) ...[
                const SizedBox(height: AppSpacing.sm),
                actions!,
              ],
            ],
          ),
        ),
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
    final highlight = entry.highlight;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xxs,
      ),
      decoration: BoxDecoration(
        color: highlight
            ? theme.colorScheme.primary.withValues(alpha: 0.16)
            : theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(AppRadii.md),
      ),
      child: Text(
        entry.label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: highlight
              ? theme.colorScheme.primary
              : theme.colorScheme.onSurfaceVariant,
        ),
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
    required this.similar,
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
  final List<EmbyItem> similar;
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
        if (showSeasons)
          SizedBox(
            height: 64,
            child: ListView.separated(
              key: const Key('phone-season-list'),
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.xs,
              ),
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
        if (episodesLoading)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: LinearProgressIndicator(),
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
          _EpisodeRow(
            episode: episode,
            current: episode.id == playTargetId,
            onTap: () => onOpenEpisode(episode.id),
          ),
        if (hasMore && onLoadMore != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: FilledButton(
              onPressed: episodesLoading ? null : onLoadMore,
              child: Text(l.mobileLoadMore),
            ),
          ),
        if (plainOverview(item.overview) != null)
          EpisodeOverviewSection(overview: item.overview),
        EpisodePeopleSection(people: item.people),
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
                          if (code != null)
                            Positioned(
                              left: 6,
                              bottom: 4,
                              child: Text(
                                code,
                                style: theme.textTheme.labelMedium?.copyWith(
                                  color: Colors.white,
                                ),
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
                      if (runtime != null)
                        Text(
                          runtime,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
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
                      if (progress > 0 && !episode.userData.played)
                        Padding(
                          padding: const EdgeInsets.only(top: AppSpacing.xxs),
                          child: LinearProgressIndicator(value: progress),
                        ),
                      if (episode.userData.played)
                        Text(
                          l.mobileWatched,
                          style: theme.textTheme.labelMedium,
                        ),
                      if (current)
                        Icon(
                          Icons.play_circle,
                          key: const Key('phone-episode-current'),
                          color: theme.colorScheme.primary,
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
                        maxLines: 2,
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
