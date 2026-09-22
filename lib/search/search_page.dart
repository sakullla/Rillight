import 'package:flutter/material.dart';
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
import 'package:rillight/library/shelf_grid_page.dart';
import 'package:rillight/media_image/media_image.dart';
import 'package:rillight/search/search_action.dart';

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
  List<EmbyItem> _items = const [];
  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = false;
  bool _searched = false;
  EmbyException? _error;
  EmbyException? _pageError;
  String _term = '';
  int _fetched = 0;
  int _loadGen = 0;
  final ScrollController _scrollController = ScrollController();

  CatalogCache? _scopeCache;

  /// 目录缓存:无 CatalogScope 时用无会话实例降级直连。
  CatalogCache get _cache =>
      _scopeCache ??= CatalogScope.maybeOf(context)?.cache ?? CatalogCache();

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

  Future<void> _submit([String? raw]) async {
    final gen = ++_loadGen;
    final term = (raw ?? _query.text).trim();
    if (term.isEmpty) {
      setState(() {
        _searched = false;
        _items = const [];
        _error = null;
        _pageError = null;
        _loading = false;
        _loadingMore = false;
        _hasMore = false;
        _term = '';
        _fetched = 0;
      });
      return;
    }
    setState(() {
      _loading = true;
      _loadingMore = false;
      _error = null;
      _pageError = null;
      _searched = true;
      _term = term;
    });
    final client = AuthScope.of(context).client;
    final request = catalogSearchRequest(
      userId: client.userId ?? '',
      searchTerm: term,
      startIndex: 0,
    );
    // 先显:命中缓存立即渲染上一轮结果,后台重拉完成后无感更新。
    final hit = await _cache.lookup(request);
    if (!mounted || gen != _loadGen) {
      return;
    }
    if (hit != null) {
      final raw = parseCatalogPage(hit.json).items;
      setState(() {
        _items = raw.where((item) => item.isMovieOrSeries).toList();
        _fetched = raw.length;
        _hasMore = raw.length >= SearchPage.pageSize;
        _loading = false;
      });
    }
    try {
      final raw = parseCatalogPage(await _cache.fetch(client, request)).items;
      if (!mounted || gen != _loadGen) {
        return;
      }
      setState(() {
        _items = raw.where((item) => item.isMovieOrSeries).toList();
        _fetched = raw.length;
        _hasMore = raw.length >= SearchPage.pageSize;
        _loading = false;
      });
    } on EmbyException catch (error) {
      if (!mounted || gen != _loadGen) {
        return;
      }
      setState(() {
        _error = error;
        _items = const [];
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (!_hasMore || _loading || _loadingMore || _term.isEmpty) {
      return;
    }
    final gen = _loadGen;
    final start = _fetched;
    final term = _term;
    setState(() {
      _loadingMore = true;
      _pageError = null;
    });
    try {
      final client = AuthScope.of(context).client;
      final raw = parseCatalogPage(
        await _cache.fetch(
          client,
          catalogSearchRequest(
            userId: client.userId ?? '',
            searchTerm: term,
            startIndex: start,
          ),
        ),
      ).items;
      if (!mounted || gen != _loadGen) {
        return;
      }
      setState(() {
        // 分页追加按 itemId 去重,排序窗口重叠不产生重复条目。
        _items = ShelfGridPage.mergeItemsById(
          _items,
          raw.where((item) => item.isMovieOrSeries),
        );
        _fetched = start + raw.length;
        _hasMore = raw.length >= SearchPage.pageSize;
        _loadingMore = false;
      });
    } on EmbyException catch (error) {
      if (!mounted || gen != _loadGen) {
        return;
      }
      // 追加失败保留已有结果,在结果上方说明并提供重试。
      setState(() {
        _loadingMore = false;
        _pageError = error;
      });
    } finally {
      if (mounted && gen == _loadGen && _loadingMore) {
        setState(() => _loadingMore = false);
      }
    }
  }

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
