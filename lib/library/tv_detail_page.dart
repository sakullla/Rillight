import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/library/detail_source_scope.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/hero_artwork.dart';
import 'package:rillight/home/hero_logo.dart';
import 'package:rillight/library/detail_controller.dart';
import 'package:rillight/library/tv_library_page.dart';
import 'package:rillight/library/episode_detail_sections.dart';
import 'package:rillight/library/detail_extras.dart';
import 'package:rillight/library/item_format.dart';
import 'package:rillight/media_image/media_image.dart';
import 'package:rillight/player/player_window_host.dart';

/// 电视详情:整屏背景图固定在后面,信息与操作压在左下;向下是季与分集行、
/// 剧照和详细信息。滚动时背景逐步压暗,下方内容始终读得清。
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
  final _scrolled = ValueNotifier<double>(0);
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
    _scrolled.dispose();
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

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth == 0 && notification.metrics.axis == Axis.vertical) {
      _scrolled.value = notification.metrics.pixels;
    }
    return false;
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
        final size = MediaQuery.sizeOf(context);
        final s = TvDesign.scaleOf(context);
        final gutter = tvSafeGutter(size.width);
        final pad = EdgeInsets.symmetric(horizontal: gutter);
        Widget section(String title, Widget child) => Padding(
          padding: EdgeInsets.fromLTRB(gutter, 18 * s, gutter, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TvSectionTitle(title, padding: EdgeInsets.only(bottom: 10 * s)),
              child,
            ],
          ),
        );
        final source = item == null ? null : _tvSource(item, c.mediaSourceId);
        final info = source == null
            ? const <(String, String)>[]
            : EpisodeMediaStreamsSection.summary(l, source);
        // 详情以影像为主:浅色主题下同样用深色舞台,背景图上的白字与按钮
        // 始终有对比度。
        return TvDarkStage(
          child: TvFrame(
            title: item?.name ?? l.playerLoading,
            edgeToEdge: true,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (item != null)
                  _TvDetailBackdrop(
                    item: item,
                    artwork: artwork,
                    scrolled: _scrolled,
                  ),
                NotificationListener<ScrollNotification>(
                  onNotification: _onScroll,
                  child: ListView(
                    key: PageStorageKey('tv-detail-${widget.itemId}'),
                    padding: EdgeInsets.only(
                      bottom: tvSafeVertical(size.height),
                    ),
                    children: [
                      if (item == null && c.loading) const _TvDetailSkeleton(),
                      if (c.error != null)
                        Padding(
                          padding: EdgeInsets.fromLTRB(
                            gutter,
                            size.height * .4,
                            gutter,
                            0,
                          ),
                          child: TvFailure(error: c.error!, retry: c.load),
                        ),
                      if (item != null) ...[
                        _TvDetailHeader(
                          item: item,
                          actions: _actions(context, item, target),
                        ),
                        if (c.seasonError != null)
                          Padding(
                            padding: pad,
                            child: TvFailure(
                              error: c.seasonError!,
                              retry: c.loadSeasons,
                            ),
                          ),
                        if (item.mediaSources.length > 1)
                          section(
                            l.mediaSource,
                            Wrap(
                              spacing: 8 * s,
                              runSpacing: 8 * s,
                              children: [
                                for (final option in item.mediaSources)
                                  TvAction(
                                    key: ValueKey(option.id),
                                    pill: true,
                                    selected: c.mediaSourceId == option.id,
                                    leading: c.mediaSourceId == option.id
                                        ? const Icon(Icons.check_rounded)
                                        : null,
                                    onPressed: () => c.selectSource(option.id),
                                    child: Text(option.name ?? option.id),
                                  ),
                              ],
                            ),
                          ),
                        if (item.isSeries) ..._episodes(context, c, target),
                        // 剧照条自己在没有图时收起。
                        Padding(
                          padding: EdgeInsets.only(top: 10 * s),
                          child: DetailAlbumStrip(item: item),
                        ),
                        if (item.genres.isNotEmpty)
                          section(
                            l.libraryFilterGenre,
                            DetailGenreRow(item: item),
                          ),
                        if (info.isNotEmpty)
                          section(
                            l.detailMediaInfo,
                            _TvStreamInfo(lines: info),
                          ),
                        if (item.externalUrls.isNotEmpty)
                          section(
                            l.externalLinks,
                            DetailExternalLinks(
                              links: item.externalUrls,
                              title: item.name,
                            ),
                          ),
                        Padding(
                          padding: EdgeInsets.fromLTRB(
                            gutter,
                            24 * s,
                            gutter,
                            0,
                          ),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: TvAction(
                              key: const Key('tv-detail-refresh'),
                              pill: true,
                              leading: const Icon(Icons.refresh_rounded),
                              onPressed: c.load,
                              child: Text(l.mobileRefresh),
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
        );
      },
    );
  }

  List<Widget> _actions(BuildContext context, EmbyItem item, EmbyItem? target) {
    final l = AppLocalizations.of(context);
    final c = _controller!;
    return [
      TvAction(
        key: const Key('tv-detail-play'),
        emphasized: true,
        autofocus: true,
        pill: true,
        leading: const Icon(Icons.play_arrow_rounded),
        onPressed:
            !_playBusy && target != null && (target.isMovie || target.isEpisode)
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
          leading: const Icon(Icons.replay_rounded),
          onPressed: _playBusy ? null : () => _play(fromStart: true),
          child: Text(l.playFromStart),
        ),
      if (!item.isSeries)
        TvAction(
          key: const Key('tv-detail-played-toggle'),
          pill: true,
          leading: Icon(
            item.userData.played
                ? Icons.remove_done_rounded
                : Icons.done_all_rounded,
          ),
          onPressed: c.playedBusy ? null : _togglePlayed,
          child: Text(item.userData.played ? l.markUnplayed : l.markPlayed),
        ),
    ];
  }

  List<Widget> _episodes(
    BuildContext context,
    DetailController c,
    EmbyItem? target,
  ) {
    final l = AppLocalizations.of(context);
    final s = TvDesign.scaleOf(context);
    final gutter = tvSafeGutter(MediaQuery.sizeOf(context).width);
    final metrics = TvCardMetrics.of(
      context,
      wide: true,
      width: 212 * s,
      subtitle: true,
    );
    return [
      Padding(
        padding: EdgeInsets.fromLTRB(gutter, 14 * s, gutter, 0),
        child: Row(
          children: [
            Builder(
              builder: (context) => Text(
                l.playerEpisodes,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            SizedBox(width: 18 * s),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                clipBehavior: Clip.none,
                child: Row(
                  children: [
                    for (final season in c.seasons) ...[
                      TvAction(
                        key: ValueKey(season.id),
                        variant: TvActionVariant.ghost,
                        focusNode: _focus.nodeFor('season:${season.id}'),
                        selected: season.id == c.seasonId,
                        onPressed: () => c.selectSeason(season.id),
                        child: Text(season.name),
                      ),
                      SizedBox(width: 4 * s),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(key: Key('tv-detail-episodes')),
      if (c.episodesLoading && c.episodes.isEmpty)
        const TvRowSkeleton(wide: true),
      if (c.episodeError != null)
        Padding(
          padding: EdgeInsets.symmetric(horizontal: gutter),
          child: TvFailure(
            error: c.episodeError!,
            retry: () => c.selectSeason(
              c.seasonId!,
              more: c.episodes.isNotEmpty && c.hasMore,
            ),
          ),
        ),
      if (!c.episodesLoading && c.episodes.isEmpty && c.episodeError == null)
        Padding(
          padding: EdgeInsets.fromLTRB(gutter, 8 * s, gutter, 0),
          child: Builder(
            builder: (context) => Text(
              l.mobileEmpty,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      if (c.episodes.isNotEmpty)
        _TvEpisodeRow(
          key: ValueKey('tv-episodes-${c.seasonId}'),
          episodes: c.episodes,
          currentId: target?.id,
          metrics: metrics,
          nodeFor: (episode) => _focus.nodeFor('episode:${episode.id}'),
          more: c.hasMore
              ? TvMoreTile(
                  key: const Key('tv-episodes-more'),
                  metrics: metrics,
                  label: l.mobileLoadMore,
                  onPressed: c.episodesLoading
                      ? null
                      : () => c.selectSeason(c.seasonId!, more: true),
                )
              : null,
        ),
    ];
  }
}

/// 分集横向行:初次出现时把当前集滚进视口,长剧不用从第一集一路按过去。
class _TvEpisodeRow extends StatefulWidget {
  const _TvEpisodeRow({
    super.key,
    required this.episodes,
    required this.currentId,
    required this.metrics,
    required this.nodeFor,
    this.more,
  });

  final List<EmbyItem> episodes;
  final String? currentId;
  final TvCardMetrics metrics;
  final FocusNode Function(EmbyItem episode) nodeFor;
  final Widget? more;

  @override
  State<_TvEpisodeRow> createState() => _TvEpisodeRowState();
}

class _TvEpisodeRowState extends State<_TvEpisodeRow> {
  ScrollController? _scroll;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_scroll != null) return;
    final s = TvDesign.scaleOf(context);
    final index = widget.episodes.indexWhere((e) => e.id == widget.currentId);
    final step = widget.metrics.width + TvDesign.cardGap * s;
    // 当前集前面留一张,看得出前后都还有内容。
    _scroll = ScrollController(
      initialScrollOffset: index > 1 ? (index - 1) * step : 0,
    );
  }

  @override
  void dispose() {
    _scroll?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final s = TvDesign.scaleOf(context);
    final gutter = tvSafeGutter(MediaQuery.sizeOf(context).width);
    final metrics = widget.metrics;
    final episodes = widget.episodes;
    final count = episodes.length + (widget.more == null ? 0 : 1);
    return SizedBox(
      height: metrics.height + metrics.focusRoom * 2,
      child: ListView.separated(
        controller: _scroll,
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        padding: EdgeInsets.symmetric(
          horizontal: gutter,
          vertical: metrics.focusRoom,
        ),
        itemCount: count,
        separatorBuilder: (context, index) =>
            SizedBox(width: TvDesign.cardGap * s),
        itemBuilder: (context, index) {
          if (index == episodes.length) {
            return SizedBox(
              width: metrics.width,
              child: Align(alignment: Alignment.topCenter, child: widget.more),
            );
          }
          final episode = episodes[index];
          final current = episode.id == widget.currentId;
          final meta = <String>[
            if (current) l.nowPlayingEpisode,
            if (episode.canResume)
              ?remainingLabel(l, episode)
            else if (episode.userData.played)
              l.mobileWatched,
            if (episode.premiereDate != null)
              formatDateYmd(episode.premiereDate!),
          ];
          return SizedBox(
            width: metrics.width,
            child: Align(
              alignment: Alignment.topCenter,
              child: TvCard(
                key: ValueKey(episode.id),
                item: episode,
                wide: true,
                current: current,
                focusNode: widget.nodeFor(episode),
                imageMaxWidth: metrics.imageMaxWidth,
                title: episodeLabel(episode),
                subtitle: meta.join(' · '),
                badge: runtimeLabel(l, episode),
                onPressed: () => context.push(
                  DetailSourceScope.itemLocation(context, episode.id),
                  extra: DetailSourceScope.command(context, episode.id),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 整屏背景:选定条目的宣传图,左侧与底部压暗;页面下滚时整体再压暗。
class _TvDetailBackdrop extends StatelessWidget {
  const _TvDetailBackdrop({
    required this.item,
    required this.artwork,
    required this.scrolled,
  });

  final EmbyItem item;
  final EmbyItem? artwork;
  final ValueListenable<double> scrolled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = MediaQuery.sizeOf(context);
    final page = theme.scaffoldBackgroundColor;
    return Stack(
      key: const Key('tv-detail-backdrop'),
      fit: StackFit.expand,
      children: [
        ColoredBox(color: theme.colorScheme.surfaceContainerLowest),
        RepaintBoundary(
          child: MediaImage(
            item: artwork ?? item,
            smartCrop: true,
            preferBackdrop: !item.isEpisode,
            preferParentBackdrop: item.isEpisode,
            maxWidth: mediaHeroBackdropRequestWidth(
              layoutWidth: size.width,
              devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
              max: kMediaBackdropTvMaxRequestWidth,
            ),
          ),
        ),
        const TvHeroScrim(bottom: false),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                page.withValues(alpha: 0),
                page.withValues(alpha: .55),
                page.withValues(alpha: .96),
              ],
              stops: const [.35, .62, .9],
            ),
          ),
        ),
        // 下滚后逐步压暗,分集与信息不和背景图抢对比度。
        ValueListenableBuilder<double>(
          valueListenable: scrolled,
          builder: (context, offset, _) {
            final t = (offset / (size.height * .45)).clamp(0.0, 1.0);
            if (t == 0) return const SizedBox.shrink();
            return ColoredBox(color: page.withValues(alpha: t * .88));
          },
        ),
      ],
    );
  }
}

/// 头部信息块:与背景同屏,底部左对齐;操作按钮在最下面,
/// 首屏同时露出分集行的标题,提示还能往下看。
class _TvDetailHeader extends StatelessWidget {
  const _TvDetailHeader({required this.item, required this.actions});

  final EmbyItem item;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = AppLocalizations.of(context);
    final size = MediaQuery.sizeOf(context);
    final s = TvDesign.scaleOf(context);
    final gutter = tvSafeGutter(size.width);
    final overview = plainOverview(item.overview);
    final rating = item.communityRating;
    final meta = <String>[
      if (seasonEpisodeCode(item) != null) seasonEpisodeCode(item)!,
      if (item.productionYear != null) '${item.productionYear}',
      if (runtimeLabel(l, item) != null) runtimeLabel(l, item)!,
      if (item.isSeries && item.childCount != null && item.childCount! > 0)
        '${item.childCount} ${l.seasons}',
    ];
    const shadow = [Shadow(blurRadius: 12, color: Colors.black54)];
    final titleText = Text(
      item.name,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.displaySmall?.copyWith(
        color: Colors.white,
        shadows: shadow,
      ),
    );
    final textWidth = math.min(size.width * .55, 540 * s);
    return TvDarkStage(
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: size.height * .74),
        child: Padding(
          padding: EdgeInsets.fromLTRB(gutter, 40 * s, gutter, 8 * s),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (item.isEpisode && item.seriesId?.isNotEmpty == true) ...[
                TvAction(
                  key: CatalogKeys.seriesLink,
                  variant: TvActionVariant.ghost,
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onPressed: () => context.push(
                    DetailSourceScope.itemLocation(
                      context,
                      item.seriesId!,
                      seasonId: item.seasonId ?? item.parentId,
                    ),
                    extra: DetailSourceScope.command(context, item.seriesId!),
                  ),
                  child: Text(
                    item.seriesName ?? l.seasons,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                SizedBox(height: 4 * s),
              ],
              SizedBox(
                width: textWidth,
                child: !item.isEpisode && HeroLogo.available(item)
                    ? HeroLogo(
                        item: item,
                        fallback: titleText,
                        maxWidth: textWidth * .75,
                        maxHeight: 92 * s,
                        alignment: Alignment.centerLeft,
                      )
                    : titleText,
              ),
              if (meta.isNotEmpty || rating != null) ...[
                SizedBox(height: 10 * s),
                Row(
                  children: [
                    if (rating != null) ...[
                      Icon(
                        Icons.star_rounded,
                        size: 16 * s,
                        color: const Color(0xFFFFC94D),
                      ),
                      SizedBox(width: 3 * s),
                      Text(
                        rating.toStringAsFixed(1),
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: Colors.white,
                        ),
                      ),
                      SizedBox(width: 12 * s),
                    ],
                    Flexible(
                      child: Text(
                        [
                          ...meta,
                          if (item.genres.isNotEmpty)
                            item.genres.take(3).join(' / '),
                        ].join('  ·  '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: Colors.white.withValues(alpha: .82),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              if (overview != null) ...[
                SizedBox(height: 10 * s),
                SizedBox(
                  width: textWidth,
                  child: Text(
                    overview,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: Colors.white.withValues(alpha: .78),
                    ),
                  ),
                ),
              ],
              SizedBox(height: 18 * s),
              Wrap(spacing: 10 * s, runSpacing: 10 * s, children: actions),
            ],
          ),
        ),
      ),
    );
  }
}

/// 媒体信息:标签列 + 值,一行一类,不画成一堆小方块。
class _TvStreamInfo extends StatelessWidget {
  const _TvStreamInfo({required this.lines});
  final List<(String, String)> lines;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = TvDesign.scaleOf(context);
    return Column(
      key: EpisodeMediaStreamsSection.sectionKey,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (label, value) in lines)
          Padding(
            padding: EdgeInsets.only(bottom: 6 * s),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 64 * s,
                  child: Text(
                    label,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    value,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _TvDetailSkeleton extends StatelessWidget {
  const _TvDetailSkeleton();

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final s = TvDesign.scaleOf(context);
    final gutter = tvSafeGutter(size.width);
    final color = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: .07);
    Widget bone(double w, double h) => Container(
      width: w,
      height: h,
      margin: EdgeInsets.only(bottom: 12 * s),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(6 * s),
      ),
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(gutter, size.height * .38, gutter, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          bone(320 * s, 34 * s),
          bone(220 * s, 14 * s),
          bone(480 * s, 14 * s),
          bone(420 * s, 14 * s),
          SizedBox(height: 8 * s),
          Row(
            children: [
              bone(120 * s, 38 * s),
              SizedBox(width: 10 * s),
              bone(100 * s, 38 * s),
            ],
          ),
        ],
      ),
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
