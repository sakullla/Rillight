import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/app/tv_top_nav.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/home/featured_items.dart';
import 'package:rillight/home/hero_artwork.dart';
import 'package:rillight/home/hero_carousel.dart';
import 'package:rillight/home/hero_logo.dart';
import 'package:rillight/home/hero_playback_actions.dart';
import 'package:rillight/home/library_latest_row.dart';
import 'package:rillight/home/phone_home_sections.dart';
import 'package:rillight/home/tv_section_prefs.dart';
import 'package:rillight/library/item_format.dart';
import 'package:rillight/media_image/media_image.dart';
import 'package:rillight/player/player_window_host.dart';

/// TV 首页 featured 区与行级焦点记忆的测试键(仅 TV 首页使用,不入桌面键表)。
abstract final class TvHomeKeys {
  static const featured = Key('tv-featured');
  static const featuredPrev = Key('tv-featured-prev');
  static const featuredNext = Key('tv-featured-next');
  static const featuredOpen = Key('tv-featured-open');
  static const featuredPlay = Key('tv-featured-play');
  static const featuredTitle = Key('tv-featured-title');
}

/// TV 首页:沉浸 hero、继续观看、下一集、媒体库和每个片库的最近添加。
/// 顺序和显隐按服务器记在电视自己的存储里,手机和桌面不受影响。
///
/// 版式:hero 占首屏约七成,第一行内容在首屏露头;每行一个安静的小标题,
/// 卡片左缘对齐安全区,行尾是「查看全部」。行级焦点记忆由 [TvItemRow] 提供。
class TvHomePage extends StatefulWidget {
  const TvHomePage({super.key, this.heroVisible});

  /// 首页顶部是否为出血 hero,导航据此决定是否压在影像上。
  final ValueNotifier<bool>? heroVisible;

  @override
  State<TvHomePage> createState() => _TvHomePageState();
}

class _TvHomePageState extends State<TvHomePage> {
  var _loadedServerId = '';

  TvSectionController get _sections => TvSectionController.app();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final serverId = AuthScope.maybeOf(context)?.session?.server.id ?? '';
    if (_loadedServerId == serverId) {
      return;
    }
    _loadedServerId = serverId;
    unawaited(_sections.load(serverId));
  }

  void _reportHero(bool visible) {
    final notifier = widget.heroVisible;
    if (notifier == null || notifier.value == visible) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) notifier.value = visible;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = CatalogScope.of(context), l = AppLocalizations.of(context);
    final sections = _sections;
    return ListenableBuilder(
      listenable: Listenable.merge([c, sections]),
      builder: (context, _) {
        final s = TvDesign.scaleOf(context);
        final gutter = tvSafeGutter(MediaQuery.sizeOf(context).width);
        final featured = featuredHomeItems(c);
        final showBanner = !sections.isHidden(PhoneHomeSectionId.banner);
        final visible = sections.visibleIds(c.libraries);
        final watching = continueWatchingItems(c.resume.items, c.nextUp.items);
        final watchingIds = {for (final item in watching) item.id};
        final nextUpItems = [
          for (final item in c.nextUp.items)
            if (!watchingIds.contains(item.id)) item,
        ];
        final hideResume = sections.isHidden(PhoneHomeSectionId.resume);
        final hideNextUp = sections.isHidden(PhoneHomeSectionId.nextUp);
        final resumeState = CatalogRowState(
          items: watching,
          loading: !hideResume && c.resume.loading && watching.isEmpty,
          hidden:
              hideResume ||
              (watching.isEmpty && !c.resume.loading && c.resume.error == null),
          error: hideResume || watching.isNotEmpty ? null : c.resume.error,
          notice: hideResume ? null : c.resume.notice,
        );
        final nextUpState = CatalogRowState(
          items: nextUpItems,
          loading: !hideNextUp && c.nextUp.loading && nextUpItems.isEmpty,
          hidden:
              hideNextUp ||
              (nextUpItems.isEmpty &&
                  !c.nextUp.loading &&
                  c.nextUp.error == null),
          error: hideNextUp || nextUpItems.isNotEmpty ? null : c.nextUp.error,
          notice: hideNextUp ? null : c.nextUp.notice,
        );
        final showLibraryEntry =
            visible.contains(PhoneHomeSectionId.libraries) &&
            c.libraries.isNotEmpty;
        final librariesById = {
          for (final library in c.libraries) library.id: library,
        };
        final titlePadding = EdgeInsets.fromLTRB(gutter, 10 * s, gutter, 0);

        List<Widget> shelf(
          String title,
          CatalogRowState state,
          String route,
          String shelfId,
        ) {
          if (state.hidden) return const [];
          return [
            TvSectionTitle(title, padding: titlePadding),
            if (state.loading && state.items.isEmpty)
              const TvRowSkeleton(wide: true),
            if (state.error != null || state.notice != null)
              Padding(
                padding: EdgeInsets.symmetric(horizontal: gutter),
                child: TvFailure(
                  error: (state.error ?? state.notice)!,
                  retry: c.reloadHomeRows,
                ),
              ),
            if (state.items.isNotEmpty)
              TvItemRow(
                title: title,
                items: state.items,
                wide: true,
                trailing: (context, metrics) => TvMoreTile(
                  key: CatalogKeys.shelfMore(shelfId),
                  metrics: metrics,
                  onPressed: () => context.push(route),
                ),
              ),
            SizedBox(height: 8 * s),
          ];
        }

        final sectionChildren = <Widget>[
          for (final id in visible) ...[
            if (id == PhoneHomeSectionId.banner &&
                showBanner &&
                featured.isNotEmpty)
              _TvFeatured(items: featured, series: c.latestSeries.items)
            else if (id == PhoneHomeSectionId.resume)
              ...shelf(
                l.resumeRow,
                resumeState,
                AppRoutes.shelfResume,
                CatalogKeys.shelfResume,
              )
            else if (id == PhoneHomeSectionId.nextUp)
              ...shelf(
                l.nextUpRow,
                nextUpState,
                AppRoutes.shelfNextUp,
                CatalogKeys.shelfNextUp,
              )
            else if (id == PhoneHomeSectionId.libraries &&
                showLibraryEntry) ...[
              TvSectionTitle(l.libraries, padding: titlePadding),
              TvItemRow(
                title: l.libraries,
                items: c.libraries,
                wide: true,
                subtitle: false,
                width: 184 * s,
                cardBuilder: (context, library, node, metrics) => TvCard(
                  key: CatalogKeys.library(library.id),
                  item: library,
                  wide: true,
                  focusNode: node,
                  imageMaxWidth: metrics.imageMaxWidth,
                  onPressed: () => context.push(AppRoutes.library(library.id)),
                ),
              ),
              SizedBox(height: 8 * s),
            ] else if (PhoneHomeSectionId.libraryIdOf(id) case final libraryId?
                when librariesById[libraryId] != null)
              _TvLibraryLatest(library: librariesById[libraryId]!),
          ],
        ];
        final heroFirst = sectionChildren.firstOrNull is _TvFeatured;
        _reportHero(heroFirst);
        return ListView(
          key: const PageStorageKey('tv-home'),
          // Only the featured image bleeds behind the navigation. When it is
          // hidden, empty or reordered, keep the first action below the bar.
          padding: EdgeInsets.only(
            top: heroFirst ? 0 : TvTopNavBar.reserveOf(context),
            bottom: tvSafeVertical(MediaQuery.sizeOf(context).height),
          ),
          children: [
            ...sectionChildren,
            if (sectionChildren.isEmpty)
              SizedBox(
                height: 200 * s,
                child: TvEmptyState(message: l.mobileEmpty),
              ),
            Padding(
              padding: EdgeInsets.fromLTRB(gutter, 16 * s, gutter, 0),
              child: Row(
                children: [
                  TvAction(
                    key: const Key('tv-home-display'),
                    pill: true,
                    leading: const Icon(Icons.tune_rounded),
                    onPressed: () => showTvSectionEditor(context),
                    child: Text(l.phoneHomeEdit),
                  ),
                  SizedBox(width: 10 * s),
                  TvAction(
                    pill: true,
                    leading: const Icon(Icons.refresh_rounded),
                    onPressed: () => c.reload(showCachedFirst: false),
                    child: Text(l.mobileRefresh),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _TvLibraryLatest extends StatelessWidget {
  const _TvLibraryLatest({required this.library});

  final EmbyItem library;

  @override
  Widget build(BuildContext context) {
    final s = TvDesign.scaleOf(context);
    final gutter = tvSafeGutter(MediaQuery.sizeOf(context).width);
    return LibraryLatestData(
      library: library,
      builder: (context, snapshot) {
        if (!snapshot.loading &&
            snapshot.error == null &&
            snapshot.items.isEmpty) {
          return const SizedBox.shrink();
        }
        return Column(
          key: Key('tv-library-${library.id}'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TvSectionTitle(
              library.name,
              padding: EdgeInsets.fromLTRB(gutter, 10 * s, gutter, 0),
            ),
            if (snapshot.loading && snapshot.items.isEmpty)
              const TvRowSkeleton(),
            if (snapshot.error != null)
              Padding(
                padding: EdgeInsets.symmetric(horizontal: gutter),
                child: TvFailure(error: snapshot.error!, retry: snapshot.retry),
              ),
            if (snapshot.items.isNotEmpty)
              TvItemRow(
                title: library.name,
                items: snapshot.items,
                trailing: (context, metrics) => TvMoreTile(
                  metrics: metrics,
                  onPressed: () => context.push(AppRoutes.library(library.id)),
                ),
              ),
            SizedBox(height: 8 * s),
          ],
        );
      },
    );
  }
}

/// featured 沉浸舞台:全宽出血宣传图 + 遮罩 + Logo/大标题 + 主操作,手动左右
/// 切换,无自动轮换。舞台铺满视口宽并伸到顶部导航栏下,文字恒白压遮罩,
/// 底缘溶进页面底色。
///
/// 背景与文字分层过渡:新图在旧图之上淡入,旧文字先淡出、新文字再上移淡入。
/// 「播放 / 详情」与切换控件不在过渡层里,连按切换时焦点节点始终不变。
/// 左右相邻条目的图片与 Logo 提前解码,遥控器切换时不闪底色。
class _TvFeatured extends StatefulWidget {
  const _TvFeatured({required this.items, this.series = const []});

  final List<EmbyItem> items;

  /// 最新剧集行:单集条目借用所属剧集的宣传图。
  final List<EmbyItem> series;

  @override
  State<_TvFeatured> createState() => _TvFeaturedState();
}

class _TvFeaturedState extends State<_TvFeatured> {
  int _index = 0;
  bool _opening = false;

  void _go(int delta) {
    final count = widget.items.length;
    if (count < 2) {
      return;
    }
    setState(() => _index = ((_index + delta) % count + count) % count);
  }

  /// 电影直接播;剧集先解析出该播的那一集,没有可播集时提示。
  Future<void> _play(EmbyItem item) async {
    if (_opening) return;
    _opening = true;
    try {
      final target = await resolveHeroPlayTarget(context, item);
      if (!mounted) return;
      if (target == null) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context).noPlayableStream),
          ),
        );
        return;
      }
      await context.push(
        '/play/${target.id}',
        extra: PlayerOpenRequest(itemId: target.id, autoResume: true),
      );
    } finally {
      _opening = false;
    }
  }

  HeroArtworkSources _sources(EmbyItem item) =>
      heroArtworkSources(item, series: widget.series);

  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    final index = _index % items.length;
    final item = items[index];
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final viewSize = MediaQuery.sizeOf(context);
    final s = TvDesign.scaleOf(context);
    // 舞台约占视口高 72%,第一行内容的标题在首屏露头。
    final height = (viewSize.height * .72).roundToDouble();
    final gutter = tvSafeGutter(viewSize.width);
    final bottom = 30 * s;
    final textWidth = math.min(viewSize.width * .46, 460 * s);
    final logoWidth = textWidth * .8;
    final logoHeight = 84 * s;
    final requestWidth = mediaHeroBackdropRequestWidth(
      layoutWidth: viewSize.width,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      max: kMediaBackdropTvMaxRequestWidth,
    );
    final artwork = _sources(item);
    final multiple = items.length > 1;
    final page = theme.scaffoldBackgroundColor;
    final neighbours = <EmbyItem>{
      if (multiple) items[(index + 1) % items.length],
      if (items.length > 2) items[(index - 1 + items.length) % items.length],
    };
    return SizedBox(
      key: TvHomeKeys.featured,
      width: viewSize.width,
      height: height,
      child: ColoredBox(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            for (final next in neighbours)
              Offstage(
                key: ValueKey('tv-featured-prefetch-${next.id}'),
                child: Stack(
                  children: [
                    HeroArtwork(
                      sources: _sources(next),
                      requestWidth: requestWidth,
                      prefetch: true,
                    ),
                    if (HeroLogo.available(next))
                      HeroLogo(
                        item: next,
                        fallback: const SizedBox.shrink(),
                        maxWidth: logoWidth,
                        maxHeight: logoHeight,
                        prefetch: true,
                      ),
                  ],
                ),
              ),
            if (!artwork.isEmpty)
              AnimatedSwitcher(
                duration: AppMotion.durationOf(context, heroBackdropDuration),
                transitionBuilder: heroBackdropTransition,
                child: RepaintBoundary(
                  key: ValueKey('tv-featured-art-${item.id}'),
                  child: heroLayoutFor(artwork) == HeroLayout.fullBleed
                      ? HeroArtwork(
                          sources: artwork,
                          requestWidth: requestWidth,
                        )
                      : HeroPosterSpotlight(
                          sources: artwork,
                          requestWidth: requestWidth,
                          insets: EdgeInsets.fromLTRB(
                            gutter + textWidth + 48 * s,
                            TvTopNavBar.reserveOf(context),
                            gutter,
                            bottom + 56 * s,
                          ),
                        ),
                ),
              ),
            const Positioned.fill(child: TvHeroScrim(bottom: false)),
            // 深色主题底缘溶进页面底色,首行标题和舞台之间没有硬边;
            // 浅色主题舞台保持深色,底部压暗托住白字与按钮,和页面直接分界。
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: height * .34,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: theme.brightness == Brightness.dark
                        ? [page.withValues(alpha: 0), page]
                        : [
                            Colors.black.withValues(alpha: 0),
                            Colors.black.withValues(
                              alpha: AppScrim.of(context, .6),
                            ),
                          ],
                  ),
                ),
              ),
            ),
            Positioned(
              left: gutter,
              bottom: bottom,
              width: textWidth,
              child: TvDarkStage(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AnimatedSwitcher(
                      duration: AppMotion.durationOf(
                        context,
                        heroSlideDuration,
                      ),
                      switchInCurve: heroCaptionInCurve,
                      switchOutCurve: heroCaptionOutCurve,
                      transitionBuilder: heroCaptionTransition,
                      layoutBuilder: (current, previous) => Stack(
                        alignment: Alignment.bottomLeft,
                        children: [...previous, ?current],
                      ),
                      child: _TvFeaturedCaption(
                        key: ValueKey('tv-featured-caption-${item.id}'),
                        item: item,
                        logoWidth: logoWidth,
                        logoHeight: logoHeight,
                      ),
                    ),
                    SizedBox(height: 16 * s),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TvAction(
                          key: TvHomeKeys.featuredPlay,
                          emphasized: true,
                          pill: true,
                          leading: const Icon(Icons.play_arrow_rounded),
                          onPressed: () => _play(item),
                          child: Text(l.play),
                        ),
                        SizedBox(width: 10 * s),
                        TvAction(
                          key: TvHomeKeys.featuredOpen,
                          pill: true,
                          leading: const Icon(Icons.info_outline_rounded),
                          onPressed: () =>
                              context.push(AppRoutes.item(item.id)),
                          child: Text(l.details),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            if (multiple)
              Positioned(
                right: gutter,
                bottom: bottom,
                child: TvDarkStage(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TvAction(
                        key: TvHomeKeys.featuredPrev,
                        variant: TvActionVariant.icon,
                        onPressed: () => _go(-1),
                        child: const Icon(Icons.chevron_left_rounded),
                      ),
                      SizedBox(width: 12 * s),
                      _TvPagerDots(index: index, count: items.length),
                      SizedBox(width: 10 * s),
                      Text(
                        '${index + 1} / ${items.length}',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: Colors.white.withValues(alpha: .75),
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                      SizedBox(width: 12 * s),
                      TvAction(
                        key: TvHomeKeys.featuredNext,
                        variant: TvActionVariant.icon,
                        onPressed: () => _go(1),
                        child: const Icon(Icons.chevron_right_rounded),
                      ),
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

class _TvPagerDots extends StatelessWidget {
  const _TvPagerDots({required this.index, required this.count});
  final int index, count;

  @override
  Widget build(BuildContext context) {
    final s = TvDesign.scaleOf(context);
    final duration = AppMotion.durationOf(context, AppMotion.normal);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < count; i++)
          AnimatedContainer(
            duration: duration,
            curve: AppMotion.standard,
            margin: EdgeInsets.symmetric(horizontal: 2.5 * s),
            width: (i == index ? 18 : 6) * s,
            height: 6 * s,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: i == index ? .95 : .4),
              borderRadius: BorderRadius.circular(3 * s),
            ),
          ),
      ],
    );
  }
}

/// 舞台文字:引导标签 → Logo(无 Logo 时大标题) → 年份 · 流派 · 时长 ★ → 简介。
/// 只在切换时整体过渡;操作按钮在外层,焦点不随换页丢失。
class _TvFeaturedCaption extends StatelessWidget {
  const _TvFeaturedCaption({
    super.key,
    required this.item,
    required this.logoWidth,
    required this.logoHeight,
  });

  final EmbyItem item;
  final double logoWidth;
  final double logoHeight;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final s = TvDesign.scaleOf(context);
    final meta = heroMetaLabels(l, item);
    final overview = plainOverview(item.overview);
    const shadow = [Shadow(blurRadius: 12, color: Colors.black54)];
    final title = Text(
      heroTitle(item),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.displaySmall?.copyWith(
        color: Colors.white,
        shadows: shadow,
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 3 * s,
              height: 12 * s,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary,
                borderRadius: BorderRadius.circular(2 * s),
              ),
            ),
            SizedBox(width: 6 * s),
            Text(
              heroKicker(l, item),
              style: theme.textTheme.labelMedium?.copyWith(
                color: Colors.white.withValues(alpha: .85),
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        SizedBox(height: 10 * s),
        KeyedSubtree(
          key: TvHomeKeys.featuredTitle,
          child: HeroLogo.available(item)
              ? HeroLogo(
                  item: item,
                  fallback: title,
                  maxWidth: logoWidth,
                  maxHeight: logoHeight,
                )
              : title,
        ),
        if (meta.isNotEmpty || item.communityRating != null) ...[
          SizedBox(height: 10 * s),
          Row(
            children: [
              if (item.communityRating case final rating?) ...[
                Icon(
                  Icons.star_rounded,
                  size: 16 * s,
                  color: const Color(0xFFFFC94D),
                ),
                SizedBox(width: 3 * s),
                Text(
                  rating.toStringAsFixed(1),
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: Colors.white,
                  ),
                ),
                SizedBox(width: 10 * s),
              ],
              if (meta.isNotEmpty)
                Flexible(
                  child: Text(
                    meta.join('  ·  '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: Colors.white.withValues(alpha: .82),
                    ),
                  ),
                ),
            ],
          ),
        ],
        if (overview != null) ...[
          SizedBox(height: 8 * s),
          Text(
            overview,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: Colors.white.withValues(alpha: .75),
            ),
          ),
        ],
      ],
    );
  }
}
