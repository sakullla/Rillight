import 'dart:math' as math;

import 'package:rillight/app/ui/ui.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/widgets/skeleton.dart';
import 'package:rillight/media_server/models.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/featured_items.dart';
import 'package:rillight/home/hero_artwork.dart';
import 'package:rillight/home/hero_carousel.dart';
import 'package:rillight/home/hero_logo.dart';
import 'package:rillight/home/hero_playback_actions.dart';
import 'package:rillight/media_image/media_image.dart';

/// 桌面首页轮播。
///
/// 在 [AppShell] 内([topOverlap] > 0)是贴满窗口宽度的全出血舞台:画面从窗口
/// 上缘铺到下方货架,底缘渐隐融进页面底色。深色主题的文字直接压在遮罩上;
/// 浅色主题把说明收进纸色卡片,播放用强调色。文字与货架标题对齐同一条页边线,
/// 切换控件([‹] 圆点 [›])收在右下角,不压标题。
/// 独立嵌入(测试、无外壳)时退回带页边距的圆角卡片。
///
/// 背景、遮罩、文字三层分开:遮罩常驻不随换页闪烁;新背景在旧背景之上淡入;
/// 旧文字先淡出、新文字再上移淡入。下一条的图片提前解码,换页时不闪底色。
/// 候选只来自片库最近入库,不含观看记录。
class HomeHero extends StatefulWidget {
  const HomeHero({super.key, required this.catalog, this.topOverlap = 0});
  final CatalogController catalog;
  final double topOverlap;
  static const maxFeatured = 5;

  /// 舞台总高(含顶栏叠加区):首选视口 68%,仍露出下一条货架。
  /// 通常落在 16:9 到 2.4:1;短屏和超宽屏以视口上限为先。
  static double heightFor(double width, {double? viewportHeight}) {
    final viewport = viewportHeight ?? 900;
    final preferred = (viewport * .68).clamp(width / 2.4, width * 9 / 16);
    return math.min(preferred, viewport * .76).clamp(360.0, 1200.0);
  }

  static bool showsOverview(double width, {double? viewportHeight}) =>
      width >= 720;

  /// 宽屏标题升一档。
  static bool largeFor(double width) => width >= 1100;

  static double textBlockWidthFor(double width) => math.min(width * .46, 640);

  @override
  State<HomeHero> createState() => _HomeHeroState();
}

class _HomeHeroState extends State<HomeHero> with HeroAutoRotate {
  int _index = 0;
  bool _hovered = false;
  bool _focusWithin = false;
  final Map<String, HeroLayout> _layoutOverride = {};

  /// 右下切换控件尺寸:箭头 48,圆点命中区 44。
  static const double _controlExtent = 48;

  bool get _stage => widget.topOverlap > 0;

  void _select(int value, int count) {
    setState(() => _index = (value % count + count) % count);
    resetAutoRotate(count);
  }

  /// 鼠标拖拽或触控板/触屏横扫翻页;速度过低视为误触。
  void _onSwipe(DragEndDetails details, int count) {
    final velocity = details.primaryVelocity ?? 0;
    if (count < 2 || velocity.abs() < 280) return;
    _select(_index + (velocity < 0 ? 1 : -1), count);
  }

  @override
  void advanceCarousel() {
    final count = featuredHomeItems(
      widget.catalog,
      limit: HomeHero.maxFeatured,
    ).length;
    if (count >= 2 && mounted) {
      setState(() => _index = (_index + 1) % count);
    }
  }

  @override
  void dispose() {
    cancelAutoRotate();
    super.dispose();
  }

  /// 背景图校验失败落到海报时修正版式(反之亦然),按条目记忆。
  void _onArtworkResolved(
    MediaItem item,
    HeroArtworkSources sources,
    HeroArtworkData data,
  ) {
    final guessed = _layoutOverride[item.id] ?? heroLayoutFor(sources);
    final actual = data.poster
        ? HeroLayout.posterSpotlight
        : HeroLayout.fullBleed;
    if (guessed == actual) return;
    setState(() => _layoutOverride[item.id] = actual);
  }

  /// 全出血舞台的底缘渐隐就是和下一条货架的间距,不再另加底边距。
  bool get _fadesIntoPage => _stage;

  bool get _gallery => AppUiTheme.of(context).brightness == Brightness.light;

  EdgeInsets get _outerPadding => _stage
      ? EdgeInsets.only(bottom: _fadesIntoPage ? 0 : AppSpacing.md)
      : const EdgeInsets.fromLTRB(
          AppSpacing.page,
          AppSpacing.md,
          AppSpacing.page,
          AppSpacing.md,
        );

  BorderRadius get _radius =>
      _stage ? BorderRadius.zero : BorderRadius.circular(24);

  /// 舞台高度;骨架屏与真实内容共用,加载完成时不跳版。
  double _heightFor(BuildContext context, double width) {
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final viewport = MediaQuery.sizeOf(context).height;
    final base = HomeHero.heightFor(width, viewportHeight: viewport);
    if (width < 720) {
      return (math.max(base, widget.topOverlap + 276 * scale + 32) + 180)
          .roundToDouble();
    }
    // 文字块(两行标题 + 三行简介 + 按钮)加上下留白的最低需求。
    // 浅色说明卡自带内边距,再留一截避免卡片顶被舞台裁切。
    // 取整到整像素:小数高度的最后一行会透出底色,在渐隐边缘留一条暗线。
    final textFloor = (HomeHero.largeFor(width) ? 364 : 338) * scale;
    final card = _gallery ? 28.0 : 0.0;
    return math.max(base, widget.topOverlap + textFloor + card).roundToDouble();
  }

  @override
  Widget build(BuildContext context) {
    final items = featuredHomeItems(
      widget.catalog,
      limit: HomeHero.maxFeatured,
    );
    if (items.isEmpty) {
      if (!widget.catalog.latestMovies.loading &&
          !widget.catalog.latestSeries.loading) {
        return const SizedBox.shrink();
      }
      return Padding(
        padding: _outerPadding,
        child: LayoutBuilder(
          builder: (context, constraints) => SkeletonBlock(
            width: double.infinity,
            height: _heightFor(context, constraints.maxWidth),
            borderRadius: _radius,
          ),
        ),
      );
    }
    armAutoRotate(items.length);
    final index = _index % items.length;
    final item = items[index];
    return Padding(
      padding: _outerPadding,
      child: MouseRegion(
        onEnter: (_) {
          pauseAutoRotate();
          setState(() => _hovered = true);
        },
        onExit: (_) {
          resumeAutoRotate(items.length);
          setState(() => _hovered = false);
        },
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final compact = width < 720;
            final height = _heightFor(context, width);
            final content = compact
                ? _compactSlides(context, item, items, index, width)
                : _stageLayers(context, item, items, index, width);
            final theme = AppUiTheme.of(context);
            return Container(
              decoration: BoxDecoration(
                color: theme.brightness == Brightness.light
                    ? theme.scaffoldBackgroundColor
                    : const Color(0xff000000),
              ),
              key: const Key('home-hero-card'),
              clipBehavior: Clip.antiAlias,
              child: AppSurfaceAction(
                key: const Key('home-hero-details-target'),
                onTap: () => context.push(AppRoutes.item(item.id)),
                child: GestureDetector(
                  onHorizontalDragEnd: items.length > 1
                      ? (details) => _onSwipe(details, items.length)
                      : null,
                  child: Focus(
                    canRequestFocus: false,
                    skipTraversal: true,
                    onFocusChange: (value) =>
                        setState(() => _focusWithin = value),
                    child: SizedBox(height: height, child: content),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  int _requestWidth(BuildContext context, double width) =>
      mediaHeroBackdropRequestWidth(
        layoutWidth: width,
        devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      );

  HeroPlaybackActions _actions(BuildContext context, MediaItem item) =>
      HeroPlaybackActions(
        key: ValueKey('hero-actions-${item.id}'),
        item: item,
        catalog: widget.catalog,
        onDetails: () => context.push(AppRoutes.item(item.id)),
      );

  /// 宽版舞台:背景层 / 常驻遮罩 / 文字层 / 右下控件,各自独立过渡。
  Widget _stageLayers(
    BuildContext context,
    MediaItem item,
    List<MediaItem> items,
    int index,
    double width,
  ) {
    final theme = AppUiTheme.of(context);
    final artwork = heroArtworkSources(
      item,
      series: widget.catalog.latestSeries.items,
    );
    final layout = _layoutOverride[item.id] ?? heroLayoutFor(artwork);
    final requestWidth = _requestWidth(context, width);
    final inset = _stage ? AppSpacing.page : AppSpacing.xxl;
    const bottom = AppSpacing.huge;
    final multiple = items.length > 1;
    final controlsWidth = multiple
        ? _controlExtent * 2 + AppSpacing.xxs * 2 + items.length * 44.0 + 8
        : 0.0;
    final textWidth = math.max(
      240.0,
      math.min(
        HomeHero.textBlockWidthFor(width),
        width - inset * 2 - controlsWidth - AppSpacing.xl,
      ),
    );
    final fade = _gallery || _fadesIntoPage
        ? theme.scaffoldBackgroundColor
        : null;
    final large = HomeHero.largeFor(width);
    final logoWidth = math.min(textWidth * .8, large ? 460.0 : 360.0);

    final Widget backdrop = layout == HeroLayout.fullBleed
        ? HeroArtwork(
            key: ValueKey('hero-artwork-${item.id}'),
            sources: artwork,
            requestWidth: requestWidth,
            onResolved: (data) => _onArtworkResolved(item, artwork, data),
          )
        : HeroPosterSpotlight(
            key: ValueKey('hero-spotlight-${item.id}'),
            sources: artwork,
            requestWidth: requestWidth,
            insets: EdgeInsets.fromLTRB(
              inset + textWidth + AppSpacing.xl,
              widget.topOverlap + AppSpacing.xl,
              inset,
              bottom + (multiple ? _controlExtent + AppSpacing.md : 0),
            ),
            onResolved: (data) => _onArtworkResolved(item, artwork, data),
          );

    // 只预取下一条(悬停/聚焦时连上一条),换页时新图已解码就绪。
    final prefetch = <MediaItem>{
      if (multiple) items[(index + 1) % items.length],
      if (multiple && items.length > 2 && (_hovered || _focusWithin))
        items[(index - 1 + items.length) % items.length],
    };

    return Stack(
      fit: StackFit.expand,
      children: [
        for (final next in prefetch)
          Offstage(
            key: ValueKey('hero-prefetch-${next.id}'),
            child: Stack(
              children: [
                HeroArtwork(
                  sources: heroArtworkSources(
                    next,
                    series: widget.catalog.latestSeries.items,
                  ),
                  requestWidth: requestWidth,
                  prefetch: true,
                ),
                if (HeroLogo.available(next))
                  HeroLogo(
                    item: next,
                    fallback: const SizedBox.shrink(),
                    maxWidth: logoWidth,
                    maxHeight: HeroTextBlock.logoMaxHeightFor(large: large),
                    prefetch: true,
                  ),
              ],
            ),
          ),
        AnimatedSwitcher(
          duration: AppMotion.durationOf(context, heroBackdropDuration),
          transitionBuilder: heroBackdropTransition,
          layoutBuilder: heroBackdropLayout,
          child: RepaintBoundary(
            key: ValueKey('home-hero-slide-${item.id}'),
            child: backdrop,
          ),
        ),
        HeroScrim(
          top: _fadesIntoPage && !_gallery,
          leading: true,
          fadeTo: fade,
          gallery: _gallery,
        ),
        if (_gallery)
          Positioned(
            left: inset,
            right: inset,
            bottom: AppSpacing.lg,
            child: _galleryCaption(
              item: item,
              textWidth: textWidth,
              large: large,
              logoWidth: logoWidth,
              showOverview: HomeHero.showsOverview(width),
              controls: multiple ? _controlCluster(index, items) : null,
            ),
          )
        else ...[
          Positioned(
            left: inset,
            right: inset,
            bottom: bottom,
            child: Align(
              alignment: Alignment.bottomLeft,
              child: SizedBox(
                width: textWidth,
                child: _captionSwitcher(
                  item: item,
                  large: large,
                  logoWidth: logoWidth,
                  showOverview: HomeHero.showsOverview(width),
                ),
              ),
            ),
          ),
          if (multiple)
            Positioned(
              right: inset - AppSpacing.xxs,
              bottom: bottom + (48 - _controlExtent) / 2,
              child: _controlCluster(index, items),
            ),
        ],
      ],
    );
  }

  Widget _captionSwitcher({
    required MediaItem item,
    required bool large,
    required double logoWidth,
    required bool showOverview,
    bool compact = false,
  }) {
    return AnimatedSwitcher(
      duration: AppMotion.durationOf(context, heroSlideDuration),
      switchInCurve: heroCaptionInCurve,
      switchOutCurve: heroCaptionOutCurve,
      transitionBuilder: heroCaptionTransition,
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.bottomLeft,
        children: [...previous, ?current],
      ),
      child: HeroTextBlock(
        key: ValueKey('home-hero-text-${item.id}'),
        item: item,
        large: large,
        compact: compact,
        logoMaxWidth: logoWidth,
        showOverview: showOverview,
        onPaper: _gallery,
        actions: _actions(context, item),
      ),
    );
  }

  /// 浅色说明:文字直接落在纸色渐变上(遮罩从左下融进页面),切换控件贴右、与按钮底对齐。
  Widget _galleryCaption({
    required MediaItem item,
    required double textWidth,
    required bool large,
    required double logoWidth,
    required bool showOverview,
    required Widget? controls,
    bool compact = false,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Flexible(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: textWidth),
            child: _captionSwitcher(
              item: item,
              large: large,
              logoWidth: logoWidth,
              showOverview: showOverview,
              compact: compact,
            ),
          ),
        ),
        if (controls != null) ...[const Spacer(), controls],
      ],
    );
  }

  /// [‹] 圆点 [›]:圆点常驻;箭头只在悬停或键盘焦点在卡内时浮现,
  /// 透明时仍可点击,触屏桌面不会失去入口。
  Widget _controlCluster(int index, List<MediaItem> items) {
    final l10n = AppLocalizations.of(context);
    final reveal = _hovered || _focusWithin;
    final fade = AppMotion.durationOf(context, AppMotion.normal);
    Widget arrow({required bool left, required Widget child}) =>
        AnimatedOpacity(
          opacity: reveal ? 1 : 0,
          duration: fade,
          curve: AppMotion.standard,
          child: AnimatedSlide(
            offset: reveal ? Offset.zero : Offset(left ? .2 : -.2, 0),
            duration: fade,
            curve: AppMotion.standard,
            child: child,
          ),
        );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        arrow(
          left: true,
          child: _chevron(
            key: CatalogKeys.heroPrev,
            tooltip: l10n.scrollLeft,
            icon: CupertinoIcons.chevron_left,
            extent: _controlExtent,
            onPressed: () => _select(index - 1, items.length),
          ),
        ),
        const SizedBox(width: AppSpacing.xxs),
        HeroDots(
          index: index,
          count: items.length,
          // A continuous countdown keeps the whole desktop window waking
          // at the display refresh rate even when no one is interacting.
          // Keep the selected dot static; the rotation timer still works.
          onSelect: (i) => _select(i, items.length),
          onScrim: !_gallery,
          activeColor: _gallery
              ? AppUiTheme.of(context).colorScheme.primary
              : null,
        ),
        const SizedBox(width: AppSpacing.xxs),
        arrow(
          left: false,
          child: _chevron(
            key: CatalogKeys.heroNext,
            tooltip: l10n.scrollRight,
            icon: CupertinoIcons.chevron_right,
            extent: _controlExtent,
            onPressed: () => _select(index + 1, items.length),
          ),
        ),
      ],
    );
  }

  /// 窄窗口(<720):文字叠在画面底部整宽排布,整页一起淡入切换。
  Widget _compactSlides(
    BuildContext context,
    MediaItem item,
    List<MediaItem> items,
    int index,
    double width,
  ) {
    final artwork = heroArtworkSources(
      item,
      series: widget.catalog.latestSeries.items,
    );
    final layout = _layoutOverride[item.id] ?? heroLayoutFor(artwork);
    final requestWidth = _requestWidth(context, width);
    final actions = _actions(context, item);
    final light = _gallery && layout == HeroLayout.fullBleed;
    final fade = light ? AppUiTheme.of(context).scaffoldBackgroundColor : null;
    final text = HeroTextBlock(
      item: item,
      compact: true,
      includeActions: layout == HeroLayout.fullBleed,
      onPaper: light,
      actions: actions,
    );
    final Widget visual = layout == HeroLayout.fullBleed
        ? Stack(
            fit: StackFit.expand,
            children: [
              HeroArtwork(
                key: ValueKey('hero-artwork-${item.id}'),
                sources: artwork,
                requestWidth: requestWidth,
                compact: true,
                onResolved: (data) => _onArtworkResolved(item, artwork, data),
              ),
              HeroScrim(top: _stage && !light, fadeTo: fade, gallery: light),
              Positioned(left: 20, right: 20, bottom: 20, child: text),
            ],
          )
        : HeroPosterSpotlight(
            key: ValueKey('hero-spotlight-${item.id}'),
            sources: artwork,
            requestWidth: requestWidth,
            compact: true,
            text: text,
            actions: actions,
            onResolved: (data) => _onArtworkResolved(item, artwork, data),
          );
    return Stack(
      fit: StackFit.expand,
      children: [
        AnimatedSwitcher(
          duration: AppMotion.durationOf(context, heroSlideDuration),
          transitionBuilder: heroSlideTransition,
          child: RepaintBoundary(
            key: ValueKey('home-hero-slide-${item.id}'),
            child: visual,
          ),
        ),
        if (items.length > 1) ..._compactControls(index, items),
      ],
    );
  }

  List<Widget> _compactControls(int index, List<MediaItem> items) {
    final l10n = AppLocalizations.of(context);
    final reveal = _hovered || _focusWithin;
    final fade = AppMotion.durationOf(context, AppMotion.normal);
    Widget side({required bool left, required Widget child}) => Positioned(
      left: left ? 8 : null,
      right: left ? null : 8,
      top: widget.topOverlap,
      bottom: 0,
      child: Center(
        child: AnimatedOpacity(
          opacity: reveal ? 1 : 0,
          duration: fade,
          curve: AppMotion.standard,
          child: child,
        ),
      ),
    );
    return [
      side(
        left: true,
        child: _chevron(
          key: CatalogKeys.heroPrev,
          tooltip: l10n.scrollLeft,
          icon: CupertinoIcons.chevron_left,
          onPressed: () => _select(index - 1, items.length),
        ),
      ),
      side(
        left: false,
        child: _chevron(
          key: CatalogKeys.heroNext,
          tooltip: l10n.scrollRight,
          icon: CupertinoIcons.chevron_right,
          onPressed: () => _select(index + 1, items.length),
        ),
      ),
      Positioned(
        right: 20,
        bottom: 16,
        child: HeroDots(
          index: index,
          count: items.length,
          onSelect: (i) => _select(i, items.length),
          onScrim: !_gallery,
          activeColor: _gallery
              ? AppUiTheme.of(context).colorScheme.primary
              : null,
        ),
      ),
    ];
  }

  Widget _chevron({
    required Key key,
    required String tooltip,
    required IconData icon,
    required VoidCallback onPressed,
    double extent = 48,
  }) {
    final scheme = AppUiTheme.of(context).colorScheme;
    final light = _gallery;
    return AppIconButton(
      key: key,
      tooltip: tooltip,
      onPressed: onPressed,
      size: 26,
      style: AppButtonStyle(
        minimumSize: Size.square(extent),
        fixedSize: Size.square(extent),
        padding: EdgeInsets.zero,
        backgroundColor: light
            ? scheme.surfaceContainerLowest
            : const Color(0xff000000).withValues(alpha: .42),
        foregroundColor: light ? scheme.onSurface : const Color(0xffffffff),
        hoverColor: light
            ? scheme.onSurface.withValues(alpha: .06)
            : const Color(0xffffffff).withValues(alpha: .14),
        side: BorderSide(
          color: light
              ? scheme.outlineVariant
              : const Color(0xffffffff).withValues(alpha: .16),
        ),
      ),
      icon: Icon(icon),
    );
  }
}
