import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/app_shell.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/widgets/app_empty_view.dart';
import 'package:rillight/app/window_chrome.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/home/home_hero.dart';
import 'package:rillight/home/home_row.dart';
import 'package:rillight/home/library_latest_row.dart';
import 'package:rillight/home/library_tiles.dart';
import 'package:rillight/home/phone_home_sections.dart';
import 'package:rillight/media_image/media_image.dart';

/// 首页手动刷新按钮(绕过缓存立即重拉)的 key。
const Key homeRefreshKey = Key('catalog-home-refresh');

/// 首页：轮播图、继续观看、下一集、片库入口和每个片库的最近添加。
/// 顺序和显示与手机同一套。关掉的行归到「未显示」，片库页仍列出全部片库。
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

/// 手动刷新钮的挂载点:优先第一个无错误的媒体行,否则第一个可见媒体行,
/// 媒体行全隐藏时落到片库行。
enum _RefreshSlot { resume, nextUp, libraries }

class _HomePageState extends State<HomePage> {
  bool _refreshing = false;
  var _loadedServerId = '';

  PhoneHomeSectionController get _sections => PhoneHomeSectionController.app();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final serverId = AuthScope.maybeOf(context)?.session?.server.id ?? '';
    if (_loadedServerId == serverId) {
      return;
    }
    _loadedServerId = serverId;
    unawaited(_sections.load(serverId));
  }

  /// 手动刷新入口:绕过缓存先显,直接重拉首页行并写穿缓存。
  Future<void> _refresh() async {
    final catalog = CatalogScope.maybeOf(context);
    if (catalog == null || _refreshing) {
      return;
    }
    setState(() => _refreshing = true);
    try {
      await catalog.reload(
        includeLibraries: catalog.libraries.isEmpty,
        showCachedFirst: false,
      );
    } finally {
      if (mounted) {
        setState(() => _refreshing = false);
      }
    }
  }

  /// 刷新钮挂在「继续观看」货架 header;该行隐藏或出错时退到下一可见
  /// 无错误媒体行。媒体行都隐藏时挂到片库行,避免首页没有刷新入口。
  _RefreshSlot? _refreshHost({
    required CatalogRowState resume,
    required CatalogRowState nextUp,
  }) {
    _RefreshSlot? firstVisible;
    final rows = <(_RefreshSlot, CatalogRowState)>[
      (_RefreshSlot.resume, resume),
      (_RefreshSlot.nextUp, nextUp),
    ];
    for (final (slot, state) in rows) {
      if (state.hidden) {
        continue;
      }
      firstVisible ??= slot;
      if (state.error == null) {
        return slot;
      }
    }
    if (firstVisible != null) {
      return firstVisible;
    }
    return _RefreshSlot.libraries;
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

    final sections = _sections;
    return ListenableBuilder(
      listenable: Listenable.merge([catalog, sections]),
      builder: (context, _) {
        final watching = continueWatchingItems(
          catalog.resume.items,
          catalog.nextUp.items,
        );
        final watchingIds = {for (final item in watching) item.id};
        final nextUpItems = [
          for (final item in catalog.nextUp.items)
            if (!watchingIds.contains(item.id)) item,
        ];
        final hideResume = sections.isHidden(PhoneHomeSectionId.resume);
        final hideNextUp = sections.isHidden(PhoneHomeSectionId.nextUp);
        final resumeState = CatalogRowState(
          items: watching,
          loading: !hideResume && catalog.resume.loading && watching.isEmpty,
          hidden:
              hideResume ||
              (watching.isEmpty &&
                  !catalog.resume.loading &&
                  catalog.resume.error == null),
          error: hideResume || watching.isNotEmpty
              ? null
              : catalog.resume.error,
          notice: hideResume ? null : catalog.resume.notice,
        );
        final nextUpState = CatalogRowState(
          items: nextUpItems,
          loading: !hideNextUp && catalog.nextUp.loading && nextUpItems.isEmpty,
          hidden:
              hideNextUp ||
              (nextUpItems.isEmpty &&
                  !catalog.nextUp.loading &&
                  catalog.nextUp.error == null),
          error: hideNextUp || nextUpItems.isNotEmpty
              ? null
              : catalog.nextUp.error,
          notice: hideNextUp ? null : catalog.nextUp.notice,
        );
        final overlap = HomePage.heroTopOverlap(context);
        final refreshHost = _refreshHost(
          resume: resumeState,
          nextUp: nextUpState,
        );
        final showBanner = !sections.isHidden(PhoneHomeSectionId.banner);
        final visible = sections.visibleIds(catalog.libraries);
        final showLibraryEntry =
            visible.contains(PhoneHomeSectionId.libraries) &&
            catalog.libraries.isNotEmpty;
        final heroVisible =
            showBanner &&
            [
              resumeState,
              catalog.latestMovies,
              catalog.latestSeries,
            ].any((row) => row.loading || row.items.isNotEmpty);
        final bannerLeads =
            visible.isNotEmpty &&
            visible.first == PhoneHomeSectionId.banner &&
            heroVisible;
        String? refreshLibraryId;
        if (refreshHost == _RefreshSlot.libraries && !showLibraryEntry) {
          for (final id in visible) {
            final libraryId = PhoneHomeSectionId.libraryIdOf(id);
            if (libraryId != null) {
              refreshLibraryId = libraryId;
              break;
            }
          }
        }
        final librariesById = {
          for (final library in catalog.libraries) library.id: library,
        };
        final sectionChildren = <Widget>[
          for (final id in visible)
            if (id == PhoneHomeSectionId.banner && showBanner)
              RepaintBoundary(
                key: ValueKey(id),
                child: HomeHero(catalog: catalog, topOverlap: overlap),
              )
            else if (id == PhoneHomeSectionId.resume)
              RepaintBoundary(
                key: ValueKey(id),
                child: HomeMediaRow(
                  rowKey: CatalogKeys.resumeRow,
                  shelfId: CatalogKeys.shelfResume,
                  title: l10n.resumeRow,
                  state: resumeState,
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
              )
            else if (id == PhoneHomeSectionId.nextUp)
              RepaintBoundary(
                key: ValueKey(id),
                child: HomeMediaRow(
                  rowKey: CatalogKeys.nextUpRow,
                  shelfId: CatalogKeys.shelfNextUp,
                  title: l10n.nextUpRow,
                  state: nextUpState,
                  headerAction: _refreshAction(
                    l10n,
                    refreshHost,
                    _RefreshSlot.nextUp,
                  ),
                  onTap: (item) => context.push(AppRoutes.item(item.id)),
                  onRetry: catalog.reloadHomeRows,
                  onMore: () => context.push(AppRoutes.shelfNextUp),
                ),
              )
            else if (id == PhoneHomeSectionId.libraries && showLibraryEntry)
              RepaintBoundary(
                key: ValueKey(id),
                child: LibraryTiles(
                  libraries: catalog.libraries,
                  headerAction: _refreshAction(
                    l10n,
                    refreshHost,
                    _RefreshSlot.libraries,
                  ),
                ),
              )
            else if (PhoneHomeSectionId.libraryIdOf(id) case final libraryId?
                when librariesById[libraryId] != null)
              RepaintBoundary(
                key: ValueKey(id),
                child: _DesktopLibraryLatest(
                  library: librariesById[libraryId]!,
                  headerAction: refreshLibraryId == libraryId
                      ? _refreshAction(
                          l10n,
                          refreshHost,
                          _RefreshSlot.libraries,
                        )
                      : null,
                ),
              ),
        ];
        return NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (notification.depth == 0 &&
                notification.metrics.axis == Axis.vertical) {
              HomeScrollNotification(
                notification.metrics.pixels > 24,
              ).dispatch(context);
            }
            return false;
          },
          child: MediaImageScrollListener(
            child: ListView.builder(
              key: const PageStorageKey('home-scroll'),
              // 只构建视口附近的分栏。每个片库一行如果整页铺开，
              // 片库列表一到就会同时请求并解码全部海报。
              scrollCacheExtent: const ScrollCacheExtent.viewport(0.5),
              padding: EdgeInsets.only(
                bottom: AppSpacing.xxl,
                top: bannerLeads ? 0 : overlap + AppSpacing.xl,
              ),
              itemCount: sectionChildren.isEmpty ? 1 : sectionChildren.length,
              itemBuilder: (context, index) {
                if (sectionChildren.isEmpty) {
                  return SizedBox(
                    width: double.infinity,
                    child: AppEmptyView(
                      message: l10n.browseEmpty,
                      action: _refreshAction(
                        l10n,
                        refreshHost,
                        _RefreshSlot.libraries,
                      ),
                    ),
                  );
                }
                return sectionChildren[index];
              },
            ),
          ),
        );
      },
    );
  }
}

class _DesktopLibraryLatest extends StatelessWidget {
  const _DesktopLibraryLatest({required this.library, this.headerAction});

  final EmbyItem library;
  final Widget? headerAction;

  @override
  Widget build(BuildContext context) {
    return LibraryLatestData(
      library: library,
      builder: (context, snapshot) {
        if (!snapshot.loading &&
            snapshot.error == null &&
            snapshot.items.isEmpty) {
          return const SizedBox.shrink();
        }
        return HomeMediaRow(
          rowKey: Key('home-library-${library.id}'),
          shelfId: 'library-${library.id}',
          title: library.name,
          state: CatalogRowState(
            items: snapshot.items,
            loading: snapshot.loading && snapshot.items.isEmpty,
            error: snapshot.error,
          ),
          headerAction: headerAction,
          onTap: (item) => context.push(AppRoutes.item(item.id)),
          onRetry: snapshot.retry,
          onMore: () => context.push(AppRoutes.library(library.id)),
        );
      },
    );
  }
}
