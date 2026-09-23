import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_chrome.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/home/catalog_failure.dart';
import 'package:rillight/home/catalog_scope.dart';

/// 手机片库列表。点库名仍进入该库。
class PhoneLibrariesTab extends StatelessWidget {
  const PhoneLibrariesTab({super.key});

  @override
  Widget build(BuildContext context) {
    final catalog = CatalogScope.of(context);
    final l10n = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: catalog,
      builder: (context, _) {
        final error = catalog.librariesError;
        final notice = catalog.librariesNotice;
        final empty = catalog.libraries.isEmpty;
        final Widget? status;
        if (empty && catalog.librariesLoading && error == null) {
          status = const MobileLoadingPlaceholder.libraries();
        } else if (empty && !catalog.librariesLoading && error != null) {
          status = MobileFailureState(
            message: catalogFailureMessage(l10n, error),
            onRetry: () {
              catalog.reload();
            },
          );
        } else if (empty && !catalog.librariesLoading && error == null) {
          status = MobileEmptyState(
            message: l10n.mobileEmpty,
            actionLabel: l10n.mobileRefresh,
            onAction: () {
              catalog.reload();
            },
          );
        } else if (error != null || notice != null) {
          // 已有库名时刷新失败仍留下列表，只附加失败和重试。
          status = MobileFailureState(
            message: catalogFailureMessage(l10n, (error ?? notice)!),
            onRetry: () {
              catalog.reload();
            },
          );
        } else {
          status = null;
        }
        return RefreshIndicator(
          onRefresh: catalog.reload,
          child: ListView(
            key: const PageStorageKey('mobile-libraries-scroll'),
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(AppSpacing.md),
            children: [
              if (status != null) status,
              for (final library in catalog.libraries)
                Card(
                  child: ListTile(
                    minVerticalPadding: 20,
                    leading: const Icon(Icons.video_library),
                    title: Text(library.name),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => context.push(AppRoutes.library(library.id)),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
