import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/widgets/app_error_view.dart';
import 'package:rillight/app/widgets/skeleton.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_failure.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/library/item_format.dart';
import 'package:rillight/media_image/media_image.dart';

/// 分集分区:响应式网格卡片,头部为「集」+ 季切换/选集 + 「更多」。
///
/// 列数按 [targetCardWidth] 目标卡宽铺满可用宽度;窗口宽度低于
/// [AppBreakpoints.compact] 时降为单列。[error] 非空时在分区内显示错误
/// 与重试;[hasMore] 时网格末尾提供「加载更多」追加下一窗。
class EpisodeGrid extends StatelessWidget {
  const EpisodeGrid({
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
  });

  final List<EmbyItem> episodes;
  final String? currentId;
  final int revealToken;
  final bool loading;
  final EmbyException? error;
  final VoidCallback? onRetry;
  final bool hasMore;
  final bool loadingMore;
  final VoidCallback onLoadMore;
  final Widget headerAction;
  final ValueChanged<EmbyItem> onTap;
  final ValueChanged<EmbyItem> onPlay;
  final ValueChanged<EmbyItem> onTogglePlayed;
  final Set<String> busyPlayedIds;
  final VoidCallback? onMore;

  /// 目标卡片宽:列数 = 可用宽 / 目标宽 向下取整,宽屏多列填满。
  static const double targetCardWidth = 340;

  /// 网格列间距。
  static const double spacing = AppSpacing.md;

  /// 网格行间距。
  static const double runSpacing = AppSpacing.lg;

  /// 列数:窗口低于紧凑断点强制单列,否则按目标卡宽铺满可用宽度。
  static int columnsFor(double availableWidth, double screenWidth) {
    if (screenWidth < AppBreakpoints.compact) {
      return 1;
    }
    return math.max(1, (availableWidth / targetCardWidth).floor());
  }

  /// 卡宽:列间距均分后每列恰好铺满可用宽度。
  static double cardWidthFor(double availableWidth, int columns) {
    return (availableWidth - spacing * (columns - 1)) / columns;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final error = this.error;
    return Padding(
      key: CatalogKeys.episodesRow,
      padding: const EdgeInsets.only(top: AppSpacing.md, bottom: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.episodesRow,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                headerAction,
                if (onMore != null && error == null)
                  TextButton(
                    key: CatalogKeys.shelfMore(CatalogKeys.shelfEpisodes),
                    onPressed: onMore,
                    style: TextButton.styleFrom(
                      foregroundColor: theme.colorScheme.onSurfaceVariant,
                      textStyle: theme.textTheme.labelLarge,
                    ),
                    child: Text(l10n.more),
                  ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          if (error != null)
            AppErrorView(
              message: catalogFailureMessage(l10n, error),
              onRetry: onRetry,
            )
          else if (loading && episodes.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: AppSpacing.page),
              child: EpisodeGridSkeleton(),
            )
          else ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final screenWidth = MediaQuery.sizeOf(context).width;
                  final columns = columnsFor(constraints.maxWidth, screenWidth);
                  final cardWidth = cardWidthFor(constraints.maxWidth, columns);
                  return Wrap(
                    spacing: spacing,
                    runSpacing: runSpacing,
                    children: [
                      for (final episode in episodes)
                        SizedBox(
                          key: ValueKey('episode-card-${episode.id}'),
                          width: cardWidth,
                          child: _EnsureVisibleWhenSelected(
                            selected: episode.id == currentId,
                            token: revealToken,
                            child: EpisodeCard(
                              item: episode,
                              selected: episode.id == currentId,
                              busyPlayed: busyPlayedIds.contains(episode.id),
                              onTap: () => onTap(episode),
                              onPlay: () => onPlay(episode),
                              onTogglePlayed: () => onTogglePlayed(episode),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
            if (hasMore)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.sm),
                child: Center(
                  child: OutlinedButton(
                    key: CatalogKeys.episodesLoadMore,
                    onPressed: loadingMore ? null : onLoadMore,
                    child: loadingMore
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(l10n.episodesLoadMore),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// 分集卡片:16:9 缩略图(进度条叠底、右下播放钮、右上已看勾选)+
/// 「N. 标题」+ 时长/进度。点卡片进入集详情,右键菜单同样可播放/标已看。
/// 当前集以 surfaceContainerHigh 底色与 primary 描边标示。
class EpisodeCard extends StatefulWidget {
  const EpisodeCard({
    super.key,
    required this.item,
    required this.selected,
    required this.busyPlayed,
    required this.onTap,
    required this.onPlay,
    required this.onTogglePlayed,
  });

  final EmbyItem item;
  final bool selected;
  final bool busyPlayed;
  final VoidCallback onTap;
  final VoidCallback onPlay;
  final VoidCallback onTogglePlayed;

  @override
  State<EpisodeCard> createState() => _EpisodeCardState();
}

class _EpisodeCardState extends State<EpisodeCard> {
  bool _hovered = false;

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
    final action = await showMenu<_EpisodeCardMenuAction>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(globalPosition.dx, globalPosition.dy, 0, 0),
        Offset.zero & overlayBox.size,
      ),
      items: [
        PopupMenuItem(
          value: _EpisodeCardMenuAction.play,
          child: Text(playLabel),
        ),
        PopupMenuItem(
          value: _EpisodeCardMenuAction.togglePlayed,
          child: Text(played ? l10n.markUnplayed : l10n.markPlayed),
        ),
      ],
    );
    if (action == null) {
      return;
    }
    switch (action) {
      case _EpisodeCardMenuAction.play:
        widget.onPlay();
      case _EpisodeCardMenuAction.togglePlayed:
        widget.onTogglePlayed();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final item = widget.item;
    final selected = widget.selected;
    final number = item.indexNumber;
    final title = number == null ? item.name : '$number. ${item.name}';
    final progress = item.playbackProgress;
    final playLabel = item.canResume ? l10n.resumePlay : l10n.play;
    final played = item.userData.played;
    final meta = <String>[
      ?runtimeLabel(l10n, item),
      if (item.canResume) l10n.playbackProgress((progress * 100).round()),
    ];
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadii.md),
        child: Material(
          color: selected ? scheme.surfaceContainerHigh : Colors.transparent,
          child: InkWell(
            key: CatalogKeys.episode(item.id),
            onTap: widget.onTap,
            onSecondaryTapDown: (details) {
              unawaited(_openMenu(context, details.globalPosition));
            },
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadii.md),
                border: Border.all(
                  width: 2,
                  color: selected ? scheme.primary : Colors.transparent,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.sm),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AspectRatio(
                      aspectRatio: 16 / 9,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(AppRadii.sm),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            RepaintBoundary(
                              child: MediaImage(
                                key: ValueKey(item.id),
                                item: item,
                                preferThumb: true,
                                maxWidth: 480,
                              ),
                            ),
                            if (progress > 0)
                              Align(
                                alignment: Alignment.bottomCenter,
                                child: _EpisodeProgressBar(value: progress),
                              ),
                            // 播放钮常驻可点(测试/键盘可达),悬停或选中时抬亮。
                            Positioned(
                              right: AppSpacing.xs,
                              bottom: AppSpacing.xs,
                              child: AnimatedOpacity(
                                opacity: _hovered || selected ? 1 : 0.72,
                                duration: AppMotion.durationOf(
                                  context,
                                  AppMotion.fast,
                                ),
                                curve: AppMotion.standard,
                                child: IconButton.filled(
                                  key: CatalogKeys.episodePlay(item.id),
                                  tooltip: playLabel,
                                  onPressed: widget.onPlay,
                                  icon: const Icon(Icons.play_arrow_rounded),
                                ),
                              ),
                            ),
                            Positioned(
                              top: AppSpacing.xxs,
                              right: AppSpacing.xxs,
                              child: IconButton(
                                key: CatalogKeys.episodePlayed(item.id),
                                tooltip: played
                                    ? l10n.markUnplayed
                                    : l10n.markPlayed,
                                onPressed: widget.busyPlayed
                                    ? null
                                    : widget.onTogglePlayed,
                                style: IconButton.styleFrom(
                                  backgroundColor: Colors.black.withValues(
                                    alpha: 0.45,
                                  ),
                                  foregroundColor: Colors.white,
                                  minimumSize: const Size(36, 36),
                                  padding: const EdgeInsets.all(AppSpacing.xxs),
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                ),
                                icon: Icon(
                                  played
                                      ? Icons.check_circle_rounded
                                      : Icons.check_circle_outline_rounded,
                                  color: played ? scheme.primary : null,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: selected ? FontWeight.w700 : null,
                      ),
                    ),
                    if (meta.isNotEmpty) ...[
                      const SizedBox(height: AppSpacing.xxs),
                      Text(
                        meta.join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum _EpisodeCardMenuAction { play, togglePlayed }

/// 分集网格加载骨架:与 [EpisodeGrid] 同列数同卡宽的占位卡片。
class EpisodeGridSkeleton extends StatelessWidget {
  const EpisodeGridSkeleton({super.key, this.rows = 2});

  /// 骨架行数。
  final int rows;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final screenWidth = MediaQuery.sizeOf(context).width;
        final columns = EpisodeGrid.columnsFor(
          constraints.maxWidth,
          screenWidth,
        );
        final cardWidth = EpisodeGrid.cardWidthFor(
          constraints.maxWidth,
          columns,
        );
        return Wrap(
          spacing: EpisodeGrid.spacing,
          runSpacing: EpisodeGrid.runSpacing,
          children: [
            for (var i = 0; i < columns * rows; i++)
              SizedBox(width: cardWidth, child: const _EpisodeCardSkeleton()),
          ],
        );
      },
    );
  }
}

class _EpisodeCardSkeleton extends StatelessWidget {
  const _EpisodeCardSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.all(AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(aspectRatio: 16 / 9, child: SkeletonBlock()),
          SizedBox(height: AppSpacing.xs),
          FractionallySizedBox(
            widthFactor: 0.62,
            child: SkeletonBlock(height: AppSpacing.md),
          ),
          SizedBox(height: AppSpacing.xs),
          FractionallySizedBox(
            widthFactor: 0.38,
            child: SkeletonBlock(height: AppSpacing.sm),
          ),
        ],
      ),
    );
  }
}

/// 当前集变化后滚入可视区(含选集跳到已在网格中的集)。
class _EnsureVisibleWhenSelected extends StatefulWidget {
  const _EnsureVisibleWhenSelected({
    required this.selected,
    required this.token,
    required this.child,
  });

  final bool selected;
  final int token;
  final Widget child;

  @override
  State<_EnsureVisibleWhenSelected> createState() =>
      _EnsureVisibleWhenSelectedState();
}

class _EnsureVisibleWhenSelectedState
    extends State<_EnsureVisibleWhenSelected> {
  @override
  void initState() {
    super.initState();
    if (widget.selected) {
      _schedule();
    }
  }

  @override
  void didUpdateWidget(_EnsureVisibleWhenSelected oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selected &&
        (!oldWidget.selected || oldWidget.token != widget.token)) {
      _schedule();
    }
  }

  void _schedule() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      Scrollable.ensureVisible(
        context,
        alignment: 0.25,
        duration: AppMotion.durationOf(context, AppMotion.fast),
        curve: AppMotion.standard,
      );
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
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
