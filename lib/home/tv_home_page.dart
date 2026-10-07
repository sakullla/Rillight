import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/app/tv_top_nav.dart';
import 'package:rillight/app/widgets/skeleton.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/home/featured_items.dart';
import 'package:rillight/home/hero_carousel.dart';
import 'package:rillight/home/hero_playback_actions.dart';
import 'package:rillight/home/library_latest_row.dart';
import 'package:rillight/home/library_tiles.dart';
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

/// TV 首页：轮播图、继续观看、下一集、片库入口和每个片库的最近添加。
/// 顺序和显隐按服务器记在电视自己的存储里，手机和桌面不受影响。行级焦点记忆。
///
/// featured 候选复用 [featuredHomeItems](最近入库的电影/剧集交错,上限 5,
/// 不含观看记录),只手动左右
/// 切换不自动轮换;无候选时整区隐藏。切换控件在 AnimatedSwitcher 之外,快速
/// 连按时焦点节点不被移除,焦点不跳出行/区。
class TvHomePage extends StatefulWidget {
  const TvHomePage({super.key});

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

  @override
  Widget build(BuildContext context) {
    final c = CatalogScope.of(context), l = AppLocalizations.of(context);
    final sections = _sections;
    return ListenableBuilder(
      listenable: Listenable.merge([c, sections]),
      builder: (context, _) {
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
        List<Widget> shelf(
          String title,
          CatalogRowState state,
          String route,
          String shelfId, {
          bool wide = false,
        }) {
          if (state.hidden) {
            return const [];
          }
          return [
            TvAction(
              key: CatalogKeys.shelfMore(shelfId),
              onPressed: state.items.isEmpty ? null : () => context.push(route),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  if (state.items.isNotEmpty)
                    Icon(
                      Icons.chevron_right,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                ],
              ),
            ),
            if (state.loading && state.items.isEmpty) const _TvRowSkeleton(),
            if (state.error != null || state.notice != null)
              TvFailure(
                error: (state.error ?? state.notice)!,
                retry: c.reloadHomeRows,
              ),
            if (state.items.isNotEmpty)
              _TvFocusMemoryRow(title: title, items: state.items, wide: wide),
            const SizedBox(height: 20),
          ];
        }

        final gutter = tvSafeGutter(MediaQuery.sizeOf(context).width);
        Widget padded(List<Widget> children) => Padding(
          padding: EdgeInsets.symmetric(horizontal: gutter),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        );

        /// 空 section 不占位,保证全部为空时回落到空态文案。
        List<Widget> padSection(List<Widget> children) =>
            children.isEmpty ? const [] : [padded(children)];

        final sectionChildren = <Widget>[
          for (final id in visible) ...[
            if (id == PhoneHomeSectionId.banner &&
                showBanner &&
                featured.isNotEmpty) ...[
              _TvFeatured(items: featured),
              const SizedBox(height: 20),
            ] else if (id == PhoneHomeSectionId.resume)
              ...padSection(
                shelf(
                  l.resumeRow,
                  resumeState,
                  AppRoutes.shelfResume,
                  CatalogKeys.shelfResume,
                  wide: true,
                ),
              )
            else if (id == PhoneHomeSectionId.nextUp)
              ...padSection(
                shelf(
                  l.nextUpRow,
                  nextUpState,
                  AppRoutes.shelfNextUp,
                  CatalogKeys.shelfNextUp,
                ),
              )
            else if (id == PhoneHomeSectionId.libraries && showLibraryEntry)
              padded([
                LibraryTiles(
                  libraries: c.libraries,
                  cardBuilder: (context, library, width, height) {
                    return TvAction(
                      key: CatalogKeys.library(library.id),
                      onPressed: () =>
                          context.push(AppRoutes.library(library.id)),
                      child: SizedBox(
                        width: width,
                        height: height,
                        child: LibraryCardFace(
                          library: library,
                          width: width,
                          height: height,
                        ),
                      ),
                    );
                  },
                ),
              ])
            else if (PhoneHomeSectionId.libraryIdOf(id) case final libraryId?
                when librariesById[libraryId] != null)
              padded([_TvLibraryLatest(library: librariesById[libraryId]!)]),
          ],
        ];
        return ListView(
          key: const PageStorageKey('tv-home'),
          // Only the featured image bleeds behind the navigation. When it is
          // hidden, empty or reordered, keep the first action below the bar.
          padding: EdgeInsets.only(
            top: sectionChildren.firstOrNull is _TvFeatured
                ? 0
                : TvTopNavBar.reserveHeight,
          ),
          children: [
            ...sectionChildren,
            if (sectionChildren.isEmpty) padded([Text(l.mobileEmpty)]),
            padded([
              TvAction(
                key: const Key('tv-home-display'),
                onPressed: () => showTvSectionEditor(context),
                child: Text(l.phoneHomeEdit),
              ),
              TvAction(
                onPressed: () => c.reload(showCachedFirst: false),
                child: Text(l.mobileRefresh),
              ),
            ]),
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
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TvAction(
              onPressed: () => context.push(AppRoutes.library(library.id)),
              child: Text(
                library.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            if (snapshot.loading && snapshot.items.isEmpty)
              const _TvRowSkeleton(),
            if (snapshot.error != null)
              TvFailure(error: snapshot.error!, retry: snapshot.retry),
            if (snapshot.items.isNotEmpty)
              _TvFocusMemoryRow(title: library.name, items: snapshot.items),
            const SizedBox(height: 20),
          ],
        );
      },
    );
  }
}

/// featured 沉浸 hero:全宽出血背图 + 遮罩 + 大标题 + 主操作,手动左右切换,
/// 无自动轮换。hero 铺满视口宽并伸到顶部导航栏下,文字恒白压遮罩。
class _TvFeatured extends StatefulWidget {
  const _TvFeatured({required this.items});

  final List<EmbyItem> items;

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

  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    final index = _index % items.length;
    final item = items[index];
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final viewSize = MediaQuery.sizeOf(context);
    // 沉浸 hero:高度约为视口高 58%,夹在可读区间内;宽度铺满视口。
    final height = (viewSize.height * 0.58).clamp(320.0, 620.0);
    final gutter = tvSafeGutter(viewSize.width);
    final hasImage =
        item.backdropImageTag != null ||
        item.parentBackdropImageTag != null ||
        item.primaryImageTag != null;
    final title = heroTitle(item);
    final meta = heroMetaLabels(l, item);
    final overview = plainOverview(item.overview);
    return SizedBox(
      key: TvHomeKeys.featured,
      width: viewSize.width,
      height: height,
      child: ColoredBox(
        color: theme.colorScheme.surfaceContainerHigh,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (hasImage)
              AnimatedSwitcher(
                duration: AppMotion.durationOf(context, heroSlideDuration),
                transitionBuilder: heroSlideTransition,
                child: RepaintBoundary(
                  key: ValueKey(item.id),
                  child: MediaImage(
                    item: item,
                    height: height,
                    preferBackdrop: true,
                    maxWidth: mediaHeroBackdropRequestWidth(
                      layoutWidth: viewSize.width,
                      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
                    ),
                  ),
                ),
              ),
            const Positioned.fill(child: TvHeroScrim()),
            Positioned(
              left: gutter,
              right: gutter,
              bottom: 24,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  HeroKicker(label: heroKicker(l, item)),
                  const SizedBox(height: 10),
                  Text(
                    title,
                    key: TvHomeKeys.featuredTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.displaySmall?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      shadows: const [
                        Shadow(blurRadius: 12, color: Colors.black54),
                      ],
                    ),
                  ),
                  if (meta.isNotEmpty || item.communityRating != null) ...[
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        if (meta.isNotEmpty)
                          Flexible(
                            child: Text(
                              meta.join(' · '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelLarge?.copyWith(
                                color: Colors.white.withValues(alpha: 0.8),
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
                  // 矮视口只留标题与操作,保证按钮不被挤出 hero。
                  if (overview != null && height >= 360) ...[
                    const SizedBox(height: 8),
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: viewSize.width * .5,
                      ),
                      child: Text(
                        overview,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: Colors.white.withValues(alpha: 0.82),
                          height: 1.45,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 14),
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
                      const SizedBox(width: 8),
                      TvAction(
                        key: TvHomeKeys.featuredOpen,
                        pill: true,
                        onPressed: () => context.push(AppRoutes.item(item.id)),
                        child: Text(l.details),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (items.length > 1) ...[
              Positioned(
                left: 8,
                top: 0,
                bottom: 0,
                child: Center(
                  child: TvAction(
                    key: TvHomeKeys.featuredPrev,
                    onPressed: () => _go(-1),
                    child: const Icon(Icons.chevron_left),
                  ),
                ),
              ),
              Positioned(
                right: 8,
                top: 0,
                bottom: 0,
                child: Center(
                  child: TvAction(
                    key: TvHomeKeys.featuredNext,
                    onPressed: () => _go(1),
                    child: const Icon(Icons.chevron_right),
                  ),
                ),
              ),
              Positioned(
                right: gutter,
                bottom: 28,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    HeroDots(index: index, count: items.length, onSelect: null),
                    const SizedBox(width: 8),
                    Text(
                      '${index + 1} / ${items.length}',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: Colors.white.withValues(alpha: 0.8),
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 带行级焦点记忆的海报行:记住上次焦点项 id,行重获焦点时落回该项。
///
/// 外层 [Focus] 不可直接聚焦,仅在焦点从行外进入时触发恢复;行内左右移动
/// 不改变外层 hasFocus,不会误触发。滚动位置仍由 [PageStorageKey] 记忆,
/// 焦点目标移除由 TvFocusRegion 补焦,二者分工不变。
class _TvFocusMemoryRow extends StatefulWidget {
  const _TvFocusMemoryRow({
    required this.title,
    required this.items,
    this.wide = false,
  });

  final String title;
  final List<EmbyItem> items;

  /// 16:9 横版卡行(继续观看)。
  final bool wide;

  @override
  State<_TvFocusMemoryRow> createState() => _TvFocusMemoryRowState();
}

class _TvFocusMemoryRowState extends State<_TvFocusMemoryRow> {
  final _nodes = <String, FocusNode>{};
  String? _lastId;

  FocusNode _nodeFor(EmbyItem item) {
    return _nodes.putIfAbsent(item.id, () {
      final node = FocusNode();
      node.addListener(() {
        if (node.hasFocus) {
          _lastId = item.id;
        }
      });
      return node;
    });
  }

  void _prune() {
    final ids = widget.items.map((item) => item.id).toSet();
    for (final id in _nodes.keys.toList()) {
      if (!ids.contains(id)) {
        _nodes.remove(id)?.dispose();
        if (_lastId == id) {
          _lastId = null;
        }
      }
    }
  }

  void _onRowFocus(bool focused) {
    if (!focused) {
      return;
    }
    final last = _lastId;
    if (last == null) {
      return;
    }
    final node = _nodes[last];
    final primary = FocusManager.instance.primaryFocus;
    // 焦点刚从行外进入:方向遍历落在位移最近项,改落回上次焦点项;
    // 该项滚出视口未构建或不可聚焦时保持遍历结果。
    if (node != null &&
        node != primary &&
        node.context?.mounted == true &&
        node.canRequestFocus) {
      node.requestFocus();
    }
  }

  @override
  void didUpdateWidget(covariant _TvFocusMemoryRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    _prune();
  }

  @override
  void dispose() {
    for (final node in _nodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _prune();
    final wide = widget.wide;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: _onRowFocus,
      child: SizedBox(
        key: ValueKey('tv-row-${widget.title}'),
        height: wide ? 220 : 272,
        child: ListView.builder(
          key: PageStorageKey('tv-row-${widget.title}'),
          scrollDirection: Axis.horizontal,
          itemCount: widget.items.length,
          itemBuilder: (context, index) {
            final item = widget.items[index];
            return SizedBox(
              key: ValueKey(item.id),
              width: wide ? 288 : 170,
              child: TvPoster(
                item: item,
                wide: wide,
                focusNode: _nodeFor(item),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _TvRowSkeleton extends StatelessWidget {
  const _TvRowSkeleton();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 272,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: 6,
        separatorBuilder: (context, index) => const SizedBox(width: 12),
        itemBuilder: (context, index) {
          return const SizedBox(width: 170, child: _TvPosterBone());
        },
      ),
    );
  }
}

class _TvPosterBone extends StatelessWidget {
  const _TvPosterBone();

  @override
  Widget build(BuildContext context) {
    final animate = !MediaQuery.disableAnimationsOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: SkeletonBlock(animated: animate)),
        const SizedBox(height: 8),
        SkeletonBlock(width: 120, height: 16, animated: animate),
      ],
    );
  }
}
