import 'dart:async';
import 'dart:typed_data';

import 'package:rillight/app/ui/app_icons.dart';
import 'package:rillight/app/ui/ui.dart';
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
import 'package:rillight/app/widgets/skeleton.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/library/detail_source_scope.dart';
import 'package:rillight/auth/failure_message.dart';
import 'package:rillight/media_server/models.dart';
import 'package:rillight/media_server/errors.dart';
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
  List<MediaItem> _similar = const [];
  MediaItem? _nextEpisode;
  MediaItem? _previousEpisode;
  MediaServerException? _similarError;
  int _extrasRevision = 0;
  String? _selectedSourceId;
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
            () => _similarError = failure is MediaServerException
                ? failure
                : MediaServerException(
                    MediaServerFailureKind.unknown,
                    cause: failure,
                  ),
          );
        }
      }
    }
    if (item.isEpisode) {
      final neighbors = await Future.wait<MediaItem?>([
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
    Duration? startPosition,
  }) async {
    final controller = _controller;
    final item = controller?.item;
    if (controller == null || item == null) return;
    final request = await DetailSourceScope.playbackRequest(context, itemId);
    if (!mounted) return;
    final position = startPosition;
    if (position != null && position > Duration.zero) {
      // /play 目前只把 autoResume 交给播放页。在它读取起点前写上章节时间。
      _deliverStartPosition(context, position);
    }
    final isTargetEpisode =
        !item.isSeries || itemId == controller.playTarget?.id;
    final hasExplicitStreamChoice =
        _selectedSourceId != null ||
        _audioStreamIndex != null ||
        _subtitleStreamIndex != null;
    await context.push(
      '/play/$itemId',
      extra: PlayerOpenRequest(
        itemId: itemId,
        source: request.source,
        libraryId: request.libraryId,
        accessGeneration: request.accessGeneration,
        // The displayed first source is a default, not an explicit choice.
        // Only pin it when the user picked a version or one of its tracks on this page.
        mediaSourceId: isTargetEpisode && hasExplicitStreamChoice
            ? (_selectedSourceId ??
                  (item.isSeries
                      ? controller.playTarget?.mediaSources.firstOrNull?.id
                      : controller.mediaSourceId))
            : null,
        autoResume:
            !fromStart && (position == null || position <= Duration.zero),
        audioStreamIndex: isTargetEpisode ? _audioStreamIndex : null,
        subtitleStreamIndex: isTargetEpisode ? _subtitleStreamIndex : null,
        startPosition: position,
      ),
    );
    if (!mounted || !AuthScope.of(context).isLoggedIn) return;
    // Choices made inside the player are now authoritative on the next open.
    _selectedSourceId = null;
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

  void _deliverStartPosition(BuildContext context, Duration position) {
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
      player.startPosition = position;
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
    showAppNotice(context, next ? l.markPlayed : l.markUnplayed);
  }

  /// 收藏切换同样乐观更新；失败时提示并回滚。
  Future<void> _toggleFavorite() async {
    final controller = _controller;
    final item = controller?.item;
    if (controller == null || item == null) return;
    final next = !item.userData.favorite;
    final ok = await controller.toggleFavorite();
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

  void _openItem(String itemId) {
    context.push(
      DetailSourceScope.itemLocation(context, itemId),
      extra: DetailSourceScope.command(context, itemId),
    );
  }

  void _openSeries(MediaItem episode) {
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
    // 已载入的分集按位置映射到格子：标出当前集与已看集。
    final currentId = widget.initialEpisodeId ?? controller.playTarget?.id;
    int? current;
    final played = <int>{};
    for (var i = 0; i < controller.episodes.length; i++) {
      final episode = controller.episodes[i];
      final number = controller.windowStart + i + 1;
      if (episode.id == currentId) current = number;
      if (episode.userData.played) played.add(number);
    }
    const columns = 6;
    const gap = 8.0;
    const cellExtent = 44.0;
    final currentRow = current == null ? 0 : (current - 1) ~/ columns;
    // 当前集不在前两行时，打开就滚到它的上一行，不用自己翻找。
    final scroll = ScrollController(
      initialScrollOffset: currentRow <= 1
          ? 0
          : (currentRow - 1) * (cellExtent + gap),
    );
    final selected = await showAppModalSheet<int>(
      context: context,
      builder: (context) {
        final l = AppLocalizations.of(context);
        final scheme = AppUiTheme.of(context).colorScheme;
        final rows = (total / columns).ceil();
        final raw = rows * cellExtent + gap * (rows - 1);
        final maxGrid = MediaQuery.sizeOf(context).height * 0.5;
        final gridHeight = (raw < maxGrid ? raw : maxGrid) + AppSpacing.lg;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: scheme.onSurfaceVariant.withValues(alpha: .32),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                AppSpacing.sm,
                AppSpacing.md,
                AppSpacing.sm,
              ),
              child: Row(
                children: [
                  Text(
                    l.pickEpisode,
                    style: AppUiTheme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      child: Text(
                        l.episodeCount(total),
                        style: AppUiTheme.of(context).textTheme.labelSmall
                            ?.copyWith(
                              color: scheme.onSurfaceVariant,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: gridHeight,
              child: GridView.builder(
                controller: scroll,
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md,
                  0,
                  AppSpacing.md,
                  AppSpacing.lg,
                ),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  mainAxisSpacing: gap,
                  crossAxisSpacing: gap,
                  mainAxisExtent: cellExtent,
                ),
                itemCount: total,
                itemBuilder: (context, index) {
                  final number = index + 1;
                  final isCurrent = number == current;
                  final isPlayed = !isCurrent && played.contains(number);
                  return AppButton(
                    key: Key('phone-episode-pick-$number'),
                    style: AppButtonStyle(
                      padding: EdgeInsets.zero,
                      foregroundColor: isCurrent
                          ? scheme.onPrimary
                          : isPlayed
                          ? scheme.onSurfaceVariant
                          : scheme.onSurface,
                      side: isCurrent
                          ? BorderSide(color: scheme.primary)
                          : BorderSide(
                              color: scheme.outlineVariant.withValues(
                                alpha: isPlayed ? .35 : .8,
                              ),
                            ),
                      backgroundColor: isCurrent
                          ? scheme.primary
                          : isPlayed
                          ? scheme.surfaceContainerHigh.withValues(alpha: .5)
                          : null,
                      textStyle: AppUiTheme.of(context).textTheme.labelLarge
                          ?.copyWith(
                            fontWeight: isCurrent ? FontWeight.w600 : null,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                    ),
                    onPressed: () => Navigator.pop(context, number),
                    variant: isCurrent
                        ? AppButtonVariant.filled
                        : AppButtonVariant.outlined,
                    selected: isCurrent,
                    semanticLabel: isPlayed
                        ? '$number \u00b7 ${l.mobileWatched}'
                        : null,
                    child: Text('$number'),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
    scroll.dispose();
    if (!mounted || selected == null) {
      return;
    }
    final start = selected <= 1 ? 0 : selected - 1;
    await controller.selectSeason(seasonId, startAt: start);
  }

  void _openGenre(MediaItem item, String genre) {
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

  void _selectSource(String id) {
    final controller = _controller;
    if (controller == null) return;
    setState(() {
      _selectedSourceId = id;
      _audioStreamIndex = null;
      _subtitleStreamIndex = null;
    });
    controller.selectSource(id);
  }

  ItemMediaSource? _source(MediaItem item) {
    final selected = _selectedSourceId ?? _controller?.mediaSourceId;
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
  List<PhoneMetaEntry> _bannerMeta(AppLocalizations l, MediaItem item) {
    if (item.isSeries) {
      final seasons = _controller?.seasons ?? const <MediaItem>[];
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

  String _playLabel(
    AppLocalizations l,
    MediaItem item,
    MediaItem? target, {
    bool full = false,
  }) {
    if (target == null || !target.isPlayable) return l.noPlayableStream;
    if (item.isSeries) {
      // 按钮只写集号：集名放进按钮在窄屏会折成两行；悬停/读屏说明带集名。
      final code = full
          ? episodeLabel(target)
          : seasonEpisodeCode(target) ?? episodeLabel(target);
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
        // 从海报或横卡点进来时，头图和取色都停在那一张上。加载完成后不改来源，
        // 否则会先看到点中的画面，再换成另一张，颜色变两次。
        // 只有用户切换季时才换成该季的画面，旧图留到新图第一帧。
        final userSeason =
            item != null &&
            item.isSeries &&
            _artworkSeasonId != null &&
            selectedSeason != null &&
            selectedSeason.id == _artworkSeasonId;
        final entryItem = handoff?.item ?? item;
        final seasonArt = userSeason
            ? seasonArtworkItem(selectedSeason, item)
            : null;
        final imageSource = failed ? null : seasonArt ?? entryItem;
        final preferBackdrop = handoff?.preferBackdrop ?? true;
        final imageWidth = handoff?.maxWidth ?? PhoneMotion.pageRequestWidth;
        final immersive = imageSource != null && !_barSolid;
        return ContentTheme(
          item: failed ? null : entryItem,
          preferBackdrop: preferBackdrop,
          child: CupertinoPageScaffold(
            child: Stack(
              children: [
                AppRefresh(
                  // 头图铺到状态栏下，浮层顶栏盖在上面。
                  edgeOffset:
                      MediaQuery.paddingOf(context).top +
                      PhoneTopBar.bodyHeight,
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
                                titleWidget: pending
                                    ? _PhoneDetailPending.title(
                                        context,
                                        handoff,
                                      )
                                    : null,
                                pendingMeta: pending
                                    ? _PhoneDetailPending.metaPlaceholder(
                                        context,
                                        handoff,
                                      )
                                    : null,
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
                                    ? _PhoneDetailPending.metaEntries(
                                        context,
                                        handoff,
                                      )
                                    : _bannerMeta(l, item),
                                statusActions:
                                    item != null &&
                                        (controller.supportsFavorite ||
                                            !item.isSeries)
                                    ? _DetailStatusActions(
                                        played: item.isSeries
                                            ? null
                                            : item.userData.played,
                                        onTogglePlayed: controller.playedBusy
                                            ? null
                                            : _togglePlayed,
                                        favorite: controller.supportsFavorite
                                            ? item.userData.favorite
                                            : null,
                                        onToggleFavorite:
                                            controller.favoriteBusy
                                            ? null
                                            : _toggleFavorite,
                                      )
                                    : null,
                                actions: item == null
                                    ? (pending
                                          ? _PhoneDetailPending.action(context)
                                          : null)
                                    : _DetailPlayActions(
                                        label: target == null
                                            ? l.noPlayableStream
                                            : _playLabel(l, item, target),
                                        tooltip: target == null
                                            ? null
                                            : _playLabel(
                                                l,
                                                item,
                                                target,
                                                full: true,
                                              ),
                                        enabled:
                                            target != null && target.isPlayable,
                                        progress: target?.canResume == true
                                            ? target!.playbackProgress
                                            : null,
                                        progressLabel: target == null
                                            ? null
                                            : remainingLabel(l, target),
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
                                            ? () => _openItem(
                                                _previousEpisode!.id,
                                              )
                                            : null,
                                        onNext:
                                            item.isEpisode &&
                                                _nextEpisode != null
                                            ? () => _openItem(_nextEpisode!.id)
                                            : null,
                                      ),
                                preferBackdrop: preferBackdrop,
                                imagePrefersBackdrop: userSeason
                                    ? true
                                    : preferBackdrop,
                                maxWidth: imageWidth,
                                posterItem: handoff?.item ?? item,
                              ),
                            ),
                          if (pending)
                            _PhoneDetailPending(
                              handoff: handoff,
                              withCaption: imageSource == null,
                            ),
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
                          mediaStreamsSection:
                              target != null && target.mediaSources.length > 1
                              ? EpisodeMediaStreamsSection(
                                  source: _source(target),
                                  sources: target.mediaSources,
                                  selectedSourceId: _source(target)?.id,
                                  onSelectSource: _selectSource,
                                  selectedAudioIndex: _audioStreamIndex,
                                  selectedSubtitleIndex: _subtitleStreamIndex,
                                  onAudio: (index) =>
                                      setState(() => _audioStreamIndex = index),
                                  onSubtitle: (index) => setState(
                                    () => _subtitleStreamIndex = index,
                                  ),
                                )
                              : null,
                          onPickEpisode: _pickEpisode,
                          onOpenGenre:
                              DetailSourceScope.maybeOf(context) == null
                              ? (genre) => _openGenre(item, genre)
                              : null,
                          onSelectSeason: _changeSeason,
                          onOpenEpisode: _openItem,
                          onPlayEpisode: _openPlayer,
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
                              : () => _changeSeason(
                                  controller.seasonId!,
                                  more: true,
                                ),
                          onOpenItem: _openItem,
                          onOpenSimilar:
                              DetailSourceScope.maybeOf(context) == null
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
                              selectedSourceId: _source(item)?.id,
                              onSelectSource: _selectSource,
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
                                      startPosition: chapter.startPosition,
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
                              MediaQuery.paddingOf(context).bottom +
                              AppSpacing.lg,
                        ),
                      ),
                    ],
                  ),
                ),
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: _PhoneDetailBar(
                    immersive: immersive,
                    title: _barSolid ? (item ?? handoff?.item)?.name : null,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 电影详情和剧集页共用的浮层顶栏。返回钮就是 [PhoneTopBar]；
/// 头图还在时背景透明，滚过画面后交给手机顶栏自己的底色和标题。
class _PhoneDetailBar extends StatelessWidget {
  const _PhoneDetailBar({required this.immersive, this.title});

  final bool immersive;
  final String? title;

  @override
  Widget build(BuildContext context) {
    final label = title;
    final top = MediaQuery.paddingOf(context).top;
    final canPop = ModalRoute.of(context)?.canPop == true;
    return Stack(
      children: [
        // 压在画面上时给返回钮垫一枚深色圆底，亮画面上也看得清。
        if (canPop)
          Positioned(
            left: 4,
            top: top + 4,
            child: IgnorePointer(
              child: AnimatedContainer(
                duration: AppMotion.durationOf(context, AppMotion.fast),
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: immersive
                      ? const Color(0xff000000).withValues(alpha: .38)
                      : const Color(0x00000000),
                  border: immersive
                      ? Border.all(
                          color: const Color(0xffffffff).withValues(alpha: .16),
                        )
                      : null,
                ),
              ),
            ),
          ),
        PhoneTopBar(
          centerTitle: label != null,
          backgroundColor: immersive ? const Color(0x00000000) : null,
          foregroundColor: immersive ? const Color(0xFFFFFFFF) : null,
          border: immersive
              ? null
              : Border(
                  bottom: BorderSide(
                    color: phoneChromeTheme(context).colorScheme.outlineVariant
                        .withValues(alpha: .35),
                    width: 0.5,
                  ),
                ),
          title: label == null ? null : Text(label),
        ),
      ],
    );
  }
}

/// 头部右上角状态胶囊：收藏（`phone-detail-favorite`）与已看切换
/// （[CatalogKeys.playedToggle]），填充头部右上留白并释放下方播放控制区宽度。
class _DetailStatusActions extends StatelessWidget {
  const _DetailStatusActions({
    this.played,
    this.onTogglePlayed,
    this.favorite,
    this.onToggleFavorite,
  });

  static const favoriteKey = Key('phone-detail-favorite');

  final bool? played;
  final VoidCallback? onTogglePlayed;
  final bool? favorite;
  final VoidCallback? onToggleFavorite;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final favorite = this.favorite;
    final played = this.played;
    return Wrap(
      alignment: WrapAlignment.end,
      spacing: 6,
      runSpacing: 6,
      children: [
        if (favorite != null)
          Semantics(
            toggled: favorite,
            child: _SecondaryAction(
              key: favoriteKey,
              icon: AppIcons.favorite,
              iconFill: favorite ? AppIcons.filled : AppIcons.outline,
              label: favorite ? l.phoneFavorited : l.phoneFavorite,
              highlighted: favorite,
              compact: true,
              onPressed: onToggleFavorite,
            ),
          ),
        if (played != null)
          Semantics(
            toggled: played,
            child: _SecondaryAction(
              key: CatalogKeys.playedToggle,
              icon: AppIcons.checkCircle,
              iconFill: played ? AppIcons.filled : AppIcons.outline,
              label: played ? l.mobileWatched : l.markPlayed,
              tooltip: played ? l.markUnplayed : l.markPlayed,
              highlighted: played,
              compact: true,
              onPressed: onTogglePlayed,
            ),
          ),
      ],
    );
  }
}

/// 头部主操作：播放钮（`mobile-detail-play`）通栏，续播时下面是一条进度和
/// 「剩余 N 分钟」。再往下是播放与切集控制：从头播放（`phone-detail-play-start`）、
/// 上一集/下一集，只有可用时才出现，横向胶囊等宽排开。
class _DetailPlayActions extends StatelessWidget {
  const _DetailPlayActions({
    required this.label,
    this.tooltip,
    required this.enabled,
    required this.showRestart,
    required this.onPlay,
    required this.onRestart,
    this.progress,
    this.progressLabel,
    this.onPrevious,
    this.onNext,
  });

  static const double _height = 52;

  final String label;

  /// 悬停/读屏的完整说明（含集名）；缺省同 [label]。
  final String? tooltip;
  final bool enabled;
  final bool showRestart;
  final VoidCallback? onPlay;
  final VoidCallback? onRestart;

  /// 续播进度 0–1；为 null 时不画进度行。
  final double? progress;
  final String? progressLabel;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    final progress = this.progress;
    final progressLabel = this.progressLabel;
    final secondary = <Widget>[
      if (showRestart)
        _SecondaryAction(
          key: const Key('phone-detail-play-start'),
          icon: AppIcons.replay,
          label: l.playFromStart,
          onPressed: onRestart,
        ),
      if (onPrevious != null)
        _SecondaryAction(
          key: CatalogKeys.previousEpisode,
          icon: AppIcons.skipPrevious,
          label: l.previousEpisode,
          onPressed: onPrevious,
        ),
      if (onNext != null)
        _SecondaryAction(
          key: CatalogKeys.nextEpisode,
          icon: AppIcons.skipNext,
          label: l.nextEpisode,
          onPressed: onNext,
        ),
    ];
    const shape = StadiumBorder();
    final playButton = AppTooltip(
      message: tooltip ?? label,
      child: AppButton.icon(
        key: const Key('mobile-detail-play'),
        style: AppButtonStyle(
          minimumSize: const Size(48, _height),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          shape: shape,
          textStyle: theme.textTheme.titleSmall?.copyWith(
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        ),
        onPressed: enabled ? onPlay : null,
        icon: const Icon(AppIcons.play, fill: AppIcons.filled, size: 24),
        label: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis),
        variant: AppButtonVariant.filled,
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        playButton,
        if (progress != null && progress > 0) ...[
          const SizedBox(height: AppSpacing.sm),
          Semantics(
            container: true,
            label: progressLabel,
            child: Row(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: AppLoadingBar(
                      key: const Key('phone-detail-progress'),
                      value: progress.clamp(0, 1),
                      minHeight: 5,
                      color: scheme.primary,
                      backgroundColor: scheme.onSurface.withValues(alpha: .14),
                    ),
                  ),
                ),
                if (progressLabel != null && progressLabel.isNotEmpty) ...[
                  const SizedBox(width: AppSpacing.sm),
                  ExcludeSemantics(
                    child: Text(
                      progressLabel,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
        if (secondary.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              for (var i = 0; i < secondary.length; i++) ...[
                if (i > 0) const SizedBox(width: AppSpacing.xs),
                Expanded(child: secondary[i]),
              ],
            ],
          ),
        ],
      ],
    );
  }
}

/// 次级与状态操作：
/// - [compact] 用于头部右上角的收藏/已看状态胶囊（紧凑圆润胶囊）；
/// - 默认用于播放钮下方的从头播放/上一集/下一集（横向图标加文字，宽敞不截断）。
class _SecondaryAction extends StatelessWidget {
  const _SecondaryAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.iconFill = AppIcons.filled,
    this.tooltip,
    this.highlighted = false,
    this.compact = false,
  });

  final IconData icon;
  final double? iconFill;
  final String label;

  /// 悬停/读屏说明；缺省同 [label]。已看切换写的是点下去之后的动作。
  final String? tooltip;
  final VoidCallback? onPressed;
  final bool highlighted;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    final enabled = onPressed != null;
    final duration = AppMotion.durationOf(context, AppMotion.fast);
    final grow = (MediaQuery.textScalerOf(context).scale(14) / 14)
        .clamp(1.0, 1.3)
        .toDouble();
    final iconColor = !enabled
        ? scheme.onSurface.withValues(alpha: .38)
        : highlighted
        ? scheme.primary
        : scheme.onSurface;
    final labelColor = !enabled
        ? scheme.onSurface.withValues(alpha: .38)
        : highlighted
        ? scheme.primary
        : scheme.onSurface;
    final animatedIcon = AnimatedSwitcher(
      duration: duration,
      switchInCurve: AppMotion.emphasized,
      transitionBuilder: (child, animation) => ScaleTransition(
        scale: Tween<double>(begin: .6, end: 1).animate(animation),
        child: FadeTransition(opacity: animation, child: child),
      ),
      child: Icon(
        icon,
        key: ValueKey(highlighted),
        size: (compact ? 16 : 18) * grow,
        color: iconColor,
        fill: iconFill,
      ),
    );
    // 同一行的操作统一为胶囊，高度一致，边线只用细 AppEdge。
    final borderRadius = BorderRadius.circular(AppRadii.pill);
    return AppTooltip(
      message: tooltip ?? label,
      child: MobilePressFeedback(
        enabled: enabled,
        scale: .94,
        child: AnimatedContainer(
          duration: duration,
          curve: AppMotion.standard,
          constraints: BoxConstraints(minHeight: compact ? 34 : 44),
          decoration: BoxDecoration(
            borderRadius: borderRadius,
            color: highlighted
                ? scheme.primary.withValues(alpha: .18)
                : scheme.surfaceContainerHigh.withValues(
                    alpha: compact ? .76 : .68,
                  ),
            border: Border.all(
              color: highlighted
                  ? scheme.primary.withValues(alpha: .44)
                  : AppEdge.of(theme.brightness),
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: AppSurfaceAction(
            onTap: onPressed,
            borderRadius: borderRadius,
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: compact ? 11 : 12,
                vertical: compact ? 6 : 10,
              ),
              child: Row(
                mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  animatedIcon,
                  SizedBox(width: compact ? 5 : 6),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          (compact
                                  ? theme.textTheme.labelMedium
                                  : theme.textTheme.labelLarge)
                              ?.copyWith(color: labelColor),
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

// 头部画质/声道/字幕标签，与桌面和电视共用 [mediaTechBadges]。
List<String> phoneTechBadges(ItemMediaSource? source) =>
    mediaTechBadges(source);

class _PhoneItemDetail extends StatelessWidget {
  const _PhoneItemDetail({
    required this.item,
    required this.similar,
    required this.mediaSource,
    this.selectedSourceId,
    this.onSelectSource,
    required this.selectedAudioIndex,
    required this.selectedSubtitleIndex,
    required this.onAudio,
    required this.onSubtitle,
    required this.onOpenItem,
    required this.onOpenGenre,
    required this.onChapter,
    required this.onOpenSimilar,
  });

  final MediaItem item;
  final List<MediaItem> similar;
  final ItemMediaSource? mediaSource;
  final String? selectedSourceId;
  final ValueChanged<String>? onSelectSource;
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
        EpisodeMediaStreamsSection(
          source: mediaSource,
          sources: item.mediaSources,
          selectedSourceId: selectedSourceId,
          onSelectSource: onSelectSource,
          selectedAudioIndex: selectedAudioIndex,
          selectedSubtitleIndex: selectedSubtitleIndex,
          onAudio: onAudio,
          onSubtitle: onSubtitle,
        ),
        if (item.chapters.isNotEmpty)
          _ChapterStrip(
            itemId: item.id,
            chapters: item.chapters,
            onChapter: onChapter,
          ),
        EpisodePeopleSection(people: item.people),
        DetailAlbumStrip(item: item),
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

  static double cardWidthOf(double viewportWidth) {
    final inner = viewportWidth - AppSpacing.md * 2;
    return ((inner - AppSpacing.sm) / 2).floorToDouble().clamp(140.0, 220.0);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = AppUiTheme.of(context);
    final cardWidth = cardWidthOf(MediaQuery.sizeOf(context).width);
    final labelHeight =
        MediaQuery.textScalerOf(context)
            .scale(theme.textTheme.labelLarge?.fontSize ?? 14) *
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
          child: Text(
            l.chapters,
            style: theme.textTheme.titleMedium?.copyWith(
              fontSize: 19,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.2,
            ),
          ),
        ),
        WholeCardStrip(
          key: const Key('phone-chapter-strip'),
          height: cardWidth * 9 / 16 + AppSpacing.xs + labelHeight + 6,
          itemCount: chapters.length,
          cardWidth: cardWidth,
          gap: AppSpacing.sm,
          margin: AppSpacing.md,
          itemBuilder: (context, index) {
            return _ChapterCard(
              key: CatalogKeys.chapter(index),
              itemId: itemId,
              chapter: chapters[index],
              index: index,
              width: cardWidth,
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
    required this.width,
    required this.onTap,
  });

  final String itemId;
  final ItemChapter chapter;
  final int index;
  final double width;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final name = chapter.name.trim().isEmpty ? '${index + 1}' : chapter.name;
    final hasImage = chapter.imageTag != null && chapter.imageTag!.isNotEmpty;
    return SizedBox(
      width: width,
      child: AppSurfaceAction(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadii.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadii.md),
              child: SizedBox(
                width: width,
                height: width * 9 / 16,
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
                      ChapterFallbackArt(index: index),
                    Positioned(
                      left: AppSpacing.xs,
                      bottom: AppSpacing.xs,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: const Color(0xff000000)
                              .withValues(alpha: 0.62),
                          borderRadius: BorderRadius.circular(AppRadii.sm),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          child: Text(
                            chapterClock(chapter.startPosition),
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: const Color(0xffffffff),
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
    final fallback = ChapterFallbackArt(index: widget.index);
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

  final List<MediaItem> items;
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
                  style: AppUiTheme.of(context).textTheme.titleMedium?.copyWith(
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                  ),
                ),
              ),
              AppButton(
                key: CatalogKeys.shelfMore(CatalogKeys.shelfSimilar),
                style: AppButtonStyle(minimumSize: const Size(48, 48)),
                onPressed: onOpenSimilar,
                variant: AppButtonVariant.plain,
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

/// 条目还没返回时：有交接图就画同一个头部（标题、元数据和主操作就位），
/// 下面是正文占位；没有交接图时头部是骨架块，标题与主操作排在它下面。
class _PhoneDetailPending extends StatelessWidget {
  const _PhoneDetailPending({required this.handoff, required this.withCaption});

  final PhoneImageHandoff? handoff;

  /// 头部没有画面（也就没有标题区）时，由这里补上标题、元数据和主操作。
  final bool withCaption;

  static const headerKey = Key('phone-detail-pending-header');
  static const titleKey = Key('phone-detail-pending-title');
  static const actionKey = Key('phone-detail-pending-action');
  static const bodyKey = Key('phone-detail-pending-body');

  static Widget title(BuildContext context, PhoneImageHandoff? handoff) {
    final theme = AppUiTheme.of(context);
    final name = handoff?.item.name.trim() ?? '';
    final compact = handoff != null && !handoff.item.isEpisode;
    if (name.isEmpty) {
      return SkeletonBlock(
        key: titleKey,
        width: 160,
        height: 28,
        animated: !MediaQuery.disableAnimationsOf(context),
      );
    }
    return Text(
      name,
      key: titleKey,
      maxLines: compact ? 3 : 2,
      overflow: TextOverflow.ellipsis,
      style: phoneDetailTitleStyle(theme, compact: compact),
    );
  }

  static List<PhoneMetaEntry> metaEntries(
    BuildContext context,
    PhoneImageHandoff? handoff,
  ) {
    final l = AppLocalizations.of(context);
    final item = handoff?.item;
    return [
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
  }

  static Widget? metaPlaceholder(
    BuildContext context,
    PhoneImageHandoff? handoff,
  ) {
    if (metaEntries(context, handoff).isNotEmpty) return null;
    return SkeletonBlock(
      width: 144,
      height: 18,
      animated: !MediaQuery.disableAnimationsOf(context),
    );
  }

  static Widget action(BuildContext context) {
    final l = AppLocalizations.of(context);
    return KeyedSubtree(
      key: actionKey,
      child: _DetailPlayActions(
        label: l.play,
        enabled: false,
        showRestart: false,
        onPlay: null,
        onRestart: null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final source = handoff;
    final width = MediaQuery.sizeOf(context).width;
    final contentWidth = width - AppSpacing.md * 2;
    final animate = !MediaQuery.disableAnimationsOf(context);
    final item = source?.item;
    final meta = metaEntries(context, source);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (withCaption)
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
                Align(
                  alignment: Alignment.centerLeft,
                  child: title(context, source),
                ),
                const SizedBox(height: AppSpacing.xs),
                Align(
                  alignment: Alignment.centerLeft,
                  child: meta.isEmpty
                      ? metaPlaceholder(context, source)!
                      : Text(
                          meta.map((entry) => entry.label).join(' · '),
                          style: AppUiTheme.of(context).textTheme.labelLarge,
                        ),
                ),
                const SizedBox(height: AppSpacing.md),
                action(context),
              ],
            ),
          ),
        const SizedBox(height: AppSpacing.lg),
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
