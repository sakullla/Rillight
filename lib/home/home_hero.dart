import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/content_theme.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/widgets/backdrop_scrim.dart';
import 'package:rillight/app/widgets/scrim_icon_button.dart';
import 'package:rillight/app/widgets/skeleton.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/home/featured_items.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/media_shelf.dart';
import 'package:rillight/library/item_format.dart';
import 'package:rillight/media_image/media_image.dart';

/// 首页全宽 hero 轮播:最多 5 条未看完、优先有背景图的电影和剧集。
/// 支持左右箭头与指示点手动切换,并约每 6 秒自动轮换。
/// 悬停或焦点只暂停计时与进度,离开后继续。手动切换或暂停会锁住,直到再次播放。
/// [MediaQuery.disableAnimations] 或 [AppMotion.durationOf] 为零时不切换、
/// 进度不走,暂停控制不可用(WCAG 2.2.2)。
/// backdrop 顶到内容区边缘,[BackdropScrim] 三段遮罩上叠大标题、元信息与主操作。
class HomeHero extends StatefulWidget {
  const HomeHero({super.key, required this.catalog, this.topOverlap = 0});

  final CatalogController catalog;

  /// 向上叠过 [AppShell] 顶栏的高度;由首页传入,本组件只增加画面高度。
  final double topOverlap;

  /// 总高度约占视口 60%,给第一条内容行留出首屏空间。
  static double heightFor(double width, {double? viewportHeight}) {
    final fromWidth = width * 0.50;
    final fromViewport = viewportHeight == null
        ? fromWidth
        : viewportHeight * 0.60;
    final base = math.min(fromWidth, fromViewport);
    if (width < AppBreakpoints.compact) {
      return base.clamp(320.0, 560.0);
    }
    if (width < AppBreakpoints.large) {
      return base.clamp(360.0, 640.0);
    }
    return base.clamp(400.0, 680.0);
  }

  /// 高度足够时才放得下简介。
  static bool showsOverview(double width, {double? viewportHeight}) =>
      heightFor(width, viewportHeight: viewportHeight) >= 400;

  /// 轮播候选上限,避免指示点过多。
  static const maxFeatured = 5;

  /// 自动轮换间隔。当前指示在这一整段里显示进度。
  static const autoAdvanceInterval = Duration(seconds: 6);

  /// 进度刷新步长。长于测试里 pumpAndSettle 的单步,避免空转占满帧调度。
  static const progressTick = Duration(milliseconds: 200);

  /// 顶带在顶栏下方继续溶入的高度;与 [AppScrim.topBandHeight] 的默认
  /// 构成(顶栏 56 + 溶入 36)一致。
  static const double topBandFade = 36;

  /// 文字块最大宽度:不超过 60% 视口且 ≤ 640,与 [AppScrim.textBandWidthFactor]
  /// 的文字带对齐。
  static double textBlockWidthFor(double width) =>
      width < AppBreakpoints.compact
      ? width - AppSpacing.page * 2
      : math.min(width * 0.6, 640);

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
  bool _paused = false;
  Timer? _progressTimer;
  int _elapsedMs = 0;
  final ValueNotifier<double> _progress = ValueNotifier<double>(0);

  /// 有背景图的未看完电影和剧集。
  List<EmbyItem> get _featuredItems {
    return featuredHomeItems(widget.catalog, limit: HomeHero.maxFeatured);
  }

  bool get _loading =>
      widget.catalog.latestMovies.loading ||
      widget.catalog.latestSeries.loading;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAutoAdvanceTimer();
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    _progress.dispose();
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
        !_paused &&
        TickerMode.valuesOf(context).enabled &&
        !_reduceMotion;
  }

  void _syncAutoAdvanceTimer() {
    final wantTimer = _canAutoAdvance && _featuredItems.length > 1;
    if (wantTimer) {
      _progressTimer ??= Timer.periodic(HomeHero.progressTick, (_) {
        _onProgressTick();
      });
    } else {
      _progressTimer?.cancel();
      _progressTimer = null;
    }
  }

  void _onProgressTick() {
    if (!mounted || !_canAutoAdvance || _featuredItems.length < 2) {
      return;
    }
    _elapsedMs += HomeHero.progressTick.inMilliseconds;
    final intervalMs = HomeHero.autoAdvanceInterval.inMilliseconds;
    if (_elapsedMs >= intervalMs) {
      final count = _featuredItems.length;
      _elapsedMs = 0;
      _progress.value = 0;
      setState(() => _index = (_index + 1) % count);
      return;
    }
    _progress.value = _elapsedMs / intervalMs;
  }

  void _resetProgress() {
    _elapsedMs = 0;
    _progress.value = 0;
  }

  void _go(int delta) {
    final count = _featuredItems.length;
    if (count < 2) {
      return;
    }
    _goTo(_index + delta);
  }

  void _goTo(int index) {
    final count = _featuredItems.length;
    if (count < 2) {
      return;
    }
    setState(() {
      _index = (index % count + count) % count;
      _paused = true;
      _resetProgress();
    });
  }

  @override
  Widget build(BuildContext context) {
    _syncAutoAdvanceTimer();
    final items = _featuredItems;
    return LayoutBuilder(
      builder: (context, constraints) {
        final index = items.isEmpty ? 0 : _index % items.length;
        final item = items.isEmpty ? null : items[index];
        final hasImage =
            item != null &&
            (item.backdropImageTag != null ||
                item.primaryImageTag != null ||
                item.parentBackdropImageTag != null);
        final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
        final viewportHeight = MediaQuery.sizeOf(context).height;
        final ratioHeight = hasImage
            ? HomeHero.heightFor(
                constraints.maxWidth,
                viewportHeight: viewportHeight,
              )
            : 0.0;
        final textFloor =
            (HomeHero.showsOverview(
                      constraints.maxWidth,
                      viewportHeight: viewportHeight,
                    )
                    ? 280
                    : 200) *
                scale +
            widget.topOverlap +
            64;
        final preferred = math.max(ratioHeight, textFloor);
        final cap =
            viewportHeight -
            MediaShelf.heroClearanceFor(context, constraints.maxWidth);
        final height = cap >= textFloor ? math.min(preferred, cap) : preferred;
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
        final featured = item!;
        return SizedBox(
          height: height,
          width: double.infinity,
          child: Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onFocusChange: (focused) {
              if (!mounted || _focused == focused) {
                return;
              }
              // pump(duration) elapses before drawing a frame scheduled from
              // this callback, so the timer has to start or stop here.
              _focused = focused;
              _syncAutoAdvanceTimer();
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
                      key: ValueKey(featured.id),
                      child: ContentTheme(
                        item: featured,
                        preferBackdrop: true,
                        fillSurface: false,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            BackdropScrim(
                              topBandHeight: math.max(
                                AppScrim.topBandHeight,
                                widget.topOverlap + HomeHero.topBandFade,
                              ),
                              backdrop: !hasImage
                                  ? const SizedBox.expand()
                                  : MediaImage(
                                      item: featured,
                                      height: height,
                                      preferBackdrop: true,
                                      maxWidth: mediaBackdropRequestWidth(
                                        layoutWidth: constraints.maxWidth,
                                        devicePixelRatio:
                                            MediaQuery.devicePixelRatioOf(
                                              context,
                                            ),
                                      ),
                                    ),
                            ),
                            Padding(
                              padding: EdgeInsets.fromLTRB(
                                AppSpacing.page,
                                math.max(AppSpacing.xl, widget.topOverlap),
                                AppSpacing.page,
                                items.length > 1 ? 64 : AppSpacing.xl,
                              ),
                              child: _HeroContent(
                                item: featured,
                                width: constraints.maxWidth,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (items.length > 1) ...[
                    Positioned(
                      right: AppSpacing.page,
                      bottom: AppSpacing.xs,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Theme.of(
                            context,
                          ).colorScheme.scrim.withValues(alpha: 0.34),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.12),
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(AppSpacing.xxs),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              ScrimIconButton(
                                key: CatalogKeys.heroPrev,
                                tooltip: AppLocalizations.of(
                                  context,
                                ).scrollLeft,
                                icon: const Icon(Icons.chevron_left),
                                size: ScrimIconButtonSize.regular,
                                onPressed: () => _go(-1),
                              ),
                              ScrimIconButton(
                                key: const Key('catalog-hero-pause'),
                                tooltip: _paused || _reduceMotion
                                    ? AppLocalizations.of(
                                        context,
                                      ).resumeCarousel
                                    : AppLocalizations.of(
                                        context,
                                      ).pauseCarousel,
                                icon: Icon(
                                  _paused || _reduceMotion
                                      ? Icons.play_arrow
                                      : Icons.pause,
                                ),
                                size: ScrimIconButtonSize.regular,
                                onPressed: _reduceMotion
                                    ? null
                                    : () => setState(() => _paused = !_paused),
                              ),
                              ScrimIconButton(
                                key: CatalogKeys.heroNext,
                                tooltip: AppLocalizations.of(
                                  context,
                                ).scrollRight,
                                icon: const Icon(Icons.chevron_right),
                                size: ScrimIconButtonSize.regular,
                                onPressed: () => _go(1),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: AppSpacing.page,
                      bottom: AppSpacing.xs,
                      child: _HeroIndicators(
                        key: Key('catalog-hero-index-$index'),
                        count: items.length,
                        index: index,
                        progress: _progress,
                        onSelect: _goTo,
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

class _HeroIndicators extends StatelessWidget {
  const _HeroIndicators({
    super.key,
    required this.count,
    required this.index,
    required this.progress,
    required this.onSelect,
  });

  final int count;
  final int index;
  final ValueListenable<double> progress;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const inactiveAlpha = 0.35;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < count; i++)
          SizedBox(
            width: 24,
            height: 32,
            child: IconButton(
              key: CatalogKeys.heroDot(i),
              tooltip: '${i + 1} / $count',
              isSelected: i == index,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 24, height: 32),
              onPressed: () => onSelect(i),
              icon: Center(
                child: i == index
                    ? HomeHeroProgress(progress: progress)
                    : AnimatedContainer(
                        duration: AppMotion.durationOf(context, AppMotion.fast),
                        curve: AppMotion.standard,
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: scheme.onSurface.withValues(
                            alpha: inactiveAlpha,
                          ),
                          borderRadius: BorderRadius.circular(AppRadii.sm / 2),
                        ),
                      ),
              ),
            ),
          ),
      ],
    );
  }
}

/// 当前海报指示上的间隔进度,取值 0 到 1。
class HomeHeroProgress extends StatelessWidget {
  const HomeHeroProgress({super.key, required this.progress});

  static const progressKey = Key('catalog-hero-progress');

  final ValueListenable<double> progress;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurface;
    return ValueListenableBuilder<double>(
      valueListenable: progress,
      builder: (context, value, _) {
        final progress = value.clamp(0.0, 1.0);
        return SizedBox(
          key: HomeHeroProgress.progressKey,
          width: 18,
          height: 6,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadii.sm / 2),
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(color: color.withValues(alpha: 0.35)),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: progress,
                    child: ColoredBox(color: color),
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
    final title = item.isEpisode && (item.seriesName?.isNotEmpty ?? false)
        ? item.seriesName!
        : item.name;
    // Episode names often contain release-group/codec filenames. The series
    // title is already the hero title; keep only the useful episode code here.
    final episodeLine = item.isEpisode ? seasonEpisodeCode(item) ?? '' : '';
    final meta = <String>[
      if (!item.isEpisode &&
          item.productionYear != null &&
          item.productionYear! > 0)
        '${item.productionYear}',
      ?runtimeLabel(l10n, item),
      if (item.canResume)
        l10n.playbackProgress((item.playbackProgress * 100).round()),
    ];
    final textBlockWidth = HomeHero.textBlockWidthFor(width);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Spacer(),
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: textBlockWidth),
          child: Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: titleStyle?.copyWith(
              color: theme.colorScheme.onSurface,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        if (episodeLine.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(
            episodeLine,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.86),
            ),
          ),
        ],
        if (meta.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(
            meta.join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.78),
            ),
          ),
        ],
        if (item.overview != null &&
            item.overview!.trim().isNotEmpty &&
            HomeHero.showsOverview(
              width,
              viewportHeight: MediaQuery.sizeOf(context).height,
            )) ...[
          const SizedBox(height: AppSpacing.sm),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: textBlockWidth),
            child: Text(
              item.overview!,
              maxLines: compact ? 2 : 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.86),
              ),
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.lg),
        OutlinedButton(
          onPressed: () => context.push(AppRoutes.item(item.id)),
          style: OutlinedButton.styleFrom(
            foregroundColor: theme.colorScheme.onSurface,
            side: BorderSide(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.42),
            ),
            minimumSize: const Size(0, 48),
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.sm,
            ),
          ),
          child: Text(l10n.details),
        ),
      ],
    );
  }
}
