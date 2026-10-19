import 'package:rillight/app/ui/app_icons.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/widgets/app_hover_card.dart';
import 'package:rillight/app/widgets/media_progress_bar.dart';
import 'package:rillight/media_server/models.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/library/episode_list.dart';
import 'package:rillight/library/item_format.dart';
import 'package:rillight/media_image/media_image.dart';
import 'package:rillight/player/player_window_host.dart';
import 'package:rillight/library/detail_source_scope.dart';

class PosterCard extends StatelessWidget {
  const PosterCard({
    super.key,
    required this.item,
    required this.onTap,
    this.showProgress = false,
    this.width = 120,
    this.wide = false,
    this.preferBackdrop,
    this.hoverScale = 1.04,
    this.onRemoveFromResume,
  });

  final MediaItem item;
  final VoidCallback onTap;
  final bool showProgress;
  final double width;
  final bool wide;

  /// 横卡默认用背景图。媒体库拼图是主图，需要横幅时传 false。
  final bool? preferBackdrop;
  final double hoverScale;
  final ValueChanged<MediaItem>? onRemoveFromResume;

  /// 悬停播放入口,供测试定位;仅 [MediaItem.isPlayable] 条目会挂上。
  static Key playButtonKey(String itemId) => Key('poster-play-$itemId');

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final height = wide ? width * 9 / 16 : width * 1.5;
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
        // 行高会裁切放大溢出。只放大封面,标题留在原位,避免悬停时被裁掉。
        hoverScale: 1,
        borderRadius: BorderRadius.circular(AppRadii.card),
        builder: (context, highlighted) {
          final zoom =
              highlighted && !wide && !MediaQuery.disableAnimationsOf(context);
          final scheme = AppUiTheme.of(context).colorScheme;
          final light = scheme.brightness == Brightness.light;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              DecoratedBox(
                position: DecorationPosition.foreground,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppRadii.card),
                  // 静止无框,悬停浮一圈高光环,替代旧版常驻的 0.8px 细线框。
                  border: Border.all(
                    color: highlighted
                        ? (light
                              ? scheme.outline
                              : const Color(0xffffffff).withValues(alpha: 0.24))
                        : const Color(0x00000000),
                    width: 1.2,
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadii.card),
                  clipBehavior: Clip.hardEdge,
                  child: SizedBox(
                    width: width,
                    height: height,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        RepaintBoundary(
                          child: AnimatedScale(
                            scale: zoom ? hoverScale : 1,
                            duration: AppMotion.durationOf(
                              context,
                              AppMotion.fast,
                            ),
                            curve: AppMotion.standard,
                            child: MediaImage(
                              key: ValueKey(item.id),
                              item: item,
                              width: width,
                              height: height,
                              preferBackdrop: preferBackdrop ?? wide,
                              maxWidth: wide ? 360 : 280,
                              fit: BoxFit.cover,
                            ),
                          ),
                        ),
                        _PosterRevealOverlay(
                          item: item,
                          revealed: highlighted,
                          showMeta: !wide,
                          playKey: PosterCard.playButtonKey(item.id),
                          onRemoveFromResume: onRemoveFromResume,
                        ),
                        if (!wide && !highlighted)
                          _PosterTopLeftBadges(
                            item: item,
                            l10n: l10n,
                            showWatched: showProgress,
                          ),
                        if (showProgress && item.canResume)
                          Align(
                            alignment: Alignment.bottomCenter,
                            child: MediaProgressBar(
                              key: CatalogKeys.resumeProgress,
                              value: progress,
                              label: l10n.playbackProgress(
                                (progress * 100).round(),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              SizedBox(height: wide ? AppSpacing.xxs : AppSpacing.xs),
              _Caption(
                text: title,
                width: width,
                style: AppUiTheme.of(context).textTheme.titleSmall,
              ),
              if (wide && subtitle.isNotEmpty)
                _Caption(
                  text: subtitle,
                  width: width,
                  style: AppUiTheme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppUiTheme.of(context).colorScheme.onSurface
                        .withValues(alpha: 0.72),
                  ),
                )
              else if (!wide)
                _PosterYearRatingMeta(item: item, width: width),
            ],
          );
        },
      ),
    );
  }
}

class _PosterTopLeftBadges extends StatelessWidget {
  const _PosterTopLeftBadges({
    required this.item,
    required this.l10n,
    required this.showWatched,
  });

  final MediaItem item;
  final AppLocalizations l10n;
  final bool showWatched;

  @override
  Widget build(BuildContext context) {
    final labels = <String>[];
    if (item.isSeries && (item.childCount ?? 0) > 0) {
      labels.add(l10n.cardSeasonCount(item.childCount!));
    }
    if (showWatched && item.userData.played) {
      labels.add(l10n.mobileWatched);
    }
    if (labels.isEmpty) return const SizedBox.shrink();
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    final watchedText = l10n.mobileWatched;
    return Positioned(
      top: 6,
      left: 6,
      right: 6,
      child: IgnorePointer(
        child: Wrap(
          key: Key('poster-card-badges-${item.id}'),
          spacing: 4,
          runSpacing: 4,
          children: [
            for (final label in labels)
              DecoratedBox(
                decoration: BoxDecoration(
                  color: label == watchedText
                      ? scheme.primary
                      : const Color(0xff000000).withValues(alpha: 0.68),
                  borderRadius: BorderRadius.circular(6),
                  border: label == watchedText
                      ? null
                      : Border.all(
                          color: const Color(0xffffffff)
                              .withValues(alpha: 0.16),
                          width: 0.6,
                        ),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  child: Text(
                    label,
                    maxLines: 1,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: label == watchedText
                          ? scheme.onPrimary
                          : const Color(0xffffffff),
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      height: 1.25,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PosterYearRatingMeta extends StatelessWidget {
  const _PosterYearRatingMeta({required this.item, required this.width});

  final MediaItem item;
  final double width;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    final year = item.productionYear;
    final rating = item.communityRating;
    final hasYear = year != null && year > 0;
    final hasRating = rating != null && rating > 0;
    final metaStyle = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    if (!hasYear && !hasRating) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: SizedBox(
        width: width,
        child: Row(
          children: [
            if (hasYear)
              Flexible(
                child: Text(
                  '$year',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: metaStyle,
                ),
              ),
            if (hasRating) ...[
              if (hasYear) const SizedBox(width: 6),
              Icon(
                AppIcons.star,
                fill: AppIcons.filled,
                size: 11,
                color: scheme.primary,
              ),
              const SizedBox(width: 2),
              Text(rating.toStringAsFixed(1), maxLines: 1, style: metaStyle),
            ],
          ],
        ),
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

  final MediaItem item;
  final VoidCallback onTap;
  final double width;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final height = width * 9 / 16;
    final progress = item.playbackProgress;
    final title = numberedEpisodeTitle(item);
    return SizedBox(
      width: width,
      child: _HoverHighlight(
        inkKey: CatalogKeys.episode(item.id),
        onTap: onTap,
        hoverScale: 1,
        borderRadius: BorderRadius.circular(AppRadii.sm),
        // The image frame owns selection and hover feedback, with fixed insets.
        showRing: false,
        builder: (context, highlighted) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                key: ValueKey('episode-thumb-frame-${item.id}'),
                width: width,
                height: height,
                // Reserve the same 3dp frame for every episode. Painting a ring
                // over only the selected image hides its edges and makes that
                // picture visibly smaller than its neighbours. The frame stays
                // neutral: a primary stroke lights up the top-right corner and
                // fuses with the progress into one thick bar.
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppRadii.sm),
                  color: highlighted
                      ? (AppUiTheme.of(context).brightness == Brightness.light
                            ? AppUiTheme.of(context).colorScheme.onSurface
                                  .withValues(alpha: 0.38)
                            : const Color(0xffffffff).withValues(alpha: 0.5))
                      : AppUiTheme.of(context)
                            .colorScheme
                            .surfaceContainerHighest,
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadii.sm - 3),
                  clipBehavior: Clip.hardEdge,
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
                          fit: BoxFit.cover,
                        ),
                      ),
                      _PosterRevealOverlay(
                        item: item,
                        revealed: highlighted,
                        showMeta: false,
                        playKey: PosterCard.playButtonKey(item.id),
                      ),
                      if (item.canResume)
                        Positioned(
                          left: 8,
                          right: 8,
                          bottom: 7,
                          child: _EpisodeThumbProgress(
                            key: ValueKey('episode-thumb-progress-${item.id}'),
                            value: progress,
                            label: l10n.playbackProgress(
                              (progress * 100).round(),
                            ),
                          ),
                        ),
                      if (selected && !highlighted)
                        const Center(
                          child: IgnorePointer(child: EpisodeCurrentMark()),
                        ),
                      if (item.userData.played)
                        Positioned(
                          top: 6,
                          left: 6,
                          child: IgnorePointer(
                            child: DecoratedBox(
                              key: Key('episode-thumb-played-${item.id}'),
                              decoration: BoxDecoration(
                                color: AppUiTheme.of(context)
                                    .colorScheme
                                    .primary,
                                shape: BoxShape.circle,
                              ),
                              child: const Padding(
                                padding: EdgeInsets.all(2),
                                child: Icon(
                                  CupertinoIcons.check_mark,
                                  size: 14,
                                  color: Color(0xffffffff),
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
                style: AppUiTheme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: selected ? FontWeight.w700 : null,
                  color: selected
                      ? AppUiTheme.of(context).colorScheme.primary
                      : AppUiTheme.of(context).colorScheme.onSurface,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 分集封面上的续播进度。细圆轨贴在画面内侧，不用主题色光晕，
/// 这样它读作“看到哪了”，而不是卡片的一条边。
class _EpisodeThumbProgress extends StatelessWidget {
  const _EpisodeThumbProgress({
    super.key,
    required this.value,
    required this.label,
  });

  final double value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final fraction = value.clamp(0.0, 1.0);
    return Semantics(
      container: true,
      label: label,
      child: SizedBox(
        height: 3,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xff000000).withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(99),
          ),
          child: Align(
            alignment: Alignment.centerLeft,
            child: FractionallySizedBox(
              widthFactor: fraction,
              heightFactor: 1,
              child: const DecoratedBox(
                decoration: BoxDecoration(
                  color: Color(0xeaffffff),
                  borderRadius: BorderRadius.all(Radius.circular(99)),
                ),
              ),
            ),
          ),
        ),
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

  final MediaItem item;
  final bool selected;
  final VoidCallback onTap;
  final double width;

  @override
  Widget build(BuildContext context) {
    final height = width * 3 / 2;
    final colorScheme = AppUiTheme.of(context).colorScheme;
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
                            fit: BoxFit.cover,
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
                                    style: AppUiTheme.of(context)
                                        .textTheme
                                        .labelMedium
                                        ?.copyWith(
                                          color: const Color(0xffffffff),
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
                style: AppUiTheme.of(context).textTheme.bodySmall,
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
    final textStyle = style;
    // 只有真正被截断的标题才挂 tooltip;完整标题悬停弹"完整文本"莫名其妙。
    final painter = TextPainter(
      text: TextSpan(text: text, style: textStyle),
      maxLines: 1,
      strutStyle: StrutStyle.fromTextStyle(
        textStyle ?? const TextStyle(),
        forceStrutHeight: true,
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout(maxWidth: width);
    final truncated = painter.didExceedMaxLines;
    painter.dispose();
    final child = Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.start,
      style: textStyle,
      strutStyle: StrutStyle.fromTextStyle(
        textStyle ?? const TextStyle(),
        forceStrutHeight: true,
      ),
    );
    return SizedBox(
      width: width,
      child: truncated ? AppTooltip(message: text, child: child) : child,
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
    this.showRing = true,
  });

  final Widget Function(BuildContext context, bool highlighted) builder;
  final VoidCallback onTap;
  final Key? inkKey;
  final BorderRadius? borderRadius;
  final double hoverScale;
  final bool showRing;

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
      showRing: widget.showRing,
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

  final MediaItem item;
  final bool revealed;
  final bool showMeta;
  final Key? playKey;
  final ValueChanged<MediaItem>? onRemoveFromResume;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    final light = scheme.brightness == Brightness.light;
    final meta = <String>[
      ?seasonEpisodeCode(item),
      if (!showMeta && item.productionYear != null && item.productionYear! > 0)
        '${item.productionYear}',
      if (showMeta &&
          revealed &&
          item.productionYear != null &&
          item.productionYear! > 0)
        '${item.productionYear}',
      ?runtimeLabel(l10n, item),
    ];
    // 标题和简介留在卡片下方与详情页。浮层只放播放和一行元信息，
    // 避免小海报上再叠一段看不清的简介。
    return IgnorePointer(
      ignoring: !revealed,
      child: AnimatedOpacity(
        opacity: revealed ? 1 : 0,
        duration: AppMotion.durationOf(context, AppMotion.fast),
        curve: AppMotion.standard,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: light
                ? null
                : LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: const [0, 0.6, 1],
                    colors: [
                      const Color(0x00000000),
                      const Color(0xff000000).withValues(alpha: 0.08),
                      const Color(0xff000000).withValues(
                        alpha: showMeta && meta.isNotEmpty ? 0.62 : 0,
                      ),
                    ],
                  ),
          ),
          child: revealed
              ? Stack(
                  children: [
                    if (onRemoveFromResume != null)
                      Align(
                        alignment: Alignment.topRight,
                        child: Padding(
                          padding: const EdgeInsets.all(AppSpacing.xs),
                          child: AppIconButton(
                            key: CatalogKeys.removeFromResume(item.id),
                            tooltip: l10n.removeFromResume,
                            onPressed: () => onRemoveFromResume!(item),
                            style: AppButtonStyle(
                              backgroundColor: light
                                  ? scheme.surfaceContainerLowest
                                  : const Color(0xff000000)
                                        .withValues(alpha: 0.55),
                              foregroundColor: light
                                  ? scheme.onSurface
                                  : const Color(0xffffffff),
                              side: light
                                  ? BorderSide(color: scheme.outlineVariant)
                                  : null,
                              minimumSize: const Size(36, 36),
                              padding: const EdgeInsets.all(AppSpacing.xxs),
                            ),
                            icon: const Icon(
                              AppIcons.close,
                              fill: AppIcons.filled,
                              size: 18,
                            ),
                          ),
                        ),
                      ),
                    if (item.isPlayable)
                      Center(
                        child: AppIconButton(
                          key: playKey,
                          tooltip: l10n.play,
                          onPressed: () async {
                            final host = PlayerWindowScope.of(context);
                            try {
                              final request =
                                  await DetailSourceScope.playbackRequest(
                                    context,
                                    item.id,
                                  );
                              if (!context.mounted) return;
                              await host.open(request);
                            } catch (_) {
                              if (!context.mounted) return;
                              showAppNotice(context, l10n.playbackFailed);
                            }
                          },
                          style: AppButtonStyle(
                            backgroundColor: light
                                ? scheme.primary
                                : const Color(0xffffffff),
                            foregroundColor: light
                                ? scheme.onPrimary
                                : const Color(0xff000000),
                            padding: EdgeInsets.zero,
                            minimumSize: const Size(56, 56),
                            shape: const CircleBorder(),
                            boxShadow: AppShadow.emphasis(scheme.brightness),
                          ),
                          icon: const Icon(
                            AppIcons.play,
                            fill: AppIcons.filled,
                            size: 26,
                          ),
                        ),
                      ),
                    if (showMeta && meta.isNotEmpty)
                      Align(
                        alignment: Alignment.bottomCenter,
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(
                            light ? 10 : AppSpacing.sm,
                            0,
                            light ? 10 : AppSpacing.sm,
                            light ? 14 : AppSpacing.sm,
                          ),
                          child: light
                              ? DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: scheme.surfaceContainerLowest
                                        .withValues(alpha: 0.94),
                                    borderRadius: BorderRadius.circular(99),
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: AppSpacing.xs,
                                      vertical: 2,
                                    ),
                                    child: FittedBox(
                                      fit: BoxFit.scaleDown,
                                      child: Text(
                                        meta.join(' · '),
                                        maxLines: 1,
                                        softWrap: false,
                                        style: theme.textTheme.labelMedium
                                            ?.copyWith(color: scheme.onSurface),
                                      ),
                                    ),
                                  ),
                                )
                              : Text(
                                  meta.join(' · '),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.center,
                                  style: theme.textTheme.labelMedium?.copyWith(
                                    color: const Color(0xffffffff)
                                        .withValues(alpha: 0.92),
                                  ),
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
