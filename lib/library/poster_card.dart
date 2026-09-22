import 'dart:async';

import 'package:flutter/material.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/widgets/app_hover_card.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/library/item_format.dart';
import 'package:rillight/media_image/media_image.dart';
import 'package:rillight/player/player_window_host.dart';

class PosterCard extends StatelessWidget {
  const PosterCard({
    super.key,
    required this.item,
    required this.onTap,
    this.showProgress = false,
    this.width = 120,
    this.wide = false,
    this.hoverScale = 1.04,
    this.onRemoveFromResume,
  });

  final EmbyItem item;
  final VoidCallback onTap;
  final bool showProgress;
  final double width;
  final bool wide;
  final double hoverScale;
  final ValueChanged<EmbyItem>? onRemoveFromResume;

  /// 悬停播放入口,供测试定位;仅 [EmbyItem.isPlayable] 条目会挂上。
  static Key playButtonKey(String itemId) => Key('poster-play-$itemId');

  @override
  Widget build(BuildContext context) {
    final height = wide ? width * 9 / 16 : width * 1.5;
    final l10n = AppLocalizations.of(context);
    final progress = item.playbackProgress;
    final title = item.isEpisode && (item.seriesName?.isNotEmpty ?? false)
        ? item.seriesName!
        : item.name;
    final subtitle = wide ? continueWatchingSubtitle(item) : '';
    return SizedBox(
      width: width,
      child: _HoverHighlight(
        inkKey: CatalogKeys.item(item.id),
        onTap: onTap,
        hoverScale: hoverScale,
        borderRadius: BorderRadius.circular(AppRadii.md),
        builder: (context, highlighted) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadii.md),
                clipBehavior: Clip.hardEdge,
                child: SizedBox(
                  width: width,
                  height: height,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      RepaintBoundary(
                        child: MediaImage(
                          key: ValueKey(item.id),
                          item: item,
                          width: width,
                          height: height,
                          preferBackdrop: wide,
                          maxWidth: wide ? 360 : 280,
                        ),
                      ),
                      _PosterRevealOverlay(
                        item: item,
                        revealed: highlighted,
                        showMeta: !wide,
                        playKey: PosterCard.playButtonKey(item.id),
                        onRemoveFromResume: onRemoveFromResume,
                      ),
                      if (showProgress && item.canResume)
                        Align(
                          alignment: Alignment.bottomCenter,
                          child: _ResumeProgressBar(
                            key: CatalogKeys.resumeProgress,
                            value: progress,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              SizedBox(height: wide ? AppSpacing.xxs : AppSpacing.xs),
              _Caption(
                text: title,
                width: width,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              if (subtitle.isNotEmpty)
                _Caption(
                  text: subtitle,
                  width: width,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.72),
                  ),
                ),
              if (!wide && showProgress && item.canResume)
                SizedBox(
                  width: width,
                  child: Text(
                    l10n.playbackProgress((progress * 100).round()),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class EpisodeThumbCard extends StatelessWidget {
  const EpisodeThumbCard({
    super.key,
    required this.item,
    required this.onTap,
    this.width = 210,
    this.selected = false,
  });

  final EmbyItem item;
  final VoidCallback onTap;
  final double width;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final height = width * 9 / 16;
    final progress = item.playbackProgress;
    final number = item.indexNumber;
    final title = number == null ? item.name : '$number. ${item.name}';
    return SizedBox(
      width: width,
      child: _HoverHighlight(
        inkKey: CatalogKeys.episode(item.id),
        onTap: onTap,
        hoverScale: 1,
        borderRadius: BorderRadius.circular(AppRadii.sm),
        builder: (context, highlighted) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadii.sm),
                clipBehavior: Clip.hardEdge,
                child: SizedBox(
                  width: width,
                  height: height,
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
                          maxWidth: 360,
                        ),
                      ),
                      _PosterRevealOverlay(
                        item: item,
                        revealed: highlighted,
                        showMeta: false,
                        playKey: PosterCard.playButtonKey(item.id),
                      ),
                      if (item.canResume)
                        Align(
                          alignment: Alignment.bottomCenter,
                          child: _ResumeProgressBar(value: progress),
                        ),
                      if (selected)
                        Positioned.fill(
                          child: IgnorePointer(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(
                                  AppRadii.sm,
                                ),
                                border: Border.all(
                                  color: Colors.white,
                                  width: 3,
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
              _Caption(
                text: title,
                width: width,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: selected ? FontWeight.w700 : null,
                  color: selected ? Colors.white : null,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class SeasonPosterCard extends StatelessWidget {
  const SeasonPosterCard({
    super.key,
    required this.item,
    required this.selected,
    required this.onTap,
    this.width = 132,
  });

  final EmbyItem item;
  final bool selected;
  final VoidCallback onTap;
  final double width;

  @override
  Widget build(BuildContext context) {
    final height = width * 3 / 2;
    final colorScheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: width,
      child: _HoverHighlight(
        inkKey: CatalogKeys.season(item.id),
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadii.sm),
        builder: (context, highlighted) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(
                width: width,
                height: height,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(AppRadii.sm),
                      clipBehavior: Clip.hardEdge,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          MediaImage(
                            item: item,
                            width: width,
                            height: height,
                            maxWidth: 280,
                          ),
                          _PosterRevealOverlay(
                            item: item,
                            revealed: highlighted,
                          ),
                          if (item.childCount != null && item.childCount! > 0)
                            Positioned(
                              top: AppSpacing.xs,
                              right: AppSpacing.xs,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: colorScheme.scrim.withValues(
                                    alpha: 0.72,
                                  ),
                                  borderRadius: BorderRadius.circular(
                                    AppRadii.md,
                                  ),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: AppSpacing.xs,
                                    vertical: AppSpacing.xxs,
                                  ),
                                  child: Text(
                                    '${item.childCount}',
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelMedium
                                        ?.copyWith(
                                          color: colorScheme.onSurface,
                                        ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (selected)
                      IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(AppRadii.sm),
                            border: Border.all(
                              color: colorScheme.primary,
                              width: 2,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              _Caption(
                text: item.name,
                width: width,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Caption extends StatelessWidget {
  const _Caption({
    required this.text,
    required this.width,
    required this.style,
  });

  final String text;
  final double width;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Tooltip(
        message: text,
        waitDuration: const Duration(milliseconds: 400),
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: style,
        ),
      ),
    );
  }
}

class _HoverHighlight extends StatefulWidget {
  const _HoverHighlight({
    required this.builder,
    required this.onTap,
    this.inkKey,
    this.borderRadius,
    this.hoverScale = 1.04,
  });

  final Widget Function(BuildContext context, bool highlighted) builder;
  final VoidCallback onTap;
  final Key? inkKey;
  final BorderRadius? borderRadius;
  final double hoverScale;

  @override
  State<_HoverHighlight> createState() => _HoverHighlightState();
}

class _HoverHighlightState extends State<_HoverHighlight> {
  bool _highlighted = false;

  @override
  Widget build(BuildContext context) {
    return AppHoverCard(
      inkKey: widget.inkKey,
      onTap: widget.onTap,
      hoverScale: widget.hoverScale,
      borderRadius: widget.borderRadius,
      onHighlighted: (value) {
        if (_highlighted == value) {
          return;
        }
        setState(() => _highlighted = value);
      },
      child: widget.builder(context, _highlighted),
    );
  }
}

class _PosterRevealOverlay extends StatelessWidget {
  const _PosterRevealOverlay({
    required this.item,
    required this.revealed,
    this.showMeta = true,
    this.playKey,
    this.onRemoveFromResume,
  });

  final EmbyItem item;
  final bool revealed;
  final bool showMeta;
  final Key? playKey;
  final ValueChanged<EmbyItem>? onRemoveFromResume;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final meta = <String>[
      ?seasonEpisodeCode(item),
      if (item.productionYear != null && item.productionYear! > 0)
        '${item.productionYear}',
      ?runtimeLabel(l10n, item),
    ];
    final overview = plainOverview(item.overview);
    // 标题已经写在海报下方,浮层里不再叠一遍。
    return IgnorePointer(
      ignoring: !revealed,
      child: AnimatedOpacity(
        opacity: revealed ? 1 : 0,
        duration: AppMotion.durationOf(context, AppMotion.fast),
        curve: AppMotion.standard,
        child: ColoredBox(
          color: Colors.black.withValues(alpha: revealed ? 0.42 : 0),
          child: revealed
              ? Stack(
                  children: [
                    if (onRemoveFromResume != null)
                      Align(
                        alignment: Alignment.topRight,
                        child: Padding(
                          padding: const EdgeInsets.all(AppSpacing.xs),
                          child: IconButton(
                            key: CatalogKeys.removeFromResume(item.id),
                            tooltip: l10n.removeFromResume,
                            onPressed: () => onRemoveFromResume!(item),
                            style: IconButton.styleFrom(
                              backgroundColor: Colors.black.withValues(
                                alpha: 0.55,
                              ),
                              foregroundColor: Colors.white,
                              minimumSize: const Size(32, 32),
                              padding: const EdgeInsets.all(AppSpacing.xxs),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            icon: const Icon(Icons.close_rounded, size: 18),
                          ),
                        ),
                      ),
                    if (item.isPlayable)
                      Center(
                        child: IconButton(
                          key: playKey,
                          tooltip: l10n.play,
                          onPressed: () {
                            unawaited(
                              PlayerWindowScope.of(
                                context,
                              ).open(PlayerOpenRequest(itemId: item.id)),
                            );
                          },
                          style: IconButton.styleFrom(
                            backgroundColor: Colors.white,
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.all(AppSpacing.sm),
                            minimumSize: const Size(52, 52),
                            elevation: 4,
                          ),
                          icon: const Icon(Icons.play_arrow_rounded, size: 32),
                        ),
                      ),
                    if (showMeta || overview != null)
                      Align(
                        alignment: Alignment.bottomCenter,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(
                            AppSpacing.sm,
                            0,
                            AppSpacing.sm,
                            AppSpacing.sm,
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (showMeta && meta.isNotEmpty) ...[
                                Text(
                                  meta.join(' · '),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.center,
                                  style: theme.textTheme.labelMedium?.copyWith(
                                    color: Colors.white.withValues(alpha: 0.88),
                                  ),
                                ),
                              ],
                              if (overview != null) ...[
                                if (showMeta && meta.isNotEmpty)
                                  const SizedBox(height: AppSpacing.xxs),
                                Text(
                                  overview,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.start,
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: Colors.white.withValues(alpha: 0.92),
                                    height: 1.35,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                  ],
                )
              : const SizedBox.expand(),
        ),
      ),
    );
  }
}

class _ResumeProgressBar extends StatelessWidget {
  const _ResumeProgressBar({super.key, required this.value});

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
