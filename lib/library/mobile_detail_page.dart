import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/content_theme.dart';
import 'package:rillight/library/detached_scroll.dart';
import 'package:rillight/library/detail_extras.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_chrome.dart';
import 'package:rillight/app/mobile_motion.dart';
import 'package:rillight/app/mobile_widgets.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/widgets/skeleton.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/library/detail_source_scope.dart';
import 'package:rillight/auth/failure_message.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/hero_artwork.dart';
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
  late final _episodeScrollCoordinator = EpisodeScrollCoordinator(_scroll);
  var _barSolid = false;

  /// 用户点中的季。自动落到的第一季不写这里，头图就保持打开时的那一张。
  String? _artworkSeasonId;

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
      client: DetailSourceScope.maybeOf(context)?.client,
      cache: DetailSourceScope.cacheOf(context),
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
    _episodeScrollCoordinator.dispose();
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
    if (!more && id != controller.seasonId) _artworkSeasonId = id;
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
    final client = DetailSourceScope.clientOf(context);
    final lease = DetailSourceScope.maybeOf(context)?.permit;
    final identity = (client.baseUrl, client.userId);
    bool owns() =>
        mounted &&
        revision == _extrasRevision &&
        _controller?.item?.id == item.id &&
        (lease == null || lease.isValid) &&
        identity == (client.baseUrl, client.userId);
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
        client.getNextEpisode(item).catchError((Object _) => null),
        client.getPreviousEpisode(item).catchError((Object _) => null),
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
        source: DetailSourceScope.command(context, itemId)?.source,
        libraryId: DetailSourceScope.maybeOf(context)?.libraryId,
        regionGeneration: DetailSourceScope.maybeOf(
          context,
        )?.permit.regionGeneration,
        // The displayed first source is a default, not an explicit choice.
        // Only pin it when the user picked one of its tracks on this page.
        mediaSourceId:
            !item.isSeries &&
                (_audioStreamIndex != null || _subtitleStreamIndex != null)
            ? controller.mediaSourceId
            : null,
        autoResume: !fromStart && (ticks == null || ticks <= 0),
        audioStreamIndex: item.isSeries ? null : _audioStreamIndex,
        subtitleStreamIndex: item.isSeries ? null : _subtitleStreamIndex,
        startTimeTicks: ticks,
      ),
    );
    if (!mounted || !AuthScope.of(context).isLoggedIn) return;
    // Choices made inside the player are now authoritative on the next open.
    _audioStreamIndex = null;
    _subtitleStreamIndex = null;
    await controller.load();
    if (!mounted || !AuthScope.of(context).isLoggedIn) return;
    CatalogScope.of(context).reloadHomeRows();
    await _loadExtras();
  }

  void _openSimilarShelf() {
    // Legacy shelves have no source lease receiver. Never downgrade to Auth A.
    if (DetailSourceScope.maybeOf(context) != null) return;
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
    context.push(
      DetailSourceScope.itemLocation(context, itemId),
      extra: DetailSourceScope.command(context, itemId),
    );
  }

  void _openSeries(EmbyItem episode) {
    final seriesId = episode.seriesId;
    if (seriesId == null || seriesId.isEmpty) {
      return;
    }
    context.push(
      DetailSourceScope.itemLocation(
        context,
        seriesId,
        seasonId: episode.seasonId ?? episode.parentId,
        episodeId: episode.id,
      ),
      extra: DetailSourceScope.command(context, seriesId),
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
              // 格子编号是列表位置，不是正在看的那一集。已加载的分集
              // 不能拿来上色，对不上观看进度时就留空。
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
                  return OutlinedButton(
                    style: OutlinedButton.styleFrom(padding: EdgeInsets.zero),
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
    if (DetailSourceScope.maybeOf(context) != null) return;
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

  /// 标题下只留辨认这部片子的一行:年份、时长、评分和画质/声道标签。
  /// 流派在简介下方单独一行，首播和入库日期在下方的详细信息里。
  List<PhoneMetaEntry> _bannerMeta(AppLocalizations l, EmbyItem item) {
    if (item.isSeries) {
      final seasons = _controller?.seasons ?? const <EmbyItem>[];
      return [
        if (item.productionYear != null)
          PhoneMetaEntry('${item.productionYear}'),
        if (seasons.isNotEmpty)
          PhoneMetaEntry(l.seasonCount(seasons.length))
        else if (item.childCount != null)
          PhoneMetaEntry(l.seasonCount(item.childCount!)),
        if (item.communityRating != null)
          PhoneMetaEntry(
            item.communityRating!.toStringAsFixed(1),
            highlight: true,
          ),
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
      for (final badge in phoneTechBadges(_source(item)))
        PhoneMetaEntry(badge, badge: true),
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
        final selectedSeason = controller.seasons
            .where((season) => season.id == controller.seasonId)
            .firstOrNull;
        // 从海报点进来时，头图和取色都停在那一张上。加载完成后不再改成
        // 背景或第一季的图，否则会先看到点进去的画面，再换成另一张，颜色变两次。
        final imageSource = failed
            ? null
            : handoff != null
            ? handoff.item
            : item == null
            ? null
            : item.isSeries &&
                  selectedSeason != null &&
                  selectedSeason.id == _artworkSeasonId
            ? seasonArtworkItem(selectedSeason, item)
            : item;
        final preferBackdrop = handoff?.preferBackdrop ?? true;
        final imageWidth = handoff?.maxWidth ?? PhoneMotion.pageRequestWidth;
        final immersive = imageSource != null && !_barSolid;
        return ContentTheme(
          item: imageSource,
          preferBackdrop: preferBackdrop,
          child: Scaffold(
            extendBodyBehindAppBar: imageSource != null,
            appBar: AppBar(
              backgroundColor: immersive ? Colors.transparent : null,
              surfaceTintColor: Colors.transparent,
              elevation: 0,
              scrolledUnderElevation: 0,
              foregroundColor: immersive ? Colors.white : null,
              // 横幅滚出后顶栏接管标题,不再只剩一条空色块。
              title: _barSolid && (item ?? handoff?.item) != null
                  ? Text(
                      (item ?? handoff?.item)!.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    )
                  : null,
            ),
            body: RefreshIndicator(
              onRefresh: _refresh,
              child: CustomScrollView(
                key: PageStorageKey('detail-${widget.itemId}'),
                controller: _scroll,
                physics: const AlwaysScrollableScrollPhysics(),
                scrollCacheExtent: const ScrollCacheExtent.viewport(0.5),
                slivers: [
                  SliverList.list(
                    children: [
                      if (pending && imageSource == null)
                        KeyedSubtree(
                          key: _PhoneDetailPending.headerKey,
                          child: SizedBox(
                            height: _pendingHeaderHeight(context),
                            child: SkeletonBlock(
                              borderRadius: BorderRadius.zero,
                              animated: !MediaQuery.disableAnimationsOf(
                                context,
                              ),
                            ),
                          ),
                        )
                      else if (failed)
                        MobileFailureState(
                          message: embyFailureMessage(l, controller.error!),
                          onRetry: _refresh,
                        )
                      else if (imageSource != null)
                        KeyedSubtree(
                          key: _PhoneDetailPending.headerKey,
                          child: PhoneItemBanner(
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
                            meta: item == null
                                ? const []
                                : _bannerMeta(l, item),
                            actions: item == null
                                ? null
                                : _DetailPlayActions(
                                    label: target == null
                                        ? l.noPlayableStream
                                        : _playLabel(l, item, target),
                                    enabled:
                                        target != null && target.isPlayable,
                                    progress: target?.canResume == true
                                        ? target!.playbackProgress
                                        : null,
                                    progressLabel: target == null
                                        ? null
                                        : remainingLabel(l, target),
                                    played: item.isSeries
                                        ? null
                                        : item.userData.played,
                                    onTogglePlayed: controller.playedBusy
                                        ? null
                                        : _togglePlayed,
                                    showRestart:
                                        !item.isSeries &&
                                        target?.canResume == true,
                                    onPlay: target == null
                                        ? null
                                        : _openPreferredPlayer,
                                    onRestart: target == null
                                        ? null
                                        : () => _openPlayer(
                                            target.id,
                                            fromStart: true,
                                          ),
                                    onPrevious:
                                        item.isEpisode &&
                                            _previousEpisode != null
                                        ? () => _openItem(_previousEpisode!.id)
                                        : null,
                                    onNext:
                                        item.isEpisode && _nextEpisode != null
                                        ? () => _openItem(_nextEpisode!.id)
                                        : null,
                                  ),
                            preferBackdrop: preferBackdrop,
                            maxWidth: imageWidth,
                            showCaption: !pending,
                          ),
                        ),
                      if (pending) _PhoneDetailPending(handoff: handoff),
                      if (item != null && controller.error != null)
                        MobileFailureState(
                          message: embyFailureMessage(l, controller.error!),
                          onRetry: _refresh,
                        ),
                      if (item?.isSeries == true &&
                          controller.seasonError != null)
                        MobileFailureState(
                          message: embyFailureMessage(
                            l,
                            controller.seasonError!,
                          ),
                          onRetry: controller.loadSeasons,
                        ),
                    ],
                  ),
                  if (item != null && item.isSeries)
                    ...MobileSeriesPage(
                      item: item,
                      seasons: controller.seasons,
                      seasonId: controller.seasonId,
                      episodes: controller.episodes,
                      episodesLoading: controller.episodesLoading,
                      episodeError: controller.episodeError,
                      hasMore: controller.hasMore,
                      episodeTotal: controller.episodeTotal,
                      playTargetId: target?.id,
                      focusEpisodeId: widget.initialEpisodeId,
                      scrollCoordinator: _episodeScrollCoordinator,
                      similar: _similar,
                      onPickEpisode: _pickEpisode,
                      onOpenGenre: DetailSourceScope.maybeOf(context) == null
                          ? (genre) => _openGenre(item, genre)
                          : null,
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
                      onOpenSimilar: DetailSourceScope.maybeOf(context) == null
                          ? _openSimilarShelf
                          : null,
                    ).buildSlivers(context),
                  SliverList.list(
                    children: [
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
                          onOpenGenre:
                              DetailSourceScope.maybeOf(context) == null
                              ? (genre) => _openGenre(item, genre)
                              : null,
                          onChapter: item.isPlayable
                              ? (chapter) => _openPlayer(
                                  item.id,
                                  startTimeTicks: chapter.startPositionTicks,
                                )
                              : null,
                          onOpenSimilar:
                              DetailSourceScope.maybeOf(context) == null
                              ? _openSimilarShelf
                              : null,
                        ),
                      if (_similarError != null)
                        MobileFailureState(
                          message: embyFailureMessage(l, _similarError!),
                          onRetry: _loadExtras,
                        ),
                    ],
                  ),
                  SliverToBoxAdapter(
                    child: SizedBox(
                      height:
                          MediaQuery.paddingOf(context).bottom + AppSpacing.lg,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 头部主操作：整宽播放钮（`mobile-detail-play`），续播时下方一条进度与剩余时长；
/// 再下面是带文字的次级操作——从头播放（`phone-detail-play-start`）、上一集/下一集、
/// 已看切换（[CatalogKeys.playedToggle]）。不再把它们压成一排无字圆钮或塞进顶栏。
class _DetailPlayActions extends StatelessWidget {
  const _DetailPlayActions({
    required this.label,
    required this.enabled,
    required this.showRestart,
    required this.onPlay,
    required this.onRestart,
    this.progress,
    this.progressLabel,
    this.played,
    this.onTogglePlayed,
    this.onPrevious,
    this.onNext,
  });

  final String label;
  final bool enabled;
  final bool showRestart;
  final VoidCallback? onPlay;
  final VoidCallback? onRestart;

  /// 续播进度 0–1；为 null 时不画进度行。
  final double? progress;
  final String? progressLabel;

  /// 已看状态；为 null（剧集）时不提供已看切换。
  final bool? played;
  final VoidCallback? onTogglePlayed;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final played = this.played;
    final progress = this.progress;
    final tiles = <Widget>[
      if (showRestart)
        _ActionTile(
          key: const Key('phone-detail-play-start'),
          icon: Icons.replay_rounded,
          label: l.playFromStart,
          tooltip: l.playFromStart,
          onPressed: onRestart,
        ),
      if (onPrevious != null)
        _ActionTile(
          key: CatalogKeys.previousEpisode,
          icon: Icons.skip_previous_rounded,
          label: l.previousEpisode,
          tooltip: l.previousEpisode,
          onPressed: onPrevious,
        ),
      if (onNext != null)
        _ActionTile(
          key: CatalogKeys.nextEpisode,
          icon: Icons.skip_next_rounded,
          label: l.nextEpisode,
          tooltip: l.nextEpisode,
          onPressed: onNext,
        ),
      if (played != null)
        _ActionTile(
          key: CatalogKeys.playedToggle,
          icon: played
              ? Icons.check_circle_rounded
              : Icons.check_circle_outline_rounded,
          label: played ? l.watchedAction : l.markPlayed,
          tooltip: played ? l.markUnplayed : l.markPlayed,
          active: played,
          onPressed: onTogglePlayed,
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Tooltip(
          message: label,
          child: FilledButton.icon(
            key: const Key('mobile-detail-play'),
            style: FilledButton.styleFrom(
              minimumSize: const Size(48, 52),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              textStyle: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            onPressed: enabled ? onPlay : null,
            icon: const Icon(Icons.play_arrow_rounded, size: 26),
            label: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
        ),
        if (progress != null && progress > 0) ...[
          const SizedBox(height: AppSpacing.xs),
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    key: const Key('phone-detail-progress'),
                    value: progress.clamp(0, 1),
                    minHeight: 4,
                    color: scheme.primary,
                    backgroundColor: scheme.onSurface.withValues(alpha: .12),
                  ),
                ),
              ),
              if (progressLabel != null) ...[
                const SizedBox(width: AppSpacing.sm),
                Text(
                  progressLabel!,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ],
        if (tiles.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              for (var i = 0; i < tiles.length; i++) ...[
                if (i > 0) const SizedBox(width: AppSpacing.xs),
                tiles[i],
              ],
            ],
          ),
        ],
      ],
    );
  }
}

/// 图标在上、文字在下的次级操作。触控区不小于 72×56。
class _ActionTile extends StatelessWidget {
  const _ActionTile({
    super.key,
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onPressed,
    this.active = false,
  });

  final IconData icon;
  final String label;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final enabled = onPressed != null;
    final color = !enabled
        ? scheme.onSurface.withValues(alpha: .38)
        : active
        ? scheme.primary
        : scheme.onSurface;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        enabled: enabled,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(AppRadii.md),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 72, minHeight: 56),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.xs,
                vertical: 6,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 24, color: color),
                  const SizedBox(height: 4),
                  Text(
                    label,
                    maxLines: 1,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: color,
                      fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 头部画质/声道/字幕标签：4K、HDR/杜比视界、5.1/7.1、全景声、字幕。
List<String> phoneTechBadges(ItemMediaSource? source) {
  if (source == null) return const [];
  final video = source.streams.where((s) => s.isVideo).firstOrNull;
  final audios = source.streams.where((s) => s.isAudio).toList();
  final audio =
      audios.where((s) => s.isDefault == true).firstOrNull ??
      audios.firstOrNull;
  final badges = <String>[];
  final height = video?.height ?? source.height;
  if (height != null && height > 0) {
    badges.add(
      height >= 2000
          ? '4K'
          : height >= 1000
          ? '1080P'
          : height >= 700
          ? '720P'
          : 'SD',
    );
  }
  final rangeType = (video?.videoRangeType ?? '').toUpperCase();
  final range = (video?.videoRange ?? '').toUpperCase();
  if (rangeType.contains('DOVI') || rangeType.contains('DOLBY')) {
    badges.add('DOLBY VISION');
  } else if (rangeType.contains('HDR10+') || rangeType.contains('HDR10PLUS')) {
    badges.add('HDR10+');
  } else if (range == 'HDR' ||
      rangeType.contains('HDR') ||
      rangeType == 'HLG') {
    badges.add(rangeType == 'HLG' ? 'HLG' : 'HDR');
  }
  final audioText = [
    audio?.profile,
    audio?.label,
    audio?.codec,
  ].whereType<String>().join(' ').toUpperCase();
  if (audioText.contains('ATMOS')) {
    badges.add('ATMOS');
  }
  final channels = audio?.channels;
  if (channels != null && channels >= 6) {
    badges.add(channels >= 8 ? '7.1' : '5.1');
  }
  if (source.streams.any((s) => s.isSubtitle)) {
    badges.add('CC');
  }
  return badges;
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
    required this.onOpenGenre,
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
  final ValueChanged<String>? onOpenGenre;
  final ValueChanged<ItemChapter>? onChapter;
  final VoidCallback? onOpenSimilar;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (plainOverview(item.overview) != null)
          EpisodeOverviewSection(overview: item.overview, compact: true),
        PhoneGenreChips(genres: item.genres, onTap: onOpenGenre),
        if (item.chapters.isNotEmpty)
          _ChapterStrip(
            itemId: item.id,
            chapters: item.chapters,
            onChapter: onChapter,
          ),
        EpisodePeopleSection(people: item.people),
        DetailAlbumStrip(item: item),
        EpisodeMediaStreamsSection(
          source: mediaSource,
          selectedAudioIndex: selectedAudioIndex,
          selectedSubtitleIndex: selectedSubtitleIndex,
          onAudio: onAudio,
          onSubtitle: onSubtitle,
        ),
        EpisodeMetadataSection(item: item, source: mediaSource),
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
    final labelHeight =
        MediaQuery.textScalerOf(
          context,
        ).scale(theme.textTheme.labelLarge?.fontSize ?? 14) *
        1.4;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          // 分区间距统一 xl=24(ADR-5)。
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.xl,
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
                      _ChapterFallback(index: index),
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

/// 章节没有服务器剪影时：主色渐变底 + 章节序号，一排章节读起来是一段顺序，
/// 而不是一排灰块。
class _ChapterFallback extends StatelessWidget {
  const _ChapterFallback({required this.index});

  final int index;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [scheme.primaryContainer, scheme.surfaceContainerHigh],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned(
            right: AppSpacing.xs,
            top: 2,
            child: Text(
              (index + 1).toString().padLeft(2, '0'),
              style: theme.textTheme.headlineLarge?.copyWith(
                color: scheme.onPrimaryContainer.withValues(alpha: .28),
                fontWeight: FontWeight.w800,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          Center(
            child: Icon(
              Icons.play_circle_outline_rounded,
              size: 30,
              color: scheme.onPrimaryContainer.withValues(alpha: .8),
            ),
          ),
        ],
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
    final fallback = _ChapterFallback(index: widget.index);
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
            style: theme.textTheme.headlineLarge?.copyWith(
              fontWeight: FontWeight.w700,
              height: 1.2,
            ),
          );
    final item = source?.item;
    final meta = <PhoneMetaEntry>[
      if (item?.isEpisode == true && seasonEpisodeCode(item!) != null)
        PhoneMetaEntry(seasonEpisodeCode(item)!),
      if (item?.productionYear != null)
        PhoneMetaEntry('${item!.productionYear}'),
      if (item?.isSeries == true && item?.childCount != null)
        PhoneMetaEntry(l.seasonCount(item!.childCount!)),
      if (item != null && !item.isSeries && runtimeLabel(l, item) != null)
        PhoneMetaEntry(runtimeLabel(l, item)!),
      if (item?.communityRating != null)
        PhoneMetaEntry(
          item!.communityRating!.toStringAsFixed(1),
          highlight: true,
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PhoneDetailCaption(
          title: title,
          meta: meta,
          pendingMetadata: meta.isEmpty
              ? SkeletonBlock(width: 144, height: 18, animated: animate)
              : null,
          actions: KeyedSubtree(
            key: actionKey,
            child: _DetailPlayActions(
              label: l.play,
              enabled: false,
              showRestart: false,
              onPlay: null,
              onRestart: null,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          child: Column(
            key: bodyKey,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SkeletonBlock(width: contentWidth, height: 14, animated: animate),
              const SizedBox(height: AppSpacing.xs),
              SkeletonBlock(
                width: contentWidth * .72,
                height: 14,
                animated: animate,
              ),
              const SizedBox(height: AppSpacing.lg),
              if (item?.isSeries == true) ...[
                Row(
                  children: [
                    for (var i = 0; i < 3; i++)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: SkeletonBlock(
                          width: 72,
                          height: 40,
                          animated: animate,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                for (var i = 0; i < 2; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Row(
                      children: [
                        SkeletonBlock(
                          width: contentWidth * .4,
                          height: contentWidth * .4 * 9 / 16,
                          animated: animate,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SkeletonBlock(height: 14, animated: animate),
                              const SizedBox(height: 8),
                              SkeletonBlock(
                                width: 80,
                                height: 12,
                                animated: animate,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
              ] else
                SkeletonBlock(
                  width: contentWidth,
                  height: 80,
                  animated: animate,
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
