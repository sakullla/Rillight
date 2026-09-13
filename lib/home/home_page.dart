import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/app_shell.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/window_chrome.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/home/home_hero.dart';
import 'package:rillight/home/home_row.dart';
import 'package:rillight/home/library_tiles.dart';

/// 首页:全宽 hero,有继续观看数据时排在发现 shelf 之前.
///
/// [AppShell] 把半透明顶栏放在 Column 里,本页无法把 hero 画到顶栏下方
/// (后绘制会盖住顶栏按钮).贴窗口上缘需要外壳改为 Stack(内容铺满,顶栏叠上).
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  /// 与 [AppShell] 顶栏同高;外壳仍是 Column 时只加到 hero 高度,不能真正叠到窗口上缘.
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
        final overlap = heroTopOverlap(context);
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
                  onTap: (item) => context.push(AppRoutes.item(item.id)),
                  onRetry: catalog.reloadHomeRows,
                  onMore: () => context.push(AppRoutes.shelfResume),
                  onRemoveFromResume: catalog.hideFromResume,
                ),
              ),
              RepaintBoundary(
                child: LibraryTiles(libraries: catalog.libraries),
              ),
              RepaintBoundary(
                child: HomeMediaRow(
                  rowKey: CatalogKeys.nextUpRow,
                  shelfId: CatalogKeys.shelfNextUp,
                  title: l10n.nextUpRow,
                  state: catalog.nextUp,
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
