import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/widgets/scroll_viewport.dart';
import 'package:rillight/media_server/models.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/hero_artwork.dart';
import 'package:rillight/home/hero_logo.dart';
import 'package:rillight/library/item_format.dart';

/// 轮播标题:单集用所属剧集名。
String heroTitle(MediaItem item) =>
    item.isEpisode && item.seriesName?.isNotEmpty == true
    ? item.seriesName!
    : item.name;

/// 轮播 meta 行:年份 · 流派(最多两个) · 时长 / 季数。
/// 只描述作品本身,不带任何观看记录(已看、进度、下一集)。
List<String> heroMetaLabels(AppLocalizations l10n, MediaItem item) {
  final year = item.productionYear;
  final seasons = item.childCount ?? 0;
  return [
    if (item.isEpisode) ?seasonEpisodeCode(item),
    if (year != null && year > 0) '$year',
    ...item.genres
        .map((genre) => genre.trim())
        .where((g) => g.isNotEmpty)
        .take(2),
    if (item.isSeries && seasons > 0)
      l10n.seasonCount(seasons)
    else if (!item.isSeries)
      ?runtimeLabel(l10n, item),
  ];
}

/// 轮播条目的「为什么在这里」:最新电影 / 最新剧集。
String heroKicker(AppLocalizations l10n, MediaItem item) =>
    item.isMovie ? l10n.heroNewMovie : l10n.heroNewSeries;

/// 小号大写感的引导标签,放在标题上方;[onScrim] 决定用遮罩白还是主题强调色。
class HeroKicker extends StatelessWidget {
  const HeroKicker({super.key, required this.label, this.onScrim = true});

  final String label;
  final bool onScrim;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final color = onScrim
        ? const Color(0xffffffff).withValues(alpha: .92)
        : theme.colorScheme.primary;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: onScrim
            ? const Color(0x24ffffff)
            : theme.colorScheme.primaryContainer.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: onScrim
              ? const Color(0x33ffffff)
              : theme.colorScheme.primary.withValues(alpha: 0.24),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: onScrim
                    ? theme.colorScheme.primary
                    : theme.colorScheme.primary,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium?.copyWith(
                color: color,
                letterSpacing: 0.8,
                height: 1.2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 轮播版式:有合格背景图走全出血;只有海报走海报聚焦。
enum HeroLayout { fullBleed, posterSpotlight }

HeroLayout heroLayoutFor(HeroArtworkSources sources) =>
    sources.backdrops.isEmpty
    ? HeroLayout.posterSpotlight
    : HeroLayout.fullBleed;

/// ★ 评分徽标:一位小数,无评分不占位。
/// [onScrim] 为 true 时白字(压在图片遮罩上),否则跟随主题前景色。
class HeroRatingBadge extends StatelessWidget {
  const HeroRatingBadge({super.key, required this.rating, this.onScrim = true});

  final double? rating;
  final bool onScrim;

  @override
  Widget build(BuildContext context) {
    final value = rating;
    if (value == null) return const SizedBox.shrink();
    final theme = AppUiTheme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xffffc107).withValues(alpha: onScrim ? 0.18 : 0.14),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: const Color(0xffffc107).withValues(alpha: 0.32),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              CupertinoIcons.star_fill,
              size: 13,
              color: Color(0xffffc107),
            ),
            const SizedBox(width: 3),
            Text(
              value.toStringAsFixed(1),
              style: theme.textTheme.labelSmall?.copyWith(
                color: onScrim
                    ? const Color(0xffffffff)
                    : theme.colorScheme.onSurface,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 图片上的黑色渐变遮罩:底部供文字阅读,顶部淡带保证顶栏可读。
/// 不随应用明/暗主题变化,遮罩上统一白字。
class HeroScrim extends StatelessWidget {
  const HeroScrim({
    super.key,
    this.top = false,
    this.leading = false,
    this.fadeTo,
    this.gallery = false,
  });

  final bool top;

  /// 宽版式的文字块在左下:再叠一条自左向右的横向渐变,亮图上也可读。
  /// 同时把底部压暗收窄到下半幅,高舞台不会整张发灰。
  final bool leading;

  /// 底缘融进的页面底色,消掉图片与页面之间的硬边。
  final Color? fadeTo;

  /// 浅色页面:说明文字直接压在纸色渐变上(无卡片),遮罩从左下把画面融进纸色,
  /// 不再在底缘铺一条近乎不透明的黑带。
  final bool gallery;

  @override
  Widget build(BuildContext context) {
    final fade = fadeTo;
    if (gallery && fade != null) {
      return IgnorePointer(
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (leading)
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    stops: const [0, .42, .8],
                    colors: [
                      fade.withValues(alpha: .92),
                      fade.withValues(alpha: .68),
                      fade.withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: const [0.3, 0.66, 0.96],
                  colors: [
                    fade.withValues(alpha: 0),
                    fade.withValues(alpha: 0.7),
                    fade,
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
                        colors: [Color(0x59000000), Color(0x00000000)],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    }
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (leading)
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  stops: [0, .34, .62],
                  colors: [
                    Color(0xB3000000),
                    Color(0x59000000),
                    Color(0x00000000),
                  ],
                ),
              ),
            ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: leading ? const [.3, .68, 1] : const [0, .45, 1],
                colors: const [
                  Color(0x00000000),
                  Color(0x8C000000),
                  Color(0xD9000000),
                ],
              ),
            ),
          ),
          if (fade != null)
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: const [.7, 1],
                  colors: [fade.withValues(alpha: 0), fade],
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
                      colors: [Color(0x59000000), Color(0x00000000)],
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

/// 压在画面上的文字统一带一层软阴影,亮部/杂色底图上仍可读。
const List<Shadow> heroScrimTextShadow = [
  Shadow(blurRadius: 18, color: Color(0xA6000000), offset: Offset(0, 2)),
];

/// 左下文字块:标题 → meta 行 + ★ → 简介(可选) → 按钮槽。
///
/// 压在深色遮罩上时白字硬编码。[onPaper] 为真时改用主题墨色,并放弃
/// 浅色标题图(那些图按深底设计,放到纸色卡片上会消失)。
class HeroTextBlock extends StatelessWidget {
  const HeroTextBlock({
    super.key,
    required this.item,
    required this.actions,
    this.showOverview = false,
    this.compact = false,
    this.large = false,
    this.includeActions = true,
    this.logoMaxWidth,
    this.onPaper = false,
  });

  final MediaItem item;
  final Widget actions;
  final bool showOverview;
  final bool compact;

  /// 宽屏舞台:标题升一档,与整幅画面的体量相称。
  final bool large;

  /// 海报聚焦紧凑版式把按钮移到整宽区域,这里只留标题与 meta。
  final bool includeActions;

  /// Width budget for the server's title logo; null keeps the text title.
  final double? logoMaxWidth;

  /// 浅色说明卡:墨色文字,不用遮罩白。
  final bool onPaper;

  /// Logo height cap paired with [logoMaxWidth].
  static double logoMaxHeightFor({required bool large}) => large ? 132 : 96;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final l10n = AppLocalizations.of(context);
    final meta = heroMetaLabels(l10n, item);
    final overview = showOverview ? plainOverview(item.overview) : null;
    final titleStyle = compact
        ? theme.textTheme.titleLarge
        : large
        ? theme.textTheme.displayMedium
        : theme.textTheme.headlineMedium;
    final ink = theme.colorScheme.onSurface;
    final metaColor = onPaper
        ? theme.colorScheme.onSurfaceVariant
        : const Color(0xb3ffffff);
    final overviewColor = onPaper
        ? ink.withValues(alpha: .78)
        : const Color(0xffffffff).withValues(alpha: .78);
    final textShadow = onPaper ? null : heroScrimTextShadow;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        HeroKicker(label: heroKicker(l10n, item), onScrim: !onPaper),
        SizedBox(height: compact ? 6 : 10),
        _title(titleStyle, ink: ink),
        if (meta.isNotEmpty || item.communityRating != null) ...[
          SizedBox(height: large ? 12 : 8),
          Row(
            children: [
              if (meta.isNotEmpty)
                Flexible(
                  child: Text(
                    meta.join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        (large
                                ? theme.textTheme.bodyLarge
                                : theme.textTheme.bodyMedium)
                            ?.copyWith(color: metaColor, shadows: textShadow),
                  ),
                ),
              if (item.communityRating != null) ...[
                const SizedBox(width: 10),
                HeroRatingBadge(
                  rating: item.communityRating,
                  onScrim: !onPaper,
                ),
              ],
            ],
          ),
        ],
        if (overview != null) ...[
          const SizedBox(height: 12),
          Text(
            overview,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style:
                (large ? theme.textTheme.bodyLarge : theme.textTheme.bodyMedium)
                    ?.copyWith(
                      color: overviewColor,
                      height: 1.6,
                      shadows: textShadow,
                    ),
          ),
        ],
        if (includeActions) ...[
          SizedBox(height: compact ? 12 : (large ? 24 : 20)),
          actions,
        ],
      ],
    );
  }

  Widget _title(TextStyle? style, {required Color ink}) {
    final text = Text(
      heroTitle(item),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: style?.copyWith(
        color: onPaper ? ink : const Color(0xffffffff),
        fontWeight: FontWeight.w700,
        height: 1.15,
        letterSpacing: large ? -.2 : null,
        shadows: onPaper ? null : heroScrimTextShadow,
      ),
    );
    final logoWidth = logoMaxWidth;
    if (onPaper || logoWidth == null || !HeroLogo.available(item)) return text;
    return HeroLogo(
      key: ValueKey('hero-logo-${item.id}'),
      item: item,
      fallback: text,
      maxWidth: logoWidth,
      maxHeight: logoMaxHeightFor(large: large),
    );
  }
}

/// 圆点指示器:桌面、手机与 TV 共用;可点时命中区 44×44,选中为长条。
/// [onScrim] 为 true 时用遮罩白(图片上),否则用应用主题色(图片外)。
///
/// 传入 [cycle] 时,选中长条从左向右填充,时长 [interval],显示距自动
/// 翻页还剩多久;值为 null(暂停、悬停、未武装)时长条保持实心。
/// [onSelect] 为 null 时只作展示(TV 用遥控器切换),不参与焦点遍历。
class HeroDots extends StatelessWidget {
  const HeroDots({
    super.key,
    required this.index,
    required this.count,
    required this.onSelect,
    this.onScrim = true,
    this.activeColor,
    this.cycle,
    this.interval = HeroAutoRotate.rotateInterval,
  });

  final int index;
  final int count;
  final ValueChanged<int>? onSelect;
  final bool onScrim;

  /// 选中长条的颜色。为空时遮罩上用白,页面上用 [AppColorScheme.secondary]。
  final Color? activeColor;

  final ValueListenable<int?>? cycle;
  final Duration interval;

  static const double _activeWidth = 20;
  static const double _restWidth = 6;
  static const double _thickness = 6;

  @override
  Widget build(BuildContext context) {
    final scheme = AppUiTheme.of(context).colorScheme;
    final selected =
        activeColor ?? (onScrim ? const Color(0xffffffff) : scheme.secondary);
    final resting = onScrim
        ? const Color(0xffffffff).withValues(alpha: .38)
        : scheme.onSurface.withValues(alpha: .22);
    final select = onSelect;
    final extent = select == null ? 16.0 : 44.0;
    final dots = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < count; i++)
          Semantics(
            selected: i == index,
            label: '${i + 1} / $count',
            child: _hitTarget(
              key: CatalogKeys.heroDot(i),
              onTap: select == null ? null : () => select(i),
              child: SizedBox(
                width: i == index && select == null
                    ? _activeWidth + 10
                    : extent,
                height: extent,
                child: Center(
                  child: i == index
                      ? _ActivePill(
                          cycle: cycle,
                          interval: interval,
                          fill: selected,
                          track: resting,
                        )
                      : AnimatedContainer(
                          duration: AppMotion.durationOf(
                            context,
                            AppMotion.fast,
                          ),
                          curve: AppMotion.standard,
                          width: _restWidth,
                          height: _thickness,
                          decoration: BoxDecoration(
                            color: resting,
                            borderRadius: BorderRadius.circular(99),
                          ),
                        ),
                ),
              ),
            ),
          ),
      ],
    );
    return Container(
      decoration: BoxDecoration(),
      child: select == null ? ExcludeFocus(child: dots) : dots,
    );
  }

  Widget _hitTarget({
    required Key key,
    required VoidCallback? onTap,
    required Widget child,
  }) {
    if (onTap == null) return KeyedSubtree(key: key, child: child);
    return AppSurfaceAction(key: key, onTap: onTap, child: child);
  }
}

class _ActivePill extends StatelessWidget {
  const _ActivePill({
    required this.cycle,
    required this.interval,
    required this.fill,
    required this.track,
  });

  final ValueListenable<int?>? cycle;
  final Duration interval;
  final Color fill;
  final Color track;

  @override
  Widget build(BuildContext context) {
    Widget pill(Widget? progress) => ClipRRect(
      borderRadius: BorderRadius.circular(99),
      child: SizedBox(
        width: HeroDots._activeWidth,
        height: HeroDots._thickness,
        child: progress == null
            ? ColoredBox(color: fill)
            : ColoredBox(color: track, child: progress),
      ),
    );
    final cycle = this.cycle;
    if (cycle == null || MediaQuery.disableAnimationsOf(context)) {
      return pill(null);
    }
    return ValueListenableBuilder<int?>(
      valueListenable: cycle,
      builder: (context, token, _) {
        if (token == null) return pill(null);
        return RepaintBoundary(
          child: pill(
            HeroCountdownFill(
              key: ValueKey(token),
              interval: interval,
              width: HeroDots._activeWidth,
              fill: fill,
            ),
          ),
        );
      },
    );
  }
}

/// 轮播倒计时填充:每前进一个物理像素才重建一次。
///
/// 20 逻辑像素宽的进度条在 7 秒里只有几十个可见状态。逐帧补间会让首页
/// 在没有任何交互时仍按屏幕刷新率(手机常见 90/120Hz)持续出帧,
/// CPU/GPU 与显示控制器都无法降频。这里改用按像素步进的计时器:
/// 外观相同,空闲首页的出帧次数降到每秒约 10 次以内。
@visibleForTesting
class HeroCountdownFill extends StatefulWidget {
  const HeroCountdownFill({
    super.key,
    required this.interval,
    required this.width,
    required this.fill,
  });

  final Duration interval;

  /// 填充轨道的逻辑宽度,用于按物理像素划分步数。
  final double width;
  final Color fill;

  @override
  State<HeroCountdownFill> createState() => HeroCountdownFillState();
}

@visibleForTesting
class HeroCountdownFillState extends State<HeroCountdownFill> {
  /// 两次重建的最短间隔:高 DPR 屏上也不比 30Hz 更密。
  static const minStep = Duration(milliseconds: 33);

  Timer? _timer;
  int _steps = 1;
  int _step = 0;

  /// 当前填充比例(0–1),已按步数量化。
  double get progress => _step / _steps;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    final byPixels = (widget.width * dpr).ceil();
    final byRate = widget.interval.inMicroseconds ~/ minStep.inMicroseconds;
    final steps = byPixels.clamp(1, byRate < 1 ? 1 : byRate);
    if (steps == _steps && _timer != null) return;
    // 步数变化(如窗口换到不同 DPR 的屏幕)时保持已走过的比例。
    final ratio = _steps == 0 ? 0.0 : _step / _steps;
    _steps = steps;
    _step = (ratio * steps).floor();
    _timer?.cancel();
    _timer = null;
    if (_step >= _steps) return;
    final period = Duration(
      microseconds: widget.interval.inMicroseconds ~/ _steps,
    );
    final start = _step;
    _timer = Timer.periodic(period, (timer) {
      // [Timer.tick] 计入被系统延后的周期,休眠唤醒后直接追到正确位置。
      final next = (start + timer.tick).clamp(0, _steps);
      if (next >= _steps) {
        timer.cancel();
        if (identical(_timer, timer)) _timer = null;
      }
      if (next != _step && mounted) setState(() => _step = next);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: FractionallySizedBox(
      widthFactor: progress,
      heightFactor: 1,
      child: ColoredBox(color: widget.fill),
    ),
  );
}

/// 轮播换页:淡入叠加轻微缩放(进场由 1.04 收到 1),比纯淡入更有层次。
Widget heroSlideTransition(Widget child, Animation<double> animation) {
  final curved = CurvedAnimation(parent: animation, curve: AppMotion.standard);
  return FadeTransition(
    opacity: curved,
    child: ScaleTransition(
      scale: Tween<double>(begin: 1.04, end: 1).animate(curved),
      child: child,
    ),
  );
}

/// 轮播换页时长:比常规过渡稍长,让大图交叉淡化不显生硬。
const heroSlideDuration = Duration(milliseconds: 420);

/// 桌面舞台背景换页时长:大图交叉淡化放慢一些,更接近影院转场。
const heroBackdropDuration = Duration(milliseconds: 680);

/// 桌面舞台背景换页:新图在旧图之上淡入并由 1.03 收到 1,旧图保持不透明
/// 直到被完全盖住。两层同时半透明的交叉淡化会在中途透出底色。
///
/// 缩放层比舞台各边多铺 2px 再硬裁。否则缩放落在半像素上时,底边会露出
/// 舞台底色,切换瞬间看起来像一条缝。
Widget heroBackdropTransition(Widget child, Animation<double> animation) {
  final entering = CurvedAnimation(
    parent: _EnterOnlyAnimation(animation),
    curve: AppMotion.standard,
  );
  return FadeTransition(
    opacity: entering,
    child: ClipRect(
      clipBehavior: Clip.hardEdge,
      child: ScaleTransition(
        scale: Tween<double>(begin: 1.03, end: 1).animate(entering),
        filterQuality: FilterQuality.none,
        child: _HeroBackdropBleed(child: child),
      ),
    ),
  );
}

/// 换页时两张图都铺满舞台,避免其中一张短暂变矮后在底部露出底色。
Widget heroBackdropLayout(Widget? current, List<Widget> previous) {
  return Stack(
    fit: StackFit.expand,
    clipBehavior: Clip.hardEdge,
    alignment: Alignment.center,
    children: [...previous, ?current],
  );
}

class _HeroBackdropBleed extends StatelessWidget {
  const _HeroBackdropBleed({required this.child});

  final Widget child;

  static const bleed = 2.0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final height = constraints.maxHeight;
        if (!width.isFinite || !height.isFinite) return child;
        return OverflowBox(
          alignment: Alignment.center,
          minWidth: width + bleed * 2,
          maxWidth: width + bleed * 2,
          minHeight: height + bleed * 2,
          maxHeight: height + bleed * 2,
          child: child,
        );
      },
    );
  }
}

/// 桌面舞台文字换页:旧文字先快速淡出,新文字随后上移淡入,两段文字
/// 不在同一位置叠印。配合 [heroCaptionInCurve] / [heroCaptionOutCurve]。
Widget heroCaptionTransition(Widget child, Animation<double> animation) {
  return FadeTransition(
    opacity: animation,
    child: SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(0, .06),
        end: Offset.zero,
      ).animate(animation),
      child: child,
    ),
  );
}

const Curve heroCaptionInCurve = Interval(.3, 1, curve: Curves.easeOutCubic);

/// 反向播放时 t 从 1 走到 0:前 45% 时长内旧文字就已完全淡出。
const Curve heroCaptionOutCurve = Interval(.55, 1, curve: Curves.easeIn);

/// 只在入场(forward)时跟随父动画,退场与静止时恒为 1。
class _EnterOnlyAnimation extends Animation<double>
    with AnimationWithParentMixin<double> {
  _EnterOnlyAnimation(this.parent);

  @override
  final Animation<double> parent;

  @override
  double get value =>
      parent.status == AnimationStatus.forward ? parent.value : 1;
}

/// 海报聚焦版式:海报放大模糊压暗铺底 + 清晰海报卡 + 文字槽。
/// Apple TV 风格,让只有海报的条目看起来是刻意设计而非降级。
///
/// 紧凑版式把 [actions] 放到整宽底部(文字列太窄放不下按钮),
/// 此时 [text] 应传 includeActions: false 的 [HeroTextBlock]。
///
/// 宽版舞台不传 [text]:文字层与遮罩由外层统一绘制并独立过渡,这里只画
/// 模糊铺底和 [insets] 内靠右下的清晰海报卡。
class HeroPosterSpotlight extends StatefulWidget {
  const HeroPosterSpotlight({
    super.key,
    required this.sources,
    required this.requestWidth,
    this.text,
    this.actions,
    this.compact = false,
    this.onResolved,
    this.insets = EdgeInsets.zero,
  });

  final HeroArtworkSources sources;
  final int requestWidth;

  /// 为 null 时只画铺底与海报卡(宽版舞台),文字由外层负责。
  final Widget? text;
  final Widget? actions;
  final bool compact;
  final ValueChanged<HeroArtworkData>? onResolved;

  /// 无 [text] 时海报卡的安全区:避开顶栏与右下角的切换控件。
  final EdgeInsets insets;

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
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadii.md),
              ),
              clipBehavior: Clip.antiAlias,
              child: Image.memory(
                _resolved!.bytes,
                fit: BoxFit.cover,
                cacheWidth: 480,
                filterQuality: FilterQuality.medium,
              ),
            ),
          );
    final background = HeroArtwork(
      sources: widget.sources,
      requestWidth: widget.requestWidth,
      compact: widget.compact,
      spotlightBackground: true,
      onResolved: _handleResolved,
    );
    final text = widget.text;
    if (text == null) {
      return Stack(
        fit: StackFit.expand,
        children: [
          background,
          Padding(
            padding: widget.insets,
            child: Align(alignment: Alignment.bottomRight, child: poster),
          ),
        ],
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        background,
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
                          Expanded(child: text),
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
                        Expanded(child: text),
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

  /// 当前计时周期编号;null 表示没有在倒计时。供 [HeroDots.cycle] 画进度。
  ValueListenable<int?> get rotateCycle => _rotateCycle;
  final ValueNotifier<int?> _rotateCycle = ValueNotifier(null);
  int _rotateCycleSeed = 0;
  int? _rotateCyclePending;
  bool _rotateCycleQueued = false;
  bool _rotateDisposed = false;
  AppLifecycleListener? _rotateLifecycle;

  /// A minimized or hidden window has no one watching: rotating there only
  /// rebuilds and decodes artwork for nothing. An unfocused window still counts
  /// as visible.
  static bool get _appVisible {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null ||
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
  }

  @override
  void initState() {
    super.initState();
    // Re-evaluate on every lifecycle change: arming is idempotent and the
    // check cancels the timer while the window is hidden.
    _rotateLifecycle = AppLifecycleListener(
      onStateChange: (_) => _queueRotateCheck(),
    );
  }

  // armAutoRotate 常在宿主 build 内调用,此时改通知值会让已挂载的
  // 监听者在构建期 markNeedsBuild;推迟到帧末统一发布最新值。
  void _publishCycle(int? value) {
    _rotateCyclePending = value;
    if (SchedulerBinding.instance.schedulerPhase !=
        SchedulerPhase.persistentCallbacks) {
      if (!_rotateDisposed) _rotateCycle.value = value;
      return;
    }
    if (_rotateCycleQueued) return;
    _rotateCycleQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _rotateCycleQueued = false;
      if (!_rotateDisposed) _rotateCycle.value = _rotateCyclePending;
    });
  }

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
    _rotateLifecycle?.dispose();
    _detachRotateScrolls();
    cancelAutoRotate();
    _rotateDisposed = true;
    _rotateCycle.dispose();
    super.dispose();
  }

  /// 宿主实现:推进到下一条。
  void advanceCarousel();

  bool _canAutoRotate(int itemCount) =>
      autoRotateAllowed &&
      _appVisible &&
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
      _publishCycle(null);
      if (_canAutoRotate(_rotateItemCount)) {
        advanceCarousel();
      }
    });
    _publishCycle(++_rotateCycleSeed);
  }

  void pauseAutoRotate() {
    _rotatePaused = true;
    _rotateTimer?.cancel();
    _rotateTimer = null;
    _publishCycle(null);
  }

  void resumeAutoRotate(int itemCount) {
    _rotatePaused = false;
    armAutoRotate(itemCount);
  }

  /// 手动切换后调用:重新计时。
  void resetAutoRotate(int itemCount) {
    _rotateTimer?.cancel();
    _rotateTimer = null;
    _publishCycle(null);
    armAutoRotate(itemCount);
  }

  void cancelAutoRotate() {
    final armed = _rotateTimer != null;
    _rotateTimer?.cancel();
    _rotateTimer = null;
    if (armed) _publishCycle(null);
  }
}
