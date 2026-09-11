import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/widgets/skeleton.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/library/item_format.dart';
import 'package:rillight/media_image/media_image.dart';
import 'package:rillight/player/player_window_host.dart';

/// 首页全宽沉浸式 hero:backdrop 顶到内容区边缘,渐变遮罩上叠
/// 大标题、元信息与主操作。高度随内容区宽度按比例伸缩并按断点封顶。
class HomeHero extends StatelessWidget {
  const HomeHero({super.key, required this.catalog});

  final CatalogController catalog;

  /// hero 高度:内容区宽度 × 0.42,按 [AppBreakpoints] 设上下限。
  /// compact 下限 320 保证标题+元信息+主操作在极窄窗口不溢出。
  static double heightFor(double width) {
    final base = width * 0.42;
    if (width < AppBreakpoints.compact) {
      return base.clamp(320.0, 400.0);
    }
    if (width < AppBreakpoints.large) {
      return base.clamp(360.0, 520.0);
    }
    return base.clamp(480.0, 640.0);
  }

  /// 高度足够时才放得下简介。
  static bool showsOverview(double width) => heightFor(width) >= 360;

  EmbyItem? get _featured {
    for (final item in catalog.resume.items) {
      if (item.isPlayable || item.isSeries) {
        return item;
      }
    }
    for (final item in catalog.latestMovies.items) {
      return item;
    }
    for (final item in catalog.latestSeries.items) {
      return item;
    }
    return null;
  }

  bool get _loading =>
      catalog.resume.loading ||
      catalog.latestMovies.loading ||
      catalog.latestSeries.loading;

  @override
  Widget build(BuildContext context) {
    final item = _featured;
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = heightFor(constraints.maxWidth);
        if (item == null) {
          if (!_loading) {
            return const SizedBox.shrink();
          }
          return SkeletonBlock(
            width: double.infinity,
            height: height,
            borderRadius: BorderRadius.zero,
          );
        }
        return SizedBox(
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
                      Theme.of(
                        context,
                      ).colorScheme.scrim.withValues(alpha: 0.8),
                      Theme.of(context).colorScheme.scrim.withValues(alpha: 0),
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
                      Theme.of(
                        context,
                      ).colorScheme.scrim.withValues(alpha: 0.9),
                      Theme.of(context).colorScheme.scrim.withValues(alpha: 0),
                    ],
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
                child: _HeroContent(item: item, width: constraints.maxWidth),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _HeroContent extends StatelessWidget {
  const _HeroContent({required this.item, required this.width});

  final EmbyItem item;
  final double width;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final compact = width < AppBreakpoints.compact;
    final titleStyle = compact
        ? theme.textTheme.headlineLarge
        : theme.textTheme.displayMedium;
    final meta = <String>[
      if (item.productionYear != null && item.productionYear! > 0)
        '${item.productionYear}',
      ?runtimeLabel(l10n, item),
      if (item.playbackProgress > 0)
        l10n.playbackProgress((item.playbackProgress * 100).round()),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Spacer(),
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: math.min(width * 0.7, 720)),
          child: Text(
            itemTitle(item),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: titleStyle?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        if (meta.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(
            meta.join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelLarge?.copyWith(
              color: Colors.white.withValues(alpha: 0.78),
            ),
          ),
        ],
        if (item.overview != null &&
            item.overview!.trim().isNotEmpty &&
            HomeHero.showsOverview(width)) ...[
          const SizedBox(height: AppSpacing.sm),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: math.min(width * 0.6, 560)),
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
        const SizedBox(height: AppSpacing.lg),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            if (item.isPlayable || item.isSeries)
              FilledButton.icon(
                onPressed: () {
                  if (item.isPlayable) {
                    unawaited(
                      PlayerWindowScope.of(
                        context,
                      ).open(PlayerOpenRequest(itemId: item.id)),
                    );
                    return;
                  }
                  context.push(AppRoutes.item(item.id));
                },
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.xxl,
                    vertical: AppSpacing.md,
                  ),
                ),
                icon: const Icon(Icons.play_arrow),
                label: Text(l10n.play),
              ),
            OutlinedButton(
              onPressed: () => context.push(AppRoutes.item(item.id)),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: BorderSide(color: Colors.white.withValues(alpha: 0.6)),
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.xl,
                  vertical: AppSpacing.md,
                ),
              ),
              child: Text(l10n.details),
            ),
          ],
        ),
      ],
    );
  }
}
