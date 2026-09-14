import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/app_shell.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/window_chrome.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/home/home_hero.dart';
import 'package:rillight/home/home_row.dart';
import 'package:rillight/home/library_tiles.dart';

/// 首页手动刷新按钮(绕过缓存立即重拉)的 key。
const Key homeRefreshKey = Key('catalog-home-refresh');

/// 首页:全宽 hero,有继续观看数据时排在发现 shelf 之前.
///
/// [AppShell] 外壳是 Stack:内容铺满窗口,半透明顶栏叠在内容之上,
/// 因此 hero 顶点落在窗口上缘,顶栏区域由 hero 自身的顶带遮罩保护.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();

  /// hero 需要向上叠过的高度 = [AppShell] 顶栏高(有窗口铬时取两者较大值);
  /// 这段高度加进 hero 画面,使内容块不被顶栏压住.
  static double heroTopOverlap(BuildContext context) {
    if (context.findAncestorWidgetOfExactType<AppShell>() == null) {
      return 0;
    }
    final hasChrome =
        context.findAncestorWidgetOfExactType<WindowChromeHost>() != null;
    if (!hasChrome) {
      return AppShell.topBarHeight;
    }
    return kWindowChromeHeight > AppShell.topBarHeight
        ? kWindowChromeHeight
        : AppShell.topBarHeight;
  }
}

/// 首页媒体行,按视觉顺序排列(片库行不在其中)。
enum _HomeRow {
  resume,
  nextUp,
  latestMovies,
  latestSeries;

  CatalogRowState stateOf(CatalogController catalog) => switch (this) {
    resume => catalog.resume,
    nextUp => catalog.nextUp,
    latestMovies => catalog.latestMovies,
    latestSeries => catalog.latestSeries,
  };
}

/// 手动刷新钮的挂载点:优先第一个无错误的媒体行,否则第一个可见媒体行,
/// 媒体行全隐藏时落到片库行。
enum _RefreshSlot { resume, nextUp, latestMovies, latestSeries, libraries }

class _HomePageState extends State<HomePage> {
  bool _refreshing = false;

  /// 手动刷新入口:绕过缓存先显,直接重拉首页行并写穿缓存。
  Future<void> _refresh() async {
    final catalog = CatalogScope.maybeOf(context);
    if (catalog == null || _refreshing) {
      return;
    }
    setState(() => _refreshing = true);
    try {
      await catalog.reloadHomeRows();
    } finally {
      if (mounted) {
        setState(() => _refreshing = false);
      }
    }
  }

  /// 刷新钮挂在「继续观看」货架 header;该行隐藏或出错时退到下一可见
  /// 无错误媒体行。四个媒体行都隐藏时挂到片库行,避免首页没有刷新入口。
  _RefreshSlot? _refreshHost(CatalogController catalog) {
    _RefreshSlot? firstVisible;
    for (final row in _HomeRow.values) {
      final state = row.stateOf(catalog);
      if (state.hidden) {
        continue;
      }
      final slot = _RefreshSlot.values[row.index];
      firstVisible ??= slot;
      if (state.error == null) {
        return slot;
      }
    }
    if (firstVisible != null) {
      return firstVisible;
    }
    return catalog.libraries.isEmpty ? null : _RefreshSlot.libraries;
  }

  Widget? _refreshAction(
    AppLocalizations l10n,
    _RefreshSlot? host,
    _RefreshSlot slot,
  ) {
    if (host != slot) {
      return null;
    }
    return IconButton(
      key: homeRefreshKey,
      tooltip: l10n.retry,
      visualDensity: VisualDensity.compact,
      onPressed: _refreshing ? null : _refresh,
      icon: _refreshing
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.refresh),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final catalog = CatalogScope.maybeOf(context);
    if (catalog == null) {
      return const SizedBox.shrink();
    }

    return ListenableBuilder(
      listenable: catalog,
      builder: (context, _) {
        final overlap = HomePage.heroTopOverlap(context);
        final refreshHost = _refreshHost(catalog);
        return SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: AppSpacing.xxl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              RepaintBoundary(
                child: HomeHero(catalog: catalog, topOverlap: overlap),
              ),
              RepaintBoundary(
                child: HomeMediaRow(
                  rowKey: CatalogKeys.resumeRow,
                  shelfId: CatalogKeys.shelfResume,
                  title: l10n.resumeRow,
                  state: catalog.resume,
                  showProgress: true,
                  wide: true,
                  headerAction: _refreshAction(
                    l10n,
                    refreshHost,
                    _RefreshSlot.resume,
                  ),
                  onTap: (item) => context.push(AppRoutes.item(item.id)),
                  onRetry: catalog.reloadHomeRows,
                  onMore: () => context.push(AppRoutes.shelfResume),
                  onRemoveFromResume: catalog.hideFromResume,
                ),
              ),
              RepaintBoundary(
                child: LibraryTiles(
                  libraries: catalog.libraries,
                  headerAction: _refreshAction(
                    l10n,
                    refreshHost,
                    _RefreshSlot.libraries,
                  ),
                ),
              ),
              RepaintBoundary(
                child: HomeMediaRow(
                  rowKey: CatalogKeys.nextUpRow,
                  shelfId: CatalogKeys.shelfNextUp,
                  title: l10n.nextUpRow,
                  state: catalog.nextUp,
                  headerAction: _refreshAction(
                    l10n,
                    refreshHost,
                    _RefreshSlot.nextUp,
                  ),
                  onTap: (item) => context.push(AppRoutes.item(item.id)),
                  onRetry: catalog.reloadHomeRows,
                  onMore: () => context.push(AppRoutes.shelfNextUp),
                ),
              ),
              RepaintBoundary(
                child: HomeMediaRow(
                  rowKey: CatalogKeys.latestMoviesRow,
                  shelfId: CatalogKeys.shelfLatestMovies,
                  title: l10n.latestMoviesRow,
                  state: catalog.latestMovies,
                  headerAction: _refreshAction(
                    l10n,
                    refreshHost,
                    _RefreshSlot.latestMovies,
                  ),
                  onTap: (item) => context.push(AppRoutes.item(item.id)),
                  onRetry: catalog.reloadHomeRows,
                  onMore: () => context.push(AppRoutes.shelfLatestMovies),
                ),
              ),
              RepaintBoundary(
                child: HomeMediaRow(
                  rowKey: CatalogKeys.latestSeriesRow,
                  shelfId: CatalogKeys.shelfLatestSeries,
                  title: l10n.latestSeriesRow,
                  state: catalog.latestSeries,
                  headerAction: _refreshAction(
                    l10n,
                    refreshHost,
                    _RefreshSlot.latestSeries,
                  ),
                  onTap: (item) => context.push(AppRoutes.item(item.id)),
                  onRetry: catalog.reloadHomeRows,
                  onMore: () => context.push(AppRoutes.shelfLatestSeries),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
