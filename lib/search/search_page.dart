import 'package:flutter/material.dart' hide SearchController;
import 'package:flutter/rendering.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/app_shell.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/widgets/app_empty_view.dart';
import 'package:rillight/app/widgets/app_error_view.dart';
import 'package:rillight/app/widgets/skeleton.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/catalog_cache.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_failure.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/home/media_shelf.dart';
import 'package:rillight/library/catalog_filter_button.dart';
import 'package:rillight/library/shelf_grid_page.dart';
import 'package:rillight/media_image/media_image.dart';
import 'package:rillight/search/search_action.dart';
import 'package:rillight/search/search_controller.dart';

class SearchPage extends StatefulWidget {
  const SearchPage({
    super.key,
    this.autofocus = false,
    this.focusNode,
    this.trailing,
  });

  /// 覆盖层打开时自动聚焦输入框。
  final bool autofocus;

  /// 由覆盖层持有时传入,便于再次呼出时聚焦且不重复入栈。
  final FocusNode? focusNode;

  /// 覆盖层关闭钮等:与搜索框同一行、贴窗口右侧,输入框仍居中。
  final Widget? trailing;

  /// 每页条数,与 searchByName 的 Limit 一致。
  static const int pageSize = 50;

  /// 滚动距底部不足该像素时预取下一页。
  static const double loadMoreThreshold = 600;

  /// 继续加载失败后的重试按钮。
  static const loadMoreRetryKey = Key('search-load-more-retry');

  /// 搜索输入区最大宽度,随 [AppBreakpoints] 舒展。
  static double fieldWidthFor(double screenWidth) {
    if (screenWidth < AppBreakpoints.compact) {
      return 560;
    }
    if (screenWidth < AppBreakpoints.large) {
      return 680;
    }
    return 800;
  }

  /// 搜索结果分页状态,供过期继续加载的回归读取。
  @visibleForTesting
  static ({
    List<String> itemIds,
    int fetched,
    bool hasMore,
    bool loadingMore,
    bool pageError,
  })
  debugLoadState(BuildContext context) {
    final state = (context as StatefulElement).state as _SearchPageState;
    return (
      itemIds: [for (final item in state._items) item.id],
      fetched: state._fetched,
      hasMore: state._hasMore,
      loadingMore: state._loadingMore,
      pageError: state._pageError != null,
    );
  }

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _query = TextEditingController();
  SearchController? _controller;
  SearchController get _search => _controller!;
  List<EmbyItem> get _items => _search.items;
  bool get _loading => _search.loading;
  bool get _loadingMore => _search.loadingMore;
  bool get _hasMore => _search.hasMore;
  bool get _searched => _search.searched;
  EmbyException? get _error => _search.error;
  EmbyException? get _pageError => _search.pageError;
  String get _term => _search.term;
  int get _fetched => _search.fetched;
  final ScrollController _scrollController = ScrollController();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller ??= SearchController(
      auth: AuthScope.of(context),
      cache: CatalogScope.maybeOf(context)?.cache ?? CatalogCache(),
    )..addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_maybeLoadMore);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_maybeLoadMore);
    _scrollController.dispose();
    _query.dispose();
    _controller?.removeListener(_changed);
    _controller?.dispose();
    super.dispose();
  }

  void _maybeLoadMore() {
    if (!_hasMore ||
        _loading ||
        _loadingMore ||
        _pageError != null ||
        _term.isEmpty) {
      return;
    }
    if (!_scrollController.hasClients) {
      return;
    }
    final position = _scrollController.position;
    if (position.pixels >=
        position.maxScrollExtent - SearchPage.loadMoreThreshold) {
      _loadMore();
    }
  }

  Future<void> _submit([String? raw]) => _search.submit(raw ?? _query.text);
  Future<void> _loadMore() => _search.loadMore();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final screenWidth = MediaQuery.sizeOf(context).width;
    final embedded = widget.trailing != null;
    final field = ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: SearchPage.fieldWidthFor(screenWidth),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              key: CatalogKeys.searchField,
              controller: _query,
              focusNode: widget.focusNode,
              autofocus: widget.autofocus,
              textInputAction: TextInputAction.search,
              style: Theme.of(context).textTheme.titleMedium,
              decoration: InputDecoration(
                hintText: l10n.searchHint,
                prefixIcon: const Icon(Icons.search),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.lg,
                  vertical: AppSpacing.md,
                ),
              ),
              onSubmitted: (value) => _submit(value),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          FilledButton(
            key: CatalogKeys.searchSubmit,
            onPressed: _loading ? null : () => _submit(),
            child: Text(l10n.search),
          ),
          CatalogFilterButton(
            watch: _search.watch,
            onChanged: _search.setWatch,
          ),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            embedded ? 0 : AppSpacing.md,
            embedded
                ? AppSpacing.xs
                : AppSpacing.xl +
                      (context.findAncestorWidgetOfExactType<AppShell>() != null
                          ? AppShell.topBarHeight
                          : 0),
            embedded ? 0 : AppSpacing.md,
            AppSpacing.md,
          ),
          child: embedded
              ? Row(
                  children: [
                    const SizedBox(width: 48),
                    Expanded(child: Center(child: field)),
                    widget.trailing!,
                  ],
                )
              : Center(child: field),
        ),
        if (_search.watch != null)
          CatalogWatchChip(
            watch: _search.watch!,
            onClear: () => _search.setWatch(null),
          ),
        Expanded(child: _buildBody(l10n, screenWidth)),
      ],
    );
  }

  Widget _buildBody(AppLocalizations l10n, double screenWidth) {
    if (_loading) {
      return SkeletonPosterGrid(
        maxCrossAxisExtent: ShelfGridPage.maxCrossAxisExtentFor(screenWidth),
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.page,
          AppSpacing.xs,
          AppSpacing.page,
          AppSpacing.xxl,
        ),
      );
    }
    if (_error != null) {
      return AppErrorView(
        message: searchFailureMessage(l10n, _error!),
        onRetry: _submit,
      );
    }
    if (!_searched) {
      return AppEmptyView(icon: Icons.search, message: l10n.searchEmptyQuery);
    }
    if (_items.isEmpty) {
      return AppEmptyView(
        key: CatalogKeys.searchNoResults,
        icon: Icons.search_off,
        message: l10n.searchNoResults,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_pageError != null)
          CatalogInlineFailure(
            message: searchFailureMessage(l10n, _pageError!),
            onRetry: _loadMore,
            retryKey: SearchPage.loadMoreRetryKey,
          ),
        Expanded(
          child: Shortcuts(
            shortcuts: catalogGridArrowShortcuts,
            child: FocusTraversalGroup(
              policy: ReadingOrderTraversalPolicy(),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return MediaImageScrollListener(
                    child: GridView.builder(
                      controller: _scrollController,
                      scrollCacheExtent: const ScrollCacheExtent.viewport(0.5),
                      padding: const EdgeInsets.fromLTRB(
                        AppSpacing.page,
                        AppSpacing.xs,
                        AppSpacing.page,
                        AppSpacing.xxl,
                      ),
                      gridDelegate: ShelfGridPage.gridDelegateFor(
                        screenWidth: screenWidth,
                        availableWidth:
                            constraints.maxWidth - AppSpacing.page * 2,
                        labelExtent: MediaShelf.posterLabelExtentFor(
                          context,
                          showProgress: false,
                        ),
                      ),
                      itemCount: _items.length + (_loadingMore ? 1 : 0),
                      itemBuilder: (context, index) {
                        if (index >= _items.length) {
                          return const Center(
                            child: CircularProgressIndicator(),
                          );
                        }
                        final item = _items[index];
                        return CatalogEnsureVisibleOnFocus(
                          child: ShelfGridPage.gridCard(
                            context,
                            item,
                            onTap: () {
                              closeSearch(context);
                              context.push(AppRoutes.item(item.id));
                            },
                          ),
                        );
                      },
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}
