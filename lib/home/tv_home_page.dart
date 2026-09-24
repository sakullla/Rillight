import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/app/widgets/skeleton.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/home/featured_items.dart';
import 'package:rillight/media_image/media_image.dart';

/// TV 首页 featured 区与行级焦点记忆的测试键(仅 TV 首页使用,不入桌面键表)。
abstract final class TvHomeKeys {
  static const featured = Key('tv-featured');
  static const featuredPrev = Key('tv-featured-prev');
  static const featuredNext = Key('tv-featured-next');
  static const featuredOpen = Key('tv-featured-open');
  static const featuredTitle = Key('tv-featured-title');
}

/// TV 首页:顶部手动 featured 横幅 + 四行货架,行级焦点记忆。
///
/// featured 候选复用 [featuredHomeItems](继续观看优先,上限 5),只手动左右
/// 切换不自动轮换;无候选时整区隐藏。切换控件在 AnimatedSwitcher 之外,快速
/// 连按时焦点节点不被移除,焦点不跳出行/区。
class TvHomePage extends StatelessWidget {
  const TvHomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final c = CatalogScope.of(context), l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final featured = featuredHomeItems(c);
        return ListView(
          key: const PageStorageKey('tv-home'),
          children: [
            if (featured.isNotEmpty) ...[
              _TvFeatured(items: featured),
              const SizedBox(height: 20),
            ],
            for (final row in [
              (
                l.resumeRow,
                c.resume,
                AppRoutes.shelfResume,
                CatalogKeys.shelfResume,
              ),
              (
                l.nextUpRow,
                c.nextUp,
                AppRoutes.shelfNextUp,
                CatalogKeys.shelfNextUp,
              ),
              (
                l.latestMoviesRow,
                c.latestMovies,
                AppRoutes.shelfLatestMovies,
                CatalogKeys.shelfLatestMovies,
              ),
              (
                l.latestSeriesRow,
                c.latestSeries,
                AppRoutes.shelfLatestSeries,
                CatalogKeys.shelfLatestSeries,
              ),
            ])
              if (!row.$2.hidden) ...[
                TvAction(
                  key: CatalogKeys.shelfMore(row.$4),
                  onPressed: row.$2.items.isEmpty
                      ? null
                      : () => context.push(row.$3),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          row.$1,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      if (row.$2.items.isNotEmpty)
                        Icon(
                          Icons.chevron_right,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                    ],
                  ),
                ),
                if (row.$2.loading && row.$2.items.isEmpty)
                  const _TvRowSkeleton(),
                if (row.$2.error != null || row.$2.notice != null)
                  TvFailure(
                    error: (row.$2.error ?? row.$2.notice)!,
                    retry: c.reloadHomeRows,
                  ),
                if (row.$2.items.isNotEmpty)
                  _TvFocusMemoryRow(title: row.$1, items: row.$2.items),
                const SizedBox(height: 20),
              ],
            if ([
              c.resume,
              c.nextUp,
              c.latestMovies,
              c.latestSeries,
            ].every((r) => r.hidden))
              Text(l.mobileEmpty),
            TvAction(
              onPressed: () => c.reload(showCachedFirst: false),
              child: Text(l.mobileRefresh),
            ),
          ],
        );
      },
    );
  }
}

/// featured 横幅:背景图 + 标题 + 主操作,手动左右切换,无自动轮换。
class _TvFeatured extends StatefulWidget {
  const _TvFeatured({required this.items});

  final List<EmbyItem> items;

  @override
  State<_TvFeatured> createState() => _TvFeaturedState();
}

class _TvFeaturedState extends State<_TvFeatured> {
  int _index = 0;

  void _go(int delta) {
    final count = widget.items.length;
    if (count < 2) {
      return;
    }
    setState(() => _index = ((_index + delta) % count + count) % count);
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    final index = _index % items.length;
    final item = items[index];
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final viewSize = MediaQuery.sizeOf(context);
    // 10 英尺横幅:高度约为视口高 45%,夹在可读区间内。
    final height = (viewSize.height * 0.45).clamp(220.0, 460.0);
    final hasImage =
        item.backdropImageTag != null ||
        item.parentBackdropImageTag != null ||
        item.primaryImageTag != null;
    final title = item.isEpisode && (item.seriesName?.isNotEmpty ?? false)
        ? item.seriesName!
        : item.name;
    final meta = <String>[
      if (!item.isEpisode &&
          item.productionYear != null &&
          item.productionYear! > 0)
        '${item.productionYear}',
      if (item.canResume)
        l.playbackProgress((item.playbackProgress * 100).round()),
    ];
    return SizedBox(
      key: TvHomeKeys.featured,
      height: height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: ColoredBox(
          color: const Color(0xff1d2632),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (hasImage)
                AnimatedSwitcher(
                  duration: AppMotion.durationOf(context, AppMotion.slow),
                  child: RepaintBoundary(
                    key: ValueKey(item.id),
                    child: MediaImage(
                      item: item,
                      height: height,
                      preferBackdrop: true,
                      maxWidth: mediaBackdropRequestWidth(
                        layoutWidth: viewSize.width,
                        devicePixelRatio: MediaQuery.devicePixelRatioOf(
                          context,
                        ),
                      ),
                    ),
                  ),
                ),
              const Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Color(0xcc0b0f14)],
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 24,
                right: 24,
                bottom: 20,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      key: TvHomeKeys.featuredTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.headlineMedium?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (meta.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        meta.join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: Colors.white.withValues(alpha: 0.8),
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    TvAction(
                      key: TvHomeKeys.featuredOpen,
                      emphasized: true,
                      onPressed: () => context.push(AppRoutes.item(item.id)),
                      child: Text(l.details),
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
                  right: 20,
                  bottom: 20,
                  child: Text(
                    '${index + 1} / ${items.length}',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: Colors.white.withValues(alpha: 0.8),
                    ),
                  ),
                ),
              ],
            ],
          ),
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
  const _TvFocusMemoryRow({required this.title, required this.items});

  final String title;
  final List<EmbyItem> items;

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
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: _onRowFocus,
      child: SizedBox(
        key: ValueKey('tv-row-${widget.title}'),
        height: 272,
        child: ListView.builder(
          key: PageStorageKey('tv-row-${widget.title}'),
          scrollDirection: Axis.horizontal,
          itemCount: widget.items.length,
          itemBuilder: (context, index) {
            final item = widget.items[index];
            return SizedBox(
              key: ValueKey(item.id),
              width: 170,
              child: TvPoster(item: item, focusNode: _nodeFor(item)),
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
