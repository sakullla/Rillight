import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_motion.dart';
import 'package:rillight/app/widgets/hero_palette_overlay.dart';
import 'package:rillight/media_server/models.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/home/featured_items.dart';
import 'package:rillight/home/hero_artwork.dart';
import 'package:rillight/home/hero_carousel.dart';
import 'package:rillight/home/hero_logo.dart';
import 'package:rillight/home/hero_playback_actions.dart';
import 'package:rillight/player/player_window_host.dart';

/// 手机首页头图:整屏宽的影院橱窗。
///
/// 当前条目的横版剧照铺满整段并伸进状态栏,向下溶入页面底色;片名 Logo
/// (没有 Logo 时是大号片名)、年份/类型/时长/评分与「播放 / 详情」叠在画面
/// 下缘。左右滑动翻页,剧照随滑动有轻微视差;触摸暂停 7 秒自动轮播,
/// 圆点带倒计时。条目只有海报时,海报完整地居中压在自身的模糊底上。
class PhoneHero extends StatefulWidget {
  const PhoneHero({
    super.key,
    required this.catalog,
    this.onItem,
    this.extendBehindTopBar = true,
  });

  final CatalogController catalog;
  final ValueChanged<MediaItem>? onItem;

  /// 轮播排在首页第一位时伸进状态栏与透明顶栏之下;排在后面时不再预留。
  final bool extendBehindTopBar;

  static const bannerKey = Key('phone-hero');
  static const openKey = Key('phone-hero-open');
  static const maxFeatured = 5;
  static Key itemKey(String id) => ValueKey('phone-hero-$id');
  static List<MediaItem> featuredItemsOf(CatalogController catalog) =>
      featuredHomeItems(catalog, limit: maxFeatured);

  /// 文字与按钮的左右留白。
  static const double sidePadding = 20;

  /// 「播放 / 详情」按钮高,即 48 的触控高度。
  static const double actionsHeight = 48;

  /// 圆点行高即其 44 的触控目标高。
  static const double dotsHeight = 44;

  /// 头图占屏宽的比例:接近方形,剧照的主体留在画面中央。
  static const double widthShare = 1.08;

  /// 头图占视口高的上限,矮屏和横屏时首屏仍露出下一行。
  static const double viewportShare = .62;

  /// 整段头图高(含伸进状态栏的部分)。
  static double heightFor(double width, {double? viewportHeight}) {
    final byWidth = width * widthShare;
    final vh = viewportHeight;
    final byHeight = vh != null && vh.isFinite && vh > 0
        ? vh * viewportShare
        : double.infinity;
    return math.min(byWidth, byHeight).clamp(340.0, 640.0).floorToDouble();
  }

  /// 剧照请求宽:按实际像素取,夹在清晰与流量之间。
  static int requestWidthFor(double width, double devicePixelRatio) =>
      (width * devicePixelRatio).round().clamp(720, 1280);

  @override
  State<PhoneHero> createState() => _PhoneHeroState();
}

class _PhoneHeroState extends State<PhoneHero> with HeroAutoRotate {
  int _index = 0;
  String? _reportedId;

  /// A finger is on the banner: page changes come from the user, not the timer.
  bool _touching = false;
  final PageController _page = PageController();
  Drag? _bannerDrag;
  List<MediaItem> get _featured => PhoneHero.featuredItemsOf(widget.catalog);

  @override
  void dispose() {
    cancelAutoRotate();
    _cancelBannerDrag();
    _page.dispose();
    super.dispose();
  }

  // 文字、按钮和空白处的横滑同样交给 PageView;竖向滚动和按钮点按仍正常竞争。
  void _startBannerDrag(DragStartDetails details) {
    _cancelBannerDrag();
    if (_page.hasClients) {
      _bannerDrag = _page.position.drag(details, () => _bannerDrag = null);
    }
  }

  void _endBannerDrag(DragEndDetails details) {
    final drag = _bannerDrag;
    _bannerDrag = null;
    drag?.end(details);
  }

  void _cancelBannerDrag() {
    final drag = _bannerDrag;
    _bannerDrag = null;
    drag?.cancel();
  }

  /// 翻页时剧照比页面慢一点,给画面一点纵深。
  Widget _parallax(int page, double width, Widget child) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return AnimatedBuilder(
      animation: _page,
      child: child,
      builder: (context, child) {
        var current = _index.toDouble();
        if (_page.hasClients && _page.position.haveDimensions) {
          current = _page.page ?? current;
        }
        final delta = (page - current).clamp(-1.0, 1.0);
        return Transform.translate(
          offset: Offset(-delta * width * .28, 0),
          child: child,
        );
      },
    );
  }

  HeroArtworkSources _artworkOf(MediaItem item) =>
      heroArtworkSources(item, series: widget.catalog.latestSeries.items);

  void _open(MediaItem item) {
    final media = MediaQuery.of(context);
    final requestWidth = PhoneHero.requestWidthFor(
      media.size.width,
      media.devicePixelRatio,
    );
    final sources = _artworkOf(item);
    PhoneMotion.openItem(
      context,
      sources.handoffItem(item),
      preferBackdrop: sources.backdrops.isNotEmpty || sources.posters.isEmpty,
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
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    final page = theme.scaffoldBackgroundColor;
    final dark = theme.brightness == Brightness.dark;
    final media = MediaQuery.of(context);
    final viewport = media.size.height;
    final scale = media.textScaler.scale(14) / 14;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final height = PhoneHero.heightFor(width, viewportHeight: viewport);
        final requestWidth = PhoneHero.requestWidthFor(
          width,
          media.devicePixelRatio,
        );
        // 服务器 Logo 多是给深色背景准备的浅色图:只在深色主题替换片名。
        final logo = dark
            ? Size(
                math.min(width - PhoneHero.sidePadding * 2, 250),
                30 * 1.15 * 2 * scale,
              )
            : null;
        final neighbours = <MediaItem>{
          if (logo != null && items.length > 1) ...[
            items[(index + 1) % items.length],
            items[(index - 1 + items.length) % items.length],
          ],
        }..remove(item);
        final banner = Listener(
          key: PhoneHero.bannerKey,
          onPointerDown: (_) {
            _touching = true;
            pauseAutoRotate();
          },
          onPointerUp: (_) {
            _touching = false;
            resumeAutoRotate(items.length);
          },
          onPointerCancel: (_) {
            _touching = false;
            resumeAutoRotate(items.length);
          },
          child: SizedBox(
            height: height,
            child: Stack(
              fit: StackFit.expand,
              children: [
                for (final next in neighbours)
                  if (HeroLogo.available(next))
                    Offstage(
                      key: ValueKey('phone-hero-prefetch-${next.id}'),
                      child: HeroLogo(
                        item: next,
                        fallback: const SizedBox.shrink(),
                        maxWidth: logo!.width,
                        maxHeight: logo.height,
                        prefetch: true,
                      ),
                    ),
                ColoredBox(color: scheme.surfaceContainerHigh),
                // 覆盖层只认当前页的规范 paletteKey;相邻页的上报被丢弃。
                HeroPaletteOverlay(
                  paletteKey: HeroPaletteOverlay.paletteKeyFor(
                    context,
                    item,
                    series: widget.catalog.latestSeries.items,
                  ),
                  child: PageView.builder(
                    controller: _page,
                    allowImplicitScrolling: true,
                    physics: items.length > 1
                        ? const PageScrollPhysics()
                        : const NeverScrollableScrollPhysics(),
                    itemCount: items.length,
                    onPageChanged: (value) {
                      // A light tick when a swipe settles on a new slide;
                      // timed rotation stays silent.
                      if (_touching) HapticFeedback.selectionClick();
                      setState(() => _index = value);
                      resetAutoRotate(items.length);
                    },
                    itemBuilder: (context, slide) => _slide(
                      items[slide],
                      page: slide,
                      index: index,
                      count: items.length,
                      width: width,
                      requestWidth: requestWidth,
                    ),
                  ),
                ),
                // 顶带:状态栏与透明顶栏上的图标始终读得清。
                if (widget.extendBehindTopBar)
                  IgnorePointer(
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: SizedBox(
                        height: media.viewPadding.top + 96,
                        width: double.infinity,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                AppInk.black.withValues(
                                  alpha: AppScrim.of(context, .5),
                                ),
                                AppInk.transparent,
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                // 底带:画面下缘溶进页面底色,片名与按钮压在上面。
                IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        stops: const [.34, .62, .84, 1],
                        colors: [
                          page.withValues(alpha: 0),
                          page.withValues(alpha: dark ? .62 : .72),
                          page.withValues(alpha: .96),
                          page,
                        ],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: PhoneHero.sidePadding,
                  right: PhoneHero.sidePadding,
                  bottom: 0,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // 片名区不拦点按与横滑:落到下面的剧照上,点开详情或翻页。
                      IgnorePointer(
                        child: AnimatedSwitcher(
                          duration: AppMotion.durationOf(
                            context,
                            AppMotion.slow,
                          ),
                          switchInCurve: AppMotion.standard,
                          switchOutCurve: AppMotion.exit,
                          transitionBuilder: _textTransition,
                          layoutBuilder: (current, previous) => Stack(
                            alignment: Alignment.bottomCenter,
                            children: [...previous, ?current],
                          ),
                          child: _Caption(
                            key: ValueKey('phone-hero-caption-${item.id}'),
                            item: item,
                            logo: logo,
                          ),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),
                      SizedBox(
                        height: PhoneHero.actionsHeight,
                        child: HeroPlaybackActions(
                          key: ValueKey('phone-hero-actions-${item.id}'),
                          item: item,
                          expand: true,
                          catalog: widget.catalog,
                          onDetails: () => _open(item),
                          onResume: () => _play(item),
                        ),
                      ),
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
                                  activeColor: scheme.onSurface,
                                  cycle: rotateCycle,
                                ),
                              )
                            : null,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: items.length > 1 ? _startBannerDrag : null,
          onHorizontalDragUpdate: items.length > 1
              ? (details) => _bannerDrag?.update(details)
              : null,
          onHorizontalDragEnd: items.length > 1 ? _endBannerDrag : null,
          onHorizontalDragCancel: items.length > 1 ? _cancelBannerDrag : null,
          child: banner,
        );
      },
    );
  }

  static Widget _textTransition(Widget child, Animation<double> animation) {
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

  Widget _slide(
    MediaItem item, {
    required int page,
    required int index,
    required int count,
    required double width,
    required int requestWidth,
  }) {
    final current = page == index;
    final l10n = AppLocalizations.of(context);
    final art = RepaintBoundary(
      child: ClipRect(
        child: _parallax(
          page,
          width,
          HeroArtwork(
            sources: _artworkOf(item),
            requestWidth: requestWidth,
            compact: true,
          ),
        ),
      ),
    );
    return KeyedSubtree(
      key: PhoneHero.itemKey(item.id),
      child: Semantics(
        button: true,
        label: '${l10n.heroItemOf(page + 1, count)} ${heroTitle(item)}',
        child: GestureDetector(
          key: current ? PhoneHero.openKey : null,
          behavior: HitTestBehavior.opaque,
          onTap: () => _open(item),
          child: art,
        ),
      ),
    );
  }

  Future<void> _play(MediaItem item) async {
    final l10n = AppLocalizations.of(context);
    final target = await resolveHeroPlayTarget(
      context,
      item,
      catalog: widget.catalog,
    );
    if (!mounted) return;
    if (target == null) {
      showAppNotice(context, l10n.noPlayableStream);
      return;
    }
    await context.push<void>(
      '/play/${target.id}',
      extra: PlayerOpenRequest(itemId: target.id, autoResume: true),
    );
  }

  void _report(MediaItem item) {
    final callback = widget.onItem;
    if (callback == null || _reportedId == item.id) return;
    _reportedId = item.id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _reportedId == item.id) callback(item);
    });
  }
}

/// 画面下缘的文字:引导标签 → Logo 或大号片名(居中,最多两行) → 年份 · 类型 · 时长 ★。
class _Caption extends StatelessWidget {
  const _Caption({super.key, required this.item, this.logo});

  final MediaItem item;

  /// Logo slot (dark theme only); null keeps the text title.
  final Size? logo;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final l10n = AppLocalizations.of(context);
    final meta = heroMetaLabels(l10n, item);
    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.end,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        HeroKicker(label: heroKicker(l10n, item), onScrim: false),
        const SizedBox(height: 6),
        _title(theme),
        if (meta.isNotEmpty || item.communityRating != null) ...[
          const SizedBox(height: 8),
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
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: .78),
                      height: 1.2,
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

  Widget _title(AppUiThemeData theme) {
    final text = Text(
      heroTitle(item),
      textAlign: TextAlign.center,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.displaySmall?.copyWith(
        color: theme.colorScheme.onSurface,
        fontSize: 30,
        height: 1.15,
        letterSpacing: -0.4,
      ),
    );
    final slot = logo;
    if (slot == null || !HeroLogo.available(item)) return text;
    return HeroLogo(
      item: item,
      fallback: text,
      maxWidth: slot.width,
      maxHeight: slot.height,
      alignment: Alignment.center,
    );
  }
}
