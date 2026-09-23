import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_motion.dart';
import 'package:rillight/app/mobile_widgets.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_models.dart';
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
  });

  final String itemId;
  final String? initialSeasonId;

  @override
  State<MobileDetailPage> createState() => _MobileDetailPageState();
}

class _MobileDetailPageState extends State<MobileDetailPage> {
  DetailController? _controller;
  List<EmbyItem> _similar = const [];
  EmbyItem? _nextEpisode;
  EmbyItem? _previousEpisode;
  int? _audioStreamIndex;
  int? _subtitleStreamIndex;
  bool _playedBusy = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller != null) return;
    _controller = DetailController(
      auth: AuthScope.of(context),
      cache: CatalogScope.of(context).cache,
      itemId: widget.itemId,
      seasonId: widget.initialSeasonId,
    );
    unawaited(_load());
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final controller = _controller;
    if (controller == null) return;
    if (controller.seasonId == null) {
      try {
        final season = await _seasonForPlayback(controller);
        if (!mounted) return;
        if (season != null) controller.seasonId = season;
      } catch (_) {
        // load() surfaces the item failure.
      }
    }
    if (!mounted) return;
    await controller.load();
    if (!mounted) return;
    await controller.retainOffPageResume();
    if (!mounted) return;
    await _loadExtras();
  }

  Future<void> _refresh() async {
    final controller = _controller;
    if (controller == null) return;
    await controller.load();
    if (!mounted) return;
    await controller.retainOffPageResume();
    if (!mounted) return;
    await _loadExtras();
  }

  Future<void> _changeSeason(String id, {bool more = false}) async {
    final controller = _controller;
    if (controller == null) return;
    await controller.selectSeason(id, more: more);
    if (!mounted) return;
    await controller.retainOffPageResume();
  }

  /// 续播季优先，否则第一条未看所在季，再否则第一季。
  Future<String?> _seasonForPlayback(DetailController controller) async {
    final item = await controller.repository.item(widget.itemId);
    if (!item.isSeries) return null;
    final seasons = await controller.repository.seasons(item.id);
    String? unwatched;
    for (final season in seasons) {
      var start = 0;
      while (true) {
        final page = await controller.repository.episodes(
          season.id,
          start: start,
        );
        if (page.items.any((episode) => episode.canResume)) return season.id;
        if (unwatched == null &&
            page.items.any((episode) => !episode.userData.played)) {
          unwatched = season.id;
        }
        final loaded = page.items.length;
        if (loaded == 0) break;
        start += loaded;
        final total = page.totalRecordCount;
        final more = total == null ? loaded == 50 : start < total;
        if (!more) break;
      }
    }
    return unwatched ?? seasons.firstOrNull?.id;
  }

  Future<void> _loadExtras() async {
    final item = _controller?.item;
    if (item == null || !mounted) return;
    final client = AuthScope.of(context).client;
    var similar = const <EmbyItem>[];
    EmbyItem? next;
    EmbyItem? previous;
    if (item.isMovie || item.isSeries) {
      try {
        similar = await client.getSimilar(item.id, limit: 12);
      } catch (_) {
        similar = const [];
      }
    }
    if (item.isEpisode) {
      try {
        next = await client.getNextEpisode(item);
      } catch (_) {
        next = null;
      }
      try {
        previous = await _previousEpisodeOf(client, item);
      } catch (_) {
        previous = null;
      }
    }
    if (!mounted || _controller?.item?.id != item.id) return;
    setState(() {
      _similar = similar;
      _nextEpisode = next;
      _previousEpisode = previous;
    });
  }

  Future<EmbyItem?> _previousEpisodeOf(
    EmbyClient client,
    EmbyItem episode,
  ) async {
    final seriesId = episode.seriesId;
    if (seriesId == null || seriesId.isEmpty) return null;
    final episodes = await client.getItems(
      parentId: seriesId,
      includeItemTypes: 'Episode',
      recursive: true,
    );
    episodes.sort((a, b) {
      final season = (a.parentIndexNumber ?? 0).compareTo(
        b.parentIndexNumber ?? 0,
      );
      if (season != 0) return season;
      return (a.indexNumber ?? 0).compareTo(b.indexNumber ?? 0);
    });
    final index = episodes.indexWhere((item) => item.id == episode.id);
    if (index <= 0) return null;
    return episodes[index - 1];
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
    await controller.retainOffPageResume();
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

  Future<void> _togglePlayed() async {
    final item = _controller?.item;
    if (item == null || _playedBusy) return;
    setState(() => _playedBusy = true);
    try {
      final client = AuthScope.of(context).client;
      if (item.userData.played) {
        await client.markUnplayed(item.id);
      } else {
        await client.markPlayed(item.id);
      }
      if (!mounted) return;
      await _controller!.load();
    } finally {
      if (mounted) setState(() => _playedBusy = false);
    }
  }

  void _openItem(String itemId) {
    context.push(AppRoutes.item(itemId));
  }

  ItemMediaSource? _source(EmbyItem item) {
    final selected = _controller?.mediaSourceId;
    for (final source in item.mediaSources) {
      if (source.id == selected) return source;
    }
    return item.mediaSources.firstOrNull;
  }

  bool _hasTracks(EmbyItem item) {
    final source = _source(item);
    return item.mediaSources.length > 1 ||
        (source?.audioStreams.isNotEmpty ?? false) ||
        (source?.subtitleStreams.isNotEmpty ?? false);
  }

  Future<void> _openTracks(EmbyItem item) async {
    final source = _source(item);
    await PhoneMotion.showBottomPanel<void>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      builder: (context) {
        final l = AppLocalizations.of(context);
        return ListView(
          padding: const EdgeInsets.only(bottom: AppSpacing.lg),
          children: [
            if (item.mediaSources.length > 1) ...[
              ListTile(title: Text(l.mediaSource)),
              for (final candidate in item.mediaSources)
                ListTile(
                  title: Text(candidate.label),
                  selected: candidate.id == _controller?.mediaSourceId,
                  onTap: () {
                    _controller?.selectSource(candidate.id);
                    setState(() {
                      _audioStreamIndex = null;
                      _subtitleStreamIndex = null;
                    });
                    Navigator.pop(context);
                  },
                ),
            ],
            if (source != null && source.audioStreams.isNotEmpty) ...[
              ListTile(title: Text(l.audioTrack)),
              for (final stream in source.audioStreams)
                ListTile(
                  title: Text(stream.label ?? '#${stream.index}'),
                  selected: stream.index == _audioStreamIndex,
                  onTap: () {
                    setState(() => _audioStreamIndex = stream.index);
                    Navigator.pop(context);
                  },
                ),
            ],
            if (source != null && source.subtitleStreams.isNotEmpty) ...[
              ListTile(title: Text(l.subtitleTrack)),
              for (final stream in source.subtitleStreams)
                ListTile(
                  title: Text(stream.label ?? '#${stream.index}'),
                  selected: stream.index == _subtitleStreamIndex,
                  onTap: () {
                    setState(() => _subtitleStreamIndex = stream.index);
                    Navigator.pop(context);
                  },
                ),
            ],
          ],
        );
      },
    );
  }

  PhoneImageHandoff? _imageHandoff(BuildContext context) {
    final extra = GoRouterState.of(context).extra;
    if (extra is! PhoneImageHandoff || extra.item.id != widget.itemId) {
      return null;
    }
    return extra;
  }

  /// 头部元数据胶囊:年份/季集数/时长/评级/类型,评级高亮突出层级。
  List<PhoneMetaEntry> _bannerMeta(AppLocalizations l, EmbyItem item) {
    if (item.isSeries) {
      final seasons = _controller?.seasons ?? const <EmbyItem>[];
      return [
        if (item.productionYear != null)
          PhoneMetaEntry('${item.productionYear}'),
        if (seasons.isNotEmpty) PhoneMetaEntry(l.seasonCount(seasons.length)),
        if (item.childCount != null)
          PhoneMetaEntry(l.episodeCount(item.childCount!)),
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
      for (final genre in item.genres) PhoneMetaEntry(genre),
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
        final imageSource = handoff?.item ?? item;
        return Scaffold(
          extendBodyBehindAppBar: imageSource != null,
          appBar: AppBar(
            backgroundColor: imageSource == null ? null : Colors.transparent,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            foregroundColor: imageSource == null ? null : Colors.white,
            title: imageSource == null ? Text(l.playerLoading) : null,
          ),
          body: RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              key: PageStorageKey('detail-${widget.itemId}'),
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.zero,
              children: [
                if (imageSource != null)
                  PhoneItemBanner(
                    item: imageSource,
                    title: (item ?? imageSource).name,
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
                                : () => _openPlayer(target.id),
                            onRestart: target == null
                                ? null
                                : () => _openPlayer(target.id, fromStart: true),
                          ),
                    preferBackdrop: handoff?.preferBackdrop ?? true,
                    maxWidth: handoff?.maxWidth ?? PhoneMotion.pageRequestWidth,
                  ),
                if (controller.loading) const LinearProgressIndicator(),
                if (controller.error != null && item == null)
                  MobileFailure(error: controller.error!, retry: _refresh),
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
                    similar: _similar,
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
                        : () => _changeSeason(controller.seasonId!, more: true),
                    onOpenItem: _openItem,
                    onOpenSimilar: _openSimilarShelf,
                  ),
                if (item != null && !item.isSeries)
                  _PhoneItemDetail(
                    item: item,
                    similar: _similar,
                    nextEpisode: _nextEpisode,
                    previousEpisode: _previousEpisode,
                    playedBusy: _playedBusy,
                    showTracks: _hasTracks(item),
                    onOpenItem: _openItem,
                    onOpenSeries: _openItem,
                    onChapter: item.isPlayable
                        ? (chapter) => _openPlayer(
                            item.id,
                            startTimeTicks: chapter.startPositionTicks,
                          )
                        : null,
                    onTogglePlayed: _togglePlayed,
                    onOpenTracks: () => _openTracks(item),
                    onOpenSimilar: _openSimilarShelf,
                  ),
              ],
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
  });

  final String label;
  final bool enabled;
  final bool showRestart;
  final VoidCallback? onPlay;
  final VoidCallback? onRestart;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Row(
      children: [
        Expanded(
          child: FilledButton.icon(
            key: const Key('mobile-detail-play'),
            style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: enabled ? onPlay : null,
            icon: const Icon(Icons.play_arrow),
            label: Text(label, textAlign: TextAlign.center),
          ),
        ),
        if (showRestart) ...[
          const SizedBox(width: AppSpacing.sm),
          OutlinedButton.icon(
            key: const Key('phone-detail-play-start'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: onRestart,
            icon: const Icon(Icons.replay),
            label: Text(l.playFromStart),
          ),
        ],
      ],
    );
  }
}

class _PhoneItemDetail extends StatelessWidget {
  const _PhoneItemDetail({
    required this.item,
    required this.similar,
    required this.nextEpisode,
    required this.previousEpisode,
    required this.playedBusy,
    required this.showTracks,
    required this.onOpenItem,
    required this.onOpenSeries,
    required this.onChapter,
    required this.onTogglePlayed,
    required this.onOpenTracks,
    required this.onOpenSimilar,
  });

  final EmbyItem item;
  final List<EmbyItem> similar;
  final EmbyItem? nextEpisode;
  final EmbyItem? previousEpisode;
  final bool playedBusy;
  final bool showTracks;
  final ValueChanged<String> onOpenItem;
  final ValueChanged<String> onOpenSeries;
  final ValueChanged<ItemChapter>? onChapter;
  final VoidCallback onTogglePlayed;
  final VoidCallback onOpenTracks;
  final VoidCallback onOpenSimilar;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final neighbors = [?previousEpisode, ?nextEpisode];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (item.isEpisode &&
            item.seriesName != null &&
            item.seriesName!.isNotEmpty &&
            item.seriesId != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: CatalogKeys.seriesLink,
              onPressed: () => onOpenSeries(item.seriesId!),
              child: Text(item.seriesName!),
            ),
          ),
        if (plainOverview(item.overview) != null)
          EpisodeOverviewSection(overview: item.overview),
        if (neighbors.isNotEmpty)
          SizedBox(
            height: 220,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              itemCount: neighbors.length,
              separatorBuilder: (context, index) =>
                  const SizedBox(width: AppSpacing.sm),
              itemBuilder: (context, index) {
                final episode = neighbors[index];
                final isNext = episode.id == nextEpisode?.id;
                return _NeighborCard(
                  episode: episode,
                  label: isNext ? l.nextEpisode : l.previousEpisode,
                  cardKey: isNext
                      ? CatalogKeys.nextEpisode
                      : CatalogKeys.previousEpisode,
                  onTap: () => onOpenItem(episode.id),
                );
              },
            ),
          ),
        if (item.chapters.isNotEmpty)
          _ChapterRow(
            itemId: item.id,
            chapters: item.chapters,
            onChapter: onChapter,
          ),
        EpisodePeopleSection(people: item.people),
        if (similar.isNotEmpty)
          _DetailSimilar(
            items: similar,
            onOpenItem: onOpenItem,
            onOpenSimilar: onOpenSimilar,
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: CatalogKeys.playedToggle,
              onPressed: playedBusy ? null : onTogglePlayed,
              child: Text(item.userData.played ? l.markUnplayed : l.markPlayed),
            ),
          ),
        ),
        if (showTracks)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: CatalogKeys.mediaSource,
                onPressed: onOpenTracks,
                child: Text(l.mediaSource, style: theme.textTheme.labelLarge),
              ),
            ),
          ),
        const SizedBox(height: AppSpacing.lg),
      ],
    );
  }
}

class _NeighborCard extends StatelessWidget {
  const _NeighborCard({
    required this.episode,
    required this.label,
    required this.cardKey,
    required this.onTap,
  });

  final EmbyItem episode;
  final String label;
  final Key cardKey;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 220,
      child: InkWell(
        key: cardKey,
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppRadii.sm),
                child: MediaImage(
                  item: episode,
                  preferThumb: true,
                  maxWidth: 640,
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.xxs),
            Text(label, style: theme.textTheme.labelMedium),
            Text(episode.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
    );
  }
}

class _ChapterRow extends StatelessWidget {
  const _ChapterRow({
    required this.itemId,
    required this.chapters,
    required this.onChapter,
  });

  final String itemId;
  final List<ItemChapter> chapters;
  final ValueChanged<ItemChapter>? onChapter;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
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
        SizedBox(
          height: 188,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            itemCount: chapters.length,
            separatorBuilder: (context, index) =>
                const SizedBox(width: AppSpacing.sm),
            itemBuilder: (context, index) {
              final chapter = chapters[index];
              final playable = onChapter != null;
              return InkWell(
                key: CatalogKeys.chapter(index),
                onTap: playable ? () => onChapter!(chapter) : null,
                child: SizedBox(
                  width: 200,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AspectRatio(
                        aspectRatio: 16 / 9,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(AppRadii.sm),
                          child: _ChapterStill(
                            itemId: itemId,
                            index: index,
                            chapter: chapter,
                          ),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xxs),
                      Text(
                        chapterClock(chapter.startPositionTicks),
                        style: theme.textTheme.labelMedium,
                      ),
                      Text(
                        chapter.name,
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

class _ChapterStill extends StatefulWidget {
  const _ChapterStill({
    required this.itemId,
    required this.index,
    required this.chapter,
  });

  final String itemId;
  final int index;
  final ItemChapter chapter;

  @override
  State<_ChapterStill> createState() => _ChapterStillState();
}

class _ChapterStillState extends State<_ChapterStill> {
  Future<Uint8List?>? _image;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _image ??= loadChapterImage(
      context,
      itemId: widget.itemId,
      index: widget.index,
      tag: widget.chapter.imageTag,
      maxWidth: 480,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<Uint8List?>(
      future: _image,
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes == null || bytes.isEmpty) {
          return ColoredBox(color: theme.colorScheme.surfaceContainerHigh);
        }
        return Image.memory(bytes, fit: BoxFit.cover);
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
