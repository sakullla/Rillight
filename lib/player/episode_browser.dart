import 'dart:async';

import 'package:flutter/material.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/app/widgets/skeleton.dart';
import 'package:rillight/media_server/models.dart';
import 'package:rillight/library/item_format.dart';
import 'package:rillight/media_image/media_image.dart';
import 'package:rillight/player/player_controller.dart';

/// 剧集行固定高度,给 ListView 按 index 做 O(1) jumpTo。
///
/// [Scrollable.ensureVisible] 只能滚到已经建出来的行;120 集时当前集
/// 往往还在 builder 窗口外,打开面板会停在第 1 集。行高固定后
/// `offset = index * extent` 不必先构建前面的行。
const double kPlayerEpisodeRowExtent = 112;

/// 电视行要容纳焦点按钮的内边距,比触控行更高。
const double kPlayerEpisodeRowExtentTv = 128;

/// 把当前集放到视口约 [alignment] 处;打开面板用 jumpTo,不 animate,
/// 避免长列表滑过上百行。
double playerEpisodeListOffset({
  required int index,
  required int itemCount,
  required double itemExtent,
  required double viewport,
  double alignment = 0.25,
}) {
  if (index <= 0 || itemCount <= 0 || itemExtent <= 0) {
    return 0;
  }
  final maxOffset = itemCount * itemExtent > viewport
      ? itemCount * itemExtent - viewport
      : 0.0;
  if (maxOffset <= 0) {
    return 0;
  }
  final raw = index * itemExtent - viewport * alignment;
  if (raw < 0) {
    return 0;
  }
  if (raw > maxOffset) {
    return maxOffset;
  }
  return raw;
}

/// 剧集列表面板:季切换、当前集定位、向上/向下补页。
///
/// 手机放进侧栏或底栏,电视用遥控器焦点行,桌面嵌在右侧浮层。
class PlayerEpisodeBrowser extends StatelessWidget {
  const PlayerEpisodeBrowser({
    super.key,
    required this.controller,
    required this.onClose,
    this.tv = false,
    this.closeOnPlay = false,
  });

  final PlayerController controller;
  final VoidCallback onClose;
  final bool tv;

  /// 手机浮层盖住画面,选中后收起;桌面和电视留着列表方便连换。
  final bool closeOnPlay;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final seasons = controller.seasons;
    final currentSeason = seasons
        .where((season) => season.id == controller.episodeSeasonId)
        .toList();
    final extent = tv
        ? kPlayerEpisodeRowExtentTv * TvDesign.scaleOf(context)
        : kPlayerEpisodeRowExtent;
    return Padding(
      key: const Key('player-episodes-panel'),
      padding: EdgeInsets.fromLTRB(
        tv ? context.tvdp(AppSpacing.md) : AppSpacing.md,
        tv ? context.tvdp(AppSpacing.md) : AppSpacing.md,
        tv ? context.tvdp(AppSpacing.md) : AppSpacing.md,
        tv ? context.tvdp(AppSpacing.sm) : AppSpacing.lg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _title(l10n),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      (tv
                              ? theme.textTheme.headlineSmall
                              : theme.textTheme.titleMedium)
                          ?.copyWith(
                            color: scheme.onSurface,
                            fontWeight: FontWeight.w700,
                          ),
                ),
              ),
              if (!tv && seasons.length > 1)
                _SeasonMenu(controller: controller)
              else if (!tv && currentSeason.length == 1)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.sm,
                  ),
                  child: Text(
                    currentSeason.first.name,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              _closeButton(context),
            ],
          ),
          if (tv && seasons.length > 1) ...[
            SizedBox(height: context.tvdp(AppSpacing.sm)),
            _TvSeasonStrip(controller: controller),
          ] else if (tv && currentSeason.length == 1) ...[
            SizedBox(height: context.tvdp(4)),
            Text(
              currentSeason.first.name,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
          SizedBox(height: tv ? context.tvdp(AppSpacing.sm) : AppSpacing.sm),
          Expanded(child: _body(context, l10n, scheme, extent)),
          if (tv) ...[
            SizedBox(height: context.tvdp(AppSpacing.sm)),
            TvAction(
              key: const Key('tv-panel-back'),
              variant: TvActionVariant.tile,
              onPressed: onClose,
              child: Text(l10n.mobileBack),
            ),
          ],
        ],
      ),
    );
  }

  Widget _closeButton(BuildContext context) {
    final tooltip = MaterialLocalizations.of(context).closeButtonTooltip;
    if (tv) {
      return TvAction(
        key: const Key('player-episodes-close'),
        variant: TvActionVariant.icon,
        onPressed: onClose,
        child: const Icon(Icons.close_rounded),
      );
    }
    return IconButton(
      key: const Key('player-episodes-close'),
      tooltip: tooltip,
      color: Theme.of(context).colorScheme.onSurface,
      onPressed: onClose,
      icon: const Icon(Icons.close_rounded),
    );
  }

  String _title(AppLocalizations l10n) {
    final seriesName = controller.item?.seriesName?.trim();
    if (seriesName != null && seriesName.isNotEmpty) {
      return seriesName;
    }
    return l10n.playerEpisodes;
  }

  void _play(MediaItem episode) {
    unawaited(controller.playEpisode(episode));
    if (closeOnPlay) onClose();
  }

  Widget _body(
    BuildContext context,
    AppLocalizations l10n,
    ColorScheme scheme,
    double extent,
  ) {
    if (controller.episodeListLoading && controller.episodes.isEmpty) {
      return ListView.separated(
        padding: EdgeInsets.zero,
        itemCount: 6,
        separatorBuilder: (context, index) =>
            const SizedBox(height: AppSpacing.xxs),
        itemBuilder: (context, index) => _EpisodeRowSkeleton(extent: extent),
      );
    }
    if (controller.episodeListFailed && controller.episodes.isEmpty) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            l10n.playbackFailed,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: AppSpacing.sm),
          OutlinedButton(
            key: const Key('player-episodes-retry'),
            onPressed: () {
              unawaited(controller.loadEpisodeList());
            },
            child: Text(l10n.retry),
          ),
        ],
      );
    }
    return _EpisodeListView(
      episodes: controller.episodes,
      currentId: controller.itemId,
      currentIndexNumber: controller.item?.indexNumber,
      currentSeasonId: controller.item?.seasonId,
      hasEarlier: controller.hasEarlierEpisodes,
      hasMore: controller.hasMoreEpisodes,
      loadingEarlier: controller.episodeLoadingEarlier,
      loadingMore: controller.episodeLoadingMore,
      itemExtent: extent,
      tv: tv,
      autofocusCurrent: !tv || controller.seasons.length <= 1,
      progressFor: _progress,
      onPlay: _play,
      onLoadEarlier: () => unawaited(controller.loadEarlierEpisodes()),
      onLoadMore: () => unawaited(controller.loadMoreEpisodes()),
    );
  }

  double _progress(MediaItem episode, bool isCurrent) {
    if (isCurrent) {
      final duration = controller.duration;
      if (duration > Duration.zero) {
        return (controller.position.inMilliseconds / duration.inMilliseconds)
            .clamp(0.0, 1.0);
      }
    }
    return episode.playbackProgress;
  }
}

class _SeasonMenu extends StatelessWidget {
  const _SeasonMenu({required this.controller});

  final PlayerController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final seasons = controller.seasons;
    var current = seasons.first;
    for (final season in seasons) {
      if (season.id == controller.episodeSeasonId) {
        current = season;
        break;
      }
    }
    return PopupMenuButton<String>(
      key: const Key('player-season-picker'),
      tooltip: AppLocalizations.of(context).seasons,
      onSelected: (seasonId) {
        unawaited(controller.selectSeason(seasonId));
      },
      initialValue: current.id,
      constraints: () {
        final viewport = MediaQuery.sizeOf(context);
        final maxWidth = AppViewport.fit(280, viewport.width * 0.5, viewport);
        final minWidth = AppViewport.dp(160, viewport);
        return BoxConstraints(
          minWidth: minWidth < maxWidth ? minWidth : maxWidth,
          maxWidth: maxWidth,
        );
      }(),
      padding: EdgeInsets.zero,
      splashRadius: 20,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: AppViewport.dp(140, MediaQuery.sizeOf(context)),
              ),
              child: Text(
                current.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: scheme.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Icon(Icons.arrow_drop_down_rounded, color: scheme.onSurface),
          ],
        ),
      ),
      itemBuilder: (context) => [
        for (final season in seasons)
          PopupMenuItem(value: season.id, child: Text(season.name)),
      ],
    );
  }
}

class _TvSeasonStrip extends StatelessWidget {
  const _TvSeasonStrip({required this.controller});

  final PlayerController controller;

  @override
  Widget build(BuildContext context) {
    final seasons = controller.seasons;
    return SizedBox(
      key: const Key('player-season-picker'),
      height: context.tvdp(52),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: seasons.length,
        separatorBuilder: (context, index) =>
            SizedBox(width: context.tvdp(AppSpacing.xs)),
        itemBuilder: (context, index) {
          final season = seasons[index];
          final selected = season.id == controller.episodeSeasonId;
          final hasCurrent = seasons.any(
            (item) => item.id == controller.episodeSeasonId,
          );
          return TvAction(
            pill: true,
            autofocus: hasCurrent ? selected : index == 0,
            selected: selected,
            onPressed: () => controller.selectSeason(season.id),
            child: Text(season.name),
          );
        },
      ),
    );
  }
}

class _EpisodeRow extends StatelessWidget {
  const _EpisodeRow({
    required this.episode,
    required this.isCurrent,
    required this.progress,
    required this.onTap,
    required this.tv,
  });

  static const thumbWidth = 128.0;
  static const thumbHeight = thumbWidth * 9 / 16;

  final MediaItem episode;
  final bool isCurrent;
  final double progress;
  final VoidCallback onTap;
  final bool tv;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final number = episode.indexNumber;
    final title = number == null ? episode.name : '$number. ${episode.name}';
    final played = episode.userData.played;
    final overview = tv ? null : _overview(episode.overview);
    final meta = <String>[
      ?seasonEpisodeCode(episode),
      ?runtimeLabel(l10n, episode),
      if (isCurrent) l10n.nowPlayingEpisode,
      if (!isCurrent && episode.canResume)
        l10n.playbackProgress((progress * 100).round()),
    ];
    final body = Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.sm,
        AppSpacing.xs,
        AppSpacing.sm,
        AppSpacing.xs,
      ),
      child: Row(
        children: [
          _EpisodeThumb(
            episode: episode,
            isCurrent: isCurrent,
            played: played,
            progress: progress,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: overview == null
                  ? MainAxisAlignment.center
                  : MainAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: overview == null ? 1 : 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: scheme.onSurface,
                    fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
                if (meta.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.xxs),
                  Text(
                    meta.join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: isCurrent
                          ? scheme.primary
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                ],
                if (overview != null) ...[
                  const SizedBox(height: AppSpacing.xxs),
                  Expanded(
                    child: Text(
                      overview,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurface.withValues(alpha: 0.72),
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(
            width: 3,
            color: isCurrent ? scheme.primary : Colors.transparent,
          ),
        ),
      ),
      child: tv
          ? body
          : Material(
              color: isCurrent
                  ? scheme.surfaceContainerHighest
                  : Colors.transparent,
              child: InkWell(
                key: Key('player-episode-${episode.id}'),
                onTap: onTap,
                child: body,
              ),
            ),
    );
  }
}

class _EpisodeThumb extends StatelessWidget {
  const _EpisodeThumb({
    required this.episode,
    required this.isCurrent,
    required this.played,
    required this.progress,
  });

  final MediaItem episode;
  final bool isCurrent;
  final bool played;
  final double progress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadii.sm),
      child: SizedBox(
        width: _EpisodeRow.thumbWidth,
        height: _EpisodeRow.thumbHeight,
        child: Stack(
          fit: StackFit.expand,
          children: [
            RepaintBoundary(
              child: MediaImage(
                key: ValueKey(episode.id),
                item: episode,
                width: _EpisodeRow.thumbWidth,
                height: _EpisodeRow.thumbHeight,
                preferThumb: true,
                maxWidth: 240,
              ),
            ),
            if (isCurrent)
              ColoredBox(
                color: scheme.scrim.withValues(alpha: 0.42),
                child: Icon(
                  Icons.equalizer_rounded,
                  color: scheme.onSurface,
                  size: 26,
                ),
              ),
            if (played && !isCurrent)
              Align(
                alignment: Alignment.topRight,
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.xxs),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: scheme.scrim.withValues(alpha: 0.55),
                      shape: BoxShape.circle,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: Icon(
                        Icons.check_rounded,
                        size: 14,
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                ),
              ),
            if (progress > 0 && (isCurrent || episode.canResume))
              Align(
                alignment: Alignment.bottomCenter,
                child: _EpisodeProgressBar(value: progress),
              ),
          ],
        ),
      ),
    );
  }
}

class _EpisodeProgressBar extends StatelessWidget {
  const _EpisodeProgressBar({required this.value});

  final double value;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 3,
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.45),
        child: Align(
          alignment: Alignment.centerLeft,
          child: FractionallySizedBox(
            widthFactor: value.clamp(0.0, 1.0),
            child: ColoredBox(color: Theme.of(context).colorScheme.primary),
          ),
        ),
      ),
    );
  }
}

class _EpisodeRowSkeleton extends StatelessWidget {
  const _EpisodeRowSkeleton({required this.extent});

  final double extent;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: extent,
      child: const Padding(
        padding: EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: AppSpacing.xs,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SkeletonBlock(
              width: _EpisodeRow.thumbWidth,
              height: _EpisodeRow.thumbHeight,
            ),
            SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SkeletonBlock(width: 96, height: 14),
                  SizedBox(height: AppSpacing.xs),
                  SkeletonBlock(width: 64, height: 12),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String? _overview(String? raw) {
  final text = raw?.trim();
  if (text == null || text.isEmpty) {
    return null;
  }
  final stripped = text
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), ' ')
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return stripped.isEmpty ? null : stripped;
}

class _EpisodeListView extends StatefulWidget {
  const _EpisodeListView({
    required this.episodes,
    required this.currentId,
    this.currentIndexNumber,
    this.currentSeasonId,
    required this.hasEarlier,
    required this.hasMore,
    required this.loadingEarlier,
    required this.loadingMore,
    required this.itemExtent,
    required this.tv,
    required this.autofocusCurrent,
    required this.progressFor,
    required this.onPlay,
    required this.onLoadEarlier,
    required this.onLoadMore,
  });

  final List<MediaItem> episodes;
  final String currentId;
  final int? currentIndexNumber;
  final String? currentSeasonId;
  final bool hasEarlier;
  final bool hasMore;
  final bool loadingEarlier;
  final bool loadingMore;
  final double itemExtent;
  final bool tv;
  final bool autofocusCurrent;
  final double Function(MediaItem episode, bool isCurrent) progressFor;
  final ValueChanged<MediaItem> onPlay;
  final VoidCallback onLoadEarlier;
  final VoidCallback onLoadMore;

  bool isCurrentEpisode(MediaItem episode) {
    if (episode.id == currentId) {
      return true;
    }
    final indexNumber = currentIndexNumber;
    final seasonId = currentSeasonId;
    return indexNumber != null &&
        episode.indexNumber == indexNumber &&
        seasonId != null &&
        seasonId.isNotEmpty &&
        episode.seasonId == seasonId;
  }

  @override
  State<_EpisodeListView> createState() => _EpisodeListViewState();
}

class _EpisodeListViewState extends State<_EpisodeListView> {
  static const _estimatedViewport = 560.0;

  late final ScrollController _scroll = ScrollController(
    initialScrollOffset: _offsetFor(_estimatedViewport),
  );

  int get _currentIndex {
    return widget.episodes.indexWhere(widget.isCurrentEpisode);
  }

  double get _edgeExtent => widget.itemExtent * 2;

  double _offsetFor(double viewport) {
    return playerEpisodeListOffset(
      index: _currentIndex < 0 ? 0 : _currentIndex,
      itemCount: widget.episodes.length,
      itemExtent: widget.itemExtent,
      viewport: viewport,
    );
  }

  int _prependedCount(List<MediaItem> previous, List<MediaItem> next) {
    if (previous.isEmpty || next.length <= previous.length) {
      return 0;
    }
    final index = next.indexWhere((episode) => episode.id == previous.first.id);
    return index > 0 ? index : 0;
  }

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _jumpToCurrent();
      _maybeLoadEdges();
    });
  }

  @override
  void didUpdateWidget(_EpisodeListView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final prepended = _prependedCount(oldWidget.episodes, widget.episodes);
    if (prepended > 0 && _scroll.hasClients) {
      _scroll.position.correctBy(prepended * widget.itemExtent);
    }
    final wasIn = oldWidget.episodes.any(oldWidget.isCurrentEpisode);
    final isIn = widget.episodes.any(widget.isCurrentEpisode);
    final shouldJump =
        oldWidget.currentId != widget.currentId || (!wasIn && isIn);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (shouldJump) {
        _jumpToCurrent();
      }
      _maybeLoadEdges();
    });
  }

  void _onScroll() => _maybeLoadEdges();

  void _maybeLoadEdges() {
    if (!mounted || !_scroll.hasClients) {
      return;
    }
    final position = _scroll.position;
    if (widget.hasEarlier &&
        !widget.loadingEarlier &&
        position.pixels <= _edgeExtent) {
      widget.onLoadEarlier();
    }
    if (widget.hasMore &&
        !widget.loadingMore &&
        position.pixels >= position.maxScrollExtent - _edgeExtent) {
      widget.onLoadMore();
    }
  }

  void _jumpToCurrent() {
    if (!mounted || !_scroll.hasClients) {
      return;
    }
    final viewport = _scroll.position.viewportDimension;
    if (viewport <= 0) {
      return;
    }
    final next = _offsetFor(viewport);
    if ((next - _scroll.offset).abs() < 1) {
      return;
    }
    _scroll.jumpTo(next);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scrollbar(
      controller: _scroll,
      child: ListView.builder(
        key: const Key('player-episodes-list'),
        controller: _scroll,
        itemExtent: widget.itemExtent,
        itemCount: widget.episodes.length,
        itemBuilder: (context, index) {
          final episode = widget.episodes[index];
          final isCurrent = widget.isCurrentEpisode(episode);
          final row = _EpisodeRow(
            episode: episode,
            isCurrent: isCurrent,
            progress: widget.progressFor(episode, isCurrent),
            onTap: () => widget.onPlay(episode),
            tv: widget.tv,
          );
          return ClipRect(
            child: SizedBox(
              height: widget.itemExtent,
              child: widget.tv
                  ? TvAction(
                      key: Key('player-episode-${episode.id}'),
                      variant: TvActionVariant.tile,
                      autofocus:
                          widget.autofocusCurrent &&
                          (isCurrent || (_currentIndex < 0 && index == 0)),
                      selected: isCurrent,
                      onPressed: () => widget.onPlay(episode),
                      child: row,
                    )
                  : row,
            ),
          );
        },
      ),
    );
  }
}
