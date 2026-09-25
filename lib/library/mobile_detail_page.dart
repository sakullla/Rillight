import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/content_theme.dart';
import 'package:rillight/library/detail_extras.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_motion.dart';
import 'package:rillight/app/mobile_widgets.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/widgets/skeleton.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/library/detail_controller.dart';
import 'package:rillight/library/episode_detail_sections.dart';
import 'package:rillight/library/item_format.dart';
import 'package:rillight/library/mobile_series_page.dart';
import 'package:rillight/media_image/media_image.dart';
import 'package:rillight/player/mobile_player_page.dart';
import 'package:rillight/player/player_window_host.dart';

class MobileDetailPage extends StatefulWidget {
  const MobileDetailPage({
    super.key,
    required this.itemId,
    this.initialSeasonId,
    this.initialEpisodeId,
  });

  final String itemId;
  final String? initialSeasonId;
  final String? initialEpisodeId;

  @override
  State<MobileDetailPage> createState() => _MobileDetailPageState();
}

class _MobileDetailPageState extends State<MobileDetailPage> {
  DetailController? _controller;
  List<EmbyItem> _similar = const [];
  EmbyItem? _nextEpisode;
  EmbyItem? _previousEpisode;
  EmbyException? _similarError;
  int _extrasRevision = 0;
  int? _audioStreamIndex;
  int? _subtitleStreamIndex;
  final _scroll = ScrollController();
  var _barSolid = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onDetailScroll);
  }

  void _onDetailScroll() {
    final solid = _scroll.hasClients && _scroll.offset > 72;
    if (solid == _barSolid || !mounted) {
      return;
    }
    setState(() => _barSolid = solid);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller != null) return;
    _controller = DetailController(
      auth: AuthScope.of(context),
      cache: CatalogScope.of(context).cache,
      itemId: widget.itemId,
      seasonId: widget.initialSeasonId,
      initialEpisodeId: widget.initialEpisodeId,
    );
    unawaited(_load());
  }

  @override
  void dispose() {
    _extrasRevision++;
    _scroll.removeListener(_onDetailScroll);
    _scroll.dispose();
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final controller = _controller;
    if (controller == null) return;
    await controller.load();
    if (!mounted) return;
    unawaited(_loadExtras());
  }

  Future<void> _refresh() async {
    final controller = _controller;
    if (controller == null) return;
    await controller.load();
    if (!mounted) return;
    await _loadExtras();
  }

  Future<void> _changeSeason(String id, {bool more = false}) async {
    final controller = _controller;
    if (controller == null) return;
    await controller.selectSeason(id, more: more);
  }

  Future<void> _openPreferredPlayer() async {
    final controller = _controller;
    if (controller == null) return;
    if (controller.item?.isSeries == true) {
      try {
        await controller.retainOffPageResume();
      } catch (_) {
        // A failed optional scan keeps the already loaded playable episode.
      }
    }
    if (!mounted) return;
    final target = controller.playTarget;
    if (target != null && target.isPlayable) await _openPlayer(target.id);
  }

  Future<void> _loadExtras() async {
    final controller = _controller;
    final item = controller?.item;
    if (item == null || !mounted) return;
    final revision = ++_extrasRevision;
    final auth = AuthScope.of(context);
    final identity = (
      auth.session?.server.id,
      auth.client.baseUrl,
      auth.client.userId,
    );
    bool owns() =>
        mounted &&
        revision == _extrasRevision &&
        _controller?.item?.id == item.id &&
        identity ==
            (auth.session?.server.id, auth.client.baseUrl, auth.client.userId);
    setState(() {
      _similarError = null;
      _similar = const [];
      _nextEpisode = _previousEpisode = null;
    });
    if (item.isMovie || item.isSeries) {
      final network = controller!.repository.similar(item.id);
      unawaited(() async {
        try {
          final cached = await controller.repository.cachedSimilar(item.id);
          if (owns() && cached != null && _similar.isEmpty) {
            setState(() => _similar = cached);
          }
        } catch (_) {
          // A stale cache entry does not prevent the live request.
        }
      }());
      try {
        final similar = await network;
        if (owns()) setState(() => _similar = similar);
      } catch (failure) {
        if (owns()) {
          setState(
            () => _similarError = failure is EmbyException
                ? failure
                : EmbyException(EmbyFailureKind.unknown, cause: failure),
          );
        }
      }
    }
    if (item.isEpisode) {
      final neighbors = await Future.wait<EmbyItem?>([
        auth.client.getNextEpisode(item).catchError((Object _) => null),
        auth.client.getPreviousEpisode(item).catchError((Object _) => null),
      ]);
      if (owns()) {
        setState(() {
          _nextEpisode = neighbors[0];
          _previousEpisode = neighbors[1];
        });
      }
    }
  }

  Future<void> _openPlayer(
    String itemId, {
    bool fromStart = false,
    int? startTimeTicks,
  }) async {
    final controller = _controller;
    final item = controller?.item;
    if (controller == null || item == null) return;
    final ticks = startTimeTicks;
    if (ticks != null && ticks > 0) {
      // /play 目前只把 autoResume 交给播放页。在它读取起点前写上章节时间。
      _deliverStartTicks(context, ticks);
    }
    await context.push(
      '/play/$itemId',
      extra: PlayerOpenRequest(
        itemId: itemId,
        mediaSourceId: item.isSeries ? null : controller.mediaSourceId,
        autoResume: !fromStart && (ticks == null || ticks <= 0),
        audioStreamIndex: item.isSeries ? null : _audioStreamIndex,
        subtitleStreamIndex: item.isSeries ? null : _subtitleStreamIndex,
        startTimeTicks: ticks,
      ),
    );
    if (!mounted || !AuthScope.of(context).isLoggedIn) return;
    await controller.load();
    if (!mounted || !AuthScope.of(context).isLoggedIn) return;
    CatalogScope.of(context).reloadHomeRows();
    await _loadExtras();
  }

  void _openSimilarShelf() {
    final item = _controller?.item;
    if (item == null) return;
    context.push(
      AppRoutes.shelfSimilar(
        item.id,
        title: AppLocalizations.of(context).similarRow,
      ),
    );
  }

  void _deliverStartTicks(BuildContext context, int ticks) {
    var frames = 0;
    void apply(Duration _) {
      if (!context.mounted) return;
      final player = _mountedPlayer(context)?.controller;
      if (player == null) {
        if (++frames < 6) {
          WidgetsBinding.instance.addPostFrameCallback(apply);
        }
        return;
      }
      player.startTimeTicks = ticks;
      player.autoResume = false;
    }

    WidgetsBinding.instance.addPostFrameCallback(apply);
  }

  MobilePlayerPageState? _mountedPlayer(BuildContext context) {
    Element? top;
    context.visitAncestorElements((element) {
      top = element;
      return true;
    });
    final root = top;
    if (root == null) return null;
    MobilePlayerPageState? found;
    void visit(Element element) {
      if (found != null) return;
      if (element is StatefulElement &&
          element.state is MobilePlayerPageState) {
        found = element.state as MobilePlayerPageState;
        return;
      }
      element.visitChildren(visit);
    }

    visit(root);
    return found;
  }

  /// 已看切换走 DetailController 的乐观更新(与 TV 端共用),成功后给可见反馈。
  Future<void> _togglePlayed() async {
    final controller = _controller;
    final item = controller?.item;
    if (controller == null || item == null) return;
    final next = !item.userData.played;
    final ok = await controller.togglePlayed();
    if (!mounted || !ok) return;
    final l = AppLocalizations.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(next ? l.markPlayed : l.markUnplayed)),
    );
  }

  void _openItem(String itemId) {
    context.push(AppRoutes.item(itemId));
  }

  void _openSeries(EmbyItem episode) {
    final seriesId = episode.seriesId;
    if (seriesId == null || seriesId.isEmpty) {
      return;
    }
    context.push(
      AppRoutes.item(
        seriesId,
        seasonId: episode.seasonId ?? episode.parentId,
        episodeId: episode.id,
      ),
    );
  }

  Future<void> _pickEpisode() async {
    final controller = _controller;
    final seasonId = controller?.seasonId;
    final total = controller?.episodeTotal ?? 0;
    if (controller == null || seasonId == null || total <= 0) {
      return;
    }
    final selected = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        final l = AppLocalizations.of(context);
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                0,
                AppSpacing.md,
                AppSpacing.sm,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  l.pickEpisode,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ),
            Expanded(
              child: GridView.builder(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md,
                  0,
                  AppSpacing.md,
                  AppSpacing.lg,
                ),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 6,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  childAspectRatio: 1.4,
                ),
                itemCount: total,
                itemBuilder: (context, index) {
                  final number = index + 1;
                  final current = controller.episodes.any(
                    (episode) => episode.indexNumber == number,
                  );
                  return OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      padding: EdgeInsets.zero,
                      backgroundColor: current
                          ? Theme.of(
                              context,
                            ).colorScheme.primary.withValues(alpha: 0.18)
                          : null,
                    ),
                    onPressed: () => Navigator.pop(context, number),
                    child: Text('$number'),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
    if (!mounted || selected == null) {
      return;
    }
    final start = selected <= 1 ? 0 : selected - 1;
    await controller.selectSeason(seasonId, startAt: start);
  }

  void _openGenre(EmbyItem item, String genre) {
    final types = item.isSeries || item.isEpisode ? 'Series' : 'Movie';
    final parent = item.isEpisode ? null : item.parentId;
    context.push(
      AppRoutes.shelfItems(
        parentId: parent,
        includeItemTypes: types,
        title: genre,
        recursive: true,
        genre: genre,
      ),
    );
  }

  ItemMediaSource? _source(EmbyItem item) {
    final selected = _controller?.mediaSourceId;
    for (final source in item.mediaSources) {
      if (source.id == selected) return source;
    }
    return item.mediaSources.firstOrNull;
  }

  PhoneImageHandoff? _imageHandoff(BuildContext context) {
    final extra = GoRouterState.of(context).extra;
    if (extra is! PhoneImageHandoff || extra.item.id != widget.itemId) {
      return null;
    }
    return extra;
  }

  /// 标题下只留辨认这部片子的一行:年份、时长、评分、类型。
  /// 首播和入库日期在下方的媒体信息里。
  List<PhoneMetaEntry> _bannerMeta(AppLocalizations l, EmbyItem item) {
    if (item.isSeries) {
      final seasons = _controller?.seasons ?? const <EmbyItem>[];
      return [
        if (item.productionYear != null)
          PhoneMetaEntry('${item.productionYear}'),
        if (seasons.isNotEmpty) PhoneMetaEntry(l.seasonCount(seasons.length)),
        if (item.childCount != null)
          PhoneMetaEntry(l.episodeCount(item.childCount!)),
        if (item.communityRating != null)
          PhoneMetaEntry(
            item.communityRating!.toStringAsFixed(1),
            highlight: true,
          ),
        for (final genre in item.genres)
          PhoneMetaEntry(genre, onTap: () => _openGenre(item, genre)),
      ];
    }
    final code = item.isEpisode ? seasonEpisodeCode(item) : null;
    final runtime = runtimeLabel(l, item);
    return [
      if (code != null) PhoneMetaEntry(code),
      if (item.productionYear != null) PhoneMetaEntry('${item.productionYear}'),
      if (runtime != null) PhoneMetaEntry(runtime),
      if (item.communityRating != null)
        PhoneMetaEntry(
          item.communityRating!.toStringAsFixed(1),
          highlight: true,
        ),
      for (final genre in item.genres)
        PhoneMetaEntry(genre, onTap: () => _openGenre(item, genre)),
    ];
  }

  String _playLabel(AppLocalizations l, EmbyItem item, EmbyItem? target) {
    if (target == null || !target.isPlayable) return l.noPlayableStream;
    if (item.isSeries) {
      final code = episodeLabel(target);
      return target.canResume ? l.resumePlayEpisode(code) : l.playEpisode(code);
    }
    return target.canResume ? l.resumePlay : l.play;
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final controller = _controller!;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final item = controller.item;
        final target = controller.playTarget;
        final handoff = _imageHandoff(context);
        final pending = item == null && controller.loading;
        final failed = item == null && controller.error != null;
        final imageSource = failed ? null : handoff?.item ?? item;
        final immersive = imageSource != null && !_barSolid;
        return ContentTheme(
          item: imageSource,
          preferBackdrop: handoff?.preferBackdrop ?? true,
          child: Scaffold(
            extendBodyBehindAppBar: imageSource != null,
            appBar: AppBar(
              backgroundColor: immersive ? Colors.transparent : null,
              surfaceTintColor: Colors.transparent,
              elevation: 0,
              scrolledUnderElevation: 0,
              foregroundColor: immersive ? Colors.white : null,
              actions: [
                if (item != null && !item.isSeries)
                  IconButton(
                    key: CatalogKeys.playedToggle,
                    tooltip: item.userData.played
                        ? l.markUnplayed
                        : l.markPlayed,
                    onPressed: controller.playedBusy ? null : _togglePlayed,
                    icon: Icon(
                      item.userData.played
                          ? Icons.check_circle
                          : Icons.check_circle_outline,
                      color: item.userData.played
                          ? Theme.of(context).colorScheme.primary
                          : null,
                    ),
                  ),
              ],
            ),
            body: RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                key: PageStorageKey('detail-${widget.itemId}'),
                controller: _scroll,
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.only(
                  bottom: MediaQuery.paddingOf(context).bottom + AppSpacing.lg,
                ),
                children: [
                  if (pending)
                    _PhoneDetailPending(handoff: handoff)
                  else if (failed)
                    MobileFailure(error: controller.error!, retry: _refresh)
                  else if (imageSource != null)
                    PhoneItemBanner(
                      item: imageSource,
                      title: (item ?? imageSource).name,
                      titleHint: item != null && item.isEpisode
                          ? item.seriesName
                          : null,
                      onTitleTap:
                          item != null &&
                              item.isEpisode &&
                              item.seriesId != null &&
                              item.seriesId!.isNotEmpty
                          ? () => _openSeries(item)
                          : null,
                      meta: item == null ? const [] : _bannerMeta(l, item),
                      actions: item == null
                          ? null
                          : _DetailPlayActions(
                              label: target == null
                                  ? l.noPlayableStream
                                  : _playLabel(l, item, target),
                              enabled: target != null && target.isPlayable,
                              showRestart:
                                  !item.isSeries && target?.canResume == true,
                              onPlay: target == null
                                  ? null
                                  : _openPreferredPlayer,
                              onRestart: target == null
                                  ? null
                                  : () =>
                                        _openPlayer(target.id, fromStart: true),
                              onPrevious:
                                  item.isEpisode && _previousEpisode != null
                                  ? () => _openItem(_previousEpisode!.id)
                                  : null,
                              onNext: item.isEpisode && _nextEpisode != null
                                  ? () => _openItem(_nextEpisode!.id)
                                  : null,
                            ),
                      preferBackdrop: handoff?.preferBackdrop ?? true,
                      maxWidth:
                          handoff?.maxWidth ?? PhoneMotion.pageRequestWidth,
                    ),
                  if (item != null && controller.error != null)
                    MobileFailure(error: controller.error!, retry: _refresh),
                  if (item != null) DetailAlbumStrip(item: item),
                  if (item?.isSeries == true && controller.seasonError != null)
                    MobileFailure(
                      error: controller.seasonError!,
                      retry: controller.loadSeasons,
                    ),
                  if (item != null && item.isSeries)
                    MobileSeriesPage(
                      item: item,
                      seasons: controller.seasons,
                      seasonId: controller.seasonId,
                      episodes: controller.episodes,
                      episodesLoading: controller.episodesLoading,
                      episodeError: controller.episodeError,
                      hasMore: controller.hasMore,
                      playTargetId: target?.id,
                      focusEpisodeId: widget.initialEpisodeId,
                      similar: _similar,
                      onPickEpisode: _pickEpisode,
                      onSelectSeason: _changeSeason,
                      onOpenEpisode: _openItem,
                      onRetryEpisodes: controller.seasonId == null
                          ? null
                          : () => _changeSeason(
                              controller.seasonId!,
                              more:
                                  controller.episodes.isNotEmpty &&
                                  controller.hasMore,
                            ),
                      onLoadMore: controller.seasonId == null
                          ? null
                          : () =>
                                _changeSeason(controller.seasonId!, more: true),
                      onOpenItem: _openItem,
                      onOpenSimilar: _openSimilarShelf,
                    ),
                  if (item != null && !item.isSeries)
                    _PhoneItemDetail(
                      item: item,
                      similar: _similar,
                      mediaSource: _source(item),
                      selectedAudioIndex: _audioStreamIndex,
                      selectedSubtitleIndex: _subtitleStreamIndex,
                      onAudio: (index) =>
                          setState(() => _audioStreamIndex = index),
                      onSubtitle: (index) =>
                          setState(() => _subtitleStreamIndex = index),
                      onOpenItem: _openItem,
                      onChapter: item.isPlayable
                          ? (chapter) => _openPlayer(
                              item.id,
                              startTimeTicks: chapter.startPositionTicks,
                            )
                          : null,
                      onOpenSimilar: _openSimilarShelf,
                    ),
                  if (_similarError != null)
                    MobileFailure(error: _similarError!, retry: _loadExtras),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 头部主操作:主播放按钮融入沉浸头部(`mobile-detail-play`),可续播的非剧集
/// 条目附"从头播放"次级按钮(`phone-detail-play-start`),key 与行为保持不变。
class _DetailPlayActions extends StatelessWidget {
  const _DetailPlayActions({
    required this.label,
    required this.enabled,
    required this.showRestart,
    required this.onPlay,
    required this.onRestart,
    this.onPrevious,
    this.onNext,
  });

  final String label;
  final bool enabled;
  final bool showRestart;
  final VoidCallback? onPlay;
  final VoidCallback? onRestart;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final extras = <Widget>[
      if (showRestart)
        IconButton(
          key: const Key('phone-detail-play-start'),
          tooltip: l.playFromStart,
          onPressed: onRestart,
          icon: const Icon(Icons.replay),
        ),
      if (onPrevious != null)
        IconButton(
          key: CatalogKeys.previousEpisode,
          tooltip: l.previousEpisode,
          onPressed: onPrevious,
          icon: const Icon(Icons.skip_previous),
        ),
      if (onNext != null)
        IconButton(
          key: CatalogKeys.nextEpisode,
          tooltip: l.nextEpisode,
          onPressed: onNext,
          icon: const Icon(Icons.skip_next),
        ),
    ];
    return Row(
      children: [
        Tooltip(
          message: label,
          child: FilledButton(
            key: const Key('mobile-detail-play'),
            style: FilledButton.styleFrom(
              minimumSize: const Size(48, 48),
              padding: EdgeInsets.zero,
              shape: const CircleBorder(),
            ),
            onPressed: enabled ? onPlay : null,
            child: const Icon(Icons.play_arrow, size: 28),
          ),
        ),
        if (extras.isNotEmpty) ...[
          const SizedBox(width: AppSpacing.xs),
          ...extras,
        ],
      ],
    );
  }
}

class _PhoneItemDetail extends StatelessWidget {
  const _PhoneItemDetail({
    required this.item,
    required this.similar,
    required this.mediaSource,
    required this.selectedAudioIndex,
    required this.selectedSubtitleIndex,
    required this.onAudio,
    required this.onSubtitle,
    required this.onOpenItem,
    required this.onChapter,
    required this.onOpenSimilar,
  });

  final EmbyItem item;
  final List<EmbyItem> similar;
  final ItemMediaSource? mediaSource;
  final int? selectedAudioIndex;
  final int? selectedSubtitleIndex;
  final ValueChanged<int> onAudio;
  final ValueChanged<int> onSubtitle;
  final ValueChanged<String> onOpenItem;
  final ValueChanged<ItemChapter>? onChapter;
  final VoidCallback onOpenSimilar;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (plainOverview(item.overview) != null)
          EpisodeOverviewSection(overview: item.overview, compact: true),
        if (item.chapters.isNotEmpty)
          _ChapterStrip(
            itemId: item.id,
            chapters: item.chapters,
            onChapter: onChapter,
          ),
        EpisodePeopleSection(people: item.people),
        EpisodeMediaStreamsSection(
          source: mediaSource,
          selectedAudioIndex: selectedAudioIndex,
          selectedSubtitleIndex: selectedSubtitleIndex,
          onAudio: onAudio,
          onSubtitle: onSubtitle,
        ),
        EpisodeMetadataSection(item: item),
        DetailExternalLinks(links: item.externalUrls, title: item.name),
        if (similar.isNotEmpty)
          _DetailSimilar(
            items: similar,
            onOpenItem: onOpenItem,
            onOpenSimilar: onOpenSimilar,
          ),
        const SizedBox(height: AppSpacing.lg),
      ],
    );
  }
}

/// 手机章节：横向 16:9 剧照卡，左下角时间，图下章节名。点按从该时间开播。
class _ChapterStrip extends StatelessWidget {
  const _ChapterStrip({
    required this.itemId,
    required this.chapters,
    required this.onChapter,
  });

  final String itemId;
  final List<ItemChapter> chapters;
  final ValueChanged<ItemChapter>? onChapter;

  static const double _cardWidth = 148;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final labelHeight = (theme.textTheme.labelLarge?.fontSize ?? 14) * 1.4;
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
          child: Text(l.chapters, style: theme.textTheme.titleMedium),
        ),
        WholeCardStrip(
          key: const Key('phone-chapter-strip'),
          height: _cardWidth * 9 / 16 + AppSpacing.xs + labelHeight + 6,
          itemCount: chapters.length,
          cardWidth: _cardWidth,
          gap: AppSpacing.sm,
          margin: AppSpacing.md,
          itemBuilder: (context, index) {
            return _ChapterCard(
              key: CatalogKeys.chapter(index),
              itemId: itemId,
              chapter: chapters[index],
              index: index,
              onTap: onChapter == null
                  ? null
                  : () => onChapter!(chapters[index]),
            );
          },
        ),
      ],
    );
  }
}

class _ChapterCard extends StatelessWidget {
  const _ChapterCard({
    super.key,
    required this.itemId,
    required this.chapter,
    required this.index,
    required this.onTap,
  });

  final String itemId;
  final ItemChapter chapter;
  final int index;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final name = chapter.name.trim().isEmpty ? '${index + 1}' : chapter.name;
    final hasImage = chapter.imageTag != null && chapter.imageTag!.isNotEmpty;
    return SizedBox(
      width: _ChapterStrip._cardWidth,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadii.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadii.md),
              child: SizedBox(
                width: _ChapterStrip._cardWidth,
                height: _ChapterStrip._cardWidth * 9 / 16,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (hasImage)
                      _ChapterThumb(
                        itemId: itemId,
                        index: chapter.imageIndex ?? index,
                        tag: chapter.imageTag,
                      )
                    else
                      ColoredBox(
                        color: scheme.surfaceContainerHigh,
                        child: Icon(
                          Icons.play_arrow_rounded,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    Positioned(
                      left: AppSpacing.xs,
                      bottom: AppSpacing.xs,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.62),
                          borderRadius: BorderRadius.circular(AppRadii.sm),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          child: Text(
                            chapterClock(chapter.startPositionTicks),
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: Colors.white,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelLarge,
            ),
          ],
        ),
      ),
    );
  }
}

class _ChapterThumb extends StatefulWidget {
  const _ChapterThumb({required this.itemId, required this.index, this.tag});

  final String itemId;
  final int index;
  final String? tag;

  @override
  State<_ChapterThumb> createState() => _ChapterThumbState();
}

class _ChapterThumbState extends State<_ChapterThumb> {
  Future<Uint8List?>? _future;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.tag != null && widget.tag!.isNotEmpty) {
      _future ??= loadChapterImage(
        context,
        itemId: widget.itemId,
        index: widget.index,
        tag: widget.tag,
        maxWidth: 320,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fallback = ColoredBox(
      color: scheme.surfaceContainerHigh,
      child: Icon(
        Icons.bookmark_outline_rounded,
        color: scheme.onSurfaceVariant,
      ),
    );
    return FutureBuilder<Uint8List?>(
      future: _future,
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes == null || bytes.isEmpty) {
          return fallback;
        }
        return Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true);
      },
    );
  }
}

class _DetailSimilar extends StatelessWidget {
  const _DetailSimilar({
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

/// 条目还没返回时：头图（交接图或占位）下面同时有标题、主操作和正文占位。
class _PhoneDetailPending extends StatelessWidget {
  const _PhoneDetailPending({required this.handoff});

  final PhoneImageHandoff? handoff;

  static const headerKey = Key('phone-detail-pending-header');
  static const titleKey = Key('phone-detail-pending-title');
  static const actionKey = Key('phone-detail-pending-action');
  static const bodyKey = Key('phone-detail-pending-body');

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final source = handoff;
    final width = MediaQuery.sizeOf(context).width;
    final contentWidth = width - AppSpacing.md * 2;
    final animate = !MediaQuery.disableAnimationsOf(context);
    final name = source?.item.name.trim() ?? '';
    final header = source == null
        ? SizedBox(
            height: _pendingHeaderHeight(context),
            child: SkeletonBlock(
              borderRadius: BorderRadius.zero,
              animated: animate,
            ),
          )
        : PhoneItemBanner(
            item: source.item,
            title: name,
            showCaption: false,
            preferBackdrop: source.preferBackdrop,
            maxWidth: source.maxWidth,
          );
    final title = name.isEmpty
        ? SkeletonBlock(
            key: titleKey,
            width: contentWidth * 0.5,
            height: 28,
            animated: animate,
          )
        : Text(
            name,
            key: titleKey,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
              height: 1.2,
            ),
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        KeyedSubtree(key: headerKey, child: header),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.md,
            AppSpacing.md,
            0,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(child: title),
                  const SizedBox(width: AppSpacing.sm),
                  Tooltip(
                    message: l.play,
                    child: FilledButton(
                      key: actionKey,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(48, 48),
                        padding: EdgeInsets.zero,
                        shape: const CircleBorder(),
                      ),
                      onPressed: null,
                      child: const Icon(Icons.play_arrow, size: 28),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              Column(
                key: bodyKey,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SkeletonBlock(
                    width: contentWidth,
                    height: 14,
                    animated: animate,
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  SkeletonBlock(
                    width: contentWidth * 0.72,
                    height: 14,
                    animated: animate,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  SkeletonBlock(
                    width: contentWidth,
                    height: 96,
                    animated: animate,
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

double _pendingHeaderHeight(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  final byWidth = size.width * 9 / 16;
  final cap = size.height * 0.5;
  return byWidth < cap ? byWidth : cap;
}
