import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/app_shell.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/widgets/app_error_view.dart';
import 'package:rillight/app/widgets/backdrop_scrim.dart';
import 'package:rillight/app/widgets/media_source_menu_tile.dart';
import 'package:rillight/app/widgets/scrim_icon_button.dart';
import 'package:rillight/app/widgets/skeleton.dart';
import 'package:rillight/app/window_chrome.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/catalog_cache.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_failure.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/home/media_shelf.dart';
import 'package:rillight/library/episode_detail_sections.dart';
import 'package:rillight/library/episode_list.dart';
import 'package:rillight/library/item_format.dart';
import 'package:rillight/library/poster_card.dart';
import 'package:rillight/media_image/media_image.dart';
import 'package:rillight/player/player_keys.dart';
import 'package:rillight/player/player_window_host.dart';

class ItemDetailPage extends StatefulWidget {
  const ItemDetailPage({super.key, required this.itemId, this.initialSeasonId});

  final String itemId;

  /// 打开剧集时预选的季;单集「查看剧集」带入所属季,避免落到第一季。
  final String? initialSeasonId;

  /// 加载完成后的头部根节点,供测试比对骨架/真实头部高度。
  static const headerKey = Key('detail-header');

  /// 骨架屏中的头部占位块,与 [headerKey] 同高。
  static const skeletonHeaderKey = Key('detail-skeleton-header');

  /// 头部左侧海报/缩略图区。
  static const posterKey = Key('detail-poster');

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
  EmbyItem? _item;
  List<EmbyItem> _seasons = const [];
  List<EmbyItem> _episodes = const [];
  List<EmbyItem> _similar = const [];
  String? _seasonId;
  String? _seriesId;
  String? _seriesOverview;
  String? _focusedEpisodeId;
  EmbyItem? _previousEpisode;
  EmbyItem? _nextEpisode;
  bool _loading = true;
  bool _busyPlayed = false;
  final _busyPlayedIds = <String>{};
  EmbyException? _error;
  EmbyException? _similarError;

  /// 季切换/重试失败时分集分区内联显示的错误;成功后清空。
  EmbyException? _episodeError;

  /// 已有剧集时，继续加载下一窗或跳到未加载集数失败；列表保留，分区内说明并重试。
  EmbyException? _episodeLoadMoreError;

  /// 跳转窗口失败时要重试的集号。为空表示 [_episodeLoadMoreError] 来自继续加载。
  int? _pendingJumpNumber;

  /// 作废进行中的选集跳转，避免切季或继续加载之后写入过期失败。
  int _jumpSerial = 0;
  int _episodeReveal = 0;
  bool _episodesLoading = false;
  bool _loadingMore = false;
  String? _mediaSourceId;
  bool _pickedMediaSource = false;
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
    if (closed && mounted) {
      unawaited(_load(keepChrome: true, refreshCatalog: true));
    }
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
    EmbyItem? preview;
    for (final episode in _episodes) {
      if (episode.id == itemId) {
        preview = episode;
        break;
      }
    }
    final shown = preview;
    if (shown != null && mounted) {
      setState(() {
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
        _similar = const [];
        _seasonId = null;
        _seriesId = null;
        _seriesOverview = null;
        _focusedEpisodeId = null;
        _previousEpisode = null;
        _nextEpisode = null;
        _mediaSourceId = null;
        _pickedMediaSource = false;
        _audioStreamIndex = null;
        _subtitleStreamIndex = null;
        _episodeTotal = 0;
        _episodeWindowEnd = 0;
      });
    }
    final requestedId = _itemId;
    final client = AuthScope.of(context).client;
    // 先显:详情条目命中缓存时先渲染主体,后台继续拉完整数据后无感更新。
    if (!keep && _item == null) {
      final hit = await _cache.lookup(
        catalogItemRequest(
          userId: client.userId ?? '',
          itemId: requestedId,
          fields: _detailFields,
        ),
      );
      if (!mounted || gen != _loadGen) {
        return;
      }
      if (hit != null) {
        try {
          final cachedItem = parseCatalogItem(hit.json);
          setState(() {
            _item = cachedItem;
            _loading = false;
          });
        } on EmbyException {
          // 损坏缓存忽略,继续走网络加载。
        }
      }
    }
    try {
      final item = await _fetchItem(client, requestedId);
      if (!mounted || gen != _loadGen) {
        return;
      }
      var seasons = const <EmbyItem>[];
      var episodes = const <EmbyItem>[];
      var episodeTotal = 0;
      var episodeWindowEnd = 0;
      String? seasonId;
      String? seriesId;
      EmbyItem? previousEpisode;
      EmbyItem? nextEpisode;
      final reuseCatalog =
          keep &&
          !refreshCatalog &&
          _seriesId != null &&
          ((item.isEpisode && item.seriesId == _seriesId) ||
              (item.isSeries && item.id == _seriesId));
      var seriesOverviewTask = Future<String?>.value(_seriesOverview);
      if (item.isSeries || item.isEpisode) {
        seriesId = reuseCatalog
            ? _seriesId
            : await _resolveSeriesId(client, item);
        if (!mounted || gen != _loadGen) {
          return;
        }
        seriesOverviewTask = _seriesOverviewTask(
          client,
          item: item,
          seriesId: seriesId,
          cached: _seriesOverview,
        );
        if (reuseCatalog && _seasons.isNotEmpty) {
          seasons = _seasons;
        } else if (seriesId != null && seriesId.isNotEmpty) {
          seasons = await client.getItems(
            parentId: seriesId,
            includeItemTypes: 'Season',
            sortBy: 'IndexNumber',
            sortOrder: 'Ascending',
          );
          if (!mounted || gen != _loadGen) {
            return;
          }
        }
        if (item.isEpisode) {
          seasonId = _preferredSeasonId(item, seasons);
        } else if (seasons.isNotEmpty) {
          seasonId = _requestedSeasonId() ?? seasons.first.id;
        }
        if (reuseCatalog &&
            seasonId == _seasonId &&
            _episodes.any((episode) => episode.id == item.id)) {
          episodes = _episodes;
          episodeTotal = _episodeTotal;
          episodeWindowEnd = _episodeWindowEnd;
        } else if (seasonId != null && seasonId.isNotEmpty) {
          if (item.isEpisode) {
            // 集详情:整季拉取,供本季分集横排完整切集导航。
            final window = await _loadSeasonEpisodes(client, seasonId, item);
            episodes = window.items;
            episodeTotal = window.total;
            episodeWindowEnd = window.end;
          } else {
            final window = await _loadEpisodeWindow(
              client,
              seasonId: seasonId,
              current: item.isEpisode ? item : null,
            );
            if (!mounted || gen != _loadGen) {
              return;
            }
            episodes = window.items;
            episodeTotal = window.total;
            episodeWindowEnd = window.end;
          }
        }
        if (!mounted || gen != _loadGen) {
          return;
        }
        if (item.isEpisode) {
          previousEpisode = _siblingBefore(item, episodes);
          nextEpisode = _siblingAfter(item, episodes);
          if (nextEpisode == null) {
            try {
              nextEpisode = await client.getNextEpisode(item);
            } on EmbyException {
              nextEpisode = null;
            }
          }
        }
      }
      var similar = const <EmbyItem>[];
      EmbyException? similarError;
      if (reuseCatalog) {
        similar = _similar;
        similarError = _similarError;
      } else {
        try {
          similar = (await client.getSimilar(
            item.id,
            limit: 24,
          )).where((entry) => entry.id != item.id).toList();
        } on EmbyException catch (error) {
          if (_hideSimilar(error)) {
            similar = const [];
          } else {
            similarError = error;
          }
        }
      }
      final seriesOverview = await seriesOverviewTask;
      if (!mounted || gen != _loadGen) {
        return;
      }
      setState(() {
        _item = item;
        _seasons = seasons;
        _episodes = episodes;
        _episodeTotal = episodeTotal;
        _episodeWindowEnd = episodeWindowEnd;
        _episodeError = null;
        _episodeLoadMoreError = null;
        _pendingJumpNumber = null;
        _episodesLoading = false;
        _seasonId = seasonId;
        _seriesId = seriesId;
        _seriesOverview = seriesOverview;
        if (item.isSeries) {
          if (refreshCatalog || _focusedEpisodeId == null) {
            _focusedEpisodeId = _playTarget(item)?.id;
          }
        }
        _previousEpisode = previousEpisode;
        _nextEpisode = nextEpisode;
        _similar = similar;
        _similarError = similarError;
        _loading = false;
        _mediaSourceId = item.mediaSources.isEmpty
            ? null
            : item.mediaSources.first.id;
        _pickedMediaSource = false;
        _audioStreamIndex = _defaultAudio(item, _mediaSourceId);
        _subtitleStreamIndex = _defaultSubtitle(item, _mediaSourceId);
      });
    } on EmbyException catch (error) {
      if (!mounted || gen != _loadGen) {
        return;
      }
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  CatalogCache? _scopeCache;

  /// 目录缓存:无 CatalogScope 时用无会话实例降级直连。
  CatalogCache get _cache =>
      _scopeCache ??= CatalogScope.maybeOf(context)?.cache ?? CatalogCache();

  /// 经缓存层拉取单条详情(总是走网络并写穿缓存)。
  Future<EmbyItem> _fetchItem(EmbyClient client, String itemId) async {
    return parseCatalogItem(
      await _cache.fetch(
        client,
        catalogItemRequest(
          userId: client.userId ?? '',
          itemId: itemId,
          fields: _detailFields,
        ),
      ),
    );
  }

  /// 剧集页预选季:路由 `season` 有值则用之,缺省仍是第一季。
  String? _requestedSeasonId() {
    final requested = widget.initialSeasonId?.trim();
    if (requested == null || requested.isEmpty) {
      return null;
    }
    return requested;
  }

  /// 单集所属季:优先条目自带的 seasonId/parentId,即使季列表里没有它
  /// (服务端季数据缺失或错位)也按真实归属查询;缺失时才按季号与首季兜底。
  String? _preferredSeasonId(EmbyItem item, List<EmbyItem> seasons) {
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

  Future<EmbyItemPage> _queryEpisodes(
    EmbyClient client,
    String seasonId,
    int startIndex, {
    int? limit,
  }) {
    return client.queryItems(
      parentId: seasonId,
      includeItemTypes: 'Episode',
      sortBy: 'IndexNumber',
      sortOrder: 'Ascending',
      startIndex: startIndex,
      limit: limit ?? _episodePageSize,
      fields: EmbyClient.itemFields,
    );
  }

  /// 集详情页一次拉整季(上限 [_episodeDetailSeasonLimit]):本季分集
  /// 横排是切集导航,只给当前窗口会出现"无法向左翻页"。超限季退回窗口。
  Future<_EpisodeWindow> _loadSeasonEpisodes(
    EmbyClient client,
    String seasonId,
    EmbyItem current,
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
    EmbyClient client, {
    required String seasonId,
    EmbyItem? current,
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
  }

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
        AuthScope.of(context).client,
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
    } on EmbyException catch (error) {
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
        final page = await AuthScope.of(context).client.queryItems(
          parentId: seasonId,
          includeItemTypes: 'Episode',
          sortBy: 'IndexNumber',
          sortOrder: 'Ascending',
          limit: 1,
        );
        total = page.totalRecordCount ?? _episodes.length;
      } on EmbyException {
        total = _episodes.length;
      }
    }
    if (!mounted || total <= 0) {
      return;
    }
    final currentNumber = _item?.indexNumber;
    final selected = await showDialog<int>(
      context: context,
      builder: (context) => _EpisodeNumberPicker(
        total: total,
        current: currentNumber,
        seasonId: seasonId,
        client: AuthScope.of(context).client,
      ),
    );
    if (!mounted || selected == null) {
      return;
    }
    await _jumpToEpisodeNumber(selected);
  }

  Future<void> _jumpToEpisodeNumber(int number) async {
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
        _openOrRevealEpisode(episode.id);
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
        AuthScope.of(context).client,
        seasonId: seasonId,
        aroundNumber: number,
      );
      if (!mounted || serial != _jumpSerial || _seasonId != seasonId) {
        return;
      }
      EmbyItem? target;
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
      _openOrRevealEpisode(target.id);
    } on EmbyException catch (error) {
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
    context.push(AppRoutes.item(id));
  }

  void _openOrRevealEpisode(String id) {
    if (_item?.isSeries ?? false) {
      _revealEpisode(id);
      return;
    }
    _showItem(id);
  }

  /// 切季:失败时分区内联显示错误与重试,而不是静默留下空列表。
  Future<void> _selectSeason(String seasonId) async {
    _jumpSerial++;
    setState(() {
      _seasonId = seasonId;
      _focusedEpisodeId = null;
      _episodes = const [];
      _episodeError = null;
      _episodeLoadMoreError = null;
      _pendingJumpNumber = null;
      _episodesLoading = true;
      _loadingMore = false;
      _episodeTotal = 0;
      _episodeWindowEnd = 0;
    });
    try {
      final window = await _loadEpisodeWindow(
        AuthScope.of(context).client,
        seasonId: seasonId,
      );
      if (!mounted || _seasonId != seasonId) {
        return;
      }
      setState(() {
        _applyWindow(window);
        _episodesLoading = false;
      });
    } on EmbyException catch (error) {
      if (!mounted || _seasonId != seasonId) {
        return;
      }
      setState(() {
        _episodeError = error;
        _episodesLoading = false;
      });
    }
  }

  void _openSeriesPage() {
    final item = _item;
    final seriesId = _seriesId ?? item?.seriesId;
    if (seriesId == null || seriesId.isEmpty) {
      return;
    }
    context.push(
      AppRoutes.item(seriesId, seasonId: item?.seasonId ?? _seasonId),
    );
  }

  Future<void> _openPlayer(
    String itemId, {
    int? startTimeTicks,
    bool fromBeginning = false,
  }) async {
    try {
      await PlayerWindowScope.of(context).open(
        PlayerOpenRequest(
          itemId: itemId,
          autoResume: !fromBeginning && startTimeTicks == null,
          mediaSourceId: _item?.id == itemId && _pickedMediaSource
              ? _mediaSourceId
              : null,
          audioStreamIndex: _item?.id == itemId && _pickedMediaSource
              ? _audioStreamIndex
              : null,
          subtitleStreamIndex: _item?.id == itemId && _pickedMediaSource
              ? _subtitleStreamIndex
              : null,
          startTimeTicks: startTimeTicks,
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.toString(), key: PlayerKeys.windowError)),
      );
    }
  }

  Future<void> _setPlayed(bool played) async {
    final item = _item;
    if (item == null) {
      return;
    }
    await _setItemPlayed(item, played);
  }

  EmbyUserData _optimisticPlayed(EmbyUserData current, {required bool played}) {
    return current.copyWith(
      played: played,
      playbackPositionTicks: 0,
      playedPercentage: played ? 100 : 0,
    );
  }

  void _patchPlayed(String id, EmbyUserData userData) {
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
  Future<void> _setItemPlayed(EmbyItem target, bool played) async {
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
    final client = AuthScope.of(context).client;
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
    } on EmbyException catch (error) {
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(error.toString(), key: PlayerKeys.windowError),
          ),
        );
      }
    }
  }

  String? _displayOverview(EmbyItem item) {
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
    EmbyClient client, {
    required EmbyItem item,
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
    } on EmbyException {
      return '';
    }
  }

  /// 详情 /Items/{id} 有时不带 ticks,继续观看列表却有百分比。
  /// 首页已拉过 Resume 时,把那份 UserData 补到当前条目。
  EmbyItem _withCatalogResume(EmbyItem item) {
    if (item.canResume) {
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

  EmbyItem? _playTarget(EmbyItem item) {
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
    if (_episodes.isNotEmpty) {
      return _episodes.first;
    }
    return null;
  }

  EmbyItem? _nextEpisodeAfter(EmbyItem item) {
    if (!item.isEpisode) {
      return null;
    }
    return _nextEpisode ?? _siblingAfter(item, _episodes);
  }

  EmbyItem? _previousEpisodeBefore(EmbyItem item) {
    if (!item.isEpisode) {
      return null;
    }
    return _previousEpisode ?? _siblingBefore(item, _episodes);
  }

  EmbyItem? _siblingBefore(EmbyItem item, List<EmbyItem> episodes) {
    final index = episodes.indexWhere((episode) => episode.id == item.id);
    if (index <= 0) {
      return null;
    }
    return episodes[index - 1];
  }

  EmbyItem? _siblingAfter(EmbyItem item, List<EmbyItem> episodes) {
    final index = episodes.indexWhere((episode) => episode.id == item.id);
    if (index < 0 || index + 1 >= episodes.length) {
      return null;
    }
    return episodes[index + 1];
  }

  Future<String?> _resolveSeriesId(EmbyClient client, EmbyItem item) async {
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
    } on EmbyException {
      return null;
    }
    return null;
  }

  int? _defaultAudio(EmbyItem item, String? sourceId) {
    final source = _sourceById(item, sourceId);
    final audios = source?.audioStreams ?? const [];
    return audios.isEmpty ? null : audios.first.index;
  }

  int? _defaultSubtitle(EmbyItem item, String? sourceId) {
    final source = _sourceById(item, sourceId);
    final subs = source?.subtitleStreams ?? const [];
    return subs.isEmpty ? null : subs.first.index;
  }

  ItemMediaSource? _sourceById(EmbyItem item, String? sourceId) {
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

  bool _hideSimilar(EmbyException error) {
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

    final runtime = runtimeLabel(l10n, item);
    final showSimilar = _similar.isNotEmpty || _similarError != null;
    final playTarget = _playTarget(item);
    final screenWidth = MediaQuery.sizeOf(context).width;
    final wideCardWidth = MediaShelf.wideCardWidthFor(screenWidth);
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.depth == 0 &&
            notification.metrics.axis == Axis.vertical) {
          HomeScrollNotification(
            notification.metrics.pixels > 24,
          ).dispatch(context);
        }
        return false;
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          SingleChildScrollView(
            padding: const EdgeInsets.only(bottom: AppSpacing.xxl),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _DetailHeader(
                  key: ItemDetailPage.headerKey,
                  item: item,
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
                  onViewSeries:
                      item.isEpisode && (_seriesId ?? item.seriesId) != null
                      ? _openSeriesPage
                      : null,
                  busyPlayed: _busyPlayed,
                  mediaSourceId: _mediaSourceId,
                  audioStreamIndex: _audioStreamIndex,
                  subtitleStreamIndex: _subtitleStreamIndex,
                  onMediaSource: (id) {
                    setState(() {
                      _pickedMediaSource = true;
                      _mediaSourceId = id;
                      _audioStreamIndex = _defaultAudio(item, id);
                      _subtitleStreamIndex = _defaultSubtitle(item, id);
                    });
                  },
                  onAudio: (index) => setState(() => _audioStreamIndex = index),
                  onSubtitle: (index) =>
                      setState(() => _subtitleStreamIndex = index),
                  overview: null,
                  // 电影/剧集/单集简介都放在标题旁信息栏,海报只作识别、不叠字。
                  overviewWidget: _displayOverview(item) == null
                      ? null
                      : EpisodeOverviewSection(
                          overview: _displayOverview(item),
                          compact: true,
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
                          startTimeTicks: playTarget.canResume
                              ? playTarget.resumePositionTicks
                              : null,
                        ),
                  onPlayFromStart: playTarget == null || !playTarget.canResume
                      ? null
                      : () => _openPlayer(playTarget.id, fromBeginning: true),
                  onPlayedChanged: (value) {
                    _setPlayed(value);
                  },
                ),
                if (item.isEpisode) ...[
                  // 本季分集横排:当前集高亮并自动滚入视野,点击直接切集。
                  if (_episodes.isNotEmpty)
                    MediaShelf(
                      shelfId: 'season-episodes',
                      title: l10n.seasonEpisodes,
                      items: _episodes,
                      wide: true,
                      focusItemId: item.id,
                      onTap: (episode) => _showItem(episode.id),
                      onMore: _seasonId == null
                          ? null
                          : () => context.push(
                              AppRoutes.shelfItems(
                                parentId: _seasonId,
                                includeItemTypes: 'Episode',
                                title: l10n.seasonEpisodes,
                              ),
                            ),
                      itemBuilder: (context, episode) {
                        // The merge inserts/replaces the exact current item.
                        // Do not highlight every distinct version of its number.
                        final isCurrent = episode.id == item.id;
                        return EpisodeThumbCard(
                          item: episode,
                          width: wideCardWidth,
                          selected: isCurrent,
                          onTap: () => _showItem(episode.id),
                        );
                      },
                    ),
                  if (item.chapters.isNotEmpty)
                    _ChapterStrip(
                      itemId: item.id,
                      chapters: item.chapters,
                      onSelect: (chapter) {
                        final playId = item.isPlayable
                            ? item.id
                            : playTarget?.id;
                        if (playId == null) {
                          return;
                        }
                        _openPlayer(
                          playId,
                          startTimeTicks: chapter.startPositionTicks,
                        );
                      },
                    ),
                  EpisodePeopleSection(people: item.people),
                  EpisodeMediaStreamsSection(
                    source: _sourceById(item, _mediaSourceId),
                  ),
                ],
                // 章节对所有类型可用(电影同样支持章节跳转)。
                if (!item.isEpisode && item.chapters.isNotEmpty)
                  _ChapterStrip(
                    itemId: item.id,
                    chapters: item.chapters,
                    onSelect: (chapter) {
                      final playId = item.isPlayable ? item.id : playTarget?.id;
                      if (playId == null) {
                        return;
                      }
                      _openPlayer(
                        playId,
                        startTimeTicks: chapter.startPositionTicks,
                      );
                    },
                  ),
                if (item.isSeries) ...[
                  EpisodeList(
                    episodes: _episodes,
                    currentId: _focusedEpisodeId ?? playTarget?.id,
                    revealToken: _episodeReveal,
                    loading: _episodesLoading,
                    error: _episodeError,
                    onRetry: _seasonId == null
                        ? null
                        : () => unawaited(_selectSeason(_seasonId!)),
                    hasMore: _episodeWindowEnd < _episodeTotal,
                    loadingMore: _loadingMore,
                    loadMoreError: _episodeLoadMoreError,
                    onRetryLoadMore: _retryEpisodeContinuation,
                    onLoadMore: () => unawaited(_loadMoreEpisodes()),
                    headerAction: _EpisodeShelfActions(
                      seasons: _seasons,
                      seasonId: _seasonId,
                      onSelectSeason: _selectSeason,
                      onLocate: _seasonId == null ? null : _openEpisodePicker,
                    ),
                    onTap: (episode) => _openEpisodeDetails(episode.id),
                    onPlay: (episode) => unawaited(_openPlayer(episode.id)),
                    onTogglePlayed: (episode) {
                      unawaited(
                        _setItemPlayed(episode, !episode.userData.played),
                      );
                    },
                    busyPlayedIds: _busyPlayedIds,
                    onMore: _seasonId == null
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
                if (showSimilar)
                  MediaShelf(
                    rowKey: CatalogKeys.similarRow,
                    shelfId: CatalogKeys.shelfSimilar,
                    title: l10n.similarRow,
                    items: _similar,
                    error: _similarError,
                    onRetry: _load,
                    onTap: (similar) =>
                        context.push(AppRoutes.item(similar.id)),
                    onMore: () => context.push(
                      AppRoutes.shelfSimilar(item.id, title: l10n.similarRow),
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
    final theme = Theme.of(context);
    final labelHeight = MediaShelf.lineHeightOf(
      context,
      theme.textTheme.labelLarge,
    );
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
            height:
                _ChapterTile.width * 9 / 16 + AppSpacing.xs + labelHeight + 2,
            child: Stack(
              children: [
                NotificationListener<ScrollMetricsNotification>(
                  onNotification: (_) {
                    _updateButtons();
                    return false;
                  },
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
                if (_canScrollLeft)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: ScrimIconButton(
                      key: CatalogKeys.shelfScrollLeft(
                        CatalogKeys.shelfChapters,
                      ),
                      tooltip: l10n.scrollLeft,
                      icon: const Icon(Icons.chevron_left),
                      onPressed: () => _page(-1),
                    ),
                  ),
                if (_canScrollRight)
                  Align(
                    alignment: Alignment.centerRight,
                    child: ScrimIconButton(
                      key: CatalogKeys.shelfScrollRight(
                        CatalogKeys.shelfChapters,
                      ),
                      tooltip: l10n.scrollRight,
                      icon: const Icon(Icons.chevron_right),
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
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final name = chapter.name.trim().isEmpty ? '${index + 1}' : chapter.name;
    final hasImage = chapter.imageTag != null && chapter.imageTag!.isNotEmpty;
    // 16:9 章节图卡:左下角时间码角标,图下一行章节名;无图以底色 + 图标兜底。
    return SizedBox(
      width: width,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(AppRadii.md),
        child: InkWell(
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
                        ColoredBox(
                          color: scheme.surfaceContainerHigh,
                          child: Icon(
                            Icons.play_arrow_rounded,
                            size: 28,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
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
    final fallback = ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(
        Icons.bookmark_outline_rounded,
        size: 18,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
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

class _EpisodeShelfActions extends StatelessWidget {
  const _EpisodeShelfActions({
    required this.seasons,
    required this.seasonId,
    required this.onSelectSeason,
    this.onLocate,
  });

  final List<EmbyItem> seasons;
  final String? seasonId;
  final ValueChanged<String> onSelectSeason;
  final VoidCallback? onLocate;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (seasons.length > 1)
          _SeasonJump(
            seasons: seasons,
            seasonId: seasonId,
            onSelected: onSelectSeason,
          ),
        if (onLocate != null)
          TextButton.icon(
            key: CatalogKeys.locateEpisode,
            onPressed: onLocate,
            icon: const Icon(Icons.apps_rounded, size: 18),
            label: Text(l10n.pickEpisode),
          ),
      ],
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
  final EmbyClient client;

  @override
  State<_EpisodeNumberPicker> createState() => _EpisodeNumberPickerState();
}

class _EpisodeNumberPickerState extends State<_EpisodeNumberPicker> {
  static const _pageSize = 30;
  late int _rangeStart;
  final _jump = TextEditingController();
  List<EmbyItem> _page = const [];
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
    } on EmbyException {
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
    final theme = Theme.of(context);
    final ranges = <(int, int)>[];
    for (var start = 1; start <= widget.total; start += _pageSize) {
      final end = math.min(start + _pageSize - 1, widget.total);
      ranges.add((start, end));
    }
    return AlertDialog(
      backgroundColor: theme.colorScheme.surface,
      surfaceTintColor: Colors.transparent,
      title: Text(l10n.pickEpisode),
      content: SizedBox(
        width: 420,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _jump,
              autofocus: true,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.go,
              onSubmitted: (_) => _submitJump(),
              decoration: InputDecoration(
                hintText: l10n.jumpToEpisodeHint,
                isDense: true,
                suffixIcon: IconButton(
                  tooltip: l10n.pickEpisode,
                  onPressed: _submitJump,
                  icon: const Icon(Icons.arrow_forward_rounded),
                ),
              ),
            ),
            if (ranges.length > 1) ...[
              const SizedBox(height: AppSpacing.sm),
              Align(
                alignment: Alignment.centerLeft,
                child: PopupMenuButton<int>(
                  key: CatalogKeys.episodeRange,
                  tooltip: l10n.pickEpisode,
                  initialValue: _rangeStart,
                  constraints: const BoxConstraints(
                    minWidth: 160,
                    maxHeight: 320,
                  ),
                  onSelected: _loadRange,
                  itemBuilder: (context) => [
                    for (final range in ranges)
                      CheckedPopupMenuItem(
                        value: range.$1,
                        checked: range.$1 == _rangeStart,
                        child: Text('${range.$1}-${range.$2}'),
                      ),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.xs,
                      vertical: AppSpacing.xs,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '$_rangeStart-${math.min(_rangeStart + _pageSize - 1, widget.total)}',
                          style: theme.textTheme.labelLarge,
                        ),
                        const Icon(Icons.arrow_drop_down, size: 20),
                      ],
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.sm),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : ListView.builder(
                      itemCount: _page.length,
                      itemBuilder: (context, index) {
                        final episode = _page[index];
                        final number =
                            episode.indexNumber ?? (index + _rangeStart);
                        final selected = number == widget.current;
                        return ListTile(
                          selected: selected,
                          dense: true,
                          leading: Text(
                            '$number',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          title: Text(
                            episode.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
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

class _SeasonJump extends StatelessWidget {
  const _SeasonJump({
    required this.seasons,
    required this.seasonId,
    required this.onSelected,
  });

  final List<EmbyItem> seasons;
  final String? seasonId;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    EmbyItem current = seasons.first;
    for (final season in seasons) {
      if (season.id == seasonId) {
        current = season;
        break;
      }
    }
    return PopupMenuButton<String>(
      key: CatalogKeys.seasonPicker,
      tooltip: AppLocalizations.of(context).seasons,
      initialValue: seasonId,
      onSelected: onSelected,
      itemBuilder: (context) => [
        for (final season in seasons)
          PopupMenuItem(value: season.id, child: Text(season.name)),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(current.name, style: Theme.of(context).textTheme.labelLarge),
            const Icon(Icons.arrow_drop_down, size: 20),
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
    final theme = Theme.of(context);
    final style = theme.textTheme.titleSmall?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.86),
      fontWeight: FontWeight.w600,
    );
    if (seriesId == null || seriesId!.isEmpty) {
      return Text(
        name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
      );
    }
    return Tooltip(
      message: AppLocalizations.of(context).viewSeries,
      child: TextButton.icon(
        key: CatalogKeys.seriesLink,
        onPressed: () =>
            context.push(AppRoutes.item(seriesId!, seasonId: seasonId)),
        style: TextButton.styleFrom(
          foregroundColor: theme.colorScheme.onSurface.withValues(alpha: 0.9),
          padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 2),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.compact,
        ),
        icon: const Icon(Icons.chevron_right_rounded, size: 18),
        iconAlignment: IconAlignment.end,
        label: Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: style,
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

  final List<EmbyItem> items;

  /// 季内分集总数(服务端 TotalRecordCount)。
  final int total;

  /// 窗口末条之后的季内偏移;等于 [total] 时已无后续分集。
  final int end;
}

const _episodePageSize = 80;

/// 集详情页整季拉取上限;超过该集数的季退回当前集窗口。
const _episodeDetailSeasonLimit = 300;

List<EmbyItem> _dedupeById(Iterable<EmbyItem> items) {
  final seen = <String>{};
  return [
    for (final item in items)
      if (seen.add(item.id)) item,
  ];
}

List<EmbyItem> _mergeCurrentEpisode(
  Iterable<EmbyItem> entries,
  EmbyItem current,
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
List<EmbyItem> _sortedByIndex(List<EmbyItem> items) {
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
    required this.runtime,
    required this.busyPlayed,
    required this.onPlay,
    required this.onPlayedChanged,
    this.onPlayFromStart,
    this.topOverlap = 0,
    this.seasonCount = 0,
    this.seriesId,
    this.previousEpisode,
    this.nextEpisode,
    this.onOpenPreviousEpisode,
    this.onOpenNextEpisode,
    this.onViewSeries,
    this.mediaSourceId,
    this.audioStreamIndex,
    this.subtitleStreamIndex,
    this.onMediaSource,
    this.onAudio,
    this.onSubtitle,
    this.onLocateEpisode,
    this.overview,
    this.overviewWidget,
  });

  final EmbyItem item;
  final String? runtime;
  final bool busyPlayed;
  final VoidCallback? onPlay;
  final ValueChanged<bool> onPlayedChanged;
  final VoidCallback? onPlayFromStart;
  final double topOverlap;
  final int seasonCount;
  final String? seriesId;
  final EmbyItem? previousEpisode;
  final EmbyItem? nextEpisode;
  final VoidCallback? onOpenPreviousEpisode;
  final VoidCallback? onOpenNextEpisode;
  final VoidCallback? onViewSeries;
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

  /// 头部最小高度:电影约半屏画幅,夹在 360–640 之间;单集为 0.42 视高
  /// (340–520),容纳左侧 16:9 剧照与右侧标题/简介/操作栏;
  /// 剧集 [billboard] 为 false,不定死半屏,避免无 backdrop 时大块空白。
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
      return (viewportHeight * 0.42).clamp(340.0, 520.0);
    }
    return (viewportHeight * 0.52).clamp(360.0, 640.0);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final viewportHeight = MediaQuery.sizeOf(context).height;
        final billboard = !item.isSeries;
        final minHeight =
            heightFor(
              width,
              viewportHeight,
              billboard: billboard,
              episode: item.isEpisode,
            ) +
            topOverlap;
        return SizedBox(
          width: double.infinity,
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: minHeight),
            child: Stack(
              alignment: AlignmentDirectional.bottomStart,
              children: [
                Positioned.fill(
                  child: BackdropScrim(
                    topBandHeight: math.max(
                      AppScrim.topBandHeight,
                      topOverlap + _topBandFade,
                    ),
                    backdrop: MediaImage(
                      key: ValueKey('detail-hero-${item.id}'),
                      item: item,
                      preferBackdrop: !item.isEpisode,
                      preferParentBackdrop: item.isEpisode,
                      maxWidth: mediaBackdropRequestWidth(
                        layoutWidth: width,
                        devicePixelRatio: MediaQuery.devicePixelRatioOf(
                          context,
                        ),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    AppSpacing.page,
                    topOverlap + AppSpacing.xl,
                    AppSpacing.page,
                    AppSpacing.xl,
                  ),
                  // At narrow desktop widths the poster and action stack must
                  // remain readable; keeping them in a row squeezes the
                  // primary play button behind long Chinese titles.
                  child: Flex(
                    direction: width < AppBreakpoints.compact
                        ? Axis.vertical
                        : Axis.horizontal,
                    crossAxisAlignment: width < AppBreakpoints.compact
                        ? CrossAxisAlignment.start
                        : CrossAxisAlignment.end,
                    mainAxisSize: width < AppBreakpoints.compact
                        ? MainAxisSize.min
                        : MainAxisSize.max,
                    children: [
                      _DetailPoster(item: item, layoutWidth: width),
                      const SizedBox(width: AppSpacing.xl),
                      Flexible(
                        fit: width < AppBreakpoints.compact
                            ? FlexFit.loose
                            : FlexFit.tight,
                        child: _DetailInfo(
                          item: item,
                          runtime: runtime,
                          compact: width < AppBreakpoints.compact,
                          seasonCount: seasonCount,
                          seriesId: seriesId,
                          overview: overview,
                          overviewWidget: overviewWidget,
                          playEpisode: item.isSeries ? nextEpisode : null,
                          onLocateEpisode: onLocateEpisode,
                          actions: _DetailActions(
                            item: item,
                            busyPlayed: busyPlayed,
                            onPlay: onPlay,
                            onPlayFromStart: onPlayFromStart,
                            onOpenPreviousEpisode: onOpenPreviousEpisode,
                            onOpenNextEpisode: onOpenNextEpisode,
                            onViewSeries: onViewSeries,
                            onPlayedChanged: onPlayedChanged,
                            playEpisode: item.isSeries ? nextEpisode : null,
                            mediaSourceId: mediaSourceId,
                            audioStreamIndex: audioStreamIndex,
                            subtitleStreamIndex: subtitleStreamIndex,
                            onMediaSource: onMediaSource,
                            onAudio: onAudio,
                            onSubtitle: onSubtitle,
                          ),
                        ),
                      ),
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
}

/// 头部左栏:电影/剧集为干净 2:3 海报,单集为 16:9 剧照;简介一律在信息栏。
class _DetailPoster extends StatelessWidget {
  const _DetailPoster({required this.item, required this.layoutWidth});

  final EmbyItem item;
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

  /// 单集剧照宽:与海报同档位放大,让 16:9 剧照在 hero 里有主体感。
  static double thumbWidthFor(double width) {
    if (width < AppBreakpoints.compact) {
      return 320;
    }
    if (width < AppBreakpoints.large) {
      return 384;
    }
    return 448;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final episode = item.isEpisode;
    final width = episode
        ? thumbWidthFor(layoutWidth)
        : posterWidthFor(layoutWidth);
    final height = episode ? width * 9 / 16 : width * 3 / 2;
    return DecoratedBox(
      key: ItemDetailPage.posterKey,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadii.lg),
        border: Border.all(color: scheme.onSurface.withValues(alpha: 0.12)),
        boxShadow: [
          BoxShadow(
            color: scheme.shadow.withValues(alpha: 0.45),
            blurRadius: 28,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadii.lg),
        child: SizedBox(
          width: width,
          height: height,
          child: MediaImage(
            key: ValueKey('detail-poster-${item.id}'),
            item: item,
            width: width,
            height: height,
            preferThumb: episode,
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
  });

  final EmbyItem item;
  final String? runtime;
  final bool compact;
  final int seasonCount;
  final String? seriesId;
  final VoidCallback? onLocateEpisode;
  final Widget actions;
  final String? overview;
  final Widget? overviewWidget;
  final EmbyItem? playEpisode;

  /// 简介行宽上限:约 70–90 个汉字/行,超过后行长过长可读性下降。
  static const double overviewMaxWidth = 720;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
        SelectableText(
          itemTitle(item),
          maxLines: 2,
          style:
              (compact
                      ? theme.textTheme.headlineLarge
                      : theme.textTheme.displaySmall)
                  ?.copyWith(
                    color: theme.colorScheme.onSurface,
                    fontWeight: FontWeight.w800,
                  ),
        ),
        const SizedBox(height: AppSpacing.xs),
        _MetaRow(
          item: item,
          runtime: runtime,
          seasonCount: seasonCount,
          playEpisode: playEpisode,
          onLocateEpisode: onLocateEpisode,
        ),
        if (overviewWidget != null) ...[
          const SizedBox(height: AppSpacing.md),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: overviewMaxWidth),
            child: overviewWidget,
          ),
        ] else if (overview != null && overview!.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.md),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: overviewMaxWidth),
            child: Text(
              overview!,
              key: CatalogKeys.overview,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.88),
                height: 1.5,
              ),
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.lg),
        actions,
      ],
    );
  }
}

/// 头部元信息行:集标、时长、季集数与观看进度。
class _MetaRow extends StatelessWidget {
  const _MetaRow({
    required this.item,
    required this.runtime,
    required this.seasonCount,
    this.playEpisode,
    this.onLocateEpisode,
  });

  final EmbyItem item;
  final String? runtime;
  final int seasonCount;
  final EmbyItem? playEpisode;
  final VoidCallback? onLocateEpisode;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.labelMedium?.copyWith(
      color: scheme.onSurface,
      letterSpacing: 0.2,
    );
    Widget chip(String text, {Key? key}) {
      return Container(
        key: key,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(text, style: style),
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
      return Tooltip(
        message: tooltip ?? l10n.pickEpisode,
        child: InkWell(
          key: key ?? CatalogKeys.locateEpisode,
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          child: body,
        ),
      );
    }

    final listed = playEpisode;
    final playCode = listed != null && listed.isEpisode
        ? seasonEpisodeCode(listed) ?? episodeLabel(listed)
        : null;

    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.xs,
      children: [
        if (item.isEpisode)
          locateChip(
            seasonEpisodeCode(item) ?? episodeLabel(item),
            onTap: onLocateEpisode,
          ),
        if (item.isSeries && playCode != null)
          locateChip(
            playCode,
            onTap: onLocateEpisode,
            tooltip: l10n.locateEpisode,
            key: CatalogKeys.playTarget,
          ),
        if (runtime != null) chip(runtime!),
        if (item.isEpisode && item.premiereDate != null)
          chip(l10n.premiereDate(formatDateYmd(item.premiereDate!))),
        if (item.isEpisode && item.dateCreated != null)
          chip(l10n.dateAddedOn(formatDateYmd(item.dateCreated!))),
        if (item.isSeries && seasonCount > 0)
          chip(l10n.seasonCount(seasonCount)),
        if (item.childCount != null && item.isSeries)
          chip(l10n.episodeCount(item.childCount!)),
        if (item.canResume)
          chip(
            l10n.playbackProgress((item.playbackProgress * 100).round()),
            key: CatalogKeys.resumeProgress,
          ),
      ],
    );
  }
}

/// PopupMenuButton 把 null 当成取消,字幕关闭用哨兵值再映回 null。
const _subtitleOffToken = -1;

ButtonStyle _detailGhostButtonStyle(ColorScheme scheme) {
  return OutlinedButton.styleFrom(
    foregroundColor: scheme.onSurface,
    side: BorderSide(color: scheme.onSurface.withValues(alpha: 0.42)),
    minimumSize: const Size(0, 48),
    padding: const EdgeInsets.symmetric(
      horizontal: AppSpacing.lg,
      vertical: AppSpacing.sm,
    ),
  );
}

/// 操作区:播放/从头播放/下一集一组,已看与片源/音轨/字幕
/// 圆钮一组,两组之间以 [AppSpacing.md] 分隔。
class _DetailActions extends StatelessWidget {
  const _DetailActions({
    required this.item,
    required this.busyPlayed,
    required this.onPlayedChanged,
    this.onPlay,
    this.onPlayFromStart,
    this.onOpenPreviousEpisode,
    this.onOpenNextEpisode,
    this.onViewSeries,
    this.playEpisode,
    this.mediaSourceId,
    this.audioStreamIndex,
    this.subtitleStreamIndex,
    this.onMediaSource,
    this.onAudio,
    this.onSubtitle,
  });

  final EmbyItem item;
  final bool busyPlayed;
  final ValueChanged<bool> onPlayedChanged;
  final VoidCallback? onPlay;
  final VoidCallback? onPlayFromStart;
  final VoidCallback? onOpenPreviousEpisode;
  final VoidCallback? onOpenNextEpisode;
  final VoidCallback? onViewSeries;
  final EmbyItem? playEpisode;
  final String? mediaSourceId;
  final int? audioStreamIndex;
  final int? subtitleStreamIndex;
  final ValueChanged<String>? onMediaSource;
  final ValueChanged<int>? onAudio;
  final ValueChanged<int?>? onSubtitle;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final audios = _audioChoices(item, mediaSourceId);
    final subtitles = _subtitleChoices(item, mediaSourceId);
    final sourceId =
        mediaSourceId ??
        (item.mediaSources.isEmpty ? null : item.mediaSources.first.id);
    String sourceLabel = '';
    for (final source in item.mediaSources) {
      if (source.id == sourceId) {
        sourceLabel = source.presentation.compact;
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
    final ghost = _detailGhostButtonStyle(scheme);
    final played = item.userData.played;
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
    final primary = <Widget>[
      if (onPlay != null)
        FilledButton.icon(
          key: PlayerKeys.open,
          onPressed: onPlay,
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, 48),
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.xxl,
              vertical: AppSpacing.sm,
            ),
          ),
          icon: const Icon(Icons.play_arrow_rounded, size: 26),
          label: Text(playLabel),
        ),
      if (onPlayFromStart != null)
        OutlinedButton(
          key: PlayerKeys.resumeFromStart,
          onPressed: onPlayFromStart,
          style: ghost,
          child: Text(l10n.playFromStart),
        ),
      if (onOpenPreviousEpisode != null)
        OutlinedButton.icon(
          key: CatalogKeys.previousEpisode,
          onPressed: onOpenPreviousEpisode,
          style: ghost,
          icon: const Icon(Icons.skip_previous_rounded),
          label: Text(l10n.previousEpisode),
        ),
      if (onOpenNextEpisode != null)
        OutlinedButton.icon(
          key: CatalogKeys.nextEpisode,
          onPressed: onOpenNextEpisode,
          style: ghost,
          icon: const Icon(Icons.skip_next_rounded),
          label: Text(l10n.nextEpisode),
        ),
      if (onViewSeries != null)
        OutlinedButton.icon(
          key: CatalogKeys.viewSeries,
          onPressed: onViewSeries,
          style: ghost,
          icon: const Icon(Icons.video_library_outlined),
          label: Text(l10n.viewSeries),
        ),
    ];
    final tools = <Widget>[
      ScrimIconButton(
        key: CatalogKeys.playedToggle,
        size: ScrimIconButtonSize.large,
        tooltip: played ? l10n.markUnplayed : l10n.markPlayed,
        icon: Icon(
          played
              ? Icons.check_circle_rounded
              : Icons.check_circle_outline_rounded,
          color: played ? scheme.primary : null,
        ),
        onPressed: busyPlayed ? null : () => onPlayedChanged(!played),
      ),
      if (item.mediaSources.length > 1)
        _DetailMenuButton<String>(
          menuKey: CatalogKeys.mediaSource,
          tooltip: '${l10n.mediaSource} · $sourceLabel',
          icon: Icons.movie_filter_outlined,
          constraints: const BoxConstraints(minWidth: 280, maxWidth: 420),
          items: [
            for (final source in item.mediaSources)
              CheckedPopupMenuItem(
                value: source.id,
                checked: source.id == sourceId,
                child: MediaSourceMenuTile(view: source.presentation),
              ),
          ],
          onSelected: (value) => onMediaSource?.call(value),
        ),
      if (audios.length > 1)
        _DetailMenuButton<int>(
          menuKey: CatalogKeys.detailAudio,
          tooltip: '${l10n.audioTrack} · $audioLabel',
          icon: Icons.graphic_eq_rounded,
          items: [
            for (final stream in audios)
              CheckedPopupMenuItem(
                value: stream.index,
                checked: stream.index == audioStreamIndex,
                child: Text(stream.label ?? '#${stream.index}'),
              ),
          ],
          onSelected: (value) => onAudio?.call(value),
        ),
      if (subtitles.isNotEmpty)
        _DetailMenuButton<int>(
          menuKey: CatalogKeys.detailSubtitle,
          tooltip: '${l10n.subtitleTrack} · $subtitleLabel',
          icon: Icons.subtitles_outlined,
          items: [
            CheckedPopupMenuItem<int>(
              value: _subtitleOffToken,
              checked: subtitleStreamIndex == null,
              child: Text(l10n.subtitleOff),
            ),
            for (final stream in subtitles)
              CheckedPopupMenuItem<int>(
                value: stream.index,
                checked: stream.index == subtitleStreamIndex,
                child: Text(stream.label ?? '#${stream.index}'),
              ),
          ],
          onSelected: (value) =>
              onSubtitle?.call(value == _subtitleOffToken ? null : value),
        ),
    ];
    return Wrap(
      spacing: AppSpacing.md,
      runSpacing: AppSpacing.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (primary.isNotEmpty)
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: primary,
          ),
        Wrap(
          spacing: AppSpacing.xs,
          runSpacing: AppSpacing.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: tools,
        ),
      ],
    );
  }
}

/// 海报上的圆形菜单钮:[ScrimIconButton] 外观,点击在按钮下方弹出选项。
class _DetailMenuButton<T> extends StatelessWidget {
  const _DetailMenuButton({
    required this.tooltip,
    required this.icon,
    required this.items,
    required this.onSelected,
    this.menuKey,
    this.constraints,
  });

  final Key? menuKey;
  final String tooltip;
  final IconData icon;
  final List<PopupMenuEntry<T>> items;
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
    final value = await showMenu<T>(
      context: context,
      position: position,
      constraints: constraints,
      items: items,
    );
    if (value != null) {
      onSelected(value);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ScrimIconButton(
      key: menuKey,
      size: ScrimIconButtonSize.large,
      tooltip: tooltip,
      icon: Icon(icon),
      onPressed: () => unawaited(_open(context)),
    );
  }
}

/// 详情路径字段:在 [EmbyClient.itemFields] 之上加 People,单条目详情
/// 开销可忽略(ADR-2);季列表等 /Items 高频路径不带 People。
const _detailFields = '${EmbyClient.itemFields},People';

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

List<ItemMediaStream> _audioChoices(EmbyItem item, String? sourceId) {
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

List<ItemMediaStream> _subtitleChoices(EmbyItem item, String? sourceId) {
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
