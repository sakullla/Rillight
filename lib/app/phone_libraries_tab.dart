import 'package:rillight/app/ui/ui.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_chrome.dart';
import 'package:rillight/app/mobile_widgets.dart';
import 'package:rillight/app/phone_bottom_nav.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/home/catalog_failure.dart';
import 'package:rillight/home/catalog_scope.dart';

/// 手机「媒体库」标签页:顶部一排快速入口(继续观看、即将播放、最新电影、
/// 最新剧集),下面是当前服务器的全部媒体库磁贴。磁贴有封面铺封面,没有就按
/// 类型画渐变和图标。
class PhoneLibrariesTab extends StatelessWidget {
  const PhoneLibrariesTab({super.key});

  static const shortcutsKey = Key('phone-libraries-shortcuts');
  static Key shortcutKey(String id) => Key('phone-libraries-shortcut-$id');

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
          // 已有库时刷新失败仍留下磁贴，只附加失败和重试。
          status = MobileFailureState(
            message: catalogFailureMessage(l10n, (error ?? notice)!),
            onRetry: () {
              catalog.reload();
            },
          );
        } else {
          status = null;
        }
        final shortcuts = <_Shortcut>[
          _Shortcut(
            id: 'resume',
            label: l10n.resumeRow,
            icon: CupertinoIcons.play_circle,
            location: AppRoutes.shelfResume,
          ),
          _Shortcut(
            id: 'nextup',
            label: l10n.nextUpRow,
            icon: CupertinoIcons.forward_end_alt,
            location: AppRoutes.shelfNextUp,
          ),
          _Shortcut(
            id: 'latest-movies',
            label: l10n.phoneShortcutLatestMovies,
            icon: CupertinoIcons.film,
            location: AppRoutes.shelfLatestMovies,
          ),
          _Shortcut(
            id: 'latest-series',
            label: l10n.phoneShortcutLatestSeries,
            icon: CupertinoIcons.tv,
            location: AppRoutes.shelfLatestSeries,
          ),
        ];
        return AppRefresh(
          onRefresh: catalog.reload,
          child: CustomScrollView(
            key: const PageStorageKey('mobile-libraries-scroll'),
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.xs),
                  child: SizedBox(
                    height: 40,
                    child: ListView.separated(
                      key: shortcutsKey,
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.md,
                      ),
                      itemCount: shortcuts.length,
                      separatorBuilder: (context, index) =>
                          const SizedBox(width: AppSpacing.xs),
                      itemBuilder: (context, index) {
                        final shortcut = shortcuts[index];
                        return _ShortcutChip(
                          key: shortcutKey(shortcut.id),
                          shortcut: shortcut,
                        );
                      },
                    ),
                  ),
                ),
              ),
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
              if (!empty)
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.md,
                    AppSpacing.xl,
                    AppSpacing.md,
                    0,
                  ),
                  sliver: SliverToBoxAdapter(
                    child: PhoneSectionHeader(
                      title: l10n.phoneLibrariesMine,
                      subtitle: l10n.phoneLibraryCount(
                        catalog.libraries.length,
                      ),
                    ),
                  ),
                ),
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  AppSpacing.md,
                  AppSpacing.xxs,
                  AppSpacing.md,
                  AppSpacing.md + phoneScrollClearance(context),
                ),
                sliver: SliverLayoutBuilder(
                  builder: (context, constraints) {
                    const spacing = AppSpacing.sm;
                    final textScale =
                        MediaQuery.textScalerOf(context).scale(14) / 14;
                    final columns = textScale > 1.5 ? 1 : 2;
                    final cellWidth =
                        (constraints.crossAxisExtent -
                            spacing * (columns - 1)) /
                        columns;
                    return SliverGrid(
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        mainAxisSpacing: spacing,
                        crossAxisSpacing: spacing,
                        childAspectRatio: cellWidth / (cellWidth * 10 / 16),
                      ),
                      delegate: SliverChildBuilderDelegate((context, index) {
                        final library = catalog.libraries[index];
                        return MobilePressable(
                          key: Key('phone-library-block-${library.id}'),
                          onTap: () =>
                              context.push(AppRoutes.library(library.id)),
                          child: PhoneLibraryTile(
                            library: library,
                            large: columns == 1,
                            imageKey: Key('phone-library-image-${library.id}'),
                            placeholderKey: Key(
                              'phone-library-placeholder-${library.id}',
                            ),
                          ),
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

class _Shortcut {
  const _Shortcut({
    required this.id,
    required this.label,
    required this.icon,
    required this.location,
  });

  final String id;
  final String label;
  final IconData icon;
  final String location;
}

/// 快速入口:浅底胶囊,图标用强调色。
class _ShortcutChip extends StatelessWidget {
  const _ShortcutChip({super.key, required this.shortcut});

  final _Shortcut shortcut;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(999),
      ),
      clipBehavior: Clip.antiAlias,
      child: AppSurfaceAction(
        onTap: () => context.push(shortcut.location),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(shortcut.icon, size: 17, color: scheme.primary),
              const SizedBox(width: 6),
              Text(
                shortcut.label,
                maxLines: 1,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: scheme.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
