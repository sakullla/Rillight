import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/widgets/app_error_view.dart';
import 'package:rillight/home/catalog_failure.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/home/home_hero.dart';
import 'package:rillight/home/home_row.dart';
import 'package:rillight/home/library_tiles.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

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
        return SingleChildScrollView(
          padding: const EdgeInsets.only(top: 16, bottom: 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (catalog.librariesError != null)
                AppErrorView(
                  message: catalogFailureMessage(l10n, catalog.librariesError!),
                  onRetry: catalog.reload,
                ),
              HomeHero(catalog: catalog),
              HomeMediaRow(
                rowKey: CatalogKeys.resumeRow,
                shelfId: CatalogKeys.shelfResume,
                title: l10n.resumeRow,
                state: catalog.resume,
                showProgress: true,
                wide: true,
                onTap: (item) => context.push(AppRoutes.item(item.id)),
                onRetry: catalog.reloadHomeRows,
                onMore: () => context.push(AppRoutes.shelfResume),
              ),
              LibraryTiles(libraries: catalog.libraries),
              HomeMediaRow(
                rowKey: CatalogKeys.nextUpRow,
                shelfId: CatalogKeys.shelfNextUp,
                title: l10n.nextUpRow,
                state: catalog.nextUp,
                onTap: (item) => context.push(AppRoutes.item(item.id)),
                onRetry: catalog.reloadHomeRows,
                onMore: () => context.push(AppRoutes.shelfNextUp),
              ),
              HomeMediaRow(
                rowKey: CatalogKeys.latestMoviesRow,
                shelfId: CatalogKeys.shelfLatestMovies,
                title: l10n.latestMoviesRow,
                state: catalog.latestMovies,
                onTap: (item) => context.push(AppRoutes.item(item.id)),
                onRetry: catalog.reloadHomeRows,
                onMore: () => context.push(AppRoutes.shelfLatestMovies),
              ),
              HomeMediaRow(
                rowKey: CatalogKeys.latestSeriesRow,
                shelfId: CatalogKeys.shelfLatestSeries,
                title: l10n.latestSeriesRow,
                state: catalog.latestSeries,
                onTap: (item) => context.push(AppRoutes.item(item.id)),
                onRetry: catalog.reloadHomeRows,
                onMore: () => context.push(AppRoutes.shelfLatestSeries),
              ),
            ],
          ),
        );
      },
    );
  }
}
