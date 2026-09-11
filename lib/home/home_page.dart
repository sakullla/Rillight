import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/widgets/app_error_view.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/home/catalog_failure.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/home/home_row.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final auth = AuthScope.of(context);
    final catalog = CatalogScope.maybeOf(context);
    if (catalog == null) {
      return const SizedBox.shrink();
    }
    final session = auth.session;

    return ListenableBuilder(
      listenable: catalog,
      builder: (context, _) {
        return SingleChildScrollView(
          padding: const EdgeInsets.only(top: 16, bottom: 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (session != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: Text(
                    l10n.connectedTo(session.server.name),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              if (catalog.librariesError != null)
                AppErrorView(
                  message: catalogFailureMessage(l10n, catalog.librariesError!),
                  onRetry: catalog.reload,
                ),
              HomeMediaRow(
                rowKey: CatalogKeys.resumeRow,
                title: l10n.resumeRow,
                state: catalog.resume,
                showProgress: true,
                onTap: (item) => context.push(AppRoutes.item(item.id)),
                onRetry: catalog.reloadHomeRows,
              ),
              HomeMediaRow(
                rowKey: CatalogKeys.nextUpRow,
                title: l10n.nextUpRow,
                state: catalog.nextUp,
                onTap: (item) => context.push(AppRoutes.item(item.id)),
                onRetry: catalog.reloadHomeRows,
              ),
              HomeMediaRow(
                rowKey: CatalogKeys.latestMoviesRow,
                title: l10n.latestMoviesRow,
                state: catalog.latestMovies,
                onTap: (item) => context.push(AppRoutes.item(item.id)),
                onRetry: catalog.reloadHomeRows,
              ),
              HomeMediaRow(
                rowKey: CatalogKeys.latestSeriesRow,
                title: l10n.latestSeriesRow,
                state: catalog.latestSeries,
                onTap: (item) => context.push(AppRoutes.item(item.id)),
                onRetry: catalog.reloadHomeRows,
              ),
            ],
          ),
        );
      },
    );
  }
}
