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
import 'package:rillight/app/widgets/liquid_glass.dart';
import 'package:rillight/app/widgets/skeleton.dart';
import 'package:rillight/app/window_chrome.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_failure.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/home/media_shelf.dart';
import 'package:rillight/library/item_format.dart';
import 'package:rillight/library/poster_card.dart';
import 'package:rillight/media_image/media_image.dart';
import 'package:rillight/player/player_keys.dart';
import 'package:rillight/player/player_window_host.dart';

class ItemDetailPage extends StatefulWidget {
  const ItemDetailPage({super.key, required this.itemId});

  final String itemId;

  /// 与 [AppShell] 顶栏同高;外壳仍是 Column 时只加到 hero 高度,不能真正叠到窗口上缘.
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
  EmbyItem? _nextEpisode;
  bool _loading = true;
  bool _busyPlayed = false;
  EmbyException? _error;
  EmbyException? _similarError;
  String? _mediaSourceId;
  int? _audioStreamIndex;
  int? _subtitleStreamIndex;
  int _loadGen = 0;
  int _episodeFocusNonce = 0;
  int _episodeTotal = 0;

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
    }
  }

  void _showItem(String itemId) {
    if (itemId.isEmpty || itemId == _itemId) {
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
        _nextEpisode = _siblingAfter(shown, _episodes);
        _mediaSourceId = shown.mediaSources.isEmpty
            ? null
            : shown.mediaSources.first.id;
        _audioStreamIndex = _defaultAudio(shown, _mediaSourceId);
        _subtitleStreamIndex = _defaultSubtitle(shown, _mediaSourceId);
      });
    }
    _episodeFocusNonce++;
    unawaited(_load(keepChrome: true));
  }

  Future<void> _load({bool keepChrome = false}) async {
    final gen = ++_loadGen;
    final keep = keepChrome && _item != null && _error == null;
    if (!keep) {
      setState(() {
        _loading = true;
        _error = null;
        _similarError = null;
        _seasons = const [];
        _episodes = const [];
        _similar = const [];
        _seasonId = null;
        _seriesId = null;
        _seriesOverview = null;
        _nextEpisode = null;
        _mediaSourceId = null;
        _audioStreamIndex = null;
        _subtitleStreamIndex = null;
      });
    }
    final requestedId = _itemId;
    final client = AuthScope.of(context).client;
    try {
      final item = await client.getItem(requestedId);
      if (!mounted || gen != _loadGen) {
        return;
      }
      var seasons = const <EmbyItem>[];
      var episodes = const <EmbyItem>[];
      String? seasonId;
      String? seriesId;
      EmbyItem? nextEpisode;
      final reuseCatalog =
          keep &&
          _seriesId != null &&
          ((item.isEpisode && item.seriesId == _seriesId) ||
              (item.isSeries && item.id == _seriesId));
      if (item.isSeries || item.isEpisode) {
        seriesId = reuseCatalog
            ? _seriesId
            : await _resolveSeriesId(client, item);
        if (!mounted || gen != _loadGen) {
          return;
        }
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
          seasonId = item.seasonId ?? item.parentId;
          if (seasonId == null ||
              (seasons.isNotEmpty &&
                  !seasons.any((season) => season.id == seasonId))) {
            for (final season in seasons) {
              if (season.indexNumber == item.parentIndexNumber) {
                seasonId = season.id;
                break;
              }
            }
            seasonId ??= seasons.isEmpty ? item.parentId : seasons.first.id;
          }
        } else if (seasons.isNotEmpty) {
          seasonId = seasons.first.id;
        }
        if (reuseCatalog &&
            seasonId == _seasonId &&
            _episodes.any((episode) => episode.id == item.id)) {
          episodes = _episodes;
        } else if (seasonId != null && seasonId.isNotEmpty) {
          final window = await _loadEpisodeWindow(
            client,
            seasonId: seasonId,
            current: item.isEpisode ? item : null,
          );
          if (!mounted || gen != _loadGen) {
            return;
          }
          episodes = window.items;
          _episodeTotal = window.total;
        }
        if (item.isEpisode) {
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
      var seriesOverview = _seriesOverview;
      if (item.isSeries) {
        seriesOverview = item.overview;
      } else if (item.isEpisode &&
          seriesOverview == null &&
          seriesId != null &&
          seriesId.isNotEmpty) {
        try {
          final series = await client.getItem(seriesId);
          seriesOverview = series.overview ?? '';
        } on EmbyException {
          seriesOverview = '';
        }
        if (!mounted || gen != _loadGen) {
          return;
        }
      }
      if (!mounted || gen != _loadGen) {
        return;
      }
      setState(() {
        _item = item;
        _seasons = seasons;
        _episodes = episodes;
        _seasonId = seasonId;
        _seriesId = seriesId;
        _seriesOverview = seriesOverview;
        _nextEpisode = nextEpisode;
        _similar = similar;
        _similarError = similarError;
        _loading = false;
        _mediaSourceId = item.mediaSources.isEmpty
            ? null
            : item.mediaSources.first.id;
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

  Future<({List<EmbyItem> items, int total})> _loadEpisodeWindow(
    EmbyClient client, {
    required String seasonId,
    EmbyItem? current,
    int? aroundNumber,
  }) async {
    final index = aroundNumber ?? current?.indexNumber;
    final startIndex = index == null || index <= 1
        ? 0
        : math.max(0, index - 1 - 4);
    var page = await client.queryItems(
      parentId: seasonId,
      includeItemTypes: 'Episode',
      sortBy: 'IndexNumber',
      sortOrder: 'Ascending',
      startIndex: startIndex,
      limit: 80,
      fields: EmbyClient.itemFields,
    );
    var episodes = page.items;
    var total = page.totalRecordCount ?? episodes.length;
    if (current != null &&
        current.isEpisode &&
        episodes.every((episode) => episode.id != current.id)) {
      page = await client.queryItems(
        parentId: seasonId,
        includeItemTypes: 'Episode',
        sortBy: 'IndexNumber',
        sortOrder: 'Ascending',
        startIndex: math.max(0, (current.indexNumber ?? 1) - 1),
        limit: 80,
        fields: EmbyClient.itemFields,
      );
      episodes = page.items;
      total = page.totalRecordCount ?? total;
    }
    if (current != null &&
        current.isEpisode &&
        episodes.every((episode) => episode.id != current.id)) {
      episodes = [...episodes, current]
        ..sort((a, b) {
          final left = a.indexNumber ?? 1 << 30;
          final right = b.indexNumber ?? 1 << 30;
          return left.compareTo(right);
        });
    }
    return (items: episodes, total: total);
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
    for (final episode in _episodes) {
      if (episode.indexNumber == number) {
        _showItem(episode.id);
        return;
      }
    }
    try {
      final window = await _loadEpisodeWindow(
        AuthScope.of(context).client,
        seasonId: seasonId,
        aroundNumber: number,
      );
      if (!mounted) {
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
        _episodes = window.items;
        _episodeTotal = window.total;
      });
      _showItem(target.id);
    } on EmbyException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = error);
    }
  }

  Future<void> _selectSeason(String seasonId) async {
    setState(() {
      _seasonId = seasonId;
      _episodes = const [];
    });
    try {
      final window = await _loadEpisodeWindow(
        AuthScope.of(context).client,
        seasonId: seasonId,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _episodes = window.items;
        _episodeTotal = window.total;
      });
    } on EmbyException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = error);
    }
  }

  void _openSeason(EmbyItem season) {
    unawaited(_selectSeason(season.id));
    context.push(
      AppRoutes.shelfItems(
        parentId: season.id,
        includeItemTypes: 'Episode',
        title: season.name,
      ),
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
          mediaSourceId: _mediaSourceId,
          audioStreamIndex: _audioStreamIndex,
          subtitleStreamIndex: _subtitleStreamIndex,
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
    if (item == null || _busyPlayed) {
      return;
    }
    setState(() => _busyPlayed = true);
    final client = AuthScope.of(context).client;
    try {
      if (played) {
        await client.markPlayed(item.id);
      } else {
        await client.markUnplayed(item.id);
      }
      final updated = await client.getItem(item.id);
      if (!mounted) {
        return;
      }
      setState(() {
        _item = updated;
        _busyPlayed = false;
      });
      await CatalogScope.maybeOf(context)?.reloadHomeRows();
    } on EmbyException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error;
        _busyPlayed = false;
      });
    }
  }

  String? _displayOverview(EmbyItem item) {
    final own = item.overview?.trim();
    if (own != null && own.isNotEmpty) {
      return own;
    }
    if (!item.isEpisode) {
      return null;
    }
    final fallback = _seriesOverview?.trim();
    if (fallback != null && fallback.isNotEmpty) {
      return fallback;
    }
    return null;
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
    final item = _item;
    if (item == null) {
      return AppErrorView(message: l10n.itemUnavailable, onRetry: _load);
    }

    final runtime = runtimeLabel(l10n, item);
    final showSimilar = _similar.isNotEmpty || _similarError != null;
    final playTarget = _playTarget(item);
    final continueWatching = [
      for (final episode in _episodes)
        if (episode.canResume) episode,
    ];
    final screenWidth = MediaQuery.sizeOf(context).width;
    final wideCardWidth = MediaShelf.wideCardWidthFor(screenWidth);
    final posterWidth = MediaShelf.posterWidthFor(screenWidth);
    return Stack(
      fit: StackFit.expand,
      children: [
        SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: AppSpacing.xxl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _DetailHero(
                item: item,
                runtime: runtime,
                topOverlap: topOverlap,
                seasonCount: _seasons.length,
                seriesId: _seriesId,
                nextEpisode: item.isSeries
                    ? playTarget
                    : _nextEpisodeAfter(item),
                onOpenNextEpisode:
                    !item.isEpisode || _nextEpisodeAfter(item) == null
                    ? null
                    : () {
                        final next = _nextEpisodeAfter(item);
                        if (next == null) {
                          return;
                        }
                        _showItem(next.id);
                      },
                onViewEpisode:
                    item.isSeries &&
                        playTarget != null &&
                        playTarget.id != item.id
                    ? () => _showItem(playTarget.id)
                    : null,
                busyPlayed: _busyPlayed,
                mediaSourceId: _mediaSourceId,
                audioStreamIndex: _audioStreamIndex,
                subtitleStreamIndex: _subtitleStreamIndex,
                onMediaSource: (id) {
                  setState(() {
                    _mediaSourceId = id;
                    _audioStreamIndex = _defaultAudio(item, id);
                    _subtitleStreamIndex = _defaultSubtitle(item, id);
                  });
                },
                onAudio: (index) => setState(() => _audioStreamIndex = index),
                onSubtitle: (index) =>
                    setState(() => _subtitleStreamIndex = index),
                onLocateEpisode: item.isEpisode ? _locateCurrentEpisode : null,
                onPlay: playTarget == null
                    ? null
                    : () => _openPlayer(playTarget.id),
                onPlayFromStart: playTarget == null || !playTarget.canResume
                    ? null
                    : () => _openPlayer(playTarget.id, fromBeginning: true),
                onPlayedChanged: (value) {
                  _setPlayed(value);
                },
                showOverviewInHero: !item.isEpisode,
              ),
              if (item.isEpisode)
                _OverviewSection(text: _displayOverview(item)),
              if (item.chapters.isNotEmpty)
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
              if (item.isSeries || item.isEpisode) ...[
                if (item.isSeries && continueWatching.isNotEmpty)
                  MediaShelf(
                    rowKey: CatalogKeys.resumeRow,
                    shelfId: '${CatalogKeys.shelfEpisodes}-resume',
                    title: l10n.resumeRow,
                    items: continueWatching,
                    wide: true,
                    onTap: (episode) => _showItem(episode.id),
                    itemBuilder: (context, episode) {
                      return EpisodeThumbCard(
                        item: episode,
                        width: wideCardWidth,
                        selected: episode.id == item.id,
                        onTap: () => _showItem(episode.id),
                      );
                    },
                  ),
                if (item.isSeries && _seasons.length > 1)
                  MediaShelf(
                    shelfId: 'seasons',
                    title: l10n.seasons,
                    items: _seasons,
                    onTap: (season) => _openSeason(season),
                    itemBuilder: (context, season) {
                      return SeasonPosterCard(
                        item: season,
                        width: posterWidth,
                        selected: season.id == _seasonId,
                        onTap: () => _openSeason(season),
                      );
                    },
                  ),
                if (_episodes.isNotEmpty)
                  MediaShelf(
                    rowKey: CatalogKeys.episodesRow,
                    shelfId: CatalogKeys.shelfEpisodes,
                    title: l10n.episodesRow,
                    items: _episodes,
                    wide: true,
                    focusedId: item.isEpisode ? item.id : null,
                    focusNonce: _episodeFocusNonce,
                    headerAction: _EpisodeShelfActions(
                      seasons: _seasons,
                      seasonId: _seasonId,
                      onSelectSeason: _selectSeason,
                      onLocate: _seasonId == null ? null : _openEpisodePicker,
                    ),
                    onTap: (episode) => _showItem(episode.id),
                    onMore: _seasonId == null
                        ? null
                        : () => context.push(
                            AppRoutes.shelfItems(
                              parentId: _seasonId,
                              includeItemTypes: 'Episode',
                              title: l10n.episodesRow,
                            ),
                          ),
                    itemBuilder: (context, episode) {
                      return EpisodeThumbCard(
                        item: episode,
                        width: wideCardWidth,
                        selected: episode.id == item.id,
                        onTap: () => _showItem(episode.id),
                      );
                    },
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
                  onTap: (similar) => context.push(AppRoutes.item(similar.id)),
                  onMore: () => context.push(
                    AppRoutes.shelfSimilar(item.id, title: l10n.similarRow),
                  ),
                ),
            ],
          ),
        ),
      ],
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
    _controller.animateTo(
      (position.pixels + position.viewportDimension * 0.9 * direction).clamp(
        0.0,
        position.maxScrollExtent,
      ),
      duration: AppMotion.normal,
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
            height: 72,
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
                    child: _ChapterScrollButton(
                      buttonKey: CatalogKeys.shelfScrollLeft(
                        CatalogKeys.shelfChapters,
                      ),
                      tooltip: l10n.scrollLeft,
                      icon: Icons.chevron_left,
                      onPressed: () => _page(-1),
                    ),
                  ),
                if (_canScrollRight)
                  Align(
                    alignment: Alignment.centerRight,
                    child: _ChapterScrollButton(
                      buttonKey: CatalogKeys.shelfScrollRight(
                        CatalogKeys.shelfChapters,
                      ),
                      tooltip: l10n.scrollRight,
                      icon: Icons.chevron_right,
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

class _ChapterScrollButton extends StatelessWidget {
  const _ChapterScrollButton({
    required this.buttonKey,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final Key buttonKey;
  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return LiquidGlass(
      kind: LiquidGlassKind.pill,
      child: Material(
        type: MaterialType.transparency,
        shape: const CircleBorder(),
        child: IconButton(
          key: buttonKey,
          tooltip: tooltip,
          onPressed: onPressed,
          icon: Icon(icon),
        ),
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = chapter.name.trim().isEmpty ? '${index + 1}' : chapter.name;
    return SizedBox(
      width: 220,
      child: Material(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(AppRadii.md),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadii.md),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.sm),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadii.sm),
                  child: SizedBox(
                    width: 72,
                    height: 40,
                    child: _ChapterThumb(
                      itemId: itemId,
                      index: chapter.imageIndex ?? index,
                      tag: chapter.imageTag,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall,
                      ),
                      Text(
                        chapterClock(chapter.startPositionTicks),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
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
  const _SeriesLink({required this.name, this.seriesId});

  final String name;
  final String? seriesId;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.titleSmall?.copyWith(
      color: Colors.white.withValues(alpha: 0.86),
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
        onPressed: () => context.push(AppRoutes.item(seriesId!)),
        style: TextButton.styleFrom(
          foregroundColor: Colors.white.withValues(alpha: 0.9),
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

class _OverviewSection extends StatelessWidget {
  const _OverviewSection({required this.text});

  final String? text;

  @override
  Widget build(BuildContext context) {
    final body = text?.trim();
    if (body == null || body.isEmpty) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return Padding(
      key: CatalogKeys.overview,
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.page,
        AppSpacing.md,
        AppSpacing.page,
        AppSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.overview, style: theme.textTheme.titleMedium),
          const SizedBox(height: AppSpacing.sm),
          SelectableText(
            body,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.82),
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }
}

/// 详情页全宽沉浸式 hero:backdrop 顶到内容区边缘,左右/底部 scrim 上叠
/// 大标题、元信息行与主操作;无 backdrop 时走 [MediaImage] contain/左侧竖图。
/// 高度随内容区宽度比例伸缩并按断点封顶。
/// 高度不足时简介下沉到 hero 下方正文区,避免挤压主操作。
class _DetailHero extends StatelessWidget {
  const _DetailHero({
    required this.item,
    required this.runtime,
    required this.busyPlayed,
    required this.onPlay,
    required this.onPlayedChanged,
    this.onPlayFromStart,
    this.topOverlap = 0,
    this.seasonCount = 0,
    this.seriesId,
    this.nextEpisode,
    this.onViewEpisode,
    this.onOpenNextEpisode,
    this.mediaSourceId,
    this.audioStreamIndex,
    this.subtitleStreamIndex,
    this.onMediaSource,
    this.onAudio,
    this.onSubtitle,
    this.onLocateEpisode,
    this.showOverviewInHero = true,
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
  final EmbyItem? nextEpisode;
  final VoidCallback? onViewEpisode;
  final VoidCallback? onOpenNextEpisode;
  final String? mediaSourceId;
  final int? audioStreamIndex;
  final int? subtitleStreamIndex;
  final ValueChanged<String>? onMediaSource;
  final ValueChanged<int>? onAudio;
  final ValueChanged<int?>? onSubtitle;
  final VoidCallback? onLocateEpisode;
  final bool showOverviewInHero;

  /// hero 高度:约半屏画幅,给标题、简介与操作条留位,下方仍能露出季集行。
  static double heightFor(double width, {double? viewportHeight}) {
    final fromWidth = width * 0.46;
    final fromViewport = viewportHeight == null
        ? fromWidth
        : viewportHeight * 0.56;
    final base = math.min(fromWidth, fromViewport);
    if (width < AppBreakpoints.compact) {
      return base.clamp(360.0, 500.0);
    }
    if (width < AppBreakpoints.large) {
      return base.clamp(420.0, 580.0);
    }
    return base.clamp(460.0, 640.0);
  }

  /// 高度足够时才把简介放进 hero。
  static bool showsOverview(double width, {double? viewportHeight}) =>
      heightFor(width, viewportHeight: viewportHeight) >= 400;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scrim = theme.colorScheme.scrim;
    final pageBg = theme.scaffoldBackgroundColor;
    final hasOverview =
        showOverviewInHero &&
        item.overview != null &&
        item.overview!.trim().isNotEmpty;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final viewportHeight = MediaQuery.sizeOf(context).height;
        final height =
            heightFor(width, viewportHeight: viewportHeight) + topOverlap;
        final compact = width < AppBreakpoints.compact;
        final overviewInHero =
            hasOverview && showsOverview(width, viewportHeight: viewportHeight);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: height,
              width: double.infinity,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  MediaImage(
                    key: ValueKey('detail-hero-${item.id}'),
                    item: item,
                    height: height,
                    preferBackdrop: true,
                    maxWidth: 1920,
                  ),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.centerLeft,
                        end: Alignment.centerRight,
                        stops: const [0, 0.34, 0.62, 1],
                        colors: [
                          scrim.withValues(alpha: 0.62),
                          scrim.withValues(alpha: 0.18),
                          Colors.transparent,
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        stops: const [0, 0.5, 0.78, 1],
                        colors: [
                          Colors.transparent,
                          Colors.transparent,
                          pageBg.withValues(alpha: 0.55),
                          pageBg,
                        ],
                      ),
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      AppSpacing.page,
                      math.max(AppSpacing.xl, topOverlap),
                      AppSpacing.page,
                      AppSpacing.xl,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Spacer(),
                        if (item.isEpisode &&
                            item.seriesName != null &&
                            item.seriesName!.isNotEmpty)
                          _SeriesLink(
                            name: item.seriesName!,
                            seriesId: seriesId ?? item.seriesId,
                          ),
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: math.min(width * 0.68, 720),
                          ),
                          child: SelectableText(
                            itemTitle(item),
                            maxLines: 2,
                            style:
                                (compact
                                        ? theme.textTheme.headlineLarge
                                        : theme.textTheme.displayMedium)
                                    ?.copyWith(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w800,
                                    ),
                          ),
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        _MetaRow(
                          item: item,
                          runtime: runtime,
                          seasonCount: seasonCount,
                          nextEpisode: nextEpisode,
                          onLocateEpisode: onLocateEpisode,
                        ),
                        if (overviewInHero) ...[
                          const SizedBox(height: AppSpacing.sm),
                          ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: math.min(width * 0.6, 560),
                            ),
                            child: SelectableText(
                              item.overview!,
                              maxLines: compact ? 2 : 3,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: Colors.white.withValues(alpha: 0.86),
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(height: AppSpacing.lg),
                        _HeroActions(
                          item: item,
                          l10n: l10n,
                          busyPlayed: busyPlayed,
                          onPlay: onPlay,
                          onPlayFromStart: onPlayFromStart,
                          onOpenNextEpisode: onOpenNextEpisode,
                          onViewEpisode: onViewEpisode,
                          onPlayedChanged: onPlayedChanged,
                          mediaSourceId: mediaSourceId,
                          audioStreamIndex: audioStreamIndex,
                          subtitleStreamIndex: subtitleStreamIndex,
                          onMediaSource: onMediaSource,
                          onAudio: onAudio,
                          onSubtitle: onSubtitle,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (hasOverview && !overviewInHero)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.page,
                  AppSpacing.md,
                  AppSpacing.page,
                  0,
                ),
                child: SelectableText(
                  item.overview!,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.78),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// hero 内的元信息行:集标/下一集、时长、季集数与观看进度。
class _MetaRow extends StatelessWidget {
  const _MetaRow({
    required this.item,
    required this.runtime,
    required this.seasonCount,
    required this.nextEpisode,
    this.onLocateEpisode,
  });

  final EmbyItem item;
  final String? runtime;
  final int seasonCount;
  final EmbyItem? nextEpisode;
  final VoidCallback? onLocateEpisode;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final style = Theme.of(context).textTheme.labelMedium?.copyWith(
      color: Colors.white.withValues(alpha: 0.82),
      letterSpacing: 0.2,
    );
    Widget chip(String text, {Key? key}) {
      return Container(
        key: key,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(text, style: style),
      );
    }

    Widget locateChip(String text, {VoidCallback? onTap}) {
      final body = chip(text);
      if (onTap == null) {
        return body;
      }
      return Tooltip(
        message: AppLocalizations.of(context).pickEpisode,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          child: body,
        ),
      );
    }

    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.xs,
      children: [
        if (item.isEpisode)
          locateChip(
            seasonEpisodeCode(item) ?? episodeLabel(item),
            onTap: onLocateEpisode,
          ),
        if (nextEpisode != null && item.isSeries)
          chip(episodeLabel(nextEpisode!)),
        if (runtime != null) chip(runtime!),
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

ButtonStyle _heroGhostButtonStyle() {
  return OutlinedButton.styleFrom(
    foregroundColor: Colors.white,
    side: BorderSide(color: Colors.white.withValues(alpha: 0.42)),
    minimumSize: const Size(0, 48),
    padding: const EdgeInsets.symmetric(
      horizontal: AppSpacing.lg,
      vertical: AppSpacing.sm,
    ),
  );
}

/// 主操作与片源/音轨/字幕收在同一排,避免英雄区下面再挂一块表单。
class _HeroActions extends StatelessWidget {
  const _HeroActions({
    required this.item,
    required this.l10n,
    required this.busyPlayed,
    required this.onPlayedChanged,
    this.onPlay,
    this.onPlayFromStart,
    this.onOpenNextEpisode,
    this.onViewEpisode,
    this.mediaSourceId,
    this.audioStreamIndex,
    this.subtitleStreamIndex,
    this.onMediaSource,
    this.onAudio,
    this.onSubtitle,
  });

  final EmbyItem item;
  final AppLocalizations l10n;
  final bool busyPlayed;
  final ValueChanged<bool> onPlayedChanged;
  final VoidCallback? onPlay;
  final VoidCallback? onPlayFromStart;
  final VoidCallback? onOpenNextEpisode;
  final VoidCallback? onViewEpisode;
  final String? mediaSourceId;
  final int? audioStreamIndex;
  final int? subtitleStreamIndex;
  final ValueChanged<String>? onMediaSource;
  final ValueChanged<int>? onAudio;
  final ValueChanged<int?>? onSubtitle;

  @override
  Widget build(BuildContext context) {
    final audios = _audioChoices(item, mediaSourceId);
    final subtitles = _subtitleChoices(item, mediaSourceId);
    final sourceId =
        mediaSourceId ??
        (item.mediaSources.isEmpty ? null : item.mediaSources.first.id);
    String sourceLabel = '';
    for (final source in item.mediaSources) {
      if (source.id == sourceId) {
        sourceLabel = source.label;
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
    final ghost = _heroGhostButtonStyle();
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (onPlay != null)
          FilledButton.icon(
            key: PlayerKeys.open,
            onPressed: onPlay,
            style: FilledButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: Colors.black,
              minimumSize: const Size(0, 48),
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.xxl,
                vertical: AppSpacing.sm,
              ),
            ),
            icon: const Icon(Icons.play_arrow_rounded, size: 26),
            label: Text(
              onPlayFromStart != null || item.canResume
                  ? l10n.resumePlay
                  : l10n.play,
            ),
          ),
        if (onPlayFromStart != null)
          OutlinedButton(
            key: PlayerKeys.resumeFromStart,
            onPressed: onPlayFromStart,
            style: ghost,
            child: Text(l10n.playFromStart),
          ),
        if (onOpenNextEpisode != null)
          OutlinedButton.icon(
            key: CatalogKeys.nextEpisode,
            onPressed: onOpenNextEpisode,
            style: ghost.copyWith(
              minimumSize: const WidgetStatePropertyAll(Size(0, 48)),
            ),
            icon: const Icon(Icons.skip_next_rounded),
            label: Text(l10n.nextEpisode),
          ),
        if (onViewEpisode != null)
          OutlinedButton.icon(
            key: CatalogKeys.viewEpisode,
            onPressed: onViewEpisode,
            style: ghost,
            icon: const Icon(Icons.slideshow_outlined),
            label: Text(l10n.viewThisEpisode),
          ),
        if (item.mediaSources.length > 1 ||
            audios.length > 1 ||
            subtitles.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xxs),
            child: SizedBox(
              height: 22,
              child: VerticalDivider(
                width: 1,
                thickness: 1,
                color: Colors.white.withValues(alpha: 0.28),
              ),
            ),
          ),
        _HeroIconButton(
          buttonKey: CatalogKeys.playedToggle,
          tooltip: item.userData.played ? l10n.markUnplayed : l10n.markPlayed,
          icon: item.userData.played
              ? Icons.check_circle_rounded
              : Icons.check_circle_outline_rounded,
          selected: item.userData.played,
          onPressed: busyPlayed
              ? null
              : () => onPlayedChanged(!item.userData.played),
        ),
        if (item.mediaSources.length > 1)
          _HeroIconMenu<String>(
            menuKey: CatalogKeys.mediaSource,
            tooltip: '${l10n.mediaSource} · $sourceLabel',
            icon: Icons.movie_filter_outlined,
            items: [
              for (final source in item.mediaSources)
                CheckedPopupMenuItem(
                  value: source.id,
                  checked: source.id == sourceId,
                  child: Text(source.label),
                ),
            ],
            onSelected: (value) => onMediaSource?.call(value),
          ),
        if (audios.length > 1)
          KeyedSubtree(
            key: ValueKey('audio-$mediaSourceId-$audioStreamIndex'),
            child: _HeroIconMenu<int>(
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
          ),
        if (subtitles.isNotEmpty)
          _HeroIconMenu<int>(
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
      ],
    );
  }
}

class _HeroIconButton extends StatelessWidget {
  const _HeroIconButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.buttonKey,
    this.selected = false,
  });

  final Key? buttonKey;
  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: LiquidGlass(
        kind: LiquidGlassKind.pill,
        width: 48,
        height: 48,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            key: buttonKey,
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: Center(
              child: Icon(
                icon,
                size: 22,
                color: selected
                    ? Theme.of(context).colorScheme.primary
                    : Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HeroIconMenu<T> extends StatelessWidget {
  const _HeroIconMenu({
    required this.tooltip,
    required this.icon,
    required this.items,
    required this.onSelected,
    this.menuKey,
  });

  final Key? menuKey;
  final String tooltip;
  final IconData icon;
  final List<PopupMenuEntry<T>> items;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<T>(
      key: menuKey,
      tooltip: tooltip,
      onSelected: onSelected,
      itemBuilder: (context) => items,
      child: LiquidGlass(
        kind: LiquidGlassKind.pill,
        width: 48,
        height: 48,
        child: Center(child: Icon(icon, size: 22, color: Colors.white)),
      ),
    );
  }
}

/// 详情页加载骨架:hero 色块 + 文本行 + 一行 shelf 占位。
class _DetailSkeleton extends StatelessWidget {
  const _DetailSkeleton({this.topOverlap = 0});

  final double topOverlap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return SingleChildScrollView(
          physics: const NeverScrollableScrollPhysics(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SkeletonBlock(
                width: double.infinity,
                height: _DetailHero.heightFor(width) + topOverlap,
                borderRadius: BorderRadius.zero,
              ),
              Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SkeletonBlock(width: width * 0.35, height: AppSpacing.lg),
                    const SizedBox(height: AppSpacing.xs),
                    SkeletonBlock(width: width * 0.6, height: AppSpacing.md),
                    const SizedBox(height: AppSpacing.xs),
                    SkeletonBlock(width: width * 0.55, height: AppSpacing.md),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                child: SkeletonShelfRow(
                  posterWidth: MediaShelf.wideCardWidthFor(width),
                  posterAspectRatio: 16 / 9,
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
