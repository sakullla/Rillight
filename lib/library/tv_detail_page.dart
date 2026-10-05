import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/content_theme.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/app/widgets/skeleton.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/library/detail_source_scope.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/hero_artwork.dart';
import 'package:rillight/library/detail_controller.dart';
import 'package:rillight/library/tv_library_page.dart';
import 'package:rillight/library/episode_detail_sections.dart';
import 'package:rillight/library/episode_list.dart';
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
  final _focus = TvReturnFocus();
  bool _playBusy = false;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_onFocus);
  }

  void _onFocus() {
    if (!mounted) return;
    _focus.syncOwned(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller ??= DetailController(
      auth: AuthScope.of(context),
      client: DetailSourceScope.maybeOf(context)?.client,
      cache: DetailSourceScope.cacheOf(context),
      itemId: widget.itemId,
      seasonId: widget.initialSeasonId,
    )..load();
    _focus.noteRoute(
      ModalRoute.of(context)?.isCurrent ?? true,
      () => _focus.allowRestore(this),
    );
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_onFocus);
    _focus.dispose();
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _play({bool fromStart = false}) async {
    if (_playBusy) return;
    final c = _controller!;
    setState(() => _playBusy = true);
    try {
      if (c.item?.isSeries == true && !fromStart) {
        try {
          await c.retainOffPageResume();
        } catch (_) {
          // The first visible episode remains usable if the scan fails.
        }
      }
      if (!mounted || !AuthScope.of(context).isLoggedIn) return;
      final target = c.playTarget;
      if (target == null) return;
      await context.push(
        '/play/${target.id}',
        extra: PlayerOpenRequest(
          itemId: target.id,
          source: DetailSourceScope.command(context, target.id)?.source,
          libraryId: DetailSourceScope.maybeOf(context)?.libraryId,
          regionGeneration: DetailSourceScope.maybeOf(
            context,
          )?.permit.regionGeneration,
          mediaSourceId: c.item?.isSeries == true ? null : c.mediaSourceId,
          autoResume: !fromStart,
        ),
      );
      if (mounted && AuthScope.of(context).isLoggedIn) {
        c.load();
        CatalogScope.of(context).reloadHomeRows();
      }
    } finally {
      if (mounted) setState(() => _playBusy = false);
    }
  }

  Future<void> _togglePlayed() async {
    final c = _controller!;
    final item = c.item;
    if (item == null) return;
    final next = !item.userData.played;
    final ok = await c.togglePlayed();
    if (!mounted || !ok) return;
    final l = AppLocalizations.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(next ? l.markPlayed : l.markUnplayed)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller!, l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        _focus.retain([
          for (final season in c.seasons) 'season:${season.id}',
          for (final episode in c.episodes) 'episode:${episode.id}',
        ]);
        final item = c.item, target = c.playTarget;
        final season = c.seasons.where((s) => s.id == c.seasonId).firstOrNull;
        final artwork = item?.isSeries == true && season != null
            ? seasonArtworkItem(season, item!)
            : item;
        return ContentTheme(
          item: artwork,
          preferBackdrop: item?.isEpisode != true,
          preferParentBackdrop: item?.isEpisode == true,
          child: TvFrame(
            title: item?.name ?? l.playerLoading,
            edgeToEdge: true,
            child: ListView(
              key: PageStorageKey('tv-detail-${widget.itemId}'),
              padding: EdgeInsets.zero,
              children: [
                if (item == null && c.loading)
                  Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: tvSafeGutter(
                        MediaQuery.sizeOf(context).width,
                      ),
                    ),
                    child: const _TvDetailSkeleton(),
                  ),
                if (c.error != null)
                  Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: tvSafeGutter(
                        MediaQuery.sizeOf(context).width,
                      ),
                    ),
                    child: TvFailure(error: c.error!, retry: c.load),
                  ),
                if (item != null) ...[
                  _TvBackdropHeader(item: item, artwork: artwork),
                  const SizedBox(height: 12),
                  Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: tvSafeGutter(
                        MediaQuery.sizeOf(context).width,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (c.seasonError != null)
                          TvFailure(
                            error: c.seasonError!,
                            retry: c.loadSeasons,
                          ),
                        Wrap(
                          spacing: 4,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            TvAction(
                              key: const Key('tv-detail-play'),
                              emphasized: true,
                              autofocus: true,
                              pill: true,
                              leading: const Icon(
                                Icons.play_arrow_rounded,
                                size: 20,
                              ),
                              onPressed:
                                  !_playBusy &&
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
                                pill: true,
                                onPressed: _playBusy
                                    ? null
                                    : () => _play(fromStart: true),
                                child: Text(l.playFromStart),
                              ),
                            if (!item.isSeries)
                              TvAction(
                                key: const Key('tv-detail-played-toggle'),
                                pill: true,
                                onPressed: c.playedBusy ? null : _togglePlayed,
                                child: Text(
                                  item.userData.played
                                      ? l.markUnplayed
                                      : l.markPlayed,
                                ),
                              ),
                          ],
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
                        if (item.mediaSources.length > 1) ...[
                          Text(l.mediaSource),
                          Wrap(
                            spacing: 4,
                            runSpacing: 4,
                            children: [
                              for (final source in item.mediaSources)
                                TvAction(
                                  key: ValueKey(source.id),
                                  pill: true,
                                  selected: c.mediaSourceId == source.id,
                                  onPressed: () => c.selectSource(source.id),
                                  child: Text(source.name ?? source.id),
                                ),
                            ],
                          ),
                        ],
                        if (item.isSeries) ...[
                          const SizedBox(height: 16),
                          Text(l.playerEpisodes),
                          Wrap(
                            spacing: 4,
                            runSpacing: 4,
                            children: [
                              for (final season in c.seasons)
                                TvAction(
                                  key: ValueKey(season.id),
                                  pill: true,
                                  focusNode: _focus.nodeFor(
                                    'season:${season.id}',
                                  ),
                                  selected: season.id == c.seasonId,
                                  onPressed: () => c.selectSeason(season.id),
                                  child: Text(season.name),
                                ),
                            ],
                          ),
                          Column(
                            key: const Key('tv-detail-episodes'),
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
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
                                _TvEpisodeTile(
                                  episode: episode,
                                  current: episode.id == target?.id,
                                  focusNode: _focus.nodeFor(
                                    'episode:${episode.id}',
                                  ),
                                ),
                              if (c.hasMore)
                                TvAction(
                                  key: const Key('tv-episodes-more'),
                                  onPressed: c.episodesLoading
                                      ? null
                                      : () => c.selectSeason(
                                          c.seasonId!,
                                          more: true,
                                        ),
                                  child: Text(l.mobileLoadMore),
                                ),
                            ],
                          ),
                        ],
                        TvAction(
                          key: const Key('tv-detail-refresh'),
                          onPressed: c.load,
                          child: Text(l.mobileRefresh),
                        ),
                      ],
                    ),
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

/// 沉浸式头部:全宽背图出血到屏幕顶(标题行遮罩由 TvFrame 提供),底部渐变
/// 上落大标题、元信息与简介。
class _TvBackdropHeader extends StatelessWidget {
  const _TvBackdropHeader({required this.item, this.artwork});

  final EmbyItem item;
  final EmbyItem? artwork;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = AppLocalizations.of(context);
    final size = MediaQuery.sizeOf(context);
    final height = math.min(420.0, size.height * 0.46);
    final gutter = tvSafeGutter(size.width);
    final overview = plainOverview(item.overview);
    final meta = <String>[
      if (seasonEpisodeCode(item) != null) seasonEpisodeCode(item)!,
      if (item.productionYear != null) '${item.productionYear}',
      if (runtimeLabel(l, item) != null) runtimeLabel(l, item)!,
      if (item.communityRating != null)
        item.communityRating!.toStringAsFixed(1),
    ];
    return SizedBox(
      key: const Key('tv-detail-backdrop'),
      height: height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: theme.colorScheme.surfaceContainerHigh),
          MediaImage(
            item: artwork ?? item,
            contributesToTheme: true,
            smartCrop: true,
            preferBackdrop: !item.isEpisode,
            preferParentBackdrop: item.isEpisode,
            maxWidth: 1280,
          ),
          const TvHeroScrim(top: false),
          Positioned(
            left: gutter,
            right: gutter,
            bottom: 16,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (item.isEpisode && item.seriesId?.isNotEmpty == true)
                  TvAction(
                    key: CatalogKeys.seriesLink,
                    pill: true,
                    onPressed: () => context.push(
                      AppRoutes.item(
                        item.seriesId!,
                        seasonId: item.seasonId ?? item.parentId,
                      ),
                      extra: DetailSourceScope.command(context, item.seriesId!),
                    ),
                    child: Text(
                      '${item.seriesName ?? l.seasons}  ›',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                Text(
                  item.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.headlineMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    shadows: const [
                      Shadow(blurRadius: 12, color: Colors.black54),
                    ],
                  ),
                ),
                if (meta.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    meta.join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: Colors.white.withValues(alpha: 0.85),
                    ),
                  ),
                ],
                if (overview != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    overview,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.white.withValues(alpha: 0.85),
                      height: 1.4,
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

/// 分集行:缩略图(进度/已看角标)+ 集数名 + 时长/已看,当前集以选中态与播放图标标识。
class _TvEpisodeTile extends StatelessWidget {
  const _TvEpisodeTile({
    required this.episode,
    required this.current,
    required this.focusNode,
  });

  final EmbyItem episode;
  final bool current;
  final FocusNode focusNode;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = AppLocalizations.of(context);
    final progress = episode.playbackProgress;
    final played = episode.userData.played;
    final runtime = runtimeLabel(l, episode);
    final overview = plainOverview(episode.overview);
    final meta = <String>[
      if (current) l.nowPlayingEpisode,
      if (episode.canResume)
        ?remainingLabel(l, episode)
      else if (played)
        l.mobileWatched,
      if (episode.premiereDate != null) formatDateYmd(episode.premiereDate!),
    ];
    return TvAction(
      key: ValueKey(episode.id),
      focusNode: focusNode,
      selected: current,
      onPressed: () => context.push(
        AppRoutes.item(episode.id),
        extra: DetailSourceScope.command(context, episode.id),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 232,
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppRadii.md),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    MediaImage(item: episode, preferThumb: true, maxWidth: 480),
                    if (played && !current)
                      ColoredBox(color: Colors.black.withValues(alpha: .36)),
                    if (progress > 0 && !played)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: LinearProgressIndicator(
                          value: progress,
                          minHeight: 4,
                          backgroundColor: Colors.black.withValues(alpha: .45),
                        ),
                      ),
                    if (runtime != null)
                      Positioned(
                        right: 6,
                        bottom: progress > 0 && !played ? 10 : 6,
                        child: EpisodeThumbBadge(label: runtime),
                      ),
                    if (played)
                      const Positioned(
                        right: 6,
                        top: 6,
                        child: EpisodeWatchedBadge(size: 18),
                      ),
                    if (current)
                      Center(
                        child: Icon(
                          Icons.play_circle_fill,
                          key: const Key('tv-episode-current'),
                          size: 36,
                          color: Colors.white.withValues(alpha: 0.92),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  episodeLabel(episode),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (meta.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    meta.join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: current || episode.canResume
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                if (overview != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    overview,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.4,
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

class _TvDetailSkeleton extends StatelessWidget {
  const _TvDetailSkeleton();

  @override
  Widget build(BuildContext context) {
    final animate = !MediaQuery.disableAnimationsOf(context);
    final height = math.min(320.0, MediaQuery.sizeOf(context).height * 0.42);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SkeletonBlock(height: height, animated: animate),
        const SizedBox(height: 16),
        SkeletonBlock(width: 220, height: 48, animated: animate),
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
        for (var i = 0; i < 3; i++) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              SkeletonBlock(width: 232, height: 130, animated: animate),
              const SizedBox(width: 12),
              SkeletonBlock(width: 240, height: 20, animated: animate),
            ],
          ),
        ],
      ],
    );
  }
}
