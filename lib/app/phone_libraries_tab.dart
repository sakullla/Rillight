import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_chrome.dart';
import 'package:rillight/app/phone_bottom_nav.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_failure.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/media_image/media_image.dart';

/// 手机片库列表。大约两列带库名的卡片；没有库图时用库名占满该卡。
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
          // 已有库时刷新失败仍留下图片块，只附加失败和重试。
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
          child: CustomScrollView(
            key: const PageStorageKey('mobile-libraries-scroll'),
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              if (status != null)
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.md,
                    AppSpacing.md,
                    AppSpacing.md,
                    0,
                  ),
                  sliver: SliverToBoxAdapter(child: status),
                ),
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  AppSpacing.md,
                  AppSpacing.md,
                  AppSpacing.md,
                  AppSpacing.md + phoneScrollClearance(context),
                ),
                sliver: SliverLayoutBuilder(
                  builder: (context, constraints) {
                    const spacing = AppSpacing.md;
                    const columns = 2;
                    final cellWidth =
                        (constraints.crossAxisExtent - spacing) / columns;
                    final textScale =
                        MediaQuery.textScalerOf(context).scale(14) / 14;
                    final titleBlock = AppSpacing.xs + 22 * textScale;
                    return SliverGrid(
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        mainAxisSpacing: spacing,
                        crossAxisSpacing: spacing,
                        childAspectRatio:
                            cellWidth / (cellWidth * 9 / 16 + titleBlock),
                      ),
                      delegate: SliverChildBuilderDelegate((context, index) {
                        final library = catalog.libraries[index];
                        return _LibraryBlock(
                          library: library,
                          onTap: () =>
                              context.push(AppRoutes.library(library.id)),
                        );
                      }, childCount: catalog.libraries.length),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _LibraryBlock extends StatelessWidget {
  const _LibraryBlock({required this.library, required this.onTap});

  final EmbyItem library;
  final VoidCallback onTap;

  bool get _hasImage {
    bool tagged(String? tag) => tag != null && tag.isNotEmpty;
    return tagged(library.primaryImageTag) ||
        tagged(library.backdropImageTag) ||
        tagged(library.thumbImageTag);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hasImage = _hasImage;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: Key('phone-library-block-${library.id}'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadii.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Material(
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(AppRadii.md),
                clipBehavior: Clip.antiAlias,
                child: hasImage
                    ? MediaImage(
                        key: Key('phone-library-image-${library.id}'),
                        item: library,
                        preferBackdrop: true,
                        maxWidth: 480,
                      )
                    : _LibraryNamePlaceholder(
                        key: Key('phone-library-placeholder-${library.id}'),
                      ),
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              library.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class _LibraryNamePlaceholder extends StatelessWidget {
  const _LibraryNamePlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
    );
  }
}
