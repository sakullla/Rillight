import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/widgets/skeleton.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/library/item_format.dart';
import 'package:rillight/media_image/media_image.dart';
import 'package:rillight/player/player_window_host.dart';

/// 首页全宽沉浸式 hero 轮播:多条 featured 内容(继续观看优先,其次最新
/// 电影/剧集),支持左右箭头与指示点手动切换,并每 10 秒自动轮换。
/// 悬停、焦点在 hero 内、或 [MediaQuery.disableAnimations] /
/// [AppMotion.durationOf] 为零时停止自动轮换(WCAG 2.2.2)。
/// backdrop 顶到内容区边缘,渐变遮罩上叠大标题、元信息与主操作。
class HomeHero extends StatefulWidget {
  const HomeHero({super.key, required this.catalog, this.topOverlap = 0});

  final CatalogController catalog;

  /// 向上叠过 [AppShell] 顶栏的高度;由首页传入,本组件只增加画面高度。
  final double topOverlap;

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

  /// 轮播候选上限,避免指示点过多。
  static const maxFeatured = 10;

  /// 自动轮换间隔。
  static const autoAdvanceInterval = Duration(seconds: 10);

  /// 自动轮换开关;flutter test 环境默认关闭,保证 pumpAndSettle 期间内容确定
  /// (本应用仅桌面平台,Platform 可用)。
  static bool autoAdvanceEnabled =
      Platform.environment['FLUTTER_TEST'] != 'true';

  @override
  State<HomeHero> createState() => _HomeHeroState();
}

class _HomeHeroState extends State<HomeHero> {
  int _index = 0;
  bool _hovering = false;
  bool _focused = false;
  Timer? _autoAdvance;

  /// featured 候选:继续观看(可播/剧集)优先,其次最新电影、最新剧集,
  /// 按 id 去重并截断到 [HomeHero.maxFeatured]。
  List<EmbyItem> get _featuredItems {
    final seen = <String>{};
    final items = <EmbyItem>[];
    void addAll(Iterable<EmbyItem> source, {bool playableOnly = false}) {
      for (final item in source) {
        if (playableOnly && !item.isPlayable && !item.isSeries) {
          continue;
        }
        if (seen.add(item.id)) {
          items.add(item);
        }
        if (items.length >= HomeHero.maxFeatured) {
          return;
        }
      }
    }

    addAll(widget.catalog.resume.items, playableOnly: true);
    addAll(widget.catalog.latestMovies.items);
    addAll(widget.catalog.latestSeries.items);
    return items;
  }

  bool get _loading =>
      widget.catalog.resume.loading ||
      widget.catalog.latestMovies.loading ||
      widget.catalog.latestSeries.loading;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAutoAdvanceTimer();
  }

  @override
  void dispose() {
    _autoAdvance?.cancel();
    super.dispose();
  }

  bool get _reduceMotion {
    return MediaQuery.disableAnimationsOf(context) ||
        AppMotion.durationOf(context) == Duration.zero;
  }

  bool get _canAutoAdvance {
    return HomeHero.autoAdvanceEnabled &&
        !_hovering &&
        !_focused &&
        !_reduceMotion;
  }

  void _syncAutoAdvanceTimer() {
    final wantTimer = HomeHero.autoAdvanceEnabled && !_reduceMotion;
    if (wantTimer) {
      _autoAdvance ??= Timer.periodic(HomeHero.autoAdvanceInterval, (_) {
        _tick();
      });
    } else {
      _autoAdvance?.cancel();
      _autoAdvance = null;
    }
  }

  void _tick() {
    if (!mounted || !_canAutoAdvance) {
      return;
    }
    final count = _featuredItems.length;
    if (count < 2) {
      return;
    }
    setState(() => _index = (_index + 1) % count);
  }

  void _go(int delta) {
    final count = _featuredItems.length;
    if (count < 2) {
      return;
    }
    setState(() => _index = (_index + delta + count) % count);
  }

  @override
  Widget build(BuildContext context) {
    _syncAutoAdvanceTimer();
    final items = _featuredItems;
    return LayoutBuilder(
      builder: (context, constraints) {
        final height =
            HomeHero.heightFor(constraints.maxWidth) + widget.topOverlap;
        if (items.isEmpty) {
          if (!_loading) {
            return const SizedBox.shrink();
          }
          return SkeletonBlock(
            width: double.infinity,
            height: height,
            borderRadius: BorderRadius.zero,
          );
        }
        final index = _index % items.length;
        final item = items[index];
        return SizedBox(
          height: height,
          width: double.infinity,
          child: Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onFocusChange: (focused) {
              if (_focused == focused) {
                return;
              }
              setState(() => _focused = focused);
            },
            child: MouseRegion(
              onEnter: (_) {
                if (!_hovering) {
                  setState(() => _hovering = true);
                }
              },
              onExit: (_) {
                if (_hovering) {
                  setState(() => _hovering = false);
                }
              },
              child: Stack(
                fit: StackFit.expand,
                children: [
                  AnimatedSwitcher(
                    duration: AppMotion.durationOf(context, AppMotion.slow),
                    child: KeyedSubtree(
                      key: ValueKey(item.id),
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
                                  Theme.of(
                                    context,
                                  ).colorScheme.scrim.withValues(alpha: 0),
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
                                  Theme.of(
                                    context,
                                  ).colorScheme.scrim.withValues(alpha: 0),
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
                            child: _HeroContent(
                              item: item,
                              width: constraints.maxWidth,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (items.length > 1) ...[
                    Positioned(
                      left: AppSpacing.sm,
                      top: 0,
                      bottom: 0,
                      child: Center(
                        child: _HeroNavButton(
                          buttonKey: CatalogKeys.heroPrev,
                          tooltip: AppLocalizations.of(context).scrollLeft,
                          icon: Icons.chevron_left,
                          onPressed: () => _go(-1),
                        ),
                      ),
                    ),
                    Positioned(
                      right: AppSpacing.sm,
                      top: 0,
                      bottom: 0,
                      child: Center(
                        child: _HeroNavButton(
                          buttonKey: CatalogKeys.heroNext,
                          tooltip: AppLocalizations.of(context).scrollRight,
                          icon: Icons.chevron_right,
                          onPressed: () => _go(1),
                        ),
                      ),
                    ),
                    Positioned(
                      right: AppSpacing.xl,
                      bottom: AppSpacing.md,
                      child: _HeroIndicators(
                        key: Key('catalog-hero-index-$index'),
                        count: items.length,
                        index: index,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _HeroNavButton extends StatelessWidget {
  const _HeroNavButton({
    required this.buttonKey,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final Key buttonKey;
  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.scrim.withValues(alpha: 0.55),
      shape: const CircleBorder(),
      child: IconButton(
        key: buttonKey,
        tooltip: tooltip,
        onPressed: onPressed,
        icon: Icon(icon),
      ),
    );
  }
}

class _HeroIndicators extends StatelessWidget {
  const _HeroIndicators({super.key, required this.count, required this.index});

  final int count;
  final int index;

  @override
  Widget build(BuildContext context) {
    final active = Theme.of(context).colorScheme.primary;
    final inactive = Colors.white.withValues(alpha: 0.45);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < count; i++)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xxs / 2),
            child: AnimatedContainer(
              duration: AppMotion.durationOf(context, AppMotion.fast),
              curve: AppMotion.standard,
              width: i == index ? 18 : 6,
              height: 6,
              decoration: BoxDecoration(
                color: i == index ? active : inactive,
                borderRadius: BorderRadius.circular(AppRadii.sm / 2),
              ),
            ),
          ),
      ],
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
