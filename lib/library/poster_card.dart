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
  });

  final EmbyItem item;
  final VoidCallback onTap;
  final bool showProgress;
  final double width;
  final bool wide;

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
    return SizedBox(
      width: width,
      child: _HoverHighlight(
        inkKey: CatalogKeys.item(item.id),
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadii.sm),
        builder: (context, highlighted) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadii.sm),
                child: SizedBox(
                  width: width,
                  height: height,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      MediaImage(
                        item: item,
                        width: width,
                        height: height,
                        preferBackdrop: wide,
                        maxWidth: wide ? 480 : 280,
                      ),
                      _PosterRevealOverlay(
                        item: item,
                        title: title,
                        revealed: highlighted,
                        playKey: PosterCard.playButtonKey(item.id),
                      ),
                      if (showProgress && progress > 0)
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
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: wide
                    ? Theme.of(context).textTheme.bodySmall
                    : Theme.of(context).textTheme.bodyMedium,
              ),
              if (!wide && showProgress && progress > 0)
                Text(
                  l10n.playbackProgress((progress * 100).round()),
                  style: Theme.of(context).textTheme.bodySmall,
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
  });

  final EmbyItem item;
  final VoidCallback onTap;
  final double width;

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
        borderRadius: BorderRadius.circular(AppRadii.sm),
        builder: (context, highlighted) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadii.sm),
                child: SizedBox(
                  width: width,
                  height: height,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      MediaImage(
                        item: item,
                        width: width,
                        height: height,
                        maxWidth: 480,
                      ),
                      _PosterRevealOverlay(
                        item: item,
                        title: title,
                        revealed: highlighted,
                        playKey: PosterCard.playButtonKey(item.id),
                      ),
                      if (progress > 0)
                        Align(
                          alignment: Alignment.bottomCenter,
                          child: _ResumeProgressBar(value: progress),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
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
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppRadii.sm),
                  border: Border.all(
                    color: selected ? colorScheme.primary : Colors.transparent,
                    width: 2,
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadii.sm),
                  child: SizedBox(
                    width: width,
                    height: height,
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
                          title: item.name,
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
                                  style: Theme.of(context).textTheme.labelMedium
                                      ?.copyWith(color: colorScheme.onSurface),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                item.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          );
        },
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
  });

  final Widget Function(BuildContext context, bool highlighted) builder;
  final VoidCallback onTap;
  final Key? inkKey;
  final BorderRadius? borderRadius;

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
    required this.title,
    required this.revealed,
    this.playKey,
  });

  final EmbyItem item;
  final String title;
  final bool revealed;
  final Key? playKey;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final meta = <String>[
      if (item.productionYear != null && item.productionYear! > 0)
        '${item.productionYear}',
      ?runtimeLabel(l10n, item),
    ];
    return IgnorePointer(
      ignoring: !revealed,
      child: AnimatedOpacity(
        opacity: revealed ? 1 : 0,
        duration: AppMotion.durationOf(context, AppMotion.fast),
        curve: AppMotion.standard,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                colorScheme.scrim.withValues(alpha: revealed ? 0.12 : 0),
                colorScheme.scrim.withValues(alpha: revealed ? 0.78 : 0),
              ],
            ),
          ),
          child: revealed
              ? Padding(
                  padding: const EdgeInsets.all(AppSpacing.xs),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (item.isPlayable)
                        Align(
                          alignment: Alignment.topRight,
                          child: ExcludeFocus(
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
                                backgroundColor: colorScheme.primary,
                                foregroundColor: colorScheme.onPrimary,
                                visualDensity: VisualDensity.compact,
                                padding: const EdgeInsets.all(AppSpacing.xxs),
                                minimumSize: const Size(32, 32),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              icon: const Icon(Icons.play_arrow, size: 20),
                            ),
                          ),
                        ),
                      Expanded(
                        child: Align(
                          alignment: Alignment.bottomLeft,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (meta.isNotEmpty)
                                Text(
                                  meta.join(' · '),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: Colors.white.withValues(alpha: 0.78),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
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
      height: AppSpacing.xxs,
      child: ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
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
