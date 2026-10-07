import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_motion.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/home/featured_items.dart';
import 'package:rillight/home/hero_artwork.dart';
import 'package:rillight/home/hero_carousel.dart';
import 'package:rillight/home/hero_playback_actions.dart';
import 'package:rillight/player/player_window_host.dart';

/// 手机轮播:海报橱窗。
///
/// 当前条目的宣传图模糊后铺满整段并向下溶入页面底色,2:3 海报卡居中、邻卡
/// 两侧露边并缩小压暗;标题、元信息与「播放 / 详情」固定在海报下方的页面
/// 底色上,跟随主题取色,随翻页交叉淡化。竖屏手机的画面是海报而不是被压
/// 成一条的 16:9 横图。触摸暂停的 7 秒自动轮播,圆点带倒计时。
class PhoneHero extends StatefulWidget {
  const PhoneHero({
    super.key,
    required this.catalog,
    this.onItem,
    this.extendBehindTopBar = true,
  });

  final CatalogController catalog;
  final ValueChanged<EmbyItem>? onItem;

  /// 轮播排在首页第一位时伸进状态栏与透明顶栏之下;排在后面时不再预留。
  final bool extendBehindTopBar;

  static const bannerKey = Key('phone-hero');
  static const openKey = Key('phone-hero-open');
  static const maxFeatured = 5;
  static Key itemKey(String id) => ValueKey('phone-hero-$id');
  static List<EmbyItem> featuredItemsOf(CatalogController catalog) =>
      featuredHomeItems(catalog, limit: maxFeatured);

  /// 顶栏到海报、海报到文字、文字到按钮、按钮到圆点的垂直节奏。
  static const double topGap = 12;
  static const double posterGap = 14;
  static const double actionsGap = 14;
  static const double dotsGap = 0;
  static const double sidePadding = 24;
  static const double actionsHeight = 48;

  /// 圆点行高即其 44 的触控目标高,不另加间距。
  static const double dotsHeight = 44;

  /// 相邻海报之间的间距;邻卡从这条缝两侧露出。
  static const double posterSpacing = 16;

  /// 海报占视口高的上限;矮视口整段随之收缩而不是裁切。
  static const double posterViewportShare = .34;

  /// 海报高:占屏宽 56% 的 2:3 海报,再被 [posterViewportShare] 封顶,
  /// 夹在可读区间。
  static double posterHeightFor(double width, {double? viewportHeight}) {
    final byWidth = width * .56 * 1.5;
    final vh = viewportHeight;
    final byHeight = vh != null && vh.isFinite && vh > 0
        ? vh * posterViewportShare
        : double.infinity;
    return math.min(byWidth, byHeight).clamp(180.0, 330.0);
  }

  static double posterWidthFor(double width, {double? viewportHeight}) =>
      posterHeightFor(width, viewportHeight: viewportHeight) * 2 / 3;

  static double viewportFractionFor(double width, {double? viewportHeight}) =>
      width <= 0
      ? 1
      : ((posterWidthFor(width, viewportHeight: viewportHeight) +
                    posterSpacing) /
                width)
            .clamp(.3, 1.0);

  /// 文字区最小高:引导标签 + 两行标题 + 元信息行,标题不足两行时也占位,
  /// 翻页时下方按钮不会上下跳。
  static double textBlockHeightFor(double textScale) =>
      (16 + 6 + 22 * 1.2 * 2 + 6 + 20) * textScale;

  /// 顶栏以下的内容高(骨架屏与首页布局估算用)。
  static double contentHeightFor(
    double width, {
    double textScale = 1,
    double? viewportHeight,
  }) =>
      topGap +
      posterHeightFor(width, viewportHeight: viewportHeight) +
      posterGap +
      textBlockHeightFor(textScale) +
      actionsGap +
      actionsHeight +
      dotsGap +
      dotsHeight;

  @override
  State<PhoneHero> createState() => _PhoneHeroState();
}

class _PhoneHeroState extends State<PhoneHero> with HeroAutoRotate {
  int _index = 0;
  String? _reportedId;
  PageController _page = PageController();
  List<EmbyItem> get _featured => PhoneHero.featuredItemsOf(widget.catalog);

  @override
  void dispose() {
    cancelAutoRotate();
    _page.dispose();
    super.dispose();
  }

  /// viewportFraction 只能在构造时给定;横竖屏切换改了宽度就换一个
  /// 停在同一页的控制器,旧控制器等 PageView 解绑后再释放。
  PageController _controllerFor(double fraction) {
    if ((_page.viewportFraction - fraction).abs() < .001) return _page;
    final old = _page;
    _page = PageController(initialPage: _index, viewportFraction: fraction);
    WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    return _page;
  }

  /// 邻卡按离中心的距离缩小并压暗,当前卡保持原大。
  Widget _depth(int page, Widget child) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return AnimatedBuilder(
      animation: _page,
      child: child,
      builder: (context, child) {
        var current = _index.toDouble();
        if (_page.hasClients && _page.position.haveDimensions) {
          current = _page.page ?? current;
        }
        final distance = (current - page).abs().clamp(0.0, 1.0);
        return Transform.scale(
          scale: 1 - .12 * distance,
          child: Opacity(opacity: 1 - .5 * distance, child: child),
        );
      },
    );
  }

  HeroArtworkSources _artworkOf(EmbyItem item) =>
      heroArtworkSources(item, series: widget.catalog.latestSeries.items);

  /// 卡片实际画出的是海报时，进详情也带这张海报。横图只在没有海报时才用，
  /// 避免飞过去的是海报、落地后又换成背景，动态色跟着取两次。
  bool _posterLed(EmbyItem item) => _artworkOf(item).posters.isNotEmpty;

  void _open(EmbyItem item) {
    final media = MediaQuery.of(context);
    final posterWidth = PhoneHero.posterWidthFor(
      media.size.width,
      viewportHeight: media.size.height,
    );
    final requestWidth = (posterWidth * media.devicePixelRatio).round().clamp(
      400,
      800,
    );
    PhoneMotion.openItem(
      context,
      _artworkOf(item).handoffItem(item),
      preferBackdrop: !_posterLed(item),
      maxWidth: requestWidth,
    );
  }

  void _goTo(int value) {
    _page.animateToPage(
      value,
      duration: AppMotion.durationOf(context, AppMotion.slow),
      curve: AppMotion.emphasized,
    );
  }

  @override
  void advanceCarousel() {
    final count = _featured.length;
    if (count >= 2 && mounted) {
      _goTo((_index + 1) % count);
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _featured;
    if (items.isEmpty) return const SizedBox.shrink();
    armAutoRotate(items.length);
    final index = _index % items.length;
    final item = items[index];
    _report(item);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final viewport = MediaQuery.sizeOf(context).height;
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final top = widget.extendBehindTopBar
        ? MediaQuery.viewPaddingOf(context).top + 56
        : 0.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final posterHeight = PhoneHero.posterHeightFor(
          width,
          viewportHeight: viewport,
        );
        final posterWidth = posterHeight * 2 / 3;
        final requestWidth =
            (posterWidth * MediaQuery.devicePixelRatioOf(context))
                .round()
                .clamp(400, 800);
        final controller = _controllerFor(
          PhoneHero.viewportFractionFor(width, viewportHeight: viewport),
        );
        final ambient = _artworkOf(item);
        return Listener(
          key: PhoneHero.bannerKey,
          onPointerDown: (_) => pauseAutoRotate(),
          onPointerUp: (_) => resumeAutoRotate(items.length),
          onPointerCancel: (_) => resumeAutoRotate(items.length),
          child: Stack(
            children: [
              Positioned.fill(
                child: _Ambient(
                  itemId: item.id,
                  sources: ambient,
                  requestWidth: requestWidth,
                  surface: scheme.surface,
                  dark: theme.brightness == Brightness.dark,
                ),
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(height: top + PhoneHero.topGap),
                  SizedBox(
                    height: posterHeight,
                    child: PageView.builder(
                      controller: controller,
                      clipBehavior: Clip.none,
                      physics: items.length > 1
                          ? const PageScrollPhysics()
                          : const NeverScrollableScrollPhysics(),
                      itemCount: items.length,
                      onPageChanged: (value) {
                        setState(() => _index = value);
                        resetAutoRotate(items.length);
                      },
                      itemBuilder: (context, page) => _poster(
                        items[page],
                        page: page,
                        index: index,
                        count: items.length,
                        width: posterWidth,
                        height: posterHeight,
                        requestWidth: requestWidth,
                      ),
                    ),
                  ),
                  const SizedBox(height: PhoneHero.posterGap),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: PhoneHero.sidePadding,
                    ),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: PhoneHero.textBlockHeightFor(scale),
                      ),
                      child: AnimatedSwitcher(
                        duration: AppMotion.durationOf(context, AppMotion.slow),
                        switchInCurve: AppMotion.standard,
                        switchOutCurve: AppMotion.exit,
                        transitionBuilder: _textTransition,
                        child: _Caption(
                          key: ValueKey('phone-hero-caption-${item.id}'),
                          item: item,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: PhoneHero.actionsGap),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: PhoneHero.sidePadding,
                    ),
                    child: HeroPlaybackActions(
                      key: ValueKey('phone-hero-actions-${item.id}'),
                      item: item,
                      expand: true,
                      catalog: widget.catalog,
                      onDetails: () => _open(item),
                      onResume: () => _play(item),
                    ),
                  ),
                  const SizedBox(height: PhoneHero.dotsGap),
                  SizedBox(
                    height: PhoneHero.dotsHeight,
                    child: items.length > 1
                        ? Center(
                            child: HeroDots(
                              index: index,
                              count: items.length,
                              onSelect: (i) {
                                _goTo(i);
                                resetAutoRotate(items.length);
                              },
                              onScrim: false,
                              cycle: rotateCycle,
                            ),
                          )
                        : null,
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  static Widget _textTransition(Widget child, Animation<double> animation) {
    return FadeTransition(
      opacity: animation,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, .08),
          end: Offset.zero,
        ).animate(animation),
        child: child,
      ),
    );
  }

  Widget _poster(
    EmbyItem item, {
    required int page,
    required int index,
    required int count,
    required double width,
    required double height,
    required int requestWidth,
  }) {
    final current = page == index;
    final l10n = AppLocalizations.of(context);
    final card = Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      elevation: current ? 10 : 2,
      shadowColor: Colors.black.withValues(alpha: .6),
      borderRadius: BorderRadius.circular(AppRadii.lg),
      clipBehavior: Clip.antiAlias,
      child: HeroArtwork(
        sources: _artworkOf(item),
        requestWidth: requestWidth,
        compact: true,
        posterFirst: true,
      ),
    );
    return KeyedSubtree(
      key: PhoneHero.itemKey(item.id),
      child: _depth(
        page,
        Center(
          child: SizedBox(
            width: width,
            height: height,
            child: Semantics(
              button: true,
              label: '${l10n.heroItemOf(page + 1, count)} ${heroTitle(item)}',
              child: GestureDetector(
                key: current ? PhoneHero.openKey : null,
                behavior: HitTestBehavior.opaque,
                // 点当前海报进详情;点露出的邻卡先把它滑到中间。
                onTap: current
                    ? () => _open(item)
                    : () {
                        _goTo(page);
                        resetAutoRotate(count);
                      },
                child: card,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _play(EmbyItem item) async {
    final l10n = AppLocalizations.of(context);
    final target = await resolveHeroPlayTarget(
      context,
      item,
      catalog: widget.catalog,
    );
    if (!mounted) return;
    if (target == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.noPlayableStream)));
      return;
    }
    await context.push<void>(
      '/play/${target.id}',
      extra: PlayerOpenRequest(itemId: target.id, autoResume: true),
    );
  }

  void _report(EmbyItem item) {
    final callback = widget.onItem;
    if (callback == null || _reportedId == item.id) return;
    _reportedId = item.id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _reportedId == item.id) callback(item);
    });
  }
}

/// 当前条目宣传图的模糊底:上端留出透明顶栏可读的底色,向下溶成页面底色,
/// 文字与按钮正好落在实色区。随条目切换交叉淡化。
class _Ambient extends StatelessWidget {
  const _Ambient({
    required this.itemId,
    required this.sources,
    required this.requestWidth,
    required this.surface,
    required this.dark,
  });

  final String itemId;
  final HeroArtworkSources sources;
  final int requestWidth;
  final Color surface;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: [
            AnimatedSwitcher(
              duration: AppMotion.durationOf(context, heroSlideDuration),
              switchInCurve: AppMotion.standard,
              switchOutCurve: AppMotion.exit,
              child: RepaintBoundary(
                key: ValueKey('phone-hero-ambient-$itemId'),
                child: HeroArtwork(
                  sources: sources,
                  requestWidth: requestWidth,
                  compact: true,
                  posterFirst: true,
                  ambient: true,
                ),
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: const [0, .42, .78, 1],
                  colors: [
                    surface.withValues(alpha: dark ? .45 : .55),
                    surface.withValues(alpha: dark ? .55 : .62),
                    surface,
                    surface,
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 海报下方的文字:引导标签 → 标题(居中,最多两行) → 年份 · 流派 · 时长 ★。
class _Caption extends StatelessWidget {
  const _Caption({super.key, required this.item});

  final EmbyItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final meta = heroMetaLabels(l10n, item);
    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        HeroKicker(label: heroKicker(l10n, item), onScrim: false),
        const SizedBox(height: 6),
        Text(
          heroTitle(item),
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
            height: 1.2,
          ),
        ),
        if (meta.isNotEmpty || item.communityRating != null) ...[
          const SizedBox(height: 6),
          Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (meta.isNotEmpty)
                Flexible(
                  child: Text(
                    meta.join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.3,
                    ),
                  ),
                ),
              if (item.communityRating != null) ...[
                if (meta.isNotEmpty) const SizedBox(width: 8),
                HeroRatingBadge(rating: item.communityRating, onScrim: false),
              ],
            ],
          ),
        ],
      ],
    );
  }
}
