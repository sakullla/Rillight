import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:rillight/app/content_theme.dart';
import 'package:rillight/app/mobile_motion.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/home/featured_items.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/library/item_format.dart';
import 'package:rillight/media_image/media_image.dart';

/// 手机首页横幅。候选规则与桌面首页横幅相同，但不把那个组件装进手机：
/// 它依赖桌面顶栏重叠。左右滑动切换；点画面进入条目。减少动效时不轮换。
class PhoneHero extends StatefulWidget {
  const PhoneHero({super.key, required this.catalog, this.onItem});

  final CatalogController catalog;

  /// 当前画面，供首页把页面底色收成这张图的主题色。
  final ValueChanged<EmbyItem>? onItem;

  static const bannerKey = Key('phone-hero');
  static const pauseKey = Key('phone-hero-pause');
  static const openKey = Key('phone-hero-open');

  static const maxFeatured = 5;
  static const autoAdvanceInterval = Duration(seconds: 6);

  /// flutter test 默认关闭，避免周期计时拖住 pumpAndSettle。
  static bool autoAdvanceEnabled =
      Platform.environment['FLUTTER_TEST'] != 'true';

  static Key itemKey(String id) => ValueKey('phone-hero-$id');

  /// 有背景图的未看完电影和剧集，最多 [maxFeatured] 条。
  static List<EmbyItem> featuredItemsOf(CatalogController catalog) {
    return featuredHomeItems(catalog, limit: maxFeatured);
  }

  @override
  State<PhoneHero> createState() => _PhoneHeroState();
}

class _PhoneHeroState extends State<PhoneHero> {
  int _index = 0;
  String? _reportedId;
  bool _paused = false;
  Timer? _timer;
  final PageController _page = PageController();

  List<EmbyItem> get _featured => PhoneHero.featuredItemsOf(widget.catalog);

  @override
  void dispose() {
    _timer?.cancel();
    _page.dispose();
    super.dispose();
  }

  bool get _reduceMotion {
    return MediaQuery.disableAnimationsOf(context) ||
        AppMotion.durationOf(context) == Duration.zero;
  }

  bool get _canAutoAdvance {
    return PhoneHero.autoAdvanceEnabled &&
        !_paused &&
        TickerMode.valuesOf(context).enabled &&
        !_reduceMotion;
  }

  void _syncTimer(int count) {
    final want = _canAutoAdvance && count > 1;
    if (want) {
      _timer ??= Timer.periodic(PhoneHero.autoAdvanceInterval, (_) {
        _advance();
      });
      return;
    }
    _timer?.cancel();
    _timer = null;
  }

  void _advance() {
    if (!mounted || !_canAutoAdvance || !_page.hasClients) {
      return;
    }
    final count = _featured.length;
    if (count < 2) {
      return;
    }
    final next = (_index + 1) % count;
    final motion = AppMotion.durationOf(context);
    if (motion == Duration.zero) {
      _page.jumpToPage(next);
      return;
    }
    _page.animateToPage(
      next,
      duration: const Duration(milliseconds: 520),
      curve: Curves.easeOutCubic,
    );
  }

  void _pauseForTouch() {
    if (_paused || _reduceMotion) {
      return;
    }
    setState(() => _paused = true);
  }

  void _open(EmbyItem item) {
    PhoneMotion.openItem(
      context,
      item,
      preferBackdrop: true,
      maxWidth: PhoneMotion.heroRequestWidth,
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = _featured;
    _syncTimer(items.length);
    if (items.isEmpty) {
      return const SizedBox.shrink();
    }
    final index = _index % items.length;
    final rotating = items.length > 1;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        // 画面从状态栏背后铺下来。多出来的高度是顶栏，16:9 仍完整留在顶栏下面。
        final top = MediaQuery.paddingOf(context).top + 56;
        final height = top + width * 9 / 16;
        _report(items[index]);
        return Listener(
          onPointerDown: (_) => _pauseForTouch(),
          child: SizedBox(
            key: PhoneHero.bannerKey,
            width: width,
            height: height,
            child: Stack(
              fit: StackFit.expand,
              children: [
                PageView.builder(
                  controller: _page,
                  physics: rotating
                      ? const PageScrollPhysics()
                      : const NeverScrollableScrollPhysics(),
                  itemCount: items.length,
                  onPageChanged: (value) {
                    setState(() => _index = value);
                    _report(items[value]);
                  },
                  itemBuilder: (context, page) {
                    final pageItem = items[page];
                    final pageTitle =
                        pageItem.isEpisode &&
                            (pageItem.seriesName?.isNotEmpty ?? false)
                        ? pageItem.seriesName!
                        : pageItem.name;
                    return GestureDetector(
                      key: page == index ? PhoneHero.openKey : null,
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _open(pageItem),
                      child: KeyedSubtree(
                        key: PhoneHero.itemKey(pageItem.id),
                        child: ContentTheme(
                          item: pageItem,
                          preferBackdrop: true,
                          fillSurface: false,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              PhoneMotion.sharedImage(
                                itemId: pageItem.id,
                                preferBackdrop: true,
                                child: MediaImage(
                                  item: pageItem,
                                  preferBackdrop: true,
                                  alignment: Alignment.center,
                                  maxWidth: PhoneMotion.heroRequestWidth,
                                ),
                              ),
                              const _HeroWash(),
                              Positioned(
                                left: AppSpacing.md,
                                right: AppSpacing.md,
                                bottom: rotating ? 22 : AppSpacing.md,
                                child: _HeroCaption(
                                  item: pageItem,
                                  title: pageTitle,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
                if (rotating)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: AppSpacing.xs,
                    child: ContentTheme(
                      item: items[index],
                      preferBackdrop: true,
                      fillSurface: false,
                      child: Builder(
                        builder: (context) {
                          final active = Theme.of(context).colorScheme.primary;
                          return Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              for (var i = 0; i < items.length; i++)
                                Container(
                                  key: CatalogKeys.heroDot(i),
                                  width: i == index ? 16 : 6,
                                  height: 4,
                                  margin: const EdgeInsets.symmetric(
                                    horizontal: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    color: i == index
                                        ? active
                                        : Colors.white.withValues(alpha: 0.45),
                                    borderRadius: BorderRadius.circular(99),
                                  ),
                                ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _report(EmbyItem item) {
    final onItem = widget.onItem;
    if (onItem == null || _reportedId == item.id) {
      return;
    }
    _reportedId = item.id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _reportedId == item.id) {
        onItem(item);
      }
    });
  }
}

class _HeroWash extends StatelessWidget {
  const _HeroWash();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color(0xB3000000),
            Color(0x00000000),
            Color(0x00000000),
            Color(0x8C000000),
            Color(0xE6000000),
          ],
          stops: [0, 0.22, 0.48, 0.78, 1],
        ),
      ),
    );
  }
}

class _HeroCaption extends StatelessWidget {
  const _HeroCaption({required this.item, required this.title});

  final EmbyItem item;
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final date = _heroDate(item);
    final rating = item.communityRating;
    final genre = item.genres.isEmpty ? null : item.genres.first;
    final overview = plainOverview(item.overview);
    const ink = Colors.white;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (date != null)
          Text(
            date,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelMedium?.copyWith(
              color: ink.withValues(alpha: 0.78),
              letterSpacing: 0.4,
              height: 1.2,
            ),
          ),
        Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.headlineSmall?.copyWith(
            color: ink,
            fontWeight: FontWeight.w600,
            height: 1.15,
          ),
        ),
        if (rating != null || genre != null) ...[
          const SizedBox(height: 6),
          Text(
            [
              if (rating != null) rating.toStringAsFixed(1),
              ?genre,
            ].join('  ·  '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelLarge?.copyWith(
              color: ink.withValues(alpha: 0.88),
              height: 1.2,
            ),
          ),
        ],
        if (overview != null) ...[
          const SizedBox(height: 8),
          Text(
            overview,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: ink.withValues(alpha: 0.78),
              height: 1.35,
            ),
          ),
        ],
      ],
    );
  }
}

/// 首播日期单独成行。没有首播日时只留年份。
String? _heroDate(EmbyItem item) {
  final premiere = item.premiereDate;
  if (premiere != null) {
    return '${premiere.year}年${premiere.month}月${premiere.day}日';
  }
  final year = item.productionYear;
  if (year != null && year > 0) {
    return '$year';
  }
  return null;
}
