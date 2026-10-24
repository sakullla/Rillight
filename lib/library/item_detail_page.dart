import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:rillight/app/ui/app_icons.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/app_shell.dart';
import 'package:rillight/app/content_theme.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/widgets/app_error_view.dart';
import 'package:rillight/app/widgets/backdrop_scrim.dart';
import 'package:rillight/app/widgets/hero_palette_overlay.dart';
import 'package:rillight/app/widgets/media_source_menu_tile.dart';
import 'package:rillight/app/widgets/scrim_icon_button.dart';
import 'package:rillight/app/widgets/skeleton.dart';
import 'package:rillight/app/window_chrome.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/catalog_cache.dart';
import 'package:rillight/media_server/media_server_client.dart';
import 'package:rillight/library/detail_source_scope.dart';
import 'package:rillight/media_server/errors.dart';
import 'package:rillight/home/catalog_failure.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/hero_artwork.dart';
import 'package:rillight/library/detail_extras.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/home/media_shelf.dart';
import 'package:rillight/library/episode_detail_sections.dart';
import 'package:rillight/library/detail_repository.dart';
import 'package:rillight/library/episode_list.dart';
import 'package:rillight/library/item_format.dart';
import 'package:rillight/home/hero_carousel.dart';
import 'package:rillight/library/poster_card.dart';
import 'package:rillight/library/season_switcher.dart';
import 'package:rillight/library/source_selection.dart';
import 'package:rillight/media_image/media_image.dart';
import 'package:rillight/player/player_keys.dart';
import 'package:rillight/player/player_window_host.dart';

class ItemDetailPage extends StatefulWidget {
  const ItemDetailPage({
    super.key,
    required this.itemId,
    this.initialSeasonId,
    this.initialMediaSourceId,
  });

  final String itemId;

  /// 打开剧集时预选的季;单集标题链接带入所属季,避免落到第一季。
  final String? initialSeasonId;

  /// 片源选择里点中的版本（路由 `version` 参数）。条目有这个版本时
  /// 打开后预选它，并作为首次播放的明确选择。
  final String? initialMediaSourceId;

  /// 加载完成后的头部根节点,供测试比对骨架/真实头部高度。
  static const headerKey = Key('detail-header');

  /// 骨架屏中的头部占位块,与 [headerKey] 同高。
  static const skeletonHeaderKey = Key('detail-skeleton-header');

  /// 头部左侧海报/缩略图区。
  static const posterKey = Key('detail-poster');

  /// 头部标题。年份与评分移到标题下的元信息行，与手机详情一致。
  static const titleKey = Key('detail-title');

  /// 头部动作行：播放/导航带字胶囊 + 收藏/已看状态圆钮。
  static const actionRowKey = Key('detail-action-row');

  /// 头部播放选项行：片源/音轨/字幕当前值下拉与「其他来源」。
  static const optionRowKey = Key('detail-option-row');

  /// 相邻集预览期间，替还没回来的选项行占位。
  static const optionRowPlaceholderKey = Key('detail-option-row-placeholder');

  /// 头部最小高度(不含顶栏叠加),骨架与真实头部共用同一算法。
  static double headerHeightFor(double width, double viewportHeight) {
    return _DetailHeader.heightFor(width, viewportHeight);
  }

  /// 与 [AppShell] 顶栏同高;顶栏叠在内容之上,头部据此下沉前景内容。
  static double heroTopOverlap(BuildContext context) {
    if (context.findAncestorWidgetOfExactType<AppShell>() == null) {
      return 0;
    }
    final hasChrome =
        context.findAncestorWidgetOfExactType<WindowChromeHost>() != null;
    if (!hasChrome) {
      return AppShell.topBarHeight;
    }
    return kWindowChromeHeight > AppShell.topBarHeight
        ? kWindowChromeHeight
        : AppShell.topBarHeight;
  }

  @override
  State<ItemDetailPage> createState() => _ItemDetailPageState();
}

class _ItemDetailPageState extends State<ItemDetailPage> {
  late String _itemId;
  MediaItem? _item;
  MediaItem? _sharedBackdrop;

  /// 切集时列表条目经常没有演职员、流派和剧照。先沿用上一集已经画出来的内容，
  /// 详情回来再换成这一集自己的；没变就不用拆掉重画。
  List<ItemPerson> _sectionPeople = const [];
  List<String> _sectionGenres = const [];
  ({String itemId, List<String> tags})? _sectionAlbum;

  /// 点选某一季并且该季头图已经能绘制后才为真。绘制前继续用剧集或上一张季图。
  var _applySeasonArtwork = false;

  /// 当前头图对应的季。为空时头图仍是剧集自己的海报。
  String? _paintedSeasonId;

  /// 已显示分集所属的季。切季后、新分集到达前仍是上一季。
  String? _episodesForSeason;
  List<MediaItem> _seasons = const [];
  List<MediaItem> _episodes = const [];
  List<MediaItem> _similar = const [];
  String? _seasonId;
  String? _seriesId;
  String? _seriesOverview;
  String? _focusedEpisodeId;
  MediaItem? _previousEpisode;
  MediaItem? _nextEpisode;
  bool _loading = true;
  bool _busyPlayed = false;
  bool _busyFavorite = false;
  final _busyPlayedIds = <String>{};
  MediaServerException? _error;
  MediaServerException? _similarError;

  /// 季切换/重试失败时分集分区内联显示的错误;成功后清空。
  MediaServerException? _episodeError;

  /// 已有剧集时，继续加载下一窗或跳到未加载集数失败；列表保留，分区内说明并重试。
  MediaServerException? _episodeLoadMoreError;

  /// 跳转窗口失败时要重试的集号。为空表示 [_episodeLoadMoreError] 来自继续加载。
  int? _pendingJumpNumber;

  /// 作废进行中的选集跳转，避免切季或继续加载之后写入过期失败。
  int _jumpSerial = 0;
  int _episodeReveal = 0;
  bool _episodesLoading = false;
  bool _loadingMore = false;
  String? _mediaSourceId;
  bool _pickedMediaSource = false;

  /// 切到相邻一集时先用分集列表里的条目预览；列表条目不带完整片源与
  /// 音轨/字幕，播放选项行要等详情回来才出现。上一集有这一行时预览
  /// 期间先占住它的高度，详情回来后再按实际内容收放，头部不上下跳。
  bool _holdOptionRow = false;

  /// 路由预选的版本已被手动改选或一次播放用掉，之后不再套用。
  bool _routeVersionConsumed = false;
  int? _audioStreamIndex;
  int? _subtitleStreamIndex;
  int _loadGen = 0;
  int _episodeTotal = 0;

  /// 已加载分集窗口之后的季内偏移;小于 [_episodeTotal] 时还有后续分集可追加。
  int _episodeWindowEnd = 0;
  PlayerWindowHost? _playerHost;
  PlayerOpenRequest? _playerRequest;

  @override
  void initState() {
    super.initState();
    _itemId = widget.itemId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _load();
      }
    });
  }

  @override
  void didUpdateWidget(ItemDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.itemId != widget.itemId && widget.itemId != _itemId) {
      _itemId = widget.itemId;
      _load();
      return;
    }
    final nextSeason = widget.initialSeasonId?.trim();
    if (nextSeason != null &&
        nextSeason.isNotEmpty &&
        nextSeason != oldWidget.initialSeasonId?.trim() &&
        nextSeason != _seasonId &&
        (_item?.isSeries ?? false)) {
      unawaited(_selectSeason(nextSeason));
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final host = PlayerWindowScope.maybeOf(context);
    if (!identical(host, _playerHost)) {
      _playerHost?.removeListener(_onPlayerWindow);
      _playerHost = host;
      _playerHost?.addListener(_onPlayerWindow);
      _playerRequest = host?.current;
    }
  }

  @override
  void dispose() {
    _playerHost?.removeListener(_onPlayerWindow);
    super.dispose();
  }

  void _onPlayerWindow() {
    final current = _playerHost?.current;
    final closed = _playerRequest != null && current == null;
    _playerRequest = current;
    if (closed &&
        mounted &&
        (DetailSourceScope.maybeOf(context)?.permit.isValid ?? true)) {
      unawaited(_load(keepChrome: true, refreshCatalog: true));
    }
  }

  void _syncDetailSections(MediaItem next, {required bool holdMissing}) {
    final current = _item;
    final previousBackdrop = _sharedBackdrop ?? current;
    final hasParentBackdrop =
        next.parentBackdropItemId != null &&
        next.parentBackdropImageTag != null;
    _sharedBackdrop =
        !hasParentBackdrop &&
            previousBackdrop != null &&
            _sameShow(previousBackdrop, next) &&
            previousBackdrop.parentBackdropImageTag != null
        ? previousBackdrop
        : next;
    final sameShow =
        holdMissing &&
        current != null &&
        current.id != next.id &&
        _sameShow(current, next);
    if (!sameShow || next.people.isNotEmpty) {
      _sectionPeople = next.people;
    }
    if (!sameShow || next.genres.isNotEmpty) {
      _sectionGenres = next.genres;
    }
    final album = detailAlbumOf(next);
    if (!sameShow || album != null) {
      _sectionAlbum = album;
    }
  }

  bool _sameShow(MediaItem current, MediaItem next) {
    if (!current.isEpisode || !next.isEpisode) {
      return false;
    }
    final series = current.seriesId;
    if (series != null && series.isNotEmpty) {
      return series == next.seriesId;
    }
    final season = current.seasonId ?? current.parentId;
    return season != null &&
        season.isNotEmpty &&
        season == (next.seasonId ?? next.parentId);
  }

  void _showItem(String itemId) {
    if (itemId.isEmpty) {
      return;
    }
    if (itemId == _itemId) {
      setState(() => _episodeReveal++);
      return;
    }
    _itemId = itemId;
    MediaItem? preview;
    for (final episode in _episodes) {
      if (episode.id == itemId) {
        preview = episode;
        break;
      }
    }
    final shown = preview;
    final before = _item;
    final holdOptionRow =
        _holdOptionRow ||
        (before != null && _hasOptionRow(before, _mediaSourceId));
    if (shown != null && mounted) {
      setState(() {
        _holdOptionRow = holdOptionRow;
        _syncDetailSections(shown, holdMissing: true);
        _item = shown;
        _episodeReveal++;
        _previousEpisode = _siblingBefore(shown, _episodes);
        _nextEpisode = _siblingAfter(shown, _episodes);
        _mediaSourceId = shown.mediaSources.isEmpty
            ? null
            : shown.mediaSources.first.id;
        _pickedMediaSource = false;
        _audioStreamIndex = _defaultAudio(shown, _mediaSourceId);
        _subtitleStreamIndex = _defaultSubtitle(shown, _mediaSourceId);
      });
    }
    unawaited(_load(keepChrome: true));
  }

  Future<void> _load({
    bool keepChrome = false,
    bool refreshCatalog = false,
  }) async {
    final gen = ++_loadGen;
    _jumpSerial++;
    final keep = keepChrome && _item != null && _error == null;
    if (!keep) {
      setState(() {
        _loading = true;
        _error = null;
        _similarError = null;
        _episodeError = null;
        _episodeLoadMoreError = null;
        _pendingJumpNumber = null;
        _episodesLoading = false;
        _loadingMore = false;
        _seasons = const [];
        _episodes = const [];
        _episodesForSeason = null;
        _applySeasonArtwork = false;
        _paintedSeasonId = null;
        _similar = const [];
        _seasonId = null;
        _seriesId = null;
        _seriesOverview = null;
        _focusedEpisodeId = null;
        _previousEpisode = null;
        _nextEpisode = null;
        _mediaSourceId = null;
        _pickedMediaSource = false;
        _holdOptionRow = false;
        _audioStreamIndex = null;
        _subtitleStreamIndex = null;
        _episodeTotal = 0;
        _episodeWindowEnd = 0;
      });
    }
    final requestedId = _itemId;
    final client = DetailSourceScope.clientOf(context);
    final repository = _repository(client);
    // Start the network before disk lookup. A late cache read may never replace
    // a live response or a newer navigation.
    final network = repository.item(requestedId);
    var liveItemReady = false;
    if (!keep) {
      unawaited(() async {
        try {
          final cached = await repository.cachedItem(requestedId);
          if (!mounted || gen != _loadGen || liveItemReady || cached == null) {
            return;
          }
          setState(() {
            _syncDetailSections(cached, holdMissing: false);
            _item = cached;
            _loading = false;
          });
        } catch (_) {
          // Corrupt or unavailable cache must not hold the live request.
        }
      }());
    }
    final catalogSerial = _jumpSerial;
    bool current() => mounted && gen == _loadGen;
    bool catalogCurrent() => current() && catalogSerial == _jumpSerial;
    try {
      final item = await network;
      liveItemReady = true;
      if (!current()) return;
      final reuseCatalog =
          keep &&
          !refreshCatalog &&
          _seriesId != null &&
          ((item.isEpisode && item.seriesId == _seriesId) ||
              (item.isSeries && item.id == _seriesId));
      setState(() {
        _syncDetailSections(item, holdMissing: false);
        _item = item;
        _holdOptionRow = false;
        _loading = false;
        _error = null;
        _episodesLoading = (item.isSeries || item.isEpisode) && !reuseCatalog;
        final routed = _routeVersion(item);
        _mediaSourceId = routed ?? item.mediaSources.firstOrNull?.id;
        _pickedMediaSource = routed != null;
        _audioStreamIndex = _defaultAudio(item, _mediaSourceId);
        _subtitleStreamIndex = _defaultSubtitle(item, _mediaSourceId);
      });
      if (!reuseCatalog) unawaited(_loadSimilar(client, item, gen));
      if (!item.isSeries && !item.isEpisode) return;

      final seriesId = reuseCatalog
          ? _seriesId
          : await _resolveSeriesId(client, item);
      if (!current()) return;
      setState(() => _seriesId = seriesId);
      unawaited(() async {
        final overview = await _seriesOverviewTask(
          client,
          item: item,
          seriesId: seriesId,
          cached: _seriesOverview,
        );
        if (current()) setState(() => _seriesOverview = overview);
      }());
      // Resume lookup and seasons are independent. Explicit season routes skip
      // the progress request entirely.
      final resumeTask =
          item.isSeries &&
              _requestedSeasonId() == null &&
              !(keep && _seasonId != null)
          ? repository.resumeEpisode(item.id).catchError((Object _) => null)
          : Future<MediaItem?>.value();
      var seasons = _seasons;
      final knownSeason = item.isEpisode
          ? _preferredSeasonId(item, const [])
          : _requestedSeasonId() ?? (keep ? _seasonId : null);
      if (!(reuseCatalog && seasons.isNotEmpty) &&
          seriesId != null &&
          seriesId.isNotEmpty) {
        var liveSeasonsReady = false;
        final seasonTask = repository.seasons(seriesId);
        unawaited(() async {
          try {
            final cached = await repository.cachedSeasons(seriesId);
            if (!current() ||
                liveSeasonsReady ||
                cached == null ||
                _seasons.isNotEmpty) {
              return;
            }
            setState(() => _seasons = cached);
          } catch (_) {
            // Keep waiting for live seasons.
          }
        }());
        Future<List<MediaItem>> publishSeasons() async {
          try {
            final loaded = await seasonTask;
            liveSeasonsReady = true;
            if (current()) setState(() => _seasons = loaded);
            return loaded;
          } on MediaServerException {
            // A known season can be browsed even if the optional picker fails.
            if (knownSeason == null) rethrow;
            return seasons;
          }
        }

        final published = publishSeasons();
        if (knownSeason == null) {
          seasons = await published;
          if (!current()) return;
        } else {
          unawaited(published);
        }
      }
      final resume = await resumeTask;
      // A user can already select a cached/live season while these requests
      // finish. That selection owns the episode list from this point onward.
      if (!catalogCurrent()) return;
      final seasonId =
          knownSeason ??
          (item.isEpisode
              ? _preferredSeasonId(item, seasons)
              : _requestedSeasonId() ??
                    (keep ? _seasonId : null) ??
                    (resume == null
                        ? null
                        : _preferredSeasonId(resume, seasons)) ??
                    seasons.where((s) => s.indexNumber != 0).firstOrNull?.id ??
                    seasons.firstOrNull?.id);
      final reuseEpisodes =
          reuseCatalog &&
          seasonId == _seasonId &&
          (item.isSeries || _episodes.any((e) => e.id == item.id));
      setState(() {
        _seasonId = seasonId;
        _episodesLoading = !reuseEpisodes && seasonId != null;
      });
      if (!reuseEpisodes && seasonId != null && seasonId.isNotEmpty) {
        final start = item.isEpisode
            ? 0
            : math.max(0, (resume?.indexNumber ?? 1) - 1 - 4);
        final limit = item.isEpisode
            ? _episodeDetailSeasonLimit
            : _episodePageSize;
        unawaited(
          _showCachedEpisodes(
            repository,
            seasonId,
            gen,
            catalogSerial,
            start: start,
            limit: limit,
            current: item.isEpisode ? item : resume,
          ),
        );
        final window = item.isEpisode
            ? await _loadSeasonEpisodes(client, seasonId, item)
            : await _loadEpisodeWindow(
                client,
                seasonId: seasonId,
                current: resume,
              );
        if (!catalogCurrent()) return;
        setState(() => _applyWindow(window));
      }
      if (!catalogCurrent()) return;
      setState(() {
        _episodeError = null;
        _episodeLoadMoreError = null;
        _pendingJumpNumber = null;
        _episodesLoading = false;
        if (item.isSeries && (refreshCatalog || _focusedEpisodeId == null)) {
          _focusedEpisodeId = _playTarget(item)?.id;
        }
        _previousEpisode = item.isEpisode
            ? _siblingBefore(item, _episodes)
            : null;
        _nextEpisode = item.isEpisode ? _siblingAfter(item, _episodes) : null;
      });
      if (item.isEpisode && _nextEpisode == null) {
        unawaited(() async {
          try {
            final next = await client.getNextEpisode(item);
            if (catalogCurrent()) setState(() => _nextEpisode = next);
          } on MediaServerException {
            // Optional next-season navigation must not hold the visible list.
          }
        }());
      }
    } on MediaServerException catch (error) {
      if (!current()) return;
      setState(() {
        if (!liveItemReady) {
          _error = error;
        } else if (catalogCurrent()) {
          _episodeError = error;
          _episodesLoading = false;
        }
        _loading = false;
      });
    }
  }

  Future<void> _loadSimilar(
    MediaServerClient client,
    MediaItem item,
    int gen,
  ) async {
    try {
      final similar = await _repository(client).similar(item.id, limit: 24);
      if (!mounted || gen != _loadGen) return;
      setState(() {
        _similar = similar.where((entry) => entry.id != item.id).toList();
        _similarError = null;
      });
    } on MediaServerException catch (error) {
      if (!mounted || gen != _loadGen) return;
      setState(() => _similarError = _hideSimilar(error) ? null : error);
    }
  }

  Future<void> _showCachedEpisodes(
    DetailRepository repository,
    String seasonId,
    int gen,
    int serial, {
    int start = 0,
    int limit = _episodePageSize,
    MediaItem? current,
    void Function()? onApplied,
  }) async {
    try {
      final cached = await repository.cachedEpisodes(
        seasonId,
        start: start,
        limit: limit,
      );
      if (!mounted ||
          gen != _loadGen ||
          serial != _jumpSerial ||
          _seasonId != seasonId ||
          !_episodesLoading ||
          cached == null) {
        return;
      }
      // 空缓存不能把还在屏幕上的上一季擦掉。
      if (cached.items.isEmpty && _episodes.isNotEmpty) return;
      setState(
        () => _applyWindow(
          _EpisodeWindow(
            items: current == null
                ? cached.items
                : _mergeCurrentEpisode(cached.items, current),
            total: cached.totalRecordCount ?? cached.items.length,
            end: start + cached.items.length,
          ),
        ),
      );
      if (cached.items.isNotEmpty) onApplied?.call();
    } catch (_) {
      // Cached episodes are optional; the network owns errors and completion.
    }
  }

  CatalogCache? _scopeCache;

  /// 目录缓存:无 CatalogScope 时用无会话实例降级直连。
  CatalogCache get _cache =>
      _scopeCache ??= DetailSourceScope.maybeOf(context) != null
      ? DetailSourceScope.cacheOf(context)
      : CatalogScope.maybeOf(context)?.cache ?? CatalogCache();

  DetailRepository? _detailRepository;

  DetailRepository _repository(MediaServerClient client) {
    final existing = _detailRepository;
    if (existing != null && identical(existing.client, client)) return existing;
    return _detailRepository = DetailRepository(client, _cache);
  }

  /// 经缓存层拉取单条详情(总是走网络并写穿缓存)。
  Future<MediaItem> _fetchItem(MediaServerClient client, String itemId) =>
      _repository(client).item(itemId);

  /// 路由指定的季优先于自动续播定位。
  String? _requestedSeasonId() {
    final requested = widget.initialSeasonId?.trim();
    if (requested == null || requested.isEmpty) {
      return null;
    }
    return requested;
  }

  /// 单集所属季:优先条目自带的 seasonId/parentId,即使季列表里没有它
  /// (服务端季数据缺失或错位)也按真实归属查询;缺失时才按季号与首季兜底。
  String? _preferredSeasonId(MediaItem item, List<MediaItem> seasons) {
    final own = item.seasonId ?? item.parentId;
    if (own != null && own.isNotEmpty) {
      return own;
    }
    final seasonNumber = item.parentIndexNumber;
    if (seasonNumber != null) {
      for (final season in seasons) {
        if (season.indexNumber == seasonNumber) {
          return season.id;
        }
      }
    }
    return seasons.isEmpty ? null : seasons.first.id;
  }

  Future<MediaItemPage> _queryEpisodes(
    MediaServerClient client,
    String seasonId,
    int startIndex, {
    int? limit,
  }) {
    return _repository(
      client,
    ).episodes(seasonId, start: startIndex, limit: limit ?? _episodePageSize);
  }

  /// 集详情页一次拉整季(上限 [_episodeDetailSeasonLimit]):本季分集
  /// 横排是切集导航,只给当前窗口会出现"无法向左翻页"。超限季退回窗口。
  Future<_EpisodeWindow> _loadSeasonEpisodes(
    MediaServerClient client,
    String seasonId,
    MediaItem current,
  ) async {
    final page = await _queryEpisodes(
      client,
      seasonId,
      0,
      limit: _episodeDetailSeasonLimit,
    );
    final total = page.totalRecordCount ?? page.items.length;
    final merged = _mergeCurrentEpisode(page.items, current);
    if (total > page.items.length) {
      // 超大季:退回当前集窗口,行为同旧实现。
      return _loadEpisodeWindow(client, seasonId: seasonId, current: current);
    }
    return _EpisodeWindow(items: merged, total: total, end: page.items.length);
  }

  /// 以当前集(或给定集号)前 4 条为起点拉一窗分集;结果按 id 去重,
  /// 当前集缺席但存在唯一同季同集条目时替换目录别名，不补出重复卡片。
  /// 服务端实际返回的多个版本仍保留。
  Future<_EpisodeWindow> _loadEpisodeWindow(
    MediaServerClient client, {
    required String seasonId,
    MediaItem? current,
    int? aroundNumber,
  }) async {
    final index = aroundNumber ?? current?.indexNumber;
    var start = index == null || index <= 1 ? 0 : math.max(0, index - 1 - 4);
    var page = await _queryEpisodes(client, seasonId, start);
    final wantsCurrent = current != null && current.isEpisode;
    if (wantsCurrent &&
        page.items.every((episode) => episode.id != current.id)) {
      // 集号与季内位置不一致(缺集/多版本):整季能装进一窗就从头拉,
      // 否则退回以集号为起点。
      final total = page.totalRecordCount ?? 0;
      start = total <= _episodePageSize
          ? 0
          : math.max(0, (current.indexNumber ?? 1) - 1);
      page = await _queryEpisodes(client, seasonId, start);
    }
    final total = page.totalRecordCount ?? page.items.length;
    final items = wantsCurrent
        ? _mergeCurrentEpisode(page.items, current)
        : _dedupeById(page.items);
    return _EpisodeWindow(
      items: items,
      total: total,
      end: start + page.items.length,
    );
  }

  void _applyWindow(_EpisodeWindow window) {
    _episodes = window.items;
    _episodeTotal = window.total;
    _episodeWindowEnd = window.end;
    _episodesForSeason = _seasonId;
  }

  bool _episodesBelongTo(String? seasonId) =>
      seasonId != null && _episodesForSeason == seasonId;

  /// 追加当前窗口之后的下一窗分集(按 id 去重)。
  Future<void> _loadMoreEpisodes() async {
    final seasonId = _seasonId;
    if (seasonId == null ||
        seasonId.isEmpty ||
        _loadingMore ||
        _episodeWindowEnd >= _episodeTotal) {
      return;
    }
    final gen = _loadGen;
    final startIndex = _episodeWindowEnd;
    final serial = ++_jumpSerial;
    setState(() {
      _loadingMore = true;
      _episodeLoadMoreError = null;
      _pendingJumpNumber = null;
    });
    try {
      final page = await _queryEpisodes(
        DetailSourceScope.clientOf(context),
        seasonId,
        startIndex,
      );
      if (!mounted ||
          gen != _loadGen ||
          serial != _jumpSerial ||
          _seasonId != seasonId) {
        return;
      }
      setState(() {
        _episodes = _sortedByIndex(_dedupeById([..._episodes, ...page.items]));
        _episodeTotal = page.totalRecordCount ?? _episodeTotal;
        _episodeWindowEnd = page.items.isEmpty
            ? _episodeTotal
            : startIndex + page.items.length;
        _loadingMore = false;
        _episodeLoadMoreError = null;
      });
    } on MediaServerException catch (error) {
      if (!mounted ||
          gen != _loadGen ||
          serial != _jumpSerial ||
          _seasonId != seasonId) {
        return;
      }
      setState(() {
        _loadingMore = false;
        _episodeLoadMoreError = error;
        _pendingJumpNumber = null;
      });
    }
  }

  void _locateCurrentEpisode() {
    unawaited(_openEpisodePicker());
  }

  Future<void> _openEpisodePicker() async {
    final seasonId = _seasonId;
    if (seasonId == null || seasonId.isEmpty) {
      return;
    }
    var total = _episodeTotal;
    if (total <= 0) {
      try {
        final page = await DetailSourceScope.clientOf(context).queryItems(
          parentId: seasonId,
          includeItemTypes: 'Episode',
          sortBy: 'IndexNumber',
          sortOrder: 'Ascending',
          limit: 1,
        );
        total = page.totalRecordCount ?? _episodes.length;
      } on MediaServerException {
        total = _episodes.length;
      }
    }
    if (!mounted || total <= 0) {
      return;
    }
    final currentNumber = _item?.isEpisode == true ? _item?.indexNumber : null;
    final selected = await showAppDialog<int>(
      context: context,
      builder: (context) => _EpisodeNumberPicker(
        total: total,
        current: currentNumber,
        seasonId: seasonId,
        client: DetailSourceScope.clientOf(context),
      ),
    );
    if (!mounted || selected == null) {
      return;
    }
    await _jumpToEpisodeNumber(selected);
  }

  /// [reveal] 为 false 时只换窗口、不改当前集（分段条用），定位由分集列表自己做。
  Future<void> _jumpToEpisodeNumber(int number, {bool reveal = true}) async {
    final seasonId = _seasonId;
    if (seasonId == null) {
      return;
    }
    final serial = ++_jumpSerial;
    for (final episode in _episodes) {
      if (episode.indexNumber == number) {
        if (_loadingMore || _pendingJumpNumber != null) {
          setState(() {
            _loadingMore = false;
            if (_pendingJumpNumber != null) {
              _pendingJumpNumber = null;
              _episodeLoadMoreError = null;
            }
          });
        }
        if (reveal) _openOrRevealEpisode(episode.id);
        return;
      }
    }
    setState(() {
      _loadingMore = false;
      _episodeLoadMoreError = null;
      _pendingJumpNumber = null;
    });
    try {
      final window = await _loadEpisodeWindow(
        DetailSourceScope.clientOf(context),
        seasonId: seasonId,
        aroundNumber: number,
      );
      if (!mounted || serial != _jumpSerial || _seasonId != seasonId) {
        return;
      }
      MediaItem? target;
      for (final episode in window.items) {
        if (episode.indexNumber == number) {
          target = episode;
          break;
        }
      }
      target ??= window.items.isEmpty ? null : window.items.first;
      if (target == null) {
        return;
      }
      setState(() {
        _applyWindow(window);
        _episodeLoadMoreError = null;
        _pendingJumpNumber = null;
      });
      if (reveal) _openOrRevealEpisode(target.id);
    } on MediaServerException catch (error) {
      if (!mounted || serial != _jumpSerial || _seasonId != seasonId) {
        return;
      }
      setState(() {
        _episodeLoadMoreError = error;
        _pendingJumpNumber = number;
      });
    }
  }

  void _retryEpisodeContinuation() {
    final number = _pendingJumpNumber;
    if (number != null) {
      unawaited(_jumpToEpisodeNumber(number));
      return;
    }
    unawaited(_loadMoreEpisodes());
  }

  void _revealEpisode(String id) {
    if (!mounted) {
      return;
    }
    setState(() {
      _focusedEpisodeId = id;
      _episodeReveal++;
    });
  }

  /// 分集详情走独立路由:返回键能回到剧集列表。
  /// 行点击进详情;播放按钮才开播放器。
  void _openEpisodeDetails(String id) {
    if (id.isEmpty) {
      return;
    }
    if (id == _itemId) {
      _revealEpisode(id);
      return;
    }
    context.push(
      DetailSourceScope.itemLocation(context, id),
      extra: DetailSourceScope.command(context, id),
    );
  }

  void _openOrRevealEpisode(String id) {
    if (_item?.isSeries ?? false) {
      _revealEpisode(id);
      return;
    }
    _showItem(id);
  }

  /// 切季:分集和头图留到新分集(或缓存)并且新头图能绘制。失败只在分集区。
  Future<void> _selectSeason(String seasonId) async {
    final serial = ++_jumpSerial;
    final gen = _loadGen;
    final paintedBefore = _paintedSeasonId;
    final applyBefore = _applySeasonArtwork;
    final heroWidth = _heroRequestWidth();
    final artwork = _seasonArtwork(seasonId);
    setState(() {
      _seasonId = seasonId;
      _focusedEpisodeId = null;
      _episodeError = null;
      _episodeLoadMoreError = null;
      _pendingJumpNumber = null;
      _episodesLoading = true;
      _loadingMore = false;
      // 旧窗口不能拿去请求新季的下一页。
      if (_episodes.isNotEmpty && _episodeWindowEnd < _episodeTotal) {
        _episodeWindowEnd = _episodeTotal;
      }
    });
    final paintReady = artwork == null
        ? Future<bool>.value(false)
        : _seasonArtworkReady(
            artwork,
            maxWidth: heroWidth,
            current: () =>
                mounted &&
                gen == _loadGen &&
                serial == _jumpSerial &&
                _seasonId == seasonId,
          );
    var failed = false;
    void publishArtwork() {
      if (failed || !mounted || gen != _loadGen || serial != _jumpSerial) {
        return;
      }
      if (_seasonId != seasonId || _episodeError != null) return;
      if (!_episodesBelongTo(seasonId)) return;
      unawaited(() async {
        final ready = await paintReady;
        if (failed || !mounted || gen != _loadGen || serial != _jumpSerial) {
          return;
        }
        if (!ready || _seasonId != seasonId || _episodeError != null) return;
        if (!_episodesBelongTo(seasonId)) return;
        setState(() {
          _applySeasonArtwork = true;
          _paintedSeasonId = seasonId;
        });
      }());
    }

    unawaited(
      _showCachedEpisodes(
        _repository(DetailSourceScope.clientOf(context)),
        seasonId,
        gen,
        serial,
        onApplied: publishArtwork,
      ),
    );
    try {
      final window = await _loadEpisodeWindow(
        DetailSourceScope.clientOf(context),
        seasonId: seasonId,
      );
      if (!mounted ||
          gen != _loadGen ||
          serial != _jumpSerial ||
          _seasonId != seasonId) {
        return;
      }
      setState(() {
        _applyWindow(window);
        _episodesLoading = false;
      });
      publishArtwork();
    } on MediaServerException catch (error) {
      if (!mounted ||
          gen != _loadGen ||
          serial != _jumpSerial ||
          _seasonId != seasonId) {
        return;
      }
      failed = true;
      setState(() {
        _episodeError = error;
        _episodesLoading = false;
        _applySeasonArtwork = applyBefore;
        _paintedSeasonId = paintedBefore;
      });
    }
  }

  MediaItem? _seasonArtwork(String seasonId) {
    final item = _item;
    if (item == null || !item.isSeries) return null;
    final season = _seasons.where((entry) => entry.id == seasonId).firstOrNull;
    if (season == null) return null;
    return seasonArtworkItem(season, item);
  }

  int _heroRequestWidth() {
    final media = MediaQuery.of(context);
    return mediaBackdropRequestWidth(
      layoutWidth: media.size.width,
      devicePixelRatio: media.devicePixelRatio,
    );
  }

  /// 与详情头图同一条加载路径。字节进缓存后,可见头图才能在换源的第一帧画上。
  Future<bool> _seasonArtworkReady(
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
    final candidates = artwork.imageCandidates(preferBackdrop: true);
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
          onAbort: () => token?.cancel('season-artwork'),
        );
        if (!current()) return false;
        if (bytes != null && bytes.isNotEmpty) return true;
      } catch (_) {
        // 下一张候选仍可能画得出来。
      }
    }
    return false;
  }

  /// 路由要求的版本：只对路由打开的那个条目、且条目确有这个版本时生效。
  String? _routeVersion(MediaItem item) {
    final wanted = widget.initialMediaSourceId;
    if (wanted == null ||
        _routeVersionConsumed ||
        item.id != widget.itemId ||
        !item.mediaSources.any((source) => source.id == wanted)) {
      return null;
    }
    return wanted;
  }

  Future<void> _openPlayer(
    String itemId, {
    Duration? startPosition,
    bool fromBeginning = false,
  }) async {
    try {
      final request = await DetailSourceScope.playbackRequest(context, itemId);
      if (!mounted) return;
      await PlayerWindowScope.of(context).open(
        PlayerOpenRequest(
          itemId: itemId,
          source: request.source,
          libraryId: request.libraryId,
          accessGeneration: request.accessGeneration,
          autoResume: !fromBeginning && startPosition == null,
          mediaSourceId: _item?.id == itemId && _pickedMediaSource
              ? _mediaSourceId
              : null,
          audioStreamIndex: _item?.id == itemId && _pickedMediaSource
              ? _audioStreamIndex
              : null,
          subtitleStreamIndex: _item?.id == itemId && _pickedMediaSource
              ? _subtitleStreamIndex
              : null,
          startPosition: startPosition,
        ),
      );
      _routeVersionConsumed = true;
    } catch (error) {
      if (!mounted) {
        return;
      }
      showAppNotice(context, error.toString(), key: PlayerKeys.windowError);
    }
  }

  Future<void> _setPlayed(bool played) async {
    final item = _item;
    if (item == null) {
      return;
    }
    await _setItemPlayed(item, played);
  }

  /// 收藏：乐观更新，写入失败回滚并提示；与手机/电视的收藏语义一致。
  Future<void> _setFavorite(bool favorite) async {
    final item = _item;
    final Object client = DetailSourceScope.clientOf(context);
    if (item == null || _busyFavorite || client is! MediaFavorites) {
      return;
    }
    final l10n = AppLocalizations.of(context);
    final previous = item.userData.favorite;
    setState(() {
      _busyFavorite = true;
      _item = item.copyWith(
        userData: item.userData.copyWith(favorite: favorite),
      );
    });
    var ok = true;
    try {
      await client.setFavorite(item.id, favorite: favorite);
    } catch (_) {
      ok = false;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _busyFavorite = false;
      final latest = _item;
      if (!ok && latest != null && latest.id == item.id) {
        _item = latest.copyWith(
          userData: latest.userData.copyWith(favorite: previous),
        );
      }
    });
    showAppNotice(
      context,
      !ok
          ? l10n.phoneFavoriteFailed
          : favorite
          ? l10n.phoneFavoriteAdded
          : l10n.phoneFavoriteRemoved,
    );
    if (ok) {
      unawaited(CatalogScope.maybeOf(context)?.reloadHomeRows());
    }
  }

  MediaUserData _optimisticPlayed(
    MediaUserData current, {
    required bool played,
  }) {
    return current.copyWith(
      played: played,
      playbackPosition: Duration(microseconds: (0) ~/ 10),
      playedPercentage: played ? 100 : 0,
    );
  }

  void _patchPlayed(String id, MediaUserData userData) {
    _episodes = [
      for (final episode in _episodes)
        if (episode.id == id) episode.copyWith(userData: userData) else episode,
    ];
    final item = _item;
    if (item != null && item.id == id) {
      _item = item.copyWith(userData: userData);
    }
  }

  /// 标记已看/未看:先改列表与当前条目,再写 Emby PlayedItems,最后回读详情。
  Future<void> _setItemPlayed(MediaItem target, bool played) async {
    if (_busyPlayedIds.contains(target.id)) {
      return;
    }
    final previous = target.userData;
    setState(() {
      _busyPlayedIds.add(target.id);
      if (_item?.id == target.id) {
        _busyPlayed = true;
      }
      _patchPlayed(target.id, _optimisticPlayed(previous, played: played));
    });
    final client = DetailSourceScope.clientOf(context);
    try {
      if (played) {
        await client.markPlayed(target.id);
      } else {
        await client.markUnplayed(target.id);
      }
      // 写穿缓存:详情缓存与服务器保持一致。
      final updated = await _fetchItem(client, target.id);
      if (!mounted) {
        return;
      }
      setState(() {
        _busyPlayedIds.remove(target.id);
        if (_item?.id == target.id) {
          _busyPlayed = false;
        }
        _patchPlayed(target.id, updated.userData);
      });
      await CatalogScope.maybeOf(context)?.reloadHomeRows();
    } on MediaServerException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _busyPlayedIds.remove(target.id);
        _patchPlayed(target.id, previous);
        if (_item?.id == target.id) {
          _busyPlayed = false;
          _error = error;
        }
      });
      if (_item?.id != target.id) {
        showAppNotice(context, error.toString());
      }
    }
  }

  String? _displayOverview(MediaItem item) {
    final own = plainOverview(item.overview);
    if (own != null) {
      return own;
    }
    if (!item.isEpisode) {
      return null;
    }
    return plainOverview(_seriesOverview);
  }

  Future<String?> _seriesOverviewTask(
    MediaServerClient client, {
    required MediaItem item,
    required String? seriesId,
    required String? cached,
  }) async {
    if (item.isSeries) {
      return item.overview;
    }
    if (!item.isEpisode) {
      return cached;
    }
    if (cached != null) {
      return cached;
    }
    if (seriesId == null || seriesId.isEmpty) {
      return '';
    }
    try {
      return (await client.getItem(seriesId)).overview ?? '';
    } on MediaServerException {
      return '';
    }
  }

  /// 详情 /Items/{id} 有时不带 ticks,继续观看列表却有百分比。
  /// 首页已拉过 Resume 时,把那份 UserData 补到当前条目。
  MediaItem _withCatalogResume(MediaItem item) {
    if (item.canResume || DetailSourceScope.maybeOf(context) != null) {
      return item;
    }
    final rows = CatalogScope.maybeOf(context)?.resume.items ?? const [];
    for (final entry in rows) {
      if (entry.id == item.id && entry.canResume) {
        return item.copyWith(userData: entry.userData);
      }
    }
    return item;
  }

  MediaItem? _playTarget(MediaItem item) {
    if (item.isPlayable) {
      return item;
    }
    if (!item.isSeries) {
      return null;
    }
    for (final episode in _episodes) {
      if (episode.canResume) {
        return episode;
      }
    }
    // Match DetailController: without resume progress, continue from the
    // first unwatched episode before falling back to the first one.
    return _episodes.where((e) => !e.userData.played).firstOrNull ??
        _episodes.firstOrNull;
  }

  MediaItem? _nextEpisodeAfter(MediaItem item) {
    if (!item.isEpisode) {
      return null;
    }
    return _nextEpisode ?? _siblingAfter(item, _episodes);
  }

  MediaItem? _previousEpisodeBefore(MediaItem item) {
    if (!item.isEpisode) {
      return null;
    }
    return _previousEpisode ?? _siblingBefore(item, _episodes);
  }

  MediaItem? _siblingBefore(MediaItem item, List<MediaItem> episodes) {
    final index = episodes.indexWhere((episode) => episode.id == item.id);
    if (index <= 0) {
      return null;
    }
    return episodes[index - 1];
  }

  MediaItem? _siblingAfter(MediaItem item, List<MediaItem> episodes) {
    final index = episodes.indexWhere((episode) => episode.id == item.id);
    if (index < 0 || index + 1 >= episodes.length) {
      return null;
    }
    return episodes[index + 1];
  }

  Future<String?> _resolveSeriesId(
    MediaServerClient client,
    MediaItem item,
  ) async {
    if (item.isSeries) {
      return item.id;
    }
    final direct = item.seriesId;
    if (direct != null && direct.isNotEmpty) {
      return direct;
    }
    if (!item.isEpisode) {
      return null;
    }
    final seasonId = item.seasonId ?? item.parentId;
    if (seasonId == null || seasonId.isEmpty) {
      return null;
    }
    try {
      final season = await client.getItem(seasonId);
      final fromSeason = season.seriesId ?? season.parentId;
      if (fromSeason != null &&
          fromSeason.isNotEmpty &&
          fromSeason != seasonId) {
        return fromSeason;
      }
    } on MediaServerException {
      return null;
    }
    return null;
  }

  int? _defaultAudio(MediaItem item, String? sourceId) {
    final source = _sourceById(item, sourceId);
    final audios = source?.audioStreams ?? const [];
    return audios.isEmpty ? null : audios.first.index;
  }

  int? _defaultSubtitle(MediaItem item, String? sourceId) {
    final source = _sourceById(item, sourceId);
    final subs = source?.subtitleStreams ?? const [];
    return subs.isEmpty ? null : subs.first.index;
  }

  ItemMediaSource? _sourceById(MediaItem item, String? sourceId) {
    if (item.mediaSources.isEmpty) {
      return null;
    }
    if (sourceId == null || sourceId.isEmpty) {
      return item.mediaSources.first;
    }
    for (final source in item.mediaSources) {
      if (source.id == sourceId) {
        return source;
      }
    }
    return item.mediaSources.first;
  }

  bool _hideSimilar(MediaServerException error) {
    final code = error.statusCode;
    return code == 404 || code == 400 || code == 501;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final topOverlap = ItemDetailPage.heroTopOverlap(context);
    if (_loading) {
      return _DetailSkeleton(topOverlap: topOverlap);
    }
    final error = _error;
    if (error != null && _item == null) {
      final message = error.statusCode == 404
          ? l10n.itemUnavailable
          : catalogFailureMessage(l10n, error);
      return AppErrorView(message: message, onRetry: _load);
    }
    final rawItem = _item;
    if (rawItem == null) {
      return AppErrorView(message: l10n.itemUnavailable, onRetry: _load);
    }
    final item = _withCatalogResume(rawItem);
    final people = item.people.isNotEmpty ? item.people : _sectionPeople;
    final genres = _sectionGenres.isNotEmpty ? _sectionGenres : item.genres;
    final album = detailAlbumOf(item) ?? _sectionAlbum;

    final runtime = runtimeLabel(l10n, item);
    final showSimilar = _similar.isNotEmpty || _similarError != null;
    final playTarget = _playTarget(item);
    final season = _seasons.where((s) => s.id == _seasonId).firstOrNull;
    final painted = _seasons
        .where((entry) => entry.id == _paintedSeasonId)
        .firstOrNull;
    final artwork = item.isSeries && _applySeasonArtwork && painted != null
        ? seasonArtworkItem(painted, item)
        : item;
    final shared = _sharedBackdrop ?? artwork;
    final backdrop = item.isEpisode
        ? (heroArtworkSources(shared).themeItem ?? shared)
        : artwork;
    // 分集区标题旁的一行小字：本季集数，整季载入后再加已看进度。
    final seasonTotal = _episodeTotal > 0 ? _episodeTotal : season?.childCount;
    final seasonWatched =
        seasonTotal != null &&
            _episodeWindowEnd >= seasonTotal &&
            _episodes.length >= seasonTotal
        ? _episodes.where((episode) => episode.userData.played).length
        : null;
    final episodeSummary = <String>[
      if (seasonTotal != null && seasonTotal > 0)
        l10n.episodeCount(seasonTotal),
      if (seasonWatched != null && seasonTotal != null && seasonTotal > 0)
        l10n.seasonWatchedCount(seasonWatched, seasonTotal),
    ].join(' · ');
    final content = <Widget>[
      RepaintBoundary(
        child: _DetailHeader(
          key: ItemDetailPage.headerKey,
          item: item,
          artworkItem: artwork,
          backdropItem: backdrop,
          runtime: runtime,
          topOverlap: topOverlap,
          seasonCount: _seasons.length,
          seriesId: _seriesId,
          previousEpisode: _previousEpisodeBefore(item),
          nextEpisode: item.isSeries ? playTarget : null,
          onOpenPreviousEpisode: _previousEpisodeBefore(item) == null
              ? null
              : () {
                  final previous = _previousEpisodeBefore(item);
                  if (previous == null) {
                    return;
                  }
                  _showItem(previous.id);
                },
          onOpenNextEpisode: _nextEpisodeAfter(item) == null
              ? null
              : () {
                  final next = _nextEpisodeAfter(item);
                  if (next == null) {
                    return;
                  }
                  _showItem(next.id);
                },
          busyPlayed: _busyPlayed,
          genres: genres,
          holdOptionRow: _holdOptionRow,
          mediaSourceId: _mediaSourceId,
          audioStreamIndex: _audioStreamIndex,
          subtitleStreamIndex: _subtitleStreamIndex,
          onMediaSource: (id) {
            setState(() {
              _routeVersionConsumed = true;
              _pickedMediaSource = true;
              _mediaSourceId = id;
              _audioStreamIndex = _defaultAudio(item, id);
              _subtitleStreamIndex = _defaultSubtitle(item, id);
            });
          },
          onAudio: (index) => setState(() => _audioStreamIndex = index),
          onSubtitle: (index) => setState(() => _subtitleStreamIndex = index),
          overview: null,
          // 电影/剧集/单集简介都放在标题旁信息栏,海报只作识别、不叠字。
          overviewWidget: _displayOverview(item) == null
              ? null
              : EpisodeOverviewSection(
                  overview: _displayOverview(item),
                  compact: true,
                  collapsedLines: item.isSeries ? 2 : 3,
                ),
          onLocateEpisode: item.isEpisode
              ? _locateCurrentEpisode
              : playTarget == null || !item.isSeries
              ? null
              : () => _revealEpisode(playTarget.id),
          onPlay: playTarget == null
              ? null
              : () => _openPlayer(
                  playTarget.id,
                  startPosition: playTarget.canResume
                      ? playTarget.resumePosition
                      : null,
                ),
          onPlayFromStart: playTarget == null || !playTarget.canResume
              ? null
              : () => _openPlayer(playTarget.id, fromBeginning: true),
          onPlayedChanged: (value) {
            _setPlayed(value);
          },
          busyFavorite: _busyFavorite,
          onFavoriteChanged:
              DetailSourceScope.clientOf(context) is MediaFavorites
              ? (value) => unawaited(_setFavorite(value))
              : null,
        ),
      ),
      if (item.isEpisode) ...[
        // 本季分集横排:一页正好放下整数张卡,当前集所在页自动滚入视野,
        // 点击直接切集。下一分区自带上边距,货架下方只留小间隔。
        if (_episodes.isNotEmpty)
          MediaShelf(
            shelfId: 'season-episodes',
            title: l10n.seasonEpisodes,
            items: _episodes,
            wide: true,
            fitWholeCards: true,
            bottomSpacing: AppSpacing.xs,
            focusItemId: item.id,
            scrollPageOnFocus: false,
            onTap: (episode) => _showItem(episode.id),
            onMore:
                _seasonId == null || DetailSourceScope.maybeOf(context) != null
                ? null
                : () => context.push(
                    AppRoutes.shelfItems(
                      parentId: _seasonId,
                      includeItemTypes: 'Episode',
                      title: l10n.seasonEpisodes,
                    ),
                  ),
            cardBuilder: (context, episode, width) {
              // The merge inserts/replaces the exact current item.
              // Do not highlight every distinct version of its number.
              final isCurrent = episode.id == item.id;
              return EpisodeThumbCard(
                item: episode,
                width: width,
                selected: isCurrent,
                onTap: () => _showItem(episode.id),
              );
            },
          ),
      ],
      if (item.chapters.isNotEmpty)
        _ChapterStrip(
          itemId: item.id,
          chapters: item.chapters,
          onSelect: (chapter) {
            final playId = item.isPlayable ? item.id : playTarget?.id;
            if (playId == null) {
              return;
            }
            _openPlayer(playId, startPosition: chapter.startPosition);
          },
        ),
      if (item.isSeries) ...[
        EpisodeList(
          // 缓存分集已经属于当前季时，失败仍要空列表，错误和重试才会画出来。
          episodes: _episodeError != null ? const <MediaItem>[] : _episodes,
          currentId: _focusedEpisodeId ?? playTarget?.id,
          revealToken: _episodeReveal,
          loading: _episodesLoading,
          error: _episodeError,
          onRetry: _seasonId == null
              ? () => unawaited(_load(keepChrome: true))
              : () => unawaited(_selectSeason(_seasonId!)),
          hasMore: _episodeError == null && _episodeWindowEnd < _episodeTotal,
          loadingMore: _loadingMore,
          loadMoreError: _episodeLoadMoreError,
          onRetryLoadMore: _retryEpisodeContinuation,
          onLoadMore: () => unawaited(_loadMoreEpisodes()),
          summary: episodeSummary,
          rangeTotal: seasonTotal ?? 0,
          onJumpToNumber: _seasonId == null
              ? null
              : (number) =>
                    unawaited(_jumpToEpisodeNumber(number, reveal: false)),
          seasonSwitcher: _seasons.length > 1
              ? SeasonSwitcher(
                  seasons: _seasons,
                  currentId: _seasonId,
                  onSelected: (id) => unawaited(_selectSeason(id)),
                )
              : null,
          headerAction: _EpisodeShelfActions(
            onLocate: _seasonId == null ? null : _openEpisodePicker,
          ),
          onTap: (episode) => _openEpisodeDetails(episode.id),
          onPlay: (episode) => unawaited(_openPlayer(episode.id)),
          onTogglePlayed: (episode) {
            unawaited(_setItemPlayed(episode, !episode.userData.played));
          },
          busyPlayedIds: _busyPlayedIds,
          onMore:
              _seasonId == null || DetailSourceScope.maybeOf(context) != null
              ? null
              : () => context.push(
                  AppRoutes.shelfItems(
                    parentId: _seasonId,
                    includeItemTypes: 'Episode',
                    title: l10n.episodesRow,
                  ),
                ),
        ),
      ],
      // 演职员、相册、媒体信息与外链对三种条目同序排列。
      EpisodePeopleSection(people: people),
      // 没有剧照时不画相册分区，也不留它的上下边距。
      if (album != null)
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.page,
            vertical: AppSpacing.sm,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DetailAlbumStrip(
                item: item,
                album: album,
                thumbnailWidth: (MediaQuery.sizeOf(context).width / 4).clamp(
                  240.0,
                  360.0,
                ),
              ),
            ],
          ),
        ),
      if (!item.isSeries)
        // 播放设置行已经能选的音轨/字幕不在媒体信息里重复列出。
        EpisodeMediaStreamsSection(
          source: _sourceById(item, _mediaSourceId),
          selectableElsewhere: {
            if (_audioSelectable(_audioChoices(item, _mediaSourceId)))
              MediaStreamKind.audio,
            if (_subtitleSelectable(_subtitleChoices(item, _mediaSourceId)))
              MediaStreamKind.subtitle,
          },
        ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
        child: DetailExternalLinks(links: item.externalUrls, title: item.name),
      ),
      if (showSimilar)
        MediaShelf(
          rowKey: CatalogKeys.similarRow,
          shelfId: CatalogKeys.shelfSimilar,
          title: l10n.similarRow,
          items: _similar,
          error: _similarError,
          onRetry: _load,
          onTap: (similar) => context.push(
            DetailSourceScope.itemLocation(context, similar.id),
            extra: DetailSourceScope.command(context, similar.id),
          ),
          onMore: DetailSourceScope.maybeOf(context) != null
              ? null
              : () => context.push(
                  AppRoutes.shelfSimilar(item.id, title: l10n.similarRow),
                ),
        ),
    ];
    return ContentTheme(
      // 详情取色始终用规范 backdrop;海报卡不参与,浅色也一样。
      item: backdrop,
      preferBackdrop: !item.isEpisode,
      preferParentBackdrop: item.isEpisode,
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification.depth == 0 &&
              notification.metrics.axis == Axis.vertical) {
            HomeScrollNotification(notification.metrics.pixels > 24)
                .dispatch(context);
          }
          return false;
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            AppViewport.readingScope(
              enabled: item.isSeries,
              child: MediaImageScrollListener(
                child: item.isSeries
                    ? CustomScrollView(slivers: _detailSlivers(content))
                    : SingleChildScrollView(
                        padding: const EdgeInsets.only(bottom: AppSpacing.xxl),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: content,
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

List<Widget> _detailSlivers(List<Widget> sections) {
  final slivers = <Widget>[];
  var boxes = <Widget>[];
  for (final section in sections) {
    if (section is EpisodeList) {
      if (boxes.isNotEmpty) slivers.add(SliverList.list(children: boxes));
      boxes = [];
      slivers.add(section);
    } else {
      boxes.add(section);
    }
  }
  boxes.add(const SizedBox(height: AppSpacing.xxl));
  slivers.add(SliverList.list(children: boxes));
  return slivers;
}

class _ChapterStrip extends StatefulWidget {
  const _ChapterStrip({
    required this.itemId,
    required this.chapters,
    required this.onSelect,
  });

  final String itemId;
  final List<ItemChapter> chapters;
  final ValueChanged<ItemChapter> onSelect;

  @override
  State<_ChapterStrip> createState() => _ChapterStripState();
}

class _ChapterStripState extends State<_ChapterStrip> {
  final _controller = ScrollController();
  bool _canScrollLeft = false;
  bool _canScrollRight = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_updateButtons);
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateButtons());
  }

  @override
  void didUpdateWidget(covariant _ChapterStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.chapters.length != widget.chapters.length ||
        oldWidget.itemId != widget.itemId) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _updateButtons());
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_updateButtons);
    _controller.dispose();
    super.dispose();
  }

  void _updateButtons() {
    if (!_controller.hasClients) {
      if (_canScrollLeft || _canScrollRight) {
        setState(() {
          _canScrollLeft = false;
          _canScrollRight = false;
        });
      }
      return;
    }
    final position = _controller.position;
    final overflowing = position.maxScrollExtent > 0.5;
    final canLeft = overflowing && position.pixels > 0.5;
    final canRight =
        overflowing && position.pixels < position.maxScrollExtent - 0.5;
    if (canLeft != _canScrollLeft || canRight != _canScrollRight) {
      setState(() {
        _canScrollLeft = canLeft;
        _canScrollRight = canRight;
      });
    }
  }

  void _page(int direction) {
    if (!_controller.hasClients) {
      return;
    }
    final position = _controller.position;
    final target =
        (position.pixels + position.viewportDimension * 0.9 * direction).clamp(
          0.0,
          position.maxScrollExtent,
        );
    final duration = AppMotion.durationOf(context);
    if (duration == Duration.zero) {
      _controller.jumpTo(target);
      return;
    }
    _controller.animateTo(
      target,
      duration: duration,
      curve: AppMotion.standard,
    );
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) {
      return;
    }
    if (event.scrollDelta.dy.abs() <= event.scrollDelta.dx.abs()) {
      return;
    }
    final vertical = Scrollable.maybeOf(context, axis: Axis.vertical);
    if (vertical == null) {
      return;
    }
    GestureBinding.instance.pointerSignalResolver.register(event, (resolved) {
      final dy = (resolved as PointerScrollEvent).scrollDelta.dy;
      final position = vertical.position;
      position.jumpTo(
        (position.pixels + dy).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = AppUiTheme.of(context);
    final labelHeight = MediaShelf.lineHeightOf(
      context,
      theme.textTheme.labelLarge,
    );
    // Emby 默认不抽章节图。整片都没有章节图时，用紧凑的时间码胶囊代替一排空白 16:9 占位。
    final imageless = widget.chapters.every(
      (chapter) => chapter.imageTag == null || chapter.imageTag!.isEmpty,
    );
    final stripHeight = imageless
        ? ChapterTimeChip.heightOf(context)
        : _ChapterTile.width * 9 / 16 + AppSpacing.xs + labelHeight + 2;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.page,
        AppSpacing.md,
        AppSpacing.page,
        AppSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.chapters, style: theme.textTheme.titleMedium),
          const SizedBox(height: AppSpacing.sm),
          SizedBox(
            height: stripHeight,
            child: Stack(
              children: [
                NotificationListener<ScrollMetricsNotification>(
                  onNotification: (_) {
                    _updateButtons();
                    return false;
                  },
                  child: ScrollConfiguration(
                    behavior: const _ChapterScrollBehavior(),
                    child: Listener(
                      onPointerSignal: _onPointerSignal,
                      child: ListView.separated(
                        controller: _controller,
                        scrollDirection: Axis.horizontal,
                        itemCount: widget.chapters.length,
                        separatorBuilder: (context, index) =>
                            const SizedBox(width: AppSpacing.sm),
                        itemBuilder: (context, index) {
                          final chapter = widget.chapters[index];
                          if (imageless) {
                            return ChapterTimeChip(
                              key: CatalogKeys.chapter(index),
                              chapter: chapter,
                              index: index,
                              onTap: () => widget.onSelect(chapter),
                            );
                          }
                          return _ChapterTile(
                            key: CatalogKeys.chapter(index),
                            itemId: widget.itemId,
                            chapter: chapter,
                            index: index,
                            onTap: () => widget.onSelect(chapter),
                          );
                        },
                      ),
                    ),
                  ),
                ),
                if (_canScrollLeft)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: ScrimIconButton(
                      paperInLight: true,
                      key: CatalogKeys.shelfScrollLeft(
                        CatalogKeys.shelfChapters,
                      ),
                      tooltip: l10n.scrollLeft,
                      icon: const Icon(CupertinoIcons.chevron_left),
                      onPressed: () => _page(-1),
                    ),
                  ),
                if (_canScrollRight)
                  Align(
                    alignment: Alignment.centerRight,
                    child: ScrimIconButton(
                      paperInLight: true,
                      key: CatalogKeys.shelfScrollRight(
                        CatalogKeys.shelfChapters,
                      ),
                      tooltip: l10n.scrollRight,
                      icon: const Icon(CupertinoIcons.chevron_right),
                      onPressed: () => _page(1),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 桌面鼠标左键可以拖动章节条。竖直滚轮仍交给外层详情页。
class _ChapterScrollBehavior extends AppScrollBehavior {
  const _ChapterScrollBehavior();
}

class _ChapterTile extends StatelessWidget {
  const _ChapterTile({
    super.key,
    required this.itemId,
    required this.chapter,
    required this.index,
    required this.onTap,
  });

  final String itemId;
  final ItemChapter chapter;
  final int index;
  final VoidCallback onTap;

  /// 章节卡宽;与 16:9 剧照卡同一族,但小一档,不与分集条争主次。
  static const double width = 176;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    final name = chapter.name.trim().isEmpty ? '${index + 1}' : chapter.name;
    final hasImage = chapter.imageTag != null && chapter.imageTag!.isNotEmpty;
    // 16:9 章节图卡:左下角时间码角标,图下一行章节名;无图画主色渐变与序号。
    return SizedBox(
      width: width,
      child: Container(
        decoration: BoxDecoration(
          color: AppInk.transparent,
          borderRadius: BorderRadius.circular(AppRadii.md),
        ),
        child: AppSurfaceAction(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadii.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
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
                            color: scheme.scrim.withValues(alpha: 0.62),
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
                                color: AppInk.white,
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
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge,
                ),
              ),
            ],
          ),
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
      _future ??= _load();
    }
  }

  Future<Uint8List?> _load() {
    // 章节图经 MediaImageCache 统一管道加载,与海报/剧照共用
    // 内存 LRU + 磁盘两级缓存,重复进入详情页不再重复请求。
    return loadChapterImage(
      context,
      itemId: widget.itemId,
      index: widget.index,
      tag: widget.tag,
    );
  }

  @override
  Widget build(BuildContext context) {
    final fallback = ChapterFallbackArt(index: widget.index);
    if (widget.tag == null || widget.tag!.isEmpty) {
      return fallback;
    }
    return FutureBuilder<Uint8List?>(
      future: _future,
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (snapshot.connectionState != ConnectionState.done) {
          return const SkeletonBlock(borderRadius: BorderRadius.zero);
        }
        if (bytes == null || bytes.isEmpty) {
          return fallback;
        }
        return Image.memory(bytes, fit: BoxFit.cover);
      },
    );
  }
}

/// 剧集区标题行右侧:「选集」(按集号跳转)。季切换在左侧,与标题同组。
class _EpisodeShelfActions extends StatelessWidget {
  const _EpisodeShelfActions({this.onLocate});

  final VoidCallback? onLocate;

  @override
  Widget build(BuildContext context) {
    if (onLocate == null) return const SizedBox.shrink();
    return AppActionButton(
      key: CatalogKeys.locateEpisode,
      onPressed: onLocate,
      icon: AppIcons.episodes,
      label: AppLocalizations.of(context).pickEpisode,
    );
  }
}

class _EpisodeNumberPicker extends StatefulWidget {
  const _EpisodeNumberPicker({
    required this.total,
    required this.seasonId,
    required this.client,
    this.current,
  });

  final int total;
  final int? current;
  final String seasonId;
  final MediaServerClient client;

  @override
  State<_EpisodeNumberPicker> createState() => _EpisodeNumberPickerState();
}

class _EpisodeNumberPickerState extends State<_EpisodeNumberPicker> {
  static const _pageSize = 30;
  late int _rangeStart;
  final _jump = TextEditingController();
  List<MediaItem> _page = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    final current = widget.current ?? 1;
    _rangeStart = ((current - 1) ~/ _pageSize) * _pageSize + 1;
    _jump.text = current.toString();
    unawaited(_loadRange(_rangeStart));
  }

  @override
  void dispose() {
    _jump.dispose();
    super.dispose();
  }

  Future<void> _loadRange(int start) async {
    setState(() {
      _rangeStart = start;
      _loading = true;
    });
    try {
      final page = await widget.client.queryItems(
        parentId: widget.seasonId,
        includeItemTypes: 'Episode',
        sortBy: 'IndexNumber',
        sortOrder: 'Ascending',
        startIndex: math.max(0, start - 1),
        limit: _pageSize,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _page = page.items;
        _loading = false;
      });
    } on MediaServerException {
      if (!mounted) {
        return;
      }
      setState(() => _loading = false);
    }
  }

  void _submitJump() {
    final number = int.tryParse(_jump.text.trim());
    if (number == null || number < 1 || number > widget.total) {
      return;
    }
    Navigator.of(context).pop(number);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    final ranges = <(int, int)>[];
    for (var start = 1; start <= widget.total; start += _pageSize) {
      final end = math.min(start + _pageSize - 1, widget.total);
      ranges.add((start, end));
    }
    final viewport = MediaQuery.sizeOf(context);
    return AppDialog(
      title: Row(
        children: [
          Text(l10n.pickEpisode),
          const SizedBox(width: AppSpacing.xs),
          DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(AppRadii.pill),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              child: Text(
                l10n.episodeCount(widget.total),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: AppViewport.fit(440, viewport.width - 80, viewport),
        height: AppViewport.fit(440, viewport.height * 0.8, viewport),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppTextField(
              controller: _jump,
              autofocus: true,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.go,
              onSubmitted: (_) => _submitJump(),
              placeholder: l10n.jumpToEpisodeHint,
              suffix: AppIconButton(
                tooltip: l10n.pickEpisode,
                onPressed: _submitJump,
                icon: const Icon(CupertinoIcons.arrow_right),
              ),
            ),
            if (ranges.length > 1) ...[
              const SizedBox(height: AppSpacing.sm),
              Align(
                alignment: Alignment.centerLeft,
                child: AppMenuButton<int>(
                  key: CatalogKeys.episodeRange,
                  tooltip: l10n.pickEpisode,
                  selected: _rangeStart,
                  onSelected: _loadRange,
                  padding: EdgeInsets.zero,
                  items: [
                    for (final range in ranges)
                      AppMenuEntry(
                        value: range.$1,
                        child: Text('${range.$1}-${range.$2}'),
                      ),
                  ],
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(AppRadii.pill),
                      border: Border.all(
                        color: AppEdge.of(scheme.brightness, strong: true),
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '$_rangeStart-${math.min(_rangeStart + _pageSize - 1, widget.total)}',
                            style: theme.textTheme.labelLarge?.copyWith(
                              fontWeight: FontWeight.w600,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                          const SizedBox(width: 4),
                          Icon(
                            CupertinoIcons.chevron_down,
                            size: 14,
                            color: scheme.onSurfaceVariant,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.sm),
            Expanded(
              child: _loading
                  ? const Center(child: CupertinoActivityIndicator())
                  : ListView.builder(
                      itemCount: _page.length,
                      itemBuilder: (context, index) {
                        final episode = _page[index];
                        final number =
                            episode.indexNumber ?? (index + _rangeStart);
                        final selected = number == widget.current;
                        final played = episode.userData.played;
                        return AppListTile(
                          selected: selected,
                          leading: Container(
                            constraints: const BoxConstraints(
                              minWidth: 32,
                              minHeight: 28,
                            ),
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: selected
                                  ? scheme.primary
                                  : scheme.surfaceContainerHigh,
                              borderRadius: BorderRadius.circular(AppRadii.sm),
                            ),
                            child: Text(
                              '$number',
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: selected
                                    ? scheme.onPrimary
                                    : scheme.onSurfaceVariant,
                                fontWeight: FontWeight.w700,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ),
                          title: Text(
                            episode.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: selected ? FontWeight.w600 : null,
                            ),
                          ),
                          trailing: played
                              ? Icon(
                                  CupertinoIcons.check_mark_circled_solid,
                                  size: 16,
                                  color: selected
                                      ? scheme.primary
                                      : scheme.onSurfaceVariant,
                                )
                              : null,
                          onTap: () => Navigator.of(context).pop(number),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SeriesLink extends StatelessWidget {
  const _SeriesLink({required this.name, this.seriesId, this.seasonId});

  final String name;
  final String? seriesId;
  final String? seasonId;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final style = theme.textTheme.titleSmall?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.86),
    );
    if (seriesId == null || seriesId!.isEmpty) {
      return Text(
        name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
      );
    }
    return AppTooltip(
      message: AppLocalizations.of(context).viewSeries,
      child: AppButton(
        key: CatalogKeys.seriesLink,
        onPressed: () => context.push(
          DetailSourceScope.itemLocation(
            context,
            seriesId!,
            seasonId: seasonId,
          ),
          extra: DetailSourceScope.command(
            context,
            seriesId!,
            seasonId: seasonId,
          ),
        ),
        style: AppButtonStyle(
          foregroundColor: theme.colorScheme.onSurface.withValues(alpha: 0.9),
          padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 2),
          minimumSize: Size.zero,
        ),
        // 面包屑:剧名在前、箭头在后,读作「老友记 ›」,点开回到整部剧。
        variant: AppButtonVariant.plain,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style,
              ),
            ),
            const SizedBox(width: AppSpacing.xxs),
            Icon(
              CupertinoIcons.chevron_right,
              size: 14,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

/// 分集窗口:一次查询得到的分集及其在季内的服务端偏移终点。
class _EpisodeWindow {
  const _EpisodeWindow({
    required this.items,
    required this.total,
    required this.end,
  });

  final List<MediaItem> items;

  /// 季内分集总数(服务端 TotalRecordCount)。
  final int total;

  /// 窗口末条之后的季内偏移;等于 [total] 时已无后续分集。
  final int end;
}

const _episodePageSize = 80;

/// 集详情页整季拉取上限;超过该集数的季退回当前集窗口。
const _episodeDetailSeasonLimit = 300;

List<MediaItem> _dedupeById(Iterable<MediaItem> items) {
  final seen = <String>{};
  return [
    for (final item in items)
      if (seen.add(item.id)) item,
  ];
}

List<MediaItem> _mergeCurrentEpisode(
  Iterable<MediaItem> entries,
  MediaItem current,
) {
  final items = _dedupeById(entries);
  if (items.any((entry) => entry.id == current.id)) return items;
  final equivalents = [
    for (var i = 0; i < items.length; i++)
      if (current.indexNumber != null &&
          current.seasonId != null &&
          current.seasonId!.isNotEmpty &&
          items[i].seasonId == current.seasonId &&
          items[i].indexNumber == current.indexNumber &&
          (current.seriesId == null || items[i].seriesId == current.seriesId))
        i,
  ];
  if (equivalents.length == 1) {
    items[equivalents.single] = current;
    return items;
  }
  // No unambiguous equivalent: preserve legitimate variants and unnumbered
  // extras rather than discarding a different playable item.
  return _sortedByIndex([...items, current]);
}

/// 按集号稳定排序:同号多版本保持原有相对顺序,无集号者排最后。
List<MediaItem> _sortedByIndex(List<MediaItem> items) {
  final indexed = [for (var i = 0; i < items.length; i++) (i, items[i])];
  indexed.sort((a, b) {
    final left = a.$2.indexNumber ?? 1 << 30;
    final right = b.$2.indexNumber ?? 1 << 30;
    final compared = left.compareTo(right);
    return compared != 0 ? compared : a.$1.compareTo(b.$1);
  });
  return [for (final entry in indexed) entry.$2];
}

/// 详情页头部:全幅 backdrop + [BackdropScrim] 作底,前景为
/// 干净海报 | 信息区(剧名链接、标题、元信息胶囊、简介、操作)两栏。
///
/// 高度至少为 [heightFor] + 顶栏叠加;内容更高时按内容自增。
/// 剧集不拉半屏空英雄位:分集才是主体,头部随海报+信息贴合。
/// 单集底图取所属剧集的 backdrop,前景是本集 16:9 剧照——与 Plex /
/// Jellyfin 的单集页一致,两张图各司其职,不再"同源重复"。
/// 骨架屏用同一算法取高,首帧不跳变。
class _DetailHeader extends StatelessWidget {
  const _DetailHeader({
    super.key,
    required this.item,
    this.artworkItem,
    this.backdropItem,
    required this.runtime,
    required this.busyPlayed,
    required this.onPlay,
    required this.onPlayedChanged,
    this.onPlayFromStart,
    this.busyFavorite = false,
    this.onFavoriteChanged,
    this.topOverlap = 0,
    this.seasonCount = 0,
    this.seriesId,
    this.previousEpisode,
    this.nextEpisode,
    this.onOpenPreviousEpisode,
    this.onOpenNextEpisode,
    this.mediaSourceId,
    this.audioStreamIndex,
    this.subtitleStreamIndex,
    this.onMediaSource,
    this.onAudio,
    this.onSubtitle,
    this.onLocateEpisode,
    this.overview,
    this.overviewWidget,
    this.genres = const [],
    this.holdOptionRow = false,
  });

  final MediaItem item;
  final List<String> genres;
  final bool holdOptionRow;
  final MediaItem? artworkItem;
  final MediaItem? backdropItem;
  final String? runtime;
  final bool busyPlayed;
  final VoidCallback? onPlay;
  final ValueChanged<bool> onPlayedChanged;
  final VoidCallback? onPlayFromStart;
  final bool busyFavorite;
  final ValueChanged<bool>? onFavoriteChanged;
  final double topOverlap;
  final int seasonCount;
  final String? seriesId;
  final MediaItem? previousEpisode;
  final MediaItem? nextEpisode;
  final VoidCallback? onOpenPreviousEpisode;
  final VoidCallback? onOpenNextEpisode;
  final String? mediaSourceId;
  final int? audioStreamIndex;
  final int? subtitleStreamIndex;
  final ValueChanged<String>? onMediaSource;
  final ValueChanged<int>? onAudio;
  final ValueChanged<int?>? onSubtitle;
  final VoidCallback? onLocateEpisode;
  final String? overview;

  /// 信息栏内自定义简介控件(单集用可展开收起的概览);与 [overview] 互斥。
  final Widget? overviewWidget;

  /// 顶带在顶栏之下继续溶入的高度。
  static const double _topBandFade = 36;

  /// 头部最小高度:电影约半屏画幅,夹在 360–640 之间;单集为 0.34 视高
  /// (280–420),留给本季分集和演职员;剧集 [billboard] 为 false,
  /// 不定死半屏,高度跟着海报走,避免分集被挤到首屏之外。
  static double heightFor(
    double width,
    double viewportHeight, {
    bool billboard = true,
    bool episode = false,
  }) {
    if (!billboard) {
      return 0;
    }
    if (episode) {
      return (viewportHeight * 0.34).clamp(280.0, 420.0);
    }
    return (viewportHeight * 0.52).clamp(360.0, 640.0);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final stacked = width < 760;
        final viewportHeight = MediaQuery.sizeOf(context).height;
        final theme = AppUiTheme.of(context);
        final light = theme.brightness == Brightness.light;
        // 浅色头部不铺半屏画幅，没有画面可看就不留半屏空白。
        final billboard = !item.isSeries && !light;
        final minHeight =
            heightFor(
              width,
              viewportHeight,
              billboard: billboard,
              episode: item.isEpisode,
            ) +
            topOverlap;
        // The canonical theme artwork is the same image in both themes. In
        // light it sits behind a surface wash so the reported bytes and the
        // palette key always describe the artwork that actually painted.
        final themeArtwork = backdropItem ?? artworkItem ?? item;
        final backdropImage = HeroPaletteOverlay(
          paletteKey: HeroPaletteOverlay.paletteKeyFor(context, themeArtwork),
          child: MediaImage(
            key: const ValueKey('detail-hero'),
            contributesToTheme: true,
            smartCrop: true,
            retainVisibleFrame: true,
            item: themeArtwork,
            preferBackdrop: !item.isEpisode,
            preferParentBackdrop: item.isEpisode,
            maxWidth: mediaBackdropRequestWidth(
              layoutWidth: width,
              devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
            ),
          ),
        );
        return SizedBox(
          width: double.infinity,
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: minHeight),
            child: Stack(
              alignment: AlignmentDirectional.bottomStart,
              children: [
                Positioned.fill(
                  child: light
                      ? Stack(
                          fit: StackFit.expand,
                          children: [
                            backdropImage,
                            DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                  colors: [
                                    theme.scaffoldBackgroundColor.withValues(
                                      alpha: 0.92,
                                    ),
                                    theme.scaffoldBackgroundColor.withValues(
                                      alpha: 0.86,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        )
                      : BackdropScrim(
                          textBandWidthFactor: 1,
                          topBandHeight: math.max(
                            AppScrim.topBandHeight,
                            topOverlap + _topBandFade,
                          ),
                          backdrop: backdropImage,
                        ),
                ),
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    AppSpacing.page,
                    topOverlap +
                        (item.isSeries ? AppSpacing.lg : AppSpacing.xl),
                    AppSpacing.page,
                    item.isSeries ? AppSpacing.md : AppSpacing.xl,
                  ),
                  child: Container(
                    padding: EdgeInsets.all(
                      stacked ? AppSpacing.md : AppSpacing.lg,
                    ),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          theme.colorScheme.surfaceContainerLowest.withValues(
                            alpha: light ? .82 : .58,
                          ),
                          theme.colorScheme.surfaceContainerHigh.withValues(
                            alpha: light ? .62 : .30,
                          ),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(AppRadii.overlay + 4),
                      border: Border.all(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: light ? .10 : .16,
                        ),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: AppInk.scrim(light ? .08 : .20),
                          blurRadius: 32,
                          offset: const Offset(0, 16),
                        ),
                      ],
                    ),
                    // The poster and copy read as one content stage above the
                    // artwork instead of unrelated widgets over a backdrop.
                    child: Flex(
                      direction: stacked ? Axis.vertical : Axis.horizontal,
                      crossAxisAlignment: stacked
                          ? CrossAxisAlignment.start
                          : CrossAxisAlignment.end,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _DetailPoster(
                          item: artworkItem ?? item,
                          layoutWidth: width,
                        ),
                        SizedBox(
                          width: stacked ? 0 : AppSpacing.xl,
                          height: stacked ? AppSpacing.lg : 0,
                        ),
                        Flexible(
                          fit: FlexFit.loose,
                          child: _DetailInfo(
                            item: item,
                            runtime: runtime,
                            compact: width < AppBreakpoints.compact,
                            seasonCount: seasonCount,
                            seriesId: seriesId,
                            overview: overview,
                            overviewWidget: overviewWidget,
                            genres: genres,
                            mediaSource: _headerSource(item, mediaSourceId),
                            playEpisode: item.isSeries ? nextEpisode : null,
                            onLocateEpisode: onLocateEpisode,
                            actions: _DetailActions(
                              item: item,
                              busyPlayed: busyPlayed,
                              onPlay: onPlay,
                              onPlayFromStart: onPlayFromStart,
                              onOpenPreviousEpisode: onOpenPreviousEpisode,
                              onOpenNextEpisode: onOpenNextEpisode,
                              onPlayedChanged: onPlayedChanged,
                              busyFavorite: busyFavorite,
                              onFavoriteChanged: onFavoriteChanged,
                              playEpisode: item.isSeries ? nextEpisode : null,
                              mediaSourceId: mediaSourceId,
                              audioStreamIndex: audioStreamIndex,
                              subtitleStreamIndex: subtitleStreamIndex,
                              onMediaSource: onMediaSource,
                              onAudio: onAudio,
                              onSubtitle: onSubtitle,
                              holdOptionRow: holdOptionRow,
                            ),
                          ),
                        ),
                      ],
                    ),
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

/// 头部左栏:电影/剧集为干净 2:3 海报,单集为 16:9 剧照;简介一律在信息栏。
class _DetailPoster extends StatelessWidget {
  const _DetailPoster({required this.item, required this.layoutWidth});

  final MediaItem item;
  final double layoutWidth;

  static double posterWidthFor(double width) {
    if (width < AppBreakpoints.compact) {
      return 160;
    }
    if (width < AppBreakpoints.large) {
      return 200;
    }
    return 240;
  }

  /// 剧集页以分集为主体,海报只作识别,比电影海报收一档。
  static double seriesPosterWidthFor(double width) {
    if (width < AppBreakpoints.compact) {
      return 132;
    }
    if (width < AppBreakpoints.large) {
      return 156;
    }
    return 176;
  }

  /// 单集剧照宽:比海报略宽,但不要把本季分集挤出首屏。
  static double thumbWidthFor(double width) {
    if (width < AppBreakpoints.compact) {
      return 280;
    }
    if (width < AppBreakpoints.large) {
      return 336;
    }
    return 384;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = AppUiTheme.of(context).colorScheme;
    final episode = item.isEpisode;
    final series = item.isSeries || item.isSeason;
    final width =
        (episode
            ? thumbWidthFor(layoutWidth)
            : series
            ? seriesPosterWidthFor(layoutWidth)
            : posterWidthFor(layoutWidth)) *
        (series ? AppViewport.readingScaleOf(MediaQuery.sizeOf(context)) : 1);
    final height = episode ? width * 9 / 16 : width * 3 / 2;
    return DecoratedBox(
      key: ItemDetailPage.posterKey,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadii.lg),
        border: Border.all(color: AppEdge.of(scheme.brightness, strong: true)),
        boxShadow: AppShadow.cardHover(scheme.brightness),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadii.lg),
        child: SizedBox(
          width: width,
          height: height,
          child: MediaImage(
            key: const ValueKey('detail-poster'),
            item: item,
            // 海报卡只作识别;氛围始终来自规范 backdrop。
            // 稳定 key 才能在换季时把旧画面留到新图第一帧。
            width: width,
            height: height,
            preferThumb: episode,
            fit: BoxFit.cover,
            retainVisibleFrame: true,
            maxWidth: episode ? 720 : 480,
          ),
        ),
      ),
    );
  }
}

/// 头部右栏:剧名链接(单集)、标题、元信息胶囊与操作区。
class _DetailInfo extends StatelessWidget {
  const _DetailInfo({
    required this.item,
    required this.runtime,
    required this.compact,
    required this.seasonCount,
    required this.seriesId,
    required this.onLocateEpisode,
    required this.actions,
    this.overview,
    this.overviewWidget,
    this.playEpisode,
    this.genres = const [],
    this.mediaSource,
  });

  final MediaItem item;
  final List<String> genres;
  final ItemMediaSource? mediaSource;
  final String? runtime;
  final bool compact;
  final int seasonCount;
  final String? seriesId;
  final VoidCallback? onLocateEpisode;
  final Widget actions;
  final String? overview;
  final Widget? overviewWidget;
  final MediaItem? playEpisode;

  /// 简介行宽上限:约 70–90 个汉字/行,超过后行长过长可读性下降。
  static const double overviewMaxWidth = 720;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final seriesName = item.seriesName;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (item.isEpisode && seriesName != null && seriesName.isNotEmpty)
          _SeriesLink(
            name: seriesName,
            seriesId: seriesId ?? item.seriesId,
            seasonId: item.seasonId ?? item.parentId,
          ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: AppSelectableText(
            item.name,
            key: ItemDetailPage.titleKey,
            style:
                (compact
                        ? theme.textTheme.headlineLarge
                        : theme.textTheme.displaySmall)
                    ?.copyWith(
                      color: theme.colorScheme.onSurface,
                      fontWeight: FontWeight.w700,
                      height: 1.10,
                      letterSpacing: -.6,
                    ),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        _MetaRow(
          item: item,
          runtime: runtime,
          seasonCount: seasonCount,
          playEpisode: playEpisode,
          onLocateEpisode: onLocateEpisode,
          badges: item.isSeries ? const [] : mediaTechBadges(mediaSource),
        ),
        if (genres.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sm),
          DetailGenreRow(item: item, genres: genres, dense: true),
        ],
        if (overviewWidget != null) ...[
          SizedBox(height: item.isSeries ? AppSpacing.sm : AppSpacing.md),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: overviewMaxWidth),
            child: overviewWidget,
          ),
        ] else if (overview != null && overview!.isNotEmpty) ...[
          SizedBox(height: item.isSeries ? AppSpacing.sm : AppSpacing.md),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: overviewMaxWidth),
            child: Text(
              overview!,
              key: CatalogKeys.overview,
              maxLines: item.isSeries ? 2 : 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.82),
                height: 1.6,
              ),
            ),
          ),
        ],
        SizedBox(height: item.isSeries ? AppSpacing.lg : AppSpacing.xl),
        actions,
      ],
    );
  }
}

/// 头部元信息:可点的集标单独成胶囊,时长、日期、季集数与进度收成一行。
class _MetaRow extends StatelessWidget {
  const _MetaRow({
    required this.item,
    required this.runtime,
    required this.seasonCount,
    this.playEpisode,
    this.onLocateEpisode,
    this.badges = const [],
  });

  final MediaItem item;
  final String? runtime;
  final int seasonCount;
  final MediaItem? playEpisode;
  final VoidCallback? onLocateEpisode;

  /// 画质/声道/字幕描边标签，跟在事实与评分后面。
  final List<String> badges;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = AppUiTheme.of(context).colorScheme;
    final theme = AppUiTheme.of(context);
    // 取色主题的 primaryContainer 与前景色有时几乎同色，集标会看不清。
    // 改用半透明前景色底，压在任何剧照上都读得出。
    final style = theme.textTheme.labelMedium?.copyWith(
      color: scheme.onSurface,
      letterSpacing: 0.2,
    );
    Widget chip(String text) {
      return Container(
        height: AppControlHeight.sm,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
        decoration: BoxDecoration(
          color: scheme.onSurface.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppRadii.pill),
          border: Border.all(color: AppEdge.of(theme.brightness, strong: true)),
        ),
        child: Align(widthFactor: 1, child: Text(text, style: style)),
      );
    }

    Widget locateChip(
      String text, {
      VoidCallback? onTap,
      String? tooltip,
      Key? key,
    }) {
      final body = chip(text);
      if (onTap == null) {
        return body;
      }
      return AppTooltip(
        message: tooltip ?? l10n.pickEpisode,
        child: AppSurfaceAction(
          key: key ?? CatalogKeys.locateEpisode,
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadii.pill),
          child: body,
        ),
      );
    }

    // 剧集要播哪一集已写在播放钮上，元信息行不再重复一枚集标胶囊。
    final year = item.productionYear;
    final facts = <String>[
      if (!item.isEpisode && year != null && year > 0) '$year',
      ?runtime,
      if (item.isEpisode && item.premiereDate != null)
        l10n.premiereDate(formatDateYmd(item.premiereDate!)),
      // Emby 剧集的 ChildCount 是季数，不再误标成「N 集」。
      if (item.isSeries && seasonCount > 0) l10n.seasonCount(seasonCount),
    ];
    final rating = item.isEpisode ? null : item.communityRating;
    final actions = <Widget>[
      if (item.isEpisode)
        locateChip(
          seasonEpisodeCode(item) ?? episodeLabel(item),
          onTap: onLocateEpisode,
        ),
    ];
    final factStyle = theme.textTheme.bodyMedium?.copyWith(
      color: scheme.onSurface.withValues(alpha: .78),
      height: 1.5,
    );
    // 画质/声道标签:发丝描边的安静小标,不抢事实文字。
    Widget badge(String text) => DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadii.xs),
        border: Border.all(color: AppEdge.of(theme.brightness, strong: true)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Text(
          text,
          style: theme.textTheme.labelSmall?.copyWith(
            color: scheme.onSurface.withValues(alpha: .85),
            letterSpacing: .3,
          ),
        ),
      ),
    );
    final remaining = item.canResume ? remainingLabel(l10n, item) : null;
    // 集标、事实、评分与画质标签排在同一行，换行时按块折行。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ...actions,
            if (facts.isNotEmpty) Text(facts.join(' · '), style: factStyle),
            if (rating != null) HeroRatingBadge(rating: rating, onScrim: false),
            for (final label in badges) badge(label),
          ],
        ),
        if (item.canResume) ...[
          const SizedBox(height: AppSpacing.sm),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(
                container: true,
                label: l10n.playbackProgress(
                  (item.playbackProgress * 100).round(),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadii.sm),
                  child: SizedBox(
                    key: CatalogKeys.resumeProgress,
                    width: 200,
                    child: AppLoadingBar(
                      value: item.playbackProgress.clamp(0, 1),
                      minHeight: 4,
                      color: scheme.primary,
                      backgroundColor: scheme.onSurface.withValues(alpha: .16),
                    ),
                  ),
                ),
              ),
              if (remaining != null) ...[
                const SizedBox(width: AppSpacing.sm),
                ExcludeSemantics(
                  child: Text(
                    remaining,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ],
    );
  }
}

ItemMediaSource? _headerSource(MediaItem item, String? id) {
  for (final source in item.mediaSources) {
    if (source.id == id) return source;
  }
  return item.mediaSources.firstOrNull;
}

/// PopupMenuButton 把 null 当成取消,字幕关闭用哨兵值再映回 null。
const _subtitleOffToken = -1;

/// 操作区两行：
///
/// 1. **动作组**（[ItemDetailPage.actionRowKey]）——「按下去会怎样」：唯一的
///    primary「播放」（写明续播/哪一集）固定在第一位，其后全部是同高的带字
///    次级按钮：「从头播放 / 上一集 / 下一集 / 收藏 / 已看 / 其他来源」。
///    收藏与已看是开关，激活时为实底加填充图标并输出 Semantics toggled。
///    不可用的项不渲染，也不留空位；窄窗口整组折行（1024 下最多两行）。
/// 2. **播放设置行**（[ItemDetailPage.optionRowKey]）——「这次播的是什么」：
///    只放真正可选的版本、音轨、字幕，做成「图标 + 类别 | 当前值 ˅」的安静
///    下拉胶囊。没有可选项时整行不画。媒体信息分区不再重复列出这里能选的轨道。
class _DetailActions extends StatelessWidget {
  const _DetailActions({
    required this.item,
    required this.busyPlayed,
    required this.onPlayedChanged,
    this.onPlay,
    this.onPlayFromStart,
    this.onOpenPreviousEpisode,
    this.onOpenNextEpisode,
    this.playEpisode,
    this.mediaSourceId,
    this.audioStreamIndex,
    this.subtitleStreamIndex,
    this.onMediaSource,
    this.onAudio,
    this.onSubtitle,
    this.busyFavorite = false,
    this.onFavoriteChanged,
    this.holdOptionRow = false,
  });

  final MediaItem item;
  final bool busyPlayed;
  final ValueChanged<bool> onPlayedChanged;

  /// 选项行暂无内容时仍占一行高度（相邻集预览，详情未到）。
  final bool holdOptionRow;
  final VoidCallback? onPlay;
  final VoidCallback? onPlayFromStart;
  final VoidCallback? onOpenPreviousEpisode;
  final VoidCallback? onOpenNextEpisode;
  final MediaItem? playEpisode;
  final String? mediaSourceId;
  final int? audioStreamIndex;
  final int? subtitleStreamIndex;
  final ValueChanged<String>? onMediaSource;
  final ValueChanged<int>? onAudio;
  final ValueChanged<int?>? onSubtitle;
  final bool busyFavorite;

  /// 服务器支持收藏时才有；为空则不画收藏钮。
  final ValueChanged<bool>? onFavoriteChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final audios = _audioChoices(item, mediaSourceId);
    final subtitles = _subtitleChoices(item, mediaSourceId);
    final sourceId =
        mediaSourceId ??
        (item.mediaSources.isEmpty ? null : item.mediaSources.first.id);
    String sourceLabel = '';
    for (final source in item.mediaSources) {
      if (source.id == sourceId) {
        sourceLabel = phoneSourceVersionLabel(source, item.mediaSources);
        break;
      }
    }
    String audioLabel = l10n.audioTrack;
    for (final stream in audios) {
      if (stream.index == audioStreamIndex) {
        audioLabel = stream.label ?? '#${stream.index}';
        break;
      }
    }
    var subtitleLabel = l10n.subtitleOff;
    if (subtitleStreamIndex != null) {
      for (final stream in subtitles) {
        if (stream.index == subtitleStreamIndex) {
          subtitleLabel = stream.label ?? '#${stream.index}';
          break;
        }
      }
    }
    final played = item.userData.played;
    final favorite = item.userData.favorite;
    final resume = onPlayFromStart != null || item.canResume;
    final listed = playEpisode;
    final playCode = listed != null && listed.isEpisode
        ? seasonEpisodeCode(listed)
        : null;
    final playLabel = playCode == null
        ? (resume ? l10n.resumePlay : l10n.play)
        : (resume
              ? l10n.resumePlayEpisode(playCode)
              : l10n.playEpisode(playCode));
    final playbackActions = <Widget>[
      if (onPlay != null)
        Container(
          constraints: const BoxConstraints(minWidth: 184),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadii.pill),
            boxShadow: [
              BoxShadow(
                color: AppUiTheme.of(context).colorScheme.primary
                    .withValues(alpha: .24),
                blurRadius: 20,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: AppActionButton(
            key: PlayerKeys.open,
            tier: AppActionTier.primary,
            onPressed: onPlay,
            icon: AppIcons.play,
            label: playLabel,
          ),
        ),
      if (onPlayFromStart != null)
        AppActionButton(
          key: PlayerKeys.resumeFromStart,
          onPressed: onPlayFromStart,
          icon: AppIcons.replay,
          label: l10n.playFromStart,
        ),
      if (onOpenPreviousEpisode != null)
        AppActionButton(
          key: CatalogKeys.previousEpisode,
          onPressed: onOpenPreviousEpisode,
          icon: AppIcons.skipPrevious,
          label: l10n.previousEpisode,
        ),
      if (onOpenNextEpisode != null)
        AppActionButton(
          key: CatalogKeys.nextEpisode,
          onPressed: onOpenNextEpisode,
          icon: AppIcons.skipNext,
          label: l10n.nextEpisode,
        ),
    ];
    final libraryActions = <Widget>[
      if (onFavoriteChanged != null)
        AppActionButton(
          key: CatalogKeys.favoriteToggle,
          active: favorite,
          icon: AppIcons.favorite,
          label: favorite ? l10n.phoneFavorited : l10n.phoneFavorite,
          onPressed: busyFavorite ? null : () => onFavoriteChanged!(!favorite),
        ),
      AppActionButton(
        key: CatalogKeys.playedToggle,
        active: played,
        icon: played
            ? CupertinoIcons.checkmark_circle_fill
            : CupertinoIcons.checkmark_circle,
        label: played ? l10n.watchedAction : l10n.markPlayed,
        tooltip: played ? l10n.markUnplayed : l10n.markPlayed,
        onPressed: busyPlayed ? null : () => onPlayedChanged(!played),
      ),
      // 跨服务器找同一部影片：与其他次级动作同组，不再单占选项行。
      if (SourceSelectionAction.availableIn(context))
        SourceSelectionAction(
          builder: (context, view) => AppActionButton(
            key: SourceSelectionActionView.key,
            icon: view.icon,
            label: view.shortLabel,
            tooltip: view.label,
            semanticLabel: view.label,
            onPressed: view.loading ? null : view.onPressed,
          ),
        ),
    ];
    final viewport = MediaQuery.sizeOf(context);
    final sourceMenuMax = AppViewport.fit(420, viewport.width - 48, viewport);
    final sourceMenuMin = AppViewport.dp(280, viewport);
    final choices = <Widget>[
      if (item.mediaSources.length > 1)
        _DetailMenuButton<String>(
          menuKey: CatalogKeys.mediaSource,
          initialValue: sourceId,
          category: l10n.mediaSource,
          value: sourceLabel,
          icon: AppIcons.mediaSource,
          constraints: BoxConstraints(
            minWidth: sourceMenuMin < sourceMenuMax
                ? sourceMenuMin
                : sourceMenuMax,
            maxWidth: sourceMenuMax,
          ),
          items: [
            for (final source in item.mediaSources)
              AppMenuEntry(
                value: source.id,
                child: MediaSourceMenuTile(view: source.presentation),
              ),
          ],
          onSelected: (value) => onMediaSource?.call(value),
        ),
      if (_audioSelectable(audios))
        _DetailMenuButton<int>(
          menuKey: CatalogKeys.detailAudio,
          initialValue: audioStreamIndex,
          category: l10n.audioTrack,
          value: audioLabel,
          icon: AppIcons.music,
          items: [
            for (final stream in audios)
              AppMenuEntry(
                value: stream.index,
                child: Text(stream.label ?? '#${stream.index}'),
              ),
          ],
          onSelected: (value) => onAudio?.call(value),
        ),
      if (_subtitleSelectable(subtitles))
        _DetailMenuButton<int>(
          menuKey: CatalogKeys.detailSubtitle,
          initialValue: subtitleStreamIndex ?? _subtitleOffToken,
          category: l10n.subtitleTrack,
          value: subtitleLabel,
          icon: AppIcons.subtitles,
          items: [
            AppMenuEntry<int>(
              value: _subtitleOffToken,
              child: Text(l10n.subtitleOff),
            ),
            for (final stream in subtitles)
              AppMenuEntry<int>(
                value: stream.index,
                child: Text(stream.label ?? '#${stream.index}'),
              ),
          ],
          onSelected: (value) =>
              onSubtitle?.call(value == _subtitleOffToken ? null : value),
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Column(
          key: ItemDetailPage.actionRowKey,
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: playbackActions,
            ),
            if (libraryActions.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: AppSpacing.xs,
                runSpacing: AppSpacing.xs,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: libraryActions,
              ),
            ],
          ],
        ),
        if (choices.isEmpty && holdOptionRow) ...[
          const SizedBox(height: AppSpacing.md),
          // 不可见、不可点、不进读屏，只占一枚选项胶囊的高度。
          Visibility(
            key: ItemDetailPage.optionRowPlaceholderKey,
            visible: false,
            maintainSize: true,
            maintainAnimation: true,
            maintainState: true,
            child: Container(
              padding: const EdgeInsets.all(AppSpacing.xs),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadii.lg),
                border: Border.all(color: AppInk.transparent),
              ),
              child: const _DetailOptionChip(
                icon: AppIcons.mediaSource,
                value: ' ',
                tooltip: ' ',
                semanticLabel: '',
                onPressed: null,
              ),
            ),
          ),
        ],
        if (choices.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.md),
          Container(
            padding: const EdgeInsets.all(AppSpacing.xs),
            decoration: BoxDecoration(
              color: AppUiTheme.of(context).colorScheme.surfaceContainerLowest
                  .withValues(alpha: .24),
              borderRadius: BorderRadius.circular(AppRadii.lg),
              border: Border.all(
                color: AppUiTheme.of(context).colorScheme.onSurface
                    .withValues(alpha: .10),
              ),
            ),
            child: Semantics(
              container: true,
              label: l10n.detailPlaybackOptions,
              child: Wrap(
                key: ItemDetailPage.optionRowKey,
                spacing: AppSpacing.xs,
                runSpacing: AppSpacing.xs,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: choices,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// 头部是否画播放选项行（多版本、多音轨或有字幕）。
bool _hasOptionRow(MediaItem item, String? sourceId) =>
    item.mediaSources.length > 1 ||
    _audioSelectable(_audioChoices(item, sourceId)) ||
    _subtitleSelectable(_subtitleChoices(item, sourceId));

/// 音轨多于一条时才在播放设置行提供选择。
bool _audioSelectable(List<ItemMediaStream> audios) => audios.length > 1;

/// 有任一字幕即可选择（含关闭字幕）。
bool _subtitleSelectable(List<ItemMediaStream> subtitles) =>
    subtitles.isNotEmpty;

/// 播放设置胶囊：「图标 + 类别标签 + 当前值 (+ ˅)」，与次级动作同高、安静表面、
/// 发丝边。
/// 当前值是要告诉用户的事实，所以写在按钮上；类别说明同时展示并走 tooltip 与读屏。
class _DetailOptionChip extends StatelessWidget {
  const _DetailOptionChip({
    super.key,
    required this.icon,
    required this.value,
    required this.tooltip,
    required this.semanticLabel,
    required this.onPressed,
    this.category,
    this.dropdown = false,
  });

  final IconData icon;
  final String? category;
  final String value;
  final String tooltip;
  final String semanticLabel;
  final VoidCallback? onPressed;

  /// 为 true 时行尾画 ˅，表示点开是就地下拉选择。
  final bool dropdown;

  /// 当前值过长（发布串、长音轨名）时截断，完整值在 tooltip 里。
  static const double maxValueWidth = 220;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    final light = scheme.brightness == Brightness.light;
    final muted = light
        ? scheme.onSurfaceVariant
        : scheme.onSurface.withValues(alpha: .74);
    final categoryLabel = category;
    return Semantics(
      button: true,
      label: semanticLabel,
      excludeSemantics: true,
      child: AppTooltip(
        message: tooltip,
        child: AppButton(
          onPressed: onPressed,
          variant: AppButtonVariant.outlined,
          style: AppButtonStyle(
            foregroundColor: scheme.onSurface,
            backgroundColor: light
                ? scheme.surfaceContainerLowest.withValues(alpha: .92)
                : scheme.surfaceContainerHigh.withValues(alpha: .54),
            side: BorderSide(
              color: light
                  ? scheme.outlineVariant
                  : scheme.onSurface.withValues(alpha: .18),
            ),
            faceExtent: AppActionButton.extentOf(context),
            padding: EdgeInsetsDirectional.only(
              start: AppSpacing.sm,
              end: dropdown ? AppSpacing.xs + 2 : AppSpacing.sm,
            ),
            shape: const StadiumBorder(),
            textStyle: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox.square(
                dimension: 18,
                child: Icon(icon, size: 17, color: scheme.primary, fill: 1),
              ),
              const SizedBox(width: 6),
              if (categoryLabel != null && categoryLabel.isNotEmpty) ...[
                Text(
                  categoryLabel,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: muted,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                Container(
                  width: 1,
                  height: 12,
                  margin: const EdgeInsets.symmetric(horizontal: 7),
                  color: scheme.onSurface.withValues(alpha: .16),
                ),
              ],
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: maxValueWidth),
                child: Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (dropdown) ...[
                const SizedBox(width: 3),
                Icon(AppIcons.chevronDown, size: 17, color: muted),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 播放选项下拉：[_DetailOptionChip] 显示类别与当前值，点开就地弹出菜单。
class _DetailMenuButton<T> extends StatelessWidget {
  const _DetailMenuButton({
    required this.category,
    required this.value,
    required this.icon,
    required this.items,
    required this.onSelected,
    this.menuKey,
    this.initialValue,
    this.constraints,
  });

  final T? initialValue;
  final Key? menuKey;
  final String category;
  final String value;
  final IconData icon;
  final List<AppMenuEntry<T>> items;
  final ValueChanged<T> onSelected;
  final BoxConstraints? constraints;

  Future<void> _open(BuildContext context) async {
    final button = context.findRenderObject()! as RenderBox;
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        button.localToGlobal(Offset.zero, ancestor: overlay),
        button.localToGlobal(
          button.size.bottomRight(Offset.zero),
          ancestor: overlay,
        ),
      ),
      Offset.zero & overlay.size,
    );
    final value = await showAppMenu<T>(
      context: context,
      items: items,
      position: position,
      constraints: constraints,
      selected: initialValue,
    );
    if (value != null) {
      onSelected(value);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _DetailOptionChip(
      key: menuKey,
      icon: icon,
      category: category,
      value: value,
      tooltip: '$category · $value',
      semanticLabel: '$category，$value',
      dropdown: true,
      onPressed: () => unawaited(_open(context)),
    );
  }
}

/// 详情页加载骨架:头部占位块(与真实头部同高)+ 文本行 + 分集网格占位。
class _DetailSkeleton extends StatelessWidget {
  const _DetailSkeleton({this.topOverlap = 0});

  final double topOverlap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final viewportHeight = MediaQuery.sizeOf(context).height;
        return SingleChildScrollView(
          physics: const NeverScrollableScrollPhysics(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SkeletonBlock(
                key: ItemDetailPage.skeletonHeaderKey,
                width: double.infinity,
                height:
                    _DetailHeader.heightFor(width, viewportHeight) + topOverlap,
                borderRadius: BorderRadius.zero,
              ),
              Padding(
                padding: const EdgeInsets.all(AppSpacing.page),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SkeletonBlock(width: width * 0.2, height: AppSpacing.lg),
                    const SizedBox(height: AppSpacing.sm),
                    const EpisodeListSkeleton(),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

List<ItemMediaStream> _audioChoices(MediaItem item, String? sourceId) {
  if (item.mediaSources.isEmpty) {
    return const [];
  }
  var source = item.mediaSources.first;
  if (sourceId != null) {
    for (final candidate in item.mediaSources) {
      if (candidate.id == sourceId) {
        source = candidate;
        break;
      }
    }
  }
  return source.audioStreams;
}

List<ItemMediaStream> _subtitleChoices(MediaItem item, String? sourceId) {
  if (item.mediaSources.isEmpty) {
    return const [];
  }
  var source = item.mediaSources.first;
  if (sourceId != null) {
    for (final candidate in item.mediaSources) {
      if (candidate.id == sourceId) {
        source = candidate;
        break;
      }
    }
  }
  return source.subtitleStreams;
}
