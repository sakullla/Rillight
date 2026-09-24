import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/content_theme.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/app/widgets/skeleton.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/library/detail_controller.dart';
import 'package:rillight/library/episode_detail_sections.dart';
import 'package:rillight/library/detail_extras.dart';
import 'package:rillight/library/item_format.dart';
import 'package:rillight/media_image/media_image.dart';
import 'package:rillight/player/player_window_host.dart';

class TvDetailPage extends StatefulWidget {
  const TvDetailPage({super.key, required this.itemId, this.initialSeasonId});
  final String itemId;
  final String? initialSeasonId;
  @override
  State<TvDetailPage> createState() => _TvDetailPageState();
}

class _TvDetailPageState extends State<TvDetailPage> {
  DetailController? _controller;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller ??= DetailController(
      auth: AuthScope.of(context),
      cache: CatalogScope.of(context).cache,
      itemId: widget.itemId,
      seasonId: widget.initialSeasonId,
    )..load();
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _play({bool fromStart = false}) async {
    final c = _controller!, target = _controller!.playTarget;
    if (target == null) return;
    await context.push(
      '/play/${target.id}',
      extra: PlayerOpenRequest(
        itemId: target.id,
        mediaSourceId: c.item?.isSeries == true ? null : c.mediaSourceId,
        autoResume: !fromStart,
      ),
    );
    if (mounted && AuthScope.of(context).isLoggedIn) {
      c.load();
      CatalogScope.of(context).reloadHomeRows();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller!, l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final item = c.item, target = c.playTarget;
        return ContentTheme(
          item: item,
          preferBackdrop: item?.isEpisode != true,
          preferParentBackdrop: item?.isEpisode == true,
          child: TvFrame(
            title: item?.name ?? l.playerLoading,
            child: ListView(
              key: PageStorageKey('tv-detail-${widget.itemId}'),
              children: [
                if (item == null && c.loading) const _TvDetailSkeleton(),
                if (c.error != null) TvFailure(error: c.error!, retry: c.load),
                if (item != null) ...[
                  Row(
                    key: const Key('tv-detail-overview'),
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 175,
                        height: 240,
                        child: MediaImage(item: item, maxWidth: 400),
                      ),
                      const SizedBox(width: 24),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              item.name,
                              style: Theme.of(context).textTheme.headlineSmall,
                            ),
                            if (item.productionYear != null)
                              Text('${item.productionYear}'),
                            if (item.overview?.isNotEmpty == true)
                              Text(
                                item.overview!,
                                maxLines: 4,
                                overflow: TextOverflow.ellipsis,
                              ),
                            DetailGenreRow(item: item),
                            DetailAlbumStrip(item: item),
                            DetailExternalLinks(
                              links: item.externalUrls,
                              title: item.name,
                            ),
                            EpisodeMediaStreamsSection(
                              source: _tvSource(item, c.mediaSourceId),
                            ),
                            TvAction(
                              key: const Key('tv-detail-play'),
                              emphasized: true,
                              autofocus: true,
                              onPressed:
                                  target != null &&
                                      (target.isMovie || target.isEpisode)
                                  ? _play
                                  : null,
                              child: Text(
                                target == null
                                    ? l.noPlayableStream
                                    : target.canResume
                                    ? l.resumePlay
                                    : l.play,
                              ),
                            ),
                            if (target?.canResume == true)
                              TvAction(
                                onPressed: () => _play(fromStart: true),
                                child: Text(l.playFromStart),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (item.mediaSources.length > 1) ...[
                    Text(l.mediaSource),
                    for (final source in item.mediaSources)
                      TvAction(
                        key: ValueKey(source.id),
                        selected: c.mediaSourceId == source.id,
                        onPressed: () => c.selectSource(source.id),
                        child: Text(source.name ?? source.id),
                      ),
                  ],
                  if (item.isSeries) ...[
                    const SizedBox(height: 16),
                    Text(l.playerEpisodes),
                    Wrap(
                      children: [
                        for (final season in c.seasons)
                          TvAction(
                            key: ValueKey(season.id),
                            selected: season.id == c.seasonId,
                            onPressed: () => c.selectSeason(season.id),
                            child: Text(season.name),
                          ),
                      ],
                    ),
                    if (c.episodesLoading && c.episodes.isEmpty)
                      const _TvEpisodeSkeleton(),
                    if (c.episodeError != null)
                      TvFailure(
                        error: c.episodeError!,
                        retry: () => c.selectSeason(
                          c.seasonId!,
                          more: c.episodes.isNotEmpty && c.hasMore,
                        ),
                      ),
                    if (!c.episodesLoading && c.episodes.isEmpty)
                      Text(l.mobileEmpty),
                    for (final episode in c.episodes)
                      TvAction(
                        key: ValueKey(episode.id),
                        onPressed: () =>
                            context.push(AppRoutes.item(episode.id)),
                        child: Text(
                          '${episodeLabel(episode)} · ${episode.name}',
                        ),
                      ),
                    if (c.hasMore)
                      TvAction(
                        key: const Key('tv-episodes-more'),
                        onPressed: c.episodesLoading
                            ? null
                            : () => c.selectSeason(c.seasonId!, more: true),
                        child: Text(l.mobileLoadMore),
                      ),
                  ],
                  TvAction(
                    key: const Key('tv-detail-refresh'),
                    onPressed: c.load,
                    child: Text(l.mobileRefresh),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _TvDetailSkeleton extends StatelessWidget {
  const _TvDetailSkeleton();

  @override
  Widget build(BuildContext context) {
    final animate = !MediaQuery.disableAnimationsOf(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SkeletonBlock(width: 175, height: 240, animated: animate),
        const SizedBox(width: 24),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SkeletonBlock(width: 280, height: 28, animated: animate),
              const SizedBox(height: 12),
              SkeletonBlock(width: 160, height: 16, animated: animate),
              const SizedBox(height: 16),
              SkeletonBlock(width: 420, height: 14, animated: animate),
              const SizedBox(height: 8),
              SkeletonBlock(width: 360, height: 14, animated: animate),
              const SizedBox(height: 24),
              SkeletonBlock(width: 220, height: 48, animated: animate),
            ],
          ),
        ),
      ],
    );
  }
}

ItemMediaSource? _tvSource(EmbyItem item, String? id) {
  for (final source in item.mediaSources) {
    if (source.id == id) {
      return source;
    }
  }
  if (item.mediaSources.isEmpty) {
    return null;
  }
  return item.mediaSources.first;
}

class _TvEpisodeSkeleton extends StatelessWidget {
  const _TvEpisodeSkeleton();

  @override
  Widget build(BuildContext context) {
    final animate = !MediaQuery.disableAnimationsOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < 4; i++) ...[
          const SizedBox(height: 8),
          SkeletonBlock(width: 360, height: 20, animated: animate),
        ],
      ],
    );
  }
}
