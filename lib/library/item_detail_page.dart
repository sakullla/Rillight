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
import 'package:rillight/app/widgets/app_hover_card.dart';
import 'package:rillight/app/widgets/skeleton.dart';
import 'package:rillight/app/window_chrome.dart';
import 'package:rillight/auth/auth_scope.dart';
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
  EmbyItem? _item;
  List<EmbyItem> _seasons = const [];
  List<EmbyItem> _episodes = const [];
  List<EmbyItem> _similar = const [];
  String? _seasonId;
  bool _loading = true;
  bool _busyPlayed = false;
  EmbyException? _error;
  EmbyException? _similarError;
  String? _mediaSourceId;
  int? _audioStreamIndex;
  int? _subtitleStreamIndex;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _load();
      }
    });
  }

  @override
  void didUpdateWidget(ItemDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.itemId != widget.itemId) {
      _load();
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _similarError = null;
      _seasons = const [];
      _episodes = const [];
      _similar = const [];
      _seasonId = null;
      _mediaSourceId = null;
      _audioStreamIndex = null;
      _subtitleStreamIndex = null;
    });
    final client = AuthScope.of(context).client;
    try {
      final item = await client.getItem(widget.itemId);
      var seasons = const <EmbyItem>[];
      var episodes = const <EmbyItem>[];
      String? seasonId;
      if (item.isSeries) {
        seasons = await client.getItems(
          parentId: item.id,
          includeItemTypes: 'Season',
          sortBy: 'IndexNumber',
          sortOrder: 'Ascending',
        );
        if (seasons.isNotEmpty) {
          seasonId = seasons.first.id;
          episodes = await client.getItems(
            parentId: seasonId,
            includeItemTypes: 'Episode',
            sortBy: 'IndexNumber',
            sortOrder: 'Ascending',
          );
        }
      }
      var similar = const <EmbyItem>[];
      EmbyException? similarError;
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
      if (!mounted) {
        return;
      }
      setState(() {
        _item = item;
        _seasons = seasons;
        _episodes = episodes;
        _seasonId = seasonId;
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
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  Future<void> _selectSeason(String seasonId) async {
    setState(() {
      _seasonId = seasonId;
      _episodes = const [];
    });
    try {
      final episodes = await AuthScope.of(context).client.getItems(
        parentId: seasonId,
        includeItemTypes: 'Episode',
        sortBy: 'IndexNumber',
        sortOrder: 'Ascending',
      );
      if (!mounted) {
        return;
      }
      setState(() => _episodes = episodes);
    } on EmbyException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = error);
    }
  }

  Future<void> _openPlayer(String itemId, {int? startTimeTicks}) async {
    try {
      await PlayerWindowScope.of(context).open(
        PlayerOpenRequest(
          itemId: itemId,
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
                nextEpisode: playTarget != null && item.isSeries
                    ? playTarget
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
                onPlay: playTarget == null
                    ? null
                    : () => _openPlayer(playTarget.id),
                onPlayedChanged: (value) {
                  _setPlayed(value);
                },
              ),
              if (item.chapters.isNotEmpty)
                _ChapterRow(
                  itemId: item.id,
                  chapters: item.chapters,
                  onSelect: (chapter) {
                    final target = playTarget ?? item;
                    if (target.isPlayable) {
                      _openPlayer(
                        target.id,
                        startTimeTicks: chapter.startPositionTicks,
                      );
                    }
                  },
                ),
              if (item.isSeries) ...[
                if (continueWatching.isNotEmpty)
                  MediaShelf(
                    rowKey: CatalogKeys.resumeRow,
                    shelfId: '${CatalogKeys.shelfEpisodes}-resume',
                    title: l10n.resumeRow,
                    items: continueWatching,
                    wide: true,
                    onTap: (episode) =>
                        context.push(AppRoutes.item(episode.id)),
                    itemBuilder: (context, episode) {
                      return EpisodeThumbCard(
                        item: episode,
                        width: wideCardWidth,
                        onTap: () => context.push(AppRoutes.item(episode.id)),
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
                    onTap: (episode) =>
                        context.push(AppRoutes.item(episode.id)),
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
                        onTap: () => context.push(AppRoutes.item(episode.id)),
                      );
                    },
                  ),
                if (_seasons.isNotEmpty)
                  MediaShelf(
                    shelfId: 'seasons',
                    title: l10n.seasons,
                    items: _seasons,
                    onTap: (season) => _selectSeason(season.id),
                    itemBuilder: (context, season) {
                      return SeasonPosterCard(
                        item: season,
                        width: posterWidth,
                        selected: season.id == _seasonId,
                        onTap: () => _selectSeason(season.id),
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
        // 返回按钮悬浮于整页左上,滚动出 hero 后仍可及。
        Positioned(
          top: AppSpacing.md,
          left: AppSpacing.md,
          child: _FloatingBackButton(
            onPressed: () {
              if (context.canPop()) {
                context.pop();
              } else {
                context.go(AppRoutes.home);
              }
            },
          ),
        ),
      ],
    );
  }
}

/// 悬浮圆形返回按钮,与 shelf 翻页按钮同款 scrim 圆形风格。
class _FloatingBackButton extends StatelessWidget {
  const _FloatingBackButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.scrim.withValues(alpha: 0.55),
      shape: const CircleBorder(),
      child: IconButton(
        key: CatalogKeys.back,
        tooltip: 'Back',
        color: Colors.white,
        onPressed: onPressed,
        icon: const Icon(Icons.arrow_back),
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
    this.topOverlap = 0,
    this.seasonCount = 0,
    this.nextEpisode,
    this.mediaSourceId,
    this.audioStreamIndex,
    this.subtitleStreamIndex,
    this.onMediaSource,
    this.onAudio,
    this.onSubtitle,
  });

  final EmbyItem item;
  final String? runtime;
  final bool busyPlayed;
  final VoidCallback? onPlay;
  final ValueChanged<bool> onPlayedChanged;
  final double topOverlap;
  final int seasonCount;
  final EmbyItem? nextEpisode;
  final String? mediaSourceId;
  final int? audioStreamIndex;
  final int? subtitleStreamIndex;
  final ValueChanged<String>? onMediaSource;
  final ValueChanged<int>? onAudio;
  final ValueChanged<int?>? onSubtitle;

  /// hero 高度:内容区宽度 × 0.45,按 [AppBreakpoints] 设上下限。
  static double heightFor(double width) {
    final base = width * 0.45;
    if (width < AppBreakpoints.compact) {
      return base.clamp(320.0, 420.0);
    }
    if (width < AppBreakpoints.large) {
      return base.clamp(400.0, 560.0);
    }
    return base.clamp(520.0, 680.0);
  }

  /// 高度足够时才把简介放进 hero。
  static bool showsOverview(double width) => heightFor(width) >= 360;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scrim = theme.colorScheme.scrim;
    final surface = theme.colorScheme.surface;
    final hasOverview =
        item.overview != null && item.overview!.trim().isNotEmpty;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final height = heightFor(width) + topOverlap;
        final compact = width < AppBreakpoints.compact;
        final overviewInHero = hasOverview && showsOverview(width);
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
                    item: item,
                    height: height,
                    preferBackdrop: true,
                    maxWidth: 1600,
                  ),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.centerLeft,
                        end: Alignment.centerRight,
                        colors: [
                          scrim.withValues(alpha: 0.8),
                          scrim.withValues(alpha: 0),
                        ],
                      ),
                    ),
                  ),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [
                          scrim.withValues(alpha: 0.9),
                          scrim.withValues(alpha: 0),
                        ],
                      ),
                    ),
                  ),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.center,
                        colors: [surface, surface.withValues(alpha: 0)],
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.xxl,
                      AppSpacing.xl,
                      AppSpacing.xxl,
                      AppSpacing.xl,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Spacer(),
                        if (item.isEpisode && item.seriesName != null)
                          Text(
                            item.seriesName!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              color: Colors.white.withValues(alpha: 0.78),
                            ),
                          ),
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: math.min(width * 0.75, 760),
                          ),
                          child: Text(
                            itemTitle(item),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
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
                        ),
                        if (overviewInHero) ...[
                          const SizedBox(height: AppSpacing.sm),
                          ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: math.min(width * 0.6, 560),
                            ),
                            child: Text(
                              item.overview!,
                              maxLines: compact ? 2 : 3,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: Colors.white.withValues(alpha: 0.86),
                              ),
                            ),
                          ),
                        ],
                        if (onPlay != null) ...[
                          const SizedBox(height: AppSpacing.lg),
                          FilledButton.icon(
                            key: PlayerKeys.open,
                            onPressed: onPlay,
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: AppSpacing.xxl,
                                vertical: AppSpacing.md,
                              ),
                            ),
                            icon: const Icon(Icons.play_arrow),
                            label: Text(
                              item.canResume ? l10n.resumePlay : l10n.play,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (hasOverview && !overviewInHero)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md,
                  AppSpacing.md,
                  AppSpacing.md,
                  0,
                ),
                child: Text(
                  item.overview!,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.78),
                  ),
                ),
              ),
            _PlaybackSettings(
              item: item,
              busyPlayed: busyPlayed,
              mediaSourceId: mediaSourceId,
              audioStreamIndex: audioStreamIndex,
              subtitleStreamIndex: subtitleStreamIndex,
              onMediaSource: onMediaSource,
              onAudio: onAudio,
              onSubtitle: onSubtitle,
              onPlayedChanged: onPlayedChanged,
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
  });

  final EmbyItem item;
  final String? runtime;
  final int seasonCount;
  final EmbyItem? nextEpisode;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final style = Theme.of(context).textTheme.labelLarge?.copyWith(
      color: Colors.white.withValues(alpha: 0.78),
    );
    return Wrap(
      spacing: AppSpacing.md,
      runSpacing: AppSpacing.xs,
      children: [
        if (item.isEpisode) Text(episodeLabel(item), style: style),
        if (nextEpisode != null && item.isSeries)
          Text(episodeLabel(nextEpisode!), style: style),
        if (runtime != null) Text(runtime!, style: style),
        if (item.isSeries && seasonCount > 0)
          Text(l10n.seasonCount(seasonCount), style: style),
        if (item.childCount != null && item.isSeries)
          Text(l10n.episodeCount(item.childCount!), style: style),
        if (item.canResume)
          Text(
            l10n.playbackProgress((item.playbackProgress * 100).round()),
            key: CatalogKeys.resumeProgress,
            style: style,
          ),
      ],
    );
  }
}

/// 播放设置区:版本/音轨/字幕选择与已看开关,卡片化分组。
/// 下拉取值与联动回调与旧实现一致。
class _PlaybackSettings extends StatelessWidget {
  const _PlaybackSettings({
    required this.item,
    required this.busyPlayed,
    required this.onPlayedChanged,
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
  final String? mediaSourceId;
  final int? audioStreamIndex;
  final int? subtitleStreamIndex;
  final ValueChanged<String>? onMediaSource;
  final ValueChanged<int>? onAudio;
  final ValueChanged<int?>? onSubtitle;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
      ),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (item.mediaSources.length > 1)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                  child: KeyedSubtree(
                    key: ValueKey(
                      'source-${mediaSourceId ?? item.mediaSources.first.id}',
                    ),
                    child: DropdownButtonFormField<String>(
                      key: CatalogKeys.mediaSource,
                      decoration: InputDecoration(labelText: l10n.mediaSource),
                      initialValue: mediaSourceId ?? item.mediaSources.first.id,
                      items: [
                        for (final source in item.mediaSources)
                          DropdownMenuItem(
                            value: source.id,
                            child: Text(
                              source.label,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          onMediaSource?.call(value);
                        }
                      },
                    ),
                  ),
                ),
              if (_audioChoices(item, mediaSourceId).length > 1)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                  child: KeyedSubtree(
                    key: ValueKey('audio-$mediaSourceId-$audioStreamIndex'),
                    child: DropdownButtonFormField<int>(
                      key: CatalogKeys.detailAudio,
                      decoration: InputDecoration(labelText: l10n.audioTrack),
                      initialValue: audioStreamIndex,
                      items: [
                        for (final stream in _audioChoices(item, mediaSourceId))
                          DropdownMenuItem(
                            value: stream.index,
                            child: Text(stream.label ?? '#${stream.index}'),
                          ),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          onAudio?.call(value);
                        }
                      },
                    ),
                  ),
                ),
              if (_subtitleChoices(item, mediaSourceId).isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                  child: DropdownButtonFormField<int?>(
                    decoration: InputDecoration(labelText: l10n.subtitleTrack),
                    initialValue: subtitleStreamIndex,
                    items: [
                      DropdownMenuItem<int?>(
                        value: null,
                        child: Text(l10n.subtitleOff),
                      ),
                      for (final stream in _subtitleChoices(
                        item,
                        mediaSourceId,
                      ))
                        DropdownMenuItem<int?>(
                          value: stream.index,
                          child: Text(stream.label ?? '#${stream.index}'),
                        ),
                    ],
                    onChanged: onSubtitle,
                  ),
                ),
              SwitchListTile(
                key: CatalogKeys.playedToggle,
                contentPadding: EdgeInsets.zero,
                title: Text(
                  item.userData.played ? l10n.markUnplayed : l10n.markPlayed,
                ),
                value: item.userData.played,
                onChanged: busyPlayed ? null : onPlayedChanged,
              ),
            ],
          ),
        ),
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

class _ChapterRow extends StatefulWidget {
  const _ChapterRow({
    required this.itemId,
    required this.chapters,
    required this.onSelect,
  });

  final String itemId;
  final List<ItemChapter> chapters;
  final ValueChanged<ItemChapter> onSelect;

  static const double _cardWidth = 168;
  static const double _imageHeight = 94;

  // 行高:缩略图 + 间距 + 两行文字(标题/时间码)。
  static const double _rowHeight =
      _imageHeight + AppSpacing.xs + AppSpacing.xxxl;

  @override
  State<_ChapterRow> createState() => _ChapterRowState();
}

class _ChapterRowState extends State<_ChapterRow> {
  final ScrollController _controller = ScrollController();
  bool _overflowing = false;
  bool _canScrollLeft = false;
  bool _canScrollRight = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_updateScrollButtons);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _updateScrollButtons();
      }
    });
  }

  @override
  void dispose() {
    _controller.removeListener(_updateScrollButtons);
    _controller.dispose();
    super.dispose();
  }

  void _updateScrollButtons() {
    if (!_controller.hasClients) {
      if (_overflowing || _canScrollLeft || _canScrollRight) {
        setState(() {
          _overflowing = false;
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
    if (overflowing != _overflowing ||
        canLeft != _canScrollLeft ||
        canRight != _canScrollRight) {
      setState(() {
        _overflowing = overflowing;
        _canScrollLeft = canLeft;
        _canScrollRight = canRight;
      });
    }
  }

  // 垂直滚轮转发给父级滚动(与 MediaShelf 同策略),避免在行上死锁滚轮。
  void _onVerticalWheelToParent(PointerSignalEvent event) {
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

  void _page(int direction) {
    if (!_controller.hasClients) {
      return;
    }
    final position = _controller.position;
    final delta = position.viewportDimension * 0.9 * direction;
    _controller.animateTo(
      (position.pixels + delta).clamp(0.0, position.maxScrollExtent),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: Text(
              l10n.chapters,
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          SizedBox(
            height: _ChapterRow._rowHeight,
            child: Stack(
              children: [
                NotificationListener<ScrollMetricsNotification>(
                  onNotification: (notification) {
                    _updateScrollButtons();
                    return false;
                  },
                  child: ListView.separated(
                    controller: _controller,
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.md,
                    ),
                    scrollDirection: Axis.horizontal,
                    itemCount: widget.chapters.length,
                    separatorBuilder: (context, index) =>
                        const SizedBox(width: AppSpacing.sm),
                    itemBuilder: (context, index) {
                      final chapter = widget.chapters[index];
                      return Align(
                        alignment: Alignment.center,
                        child: Listener(
                          onPointerSignal: _onVerticalWheelToParent,
                          child: _ChapterCard(
                            itemId: widget.itemId,
                            index: index,
                            chapter: chapter,
                            onTap: () => widget.onSelect(chapter),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                if (_canScrollLeft)
                  Positioned(
                    left: AppSpacing.xs,
                    top: 0,
                    bottom: 0,
                    child: Center(
                      child: _ChapterScrollButton(
                        buttonKey: CatalogKeys.shelfScrollLeft('chapters'),
                        tooltip: l10n.scrollLeft,
                        icon: Icons.chevron_left,
                        onPressed: () => _page(-1),
                      ),
                    ),
                  ),
                if (_canScrollRight)
                  Positioned(
                    right: AppSpacing.xs,
                    top: 0,
                    bottom: 0,
                    child: Center(
                      child: _ChapterScrollButton(
                        buttonKey: CatalogKeys.shelfScrollRight('chapters'),
                        tooltip: l10n.scrollRight,
                        icon: Icons.chevron_right,
                        onPressed: () => _page(1),
                      ),
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
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xxs),
      child: Material(
        color: Theme.of(context).colorScheme.scrim.withValues(alpha: 0.55),
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

class _ChapterCard extends StatelessWidget {
  const _ChapterCard({
    required this.itemId,
    required this.index,
    required this.chapter,
    required this.onTap,
  });

  final String itemId;
  final int index;
  final ItemChapter chapter;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const width = _ChapterRow._cardWidth;
    const height = _ChapterRow._imageHeight;
    final colorScheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: width,
      child: AppHoverCard(
        inkKey: CatalogKeys.chapter(index),
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadii.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadii.sm),
              child: SizedBox(
                width: width,
                height: height,
                child: ColoredBox(
                  color: colorScheme.surfaceContainerHigh,
                  child: _ChapterImage(
                    itemId: itemId,
                    index: index,
                    tag: chapter.imageTag,
                  ),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              chapter.name.isEmpty ? 'Chapter ${index + 1}' : chapter.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            Text(
              chapterClock(chapter.startPositionTicks),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 章节缩略图:数据通道保持 client.getChapterImage + FutureBuilder 不变,
/// 加载中显示骨架,加载完成淡入,失败/空数据回退占位图标。
class _ChapterImage extends StatefulWidget {
  const _ChapterImage({required this.itemId, required this.index, this.tag});

  final String itemId;
  final int index;
  final String? tag;

  @override
  State<_ChapterImage> createState() => _ChapterImageState();
}

class _ChapterImageState extends State<_ChapterImage> {
  Future<Uint8List?>? _future;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _future ??= _load();
  }

  Future<Uint8List?> _load() async {
    try {
      final bytes = await AuthScope.of(context).client.getChapterImage(
        widget.itemId,
        index: widget.index,
        tag: widget.tag,
      );
      if (bytes.isEmpty) {
        return null;
      }
      return Uint8List.fromList(bytes);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: _future,
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (snapshot.connectionState != ConnectionState.done) {
          return const SkeletonBlock(borderRadius: BorderRadius.zero);
        }
        if (bytes == null || bytes.isEmpty) {
          return Center(
            child: Icon(
              Icons.menu_book_outlined,
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          );
        }
        return Image.memory(
          bytes,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
            if (wasSynchronouslyLoaded) {
              return child;
            }
            return AnimatedOpacity(
              opacity: frame == null ? 0 : 1,
              duration: AppMotion.normal,
              curve: AppMotion.standard,
              child: child,
            );
          },
        );
      },
    );
  }
}
