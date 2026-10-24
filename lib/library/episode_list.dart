import 'dart:async';

import 'package:rillight/app/ui/app_icons.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:flutter/rendering.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/widgets/app_error_view.dart';
import 'package:rillight/app/widgets/skeleton.dart';
import 'package:rillight/media_server/errors.dart';
import 'package:rillight/media_server/models.dart';
import 'package:rillight/home/catalog_failure.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/library/episode_detail_sections.dart';
import 'package:rillight/library/episode_range_bar.dart';
import 'package:rillight/library/item_format.dart';
import 'package:rillight/media_image/media_image.dart';

/// 分集行网格的几何：列数、行宽、缩略图尺寸与固定的行高。
///
/// 每集是一条等高横排行：左侧 16:9 缩略图，右侧标题、时长/首播与两行简介。
/// 行高取缩略图与文字列（按实际字体与字号测量）中较高者，同一季每行等高，
/// 网格不必构建屏外的行就能定位到任意一集。
class EpisodeGridMetrics {
  const EpisodeGridMetrics({
    required this.columns,
    required this.cardWidth,
    required this.thumbWidth,
    required this.thumbHeight,
    required this.extent,
  });

  /// 行之间的横向/纵向间距。
  static const double crossSpacing = AppSpacing.md;
  static const double mainSpacing = AppSpacing.xs;

  /// 行内边距：悬停/当前集底色比缩略图外扩一圈。
  static const double inset = AppSpacing.xs;

  /// 缩略图与文字列之间的间距。
  static const double textGap = AppSpacing.sm;

  /// 最多并排的列数。
  static const int maxColumns = 3;

  final int columns;
  final double cardWidth;
  final double thumbWidth;
  final double thumbHeight;
  final double extent;

  /// 最窄行宽（1080p 设计值），宽屏随阅读缩放一起变大；可用宽度够放两行
  /// 时并为两列。
  static double minCardWidthFor(Size viewport) =>
      560 * AppViewport.readingScaleOf(viewport);

  /// 两列时允许的最窄行宽。最小窗口 960 与常见的 1024–1280 笔记本窗口
  /// 放不下两条 560 的行，过去只能排成单列：每行左侧四成是内容，右侧大片
  /// 空白。两列放宽到 440；三列仍要求每行不窄于 [minCardWidthFor]。
  static double compactCardWidthFor(Size viewport) =>
      440 * AppViewport.readingScaleOf(viewport);

  /// 缩略图宽度的设计值（1080p），随阅读缩放放大。
  static double thumbDesignWidthFor(Size viewport) =>
      192 * AppViewport.readingScaleOf(viewport);

  /// 给定行宽时的缩略图宽：设计值，但窄行里不超过内容宽的四成。
  static double thumbWidthIn(double cardWidth, Size viewport) {
    final design = thumbDesignWidthFor(viewport);
    final cap = (cardWidth - inset * 2) * .4;
    return cap < design ? (cap < 0 ? 0 : cap) : design;
  }

  /// 文字列（标题 + 时长/首播 + 两行简介）的实际排版高度。
  static double textHeightOf(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    double lines(TextStyle? style, int count) {
      final painter = TextPainter(
        text: TextSpan(
          text: List.filled(count, '国Ag').join('\n'),
          style: style,
        ),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
        maxLines: count,
      )..layout();
      final height = painter.height;
      painter.dispose();
      return height;
    }

    return lines(_EpisodeCardStyles.title(theme), 1) +
        2 +
        lines(_EpisodeCardStyles.meta(theme), 1) +
        AppSpacing.xxs +
        lines(_EpisodeCardStyles.overview(theme), 2);
  }

  static EpisodeGridMetrics of(BuildContext context, double available) {
    final viewport = MediaQuery.sizeOf(context);
    int fit(double min) =>
        ((available + crossSpacing) / (min + crossSpacing)).floor();
    var columns = fit(minCardWidthFor(viewport));
    if (columns < 2) {
      columns = fit(compactCardWidthFor(viewport)).clamp(1, 2);
    }
    if (columns > maxColumns) columns = maxColumns;
    final cardWidth = (available - crossSpacing * (columns - 1)) / columns;
    final thumbWidth = thumbWidthIn(cardWidth, viewport);
    final thumbHeight = thumbWidth * 9 / 16;
    final text = textHeightOf(context);
    final body = text > thumbHeight ? text : thumbHeight;
    return EpisodeGridMetrics(
      columns: columns,
      cardWidth: cardWidth,
      thumbWidth: thumbWidth,
      thumbHeight: thumbHeight,
      extent: (inset * 2 + body).ceilToDouble() + 1,
    );
  }
}

abstract final class _EpisodeCardStyles {
  static TextStyle? title(AppUiThemeData theme) => theme.textTheme.titleSmall;

  static TextStyle? meta(AppUiThemeData theme) => theme.textTheme.bodySmall
      ?.copyWith(color: theme.colorScheme.onSurfaceVariant);

  static TextStyle? overview(AppUiThemeData theme) => theme.textTheme.bodyMedium
      ?.copyWith(color: theme.colorScheme.onSurfaceVariant, height: 1.5);
}

/// 分集分区:等高横排行网格(左侧 16:9 缩略图,右侧「N. 标题」、时长/首播与
/// 两行简介),可用宽度够时两列。头部左侧是「剧集」、统计与季切换器
/// ([seasonSwitcher]),右侧是 [headerAction](选集)与「更多」。
///
/// 缩略图承载状态与快捷操作:悬停浮出中央播放钮,右上角是已看切换(已看时
/// 常驻实心勾,未看时悬停/聚焦才出现),左上角是当前集播放标记,底部是续播
/// 进度。点行其余区域进入集详情,右键菜单同样可播放/标已看。
/// [error] 非空且没有剧集时,分区换成说明与重试。已有剧集时 [loadMoreError]
/// 留在网格上方,条目保持可见;[hasMore] 时网格末尾提供「加载更多」。
/// 作为 sliver 放入父级 [CustomScrollView]，分集只在视口附近构建。
class EpisodeList extends StatefulWidget {
  const EpisodeList({
    super.key,
    required this.episodes,
    required this.currentId,
    required this.revealToken,
    required this.loading,
    required this.error,
    required this.onRetry,
    required this.hasMore,
    required this.loadingMore,
    required this.onLoadMore,
    required this.headerAction,
    required this.onTap,
    required this.onPlay,
    required this.onTogglePlayed,
    required this.busyPlayedIds,
    required this.onMore,
    this.summary,
    this.seasonSwitcher,
    this.loadMoreError,
    this.onRetryLoadMore,
    this.rangeTotal = 0,
    this.onJumpToNumber,
  });

  final List<MediaItem> episodes;
  final String? currentId;
  final int revealToken;
  final bool loading;
  final MediaServerException? error;
  final VoidCallback? onRetry;
  final bool hasMore;
  final bool loadingMore;
  final VoidCallback onLoadMore;
  final MediaServerException? loadMoreError;
  final VoidCallback? onRetryLoadMore;
  final Widget headerAction;
  final ValueChanged<MediaItem> onTap;
  final ValueChanged<MediaItem> onPlay;
  final ValueChanged<MediaItem> onTogglePlayed;
  final Set<String> busyPlayedIds;
  final VoidCallback? onMore;

  /// 标题旁的小字(集数、已看进度);为空时不画。
  final String? summary;

  /// 与标题、统计同在左侧一组的季切换器;季标签放不下时它自己折叠为下拉。
  final Widget? seasonSwitcher;

  /// 本季集数。超过 [EpisodeRanges.minTotal] 且给了 [onJumpToNumber] 时，
  /// 标题行下方出现分段条，高亮的是视口里正在看的那一段。
  final int rangeTotal;
  final ValueChanged<int>? onJumpToNumber;

  @override
  State<EpisodeList> createState() => _EpisodeListState();
}

class _EpisodeListState extends State<EpisodeList> {
  final _header = GlobalKey();
  final _rows = <String, GlobalKey>{};
  int _seekGeneration = 0;
  EpisodeGridMetrics? _metrics;
  ScrollPosition? _position;

  /// 视口上部那一集的集号，决定分段条高亮哪一段。
  int? _visibleNumber;

  bool get _showRanges =>
      widget.onJumpToNumber != null && EpisodeRanges.show(widget.rangeTotal);

  @override
  void initState() {
    super.initState();
    _locate();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final position = Scrollable.maybeOf(context)?.position;
    if (!identical(position, _position)) {
      _position?.removeListener(_trackVisible);
      _position = position;
      _position?.addListener(_trackVisible);
    }
  }

  @override
  void dispose() {
    _position?.removeListener(_trackVisible);
    super.dispose();
  }

  /// 行等高，视口上部是第几行可以直接算出来，不必遍历已构建的行。
  void _trackVisible() {
    if (!_showRanges || widget.episodes.isEmpty) return;
    final header = _header.currentContext;
    final metrics = _metrics;
    final position = _position;
    if (header == null || metrics == null || position == null) return;
    final anchor = header.findRenderObject();
    if (anchor is! RenderBox || !anchor.attached || !anchor.hasSize) return;
    final start = RenderAbstractViewport.of(anchor)
        .getOffsetToReveal(anchor, 0)
        .offset;
    final gridTop = start + anchor.size.height;
    final probe = position.pixels + position.viewportDimension * .3;
    final row =
        ((probe - gridTop) / (metrics.extent + EpisodeGridMetrics.mainSpacing))
            .floor();
    final index = (row * metrics.columns).clamp(0, widget.episodes.length - 1);
    final number = widget.episodes[index].indexNumber ?? index + 1;
    final total = widget.rangeTotal;
    final current = _visibleNumber;
    if (current != null &&
        EpisodeRanges.indexOf(total, current) ==
            EpisodeRanges.indexOf(total, number)) {
      return;
    }
    setState(() => _visibleNumber = number);
  }

  /// 点了分段、但该段还没载入时记下起始集号，新窗口到达后再滚过去。
  int? _pendingRange;

  int? _indexAtOrAfter(int number) {
    for (var i = 0; i < widget.episodes.length; i++) {
      if ((widget.episodes[i].indexNumber ?? i + 1) >= number) return i;
    }
    return null;
  }

  /// 分段已在列表里就直接滚到该段第一集；没载入就请页面换窗口。
  /// 只滚动，不改「当前集」高亮——那仍是续播/下一集。
  void _jumpToRange(int start) {
    setState(() => _visibleNumber = start);
    final index = _indexAtOrAfter(start);
    final loadedFrom = widget.episodes.firstOrNull?.indexNumber ?? 1;
    if (index != null && loadedFrom <= start) {
      _pendingRange = null;
      _seekTo(index);
      return;
    }
    _pendingRange = start;
    widget.onJumpToNumber?.call(start);
  }

  void _seekTo(int index) {
    final generation = ++_seekGeneration;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _seek(index, generation, 0, force: true),
    );
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  int? get _fallbackNumber {
    for (final episode in widget.episodes) {
      if (episode.id == widget.currentId) return episode.indexNumber;
    }
    return widget.episodes.firstOrNull?.indexNumber;
  }

  @override
  void didUpdateWidget(EpisodeList oldWidget) {
    super.didUpdateWidget(oldWidget);
    final ids = widget.episodes.map((episode) => episode.id).toSet();
    _rows.removeWhere((id, _) => !ids.contains(id));
    if (oldWidget.currentId != widget.currentId ||
        oldWidget.revealToken != widget.revealToken ||
        oldWidget.episodes.indexWhere(
              (episode) => episode.id == widget.currentId,
            ) !=
            widget.episodes.indexWhere(
              (episode) => episode.id == widget.currentId,
            )) {
      _locate();
    }
    final pending = _pendingRange;
    if (pending != null && !identical(oldWidget.episodes, widget.episodes)) {
      final index = _indexAtOrAfter(pending);
      if (index != null) {
        _pendingRange = null;
        _seekTo(index);
      }
    }
  }

  void _locate() {
    final generation = ++_seekGeneration;
    final target = widget.episodes.indexWhere(
      (episode) => episode.id == widget.currentId,
    );
    if (target < 0) return;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _seek(target, generation, 0),
    );
  }

  // 网格卡片等高:由目标所在行直接算出偏移,跳过去后再把已构建的目标卡对齐。
  // 定位从不为了量高度而构建整季。
  void _seek(int target, int generation, int attempt, {bool force = false}) {
    if (!mounted || generation != _seekGeneration || attempt >= 24) return;
    if (target >= widget.episodes.length) return;
    final columns = _metrics?.columns ?? 2;
    if (!force && widget.revealToken == 0 && target < columns) {
      return;
    }
    final id = widget.episodes[target].id;
    final targetContext = _rows[id]?.currentContext;
    if (targetContext != null) {
      Scrollable.ensureVisible(targetContext, alignment: 0.25);
      return;
    }
    final header = _header.currentContext;
    final metrics = _metrics;
    if (header == null || metrics == null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _seek(target, generation, attempt + 1),
      );
      return;
    }
    final position = Scrollable.of(header).position;
    final anchor = header.findRenderObject() as RenderBox;
    final start = RenderAbstractViewport.of(anchor)
        .getOffsetToReveal(anchor, 0)
        .offset;
    final row = target ~/ metrics.columns;
    final offset =
        (start +
                anchor.size.height +
                row * (metrics.extent + EpisodeGridMetrics.mainSpacing))
            .clamp(position.minScrollExtent, position.maxScrollExtent);
    position.jumpTo(offset);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _seek(target, generation, attempt + 1, force: force),
    );
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = AppUiTheme.of(context);
    final error = widget.error;
    final loadMoreError = widget.loadMoreError;
    final empty = widget.episodes.isEmpty;
    final summary = widget.summary;
    return SliverMainAxisGroup(
      key: CatalogKeys.episodesRow,
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            key: _header,
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.page,
              AppSpacing.lg,
              AppSpacing.page,
              AppSpacing.sm,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    // 标题、统计与季切换器同在左侧一组;季切换器拿剩余宽度,
                    // 季标签放不下时折叠为「当前季 ˅」。
                    Expanded(
                      child: Row(
                        children: [
                          Text(
                            l10n.episodesRow,
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (summary != null && summary.isNotEmpty) ...[
                            const SizedBox(width: AppSpacing.sm),
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 240),
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.onSurface.withValues(
                                    alpha: .07,
                                  ),
                                  borderRadius: BorderRadius.circular(
                                    AppRadii.pill,
                                  ),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 3,
                                  ),
                                  child: Text(
                                    summary,
                                    key: const Key('episode-list-summary'),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.labelMedium
                                        ?.copyWith(
                                          color: theme
                                              .colorScheme
                                              .onSurfaceVariant,
                                          fontWeight: FontWeight.w600,
                                          fontFeatures: const [
                                            FontFeature.tabularFigures(),
                                          ],
                                        ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                          if (widget.seasonSwitcher != null) ...[
                            const SizedBox(width: AppSpacing.md),
                            Flexible(
                              child: Align(
                                alignment: AlignmentDirectional.centerStart,
                                widthFactor: 1,
                                child: widget.seasonSwitcher,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    widget.headerAction,
                    if (widget.onMore != null && error == null) ...[
                      const SizedBox(width: AppSpacing.xxs),
                      AppActionButton(
                        key: CatalogKeys.shelfMore(CatalogKeys.shelfEpisodes),
                        tier: AppActionTier.tertiary,
                        onPressed: widget.onMore,
                        label: l10n.more,
                      ),
                    ],
                  ],
                ),
                if (_showRanges && !(error != null && empty)) ...[
                  const SizedBox(height: AppSpacing.sm),
                  EpisodeRangeBar(
                    total: widget.rangeTotal,
                    activeNumber: _visibleNumber ?? _fallbackNumber,
                    onSelected: _jumpToRange,
                  ),
                ],
                if (error != null && empty)
                  AppErrorView(
                    message: catalogFailureMessage(l10n, error),
                    onRetry: widget.onRetry,
                  )
                else if (widget.loading && empty)
                  const Padding(
                    padding: EdgeInsets.only(top: AppSpacing.sm),
                    child: EpisodeListSkeleton(rows: 2),
                  ),
                if (loadMoreError != null && !empty)
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          catalogFailureMessage(l10n, loadMoreError),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (widget.onRetryLoadMore != null)
                        AppButton(
                          onPressed: widget.loadingMore
                              ? null
                              : widget.onRetryLoadMore,
                          variant: AppButtonVariant.plain,
                          child: Text(l10n.retry),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ),
        SliverPadding(
          // 行内边距让缩略图与页面边距对齐，悬停底色外扩到边距里。
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.page - EpisodeGridMetrics.inset,
          ),
          sliver: SliverLayoutBuilder(
            builder: (context, constraints) {
              final metrics = EpisodeGridMetrics.of(
                context,
                constraints.crossAxisExtent,
              );
              _metrics = metrics;
              return SliverGrid.builder(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: metrics.columns,
                  crossAxisSpacing: EpisodeGridMetrics.crossSpacing,
                  mainAxisSpacing: EpisodeGridMetrics.mainSpacing,
                  mainAxisExtent: metrics.extent,
                ),
                itemCount: widget.episodes.length,
                itemBuilder: (context, index) {
                  final episode = widget.episodes[index];
                  return KeyedSubtree(
                    key: _rows.putIfAbsent(episode.id, () => GlobalKey()),
                    child: EpisodeRow(
                      key: ValueKey('episode-row-${episode.id}'),
                      item: episode,
                      selected: episode.id == widget.currentId,
                      busyPlayed: widget.busyPlayedIds.contains(episode.id),
                      onTap: () => widget.onTap(episode),
                      onPlay: () => widget.onPlay(episode),
                      onTogglePlayed: () => widget.onTogglePlayed(episode),
                    ),
                  );
                },
              );
            },
          ),
        ),
        // 末尾放在惰性 SliverList 里：SliverToBoxAdapter 的子节点会立即构建，
        // 续载触发点就会在首帧触发，把整季一窗一窗全拉下来。
        SliverList.list(
          children: [
            Padding(
              padding: const EdgeInsets.only(
                top: AppSpacing.md,
                bottom: AppSpacing.md,
              ),
              child: widget.hasMore
                  ? AutoLoadTrigger(
                      // 滚到网格末尾附近就续载下一窗；失败后停住，等用户点重试。
                      token: widget.loadMoreError == null && !widget.loadingMore
                          ? widget.episodes.length
                          : -1,
                      onTrigger: () {
                        if (widget.loadMoreError == null &&
                            !widget.loadingMore &&
                            widget.hasMore) {
                          widget.onLoadMore();
                        }
                      },
                      child: Center(
                        child: AppButton(
                          key: CatalogKeys.episodesLoadMore,
                          onPressed: widget.loadingMore
                              ? null
                              : widget.onLoadMore,
                          variant: AppButtonVariant.outlined,
                          child: widget.loadingMore
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CupertinoActivityIndicator(),
                                )
                              : Text(l10n.episodesLoadMore),
                        ),
                      ),
                    )
                  : null,
            ),
          ],
        ),
      ],
    );
  }
}

/// 分集编号来自数据，不依赖集名前缀；三端分集卡共用这一紧凑标识。
class EpisodeNumberBadge extends StatelessWidget {
  const EpisodeNumberBadge({
    super.key,
    required this.number,
    this.selected = false,
  });

  final int? number;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final number = this.number;
    if (number == null) return const SizedBox.shrink();
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      constraints: const BoxConstraints(minWidth: 34, minHeight: 22),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: selected
            ? scheme.primary.withValues(alpha: .16)
            : scheme.onSurface.withValues(alpha: .055),
        borderRadius: BorderRadius.circular(AppRadii.sm),
        border: Border.all(
          color: selected
              ? scheme.primary.withValues(alpha: .42)
              : AppEdge.of(scheme.brightness),
        ),
      ),
      child: Text(
        'E$number',
        maxLines: 1,
        style: theme.textTheme.labelSmall?.copyWith(
          color: selected ? scheme.primary : scheme.onSurfaceVariant,
          fontWeight: FontWeight.w700,
          letterSpacing: .25,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// 分集行:左侧 16:9 缩略图,右侧独立集号、标题、时长/首播与两行简介。
///
/// 当前集:主题色描边 + 加粗标题 + 缩略图左上角播放标记;已看同时显示
/// 文字状态和缩略图实心勾。点行进集详情;缩略图中央的圆钮直接开播
/// ([CatalogKeys.episodePlay]);右上角 [CatalogKeys.episodePlayed] 切换已看。
/// 行在网格里等高,由 [EpisodeGridMetrics] 给出;单独使用时按内容收缩。
class EpisodeRow extends StatefulWidget {
  const EpisodeRow({
    super.key,
    required this.item,
    required this.selected,
    required this.busyPlayed,
    required this.onTap,
    required this.onPlay,
    required this.onTogglePlayed,
  });

  final MediaItem item;
  final bool selected;
  final bool busyPlayed;
  final VoidCallback onTap;
  final VoidCallback onPlay;
  final VoidCallback onTogglePlayed;

  /// 缩略图宽度的设计值，随阅读缩放放大。
  static double thumbWidthFor(Size viewport) =>
      EpisodeGridMetrics.thumbDesignWidthFor(viewport);

  @override
  State<EpisodeRow> createState() => _EpisodeRowState();
}

class _EpisodeRowState extends State<EpisodeRow> {
  bool _hovered = false;
  bool _focused = false;
  bool _actionFocused = false;

  Future<void> _openMenu(BuildContext context, Offset globalPosition) async {
    final l10n = AppLocalizations.of(context);
    final overlay = Navigator.of(context).overlay;
    if (overlay == null) {
      return;
    }
    final overlayBox = overlay.context.findRenderObject()! as RenderBox;
    final item = widget.item;
    final played = item.userData.played;
    final playLabel = item.canResume ? l10n.resumePlay : l10n.play;
    final action = await showAppMenu<_EpisodeRowMenuAction>(
      context: context,
      position: RelativeRect.fromLTRB(
        globalPosition.dx,
        globalPosition.dy,
        overlayBox.size.width - globalPosition.dx,
        overlayBox.size.height - globalPosition.dy,
      ),
      items: [
        AppMenuEntry(value: _EpisodeRowMenuAction.play, child: Text(playLabel)),
        AppMenuEntry(
          value: _EpisodeRowMenuAction.togglePlayed,
          child: Text(played ? l10n.markUnplayed : l10n.markPlayed),
        ),
      ],
    );
    if (action == null) {
      return;
    }
    switch (action) {
      case _EpisodeRowMenuAction.play:
        widget.onPlay();
      case _EpisodeRowMenuAction.togglePlayed:
        widget.onTogglePlayed();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    final item = widget.item;
    final selected = widget.selected;
    final playLabel = item.canResume ? l10n.resumePlay : l10n.play;
    final played = item.userData.played;
    final runtime = runtimeLabel(l10n, item);
    final premiere = item.premiereDate;
    final overview = plainOverview(item.overview);
    final revealed = _hovered || _focused || _actionFocused;
    // 每张卡都有稳定表面；当前集再用描边和集号强调，悬停只提升层次。
    final fill = selected
        ? scheme.primaryContainer.withValues(alpha: 0.58)
        : revealed
        ? scheme.surfaceContainerHighest.withValues(alpha: 0.78)
        : scheme.surfaceContainerLow.withValues(alpha: 0.52);
    final stroke = selected
        ? scheme.primary.withValues(alpha: 0.62)
        : revealed
        ? AppEdge.of(scheme.brightness, strong: true)
        : AppEdge.of(scheme.brightness);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Container(
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(AppRadii.lg),
        ),
        foregroundDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadii.lg),
          border: Border.all(color: stroke, width: selected ? 1.2 : 1),
        ),
        clipBehavior: Clip.antiAlias,
        child: AppSurfaceAction(
          key: CatalogKeys.episode(item.id),
          onTap: widget.onTap,
          onFocusChange: (value) => setState(() => _focused = value),
          onSecondaryTapDown: (details) {
            unawaited(_openMenu(context, details.globalPosition));
          },
          child: Padding(
            padding: const EdgeInsets.all(EpisodeGridMetrics.inset),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final thumbWidth = EpisodeGridMetrics.thumbWidthIn(
                  constraints.maxWidth + EpisodeGridMetrics.inset * 2,
                  MediaQuery.sizeOf(context),
                );
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: thumbWidth,
                      child: AspectRatio(
                        aspectRatio: 16 / 9,
                        child: _EpisodeThumb(
                          item: item,
                          hovered: revealed,
                          selected: selected,
                          playLabel: playLabel,
                          onPlay: widget.onPlay,
                          played: played,
                          busyPlayed: widget.busyPlayed,
                          onTogglePlayed: widget.onTogglePlayed,
                          onActionFocusChange: (value) =>
                              setState(() => _actionFocused = value),
                        ),
                      ),
                    ),
                    const SizedBox(width: EpisodeGridMetrics.textGap),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              EpisodeNumberBadge(
                                key: ValueKey('episode-number-${item.id}'),
                                number: item.indexNumber,
                                selected: selected,
                              ),
                              if (item.indexNumber != null)
                                const SizedBox(width: AppSpacing.xs),
                              Expanded(
                                child: Text(
                                  item.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: _EpisodeCardStyles.title(theme)
                                      ?.copyWith(
                                        fontWeight: selected
                                            ? FontWeight.w700
                                            : FontWeight.w600,
                                        color: played && !selected
                                            ? scheme.onSurfaceVariant
                                            : scheme.onSurface,
                                      ),
                                ),
                              ),
                            ],
                          ),
                          if (runtime != null ||
                              premiere != null ||
                              played) ...[
                            const SizedBox(height: 2),
                            _EpisodeMetaLine(
                              runtime: runtime,
                              premiere: premiere == null
                                  ? null
                                  : formatDateYmd(premiere),
                              watched: played,
                            ),
                          ],
                          if (overview != null && overview.isNotEmpty) ...[
                            const SizedBox(height: AppSpacing.xxs),
                            Text(
                              overview,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: _EpisodeCardStyles.overview(theme),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// 时长与首播日期一行;两段各自是独立文字,日期过长时省略。
class _EpisodeMetaLine extends StatelessWidget {
  const _EpisodeMetaLine({this.runtime, this.premiere, this.watched = false});

  final String? runtime;
  final String? premiere;
  final bool watched;

  @override
  Widget build(BuildContext context) {
    final style = _EpisodeCardStyles.meta(AppUiTheme.of(context))
        ?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
    final runtime = this.runtime;
    final premiere = this.premiere;
    final theme = AppUiTheme.of(context);
    return Row(
      children: [
        if (runtime != null) Text(runtime, maxLines: 1, style: style),
        if (runtime != null && premiere != null)
          Text(' · ', maxLines: 1, style: style),
        if (premiere != null)
          Flexible(
            child: Text(
              premiere,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
        if (watched) ...[
          if (runtime != null || premiere != null)
            Text(' · ', maxLines: 1, style: style),
          Icon(
            CupertinoIcons.checkmark_circle_fill,
            size: 12,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 3),
          Text(
            AppLocalizations.of(context).watchedAction,
            maxLines: 1,
            style: style?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ],
    );
  }
}

enum _EpisodeRowMenuAction { play, togglePlayed }

/// 分集缩略图:左上当前集标记、底部续播进度、右上已看切换;悬停时压暗并
/// 浮出中央播放钮,点它直接开播(点行其余区域,包括缩略图,进集详情)。
class _EpisodeThumb extends StatelessWidget {
  const _EpisodeThumb({
    required this.item,
    required this.hovered,
    required this.selected,
    required this.playLabel,
    required this.onPlay,
    required this.played,
    required this.busyPlayed,
    required this.onTogglePlayed,
    required this.onActionFocusChange,
  });

  final MediaItem item;
  final bool hovered;
  final bool selected;
  final String playLabel;
  final VoidCallback onPlay;
  final bool played;
  final bool busyPlayed;
  final VoidCallback onTogglePlayed;
  final ValueChanged<bool> onActionFocusChange;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = AppUiTheme.of(context).colorScheme;
    final resumable = item.canResume;
    final fade = AppMotion.durationOf(context, AppMotion.normal);
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight;
        final width = constraints.maxWidth;
        return DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadii.md),
            border: Border.all(color: AppEdge.of(scheme.brightness)),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadii.md),
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(color: scheme.surfaceContainerHigh),
                RepaintBoundary(
                  child: AnimatedScale(
                    scale: hovered ? 1.04 : 1,
                    duration: fade,
                    curve: AppMotion.standard,
                    child: MediaImage(
                      key: ValueKey(item.id),
                      item: item,
                      width: width,
                      height: height,
                      preferThumb: true,
                      fit: BoxFit.cover,
                      maxWidth: 640,
                    ),
                  ),
                ),
                IgnorePointer(
                  child: AnimatedContainer(
                    duration: fade,
                    color: AppInk.black.withValues(
                      alpha: hovered
                          ? .36
                          : played && !selected
                          ? .22
                          : 0,
                    ),
                  ),
                ),
                // 当前集不只靠底色:缩略图左上角常驻播放标记。
                if (selected)
                  const Positioned(
                    top: 6,
                    left: 6,
                    child: IgnorePointer(child: EpisodeCurrentMark(size: 12)),
                  ),
                // 只有中央的圆钮开播；卡片其余位置（含剧照）进入集详情。
                Center(
                  child: AnimatedOpacity(
                    opacity: hovered ? 1 : 0,
                    duration: fade,
                    child: AnimatedScale(
                      scale: hovered ? 1 : .85,
                      duration: fade,
                      curve: AppMotion.standard,
                      child: AppTooltip(
                        message: playLabel,
                        child: Container(
                          decoration: BoxDecoration(
                            color: scheme.brightness == Brightness.light
                                ? scheme.primary
                                : AppInk.white,
                            shape: BoxShape.circle,
                          ),
                          key: CatalogKeys.episodePlay(item.id),
                          clipBehavior: Clip.antiAlias,
                          child: AppSurfaceAction(
                            key: ValueKey('episode-thumb-play-${item.id}'),
                            canRequestFocus: hovered,
                            onFocusChange: onActionFocusChange,
                            borderRadius: BorderRadius.circular(AppRadii.pill),
                            onTap: onPlay,
                            child: Padding(
                              padding: EdgeInsets.all(height * .06),
                              child: Icon(
                                AppIcons.play,
                                fill: AppIcons.filled,
                                color: scheme.brightness == Brightness.light
                                    ? scheme.onPrimary
                                    : AppInk.black,
                                size: height * .22,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: 2,
                  right: 2,
                  child: AnimatedOpacity(
                    // 未看的勾平时隐去,悬停/聚焦再出现;已看的实心勾常驻。
                    opacity: played || hovered ? 1 : 0,
                    duration: AppMotion.durationOf(context, AppMotion.fast),
                    child: Focus(
                      canRequestFocus: played || hovered,
                      skipTraversal: true,
                      onFocusChange: onActionFocusChange,
                      child: AppIconButton(
                        key: CatalogKeys.episodePlayed(item.id),
                        tooltip: played ? l10n.markUnplayed : l10n.markPlayed,
                        style: AppButtonStyle(
                          minimumSize: const Size(32, 32),
                          padding: const EdgeInsets.all(4),
                        ),
                        onPressed: busyPlayed ? null : onTogglePlayed,
                        icon: played
                            ? const EpisodeWatchedBadge()
                            : DecoratedBox(
                                decoration: BoxDecoration(
                                  color: AppInk.black.withValues(alpha: .6),
                                  shape: BoxShape.circle,
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.all(2),
                                  child: Icon(
                                    CupertinoIcons.check_mark,
                                    size: 16,
                                    color: AppInk.white.withValues(alpha: .7),
                                  ),
                                ),
                              ),
                      ),
                    ),
                  ),
                ),
                if (resumable)
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: _EpisodeProgressBar(
                      key: ValueKey('episode-progress-${item.id}'),
                      value: item.playbackProgress,
                      label: l10n.playbackProgress(
                        (item.playbackProgress * 100).round(),
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

/// 缩略图上的深底白字小胶囊(时长等),亮画面上也能读清。
class EpisodeThumbBadge extends StatelessWidget {
  const EpisodeThumbBadge({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppInk.black.withValues(alpha: .66),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        child: Text(
          label,
          maxLines: 1,
          style: AppUiTheme.of(context).textTheme.labelSmall?.copyWith(
            color: AppInk.white,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }
}

/// 当前集标记:实心圆底上的播放图标,亮暗剧照都能看清。
class EpisodeCurrentMark extends StatelessWidget {
  const EpisodeCurrentMark({super.key, this.size = 22, this.iconKey});

  final double size;
  final Key? iconKey;

  @override
  Widget build(BuildContext context) {
    final scheme = AppUiTheme.of(context).colorScheme;
    final light = scheme.brightness == Brightness.light;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: light ? scheme.primary : AppInk.black.withValues(alpha: .86),
        shape: BoxShape.circle,
        border: light
            ? null
            : Border.all(
                color: AppInk.white.withValues(alpha: .92),
                width: (size * .07).clamp(1.5, 2.5).toDouble(),
              ),
      ),
      child: Padding(
        padding: EdgeInsets.all(size * .28),
        child: Icon(
          AppIcons.play,
          key: iconKey,
          fill: AppIcons.filled,
          size: size,
          color: light ? scheme.onPrimary : AppInk.white,
        ),
      ),
    );
  }
}

/// 已看角标:深色圆底上的勾,不依赖画面明暗。
class EpisodeWatchedBadge extends StatelessWidget {
  const EpisodeWatchedBadge({super.key, this.size = 16, this.iconKey});

  final double size;
  final Key? iconKey;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: AppLocalizations.of(context).mobileWatched,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppInk.black.withValues(alpha: .6),
          shape: BoxShape.circle,
        ),
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Icon(
            CupertinoIcons.check_mark,
            key: iconKey,
            size: size,
            color: AppInk.white.withValues(alpha: .95),
          ),
        ),
      ),
    );
  }
}

/// 分集网格加载骨架:与 [EpisodeRow] 同几何的横排行占位。
class EpisodeListSkeleton extends StatelessWidget {
  const EpisodeListSkeleton({super.key, this.rows = 1});

  /// 骨架行数。
  final int rows;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final metrics = EpisodeGridMetrics.of(context, available);
        final textWidth =
            metrics.cardWidth -
            metrics.thumbWidth -
            EpisodeGridMetrics.inset * 2 -
            EpisodeGridMetrics.textGap;
        return Column(
          children: [
            for (var row = 0; row < rows; row++)
              Padding(
                padding: const EdgeInsets.only(
                  bottom: EpisodeGridMetrics.mainSpacing,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var i = 0; i < metrics.columns; i++) ...[
                      if (i > 0)
                        const SizedBox(width: EpisodeGridMetrics.crossSpacing),
                      SizedBox(
                        width: metrics.cardWidth,
                        height: metrics.extent,
                        child: Padding(
                          padding: const EdgeInsets.all(
                            EpisodeGridMetrics.inset,
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SkeletonBlock(
                                width: metrics.thumbWidth,
                                height: metrics.thumbHeight,
                              ),
                              const SizedBox(width: EpisodeGridMetrics.textGap),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  SkeletonBlock(
                                    width: textWidth * .6,
                                    height: AppSpacing.md,
                                  ),
                                  const SizedBox(height: AppSpacing.xs),
                                  SkeletonBlock(
                                    width: textWidth * .35,
                                    height: AppSpacing.sm,
                                  ),
                                  const SizedBox(height: AppSpacing.xs),
                                  SkeletonBlock(
                                    width: textWidth * .9,
                                    height: AppSpacing.sm,
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

class _EpisodeProgressBar extends StatelessWidget {
  const _EpisodeProgressBar({
    super.key,
    required this.value,
    required this.label,
  });

  final double value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: label,
      child: SizedBox(
        height: 3,
        child: ColoredBox(
          color: AppInk.black.withValues(alpha: 0.45),
          child: Align(
            alignment: Alignment.centerLeft,
            child: FractionallySizedBox(
              widthFactor: value.clamp(0.0, 1.0),
              child: ColoredBox(
                color: AppUiTheme.of(context).colorScheme.primary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
