import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_motion.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/library/detail_controller.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/home/featured_items.dart';
import 'package:rillight/home/hero_artwork.dart';
import 'package:rillight/home/hero_carousel.dart';
import 'package:rillight/home/hero_playback_actions.dart';
import 'package:rillight/media_image/media_image.dart';
import 'package:rillight/player/player_window_host.dart';

/// 全出血轮播:图片铺满整卡,渐变遮罩上排标题与按钮,
/// 触摸暂停的 7 秒自动轮播;仅海报的条目走海报聚焦版式。
class PhoneHero extends StatefulWidget {
  const PhoneHero({super.key, required this.catalog, this.onItem});
  final CatalogController catalog;
  final ValueChanged<EmbyItem>? onItem;
  static const bannerKey = Key('phone-hero');
  static const openKey = Key('phone-hero-open');
  static const maxFeatured = 5;
  static Key itemKey(String id) => ValueKey('phone-hero-$id');
  static List<EmbyItem> featuredItemsOf(CatalogController catalog) =>
      featuredHomeItems(catalog, limit: maxFeatured);

  /// 当前卡距屏幕边缘的距离;相邻卡之间留 [cardGap],
  /// 两侧各露出 [cardInset] - [cardGap] 宽的邻卡,提示可以横滑。
  static const double cardInset = 24;
  static const double cardGap = 8;
  static double cardWidthFor(double width) => width - cardInset * 2;
  static double viewportFractionFor(double width) =>
      width <= 0 ? 1 : ((cardWidthFor(width) + cardGap) / width).clamp(.5, 1.0);
  static double contentHeightFor(double width, {double textScale = 1}) =>
      cardWidthFor(width) * 9 / 16 + 120 * textScale + 44;

  @override
  State<PhoneHero> createState() => _PhoneHeroState();
}

class _PhoneHeroState extends State<PhoneHero> with HeroAutoRotate {
  int _index = 0;
  String? _reportedId;
  PageController _page = PageController();
  final Map<String, HeroLayout> _layoutOverride = {};
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
          scale: 1 - .06 * distance,
          child: Opacity(opacity: 1 - .35 * distance, child: child),
        );
      },
    );
  }

  void _open(EmbyItem item) {
    final artwork = heroArtworkSources(
      item,
      series: widget.catalog.latestSeries.items,
    );
    PhoneMotion.openItem(
      context,
      artwork.handoffItem(item),
      preferBackdrop: true,
      maxWidth: PhoneMotion.heroRequestWidth,
    );
  }

  void _goTo(int value) {
    _page.animateToPage(
      value,
      duration: AppMotion.durationOf(context),
      curve: AppMotion.standard,
    );
  }

  @override
  void advanceCarousel() {
    final count = _featured.length;
    if (count >= 2 && mounted) {
      _goTo((_index + 1) % count);
    }
  }

  void _onArtworkResolved(
    EmbyItem item,
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

  @override
  Widget build(BuildContext context) {
    final items = _featured;
    if (items.isEmpty) return const SizedBox.shrink();
    armAutoRotate(items.length);
    final index = _index % items.length;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final top = MediaQuery.viewPaddingOf(context).top + 56;
        final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
        final height =
            top + PhoneHero.contentHeightFor(width, textScale: scale);
        final controller = _controllerFor(PhoneHero.viewportFractionFor(width));
        _report(items[index]);
        return SizedBox(
          key: PhoneHero.bannerKey,
          width: width,
          height: height,
          child: Padding(
            padding: EdgeInsets.only(top: top),
            child: Column(
              children: [
                Expanded(
                  child: Listener(
                    onPointerDown: (_) => pauseAutoRotate(),
                    onPointerUp: (_) => resumeAutoRotate(items.length),
                    onPointerCancel: (_) => resumeAutoRotate(items.length),
                    child: PageView.builder(
                      controller: controller,
                      clipBehavior: Clip.none,
                      physics: items.length > 1
                          ? const PageScrollPhysics()
                          : const NeverScrollableScrollPhysics(),
                      itemCount: items.length,
                      onPageChanged: (value) {
                        setState(() => _index = value);
                        _report(items[value]);
                        resetAutoRotate(items.length);
                      },
                      itemBuilder: (context, page) {
                        final item = items[page];
                        return KeyedSubtree(
                          key: PhoneHero.itemKey(item.id),
                          child: _depth(
                            page,
                            _pageCard(context, item, page == index, width),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                if (items.length > 1)
                  HeroDots(
                    index: index,
                    count: items.length,
                    onSelect: (i) {
                      _goTo(i);
                      resetAutoRotate(items.length);
                    },
                    onScrim: false,
                    cycle: rotateCycle,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _pageCard(
    BuildContext context,
    EmbyItem item,
    bool current,
    double width,
  ) {
    final artwork = heroArtworkSources(
      item,
      series: widget.catalog.latestSeries.items,
    );
    final layout = _layoutOverride[item.id] ?? heroLayoutFor(artwork);
    final requestWidth = mediaHeroBackdropRequestWidth(
      layoutWidth: PhoneHero.cardWidthFor(width),
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
    );
    final actions = HeroPlaybackActions(
      item: item,
      onDetails: () => _open(item),
      onResume: () => _resume(item),
    );
    final text = HeroTextBlock(
      item: item,
      compact: true,
      includeActions: layout == HeroLayout.fullBleed,
      actions: actions,
    );
    final artworkWidget = RepaintBoundary(
      child: PhoneMotion.sharedImage(
        itemId: item.id,
        preferBackdrop: true,
        child: HeroArtwork(
          sources: artwork,
          requestWidth: requestWidth,
          compact: true,
          onResolved: (data) => _onArtworkResolved(item, artwork, data),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: PhoneHero.cardGap / 2),
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(24),
        clipBehavior: Clip.antiAlias,
        elevation: current ? 3 : 0,
        shadowColor: Colors.black54,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (layout == HeroLayout.fullBleed) ...[
              GestureDetector(
                key: current ? PhoneHero.openKey : null,
                onTap: () => _open(item),
                child: artworkWidget,
              ),
              const HeroScrim(),
              Positioned(left: 20, right: 20, bottom: 16, child: text),
            ] else
              GestureDetector(
                key: current ? PhoneHero.openKey : null,
                onTap: () => _open(item),
                child: HeroPosterSpotlight(
                  sources: artwork,
                  requestWidth: requestWidth,
                  compact: true,
                  text: text,
                  actions: actions,
                  onResolved: (data) => _onArtworkResolved(item, artwork, data),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _resume(EmbyItem item) async {
    final l10n = AppLocalizations.of(context);
    var target = item;
    if (item.isSeries) {
      final controller = DetailController(
        auth: AuthScope.of(context),
        cache: CatalogScope.of(context).cache,
        itemId: item.id,
      );
      try {
        controller.applyItem(item);
        await controller.loadSeasons();
        await controller.retainOffPageResume();
        final resolved = controller.playTarget;
        if (!mounted) return;
        if (resolved == null || !resolved.isPlayable) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(l10n.noPlayableStream)));
          return;
        }
        target = resolved;
      } finally {
        controller.dispose();
      }
    }
    if (!mounted) return;
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
