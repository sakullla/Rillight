import 'dart:async';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:rillight/app/ui/app_icons.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/library/detail_source_scope.dart';
import 'package:rillight/media_server/models.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/hero_artwork.dart';
import 'package:rillight/home/hero_logo.dart';
import 'package:rillight/library/detail_controller.dart';
import 'package:rillight/library/tv_library_page.dart';
import 'package:rillight/library/episode_detail_sections.dart';
import 'package:rillight/library/episode_range_bar.dart';
import 'package:rillight/library/detail_extras.dart';
import 'package:rillight/library/item_format.dart';
import 'package:rillight/library/season_switcher.dart';
import 'package:rillight/library/source_selection.dart';
import 'package:rillight/media_image/media_image.dart';
import 'package:rillight/player/player_window_host.dart';

/// 电视详情:整屏背景图固定在后面,信息与操作压在左下;向下是季与分集行、
/// 剧照和详细信息。滚动时背景逐步压暗,下方内容始终读得清。
class TvDetailPage extends StatefulWidget {
  const TvDetailPage({
    super.key,
    required this.itemId,
    this.initialSeasonId,
    this.initialEpisodeId,
  });
  final String itemId;
  final String? initialSeasonId;
  final String? initialEpisodeId;
  @override
  State<TvDetailPage> createState() => _TvDetailPageState();
}

class _TvDetailPageState extends State<TvDetailPage> {
  /// 季切换折叠为单个焦点按钮时的返回焦点 id。
  static const _seasonPickerFocus = 'season-picker';

  DetailController? _controller;
  final _focus = TvReturnFocus();
  final _scrolled = ValueNotifier<double>(0);
  bool _playBusy = false;

  /// 单集的前后集：条目载入后各取一次，供头部「上一集/下一集」。
  String? _neighborsFor;
  MediaItem? _previous, _next;

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
      initialEpisodeId: widget.initialEpisodeId,
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
      final request = await DetailSourceScope.playbackRequest(
        context,
        target.id,
      );
      if (!mounted) return;
      await context.push(
        '/play/${target.id}',
        extra: PlayerOpenRequest(
          itemId: target.id,
          source: request.source,
          libraryId: request.libraryId,
          accessGeneration: request.accessGeneration,
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
    showAppNotice(context, next ? l.markPlayed : l.markUnplayed);
  }

  Future<void> _toggleFavorite() async {
    final c = _controller!;
    final item = c.item;
    if (item == null) return;
    final next = !item.userData.favorite;
    final ok = await c.toggleFavorite();
    if (!mounted) return;
    final l = AppLocalizations.of(context);
    showAppNotice(
      context,
      !ok
          ? l.phoneFavoriteFailed
          : next
          ? l.phoneFavoriteAdded
          : l.phoneFavoriteRemoved,
    );
  }

  void _loadNeighbors(MediaItem item) {
    if (!item.isEpisode || _neighborsFor == item.id) return;
    _neighborsFor = item.id;
    _previous = _next = null;
    final client = DetailSourceScope.clientOf(context);
    Future.wait<MediaItem?>([
      client.getPreviousEpisode(item).catchError((Object _) => null),
      client.getNextEpisode(item).catchError((Object _) => null),
    ]).then((neighbors) {
      if (!mounted || _neighborsFor != item.id) return;
      setState(() {
        _previous = neighbors[0];
        _next = neighbors[1];
      });
    });
  }

  void _openEpisode(MediaItem episode) {
    context.push(
      DetailSourceScope.itemLocation(context, episode.id),
      extra: DetailSourceScope.command(context, episode.id),
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
          _seasonPickerFocus,
          for (final season in c.seasons) 'season:${season.id}',
          for (final episode in c.episodes) 'episode:${episode.id}',
        ]);
        final item = c.item, target = c.playTarget;
        if (item != null && item.isEpisode && _neighborsFor != item.id) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _loadNeighbors(item);
          });
        }
        final season = c.seasons.where((s) => s.id == c.seasonId).firstOrNull;
        final artwork = item?.isSeries == true && season != null
            ? seasonArtworkItem(season, item!)
            : item;
        final size = MediaQuery.sizeOf(context);
        final s = TvDesign.scaleOf(context);
        final gutter = tvSafeGutter(size.width);
        final pad = EdgeInsets.symmetric(horizontal: gutter);
        Widget section(String title, Widget child) => Padding(
          padding: EdgeInsets.fromLTRB(gutter, AppSpacing.lg * s, gutter, 0),
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
                    holdUntilReady: item.isSeries,
                    blockAdvance: c.episodeError != null,
                    settled: c.episodeError == null && !c.episodesLoading,
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
                          source: source,
                          resume: target?.canResume == true ? target : null,
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
                              spacing: AppSpacing.xs * s,
                              runSpacing: AppSpacing.xs * s,
                              children: [
                                for (final option in item.mediaSources)
                                  TvAction(
                                    key: ValueKey(option.id),
                                    pill: true,
                                    selected: c.mediaSourceId == option.id,
                                    leading: c.mediaSourceId == option.id
                                        ? const Icon(CupertinoIcons.check_mark)
                                        : null,
                                    onPressed: () => c.selectSource(option.id),
                                    child: Text(option.name ?? option.id),
                                  ),
                              ],
                            ),
                          ),
                        if (item.isSeries) ..._episodes(context, c, target),
                        // 演职员分区自带标题与页面边距，这里补齐到电视安全区。
                        Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: math.max(0, gutter - AppSpacing.page),
                          ),
                          child: EpisodePeopleSection(people: item.people),
                        ),
                        // 剧照条自己在没有图时收起；标题与横条对齐安全区。
                        Padding(
                          padding: EdgeInsets.fromLTRB(gutter, 10 * s, 0, 0),
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
                            AppSpacing.xl * s,
                            gutter,
                            0,
                          ),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: TvAction(
                              key: const Key('tv-detail-refresh'),
                              pill: true,
                              leading: const Icon(
                                CupertinoIcons.arrow_clockwise,
                              ),
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

  List<Widget> _actions(
    BuildContext context,
    MediaItem item,
    MediaItem? target,
  ) {
    final l = AppLocalizations.of(context);
    final c = _controller!;
    return [
      TvAction(
        key: const Key('tv-detail-play'),
        emphasized: true,
        autofocus: true,
        pill: true,
        leading: const Icon(AppIcons.play, fill: AppIcons.filled),
        onPressed:
            !_playBusy && target != null && (target.isMovie || target.isEpisode)
            ? _play
            : null,
        child: Text(_playLabel(l, item, target)),
      ),
      if (target?.canResume == true)
        TvAction(
          pill: true,
          leading: const Icon(CupertinoIcons.arrow_counterclockwise),
          onPressed: _playBusy ? null : () => _play(fromStart: true),
          child: Text(l.playFromStart),
        ),
      if (item.isEpisode && _previous != null)
        TvAction(
          key: CatalogKeys.previousEpisode,
          pill: true,
          leading: const Icon(AppIcons.skipPrevious, fill: AppIcons.filled),
          onPressed: () => _openEpisode(_previous!),
          child: Text(l.previousEpisode),
        ),
      if (item.isEpisode && _next != null)
        TvAction(
          key: CatalogKeys.nextEpisode,
          pill: true,
          leading: const Icon(AppIcons.skipNext, fill: AppIcons.filled),
          onPressed: () => _openEpisode(_next!),
          child: Text(l.nextEpisode),
        ),
      // 收藏、已看紧跟导航动作，三类详情页位置一致；遥控器没有悬停，
      // 一律带字。两者是开关：激活时 primaryContainer 实底加填充图标，
      // 标签改写为状态（已收藏、已看），读屏另有 toggled。
      if (c.supportsFavorite)
        TvAction(
          key: const Key('tv-detail-favorite'),
          pill: true,
          active: item.userData.favorite,
          leading: Icon(
            AppIcons.favorite,
            fill: item.userData.favorite ? AppIcons.filled : AppIcons.outline,
          ),
          onPressed: c.favoriteBusy ? null : _toggleFavorite,
          child: Text(
            item.userData.favorite ? l.phoneFavorited : l.phoneFavorite,
          ),
        ),
      if (!item.isSeries)
        TvAction(
          key: const Key('tv-detail-played-toggle'),
          pill: true,
          active: item.userData.played,
          leading: Icon(
            item.userData.played
                ? CupertinoIcons.checkmark_circle_fill
                : CupertinoIcons.checkmark_circle,
          ),
          onPressed: c.playedBusy ? null : _togglePlayed,
          child: Text(item.userData.played ? l.watchedAction : l.markPlayed),
        ),
      // 跨服务器「其他来源」：电视没有悬停提示，图标钮读不出含义，
      // 改为带字胶囊排在行尾；打开对话框期间保持可聚焦，关闭后焦点回到这里。
      if (SourceSelectionAction.availableIn(context))
        SourceSelectionAction(
          builder: (context, view) => Semantics(
            button: true,
            label: view.label,
            excludeSemantics: true,
            child: TvAction(
              key: SourceSelectionActionView.key,
              pill: true,
              leading: Icon(view.icon),
              onPressed: view.onPressed,
              child: Text(view.shortLabel),
            ),
          ),
        ),
    ];
  }

  /// 剧集页的主操作写明要播哪一集，进页面就知道按下去会发生什么。
  String _playLabel(AppLocalizations l, MediaItem item, MediaItem? target) {
    if (target == null) return l.noPlayableStream;
    if (item.isSeries && target.isEpisode) {
      final code = seasonEpisodeCode(target) ?? episodeLabel(target);
      return target.canResume ? l.resumePlayEpisode(code) : l.playEpisode(code);
    }
    return target.canResume ? l.resumePlay : l.play;
  }

  List<Widget> _episodes(
    BuildContext context,
    DetailController c,
    MediaItem? target,
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
                style: AppUiTheme.of(context).textTheme.titleLarge,
              ),
            ),
            SizedBox(width: AppSpacing.lg * s),
            // 共享季切换器的 TV 呈现：放得下时是一排焦点标签，放不下时折叠为
            // 一个焦点按钮，按下弹出可聚焦的季列表。标签沿用 `season:<id>`
            // 焦点节点，从按钮行按「下」直接落到这里。
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      widthFactor: 1,
                      child: SeasonSwitcher(
                        platform: SeasonSwitcherPlatform.tv,
                        seasons: c.seasons,
                        currentId: c.seasonId,
                        tabKey: (id) => ValueKey(id),
                        focusNodeFor: (id) => _focus.nodeFor('season:$id'),
                        pickerFocusNode: _focus.nodeFor(_seasonPickerFocus),
                        onSelected: (id) => c.selectSeason(id),
                      ),
                    ),
                  ),
                  // 长季分段紧跟在季入口后面，读作「第 2 季 › 51–100」。
                  if (EpisodeRanges.show(c.episodeTotal) &&
                      c.seasonId != null) ...[
                    SizedBox(width: AppSpacing.xs * s),
                    _TvRangeButton(
                      total: c.episodeTotal,
                      activeNumber:
                          c.episodes.firstOrNull?.indexNumber ??
                          c.windowStart + 1,
                      onSelected: (start) =>
                          c.selectSeason(c.seasonId!, startAt: start - 1),
                    ),
                  ],
                ],
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
          padding: EdgeInsets.fromLTRB(gutter, AppSpacing.xs * s, gutter, 0),
          child: Builder(
            builder: (context) => Text(
              l.mobileEmpty,
              style: TextStyle(
                color: AppUiTheme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      if (c.episodes.isNotEmpty)
        _TvEpisodeRow(
          key: ValueKey('tv-episodes-${c.seasonId}'),
          episodes: c.episodes,
          currentId: _tvEpisodeAnchor(c, target),
          metrics: metrics,
          nodeFor: (episode) => _focus.nodeFor('episode:${episode.id}'),
          // 遥控器一格一格按到行尾很慢：「更多」卡快进入视野时就自动续载，
          // 卡片本身保留，失败后仍可按确认重试。
          more: c.hasMore
              ? AutoLoadTrigger(
                  token: c.episodesLoading || c.episodeError != null
                      ? -1
                      : c.episodes.length,
                  onTrigger: () {
                    if (!c.episodesLoading && c.hasMore) {
                      c.selectSeason(c.seasonId!, more: true);
                    }
                  },
                  child: TvMoreTile(
                    key: const Key('tv-episodes-more'),
                    metrics: metrics,
                    label: l.mobileLoadMore,
                    onPressed: c.episodesLoading
                        ? null
                        : () => c.selectSeason(c.seasonId!, more: true),
                  ),
                )
              : null,
        ),
    ];
  }
}

/// 分集行要露出的那一集:从分集详情进来时是该集,否则是这一季的续播或下一集。
String? _tvEpisodeAnchor(DetailController controller, MediaItem? playTarget) {
  final requested = controller.initialEpisodeId?.trim();
  if (requested != null &&
      requested.isNotEmpty &&
      controller.episodes.any((episode) => episode.id == requested)) {
    return requested;
  }
  final target = playTarget?.id;
  if (target != null &&
      controller.episodes.any((episode) => episode.id == target)) {
    return target;
  }
  return null;
}

/// 分集横向行:把当前集滚进视口,长剧不用从第一集一路按过去。
class _TvEpisodeRow extends StatefulWidget {
  const _TvEpisodeRow({
    super.key,
    required this.episodes,
    required this.currentId,
    required this.metrics,
    required this.nodeFor,
    this.more,
  });

  final List<MediaItem> episodes;
  final String? currentId;
  final TvCardMetrics metrics;
  final FocusNode Function(MediaItem episode) nodeFor;
  final Widget? more;

  @override
  State<_TvEpisodeRow> createState() => _TvEpisodeRowState();
}

class _TvEpisodeRowState extends State<_TvEpisodeRow> {
  // 详情页纵向列表已经占用了这条路由的 PageStorage。分集行若再恢复它,
  // 点季后会停在纵向偏移上,而不是这一季对应的集。
  ScrollController? _scroll;
  int _alignGeneration = 0;

  @override
  void initState() {
    super.initState();
    _scheduleAlign();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 首帧就用目标偏移。keepScrollOffset 为 false 时,这个值不会被
    // 详情页已经滚过的纵向位置盖掉。
    _scroll ??= ScrollController(
      keepScrollOffset: false,
      initialScrollOffset: _desiredOffset(),
    );
  }

  @override
  void didUpdateWidget(_TvEpisodeRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldIndex = oldWidget.episodes.indexWhere(
      (episode) => episode.id == oldWidget.currentId,
    );
    final index = widget.episodes.indexWhere(
      (episode) => episode.id == widget.currentId,
    );
    if (oldWidget.currentId != widget.currentId ||
        oldIndex != index ||
        oldWidget.episodes.length != widget.episodes.length) {
      _scheduleAlign();
    }
  }

  void _scheduleAlign() {
    final generation = ++_alignGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) => _align(generation, 0));
  }

  double _slot() =>
      widget.metrics.width + TvDesign.cardGap * TvDesign.scaleOf(context);

  /// 当前集前面留一张,看得出前后都还有内容。
  double _offsetFor(int index) => index > 1 ? (index - 1) * _slot() : 0;

  double _desiredOffset() {
    final index = widget.episodes.indexWhere(
      (episode) => episode.id == widget.currentId,
    );
    return _offsetFor(index);
  }

  void _align(int generation, int attempt) {
    if (!mounted ||
        generation != _alignGeneration ||
        _scroll?.hasClients != true) {
      return;
    }
    final position = _scroll!.position;
    if (attempt >= 24) return;
    if (!position.hasContentDimensions) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _align(generation, attempt + 1),
      );
      return;
    }
    final index = widget.episodes.indexWhere(
      (episode) => episode.id == widget.currentId,
    );
    final raw = _offsetFor(index);
    final max = position.maxScrollExtent;
    // 懒加载列表首帧还不知道全程。先推到已知末端,下一帧再对准。
    if (raw > max + 1) {
      if (position.pixels != max) position.jumpTo(max);
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _align(generation, attempt + 1),
      );
      return;
    }
    final target = raw.clamp(0.0, max);
    if ((position.pixels - target).abs() > 1) position.jumpTo(target);
  }

  /// 槽宽包含间距。卡片保持原宽度并靠左，间距留在右侧。
  Widget _slotChild(Widget child) {
    return Align(alignment: Alignment.topLeft, child: child);
  }

  @override
  void dispose() {
    _alignGeneration++;
    _scroll?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final gutter = tvSafeGutter(MediaQuery.sizeOf(context).width);
    final metrics = widget.metrics;
    final episodes = widget.episodes;
    final count = episodes.length + (widget.more == null ? 0 : 1);
    return SizedBox(
      height: metrics.height + metrics.focusRoom * 2,
      child: ListView.builder(
        controller: _scroll!,
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        // 固定槽宽后首帧就知道滚动范围,切季能直接落到对应集。
        itemExtent: _slot(),
        padding: EdgeInsets.symmetric(
          horizontal: gutter,
          vertical: metrics.focusRoom,
        ),
        itemCount: count,
        itemBuilder: (context, index) {
          if (index == episodes.length) {
            return _slotChild(
              SizedBox(
                width: metrics.width,
                child: Align(
                  alignment: Alignment.topCenter,
                  child: widget.more,
                ),
              ),
            );
          }
          final episode = episodes[index];
          final current = episode.id == widget.currentId;
          // 当前集由实心圆标和主色标题标出，续播由进度条标出，已看由角标标出。
          final meta = <String>[
            if (episode.premiereDate != null)
              formatDateYmd(episode.premiereDate!),
          ];
          return _slotChild(
            SizedBox(
              width: metrics.width,
              child: TvCard(
                key: ValueKey(episode.id),
                item: episode,
                wide: true,
                current: current,
                focusNode: widget.nodeFor(episode),
                imageMaxWidth: metrics.imageMaxWidth,
                // 「N. 集名」；集名已以集数开头（「第 3 集 …」）时直接用集名，
                // 不再叠一层 S1E3 前缀。
                title: numberedEpisodeTitle(episode),
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
///
/// 剧集切季时,上一张已绘制的图留到新季头图按同一候选和请求宽度进入缓存。
/// 未就绪或加载失败不换成新季的 [MediaImage];分集失败则退回切换前。
class _TvDetailBackdrop extends StatefulWidget {
  const _TvDetailBackdrop({
    required this.item,
    required this.artwork,
    required this.holdUntilReady,
    required this.blockAdvance,
    required this.settled,
    required this.scrolled,
  });

  final MediaItem item;
  final MediaItem? artwork;

  /// 为真时,新头图能绘制前不更换正在显示的图。
  final bool holdUntilReady;

  /// 这一季的分集失败。进行中的换图取消,已经换上的退回切换前。
  final bool blockAdvance;

  /// 分集请求已经结束且没有错误。可以丢掉退回用的上一张图。
  final bool settled;
  final ValueListenable<double> scrolled;

  @override
  State<_TvDetailBackdrop> createState() => _TvDetailBackdropState();
}

class _TvDetailBackdropState extends State<_TvDetailBackdrop> {
  MediaItem? _shown;
  MediaItem? _before;
  String? _advancingId;
  String? _failedId;
  int _serial = 0;

  bool get _preferBackdrop => !widget.item.isEpisode;

  bool get _preferParentBackdrop => widget.item.isEpisode;

  MediaItem get _requested => widget.artwork ?? widget.item;

  @override
  void initState() {
    super.initState();
    _shown = _requested;
  }

  @override
  void didUpdateWidget(_TvDetailBackdrop oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  @override
  void dispose() {
    _serial++;
    super.dispose();
  }

  void _sync() {
    final requested = _requested;
    if (!widget.holdUntilReady) {
      _serial++;
      _advancingId = null;
      _failedId = null;
      _before = null;
      _shown = requested;
      return;
    }
    _shown ??= requested;
    final identity = _imageIdentity(requested);
    if (widget.blockAdvance) {
      _serial++;
      _advancingId = null;
      final shown = _shown;
      final before = _before;
      if (before != null &&
          shown != null &&
          _imageIdentity(shown) == identity) {
        _shown = before;
        _before = null;
      }
      return;
    }
    if (_imageIdentity(_shown!) == identity) {
      if (widget.settled) {
        _before = null;
        _advancingId = null;
        _failedId = null;
      }
      return;
    }
    if (_failedId != null && _failedId != identity) _failedId = null;
    if (_failedId == identity || _advancingId == identity) return;
    _advancingId = identity;
    final serial = ++_serial;
    final previous = _shown!;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || serial != _serial || _advancingId != identity) return;
      unawaited(
        _reveal(requested, identity, previous, serial, _requestWidth()),
      );
    });
  }

  Future<void> _reveal(
    MediaItem requested,
    String identity,
    MediaItem previous,
    int serial,
    int width,
  ) async {
    final ready = await _artworkReady(
      requested,
      maxWidth: width,
      current: () =>
          mounted &&
          serial == _serial &&
          !widget.blockAdvance &&
          _imageIdentity(_requested) == identity,
    );
    if (!mounted || serial != _serial || widget.blockAdvance) return;
    if (_imageIdentity(_requested) != identity) return;
    if (!ready) {
      _failedId = identity;
      _advancingId = null;
      return;
    }
    setState(() {
      _before = previous;
      _shown = requested;
      _advancingId = null;
    });
  }

  String _imageIdentity(MediaItem item) =>
      '${item.id}|${item.primaryImageTag}|${item.thumbImageTag}|'
      '${item.backdropImageTag}|${item.parentBackdropItemId}|'
      '${item.parentBackdropImageTag}|${item.seriesPrimaryImageTag}';

  int _requestWidth() {
    final size = MediaQuery.sizeOf(context);
    return mediaHeroBackdropRequestWidth(
      layoutWidth: size.width,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      max: kMediaBackdropTvMaxRequestWidth,
    );
  }

  /// 与背景 [MediaImage] 同一条候选和请求宽度。字节进缓存后才允许换图。
  Future<bool> _artworkReady(
    MediaItem artwork, {
    required int maxWidth,
    required bool Function() current,
  }) async {
    if (!current()) return false;
    final auth = AuthScope.maybeOf(context);
    final policy = DetailSourceScope.imagePolicyOf(context);
    final scope = policy != null
        ? (policy.isValid ? policy.scope : null)
        : mediaImageAccountScope(auth);
    if (scope == null) return false;
    final client =
        DetailSourceScope.maybeOf(context)?.client ?? auth?.imageClient;
    if (client == null) return false;
    final candidates = artwork.imageCandidates(
      preferBackdrop: _preferBackdrop,
      preferParentBackdrop: _preferParentBackdrop,
    );
    for (final candidate in candidates) {
      if (!current()) return false;
      final peeked = MediaImageCache.instance.peek(
        serverId: scope,
        itemId: candidate.itemId,
        type: candidate.type,
        tag: candidate.tag,
        maxWidth: maxWidth,
      );
      if (peeked != null && peeked.isNotEmpty) return true;
      if (MediaImageCache.instance.isNegativeCached(
        serverId: scope,
        itemId: candidate.itemId,
        type: candidate.type,
        tag: candidate.tag,
        maxWidth: maxWidth,
      )) {
        continue;
      }
      CancelToken? token;
      try {
        final bytes = await MediaImageCache.instance.load(
          policy: policy,
          serverId: scope,
          itemId: candidate.itemId,
          type: candidate.type,
          tag: candidate.tag,
          maxWidth: maxWidth,
          isCurrent: current,
          inViewport: current,
          fetch: () async {
            if (!current()) return null;
            token = CancelToken();
            final data = await client.getItemImage(
              candidate.itemId,
              type: candidate.type,
              tag: candidate.tag,
              maxWidth: maxWidth,
              cancelToken: token,
            );
            if (data.isEmpty) return null;
            return Uint8List.fromList(data);
          },
          onAbort: () => token?.cancel('tv-season-artwork'),
        );
        if (!current()) return false;
        if (bytes != null && bytes.isNotEmpty) return true;
      } catch (_) {
        // 下一张候选仍可能画得出来。
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final size = MediaQuery.sizeOf(context);
    final page = theme.scaffoldBackgroundColor;
    final shown = _shown ?? _requested;
    return Stack(
      key: const Key('tv-detail-backdrop'),
      fit: StackFit.expand,
      children: [
        ColoredBox(color: theme.colorScheme.surfaceContainerLowest),
        RepaintBoundary(
          child: MediaImage(
            item: shown,
            smartCrop: true,
            preferBackdrop: _preferBackdrop,
            preferParentBackdrop: _preferParentBackdrop,
            // 默认不保留上一帧。这里只盖住换源后的解码空隙,不改 MediaImage 的默认值。
            retainVisibleFrame: true,
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
          valueListenable: widget.scrolled,
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
  const _TvDetailHeader({
    required this.item,
    required this.actions,
    this.source,
    this.resume,
  });

  final MediaItem item;
  final List<Widget> actions;

  /// 当前片源：头部画质/声道标签只描述它。
  final ItemMediaSource? source;

  /// 有续播进度的播放目标（电影/单集本身，或剧集的续播集）。
  final MediaItem? resume;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
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
    final badges = item.isSeries ? const <String>[] : mediaTechBadges(source);
    final shadow = [Shadow(blurRadius: 12, color: AppInk.scrim(.54))];
    // 长标题在 200% 字号下按宽度自然换行，头部随内容增高，不省略。
    final titleText = Text(
      item.name,
      key: const Key('tv-detail-title'),
      style: theme.textTheme.displaySmall?.copyWith(
        color: AppInk.white,
        shadows: shadow,
      ),
    );
    final textWidth = math.min(size.width * .55, 540 * s);
    return TvDarkStage(
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: size.height * .74),
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            gutter,
            AppSpacing.xxxl * s,
            gutter,
            AppSpacing.xs * s,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (item.isEpisode && item.seriesId?.isNotEmpty == true) ...[
                TvAction(
                  key: CatalogKeys.seriesLink,
                  variant: TvActionVariant.ghost,
                  trailing: const Icon(CupertinoIcons.chevron_right),
                  onPressed: () => context.push(
                    DetailSourceScope.itemLocation(
                      context,
                      item.seriesId!,
                      seasonId: item.seasonId ?? item.parentId,
                      episodeId: item.id,
                    ),
                    extra: DetailSourceScope.command(context, item.seriesId!),
                  ),
                  child: Text(
                    item.seriesName ?? l.seasons,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                SizedBox(height: AppSpacing.xxs * s),
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
                        CupertinoIcons.star_fill,
                        size: 16 * s,
                        color: AppBrand.ratingStar(theme.brightness),
                      ),
                      SizedBox(width: 3 * s),
                      Text(
                        rating.toStringAsFixed(1),
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: AppInk.white,
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
                        key: const Key('tv-detail-meta'),
                        style: theme.textTheme.bodyLarge?.copyWith(
                          height: 1.3,
                          color: AppInk.white.withValues(alpha: .82),
                        ),
                      ),
                    ),
                    for (final badge in badges) ...[
                      SizedBox(width: AppSpacing.xs * s),
                      _TvBadge(label: badge),
                    ],
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
                    style: theme.textTheme.bodyLarge?.copyWith(
                      height: 1.3,
                      color: AppInk.white.withValues(alpha: .78),
                    ),
                  ),
                ),
              ],
              if (resume != null) ...[
                SizedBox(height: 14 * s),
                _TvResumeBar(item: resume!),
              ],
              SizedBox(height: AppSpacing.lg * s),
              Wrap(spacing: 10 * s, runSpacing: 10 * s, children: actions),
            ],
          ),
        ),
      ),
    );
  }
}

/// 头部画质/声道描边小标签，压在背景图上始终是白字。
class _TvBadge extends StatelessWidget {
  const _TvBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final s = TvDesign.scaleOf(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppInk.white.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(AppRadii.xs * s),
        // 发丝描边:只做轻量分组,不抢封面和标题。
        border: Border.all(color: AppEdge.of(Brightness.dark, strong: true)),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 7 * s, vertical: 2 * s),
        child: Text(
          label,
          style: AppUiTheme.of(context).textTheme.labelLarge?.copyWith(
            color: AppInk.white.withValues(alpha: .88),
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

/// 续播进度：一条细进度和「剩余 N 分钟」，与主操作的「继续播放」呼应。
class _TvResumeBar extends StatelessWidget {
  const _TvResumeBar({required this.item});

  final MediaItem item;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = AppUiTheme.of(context);
    final s = TvDesign.scaleOf(context);
    final remaining = remainingLabel(l, item);
    final code = item.isEpisode ? seasonEpisodeCode(item) : null;
    return Row(
      key: const Key('tv-detail-resume'),
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(2 * s),
          child: SizedBox(
            width: 180 * s,
            child: AppLoadingBar(
              value: item.playbackProgress.clamp(0, 1),
              minHeight: 3 * s,
              color: theme.colorScheme.primary,
              backgroundColor: AppInk.white.withValues(alpha: .22),
            ),
          ),
        ),
        if (remaining != null) ...[
          SizedBox(width: 10 * s),
          Text(
            [?code, remaining].join(' · '),
            style: theme.textTheme.labelLarge?.copyWith(
              color: AppInk.white.withValues(alpha: .82),
            ),
          ),
        ],
      ],
    );
  }
}

/// 媒体信息:标签列 + 值,一行一类,不画成一堆小方块。
class _TvStreamInfo extends StatelessWidget {
  const _TvStreamInfo({required this.lines});
  final List<(String, String)> lines;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
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
    final color = AppUiTheme.of(context).colorScheme.onSurface
        .withValues(alpha: .07);
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
          SizedBox(height: AppSpacing.xs * s),
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

ItemMediaSource? _tvSource(MediaItem item, String? id) {
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

/// TV 长季分段入口：一个焦点按钮写着当前段（如「51–100 ˅」），按下弹出
/// 可聚焦的分段列表。遥控器上横向分段条要一格格移动，列表更快。
class _TvRangeButton extends StatelessWidget {
  const _TvRangeButton({
    required this.total,
    required this.activeNumber,
    required this.onSelected,
  });

  final int total;
  final int activeNumber;
  final ValueChanged<int> onSelected;

  static const buttonKey = Key('tv-episode-range');

  Future<void> _pick(BuildContext context) async {
    final ranges = EpisodeRanges.of(total);
    final active = EpisodeRanges.indexOf(total, activeNumber);
    final picked = await showAppDialog<int>(
      context: context,
      useRootNavigator: false,
      builder: (context) {
        final l = AppLocalizations.of(context);
        final s = TvDesign.scaleOf(context);
        return AppDialog(
          maxWidth: 360 * s,
          title: Text(l.episodeRangesTitle),
          content: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * .6,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < ranges.length; i++)
                    Padding(
                      padding: EdgeInsets.only(bottom: 4 * s),
                      child: TvChoiceTile(
                        actionKey: EpisodeRangeBar.chipKey(ranges[i].start),
                        label: l.episodeRangeLabel(
                          ranges[i].start,
                          ranges[i].end,
                        ),
                        selected: i == active,
                        autofocus: i == active,
                        onPressed: () =>
                            Navigator.of(context).pop(ranges[i].start),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
    if (picked != null) onSelected(picked);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final range = EpisodeRanges.of(
      total,
    )[EpisodeRanges.indexOf(total, activeNumber)];
    return Semantics(
      button: true,
      label: l.episodeRangeSemantic(range.start, range.end),
      excludeSemantics: true,
      child: TvAction(
        key: buttonKey,
        variant: TvActionVariant.ghost,
        selected: true,
        trailing: const Icon(CupertinoIcons.chevron_down),
        onPressed: () => _pick(context),
        child: Text(l.episodeRangeLabel(range.start, range.end)),
      ),
    );
  }
}
