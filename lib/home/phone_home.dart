import 'package:flutter/material.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_chrome.dart';
import 'package:rillight/app/mobile_widgets.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/home/catalog_failure.dart';
import 'package:rillight/home/catalog_scope.dart';

/// 手机首页：行数据从壳中拆出，加载、空、失败各用一种画面。
class PhoneHome extends StatelessWidget {
  const PhoneHome({super.key});

  @override
  Widget build(BuildContext context) {
    final catalog = CatalogScope.of(context);
    final l10n = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: catalog,
      builder: (context, _) {
        final sections = [
          (l10n.resumeRow, catalog.resume),
          (l10n.nextUpRow, catalog.nextUp),
          (l10n.latestMoviesRow, catalog.latestMovies),
          (l10n.latestSeriesRow, catalog.latestSeries),
        ];
        final states = [for (final section in sections) section.$2];
        final hasItems = states.any((state) => state.items.isNotEmpty);
        final loading = states.any((state) => state.loading);
        EmbyException? firstError;
        for (final state in states) {
          if (state.error != null) {
            firstError = state.error;
            break;
          }
        }
        // 没有海报时只留一种画面：占位、失败或空。已有海报则保留各行。
        final Widget body;
        if (!hasItems && firstError == null && loading) {
          body = const MobileLoadingPlaceholder.home();
        } else if (!hasItems && firstError != null && !loading) {
          body = MobileFailureState(
            message: catalogFailureMessage(l10n, firstError),
            onRetry: () {
              catalog.reloadHomeRows();
            },
          );
        } else if (!hasItems && !loading) {
          body = MobileEmptyState(
            message: l10n.mobileEmpty,
            actionLabel: l10n.mobileRefresh,
            onAction: () {
              catalog.reload(showCachedFirst: false);
            },
          );
        } else {
          body = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final section in sections)
                _PhoneHomeRow(
                  title: section.$1,
                  state: section.$2,
                  retry: () {
                    catalog.reloadHomeRows();
                  },
                ),
              TextButton.icon(
                style: TextButton.styleFrom(minimumSize: _refreshHit),
                onPressed: () {
                  catalog.reload(showCachedFirst: false);
                },
                icon: const Icon(Icons.refresh),
                label: Text(l10n.mobileRefresh),
              ),
            ],
          );
        }
        return RefreshIndicator(
          onRefresh: () => catalog.reload(showCachedFirst: false),
          child: ListView(
            key: const PageStorageKey('mobile-home-scroll'),
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(AppSpacing.md),
            children: [body],
          ),
        );
      },
    );
  }
}

const Size _refreshHit = Size(AppSpacing.huge, AppSpacing.huge);

class _PhoneHomeRow extends StatelessWidget {
  const _PhoneHomeRow({
    required this.title,
    required this.state,
    required this.retry,
  });

  final String title;
  final CatalogRowState state;
  final VoidCallback retry;

  @override
  Widget build(BuildContext context) {
    if (state.hidden) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context);
    final problem = state.error ?? state.notice;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
          child: Text(title, style: Theme.of(context).textTheme.titleLarge),
        ),
        if (state.loading && state.items.isEmpty)
          const MobileLoadingPlaceholder.row(),
        if (problem != null)
          MobileFailureState(
            message: catalogFailureMessage(l10n, problem),
            onRetry: retry,
          ),
        if (state.items.isNotEmpty)
          SizedBox(
            height:
                250 + 35 * (MediaQuery.textScalerOf(context).scale(14) / 14),
            child: ListView.builder(
              key: PageStorageKey('row-$title'),
              scrollDirection: Axis.horizontal,
              itemCount: state.items.length,
              itemBuilder: (context, index) => SizedBox(
                width: 148,
                child: MobilePoster(item: state.items[index]),
              ),
            ),
          ),
      ],
    );
  }
}
