import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/widgets/scroll_viewport.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/hero_artwork.dart';
import 'package:rillight/library/item_format.dart';

/// 轮播标题:单集用所属剧集名。
String heroTitle(EmbyItem item) =>
    item.isEpisode && item.seriesName?.isNotEmpty == true
    ? item.seriesName!
    : item.name;

/// 轮播 meta 行:SxxExx / 年份 / 时长 / 已看进度。
List<String> heroMetaLabels(AppLocalizations l10n, EmbyItem item) => [
  if (item.isEpisode) ?seasonEpisodeCode(item),
  if (!item.isEpisode && item.productionYear != null) '${item.productionYear}',
  ?runtimeLabel(l10n, item),
  if (item.canResume)
    l10n.playbackProgress((item.playbackProgress * 100).round()),
];

/// 轮播版式:有合格背景图走全出血;只有海报走海报聚焦。
enum HeroLayout { fullBleed, posterSpotlight }

HeroLayout heroLayoutFor(HeroArtworkSources sources) =>
    sources.backdrops.isEmpty
    ? HeroLayout.posterSpotlight
    : HeroLayout.fullBleed;

/// ★ 评分徽标:一位小数,无评分不占位。
class HeroRatingBadge extends StatelessWidget {
  const HeroRatingBadge({super.key, required this.rating});

  final double? rating;

  @override
  Widget build(BuildContext context) {
    final value = rating;
    if (value == null) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.star_rounded, size: 15, color: Colors.amber),
        const SizedBox(width: 3),
        Text(
          value.toStringAsFixed(1),
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

/// 图片上的黑色渐变遮罩:底部供文字阅读,顶部淡带保证顶栏可读。
/// 不随应用明/暗主题变化,遮罩上统一白字。
class HeroScrim extends StatelessWidget {
  const HeroScrim({super.key, this.top = false});

  final bool top;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: [0, .45, 1],
                colors: [
                  Colors.transparent,
                  Color(0x8C000000),
                  Color(0xD9000000),
                ],
              ),
            ),
          ),
          if (top)
            const Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                height: 96,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0x59000000), Colors.transparent],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 左下文字块:标题 → meta 行 + ★ → 简介(可选) → 按钮槽。
/// 白字硬编码,配合 [HeroScrim] 使用,不随应用主题变化。
class HeroTextBlock extends StatelessWidget {
  const HeroTextBlock({
    super.key,
    required this.item,
    required this.actions,
    this.showOverview = false,
    this.compact = false,
    this.includeActions = true,
  });

  final EmbyItem item;
  final Widget actions;
  final bool showOverview;
  final bool compact;

  /// 海报聚焦紧凑版式把按钮移到整宽区域,这里只留标题与 meta。
  final bool includeActions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final meta = heroMetaLabels(l10n, item);
    final titleStyle = compact
        ? theme.textTheme.titleLarge
        : theme.textTheme.headlineMedium;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          heroTitle(item),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: titleStyle?.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.w700,
            shadows: const [Shadow(blurRadius: 12, color: Colors.black54)],
          ),
        ),
        if (meta.isNotEmpty || item.communityRating != null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              if (meta.isNotEmpty)
                Flexible(
                  child: Text(
                    meta.join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: Colors.white70,
                    ),
                  ),
                ),
              if (item.communityRating != null) ...[
                const SizedBox(width: 10),
                HeroRatingBadge(rating: item.communityRating),
              ],
            ],
          ),
        ],
        if (showOverview && item.overview?.trim().isNotEmpty == true) ...[
          const SizedBox(height: 12),
          Text(
            item.overview!,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: Colors.white70,
              height: 1.6,
            ),
          ),
        ],
        if (includeActions) ...[SizedBox(height: compact ? 12 : 20), actions],
      ],
    );
  }
}

/// 圆点指示器:桌面与手机共用;命中区 44×44,选中为长条。
/// [onScrim] 为 true 时用遮罩白(图片上),否则用应用主题色(图片外)。
class HeroDots extends StatelessWidget {
  const HeroDots({
    super.key,
    required this.index,
    required this.count,
    required this.onSelect,
    this.onScrim = true,
  });

  final int index;
  final int count;
  final ValueChanged<int> onSelect;
  final bool onScrim;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selected = onScrim ? Colors.white : scheme.secondary;
    final resting = onScrim
        ? Colors.white.withValues(alpha: .35)
        : scheme.onSurface.withValues(alpha: .25);
    return Material(
      type: MaterialType.transparency,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < count; i++)
            Semantics(
              selected: i == index,
              label: '${i + 1} / $count',
              child: InkResponse(
                key: CatalogKeys.heroDot(i),
                onTap: () => onSelect(i),
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: Center(
                    child: AnimatedContainer(
                      duration: AppMotion.durationOf(context, AppMotion.fast),
                      width: i == index ? 18 : 5,
                      height: 5,
                      decoration: BoxDecoration(
                        color: i == index ? selected : resting,
                        borderRadius: BorderRadius.circular(99),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 海报聚焦版式:海报放大模糊压暗铺底 + 清晰海报卡 + 文字槽。
/// Apple TV 风格,让只有海报的条目看起来是刻意设计而非降级。
///
/// 紧凑版式把 [actions] 放到整宽底部(文字列太窄放不下按钮),
/// 此时 [text] 应传 includeActions: false 的 [HeroTextBlock]。
class HeroPosterSpotlight extends StatefulWidget {
  const HeroPosterSpotlight({
    super.key,
    required this.sources,
    required this.requestWidth,
    required this.text,
    this.actions,
    this.compact = false,
    this.onResolved,
  });

  final HeroArtworkSources sources;
  final int requestWidth;
  final Widget text;
  final Widget? actions;
  final bool compact;
  final ValueChanged<HeroArtworkData>? onResolved;

  @override
  State<HeroPosterSpotlight> createState() => _HeroPosterSpotlightState();
}

class _HeroPosterSpotlightState extends State<HeroPosterSpotlight> {
  HeroArtworkData? _resolved;

  void _handleResolved(HeroArtworkData data) {
    widget.onResolved?.call(data);
    if (!data.poster || _resolved?.identity == data.identity) return;
    setState(() => _resolved = data);
  }

  @override
  Widget build(BuildContext context) {
    final poster = _resolved == null
        ? const SizedBox.shrink()
        : AspectRatio(
            aspectRatio: 2 / 3,
            child: Material(
              elevation: 8,
              shadowColor: Colors.black87,
              borderRadius: BorderRadius.circular(AppRadii.md),
              clipBehavior: Clip.antiAlias,
              child: Image.memory(
                _resolved!.bytes,
                fit: BoxFit.cover,
                cacheWidth: 480,
                filterQuality: FilterQuality.medium,
              ),
            ),
          );
    return Stack(
      fit: StackFit.expand,
      children: [
        HeroArtwork(
          sources: widget.sources,
          requestWidth: widget.requestWidth,
          compact: widget.compact,
          spotlightBackground: true,
          onResolved: _handleResolved,
        ),
        const HeroScrim(),
        Padding(
          padding: EdgeInsets.all(widget.compact ? 20 : 32),
          child: widget.compact
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Row(
                        children: [
                          Expanded(child: widget.text),
                          const SizedBox(width: 12),
                          SizedBox(height: 132, child: poster),
                        ],
                      ),
                    ),
                    if (widget.actions != null) ...[
                      const SizedBox(height: 12),
                      widget.actions!,
                    ],
                  ],
                )
              : LayoutBuilder(
                  builder: (context, constraints) {
                    // 海报底部抬高 48,给右下圆点指示器留净空。
                    final posterHeight = (constraints.maxHeight * .92 - 48)
                        .clamp(120.0, 2000.0);
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(child: widget.text),
                        const SizedBox(width: 32),
                        Padding(
                          padding: const EdgeInsets.only(bottom: 48),
                          child: SizedBox(height: posterHeight, child: poster),
                        ),
                      ],
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// 7 秒自动轮播:一次性重排计时器,hover/触摸暂停,手动切换重置。
///
/// 测试与 UI 捕获(运行在 flutter test 下)默认关闭,避免 pumpAndSettle
/// 挂起与捕获不确定性;新行为测试用 [debugForceAutoRotate] 显式开启,
/// 只用固定时长 pump。
mixin HeroAutoRotate<T extends StatefulWidget> on State<T> {
  static const rotateInterval = Duration(seconds: 7);

  @visibleForTesting
  static bool debugForceAutoRotate = false;

  static bool get autoRotateAllowed =>
      debugForceAutoRotate || Platform.environment['FLUTTER_TEST'] != 'true';

  Timer? _rotateTimer;
  bool _rotatePaused = false;
  int _rotateItemCount = 0;
  List<ScrollPosition> _rotateScrolls = const [];
  bool _rotateCheckQueued = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _detachRotateScrolls();
    _rotateScrolls = ancestorScrollPositions(context);
    for (final position in _rotateScrolls) {
      position.addListener(_onRotateScroll);
      position.isScrollingNotifier.addListener(_onRotateScroll);
    }
    _queueRotateCheck();
  }

  void _detachRotateScrolls() {
    for (final position in _rotateScrolls) {
      position.removeListener(_onRotateScroll);
      position.isScrollingNotifier.removeListener(_onRotateScroll);
    }
    _rotateScrolls = const [];
  }

  void _onRotateScroll() {
    cancelAutoRotate();
    _queueRotateCheck();
  }

  void _queueRotateCheck() {
    if (_rotateCheckQueued) return;
    _rotateCheckQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _rotateCheckQueued = false;
      if (!mounted) return;
      if (_canAutoRotate(_rotateItemCount)) {
        armAutoRotate(_rotateItemCount);
      } else {
        cancelAutoRotate();
      }
    });
  }

  bool _rotateInViewport() {
    final object = context.findRenderObject();
    if (object is! RenderBox || !object.attached || !object.hasSize) {
      return true;
    }
    RenderObject? ancestor = object.parent;
    while (ancestor != null) {
      if (ancestor is RenderAbstractViewport && ancestor is RenderBox) {
        final box = ancestor as RenderBox;
        if (box.attached && box.hasSize) {
          final rect = MatrixUtils.transformRect(
            object.getTransformTo(box),
            Offset.zero & object.size,
          );
          if (!rect.overlaps(Offset.zero & box.size)) return false;
        }
      }
      ancestor = ancestor.parent;
    }
    return true;
  }

  @override
  void dispose() {
    _detachRotateScrolls();
    cancelAutoRotate();
    super.dispose();
  }

  /// 宿主实现:推进到下一条。
  void advanceCarousel();

  bool _canAutoRotate(int itemCount) =>
      autoRotateAllowed &&
      itemCount >= 2 &&
      !_rotatePaused &&
      mounted &&
      !_rotateScrolls.any((position) => position.isScrollingNotifier.value) &&
      _rotateInViewport() &&
      TickerMode.valuesOf(context).enabled &&
      !MediaQuery.disableAnimationsOf(context);

  /// 幂等:计时器存活时不重置,触发后由宿主 build 再次调用重新武装。
  void armAutoRotate(int itemCount) {
    _rotateItemCount = itemCount;
    if (_rotateTimer != null || !_canAutoRotate(itemCount)) return;
    _rotateTimer = Timer(rotateInterval, () {
      _rotateTimer = null;
      if (_canAutoRotate(_rotateItemCount)) {
        advanceCarousel();
      }
    });
  }

  void pauseAutoRotate() {
    _rotatePaused = true;
    _rotateTimer?.cancel();
    _rotateTimer = null;
  }

  void resumeAutoRotate(int itemCount) {
    _rotatePaused = false;
    armAutoRotate(itemCount);
  }

  /// 手动切换后调用:重新计时。
  void resetAutoRotate(int itemCount) {
    _rotateTimer?.cancel();
    _rotateTimer = null;
    armAutoRotate(itemCount);
  }

  void cancelAutoRotate() {
    _rotateTimer?.cancel();
    _rotateTimer = null;
  }
}
