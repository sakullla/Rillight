import 'package:flutter/material.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_widgets.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/library/episode_detail_sections.dart';
import 'package:rillight/library/item_format.dart';
import 'package:rillight/media_image/media_image.dart';

/// 铺到状态栏后方的 16:9 横幅。剧名叠在画面上，不另占一条顶栏标题。
class PhoneItemBanner extends StatelessWidget {
  const PhoneItemBanner({
    super.key,
    required this.item,
    required this.title,
    this.subtitle,
  });

  static const bannerKey = Key('phone-detail-banner');

  final EmbyItem item;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AspectRatio(
      key: bannerKey,
      aspectRatio: 16 / 9,
      child: Stack(
        fit: StackFit.expand,
        children: [
          MediaImage(item: item, preferBackdrop: true, maxWidth: 1280),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0x99000000),
                  Color(0x00000000),
                  Color(0xCC000000),
                ],
                stops: [0, 0.45, 1],
              ),
            ),
          ),
          Positioned(
            left: AppSpacing.md,
            right: AppSpacing.md,
            bottom: AppSpacing.md,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    color: Colors.white,
                  ),
                ),
                if (subtitle != null && subtitle!.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.xxs),
                  Text(
                    subtitle!,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: Colors.white,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
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

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final meta = [
      if (item.productionYear != null) '${item.productionYear}',
      if (seasons.isNotEmpty) l.seasonCount(seasons.length),
      if (item.childCount != null) l.episodeCount(item.childCount!),
    ].where((part) => part.isNotEmpty).join(' · ');
    final showSeasons = seasons.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PhoneItemBanner(
          item: item,
          title: item.name,
          subtitle: meta.isEmpty ? null : meta,
        ),
        if (showSeasons)
          SizedBox(
            height: 72,
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
          _SimilarRow(items: similar, onOpenItem: onOpenItem),
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
                      Text(episode.name),
                      if (runtime != null)
                        Text(
                          runtime,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      if (overview != null)
                        Text(
                          overview,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
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
  const _SimilarRow({required this.items, required this.onOpenItem});

  final List<EmbyItem> items;
  final ValueChanged<String> onOpenItem;

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
            AppSpacing.md,
            AppSpacing.sm,
          ),
          child: Text(
            l.similarRow,
            style: Theme.of(context).textTheme.titleMedium,
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
