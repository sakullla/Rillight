import 'dart:async';

import 'package:flutter/material.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/widgets/app_error_view.dart';
import 'package:rillight/app/widgets/skeleton.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_failure.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/library/episode_detail_sections.dart';
import 'package:rillight/library/item_format.dart';
import 'package:rillight/media_image/media_image.dart';

/// 分集分区:纵向行列表(缩略图 + 标题 + 时长/进度 + 简介),头部为
/// 「集」+ 季切换/选集 + 「更多」。行内容自适应伸展铺满可用宽度。
///
/// 播放和已看一直留在行尾,方便扫视一季时直接开播或标已看。
/// [error] 非空且没有剧集时,分区换成说明与重试。已有剧集时 [loadMoreError]
/// 留在列表上方,条目保持可见;[hasMore] 时列表末尾提供「加载更多」。
class EpisodeList extends StatelessWidget {
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
    this.loadMoreError,
    this.onRetryLoadMore,
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
  final EmbyException? loadMoreError;
  final VoidCallback? onRetryLoadMore;
  final Widget headerAction;
  final ValueChanged<EmbyItem> onTap;
  final ValueChanged<EmbyItem> onPlay;
  final ValueChanged<EmbyItem> onTogglePlayed;
  final Set<String> busyPlayedIds;
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final error = this.error;
    final loadMoreError = this.loadMoreError;
    return Padding(
      key: CatalogKeys.episodesRow,
      padding: const EdgeInsets.only(top: AppSpacing.md, bottom: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
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
          if (error != null && episodes.isEmpty)
            AppErrorView(
              message: catalogFailureMessage(l10n, error),
              onRetry: onRetry,
            )
          else if (loading && episodes.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: AppSpacing.page),
              child: EpisodeListSkeleton(),
            )
          else ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (loadMoreError != null) ...[
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            catalogFailureMessage(l10n, loadMoreError),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (onRetryLoadMore != null)
                          TextButton(
                            onPressed: loadingMore ? null : onRetryLoadMore,
                            child: Text(l10n.retry),
                          ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.sm),
                  ],
                  for (final episode in episodes)
                    _EnsureVisibleWhenSelected(
                      selected: episode.id == currentId,
                      token: revealToken,
                      child: RepaintBoundary(
                        child: EpisodeRow(
                          key: ValueKey('episode-row-${episode.id}'),
                          item: episode,
                          selected: episode.id == currentId,
                          busyPlayed: busyPlayedIds.contains(episode.id),
                          onTap: () => onTap(episode),
                          onPlay: () => onPlay(episode),
                          onTogglePlayed: () => onTogglePlayed(episode),
                        ),
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
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Text(l10n.episodesLoadMore),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 分集行:16:9 缩略图(进度条叠底) + 「N. 标题」+ 时长/进度 + 两行简介。
/// 播放/已看紧贴行尾,不另占一列空白。点整行进入集详情,右键菜单同样可
/// 播放/标已看。当前集以 surfaceContainerHigh 底色与 primary 左边条标示。
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

  final EmbyItem item;
  final bool selected;
  final bool busyPlayed;
  final VoidCallback onTap;
  final VoidCallback onPlay;
  final VoidCallback onTogglePlayed;

  static double thumbWidthFor(Size viewport) {
    final width = viewport.width;
    final base = width < AppBreakpoints.compact
        ? 168.0
        : width < AppBreakpoints.large
        ? 184.0
        : 200.0;
    return base * AppViewport.readingScaleOf(viewport);
  }

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
    final action = await showMenu<_EpisodeRowMenuAction>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(globalPosition.dx, globalPosition.dy, 0, 0),
        Offset.zero & overlayBox.size,
      ),
      items: [
        PopupMenuItem(
          value: _EpisodeRowMenuAction.play,
          child: Text(playLabel),
        ),
        PopupMenuItem(
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
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final item = widget.item;
    final selected = widget.selected;
    final number = item.indexNumber;
    final title = number == null ? item.name : '$number. ${item.name}';
    final progress = item.playbackProgress;
    final playLabel = item.canResume ? l10n.resumePlay : l10n.play;
    final played = item.userData.played;
    final runtime = runtimeLabel(l10n, item);
    final premiere = item.premiereDate;
    final meta = <String>[
      if (item.canResume)
        remainingLabel(l10n, item) ??
            l10n.playbackProgress((progress * 100).round())
      else if (played)
        l10n.mobileWatched,
      if (premiere != null) formatDateYmd(premiere),
    ];
    final overview = plainOverview(item.overview);
    final viewport = MediaQuery.sizeOf(context);
    final thumbWidth = EpisodeRow.thumbWidthFor(viewport);
    final thumbHeight = thumbWidth * 9 / 16;
    final control = 36.0 * AppViewport.readingScaleOf(viewport);
    final fill = selected
        ? scheme.surfaceContainerHigh
        : _hovered
        ? scheme.surfaceContainerHighest.withValues(alpha: 0.55)
        : scheme.surfaceContainerHighest.withValues(alpha: 0.28);
    final actionStyle = IconButton.styleFrom(
      minimumSize: Size(control, control),
      padding: EdgeInsets.all(6 * control / 36),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
      iconSize: 24 * control / 36,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadii.md),
          child: Material(
            color: fill,
            child: InkWell(
              key: CatalogKeys.episode(item.id),
              onTap: widget.onTap,
              onFocusChange: (value) => setState(() => _focused = value),
              onSecondaryTapDown: (details) {
                unawaited(_openMenu(context, details.globalPosition));
              },
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border(
                    left: BorderSide(
                      width: 3,
                      color: selected ? scheme.primary : Colors.transparent,
                    ),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.sm,
                    vertical: AppSpacing.xs,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      _EpisodeThumb(
                        item: item,
                        width: thumbWidth,
                        height: thumbHeight,
                        runtime: runtime,
                        hovered: _hovered || _focused,
                        selected: selected,
                        playLabel: playLabel,
                        onPlay: widget.onPlay,
                      ),
                      const SizedBox(width: AppSpacing.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: selected
                                    ? FontWeight.w700
                                    : FontWeight.w600,
                                color: selected
                                    ? scheme.primary
                                    : played
                                    ? scheme.onSurface.withValues(alpha: .72)
                                    : null,
                              ),
                            ),
                            if (meta.isNotEmpty) ...[
                              const SizedBox(height: AppSpacing.xxs),
                              Text(
                                meta.join(' · '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: item.canResume
                                      ? scheme.primary
                                      : scheme.onSurfaceVariant,
                                  fontWeight: item.canResume
                                      ? FontWeight.w600
                                      : null,
                                ),
                              ),
                            ],
                            if (overview != null && overview.isNotEmpty) ...[
                              const SizedBox(height: AppSpacing.xxs),
                              Text(
                                overview,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: scheme.onSurface.withValues(
                                    alpha: played ? 0.58 : 0.78,
                                  ),
                                  height: 1.35,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      IconButton(
                        key: CatalogKeys.episodePlayed(item.id),
                        tooltip: played ? l10n.markUnplayed : l10n.markPlayed,
                        style: actionStyle,
                        onPressed: widget.busyPlayed
                            ? null
                            : widget.onTogglePlayed,
                        icon: Icon(
                          played
                              ? Icons.check_circle_rounded
                              : Icons.check_circle_outline_rounded,
                          color: played
                              ? scheme.primary
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                      IconButton.filled(
                        key: CatalogKeys.episodePlay(item.id),
                        tooltip: playLabel,
                        style: actionStyle,
                        onPressed: widget.onPlay,
                        icon: const Icon(Icons.play_arrow_rounded),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum _EpisodeRowMenuAction { play, togglePlayed }

/// 分集缩略图:右下时长胶囊、已看角标并压暗;悬停浮出播放按钮,
/// 点缩略图直接开播(点行其余区域仍进集详情)。
class _EpisodeThumb extends StatelessWidget {
  const _EpisodeThumb({
    required this.item,
    required this.width,
    required this.height,
    required this.runtime,
    required this.hovered,
    required this.selected,
    required this.playLabel,
    required this.onPlay,
  });

  final EmbyItem item;
  final double width;
  final double height;
  final String? runtime;
  final bool hovered;
  final bool selected;
  final String playLabel;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final played = item.userData.played;
    final resumable = item.canResume;
    final fade = AppMotion.durationOf(context, AppMotion.normal);
    final runtime = this.runtime;
    return Container(
      width: width,
      height: height,
      foregroundDecoration: selected
          ? BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadii.sm),
              border: Border.all(color: scheme.primary, width: 2),
            )
          : null,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadii.sm),
        child: Stack(
          fit: StackFit.expand,
          children: [
            RepaintBoundary(
              child: MediaImage(
                key: ValueKey(item.id),
                item: item,
                width: width,
                height: height,
                preferThumb: true,
                fit: BoxFit.cover,
                maxWidth: 480,
              ),
            ),
            IgnorePointer(
              child: AnimatedContainer(
                duration: fade,
                color: Colors.black.withValues(
                  alpha: hovered
                      ? .32
                      : played && !selected
                      ? .36
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
            if (played)
              const Positioned(top: 6, right: 6, child: EpisodeWatchedBadge()),
            Material(
              type: MaterialType.transparency,
              child: InkWell(
                key: ValueKey('episode-thumb-play-${item.id}'),
                canRequestFocus: false,
                onTap: onPlay,
                child: Center(
                  child: AnimatedOpacity(
                    opacity: hovered ? 1 : 0,
                    duration: fade,
                    child: AnimatedScale(
                      scale: hovered ? 1 : .85,
                      duration: fade,
                      curve: AppMotion.standard,
                      child: Tooltip(
                        message: playLabel,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: .5),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Colors.white.withValues(alpha: .85),
                              width: 1.5,
                            ),
                          ),
                          child: Padding(
                            padding: EdgeInsets.all(height * .08),
                            child: Icon(
                              Icons.play_arrow_rounded,
                              color: Colors.white,
                              size: height * .26,
                            ),
                          ),
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
                child: _EpisodeProgressBar(value: item.playbackProgress),
              ),
          ],
        ),
      ),
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
        color: Colors.black.withValues(alpha: .66),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        child: Text(
          label,
          maxLines: 1,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: Colors.white,
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
  const EpisodeWatchedBadge({super.key, this.size = 16});

  final double size;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .6),
        shape: BoxShape.circle,
      ),
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: Icon(
          Icons.check_rounded,
          size: size,
          color: Colors.white.withValues(alpha: .95),
        ),
      ),
    );
  }
}

/// 分集列表加载骨架:与 [EpisodeRow] 同结构的全宽占位行。
class EpisodeListSkeleton extends StatelessWidget {
  const EpisodeListSkeleton({super.key, this.rows = 3});

  /// 骨架行数。
  final int rows;

  @override
  Widget build(BuildContext context) {
    final thumbWidth = EpisodeRow.thumbWidthFor(MediaQuery.sizeOf(context));
    return Column(
      children: [
        for (var i = 0; i < rows; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.xs),
            child: _EpisodeRowSkeleton(thumbWidth: thumbWidth),
          ),
      ],
    );
  }
}

class _EpisodeRowSkeleton extends StatelessWidget {
  const _EpisodeRowSkeleton({required this.thumbWidth});

  final double thumbWidth;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SkeletonBlock(width: thumbWidth, height: thumbWidth * 9 / 16),
          const SizedBox(width: AppSpacing.md),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SkeletonBlock(width: 220, height: AppSpacing.md),
                SizedBox(height: AppSpacing.xs),
                SkeletonBlock(width: 140, height: AppSpacing.sm),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 当前集变化后滚入可视区(含选集跳到已在列表中的集)。
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
