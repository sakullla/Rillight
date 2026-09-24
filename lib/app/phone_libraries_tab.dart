import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_chrome.dart';
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
                padding: const EdgeInsets.all(AppSpacing.md),
                sliver: SliverGrid(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    mainAxisSpacing: AppSpacing.md,
                    crossAxisSpacing: AppSpacing.md,
                    childAspectRatio: 16 / 9,
                  ),
                  delegate: SliverChildBuilderDelegate((context, index) {
                    final library = catalog.libraries[index];
                    return _LibraryBlock(
                      library: library,
                      onTap: () => context.push(AppRoutes.library(library.id)),
                    );
                  }, childCount: catalog.libraries.length),
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
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(AppRadii.md),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: Key('phone-library-block-${library.id}'),
        onTap: onTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (hasImage)
              MediaImage(
                key: Key('phone-library-image-${library.id}'),
                item: library,
                preferBackdrop: true,
                maxWidth: 480,
              )
            else
              _LibraryNamePlaceholder(
                key: Key('phone-library-placeholder-${library.id}'),
                name: library.name,
              ),
            if (hasImage) ...[
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: const [0.45, 1],
                    colors: [
                      scheme.scrim.withValues(alpha: 0),
                      scheme.scrim.withValues(
                        alpha: AppScrim.of(context, AppScrim.textStart),
                      ),
                    ],
                  ),
                ),
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  child: Text(
                    library.name,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleLarge?.copyWith(
                      color: scheme.onSurface,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _LibraryNamePlaceholder extends StatelessWidget {
  const _LibraryNamePlaceholder({super.key, required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ColoredBox(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Text(
            name,
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleLarge,
          ),
        ),
      ),
    );
  }
}
