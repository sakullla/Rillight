import 'dart:async';

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
import 'package:rillight/library/item_format.dart';
import 'package:rillight/media_image/media_image.dart';

/// 分集网格的几何：列数、卡宽与固定的卡高。
///
/// 卡高由剧照高度加标题、日期和两行简介的实际行高算出，同一季每张卡等高，
/// 网格不必构建屏外的卡片就能定位到任意一集。
class EpisodeGridMetrics {
  const EpisodeGridMetrics({
    required this.columns,
    required this.cardWidth,
    required this.thumbHeight,
    required this.extent,
  });

  /// 卡片之间的横向/纵向间距。
  static const double crossSpacing = AppSpacing.md;
  static const double mainSpacing = AppSpacing.sm;

  /// 卡片内边距：悬停/当前集底色比剧照外扩一圈。
  static const double inset = AppSpacing.xs;

  final int columns;
  final double cardWidth;
  final double thumbHeight;
  final double extent;

  /// 最窄卡宽（1080p 设计值），宽屏随阅读缩放一起变大。
  static double minCardWidthFor(Size viewport) =>
      272 * AppViewport.readingScaleOf(viewport);

  static EpisodeGridMetrics of(BuildContext context, double available) {
    final viewport = MediaQuery.sizeOf(context);
    final min = minCardWidthFor(viewport);
    var columns = ((available + crossSpacing) / (min + crossSpacing)).floor();
    if (columns < 1) columns = 1;
    if (columns > 6) columns = 6;
    final cardWidth = (available - crossSpacing * (columns - 1)) / columns;
    final thumbWidth = cardWidth - inset * 2;
    final thumbHeight = thumbWidth * 9 / 16;
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

    final text =
        AppSpacing.xs +
        lines(_EpisodeCardStyles.title(theme), 1) +
        2 +
        lines(_EpisodeCardStyles.meta(theme), 1) +
        AppSpacing.xxs +
        lines(_EpisodeCardStyles.overview(theme), 2);
    return EpisodeGridMetrics(
      columns: columns,
      cardWidth: cardWidth,
      thumbHeight: thumbHeight,
      extent: (inset * 2 + thumbHeight + text).ceilToDouble() + 1,
    );
  }
}

abstract final class _EpisodeCardStyles {
  static TextStyle? title(AppUiThemeData theme) =>
      theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600);

  static TextStyle? meta(AppUiThemeData theme) => theme.textTheme.bodySmall
      ?.copyWith(color: theme.colorScheme.onSurfaceVariant);

  static TextStyle? overview(AppUiThemeData theme) => theme.textTheme.bodySmall
      ?.copyWith(color: theme.colorScheme.onSurfaceVariant, height: 1.4);
}

/// 分集分区:响应式卡片网格(16:9 剧照 + 「N. 标题」+ 播出日期 + 两行简介),
/// 头部为「剧集」+ 季切换/选集 + 「更多」。宽窗口一行四五集,一季一眼扫完,
/// 不再是一条条横贯整屏、播放钮远在行尾的长行。
///
/// 剧照承载全部状态与快捷操作:悬停浮出中央播放钮,右上角是
/// 已看切换(已看时常驻实心勾,未看时悬停/聚焦才出现),底部是时长与续播进度。
/// 点卡片其余区域进入集详情,右键菜单同样可播放/标已看。
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
    this.loadMoreError,
    this.onRetryLoadMore,
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

  /// 标题下的一行小字(集数、已看进度);为空时不占行。
  final String? summary;

  @override
  State<EpisodeList> createState() => _EpisodeListState();
}

class _EpisodeListState extends State<EpisodeList> {
  final _header = GlobalKey();
  final _rows = <String, GlobalKey>{};
  int _seekGeneration = 0;
  EpisodeGridMetrics? _metrics;

  @override
  void initState() {
    super.initState();
    _locate();
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
  void _seek(int target, int generation, int attempt) {
    if (!mounted || generation != _seekGeneration || attempt >= 24) return;
    if (target >= widget.episodes.length) return;
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
      (_) => _seek(target, generation, attempt + 1),
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
                    Expanded(
                      child: Wrap(
                        spacing: AppSpacing.sm,
                        crossAxisAlignment: WrapCrossAlignment.end,
                        children: [
                          Text(
                            l10n.episodesRow,
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (summary != null && summary.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 2),
                              child: Text(
                                summary,
                                key: const Key('episode-list-summary'),
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    widget.headerAction,
                    if (widget.onMore != null && error == null)
                      AppButton(
                        key: CatalogKeys.shelfMore(CatalogKeys.shelfEpisodes),
                        onPressed: widget.onMore,
                        style: AppButtonStyle(
                          foregroundColor: theme.colorScheme.onSurfaceVariant,
                          textStyle: theme.textTheme.labelLarge,
                        ),
                        variant: AppButtonVariant.plain,
                        child: Text(l10n.more),
                      ),
                  ],
                ),
                if (error != null && empty)
                  AppErrorView(
                    message: catalogFailureMessage(l10n, error),
                    onRetry: widget.onRetry,
                  )
                else if (widget.loading && empty)
                  const Padding(
                    padding: EdgeInsets.only(top: AppSpacing.sm),
                    child: EpisodeListSkeleton(),
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
          // 卡片内边距让剧照与页面边距对齐，悬停底色外扩到边距里。
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
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(
              top: AppSpacing.md,
              bottom: AppSpacing.md,
            ),
            child: widget.hasMore
                ? Center(
                    child: AppButton(
                      key: CatalogKeys.episodesLoadMore,
                      onPressed: widget.loadingMore ? null : widget.onLoadMore,
                      variant: AppButtonVariant.outlined,
                      child: widget.loadingMore
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CupertinoActivityIndicator(),
                            )
                          : Text(l10n.episodesLoadMore),
                    ),
                  )
                : null,
          ),
        ),
      ],
    );
  }
}

/// 分集卡:16:9 剧照在上,「N. 标题」、播出日期与两行简介在下。
///
/// 当前集:剧照主色描边 + 主色标题;已看:标题转次要色,剧照右上角实心勾。
/// 点卡片进集详情;剧照中央的圆钮直接开播([CatalogKeys.episodePlay]);右上角
/// [CatalogKeys.episodePlayed] 切换已看。卡片在网格里等高,由
/// [EpisodeGridMetrics] 给出;单独使用时按内容收缩。
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

  /// 网格最窄的剧照宽，骨架与旧调用方沿用。
  static double thumbWidthFor(Size viewport) =>
      EpisodeGridMetrics.minCardWidthFor(viewport) -
      EpisodeGridMetrics.inset * 2;

  @override
  State<EpisodeRow> createState() => _EpisodeRowState();
}

class _EpisodeRowState extends State<EpisodeRow> {
  bool _hovered = false;
  bool _focused = false;

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
    final title = numberedEpisodeTitle(item);
    final playLabel = item.canResume ? l10n.resumePlay : l10n.play;
    final played = item.userData.played;
    final runtime = runtimeLabel(l10n, item);
    final premiere = item.premiereDate;
    final overview = plainOverview(item.overview);
    final revealed = _hovered || _focused;
    final fill = revealed
        ? scheme.surfaceContainerHighest.withValues(alpha: 0.5)
        : const Color(0x00000000);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Container(
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(AppRadii.lg),
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                AspectRatio(
                  aspectRatio: 16 / 9,
                  child: _EpisodeThumb(
                    item: item,
                    runtime: runtime,
                    hovered: revealed,
                    selected: selected,
                    playLabel: playLabel,
                    onPlay: widget.onPlay,
                    played: played,
                    busyPlayed: widget.busyPlayed,
                    onTogglePlayed: widget.onTogglePlayed,
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _EpisodeCardStyles.title(theme)?.copyWith(
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                    color: selected
                        ? scheme.primary
                        : played
                        ? scheme.onSurfaceVariant
                        : scheme.onSurface,
                  ),
                ),

                if (premiere != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    formatDateYmd(premiere),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _EpisodeCardStyles.meta(theme)?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
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
        ),
      ),
    );
  }
}

enum _EpisodeRowMenuAction { play, togglePlayed }

/// 分集剧照:右下时长胶囊、底部续播进度、右上已看切换;悬停时压暗并浮出
/// 中央播放钮,点它直接开播(点卡片其余区域,包括剧照,进集详情)。
class _EpisodeThumb extends StatelessWidget {
  const _EpisodeThumb({
    required this.item,
    required this.runtime,
    required this.hovered,
    required this.selected,
    required this.playLabel,
    required this.onPlay,
    required this.played,
    required this.busyPlayed,
    required this.onTogglePlayed,
  });

  final MediaItem item;
  final String? runtime;
  final bool hovered;
  final bool selected;
  final String playLabel;
  final VoidCallback onPlay;
  final bool played;
  final bool busyPlayed;
  final VoidCallback onTogglePlayed;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = AppUiTheme.of(context).colorScheme;
    final resumable = item.canResume;
    final fade = AppMotion.durationOf(context, AppMotion.normal);
    final runtime = this.runtime;
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight;
        final width = constraints.maxWidth;
        return DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadii.md),
            border: selected
                ? Border.all(color: scheme.primary, width: 2)
                : Border.all(color: scheme.onSurface.withValues(alpha: .08)),
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
                    color: const Color(0xff000000).withValues(
                      alpha: hovered
                          ? .36
                          : played && !selected
                          ? .22
                          : 0,
                    ),
                  ),
                ),
                if (runtime != null)
                  Positioned(
                    right: 6,
                    bottom: resumable ? 9 : 6,
                    child: EpisodeThumbBadge(label: runtime),
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
                          decoration: BoxDecoration(color: scheme.primary),
                          key: CatalogKeys.episodePlay(item.id),
                          clipBehavior: Clip.antiAlias,
                          child: AppSurfaceAction(
                            key: ValueKey('episode-thumb-play-${item.id}'),
                            canRequestFocus: false,
                            onTap: onPlay,
                            child: Padding(
                              padding: EdgeInsets.all(height * .06),
                              child: Icon(
                                CupertinoIcons.play_fill,
                                color: scheme.onPrimary,
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
                                color: const Color(0xff000000)
                                    .withValues(alpha: .6),
                                shape: BoxShape.circle,
                              ),
                              child: Padding(
                                padding: const EdgeInsets.all(2),
                                child: Icon(
                                  CupertinoIcons.check_mark,
                                  size: 16,
                                  color: const Color(0xffffffff)
                                      .withValues(alpha: .7),
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
        color: const Color(0xff000000).withValues(alpha: .66),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        child: Text(
          label,
          maxLines: 1,
          style: AppUiTheme.of(context).textTheme.labelSmall?.copyWith(
            color: const Color(0xffffffff),
            fontWeight: FontWeight.w600,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
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
          color: const Color(0xff000000).withValues(alpha: .6),
          shape: BoxShape.circle,
        ),
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Icon(
            CupertinoIcons.check_mark,
            key: iconKey,
            size: size,
            color: const Color(0xffffffff).withValues(alpha: .95),
          ),
        ),
      ),
    );
  }
}

/// 分集网格加载骨架:与 [EpisodeRow] 同几何的一行卡片占位。
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
        return Column(
          children: [
            for (var row = 0; row < rows; row++)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.md),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var i = 0; i < metrics.columns; i++) ...[
                      if (i > 0)
                        const SizedBox(width: EpisodeGridMetrics.crossSpacing),
                      SizedBox(
                        width: metrics.cardWidth,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SkeletonBlock(
                              width: metrics.cardWidth,
                              height: metrics.cardWidth * 9 / 16,
                            ),
                            const SizedBox(height: AppSpacing.xs),
                            SkeletonBlock(
                              width: metrics.cardWidth * .7,
                              height: AppSpacing.md,
                            ),
                            const SizedBox(height: AppSpacing.xs),
                            SkeletonBlock(
                              width: metrics.cardWidth * .4,
                              height: AppSpacing.sm,
                            ),
                          ],
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
          color: const Color(0xff000000).withValues(alpha: 0.45),
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
